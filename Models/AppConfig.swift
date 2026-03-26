import Foundation
import CoreGraphics

struct AppConfig {
    static let analysisFPS: Int = 10
    static let maxVideoDimension: CGFloat = 80.0

    static let motionAnalysisFPS: Double = 8.0
    static let motionMinAnalysisFPS: Double = 5.0
    static let motionTargetMaxSamples: Double = 1200.0
    static let motionGridWidth: Int = 10
    static let motionGridHeight: Int = 20
    static let motionThreshold: Int = 20
    static let motionLaneStartColumn: Int = 3
    static let motionLaneEndColumn: Int = 7

    static let motionBaselineSmoothWindow: Int = 8
    static let motionBaselineStartMin: Double = 0.05
    static let motionBaselineStartMax: Double = 0.30
    static let motionBaselineStartVelocity: Double = 0.005
    static let motionBaselineStartFrames: Int = 5
    static let motionBaselineTopMin: Double = 0.60
    static let motionBaselineTopVelocityThreshold: Double = 0.01
    static let motionBaselineTopStableFrames: Int = 3

    static let motionHybridMinDuration: Double = 5.0
    static let motionHybridMaxDuration: Double = 15.0

    static let motionValleySmoothWindow: Int = 8
    static let motionValleyPreWindow: Int = 4
    static let motionValleyStartMax: Double = 0.08
    static let motionValleyCalmMax: Double = 0.08
    static let motionValleyRiseMin: Double = 0.16
    static let motionValleyLookahead: Int = 10
    static let motionValleyStartGap: Int = 8
    static let motionValleyTopMin: Double = 0.50
    static let motionValleyFallMin: Double = 0.08
    static let motionValleyFallWindow: Int = 6
    static let motionValleyMinDuration: Double = 6.0
    static let motionValleyMaxDuration: Double = 11.0
    static let motionValleyIdealDuration: Double = 9.0

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
