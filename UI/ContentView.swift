import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var logMessages: [String] = ["Lancement de l'app UI..."]
    @State private var safeBootSuccess = false
    
    // Defer initialization to avoid init crashes
    @State private var cameraManager: CameraManager?
    @State private var analysisService: VideoAnalysisService?
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if !safeBootSuccess {
                VStack {
                    Text("🚀 SpeedClimbCut (Safe Mode)")
                        .foregroundColor(.white)
                        .font(.headline)
                        .padding()
                    
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(logMessages, id: \.self) { msg in
                                Text(">> \(msg)").foregroundColor(.green).font(.caption)
                            }
                        }
                    }
                    .frame(height: 150)
                    .background(Color.gray.opacity(0.3))
                    
                    Button("Initialiser la Caméra et les Services") {
                        addLog("Bouton pressé: Initialisation...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            doSafeBoot()
                        }
                    }
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
            } else if let cameraManager = cameraManager, let analysisService = analysisService {
                mainAppView(cameraManager: cameraManager, analysisService: analysisService)
            }
        }
    }
    
    func doSafeBoot() {
        addLog("▶️ Step 1: VideoAnalysisService...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.analysisService = VideoAnalysisService()
            addLog("✅ VideoService OK.")
            
            addLog("▶️ Step 2: CameraManager...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.cameraManager = CameraManager()
                addLog("✅ CameraManager OK.")
                
                addLog("▶️ Step 3: Lancement Interface (CameraView)...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    addLog("Activation UI...")
                    self.safeBootSuccess = true
                }
            }
        }
    }
    
    func addLog(_ message: String) {
        logMessages.append(message)
    }
    
    // --- MAIN APP ---
    @ViewBuilder
    func mainAppView(cameraManager: CameraManager, analysisService: VideoAnalysisService) -> some View {
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
                    analysisService.startAnalysis(videoURL: url)
                }
                
                VStack {
                    HStack {
                        Spacer()
                        // Fallback temporaire pour ne pas crasher sur PhotosPickerItem
                        Button(action: {
                            // On désactive l'import pendant le test de la caméra
                            // pour être sûr qu'aucun framework ne manque.
                        }) {
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
