import Foundation
import Photos
import UIKit

class PhotoLibraryService: NSObject, ObservableObject {
    private var completionHandler: ((Bool, Error?) -> Void)?
    
    func saveVideoToLibrary(url: URL, completion: @escaping (Bool, Error?) -> Void) {
        self.completionHandler = completion
        
        // Verify file exists before attempting to save to prevent crashes
        guard FileManager.default.fileExists(atPath: url.path) else {
            let error = NSError(domain: "PhotoLibraryAccess", code: 404, userInfo: [NSLocalizedDescriptionKey: "Fichier vidéo introuvable"])
            DispatchQueue.main.async { completion(false, error) }
            return
        }
        
        // Use the older, much more robust API that doesn't hard-crash on invalid formats or locked files
        if UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path) {
            UISaveVideoAtPathToSavedPhotosAlbum(url.path, self, #selector(video(_:didFinishSavingWithError:contextInfo:)), nil)
        } else {
            let error = NSError(domain: "PhotoLibraryAccess", code: 400, userInfo: [NSLocalizedDescriptionKey: "Vidéo incompatible avec la galerie"])
            DispatchQueue.main.async { completion(false, error) }
        }
    }
    
    @objc func video(_ videoPath: String, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        DispatchQueue.main.async {
            self.completionHandler?(error == nil, error)
            self.completionHandler = nil
        }
    }
}
