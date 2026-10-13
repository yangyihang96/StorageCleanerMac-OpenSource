import Darwin
import XCTest
@testable import StorageCleanerMac

final class MigrationDurabilityTests: XCTestCase {
    func testMigrationFlushesTargetFilesAndPublicationParentsBeforeReturningProof() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let trace = FlushTrace()
        let system = MigrationDurability()
        let result = try fixture.migrate(durability: .init(flushOperation: { descriptor, directory in
            try trace.record(descriptor, directory: directory)
            try system.flushOperation(descriptor, directory)
        }, fullSyncOperation: { descriptor in
            try trace.recordBarrier(descriptor)
            try system.fullSyncOperation(descriptor)
        }))
        XCTAssertNil(result.publicationWarning)
        XCTAssertNotNil(result.contentVerification)
        let events = trace.events
        XCTAssertTrue(events.contains { !$0.directory && $0.path.contains(".partial/") && $0.path.hasSuffix("/source.bin") })
        XCTAssertTrue(events.contains { !$0.directory && $0.path == result.destinationURL.path })
        for parent in [result.destinationURL.deletingLastPathComponent(),
                       fixture.volume.url.appendingPathComponent("StorageCleaner Migration"), fixture.volume.url] {
            XCTAssertTrue(events.contains { $0.directory && $0.path == parent.path }, "Missing namespace sync: \(parent)")
        }
        XCTAssertEqual(events.last?.path, result.destinationURL.path)
        XCTAssertEqual(events.last?.directory, false)
        XCTAssertFalse(events.contains { $0.path == fixture.file.path }, "Never flush/write the original")
    }

    func testBundleDurabilityFlushesEveryRegularFileAndDoesNotFollowLinks() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("Fixture.app", isDirectory: true)
        let directory = source.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["one.bin", "two.bin"] { try fixture.contents.write(to: directory.appendingPathComponent(name)) }
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("outside-link").path,
                                                   withDestinationPath: fixture.file.path)
        let staging = try MigrationStagingDirectory(parentURL: fixture.root)
        defer { try? staging.remove() }
        let target = staging.url.appendingPathComponent("Fixture.app")
        let trace = FlushTrace()
        let system = MigrationDurability()
        let copier = GuardedFileCopy(reader: .init(), durability: .init(flushOperation: { descriptor, directory in
            try trace.record(descriptor, directory: directory)
            try system.flushOperation(descriptor, directory)
        }, fullSyncOperation: { descriptor in
            try trace.recordBarrier(descriptor)
            try system.fullSyncOperation(descriptor)
        }))
        let copied = try copier.copy(source, to: target, deferRootFlags: true)
        try copier.makeDurable(copied, at: target)
        let events = trace.events
        for name in ["one.bin", "two.bin"] {
            XCTAssertTrue(events.contains { !$0.directory && $0.path == target.appendingPathComponent("Contents/Resources/" + name).path })
        }
        for directory in [target, target.appendingPathComponent("Contents"), target.appendingPathComponent("Contents/Resources")] {
            XCTAssertTrue(events.contains { $0.directory && $0.path == directory.path })
        }
        XCTAssertFalse(events.contains { $0.path == fixture.file.path || $0.path.hasSuffix("outside-link") })
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
        XCTAssertEqual(trace.barriers.count, 1, "One device barrier after every inode fsync, not one per file")
    }

    func testFailedPrepublicationFullSyncNeverPublishesOrMovesOriginal() async throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let system = MigrationDurability()
        XCTAssertThrowsError(try fixture.migrate(durability: .init(fullSyncOperation: { descriptor in
            if try FlushTrace.path(descriptor).contains(".durability-probe-") { try system.fullSyncOperation(descriptor) }
            else { throw POSIXError(.EIO) }
        }))) {
            XCTAssertEqual(($0 as? POSIXError)?.code, .EIO)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path)).isEmpty,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try fixture.assertNoPartialOrPublishedCopy()
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
    }

    func testPostpublicationSyncFailureReturnsCopyWithWarningAndNoRemovalProof() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let system = MigrationDurability()
        let result = try fixture.migrate(durability: .init(flushOperation: { descriptor, directory in
            if try FlushTrace.path(descriptor) == fixture.destination.path { throw POSIXError(.EIO) }
            try system.flushOperation(descriptor, directory)
        }))
        XCTAssertNotNil(result.publicationWarning)
        XCTAssertNil(result.contentVerification)
        XCTAssertFalse(result.didMoveSourceToTrash)
        XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.contents)
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: result.destinationURL.deletingLastPathComponent().path),
                       [fixture.file.lastPathComponent])
    }

    func testCancellationOrTimeoutDuringSyncWaitsForWorkerBeforeCleanup() async throws {
        for cancels in [false, true] {
            let fixture = try MigrationContentFixture()
            defer { fixture.remove() }
            let staging = try MigrationStagingDirectory(parentURL: fixture.root)
            defer { try? staging.remove() }
            let target = staging.url.appendingPathComponent("copy.bin")
            let copied = try GuardedFileCopy(reader: .init()).copy(fixture.file, to: target)
            let gate = ContentReadGate()
            defer { gate.release() }
            let calls = ContentReadProbe()
            let cleanups = ContentReadProbe()
            let cleaned = XCTestExpectation(description: "abandoned sync cleaned after syscall returns")
            cleaned.assertForOverFulfill = true
            let copier = GuardedFileCopy(reader: .init(timeout: cancels ? 10 : 0.1),
                durability: .init(flushOperation: { _, _ in
                    XCTAssertEqual(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD),
                                   IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
                    if calls.reads == 0 { calls.recordRead(); gate.block() }
                }, timeout: cancels ? 10 : 0.1))
            let worker = Task.detached {
                try copier.makeDurable(copied, at: target, onFailure: {
                    XCTAssertTrue(gate.didReturn)
                    cleanups.recordRead()
                    do { try staging.remove() } catch { XCTFail("Cleanup failed: \(error)") }
                    cleaned.fulfill()
                })
            }
            await fulfillment(of: [gate.entered], timeout: 1)
            let start = ProcessInfo.processInfo.systemUptime
            if cancels { worker.cancel() }
            do { _ = try await worker.value; XCTFail("Abandoned sync returned success") }
            catch {
                if cancels { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? FileContentReadError, .writingTimedOut) }
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertFalse(gate.didReturn)
            XCTAssertEqual(cleanups.reads, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging.url.path))
            gate.release()
            await fulfillment(of: [cleaned], timeout: 1)
            XCTAssertEqual(cleanups.reads, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.url.path))
            XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
        }
    }

    func testHandlingOriginalRefusesSyncFailureBeforeAnyReceiptOrMove() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let copied = try fixture.migrate()
        var persisted = 0
        XCTAssertThrowsError(try ExternalDriveMigrationService.moveOriginalToTrash(fixture.item,
            verifiedCopyAt: copied.destinationURL, on: fixture.volume, trustedVolumes: [fixture.volume],
            trashOperation: { _ in XCTFail("Cannot move before durability succeeds"); return nil },
            persist: { _, _ in persisted += 1 }, contentVerification: copied.contentVerification,
            durability: .init(flushOperation: { _, _ in throw POSIXError(.ENOTSUP) }))) {
            XCTAssertEqual(($0 as? POSIXError)?.code, .ENOTSUP)
        }
        XCTAssertEqual(persisted, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
        XCTAssertEqual(try Data(contentsOf: copied.destinationURL), fixture.contents)
    }

    func testOriginalMovesOnlyAfterDestinationAndParentSyncs() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let copied = try fixture.migrate()
        let trace = FlushTrace()
        let system = MigrationDurability()
        let trash = fixture.root.appendingPathComponent("simulated-trash.bin")
        let result = try ExternalDriveMigrationService.moveOriginalToTrash(fixture.item,
            verifiedCopyAt: copied.destinationURL, on: fixture.volume, trustedVolumes: [fixture.volume],
            trashOperation: { url in
                let events = trace.events
                XCTAssertEqual(events.last?.path, copied.destinationURL.path)
                XCTAssertEqual(events.last?.directory, false)
                XCTAssertTrue(events.contains { $0.directory && $0.path == copied.destinationURL.deletingLastPathComponent().path })
                try FileManager.default.moveItem(at: url, to: trash)
                return trash
            }, journal: CleanupReportJournal(directory: fixture.root.appendingPathComponent("journal")),
            contentVerification: copied.contentVerification,
            durability: .init(flushOperation: { descriptor, directory in
                try trace.record(descriptor, directory: directory)
                try system.flushOperation(descriptor, directory)
            }, fullSyncOperation: { descriptor in
                try trace.recordBarrier(descriptor)
                try system.fullSyncOperation(descriptor)
            }))
        XCTAssertTrue(result.canRestoreFromHistory)
        XCTAssertEqual(result.report?.summary.unverifiedMoveCount, 0)
        XCTAssertEqual(try Data(contentsOf: trash), fixture.contents)
    }

    func testCommittedSyncIgnoresLateCancellationWithoutRemovingPublishedCopy() async throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let gate = ContentReadGate()
        defer { gate.release() }
        let calls = ContentReadProbe()
        let system = MigrationDurability()
        let durability = MigrationDurability(flushOperation: { descriptor, directory in
            if try FlushTrace.path(descriptor) == fixture.destination.path, calls.reads == 0 {
                calls.recordRead()
                gate.block()
            }
            try system.flushOperation(descriptor, directory)
        })
        let worker = Task.detached { try fixture.migrate(durability: durability) }
        await fulfillment(of: [gate.entered], timeout: 1)
        worker.cancel()
        gate.release()
        let result = try await worker.value
        XCTAssertEqual(result.destinationURL, fixture.destination)
        XCTAssertFalse(result.didMoveSourceToTrash)
        XCTAssertNil(result.publicationWarning)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.contents)
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
    }

    func testMutationDuringDurabilityWaitCannotRebindAnOldDigest() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let injected = ContentReadProbe()
        let reads = ContentReadProbe()
        let system = MigrationDurability()
        let durability = MigrationDurability(flushOperation: { descriptor, directory in
            let path = try FlushTrace.path(descriptor)
            if !directory, path.contains(".partial/"), path.hasSuffix("/source.bin"), injected.reads == 0 {
                injected.recordRead()
                var status = stat()
                XCTAssertEqual(fstat(descriptor, &status), 0)
                let url = URL(fileURLWithPath: path)
                let handle = try FileHandle(forWritingTo: url)
                try handle.write(contentsOf: Data(repeating: 0x59, count: fixture.contents.count))
                try handle.close()
                let times = [status.st_atimespec, status.st_mtimespec]
                XCTAssertEqual(times.withUnsafeBufferPointer {
                    utimensat(AT_FDCWD, path, $0.baseAddress, AT_SYMLINK_NOFOLLOW)
                }, 0)
            }
            try system.flushOperation(descriptor, directory)
        })
        let result = try fixture.migrate(reader: .init(willRead: { _ in reads.recordRead() }), durability: durability)
        XCTAssertEqual(injected.reads, 1)
        XCTAssertNil(result.contentVerification, "H must not widen F's ctime exception across the sync wait")
        XCTAssertGreaterThan(reads.reads, 3, "The changed copy must be rehashed after publication")
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
        XCTAssertEqual(try Data(contentsOf: result.destinationURL), Data(repeating: 0x59, count: fixture.contents.count))
    }

    func testManyFileSyncInspectsTheRootOnceAndUsesOneFinalDeviceBarrier() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("tree", isDirectory: true)
        let folder = source.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<32 { try fixture.contents.write(to: folder.appendingPathComponent("file-\(index).bin")) }
        let staging = try MigrationStagingDirectory(parentURL: fixture.root)
        defer { try? staging.remove() }
        let target = staging.url.appendingPathComponent("tree")
        let copied = try GuardedFileCopy(reader: .init()).copy(source, to: target)
        let inspections = ContentReadProbe()
        let synced = FlushTrace()
        let system = MigrationDurability()
        let policy = MigrationDurability(flushOperation: { descriptor, directory in
            try synced.record(descriptor, directory: directory)
            try system.flushOperation(descriptor, directory)
        }, fullSyncOperation: { descriptor in
            XCTAssertEqual(synced.events.filter { !$0.directory }.count, 32, "All files must fsync before the barrier")
            XCTAssertEqual(synced.events.filter { $0.directory }.count, 2, "Directories must fsync after their children")
            try synced.recordBarrier(descriptor)
            try system.fullSyncOperation(descriptor)
        }, pathInspectionOperation: { url in
            inspections.recordRead()
            return system.pathInspectionOperation(url)
        })
        let information = try GuardedFileCopy(reader: .init(), durability: policy).makeDurable(copied, at: target)
        XCTAssertTrue(information.isEmpty)
        XCTAssertEqual(inspections.reads, 1, "Do not inspect all absolute ancestor paths for each file")
        XCTAssertEqual(synced.barriers.count, 1)
        XCTAssertEqual(synced.events.filter { !$0.directory }.count, 33, "32 inode syncs plus one final device barrier")
        XCTAssertEqual(synced.events.last?.path, synced.barriers.last)
        XCTAssertFalse(synced.events.contains { $0.path.hasPrefix(source.path + "/") })
    }

    func testDescriptorTraversalRejectsDirectoryReplacementWithoutFollowingTheNewLink() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("tree/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try fixture.contents.write(to: source.appendingPathComponent("file.bin"))
        let staging = try MigrationStagingDirectory(parentURL: fixture.root)
        defer { try? staging.remove() }
        let target = staging.url.appendingPathComponent("tree")
        let copied = try GuardedFileCopy(reader: .init()).copy(source.deletingLastPathComponent(), to: target)
        let trace = FlushTrace()
        let changed = ContentReadProbe()
        let system = MigrationDurability()
        let copier = GuardedFileCopy(reader: .init(), durability: .init(flushOperation: { descriptor, directory in
            let path = try FlushTrace.path(descriptor)
            if path == target.appendingPathComponent("nested/file.bin").path, changed.reads == 0 {
                changed.recordRead()
                try FileManager.default.moveItem(at: target.appendingPathComponent("nested"),
                                                 to: fixture.root.appendingPathComponent("detached"))
                try FileManager.default.createSymbolicLink(atPath: target.appendingPathComponent("nested").path,
                                                           withDestinationPath: fixture.root.path)
            }
            try trace.record(descriptor, directory: directory)
            try system.flushOperation(descriptor, directory)
        }))
        XCTAssertThrowsError(try copier.makeDurable(copied, at: target)) {
            XCTAssertEqual($0 as? FileContentReadError, .changed)
        }
        XCTAssertEqual(changed.reads, 1)
        XCTAssertFalse(trace.events.contains { $0.path == fixture.file.path })
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
    }

    func testSlowSyncUsesItsOwnBudgetWithoutChangingCopyTimeout() async throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let staging = try MigrationStagingDirectory(parentURL: fixture.root)
        defer { try? staging.remove() }
        let target = staging.url.appendingPathComponent("copy.bin")
        let copied = try GuardedFileCopy(reader: .init()).copy(fixture.file, to: target)
        let gate = ContentReadGate()
        defer { gate.release() }
        let entered = ContentReadProbe()
        let system = MigrationDurability()
        let copier = GuardedFileCopy(reader: .init(timeout: 0.1), durability: .init(flushOperation: { descriptor, directory in
            if entered.reads == 0 { entered.recordRead(); gate.block() }
            try system.flushOperation(descriptor, directory)
        }))
        let worker = Task.detached { try copier.makeDurable(copied, at: target) }
        await fulfillment(of: [gate.entered], timeout: 1)
        try await Task.sleep(for: .milliseconds(300))
        gate.release()
        let information = try await worker.value
        XCTAssertTrue(information.isEmpty)
        XCTAssertEqual(copier.reader.timeout, 0.1, "The copy/read watchdog has not changed")
        XCTAssertEqual(system.timeBudget(bytes: 512 * 1_048_576, minimum: 15), 572)
        XCTAssertEqual(system.timeBudget(bytes: Int64.max, minimum: 15), 3_600)
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
    }

    func testUnsupportedDeviceFlushIsProbedBeforeCopyAndRecordedWithoutBlockingProof() throws {
        for code in [POSIXErrorCode.ENOTSUP, .ENOSYS, .EINVAL] {
            let fixture = try MigrationContentFixture()
            defer { fixture.remove() }
            let calls = ContentReadProbe()
            let system = MigrationDurability()
            let result = try fixture.migrate(durability: .init(fullSyncOperation: { descriptor in
                calls.recordRead()
                let path = try FlushTrace.path(descriptor)
                XCTAssertTrue(path.contains(".partial/.durability-probe-"))
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [URL(fileURLWithPath: path).lastPathComponent],
                               "Capability must be known before any source copy exists")
                throw POSIXError(code)
            }))
            XCTAssertEqual(calls.reads, 1, "Unsupported capability is reused for both sync phases")
            XCTAssertNil(result.publicationWarning)
            XCTAssertNotNil(result.contentVerification)
            XCTAssertEqual(result.information, [MigrationDurability.fallbackInformation])
            XCTAssertTrue(result.noticeMessage(fallback: "verified").contains(MigrationDurability.fallbackInformation))
            XCTAssertFalse(result.didMoveSourceToTrash)
            XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.contents)
            XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
            let file = GuardedFileCopy.PreparedCopy(entries: [], deferredFlags: 0)
            let notes = try GuardedFileCopy(reader: .init(), durability: .init(fullSyncOperation: { _ in throw POSIXError(code) }))
                .makeDurable(file, at: result.destinationURL, volumeRoot: fixture.volume.url)
            XCTAssertEqual(notes, [MigrationDurability.fallbackInformation])
            XCTAssertGreaterThan(system.timeBudget(bytes: Int64(fixture.contents.count), minimum: 15), 15)
        }
    }

    func testDeviceProbeIOFailureStopsBeforeReadingOrCopyingSource() async throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let reads = ContentReadProbe()
        XCTAssertThrowsError(try fixture.migrate(reader: .init(willRead: { _ in reads.recordRead() }),
            durability: .init(fullSyncOperation: { _ in throw POSIXError(.EIO) }))) {
            XCTAssertEqual(($0 as? POSIXError)?.code, .EIO)
        }
        XCTAssertEqual(reads.reads, 0)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path)).isEmpty,
              ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try fixture.assertNoPartialOrPublishedCopy()
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
    }

    func testPostpublicationDurabilityMessageExplainsExistingCopyAndNextActionInBothLanguages() throws {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            let fixture = try MigrationContentFixture()
            defer { fixture.remove() }
            let system = MigrationDurability()
            let result = try fixture.migrate(durability: .init(flushOperation: { descriptor, directory in
                if try FlushTrace.path(descriptor) == fixture.destination.path { throw POSIXError(.EIO) }
                try system.flushOperation(descriptor, directory)
            }))
            let warning = try XCTUnwrap(result.publicationWarning)
            XCTAssertTrue(warning.contains(language == .zhHans ? "副本已生成" : "The copy exists"))
            XCTAssertTrue(warning.contains(language == .zhHans ? "从列表处理原件" : "handle the original from the list"))
            XCTAssertTrue(warning.contains(language == .zhHans ? "不要重新复制到同一位置" : "Do not copy again to the same location"))
            XCTAssertFalse(warning.contains(language == .zhHans ? "请重试" : "Retry."))
            XCTAssertNil(result.contentVerification)
            XCTAssertFalse(result.didMoveSourceToTrash)
            XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.contents)
            XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
        }
    }

    func testCancelledCapabilityProbeKeepsStagingUntilItsWorkerReturns() async throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let staging = try MigrationStagingDirectory(parentURL: fixture.root)
        defer { try? staging.remove() }
        let gate = ContentReadGate()
        defer { gate.release() }
        let cleanups = ContentReadProbe()
        let cleaned = XCTestExpectation(description: "probe worker cleaned its own staging")
        cleaned.assertForOverFulfill = true
        let copier = GuardedFileCopy(reader: .init(), durability: .init(fullSyncOperation: { _ in gate.block() }))
        let worker = Task.detached {
            try copier.probeDurability(at: staging.url, onFailure: {
                XCTAssertTrue(gate.didReturn)
                cleanups.recordRead()
                do { try staging.remove() } catch { XCTFail("Probe cleanup failed: \(error)") }
                cleaned.fulfill()
            })
        }
        await fulfillment(of: [gate.entered], timeout: 1)
        let start = ProcessInfo.processInfo.systemUptime
        worker.cancel()
        do { _ = try await worker.value; XCTFail("Cancelled probe returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(cleanups.reads, 0)
        XCTAssertFalse(gate.didReturn)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.url.path))
        gate.release()
        await fulfillment(of: [cleaned], timeout: 1)
        XCTAssertEqual(cleanups.reads, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.url.path))
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
    }

    private final class FlushTrace: @unchecked Sendable {
        struct Event: Sendable { let path: String; let directory: Bool }
        private let lock = NSLock()
        private var recorded: [Event] = []
        private var recordedBarriers: [String] = []
        var events: [Event] { lock.withLock { recorded } }
        var barriers: [String] { lock.withLock { recordedBarriers } }
        func record(_ descriptor: Int32, directory: Bool) throws {
            let value = Event(path: try Self.path(descriptor), directory: directory)
            lock.withLock { recorded.append(value) }
        }
        func recordBarrier(_ descriptor: Int32) throws {
            let path = try Self.path(descriptor)
            lock.withLock { recorded.append(Event(path: path, directory: false)); recordedBarriers.append(path) }
        }
        static func path(_ descriptor: Int32) throws -> String {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let result = buffer.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
            guard result == 0 else { throw POSIXError(.EIO) }
            return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
    }
}
