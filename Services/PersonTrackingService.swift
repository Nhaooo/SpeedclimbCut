import Foundation
import CoreMedia
import Vision

class PersonTrackingService {
    // Stores ongoing tracks
    private var tracks: [UUID: PersonTrack] = [:]
    
    func processFrame(cmTime: CMTime, boundingBoxes: [CGRect], debug: Bool = false) {
        // Simple tracker: associate new boxes with existing tracks using Distance or IoU
        var unassignedBoxes = boundingBoxes
        
        for (id, track) in tracks {
            guard let lastPoint = track.points.last else { continue }
            
            // Find closest box
            if let closestIndex = unassignedBoxes.firstIndex(where: { 
                distance(rect1: $0, rect2: lastPoint.bbox) < 0.2 // Max allowed movement per frame
            }) {
                let matchedBox = unassignedBoxes.remove(at: closestIndex)
                let newPoint = TrackPoint(time: cmTime, y: 1.0 - matchedBox.midY, bbox: matchedBox) // Vision 0 is bottom
                tracks[id]?.points.append(newPoint)
            }
        }
        
        // Create new tracks for remaining boxes
        for box in unassignedBoxes {
            let id = UUID()
            let newPoint = TrackPoint(time: cmTime, y: 1.0 - box.midY, bbox: box)
            tracks[id] = PersonTrack(id: id, points: [newPoint])
        }
    }
    
    private func distance(rect1: CGRect, rect2: CGRect) -> CGFloat {
        let dx = rect1.midX - rect2.midX
        let dy = rect1.midY - rect2.midY
        return sqrt(dx*dx + dy*dy)
    }
    
    func getTargetTrack() -> PersonTrack? {
        // Score: Vertical distance traveled * Start bonus
        // The real climber is the one that moves from bottom to top the most.
        return tracks.values.max(by: { $0.totalScore < $1.totalScore })
    }
    
    func reset() {
        tracks.removeAll()
    }
}
