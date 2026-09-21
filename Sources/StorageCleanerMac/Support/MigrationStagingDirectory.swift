import Foundation

/// Owns a private staging directory before a copy can leave partial output.
/// The caller must validate the selected volume and its parent path first.
struct MigrationStagingDirectory {
    let url: URL
    private let fileManager: FileManager

    init(parentURL: URL, fileManager: FileManager = .default) throws {
        guard parentURL.isFileURL else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let directory = parentURL.appendingPathComponent(
            ".storagecleaner-\(UUID().uuidString).partial", isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        self.url = directory
        self.fileManager = fileManager
    }

    /// Throws if the volume is gone or cleanup fails; never searches by prefix
    /// or removes any sibling directory.
    func remove() throws {
        try fileManager.removeItem(at: url)
    }
}
