import Foundation
import CoreGraphics

struct AppConfig {
    static let analysisFPS: Int = 15
    static let maxVideoDimension: CGFloat = 80.0

    static let laneRegionOfInterest = CGRect(x: 0.24, y: 0.05, width: 0.52, height: 0.90)

    static let startZoneMaxY: CGFloat = 0.38
    static let startVelocityThreshold: CGFloat = 0.005
    static let startConfirmationFrames: Int = 5

    static let topZoneMinY: CGFloat = 0.72
    static let topStabilizationFrames: Int = 3
    static let topStabilizationThreshold: CGFloat = 0.01

    static let maxTrackingMissedFrames: Int = 8
    static let maxHorizontalTrackDrift: CGFloat = 0.14
    static let maxDownwardTrackJump: CGFloat = 0.12
    static let maxUpwardTrackJump: CGFloat = 0.55
    static let trackerRedetectionInterval: Int = 8
    static let trackingConfidenceThreshold: Float = 0.28
    static let upperBodyAnchorRatio: CGFloat = 0.78

    static let poseRefinementWindowSeconds: Double = 1.5
    static let poseRefinementFPS: Int = 24
    static let poseConfidenceThreshold: Float = 0.15
    static let poseHorizontalPaddingRatio: CGFloat = 0.28
    static let poseVerticalPaddingRatio: CGFloat = 0.18

    static let preStartTrimMarginSeconds: Double = 1.0
    static let postTopTrimMarginSeconds: Double = 1.0
}
