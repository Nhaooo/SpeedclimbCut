import AVFoundation
import CoreImage
import CoreGraphics
import Foundation
import ImageIO

final class MotionHybridAnalysisService {
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

    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func analyze(asset: AVAsset, videoTrack: AVAssetTrack, orientation: CGImagePropertyOrientation) async throws -> Analysis {
        let assetDuration = (try? await asset.load(.duration)) ?? videoTrack.timeRange.duration
        let analysisTimeRange = analysisTimeRange(for: assetDuration)
        let analysisDuration = analysisTimeRange?.duration.seconds ?? assetDuration.seconds
        let targetFPS = recommendedAnalysisFPS(for: analysisDuration)
        let curve = try extractMotionCurve(
            asset: asset,
            videoTrack: videoTrack,
            orientation: orientation,
            targetFPS: targetFPS,
            analysisTimeRange: analysisTimeRange
        )

        guard !curve.times.isEmpty else {
            return Analysis(
                startTime: nil,
                topTime: nil,
                confidenceScore: 0,
                method: "none",
                debugLogs: "Motion analysis: aucune courbe exploitable.\n"
            )
        }

        let baselineValues = smooth(curve.values, window: AppConfig.motionBaselineSmoothWindow)
        let baseline = motionStateMachine(times: curve.times, values: baselineValues)

        let valleyValues = smooth(curve.values, window: AppConfig.motionValleySmoothWindow)
        let valleyPeak = motionValleyPeak(times: curve.times, values: valleyValues)

        let selected = chooseHybridResult(primary: baseline, fallback: valleyPeak)
        let peakMotion = CGFloat(curve.values.max() ?? 0)
        let peakIndex = curve.values.enumerated().max(by: { $0.element < $1.element })?.offset
        let peakTime = peakIndex.flatMap { index in
            guard curve.times.indices.contains(index) else { return nil }
            return curve.times[index]
        } ?? -1
        let effectiveFPS = estimatedFPS(from: curve.times)
        let analyzedSpan = max((curve.times.last ?? 0) - (curve.times.first ?? 0), 0)
        let nonZeroSamples = curve.values.filter { $0 > 0.0 }.count
        let minMotion = curve.values.min() ?? 0

        let logs = """
        Motion analysis: \(curve.values.count) samples, target \(String(format: "%.2f", targetFPS)) FPS, effective \(String(format: "%.2f", effectiveFPS)) FPS over \(String(format: "%.2f", analyzedSpan))s.
        Motion window -> \(String(format: "%.2f", analysisTimeRange?.start.seconds ?? 0))s to \(String(format: "%.2f", analysisTimeRange?.end.seconds ?? assetDuration.seconds))s
        Motion curve -> min: \(String(format: "%.3f", minMotion)), max: \(String(format: "%.3f", Double(peakMotion))), non-zero: \(nonZeroSamples), peak time: \(String(format: "%.2f", peakTime))
        Motion baseline -> start: \(baseline.startTime ?? -1), top: \(baseline.topTime ?? -1)
        Motion valley_peak -> start: \(valleyPeak.startTime ?? -1), top: \(valleyPeak.topTime ?? -1)
        Motion selected -> method: \(selected.method), start: \(selected.timing.startTime ?? -1), top: \(selected.timing.topTime ?? -1), peak: \(String(format: "%.3f", peakMotion))
        """

        return Analysis(
            startTime: selected.timing.startTime.map { CMTime(seconds: $0, preferredTimescale: 600) },
            topTime: selected.timing.topTime.map { CMTime(seconds: $0, preferredTimescale: 600) },
            confidenceScore: peakMotion,
            method: selected.method,
            debugLogs: logs + "\n"
        )
    }

    private func extractMotionCurve(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        orientation: CGImagePropertyOrientation,
        targetFPS: Double,
        analysisTimeRange: CMTimeRange?
    ) throws -> MotionCurve {
        let reader = try AVAssetReader(asset: asset)
        if let analysisTimeRange {
            reader.timeRange = analysisTimeRange
        }
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            throw NSError(
                domain: "MotionHybridAnalysisService",
                code: 100,
                userInfo: [NSLocalizedDescriptionKey: "Impossible d'ajouter la sortie video pour l'analyse motion."]
            )
        }

        reader.add(trackOutput)

        guard reader.startReading() else {
            throw NSError(
                domain: "MotionHybridAnalysisService",
                code: 101,
                userInfo: [NSLocalizedDescriptionKey: reader.error?.localizedDescription ?? "Impossible de demarrer AVAssetReader."]
            )
        }

        let frameInterval = CMTime(seconds: 1.0 / targetFPS, preferredTimescale: 600)
        var nextTargetTime = analysisTimeRange?.start ?? .zero
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
                domain: "MotionHybridAnalysisService",
                code: 102,
                userInfo: [NSLocalizedDescriptionKey: reader.error?.localizedDescription ?? "Echec de lecture motion."]
            )
        }

        return MotionCurve(times: times, values: values)
    }

    private func renderGrid(from pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> [UInt8]? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(forExifOrientation: Int32(orientation.rawValue))

        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }

        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scaleTransform = CGAffineTransform(
            scaleX: CGFloat(AppConfig.motionGridWidth) / extent.width,
            y: CGFloat(AppConfig.motionGridHeight) / extent.height
        )

        let scaled = normalized
            .transformed(by: scaleTransform)
            .cropped(to: CGRect(x: 0, y: 0, width: AppConfig.motionGridWidth, height: AppConfig.motionGridHeight))

        guard let cgImage = ciContext.createCGImage(
            scaled,
            from: CGRect(x: 0, y: 0, width: AppConfig.motionGridWidth, height: AppConfig.motionGridHeight)
        ) else {
            return nil
        }

        guard let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return nil
        }

        let width = AppConfig.motionGridWidth
        let height = AppConfig.motionGridHeight
        let bytesPerRow = cgImage.bytesPerRow
        var grayscale = [UInt8](repeating: 0, count: width * height)

        for row in 0..<height {
            // CI/CG image buffers can come back vertically flipped relative to the
            // motion benchmark. Normalize here so row 0 is always the visual top.
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
        let width = AppConfig.motionGridWidth
        let height = AppConfig.motionGridHeight
        let startColumn = AppConfig.motionLaneStartColumn
        let endColumn = min(AppConfig.motionLaneEndColumn, width)

        for row in 0..<height {
            var activeCells = 0
            for column in startColumn..<endColumn {
                let index = (row * width) + column
                let delta = abs(Int(current[index]) - Int(previous[index]))
                if delta >= AppConfig.motionThreshold {
                    activeCells += 1
                }
            }

            if activeCells >= AppConfig.motionMinActiveCellsPerRow {
                return 1.0 - (Double(row) / Double(height))
            }
        }

        return 0.0
    }

    private func smooth(_ values: [Double], window: Int) -> [Double] {
        guard window > 1 else { return values }

        var smoothed: [Double] = []
        smoothed.reserveCapacity(values.count)

        for index in values.indices {
            let startIndex = max(0, index - window)
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

        return MotionTiming(
            startTime: times[bestPair.0],
            topTime: times[bestPair.1]
        )
    }

    private func chooseHybridResult(primary: MotionTiming, fallback: MotionTiming) -> (method: String, timing: MotionTiming) {
        if primary.isValid,
           let duration = primary.duration,
           duration >= AppConfig.motionHybridMinDuration,
           duration <= AppConfig.motionHybridMaxDuration {
            return ("baseline", primary)
        }

        return ("valley_peak", fallback)
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

    private func estimatedFPS(from times: [Double]) -> Double {
        guard times.count > 1 else { return 0 }

        let span = times[times.count - 1] - times[0]
        guard span > 0 else { return 0 }

        return Double(times.count - 1) / span
    }

    private func recommendedAnalysisFPS(for duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else {
            return AppConfig.motionAnalysisFPS
        }

        let cappedFPS = AppConfig.motionTargetMaxSamples / duration
        return min(AppConfig.motionAnalysisFPS, max(AppConfig.motionMinAnalysisFPS, cappedFPS))
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
}
