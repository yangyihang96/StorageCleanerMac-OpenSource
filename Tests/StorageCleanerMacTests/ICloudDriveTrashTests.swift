import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

final class ICloudDriveTrashTests: XCTestCase {
    func testRuleIsLoadedOnceAndIsProtectedUnselectedAndNarrow() throws {
        let rule = CleanupCoverageCatalog.iCloudDriveTrashRule
        XCTAssertEqual(try CleanupRuleSetLoader.loadBundled().rules.filter { $0.id == rule.id }.count, 1)
        XCTAssertEqual(rule.id, "trash.icloud-drive")
        XCTAssertEqual(rule.root.kind, .homeRelative)
        XCTAssertEqual(rule.root.path, "Library/Mobile Documents/.Trash")
        XCTAssertEqual(rule.effectiveCandidateScope, .root)
        XCTAssertEqual(rule.cloudPolicy, .metadataOnly)
        XCTAssertEqual(rule.action, .emptyTrash)
        XCTAssertEqual(rule.risk, .protected)
        XCTAssertEqual(rule.defaultSelection, .unselected)
        XCTAssertEqual(rule.recommendation, .notRecommended)
        XCTAssertEqual(rule.executionEligibility, .eligibleAfterProtectedReview)
        XCTAssertEqual(rule.measurementRequirement, .complete)
        XCTAssertTrue(rule.allowsManualSelection)
        XCTAssertEqual(CareJunkGroup.group(for: rule), .trashBins)
        XCTAssertEqual(rule.maintenance?.revision, 1)
        let baseline = try XCTUnwrap(try CleanupRuleTestFixtures.baseline().entries.first { $0.ruleID == rule.id })
        XCTAssertEqual(baseline.revision, 1)
        XCTAssertEqual(try CleanupRuleFingerprint.contentHash(for: rule), baseline.contentHash)
    }

    func testValidatorRefusesBroaderCloudRootsAndOtherRuleIDs() throws {
        let rule = CleanupCoverageCatalog.iCloudDriveTrashRule
        for path in ["Library/Mobile Documents", "Library/Mobile Documents/.Trash/child", "Library/CloudStorage/.Trash"] {
            let changed = try CleanupRuleTestFixtures.replacing(rule, fields: ["root": ["kind": "homeRelative", "path": path]])
            XCTAssertThrowsError(try CleanupRuleValidator.validate(CleanupRuleTestFixtures.set([changed])), path)
        }
        for fields: [String: Any] in [["id": "trash.other-cloud"], ["cloudPolicy": "skipPlaceholder"], ["defaultSelection": "selected"]] {
            let changed = try CleanupRuleTestFixtures.replacing(rule, fields: fields)
            XCTAssertThrowsError(try CleanupRuleValidator.validate(CleanupRuleTestFixtures.set([changed])))
        }
    }

    func testCloudOnlyAndLocalSizesAreMeasuredSeparatelyWithoutResourceQueries() async throws {
        let fixture = try ICloudTrashFixture(test: self)
        try fixture.write("online.bin")
        try fixture.write("Folder/online.bin")
        try fixture.write("Folder/Documents/local.bin")
        let fs = fixture.reader(overrides: [
            "online.bin": .init(logical: 9_000_000_000, allocated: 0, cloudOnly: true),
            "Folder/online.bin": .init(logical: 10_000_000_000, allocated: 0, cloudOnly: true),
            "Folder/Documents/local.bin": .init(logical: 2_000_000_000, allocated: 1_000_000_000, cloudOnly: false),
        ])
        let session = try await fixture.scan(fs)
        let row = try XCTUnwrap(session.candidates.first)
        XCTAssertEqual(session.candidates.count, 1)
        XCTAssertEqual(row.snapshot.logicalSizeBytes, 21_000_000_000)
        XCTAssertEqual(row.snapshot.allocatedSizeBytes, 1_000_000_000)
        XCTAssertEqual(row.estimatedSizeBytes, 1_000_000_000)
        XCTAssertEqual(row.measurementCompleteness, .complete)
        XCTAssertEqual(row.permanentDeletionEntries?.count, 2, "Freeze top-level entries, never their individual descendants")
        XCTAssertTrue(row.permanentDeletionEntries?.contains(where: \.isCloudPlaceholder) == true)
        XCTAssertFalse(session.issues.contains { $0.kind == .cloudPlaceholderSkipped })
        XCTAssertEqual(CleanupMeasurementPresentation.value(row),
                       L10n.text("iCloud 中 \(ByteFormat.storageString(21_000_000_000)) · 本机 \(ByteFormat.storageString(1_000_000_000))",
                                 "iCloud \(ByteFormat.storageString(21_000_000_000)) · On this Mac \(ByteFormat.storageString(1_000_000_000))"))
        XCTAssertFalse(CleanupSelection.defaults(in: session).selectedCandidateIDs.contains(row.id))
        XCTAssertFalse(CleanupSelection.recommended(in: session).selectedCandidateIDs.contains(row.id))
        let plan = try fixture.plan(session)
        XCTAssertEqual(plan.permanentDeletionItems.count, 2)
        XCTAssertEqual(plan.permanentDeletionBytes, 1_000_000_000, "D192: expected release is local allocation, never cloud logical size")
        XCTAssertEqual(fs.forbiddenReads, [])
    }

    func testAnEntirelyCloudOnlyTrashStillHasASelectableRowWithZeroLocalRelease() async throws {
        let fixture = try ICloudTrashFixture(test: self)
        try fixture.write("online.bin")
        let fs = fixture.reader(overrides: [
            "": .init(logical: 0, allocated: 0, cloudOnly: true),
            "online.bin": .init(logical: 19_100_000_000, allocated: 0, cloudOnly: true),
        ])
        let session = try await fixture.scan(fs)
        let row = try XCTUnwrap(session.candidates.first)
        XCTAssertTrue(row.isSelectable)
        XCTAssertFalse(row.isPreselectedByDefault)
        XCTAssertEqual(row.snapshot.logicalSizeBytes, 19_100_000_000)
        XCTAssertEqual(row.estimatedSizeBytes, 0)
        XCTAssertEqual(CleanupSelection().selectedCandidates(in: session).count, 0)
        let plan = try fixture.plan(session)
        XCTAssertEqual(plan.permanentDeletionItems.count, 1)
        XCTAssertEqual(plan.permanentDeletionBytes, 0)
        let report = await fixture.execute(plan, session: session, reader: fs)
        XCTAssertEqual(report.summary.deletedItemCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("online.bin").path))
        XCTAssertEqual(fs.forbiddenReads, [], "Scanning, execution preflight and deletion readback must all avoid resource queries")
    }

    func testBothConfirmationsAreRequiredAndTheSecondNamesAllDevices() async throws {
        let fixture = try ICloudTrashFixture(test: self)
        try fixture.write("old.bin")
        let session = try await fixture.scan(fixture.reader())
        let plan = try fixture.plan(session)
        for deletion in [false, true] {
            for reviewed in [false, true] {
                XCTAssertEqual(CleanupPlanConfirmationSheet.permanentDeletionAcknowledged(
                    for: plan, deletion: deletion, contentsReviewed: reviewed), deletion && reviewed)
            }
        }
        XCTAssertEqual(CleanupPlanConfirmationSheet.trashContentsAcknowledgement(for: plan),
                       L10n.text("我已确认没有需要保留的文件；会从你所有设备上的 iCloud 云盘永久删除，不能撤销",
                                 "I confirmed there is nothing to keep; this permanently deletes from iCloud Drive on all your devices and cannot be undone"))
        let source = try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/StorageCleanerMac/Views/CleanupExecutionViews.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Toggle(isOn: $acknowledgesPermanentDeletion)"))
        XCTAssertTrue(source.contains("Toggle(isOn: $acknowledgesTrashContentsReviewed)"))
        XCTAssertTrue(source.contains("deletion: acknowledgesPermanentDeletion"))
        XCTAssertTrue(source.contains("contentsReviewed: acknowledgesTrashContentsReviewed"))
        XCTAssertTrue(source.contains("Text(Self.trashContentsAcknowledgement(for: plan))"))
    }

    func testOnlyFrozenEntriesAreDeletedAndChangedEntriesAndLinkTargetsStay() async throws {
        let fixture = try ICloudTrashFixture(test: self)
        try fixture.write("old.bin")
        try fixture.write("replaced.bin")
        try fixture.write("Folder/deep/file.bin")
        let outside = fixture.home.appendingPathComponent("outside.bin")
        try Data([1, 2, 3]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.trash.appendingPathComponent("Folder/link"), withDestinationURL: outside)
        let link = fixture.trash.appendingPathComponent("link-to-target")
        let target = fixture.trash.appendingPathComponent("link-target.bin")
        try fixture.write("link-target.bin")
        let later = fixture.trash.appendingPathComponent("added-after-scan.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let fs = fixture.reader()
        let session = try await fixture.scan(fs)
        let plan = try fixture.plan(session)
        XCTAssertEqual(Set(plan.items.map { $0.sourceURL.lastPathComponent }),
                       ["old.bin", "replaced.bin", "Folder", "link-to-target", "link-target.bin"])
        try FileManager.default.moveItem(at: fixture.trash.appendingPathComponent("replaced.bin"),
                                         to: fixture.home.appendingPathComponent("original.bin"))
        try fixture.write("replaced.bin")
        try FileManager.default.moveItem(at: target, to: fixture.home.appendingPathComponent("original-link-target.bin"))
        try fixture.write("link-target.bin")
        try fixture.write("added-after-scan.bin")
        let report = await fixture.execute(plan, session: session, reader: fs)
        let outcomes = Dictionary(uniqueKeysWithValues: report.items.map { (URL(fileURLWithPath: $0.sourcePath).lastPathComponent, $0.outcome) })
        XCTAssertEqual(outcomes["replaced.bin"], .skipped(.identityChanged))
        XCTAssertEqual(outcomes["link-target.bin"], .skipped(.identityChanged))
        XCTAssertEqual(report.summary.deletedItemCount, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("replaced.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "Unlinking a frozen link must not delete its replacement target")
        XCTAssertTrue(FileManager.default.fileExists(atPath: later.path), "A new top-level entry was never frozen")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "Nested links never delete outside targets")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("Folder").path))
        XCTAssertEqual(fs.forbiddenReads, [])
    }

    func testReplacingTheTrashRootRefusesEveryFrozenEntry() async throws {
        let fixture = try ICloudTrashFixture(test: self)
        try fixture.write("old.bin")
        let fs = fixture.reader()
        let session = try await fixture.scan(fs)
        let plan = try fixture.plan(session)
        let moved = fixture.home.appendingPathComponent("old-trash")
        try FileManager.default.moveItem(at: fixture.trash, to: moved)
        try FileManager.default.createDirectory(at: fixture.trash, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: moved.appendingPathComponent("old.bin"), to: fixture.trash.appendingPathComponent("old.bin"))
        let report = await fixture.execute(plan, session: session, reader: fs)
        XCTAssertEqual(report.items.map(\.outcome), [.skipped(.pathOutsideAllowedRoot)])
        XCTAssertEqual(report.summary.deletedItemCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("old.bin").path))
        XCTAssertEqual(fs.forbiddenReads, [])
    }

    func testCloudDownloadStateChangesDoNotRequireDownloadingBeforeDeletion() async throws {
        let fixture = try ICloudTrashFixture(test: self)
        try fixture.write("old.bin")
        let session = try await fixture.scan(fixture.reader())
        let plan = try fixture.plan(session)
        let nowCloudOnly = fixture.reader(overrides: ["old.bin": .init(logical: 8192, allocated: 0, cloudOnly: true)])
        let report = await fixture.execute(plan, session: session, reader: nowCloudOnly)
        XCTAssertEqual(report.summary.deletedItemCount, 1)
        XCTAssertEqual(nowCloudOnly.forbiddenReads, [])
    }
}

private struct ICloudTrashFixture {
    let home: URL
    let trash: URL
    let rules = CleanupRuleTestFixtures.set([CleanupCoverageCatalog.iCloudDriveTrashRule], version: "d192.icloud-trash")

    init(test: XCTestCase) throws {
        home = try TestFileSystem.makeHome(for: test).resolvingSymlinksInPath()
        trash = home.appendingPathComponent("Library/Mobile Documents/.Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    func write(_ relative: String) throws {
        try CleanupRuleTestFixtures.write(trash.appendingPathComponent(relative), bytes: 8192)
    }

    func reader(overrides: [String: ICloudTrashMetadata] = [:]) -> ICloudTrashMetadataOnlyFileSystem {
        ICloudTrashMetadataOnlyFileSystem(home: home, trash: trash, overrides: overrides)
    }

    func scan(_ reader: ICloudTrashMetadataOnlyFileSystem) async throws -> ScanSession {
        let session = try await ReadOnlyCleanupScanner(fileSystem: reader, ruleSet: rules,
            applicationsURL: home.appendingPathComponent("Applications"), volumesURL: home.appendingPathComponent("Volumes"),
            developerDirectoryLinkURL: home.appendingPathComponent("no-xcode-link"))
            .scan(request: CleanupScanRequest(userHomeURL: home)) { _ in }
        XCTAssertFalse(session.candidates.isEmpty,
                       "Fixture scan: permissions=\(session.permissions), issues=\(session.issues), forbiddenReads=\(reader.forbiddenReads)")
        return session
    }

    func plan(_ session: ScanSession) throws -> CleanPlan {
        var selection = CleanupSelection()
        selection.setCandidates(session.candidates.map(\.id), selected: true, in: session)
        return try CleanPlanBuilder.makePlan(session: session, selection: selection, activeRules: rules, disposition: .trash)
    }

    func execute(_ plan: CleanPlan, session: ScanSession, reader: ICloudTrashMetadataOnlyFileSystem) async -> CleanReport {
        await SafeCleanupExecutor(metadataReader: reader, mover: VolumeTrashRefusingMover(),
            volumeChecker: ICloudTrashAvailableVolume(), capacityReader: VolumeTrashNoCapacityReader(),
            coordinator: HeavyWorkCoordinator()).execute(plan: plan,
                context: CleanupExecutionContext(featureConfiguration: .productDefault, activeSessionID: session.id,
                    activeRules: rules, userHomeURL: home, excludedURLs: [], approvedPlanItemIDs: Set(plan.items.map(\.id)))) { _ in }
    }
}

private struct ICloudTrashMetadata: Sendable {
    let logical: Int64
    let allocated: Int64
    let cloudOnly: Bool
}

/// Any resource-value, sharing or ordinary snapshot request fails this fixture.
/// Sizes and dataless flags are injected; all paths remain in the owned temp home.
private final class ICloudTrashMetadataOnlyFileSystem: ReadOnlyFileSystem, @unchecked Sendable {
    let home: URL
    let trash: URL
    let overrides: [String: ICloudTrashMetadata]
    private let lock = NSLock()
    private var violations: [String] = []
    var forbiddenReads: [String] { lock.withLock { violations } }

    init(home: URL, trash: URL, overrides: [String: ICloudTrashMetadata]) {
        self.home = home; self.trash = trash; self.overrides = overrides
    }

    func snapshot(at url: URL) throws -> FileSnapshot {
        lock.withLock { violations.append("snapshot: \(url.lastPathComponent)") }
        throw CleanupFileSystemError.unreadable
    }

    func aggregateSnapshot(at url: URL) throws -> FileSnapshot {
        lock.withLock { violations.append("aggregateSnapshot: \(url.lastPathComponent)") }
        throw CleanupFileSystemError.unreadable
    }

    func metadataOnlySnapshot(at url: URL) throws -> FileSnapshot {
        guard PathSafety.isContained(url.path, in: home.path, resolvingSymlinks: false) else { throw CleanupFileSystemError.unreadable }
        let real = FoundationReadOnlyFileSystem()
        let value = try real.metadataOnlySnapshot(at: url)
        let homePath = PathSafety.lexicalPath(home.path)
        let path = PathSafety.lexicalPath(url.path)
        // As in RuleTestReadOnlyFileSystem: ignore inaccessible system
        // ancestors and /var's alias; retain every link check inside our home.
        var current = URL(fileURLWithPath: homePath, isDirectory: true)
        var linked = try real.aggregateSnapshot(at: current).identity.entryKind == .symbolicLink
        for part in path.dropFirst(homePath.count).split(separator: "/") {
            current.appendPathComponent(String(part))
            if try real.aggregateSnapshot(at: current).identity.entryKind == .symbolicLink {
                linked = true
                break
            }
        }
        let relative = String(path.dropFirst(PathSafety.lexicalPath(trash.path).count + 1))
        let metadata = overrides[relative]
        return FileSnapshot(identity: value.identity, standardizedPath: value.standardizedPath,
            volumeIdentifier: value.volumeIdentifier, logicalSizeBytes: metadata?.logical ?? value.logicalSizeBytes,
            allocatedSizeBytes: metadata?.allocated ?? value.allocatedSizeBytes, modificationTimeNanoseconds: value.modificationTimeNanoseconds,
            isWritableVolume: value.isWritableVolume, isCloudItem: metadata?.cloudOnly ?? value.isCloudItem,
            isCloudPlaceholder: metadata?.cloudOnly ?? value.isCloudPlaceholder, hasSymbolicLinkComponent: linked)
    }

    func children(of directory: URL) throws -> [URL] {
        guard PathSafety.isContained(directory.path, in: home.path, resolvingSymlinks: false) else { throw CleanupFileSystemError.unreadable }
        return try FoundationReadOnlyFileSystem().children(of: directory)
    }

    func storageSharing(at url: URL) -> FileStorageSharing.Reading {
        lock.withLock { violations.append("storageSharing: \(url.lastPathComponent)") }
        return .unknown
    }
}

private struct ICloudTrashAvailableVolume: CleanupVolumeChecking {
    func isAvailable(volumeIdentifier: String) async -> Bool { true }
}
