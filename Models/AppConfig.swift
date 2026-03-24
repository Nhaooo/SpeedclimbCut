import Foundation
import CoreGraphics

struct AppConfig {
    static let analysisFPS: Int = 15
    static let maxVideoDimension: CGFloat = 80.0

    static let startZoneMaxY: CGFloat = 0.30
    static let startVelocityThreshold: CGFloat = 0.005
    static let startConfirmationFrames: Int = 5

    static let topZoneMinY: CGFloat = 0.60
    static let topStabilizationFrames: Int = 3
    static let topStabilizationThreshold: CGFloat = 0.01

    static let maxTrackingMissedFrames: Int = 8
    static let maxHorizontalTrackDrift: CGFloat = 0.14
    static let maxDownwardTrackJump: CGFloat = 0.12
    static let maxUpwardTrackJump: CGFloat = 0.55

    static let preStartTrimMarginSeconds: Double = 1.0
    static let postTopTrimMarginSeconds: Double = 1.0
}
