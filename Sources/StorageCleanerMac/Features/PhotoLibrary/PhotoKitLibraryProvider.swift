import AppKit
import Foundation
@preconcurrency import Photos

/// Construction is inert. All Photos calls follow an explicit user action.
actor PhotoKitLibraryProvider: PhotoLibraryProviding {
    static let reviewAlbumTitle = PhotoReviewAlbumCoordinator.reviewAlbumTitle
    private let albumCoordinator = PhotoReviewAlbumCoordinator(backend: PhotoKitAlbumAccess(), identity: .init(fileURL:
        AppDataDirectories.applicationSupportRoot.appendingPathComponent("PhotoLibrary/review-album-id.json")))
    private var assetIndexes: [String: Int] = [:]
    private var assets: PHFetchResult<PHAsset>?
    func authorization() -> PhotoLibraryAuthorization {
        guard PhotoLibraryAvailability.isEnabledInMainBundle else { return .restricted }
        return Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }
    func requestAuthorization() async -> PhotoLibraryAuthorization {
        let current = authorization()
        guard current == .notDetermined else { return current }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return Self.map(status)
    }
    private static func map(_ status: PHAuthorizationStatus) -> PhotoLibraryAuthorization {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }
    func begin(limit: Int) throws -> Int {
        guard authorization().canRead else { throw PhotoLibraryError.permission }
        let options = PHFetchOptions()
        options.fetchLimit = limit + 1 // One lookahead detects truncation without enumerating the whole library.
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        let result = PHAsset.fetchAssets(with: .image, options: options)
        assets = result
        return result.count
    }
    func batch(offset: Int, count: Int) throws -> [LibraryPhoto] {
        try Task.checkCancellation()
        guard authorization().canRead, let assets else { throw PhotoLibraryError.permission }
        guard offset >= 0, count > 0, offset < assets.count else { return [] }
        return try autoreleasepool {
            try (offset..<min(assets.count, offset + count)).map { index in
                try Task.checkCancellation()
                let asset = assets.object(at: index)
                assetIndexes[asset.localIdentifier] = index
                return LibraryPhoto(id: asset.localIdentifier, width: asset.pixelWidth, height: asset.pixelHeight,
                                    creationDate: asset.creationDate, modificationDate: asset.modificationDate,
                                    favorite: asset.isFavorite, edited: false)
            }
        }
    }
    func reviewMetadata(for photos: [LibraryPhoto]) throws -> [LibraryPhoto] {
        guard authorization().canRead else { throw PhotoLibraryError.permission }
        return try photos.map { photo in
            try Task.checkCancellation()
            guard let asset = asset(for: photo.id) else { return photo }
            // Resource types only, and only for review candidates, not every scanned asset.
            let edited = PHAssetResource.assetResources(for: asset).contains { $0.type == .adjustmentData }
            return LibraryPhoto(id: photo.id, width: photo.width, height: photo.height, creationDate: photo.creationDate,
                                modificationDate: photo.modificationDate, favorite: photo.favorite, edited: edited)
        }
    }
    private func asset(for identifier: String) -> PHAsset? {
        if let assets, let index = assetIndexes[identifier] { return assets.object(at: index) }
        return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }
    func finish() { assets = nil; assetIndexes.removeAll() }
    func thumbnail(for photo: LibraryPhoto, includePreview: Bool) async throws -> LibraryPhotoThumbnail? {
        try Task.checkCancellation()
        guard authorization().canRead else { throw PhotoLibraryError.permission }
        guard let asset = asset(for: photo.id) else { return nil }
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        options.resizeMode = .exact
        options.version = .current
        let request = PhotoThumbnailRequest(manager: manager)
        let timeout = Task { try? await Task.sleep(for: .seconds(10)); if !Task.isCancelled { request.resolve(nil) } }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                guard !Task.isCancelled else { request.cancel(); return }
                let id = manager.requestImage(for: asset, targetSize: CGSize(width: 96, height: 96),
                                              contentMode: .aspectFit, options: options) { image, info in
                    guard let image, (info?[PHImageCancelledKey] as? Bool) != true,
                          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          let signature = ImageSimilarity.signature(from: cgImage) else {
                        request.resolve(nil); return
                    }
                    // Scan hashing never encodes preview JPEGs. UI requests opt in separately.
                    let preview = includePreview ? NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) ?? Data() : Data()
                    request.resolve(.init(signature: signature, preview: preview))
                }
                request.setID(id)
            }
        } onCancel: { request.cancel() }
    }
    func addToReviewAlbum(identifiers: [String]) async throws -> Int {
        try await albumCoordinator.add(identifiers: identifiers, authorization: authorization())
    }

}

/// Callback, cancellation, timeout and synchronous callback-before-ID share one completion gate.
private final class PhotoThumbnailRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let manager: PHImageManager
    private var id: PHImageRequestID?
    private var continuation: CheckedContinuation<LibraryPhotoThumbnail?, any Error>?
    private var result: Result<LibraryPhotoThumbnail?, any Error>?
    init(manager: PHImageManager) { self.manager = manager }
    func install(_ continuation: CheckedContinuation<LibraryPhotoThumbnail?, any Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func setID(_ id: PHImageRequestID) {
        lock.lock(); self.id = id; let finished = result != nil; lock.unlock()
        if finished { manager.cancelImageRequest(id) }
    }
    func resolve(_ value: LibraryPhotoThumbnail?) { complete(.success(value)) }
    func cancel() { complete(.failure(CancellationError())) }
    private func complete(_ result: Result<LibraryPhotoThumbnail?, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation, id = self.id
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        if let id { manager.cancelImageRequest(id) }
    }
}

/// All framework calls remain in this file; orchestration uses the Foundation-only protocol.
private actor PhotoKitAlbumAccess: PhotoAlbumAccessing {
    private func requireFullAccess() throws {
        guard PhotoLibraryAvailability.isEnabledInMainBundle,
              PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { throw PhotoLibraryError.permission }
    }
    func accessibleIdentifiers(_ identifiers: [String]) throws -> Set<String> {
        try requireFullAccess()
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var ids = Set<String>()
        assets.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        return ids
    }
    func album(identifier: String) throws -> PhotoReviewAlbum? {
        try requireFullAccess()
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject,
              album.assetCollectionType == .album else { return nil }
        return .init(id: album.localIdentifier, title: album.localizedTitle ?? "")
    }
    func albums(title: String) throws -> [PhotoReviewAlbum] {
        try requireFullAccess()
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", title)
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        var matches: [PhotoReviewAlbum] = []
        albums.enumerateObjects { album, _, _ in matches.append(.init(id: album.localIdentifier, title: album.localizedTitle ?? "")) }
        return matches
    }
    func performAddition(identifiers: [String], album: PhotoReviewAlbum?, title: String) async throws -> PhotoReviewAlbum {
        try requireFullAccess()
        let selected = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard selected.count == identifiers.count else { throw PhotoLibraryError.unavailable }
        let existing = album.flatMap { PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [$0.id], options: nil).firstObject }
        guard album == nil || existing?.localizedTitle == title else { throw PhotoLibraryError.unavailable }
        let identifier = PhotoAlbumIdentifier()
        // Sole write path: create/reuse this album and add existing assets. No asset mutation request.
        try await PHPhotoLibrary.shared().performChanges {
            let change: PHAssetCollectionChangeRequest?
            if let existing {
                change = PHAssetCollectionChangeRequest(for: existing)
                identifier.set(existing.localIdentifier)
            } else {
                change = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                identifier.set(change?.placeholderForCreatedAssetCollection.localIdentifier)
            }
            change?.addAssets(selected)
        }
        guard let id = identifier.value() else { throw PhotoLibraryError.albumChangeFailed }
        return .init(id: id, title: title)
    }
    func members(in album: PhotoReviewAlbum) throws -> Set<String> {
        try requireFullAccess()
        guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.id], options: nil).firstObject,
              collection.localizedTitle == album.title else { throw PhotoLibraryError.albumChangeFailed }
        let members = PHAsset.fetchAssets(in: collection, options: nil)
        var ids = Set<String>()
        members.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        return ids
    }
}

private final class PhotoAlbumIdentifier: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: String?
    func set(_ value: String?) { lock.lock(); identifier = value; lock.unlock() }
    func value() -> String? { lock.lock(); defer { lock.unlock() }; return identifier }
}
