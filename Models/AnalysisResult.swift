import Foundation
import CoreMedia

struct AnalysisResult {
    /// Start time calculated from video timeline
    let startTime: CMTime?
    /// Top reached time calculated from video timeline
    let topTime: CMTime?
    
    /// Trim limits including the paddings
    let trimStart: CMTime?
    let trimEnd: CMTime?
    
    /// Score of the person tracked to give confidence info
    let targetConfidenceScore: CGFloat
    
    /// Telemetry for remote debugging
    let debugLogs: String
    
    /// Path to the trimmed video file
    let exportedURL: URL?
    
    var isValid: Bool {
        return trimStart != nil && trimEnd != nil
    }
}
