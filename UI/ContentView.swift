import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var analysisService = VideoAnalysisService()

    @State private var importedVideoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var hasRequestedPhotoPermission = false

    private let photoLibraryService = PhotoLibraryService()

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            if analysisService.isAnalyzing {
                VStack(spacing: 12) {
                    ProgressView("Analyse en cours...")
                        .padding()
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(10)
                        .foregroundColor(.white)

                    Text(analysisService.currentStatus)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            } else if let result = analysisService.lastResult {
                AnalysisResultView(result: result) {
                    analysisService.reset()
                }
            } else if showCamera {
                CameraView(manager: cameraManager) { url in
                    showCamera = false
                    analysisService.startAnalysis(videoURL: url)
                }

                VStack {
                    HStack {
                        Button(action: { showCamera = false }) {
                            Image(systemName: "xmark")
                                .font(.title)
                                .padding()
                                .background(Circle().fill(Color.white.opacity(0.8)))
                                .foregroundColor(.black)
                        }
                        .padding()

                        Spacer()
                    }

                    Spacer()

                    if cameraManager.isRecording {
                        Button(action: { cameraManager.stopRecording() }) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 70, height: 70)
                                .overlay(Circle().stroke(Color.white, lineWidth: 4))
                        }
                        .padding(.bottom, 30)
                    } else {
                        Button(action: { cameraManager.startRecording() }) {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 70, height: 70)
                                .overlay(Circle().stroke(Color.gray, lineWidth: 4))
                        }
                        .padding(.bottom, 30)
                    }
                }
            } else {
                VStack(spacing: 30) {
                    Image(systemName: "timer")
                        .font(.system(size: 80))
                        .foregroundColor(.green)

                    Text("SpeedClimbCut")
                        .font(.largeTitle.bold())
                        .foregroundColor(.white)
                        .padding(.bottom, 20)

                    PhotosPicker(selection: $importedVideoItem, matching: .videos) {
                        HStack {
                            Image(systemName: "photo.stack")
                            Text("Importer une video")
                        }
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(15)
                    }

                    Button(action: {
                        showCamera = true
                    }) {
                        HStack {
                            Image(systemName: "camera")
                            Text("Camera (experimental)")
                        }
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(15)
                    }
                }
                .padding(40)
            }
        }
        .onChange(of: importedVideoItem) { newItem in
            handleImportedVideoSelection(newItem)
        }
        .onAppear {
            guard !hasRequestedPhotoPermission else { return }
            hasRequestedPhotoPermission = true
            photoLibraryService.requestAddPermission()
        }
        .edgesIgnoringSafeArea(.all)
    }

    private func handleImportedVideoSelection(_ item: PhotosPickerItem?) {
        guard let item else { return }

        analysisService.prepareImportedVideoLoad()

        Task {
            do {
                guard let importedVideo = try await item.loadTransferable(type: ImportedVideo.self) else {
                    analysisService.presentImportFailure(message: "Le selecteur n'a retourne aucune video.")
                    await MainActor.run {
                        importedVideoItem = nil
                    }
                    return
                }

                analysisService.startAnalysis(videoURL: importedVideo.url)
            } catch {
                analysisService.presentImportFailure(error)
            }

            await MainActor.run {
                importedVideoItem = nil
            }
        }
    }
}

struct AnalysisResultView: View {
    let result: AnalysisResult
    let onDismiss: () -> Void
    @State private var showLogs = false
    private let maxVisibleLogCharacters = 6000

    private var visibleLogs: String {
        guard result.debugLogs.count > maxVisibleLogCharacters else {
            return result.debugLogs
        }

        let suffix = result.debugLogs.suffix(maxVisibleLogCharacters)
        return "[Logs tronques dans l'UI - copie pour avoir le complet]\n" + String(suffix)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(result.isValid ? "Analyse terminee" : "Echec de l'analyse")
                .font(.title.bold())

            if result.isValid {
                Text("Start: +\(String(format: "%.2fs", result.startTime?.seconds ?? 0))")
                Text("Top: +\(String(format: "%.2fs", result.topTime?.seconds ?? 0))")

                if result.savedToLibrary {
                    Text("Video decoupee sauvegardee dans Photos.")
                        .foregroundColor(.green)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Decoupage reussi, mais la sauvegarde Photos a echoue. Consulte les logs.")
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }
            }

            VStack(alignment: .leading) {
                HStack {
                    Button(showLogs ? "Masquer les logs" : "Afficher les logs") {
                        showLogs.toggle()
                    }
                    .font(.caption.bold())

                    Spacer()

                    Button(action: {
                        UIPasteboard.general.string = result.debugLogs
                    }) {
                        Image(systemName: "doc.on.doc")
                        Text("Copier")
                    }
                    .font(.caption)
                    .padding(5)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(5)
                }

                if showLogs {
                    ScrollView {
                        Text(visibleLogs)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxHeight: 200)
                    .padding(5)
                    .background(Color.black.opacity(0.05))
                    .cornerRadius(8)
                }
            }

            Button("Retour", action: onDismiss)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
        }
        .padding()
        .background(Color.white)
        .cornerRadius(20)
        .shadow(radius: 10)
        .padding()
    }
}
