import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct ImportedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let copiedURL = try RecordingManager.shared.importVideo(from: received.file)
            return Self(url: copiedURL)
        }
    }
}
