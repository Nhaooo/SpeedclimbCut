import AVFoundation
import SwiftUI

struct CameraView: UIViewControllerRepresentable {
    @ObservedObject var manager: CameraManager
    var onVideoSaved: (URL) -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let viewController = CameraViewController()
        viewController.manager = manager
        manager.onVideoSaved = onVideoSaved
        return viewController
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}
}

final class CameraViewController: UIViewController {
    var manager: CameraManager?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let manager else { return }

        let previewLayer = AVCaptureVideoPreviewLayer(session: manager.session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer

        manager.checkPermissionsAndStart()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        manager?.stopSession()
    }
}
