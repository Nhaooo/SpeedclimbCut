import AVFoundation
import CoreMedia
import Foundation
import Vision

final class HybridVisionTrackingService {
    struct TrackingAnalysis {
        let track: PersonTrack
        let debugLogs: String
    }

    struct RefinementResult {
        let startTime: CMTime?
        let topTime: CMTime?
        let debugLogs: String
    }

    func analyze(asset: AVAsset, videoTrack: AVAssetTrack, orientation: CGImagePropertyOrientation) async throws -> TrackingAnalysis? {
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            throw NSError(domain: "HybridVisionTrackingService", code: 10, userInfo: [NSLocalizedDescriptionKey: "Impossible d'ajouter la sortie video au lecteur"])
        }

        reader.add(trackOutput)

        guard reader.startReading() else {
            throw NSError(domain: "HybridVisionTrackingService", code: 11, userInfo: [NSLocalizedDescriptionKey: reader.error?.localizedDescription ?? "Impossible de demarrer la lecture video"])
        }

        let frameInterval = CMTime(seconds: 1.0 / Double(AppConfig.analysisFPS), preferredTimescale: 600)
        var nextTargetTime = CMTime.zero
        var sampledFrames = 0
        var lastResolvedBox: CGRect?
        var trackRequest: VNTrackObjectRequest?
        var points: [TrackPoint] = []
        var logs = "Hybrid pass 1: ROI voie + VNTrackObjectRequest.\n"

        let detectRequest = VNDetectHumanRectanglesRequest()
        detectRequest.regionOfInterest = AppConfig.laneRegionOfInterest

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts < nextTargetTime {
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                nextTargetTime = CMTimeAdd(nextTargetTime, frameInterval)
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            var currentBox: CGRect?

            if let activeTrackRequest = trackRequest {
                do {
                    try handler.perform([activeTrackRequest])
                    if let trackedObservation = activeTrackRequest.results?.first as? VNDetectedObjectObservation,
                       trackedObservation.confidence >= AppConfig.trackingConfidenceThreshold {
                        let transformed = clampToUnitRect(transformRect(trackedObservation.boundingBox, orientation: orientation))
                        if transformed.intersects(AppConfig.laneRegionOfInterest) {
                            currentBox = transformed
                            activeTrackRequest.inputObservation = trackedObservation
                        } else {
                            trackRequest = nil
                        }
                    } else {
                        trackRequest = nil
                    }
                } catch {
                    logs += "Track Vision error @ \(String(format: "%.2f", pts.seconds))s: \(error.localizedDescription)\n"
                    trackRequest = nil
                }
            }

            let shouldRedetect = currentBox == nil || sampledFrames % AppConfig.trackerRedetectionInterval == 0
            if shouldRedetect {
                do {
                    try handler.perform([detectRequest])
                    let observations = (detectRequest.results as? [VNHumanObservation]) ?? []
                    if let selectedRawBox = selectBestHumanBox(from: observations, previousBox: lastResolvedBox, orientation: orientation) {
                        let selectedBox = clampToUnitRect(transformRect(selectedRawBox, orientation: orientation))
                        currentBox = selectedBox

                        let seedObservation = VNDetectedObjectObservation(boundingBox: selectedRawBox)
                        let newTrackRequest = VNTrackObjectRequest(detectedObjectObservation: seedObservation)
                        newTrackRequest.trackingLevel = .accurate
                        trackRequest = newTrackRequest
                    }
                } catch {
                    logs += "Detect Vision error @ \(String(format: "%.2f", pts.seconds))s: \(error.localizedDescription)\n"
                }
            }

            if let resolvedBox = currentBox {
                lastResolvedBox = resolvedBox
                let anchorY = upperBodyAnchor(for: resolvedBox)
                points.append(TrackPoint(time: pts, y: anchorY, bbox: resolvedBox))
            }

            sampledFrames += 1
            nextTargetTime = CMTimeAdd(nextTargetTime, frameInterval)
            CMSampleBufferInvalidate(sampleBuffer)
        }

        guard !points.isEmpty else {
            logs += "Aucune piste athlete stable detectee dans la ROI.\n"
            return nil
        }

        let id = UUID()
        let track = PersonTrack(id: id, points: points)
        logs += "Hybrid pass 1 OK: \(points.count) points, peakY \(String(format: "%.2f", track.peakHeight)), lastY \(String(format: "%.2f", track.lastHeight)).\n"
        return TrackingAnalysis(track: track, debugLogs: logs)
    }

    func refineEventTimes(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        orientation: CGImagePropertyOrientation,
        baseTrack: PersonTrack,
        roughResult: AnalysisResult
    ) async throws -> RefinementResult {
        var logs = "Hybrid pass 2: body pose upper-body.\n"

        let refinedStart = try refineEventTime(
            asset: asset,
            videoTrack: videoTrack,
            orientation: orientation,
            baseTrack: baseTrack,
            around: roughResult.startTime ?? baseTrack.points.first?.time,
            preferHands: false,
            eventName: "start"
        )
        logs += refinedStart.logs

        let topReference = roughResult.topTime ?? baseTrack.points.max(by: { $0.y < $1.y })?.time
        let refinedTop = try refineEventTime(
            asset: asset,
            videoTrack: videoTrack,
            orientation: orientation,
            baseTrack: baseTrack,
            around: topReference,
            preferHands: true,
            eventName: "top"
        )
        logs += refinedTop.logs

        return RefinementResult(startTime: refinedStart.time, topTime: refinedTop.time, debugLogs: logs)
    }

    private func refineEventTime(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        orientation: CGImagePropertyOrientation,
        baseTrack: PersonTrack,
        around referenceTime: CMTime?,
        preferHands: Bool,
        eventName: String
    ) throws -> (time: CMTime?, logs: String) {
        guard let referenceTime else {
            return (nil, "Body pose \(eventName): reference time missing.\n")
        }

        let duration = CMTime(seconds: AppConfig.poseRefinementWindowSeconds, preferredTimescale: 600)
        let assetDuration = asset.duration
        let rangeStart = CMTimeMaximum(CMTimeSubtract(referenceTime, duration), .zero)
        let rangeEnd = CMTimeMinimum(CMTimeAdd(referenceTime, duration), assetDuration)

        if rangeStart >= rangeEnd {
            return (referenceTime, "Body pose \(eventName): invalid refinement window, keeping rough time.\n")
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: rangeStart, end: rangeEnd)

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            throw NSError(domain: "HybridVisionTrackingService", code: 12, userInfo: [NSLocalizedDescriptionKey: "Impossible d'ajouter la sortie video du second pass"])
        }

        reader.add(trackOutput)

        guard reader.startReading() else {
            throw NSError(domain: "HybridVisionTrackingService", code: 13, userInfo: [NSLocalizedDescriptionKey: reader.error?.localizedDescription ?? "Impossible de demarrer la lecture du second pass"])
        }

        let frameInterval = CMTime(seconds: 1.0 / Double(AppConfig.poseRefinementFPS), preferredTimescale: 600)
        var nextTargetTime = rangeStart
        var samples: [TrackPoint] = []

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts < nextTargetTime {
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let basePoint = nearestTrackPoint(to: pts, in: baseTrack.points) else {
                nextTargetTime = CMTimeAdd(nextTargetTime, frameInterval)
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            let poseRequest = VNDetectHumanBodyPoseRequest()
            poseRequest.regionOfInterest = expandedPoseROI(from: basePoint.bbox)

            var anchorY = upperBodyAnchor(for: basePoint.bbox)

            do {
                try handler.perform([poseRequest])
                if let observation = (poseRequest.results as? [VNHumanBodyPoseObservation])?.first,
                   let poseAnchor = extractUpperBodyAnchor(from: observation, preferHands: preferHands) {
                    anchorY = poseAnchor
                }
            } catch {
                // Keep the bbox-based fallback anchor if body pose fails on a frame.
            }

            samples.append(TrackPoint(time: pts, y: anchorY, bbox: basePoint.bbox))
            nextTargetTime = CMTimeAdd(nextTargetTime, frameInterval)
            CMSampleBufferInvalidate(sampleBuffer)
        }

        guard samples.count >= 3 else {
            return (referenceTime, "Body pose \(eventName): too few refined samples, keeping rough time.\n")
        }

        let refinedTime = eventName == "start"
            ? detectStartTime(in: samples) ?? referenceTime
            : detectTopTime(in: samples) ?? referenceTime

        let logs = "Body pose \(eventName): \(samples.count) samples, refined -> \(String(format: "%.2f", refinedTime.seconds))s.\n"
        return (refinedTime, logs)
    }

    private func detectStartTime(in points: [TrackPoint]) -> CMTime? {
        guard let firstPoint = points.first else { return nil }

        var lastY = firstPoint.y
        var consecutiveUpFrames = 0

        for (index, point) in points.enumerated() {
            let dy = point.y - lastY

            if point.y < AppConfig.startZoneMaxY && dy > AppConfig.startVelocityThreshold {
                consecutiveUpFrames += 1
                if consecutiveUpFrames >= max(AppConfig.startConfirmationFrames - 2, 2) {
                    let startIndex = max(index - consecutiveUpFrames + 1, 0)
                    return points[startIndex].time
                }
            } else if dy <= 0 {
                consecutiveUpFrames = 0
            }

            lastY = point.y
        }

        return nil
    }

    private func detectTopTime(in points: [TrackPoint]) -> CMTime? {
        guard let firstPoint = points.first else { return nil }

        var lastY = firstPoint.y
        var stableFrames = 0

        for point in points {
            let dy = point.y - lastY

            if point.y > AppConfig.topZoneMinY {
                if abs(dy) < AppConfig.topStabilizationThreshold || dy < 0 {
                    stableFrames += 1
                    if stableFrames >= max(AppConfig.topStabilizationFrames - 1, 2) {
                        return point.time
                    }
                } else {
                    stableFrames = 0
                }
            }

            lastY = point.y
        }

        return points.max(by: { $0.y < $1.y })?.time
    }

    private func selectBestHumanBox(
        from observations: [VNHumanObservation],
        previousBox: CGRect?,
        orientation: CGImagePropertyOrientation
    ) -> CGRect? {
        observations
            .filter { $0.confidence >= AppConfig.trackingConfidenceThreshold }
            .map(\.boundingBox)
            .filter { transformRect($0, orientation: orientation).intersects(AppConfig.laneRegionOfInterest) }
            .max { lhs, rhs in
                score(for: lhs, previousBox: previousBox, orientation: orientation)
                    < score(for: rhs, previousBox: previousBox, orientation: orientation)
            }
    }

    private func score(for rawBox: CGRect, previousBox: CGRect?, orientation: CGImagePropertyOrientation) -> CGFloat {
        let box = clampToUnitRect(transformRect(rawBox, orientation: orientation))
        let areaScore = box.width * box.height * 2.0
        let lanePenalty = abs(box.midX - AppConfig.laneRegionOfInterest.midX)

        guard let previousBox else {
            return areaScore - lanePenalty
        }

        let continuityPenalty = abs(box.midX - previousBox.midX) + abs(box.maxY - previousBox.maxY)
        return areaScore - lanePenalty - (continuityPenalty * 1.5)
    }

    private func upperBodyAnchor(for box: CGRect) -> CGFloat {
        clamp(box.minY + (box.height * AppConfig.upperBodyAnchorRatio), min: 0, max: 1)
    }

    private func expandedPoseROI(from box: CGRect) -> CGRect {
        let expanded = box.insetBy(
            dx: -(box.width * AppConfig.poseHorizontalPaddingRatio),
            dy: -(box.height * AppConfig.poseVerticalPaddingRatio)
        )

        return clampToUnitRect(expanded.intersection(AppConfig.laneRegionOfInterest))
    }

    private func extractUpperBodyAnchor(from observation: VNHumanBodyPoseObservation, preferHands: Bool) -> CGFloat? {
        guard let recognizedPoints = try? observation.recognizedPoints(.all) else {
            return nil
        }

        let preferredJoints: [VNHumanBodyPoseObservation.JointName] = preferHands
            ? [.leftWrist, .rightWrist, .nose, .neck, .leftShoulder, .rightShoulder]
            : [.nose, .neck, .leftShoulder, .rightShoulder, .leftWrist, .rightWrist]

        let anchors = preferredJoints.compactMap { jointName -> CGFloat? in
            guard let point = recognizedPoints[jointName], point.confidence >= AppConfig.poseConfidenceThreshold else {
                return nil
            }
            return CGFloat(point.location.y)
        }

        return anchors.max()
    }

    private func nearestTrackPoint(to time: CMTime, in points: [TrackPoint]) -> TrackPoint? {
        points.min { lhs, rhs in
            abs(lhs.time.seconds - time.seconds) < abs(rhs.time.seconds - time.seconds)
        }
    }

    private func clampToUnitRect(_ rect: CGRect) -> CGRect {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        if clipped.isNull || clipped.isEmpty {
            return CGRect(x: clamp(rect.origin.x, min: 0, max: 1),
                          y: clamp(rect.origin.y, min: 0, max: 1),
                          width: min(max(rect.width, 0.01), 1),
                          height: min(max(rect.height, 0.01), 1))
        }
        return clipped
    }

    private func clamp(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minimum), maximum)
    }

    private func transformRect(_ rect: CGRect, orientation: CGImagePropertyOrientation) -> CGRect {
        switch orientation {
        case .up:
            return rect
        case .down:
            return CGRect(x: 1 - rect.maxX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        case .left:
            return CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        case .right:
            return CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        default:
            return rect
        }
    }
}
