import Foundation
import XCTest
@testable import StorageCleanerMac

private actor FakePhotoLibrary: PhotoLibraryProviding {
    var status: PhotoLibraryAuthorization
    var requested = 0
    var beginCalls = 0
    var batchCalls = 0
    var thumbnailCalls = 0
    var finished = 0
    var albumCalls: [[String]] = []
    var albumNames: [String] = []
    let photos: [LibraryPhoto]
    let signatures: [String: ImageSimilaritySignature]
    var thumbnailDelay = false
    init(status: PhotoLibraryAuthorization = .authorized, photos: [LibraryPhoto] = [], signatures: [String: ImageSimilaritySignature]? = nil) {
        self.status = status; self.photos = photos; self.signatures = signatures ?? Dictionary(uniqueKeysWithValues: photos.map { ($0.id, ImageSimilaritySignature(differenceHash: 0, averageHash: 0, aspectRatio: 1, red: 0.5, green: 0.5, blue: 0.5)) })
    }
    func authorization() -> PhotoLibraryAuthorization { status }
    func requestAuthorization() -> PhotoLibraryAuthorization {
        if status == .notDetermined { requested += 1; status = .authorized }; return status
    }
    func begin(limit: Int) -> Int { beginCalls += 1; return photos.count }
    func batch(offset: Int, count: Int) -> [LibraryPhoto] {
        batchCalls += 1
        return Array(photos.dropFirst(offset).prefix(count))
    }
    func thumbnail(for photo: LibraryPhoto, includePreview: Bool) async throws -> LibraryPhotoThumbnail? {
        thumbnailCalls += 1
        if thumbnailDelay { try await Task.sleep(for: .seconds(30)) }
        return signatures[photo.id].map { .init(signature: $0, preview: Data()) }
    }
    func finish() { finished += 1 }
    func addToReviewAlbum(identifiers: [String]) -> Int {
        albumCalls.append(identifiers); albumNames.append(PhotoKitLibraryProvider.reviewAlbumTitle); return identifiers.count
    }
    func enableDelay() { thumbnailDelay = true }
    func setStatus(_ status: PhotoLibraryAuthorization) { self.status = status }
    func counts() -> (begin: Int, batches: Int, thumbnails: Int, finish: Int, requests: Int) {
        (beginCalls, batchCalls, thumbnailCalls, finished, requested)
    }
    func writes() -> ([[String]], [String]) { (albumCalls, albumNames) }
}

final class PhotoLibraryTests: XCTestCase, @unchecked Sendable {
    private func photo(_ id: String, date: Date? = Date(timeIntervalSince1970: 100), width: Int = 100,
                       favorite: Bool = false, edited: Bool = false, modification: Date? = Date(timeIntervalSince1970: 200),
                       size: Int64? = nil, fingerprint: String? = nil) -> LibraryPhoto {
        .init(id: id, width: width, height: 100, creationDate: date, modificationDate: modification,
              favorite: favorite, edited: edited, fileSize: size, resourceFingerprint: fingerprint)
    }
    private func signature(hash: UInt64 = 0, average: UInt64 = 0, aspect: Double = 1, color: Double = 0.5) -> ImageSimilaritySignature {
        .init(differenceHash: hash, averageHash: average, aspectRatio: aspect, red: color, green: color, blue: color)
    }
    private func cache() throws -> PhotoThumbnailHashCache {
        let root = try TestFileSystem.makeHome(for: self)
        return .init(fileURL: root.appendingPathComponent("photo-cache.json"))
    }
    func testDuplicateEvidenceLevelsDoNotConfuseMetadataWithContent() throws {
        let input = [photo("a"), photo("b"), photo("c", size: 12), photo("d", size: 12),
                     photo("e", fingerprint: "digest"), photo("f", fingerprint: "digest")]
        let groups = try PhotoLibraryScanner.group(input, signatures: Dictionary(uniqueKeysWithValues: input.map { ($0.id, signature()) })).groups
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].evidence, .metadata)
        XCTAssertEqual(groups[1].evidence, .sizeAndDate)
        XCTAssertEqual(groups[2].evidence, .contentFingerprint)
    }
    func testUnknownDatesAndDifferentDimensionsDoNotConfirmDuplicates() throws {
        let groups = try PhotoLibraryScanner.group([photo("a", date: nil), photo("b", date: nil),
                                                   photo("c"), photo("d", width: 200)], signatures: [:]).groups
        XCTAssertTrue(groups.isEmpty)
    }
    func testSimilarGroupsUseSharedThresholdAndNoTransitiveChain() throws {
        let input = [photo("a", date: nil), photo("b", date: nil), photo("c", date: nil)]
        let groups = try PhotoLibraryScanner.group(input, signatures: ["a": signature(), "b": signature(hash: 0x3ff), "c": signature(hash: 0xfffff)]).groups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].photos.map(\.id), ["a", "b"])
        XCTAssertEqual(groups[0].evidence, .similar)
    }
    func testComparisonBudgetMarksIncompleteRatherThanBlocking() throws {
        let input = [photo("a", date: nil), photo("b", date: nil), photo("c", date: nil)]
        let output = try PhotoLibraryScanner.group(input, signatures: ["a": signature(color: 0), "b": signature(color: 1), "c": signature(color: 0.5)], comparisonLimit: 1)
        XCTAssertTrue(output.limited)
        XCTAssertTrue(output.groups.isEmpty)
        XCTAssertGreaterThanOrEqual(PhotoLibraryScanner.comparisonBudget, PhotoLibraryScanner.maximumPhotos * 64)
    }
    func testSharedSimilarityRejectsHashAspectAndColorOutsideThreshold() {
        XCTAssertNotNil(ImageSimilarity.score(signature(), signature(hash: 0x3ff)))
        XCTAssertNil(ImageSimilarity.score(signature(), signature(hash: 0x7ff)))
        XCTAssertNil(ImageSimilarity.score(signature(), signature(average: 0x7ff)))
        XCTAssertNil(ImageSimilarity.score(signature(), signature(aspect: 1.2)))
        XCTAssertNil(ImageSimilarity.score(signature(), signature(color: 0.9)))
        XCTAssertNotNil(ImageSimilarity.score(signature(), signature(hash: 0x3ff, average: 0x3ff, color: 0.66)))
        XCTAssertNil(ImageSimilarity.score(signature(), signature(hash: 0x3ff, average: 0x3ff, color: 0.70)))
    }
    func testKeeperOrdersFavoriteResolutionEditedEarlierAndStableIdentity() {
        XCTAssertEqual(PhotoLibraryScanner.preferredKeeper([photo("a", favorite: true), photo("b", width: 200)]).id, "a")
        XCTAssertEqual(PhotoLibraryScanner.preferredKeeper([photo("a", edited: true), photo("b", favorite: true)]).id, "b")
        // Resolution alone decides (both orders, so a reversed comparison or a
        // stable-identity fallback cannot pass), and it outranks edited/earlier.
        XCTAssertEqual(PhotoLibraryScanner.preferredKeeper([photo("a"), photo("b", width: 200)]).id, "b")
        XCTAssertEqual(PhotoLibraryScanner.preferredKeeper([photo("b", width: 200), photo("a")]).id, "b")
        XCTAssertEqual(PhotoLibraryScanner.preferredKeeper([photo("a", date: Date(timeIntervalSince1970: 1), edited: true),
                                                            photo("b", width: 200)]).id, "b")
        XCTAssertEqual(PhotoLibraryScanner.preferredKeeper([photo("a"), photo("b", edited: true)]).id, "b")
        XCTAssertEqual(PhotoLibraryScanner.preferredKeeper([photo("a", date: nil), photo("b")]).id, "b")
        XCTAssertEqual(PhotoLibraryScanner.preferredKeeper([photo("b"), photo("a")]).id, "a")
        XCTAssertEqual(PhotoLibraryScanner.preferredKeeper([photo("a"), photo("b", date: Date(timeIntervalSince1970: 99))]).id, "b")
    }
    func testDeniedRestrictedAndUndeterminedNeverEnumerate() async throws {
        for status in [PhotoLibraryAuthorization.denied, .restricted, .notDetermined] {
            let provider = FakePhotoLibrary(status: status)
            do { _ = try await PhotoLibraryScanner(provider: provider, cache: cache()).scan(); XCTFail("Expected permission rejection") }
            catch PhotoLibraryError.permission {} catch { XCTFail("Unexpected error: \(error)") }
            let counts = await provider.counts()
            XCTAssertEqual(counts.begin, 0); XCTAssertEqual(counts.requests, 0)
        }
    }
    func testLimitedAndAuthorizedReadOnlyScan() async throws {
        for status in [PhotoLibraryAuthorization.limited, .authorized] {
            let provider = FakePhotoLibrary(status: status, photos: [photo("a"), photo("b")])
            let result = try await PhotoLibraryScanner(provider: provider, cache: cache()).scan()
            XCTAssertEqual(result.processed, 2)
            let writes = await provider.writes(); XCTAssertTrue(writes.0.isEmpty)
        }
    }
    func testCapTruncatesWithoutRequestingExtraThumbnails() async throws {
        let provider = FakePhotoLibrary(photos: (0..<405).map { photo(String($0), date: nil) })
        let output = try await PhotoLibraryScanner(provider: provider, cache: cache()).scan(limit: 401)
        XCTAssertEqual(output.processed, 401); XCTAssertTrue(output.truncated)
        let counts = await provider.counts()
        XCTAssertEqual(counts.batches, 3); XCTAssertEqual(counts.thumbnails, 401)
        XCTAssertEqual(PhotoLibraryScanner.maximumPhotos, 50_000)
    }
    func testCancellationFinishesProviderWithoutPublishingResults() async throws {
        let provider = FakePhotoLibrary(photos: [photo("a")]); await provider.enableDelay()
        let scanner = PhotoLibraryScanner(provider: provider, cache: try cache())
        let task = Task { try await scanner.scan() }
        for _ in 0..<10_000 { if await provider.counts().thumbnails > 0 { break }; await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must throw") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let counts = await provider.counts(); XCTAssertEqual(counts.finish, 1)
    }
    func testCacheInvalidatesOnModificationAndUnknownDateIsNeverCached() async throws {
        let cache = try cache(), original = photo("a"), changed = photo("a", modification: Date(timeIntervalSince1970: 201))
        await cache.insert(signature(), for: original)
        let hit = await cache.value(for: original), miss = await cache.value(for: changed)
        XCTAssertNotNil(hit); XCTAssertNil(miss)
        let unknown = photo("unknown", modification: nil)
        await cache.insert(signature(), for: unknown)
        let unknownHit = await cache.value(for: unknown); XCTAssertNil(unknownHit)
    }
    func testCacheSeparatesIdentifiers() async throws {
        let cache = try cache()
        await cache.insert(signature(), for: photo("a"))
        let other = await cache.value(for: photo("b")); XCTAssertNil(other)
    }
    func testCachePersistsAndScanReusesHashes() async throws {
        let root = try TestFileSystem.makeHome(for: self), file = root.appendingPathComponent("cache.json")
        let photo = photo("a"), cache = PhotoThumbnailHashCache(fileURL: file)
        await cache.insert(signature(), for: photo); try await cache.save(retaining: [photo])
        let restored = PhotoThumbnailHashCache(fileURL: file)
        let provider = FakePhotoLibrary(photos: [photo])
        _ = try await PhotoLibraryScanner(provider: provider, cache: restored).scan()
        let counts = await provider.counts(); XCTAssertEqual(counts.thumbnails, 0)
    }
    @MainActor
    func testStoreOnlyAddsSelectedNonKeeperToSpecifiedAlbumNeverDeletes() async throws {
        let provider = FakePhotoLibrary(photos: [photo("a"), photo("b")])
        let store = PhotoLibraryStore(provider: provider, cache: try cache())
        store.scan(); await waitUntilIdle(store)
        XCTAssertTrue(store.selectedIDs.isEmpty)
        let group = try XCTUnwrap(store.result?.groups.first)
        store.selectedIDs = ["a", "b", "foreign"]
        store.addSelectedToAlbum(); await waitUntilIdle(store)
        let writes = await provider.writes()
        XCTAssertEqual(writes.0, [["b"]]); XCTAssertEqual(writes.1, ["存储清理助手-待删除"])
        XCTAssertEqual(group.keeperID, "a")
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertTrue(store.message?.contains("30") == true)
    }
    @MainActor
    func testAuthorizationRequestOnlyOnExplicitActionAndNeverRepeatedAfterDenial() async throws {
        let provider = FakePhotoLibrary(status: .denied)
        let store = PhotoLibraryStore(provider: provider, cache: try cache())
        await store.refreshAuthorization(); store.authorize(); await waitUntilIdle(store)
        let counts = await provider.counts(); XCTAssertEqual(counts.requests, 0)
        XCTAssertEqual(store.authorization, .denied)
        XCTAssertFalse(store.authorization.canRead)
        XCTAssertTrue(PhotoLibraryAuthorization.allCases.allSatisfy { !$0.message.isEmpty })
    }
    @MainActor
    func testRevokedPermissionPreventsAlbumWriteAndClearsResult() async throws {
        let provider = FakePhotoLibrary(photos: [photo("a"), photo("b")])
        let root = try TestFileSystem.makeHome(for: self), file = root.appendingPathComponent("revoked-cache.json")
        let store = PhotoLibraryStore(provider: provider, cache: .init(fileURL: file))
        store.scan(); await waitUntilIdle(store); store.selectedIDs = ["b"]
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await provider.setStatus(.denied)
        store.addSelectedToAlbum(); await waitUntilIdle(store)
        let writes = await provider.writes(); XCTAssertTrue(writes.0.isEmpty)
        XCTAssertNil(store.result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    @MainActor
    func testLimitedStoreBlocksAlbumButtonAndAction() async throws {
        let provider = FakePhotoLibrary(status: .limited, photos: [photo("a"), photo("b")])
        let store = PhotoLibraryStore(provider: provider, cache: try cache())
        store.scan(); await waitUntilIdle(store); store.selectedIDs = ["b"]
        XCTAssertEqual(store.authorization, .limited)
        store.addSelectedToAlbum(); await waitUntilIdle(store)
        let writes = await provider.writes(); XCTAssertTrue(writes.0.isEmpty)
        XCTAssertFalse(store.authorization.canAddToAlbum)
    }
    @MainActor
    func testExplicitAuthorizationOnceAndKeeperCannotBeSelected() async throws {
        let provider = FakePhotoLibrary(status: .notDetermined, photos: [photo("a"), photo("b")])
        let store = PhotoLibraryStore(provider: provider, cache: try cache())
        await store.refreshAuthorization()
        let initial = await provider.counts(); XCTAssertEqual(initial.requests, 0)
        store.authorize(); await waitUntilIdle(store)
        store.authorize(); await waitUntilIdle(store)
        let counts = await provider.counts(); XCTAssertEqual(counts.requests, 1)
        store.scan(); await waitUntilIdle(store)
        let group = try XCTUnwrap(store.result?.groups.first)
        store.toggle(group.photos[0], in: group); XCTAssertTrue(store.selectedIDs.isEmpty)
        store.toggle(group.photos[1], in: group); XCTAssertEqual(store.selectedIDs, ["b"])
        store.keep(group.photos[1], in: group); XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertEqual(store.keepers[group.id], "b")
    }
    func testProductionSourceHasOnlyAlbumAdditionAndLocalSmallThumbnailRequests() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Features/PhotoLibrary/PhotoKitLibraryProvider.swift"), encoding: .utf8)
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
        var inspected = 0
        for case let url as URL in files where ["swift", "m", "mm", "h", "c"].contains(url.pathExtension) {
            inspected += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for forbidden in ["removeAssets", "deleteAssetCollections", "requestContentEditingInput", "requestAVAsset", ".highQualityFormat", "PHAssetChangeRequest", "deleteAssets", "requestImageData"] {
                XCTAssertFalse(text.contains(forbidden), url.lastPathComponent + ": " + forbidden)
            }
            if text.range(of: #"\bimport\s+Photos\b"#, options: .regularExpression) != nil {
                // D106: the acceptance display confinement also imports Photos,
                // only to hold back the first permission prompt of a confined
                // launch; it must never reach the library itself (was: only
                // PhotoKitLibraryProvider.swift imports Photos).
                if url.lastPathComponent == "DisplayConfinement.swift" {
                    for libraryAccess in ["PHAsset", "PHFetch", "PHImageManager", "PHCachingImageManager", "performChanges"] {
                        XCTAssertFalse(text.contains(libraryAccess), url.lastPathComponent + ": " + libraryAccess)
                    }
                } else {
                    XCTAssertEqual(url.standardizedFileURL, root.appendingPathComponent("Sources/StorageCleanerMac/Features/PhotoLibrary/PhotoKitLibraryProvider.swift").standardizedFileURL)
                }
            }
        }
        XCTAssertGreaterThan(inspected, 100)
        XCTAssertFalse(source.contains("requestData"))
        XCTAssertFalse(source.contains("value(forKey:"))
        XCTAssertFalse(source.contains(".location"))
        XCTAssertTrue(source.contains("options.includeHiddenAssets = false"))
        XCTAssertTrue(source.contains("ascending: false"))
        XCTAssertTrue(source.contains("includePreview ? NSBitmapImageRep"))
        XCTAssertTrue(source.contains("assetIndexes[identifier]"))
        XCTAssertTrue(source.contains("options.isNetworkAccessAllowed = false"))
        XCTAssertTrue(source.contains("CGSize(width: 96, height: 96)"))
        XCTAssertTrue(source.contains("change?.addAssets(selected)"))
        XCTAssertTrue(source.contains("authorizationStatus(for: .readWrite)"))
        XCTAssertTrue(source.contains("guard current == .notDetermined else"))
    }
    @MainActor private func waitUntilIdle(_ store: PhotoLibraryStore) async {
        for _ in 0..<100_000 { if !store.busy { return }; await Task.yield() }
        XCTFail("Fake library task did not complete")
    }
}
