import Foundation
import CoreMedia
import Vision

class VideoAnalysisService: ObservableObject {
    @Published var isAnalyzing = false
    @Published var currentStatus = ""
    @Published var lastResult: AnalysisResult?
    
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
        let asset = AVAsset(url: url)
        
        // Simplified Video Processing logic for MVP
        // In real world: we use AVAssetReader to get frames at 15 FPS
        // Then we run VNDetectHumanRectanglesRequest on each frame
        // Here we simulate the logic flow
        
        DispatchQueue.main.async { self.currentStatus = "Extraction des frames..." }
        
        // NOTE: In a complete implementation, an AVAssetReader loop goes here.
        // It outputs CVPixelBuffer and we run Vision requests.
        // For brevity and clear architecture, we assume trackingService.processFrame was called in a loop.
        
        // ----
        // Simulated tracking process...
        // let request = VNDetectHumanRectanglesRequest { ... trackingService.processFrame(...) }
        // ----
        
        // MOCK DATA for compilation and structure demo
        // Assume climber went from y=0.1 to y=0.9
        let dummyTrack = PersonTrack(id: UUID(), points: [
            TrackPoint(time: CMTime(seconds: 0.1, preferredTimescale: 600), y: 0.1, bbox: .zero),
            TrackPoint(time: CMTime(seconds: 1.0, preferredTimescale: 600), y: 0.1, bbox: .zero),
            // Starts climbing
            TrackPoint(time: CMTime(seconds: 1.5, preferredTimescale: 600), y: 0.15, bbox: .zero),
            TrackPoint(time: CMTime(seconds: 2.0, preferredTimescale: 600), y: 0.3, bbox: .zero),
            TrackPoint(time: CMTime(seconds: 3.0, preferredTimescale: 600), y: 0.5, bbox: .zero),
            TrackPoint(time: CMTime(seconds: 4.0, preferredTimescale: 600), y: 0.75, bbox: .zero),
            // Top reached
            TrackPoint(time: CMTime(seconds: 5.0, preferredTimescale: 600), y: 0.85, bbox: .zero),
            TrackPoint(time: CMTime(seconds: 6.0, preferredTimescale: 600), y: 0.85, bbox: .zero)
        ])
        
        DispatchQueue.main.async { self.currentStatus = "Recherche du grimpeur cible..." }
        
        // Find best track
        guard let targetTrack = /* trackingService.getTargetTrack() */ dummyTrack as PersonTrack? else {
            DispatchQueue.main.async { self.isAnalyzing = false }
            return
        }
        
        DispatchQueue.main.async { self.currentStatus = "Détection Start et Top..." }
        let result = eventDetector.analyzeTrack(targetTrack)
        
        guard result.isValid, let start = result.trimStart, let end = result.trimEnd else {
            DispatchQueue.main.async { 
                self.lastResult = result
                self.isAnalyzing = false 
            }
            return
        }
        
        DispatchQueue.main.async { self.currentStatus = "Découpage de la vidéo (Trim)..." }
        
        let outputTempURL = trimExportService.trimVideo(url: url, start: start, end: end) { exportedURL, error in
            if let exportedURL = exportedURL {
                DispatchQueue.main.async { self.currentStatus = "Sauvegarde dans Photos..." }
                self.photoLibraryService.saveVideoToLibrary(url: exportedURL) { success, error in
                    DispatchQueue.main.async {
                        // Clean up
                        try? FileManager.default.removeItem(at: exportedURL)
                        self.lastResult = result
                        self.isAnalyzing = false
                    }
                }
            } else {
                DispatchQueue.main.async { self.isAnalyzing = false }
            }
        }
    }
    
    func reset() {
        lastResult = nil
        currentStatus = ""
    }
}
