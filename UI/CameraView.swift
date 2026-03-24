import SwiftUI
import AVFoundation

struct CameraView: UIViewControllerRepresentable {
    @ObservedObject var manager: CameraManager
    var onVideoSaved: (URL) -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.manager = manager
        manager.onVideoSaved = onVideoSaved
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}
}

class CameraViewController: UIViewController {
    var manager: CameraManager?
    var previewLayer: AVCaptureVideoPreviewLayer!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        guard let manager = manager else { return }
        
        previewLayer = AVCaptureVideoPreviewLayer(session: manager.session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        
        manager.checkPermissionsAndStart()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }
}
