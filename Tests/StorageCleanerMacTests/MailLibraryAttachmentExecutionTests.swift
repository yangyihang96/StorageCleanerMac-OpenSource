import Foundation
import XCTest
@testable import StorageCleanerMac

final class MailLibraryAttachmentExecutionTests: XCTestCase {
    private let rule = CleanupCoverageCatalog.mailLibraryAttachmentFoldersRule

    func testReviewedFolderUsesTheExistingMoveReceiptAndCanBePutBack() async throws {
        let fixture = try await self.fixture()
        let item = try XCTUnwrap(fixture.plan.items.first)
        let executor = SafeCleanupExecutor(metadataReader: RuleTestReadOnlyFileSystem(root: fixture.home),
            mover: MailFixtureTrashMover(trash: fixture.home.appendingPathComponent(".Trash")),
            volumeChecker: MailAvailableVolume(), runningApplicationChecker: MailRunningChecker(running: false),
            capacityReader: MailUnknownCapacity(), coordinator: HeavyWorkCoordinator())
        let preflight = await executor.preflight(plan: fixture.plan, context: context(fixture))
        XCTAssertEqual(preflight.readyCount, 1)
        let report = await executor.execute(plan: fixture.plan, context: context(fixture), progress: { _ in })
        guard case let .moved(receipt) = try XCTUnwrap(report.items.first?.outcome) else {
            return XCTFail("Expected a move receipt: \(report.items)")
        }
        XCTAssertEqual(receipt.disposition, .trash)
        XCTAssertEqual(receipt.verification, .identityVerified)
        XCTAssertTrue(receipt.isRestorable)
        XCTAssertEqual(receipt.movedIdentity, item.expectedSnapshot.identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.sourceURL.path))
        // Put back only this test-owned folder, never the user's Trash.
        try FileManager.default.moveItem(at: receipt.resultingItemURL, to: item.sourceURL)
        XCTAssertEqual(try RuleTestReadOnlyFileSystem(root: fixture.home).snapshot(at: item.sourceURL).identity,
                       item.expectedSnapshot.identity)
    }

    func testMailMustBeClosedAndSelectionMustBeExplicit() async throws {
        let fixture = try await self.fixture()
        let candidate = try XCTUnwrap(fixture.session.candidates.first)
        XCTAssertThrowsError(try CleanPlanBuilder.makePlan(session: fixture.session,
            selection: CleanupSelection(selectedCandidateIDs: [candidate.id]),
            activeRules: fixture.rules, disposition: .trash)) {
            XCTAssertEqual($0 as? CleanPlanBuildError, .invalidCandidate)
        }
        let mover = MailRejectingMover()
        let executor = executor(home: fixture.home, mover: mover, mailIsRunning: true)
        let executionContext = context(fixture)
        let preflight = await executor.preflight(plan: fixture.plan, context: executionContext)
        XCTAssertEqual(preflight.items.map(\.status), [.skipped(.relatedAppStillRunning)])
        let report = await executor.execute(plan: fixture.plan, context: executionContext, progress: { _ in })
        XCTAssertEqual(report.items.map(\.outcome), [.skipped(.relatedAppStillRunning)])
        let calls = await mover.calls
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.sourceURL.path))
    }

    func testPlanAndExecutorRejectRenamedOutsideAndTooDeepPaths() async throws {
        let fixture = try await self.fixture()
        let candidate = try XCTUnwrap(fixture.session.candidates.first)
        let root = fixture.home.appendingPathComponent(rule.root.path)
        let tooDeep = root.appendingPathComponent((1...16).map { "d\($0)" }.joined(separator: "/") + "/Attachments")
        let invalidPaths = [candidate.sourceURL.deletingLastPathComponent().appendingPathComponent("Attachments-old"),
                            fixture.home.appendingPathComponent("outside/Attachments"), tooDeep]
        for url in invalidPaths {
            let changed = relocated(candidate, to: url)
            let session = fixture.session.mappingCandidates { _ in changed }
            XCTAssertThrowsError(try CleanPlanBuilder.makePlan(session: session,
                selection: selected(session), activeRules: fixture.rules, disposition: .trash), url.path) {
                XCTAssertEqual($0 as? CleanPlanBuildError, .invalidCandidate)
            }
            // Plans have a fileprivate initializer. Exercise the executor's
            // independent path recheck through the metadata boundary instead.
            let reader = MailReportedPathFileSystem(root: fixture.home, source: candidate.sourceURL, reported: changed.snapshot)
            let check = await executor(home: fixture.home, metadataReader: reader)
                .preflight(plan: fixture.plan, context: context(fixture))
            XCTAssertEqual(check.items.map(\.status), [.skipped(.pathOutsideAllowedRoot)], url.path)
        }
        // The rule root must belong to the current home, even if its suffix
        // and its containment in the supplied home both appear valid.
        let wrongHome = CleanupExecutionContext(featureConfiguration: .productDefault, activeSessionID: fixture.session.id,
            activeRules: fixture.rules, userHomeURL: fixture.home.deletingLastPathComponent(), excludedURLs: [],
            approvedPlanItemIDs: Set(fixture.plan.items.map(\.id)))
        let report = await executor(home: fixture.home).preflight(plan: fixture.plan, context: wrongHome)
        XCTAssertEqual(report.items.map(\.status), [.skipped(.pathOutsideAllowedRoot)])
    }

    func testPreflightRejectsReplacementBySymlinkOrAnotherDirectory() async throws {
        for symlink in [true, false] {
            let fixture = try await self.fixture()
            let url = try XCTUnwrap(fixture.plan.items.first?.sourceURL)
            let saved = url.deletingLastPathComponent().appendingPathComponent("saved-attachments")
            try FileManager.default.moveItem(at: url, to: saved)
            if symlink {
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: saved)
            } else {
                try CleanupRuleTestFixtures.write(url.appendingPathComponent("different.pdf"), bytes: 1_200_000)
            }
            let report = await executor(home: fixture.home).preflight(plan: fixture.plan, context: context(fixture))
            XCTAssertEqual(report.items.map(\.status), [.skipped(symlink ? .symbolicLinkDetected : .identityChanged)])
        }
    }

    func testPreflightRejectsASymlinkInAnAncestor() async throws {
        let fixture = try await self.fixture()
        let ancestor = fixture.home.appendingPathComponent("Library/Mail/V10")
        let saved = fixture.home.appendingPathComponent("saved-account")
        try FileManager.default.moveItem(at: ancestor, to: saved)
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: saved)
        let report = await executor(home: fixture.home).preflight(plan: fixture.plan, context: context(fixture))
        XCTAssertEqual(report.items.map(\.status), [.skipped(.symbolicLinkDetected)])
    }

    func testRenamingOrMovingAScannedFolderMakesTheOriginalPlanMissing() async throws {
        for outside in [true, false] {
            let fixture = try await self.fixture()
            let url = try XCTUnwrap(fixture.plan.items.first?.sourceURL)
            let destination = outside
                ? fixture.home.appendingPathComponent("moved-outside-mail")
                : url.deletingLastPathComponent().appendingPathComponent("renamed-attachments")
            try FileManager.default.moveItem(at: url, to: destination)
            let report = await executor(home: fixture.home).preflight(plan: fixture.plan, context: context(fixture))
            XCTAssertEqual(report.items.map(\.status), [.skipped(.itemMissing)])
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testFinalIdentityCheckAfterDurableIntentStopsASymlinkSwap() async throws {
        let fixture = try await self.fixture()
        let url = try XCTUnwrap(fixture.plan.items.first?.sourceURL)
        let saved = url.deletingLastPathComponent().appendingPathComponent("saved-attachments")
        let mover = MailRejectingMover()
        let executor = SafeCleanupExecutor(metadataReader: RuleTestReadOnlyFileSystem(root: fixture.home),
            mover: mover, volumeChecker: MailAvailableVolume(), runningApplicationChecker: MailRunningChecker(running: false),
            capacityReader: MailUnknownCapacity(), coordinator: HeavyWorkCoordinator(), persistReport: { report, _ in
                if let outcome = report.items.first?.outcome,
                   case let .failed(failure) = outcome, failure.code == .moveOutcomeUnknown {
                    try FileManager.default.moveItem(at: url, to: saved)
                    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: saved)
                }
            })
        let preflight = await executor.preflight(plan: fixture.plan, context: context(fixture))
        XCTAssertEqual(preflight.readyCount, 1)
        let report = await executor.execute(plan: fixture.plan, context: context(fixture), progress: { _ in })
        XCTAssertEqual(report.items.map(\.outcome), [.skipped(.symbolicLinkDetected)])
        let calls = await mover.calls
        XCTAssertEqual(calls, 0)
    }

    /// This fixture uses an owned temporary home; no system Trash operation
    /// is invoked. The injected mover fails if any refusal reaches it.
    private func fixture() async throws -> MailExecutionFixture {
        let home = try TestFileSystem.makeHome(for: self)
        let url = home.appendingPathComponent("Library/Mail/V10/ACCOUNT/INBOX.mbox/U/Data/1/Attachments")
        try CleanupRuleTestFixtures.write(url.appendingPathComponent("7/1/file.pdf"), bytes: 1_200_000)
        let rules = CleanupRuleTestFixtures.set([rule])
        let session = try await CleanupRuleTestFixtures.scan(rules, home: home)
        XCTAssertEqual(session.candidates.count, 1, "\(session.issues)")
        let plan = try CleanPlanBuilder.makePlan(session: session, selection: selected(session), activeRules: rules, disposition: .trash)
        return MailExecutionFixture(home: home, rules: rules, session: session, plan: plan)
    }

    private func selected(_ session: ScanSession) -> CleanupSelection {
        let ids = Set(session.candidates.map(\.id))
        return CleanupSelection(selectedCandidateIDs: ids, explicitlySelectedCandidateIDs: ids)
    }

    private func executor(home: URL, metadataReader: (any ReadOnlyFileSystem)? = nil,
                          mover: MailRejectingMover = MailRejectingMover(), mailIsRunning: Bool = false) -> SafeCleanupExecutor {
        SafeCleanupExecutor(metadataReader: metadataReader ?? RuleTestReadOnlyFileSystem(root: home), mover: mover,
            volumeChecker: MailAvailableVolume(), runningApplicationChecker: MailRunningChecker(running: mailIsRunning),
            capacityReader: MailUnknownCapacity(), coordinator: HeavyWorkCoordinator())
    }

    private func context(_ fixture: MailExecutionFixture) -> CleanupExecutionContext {
        CleanupExecutionContext(featureConfiguration: .productDefault, activeSessionID: fixture.session.id,
            activeRules: fixture.rules, userHomeURL: fixture.home, excludedURLs: [], approvedPlanItemIDs: Set(fixture.plan.items.map(\.id)))
    }

    private func relocated(_ value: FileSnapshot, to url: URL) -> FileSnapshot {
        FileSnapshot(identity: value.identity, standardizedPath: url.path, volumeIdentifier: value.volumeIdentifier,
            logicalSizeBytes: value.logicalSizeBytes, allocatedSizeBytes: value.allocatedSizeBytes,
            modificationTimeNanoseconds: value.modificationTimeNanoseconds, isWritableVolume: value.isWritableVolume,
            isCloudItem: value.isCloudItem, isCloudPlaceholder: value.isCloudPlaceholder,
            hasSymbolicLinkComponent: value.hasSymbolicLinkComponent)
    }

    private func relocated(_ row: ScanCandidate, to url: URL) -> ScanCandidate {
        var result = ScanCandidate(id: row.id, sessionID: row.sessionID, ruleID: row.ruleID,
            ruleSelectionPolicyVersion: row.ruleSelectionPolicyVersion, categoryID: row.categoryID,
            categoryTitle: row.categoryTitle, subcategoryTitle: row.subcategoryTitle, sourceURL: url,
            allowedRootURL: row.allowedRootURL, snapshot: relocated(row.snapshot, to: url), risk: row.risk,
            recommendation: row.recommendation, defaultSelection: row.defaultSelection,
            executionEligibility: row.executionEligibility, measurementCompleteness: row.measurementCompleteness,
            isManuallySelectable: row.isManuallySelectable, action: row.action,
            requiredClosedBundleIDs: row.requiredClosedBundleIDs, reason: row.reason)
        result.ruleRevision = row.ruleRevision
        result.rulesProvenance = row.rulesProvenance
        return result
    }

}

private struct MailExecutionFixture {
    let home: URL
    let rules: CleanupRuleSet
    let session: ScanSession
    let plan: CleanPlan
}

private actor MailRejectingMover: CleanupMoving {
    var calls = 0
    func moveToTrash(_ url: URL) async throws -> URL {
        calls += 1
        throw CleanupFileSystemError.unreadable
    }
    func moveToQuarantine(_ url: URL, planID: CleanPlanID, itemID: UUID) async throws -> URL {
        calls += 1
        throw CleanupFileSystemError.unreadable
    }
}

private struct MailAvailableVolume: CleanupVolumeChecking {
    func isAvailable(volumeIdentifier: String) async -> Bool { true }
}

private struct MailRunningChecker: CleanupRunningApplicationChecking {
    let running: Bool
    func isRunning(bundleIdentifier: String) async -> Bool { running && bundleIdentifier == "com.apple.mail" }
}

private struct MailUnknownCapacity: CleanupCapacityReading {
    func availableCapacity(at url: URL) async -> Int64? { nil }
}

private struct MailFixtureTrashMover: CleanupMoving {
    let trash: URL
    func moveToTrash(_ url: URL) async throws -> URL {
        let destination = trash.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
    func moveToQuarantine(_ url: URL, planID: CleanPlanID, itemID: UUID) async throws -> URL {
        throw CleanupFileSystemError.unreadable
    }
}

private struct MailReportedPathFileSystem: ReadOnlyFileSystem {
    let root: URL
    let source: URL
    let reported: FileSnapshot
    func snapshot(at url: URL) throws -> FileSnapshot {
        if PathSafety.normalizedPath(url.path) == PathSafety.normalizedPath(source.path) { return reported }
        return try RuleTestReadOnlyFileSystem(root: root).snapshot(at: url)
    }
    func children(of directory: URL) throws -> [URL] {
        try FoundationReadOnlyFileSystem().children(of: directory)
    }
}
