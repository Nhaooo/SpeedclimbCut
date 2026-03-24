import SwiftUI
import AVFoundation
import PhotosUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var analysisService = VideoAnalysisService()
    
    @State private var importedVideoItem: PhotosPickerItem? = nil
    @State private var showCamera = false
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
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
                // Menu d'Accueil (Dashboard)
                VStack(spacing: 30) {
                    Image(systemName: "timer")
                        .font(.system(size: 80))
                        .foregroundColor(.green)
                    
                    Text("SpeedClimbCut")
                        .font(.largeTitle).bold()
                        .foregroundColor(.white)
                        .padding(.bottom, 20)
                    
                    PhotosPicker(selection: $importedVideoItem, matching: .videos) {
                        HStack {
                            Image(systemName: "photo.stack")
                            Text("Importer une vidéo")
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
                            Text("Caméra (Expérimental)")
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
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
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
            Text("✅ Analyse Terminée")
                .font(.title).bold()
            
            if result.isValid {
                Text("Start: +\(String(format: "%.2fs", result.startTime?.seconds ?? 0))")
                Text("Top: +\(String(format: "%.2fs", result.topTime?.seconds ?? 0))")
                
                Text("Vidéo coupée copiée dans tes Photos !")
                    .foregroundColor(.green)
                    .multilineTextAlignment(.center)
            } else {
                Text("Échec de l'analyse.")
                    .foregroundColor(.red)
                Text("L'algorithme a perdu la piste.")
            }
            
            Button("Retour", action: onDismiss)
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
