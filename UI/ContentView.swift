import SwiftUI
import AVFoundation
import PhotosUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var analysisService = VideoAnalysisService()
    
    @State private var importedVideoItem: PhotosPickerItem? = nil
    
    var body: some View {
        ZStack {
            if analysisService.isAnalyzing {
                VStack {
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
            } else {
                CameraView(manager: cameraManager) { url in
                    // On recording finished
                    analysisService.startAnalysis(videoURL: url)
                }
                
                // Overlay Controls
                VStack {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $importedVideoItem, matching: .videos) {
                            Image(systemName: "photo")
                                .font(.title)
                                .padding()
                                .background(Circle().fill(Color.white.opacity(0.8)))
                                .foregroundColor(.black)
                        }
                        .padding()
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
            }
        }
        .onChange(of: importedVideoItem) { newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                    // Create temp file for analysis
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                    try? data.write(to: tempURL)
                    analysisService.startAnalysis(videoURL: tempURL)
                }
            }
        }
        .edgesIgnoringSafeArea(.all)
    }
}

struct AnalysisResultView: View {
    let result: AnalysisResult
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Analyse Terminée")
                .font(.title).bold()
            
            if result.isValid {
                Text("Cible identifiée (Score: \(String(format: "%.2f", result.targetConfidenceScore)))")
                Text("Départ détecté: +\(String(format: "%.2fs", result.startTime?.seconds ?? 0))")
                Text("Top détecté: +\(String(format: "%.2fs", result.topTime?.seconds ?? 0))")
                
                Text("Export final généré et sauvegardé dans Photos.")
                    .foregroundColor(.green)
                    .multilineTextAlignment(.center)
            } else {
                Text("Échec de l'analyse.")
                    .foregroundColor(.red)
                Text("Aucun grimpeur trouvé ou mouvement insertain.")
            }
            
            Button("Nouvelle vidéo", action: onDismiss)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
        }
        .padding()
        .background(Color.white)
        .cornerRadius(20)
        .shadow(radius: 10)
    }
}
