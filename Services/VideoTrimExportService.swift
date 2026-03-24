import AVFoundation
import Foundation

final class VideoTrimExportService {
    private let recordingManager = RecordingManager.shared

    func trimVideo(url: URL, start: CMTime, end: CMTime, completion: @escaping (URL?, Error?) -> Void) {
        let asset = AVAsset(url: url)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            completion(nil, NSError(domain: "Export", code: 500, userInfo: [NSLocalizedDescriptionKey: "Impossible de creer la session d'export"]))
            return
        }

        let outputURL: URL
        do {
            outputURL = try recordingManager.makeExportURL(fileExtension: "mp4")
        } catch {
            completion(nil, error)
            return
        }

        Task {
            let duration = try? await asset.load(.duration)
            let actualDuration = duration ?? .zero

            var finalStart = CMTimeMaximum(start, .zero)
            var finalEnd = CMTimeMinimum(end, actualDuration)

            if finalStart >= finalEnd {
                finalStart = .zero
                finalEnd = actualDuration
            }

            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4
            exportSession.timeRange = CMTimeRange(start: finalStart, end: finalEnd)
            exportSession.shouldOptimizeForNetworkUse = false

            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    completion(outputURL, nil)
                case .failed:
                    completion(nil, exportSession.error)
                case .cancelled:
                    completion(nil, NSError(domain: "Export", code: 499, userInfo: [NSLocalizedDescriptionKey: "Export annule"]))
                default:
                    completion(nil, NSError(domain: "Export", code: 520, userInfo: [NSLocalizedDescriptionKey: "Etat d'export inattendu"]))
                }
            }
        }
    }
}
