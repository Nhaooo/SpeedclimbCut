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
            
            // Find closest box using lane-tracking logic
            if let closestIndex = unassignedBoxes.firstIndex(where: { 
                isSamePerson(last: lastPoint.bbox, current: $0)
            }) {
                let matchedBox = unassignedBoxes.remove(at: closestIndex)
                let newPoint = TrackPoint(time: cmTime, y: matchedBox.midY, bbox: matchedBox) // Vision: 0 is bottom, 1 is top
                tracks[id]?.points.append(newPoint)
            }
        }
        
        // Create new tracks for remaining boxes
        for box in unassignedBoxes {
            let id = UUID()
            let newPoint = TrackPoint(time: cmTime, y: box.midY, bbox: box)
            tracks[id] = PersonTrack(id: id, points: [newPoint])
        }
    }
    
    private func isSamePerson(last: CGRect, current: CGRect) -> Bool {
        // Speed climbing is vertical. X rarely changes. Y moves upward.
        let dx = abs(current.midX - last.midX)
        let dy = current.midY - last.midY // Positive = moving UP toward buzzer
        
        // As long as they stay in the same horizontal lane (dx < 0.2)
        // And they don't teleport insanely far down due to bugs (dy > -0.15)
        // And we allow climbing very fast even with detection gaps (dy up to 0.70)
        return dx < 0.2 && dy > -0.15 && dy < 0.70
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
