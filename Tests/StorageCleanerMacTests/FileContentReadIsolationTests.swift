import CryptoKit
import Darwin
import XCTest
@testable import StorageCleanerMac

final class FileContentReadIsolationTests: XCTestCase {
    func testProductionMountedVolumeKeysSeparateDevfsFromHome() {
        let pool = FileContentReadPool(maximumReaders: 4)
        let device = URL(fileURLWithPath: "/dev/null")
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertNotEqual(pool.volumeIdentity(for: device), pool.volumeIdentity(for: home),
                          "The production cached mount key must isolate devfs from the home volume")
        XCTAssertEqual(pool.volumeIdentity(for: home),
                       pool.volumeIdentity(for: home.appendingPathComponent(".storage-cleaner-key-fixture-does-not-exist")))
    }

    func testFourStalledReadsOnOneVolumeLeaveOtherVolumeHashAndCopyAvailable() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let pool = FileContentReadPool(maximumReaders: 4, volumeKey: {
            $0.path.hasPrefix("/unresponsive-fixture/") ? "stalled-volume" : "local-volume"
        })
        let gates = (0..<4).map { _ in ContentReadGate() }
        defer { for gate in gates { gate.release() } }
        let stalled = URL(fileURLWithPath: "/unresponsive-fixture/stand-in")
        for gate in gates {
            XCTAssertThrowsError(try pool.read(at: stalled, timeout: 0.05) { _ in gate.block(); return 1 }) {
                XCTAssertEqual($0 as? FileContentReadError, .timedOut)
            }
        }
        XCTAssertThrowsError(try pool.read(at: stalled) { _ in 1 }) {
            XCTAssertEqual($0 as? FileContentReadError, .busy)
        }
        let reader = GuardedFileContentReader(pool: pool)
        XCTAssertEqual(try reader.sha256(fixture.file), Data(SHA256.hash(data: fixture.contents)))
        let copy = fixture.root.appendingPathComponent("local-copy.bin")
        try GuardedFileCopy(reader: reader).copy(fixture.file, to: copy)
        XCTAssertEqual(try Data(contentsOf: copy), fixture.contents)
        XCTAssertTrue(gates.allSatisfy { !$0.didReturn }, "Other volumes work while all four stalled reads still own their slots")
    }

    func testOrdinaryDirectoryTreeDoesNotQueryFileProvider() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        for index in 0..<30 {
            try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("directory-\(index)/child"),
                                                     withIntermediateDirectories: true)
        }
        let probe = ContentReadProbe()
        let guardPolicy = FileContentReadGuard(cloudState: { _ in probe.recordProvider(); return nil })
        try FileContentReadPool.shared.read(at: fixture.root) { control in
            try guardPolicy.checkTree(fixture.root, control: control)
        }
        XCTAssertEqual(probe.providers, 0)
        for path in ["/Users/fixture/Library/Mobile Documents/folder", "/Users/fixture/Library/CloudStorage/provider/folder"] {
            XCTAssertTrue(guardPolicy.needsCloudState(URL(fileURLWithPath: path), true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(guardPolicy.needsCloudState(home.appendingPathComponent("Desktop"), true))
        XCTAssertTrue(guardPolicy.needsCloudState(home.appendingPathComponent("Documents"), true))
    }

    func testUserInitiatedReadsUseRequestedQoSAndRefuseMaterialization() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let reader = GuardedFileContentReader(priority: .userInitiated, willRead: { _ in
            // The OS may promote a queue while another thread waits for it.
            XCTAssertTrue([QOS_CLASS_USER_INITIATED, QOS_CLASS_USER_INTERACTIVE].contains(qos_class_self()))
            XCTAssertEqual(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD),
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        })
        XCTAssertEqual(try reader.sha256(fixture.file), Data(SHA256.hash(data: fixture.contents)))
        XCTAssertEqual(FoundationCleanupContentDigestReader().reader.priority, .userInitiated)
    }

    func testLargeApplicationSignatureAllowsColdSlowDiskButHasAFiniteDeadline() {
        let gib: Int64 = 1_073_741_824
        XCTAssertGreaterThanOrEqual(ExternalDriveMigrationService.applicationSignatureTimeout(sizeBytes: 2 * gib, readTimeout: 15), 1024)
        XCTAssertLessThanOrEqual(ExternalDriveMigrationService.applicationSignatureTimeout(sizeBytes: 100 * gib, readTimeout: 15), 1800)
        XCTAssertGreaterThan(ExternalDriveMigrationService.applicationSignatureTimeout(sizeBytes: 2 * gib, readTimeout: 15),
                             ExternalDriveMigrationService.applicationSignatureTimeout(sizeBytes: gib, readTimeout: 15))
    }

    func testProgressCallbackStopsCancelledOrTimedOutSystemCopyAndCleansOnlyAfterReturn() async throws {
        for cancels in [false, true] {
            let fixture = try MigrationContentFixture()
            defer { fixture.remove() }
            try Data(repeating: 0x58, count: 8 * 1_048_576).write(to: fixture.file)
            let staging = try MigrationStagingDirectory(parentURL: fixture.root)
            let target = staging.url.appendingPathComponent("copy.bin")
            let gate = ContentReadGate()
            defer { gate.release() }
            let entered = ContentReadProbe()
            let cleaned = XCTestExpectation(description: "abandoned copy cleaned")
            cleaned.assertForOverFulfill = true
            let cleanupCalls = ContentReadProbe()
            let copier = GuardedFileCopy(reader: .init(timeout: cancels ? 10 : 0.1), allowsCloning: false,
                progressObserver: { what, stage in
                    if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, entered.reads == 0 {
                        entered.recordRead()
                        XCTAssertEqual(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD),
                                       IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
                        gate.block()
                    }
                })
            let worker = Task.detached {
                try copier.copy(fixture.file, to: target, onFailure: {
                    XCTAssertTrue(gate.didReturn, "Cleanup may not race an active copyfile worker (M6)")
                    cleanupCalls.recordRead()
                    do { try staging.remove() } catch { XCTFail("Failed to remove owned staging: \(error)") }
                    cleaned.fulfill()
                })
            }
            await fulfillment(of: [gate.entered], timeout: 1)
            let start = ProcessInfo.processInfo.systemUptime
            if cancels { worker.cancel() }
            do { _ = try await worker.value; XCTFail("Abandoned copy returned publishable output") }
            catch {
                if cancels { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? FileContentReadError, .copyTimedOut) }
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
            XCTAssertFalse(gate.didReturn)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging.url.path))
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(cleanupCalls.reads, 0, "An asynchronous early cleanup must also be caught")
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging.url.path))
            gate.release()
            await fulfillment(of: [cleaned], timeout: 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.url.path))
            XCTAssertEqual(cleanupCalls.reads, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
        }
    }

    func testSystemErrorsAndSpecialFilesHaveChineseAndEnglishReasons() {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            for error in [POSIXError(.EACCES), .init(.EROFS), .init(.ENOTSUP), .init(.EFBIG)] {
                let message = FileContentReadError.userMessage(for: error)
                XCTAssertFalse(message.isEmpty)
                XCTAssertNotEqual(message, error.localizedDescription)
                if language == .zhHans { XCTAssertFalse(message.contains("Permission denied")) }
            }
            for reason in [FileContentReadError.tooDeep, .unsupportedType, .fileTooLarge, .invalidPath] {
                XCTAssertNotEqual(reason.localizedDescription, FileContentReadError.changed.localizedDescription)
                XCTAssertFalse(reason.localizedDescription.isEmpty)
            }
        }
    }
}
