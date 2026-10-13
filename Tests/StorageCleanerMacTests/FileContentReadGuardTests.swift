import AppKit
import CryptoKit
import Darwin
import XCTest
@testable import StorageCleanerMac

final class FileContentReadGuardTests: XCTestCase {
    func testSystemAliasTranslationAcceptsOnlyItsExactRootRelativeOrAbsoluteTarget() {
        for name in ["var", "tmp"] {
            let alias = "/" + name
            let path = alias + "/fixture/file.bin"
            let target = "/private/" + name
            for destination in [target, "private/" + name] {
                XCTAssertEqual(GuardedFileContentReader.systemAliasPath(path, linkDestination: {
                    XCTAssertEqual($0, alias)
                    return destination
                }), target + "/fixture/file.bin")
            }
            for destination in ["/elsewhere", "private/other", "../private/" + name, target + "/nested"] {
                XCTAssertEqual(GuardedFileContentReader.systemAliasPath(path, linkDestination: { _ in destination }), path)
            }
            XCTAssertEqual(GuardedFileContentReader.systemAliasPath(path, linkDestination: { _ in
                throw CocoaError(.fileReadNoSuchFile)
            }), path)
        }
        for path in ["/private/tmp/fixture/file.bin", "/Users/fixture/link/file.bin", "/tmp-other/file.bin"] {
            XCTAssertEqual(GuardedFileContentReader.systemAliasPath(path, linkDestination: { _ in
                XCTFail("Only the exact system aliases may be translated")
                return "/private/tmp"
            }), path)
        }
    }

    func testLocalFilesUnderBothSystemTemporaryAliasesReachTheContentReader() throws {
        for (physicalRoot, aliasRoot) in [("/private/var/tmp", "/var/tmp"), ("/private/tmp", "/tmp")] {
            let name = "content-alias-\(UUID().uuidString)"
            let folder = URL(fileURLWithPath: physicalRoot, isDirectory: true).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let contents = Data(repeating: 0x5a, count: 1_048_577)
            try contents.write(to: folder.appendingPathComponent("source.bin"))
            let alias = URL(fileURLWithPath: aliasRoot, isDirectory: true)
                .appendingPathComponent(name).appendingPathComponent("source.bin")
            let probe = ContentReadProbe()
            let reader = GuardedFileContentReader(guardPolicy: .init(cloudState: { _ in
                probe.recordProvider(); return nil
            }), willRead: { _ in probe.recordRead() })

            XCTAssertEqual(try reader.sha256(alias), Data(SHA256.hash(data: contents)))
            XCTAssertEqual(try FoundationCleanupContentDigestReader(reader: reader).sha256(at: alias),
                           Data(SHA256.hash(data: contents)))
            XCTAssertGreaterThan(probe.reads, 0)
            XCTAssertEqual(probe.providers, 0, "Ordinary temporary files must not query File Provider")
        }
    }

    func testSystemAliasDoesNotPermitUserSymlinksOrReadTheirContents() throws {
        let name = "content-alias-links-\(UUID().uuidString)"
        let folder = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(name)
        let real = folder.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("protected contents".utf8).write(to: real.appendingPathComponent("source.bin"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("parent-link").path,
                                                   withDestinationPath: "real")
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("leaf-link").path,
                                                   withDestinationPath: "real/source.bin")
        let probe = ContentReadProbe()
        let reader = GuardedFileContentReader(willRead: { _ in probe.recordRead() })
        let alias = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(name)
        for suffix in ["parent-link/source.bin", "leaf-link"] {
            XCTAssertThrowsError(try reader.sha256(alias.appendingPathComponent(suffix)))
        }
        XCTAssertEqual(probe.reads, 0)
    }

    func testCloudOnlyPreviewsAndCleanupHashesNeverReadBytes() throws {
        let fixture = try ContentReadFixture()
        defer { fixture.remove() }
        let probe = ContentReadProbe()
        let reader = GuardedFileContentReader(
            guardPolicy: .init(isPlaceholder: { _ in true }, cloudState: { _ in
                probe.recordProvider(); return nil
            }), willRead: { _ in probe.recordRead() }
        )
        XCTAssertThrowsError(try FoundationCleanupContentDigestReader(reader: reader).sha256(at: fixture.file)) {
            XCTAssertEqual($0 as? FileContentReadError, .cloudOnly)
        }
        let preview = SimilarImagePreviewCache.load(at: fixture.file.path, reader: reader)
        XCTAssertNil(preview.image)
        XCTAssertEqual(preview.unavailableReason, FileContentReadError.cloudOnly.localizedDescription)
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(probe.providers, 0, "The 2c flag alone is sufficient; do not ask File Provider")
    }

    func testDownloadingPreviewsAndCleanupHashesNeverReadBytes() throws {
        let fixture = try ContentReadFixture()
        defer { fixture.remove() }
        let probe = ContentReadProbe()
        let reader = GuardedFileContentReader(guardPolicy: .init(
            isPlaceholder: { _ in false }, cloudState: { _ in .downloading }, needsCloudState: { _, _ in true }
        ), willRead: { _ in probe.recordRead() })
        XCTAssertThrowsError(try FoundationCleanupContentDigestReader(reader: reader).sha256(at: fixture.file)) {
            XCTAssertEqual($0 as? FileContentReadError, .downloading)
        }
        let preview = SimilarImagePreviewCache.load(at: fixture.file.path, reader: reader)
        XCTAssertNil(preview.image)
        XCTAssertEqual(preview.unavailableReason, FileContentReadError.downloading.localizedDescription)
        XCTAssertEqual(probe.reads, 0)
    }

    func testOrdinaryLocalFilesDoNotQueryFileProviderAndKeepTheirDigest() throws {
        let fixture = try ContentReadFixture()
        defer { fixture.remove() }
        let probe = ContentReadProbe()
        let reader = GuardedFileContentReader(guardPolicy: .init(cloudState: { _ in
            probe.recordProvider(); return nil
        }), willRead: { _ in probe.recordRead() })
        XCTAssertEqual(try reader.sha256(fixture.file), Data(SHA256.hash(data: fixture.contents)))
        XCTAssertEqual(probe.reads, 1)
        XCTAssertEqual(probe.providers, 0)
    }

    func testSharedPolicyIsOffOnTheActualReadThreadAndRestoresOnThrow() throws {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let previous = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        defer { _ = setiopolicy_np(type, IOPOL_SCOPE_THREAD, previous) }
        XCTAssertEqual(setiopolicy_np(type, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_ON), 0)
        XCTAssertThrowsError(try { () throws -> Void in
            let restore = try FileContentReadGuard.refuseMaterializationOnThisThread()
            defer { restore() }
            XCTAssertEqual(getiopolicy_np(type, IOPOL_SCOPE_THREAD), IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            throw FileContentReadError.changed
        }())
        XCTAssertEqual(getiopolicy_np(type, IOPOL_SCOPE_THREAD), IOPOL_MATERIALIZE_DATALESS_FILES_ON)
        let policy = try FileContentReadPool(maximumReaders: 1).read { _ in
            getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        }
        XCTAssertEqual(policy, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }

    func testBlockedHashTimesOutAndPoolBoundsLingeringWorkers() throws {
        let fixture = try ContentReadFixture()
        defer { fixture.remove() }
        let gate = ContentReadGate()
        defer { gate.release() }
        let pool = FileContentReadPool(maximumReaders: 1)
        let reader = GuardedFileContentReader(pool: pool, timeout: 0.05, willRead: { _ in gate.block() })
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try reader.sha256(fixture.file)) {
            XCTAssertEqual($0 as? FileContentReadError, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertThrowsError(try pool.read { _ in 1 }) {
            XCTAssertEqual($0 as? FileContentReadError, .busy)
        }
        XCTAssertFalse(gate.didReturn, "The caller returned before the uninterruptible read did")
    }

    func testCancelledHashReturnsWhileTheReadRemainsBlocked() async throws {
        let fixture = try ContentReadFixture()
        defer { fixture.remove() }
        let gate = ContentReadGate()
        defer { gate.release() }
        let reader = GuardedFileContentReader(pool: FileContentReadPool(maximumReaders: 1), timeout: 10,
                                              willRead: { _ in gate.block() })
        let worker = Task.detached { try FoundationCleanupContentDigestReader(reader: reader).sha256(at: fixture.file) }
        await fulfillment(of: [gate.entered], timeout: 1)
        let start = ProcessInfo.processInfo.systemUptime
        worker.cancel()
        do { _ = try await worker.value; XCTFail("Cancelled hash returned a digest") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertFalse(gate.didReturn)
    }

    func testBlockedPreviewHasATimeoutReason() throws {
        let fixture = try ContentReadFixture()
        defer { fixture.remove() }
        let gate = ContentReadGate()
        defer { gate.release() }
        let reader = GuardedFileContentReader(pool: FileContentReadPool(maximumReaders: 1), timeout: 0.05,
                                              willRead: { _ in gate.block() })
        let start = ProcessInfo.processInfo.systemUptime
        let loaded = SimilarImagePreviewCache.load(at: fixture.file.path, reader: reader)
        XCTAssertNil(loaded.image)
        XCTAssertEqual(loaded.unavailableReason, FileContentReadError.timedOut.localizedDescription)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertFalse(gate.didReturn)
    }

    func testPreviewCancellationUnblocksTheCacheQueueWithoutWaitingForTheRead() async throws {
        let fixture = try ContentReadFixture()
        defer { fixture.remove() }
        let gate = ContentReadGate()
        defer { gate.release() }
        let probe = ContentReadProbe()
        let reader = GuardedFileContentReader(pool: FileContentReadPool(maximumReaders: 1), timeout: 10,
                                              willRead: { _ in gate.block() })
        let cache = AppIconCache(capacity: 2, resultLoader: { path, cancelled in
            if path == fixture.file.path {
                return SimilarImagePreviewCache.load(at: path, reader: reader, isCancelled: cancelled)
            }
            probe.recordRead()
            return AppIconCache.LoadedImage(image: nil)
        })
        let first = Task { await cache.loadedIcon(for: fixture.file.path) }
        await fulfillment(of: [gate.entered], timeout: 1)
        first.cancel()
        _ = await first.value
        let start = ProcessInfo.processInfo.systemUptime
        _ = await cache.loadedIcon(for: fixture.root.appendingPathComponent("next.bin").path)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertEqual(probe.reads, 1)
        XCTAssertFalse(gate.didReturn)
    }

    func testCloudReasonsHaveChineseAndEnglishTextWithoutWritingPreferences() {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        for (language, expected) in [(AppLanguage.zhHans.rawValue, "仅在云端"), (AppLanguage.english.rawValue, "Only in the cloud")] {
            preferences.set(language, forKey: L10n.languageDefaultsKey)
            XCTAssertTrue(FileContentReadError.cloudOnly.localizedDescription.contains(expected))
        }
    }
}

struct ContentReadFixture: Sendable {
    let root: URL
    let file: URL
    let contents = Data("guarded local fixture".utf8)
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("content-read-\(UUID().uuidString)", isDirectory: true)
        file = root.appendingPathComponent("source.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try contents.write(to: file)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

final class ContentReadGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "read started")
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var returned = false
    var didReturn: Bool { lock.withLock { returned } }
    func block() {
        entered.fulfill()
        _ = gate.wait(timeout: .now() + 3)
        lock.withLock { returned = true }
    }
    func release() { gate.signal() }
}

final class ContentReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var readCount = 0
    private var providerCount = 0
    var reads: Int { lock.withLock { readCount } }
    var providers: Int { lock.withLock { providerCount } }
    func recordRead() { lock.withLock { readCount += 1 } }
    func recordProvider() { lock.withLock { providerCount += 1 } }
}
