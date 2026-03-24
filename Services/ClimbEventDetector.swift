import Foundation
import CoreMedia

class ClimbEventDetector {

    func analyzeTrack(_ track: PersonTrack) -> AnalysisResult {
        var state: ClimbState = .armedForStart

        var tStart: CMTime? = nil
        var tTop: CMTime? = nil

        var consecutiveUpFrames = 0
        var consecutiveStableTopFrames = 0

        guard let firstPoint = track.points.first else {
            return AnalysisResult(startTime: nil, topTime: nil, trimStart: nil, trimEnd: nil, targetConfidenceScore: 0, debugLogs: "", exportedURL: nil, savedToLibrary: false)
        }

        var lastY = firstPoint.y
        var highestPoint = firstPoint

        for (index, point) in track.points.enumerated() {
            let dy = point.y - lastY
            let isMovingUp = dy > AppConfig.startVelocityThreshold

            if point.y > highestPoint.y {
                highestPoint = point
            }

            switch state {
            case .armedForStart:
                if point.y < AppConfig.startZoneMaxY && isMovingUp {
                    consecutiveUpFrames += 1
                    if consecutiveUpFrames >= AppConfig.startConfirmationFrames {
                        state = .climbing
                        let startIndex = max(index - (AppConfig.startConfirmationFrames - 1), 0)
                        tStart = track.points[startIndex].time
                    }
                } else if dy <= 0 {
                    consecutiveUpFrames = 0
                }

            case .climbing:
                if point.y > AppConfig.topZoneMinY {
                    state = .nearTop
                }

            case .nearTop:
                if abs(dy) < AppConfig.topStabilizationThreshold || dy < 0 {
                    consecutiveStableTopFrames += 1
                    if consecutiveStableTopFrames >= AppConfig.topStabilizationFrames {
                        state = .topConfirmed
                        tTop = point.time
                    }
                } else {
                    consecutiveStableTopFrames = 0
                }

            case .topConfirmed:
                break
            default:
                break
            }

            lastY = point.y
            if state == .topConfirmed { break }
        }

        if tStart == nil, highestPoint.y > AppConfig.topZoneMinY, let firstClimbingPoint = track.points.first(where: { $0.y < AppConfig.startZoneMaxY }) {
            tStart = firstClimbingPoint.time
        }

        if tTop == nil, highestPoint.y > AppConfig.topZoneMinY {
            tTop = highestPoint.time
        }

        var trimStart: CMTime?
        var trimEnd: CMTime?

        if let st = tStart, let tt = tTop {
            trimStart = CMTimeSubtract(st, CMTime(seconds: AppConfig.preStartTrimMarginSeconds, preferredTimescale: 600))
            trimEnd = CMTimeAdd(tt, CMTime(seconds: AppConfig.postTopTrimMarginSeconds, preferredTimescale: 600))
        }

        return AnalysisResult(
            startTime: tStart,
            topTime: tTop,
            trimStart: trimStart,
            trimEnd: trimEnd,
            targetConfidenceScore: track.totalScore,
            debugLogs: "",
            exportedURL: nil,
            savedToLibrary: false
        )
    }
}
