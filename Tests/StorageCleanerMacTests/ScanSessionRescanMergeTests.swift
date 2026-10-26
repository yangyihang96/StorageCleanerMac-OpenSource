import Foundation
import XCTest
@testable import StorageCleanerMac

/// D104 G5: scanning only the locations that became readable completes the
/// same session. These tests cover the merge; the store's flow is in
/// `ScanAccessReturnTests`.
final class ScanSessionRescanMergeTests: XCTestCase {
    private let sessionID = ScanSessionID()
    private let provenance = CleanupRuleSetProvenance(fingerprint: "g5-fixture", rules: [])

    func testDeniedRuleIDsNameEveryDeniedRuleOfTheReadablePaths() {
        let session = makeSession(permissions: [
            report("downloads.installers", "/H/Downloads", .permissionDenied),
            report("downloads.large-items", "/H/Downloads", .permissionDenied),
            report("system.user-logs", "/H/Library/Logs", .permissionDenied),
            report("system.user-caches", "/H/Library/Caches", .readable),
            report("gone", "/H/Gone", .missing),
            report("broken", "/H/Broken", .unreadable),
        ])
        XCTAssertEqual(
            session.deniedRuleIDs(at: ["/H/Downloads", "/H/Library/Caches", "/H/Gone", "/H/Broken"]),
            ["downloads.installers", "downloads.large-items"]
        )
        XCTAssertEqual(session.deniedRuleIDs(at: []), [])
    }

    func testOnlyTheRescannedRulesChangeAndEverythingElseStays() throws {
        let kept = candidate("system.user-caches", "/H/Library/Caches/com.example.app", inode: 1, bytes: 4_096)
        let original = makeSession(
            groups: [
                ("system", [("system.user-caches", [kept]), ("system.user-logs", [])]),
                ("downloads", [("downloads.installers", [])]),
            ],
            permissions: [
                report("system.user-caches", "/H/Library/Caches", .readable),
                report("system.user-logs", "/H/Library/Logs", .permissionDenied),
                report("downloads.installers", "/H/Downloads", .permissionDenied),
            ],
            issues: [
                ScanIssue(ruleID: "system.user-logs", path: "/H/Library/Logs", kind: .permissionDenied),
                ScanIssue(ruleID: "downloads.installers", path: "/H/Downloads", kind: .permissionDenied),
                ScanIssue(ruleID: "system.user-caches", path: "/H/Library/Caches/link", kind: .symbolicLinkSkipped),
            ],
            metrics: metrics(visited: 10, directories: 3, deduplicated: 1, duration: 2, notActionable: 1)
        )
        let log = candidate("system.user-logs", "/H/Library/Logs/com.example.app", inode: 2, bytes: 8_192)
        let installer = candidate(
            "downloads.installers", "/H/Downloads/Setup.dmg", inode: 3, bytes: 16_384, risk: .reviewOnly
        )
        let rescan = makeSession(
            groups: [
                ("system", [("system.user-logs", [log])]),
                ("downloads", [("downloads.installers", [installer])]),
            ],
            permissions: [
                report("system.user-logs", "/H/Library/Logs", .readable),
                report("downloads.installers", "/H/Downloads", .readable),
            ],
            metrics: metrics(visited: 5, directories: 2, deduplicated: 2, duration: 1, notActionable: 2),
            completedAt: Date(timeIntervalSince1970: 2_000)
        )

        let merged = try XCTUnwrap(original.mergingRescan(
            rescan,
            ofRules: ["system.user-logs", "downloads.installers"]
        ))

        XCTAssertEqual(merged.id, original.id)
        XCTAssertEqual(merged.startedAt, original.startedAt)
        XCTAssertEqual(merged.completedAt, rescan.completedAt)
        XCTAssertEqual(merged.outcome, .complete, "nothing limits the coverage any more")
        XCTAssertEqual(merged.categories.map(\.id), ["system", "downloads"])
        XCTAssertEqual(
            merged.categories.flatMap(\.subcategories).map(\.id),
            ["system.user-caches", "system.user-logs", "downloads.installers"]
        )
        XCTAssertEqual(merged.candidates.map(\.id), [kept.id, log.id, installer.id])
        XCTAssertEqual(
            merged.permissions.map(\.ruleID),
            ["system.user-caches", "system.user-logs", "downloads.installers"]
        )
        XCTAssertTrue(merged.permissions.allSatisfy { $0.status == .readable })
        XCTAssertEqual(merged.issues.map(\.kind), [.symbolicLinkSkipped])
        XCTAssertEqual(merged.metrics.candidateCount, 3)
        XCTAssertEqual(merged.metrics.estimatedCandidateBytes, 4_096 + 8_192 + 16_384)
        XCTAssertEqual(merged.metrics.completeMeasurementCandidateCount, 3)
        XCTAssertEqual(merged.metrics.visitedEntryCount, 15)
        XCTAssertEqual(merged.metrics.visitedDirectoryCount, 5)
        XCTAssertEqual(merged.metrics.deduplicatedIdentityCount, 3)
        XCTAssertEqual(merged.metrics.notActionableCandidateCount, 3)
        XCTAssertEqual(merged.metrics.permissionFailureCount, 0)
        XCTAssertEqual(merged.metrics.duration, 3)
        XCTAssertEqual(merged.rulesVersion, original.rulesVersion)
        XCTAssertEqual(merged.rulesProvenance, original.rulesProvenance)
        XCTAssertEqual(merged.developerInactivityThresholdDays, original.developerInactivityThresholdDays)
    }

    /// A rule the rescan did not reach (here its deadline passed first) keeps
    /// its old report, so its location still counts as not read.
    func testARuleTheRescanDidNotReachStaysNotRead() throws {
        let original = makeSession(
            groups: [("system", [("system.user-logs", [])]), ("downloads", [("downloads.installers", [])])],
            permissions: [
                report("system.user-logs", "/H/Library/Logs", .permissionDenied),
                report("downloads.installers", "/H/Downloads", .permissionDenied),
            ],
            issues: [
                ScanIssue(ruleID: "system.user-logs", path: "/H/Library/Logs", kind: .permissionDenied),
                ScanIssue(ruleID: "downloads.installers", path: "/H/Downloads", kind: .permissionDenied),
            ]
        )
        let log = candidate("system.user-logs", "/H/Library/Logs/com.example.app", inode: 2, bytes: 8_192)
        let rescan = makeSession(
            outcome: .partial,
            groups: [("system", [("system.user-logs", [log])])],
            permissions: [report("system.user-logs", "/H/Library/Logs", .readable)],
            issues: [ScanIssue(ruleID: nil, path: nil, kind: .timedOut)]
        )

        let merged = try XCTUnwrap(original.mergingRescan(
            rescan,
            ofRules: ["system.user-logs", "downloads.installers"]
        ))

        XCTAssertEqual(merged.candidates.map(\.id), [log.id])
        XCTAssertEqual(merged.permissions.map(\.status), [.readable, .permissionDenied])
        XCTAssertEqual(
            merged.issues.map(\.kind),
            [.permissionDenied, .timedOut],
            "the unreached rule keeps its issue; the rescan's deadline is kept too"
        )
        XCTAssertEqual(merged.issues.first?.ruleID, "downloads.installers")
        XCTAssertEqual(merged.metrics.permissionFailureCount, 1)
        XCTAssertEqual(merged.outcome, .partial)
    }

    /// A rescanned row that is a listed file, lies inside one or contains one
    /// is not listed again and counts as deduplicated.
    func testRowsAlreadyListedAreNotListedTwice() throws {
        let listed = candidate("system.user-caches", "/H/Library/Caches/AppA", inode: 1, bytes: 4_096)
        let original = makeSession(
            groups: [("system", [("system.user-caches", [listed]), ("system.user-logs", [])])],
            permissions: [
                report("system.user-caches", "/H/Library/Caches", .readable),
                report("system.user-logs", "/H/Library/Logs", .permissionDenied),
            ],
            issues: [ScanIssue(ruleID: "system.user-logs", path: "/H/Library/Logs", kind: .permissionDenied)]
        )
        let sameFile = candidate("system.user-logs", "/H/Library/Logs/hard-link", inode: 1, bytes: 4_096)
        let inside = candidate("system.user-logs", "/H/Library/Caches/AppA/nested", inode: 2, bytes: 1_024)
        let containing = candidate("system.user-logs", "/H/Library/Caches", inode: 3, bytes: 9_000)
        let sibling = candidate("system.user-logs", "/H/Library/Caches/AppAB", inode: 4, bytes: 2_048)
        let separate = candidate("system.user-logs", "/H/Library/Logs/AppB", inode: 5, bytes: 512)
        let rescan = makeSession(
            groups: [("system", [("system.user-logs", [sameFile, inside, containing, sibling, separate])])],
            permissions: [report("system.user-logs", "/H/Library/Logs", .readable)]
        )

        let merged = try XCTUnwrap(original.mergingRescan(rescan, ofRules: ["system.user-logs"]))

        XCTAssertEqual(merged.candidates.map(\.id), [listed.id, sibling.id, separate.id])
        let deduplicated = merged.issues.filter { $0.kind == .hardLinkDeduplicated }
        XCTAssertEqual(deduplicated.map(\.path), [sameFile, inside, containing].map(\.snapshot.standardizedPath))
        XCTAssertTrue(deduplicated.allSatisfy { $0.ruleID == "system.user-logs" })
        XCTAssertEqual(merged.metrics.deduplicatedIdentityCount, 3)
        XCTAssertEqual(merged.metrics.candidateCount, 3)
        XCTAssertEqual(merged.outcome, .complete, "deduplicated rows do not limit the coverage")
    }

    func testNothingMergesThatDoesNotBelongToTheSessionAndItsRules() {
        let original = makeSession(
            groups: [("system", [("system.user-logs", [])])],
            permissions: [report("system.user-logs", "/H/Library/Logs", .permissionDenied)]
        )
        let log = candidate("system.user-logs", "/H/Library/Logs/com.example.app", inode: 2, bytes: 8_192)
        func rescan(
            id: ScanSessionID? = nil,
            outcome: ScanOutcome = .complete,
            rulesVersion: String = "g5.1",
            provenance: CleanupRuleSetProvenance? = nil,
            ruleID: String = "system.user-logs"
        ) -> ScanSession {
            makeSession(
                id: id ?? sessionID,
                outcome: outcome,
                groups: [("system", [(ruleID, [log])])],
                permissions: [report(ruleID, "/H/Library/Logs", .readable)],
                rulesVersion: rulesVersion,
                provenance: provenance ?? self.provenance
            )
        }

        XCTAssertNotNil(original.mergingRescan(rescan(), ofRules: ["system.user-logs"]), "fixture")
        XCTAssertNil(original.mergingRescan(rescan(outcome: .cancelled), ofRules: ["system.user-logs"]))
        XCTAssertNil(original.mergingRescan(rescan(id: ScanSessionID()), ofRules: ["system.user-logs"]))
        XCTAssertNil(original.mergingRescan(rescan(rulesVersion: "g5.2"), ofRules: ["system.user-logs"]))
        XCTAssertNil(original.mergingRescan(
            rescan(provenance: CleanupRuleSetProvenance(fingerprint: "changed", rules: [])),
            ofRules: ["system.user-logs"]
        ))
        XCTAssertNil(original.mergingRescan(rescan(), ofRules: []), "no rule requested")
        XCTAssertNil(original.mergingRescan(rescan(), ofRules: ["system.user-caches"]), "the rescan did not report on it")
        XCTAssertNil(
            original.mergingRescan(rescan(ruleID: "system.unlisted"), ofRules: ["system.unlisted"]),
            "the session never listed that rule"
        )
    }

    func testACancelledSessionStaysCancelled() throws {
        let original = makeSession(
            outcome: .cancelled,
            groups: [("system", [("system.user-logs", [])])],
            permissions: [report("system.user-logs", "/H/Library/Logs", .permissionDenied)]
        )
        let rescan = makeSession(
            groups: [("system", [("system.user-logs", [])])],
            permissions: [report("system.user-logs", "/H/Library/Logs", .readable)]
        )
        XCTAssertEqual(try XCTUnwrap(original.mergingRescan(rescan, ofRules: ["system.user-logs"])).outcome, .cancelled)
    }

    /// The merged outcome follows the scanner's test: what the rescan could
    /// not read or measure, and roots it could not read, leave it partial.
    func testTheMergedOutcomeFollowsTheScannersCoverageTest() throws {
        let original = makeSession(
            groups: [("system", [("system.user-logs", [])])],
            permissions: [report("system.user-logs", "/H/Library/Logs", .permissionDenied)],
            issues: [ScanIssue(ruleID: "system.user-logs", path: "/H/Library/Logs", kind: .permissionDenied)]
        )
        func outcome(
            permission: CleanupPermissionStatus = .readable,
            issue: ScanIssueKind? = nil,
            measurement: MeasurementCompleteness = .complete
        ) throws -> ScanOutcome {
            let row = candidate(
                "system.user-logs", "/H/Library/Logs/com.example.app", inode: 2, bytes: 8_192,
                measurement: measurement
            )
            let rescan = makeSession(
                groups: [("system", [("system.user-logs", [row])])],
                permissions: [report("system.user-logs", "/H/Library/Logs", permission)],
                issues: issue.map { [ScanIssue(ruleID: "system.user-logs", path: "/H/Library/Logs/x", kind: $0)] } ?? []
            )
            return try XCTUnwrap(original.mergingRescan(rescan, ofRules: ["system.user-logs"])).outcome
        }

        XCTAssertEqual(try outcome(), .complete)
        XCTAssertEqual(try outcome(permission: .permissionDenied), .partial)
        XCTAssertEqual(try outcome(permission: .unreadable), .partial, "a root behind a symbolic link")
        XCTAssertEqual(try outcome(measurement: .lowerBound(reason: .permissionDenied)), .partial)
        for kind in [ScanIssueKind.symbolicLinkSkipped, .hardLinkDeduplicated, .cloudPlaceholderSkipped] {
            XCTAssertEqual(try outcome(issue: kind), .complete, "\(kind)")
            XCTAssertFalse(kind.limitsScanCoverage)
        }
        for kind in [ScanIssueKind.permissionDenied, .vanished, .unreadable, .metadataUnavailable,
                     .volumeUnavailable, .outsideAllowedRoot, .timedOut, .candidateNotActionable,
                     .candidateContainsExcludedPath, .candidateContainsProtectedData] {
            XCTAssertEqual(try outcome(issue: kind), .partial, "\(kind)")
            XCTAssertTrue(kind.limitsScanCoverage)
        }
    }

    /// What the user selected or cleared stays so; only added rows take the
    /// default selection, as after a full scan (D47).
    func testTheSelectionKeepsChoicesAndDefaultsOnlyAddedRows() throws {
        let cleared = candidate("system.user-caches", "/H/Library/Caches/AppA", inode: 1, bytes: 4_096)
        let chosen = candidate(
            "downloads.large-items", "/H/Downloads/Movie.mov", inode: 6, bytes: 32_768, risk: .reviewOnly
        )
        let original = makeSession(
            groups: [
                ("system", [("system.user-caches", [cleared]), ("system.user-logs", [])]),
                ("downloads", [("downloads.large-items", [chosen]), ("downloads.installers", [])]),
            ],
            permissions: [
                report("system.user-caches", "/H/Library/Caches", .readable),
                report("system.user-logs", "/H/Library/Logs", .permissionDenied),
                report("downloads.large-items", "/H/Downloads", .readable),
                report("downloads.installers", "/H/Other", .permissionDenied),
            ]
        )
        var selection = CleanupSelection.defaults(in: original)
        XCTAssertEqual(selection.selectedCandidateIDs, [cleared.id], "fixture: the green row is preselected")
        selection.setCandidate(cleared.id, selected: false, in: original)
        selection.setCandidate(chosen.id, selected: true, in: original)
        let log = candidate("system.user-logs", "/H/Library/Logs/com.example.app", inode: 2, bytes: 8_192)
        let installer = candidate(
            "downloads.installers", "/H/Other/Setup.dmg", inode: 3, bytes: 16_384, risk: .reviewOnly
        )
        let rescan = makeSession(
            groups: [
                ("system", [("system.user-logs", [log])]),
                ("downloads", [("downloads.installers", [installer])]),
            ],
            permissions: [
                report("system.user-logs", "/H/Library/Logs", .readable),
                report("downloads.installers", "/H/Other", .readable),
            ]
        )
        let merged = try XCTUnwrap(original.mergingRescan(
            rescan,
            ofRules: ["system.user-logs", "downloads.installers"]
        ))

        let updated = selection.addingDefaults(forRowsAddedTo: original, in: merged)

        XCTAssertEqual(updated.selectedCandidateIDs, [chosen.id, log.id])
        XCTAssertEqual(updated.explicitlySelectedCandidateIDs, selection.explicitlySelectedCandidateIDs)
        XCTAssertTrue(updated.isExplicitlySelected(chosen.id))
    }

    // MARK: Fixtures

    private func report(
        _ ruleID: String,
        _ path: String,
        _ status: CleanupPermissionStatus
    ) -> CleanupPermissionReport {
        CleanupPermissionReport(ruleID: ruleID, path: path, status: status)
    }

    private func metrics(
        visited: Int = 0,
        directories: Int = 0,
        deduplicated: Int = 0,
        duration: TimeInterval = 0,
        notActionable: Int = 0
    ) -> ScanMetrics {
        ScanMetrics(
            visitedEntryCount: visited,
            visitedDirectoryCount: directories,
            candidateCount: 0,
            deduplicatedIdentityCount: deduplicated,
            estimatedCandidateBytes: 0,
            duration: duration,
            notActionableCandidateCount: notActionable
        )
    }

    private func makeSession(
        id: ScanSessionID? = nil,
        outcome: ScanOutcome = .partial,
        groups: [(String, [(String, [ScanCandidate])])] = [],
        permissions: [CleanupPermissionReport],
        issues: [ScanIssue] = [],
        metrics: ScanMetrics? = nil,
        completedAt: Date = Date(timeIntervalSince1970: 1_001),
        rulesVersion: String = "g5.1",
        provenance: CleanupRuleSetProvenance? = nil
    ) -> ScanSession {
        RescanFixtureRows.session(
            id: id ?? sessionID,
            outcome: outcome,
            groups: groups,
            permissions: permissions,
            issues: issues,
            metrics: metrics ?? self.metrics(),
            completedAt: completedAt,
            rulesVersion: rulesVersion,
            provenance: provenance ?? self.provenance
        )
    }

    private func candidate(
        _ ruleID: String,
        _ path: String,
        inode: UInt64,
        bytes: Int64,
        risk: CleanupRisk = .safe,
        measurement: MeasurementCompleteness = .complete
    ) -> ScanCandidate {
        RescanFixtureRows.candidate(
            ruleID, path, sessionID: sessionID, inode: inode, bytes: bytes, risk: risk, measurement: measurement
        )
    }
}

/// Rows for the D104 G5 tests: a green (safe) or yellow (review) row whose
/// identifier is stable by rule and path, as the scanner's are.
enum RescanFixtureRows {
    static func id(_ ruleID: String, _ path: String) -> ScanCandidateID {
        ScanCandidateID(stableKey: ruleID + "\u{0}" + path)
    }

    static func candidate(
        _ ruleID: String,
        _ path: String,
        sessionID: ScanSessionID,
        inode: UInt64,
        bytes: Int64,
        risk: CleanupRisk = .safe,
        measurement: MeasurementCompleteness = .complete
    ) -> ScanCandidate {
        let source = URL(fileURLWithPath: path)
        return ScanCandidate(
            id: id(ruleID, path),
            sessionID: sessionID,
            ruleID: ruleID,
            ruleSelectionPolicyVersion: 1,
            categoryID: String(ruleID.prefix { $0 != "." }),
            categoryTitle: ruleID,
            subcategoryTitle: ruleID,
            sourceURL: source,
            allowedRootURL: source.deletingLastPathComponent(),
            snapshot: FileSnapshot(
                identity: FileIdentity(deviceID: 7, inode: inode, entryKind: .directory, creationTimeNanoseconds: 1),
                standardizedPath: path,
                volumeIdentifier: "g5-fixture",
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
                level: risk == .safe ? .recommended : .notRecommended,
                reasonCode: "g5-fixture",
                evidenceCodes: []
            ),
            defaultSelection: risk == .safe ? .selected : .unselected,
            executionEligibility: risk == .safe ? .eligible : .eligibleAfterReview,
            measurementCompleteness: measurement,
            isManuallySelectable: true,
            action: risk == .safe ? .moveToTrash : .moveToTrashAfterReview,
            requiredClosedBundleIDs: [],
            reason: "G5 fixture"
        )
    }

    static func session(
        id: ScanSessionID,
        outcome: ScanOutcome,
        groups: [(String, [(String, [ScanCandidate])])],
        permissions: [CleanupPermissionReport],
        issues: [ScanIssue] = [],
        metrics: ScanMetrics = ScanMetrics(
            visitedEntryCount: 0, candidateCount: 0, deduplicatedIdentityCount: 0,
            estimatedCandidateBytes: 0, duration: 0
        ),
        completedAt: Date = Date(timeIntervalSince1970: 1_001),
        rulesVersion: String,
        provenance: CleanupRuleSetProvenance?,
        developerInactivityThresholdDays: Int = 45,
        includedCategoryIDs: Set<String>? = nil,
        includedRuleIDs: Set<String>? = nil
    ) -> ScanSession {
        ScanSession(
            id: id,
            rulesVersion: rulesVersion,
            startedAt: Date(timeIntervalSince1970: 1_000),
            completedAt: completedAt,
            outcome: outcome,
            categories: groups.map { categoryID, subcategories in
                CleanupScanCategory(
                    id: categoryID,
                    title: categoryID,
                    subcategories: subcategories.map { ruleID, candidates in
                        CleanupScanSubcategory(
                            id: ruleID,
                            title: ruleID,
                            risk: candidates.first?.risk ?? .safe,
                            recommendation: .recommended,
                            reason: "G5 fixture",
                            candidates: candidates
                        )
                    }
                )
            },
            issues: issues,
            permissions: permissions,
            metrics: metrics,
            developerInactivityThresholdDays: developerInactivityThresholdDays,
            includedCategoryIDs: includedCategoryIDs,
            includedRuleIDs: includedRuleIDs,
            rulesProvenance: provenance
        )
    }
}
