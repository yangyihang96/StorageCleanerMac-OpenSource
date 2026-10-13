import Foundation
import XCTest
@testable import StorageCleanerMac

private actor FakeAlbumAccess: PhotoAlbumAccessing {
    var accessible: Set<String> = ["a", "b"]
    var known: [PhotoReviewAlbum] = []
    var readback: Set<String> = ["a", "b"]
    var lookups: [String] = []
    var titleLookups: [String] = []
    var additions: [PhotoReviewAlbum?] = []
    var readbacks: [String] = []
    func accessibleIdentifiers(_ identifiers: [String]) -> Set<String> { accessible.intersection(identifiers) }
    func album(identifier: String) -> PhotoReviewAlbum? { lookups.append(identifier); return known.first { $0.id == identifier } }
    func albums(title: String) -> [PhotoReviewAlbum] { titleLookups.append(title); return known.filter { $0.title == title } }
    func performAddition(identifiers: [String], album: PhotoReviewAlbum?, title: String) -> PhotoReviewAlbum {
        additions.append(album)
        let result = album ?? PhotoReviewAlbum(id: "created-id", title: title)
        if album == nil { known.append(result) }
        return result
    }
    func members(in album: PhotoReviewAlbum) -> Set<String> { readbacks.append(album.id); return readback }
    func configure(known: [PhotoReviewAlbum] = [], accessible: Set<String> = ["a", "b"], readback: Set<String> = ["a", "b"]) {
        self.known = known; self.accessible = accessible; self.readback = readback
    }
    func calls() -> (ids: [String], titles: [String], additions: [PhotoReviewAlbum?], readbacks: [String]) {
        (lookups, titleLookups, additions, readbacks)
    }
}

final class PhotoLibraryRepairTests: XCTestCase, @unchecked Sendable {
    private let title = "存储清理助手-待删除"
    private func photo(_ id: String, seconds: TimeInterval = 100) -> LibraryPhoto {
        .init(id: id, width: 100, height: 100, creationDate: Date(timeIntervalSince1970: seconds),
              modificationDate: Date(timeIntervalSince1970: 200), favorite: false, edited: false)
    }
    private func signature(hash: UInt64 = 0, color: Double = 0.5) -> ImageSimilaritySignature {
        .init(differenceHash: hash, averageHash: hash, aspectRatio: 1, red: color, green: color, blue: color)
    }
    func testMissingUsageDescriptionHidesSourceBeforePhotosCalls() throws {
        XCTAssertFalse(PhotoLibraryAvailability.isEnabled(info: nil, entitlement: true))
        XCTAssertFalse(PhotoLibraryAvailability.isEnabled(info: [:], entitlement: true))
        XCTAssertFalse(PhotoLibraryAvailability.isEnabled(info: ["NSPhotoLibraryUsageDescription": true], entitlement: true))
        XCTAssertFalse(PhotoLibraryAvailability.isEnabled(info: ["NSPhotoLibraryUsageDescription": " \n"], entitlement: true))
        XCTAssertTrue(PhotoLibraryAvailability.isEnabled(info: ["NSPhotoLibraryUsageDescription": "Explain access"], entitlement: true))
        XCTAssertFalse(PhotoLibraryAvailability.isEnabled(info: ["NSPhotoLibraryUsageDescription": "Explain access"], entitlement: false))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"), encoding: .utf8)
        // The source switch (landing status action / result toolbar) and the
        // photo page itself are both gated on the bundle availability check.
        XCTAssertTrue(view.contains("guard isSimilarPhotosRoute, PhotoLibraryAvailability.isEnabledInMainBundle else { return nil }"))
        XCTAssertTrue(view.contains("if isSimilarPhotosRoute && usesSystemPhotoLibrary && PhotoLibraryAvailability.isEnabledInMainBundle {"))
        let provider = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Features/PhotoLibrary/PhotoKitLibraryProvider.swift"), encoding: .utf8)
        XCTAssertTrue(provider.contains("guard PhotoLibraryAvailability.isEnabledInMainBundle else { return .restricted }"))
    }
    func testMainAppSigningIncludesAndVerifiesOnlyPhotoEntitlement() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Resources/Signing/StorageCleanerMac.entitlements")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Bool])
        XCTAssertEqual(plist, ["com.apple.security.personal-information.photos-library": true])
        let script = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        // Beta-only entitlement on the main app; helpers never get --entitlements.
        XCTAssertTrue(script.contains("if [ \"$BETA_MODE\" -eq 1 ]; then\n  main_entitlement_args=(--entitlements \"$ROOT_DIR/Resources/Signing/StorageCleanerMac.entitlements\")"))
        XCTAssertTrue(script.contains("${main_entitlement_args[@]+\"${main_entitlement_args[@]}\"} --sign \"$SIGN_IDENTITY\" \"$APP_BUNDLE\""))
        for line in script.split(separator: "\n") where line.contains("codesign") && (line.contains("FAN_HELPER") || line.contains("FILE_HELPER")) {
            XCTAssertFalse(line.contains("--entitlements"), String(line))
        }
        // plistlib.load() seeks and fails on a pipe (review N-P0-1).
        XCTAssertTrue(script.contains("codesign -d --entitlements - --xml \"$1\""))
        XCTAssertTrue(script.contains("plistlib.loads(sys.stdin.buffer.read())"))
        XCTAssertFalse(script.contains("plistlib.load(sys.stdin"))
        XCTAssertTrue(script.contains("verify_photo_library_entitlement \"$APP_BUNDLE\""))
        XCTAssertTrue(script.contains("verify_photo_library_entitlement \"$bundle\""))
        // The usage string is inserted only after the pieced-together plist is closed;
        // plutil cannot edit the unfinished file (beta install failed this way).
        let closed = try XCTUnwrap(script.range(of: "cat >>\"$INFO_PLIST\" <<PLIST\n</dict>\n</plist>\nPLIST"))
        let insert = try XCTUnwrap(script.range(of: "no deletion, uploads, or cloud original downloads.' \"$INFO_PLIST\""))
        XCTAssertLessThan(closed.lowerBound, insert.lowerBound)
    }
    func testSourceSwitchRetainsStoreAndRefreshesOnActivation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"), encoding: .utf8)
        let view = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/FilesLightfield/PhotoLibraryLightfieldView.swift"), encoding: .utf8)
        XCTAssertTrue(page.contains("@StateObject private var photoLibrary = PhotoLibraryStore.live()"))
        XCTAssertTrue(page.contains("PhotoLibraryLightfieldView(model: photoLibrary)"))
        XCTAssertTrue(view.contains("@ObservedObject var model: PhotoLibraryStore"))
        XCTAssertFalse(view.contains("@StateObject"))
        XCTAssertTrue(view.contains(".onChange(of: scenePhase)"))
        XCTAssertTrue(view.contains("guard phase == .active, allowsLibraryAccess else { return }"))
    }
    func testSameSecondSameDimensionsDifferentThumbnailNeverFormsDuplicateGroup() throws {
        let input = [photo("a"), photo("b")]
        let output = try PhotoLibraryScanner.group(input, signatures: ["a": signature(color: 0), "b": signature(color: 1)])
        XCTAssertTrue(output.groups.isEmpty)
        let missing = try PhotoLibraryScanner.group(input, signatures: [:])
        XCTAssertTrue(missing.groups.isEmpty)
        let matching = try PhotoLibraryScanner.group(input, signatures: ["a": signature(), "b": signature()])
        XCTAssertEqual(matching.groups.first?.evidence, .metadata)
    }
    func testMetadataMismatchFallsBackToNearbySimilarity() throws {
        let input = [photo("a"), photo("b"), photo("c", seconds: 101)]
        let output = try PhotoLibraryScanner.group(input, signatures: ["a": signature(color: 0), "b": signature(color: 1), "c": signature(color: 0)])
        XCTAssertEqual(output.groups.count, 1)
        XCTAssertEqual(output.groups[0].evidence, .similar)
        XCTAssertEqual(Set(output.groups[0].photos.map(\.id)), ["a", "c"])
    }
    func testNewestPhotosAreProcessedFirstAndDistantDatesDoNotCompare() throws {
        let input = [photo("old", seconds: 1), photo("new", seconds: 100_000)]
        let separated = try PhotoLibraryScanner.group(input, signatures: ["old": signature(), "new": signature()])
        XCTAssertTrue(separated.groups.isEmpty); XCTAssertEqual(separated.comparisons, 0)
        let near = [photo("old", seconds: 1), photo("new", seconds: 2)]
        let output = try PhotoLibraryScanner.group(near, signatures: ["old": signature(), "new": signature()])
        XCTAssertEqual(output.groups.first?.photos.map(\.id), ["new", "old"])
    }
    func testOldMetadataBucketsCannotConsumeNewestSimilarityBudget() throws {
        let input = [photo("new-a", seconds: 1_000_000), photo("new-b", seconds: 1_000_001),
                     photo("old-a"), photo("old-b"), photo("old-c")]
        let hashes = ["new-a": signature(), "new-b": signature(), "old-a": signature(color: 0),
                      "old-b": signature(color: 1), "old-c": signature(color: 0.5)]
        let output = try PhotoLibraryScanner.group(input, signatures: hashes, comparisonLimit: 3)
        XCTAssertTrue(output.limited)
        XCTAssertTrue(output.groups.contains { Set($0.photos.map(\.id)) == ["new-a", "new-b"] })
        XCTAssertLessThanOrEqual(output.comparisons, 3)
    }
    func testTwentyThousandPhotosStayWithinWindowComparisonAndTimeBudgets() throws {
        let count = 20_000
        var photos: [LibraryPhoto] = []; var hashes: [String: ImageSimilaritySignature] = [:]
        var random: UInt64 = 0x3141592653589793
        for i in 0..<count {
            let id = String(i)
            photos.append(photo(id, seconds: Double(i) * 60))
            random ^= random << 13; random ^= random >> 7; random ^= random << 17
            hashes[id] = signature(hash: random)
        }
        let started = ContinuousClock.now
        let output = try PhotoLibraryScanner.group(photos, signatures: hashes)
        let elapsed = started.duration(to: .now)
        XCTAssertFalse(output.limited)
        XCTAssertLessThanOrEqual(output.comparisons, count * 64)
        XCTAssertLessThan(elapsed, .seconds(10))
        print("PhotoLibrary synthetic 20000: \(output.comparisons) comparisons, \(elapsed)")
    }
    func testAlbumReusesSavedIdentifierWithoutTitleLookup() async throws {
        let backend = FakeAlbumAccess(), identity = PhotoReviewAlbumIdentity()
        let saved = PhotoReviewAlbum(id: "saved", title: title)
        await backend.configure(known: [saved, .init(id: "user-same-name", title: title)])
        try await identity.save("saved")
        let coordinator = PhotoReviewAlbumCoordinator(backend: backend, identity: identity)
        let count = try await coordinator.add(identifiers: ["a", "b"], authorization: .authorized)
        XCTAssertEqual(count, 2)
        let calls = await backend.calls()
        XCTAssertEqual(calls.ids, ["saved"]); XCTAssertTrue(calls.titles.isEmpty)
        XCTAssertEqual(calls.additions, [saved]); XCTAssertEqual(calls.readbacks, ["saved"])
    }
    func testAlbumCreatesAndPersistsNewIdentifierThenReusesIt() async throws {
        let root = try TestFileSystem.makeHome(for: self), file = root.appendingPathComponent("album-id.json")
        let backend = FakeAlbumAccess(), identity = PhotoReviewAlbumIdentity(fileURL: file)
        let coordinator = PhotoReviewAlbumCoordinator(backend: backend, identity: identity)
        _ = try await coordinator.add(identifiers: ["a"], authorization: .authorized)
        let restored = PhotoReviewAlbumIdentity(fileURL: file)
        let persisted = await restored.value(); XCTAssertEqual(persisted, "created-id")
        let reopened = PhotoReviewAlbumCoordinator(backend: backend, identity: restored)
        _ = try await reopened.add(identifiers: ["b"], authorization: .authorized)
        let calls = await backend.calls()
        XCTAssertNil(calls.additions[0]); XCTAssertEqual(calls.additions[1]?.id, "created-id")
        XCTAssertEqual(calls.titles, [title]); XCTAssertEqual(calls.readbacks, ["created-id", "created-id"])
    }
    func testStaleAlbumIdentifierFallsBackToUniqueTitleAndAmbiguityRejectsWrite() async throws {
        let backend = FakeAlbumAccess(), identity = PhotoReviewAlbumIdentity()
        try await identity.save("stale")
        await backend.configure(known: [.init(id: "replacement", title: title)])
        let coordinator = PhotoReviewAlbumCoordinator(backend: backend, identity: identity)
        _ = try await coordinator.add(identifiers: ["a"], authorization: .authorized)
        let calls = await backend.calls()
        XCTAssertEqual(calls.ids, ["stale"]); XCTAssertEqual(calls.titles, [title])
        XCTAssertEqual(calls.additions.first.flatMap { $0 }?.id, "replacement")
        let ambiguous = FakeAlbumAccess()
        await ambiguous.configure(known: [.init(id: "one", title: title), .init(id: "two", title: title)])
        do { _ = try await PhotoReviewAlbumCoordinator(backend: ambiguous, identity: .init()).add(identifiers: ["a"], authorization: .authorized); XCTFail("Ambiguous album must reject") }
        catch PhotoLibraryError.albumChangeFailed {} catch { XCTFail("\(error)") }
        let blocked = await ambiguous.calls(); XCTAssertTrue(blocked.additions.isEmpty)
    }
    func testAlbumReadbackFailureNeverReportsSuccessAndKeepsCreatedID() async throws {
        let backend = FakeAlbumAccess(), identity = PhotoReviewAlbumIdentity()
        await backend.configure(readback: [])
        do { _ = try await PhotoReviewAlbumCoordinator(backend: backend, identity: identity).add(identifiers: ["a"], authorization: .authorized); XCTFail("Missing member must reject") }
        catch PhotoLibraryError.albumChangeFailed {} catch { XCTFail("\(error)") }
        let calls = await backend.calls(), id = await identity.value()
        XCTAssertEqual(calls.readbacks, ["created-id"]); XCTAssertEqual(id, "created-id")
    }
    func testPartiallyAccessibleSelectionRejectsBeforeLookupOrTransaction() async throws {
        let backend = FakeAlbumAccess()
        await backend.configure(accessible: ["a"])
        do { _ = try await PhotoReviewAlbumCoordinator(backend: backend, identity: .init()).add(identifiers: ["a", "b"], authorization: .authorized); XCTFail("Partial access must reject") }
        catch PhotoLibraryError.unavailable {} catch { XCTFail("\(error)") }
        let calls = await backend.calls()
        XCTAssertTrue(calls.ids.isEmpty); XCTAssertTrue(calls.titles.isEmpty); XCTAssertTrue(calls.additions.isEmpty)
    }
    func testLimitedAccessDisablesAlbumAddition() async throws {
        XCTAssertTrue(PhotoLibraryAuthorization.limited.canRead)
        XCTAssertFalse(PhotoLibraryAuthorization.limited.canAddToAlbum)
        let backend = FakeAlbumAccess()
        do { _ = try await PhotoReviewAlbumCoordinator(backend: backend, identity: .init()).add(identifiers: ["a"], authorization: .limited); XCTFail("Limited authorization must reject write") }
        catch PhotoLibraryError.permission {} catch { XCTFail("\(error)") }
        let calls = await backend.calls(); XCTAssertTrue(calls.additions.isEmpty)
    }
    func testRevocationCacheClearRemovesDiskAndMemory() async throws {
        let root = try TestFileSystem.makeHome(for: self), file = root.appendingPathComponent("cache.json")
        let cache = PhotoThumbnailHashCache(fileURL: file), photo = photo("a")
        await cache.insert(signature(), for: photo); try await cache.save(retaining: [photo])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try await cache.clear()
        let value = await cache.value(for: photo); XCTAssertNil(value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
