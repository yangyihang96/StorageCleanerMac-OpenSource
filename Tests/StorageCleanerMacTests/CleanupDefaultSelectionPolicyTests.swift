import Foundation
import XCTest
@testable import StorageCleanerMac

/// D47 (checkpoint C1-2): the junk scan preselects every green row. The only
/// exception is a row whose app is running (cleanup would skip it anyway).
/// Yellow and red rows and "Empty Trash" (D23) are never preselected. Large
/// caches say on the row that rebuilding them costs time. Rows are built in
/// memory only; nothing touches the file system.
final class CleanupDefaultSelectionPolicyTests: XCTestCase {
    private static let gib: Int64 = 1_024 * 1_024 * 1_024

    func testOnlyARunningOwnerHoldsBackAGreenRow() {
        let unidentifiedCache = Self.candidate(name: "SomeTool", ownerResolution: .unresolved)
        let recentLog = Self.candidate(name: "recent.log", logWriteState: .recent)
        let unverifiedLog = Self.candidate(name: "unverified.log", logWriteState: .unverified)
        let quietLog = Self.candidate(name: "quiet.log", logWriteState: .quiet)
        let optionalRuleCache = Self.candidate(
            name: "optional-rule", recommendation: .optional, defaultSelection: .unselected
        )
        let lowerBoundCache = Self.candidate(
            name: "partly-unreadable", measurement: .lowerBound(reason: .permissionDenied)
        )
        let runningOwnerCache = Self.candidate(
            name: "com.example.running", ownerResolution: .declared, runningOwners: ["com.example.running"]
        )
        let runningOwnerLog = Self.candidate(
            name: "com.example.running.log", logWriteState: .quiet,
            ownerResolution: .inferredFromName, runningOwners: ["com.example.running"]
        )
        let yellow = Self.candidate(name: "Mail Downloads", risk: .reviewOnly, categoryID: "mail")
        let red = Self.candidate(name: "Example Beta.app", risk: .protected, categoryID: "applications")
        let emptyTrash = Self.candidate(name: ".Trash", risk: .protected, categoryID: "trash", action: .emptyTrash)

        let preselected = [
            unidentifiedCache, recentLog, unverifiedLog, quietLog, optionalRuleCache, lowerBoundCache,
        ]
        let notPreselected = [runningOwnerCache, runningOwnerLog, yellow, red, emptyTrash]
        for candidate in preselected {
            XCTAssertEqual(candidate.risk, .safe, candidate.sourceURL.lastPathComponent)
            XCTAssertTrue(candidate.isSelectable, candidate.sourceURL.lastPathComponent)
            XCTAssertFalse(candidate.isHeldBackFromPreselection, candidate.sourceURL.lastPathComponent)
            XCTAssertTrue(candidate.isPreselectedByDefault, candidate.sourceURL.lastPathComponent)
        }
        // "Select Recommended" keeps following the rule's recommendation; every
        // green row of the bundled rules is recommended.
        let recommended = preselected.filter { $0.id != optionalRuleCache.id }
        for candidate in recommended {
            XCTAssertTrue(candidate.isRecommendedForSelection, candidate.sourceURL.lastPathComponent)
        }
        XCTAssertFalse(optionalRuleCache.isRecommendedForSelection)
        for candidate in notPreselected {
            XCTAssertTrue(candidate.isSelectable, candidate.sourceURL.lastPathComponent)
            XCTAssertFalse(candidate.isPreselectedByDefault, candidate.sourceURL.lastPathComponent)
            XCTAssertFalse(candidate.isRecommendedForSelection, candidate.sourceURL.lastPathComponent)
        }
        XCTAssertTrue(runningOwnerCache.isHeldBackFromPreselection)
        XCTAssertTrue(runningOwnerLog.isHeldBackFromPreselection)

        let session = Self.session(preselected + notPreselected)
        XCTAssertEqual(
            CleanupSelection.defaults(in: session).selectedCandidateIDs,
            Set(preselected.map(\.id))
        )
        XCTAssertEqual(
            CleanupSelection.recommended(in: session).selectedCandidateIDs,
            Set(recommended.map(\.id))
        )
        // Once the app quits, its rows are preselected too.
        let quit = session.updatingRunningOwners(from: CleanupApplicationSnapshot())
        XCTAssertEqual(
            CleanupSelection.defaults(in: quit).selectedCandidateIDs,
            Set((preselected + [runningOwnerCache, runningOwnerLog]).map(\.id))
        )
        // A cancelled scan still preselects nothing.
        XCTAssertTrue(CleanupSelection.defaults(in: Self.session(preselected, outcome: .cancelled))
            .selectedCandidateIDs.isEmpty)
    }

    func testPreselectedRowsAreShownAsRecommendedAndKeepTheirHints() {
        let unidentifiedCache = Self.candidate(name: "SomeTool", ownerResolution: .unresolved)
        let unidentifiedLog = Self.candidate(name: "SomeTool.log", logWriteState: .quiet, ownerResolution: .unresolved)
        let recentLog = Self.candidate(name: "recent.log", logWriteState: .recent)
        let unverifiedLog = Self.candidate(name: "unverified.log", logWriteState: .unverified)
        let identifiedCache = Self.candidate(name: "com.example.idle", ownerResolution: .inferredFromName)

        XCTAssertEqual(CleanupRecommendationDisplayPolicy.level(for: unidentifiedCache), .recommended)
        XCTAssertEqual(
            CleanupCandidateRowHint.ownerStatus(for: unidentifiedCache),
            .init(
                text: L10n.text("未识别所属应用，清理前无法确认它是否在运行",
                                "Its app could not be identified, so whether it is running cannot be checked"),
                systemImage: "questionmark.app",
                // Review P2-8: the hint is about safety (no running-app check
                // can protect the row), so it uses the warning colour.
                tone: .warning
            )
        )
        XCTAssertEqual(
            CleanupCandidateRowHint.ownerStatus(for: recentLog),
            .init(text: L10n.text("最近 7 天内仍有写入", "Written within the last 7 days"),
                  systemImage: "clock.arrow.circlepath", tone: .warning)
        )
        XCTAssertEqual(
            CleanupCandidateRowHint.ownerStatus(for: unverifiedLog),
            .init(text: L10n.text("无法确认最近 7 天内是否有写入",
                                  "Cannot confirm whether it was written in the last 7 days"),
                  systemImage: "questionmark.circle", tone: .warning)
        )
        // Logs never depended on their owner (D40); a quiet log says nothing.
        XCTAssertNil(CleanupCandidateRowHint.ownerStatus(for: unidentifiedLog))
        XCTAssertNil(CleanupCandidateRowHint.ownerStatus(for: identifiedCache))
    }

    func testLargeCachesSayThatRebuildingThemIsSlow() {
        let threshold = CleanupRebuildCostPolicy.largeCacheThresholdBytes
        XCTAssertEqual(threshold, 5 * Self.gib)
        let hint = CleanupCandidateRowHint.Line(
            text: L10n.text("体积较大：重建需要重新下载或生成，可能较慢",
                            "Large cache: rebuilding it means downloading or generating it again, which may be slow"),
            systemImage: "hourglass",
            tone: .secondary
        )

        let shows = [
            Self.candidate(name: "app-cache", bytes: threshold),
            Self.candidate(name: "Chrome", categoryID: "browser-cache", bytes: 9 * Self.gib),
            Self.candidate(name: "com.example.app", categoryID: "application-cache", bytes: 6 * Self.gib),
            Self.candidate(name: "DerivedData", categoryID: "developer", bytes: 20 * Self.gib),
            // A large cache needs the hint whatever its grade.
            Self.candidate(name: "CloudKit", risk: .reviewOnly, bytes: 6 * Self.gib),
            Self.candidate(name: "_cacache", risk: .protected, categoryID: "developer", bytes: 7 * Self.gib),
            Self.candidate(name: "lower-bound", bytes: threshold,
                           measurement: .lowerBound(reason: .symbolicLinkSkipped)),
        ]
        for candidate in shows {
            XCTAssertTrue(CleanupRebuildCostPolicy.showsHint(for: candidate), candidate.sourceURL.lastPathComponent)
            XCTAssertEqual(CleanupCandidateRowHint.rebuildCost(for: candidate), hint, candidate.sourceURL.lastPathComponent)
        }

        let hidden = [
            Self.candidate(name: "just-below", bytes: threshold - 1),
            Self.candidate(name: "big.log", bytes: 8 * Self.gib, logWriteState: .quiet),
            Self.candidate(name: "dev.log", categoryID: "developer", bytes: 8 * Self.gib, logWriteState: .recent),
            Self.candidate(name: "Downloads item", risk: .reviewOnly, categoryID: "downloads", bytes: 8 * Self.gib),
            Self.candidate(name: "Mail Downloads", risk: .reviewOnly, categoryID: "mail", bytes: 8 * Self.gib),
            Self.candidate(name: "Example Beta.app", risk: .protected, categoryID: "applications", bytes: 30 * Self.gib),
            Self.candidate(name: ".Trash", risk: .protected, categoryID: "trash", action: .emptyTrash, bytes: 30 * Self.gib),
        ]
        for candidate in hidden {
            XCTAssertFalse(CleanupRebuildCostPolicy.showsHint(for: candidate), candidate.sourceURL.lastPathComponent)
            XCTAssertNil(CleanupCandidateRowHint.rebuildCost(for: candidate), candidate.sourceURL.lastPathComponent)
        }
    }

    /// The result row shows both shared hints; the group text describes D47.
    func testResultRowsShowTheSharedHints() throws {
        let views = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/StorageCleanerMac/Views/CleanupScanViews.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(views.contains("CleanupCandidateRowHint.ownerStatus(for: candidate)"))
        XCTAssertTrue(views.contains("CleanupCandidateRowHint.rebuildCost(for: candidate)"))
        XCTAssertFalse(views.contains("缓存在所属应用能识别且未运行时"))
        XCTAssertFalse(views.contains("日志在最近 7 天没有写入"))
        XCTAssertTrue(views.contains("所属应用正在运行的行除外"))
    }

    // MARK: - Fixtures

    private static let sessionID = ScanSessionID()

    private static func candidate(
        name: String,
        risk: CleanupRisk = .safe,
        categoryID: String = "system",
        action: CleanupRuleAction? = nil,
        recommendation: CleanupRecommendationLevel? = nil,
        defaultSelection: CleanupDefaultSelection? = nil,
        bytes: Int64 = 4_096,
        measurement: MeasurementCompleteness = .complete,
        logWriteState: CleanupLogWriteState? = nil,
        ownerResolution: CleanupOwnerResolution = .noApplication,
        runningOwners: [String] = []
    ) -> ScanCandidate {
        let tierAction: CleanupRuleAction = switch risk {
        case .safe: .moveToTrash
        case .reviewOnly: .moveToTrashAfterReview
        case .protected: .moveToTrashAfterProtectedReview
        case .informational: .revealOnly
        }
        let action = action ?? tierAction
        let execution: CleanupExecutionEligibility = switch action {
        case .moveToTrash: .eligible
        case .moveToTrashAfterReview: .eligibleAfterReview
        case .moveToTrashAfterProtectedReview, .emptyTrash: .eligibleAfterProtectedReview
        case .revealOnly: .advisoryOnly
        }
        let level = recommendation ?? (risk == .safe ? .recommended : .notRecommended)
        let source = URL(fileURLWithPath: "/D47Fixture/\(categoryID)/\(name)")
        var evidence = ["read-only-metadata"]
        if let logWriteState {
            evidence.append(CleanupLogPreselectionPolicy.evidenceCode(for: logWriteState))
        }
        var candidate = ScanCandidate(
            id: ScanCandidateID(),
            sessionID: sessionID,
            ruleID: "d47.\(categoryID)",
            ruleSelectionPolicyVersion: 1,
            categoryID: categoryID,
            categoryTitle: categoryID,
            subcategoryTitle: categoryID,
            sourceURL: source,
            allowedRootURL: source.deletingLastPathComponent(),
            snapshot: FileSnapshot(
                identity: FileIdentity(
                    deviceID: 7,
                    inode: UInt64(abs(name.hashValue % 1_000_000)) + 1,
                    entryKind: .directory,
                    creationTimeNanoseconds: 1
                ),
                standardizedPath: source.path,
                volumeIdentifier: "d47-fixture",
                logicalSizeBytes: bytes,
                allocatedSizeBytes: bytes,
                modificationTimeNanoseconds: 1,
                isWritableVolume: true,
                isCloudItem: false,
                isCloudPlaceholder: false,
                hasSymbolicLinkComponent: false
            ),
            risk: risk,
            recommendation: CleanupRecommendation(
                level: level, reasonCode: "d47-fixture", evidenceCodes: evidence
            ),
            defaultSelection: defaultSelection
                ?? (risk == .safe && level == .recommended ? .selected : .unselected),
            executionEligibility: execution,
            measurementCompleteness: measurement,
            isManuallySelectable: true,
            action: action,
            requiredClosedBundleIDs: ownerResolution == .declared ? runningOwners : [],
            reason: "D47 fixture"
        )
        candidate.ownerResolution = ownerResolution
        candidate.ownerBundleIdentifiers = runningOwners
        candidate.runningOwnerBundleIdentifiers = runningOwners
        return candidate
    }

    private static func session(_ candidates: [ScanCandidate], outcome: ScanOutcome = .complete) -> ScanSession {
        ScanSession(
            id: sessionID,
            rulesVersion: "d47-fixture",
            startedAt: Date(timeIntervalSince1970: 1_000),
            completedAt: Date(timeIntervalSince1970: 1_001),
            outcome: outcome,
            categories: [
                CleanupScanCategory(
                    id: "d47",
                    title: "D47",
                    subcategories: [
                        CleanupScanSubcategory(
                            id: "d47.rows",
                            title: "D47",
                            risk: .safe,
                            recommendation: .recommended,
                            reason: "D47 fixture",
                            candidates: candidates
                        ),
                    ]
                ),
            ],
            issues: [],
            permissions: [],
            metrics: ScanMetrics(
                visitedEntryCount: candidates.count,
                visitedDirectoryCount: candidates.count,
                candidateCount: candidates.count,
                deduplicatedIdentityCount: 0,
                estimatedCandidateBytes: 0,
                completeMeasurementCandidateCount: candidates.count,
                duration: 0.1
            )
        )
    }
}
