import Foundation
import Photos

final class PhotoLibraryService {
    func saveVideoToLibrary(url: URL, completion: @escaping (Bool, Error?) -> Void) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            DispatchQueue.main.async {
                completion(false, NSError(domain: "PhotoLibraryAccess", code: 404, userInfo: [NSLocalizedDescriptionKey: "Fichier source introuvable"]))
            }
            return
        }

        let performSave = {
            let creationOptions = PHAssetResourceCreationOptions()
            creationOptions.shouldMoveFile = false

            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: creationOptions)
            }) { success, error in
                DispatchQueue.main.async {
                    completion(success, error)
                }
            }
        }

        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                if status == .authorized || status == .limited {
                    performSave()
                } else {
                    DispatchQueue.main.async {
                        completion(false, NSError(domain: "PhotoLibraryAccess", code: 401, userInfo: [NSLocalizedDescriptionKey: "Permission galerie refusee"]))
                    }
                }
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                if status == .authorized || status == .limited {
                    performSave()
                } else {
                    DispatchQueue.main.async {
                        completion(false, NSError(domain: "PhotoLibraryAccess", code: 401, userInfo: [NSLocalizedDescriptionKey: "Permission galerie refusee"]))
                    }
                }
            }
        }
    }
}
