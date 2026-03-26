import AVFoundation
import Foundation
import ImageIO

final class VideoAnalysisService: ObservableObject {
    @Published var isAnalyzing = false
    @Published var currentStatus = ""
    @Published var lastResult: AnalysisResult?

    private let fusionAnalysisService = TrackMotionFusionService()
    private let motionAnalysisService = MotionHybridAnalysisService()
    private let trimExportService = VideoTrimExportService()
    private let photoLibraryService = PhotoLibraryService()
    private let recordingManager = RecordingManager.shared

    private var pendingCleanupURLs: [URL] = []

    private struct StrategyCandidate {
        let method: String
        let result: AnalysisResult
        let confidence: CGFloat
    }

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
            self.currentStatus = "Initialisation analyse finale..."
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

            var motionCandidate: StrategyCandidate?
            var fusionCandidate: StrategyCandidate?

            await self.updateStatus("Analyse motion du mur...")

            do {
                let motionAnalysis = try await self.motionAnalysisService.analyze(
                    asset: asset,
                    videoTrack: videoTrack,
                    orientation: videoOrientation
                )

                logs += motionAnalysis.debugLogs

                let motionResult = self.makeFinalResult(
                    startTime: motionAnalysis.startTime,
                    topTime: motionAnalysis.topTime,
                    confidenceScore: motionAnalysis.confidenceScore
                )

                if motionResult.isValid {
                    motionCandidate = StrategyCandidate(
                        method: "motion_\(motionAnalysis.method)",
                        result: motionResult,
                        confidence: motionAnalysis.confidenceScore
                    )
                } else {
                    logs += "Motion invalide, tentative fusion motion-track locale.\n"
                }
            } catch {
                logs += "WARNING: Motion analysis failed. \(error.localizedDescription)\n"
            }

            await self.updateStatus("Analyse fusion motion + grimpeur...")

            do {
                let fusionAnalysis = try await self.fusionAnalysisService.analyze(
                    asset: asset,
                    videoTrack: videoTrack,
                    orientation: videoOrientation
                )

                logs += fusionAnalysis.debugLogs

                let fusionResult = self.makeFinalResult(
                    startTime: fusionAnalysis.startTime,
                    topTime: fusionAnalysis.topTime,
                    confidenceScore: fusionAnalysis.confidenceScore
                )

                if fusionResult.isValid {
                    fusionCandidate = StrategyCandidate(
                        method: fusionAnalysis.method,
                        result: fusionResult,
                        confidence: fusionAnalysis.confidenceScore
                    )
                } else {
                    logs += "Fusion motion-track invalide sur cette video.\n"
                }
            } catch {
                logs += "WARNING: Fusion motion-track failed. \(error.localizedDescription)\n"
            }

            guard let selectedCandidate = self.selectBestCandidate(
                motionCandidate: motionCandidate,
                fusionCandidate: fusionCandidate,
                logs: &logs
            ) else {
                logs += "CRITICAL ERROR: No valid analysis strategy produced a trim.\n"
                self.finishWithError(logs: logs, cleanupURLs: [url])
                return
            }

            let finalResult = selectedCandidate.result
            guard let start = finalResult.trimStart, let end = finalResult.trimEnd else {
                logs += "CRITICAL ERROR: No valid analysis strategy produced a trim.\n"
                self.finishWithError(logs: logs, cleanupURLs: [url])
                return
            }

            logs += "Selected analysis method -> \(selectedCandidate.method)\n"
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

    private func selectBestCandidate(
        motionCandidate: StrategyCandidate?,
        fusionCandidate: StrategyCandidate?,
        logs: inout String
    ) -> StrategyCandidate? {
        switch (motionCandidate, fusionCandidate) {
        case let (motion?, fusion?):
            guard
                let motionStart = motion.result.startTime?.seconds,
                let motionTop = motion.result.topTime?.seconds,
                let fusionStart = fusion.result.startTime?.seconds,
                let fusionTop = fusion.result.topTime?.seconds
            else {
                logs += "Selection strategies -> donnees incompletes, fallback simple.\n"
                return motion.result.isValid ? motion : (fusion.result.isValid ? fusion : nil)
            }

            let startGap = abs(motionStart - fusionStart)
            let topGap = abs(motionTop - fusionTop)
            let motionDuration = motionTop - motionStart
            let motionDurationLooksGood =
                motionDuration >= AppConfig.motionPreferredDurationMinSeconds &&
                motionDuration <= AppConfig.motionPreferredDurationMaxSeconds

            logs += "Selection strategies -> motion \(motion.method) vs fusion \(fusion.method)\n"
            logs += "Selection strategies -> start gap: \(String(format: "%.2f", startGap))s, top gap: \(String(format: "%.2f", topGap))s, motion peak: \(String(format: "%.3f", motion.confidence)), fusion confidence: \(String(format: "%.3f", fusion.confidence))\n"

            if startGap <= AppConfig.fusionAgreementStartToleranceSeconds &&
                topGap <= AppConfig.fusionAgreementTopToleranceSeconds {
                logs += "Selection strategies -> bon accord motion/fusion, on garde motion.\n"
                return motion
            }

            let largeDisagreement =
                startGap >= AppConfig.fusionOverrideDisagreementSeconds ||
                topGap >= AppConfig.fusionOverrideDisagreementSeconds
            let motionLooksSuspicious =
                motion.confidence >= AppConfig.motionSuspiciousPeakThreshold ||
                !motionDurationLooksGood

            if largeDisagreement,
                fusion.confidence >= AppConfig.fusionOverrideConfidenceThreshold {
                logs += "Selection strategies -> grand desaccord, la strategie grimpeur prend la main.\n"
                return fusion
            }

            if motionLooksSuspicious,
                fusion.confidence >= AppConfig.fusionOverrideConfidenceThreshold {
                logs += "Selection strategies -> motion suspect et fusion plausible, on bascule vers fusion.\n"
                return fusion
            }

            logs += "Selection strategies -> desaccord non bloquant, motion reste la reference.\n"
            return motion

        case let (motion?, nil):
            logs += "Selection strategies -> fusion indisponible, on garde motion.\n"
            return motion

        case let (nil, fusion?):
            logs += "Selection strategies -> motion indisponible, on garde fusion.\n"
            return fusion

        case (nil, nil):
            logs += "Selection strategies -> aucune strategie valide.\n"
            return nil
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
