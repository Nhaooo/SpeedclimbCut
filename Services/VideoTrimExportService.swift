import AVFoundation
import Foundation

final class VideoTrimExportService {
    private let recordingManager = RecordingManager.shared

    func trimVideo(url: URL, start: CMTime, end: CMTime, completion: @escaping (URL?, Error?) -> Void) {
        let asset = AVAsset(url: url)

        Task {
            let duration = try? await asset.load(.duration)
            let actualDuration = duration ?? .zero

            var finalStart = CMTimeMaximum(start, .zero)
            var finalEnd = CMTimeMinimum(end, actualDuration)

            if finalStart >= finalEnd {
                finalStart = .zero
                finalEnd = actualDuration
            }

            let preferredPreset = AVAssetExportPresetPassthrough
            let fallbackPreset = AVAssetExportPresetMediumQuality

            guard let exportSession = AVAssetExportSession(asset: asset, presetName: preferredPreset)
                ?? AVAssetExportSession(asset: asset, presetName: fallbackPreset) else {
                completion(nil, NSError(domain: "Export", code: 500, userInfo: [NSLocalizedDescriptionKey: "Impossible de creer la session d'export"]))
                return
            }

            let outputFileType = supportedFileType(for: exportSession)
            let outputExtension = fileExtension(for: outputFileType)

            let outputURL: URL
            do {
                outputURL = try recordingManager.makeExportURL(fileExtension: outputExtension)
            } catch {
                completion(nil, error)
                return
            }

            exportSession.outputURL = outputURL
            exportSession.outputFileType = outputFileType
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

    private func supportedFileType(for exportSession: AVAssetExportSession) -> AVFileType {
        let supportedTypes = exportSession.supportedFileTypes

        if supportedTypes.contains(.mov) {
            return .mov
        }

        if supportedTypes.contains(.mp4) {
            return .mp4
        }

        return supportedTypes.first ?? .mov
    }

    private func fileExtension(for fileType: AVFileType) -> String {
        switch fileType {
        case .mp4:
            return "mp4"
        case .mov:
            return "mov"
        case .m4v:
            return "m4v"
        default:
            return "mov"
        }
    }
}
