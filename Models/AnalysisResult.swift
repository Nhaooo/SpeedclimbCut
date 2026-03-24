import Foundation
import CoreMedia

struct AnalysisResult {
    let startTime: CMTime?
    let topTime: CMTime?

    let trimStart: CMTime?
    let trimEnd: CMTime?

    let targetConfidenceScore: CGFloat

    let debugLogs: String
    let exportedURL: URL?
    let savedToLibrary: Bool

    var isValid: Bool {
        trimStart != nil && trimEnd != nil
    }
}
