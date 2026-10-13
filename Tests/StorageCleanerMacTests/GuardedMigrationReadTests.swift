import Darwin
import XCTest
@testable import StorageCleanerMac

final class GuardedMigrationReadTests: XCTestCase {
    func testCloudOnlyAndDownloadingMigrationNeverCopiesOrHashes() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        for reason in [FileContentReadError.cloudOnly, .downloading] {
            let probe = ContentReadProbe()
            let reader = GuardedFileContentReader(guardPolicy: .init(
                isPlaceholder: { _ in reason == .cloudOnly },
                cloudState: { _ in reason }, needsCloudState: { _, _ in true }
            ), willRead: { _ in probe.recordRead() })
            XCTAssertThrowsError(try fixture.migrate(reader: reader)) {
                XCTAssertEqual($0 as? FileContentReadError, reason)
                XCTAssertFalse($0.localizedDescription.isEmpty)
            }
            XCTAssertThrowsError(try ExternalDriveMigrationService.filesHaveSameSHA256(
                fixture.item.sourceURL, fixture.item.sourceURL, contentReader: reader
            )) { XCTAssertEqual($0 as? FileContentReadError, reason) }
            XCTAssertEqual(probe.reads, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertEqual(try Data(contentsOf: fixture.item.sourceURL), fixture.contents)
        }
    }

    func testCloudOnlyRetainedCopyIsRejectedBeforeEitherHashAndOriginalMove() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        _ = try fixture.migrate()
        let probe = ContentReadProbe()
        let destinationPath = fixture.destination.path
        let reader = GuardedFileContentReader(guardPolicy: .init(isPlaceholder: { $0 == destinationPath }),
                                              willRead: { _ in probe.recordRead() })
        XCTAssertThrowsError(try ExternalDriveMigrationService.moveOriginalToTrash(
            fixture.item, verifiedCopyAt: fixture.destination, on: fixture.volume,
            trustedVolumes: [fixture.volume], trashOperation: { _ in XCTFail("Must not move"); return nil },
            journal: CleanupReportJournal(directory: fixture.root.appendingPathComponent("journal")), contentReader: reader
        )) { XCTAssertEqual($0 as? FileContentReadError, .cloudOnly) }
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.item.sourceURL), fixture.contents)
    }

    func testBlockedCopyTimesOutCleansStagingAndNeverPublishesLate() async throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let gate = ContentReadGate()
        defer { gate.release() }
        let reader = GuardedFileContentReader(pool: FileContentReadPool(maximumReaders: 1), timeout: 0.1,
                                              willRead: { _ in gate.block() })
        let start = ProcessInfo.processInfo.systemUptime
        let worker = Task.detached { try fixture.migrate(reader: reader) }
        await fulfillment(of: [gate.entered], timeout: 1)
        do { _ = try await worker.value; XCTFail("Blocked copy succeeded") }
        catch { XCTAssertEqual(error as? FileContentReadError, .timedOut) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertFalse(gate.didReturn)
        // D61: the active copyfile worker retains its private staging tree.
        fixture.assertNoPublishedCopy()
        gate.release()
        // A late worker may only clean its abandoned output, never publish.
        try await Task.sleep(for: .milliseconds(100))
        try fixture.assertNoPartialOrPublishedCopy()
        XCTAssertEqual(try Data(contentsOf: fixture.item.sourceURL), fixture.contents)
    }

    func testCancelledCopyDefersStagingCleanupUntilWorkerReturns() async throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let gate = ContentReadGate()
        defer { gate.release() }
        let reader = GuardedFileContentReader(pool: FileContentReadPool(maximumReaders: 1), timeout: 10,
                                              willRead: { _ in gate.block() })
        let worker = Task.detached { try fixture.migrate(reader: reader) }
        await fulfillment(of: [gate.entered], timeout: 1)
        let start = ProcessInfo.processInfo.systemUptime
        worker.cancel()
        do { _ = try await worker.value; XCTFail("Cancelled copy succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertFalse(gate.didReturn)
        fixture.assertNoPublishedCopy()
        gate.release()
        try await Task.sleep(for: .milliseconds(100))
        try fixture.assertNoPartialOrPublishedCopy()
        XCTAssertEqual(try Data(contentsOf: fixture.item.sourceURL), fixture.contents)
    }

    func testBundleCopySkipsCloudDescendantWithoutReadingIt() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let bundle = fixture.root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        let child = bundle.appendingPathComponent("placeholder")
        try Data("fake cloud contents".utf8).write(to: child)
        let probe = ContentReadProbe()
        // The reader walks canonical paths (/private/var for /var); compare the same form.
        let childPath = child.resolvingSymlinksInPath().path
        let reader = GuardedFileContentReader(guardPolicy: .init(isPlaceholder: {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == childPath
        }),
                                              willRead: { _ in probe.recordRead() })
        let staging = try MigrationStagingDirectory(parentURL: fixture.root)
        defer { try? staging.remove() }
        XCTAssertThrowsError(try GuardedFileCopy(reader: reader).copy(bundle, to: staging.url.appendingPathComponent("Fixture.app"))) {
            XCTAssertEqual($0 as? FileContentReadError, .cloudOnly)
        }
        XCTAssertEqual(probe.reads, 0)
        // Signature preflight also walks the whole tree before reading code.
        XCTAssertThrowsError(try reader.pool.read { control in
            try reader.guardPolicy.checkTree(bundle, control: control)
        }) { XCTAssertEqual($0 as? FileContentReadError, .cloudOnly) }
    }

    func testLocalStreamCopyPreservesBytesPermissionsAndSymlinks() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        let destination = fixture.root.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("executable")
        let data = Data(repeating: 0x63, count: 2_100_000)
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: file.path)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "executable")
        try GuardedFileCopy(reader: GuardedFileContentReader()).copy(source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("executable")), data)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("executable").path)[.posixPermissions] as? Int, 0o751)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("link").path), "executable")
    }

    func testMigrationHashTimeoutAndCancellationDoNotReadASecondFile() async throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        for cancels in [false, true] {
            let gate = ContentReadGate()
            defer { gate.release() }
            let reader = GuardedFileContentReader(pool: FileContentReadPool(maximumReaders: 1),
                timeout: cancels ? 10 : 0.1, willRead: { _ in gate.block() })
            let worker = Task.detached {
                try ExternalDriveMigrationService.filesHaveSameSHA256(fixture.file, fixture.file, contentReader: reader)
            }
            await fulfillment(of: [gate.entered], timeout: 1)
            if cancels { worker.cancel() }
            let start = ProcessInfo.processInfo.systemUptime
            do { _ = try await worker.value; XCTFail("Blocked hash compared equal") }
            catch {
                if cancels { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? FileContentReadError, .timedOut) }
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
            XCTAssertFalse(gate.didReturn)
        }
    }

    func testCopyPreservesExtendedAttributesAndStreamsResourceFork() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let metadata = Data("fixture attribute".utf8)
        let fork = Data(repeating: 0x52, count: 2_100_000)
        for (name, data) in [("test.storagecleaner.metadata", metadata), ("com.apple.ResourceFork", fork)] {
            let result = data.withUnsafeBytes { buffer in
                fixture.file.path.withCString { path in name.withCString {
                    setxattr(path, $0, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
                } }
            }
            XCTAssertEqual(result, 0)
        }
        let copy = fixture.root.appendingPathComponent("copy.bin")
        try GuardedFileCopy(reader: GuardedFileContentReader()).copy(fixture.file, to: copy)
        for (name, expected) in [("test.storagecleaner.metadata", metadata), ("com.apple.ResourceFork", fork)] {
            var data = Data(count: expected.count)
            let count = data.withUnsafeMutableBytes { buffer in
                copy.path.withCString { path in name.withCString {
                    getxattr(path, $0, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
                } }
            }
            XCTAssertEqual(count, expected.count)
            XCTAssertEqual(data, expected)
        }
    }

    func testFinalReceiptRecheckRejectsCopyChangedDuringCheckpoint() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        _ = try fixture.migrate()
        XCTAssertThrowsError(try ExternalDriveMigrationService.moveOriginalToTrash(
            fixture.item, verifiedCopyAt: fixture.destination, on: fixture.volume,
            trustedVolumes: [fixture.volume], trashOperation: { _ in XCTFail("Changed copy must keep original"); return nil },
            persist: { _, _ in
                try Data(repeating: 0x59, count: fixture.contents.count).write(to: fixture.destination)
            }
        )) { XCTAssertEqual($0 as? ExternalDriveMigrationError, .copyVerificationFailed) }
        XCTAssertEqual(try Data(contentsOf: fixture.item.sourceURL), fixture.contents)
    }
}

/// Same isolated home fixture convention as ExternalMigrationReceiptTests.
/// Migration's production policy only accepts sources within the user's home;
/// no Library, Desktop, Documents, cloud, cache or preferences path is used.
struct MigrationContentFixture: Sendable {
    let root: URL
    let item: ExternalMigrationItem
    let volume: ExternalStorageVolume
    let contents = Data("migration contents".utf8)
    var file: URL { item.sourceURL }
    var destination: URL { volume.url.appendingPathComponent("StorageCleaner Migration/Large Files/source.bin") }
    init() throws {
        root = TestFileSystem.uniqueOperationRoot("content-tests").resolvingSymlinksInPath()
        let source = root.appendingPathComponent("source.bin")
        let disk = root.appendingPathComponent("external", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
            try contents.write(to: source)
            item = ExternalMigrationItem(id: "file:fixture", title: "source.bin", sourceURL: source,
                                         sizeBytes: Int64(contents.count), kind: .file, bundleIdentifier: "")
            volume = ExternalStorageVolume(url: disk, name: "Fixture", availableBytes: 1_000_000,
                                           totalBytes: 2_000_000, fileSystem: "APFS", supportsApplications: true)
        } catch {
            TestFileSystem.remove(root)
            throw error
        }
    }
    func migrate(reader: GuardedFileContentReader = GuardedFileContentReader(),
                 durability: MigrationDurability = MigrationDurability()) throws -> ExternalMigrationResult {
        try ExternalDriveMigrationService.migrate(item, to: volume, trustedVolumes: [volume], contentReader: reader,
                                                  durability: durability)
    }
    func assertNoPublishedCopy(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), file: file, line: line)
    }
    func assertNoPartialOrPublishedCopy(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), file: file, line: line)
        let contents = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        XCTAssertTrue(contents.isEmpty, "Staging was not cleaned: \(contents)", file: file, line: line)
    }
    func remove() {
        TestFileSystem.unlockOwnedTree(root)
        TestFileSystem.remove(root)
    }
}
