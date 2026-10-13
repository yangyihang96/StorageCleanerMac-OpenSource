import Foundation

struct PhotoReviewAlbum: Sendable, Equatable {
    let id: String
    let title: String
}
/// Replaceable transaction boundary: tests exercise all lookup/write/readback branches without PhotoKit.
protocol PhotoAlbumAccessing: Sendable {
    func accessibleIdentifiers(_ identifiers: [String]) async throws -> Set<String>
    func album(identifier: String) async throws -> PhotoReviewAlbum?
    func albums(title: String) async throws -> [PhotoReviewAlbum]
    func performAddition(identifiers: [String], album: PhotoReviewAlbum?, title: String) async throws -> PhotoReviewAlbum
    func members(in album: PhotoReviewAlbum) async throws -> Set<String>
}

actor PhotoReviewAlbumIdentity {
    private let fileURL: URL?
    private var loaded = false
    private var identifier: String?
    init(fileURL: URL? = nil) { self.fileURL = fileURL }
    func value() -> String? {
        if !loaded {
            loaded = true
            if let fileURL, let data = try? Data(contentsOf: fileURL), data.count < 4096 {
                identifier = try? JSONDecoder().decode(String.self, from: data)
            }
        }
        return identifier
    }
    func save(_ identifier: String) throws {
        self.identifier = identifier; loaded = true
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(identifier).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

actor PhotoReviewAlbumCoordinator {
    static let reviewAlbumTitle = "存储清理助手-待删除"
    private let backend: any PhotoAlbumAccessing
    private let identity: PhotoReviewAlbumIdentity
    private var adding = false
    init(backend: any PhotoAlbumAccessing, identity: PhotoReviewAlbumIdentity) {
        self.backend = backend; self.identity = identity
    }
    func add(identifiers: [String], authorization: PhotoLibraryAuthorization) async throws -> Int {
        guard authorization.canAddToAlbum else { throw PhotoLibraryError.permission }
        guard !adding else { throw PhotoLibraryError.albumChangeFailed }
        adding = true; defer { adding = false }
        try Task.checkCancellation()
        let unique = Array(Set(identifiers)).sorted()
        guard !unique.isEmpty else { return 0 }
        let accessible = try await backend.accessibleIdentifiers(unique)
        guard accessible == Set(unique) else { throw PhotoLibraryError.unavailable }
        var album: PhotoReviewAlbum?
        if let identifier = await identity.value() {
            let saved = try await backend.album(identifier: identifier)
            if saved?.title == Self.reviewAlbumTitle { album = saved }
        }
        if album == nil {
            let matches = try await backend.albums(title: Self.reviewAlbumTitle)
            guard matches.count <= 1 else { throw PhotoLibraryError.albumChangeFailed }
            album = matches.first
        }
        try Task.checkCancellation()
        let updated = try await backend.performAddition(identifiers: unique, album: album, title: Self.reviewAlbumTitle)
        guard updated.title == Self.reviewAlbumTitle else { throw PhotoLibraryError.albumChangeFailed }
        // Save newly created placeholder ID before readback, so a failed verification cannot lose identity.
        try await identity.save(updated.id)
        let members = try await backend.members(in: updated)
        guard Set(unique).isSubset(of: members) else { throw PhotoLibraryError.albumChangeFailed }
        return unique.count
    }
}
