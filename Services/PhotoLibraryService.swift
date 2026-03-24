import Foundation
import Photos
import UIKit

class PhotoLibraryService: ObservableObject {
    func saveVideoToLibrary(url: URL, completion: @escaping (Bool, Error?) -> Void) {
        // 1. Check if source file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            DispatchQueue.main.async {
                completion(false, NSError(domain: "PhotoLibraryAccess", code: 404, userInfo: [NSLocalizedDescriptionKey: "Fichier source introuvable"]))
            }
            return
        }
        
        // 2. Copy the file to guarantee it's not locked by AVFoundation
        let safeURL = FileManager.default.temporaryDirectory.appendingPathComponent("safe_save_\(UUID().uuidString).mp4")
        do {
            try FileManager.default.copyItem(at: url, to: safeURL)
        } catch {
            DispatchQueue.main.async { completion(false, error) }
            return
        }
        
        // 3. Define the save action using modern API
        let saveAction = {
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: safeURL, options: nil)
            }) { success, error in
                // Cleanup the copy
                try? FileManager.default.removeItem(at: safeURL)
                
                DispatchQueue.main.async {
                    completion(success, error)
                }
            }
        }
        
        // 4. Request explicit permission to Add Photos
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                if status == .authorized || status == .limited {
                    saveAction()
                } else {
                    DispatchQueue.main.async {
                        completion(false, NSError(domain: "PhotoLibraryAccess", code: 401, userInfo: [NSLocalizedDescriptionKey: "Permission galerie refusée"]))
                    }
                }
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                if status == .authorized || status == .limited {
                    saveAction()
                } else {
                    DispatchQueue.main.async {
                        completion(false, NSError(domain: "PhotoLibraryAccess", code: 401, userInfo: [NSLocalizedDescriptionKey: "Permission galerie refusée"]))
                    }
                }
            }
        }
    }
}
