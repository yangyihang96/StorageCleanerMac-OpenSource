import Darwin
import XCTest
@testable import StorageCleanerMac

private func readyCloudState(_ path: String = "/fake/cloud/file") -> CloudLocalCopyState {
    CloudLocalCopyState(path: path, provider: .iCloud, supported: true, safe: true, identity: "device:inode",
        revision: "version", allocatedBytes: 8192, download: .current, uploaded: true, conflicts: false,
        uploading: false, downloading: false, excludedFromSync: false, syncError: false)
}
private func movedCloudState(_ value: CloudLocalCopyState, to path: String) -> CloudLocalCopyState {
    CloudLocalCopyState(path: path, provider: value.provider, supported: value.supported,
        safe: value.safe, identity: value.identity, revision: value.revision, allocatedBytes: value.allocatedBytes,
        download: value.download, uploaded: value.uploaded, conflicts: value.conflicts,
        uploading: value.uploading, downloading: value.downloading, excludedFromSync: value.excludedFromSync,
        syncError: value.syncError, unreadable: value.unreadable)
}

private actor FakeCloudCopyProvider: CloudLocalCopyProvider {
    enum Failure: Error { case evict, read }
    var states: [CloudLocalCopyState]
    var reads = 0
    var evicted: [String] = []
    var failEvict = false
    var failReadAt: Int?
    var failReadsFrom: Int?
    var cancellationGate = false
    var waiting: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    var onEvict: (@Sendable () async -> Void)?
    init(_ states: [CloudLocalCopyState], failEvict: Bool = false, failReadAt: Int? = nil, failReadsFrom: Int? = nil) {
        self.states = states; self.failEvict = failEvict; self.failReadAt = failReadAt; self.failReadsFrom = failReadsFrom
    }
    func state(at path: String) async throws -> CloudLocalCopyState {
        reads += 1
        if reads == failReadAt { throw Failure.read }
        if let failReadsFrom, reads >= failReadsFrom { throw Failure.read }
        return movedCloudState(states[min(reads - 1, states.count - 1)], to: path)
    }
    func evict(_ expected: CloudLocalCopyState) async throws {
        evicted.append(expected.path)
        await onEvict?()
        started?.resume(); started = nil
        if cancellationGate { await withCheckedContinuation { waiting = $0 } }
        if failEvict { throw Failure.evict }
    }
    func counts() -> (reads: Int, evicts: Int) { (reads, evicted.count) }
    func enableGate() { cancellationGate = true }
    func setOnEvict(_ body: @escaping @Sendable () async -> Void) { onEvict = body }
    func awaitStart() async {
        if !evicted.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { waiting?.resume(); waiting = nil }
}

/// Never answers until the test releases it: models a metadata read that hangs.
private actor HangingCloudCopyProvider: CloudLocalCopyProvider {
    var parked: [CheckedContinuation<Void, Never>] = []
    var released = false
    func state(at path: String) async throws -> CloudLocalCopyState {
        if !released { await withCheckedContinuation { parked.append($0) } }
        return readyCloudState(path)
    }
    func evict(_ expected: CloudLocalCopyState) async throws { XCTFail("no eviction in read tests") }
    func releaseAll() { released = true; parked.forEach { $0.resume() }; parked = [] }
}

/// Counts metadata reads and evictor calls; the evictor is a counter only, never the system API.
private final class NativeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var evicts = 0
    let metadata: CloudSyncMetadata
    init(_ metadata: CloudSyncMetadata) { self.metadata = metadata }
    func read(_ url: URL) throws -> CloudSyncMetadata { lock.lock(); reads += 1; lock.unlock(); return metadata }
    func evict(_ url: URL) throws { lock.lock(); evicts += 1; lock.unlock() }
    var counts: (reads: Int, evicts: Int) { lock.lock(); defer { lock.unlock() }; return (reads, evicts) }
    func provider(home: String) -> NativeCloudLocalCopyProvider {
        NativeCloudLocalCopyProvider(home: home, metadata: { try self.read($0) }, evictor: { try self.evict($0) })
    }
    static let readyICloud = CloudSyncMetadata(isUbiquitous: true, download: .current, uploaded: true, conflicts: false,
        uploading: false, downloading: false, excludedFromSync: false, syncError: false)
    static let local = CloudSyncMetadata(isUbiquitous: false)
}

final class CloudLocalCopyTests: XCTestCase {
    private func ready(_ path: String = "/fake/cloud/file") -> CloudLocalCopyState { readyCloudState(path) }
    private func placeholder(_ bytes: Int64 = 0) -> CloudLocalCopyState {
        var value = ready(); value.download = .placeholder; value.allocatedBytes = bytes; return value
    }
    private func service(_ provider: any CloudLocalCopyProvider, coordinator: HeavyWorkCoordinator? = nil) -> CloudLocalCopyService {
        CloudLocalCopyService(provider: provider, coordinator: coordinator, readbackInterval: .zero)
    }

    /// Isolated local fixture root (~/.storage-cleaner-cloudcopy-<UUID>, outside Library, Desktop,
    /// Documents and every cloud folder). The system temp directory is not used because Foundation
    /// standardizes /private/var paths to /var, which the native gate rightly rejects as changed.
    private func fixture() throws -> String {
        let root = TestFileSystem.uniqueOperationRoot("cloudcopy")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        guard let real = realpath(root.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(real) }
        return String(cString: real)
    }
    private func makeFile(_ path: String, bytes: Int = 16384) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(repeating: 7, count: bytes)))
    }

    // MARK: - Eligibility

    func testEligibilityRequiresAllPositiveSyncEvidence() {
        XCTAssertNil(ready().block)
        var value = ready(); value.download = .downloaded; XCTAssertNil(value.block)
        value = ready(); value.uploaded = false; XCTAssertEqual(value.block, .notUploaded)
        value = ready(); value.excludedFromSync = true; XCTAssertEqual(value.block, .notUploaded)
        value = ready(); value.conflicts = true; XCTAssertEqual(value.block, .conflict)
        value = ready(); value.uploading = true; XCTAssertEqual(value.block, .syncing)
        value = ready(); value.downloading = true; XCTAssertEqual(value.block, .syncing)
        value = ready(); value.syncError = true; XCTAssertEqual(value.block, .syncing)
        value = ready(); value.download = .unknown; XCTAssertEqual(value.block, .unknown)
        value = ready(); value.allocatedBytes = 0; XCTAssertEqual(value.block, .placeholder)
        XCTAssertEqual(placeholder(4096).block, .placeholder)
        value = ready(); value.safe = false; XCTAssertEqual(value.block, .unsafe)
        value = ready(); value.provider = .local; XCTAssertEqual(value.block, .notCloud)
        value = ready(); value.unreadable = true; XCTAssertEqual(value.block, .unreadable)
        for key in 0..<7 {
            value = ready()
            switch key {
            case 0: value.uploaded = nil
            case 1: value.conflicts = nil
            case 2: value.uploading = nil
            case 3: value.downloading = nil
            case 4: value.excludedFromSync = nil
            case 5: value.syncError = nil
            default: value.safe = nil
            }
            XCTAssertEqual(value.block, .unknown)
        }
    }

    /// Defaults are "no evidence": leaving any one field unset can never make a file selectable.
    func testDefaultStateIsUnknownNotPermitted() {
        XCTAssertEqual(CloudLocalCopyState(path: "/fake").block, .unknown)
        XCTAssertEqual(CloudLocalCopyState.unreadable("/fake").block, .unreadable)
        let setters: [(inout CloudLocalCopyState) -> Void] = [
            { $0.provider = .iCloud }, { $0.supported = true }, { $0.safe = true },
            { $0.allocatedBytes = 8192 }, { $0.download = .current }, { $0.uploaded = true },
            { $0.conflicts = false }, { $0.uploading = false }, { $0.downloading = false },
            { $0.excludedFromSync = false }, { $0.syncError = false }
        ]
        for omitted in setters.indices {
            var value = CloudLocalCopyState(path: "/fake")
            for index in setters.indices where index != omitted { setters[index](&value) }
            XCTAssertNotNil(value.block, "field \(omitted) left at its default must block selection")
        }
        var complete = CloudLocalCopyState(path: "/fake")
        setters.forEach { $0(&complete) }
        XCTAssertNil(complete.block)
    }

    func testExternalProvidersDegradeWithoutAnEviction() async {
        for name in ["OneDrive", "Google Drive", "Dropbox", "Other Provider"] {
            var value = ready(); value.provider = .external(name); value.supported = false
            XCTAssertEqual(value.block, .unsupported)
            let fake = FakeCloudCopyProvider([value])
            let result = await service(fake).release([value])
            XCTAssertEqual(result.items.first?.status, .blocked(.unsupported))
            let counts = await fake.counts(); XCTAssertEqual(counts.evicts, 0)
        }
        XCTAssertEqual(NativeCloudLocalCopyProvider.externalProviderName("/Users/fake/Library/CloudStorage/OneDrive-Personal/x"), "OneDrive")
        XCTAssertEqual(NativeCloudLocalCopyProvider.externalProviderName("/Users/fake/Library/CloudStorage/GoogleDrive-account/x"), "Google Drive")
        XCTAssertEqual(NativeCloudLocalCopyProvider.externalProviderName("/Users/fake/Library/CloudStorage/Dropbox/x"), "Dropbox")
        XCTAssertNil(NativeCloudLocalCopyProvider.externalProviderName("/fake/CloudStorage/local"))
    }

    // MARK: - Native gate (temporary local files only; the evictor is a counter)

    func testNativeGateRejectsUnsafeLocalFixtures() async throws {
        let root = try fixture()
        let probe = NativeProbe(NativeProbe.local)
        let native = probe.provider(home: root + "/home")
        let plain = root + "/plain/file.bin"
        try makeFile(plain)
        let plainState = try await native.state(at: plain)
        XCTAssertEqual(plainState.block, .notCloud)
        XCTAssertEqual(plainState.safe, true)
        XCTAssertGreaterThan(plainState.allocatedBytes, 0)

        let fileLink = root + "/plain/link.bin"
        try FileManager.default.createSymbolicLink(atPath: fileLink, withDestinationPath: plain)
        let fileLinkState = try await native.state(at: fileLink)
        XCTAssertEqual(fileLinkState.block, .unsafe, "a symlinked file itself is never eligible")

        try FileManager.default.createSymbolicLink(atPath: root + "/linkedDir", withDestinationPath: root + "/plain")
        let ancestorState = try await native.state(at: root + "/linkedDir/file.bin")
        XCTAssertEqual(ancestorState.block, .unsafe, "a symlinked ancestor directory is never eligible")

        let hard = root + "/plain/hard.bin"
        try FileManager.default.linkItem(atPath: plain, toPath: hard)
        let hardState = try await native.state(at: hard)
        XCTAssertEqual(hardState.block, .unsafe, "nlink > 1 is never eligible")
        try FileManager.default.removeItem(atPath: hard)

        let directoryState = try await native.state(at: root + "/plain")
        XCTAssertEqual(directoryState.block, .unsafe)
        let dottedState = try await native.state(at: root + "/plain/../plain/file.bin")
        XCTAssertEqual(dottedState.block, .unsafe)
        let relativeState = try await native.state(at: "plain/file.bin")
        XCTAssertEqual(relativeState.block, .unsafe)

        XCTAssertEqual(probe.counts.reads, 1, "only the plain regular file reaches the metadata reader")
        XCTAssertEqual(probe.counts.evicts, 0)
    }

    func testNativePlainLocalFileUsesSystemMetadataAndIsNotCloud() async throws {
        let root = try fixture()
        let plain = root + "/plain.bin"
        try makeFile(plain)
        // Default reader on a temporary local file; no evictor is reachable for a local file.
        let native = NativeCloudLocalCopyProvider(home: root + "/home", evictor: { _ in XCTFail("evict must not be reached") })
        let state = try await native.state(at: plain)
        XCTAssertEqual(state.block, .notCloud)
        do { try await native.evict(state); XCTFail("non-iCloud file must be rejected by the gate") }
        catch { XCTAssertTrue(error is CloudCopyGateError) }
    }

    func testCloudStorageReturnsUnsupportedWithoutReadingSyncMetadata() async throws {
        let root = try fixture()
        let probe = NativeProbe(NativeProbe.readyICloud)
        let native = probe.provider(home: root + "/home")
        let path = root + "/home/Library/CloudStorage/OneDrive-X/f"
        try makeFile(path)
        let state = try await native.state(at: path)
        XCTAssertEqual(state.provider, .external("OneDrive"))
        XCTAssertEqual(state.block, .unsupported)
        XCTAssertEqual(probe.counts.reads, 0, "CloudStorage must fail closed before any sync metadata read")
        do { try await native.evict(state); XCTFail("unsupported provider must be rejected") }
        catch { XCTAssertTrue(error is CloudCopyGateError) }
        XCTAssertEqual(probe.counts.evicts, 0)
    }

    func testOnlyPositivelyIdentifiedICloudLocationsAreSupported() async throws {
        let root = try fixture()
        let home = root + "/home"
        let probe = NativeProbe(NativeProbe.readyICloud)
        let native = probe.provider(home: home)
        let drive = home + "/Library/Mobile Documents/com~apple~CloudDocs/a.bin"
        let desktop = home + "/Desktop/b.bin"
        let elsewhere = root + "/Elsewhere/c.bin"
        for path in [drive, desktop, elsewhere] { try makeFile(path) }
        let driveState = try await native.state(at: drive)
        XCTAssertEqual(driveState.provider, .iCloud); XCTAssertNil(driveState.block)
        let desktopState = try await native.state(at: desktop)
        XCTAssertEqual(desktopState.provider, .iCloud); XCTAssertNil(desktopState.block)
        let otherState = try await native.state(at: elsewhere)
        XCTAssertNotEqual(otherState.provider, .iCloud)
        XCTAssertEqual(otherState.block, .unsupported, "ubiquitous outside iCloud locations is another provider")
        XCTAssertTrue(NativeCloudLocalCopyProvider.isICloudLocation(home + "/Documents/x", home: home, fileDevice: 1, homeDevice: 1))
        XCTAssertFalse(NativeCloudLocalCopyProvider.isICloudLocation(home + "/Documents/x", home: home, fileDevice: 2, homeDevice: 1))
        XCTAssertFalse(NativeCloudLocalCopyProvider.isICloudLocation(home + "/Desktop/x", home: home, fileDevice: 1, homeDevice: nil))
        XCTAssertFalse(NativeCloudLocalCopyProvider.isICloudLocation(home + "/Downloads/x", home: home, fileDevice: 1, homeDevice: 1))
        let unknownProbe = NativeProbe(CloudSyncMetadata(isUbiquitous: nil))
        let unknownNative = unknownProbe.provider(home: home)
        let unknownDrive = try await unknownNative.state(at: drive)
        XCTAssertEqual(unknownDrive.block, .unknown, "missing ubiquity evidence inside iCloud stays unknown")
        let unknownElsewhere = try await unknownNative.state(at: elsewhere)
        XCTAssertEqual(unknownElsewhere.block, .notCloud)
        XCTAssertEqual(probe.counts.evicts, 0)
    }

    func testNativeEvictGateRequiresSameIdentityAndRevision() async throws {
        let root = try fixture()
        let probe = NativeProbe(NativeProbe.readyICloud)
        let native = probe.provider(home: root + "/home")
        let path = root + "/home/Library/Mobile Documents/com~apple~CloudDocs/a.bin"
        try makeFile(path)
        let reviewed = try await native.state(at: path)
        XCTAssertNil(reviewed.block)
        var otherIdentity = reviewed; otherIdentity.identity = "0:0"
        var otherRevision = reviewed; otherRevision.revision = "0:0:0"
        for stale in [otherIdentity, otherRevision] {
            do { try await native.evict(stale); XCTFail("stale review must be rejected") }
            catch { XCTAssertTrue(error is CloudCopyGateError) }
        }
        XCTAssertEqual(probe.counts.evicts, 0)
        try await native.evict(reviewed)
        XCTAssertEqual(probe.counts.evicts, 1, "only the counting evictor runs; no system eviction in tests")
    }

    // MARK: - Service

    func testExecutionRecheckBlocksChangedSyncState() async {
        for reason in [CloudCopyBlock.notUploaded, .conflict, .syncing, .placeholder, .unknown] {
            var changed = ready()
            switch reason {
            case .notUploaded: changed.uploaded = false
            case .conflict: changed.conflicts = true
            case .syncing: changed.uploading = true
            case .placeholder: changed.download = .placeholder
            default: changed.uploaded = nil
            }
            let fake = FakeCloudCopyProvider([changed])
            let result = await service(fake).release([ready()])
            XCTAssertEqual(result.items.first?.status, .blocked(reason))
            let counts = await fake.counts(); XCTAssertEqual(counts.evicts, 0)
        }
    }
    func testExecutionRecheckRejectsReplacementAndLocalEdits() async {
        for key in 0..<3 {
            var changed = ready()
            if key == 0 { changed.identity = "other-inode" }
            if key == 1 { changed.revision = "changed-content" }
            if key == 2 { changed.provider = .external("Other") }
            let fake = FakeCloudCopyProvider([changed])
            let result = await service(fake).release([ready()])
            XCTAssertEqual(result.items.first?.status, .blocked(.unsafe))
            let counts = await fake.counts(); XCTAssertEqual(counts.evicts, 0)
        }
    }
    func testReadbackCountsActualDifferenceFromFreshState() async {
        var fresh = ready(); fresh.allocatedBytes = 12288
        let fake = FakeCloudCopyProvider([fresh, placeholder(4096)])
        let result = await service(fake).release([ready()])
        XCTAssertEqual(result.releasedBytes, 8192)
        XCTAssertEqual(result.items.first?.status, .released)
        let counts = await fake.counts(); XCTAssertEqual(counts.reads, 2); XCTAssertEqual(counts.evicts, 1)
    }
    func testBothPlaceholderAndDecreaseRequired() async {
        var decreased = ready(); decreased.allocatedBytes = 4096
        for after in [ready(), decreased, placeholder(8192), placeholder(16384)] {
            let result = await service(FakeCloudCopyProvider([ready(), after])).release([ready()])
            XCTAssertEqual(result.items.first?.status, .unchanged)
            XCTAssertEqual(result.releasedBytes, 0)
        }
    }
    func testReadbackRejectsReplacedFile() async {
        var replaced = placeholder(); replaced.identity = "replacement"
        let result = await service(FakeCloudCopyProvider([ready(), replaced])).release([ready()])
        XCTAssertEqual(result.items.first?.status, .unchanged); XCTAssertEqual(result.releasedBytes, 0)
    }
    func testReadbackRejectsUnsafePath() async {
        var unsafe = placeholder(); unsafe.safe = false
        let result = await service(FakeCloudCopyProvider([ready(), unsafe])).release([ready()])
        XCTAssertEqual(result.items.first?.status, .unchanged); XCTAssertEqual(result.releasedBytes, 0)
    }
    func testReadbackPollsBoundedTimesBeforeUnconfirmed() async {
        XCTAssertEqual(CloudLocalCopyService(provider: FakeCloudCopyProvider([ready()])).readbackAttempts, 3)
        XCTAssertEqual(CloudLocalCopyService(provider: FakeCloudCopyProvider([ready()])).readbackInterval, .milliseconds(500))
        let late = FakeCloudCopyProvider([ready(), ready(), ready(), placeholder(4096)])
        let confirmed = await service(late).release([ready()])
        XCTAssertEqual(confirmed.items.first?.status, .released, "third readback may confirm a lagging state")
        XCTAssertEqual(confirmed.releasedBytes, 4096)
        let never = FakeCloudCopyProvider([ready()])
        let unconfirmed = await service(never).release([ready()])
        XCTAssertEqual(unconfirmed.items.first?.status, .unchanged)
        let counts = await never.counts(); XCTAssertEqual(counts.reads, 4, "one recheck plus at most three readbacks")
    }
    func testFailuresAreClassifiedAndNeverEstimatedAsReleased() async {
        let evictFailure = await service(FakeCloudCopyProvider([ready()], failEvict: true)).release([ready()])
        XCTAssertEqual(evictFailure.items.first?.status, .failed); XCTAssertEqual(evictFailure.releasedBytes, 0)
        let readFailure = await service(FakeCloudCopyProvider([ready()], failReadsFrom: 2)).release([ready()])
        XCTAssertEqual(readFailure.items.first?.status, .readbackFailed); XCTAssertEqual(readFailure.releasedBytes, 0)
        let preFailure = await service(FakeCloudCopyProvider([ready()], failReadAt: 1)).release([ready()])
        XCTAssertEqual(preFailure.items.first?.status, .blocked(.unreadable)); XCTAssertEqual(preFailure.releasedBytes, 0)
        XCTAssertNotNil(preFailure.items.first?.detail)
    }
    func testBatchLimitRejectsEntireOverlimitBatchBeforeAnyRead() async {
        XCTAssertEqual(CloudLocalCopyService.batchLimit, 50)
        XCTAssertEqual(CloudLocalCopyService.reviewLimit, 200)
        let fake = FakeCloudCopyProvider([ready(), placeholder()])
        let selection = (0...CloudLocalCopyService.batchLimit).map { ready("/fake/\($0)") }
        let result = await service(fake).release(selection)
        XCTAssertEqual(result.items.count, 51); XCTAssertTrue(result.items.allSatisfy { $0.status == .limit })
        let counts = await fake.counts(); XCTAssertEqual(counts.reads, 0); XCTAssertEqual(counts.evicts, 0)
    }
    func testExactlyLimitAllowedAndDuplicatePathsNeverEvictedTwice() async {
        let fake = FakeCloudCopyProvider([ready(), placeholder()])
        let result = await service(fake).release(Array(repeating: ready(), count: 50))
        XCTAssertEqual(result.items.count, 1); XCTAssertEqual(result.releasedBytes, 8192)
        let counts = await fake.counts(); XCTAssertEqual(counts.evicts, 1)
    }
    func testCancellationFinishesAcceptedReadbackAndStopsNextItem() async {
        let fake = FakeCloudCopyProvider([ready(), placeholder()])
        await fake.enableGate()
        let selected = [ready(), ready("/fake/next")]
        let release = service(fake)
        let task = Task { await release.release(selected) }
        await fake.awaitStart()
        task.cancel()
        await fake.finish()
        let result = await task.value
        XCTAssertEqual(result.items.map(\.status), [.released, .cancelled])
        XCTAssertEqual(result.releasedBytes, 8192)
        let counts = await fake.counts(); XCTAssertEqual(counts.evicts, 1)
    }
    func testCancellationBeforeStartPerformsNoProviderOperation() async {
        let fake = FakeCloudCopyProvider([ready()])
        let selected = ready()
        let release = service(fake)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await release.release([selected])
        }
        let result = await task.value
        XCTAssertEqual(result.items.first?.status, .cancelled)
        let counts = await fake.counts(); XCTAssertEqual(counts.reads, 0); XCTAssertEqual(counts.evicts, 0)
    }
    func testSharedLeaseBlocksConcurrentCleanupAndReleasesAfterFailure() async throws {
        let coordinator = HeavyWorkCoordinator()
        let lease = try await coordinator.acquire(owner: .restore)
        let fake = FakeCloudCopyProvider([ready()], failEvict: true)
        let release = service(fake, coordinator: coordinator)
        let blocked = await release.release([ready()])
        XCTAssertEqual(blocked.items.first?.status, .busy)
        XCTAssertEqual(blocked.items.first?.detail, HeavyWorkActivityStore.conflictMessage(activeOwner: .restore))
        let counts = await fake.counts(); XCTAssertEqual(counts.evicts, 0)
        await coordinator.release(lease)
        let observed = OwnerBox()
        await fake.setOnEvict { await observed.set(await coordinator.activeOwner) }
        let failed = await release.release([ready()])
        XCTAssertEqual(failed.items.first?.status, .failed)
        let during = await observed.value
        XCTAssertEqual(during, .cloudLocalCopy, "the release holds its own labelled lease")
        let owner = await coordinator.activeOwner
        XCTAssertNil(owner)
    }
    @MainActor
    func testOwnLeaseShowsReleaseLabelAndReturnsToFileAnalysis() {
        XCTAssertEqual(HeavyWorkActivityStore.navigationDestination(for: .cloudLocalCopy), .review(.largeFiles))
        XCTAssertTrue(HeavyWorkActivityStore.conflictMessage(activeOwner: .cloudLocalCopy).contains(
            L10n.text("释放本地副本", "local copy release")))
        XCTAssertFalse(HeavyWorkActivityStore.conflictMessage(activeOwner: .cloudLocalCopy).contains(
            L10n.text("安全清理", "safe cleanup")))
    }

    // MARK: - Review list

    func testReviewSkipsKnownPlaceholdersBeforeTheCap() {
        func entry(_ index: Int, cloudOnly: Bool = false, directory: Bool = false) -> StorageTreemapEntry {
            StorageTreemapEntry(id: "\(index)", title: "\(index)", path: "/fake/\(index)", sizeBytes: 100, kind: "file",
                isDirectory: directory, isCloudOnly: cloudOnly)
        }
        let entries = (0..<20).map { entry($0, cloudOnly: true) } + [entry(900, directory: true)]
            + (0..<CloudLocalCopyService.reviewLimit).map { entry(1000 + $0) }
        let paths = CloudLocalCopyService.reviewCandidates(entries)
        XCTAssertEqual(paths.count, CloudLocalCopyService.reviewLimit)
        XCTAssertEqual(paths.first, "/fake/1000")
        XCTAssertEqual(paths.last, "/fake/\(1000 + CloudLocalCopyService.reviewLimit - 1)")
    }
    func testHangingMetadataReadTimesOutAsUnreadable() async {
        let hanging = HangingCloudCopyProvider()
        let done = expectation(description: "bounded read")
        let reader = Task {
            let states = await CloudLocalCopyService.readStates(["/fake/a", "/fake/b"], provider: hanging, timeout: .milliseconds(50))
            done.fulfill()
            return states
        }
        await fulfillment(of: [done], timeout: 10)
        // Let parked reads finish (late answers are ignored) so a broken timeout cannot hang the suite.
        await hanging.releaseAll()
        let states = await reader.value
        XCTAssertEqual(states.map(\.block), [.unreadable, .unreadable])
        XCTAssertEqual(CloudCopyBlock.unreadable.title, L10n.text("未能读取状态", "Could not read state"))
    }

    // MARK: - Text

    @MainActor
    func testReasonsFollowEnglishAndChinesePreference() {
        for language in [AppLanguage.english, .zhHans] {
            let preferences = TestVolatilePreferences()
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            let english = language == .english
            XCTAssertTrue(CloudCopyBlock.notUploaded.title.contains(english ? "Upload incomplete" : "未上传"))
            XCTAssertTrue(CloudCopyBlock.unsupported.title.contains(english ? "Remove Download" : "移除下载"))
            XCTAssertTrue(CloudCopyBlock.unsupported.title.contains(english ? "Finder" : "访达"))
            let gate = CloudCopyErrorText.describe(CloudCopyGateError.recheckFailed)
            XCTAssertTrue(gate.contains(english ? "Pre-release check failed" : "执行前复查未通过"))
            let system = CloudCopyErrorText.describe(NSError(domain: "com.example.fake", code: 42,
                userInfo: [NSLocalizedDescriptionKey: "Untranslated system prose"]))
            XCTAssertFalse(system.contains("Untranslated system prose"))
            XCTAssertTrue(system.contains(english ? "error code 42" : "错误代码 42"))
            let missing = CloudCopyErrorText.describe(CocoaError(.fileNoSuchFile))
            XCTAssertEqual(missing, english ? "The file no longer exists" : "文件已不存在")
            preferences.restore()
        }
    }
    func testNativeAdapterAndUIHaveNoDeletionOrDownloadPath() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let service = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Features/LargeFiles/Services/CloudLocalCopyService.swift"), encoding: .utf8)
        for forbidden in ["removeItem", "trashItem", "moveItem", "replaceItem", "unlink(", "rename(", "remove(", "truncate",
                          "open(", "NSFileCoordinator", "FileHandle", "Data(contentsOf:", "startDownloading", "localizedDescription"] {
            XCTAssertFalse(service.contains(forbidden), forbidden)
        }
        XCTAssertTrue(service.contains("FileManager.default.evictUbiquitousItem(at:"))
        let ui = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/FilesLightfield/CloudLocalCopyView.swift"), encoding: .utf8)
        for forbidden in ["removeItem", "trashItem", "moveItem", "replaceItem", "unlink(", "rename(", "NSFileCoordinator",
                          "FileHandle", "startDownloading", "evictUbiquitousItem", "localizedDescription"] {
            XCTAssertFalse(ui.contains(forbidden), forbidden)
        }
        XCTAssertTrue(ui.contains("guard !running, confirming, !chosen.isEmpty"))
        XCTAssertTrue(ui.contains("operation?.cancel()"))
        XCTAssertTrue(ui.contains(".disabled(state.block != nil"))
        XCTAssertTrue(ui.contains("service.release(selected)"))
        XCTAssertTrue(ui.contains("outcome.releasedBytes"))
        XCTAssertTrue(ui.contains("本地占用实测减少（逐文件分配大小）"))
        XCTAssertTrue(ui.contains("FeatureLightfieldPalette.resolve(scheme)"))
    }
}

private actor OwnerBox {
    var value: HeavyWorkCoordinator.Owner?
    func set(_ owner: HeavyWorkCoordinator.Owner?) { value = owner }
}
