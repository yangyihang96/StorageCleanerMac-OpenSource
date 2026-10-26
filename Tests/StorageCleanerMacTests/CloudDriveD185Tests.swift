import Combine
import Darwin
import XCTest
@testable import StorageCleanerMac

/// Native D90 rejects /var symlink ancestors. Keep UUID temporary fixtures in this
/// worktree's scratch directory, without weakening that production safety check.
private func d185Home(_ test: XCTestCase) throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent(".build/d185-fixtures")
        .appendingPathComponent(TestFileSystem.uniqueRoot("d185").lastPathComponent)
    test.addTeardownBlock { TestFileSystem.remove(root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func d185File(_ home: URL, _ relative: String) throws -> URL {
    let file = home.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 7, count: 16384)))
    return file
}

private final class D185ScanProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [String] = []
    private var updates: [CloudDriveScanner.Progress] = []
    let values: [String: CloudDriveScanner.Metadata]
    let failures: Set<String>
    let cancelAfter: Int?
    let flag: CloudScanCancelFlag

    init(_ values: [String: CloudDriveScanner.Metadata] = [:], failures: Set<String> = [],
         cancelAfter: Int? = nil, flag: CloudScanCancelFlag = CloudScanCancelFlag()) {
        self.values = values; self.failures = failures; self.cancelAfter = cancelAfter; self.flag = flag
    }
    func read(_ url: URL) throws -> CloudDriveScanner.Metadata {
        let count = lock.withLock { reads.append(url.path); return reads.count }
        if count == cancelAfter { flag.cancel() }
        if failures.contains(url.lastPathComponent) { throw CocoaError(.fileReadNoPermission) }
        return values[url.lastPathComponent] ?? .init(isRegularFile: true, isSymbolicLink: false,
                                                     totalFileAllocatedSize: 4096, fileSize: 1000)
    }
    func progress(_ update: CloudDriveScanner.Progress) { lock.withLock { updates.append(update) } }
    var paths: [String] { lock.withLock { reads } }
    var progressValues: [CloudDriveScanner.Progress] { lock.withLock { updates } }
}

final class CloudDriveProviderTests: XCTestCase {
    func testProviderKindsAccountsHiddenFoldersAndSharedRecognition() throws {
        let home = try d185Home(self)
        let names = ["GoogleDrive-one@example.com", "GoogleDrive-two-work@example.com", "OneDrive-Personal",
                     "OneDrive-中文公司-研发", "Dropbox", "Dropbox-Work", "Box-Team", "Acme-Work",
                     ".GoogleDrive-hidden", "GoogleDriveLookalike-other"]
        let root = home.appendingPathComponent("Library/CloudStorage")
        for name in names {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        _ = try d185File(home, "Library/CloudStorage/not-a-folder")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("OneDrive-Link"),
                                                   withDestinationURL: root.appendingPathComponent("OneDrive-Personal"))
        let providers = CloudDriveScanner.otherProviders(home: home)
        XCTAssertEqual(providers.count, 9)
        XCTAssertEqual(providers.map(\.path), names.filter { !$0.hasPrefix(".") }.sorted().map { root.appendingPathComponent($0).path })
        let expected: [String: (CloudDriveScanner.ProviderKind, String, String)] = [
            "GoogleDrive-one@example.com": (.googleDrive, "Google Drive", "one@example.com"),
            "GoogleDrive-two-work@example.com": (.googleDrive, "Google Drive", "two-work@example.com"),
            "OneDrive-Personal": (.oneDrive, "OneDrive", "Personal"),
            "OneDrive-中文公司-研发": (.oneDrive, "OneDrive", "中文公司-研发"),
            "Dropbox": (.dropbox, "Dropbox", ""), "Dropbox-Work": (.dropbox, "Dropbox", "Work"),
            "Box-Team": (.box, "Box", "Team"), "Acme-Work": (.other, "Acme", "Work"),
            "GoogleDriveLookalike-other": (.other, "GoogleDriveLookalike", "other")
        ]
        for provider in providers {
            let value = try XCTUnwrap(expected[URL(fileURLWithPath: provider.path).lastPathComponent])
            XCTAssertEqual(provider.kind, value.0)
            XCTAssertEqual(provider.name, value.1)
            XCTAssertEqual(provider.account, value.2)
            for path in [provider.path, provider.path + "/sub/file"] {
                XCTAssertEqual(NativeCloudLocalCopyProvider.externalProviderName(path), provider.name)
            }
        }
    }

    func testDiscoveryDoesNotDescendAndMissingCloudStorageIsEmpty() throws {
        let home = try d185Home(self)
        XCTAssertTrue(CloudDriveScanner.otherProviders(home: home).isEmpty)
        let nested = home.appendingPathComponent("Library/CloudStorage/OneDrive-Personal/inaccessible")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(nested.path, 0), 0)
        defer { XCTAssertEqual(chmod(nested.path, 0o700), 0) }
        XCTAssertEqual(CloudDriveScanner.otherProviders(home: home).map(\.account), ["Personal"])
    }
}

final class CloudDriveD185Tests: XCTestCase {
    private func provider(_ home: URL, _ name: String = "GoogleDrive-test@example.com") -> CloudDriveScanner.Provider {
        .init(folderName: name, path: home.appendingPathComponent("Library/CloudStorage/" + name).path)
    }
    private func scan(_ provider: CloudDriveScanner.Provider, _ probe: D185ScanProbe, limit: Int = CloudDriveScanner.itemLimit) -> CloudDriveSnapshot {
        CloudDriveScanner.scan(provider: provider, limit: limit, metadata: probe.read,
                               isCancelled: { probe.flag.isCancelled }, progress: probe.progress)
    }

    func testMetadataAccountingSkipsHiddenLinksAndUnreadableItems() throws {
        let home = try d185Home(self)
        let provider = provider(home)
        let root = URL(fileURLWithPath: provider.path)
        for name in ["local", "fallback", "cloud", "empty", "denied", ".hidden", ".hiddenFolder/inside"] {
            _ = try d185File(root, name)
        }
        let outside = try d185File(home, "outside/never")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dirLink"), withDestinationURL: outside.deletingLastPathComponent())
        let date = Date(timeIntervalSince1970: 1234)
        let probe = D185ScanProbe([
            "local": .init(isRegularFile: true, totalFileAllocatedSize: 8192, fileAllocatedSize: 4096,
                           fileSize: 99999, isDataless: false /* D192: 旧值 .current */, contentModificationDate: date),
            "fallback": .init(isRegularFile: true, fileAllocatedSize: 4096, fileSize: 8000),
            "cloud": .init(isRegularFile: true, totalFileAllocatedSize: 4096, fileSize: 1_000_000, isDataless: true /* D192: 旧值 .notDownloaded */),
            "empty": .init(isRegularFile: true, fileSize: 900),
            "link": .init(isRegularFile: true, isSymbolicLink: true, totalFileAllocatedSize: 99999),
            "dirLink": .init(isRegularFile: false, isSymbolicLink: true)
        ], failures: ["denied"])
        let snapshot = scan(provider, probe)
        XCTAssertTrue(snapshot.rootExists)
        XCTAssertEqual(snapshot.localFileCount, 2)
        XCTAssertEqual(snapshot.localBytes, 12288)
        XCTAssertEqual(snapshot.cloudOnlyCount, 1)
        XCTAssertEqual(snapshot.cloudOnlyBytes, 1_000_000)
        XCTAssertEqual(snapshot.inspectedCount, 7)
        XCTAssertEqual(snapshot.unreadableCount, 1)
        XCTAssertFalse(snapshot.isTruncated)
        XCTAssertEqual(snapshot.largestLocalFiles.map(\.name), ["local", "fallback"])
        XCTAssertEqual(snapshot.largestLocalFiles.first?.modifiedAt, date)
        XCTAssertFalse(probe.paths.contains { $0.contains("hidden") || $0.hasSuffix("never") })
        let entries = CloudDriveScanner.reviewEntries(snapshot.largestLocalFiles)
        XCTAssertEqual(entries.map(\.path), snapshot.largestLocalFiles.map(\.path))
        XCTAssertEqual(entries.map(\.sizeBytes), [8192, 4096])
    }

    func testICloudAndThirdPartyUseSameAccounting() throws {
        let home = try d185Home(self)
        let provider = provider(home)
        _ = try d185File(URL(fileURLWithPath: provider.path), "file")
        _ = try d185File(CloudDriveScanner.iCloudDriveRoot(home: home), "file")
        let probe = D185ScanProbe()
        var iCloud = CloudDriveScanner.scan(home: home, metadata: probe.read, isCancelled: { false }, progress: { _ in })
        var other = scan(provider, probe)
        XCTAssertNotEqual(iCloud.largestLocalFiles.first?.path, other.largestLocalFiles.first?.path)
        iCloud.largestLocalFiles = []; other.largestLocalFiles = []
        XCTAssertEqual(iCloud, other)
        XCTAssertEqual(Set(CloudDriveScanner.resourceKeys), [.isRegularFileKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
            .contentModificationDateKey], "D192: 旧值还包含 ubiquitousItemDownloadingStatusKey")
    }

    func testEachItemReadsMetadataOnceWithoutCloudStateResourceKeys() throws {
        let home = try d185Home(self)
        let provider = provider(home)
        let root = URL(fileURLWithPath: provider.path)
        for name in ["local", "cloud", "Folder/inside", "Placeholder/also-counted"] {
            _ = try d185File(root, name)
        }
        let probe = D185ScanProbe([
            "Folder": .init(isRegularFile: false),
            "Placeholder": .init(isRegularFile: false, isDataless: true),
            "cloud": .init(isRegularFile: true, totalFileAllocatedSize: 4096,
                           fileSize: 1_000_000, isDataless: true)
        ])
        let result = scan(provider, probe)
        let counts = Dictionary(grouping: probe.paths, by: { $0 }).mapValues(\.count)
        XCTAssertEqual(counts.count, 6)
        XCTAssertTrue(counts.values.allSatisfy { $0 == 1 }, "One metadata read per enumerated item")
        XCTAssertTrue(probe.paths.contains { $0.hasSuffix("also-counted") }, "Cloud Cleanup keeps its full file inventory")
        XCTAssertEqual(result.localFileCount, 3)
        XCTAssertEqual(result.cloudOnlyCount, 1)
        XCTAssertEqual(result.cloudOnlyBytes, 1_000_000)
        XCTAssertFalse(CloudDriveScanner.resourceKeys.contains(.isUbiquitousItemKey))
        XCTAssertFalse(CloudDriveScanner.resourceKeys.contains(.ubiquitousItemDownloadingStatusKey))
    }

    func testDefaultMetadataReaderUsesLocalStatWithoutReadingContents() throws {
        let home = try d185Home(self)
        let file = try d185File(home, "local")
        var status = stat()
        XCTAssertEqual(lstat(file.path, &status), 0)
        // Reading attributes remains possible without permission to read data.
        XCTAssertEqual(chmod(file.path, 0), 0)
        defer { XCTAssertEqual(chmod(file.path, 0o600), 0) }
        let metadata = try CloudDriveScanner.Metadata.read(file)
        XCTAssertEqual(metadata.isDataless, status.st_flags & UInt32(SF_DATALESS) != 0)
        XCTAssertEqual(metadata.fileSize, Int(status.st_size))
        XCTAssertEqual(metadata.totalFileAllocatedSize ?? metadata.fileAllocatedSize, Int(status.st_blocks) * 512)
    }

    func testLargestLocalListIsBoundedAndSortedByAllocation() throws {
        let home = try d185Home(self)
        let provider = provider(home)
        var values: [String: CloudDriveScanner.Metadata] = [:]
        for index in 1...450 {
            _ = try d185File(URL(fileURLWithPath: provider.path), "\(index)")
            values["\(index)"] = .init(isRegularFile: true, totalFileAllocatedSize: index * 1_000_000, fileSize: 1)
        }
        let snapshot = scan(provider, D185ScanProbe(values))
        XCTAssertEqual(snapshot.localFileCount, 450)
        XCTAssertEqual(snapshot.largestLocalFiles.count, CloudDriveScanner.keptFileCount)
        XCTAssertEqual(snapshot.largestLocalFiles.map(\.allocatedBytes), (251...450).reversed().map { Int64($0 * 1_000_000) })
        XCTAssertEqual(snapshot.largeLocalFiles.count, CloudDriveScanner.keptFileCount)
    }

    func testPerAccountItemLimitAndProgressThrottling() throws {
        let home = try d185Home(self)
        for name in ["OneDrive-Personal", "OneDrive-Work"] {
            let provider = provider(home, name)
            for index in 0..<805 { _ = try d185File(URL(fileURLWithPath: provider.path), "\(index)") }
            let probe = D185ScanProbe()
            let snapshot = scan(provider, probe, limit: 801)
            XCTAssertTrue(snapshot.isTruncated)
            XCTAssertEqual(snapshot.inspectedCount, 802, "includes the original iCloud stop marker")
            XCTAssertEqual(probe.paths.count, 801)
            XCTAssertEqual(probe.progressValues.map(\.inspectedCount), [400, 800, 802])
            XCTAssertEqual(snapshot.localFileCount, 801, "each account has an independent budget")
        }
    }

    func testCancellationStopsMetadataReadsAndMissingOrLinkedRootIsNotWalked() throws {
        let home = try d185Home(self)
        let provider = provider(home)
        let root = URL(fileURLWithPath: provider.path)
        for index in 0..<8 { _ = try d185File(root, "\(index)") }
        let probe = D185ScanProbe(cancelAfter: 1)
        let snapshot = scan(provider, probe)
        XCTAssertEqual(snapshot.inspectedCount, 1)
        XCTAssertEqual(probe.paths.count, 1)
        XCTAssertFalse(snapshot.isTruncated)
        let cancelled = D185ScanProbe(); cancelled.flag.cancel()
        XCTAssertEqual(scan(provider, cancelled).inspectedCount, 0)
        XCTAssertTrue(cancelled.paths.isEmpty)
        XCTAssertFalse(scan(self.provider(home, "missing"), D185ScanProbe()).rootExists)
        let linked = self.provider(home, "Dropbox-Link")
        try FileManager.default.createSymbolicLink(at: URL(fileURLWithPath: linked.path), withDestinationURL: root)
        let linkProbe = D185ScanProbe()
        XCTAssertFalse(scan(linked, linkProbe).rootExists)
        XCTAssertTrue(linkProbe.paths.isEmpty)
    }

    @MainActor
    func testModelOnlyScansAfterStartAndKeepsResultsWhenRescanIsCancelled() async throws {
        let home = try d185Home(self)
        for name in ["GoogleDrive-person@example.com", "OneDrive-Personal"] {
            _ = try d185File(home, "Library/CloudStorage/\(name)/file")
        }
        let probe = D185ScanProbe()
        let model = CloudCleanupModel(home: home, metadata: probe.read)
        model.refreshProviders()
        XCTAssertEqual(model.providers.count, 2)
        XCTAssertFalse(model.iCloudDriveAvailable)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.providerSnapshots.isEmpty)
        XCTAssertTrue(probe.paths.isEmpty)
        let finished = expectation(description: "all accounts scanned")
        let observer = model.$phase.filter { $0 == .finished }.first().sink { _ in finished.fulfill() }
        model.start()
        await fulfillment(of: [finished], timeout: 10)
        withExtendedLifetime(observer) {}
        XCTAssertEqual(model.providerSnapshots.map { $0.snapshot.localFileCount }, [1, 1])
        XCTAssertEqual(probe.paths.count, 2)
        let previous = model.providerSnapshots
        let cancelled = expectation(description: "cancelled rescan returns to previous results")
        let second = model.$phase.dropFirst().filter { $0 == .finished }.first().sink { _ in cancelled.fulfill() }
        model.start(); model.cancel()
        await fulfillment(of: [cancelled], timeout: 10)
        withExtendedLifetime(second) {}
        XCTAssertEqual(model.providerSnapshots, previous)
        model.startOver()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.providerSnapshots.isEmpty)
    }
}

private func d185ReadyMetadata() -> CloudSyncMetadata {
    CloudSyncMetadata(isUbiquitous: true, download: .current, uploaded: true, conflicts: false,
                      uploading: false, downloading: false, excludedFromSync: false, syncError: false)
}

private final class D185NativeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CloudSyncMetadata
    private var evictions = 0
    init(_ metadata: CloudSyncMetadata = d185ReadyMetadata()) { value = metadata }
    func set(_ metadata: CloudSyncMetadata) { lock.withLock { value = metadata } }
    func read(_ url: URL) throws -> CloudSyncMetadata { lock.withLock { value } }
    func evict(_ url: URL) throws { lock.withLock { evictions += 1 } }
    var count: Int { lock.withLock { evictions } }
    func provider(home: URL) -> NativeCloudLocalCopyProvider {
        NativeCloudLocalCopyProvider(home: home.path, metadata: read, evictor: evict)
    }
}

private actor D185CopyProbe: CloudLocalCopyProvider {
    let before: CloudLocalCopyState
    let after: CloudLocalCopyState
    let failReadback: Bool
    let failEvict: Bool
    var reads = 0
    var evicts = 0
    init(before: CloudLocalCopyState, after: CloudLocalCopyState, failReadback: Bool = false, failEvict: Bool = false) {
        self.before = before; self.after = after; self.failReadback = failReadback; self.failEvict = failEvict
    }
    func state(at path: String) async throws -> CloudLocalCopyState {
        reads += 1
        if reads > 1, failReadback { throw CocoaError(.fileReadNoPermission) }
        return reads == 1 ? before : after
    }
    func evict(_ expected: CloudLocalCopyState) async throws {
        evicts += 1
        if failEvict { throw CocoaError(.featureUnsupported) }
    }
    func counts() -> (Int, Int) { (reads, evicts) }
}

final class CloudLocalCopyD185Tests: XCTestCase {
    private func ready(_ path: String) -> CloudLocalCopyState {
        CloudLocalCopyState(path: path, provider: .external("OneDrive"), supported: true, safe: true,
            identity: "device:inode", revision: "revision", allocatedBytes: 16384, download: .current,
            uploaded: true, conflicts: false, uploading: false, downloading: false,
            excludedFromSync: false, syncError: false)
    }

    func testNativeICloudRetainsD90MetadataSemanticsInTemporaryWorkspace() async throws {
        let home = try d185Home(self)
        let path = try d185File(home, "Library/Mobile Documents/com~apple~CloudDocs/file").path
        let probe = D185NativeProbe()
        let native = probe.provider(home: home)
        let reviewed = try await native.state(at: path)
        XCTAssertEqual(reviewed.provider, .iCloud)
        XCTAssertNil(reviewed.block)
        var value = d185ReadyMetadata(); value.uploaded = nil; probe.set(value)
        let unknown = try await native.state(at: path)
        XCTAssertEqual(unknown.provider, .iCloud)
        XCTAssertEqual(unknown.block, .unknown, "iCloud retains its original missing-evidence reason")
        value = d185ReadyMetadata(); value.conflicts = true; probe.set(value)
        let conflict = try await native.state(at: path)
        XCTAssertEqual(conflict.block, .conflict)
        do { try await native.evict(reviewed); XCTFail("must recheck iCloud sync state too") }
        catch { XCTAssertTrue(error is CloudCopyGateError) }
        XCTAssertEqual(probe.count, 0)
    }

    func testThirdPartyNativeEligibilityUsesEveryMetadataFieldAndSameEvictionGate() async throws {
        let home = try d185Home(self)
        for name in ["GoogleDrive-me@example.com", "OneDrive-中文公司", "Dropbox", "Box-Team", "Other-Personal"] {
            let path = try d185File(home, "Library/CloudStorage/\(name)/file").path
            let probe = D185NativeProbe()
            let native = probe.provider(home: home)
            let state = try await native.state(at: path)
            XCTAssertNil(state.block, name)
            XCTAssertTrue(state.supported)
            XCTAssertGreaterThan(state.allocatedBytes, 0)
            XCTAssertEqual(state.provider, .external(NativeCloudLocalCopyProvider.externalProviderName(path)!))
            try await native.evict(state)
            XCTAssertEqual(probe.count, 1, "only the injected counter, never system eviction")
        }
    }

    func testAnyMissingMetadataBlocksThirdPartyAndOffersFinderFallback() async throws {
        let home = try d185Home(self)
        let path = try d185File(home, "Library/CloudStorage/OneDrive-Personal/file").path
        let omit: [(inout CloudSyncMetadata) -> Void] = [
            { $0.isUbiquitous = nil }, { $0.download = .unknown }, { $0.uploaded = nil },
            { $0.conflicts = nil }, { $0.uploading = nil }, { $0.downloading = nil },
            { $0.excludedFromSync = nil }, { $0.syncError = nil }
        ]
        for (index, change) in omit.enumerated() {
            var value = d185ReadyMetadata(); change(&value)
            let probe = D185NativeProbe(value)
            let native = probe.provider(home: home)
            let state = try await native.state(at: path)
            XCTAssertEqual(state.block, .unsupported, "missing field \(index)")
            XCTAssertEqual(state.blockTitle, CloudCopyBlock.unsupported.title)
            do { try await native.evict(state); XCTFail("missing evidence must block direct callers") }
            catch { XCTAssertTrue(error is CloudCopyGateError) }
            XCTAssertEqual(probe.count, 0)
        }
        let native = NativeCloudLocalCopyProvider(home: home.path,
            metadata: { _ in throw CocoaError(.fileReadNoPermission) }, evictor: { _ in XCTFail("must not evict") })
        let state = try await native.state(at: path)
        XCTAssertEqual(state.block, .unsupported)
        XCTAssertEqual(state.blockTitle, CloudCopyBlock.unsupported.title)
    }

    func testNegativeSyncEvidenceAndStaleReviewCannotEvictThirdPartyFiles() async throws {
        let home = try d185Home(self)
        let path = try d185File(home, "Library/CloudStorage/Dropbox-Work/file").path
        let changes: [(CloudCopyBlock, (inout CloudSyncMetadata) -> Void)] = [
            (.unsupported, { $0.isUbiquitous = false }), (.notUploaded, { $0.uploaded = false }),
            (.notUploaded, { $0.excludedFromSync = true }), (.conflict, { $0.conflicts = true }),
            (.syncing, { $0.uploading = true }), (.syncing, { $0.downloading = true }),
            (.syncing, { $0.syncError = true }), (.placeholder, { $0.download = .placeholder })
        ]
        let probe = D185NativeProbe()
        let native = probe.provider(home: home)
        let reviewed = try await native.state(at: path)
        for (block, change) in changes {
            var value = d185ReadyMetadata(); change(&value); probe.set(value)
            let state = try await native.state(at: path)
            XCTAssertEqual(state.block, block)
            XCTAssertTrue(state.blockTitle?.contains(CloudCopyBlock.unsupported.title) == true)
            do { try await native.evict(reviewed); XCTFail("fresh sync evidence must be rechecked") }
            catch { XCTAssertTrue(error is CloudCopyGateError) }
        }
        probe.set(d185ReadyMetadata())
        var stale = reviewed; stale.identity = "replacement"
        do { try await native.evict(stale); XCTFail("must reject a replaced file") }
        catch { XCTAssertTrue(error is CloudCopyGateError) }
        stale = reviewed; stale.revision = "edited"
        do { try await native.evict(stale); XCTFail("must reject edits") }
        catch { XCTAssertTrue(error is CloudCopyGateError) }
        XCTAssertEqual(probe.count, 0)
    }

    func testCloudStorageOutsideHomeAndLinksNeverGainCapability() async throws {
        let root = try d185Home(self)
        let home = root.appendingPathComponent("home")
        let path = try d185File(home, "Library/CloudStorage/OneDrive-Personal/file").path
        let elsewhere = try d185File(root, "elsewhere/Library/CloudStorage/OneDrive-Personal/file").path
        let probe = D185NativeProbe()
        let native = probe.provider(home: home)
        let outside = try await native.state(at: elsewhere)
        XCTAssertEqual(outside.block, .unsupported)
        let link = home.appendingPathComponent("Library/CloudStorage/Dropbox-Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: path).deletingLastPathComponent())
        let linked = try await native.state(at: link.appendingPathComponent("file").path)
        XCTAssertEqual(linked.block, .unsafe)
        let hard = home.appendingPathComponent("Library/CloudStorage/OneDrive-Personal/hard")
        try FileManager.default.linkItem(atPath: path, toPath: hard.path)
        let hardState = try await native.state(at: path)
        XCTAssertEqual(hardState.block, .unsafe)
        XCTAssertEqual(probe.count, 0)
    }

    func testThirdPartyAcceptedRequestNeedsSameFilePlaceholderAndAllocationDropWithoutRetry() async throws {
        let home = try d185Home(self)
        let before = ready(try d185File(home, "file").path)
        var decreased = before; decreased.allocatedBytes = 4096
        var sameBlocks = before; sameBlocks.download = .placeholder
        var replaced = sameBlocks; replaced.identity = "other"; replaced.allocatedBytes = 0
        var unsafe = replaced; unsafe.identity = before.identity; unsafe.safe = false
        var otherProvider = replaced; otherProvider.identity = before.identity; otherProvider.provider = .external("Dropbox")
        for after in [before, decreased, sameBlocks, replaced, unsafe, otherProvider] {
            let probe = D185CopyProbe(before: before, after: after)
            let service = CloudLocalCopyService(provider: probe, readbackInterval: .zero)
            let outcome = await service.release([before])
            XCTAssertEqual(outcome.items.first?.status, .providerDeclined)
            XCTAssertEqual(outcome.releasedBytes, 0)
            let counts = await probe.counts()
            // One recheck, then the same bounded readbacks as iCloud (the
            // integrator's review changed this from exactly one readback).
            XCTAssertEqual(counts.0, 1 + service.readbackAttempts, "one recheck and the bounded readbacks")
            XCTAssertEqual(counts.1, 1, "never repeat an eviction")
        }
        var after = before; after.download = .placeholder; after.allocatedBytes = 4096
        let probe = D185CopyProbe(before: before, after: after)
        let outcome = await CloudLocalCopyService(provider: probe).release([before])
        XCTAssertEqual(outcome.items.first?.status, .released)
        XCTAssertEqual(outcome.releasedBytes, 12288)
    }

    func testThirdPartyEvictionAndReadbackErrorsHaveFinderFallback() async throws {
        let home = try d185Home(self)
        let before = ready(try d185File(home, "file").path)
        for readback in [false, true] {
            let probe = D185CopyProbe(before: before, after: before, failReadback: readback, failEvict: !readback)
            let outcome = await CloudLocalCopyService(provider: probe).release([before])
            XCTAssertEqual(outcome.items.first?.status, .providerDeclined)
            XCTAssertEqual(outcome.releasedBytes, 0)
            let counts = await probe.counts()
            XCTAssertEqual(counts.1, 1)
        }
    }
}

final class CloudCleanupD185PresentationTests: XCTestCase {
    @MainActor
    func testLandingCardsHeadlineAndFallbackFollowBothLanguagesAndD178() {
        for language in [AppLanguage.zhHans, .english] {
            let preferences = TestVolatilePreferences()
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            defer { preferences.restore() }
            let english = language == .english
            let provider = CloudDriveScanner.Provider(folderName: "GoogleDrive-me@example.com", path: "/fixture/google")
            let snapshot = CloudDriveSnapshot(rootExists: true, localFileCount: 12345, localBytes: 1_000_000_000,
                                              cloudOnlyCount: 54321, cloudOnlyBytes: 2_000_000_000,
                                              isTruncated: true, unreadableCount: 1234)
            let result = CloudDriveScanner.ProviderSnapshot(provider: provider, snapshot: snapshot)
            let bullets = CloudCleanupPresentation.landingBullets(iCloudDriveAvailable: false, providers: [provider])
            XCTAssertEqual(bullets.last?.title, "Google Drive · me@example.com")
            // D204（第 19 条，用户 10-24 定）: landings show names only. Was
            // `XCTAssertEqual(bullets.last?.detail, …"已在这台 Mac 上设置")` and
            // `XCTAssertEqual(empty.last?.detail, …"没有发现其他云盘文件夹")`: the
            // same words moved to the VoiceOver hint, nothing under the name.
            XCTAssertNil(bullets.last?.detail)
            XCTAssertEqual(bullets.last?.hint, english ? "Set up on this Mac" : "已在这台 Mac 上设置")
            XCTAssertEqual(bullets.last?.id, "provider.0")
            let empty = CloudCleanupPresentation.landingBullets(iCloudDriveAvailable: true, providers: [])
            XCTAssertNil(empty.last?.detail)
            XCTAssertEqual(empty.last?.hint, english ? "No other cloud folders found" : "没有发现其他云盘文件夹")
            let tile = CloudCleanupPresentation.providerTile(result, id: "provider.0", onReview: {}, onOpen: {})
            XCTAssertEqual(tile.title, "Google Drive · me@example.com")
            XCTAssertEqual(tile.value, ByteFormat.storageString(1_000_000_000))
            XCTAssertTrue(tile.valueCaption?.contains("12,345") == true)
            XCTAssertTrue(tile.valueCaption?.contains("54,321") == true)
            XCTAssertTrue(tile.valueCaption?.contains(ByteFormat.storageString(2_000_000_000)) == true)
            XCTAssertTrue(tile.valueCaption?.contains(english ? "On this Mac" : "本机") == true)
            XCTAssertTrue(tile.valueCaption?.contains(english ? "Cloud only" : "只在云端") == true)
            XCTAssertTrue(tile.note?.contains("400,000") == true)
            XCTAssertTrue(tile.note?.contains("1,234") == true)
            XCTAssertEqual(tile.reviewTitle, english ? "Review" : "查看")
            XCTAssertEqual(tile.cleanTitle, english ? "Open in Finder" : "在访达中打开")
            XCTAssertEqual(CloudCleanupPresentation.headline(.init(), providers: [result]), english
                ? "Cloud files take \(ByteFormat.storageString(1_000_000_000)) on this Mac."
                : "云盘文件在这台 Mac 上占用 \(ByteFormat.storageString(1_000_000_000))。")
            XCTAssertEqual(CloudCleanupPresentation.headline(snapshot, providers: []), english
                ? "iCloud Drive takes \(ByteFormat.storageString(1_000_000_000)) on this Mac."
                : "iCloud 云盘在这台 Mac 上占用 \(ByteFormat.storageString(1_000_000_000))。")
            XCTAssertEqual(CloudCleanupPresentation.resultFootnote(hasOtherProviders: true), english
                ? "Only local copies are removed · Files stay in the cloud" : "只移除本机副本 · 文件仍在云盘")
            XCTAssertTrue(CloudCopyResultStatus.providerDeclined.title.contains(english ? "did not let this app" : "没有让本应用释放"))
            XCTAssertTrue(CloudCopyResultStatus.providerDeclined.title.contains(english ? "Remove Download" : "移除下载"))
        }
    }

    @MainActor
    func testProviderTileActionsAndUnavailableState() {
        let provider = CloudDriveScanner.Provider(folderName: "OneDrive-Personal", path: "/fixture/onedrive")
        var reviews = 0, opens = 0
        let tile = CloudCleanupPresentation.providerTile(.init(provider: provider, snapshot: .init()), id: "provider.1",
                                                         onReview: { reviews += 1 }, onOpen: { opens += 1 })
        tile.onReview(); tile.onClean?()
        XCTAssertEqual(reviews, 1)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(tile.value, L10n.text("无法读取", "Unavailable"))
        XCTAssertEqual(tile.title, "OneDrive · Personal")
        XCTAssertTrue(tile.iconPaths.isEmpty, "unknown installed app uses the SF Symbol")
        XCTAssertEqual(tile.systemImage, "externaldrive.connected.to.line.below")
    }
}
