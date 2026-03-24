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
            return AnalysisResult(startTime: nil, topTime: nil, trimStart: nil, trimEnd: nil, targetConfidenceScore: 0, debugLogs: "")
        }
        
        var lastY = firstPoint.y
        
        for point in track.points {
            let dy = point.y - lastY
            let isMovingUp = dy > AppConfig.startVelocityThreshold
            
            switch state {
            case .armedForStart:
                if point.y < AppConfig.startZoneMaxY && isMovingUp {
                    consecutiveUpFrames += 1
                    if consecutiveUpFrames >= AppConfig.startConfirmationFrames {
                        state = .climbing
                        // Start was actually N frames ago
                        // For MVP, we just take the current time minus padding later
                        tStart = point.time
                    }
                } else if dy <= 0 {
                    consecutiveUpFrames = 0
                }
                
            case .climbing:
                if point.y > AppConfig.topZoneMinY {
                    state = .nearTop
                }
                
            case .nearTop:
                if abs(dy) < 0.005 || dy < 0 {
                    // Stagnating or falling = reached the buzzer
                    consecutiveStableTopFrames += 1
                    if consecutiveStableTopFrames >= AppConfig.topStabilizationFrames {
                        state = .topConfirmed
                        tTop = point.time
                    }
                } else {
                    consecutiveStableTopFrames = 0
                }
                
            case .topConfirmed:
                // We're done analyzing
                break
            default:
                break
            }
            
            lastY = point.y
            if state == .topConfirmed { break }
        }
        
        // Calculate Trim Times
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
            debugLogs: ""
        )
    }
}
