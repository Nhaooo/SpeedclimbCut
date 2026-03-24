import Foundation
import Photos
import UIKit

class PhotoLibraryService: ObservableObject {
    func saveVideoToLibrary(url: URL, completion: @escaping (Bool, Error?) -> Void) {
        let authHandler: (PHAuthorizationStatus) -> Void = { status in
            guard status == .authorized || status == .limited else {
                let error = NSError(domain: "PhotoLibraryAccess", code: 403, userInfo: [NSLocalizedDescriptionKey: "Accès refusé"])
                DispatchQueue.main.async { completion(false, error) }
                return
            }
            
            // Verify file exists before attempting to save to prevent crashes
            guard FileManager.default.fileExists(atPath: url.path) else {
                let error = NSError(domain: "PhotoLibraryAccess", code: 404, userInfo: [NSLocalizedDescriptionKey: "Fichier vidéo introuvable"])
                DispatchQueue.main.async { completion(false, error) }
                return
            }
            
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { saved, error in
                DispatchQueue.main.async {
                    completion(saved, error)
                }
            }
        }
        
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: authHandler)
        } else {
            PHPhotoLibrary.requestAuthorization(authHandler)
        }
    }
}
