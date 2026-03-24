import AVFoundation
import Foundation
import Vision

final class VideoAnalysisService: ObservableObject {
    @Published var isAnalyzing = false
    @Published var currentStatus = ""
    @Published var lastResult: AnalysisResult?

    private let trackingService = PersonTrackingService()
    private let eventDetector = ClimbEventDetector()
    private let trimExportService = VideoTrimExportService()
    private let photoLibraryService = PhotoLibraryService()
    private let recordingManager = RecordingManager.shared

    private var pendingCleanupURLs: [URL] = []

    func prepareImportedVideoLoad() {
        cleanupPendingFiles()

        DispatchQueue.main.async {
            self.lastResult = nil
            self.isAnalyzing = true
            self.currentStatus = "Chargement de la video..."
        }
    }

    func presentImportFailure(_ error: Error) {
        let logs = """
        --- START TELEMETRY ---
        ERROR: Impossible de charger la video choisie depuis la galerie.
        Import Error: \(error.localizedDescription)
        """

        finishWithError(logs: logs)
    }

    func presentImportFailure(message: String) {
        let logs = """
        --- START TELEMETRY ---
        ERROR: \(message)
        """

        finishWithError(logs: logs)
    }

    func startAnalysis(videoURL: URL) {
        cleanupPendingFiles()

        DispatchQueue.main.async {
            self.lastResult = nil
            self.isAnalyzing = true
            self.currentStatus = "Initialisation pipeline Vision..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processVideo(url: videoURL)
        }
    }

    func reset() {
        cleanupPendingFiles()
        trackingService.reset()

        lastResult = nil
        currentStatus = ""
        isAnalyzing = false
    }

    private func processVideo(url: URL) {
        trackingService.reset()
        let asset = AVAsset(url: url)

        Task { [weak self] in
            guard let self else { return }

            var logs = "--- START TELEMETRY ---\n"

            let videoTracks = try? await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks?.first else {
                logs += "ERROR: Could not find video track.\n"
                self.finishWithError(logs: logs, cleanupURLs: [url])
                return
            }

            guard let reader = try? AVAssetReader(asset: asset) else {
                logs += "ERROR: Could not create AVAssetReader.\n"
                self.finishWithError(logs: logs, cleanupURLs: [url])
                return
            }

            logs += "Asset loaded.\n"

            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]

            let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
            guard reader.canAdd(trackOutput) else {
                logs += "ERROR: Could not attach track output to reader.\n"
                self.finishWithError(logs: logs, cleanupURLs: [url])
                return
            }

            reader.add(trackOutput)

            guard reader.startReading() else {
                let readerError = reader.error?.localizedDescription ?? "Unknown AVAssetReader error"
                logs += "ERROR: Could not start reading. \(readerError)\n"
                self.finishWithError(logs: logs, cleanupURLs: [url])
                return
            }

            var framesProcessed = 0
            let targetFPS = Double(AppConfig.analysisFPS)
            let frameInterval = CMTime(seconds: 1.0 / targetFPS, preferredTimescale: 600)
            var nextTargetTime = CMTime.zero

            logs += "Starting Vision Request loop at \(AppConfig.analysisFPS) FPS...\n"

            let request = VNDetectHumanRectanglesRequest()
            await self.updateStatus("Analyse visuelle...")

            var videoOrientation: CGImagePropertyOrientation = .up
            if let transform = try? await videoTrack.load(.preferredTransform) {
                videoOrientation = self.getVideoOrientation(from: transform)
                logs += "Video orientation detected: \(videoOrientation.rawValue)\n"
            }

            while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

                if pts < nextTargetTime {
                    continue
                }

                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    nextTargetTime = CMTimeAdd(nextTargetTime, frameInterval)
                    continue
                }

                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: videoOrientation, options: [:])

                do {
                    try handler.perform([request])
                    let boxes = request.results?.map { self.transformRect($0.boundingBox, orientation: videoOrientation) } ?? []
                    self.trackingService.processFrame(cmTime: pts, boundingBoxes: boxes)

                    if framesProcessed % 30 == 0 {
                        logs += "Frame \(framesProcessed) @ \(String(format: "%.2f", pts.seconds))s: \(boxes.count) humain(s).\n"
                    }
                } catch {
                    logs += "Vision Error on frame \(framesProcessed): \(error.localizedDescription)\n"
                }

                nextTargetTime = CMTimeAdd(nextTargetTime, frameInterval)
                framesProcessed += 1

                if framesProcessed % 20 == 0 {
                    await self.updateStatus("Analyse frame \(framesProcessed)...")
                }
            }

            if reader.status == .failed {
                let readerError = reader.error?.localizedDescription ?? "Unknown reader failure"
                logs += "ERROR: Reader failed before completion. \(readerError)\n"
                self.finishWithError(logs: logs, cleanupURLs: [url])
                return
            }

            logs += "Extraction complete. \(framesProcessed) frames traitees.\n"

            guard let targetTrack = self.trackingService.getTargetTrack() else {
                logs += "CRITICAL ERROR: trackingService.getTargetTrack() returned nil. No climber moved enough vertically.\n"
                self.finishWithError(logs: logs, cleanupURLs: [url])
                return
            }

            logs += "Target track selected: UUID \(targetTrack.id.uuidString.prefix(4)), score vertical: \(String(format: "%.2f", targetTrack.totalScore))\n"
            let result = self.eventDetector.analyzeTrack(targetTrack)

            guard result.isValid, let start = result.trimStart, let end = result.trimEnd else {
                logs += "CRITICAL ERROR: EventDetector could not validate Start or Top.\n"
                logs += "Event details - start: \(result.startTime?.seconds ?? -1), top: \(result.topTime?.seconds ?? -1)\n"
                self.finishWithError(logs: logs, cleanupURLs: [url])
                return
            }

            logs += "SUCCESS! Trim constraints -> Start: \(String(format: "%.2f", start.seconds))s, End: \(String(format: "%.2f", end.seconds))s\n"
            await self.updateStatus("Decoupage (Trim)...")

            self.trimExportService.trimVideo(url: url, start: start, end: end) { [weak self] exportedURL, error in
                guard let self else { return }
                self.handleTrimCompletion(
                    sourceURL: url,
                    analysisResult: result,
                    logs: logs,
                    exportedURL: exportedURL,
                    error: error
                )
            }
        }
    }

    private func handleTrimCompletion(
        sourceURL: URL,
        analysisResult: AnalysisResult,
        logs: String,
        exportedURL: URL?,
        error: Error?
    ) {
        var completionLogs = logs

        guard let exportedURL else {
            completionLogs += "ERROR: trimVideo exportedURL is nil.\n"
            if let error {
                completionLogs += "Export Error: \(error.localizedDescription)\n"
            }

            finishWithError(logs: completionLogs, cleanupURLs: [sourceURL])
            return
        }

        DispatchQueue.main.async {
            self.currentStatus = "Sauvegarde galerie..."
        }

        photoLibraryService.saveVideoToLibrary(url: exportedURL) { [weak self] success, error in
            guard let self else { return }

            if let error {
                completionLogs += "ERROR Galerie: \(error.localizedDescription)\n"
            } else if success {
                completionLogs += "Video sauvegardee dans la galerie.\n"
            } else {
                completionLogs += "ERROR Galerie: sauvegarde retournee sans erreur explicite.\n"
            }

            let cleanupURLs = [sourceURL, exportedURL]
            let visibleExportURL = success ? nil : exportedURL

            self.finishWithResult(
                analysisResult,
                logs: completionLogs,
                exportedURL: visibleExportURL,
                cleanupURLs: cleanupURLs
            )
        }
    }

    private func finishWithResult(_ result: AnalysisResult, logs: String, exportedURL: URL?, cleanupURLs: [URL]) {
        markForCleanup(cleanupURLs)

        DispatchQueue.main.async {
            self.lastResult = AnalysisResult(
                startTime: result.startTime,
                topTime: result.topTime,
                trimStart: result.trimStart,
                trimEnd: result.trimEnd,
                targetConfidenceScore: result.targetConfidenceScore,
                debugLogs: logs,
                exportedURL: exportedURL,
                savedToLibrary: exportedURL == nil
            )
            self.currentStatus = ""
            self.isAnalyzing = false
        }
    }

    private func finishWithError(logs: String, cleanupURLs: [URL] = []) {
        markForCleanup(cleanupURLs)

        DispatchQueue.main.async {
            self.lastResult = AnalysisResult(
                startTime: nil,
                topTime: nil,
                trimStart: nil,
                trimEnd: nil,
                targetConfidenceScore: 0,
                debugLogs: logs,
                exportedURL: nil,
                savedToLibrary: false
            )
            self.currentStatus = ""
            self.isAnalyzing = false
        }
    }

    private func markForCleanup(_ urls: [URL]) {
        for url in urls where recordingManager.isManagedURL(url) {
            if !pendingCleanupURLs.contains(url) {
                pendingCleanupURLs.append(url)
            }
        }
    }

    private func cleanupPendingFiles() {
        guard !pendingCleanupURLs.isEmpty else { return }

        for url in pendingCleanupURLs {
            recordingManager.cleanup(url: url)
        }

        pendingCleanupURLs.removeAll()
    }

    private func updateStatus(_ status: String) async {
        await MainActor.run {
            self.currentStatus = status
        }
    }

    private func getVideoOrientation(from transform: CGAffineTransform) -> CGImagePropertyOrientation {
        if transform.a == 0 && transform.b == 1.0 && transform.c == -1.0 && transform.d == 0 {
            return .right
        }

        if transform.a == 0 && transform.b == -1.0 && transform.c == 1.0 && transform.d == 0 {
            return .left
        }

        if transform.a == 1.0 && transform.b == 0 && transform.c == 0 && transform.d == 1.0 {
            return .up
        }

        if transform.a == -1.0 && transform.b == 0 && transform.c == 0 && transform.d == -1.0 {
            return .down
        }

        return .up
    }

    private func transformRect(_ rect: CGRect, orientation: CGImagePropertyOrientation) -> CGRect {
        switch orientation {
        case .up:
            return rect
        case .down:
            return CGRect(x: 1 - rect.maxX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        case .left:
            return CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        case .right:
            return CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        default:
            return rect
        }
    }
}
