import AVFoundation
import CoreImage
import CoreGraphics
import Foundation
import ImageIO
import Vision

final class TrackMotionFusionService {
    struct Analysis {
        let startTime: CMTime?
        let topTime: CMTime?
        let confidenceScore: CGFloat
        let method: String
        let debugLogs: String
    }

    private struct MotionCurve {
        let times: [Double]
        let values: [Double]
    }

    private struct MotionTiming {
        let startTime: Double?
        let topTime: Double?

        var isValid: Bool {
            guard let startTime, let topTime else { return false }
            return topTime > startTime
        }

        var duration: Double? {
            guard let startTime, let topTime else { return nil }
            return topTime - startTime
        }
    }

    private struct PreferredStart {
        let startTime: Double?
        let method: String
    }

    private struct TrackState {
        let id: Int
        var points: [TrackPoint]
        var missedFrames: Int
        var isDead: Bool
    }

    private struct CandidateTrack {
        let id: Int
        let startTime: Double
        let topTime: Double
        let gain: Double
        let pointCount: Int
        let peakMotion: Double
        let score: Double
    }

    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func analyze(asset: AVAsset, videoTrack: AVAssetTrack, orientation: CGImagePropertyOrientation) async throws -> Analysis {
        let assetDuration = (try? await asset.load(.duration)) ?? videoTrack.timeRange.duration
        let analysisWindow = analysisTimeRange(for: assetDuration)
        let motionCurve = try extractMotionCurve(
            asset: asset,
            videoTrack: videoTrack,
            orientation: orientation,
            analysisWindow: analysisWindow
        )

        guard !motionCurve.times.isEmpty else {
            return Analysis(
                startTime: nil,
                topTime: nil,
                confidenceScore: 0,
                method: "fusion_none",
                debugLogs: "Fusion motion-track: aucune courbe motion exploitable.\n"
            )
        }

        let startSeries = smooth(motionCurve.values, window: AppConfig.motionBaselineSmoothWindow)
        let topSeries = smooth(motionCurve.values, window: AppConfig.fusionTopSmoothWindow)
        let baseline = motionStateMachine(times: motionCurve.times, values: startSeries)
        let valleyPeak = motionValleyPeak(times: motionCurve.times, values: startSeries)
        let preferredStart = preferredStart(primary: baseline, fallback: valleyPeak)

        var logs = """
        Fusion motion-track: \(motionCurve.values.count) motion samples.
        Fusion motion window -> \(String(format: "%.2f", analysisWindow?.start.seconds ?? 0))s to \(String(format: "%.2f", analysisWindow?.end.seconds ?? assetDuration.seconds))s
        Fusion baseline -> start: \(baseline.startTime ?? -1), top: \(baseline.topTime ?? -1)
        Fusion valley_peak -> start: \(valleyPeak.startTime ?? -1), top: \(valleyPeak.topTime ?? -1)
        Fusion preferred start -> method: \(preferredStart.method), start: \(preferredStart.startTime ?? -1)
        """

        guard let preferredStartTime = preferredStart.startTime else {
            return Analysis(
                startTime: nil,
                topTime: nil,
                confidenceScore: CGFloat(motionCurve.values.max() ?? 0),
                method: preferredStart.method,
                debugLogs: logs + "\nFusion motion-track: aucun start motion fiable.\n"
            )
        }

        guard let trackingWindow = trackingWindow(
            around: preferredStartTime,
            within: analysisWindow,
            assetDuration: assetDuration
        ) else {
            return Analysis(
                startTime: nil,
                topTime: nil,
                confidenceScore: CGFloat(motionCurve.values.max() ?? 0),
                method: preferredStart.method,
                debugLogs: logs + "\nFusion motion-track: fenetre de tracking invalide.\n"
            )
        }

        let candidates = try detectTrackCandidates(
            asset: asset,
            videoTrack: videoTrack,
            orientation: orientation,
            trackingWindow: trackingWindow,
            preferredStartTime: preferredStartTime,
            motionTimes: motionCurve.times,
            topSeries: topSeries
        )

        logs += "Fusion tracking window -> \(String(format: "%.2f", trackingWindow.start.seconds))s to \(String(format: "%.2f", trackingWindow.end.seconds))s\n"

        guard !candidates.isEmpty else {
            return Analysis(
                startTime: nil,
                topTime: nil,
                confidenceScore: CGFloat(motionCurve.values.max() ?? 0),
                method: preferredStart.method,
                debugLogs: logs + "Fusion motion-track: aucune piste candidate valide.\n"
            )
        }

        let sortedCandidates = candidates.sorted { lhs, rhs in lhs.score > rhs.score }
        for candidate in sortedCandidates.prefix(5) {
            logs += "Fusion candidate #\(candidate.id) -> start \(String(format: "%.2f", candidate.startTime))s, top \(String(format: "%.2f", candidate.topTime))s, gain \(String(format: "%.3f", candidate.gain)), points \(candidate.pointCount), peak \(String(format: "%.3f", candidate.peakMotion)), score \(String(format: "%.3f", candidate.score))\n"
        }

        guard let selected = sortedCandidates.first else {
            return Analysis(
                startTime: nil,
                topTime: nil,
                confidenceScore: CGFloat(motionCurve.values.max() ?? 0),
                method: preferredStart.method,
                debugLogs: logs + "Fusion motion-track: impossible de choisir une candidate.\n"
            )
        }

        logs += "Fusion selected -> track \(selected.id), start \(String(format: "%.2f", selected.startTime))s, top \(String(format: "%.2f", selected.topTime))s\n"

        return Analysis(
            startTime: CMTime(seconds: selected.startTime, preferredTimescale: 600),
            topTime: CMTime(seconds: selected.topTime, preferredTimescale: 600),
            confidenceScore: CGFloat(min(max(selected.score / 2.0, 0.0), 1.0)),
            method: "fusion_\(preferredStart.method)",
            debugLogs: logs
        )
    }

    private func extractMotionCurve(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        orientation: CGImagePropertyOrientation,
        analysisWindow: CMTimeRange?
    ) throws -> MotionCurve {
        let reader = try AVAssetReader(asset: asset)
        if let analysisWindow {
            reader.timeRange = analysisWindow
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            throw NSError(
                domain: "TrackMotionFusionService",
                code: 100,
                userInfo: [NSLocalizedDescriptionKey: "Impossible d'ajouter la sortie video pour l'analyse fusion motion."]
            )
        }

        reader.add(trackOutput)

        guard reader.startReading() else {
            throw NSError(
                domain: "TrackMotionFusionService",
                code: 101,
                userInfo: [NSLocalizedDescriptionKey: reader.error?.localizedDescription ?? "Impossible de demarrer le lecteur motion fusion."]
            )
        }

        let frameInterval = CMTime(seconds: 1.0 / AppConfig.motionAnalysisFPS, preferredTimescale: 600)
        var nextTargetTime = analysisWindow?.start ?? .zero
        var previousGrid: [UInt8]?
        var times: [Double] = []
        var values: [Double] = []

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if presentationTime < nextTargetTime {
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }

            let grid: [UInt8]? = autoreleasepool {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    return nil
                }

                return renderGrid(from: pixelBuffer, orientation: orientation)
            }

            guard let grid else {
                nextTargetTime = CMTimeAdd(nextTargetTime, frameInterval)
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }

            if let previousGrid {
                values.append(computeMotionValue(previous: previousGrid, current: grid))
                times.append(presentationTime.seconds)
            }

            previousGrid = grid
            nextTargetTime = CMTimeAdd(nextTargetTime, frameInterval)
            CMSampleBufferInvalidate(sampleBuffer)
        }

        if reader.status == .failed {
            throw NSError(
                domain: "TrackMotionFusionService",
                code: 102,
                userInfo: [NSLocalizedDescriptionKey: reader.error?.localizedDescription ?? "Echec de lecture motion fusion."]
            )
        }

        return MotionCurve(times: times, values: values)
    }

    private func detectTrackCandidates(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        orientation: CGImagePropertyOrientation,
        trackingWindow: CMTimeRange,
        preferredStartTime: Double,
        motionTimes: [Double],
        topSeries: [Double]
    ) throws -> [CandidateTrack] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = trackingWindow

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            throw NSError(
                domain: "TrackMotionFusionService",
                code: 110,
                userInfo: [NSLocalizedDescriptionKey: "Impossible d'ajouter la sortie video pour le tracking fusion."]
            )
        }

        reader.add(trackOutput)

        guard reader.startReading() else {
            throw NSError(
                domain: "TrackMotionFusionService",
                code: 111,
                userInfo: [NSLocalizedDescriptionKey: reader.error?.localizedDescription ?? "Impossible de demarrer le tracking fusion."]
            )
        }

        let detectRequest = VNDetectHumanRectanglesRequest()
        detectRequest.regionOfInterest = AppConfig.laneRegionOfInterest

        let frameInterval = CMTime(seconds: 1.0 / Double(AppConfig.fusionVisionFPS), preferredTimescale: 600)
        var nextTargetTime = trackingWindow.start
        var tracks: [Int: TrackState] = [:]
        var nextID = 1
        var completedTracks: [TrackState] = []

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if presentationTime < nextTargetTime {
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }

            let boxes: [CGRect] = autoreleasepool {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    return []
                }

                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
                do {
                    try handler.perform([detectRequest])
                    let observations = (detectRequest.results as? [VNHumanObservation]) ?? []
                    return observations
                        .filter { $0.confidence >= AppConfig.trackingConfidenceThreshold }
                        .map(\.boundingBox)
                        .map { transformRect($0, orientation: orientation) }
                        .map { clampToUnitRect($0) }
                        .filter { isTrackLaneCandidate($0) }
                } catch {
                    return []
                }
            }

            process(boxes: boxes, at: presentationTime, tracks: &tracks, completedTracks: &completedTracks, nextID: &nextID)
            nextTargetTime = CMTimeAdd(nextTargetTime, frameInterval)
            CMSampleBufferInvalidate(sampleBuffer)
        }

        if reader.status == .failed {
            throw NSError(
                domain: "TrackMotionFusionService",
                code: 112,
                userInfo: [NSLocalizedDescriptionKey: reader.error?.localizedDescription ?? "Echec du tracking fusion."]
            )
        }

        let allTracks = Array(tracks.values) + completedTracks
        return allTracks.compactMap { track in
            guard track.points.count >= AppConfig.fusionTrackMinPoints else { return nil }

            let yValues = track.points.map { Double($0.y) }
            guard let minY = yValues.min(), let maxY = yValues.max() else { return nil }

            let gain = maxY - minY
            guard gain >= AppConfig.fusionTrackMinGain else { return nil }

            let startTime = track.points[0].time.seconds
            guard let topEstimate = estimateTopTime(times: motionTimes, values: topSeries, startTime: startTime) else {
                return nil
            }

            let score =
                (-abs(startTime - preferredStartTime)) +
                (gain * 2.0) +
                min(Double(track.points.count) / 20.0, 1.0)

            return CandidateTrack(
                id: track.id,
                startTime: startTime,
                topTime: topEstimate.time,
                gain: gain,
                pointCount: track.points.count,
                peakMotion: topEstimate.peak,
                score: score
            )
        }
    }

    private func process(
        boxes: [CGRect],
        at time: CMTime,
        tracks: inout [Int: TrackState],
        completedTracks: inout [TrackState],
        nextID: inout Int
    ) {
        var unassignedBoxes = boxes

        let sortedTrackIDs = tracks.values
            .filter { !$0.isDead }
            .sorted { lhs, rhs in
                if lhs.points.count == rhs.points.count {
                    return lhs.id < rhs.id
                }
                return lhs.points.count > rhs.points.count
            }
            .map(\.id)

        for id in sortedTrackIDs {
            guard var track = tracks[id], let lastPoint = track.points.last else { continue }

            if let matchedIndex = bestMatchIndex(for: lastPoint.bbox, in: unassignedBoxes) {
                let matchedBox = unassignedBoxes.remove(at: matchedIndex)
                track.points.append(TrackPoint(time: time, y: topOfBoxValue(for: matchedBox), bbox: matchedBox))
                track.missedFrames = 0
                tracks[id] = track
            } else {
                track.missedFrames += 1
                if track.missedFrames > AppConfig.fusionTrackMaxMissedFrames {
                    track.isDead = true
                    completedTracks.append(track)
                    tracks.removeValue(forKey: id)
                } else {
                    tracks[id] = track
                }
            }
        }

        for box in unassignedBoxes {
            let track = TrackState(
                id: nextID,
                points: [TrackPoint(time: time, y: topOfBoxValue(for: box), bbox: box)],
                missedFrames: 0,
                isDead: false
            )
            tracks[nextID] = track
            nextID += 1
        }
    }

    private func bestMatchIndex(for lastBox: CGRect, in boxes: [CGRect]) -> Int? {
        let lastCenter = CGPoint(x: lastBox.midX, y: lastBox.midY)

        return boxes.enumerated()
            .compactMap { entry -> (index: Int, score: CGFloat)? in
                let index = entry.offset
                let box = entry.element
                let dx = abs(box.midX - lastCenter.x)
                let dy = lastCenter.y - box.midY

                guard dx < AppConfig.fusionTrackMaxDX else { return nil }
                guard dy > AppConfig.fusionTrackMinDY else { return nil }
                guard dy < AppConfig.fusionTrackMaxDY else { return nil }

                let iouBoost = intersectionOverUnion(lastBox, box)
                return (index: index, score: dx + (abs(dy) * 0.4) - (iouBoost * 0.15))
            }
            .min(by: { $0.score < $1.score })?
            .index
    }

    private func estimateTopTime(times: [Double], values: [Double], startTime: Double) -> (time: Double, peak: Double)? {
        let candidateIndices = times.indices.filter { index in
            let time = times[index]
            return time >= startTime + AppConfig.fusionTopMinDuration
                && time <= startTime + AppConfig.fusionTopMaxDuration
        }

        guard !candidateIndices.isEmpty else { return nil }

        let windowValues = candidateIndices.map { values[$0] }
        guard let peak = windowValues.max(), peak >= AppConfig.fusionTopPeakMin else {
            return nil
        }

        let threshold = peak * AppConfig.fusionTopPeakHighRatio
        let highIndices = candidateIndices.filter { values[$0] >= threshold }
        guard let firstHighIndex = highIndices.first else {
            return nil
        }

        var plateauEndIndex = firstHighIndex
        for index in highIndices.dropFirst() {
            if index == plateauEndIndex + 1 {
                plateauEndIndex = index
            } else {
                break
            }
        }

        return (time: times[plateauEndIndex], peak: peak)
    }

    private func renderGrid(from pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> [UInt8]? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(forExifOrientation: Int32(orientation.rawValue))

        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }

        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scaleTransform = CGAffineTransform(
            scaleX: CGFloat(AppConfig.fusionMotionGridWidth) / extent.width,
            y: CGFloat(AppConfig.fusionMotionGridHeight) / extent.height
        )

        let scaled = normalized
            .transformed(by: scaleTransform)
            .cropped(to: CGRect(x: 0, y: 0, width: AppConfig.fusionMotionGridWidth, height: AppConfig.fusionMotionGridHeight))

        guard let cgImage = ciContext.createCGImage(
            scaled,
            from: CGRect(x: 0, y: 0, width: AppConfig.fusionMotionGridWidth, height: AppConfig.fusionMotionGridHeight)
        ) else {
            return nil
        }

        guard let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return nil
        }

        let width = AppConfig.fusionMotionGridWidth
        let height = AppConfig.fusionMotionGridHeight
        let bytesPerRow = cgImage.bytesPerRow
        var grayscale = [UInt8](repeating: 0, count: width * height)

        for row in 0..<height {
            let sourceRow = (height - 1) - row
            let rowPointer = bytes + (sourceRow * bytesPerRow)
            for column in 0..<width {
                let pixelOffset = column * 4
                let red = Int(rowPointer[pixelOffset])
                let green = Int(rowPointer[pixelOffset + 1])
                let blue = Int(rowPointer[pixelOffset + 2])
                grayscale[(row * width) + column] = UInt8((red + green + blue) / 3)
            }
        }

        return grayscale
    }

    private func computeMotionValue(previous: [UInt8], current: [UInt8]) -> Double {
        let width = AppConfig.fusionMotionGridWidth
        let height = AppConfig.fusionMotionGridHeight
        let startColumn = AppConfig.fusionMotionLaneStartColumn
        let endColumn = min(AppConfig.fusionMotionLaneEndColumn, width)

        for row in 0..<height {
            var activeCells = 0
            for column in startColumn..<endColumn {
                let index = (row * width) + column
                let delta = abs(Int(current[index]) - Int(previous[index]))
                if delta >= AppConfig.motionThreshold {
                    activeCells += 1
                }
            }

            if activeCells >= AppConfig.fusionMotionMinActiveCellsPerRow {
                return 1.0 - (Double(row) / Double(height))
            }
        }

        return 0.0
    }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        if intersection.isNull || intersection.isEmpty {
            return 0
        }

        let intersectionArea = intersection.width * intersection.height
        let unionArea = (lhs.width * lhs.height) + (rhs.width * rhs.height) - intersectionArea
        guard unionArea > 0 else {
            return 0
        }

        return intersectionArea / unionArea
    }

    private func smooth(_ values: [Double], window: Int) -> [Double] {
        guard window > 1 else { return values }

        var smoothed: [Double] = []
        smoothed.reserveCapacity(values.count)

        for index in values.indices {
            let startIndex = max(0, index - window + 1)
            let slice = values[startIndex...index]
            smoothed.append(slice.reduce(0, +) / Double(slice.count))
        }

        return smoothed
    }

    private func motionStateMachine(times: [Double], values: [Double]) -> MotionTiming {
        guard let firstValue = values.first else {
            return MotionTiming(startTime: nil, topTime: nil)
        }

        var state = "idle"
        var startTime: Double?
        var topTime: Double?
        var upCount = 0
        var stableCount = 0
        var lastValue = firstValue

        for (time, value) in zip(times, values) {
            let delta = value - lastValue

            switch state {
            case "idle":
                if value > AppConfig.motionBaselineStartMin,
                   value < AppConfig.motionBaselineStartMax,
                   delta > AppConfig.motionBaselineStartVelocity {
                    upCount += 1
                    if upCount >= AppConfig.motionBaselineStartFrames {
                        state = "climbing"
                        startTime = max(0.0, time - 0.5)
                    }
                } else if delta <= 0 {
                    upCount = 0
                }

            case "climbing":
                if value > AppConfig.motionBaselineTopMin {
                    state = "near_top"
                }

            case "near_top":
                if abs(delta) < AppConfig.motionBaselineTopVelocityThreshold || delta < 0 {
                    stableCount += 1
                    if stableCount >= AppConfig.motionBaselineTopStableFrames {
                        topTime = time
                        return MotionTiming(startTime: startTime, topTime: topTime)
                    }
                } else {
                    stableCount = 0
                }

            default:
                break
            }

            lastValue = value
        }

        return MotionTiming(startTime: startTime, topTime: topTime)
    }

    private func motionValleyPeak(times: [Double], values: [Double]) -> MotionTiming {
        guard values.count > AppConfig.motionValleyLookahead else {
            return MotionTiming(startTime: nil, topTime: nil)
        }

        var startCandidates: [Int] = []
        let maxStartIndex = values.count - AppConfig.motionValleyLookahead

        for index in AppConfig.motionValleyPreWindow..<maxStartIndex {
            let before = Array(values[(index - AppConfig.motionValleyPreWindow)...index])
            let after = Array(values[(index + 1)..<(index + 1 + AppConfig.motionValleyLookahead)])

            guard let minBefore = before.min(), let maxAfter = after.max() else { continue }

            if values[index] <= AppConfig.motionValleyStartMax,
               (before.reduce(0, +) / Double(before.count)) <= AppConfig.motionValleyCalmMax,
               values[index] <= minBefore,
               (maxAfter - values[index]) >= AppConfig.motionValleyRiseMin {
                startCandidates.append(index)
            }
        }

        startCandidates = dedupe(indices: startCandidates, minimumGap: AppConfig.motionValleyStartGap)

        var peakCandidates: [Int] = []
        if values.count > AppConfig.motionValleyFallWindow + 1 {
            let maxPeakIndex = values.count - AppConfig.motionValleyFallWindow - 1
            for index in 1..<maxPeakIndex {
                let tail = Array(values[index...(index + AppConfig.motionValleyFallWindow)])
                guard let minimumTail = tail.min() else { continue }

                let fall = values[index] - minimumTail
                let isLocalMaximum = values[index] >= values[index - 1] && values[index] >= values[index + 1]

                if isLocalMaximum,
                   values[index] >= AppConfig.motionValleyTopMin,
                   fall >= AppConfig.motionValleyFallMin {
                    peakCandidates.append(index)
                }
            }
        }

        var bestScore: Double?
        var bestPair: (Int, Int)?

        for startIndex in startCandidates {
            let startTime = times[startIndex]

            for peakIndex in peakCandidates where peakIndex > startIndex {
                let peakTime = times[peakIndex]
                let duration = peakTime - startTime

                if duration < AppConfig.motionValleyMinDuration || duration > AppConfig.motionValleyMaxDuration {
                    continue
                }

                let score =
                    (values[peakIndex] * 3.0) +
                    ((values[peakIndex] - values[startIndex]) * 2.0) -
                    (abs(duration - AppConfig.motionValleyIdealDuration) * 0.45) -
                    values[startIndex]

                if bestScore == nil || score > bestScore! {
                    bestScore = score
                    bestPair = (startIndex, peakIndex)
                }

                break
            }
        }

        guard let bestPair else {
            return MotionTiming(startTime: nil, topTime: nil)
        }

        return MotionTiming(startTime: times[bestPair.0], topTime: times[bestPair.1])
    }

    private func preferredStart(primary: MotionTiming, fallback: MotionTiming) -> PreferredStart {
        if primary.isValid,
           let duration = primary.duration,
           duration >= AppConfig.motionHybridMinDuration,
           duration <= AppConfig.motionHybridMaxDuration {
            return PreferredStart(startTime: primary.startTime, method: "baseline")
        }

        if let fallbackStart = fallback.startTime {
            return PreferredStart(startTime: fallbackStart, method: "valley_peak")
        }

        return PreferredStart(startTime: primary.startTime, method: "baseline_start_only")
    }

    private func dedupe(indices: [Int], minimumGap: Int) -> [Int] {
        var deduped: [Int] = []
        for index in indices {
            if deduped.isEmpty || index - deduped.last! >= minimumGap {
                deduped.append(index)
            }
        }
        return deduped
    }

    private func analysisTimeRange(for duration: CMTime) -> CMTimeRange? {
        let totalSeconds = duration.seconds
        guard totalSeconds.isFinite, totalSeconds > 0 else { return nil }

        let startSeconds = AppConfig.analysisSkipLeadingSeconds
        let endSeconds = max(totalSeconds - AppConfig.analysisSkipTrailingSeconds, startSeconds)

        guard endSeconds - startSeconds >= 8.0 else {
            return nil
        }

        let start = CMTime(seconds: startSeconds, preferredTimescale: 600)
        let end = CMTime(seconds: endSeconds, preferredTimescale: 600)
        return CMTimeRange(start: start, end: end)
    }

    private func trackingWindow(around preferredStartTime: Double, within analysisWindow: CMTimeRange?, assetDuration: CMTime) -> CMTimeRange? {
        let lowerBound = analysisWindow?.start.seconds ?? 0
        let upperBound = analysisWindow?.end.seconds ?? assetDuration.seconds

        let startSeconds = max(lowerBound, preferredStartTime - AppConfig.fusionTrackWindowBeforeSeconds)
        let endSeconds = min(upperBound, preferredStartTime + AppConfig.fusionTrackWindowAfterSeconds)

        guard endSeconds - startSeconds >= 4.0 else {
            return nil
        }

        return CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            end: CMTime(seconds: endSeconds, preferredTimescale: 600)
        )
    }

    private func isTrackLaneCandidate(_ box: CGRect) -> Bool {
        let centerX = box.midX
        return centerX > AppConfig.fusionTrackMinCenterX && centerX < AppConfig.fusionTrackMaxCenterX
    }

    private func topOfBoxValue(for box: CGRect) -> CGFloat {
        min(max(box.maxY, 0), 1)
    }

    private func clampToUnitRect(_ rect: CGRect) -> CGRect {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        if clipped.isNull || clipped.isEmpty {
            return CGRect(
                x: min(max(rect.origin.x, 0), 1),
                y: min(max(rect.origin.y, 0), 1),
                width: min(max(rect.width, 0.01), 1),
                height: min(max(rect.height, 0.01), 1)
            )
        }

        return clipped
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
