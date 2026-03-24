import AVFoundation
import SwiftUI

class CameraManager: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureMovieFileOutput()
    @Published var isRecording = false
    
    var onVideoSaved: ((URL) -> Void)?
    
    func checkPermissionsAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async { self?.setupSession() }
                }
            }
        default:
            print("Permission refusée pour la caméra")
        }
    }
    
    private func setupSession() {
        session.beginConfiguration()
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput) else {
            return
        }
        
        session.addInput(videoInput)
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        
        session.commitConfiguration()
        
        DispatchQueue.global(qos: .background).async {
            self.session.startRunning()
        }
    }
    
    func startRecording() {
        let tempDir = NSTemporaryDirectory()
        let url = URL(fileURLWithPath: tempDir).appendingPathComponent(UUID().uuidString + ".mov")
        videoOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
    }
    
    func stopRecording() {
        videoOutput.stopRecording()
        isRecording = false
    }
    
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error = error {
            print("Erreur d'enregistrement: \(error.localizedDescription)")
            return
        }
        DispatchQueue.main.async {
            self.onVideoSaved?(outputFileURL)
        }
    }
}
