import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

/// D181: the Trash folder on each other mounted volume is emptied like
/// `~/.Trash` (D23): one red row per drive, never preselected, only the
/// entries frozen at scan time, each re-verified, and nothing when the drive
/// was ejected or replaced. 10-23 CleanMyMac counted 18.4 GB of Trash on the
/// user's Mac against our 54 MiB, which only looked at `~/.Trash`.
final class VolumeTrashTests: XCTestCase {
    private let uid = getuid()

    func testOnlyTheUsersOwnTrashFolderDirectlyOnAVolumeQualifies() {
        XCTAssertTrue(VolumeTrashLocator.isTrashPath("/Volumes/Storage/.Trashes/\(uid)", uid: uid))
        XCTAssertTrue(VolumeTrashLocator.isTrashPath("/Volumes/My Drive/.Trashes/\(uid)", uid: uid))
        for path in ["/Volumes/Storage/.Trashes/\(uid + 1)", "/Volumes/Storage/.Trashes",
                     "/Volumes/Storage/.Trash/\(uid)", "/Volumes/Storage/x/.Trashes/\(uid)",
                     "/Volumes/../.Trashes/\(uid)", "/Volumes/./.Trashes/\(uid)", "/Volumes/.hidden/.Trashes/\(uid)",
                     "/Volumes//.Trashes/\(uid)", "/Users/someone/.Trashes/\(uid)", "Volumes/Storage/.Trashes/\(uid)",
                     "/Volumes/Storage/.Trashes/\(uid)/"] {
            XCTAssertFalse(VolumeTrashLocator.isTrashPath(path, uid: uid), path)
        }
        XCTAssertEqual(VolumeTrashLocator.volumeName(ofTrashPath: "/Volumes/Storage/.Trashes/\(uid)"), "Storage")
        XCTAssertNil(VolumeTrashLocator.volumeName(ofTrashPath: "/Users/someone/.Trash"))
        XCTAssertFalse(VolumeTrashLocator().isValidTrash(
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(".Trashes/\(uid)"), uid: uid),
            "anything outside /Volumes is refused before the disk is read")
    }

    func testRuleIsRedUnselectedEmptyingAndInTheReviewedBaseline() throws {
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rule = try XCTUnwrap(bundled.rules.first { $0.id == "trash.volume-trashes" })
        XCTAssertEqual(rule.root.kind, .mountedVolumeTrashes)
        XCTAssertEqual(rule.root.path, "/Volumes")
        XCTAssertEqual(rule.effectiveCandidateScope, .root)
        XCTAssertEqual(rule.action, .emptyTrash)
        XCTAssertEqual(rule.risk, .protected)
        XCTAssertEqual(rule.defaultSelection, .unselected)
        XCTAssertEqual(rule.executionEligibility, .eligibleAfterProtectedReview)
        XCTAssertEqual(rule.categoryID, "trash")
        let maintenance = try XCTUnwrap(rule.maintenance)
        XCTAssertNotNil(CleanupImpactText.englishByChinese[maintenance.impact])
        let baseline = try CleanupRuleTestFixtures.baseline()
        XCTAssertNoThrow(try CleanupRuleMaintenanceValidator.validate(bundled, baseline: baseline))
        let hash = try CleanupRuleFingerprint.contentHash(for: rule)
        let entry = try XCTUnwrap(baseline.entries.first { $0.ruleID == rule.id }, "baseline entry; content hash \(hash)")
        XCTAssertEqual(entry.revision, 1)
        XCTAssertEqual(entry.contentHash, hash)
        XCTAssertEqual(CareJunkGroup.group(categoryID: rule.categoryID, candidates: []), .trashBins)
    }

    func testOtherDrivesAreOnlyEverReachedToEmptyTheirTrash() throws {
        let rule = CleanupCoverageCatalog.volumeTrashRule
        for fields: [String: Any] in [["action": "moveToTrash"], ["action": "moveToTrashAfterReview"],
                                      ["defaultSelection": "selected"], ["risk": "safe"],
                                      ["root": ["kind": "mountedVolumeTrashes", "path": "/Volumes/Storage"]],
                                      ["root": ["kind": "mountedVolumeTrashes", "path": "/"]],
                                      ["candidateScope": "immediateChildren"]] {
            let changed = try CleanupRuleTestFixtures.replacing(rule, fields: fields)
            XCTAssertThrowsError(try CleanupRuleValidator.validate(CleanupRuleTestFixtures.set([changed])), "\(fields)")
        }
        XCTAssertNoThrow(try CleanupRuleValidator.validate(CleanupRuleTestFixtures.set([rule])))
    }

    /// Scan, plan and empty one drive's Trash end to end. The drive is a
    /// temporary folder seen as `/Volumes/Fake` through a mapped file system;
    /// the real deleter runs on it.
    func testEmptiesOnlyTheEntriesFrozenInThatDrivesTrash() async throws {
        let drive = try VolumeTrashFakeDrive(test: self, uid: uid)
        try drive.write(bytes: 8_192, to: "old.bin")
        try drive.write(bytes: 8_192, to: "Folder/inner.bin")
        try drive.write(bytes: 4_096, to: "replaced.bin")
        let outside = drive.physicalRoot.appendingPathComponent("outside-keep.bin")
        try Data(count: 1_024).write(to: outside)
        try FileManager.default.createSymbolicLink(at: drive.physicalTrash.appendingPathComponent("outside-link"),
                                                   withDestinationURL: outside)

        let (session, rules) = try await drive.scan()
        let trash = try XCTUnwrap(session.candidates.first { $0.ruleID == "trash.volume-trashes" })
        XCTAssertEqual(trash.sourceURL.path, drive.logicalTrash.path)
        XCTAssertEqual(PathSafety.lexicalPath(trash.allowedRootURL.path), "/Volumes/Fake/.Trashes")
        XCTAssertEqual(trash.selectionEligibility, .selectableWithPermanentDeletionReview)
        XCTAssertEqual(Set(trash.permanentDeletionEntries?.map { URL(fileURLWithPath: $0.standardizedPath).lastPathComponent } ?? []),
                       ["old.bin", "Folder", "replaced.bin"], "a link out of the Trash is never frozen")
        XCTAssertFalse(CleanupSelection.defaults(in: session).selectedCandidateIDs.contains(trash.id))
        XCTAssertFalse(CleanupSelection.recommended(in: session).selectedCandidateIDs.contains(trash.id))
        XCTAssertEqual(CareStudioCandidateRow.title(for: trash), L10n.text("“Fake”上的废纸篓", "Trash on “Fake”"))

        var selection = CleanupSelection()
        selection.setCandidates([trash.id], selected: true, in: session)
        let plan = try CleanPlanBuilder.makePlan(session: session, selection: selection, activeRules: rules, disposition: .trash)
        XCTAssertEqual(plan.permanentDeletionItems.count, 3)
        XCTAssertTrue(plan.permanentDeletionItems.allSatisfy {
            $0.allowedRootURL.path == drive.logicalTrash.path && $0.explicitUserSelection
        })

        // After the scan one entry is replaced and a new one arrives.
        try FileManager.default.removeItem(at: drive.physicalTrash.appendingPathComponent("replaced.bin"))
        try drive.write(bytes: 1_024, to: "replaced.bin")
        try drive.write(bytes: 1_024, to: "added-after-scan.bin")

        let report = await drive.executor(trashStillValid: true).execute(
            plan: plan, context: drive.context(session: session, rules: rules, plan: plan)) { _ in }
        let outcomes = Dictionary(uniqueKeysWithValues: report.items.map {
            (URL(fileURLWithPath: $0.sourcePath).lastPathComponent, $0.outcome)
        })
        if case .deleted = outcomes["old.bin"] {} else { XCTFail("old.bin: \(String(describing: outcomes["old.bin"]))") }
        if case .deleted = outcomes["Folder"] {} else { XCTFail("Folder: \(String(describing: outcomes["Folder"]))") }
        XCTAssertEqual(outcomes["replaced.bin"], .skipped(.identityChanged))
        XCTAssertEqual(report.summary.deletedItemCount, 2)
        let fileManager = FileManager.default
        XCTAssertFalse(fileManager.fileExists(atPath: drive.physicalTrash.appendingPathComponent("old.bin").path))
        XCTAssertFalse(fileManager.fileExists(atPath: drive.physicalTrash.appendingPathComponent("Folder").path))
        XCTAssertTrue(fileManager.fileExists(atPath: drive.physicalTrash.appendingPathComponent("replaced.bin").path))
        XCTAssertTrue(fileManager.fileExists(atPath: drive.physicalTrash.appendingPathComponent("added-after-scan.bin").path))
        XCTAssertTrue(fileManager.fileExists(atPath: outside.path), "link targets are never followed")
    }

    /// A drive that was ejected or swapped since the scan (the locator no
    /// longer vouches for its Trash folder) gets nothing deleted.
    func testNothingIsDeletedWhenTheDrivesTrashNoLongerChecksOut() async throws {
        let drive = try VolumeTrashFakeDrive(test: self, uid: uid)
        try drive.write(bytes: 8_192, to: "old.bin")
        let (session, rules) = try await drive.scan()
        let trash = try XCTUnwrap(session.candidates.first { $0.ruleID == "trash.volume-trashes" })
        var selection = CleanupSelection()
        selection.setCandidates([trash.id], selected: true, in: session)
        let plan = try CleanPlanBuilder.makePlan(session: session, selection: selection, activeRules: rules, disposition: .trash)

        let report = await drive.executor(trashStillValid: false).execute(
            plan: plan, context: drive.context(session: session, rules: rules, plan: plan)) { _ in }
        XCTAssertEqual(report.items.map(\.outcome), [.skipped(.pathOutsideAllowedRoot)])
        XCTAssertEqual(report.summary.deletedItemCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: drive.physicalTrash.appendingPathComponent("old.bin").path))
    }

    func testPlanRefusesARowThatIsNotExactlyAVolumeTrash() async throws {
        let drive = try VolumeTrashFakeDrive(test: self, uid: uid)
        try drive.write(bytes: 8_192, to: "old.bin")
        let (session, rules) = try await drive.scan()
        let trash = try XCTUnwrap(session.candidates.first { $0.ruleID == "trash.volume-trashes" })
        for (source, root) in [("/Volumes/Fake/.Trashes/\(uid + 1)", "/Volumes/Fake/.Trashes"),
                               ("/Users/someone/.Trash", "/Users/someone"),
                               ("/Volumes/Fake/x/.Trashes/\(uid)", "/Volumes/Fake/x/.Trashes"),
                               ("/Volumes/Fake/.Trashes/\(uid)", "/Volumes/Fake")] {
            let moved = trash.relocated(source: source, allowedRoot: root)
            let altered = session.mappingCandidates { $0.id == trash.id ? moved : $0 }
            var selection = CleanupSelection()
            selection.setCandidates([moved.id], selected: true, in: altered)
            XCTAssertThrowsError(try CleanPlanBuilder.makePlan(session: altered, selection: selection,
                                                               activeRules: rules, disposition: .trash), source) {
                XCTAssertEqual($0 as? CleanPlanBuildError, .invalidCandidate, source)
            }
        }
    }

    /// The scanner itself refuses a locator answer that is not exactly a
    /// volume's Trash folder for this user.
    func testScannerSkipsAnythingButTheUsersOwnVolumeTrash() async throws {
        let drive = try VolumeTrashFakeDrive(test: self, uid: uid)
        let other = drive.physicalVolumes.appendingPathComponent("Fake/.Trashes/\(uid + 1)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(count: 8_192).write(to: other.appendingPathComponent("someone-else.bin"))
        let otherLogical = URL(fileURLWithPath: "/Volumes/Fake/.Trashes/\(uid + 1)", isDirectory: true)
        let (session, _) = try await drive.scan(trashes: [otherLogical])
        XCTAssertTrue(session.candidates.isEmpty)
        XCTAssertTrue(session.issues.contains { $0.path == otherLogical.path && $0.kind == .outsideAllowedRoot })
    }

    func testAnUnreadableDriveTrashIsReportedAndTheOthersStillCount() async throws {
        let drive = try VolumeTrashFakeDrive(test: self, uid: uid)
        try drive.write(bytes: 8_192, to: "old.bin")
        let (session, _) = try await drive.scan(deniedTrash: true)
        XCTAssertNil(session.candidates.first { $0.ruleID == "trash.volume-trashes" })
        XCTAssertTrue(session.permissions.contains {
            $0.ruleID == "trash.volume-trashes" && $0.path == drive.logicalTrash.path && $0.status == .permissionDenied
        })
        XCTAssertEqual(session.coverageLimits.deniedLocationCount, 1, "D179 names it in the results notice")
    }

    func testUsersOwnTrashRowIsCalledTrash() throws {
        let rule = CleanupCoverageCatalog.userTrashRule
        XCTAssertEqual(rule.root.kind, .homeRelative)
        XCTAssertNil(VolumeTrashLocator.volumeName(ofTrashPath: "/Users/someone/.Trash"))
    }
}

/// A temporary folder seen as `/Volumes/Fake`, so the scanner, the plan
/// builder and the executor see the same paths a real drive gives.
struct VolumeTrashFakeDrive {
    let physicalRoot: URL
    let physicalVolumes: URL
    let physicalTrash: URL
    let logicalTrash: URL
    let home: URL
    let uid: uid_t

    init(test: XCTestCase, uid: uid_t) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerVolumeTrash-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        physicalRoot = root
        physicalVolumes = root.appendingPathComponent("Volumes", isDirectory: true)
        physicalTrash = physicalVolumes.appendingPathComponent("Fake/.Trashes/\(uid)", isDirectory: true)
        logicalTrash = VolumeTrashLocator.trashURL(volumeName: "Fake", uid: uid)
        home = root.appendingPathComponent("Home", isDirectory: true)
        self.uid = uid
        try FileManager.default.createDirectory(at: physicalTrash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    func write(bytes: Int, to name: String) throws {
        let url = physicalTrash.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    var fileSystem: VolumeTrashMappedFileSystem {
        VolumeTrashMappedFileSystem(physicalVolumes: physicalVolumes)
    }

    func scan(deniedTrash: Bool = false, trashes: [URL]? = nil) async throws -> (ScanSession, CleanupRuleSet) {
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rules = CleanupRuleSet(schemaVersion: bundled.schemaVersion, rulesVersion: bundled.rulesVersion,
                                   rules: bundled.rules.filter { $0.id == "trash.volume-trashes" })
        var fileSystem = self.fileSystem
        if deniedTrash { fileSystem.deniedPaths = [logicalTrash.path] }
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: fileSystem,
            ruleSet: rules,
            applicationsURL: physicalRoot.appendingPathComponent("Applications"),
            volumesURL: URL(fileURLWithPath: "/Volumes", isDirectory: true),
            volumeTrashLocator: VolumeTrashFixedLocator(trashes: trashes ?? [logicalTrash], valid: true)
        )
        let session = try await scanner.scan(request: CleanupScanRequest(userHomeURL: home)) { _ in }
        return (session, rules)
    }

    func executor(trashStillValid: Bool) -> SafeCleanupExecutor {
        SafeCleanupExecutor(
            metadataReader: fileSystem,
            mover: VolumeTrashRefusingMover(),
            capacityReader: VolumeTrashNoCapacityReader(),
            deleter: VolumeTrashMappedDeleter(physicalVolumes: physicalVolumes),
            volumeTrashLocator: VolumeTrashFixedLocator(trashes: [logicalTrash], valid: trashStillValid),
            coordinator: HeavyWorkCoordinator()
        )
    }

    func context(session: ScanSession, rules: CleanupRuleSet, plan: CleanPlan) -> CleanupExecutionContext {
        CleanupExecutionContext(featureConfiguration: .productDefault, activeSessionID: session.id,
                                activeRules: rules, userHomeURL: home, excludedURLs: [],
                                approvedPlanItemIDs: Set(plan.items.map(\.id)))
    }
}

struct VolumeTrashFixedLocator: VolumeTrashLocating {
    let trashes: [URL]
    let valid: Bool
    func trashURLs(uid: uid_t) -> [URL] { trashes }
    func isValidTrash(_ trash: URL, uid: uid_t) -> Bool {
        valid && trashes.contains { $0.path == PathSafety.lexicalPath(trash.path) }
    }
}

/// `/Volumes/...` read from the temporary folder; paths come back in the
/// `/Volumes` form.
struct VolumeTrashMappedFileSystem: ReadOnlyFileSystem {
    let physicalVolumes: URL
    var deniedPaths: Set<String> = []
    private let real = FoundationReadOnlyFileSystem()

    init(physicalVolumes: URL) { self.physicalVolumes = physicalVolumes }

    func physical(_ url: URL) -> URL {
        let path = PathSafety.lexicalPath(url.path)
        guard path == "/Volumes" || path.hasPrefix("/Volumes/") else { return url }
        return URL(fileURLWithPath: physicalVolumes.path + path.dropFirst("/Volumes".count))
    }

    func logical(_ path: String) -> String {
        let physicalPath = PathSafety.lexicalPath(physicalVolumes.path)
        guard path == physicalPath || path.hasPrefix(physicalPath + "/") else { return path }
        return "/Volumes" + path.dropFirst(physicalPath.count)
    }

    func snapshot(at url: URL) throws -> FileSnapshot {
        if deniedPaths.contains(PathSafety.lexicalPath(url.path)) { throw CleanupFileSystemError.permissionDenied }
        let snapshot = try real.snapshot(at: physical(url))
        return FileSnapshot(identity: snapshot.identity, standardizedPath: logical(snapshot.standardizedPath),
                            volumeIdentifier: snapshot.volumeIdentifier, logicalSizeBytes: snapshot.logicalSizeBytes,
                            allocatedSizeBytes: snapshot.allocatedSizeBytes,
                            modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
                            isWritableVolume: snapshot.isWritableVolume, isCloudItem: snapshot.isCloudItem,
                            isCloudPlaceholder: snapshot.isCloudPlaceholder, hasSymbolicLinkComponent: false)
    }

    func children(of directory: URL) throws -> [URL] {
        if deniedPaths.contains(PathSafety.lexicalPath(directory.path)) { throw CleanupFileSystemError.permissionDenied }
        return try real.children(of: physical(directory)).map {
            URL(fileURLWithPath: logical(PathSafety.lexicalPath($0.path)))
        }
    }

    func symbolicLinkDestination(of url: URL) throws -> String {
        try real.symbolicLinkDestination(of: physical(url))
    }

    func storageSharing(at url: URL) -> FileStorageSharing.Reading {
        real.storageSharing(at: physical(url))
    }
}

/// The real deleter, on the temporary folder behind `/Volumes/Fake`.
struct VolumeTrashMappedDeleter: CleanupPermanentDeleting {
    let physicalVolumes: URL
    func removeTrashEntry(_ deletion: CleanupTrashEntryDeletion) async throws {
        let path = PathSafety.lexicalPath(deletion.trashURL.path)
        let trash = URL(fileURLWithPath: physicalVolumes.path + path.dropFirst("/Volumes".count), isDirectory: true)
        try FoundationCleanupPermanentDeleter.remove(CleanupTrashEntryDeletion(
            trashURL: trash, trashIdentity: deletion.trashIdentity,
            entryName: deletion.entryName, entryIdentity: deletion.entryIdentity))
    }
}

struct VolumeTrashRefusingMover: CleanupMoving {
    func moveToTrash(_ url: URL) async throws -> URL { throw CocoaError(.fileWriteNoPermission) }
    func moveToQuarantine(_ url: URL, planID: CleanPlanID, itemID: UUID) async throws -> URL {
        throw CocoaError(.fileWriteNoPermission)
    }
}

struct VolumeTrashNoCapacityReader: CleanupCapacityReading {
    func availableCapacity(at url: URL) async -> Int64? { nil }
}

private extension ScanCandidate {
    /// The same row at another path, as if the scan had found it there.
    func relocated(source: String, allowedRoot: String) -> ScanCandidate {
        func moved(_ snapshot: FileSnapshot, to path: String) -> FileSnapshot {
            FileSnapshot(identity: snapshot.identity, standardizedPath: path,
                         volumeIdentifier: snapshot.volumeIdentifier, logicalSizeBytes: snapshot.logicalSizeBytes,
                         allocatedSizeBytes: snapshot.allocatedSizeBytes,
                         modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
                         isWritableVolume: snapshot.isWritableVolume, isCloudItem: snapshot.isCloudItem,
                         isCloudPlaceholder: snapshot.isCloudPlaceholder,
                         hasSymbolicLinkComponent: snapshot.hasSymbolicLinkComponent)
        }
        var copy = ScanCandidate(
            id: ScanCandidateID(stableKey: source), sessionID: sessionID, ruleID: ruleID,
            ruleSelectionPolicyVersion: ruleSelectionPolicyVersion, categoryID: categoryID,
            categoryTitle: categoryTitle, subcategoryTitle: subcategoryTitle,
            sourceURL: URL(fileURLWithPath: source, isDirectory: true),
            allowedRootURL: URL(fileURLWithPath: allowedRoot, isDirectory: true),
            snapshot: moved(snapshot, to: source), risk: risk, recommendation: recommendation,
            defaultSelection: defaultSelection, executionEligibility: executionEligibility,
            measurementCompleteness: measurementCompleteness, isManuallySelectable: isManuallySelectable,
            action: action, requiredClosedBundleIDs: requiredClosedBundleIDs, reason: reason)
        copy.permanentDeletionEntries = permanentDeletionEntries?.map {
            moved($0, to: source + "/" + URL(fileURLWithPath: $0.standardizedPath).lastPathComponent)
        }
        copy.ruleRevision = ruleRevision
        copy.rulesProvenance = rulesProvenance
        return copy
    }
}
