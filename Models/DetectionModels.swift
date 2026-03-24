import Foundation
import CoreMedia

struct PersonTrack {
    let id: UUID
    var points: [TrackPoint]
    
    var startScore: CGFloat {
        // Did it start near the bottom?
        guard let firstY = points.first?.y else { return 0 }
        return firstY < AppConfig.startZoneMaxY ? 1.0 : 0.1
    }
    
    var verticalDistance: CGFloat {
        guard !points.isEmpty else { return 0 }
        let maxY = points.map { $0.y }.max() ?? 0
        let minY = points.map { $0.y }.min() ?? 0
        return maxY - minY
    }
    
    var totalScore: CGFloat {
        // High score for tracks that move vertically a lot and start at the bottom.
        return verticalDistance * startScore
    }
}

struct TrackPoint {
    let time: CMTime
    let y: CGFloat       // Normalized Y position (0 = bottom, 1 = top)
    let bbox: CGRect     // Bounding box if visual debug is needed
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
