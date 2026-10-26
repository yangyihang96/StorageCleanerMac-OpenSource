import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class CleanupRuleProvenanceTests: XCTestCase {
    func testAllSourcesHaveValidMaintenanceAndCommittedRevisions() throws {
        let rules = try CleanupRuleSetLoader.loadBundled()
        try CleanupRuleMaintenanceValidator.validate(rules, baseline: CleanupRuleTestFixtures.baseline())
        XCTAssertEqual(Set(rules.rules.compactMap { $0.maintenance?.source.rawValue }),
                       ["json", "developer-catalog", "coverage-catalog"])
        XCTAssertTrue(DeveloperToolArtifactCatalog.cleanupRules.allSatisfy { $0.maintenance?.source == .developerCatalog })
        XCTAssertTrue(CleanupCoverageCatalog.cleanupRules.allSatisfy { $0.maintenance?.source == .coverageCatalog })
        XCTAssertEqual(rules.effectiveProvenance.fingerprint.count, 64)
        XCTAssertEqual(rules.effectiveProvenance.rules.count, rules.rules.count)
    }

    func testEveryOriginalMatchingAndSelectionFieldMatchesIntegrationSnapshot() throws {
        let baseline = try CleanupRuleTestFixtures.baseline()
        // D227＋旧值：was 73; downloads.installers and downloads.large-items retired with their snapshots.
        XCTAssertEqual(baseline.legacyRules.count, 71)
        let current = try CleanupRuleSetLoader.loadBundled()
        for original in baseline.legacyRules {
            let actual = try XCTUnwrap(current.rules.first { $0.id == original.id })
            XCTAssertEqual(try CleanupRuleFingerprint.normalizedData(for: actual, includingMaintenance: false),
                           try CleanupRuleFingerprint.normalizedData(for: original, includingMaintenance: false), original.id)
        }
    }

    func testMetadataMigrationPreservesActualCandidateIdentitiesAndSelections() async throws {
        let baseline = try CleanupRuleTestFixtures.baseline()
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let originalIDs = Set(baseline.legacyRules.map(\.id))
        // Keep original limits: exact catalog allowlists also validate sizes.
        let old = baseline.legacyRules
        let annotated = bundled.rules.filter { originalIDs.contains($0.id) }
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        for rule in old { try CleanupRuleTestFixtures.seed(rule, home: home) }
        try CleanupRuleTestFixtures.ageTree(home)
        let before = try await CleanupRuleTestFixtures.scan(CleanupRuleTestFixtures.set(old), home: home)
        let after = try await CleanupRuleTestFixtures.scan(CleanupRuleTestFixtures.set(annotated), home: home)
        XCTAssertGreaterThan(before.candidates.count, 65)
        XCTAssertEqual(before.candidates.map(\.id), after.candidates.map(\.id))
        XCTAssertEqual(before.candidates.map(\.ruleID), after.candidates.map(\.ruleID))
        XCTAssertEqual(before.candidates.map { $0.risk.rawValue }, after.candidates.map { $0.risk.rawValue })
        XCTAssertEqual(before.candidates.map { $0.selectionEligibility.rawValue }, after.candidates.map { $0.selectionEligibility.rawValue })
        XCTAssertEqual(CleanupSelection.defaults(in: before).selectedCandidateIDs,
                       CleanupSelection.defaults(in: after).selectedCandidateIDs)
    }

    /// Repair 1 (P2-2): the scanner lets the first rule claim a shared
    /// identity, so the top-level order is part of the effective rules.
    /// Collections inside a rule stay order-insensitive.
    func testFingerprintKeepsRuleOrderButNormalizesCollectionsAndIgnoresDescriptiveVersion() throws {
        let original = try CleanupRuleSetLoader.loadBundled()
        let relabeled = CleanupRuleSet(schemaVersion: original.schemaVersion, rulesVersion: "another-label",
            rules: original.rules)
        XCTAssertEqual(original.effectiveProvenance, relabeled.effectiveProvenance)
        let reordered = CleanupRuleSet(schemaVersion: original.schemaVersion, rulesVersion: original.rulesVersion,
            rules: Array(original.rules.reversed()))
        XCTAssertNotEqual(original.effectiveProvenance.fingerprint, reordered.effectiveProvenance.fingerprint)
        var swapped = original.rules
        swapped.swapAt(0, 1)
        XCTAssertNotEqual(original.effectiveProvenance.fingerprint,
            CleanupRuleSet(schemaVersion: original.schemaVersion, rulesVersion: original.rulesVersion,
                rules: swapped).effectiveProvenance.fingerprint)
        let rule = try XCTUnwrap(original.rules.first { $0.requiredClosedBundleIDs.count == 1 })
        let a = try CleanupRuleTestFixtures.replacing(rule, fields: [
            "requiredClosedBundleIDs": ["com.fixture.One", "com.fixture.Two"],
            "include": ["entryKinds": ["directory", "regularFile"], "extensions": ["tmp", "log"],
                        "nameMatcher": ["mode": "exact", "values": ["Cache", "GPUCache"]]],
        ])
        let b = try CleanupRuleTestFixtures.replacing(a, fields: [
            "requiredClosedBundleIDs": ["com.fixture.Two", "com.fixture.One"],
            "include": ["entryKinds": ["regularFile", "directory"], "extensions": ["log", "tmp"],
                        "nameMatcher": ["mode": "exact", "values": ["GPUCache", "Cache"]]],
        ])
        XCTAssertEqual(CleanupRuleTestFixtures.set([a]).effectiveProvenance,
                       CleanupRuleTestFixtures.set([b]).effectiveProvenance)
    }

    func testFingerprintChangesForEverySubstantiveRuleField() throws {
        let rule = try XCTUnwrap(try CleanupRuleSetLoader.loadBundled().rules.first { $0.id == "developer.npx-cache" })
        let fingerprint = CleanupRuleTestFixtures.set([rule]).effectiveProvenance.fingerprint
        let changes: [String: Any] = [
            "id": "changed", "selectionPolicyVersion": 99, "categoryID": "changed",
            "categoryTitleKey": "changed", "titleKey": "changed",
            "root": ["kind": "homeRelative", "path": ".changed"], "candidateScope": "root",
            "maximumDepth": 1, "minimumAgeDays": 1, "minimumBytes": 1,
            "maximumCandidates": 400,
            "include": ["entryKinds": ["directory"], "extensions": ["tmp"],
                        "nameMatcher": ["mode": "exact", "values": ["other"]]],
            "exclude": ["relativePrefixes": ["personal"], "extensions": ["doc"], "namePrefixes": ["keep"]],
            "cloudPolicy": "metadataOnly", "risk": "reviewOnly", "recommendation": "optional",
            "defaultSelection": "unselected", "executionEligibility": "eligibleAfterReview",
            "measurementRequirement": "bestEffort", "allowsManualSelection": false,
            "action": "moveToTrashAfterReview", "requiredClosedBundleIDs": ["com.fixture.App"],
            "reasonKey": "changed", "ownerDisplayName": "工具", "developerTool": "openCode",
            "developerArtifactKind": "logs", "includedBundleIdentifiers": ["com.fixture.App"],
            "requiresDuplicateBundleIdentifier": true, "ownerInference": "candidateName",
        ]
        for (field, value) in changes {
            let changed = try CleanupRuleTestFixtures.replacing(rule, fields: [field: value])
            XCTAssertNotEqual(fingerprint, CleanupRuleTestFixtures.set([changed]).effectiveProvenance.fingerprint, field)
        }
        for field in ["source", "revision", "checkedAt", "impact", "applicability", "evidenceURLs"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule.maintenance)) as? [String: Any])
            switch field {
            case "source": object[field] = "coverage-catalog"
            case "revision": object[field] = 2
            case "checkedAt": object[field] = "2026-10-11"
            case "impact": object[field] = "缓存将重建"
            case "applicability": object[field] = [["field": "applicationBundleIdentifier", "value": "com.fixture.App"]]
            default: object[field] = ["https://example.com/evidence"]
            }
            let changed = try CleanupRuleTestFixtures.replacing(rule, fields: ["maintenance": object])
            XCTAssertNotEqual(fingerprint, CleanupRuleTestFixtures.set([changed]).effectiveProvenance.fingerprint, field)
        }
    }

    func testMaintenanceFailuresAreDetectedAndChangedContentRequiresRevisionBump() throws {
        let rules = try CleanupRuleSetLoader.loadBundled()
        let baseline = try CleanupRuleTestFixtures.baseline()
        var rule = try XCTUnwrap(rules.rules.first)
        let id = rule.id
        XCTAssertThrowsError(try CleanupRuleMaintenanceValidator.validate(CleanupRuleTestFixtures.set([rule, rule])))
        rule.maintenance = nil
        XCTAssertThrowsError(try CleanupRuleMaintenanceValidator.validate(CleanupRuleTestFixtures.set([rule]))) {
            XCTAssertEqual($0 as? CleanupRuleMaintenanceError, .missingMetadata(id))
        }
        rule = try XCTUnwrap(rules.rules.first)
        rule.maintenance?.impact = " "
        XCTAssertThrowsError(try CleanupRuleMaintenanceValidator.validate(CleanupRuleTestFixtures.set([rule])))
        rule = try XCTUnwrap(rules.rules.first)
        rule.maintenance?.applicability = [.init(field: "nonexistentField", value: "value")]
        XCTAssertThrowsError(try CleanupRuleMaintenanceValidator.validate(CleanupRuleTestFixtures.set([rule]))) {
            XCTAssertEqual($0 as? CleanupRuleMaintenanceError, .unknownApplicabilityField(id, "nonexistentField"))
        }
        rule = try XCTUnwrap(rules.rules.first)
        rule.maintenance?.checkedAt = "2026-02-30"
        XCTAssertThrowsError(try CleanupRuleMaintenanceValidator.validate(CleanupRuleTestFixtures.set([rule])))
        rule = try XCTUnwrap(rules.rules.first)
        rule.maintenance?.applicability = [.init(field: "minimumApplicationVersion", value: "1.2")]
        XCTAssertThrowsError(try CleanupRuleMaintenanceValidator.validate(CleanupRuleTestFixtures.set([rule])))
        rule = try XCTUnwrap(rules.rules.first)
        rule.maintenance?.impact = "工具缓存会重新生成"
        XCTAssertThrowsError(try CleanupRuleMaintenanceValidator.validate(CleanupRuleTestFixtures.set([rule]), baseline: baseline)) {
            XCTAssertEqual($0 as? CleanupRuleMaintenanceError, .revisionNotIncremented(id))
        }
        rule.maintenance?.revision += 1
        XCTAssertNoThrow(try CleanupRuleMaintenanceValidator.validate(CleanupRuleTestFixtures.set([rule]), baseline: baseline))
    }

    /// Repair 1 (P2-3): applicability conditions are format-checked only; the
    /// baseline paths for a lowered revision and a malformed snapshot fail.
    func testRevisionRegressionAndInvalidBaselineAreRejected() throws {
        let rules = try CleanupRuleSetLoader.loadBundled()
        let baseline = try CleanupRuleTestFixtures.baseline()
        var logs = try XCTUnwrap(rules.rules.first { $0.id == "developer.vscode-logs" })
        XCTAssertEqual(baseline.entries.first { $0.ruleID == logs.id }?.revision, 2)
        XCTAssertNoThrow(try CleanupRuleMaintenanceValidator.validate(CleanupRuleTestFixtures.set([logs]), baseline: baseline))
        logs.maintenance?.revision = 1
        XCTAssertThrowsError(try CleanupRuleMaintenanceValidator.validate(CleanupRuleTestFixtures.set([logs]), baseline: baseline)) {
            XCTAssertEqual($0 as? CleanupRuleMaintenanceError, .revisionRegressed(logs.id))
        }

        let rule = try XCTUnwrap(rules.rules.first)
        let entry = try XCTUnwrap(baseline.entries.first { $0.ruleID == rule.id })
        let malformed: [CleanupRuleBaseline] = [
            CleanupRuleBaseline(schemaVersion: 2, entries: [entry], legacyRules: []),
            CleanupRuleBaseline(schemaVersion: 1, entries: [entry, entry], legacyRules: []),
            CleanupRuleBaseline(schemaVersion: 1, entries: [.init(ruleID: entry.ruleID, revision: 0,
                contentHash: entry.contentHash)], legacyRules: []),
            CleanupRuleBaseline(schemaVersion: 1, entries: [.init(ruleID: entry.ruleID, revision: entry.revision,
                contentHash: String(entry.contentHash.prefix(63)))], legacyRules: []),
        ]
        for (index, value) in malformed.enumerated() {
            XCTAssertThrowsError(try CleanupRuleMaintenanceValidator.validate(CleanupRuleTestFixtures.set([rule]), baseline: value),
                "case \(index)") {
                XCTAssertEqual($0 as? CleanupRuleMaintenanceError, .invalidBaseline, "case \(index)")
            }
        }
        XCTAssertNoThrow(try CleanupRuleMaintenanceValidator.validate(CleanupRuleTestFixtures.set([rule]),
            baseline: CleanupRuleBaseline(schemaVersion: 1, entries: [entry], legacyRules: [])))
    }

    /// Repair 1 (P2-4): rows from a rule scan must carry the fingerprint and
    /// rule revision; only a session without rows may lack a fingerprint.
    func testPlanRequiresFingerprintOnRuleScanRowsAndAllowsOnlyEmptySessionsWithout() async throws {
        let full = try CleanupRuleSetLoader.loadBundled()
        let rule = try XCTUnwrap(full.rules.first { $0.id == "developer.claude-desktop-web-cache" })
        let scoped = CleanupScanOperations.scopedRuleSet(full, includedCategoryIDs: nil, includedRuleIDs: [rule.id])
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        try CleanupRuleTestFixtures.write(home.appendingPathComponent(rule.root.path).appendingPathComponent("Cache/generated.bin"))
        try CleanupRuleTestFixtures.ageTree(home)
        let session = try await CleanupRuleTestFixtures.scan(scoped, home: home)
        let selection = CleanupSelection.defaults(in: session)
        XCTAssertFalse(selection.selectedCandidateIDs.isEmpty, "Scan issues: \(session.issues)")
        XCTAssertNoThrow(try CleanPlanBuilder.makePlan(session: session, selection: selection,
            activeRules: full, disposition: .trash))

        let withoutRevision = session.mappingCandidates { row in
            var copy = row; copy.ruleRevision = nil; return copy
        }
        XCTAssertNotNil(withoutRevision.rulesProvenance)
        XCTAssertThrowsError(try CleanPlanBuilder.makePlan(session: withoutRevision, selection: selection,
            activeRules: full, disposition: .trash)) {
            XCTAssertEqual($0 as? CleanPlanBuildError, .invalidCandidate)
        }
        let strippedRows = session.mappingCandidates { row in
            var copy = row; copy.rulesProvenance = nil; return copy
        }
        let withoutFingerprint = ScanSession(id: session.id, rulesVersion: session.rulesVersion,
            startedAt: session.startedAt, completedAt: session.completedAt, outcome: session.outcome,
            categories: strippedRows.categories, issues: [], permissions: [], metrics: session.metrics)
        XCTAssertNil(withoutFingerprint.rulesProvenance)
        XCTAssertThrowsError(try CleanPlanBuilder.makePlan(session: withoutFingerprint, selection: selection,
            activeRules: full, disposition: .trash)) {
            XCTAssertEqual($0 as? CleanPlanBuildError, .rulesChanged)
        }
        let rowOnlyMissing = ScanSession(id: session.id, rulesVersion: session.rulesVersion,
            startedAt: session.startedAt, completedAt: session.completedAt, outcome: session.outcome,
            categories: strippedRows.categories, issues: [], permissions: [], metrics: session.metrics,
            rulesProvenance: full.effectiveProvenance)
        XCTAssertThrowsError(try CleanPlanBuilder.makePlan(session: rowOnlyMissing, selection: selection,
            activeRules: full, disposition: .trash)) {
            XCTAssertEqual($0 as? CleanPlanBuildError, .invalidCandidate)
        }

        // A health-only or empty Smart Scan has no rows and no fingerprint;
        // it reaches the ordinary empty-selection check, not rulesChanged.
        let empty = ScanSession(id: ScanSessionID(), rulesVersion: full.rulesVersion,
            startedAt: Date(), completedAt: Date(), outcome: .complete,
            categories: [], issues: [], permissions: [],
            metrics: ScanMetrics(visitedEntryCount: 0, candidateCount: 0,
                deduplicatedIdentityCount: 0, estimatedCandidateBytes: 0, duration: 0))
        XCTAssertNil(empty.rulesProvenance)
        XCTAssertThrowsError(try CleanPlanBuilder.makePlan(session: empty, selection: CleanupSelection(),
            activeRules: full, disposition: .trash)) {
            XCTAssertEqual($0 as? CleanPlanBuildError, .emptySelection)
        }
    }

    func testScopedFingerprintRetainsFullSetAndRejectsStaleScopeAnnotations() throws {
        let full = try CleanupRuleSetLoader.loadBundled()
        let scoped = CleanupScanOperations.scopedRuleSet(full, includedCategoryIDs: ["developer"])
        XCTAssertEqual(scoped.effectiveProvenance, full.effectiveProvenance)
        var changed = try XCTUnwrap(scoped.rules.first)
        changed.maintenance?.impact = "修改了处理影响"
        let tampered = CleanupRuleSet(schemaVersion: 2, rulesVersion: scoped.rulesVersion,
            rules: [changed], fullSetProvenance: scoped.fullSetProvenance)
        XCTAssertNotEqual(tampered.effectiveProvenance, full.effectiveProvenance)
    }

    func testEmptySmartScanWrapperPreservesScannerProvenance() throws {
        let rules = try CleanupRuleSetLoader.loadBundled()
        let session = ScanSession(id: ScanSessionID(), rulesVersion: rules.rulesVersion,
            startedAt: Date(), completedAt: Date(), outcome: .complete,
            categories: [], issues: [], permissions: [],
            metrics: ScanMetrics(visitedEntryCount: 0, candidateCount: 0,
                deduplicatedIdentityCount: 0, estimatedCandidateBytes: 0, duration: 0),
            rulesProvenance: rules.effectiveProvenance)
        XCTAssertEqual(session.withSmartScan(scopes: [.cleanupCandidates], health: nil).rulesProvenance,
                       rules.effectiveProvenance)
    }

    func testScanPlanFailureReceiptAndLegacyDecodePreserveProvenance() async throws {
        let full = try CleanupRuleSetLoader.loadBundled()
        let rule = try XCTUnwrap(full.rules.first { $0.id == "developer.claude-desktop-web-cache" })
        let scoped = CleanupScanOperations.scopedRuleSet(full, includedCategoryIDs: nil, includedRuleIDs: [rule.id])
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        let payload = home.appendingPathComponent(rule.root.path).appendingPathComponent("Cache/generated.bin")
        try CleanupRuleTestFixtures.write(payload)
        try CleanupRuleTestFixtures.ageTree(home)
        let session = try await CleanupRuleTestFixtures.scan(scoped, home: home)
        let candidate = try XCTUnwrap(session.candidates.first, "Scan issues: \(session.issues)")
        XCTAssertEqual(session.rulesProvenance, full.effectiveProvenance)
        XCTAssertEqual(candidate.ruleRevision, 1)
        XCTAssertEqual(candidate.applicationOwnershipText, "Claude")
        XCTAssertFalse(try XCTUnwrap(candidate.cleanupImpactText).isEmpty)
        XCTAssertTrue(candidate.preselectionExplanationText.contains("预选"))
        XCTAssertEqual(session.mappingCandidates { $0 }.rulesProvenance, session.rulesProvenance)
        let plan = try CleanPlanBuilder.makePlan(session: session, selection: CleanupSelection.defaults(in: session),
            activeRules: full, disposition: .trash)
        XCTAssertEqual(plan.rulesProvenance, session.rulesProvenance)
        XCTAssertEqual(plan.items.first?.ruleRevision, candidate.ruleRevision)
        var changed = rule
        changed.maintenance?.revision = 2
        let changedRules = CleanupRuleTestFixtures.set([changed], version: full.rulesVersion)
        XCTAssertThrowsError(try CleanPlanBuilder.makePlan(session: session, selection: CleanupSelection.defaults(in: session),
            activeRules: changedRules, disposition: .trash)) {
            XCTAssertEqual($0 as? CleanPlanBuildError, .rulesChanged)
        }
        let executor = SafeCleanupExecutor(coordinator: HeavyWorkCoordinator())
        let context = CleanupExecutionContext(featureConfiguration: .productDefault, activeSessionID: session.id,
            activeRules: changedRules, userHomeURL: home, excludedURLs: [], approvedPlanItemIDs: nil)
        let preflight = await executor.preflight(plan: plan, context: context)
        XCTAssertEqual(preflight.failure?.code, .planIntegrityFailed)
        let report = await executor.execute(plan: plan, context: context) { _ in }
        XCTAssertEqual(report.outcome, .failed)
        // D214＋旧值：was `XCTAssertEqual(report.summary.failedItemCount, plan.items.count)`
        // and the first item `.failed` with `.planIntegrityFailed`. The plan is still
        // refused before processing; its items are not run and the report keeps why.
        XCTAssertEqual(report.summary.failedItemCount, 0)
        XCTAssertEqual(report.summary.notProcessedItemCount, plan.items.count)
        XCTAssertEqual(report.items.first?.outcome, .notProcessed)
        XCTAssertEqual(report.startRefusal?.code, .planIntegrityFailed,
                       "Changed effective rules must refuse the plan before processing it")
        XCTAssertEqual(report.rulesProvenance, plan.rulesProvenance)
        XCTAssertEqual(report.items.first?.ruleRevision, candidate.ruleRevision)
        let encoded = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(CleanReport.self, from: encoded), report)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "rulesProvenance")
        object["items"] = try XCTUnwrap(object["items"] as? [[String: Any]]).map { row in
            var old = row; old.removeValue(forKey: "ruleRevision"); return old
        }
        let old = try JSONDecoder().decode(CleanReport.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.rulesProvenance)
        XCTAssertTrue(old.items.allSatisfy { $0.ruleRevision == nil })
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
    }

    func testJournalEventsPreserveAndRefuseChangesToProvenance() throws {
        let root = try TestFileSystem.makeOperationHome(for: self, purpose: "rules-provenance")
        let rules = try CleanupRuleSetLoader.loadBundled()
        let id = CleanPlanID()
        let item = CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: rules.rules[0].id,
            sourcePath: root.appendingPathComponent("payload").path, estimatedBytes: 1,
            outcome: .notProcessed, ruleRevision: rules.rules[0].maintenance?.revision)
        var report = CleanReport(id: id.rawValue, planID: id, sessionID: ScanSessionID(), rulesVersion: rules.rulesVersion,
            disposition: .trash, scanWasPartial: false, startedAt: Date(), completedAt: Date(), outcome: .failed,
            items: [item], summary: CleanReportSummary(requestedItemCount: 1, movedItemCount: 0, skippedItemCount: 0,
                failedItemCount: 0, notProcessedItemCount: 1, unverifiedMoveCount: 0, plannedBytes: 1,
                movedToRecoverableLocationBytes: 0, reclaimableAfterEmptyingTrashBytes: 0,
                permanentlyFreedBytes: 0, availableSpaceDeltaBytes: nil), rulesProvenance: rules.effectiveProvenance)
        let journal = CleanupReportJournal(directory: root.appendingPathComponent("journal"))
        try journal.checkpoint(report, expectedIdentities: [:])
        report.persistenceFailure = "fixture"
        try journal.checkpoint(report, expectedIdentities: [:])
        let baseURL = journal.reportURL(for: id)
        // A fresh replay instance must reconstruct disk events, not use the
        // journal's in-memory cache of the report passed to checkpoint.
        let loaded = try CleanupJournalEvents().load(baseURL: baseURL, readBase: {
            try JSONDecoder().decode(CleanupReportJournal.Entry.self, from: Data(contentsOf: baseURL))
        })
        // The delta must actually replay (a refused delta falls back to the base
        // entry, which would hide a provenance lost in the event header).
        XCTAssertFalse(loaded.damagedSuffix)
        let replayed = loaded.entry.report
        XCTAssertEqual(replayed.persistenceFailure, "fixture")
        XCTAssertEqual(replayed.rulesProvenance, report.rulesProvenance)
        XCTAssertEqual(replayed.items[0].ruleRevision, item.ruleRevision)
        var changedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        var changedRows = try XCTUnwrap(changedObject["items"] as? [[String: Any]])
        changedRows[0]["ruleRevision"] = 2
        changedObject["items"] = changedRows
        let changedItemRevision = try JSONDecoder().decode(CleanReport.self,
            from: JSONSerialization.data(withJSONObject: changedObject))
        XCTAssertThrowsError(try journal.checkpoint(changedItemRevision, expectedIdentities: [:]))
        report.rulesProvenance = nil
        XCTAssertThrowsError(try journal.checkpoint(report, expectedIdentities: [:]))
    }
}
