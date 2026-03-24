import Foundation
import Photos
import UIKit

class PhotoLibraryService: NSObject, ObservableObject {
    private var completionHandler: ((Bool, Error?) -> Void)?
    
    func saveVideoToLibrary(url: URL, completion: @escaping (Bool, Error?) -> Void) {
        // 1. Check if source file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            DispatchQueue.main.async {
                completion(false, NSError(domain: "PhotoLibraryAccess", code: 404, userInfo: [NSLocalizedDescriptionKey: "Fichier source introuvable"]))
            }
            return
        }
        
        self.completionHandler = completion
        
        // 2. Use the oldest, most robust API which often bypasses modern Sandbox restrictions on free accounts
        DispatchQueue.global(qos: .userInitiated).async {
            if UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path) {
                UISaveVideoAtPathToSavedPhotosAlbum(url.path, self, #selector(self.video(_:didFinishSavingWithError:contextInfo:)), nil)
            } else {
                DispatchQueue.main.async {
                    self.completionHandler?(false, NSError(domain: "PhotoLibraryAccess", code: 400, userInfo: [NSLocalizedDescriptionKey: "Vidéo incompatible avec la galerie"]))
                    self.completionHandler = nil
                }
            }
        }
    }
    
    @objc func video(_ videoPath: String, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        DispatchQueue.main.async {
            self.completionHandler?(error == nil, error)
            self.completionHandler = nil
        }
    }
}
