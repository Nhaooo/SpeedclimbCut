import Foundation
import CoreMedia
import Vision

class PersonTrackingService {
    private var tracks: [UUID: PersonTrack] = [:]
    private var completedTracks: [PersonTrack] = []

    func processFrame(cmTime: CMTime, boundingBoxes: [CGRect], debug: Bool = false) {
        var unassignedBoxes = boundingBoxes

        let sortedTrackIDs = tracks.values
            .sorted { lhs, rhs in
                if lhs.points.count == rhs.points.count {
                    return lhs.totalScore > rhs.totalScore
                }
                return lhs.points.count > rhs.points.count
            }
            .map(\.id)

        for id in sortedTrackIDs {
            guard let track = tracks[id] else { continue }
            guard !track.points.isEmpty else { continue }

            if let closestIndex = bestMatchIndex(for: track, in: unassignedBoxes) {
                let matchedBox = unassignedBoxes.remove(at: closestIndex)
                let newPoint = TrackPoint(time: cmTime, y: matchedBox.midY, bbox: matchedBox)
                tracks[id]?.points.append(newPoint)
                tracks[id]?.missedFrames = 0
            } else {
                tracks[id]?.missedFrames += 1
            }
        }

        tracks = tracks.filter { _, track in
            let isStillActive = track.missedFrames <= AppConfig.maxTrackingMissedFrames
            if !isStillActive, track.points.count >= AppConfig.startConfirmationFrames {
                completedTracks.append(track)
            }
            return isStillActive
        }

        for box in unassignedBoxes {
            let id = UUID()
            let newPoint = TrackPoint(time: cmTime, y: box.midY, bbox: box)
            tracks[id] = PersonTrack(id: id, points: [newPoint])
        }
    }

    private func bestMatchIndex(for track: PersonTrack, in boxes: [CGRect]) -> Int? {
        guard let lastPoint = track.points.last else { return nil }

        let scoredMatches: [(index: Int, score: CGFloat)] = boxes.enumerated().compactMap { (entry: (offset: Int, element: CGRect)) in
                let index = entry.offset
                let box = entry.element
                guard let score = associationScore(last: lastPoint.bbox, current: box, missedFrames: track.missedFrames) else {
                    return nil
                }
                return (index: index, score: score)
            }

        return scoredMatches.max(by: { $0.score < $1.score })?.index
    }

    private func associationScore(last: CGRect, current: CGRect, missedFrames: Int) -> CGFloat? {
        let dx = abs(current.midX - last.midX)
        let dy = current.midY - last.midY
        let verticalTolerance = AppConfig.maxUpwardTrackJump + (CGFloat(missedFrames) * 0.04)

        guard dx <= AppConfig.maxHorizontalTrackDrift else { return nil }
        guard dy >= -AppConfig.maxDownwardTrackJump else { return nil }
        guard dy <= verticalTolerance else { return nil }

        let widthDelta = abs(current.width - last.width)
        let heightDelta = abs(current.height - last.height)

        let laneScore = 1.0 - min(dx / AppConfig.maxHorizontalTrackDrift, 1.0)
        let verticalScore = 1.0 - min(max(dy, 0) / max(verticalTolerance, 0.001), 1.0)
        let sizePenalty = min(widthDelta + heightDelta, 0.4)

        return (laneScore * 1.5) + verticalScore - sizePenalty
    }

    func getTargetTrack() -> PersonTrack? {
        let candidates = Array(tracks.values) + completedTracks
        return candidates.max(by: { $0.totalScore < $1.totalScore })
    }

    func reset() {
        tracks.removeAll()
        completedTracks.removeAll()
    }
}
