import Foundation

final class RecordingManager {
    static let shared = RecordingManager()

    enum ManagedVideoKind: String {
        case recordings
        case imports
        case exports
    }

    private let fileManager: FileManager
    private let rootDirectory: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootDirectory = fileManager.temporaryDirectory.appendingPathComponent("SpeedClimbCutCache", isDirectory: true)
        try? ensureDirectoryExists(at: rootDirectory)
    }

    func makeRecordingURL(fileExtension: String = "mov") throws -> URL {
        try makeManagedURL(kind: .recordings, fileExtension: fileExtension)
    }

    func importVideo(from sourceURL: URL) throws -> URL {
        let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let destinationURL = try makeManagedURL(kind: .imports, fileExtension: fileExtension)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    func makeExportURL(fileExtension: String = "mp4") throws -> URL {
        try makeManagedURL(kind: .exports, fileExtension: fileExtension)
    }

    func cleanup(url: URL?) {
        guard let url else { return }
        guard isManagedURL(url) else { return }
        try? fileManager.removeItem(at: url)
    }

    func cleanupAllManagedFiles() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for directoryURL in contents {
            try? fileManager.removeItem(at: directoryURL)
        }

        try? ensureDirectoryExists(at: rootDirectory)
    }

    func isManagedURL(_ url: URL) -> Bool {
        let managedPath = rootDirectory.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath == managedPath || candidatePath.hasPrefix(managedPath + "/")
    }

    private func makeManagedURL(kind: ManagedVideoKind, fileExtension: String) throws -> URL {
        let directoryURL = rootDirectory.appendingPathComponent(kind.rawValue, isDirectory: true)
        try ensureDirectoryExists(at: directoryURL)

        let sanitizedExtension = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return directoryURL.appendingPathComponent(UUID().uuidString).appendingPathExtension(sanitizedExtension)
    }

    private func ensureDirectoryExists(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
    }
}
