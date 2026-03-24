import Foundation
import CoreMedia
import Vision
import AVFoundation

class VideoAnalysisService: ObservableObject {
    @Published var isAnalyzing = false
    @Published var currentStatus = ""
    @Published var lastResult: AnalysisResult?
    
    private var logs = ""
    
    private let trackingService = PersonTrackingService()
    private let eventDetector = ClimbEventDetector()
    private let trimExportService = VideoTrimExportService()
    private let photoLibraryService = PhotoLibraryService()
    
    func startAnalysis(videoURL: URL) {
        isAnalyzing = true
        currentStatus = "Initialisation pipeline Vision..."
        trackingService.reset()
        
        DispatchQueue.global(qos: .userInitiated).async {
            self.processVideo(url: videoURL)
        }
    }
    
    private func processVideo(url: URL) {
        var logs = "--- START TELEMETRY ---\n"
        self.logs = logs
        let asset = AVAsset(url: url)
        
        guard let reader = try? AVAssetReader(asset: asset),
              let videoTrack = asset.tracks(withMediaType: .video).first else {
            self.logs += "ERROR: Could not create AVAssetReader or find video track.\n"
            finishWithError(logs: self.logs)
            return
        }
        
        self.logs += "Asset loaded.\n"
        
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        reader.add(trackOutput)
        reader.startReading()
        
        var framesProcessed = 0
        let targetFPS: Double = 10.0
        let frameInterval = CMTime(seconds: 1.0 / targetFPS, preferredTimescale: 600)
        var nextTargetTime = CMTime.zero
        
        self.logs += "Starting Vision Request loop at 10 FPS...\n"
        let request = VNDetectHumanRectanglesRequest()
        
        DispatchQueue.main.async { self.currentStatus = "Analyse Visuelle..." }
        
        var videoOrientation: CGImagePropertyOrientation = .up
        if let videoTrack = asset.tracks(withMediaType: .video).first {
            videoOrientation = self.getVideoOrientation(from: videoTrack.preferredTransform)
            self.logs += "Video orientation detected: \(videoOrientation.rawValue)\n"
        }
        
        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            if pts >= nextTargetTime {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: videoOrientation, options: [:])
                do {
                    try handler.perform([request])
                    if let results = request.results {
                        let boxes = results.map { self.transformRect($0.boundingBox, orientation: videoOrientation) }
                        trackingService.processFrame(cmTime: pts, boundingBoxes: boxes)
                        if framesProcessed % 30 == 0 {
                            self.logs += "Frame \(framesProcessed) @ \(String(format: "%.2f", pts.seconds))s: \(boxes.count) humain(s).\n"
                        }
                    }
                } catch {
                    self.logs += "Vision Error on frame \(framesProcessed): \(error.localizedDescription)\n"
                }

                nextTargetTime = CMTimeAdd(nextTargetTime, frameInterval)
                framesProcessed += 1
                
                if framesProcessed % 20 == 0 {
                    DispatchQueue.main.async { self.currentStatus = "Analyse frame \(framesProcessed)..." }
                }
            }
        }
        
        self.logs += "Extraction complete. \(framesProcessed) frames traitées.\n"
        
        guard let targetTrack = trackingService.getTargetTrack() else {
            self.logs += "CRITICAL ERROR: trackingService.getTargetTrack() returned nil. Personne n'a bougé verticalement !\n"
            finishWithError(logs: self.logs)
            return
        }
        
        self.logs += "🎯 Target Track sélectionné : UUID \(targetTrack.id.uuidString.prefix(4)), Score vertical: \(String(format: "%.2f", targetTrack.totalScore))\n"
        let result = eventDetector.analyzeTrack(targetTrack)
        
        if result.isValid, let start = result.trimStart, let end = result.trimEnd {
            self.logs += "✅ SUCCESS! Trim constraints -> Start: \(String(format: "%.2f", start.seconds))s, End: \(String(format: "%.2f", end.seconds))s\n"
            
            DispatchQueue.main.async { self.currentStatus = "Découpage (Trim)..." }
            trimExportService.trimVideo(url: url, start: start, end: end) { [weak self] exportedURL, error in
                guard let self = self else { return }
                
                if let exportedURL = exportedURL {
                    DispatchQueue.main.async {
                        // On ignore la sauvegarde auto dans la galerie pour l'instant
                        self.logs += "✅ Vidéo sauvegardée dans les fichiers temporaires : \(exportedURL.lastPathComponent)\n"
                        self.lastResult = AnalysisResult(startTime: result.startTime, topTime: result.topTime, trimStart: result.trimStart, trimEnd: result.trimEnd, targetConfidenceScore: result.targetConfidenceScore, debugLogs: self.logs)
                        self.isAnalyzing = false
                    }
                } else {
                    self.logs += "ERROR: trimVideo exportedURL est nil.\n"
                    if let err = error {
                        self.logs += "Export Error: \(err.localizedDescription)\n"
                    }
                    self.finishWithError(logs: self.logs)
                }
            }
        } else {
            self.logs += "CRITICAL ERROR: EventDetector n'a pas validé le Start ou le Top.\n"
            self.logs += "Event Details - start: \(result.startTime?.seconds ?? -1), top: \(result.topTime?.seconds ?? -1)\n"
            finishWithError(logs: self.logs)
        }
    }
    
    private func finishWithError(logs: String) {
        DispatchQueue.main.async {
            self.lastResult = AnalysisResult(startTime: nil, topTime: nil, trimStart: nil, trimEnd: nil, targetConfidenceScore: 0, debugLogs: logs)
            self.isAnalyzing = false
        }
    }
    
    private func getVideoOrientation(from transform: CGAffineTransform) -> CGImagePropertyOrientation {
        if transform.a == 0 && transform.b == 1.0 && transform.c == -1.0 && transform.d == 0 {
            return .right // Portrait
        }
        if transform.a == 0 && transform.b == -1.0 && transform.c == 1.0 && transform.d == 0 {
            return .left // Portrait Upside Down
        }
        if transform.a == 1.0 && transform.b == 0 && transform.c == 0 && transform.d == 1.0 {
            return .up // Landscape Right
        }
        if transform.a == -1.0 && transform.b == 0 && transform.c == 0 && transform.d == -1.0 {
            return .down // Landscape Left
        }
        return .up
    }
    
    private func transformRect(_ rect: CGRect, orientation: CGImagePropertyOrientation) -> CGRect {
        switch orientation {
        case .up:
            return rect
        case .down:
            return CGRect(x: 1 - rect.maxX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        case .left: // Portrait Upside Down (90 deg CCW)
            return CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        case .right: // Portrait (90 deg CW)
            return CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        default:
            return rect
        }
    }
    
    func reset() {
        lastResult = nil
        currentStatus = ""
    }
}
