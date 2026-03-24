import AVFoundation

class VideoTrimExportService {
    func trimVideo(url: URL, start: CMTime, end: CMTime, completion: @escaping (URL?, Error?) -> Void) {
        let asset = AVAsset(url: url)
        
        let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
        guard let exportSession = exportSession else {
            completion(nil, NSError(domain: "Export", code: 500, userInfo: [NSLocalizedDescriptionKey: "Impossible de créer la session d'export"]))
            return
        }
        
        let tempDir = NSTemporaryDirectory()
        let outputURL = URL(fileURLWithPath: tempDir).appendingPathComponent("climb_trimmed_\(UUID().uuidString).mp4")
        
        // Ensure valid range
        let duration = asset.duration
        var finalStart = CMTimeMaximum(start, .zero)
        var finalEnd = CMTimeMinimum(end, duration)
        
        if finalStart >= finalEnd {
            // Fallback to the whole video if the times are inverted or invalid
            finalStart = .zero
            finalEnd = duration
        }
        
        let timeRange = CMTimeRange(start: finalStart, end: finalEnd)
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.timeRange = timeRange
        
        exportSession.exportAsynchronously {
            switch exportSession.status {
            case .completed:
                completion(outputURL, nil)
            case .failed:
                completion(nil, exportSession.error)
            case .cancelled:
                completion(nil, NSError(domain: "Export", code: 499, userInfo: [NSLocalizedDescriptionKey: "Annulé"]))
            default:
                break
            }
        }
    }
}
