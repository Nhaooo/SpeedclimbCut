import Foundation
import CoreMedia

struct PersonTrack {
    let id: UUID
    var points: [TrackPoint]
    var missedFrames: Int = 0

    var startScore: CGFloat {
        guard let firstY = points.first?.y else { return 0 }
        return firstY < AppConfig.startZoneMaxY ? 1.0 : 0.25
    }

    var verticalDistance: CGFloat {
        guard !points.isEmpty else { return 0 }
        let maxY = points.map(\.y).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        return maxY - minY
    }

    var peakHeight: CGFloat {
        points.map(\.y).max() ?? 0
    }

    var lastHeight: CGFloat {
        points.last?.y ?? 0
    }

    var durationScore: CGFloat {
        min(CGFloat(points.count) / 30.0, 1.5)
    }

    var totalScore: CGFloat {
        let finishBonus: CGFloat = lastHeight > AppConfig.topZoneMinY ? 0.6 : 0.0
        let continuityBonus = points.count >= 20 ? 0.4 : 0.0
        let rawScore = (verticalDistance * 2.0) + (peakHeight * 0.8) + durationScore + finishBonus + continuityBonus
        return rawScore * startScore
    }
}

struct TrackPoint {
    let time: CMTime
    let y: CGFloat
    let bbox: CGRect
}

enum ClimbState: String {
    case idle
    case searchingTarget
    case targetLocked
    case armedForStart
    case climbing
    case nearTop
    case topConfirmed
    case done
    case failed
}
