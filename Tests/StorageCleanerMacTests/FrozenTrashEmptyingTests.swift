import Foundation
import XCTest
@testable import StorageCleanerMac

/// D101 L5: the menu's Empty Trash freezes the Trash when its confirmation
/// opens and, after D23's two confirmations, deletes only those entries
/// through D23's deleter. Fixtures live in an isolated folder only.
final class FrozenTrashEmptyingTests: XCTestCase {
    func testFreezeRecordsEachEntryWithTheIdentityTheDeleterCompares() throws {
        let trash = try makeTrash()
        try write(4_096, to: trash.appendingPathComponent("file.bin"))
        try write(8_192, to: trash.appendingPathComponent("Folder/nested/inner.bin"))
        try write(16, to: trash.appendingPathComponent(".DS_Store"))
        let outside = trash.deletingLastPathComponent().appendingPathComponent("outside.bin")
        try write(4_096, to: outside)
        try FileManager.default.createSymbolicLink(
            at: trash.appendingPathComponent("link"), withDestinationURL: outside)

        let frozen = try XCTUnwrap(CleanupService.freezeTrash(at: trash))

        XCTAssertEqual(frozen.trashURL, trash)
        XCTAssertEqual(frozen.trashIdentity, try FoundationCleanupPermanentDeleter.identity(at: trash))
        XCTAssertEqual(Set(frozen.entries.map(\.name)), ["file.bin", "Folder", ".DS_Store", "link"])
        for entry in frozen.entries {
            let identity = try FoundationCleanupPermanentDeleter.identity(at: trash.appendingPathComponent(entry.name))
            XCTAssertEqual(entry.identity, identity, entry.name)
        }
        XCTAssertEqual(frozen.entries.first { $0.name == "link" }?.identity.entryKind, .symbolicLink)
        XCTAssertEqual(frozen.entries.first { $0.name == "Folder" }?.identity.entryKind, .directory)
        XCTAssertGreaterThanOrEqual(frozen.entries.first { $0.name == "Folder" }?.allocatedBytes ?? 0, 8_192)
        XCTAssertEqual(frozen.summary.itemCount, 4)
        XCTAssertEqual(frozen.summary.totalBytes, frozen.entries.reduce(0) { $0 + $1.allocatedBytes })
        // Freezing only reads.
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Folder/nested/inner.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testEmptyingDeletesOnlyFrozenEntriesAndKeepsLaterOnes() async throws {
        let trash = try makeTrash()
        try write(4_096, to: trash.appendingPathComponent("old.bin"))
        try write(4_096, to: trash.appendingPathComponent("Old Folder/inner.bin"))
        let frozen = try XCTUnwrap(CleanupService.freezeTrash(at: trash))
        // Put in the Trash after the confirmation opened.
        try write(4_096, to: trash.appendingPathComponent("late.bin"))

        let result = await CleanupService.emptyFrozenTrash(frozen, deleter: FoundationCleanupPermanentDeleter())

        XCTAssertEqual(result, FrozenTrashEmptyResult(deletedCount: 2, deletedBytes: frozen.summary.totalBytes,
                                                      deletedNames: frozen.entries.map(\.name)))
        XCTAssertEqual(Set(result.deletedNames), ["old.bin", "Old Folder"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), ["late.bin"])
    }

    func testEntryReplacedUnderTheSameNameIsKeptAndSkipped() async throws {
        let trash = try makeTrash()
        let replaced = trash.appendingPathComponent("report.pdf")
        try write(4_096, to: replaced)
        try write(4_096, to: trash.appendingPathComponent("other.bin"))
        let frozen = try XCTUnwrap(CleanupService.freezeTrash(at: trash))
        try FileManager.default.removeItem(at: replaced)
        try write(2_048, to: replaced)
        let replacement = try XCTUnwrap(try FoundationCleanupPermanentDeleter.identity(at: replaced))

        let result = await CleanupService.emptyFrozenTrash(frozen, deleter: FoundationCleanupPermanentDeleter())

        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.deletedNames, ["other.bin"])
        XCTAssertEqual(try FoundationCleanupPermanentDeleter.identity(at: replaced), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash.appendingPathComponent("other.bin").path))
    }

    /// The Trash is swapped after the freeze for a link to a folder holding a
    /// hard link to the frozen entry, so the entry's identity still matches.
    func testTrashSwappedForALinkAfterTheFreezeDeletesNothing() async throws {
        let trash = try makeTrash()
        try write(4_096, to: trash.appendingPathComponent("entry.bin"))
        let frozen = try XCTUnwrap(CleanupService.freezeTrash(at: trash))
        let home = trash.deletingLastPathComponent()
        let moved = home.appendingPathComponent("Moved Trash")
        let elsewhere = home.appendingPathComponent("Elsewhere")
        try FileManager.default.moveItem(at: trash, to: moved)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.linkItem(
            at: moved.appendingPathComponent("entry.bin"), to: elsewhere.appendingPathComponent("entry.bin"))
        try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: elsewhere)

        let result = await CleanupService.emptyFrozenTrash(frozen, deleter: FoundationCleanupPermanentDeleter())

        XCTAssertEqual(result, FrozenTrashEmptyResult(skippedCount: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("entry.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("entry.bin").path))
    }

    /// The Trash is replaced by another real folder holding a hard link to the
    /// frozen entry.
    func testTrashReplacedByAnotherFolderDeletesNothing() async throws {
        let trash = try makeTrash()
        try write(4_096, to: trash.appendingPathComponent("entry.bin"))
        let frozen = try XCTUnwrap(CleanupService.freezeTrash(at: trash))
        let moved = trash.deletingLastPathComponent().appendingPathComponent("Moved Trash")
        try FileManager.default.moveItem(at: trash, to: moved)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.linkItem(
            at: moved.appendingPathComponent("entry.bin"), to: trash.appendingPathComponent("entry.bin"))

        let result = await CleanupService.emptyFrozenTrash(frozen, deleter: FoundationCleanupPermanentDeleter())

        XCTAssertEqual(result, FrozenTrashEmptyResult(skippedCount: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("entry.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("entry.bin").path))
    }

    func testLinkEntryIsRemovedWithoutMeasuringOrTouchingItsTarget() async throws {
        let trash = try makeTrash()
        let outside = trash.deletingLastPathComponent().appendingPathComponent("Outside")
        try write(1_048_576, to: outside.appendingPathComponent("keep.bin"))
        try FileManager.default.createSymbolicLink(
            at: trash.appendingPathComponent("folder-link"), withDestinationURL: outside)
        let frozen = try XCTUnwrap(CleanupService.freezeTrash(at: trash))
        XCTAssertLessThan(frozen.summary.totalBytes, 1_048_576)

        let result = await CleanupService.emptyFrozenTrash(frozen, deleter: FoundationCleanupPermanentDeleter())

        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.bin").path))
    }

    func testFreezeRefusesAnotherLocationOrALinkedTrashAndAMissingTrashIsNil() throws {
        let trash = try makeTrash()
        let home = trash.deletingLastPathComponent()
        func assertRefused(_ url: URL, line: UInt = #line) {
            XCTAssertThrowsError(try CleanupService.freezeTrash(at: url), line: line) { error in
                guard case CleanupServiceError.invalidTrashLocation = error else {
                    return XCTFail("Expected invalidTrashLocation, got \(error)", line: line)
                }
            }
        }
        assertRefused(home)

        try FileManager.default.removeItem(at: trash)
        XCTAssertNil(try CleanupService.freezeTrash(at: trash))

        let real = home.appendingPathComponent("Real")
        try write(16, to: real.appendingPathComponent("entry.bin"))
        try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: real)
        assertRefused(trash)

        // A link above the Trash is refused too.
        let realHome = home.appendingPathComponent("Real Home")
        try write(16, to: realHome.appendingPathComponent(".Trash/entry.bin"))
        let linkedHome = home.appendingPathComponent("Linked Home")
        try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: realHome)
        assertRefused(linkedHome.appendingPathComponent(".Trash"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent("entry.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: realHome.appendingPathComponent(".Trash/entry.bin").path))
    }

    func testEachDeletionCarriesTheFrozenIdentities() async {
        let frozen = FrozenTrash.testFixture(names: ["a", "b"])
        let deleter = ScriptedTrashDeleter()

        let result = await CleanupService.emptyFrozenTrash(frozen, deleter: deleter)

        let requests = deleter.requests
        XCTAssertEqual(requests.map(\.entryName), ["a", "b"])
        XCTAssertEqual(requests.map(\.entryIdentity), frozen.entries.map(\.identity))
        XCTAssertTrue(requests.allSatisfy { $0.trashURL == frozen.trashURL && $0.trashIdentity == frozen.trashIdentity })
        // The fixture's paths do not exist, so both entries are gone afterwards.
        XCTAssertEqual(result, FrozenTrashEmptyResult(deletedCount: 2, deletedBytes: frozen.summary.totalBytes,
                                                      deletedNames: ["a", "b"]))
    }

    /// A failed deletion, or one that leaves the entry in place, is a failure.
    func testDeletionCountsOnlyEntriesThatAreGone() async throws {
        let trash = try makeTrash()
        try write(4_096, to: trash.appendingPathComponent("stays.bin"))
        try write(4_096, to: trash.appendingPathComponent("fails.bin"))
        let frozen = try XCTUnwrap(CleanupService.freezeTrash(at: trash))

        let result = await CleanupService.emptyFrozenTrash(frozen, deleter: ScriptedTrashDeleter(failing: ["fails.bin"]))

        XCTAssertEqual(result, FrozenTrashEmptyResult(failedCount: 2))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: trash.path)), ["stays.bin", "fails.bin"])
    }

    @MainActor
    func testRequestFreezesThroughTheServiceAndOpensTheConfirmation() async throws {
        let frozen = FrozenTrash.testFixture(names: ["a"])
        let store = try ScanStore.makeForTests(for: self,
            scanHeavyWorkOperations: TestOperationFactory(for: self).scanOperations(freezeTrash: { frozen }),
            cleanupFeatureConfiguration: .legacy
        )

        store.requestEmptyTrash()
        XCTAssertTrue(store.isCheckingTrashSummary)
        try await waitUntil { !store.isCheckingTrashSummary }

        XCTAssertEqual(store.pendingEmptyTrash, frozen)
        XCTAssertFalse(store.isEmptyingTrash)
    }

    @MainActor
    func testEmptyOrMissingTrashDoesNotOpenTheConfirmation() async throws {
        for answer in [nil, FrozenTrash.testFixture(names: [])] as [FrozenTrash?] {
            let store = try ScanStore.makeForTests(for: self,
                scanHeavyWorkOperations: TestOperationFactory(for: self).scanOperations(freezeTrash: { answer }),
                cleanupFeatureConfiguration: .legacy
            )

            store.requestEmptyTrash()
            try await waitUntil { !store.isCheckingTrashSummary }

            XCTAssertNil(store.pendingEmptyTrash)
            XCTAssertEqual(store.actionMessage, L10n.text("废纸篓已经是空的", "Trash is already empty"))
        }
    }

    @MainActor
    func testConfirmationNeedsBothAcknowledgementsAndDeletesTheFrozenList() async throws {
        let frozen = FrozenTrash.testFixture(names: ["a", "b"])
        let received = ReceivedTrash()
        let outcome = FrozenTrashEmptyResult(deletedCount: 1, deletedBytes: 4_096, skippedCount: 1)
        let store = try ScanStore.makeForTests(for: self,
            scanHeavyWorkOperations: TestOperationFactory(for: self).scanOperations(emptyTrash: { trash in
                received.append(trash)
                return outcome
            }),
            cleanupFeatureConfiguration: .legacy
        )
        store.pendingEmptyTrash = frozen

        store.confirmEmptyTrash(acknowledgesPermanentDeletion: true, acknowledgesTrashContentsReviewed: false)
        store.confirmEmptyTrash(acknowledgesPermanentDeletion: false, acknowledgesTrashContentsReviewed: true)
        XCTAssertEqual(store.pendingEmptyTrash, frozen)
        XCTAssertFalse(store.isEmptyingTrash)

        store.confirmEmptyTrash(acknowledgesPermanentDeletion: true, acknowledgesTrashContentsReviewed: true)
        XCTAssertNil(store.pendingEmptyTrash)
        try await waitUntil { !store.isEmptyingTrash }

        XCTAssertEqual(received.values, [frozen])
        XCTAssertEqual(store.actionMessage, ScanStore.emptyTrashResultMessage(outcome))
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testFailedEntriesAreReportedAsAnError() async throws {
        let outcome = FrozenTrashEmptyResult(deletedCount: 1, deletedBytes: 4_096, failedCount: 1)
        let store = try ScanStore.makeForTests(for: self,
            scanHeavyWorkOperations: TestOperationFactory(for: self).scanOperations(emptyTrash: { _ in outcome }),
            cleanupFeatureConfiguration: .legacy
        )
        store.pendingEmptyTrash = FrozenTrash.testFixture(names: ["a", "b"])

        store.confirmEmptyTrash(acknowledgesPermanentDeletion: true, acknowledgesTrashContentsReviewed: true)
        try await waitUntil { !store.isEmptyingTrash }

        XCTAssertEqual(store.errorMessage, ScanStore.emptyTrashResultMessage(outcome))
    }

    func testResultMessageNamesKeptAndFailedEntries() {
        let outcome = FrozenTrashEmptyResult(deletedCount: 2, deletedBytes: 2_048, skippedCount: 1, failedCount: 3)
        withLanguage(.zhHans) {
            let message = ScanStore.emptyTrashResultMessage(outcome)
            XCTAssertTrue(message.hasPrefix("已清空废纸篓：2 项"), message)
            XCTAssertTrue(message.contains("1 项在确认后有变化，已保留"), message)
            XCTAssertTrue(message.contains("3 项未能删除"), message)
            XCTAssertEqual(ScanStore.emptyTrashResultMessage(FrozenTrashEmptyResult(deletedCount: 1, deletedBytes: 1))
                .components(separatedBy: "；").count, 1)
        }
        withLanguage(.english) {
            let message = ScanStore.emptyTrashResultMessage(outcome)
            XCTAssertTrue(message.contains("changed after confirmation and were kept"), message)
            XCTAssertTrue(message.contains("could not be deleted"), message)
        }
    }

    /// B-R3: after a partial result only the rows for deleted entries (and
    /// anything inside them) leave the scan result. An entry kept or not
    /// deleted stays listed, as does a row the freeze did not include.
    @MainActor
    func testOnlyDeletedEntriesLeaveTheScanResult() async throws {
        let frozen = FrozenTrash.testFixture(names: ["gone.bin", "Gone Folder", "kept.bin"])
        let outcome = FrozenTrashEmptyResult(deletedCount: 2, deletedBytes: 8_192, failedCount: 1,
                                             deletedNames: ["gone.bin", "Gone Folder"])
        let store = try ScanStore.makeForTests(for: self,
            scanHeavyWorkOperations: TestOperationFactory(for: self).scanOperations(emptyTrash: { _ in outcome }),
            cleanupFeatureConfiguration: .legacy
        )
        let trash = frozen.trashURL.path
        let other = StorageItem(
            id: "other", title: "Other", path: "/nonexistent-storage-cleaner-fixture/Library/Caches/big",
            sourceID: "caches", groupTitle: "Caches", sizeBytes: 4_096, tier: .green, kind: "folder",
            reason: "fixture", recommendation: "fixture", risk: "fixture", requiresClose: "", trashPaths: [],
            openPath: "/nonexistent-storage-cleaner-fixture/Library/Caches/big", status: .available
        )
        store.result = Self.scanResult(items: [
            "gone.bin", "Gone Folder", "Gone Folder/inner.bin", "gone.bin.partial", "kept.bin", "not frozen.bin",
        ].map { Self.trashRow(trash + "/" + $0) } + [other])
        store.pendingEmptyTrash = frozen

        store.confirmEmptyTrash(acknowledgesPermanentDeletion: true, acknowledgesTrashContentsReviewed: true)
        try await waitUntil { !store.isEmptyingTrash }

        XCTAssertEqual(Set(store.result?.items.filter { $0.sourceID == "trash_bins" }.map(\.path) ?? []),
                       Set(["gone.bin.partial", "kept.bin", "not frozen.bin"].map { trash + "/" + $0 }))
        XCTAssertEqual(store.result?.items.filter { $0.sourceID == "caches" }.map(\.id), [other.id])
        XCTAssertEqual(store.errorMessage, ScanStore.emptyTrashResultMessage(outcome))
    }

    // MARK: - Helpers

    private static func trashRow(_ path: String) -> StorageItem {
        StorageItem(
            id: path, title: URL(fileURLWithPath: path).lastPathComponent, path: path,
            sourceID: "trash_bins", groupTitle: "Trash", sizeBytes: 4_096, tier: .yellow, kind: "file",
            reason: "fixture", recommendation: "fixture", risk: "fixture", requiresClose: "", trashPaths: [],
            openPath: path, status: .available
        )
    }

    private static func scanResult(items: [StorageItem]) -> ScanResult {
        ScanResult(
            generatedAt: Date(), scanSeconds: 0.01,
            system: SystemSnapshot(osName: "macOS", build: "fixture", arch: "arm64", user: "fixture",
                home: "/nonexistent-storage-cleaner-fixture", filesystem: "APFS", purgeable: "", diskName: "Fixture",
                diskTotalBytes: 16_384, diskUsedBytes: 8_192, diskFreeBytes: 8_192),
            groups: [], items: items, deniedPaths: [])
    }

    private func makeTrash() throws -> URL {
        // Under the home folder: a temporary folder sits below `/var`, a
        // link, and the freeze refuses any link above the Trash.
        let home = TestFileSystem.uniqueOperationRoot("frozen-trash")
        TestFileSystem.registerCleanup(of: home, for: self)
        let trash = CleanupService.userTrashURL(homeDirectory: home)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return trash
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func withLanguage(_ language: AppLanguage, _ body: () throws -> Void) rethrows {
        let defaults = TestPreferenceDomain.make(for: self)
        defaults.set(language.rawValue, forKey: L10n.languageDefaultsKey)
        let preferences = TestVolatilePreferences()
        preferences.set(defaults.string(forKey: L10n.languageDefaultsKey) ?? language.rawValue,
            forKey: L10n.languageDefaultsKey)
        defer { preferences.restore() }
        XCTAssertEqual(L10n.usesChinese, language == .zhHans)
        try body()
    }
}

extension FrozenTrash {
    /// A frozen list whose paths do not exist; for code that never touches
    /// the file system, or a deleter that is faked.
    static func testFixture(names: [String]) -> FrozenTrash {
        FrozenTrash(
            trashURL: URL(fileURLWithPath: "/nonexistent-storage-cleaner-fixture/.Trash", isDirectory: true),
            trashIdentity: FileIdentity(deviceID: 7, inode: 1, entryKind: .directory, creationTimeNanoseconds: 1),
            entries: names.enumerated().map { index, name in
                FrozenTrash.Entry(
                    name: name,
                    identity: FileIdentity(deviceID: 7, inode: UInt64(index + 2), entryKind: .regularFile,
                                           creationTimeNanoseconds: Int64(index + 2)),
                    allocatedBytes: 4_096
                )
            }
        )
    }
}

/// Records each request; deletes nothing. Names in `failing` throw a
/// failure, as if part of the entry might already be gone.
private final class ScriptedTrashDeleter: CleanupPermanentDeleting, @unchecked Sendable {
    private let failing: Set<String>
    private let lock = NSLock()
    private var stored: [CleanupTrashEntryDeletion] = []

    init(failing: Set<String> = []) { self.failing = failing }

    var requests: [CleanupTrashEntryDeletion] { lock.withLock { stored } }

    func removeTrashEntry(_ deletion: CleanupTrashEntryDeletion) async throws {
        lock.withLock { stored.append(deletion) }
        if failing.contains(deletion.entryName) {
            throw CleanupTrashDeletionFailure.system(EIO)
        }
    }
}

private final class ReceivedTrash: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [FrozenTrash] = []

    var values: [FrozenTrash] { lock.withLock { stored } }

    func append(_ trash: FrozenTrash) { lock.withLock { stored.append(trash) } }
}
