import AVFoundation
import Foundation
import ImageIO

final class VideoAnalysisService: ObservableObject {
    @Published var isAnalyzing = false
    @Published var currentStatus = ""
    @Published var lastResult: AnalysisResult?

    private let hybridTrackingService = HybridVisionTrackingService()
    private let eventDetector = ClimbEventDetector()
    private let motionAnalysisService = MotionHybridAnalysisService()
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
            self.currentStatus = "Initialisation analyse hybride..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processVideo(url: videoURL)
        }
    }

    func reset() {
        cleanupPendingFiles()

        lastResult = nil
        currentStatus = ""
        isAnalyzing = false
    }

    private func processVideo(url: URL) {
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

            logs += "Asset loaded.\n"

            var videoOrientation: CGImagePropertyOrientation = .up
            if let transform = try? await videoTrack.load(.preferredTransform) {
                videoOrientation = self.getVideoOrientation(from: transform)
                logs += "Video orientation detected: \(videoOrientation.rawValue)\n"
            }

            var selectedMethod = "none"
            var finalResult: AnalysisResult?

            await self.updateStatus("Suivi du grimpeur...")

            do {
                if let trackingAnalysis = try await self.hybridTrackingService.analyze(
                    asset: asset,
                    videoTrack: videoTrack,
                    orientation: videoOrientation
                ) {
                    logs += trackingAnalysis.debugLogs
                    logs += "Hybrid target track: score \(String(format: "%.2f", trackingAnalysis.track.totalScore)), points: \(trackingAnalysis.track.points.count), peakY: \(String(format: "%.2f", trackingAnalysis.track.peakHeight)), lastY: \(String(format: "%.2f", trackingAnalysis.track.lastHeight))\n"

                    let roughResult = self.eventDetector.analyzeTrack(trackingAnalysis.track)
                    logs += "Hybrid rough events -> start: \(roughResult.startTime?.seconds ?? -1), top: \(roughResult.topTime?.seconds ?? -1)\n"

                    await self.updateStatus("Raffinement haut du corps...")

                    let refinementResult: HybridVisionTrackingService.RefinementResult
                    do {
                        refinementResult = try await self.hybridTrackingService.refineEventTimes(
                            asset: asset,
                            videoTrack: videoTrack,
                            orientation: videoOrientation,
                            baseTrack: trackingAnalysis.track,
                            roughResult: roughResult
                        )
                    } catch {
                        logs += "WARNING: Body pose refinement failed. \(error.localizedDescription)\n"
                        refinementResult = HybridVisionTrackingService.RefinementResult(
                            startTime: roughResult.startTime,
                            topTime: roughResult.topTime,
                            debugLogs: ""
                        )
                    }

                    logs += refinementResult.debugLogs

                    let hybridResult = self.makeFinalResult(
                        startTime: refinementResult.startTime ?? roughResult.startTime,
                        topTime: refinementResult.topTime ?? roughResult.topTime,
                        confidenceScore: trackingAnalysis.track.totalScore
                    )

                    if hybridResult.isValid {
                        finalResult = hybridResult
                        selectedMethod = "hybrid_vision"
                    } else {
                        logs += "Hybrid Vision invalid, fallback vers motion.\n"
                    }
                } else {
                    logs += "Hybrid Vision n'a trouve aucune piste stable, fallback vers motion.\n"
                }
            } catch {
                logs += "WARNING: Hybrid Vision failed. \(error.localizedDescription)\n"
            }

            if finalResult == nil {
                await self.updateStatus("Analyse motion du mur...")

                let motionAnalysis: MotionHybridAnalysisService.Analysis
                do {
                    motionAnalysis = try await self.motionAnalysisService.analyze(
                        asset: asset,
                        videoTrack: videoTrack,
                        orientation: videoOrientation
                    )
                } catch {
                    logs += "CRITICAL ERROR: Motion analysis failed. \(error.localizedDescription)\n"
                    self.finishWithError(logs: logs, cleanupURLs: [url])
                    return
                }

                logs += motionAnalysis.debugLogs
                let motionResult = self.makeFinalResult(
                    startTime: motionAnalysis.startTime,
                    topTime: motionAnalysis.topTime,
                    confidenceScore: motionAnalysis.confidenceScore
                )

                if motionResult.isValid {
                    finalResult = motionResult
                    selectedMethod = "motion_\(motionAnalysis.method)"
                } else {
                    logs += "CRITICAL ERROR: Motion analysis could not validate Start or Top.\n"
                    logs += "Event details - method: \(motionAnalysis.method), start: \(motionAnalysis.startTime?.seconds ?? -1), top: \(motionAnalysis.topTime?.seconds ?? -1)\n"
                    self.finishWithError(logs: logs, cleanupURLs: [url])
                    return
                }
            }

            guard let finalResult, let start = finalResult.trimStart, let end = finalResult.trimEnd else {
                logs += "CRITICAL ERROR: No valid analysis strategy produced a trim.\n"
                self.finishWithError(logs: logs, cleanupURLs: [url])
                return
            }

            logs += "Selected analysis method -> \(selectedMethod)\n"
            logs += "SUCCESS! Trim constraints -> Start: \(String(format: "%.2f", start.seconds))s, End: \(String(format: "%.2f", end.seconds))s\n"
            await self.updateStatus("Decoupage (Trim)...")

            self.trimExportService.trimVideo(url: url, start: start, end: end) { [weak self] exportedURL, error in
                guard let self else { return }
                self.handleTrimCompletion(
                    sourceURL: url,
                    analysisResult: finalResult,
                    logs: logs,
                    exportedURL: exportedURL,
                    error: error
                )
            }
        }
    }

    private func makeFinalResult(startTime: CMTime?, topTime: CMTime?, confidenceScore: CGFloat) -> AnalysisResult {
        guard let startTime, let topTime else {
            return AnalysisResult(
                startTime: startTime,
                topTime: topTime,
                trimStart: nil,
                trimEnd: nil,
                targetConfidenceScore: confidenceScore,
                debugLogs: "",
                exportedURL: nil,
                savedToLibrary: false
            )
        }

        let trimStart = CMTimeSubtract(startTime, CMTime(seconds: AppConfig.preStartTrimMarginSeconds, preferredTimescale: 600))
        let trimEnd = CMTimeAdd(topTime, CMTime(seconds: AppConfig.postTopTrimMarginSeconds, preferredTimescale: 600))

        return AnalysisResult(
            startTime: startTime,
            topTime: topTime,
            trimStart: trimStart,
            trimEnd: trimEnd,
            targetConfidenceScore: confidenceScore,
            debugLogs: "",
            exportedURL: nil,
            savedToLibrary: false
        )
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

            recordingManager.cleanup(url: sourceURL)
            finishWithError(logs: completionLogs, cleanupURLs: [])
            return
        }

        recordingManager.cleanup(url: sourceURL)

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

            self.recordingManager.cleanup(url: exportedURL)
            self.finishWithResult(
                analysisResult,
                logs: completionLogs,
                savedToLibrary: success
            )
        }
    }

    private func finishWithResult(_ result: AnalysisResult, logs: String, savedToLibrary: Bool) {
        DispatchQueue.main.async {
            self.lastResult = AnalysisResult(
                startTime: result.startTime,
                topTime: result.topTime,
                trimStart: result.trimStart,
                trimEnd: result.trimEnd,
                targetConfidenceScore: result.targetConfidenceScore,
                debugLogs: logs,
                exportedURL: nil,
                savedToLibrary: savedToLibrary
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
}
