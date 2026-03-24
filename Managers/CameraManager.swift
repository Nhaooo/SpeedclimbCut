import AVFoundation
import SwiftUI

final class CameraManager: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()

    @Published var isRecording = false

    var onVideoSaved: ((URL) -> Void)?

    private let sessionQueue = DispatchQueue(label: "SpeedClimbCut.CameraSession")
    private let videoOutput = AVCaptureMovieFileOutput()
    private let recordingManager = RecordingManager.shared
    private var isSessionConfigured = false

    func checkPermissionsAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                self?.startSession()
            }
        default:
            print("Permission refusee pour la camera")
        }
    }

    func startRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSessionIfNeeded()
            guard self.isSessionConfigured else { return }

            if !self.session.isRunning {
                self.session.startRunning()
            }

            guard !self.videoOutput.isRecording else { return }

            do {
                let outputURL = try self.recordingManager.makeRecordingURL(fileExtension: "mov")
                self.videoOutput.startRecording(to: outputURL, recordingDelegate: self)
                DispatchQueue.main.async {
                    self.isRecording = true
                }
            } catch {
                print("Impossible de preparer le fichier video: \(error.localizedDescription)")
            }
        }
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.videoOutput.isRecording else { return }
            self.videoOutput.stopRecording()
            DispatchQueue.main.async {
                self.isRecording = false
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSessionIfNeeded()
            guard self.isSessionConfigured else { return }

            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    private func configureSessionIfNeeded() {
        guard !isSessionConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        defer {
            session.commitConfiguration()
        }

        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput) else {
            print("Impossible de configurer la camera arriere")
            return
        }

        session.addInput(videoInput)

        guard session.canAddOutput(videoOutput) else {
            print("Impossible d'ajouter la sortie video")
            return
        }

        videoOutput.movieFragmentInterval = .invalid
        session.addOutput(videoOutput)
        isSessionConfigured = true
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        if let error {
            print("Erreur d'enregistrement: \(error.localizedDescription)")
            recordingManager.cleanup(url: outputFileURL)
            return
        }

        DispatchQueue.main.async {
            self.onVideoSaved?(outputFileURL)
        }
    }
}
