import Foundation
import Photos
import UIKit

final class PhotoLibraryService: NSObject {
    private var completionHandler: ((Bool, Error?) -> Void)?
    private var pendingCleanupURL: URL?

    func requestAddPermission(completion: ((PHAuthorizationStatus) -> Void)? = nil) {
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                DispatchQueue.main.async {
                    completion?(status)
                }
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                DispatchQueue.main.async {
                    completion?(status)
                }
            }
        }
    }

    func saveVideoToLibrary(url: URL, completion: @escaping (Bool, Error?) -> Void) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            DispatchQueue.main.async {
                completion(false, NSError(domain: "PhotoLibraryAccess", code: 404, userInfo: [NSLocalizedDescriptionKey: "Fichier source introuvable"]))
            }
            return
        }

        completionHandler = completion

        let fileExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        let copyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallery_save_\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try? FileManager.default.removeItem(at: copyURL)

        do {
            try FileManager.default.copyItem(at: url, to: copyURL)
            pendingCleanupURL = copyURL
        } catch {
            DispatchQueue.main.async {
                completion(false, error)
            }
            completionHandler = nil
            return
        }

        let performSave: () -> Void = { [weak self] in
            guard let self else { return }
            guard let saveURL = self.pendingCleanupURL else {
                DispatchQueue.main.async {
                    self.completionHandler?(false, NSError(domain: "PhotoLibraryAccess", code: 500, userInfo: [NSLocalizedDescriptionKey: "Fichier temporaire introuvable"]))
                    self.finishSave()
                }
                return
            }

            DispatchQueue.main.async {
                if UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(saveURL.path) {
                    UISaveVideoAtPathToSavedPhotosAlbum(
                        saveURL.path,
                        self,
                        #selector(self.video(_:didFinishSavingWithError:contextInfo:)),
                        nil
                    )
                } else {
                    self.saveWithPhotoKit(url: saveURL)
                }
            }
        }

        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                if status == .authorized || status == .limited {
                    performSave()
                } else {
                    DispatchQueue.main.async {
                        self.completionHandler?(false, NSError(domain: "PhotoLibraryAccess", code: 401, userInfo: [NSLocalizedDescriptionKey: "Permission galerie refusee"]))
                        self.finishSave()
                    }
                }
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                if status == .authorized || status == .limited {
                    performSave()
                } else {
                    DispatchQueue.main.async {
                        self.completionHandler?(false, NSError(domain: "PhotoLibraryAccess", code: 401, userInfo: [NSLocalizedDescriptionKey: "Permission galerie refusee"]))
                        self.finishSave()
                    }
                }
            }
        }
    }

    private func saveWithPhotoKit(url: URL) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }) { success, error in
            DispatchQueue.main.async {
                self.completionHandler?(success, error)
                self.finishSave()
            }
        }
    }

    @objc private func video(_ videoPath: String, didFinishSavingWithError error: Error?, contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            self.completionHandler?(error == nil, error)
            self.finishSave()
        }
    }

    private func finishSave() {
        if let url = pendingCleanupURL {
            try? FileManager.default.removeItem(at: url)
        }

        pendingCleanupURL = nil
        completionHandler = nil
    }
}
