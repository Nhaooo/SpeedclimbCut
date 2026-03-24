import Foundation
import Photos
import UIKit

class PhotoLibraryService: ObservableObject {
    func saveVideoToLibrary(url: URL, completion: @escaping (Bool, Error?) -> Void) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else {
                let error = NSError(domain: "PhotoLibraryAccess", code: 403, userInfo: [NSLocalizedDescriptionKey: "Accès refusé"])
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
    }
}
