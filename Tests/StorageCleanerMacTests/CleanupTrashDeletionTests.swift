import Foundation
import XCTest
@testable import StorageCleanerMac

/// P2-3: emptying the Trash deletes each frozen entry relative to the Trash
/// folder opened without following links, after checking that folder is the
/// one seen at scan time. Fixtures live in temporary folders only.
final class CleanupTrashDeletionTests: XCTestCase {
    /// The Trash is swapped for a link to another folder right after the last
    /// identity check (inside the deletion call). That folder holds a hard
    /// link to the frozen file, so its identity still matches. Nothing outside
    /// the Trash may be deleted.
    func testDeletionRefusesATrashSwappedAfterTheLastCheck() async throws {
        let fixture = try makeFixture()
        let trash = fixture.home.appendingPathComponent(".Trash")
        try write(bytes: 8_192, to: trash.appendingPathComponent("old.bin"))
        let rules = CleanupRuleSet(
            schemaVersion: 2,
            rulesVersion: "trash.fixture",
            rules: [CleanupCoverageCatalog.userTrashRule]
        )
        let session = try await ReadOnlyCleanupScanner(
            fileSystem: TrashDeletionFixtureFileSystem(),
            ruleSet: rules,
            applicationsURL: fixture.root.appendingPathComponent("Applications")
        ).scan(request: CleanupScanRequest(userHomeURL: fixture.home)) { _ in }
        let trashCandidate = try XCTUnwrap(session.candidates.first)
        var selection = CleanupSelection()
        selection.setCandidate(trashCandidate.id, selected: true, in: session)
        let plan = try CleanPlanBuilder.makePlan(
            session: session,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )
        let elsewhere = fixture.root.appendingPathComponent("Elsewhere")
        let deleter = TrashSwappingDeleter(
            trash: trash,
            movedTrash: fixture.root.appendingPathComponent("Moved Trash"),
            elsewhere: elsewhere
        )
        let executor = SafeCleanupExecutor(
            metadataReader: TrashDeletionFixtureFileSystem(),
            deleter: deleter,
            coordinator: HeavyWorkCoordinator()
        )

        let report = await executor.execute(
            plan: plan,
            context: CleanupExecutionContext(
                featureConfiguration: .productDefault,
                activeSessionID: session.id,
                activeRules: rules,
                userHomeURL: fixture.home,
                excludedURLs: [],
                approvedPlanItemIDs: Set(plan.items.map(\.id))
            )
        ) { _ in }

        XCTAssertTrue(deleter.didSwap)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("old.bin").path),
            "A file outside the Trash was deleted through the swapped link"
        )
        // Refused before anything was deleted, so it is a skip with its
        // reason rather than an unknown outcome.
        XCTAssertEqual(report.items.first?.outcome, .skipped(.pathOutsideAllowedRoot))
        XCTAssertEqual(report.summary.deletedItemCount, 0)
    }

    /// Folders are emptied level by level without following links: a link
    /// inside is removed itself and its target stays.
    func testDeleterRemovesNestedFoldersWithoutFollowingLinks() throws {
        let fixture = try makeFixture()
        let trash = fixture.home.appendingPathComponent(".Trash")
        let folder = trash.appendingPathComponent("Folder")
        try write(bytes: 4_096, to: folder.appendingPathComponent("a/b/c/inner.bin"))
        let outside = fixture.root.appendingPathComponent("Outside")
        try write(bytes: 4_096, to: outside.appendingPathComponent("keep.bin"))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("a/link-to-folder"),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("link-to-file"),
            withDestinationURL: outside.appendingPathComponent("keep.bin")
        )
        let fileLink = trash.appendingPathComponent("file-link")
        try FileManager.default.createSymbolicLink(
            at: fileLink,
            withDestinationURL: outside.appendingPathComponent("keep.bin")
        )

        try FoundationCleanupPermanentDeleter.remove(deletion(trash: trash, entry: folder))
        try FoundationCleanupPermanentDeleter.remove(deletion(trash: trash, entry: fileLink))

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: fileLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.bin").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [])
    }

    /// Nothing is deleted when the Trash folder or the entry is not the one
    /// recorded at scan time.
    func testDeleterRefusesAnotherTrashFolderOrEntry() throws {
        let fixture = try makeFixture()
        let trash = fixture.home.appendingPathComponent(".Trash")
        let entry = trash.appendingPathComponent("entry.bin")
        try write(bytes: 4_096, to: entry)
        let scanned = try deletion(trash: trash, entry: entry)

        let otherTrash = CleanupTrashEntryDeletion(
            trashURL: scanned.trashURL,
            trashIdentity: FileIdentity(
                deviceID: scanned.trashIdentity.deviceID,
                inode: scanned.trashIdentity.inode + 1,
                entryKind: .directory,
                creationTimeNanoseconds: scanned.trashIdentity.creationTimeNanoseconds
            ),
            entryName: scanned.entryName,
            entryIdentity: scanned.entryIdentity
        )
        XCTAssertThrowsError(try FoundationCleanupPermanentDeleter.remove(otherTrash)) {
            XCTAssertEqual($0 as? CleanupTrashDeletionRefusal, .trashChanged)
        }

        // Same name, new file: not the frozen entry.
        try FileManager.default.removeItem(at: entry)
        try write(bytes: 1_024, to: entry)
        XCTAssertThrowsError(try FoundationCleanupPermanentDeleter.remove(scanned)) {
            XCTAssertEqual($0 as? CleanupTrashDeletionRefusal, .entryChanged)
        }

        let escaping = CleanupTrashEntryDeletion(
            trashURL: scanned.trashURL,
            trashIdentity: scanned.trashIdentity,
            entryName: "../entry.bin",
            entryIdentity: scanned.entryIdentity
        )
        XCTAssertThrowsError(try FoundationCleanupPermanentDeleter.remove(escaping)) {
            XCTAssertEqual($0 as? CleanupTrashDeletionRefusal, .entryChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path))
    }

    /// A folder inside the entry that cannot be opened stops the deletion
    /// part-way. That is a failure, not a refusal, so the receipt says the
    /// deletion did not finish and needs verification.
    func testDeletionThatStopsPartWayIsRecordedAsUnfinished() async throws {
        let fixture = try makeFixture()
        let trash = fixture.home.appendingPathComponent(".Trash")
        let folder = trash.appendingPathComponent("Folder")
        try write(bytes: 8_192, to: folder.appendingPathComponent("readable.bin"))
        let locked = folder.appendingPathComponent("locked")
        try write(bytes: 4_096, to: locked.appendingPathComponent("inner.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        let rules = CleanupRuleSet(
            schemaVersion: 2,
            rulesVersion: "trash.fixture",
            rules: [CleanupCoverageCatalog.userTrashRule]
        )
        let session = try await ReadOnlyCleanupScanner(
            fileSystem: TrashDeletionFixtureFileSystem(),
            ruleSet: rules,
            applicationsURL: fixture.root.appendingPathComponent("Applications")
        ).scan(request: CleanupScanRequest(userHomeURL: fixture.home)) { _ in }
        let trashCandidate = try XCTUnwrap(session.candidates.first)
        var selection = CleanupSelection()
        selection.setCandidate(trashCandidate.id, selected: true, in: session)
        let plan = try CleanPlanBuilder.makePlan(
            session: session,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )
        let report = await SafeCleanupExecutor(
            metadataReader: TrashDeletionFixtureFileSystem(),
            coordinator: HeavyWorkCoordinator()
        ).execute(
            plan: plan,
            context: CleanupExecutionContext(
                featureConfiguration: .productDefault,
                activeSessionID: session.id,
                activeRules: rules,
                userHomeURL: fixture.home,
                excludedURLs: [],
                approvedPlanItemIDs: Set(plan.items.map(\.id))
            )
        ) { _ in }

        guard case let .failed(failure) = report.items.first?.outcome else {
            return XCTFail("\(String(describing: report.items.first?.outcome))")
        }
        XCTAssertEqual(failure.code, .deletionOutcomeUnknown)
        XCTAssertEqual(report.summary.deletedItemCount, 0)
        XCTAssertEqual(OperationResultPresentation(report: report).state, .needsVerification)
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path))

        // The deleter itself reports this as a failure, not a refusal.
        XCTAssertThrowsError(try FoundationCleanupPermanentDeleter.remove(deletion(trash: trash, entry: folder))) {
            XCTAssertEqual($0 as? CleanupTrashDeletionFailure, .system(EACCES))
            XCTAssertNil($0 as? CleanupTrashDeletionRefusal)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path))
    }

    /// Same boundary as B-R2 in the menu command: the deleter reports success
    /// but only takes away access to the Trash, so the entry cannot be read
    /// back. That is not evidence it is gone, so it is not counted deleted.
    func testAFailedReadbackAfterDeletionIsNotCountedAsDeleted() async throws {
        let fixture = try makeFixture()
        let trash = fixture.home.appendingPathComponent(".Trash")
        let entry = trash.appendingPathComponent("old.bin")
        try write(bytes: 8_192, to: entry)
        let rules = CleanupRuleSet(
            schemaVersion: 2,
            rulesVersion: "trash.fixture",
            rules: [CleanupCoverageCatalog.userTrashRule]
        )
        let session = try await ReadOnlyCleanupScanner(
            fileSystem: TrashDeletionFixtureFileSystem(),
            ruleSet: rules,
            applicationsURL: fixture.root.appendingPathComponent("Applications")
        ).scan(request: CleanupScanRequest(userHomeURL: fixture.home)) { _ in }
        let trashCandidate = try XCTUnwrap(session.candidates.first)
        var selection = CleanupSelection()
        selection.setCandidate(trashCandidate.id, selected: true, in: session)
        let plan = try CleanPlanBuilder.makePlan(
            session: session,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trash.path)
        }

        let report = await SafeCleanupExecutor(
            metadataReader: TrashDeletionFixtureFileSystem(),
            deleter: ReadbackDeniedTrashDeleter(),
            coordinator: HeavyWorkCoordinator()
        ).execute(
            plan: plan,
            context: CleanupExecutionContext(
                featureConfiguration: .productDefault,
                activeSessionID: session.id,
                activeRules: rules,
                userHomeURL: fixture.home,
                excludedURLs: [],
                approvedPlanItemIDs: Set(plan.items.map(\.id))
            )
        ) { _ in }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trash.path)

        XCTAssertEqual(plan.permanentDeletionItems.count, 1)
        guard case let .failed(failure) = report.items.first?.outcome else {
            return XCTFail("\(String(describing: report.items.first?.outcome))")
        }
        XCTAssertEqual(failure, CleanFailure(code: .deletionOutcomeUnknown, detailCode: "deletion-readback-failed"))
        XCTAssertEqual(report.summary.deletedItemCount, 0)
        XCTAssertEqual(OperationResultPresentation(report: report).state, .needsVerification)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path), "The fake deleter leaves the entry in place")
    }

    // MARK: - Fixtures

    private func deletion(trash: URL, entry: URL) throws -> CleanupTrashEntryDeletion {
        let reader = FoundationReadOnlyFileSystem()
        return CleanupTrashEntryDeletion(
            trashURL: trash,
            trashIdentity: try reader.snapshot(at: trash).identity,
            entryName: entry.lastPathComponent,
            entryIdentity: try reader.aggregateSnapshot(at: entry).identity
        )
    }

    private struct Fixture {
        let root: URL
        let home: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerTrashDeletion-\(UUID().uuidString)")
        let home = root.appendingPathComponent("Home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root, home: home)
    }

    private func write(bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }
}

/// Temporary fixtures live under `/var`, a symbolic link on macOS, so
/// ancestor links are ignored; links inside the fixture are still reported
/// through the entry kind.
private struct TrashDeletionFixtureFileSystem: ReadOnlyFileSystem {
    func snapshot(at url: URL) throws -> FileSnapshot {
        let snapshot = try FoundationReadOnlyFileSystem().snapshot(at: url)
        return FileSnapshot(
            identity: snapshot.identity,
            standardizedPath: snapshot.standardizedPath,
            volumeIdentifier: snapshot.volumeIdentifier,
            logicalSizeBytes: snapshot.logicalSizeBytes,
            allocatedSizeBytes: snapshot.allocatedSizeBytes,
            modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
            isWritableVolume: snapshot.isWritableVolume,
            isCloudItem: snapshot.isCloudItem,
            isCloudPlaceholder: snapshot.isCloudPlaceholder,
            hasSymbolicLinkComponent: false
        )
    }

    func children(of directory: URL) throws -> [URL] {
        try FoundationReadOnlyFileSystem().children(of: directory)
    }
}

/// Swaps the Trash for a link to another folder (holding a hard link to each
/// entry, so identities still match), then runs the production deleter.
private final class TrashSwappingDeleter: CleanupPermanentDeleting, @unchecked Sendable {
    private let trash: URL
    private let movedTrash: URL
    private let elsewhere: URL
    private let lock = NSLock()
    private var swapped = false

    init(trash: URL, movedTrash: URL, elsewhere: URL) {
        self.trash = trash
        self.movedTrash = movedTrash
        self.elsewhere = elsewhere
    }

    var didSwap: Bool { lock.withLock { swapped } }

    func removeTrashEntry(_ deletion: CleanupTrashEntryDeletion) async throws {
        try swap()
        try await FoundationCleanupPermanentDeleter().removeTrashEntry(deletion)
    }

    private func swap() throws {
        let fileManager = FileManager.default
        try fileManager.moveItem(at: trash, to: movedTrash)
        try fileManager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        for name in try fileManager.contentsOfDirectory(atPath: movedTrash.path) {
            try fileManager.linkItem(
                at: movedTrash.appendingPathComponent(name),
                to: elsewhere.appendingPathComponent(name)
            )
        }
        try fileManager.createSymbolicLink(at: trash, withDestinationURL: elsewhere)
        lock.withLock { swapped = true }
    }
}

/// Reports success but deletes nothing: it only takes away access to the
/// fixture's Trash, so reading the entry back fails with EACCES.
private struct ReadbackDeniedTrashDeleter: CleanupPermanentDeleting {
    func removeTrashEntry(_ deletion: CleanupTrashEntryDeletion) async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: deletion.trashURL.path)
    }
}
