import Foundation
import XCTest
@testable import StorageCleanerMac

final class CleanupExecutionSafetyTests: XCTestCase {
    func testProductDefaultAlwaysUsesV2Full() {
        XCTAssertEqual(CleanupFeatureConfiguration.productDefault.mode, .v2Full)
        XCTAssertEqual(
            CleanupFeatureConfiguration.productDefault.diagnosticValue,
            "cleanup-architecture=v2Full"
        )
    }

    func testCleanupByteAccountingSaturatesInsteadOfOverflowing() {
        XCTAssertEqual(CleanupByteCount.sum([Int64.max, 1]), Int64.max)
        XCTAssertEqual(CleanupByteCount.sum([-1, 5]), 5)
    }

    func testProtectedApplicationPlanRequiresExplicitSelectionAndApprovedScope() async throws {
        let sessionID = ScanSessionID()
        let source = URL(fileURLWithPath: "/Applications/Example Beta.app")
        let retainedSource = URL(fileURLWithPath: "/Applications/Example.app")
        let root = URL(fileURLWithPath: "/Applications")
        let snapshot = FileSnapshot(
            identity: FileIdentity(
                deviceID: 1,
                inode: 2,
                entryKind: .directory,
                creationTimeNanoseconds: 3
            ),
            standardizedPath: source.path,
            volumeIdentifier: "applications-volume",
            logicalSizeBytes: 8_500,
            allocatedSizeBytes: 3_500,
            modificationTimeNanoseconds: 4,
            isWritableVolume: true,
            isCloudItem: false,
            isCloudPlaceholder: false,
            hasSymbolicLinkComponent: false
        )
        let rule = CleanupRule(
            id: "applications.duplicate-installed-apps",
            selectionPolicyVersion: 2,
            categoryID: "applications",
            categoryTitleKey: "cleanup.category.applications",
            titleKey: "cleanup.rule.duplicateInstalledApps.title",
            root: CleanupRuleRoot(kind: .applicationsDirectory, path: "/Applications"),
            maximumDepth: 0,
            minimumAgeDays: 0,
            minimumBytes: 1,
            include: CleanupRuleMatch(
                entryKinds: [.directory],
                extensions: ["app"],
                nameMatcher: CleanupNameMatcher(mode: .any, values: [])
            ),
            exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
            cloudPolicy: .metadataOnly,
            risk: .protected,
            recommendation: .notRecommended,
            defaultSelection: .unselected,
            executionEligibility: .eligibleAfterProtectedReview,
            measurementRequirement: .complete,
            allowsManualSelection: true,
            action: .moveToTrashAfterProtectedReview,
            requiredClosedBundleIDs: [],
            reasonKey: "cleanup.rule.duplicateInstalledApps.reason"
        )
        let rules = CleanupRuleSet(schemaVersion: 2, rulesVersion: "protected-v1", rules: [rule])
        let candidate = ScanCandidate(
            id: ScanCandidateID(),
            sessionID: sessionID,
            ruleID: rule.id,
            ruleSelectionPolicyVersion: rule.selectionPolicyVersion,
            categoryID: rule.categoryID,
            categoryTitle: "Applications",
            subcategoryTitle: "Duplicate Applications",
            sourceURL: source,
            allowedRootURL: root,
            snapshot: snapshot,
            risk: .protected,
            recommendation: CleanupRecommendation(
                level: .notRecommended,
                reasonCode: rule.reasonKey,
                evidenceCodes: [
                    "duplicate-bundle-identifier",
                    "duplicate-bundle-group:fixture-group",
                ]
            ),
            defaultSelection: .unselected,
            executionEligibility: .eligibleAfterProtectedReview,
            measurementCompleteness: .complete,
            isManuallySelectable: true,
            action: .moveToTrashAfterProtectedReview,
            requiredClosedBundleIDs: [],
            reason: "Fixture"
        )
        let retainedSnapshot = FileSnapshot(
            identity: FileIdentity(
                deviceID: 1,
                inode: 5,
                entryKind: .directory,
                creationTimeNanoseconds: 6
            ),
            standardizedPath: retainedSource.path,
            volumeIdentifier: "applications-volume",
            logicalSizeBytes: 1_024,
            allocatedSizeBytes: 1_024,
            modificationTimeNanoseconds: 7,
            isWritableVolume: true,
            isCloudItem: false,
            isCloudPlaceholder: false,
            hasSymbolicLinkComponent: false
        )
        let retainedMetadataSnapshot = FileSnapshot(
            identity: retainedSnapshot.identity,
            standardizedPath: retainedSnapshot.standardizedPath,
            volumeIdentifier: retainedSnapshot.volumeIdentifier,
            logicalSizeBytes: 0,
            allocatedSizeBytes: 0,
            modificationTimeNanoseconds: retainedSnapshot.modificationTimeNanoseconds,
            isWritableVolume: retainedSnapshot.isWritableVolume,
            isCloudItem: retainedSnapshot.isCloudItem,
            isCloudPlaceholder: retainedSnapshot.isCloudPlaceholder,
            hasSymbolicLinkComponent: retainedSnapshot.hasSymbolicLinkComponent
        )
        let retainedCandidate = ScanCandidate(
            id: ScanCandidateID(),
            sessionID: sessionID,
            ruleID: rule.id,
            ruleSelectionPolicyVersion: rule.selectionPolicyVersion,
            categoryID: rule.categoryID,
            categoryTitle: "Applications",
            subcategoryTitle: "Duplicate Applications",
            sourceURL: retainedSource,
            allowedRootURL: root,
            snapshot: retainedSnapshot,
            risk: .protected,
            recommendation: CleanupRecommendation(
                level: .notRecommended,
                reasonCode: rule.reasonKey,
                evidenceCodes: [
                    "duplicate-bundle-identifier",
                    "duplicate-bundle-group:fixture-group",
                ]
            ),
            defaultSelection: .unselected,
            executionEligibility: .eligibleAfterProtectedReview,
            measurementCompleteness: .complete,
            isManuallySelectable: true,
            action: .moveToTrashAfterProtectedReview,
            requiredClosedBundleIDs: [],
            reason: "Fixture"
        )
        let session = ScanSession(
            id: sessionID,
            rulesVersion: rules.rulesVersion,
            startedAt: Date(),
            completedAt: Date(),
            outcome: .complete,
            categories: [CleanupScanCategory(
                id: "applications",
                title: "Applications",
                subcategories: [CleanupScanSubcategory(
                    id: rule.id,
                    title: "Duplicate Applications",
                    risk: .protected,
                    recommendation: .notRecommended,
                    reason: "Fixture",
                    candidates: [candidate, retainedCandidate]
                )]
            )],
            issues: [],
            permissions: [],
            metrics: ScanMetrics(
                visitedEntryCount: 2,
                candidateCount: 2,
                deduplicatedIdentityCount: 0,
                estimatedCandidateBytes: 1_024,
                duration: 0
            )
        )

        XCTAssertEqual(candidate.selectionEligibility, .selectableWithProtectedReview)
        XCTAssertEqual(candidate.defaultSelection, .unselected)
        XCTAssertTrue(CleanupSelection.defaults(in: session).selectedCandidateIDs.isEmpty)
        XCTAssertThrowsError(try CleanPlanBuilder.makePlan(
            session: session,
            selection: CleanupSelection(selectedCandidateIDs: [candidate.id]),
            activeRules: rules,
            disposition: .trash
        ))

        var selection = CleanupSelection()
        selection.setCandidate(candidate.id, selected: true, in: session)
        let plan = try CleanPlanBuilder.makePlan(
            session: session,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )
        XCTAssertEqual(plan.protectedItems.map(\.sourceURL), [source])
        XCTAssertEqual(plan.protectedItems.map(\.estimatedSizeBytes), [3_500])
        XCTAssertEqual(plan.protectedItemBytes, 3_500)
        XCTAssertEqual(plan.estimatedMovableBytes, 3_500)

        let report = await SafeCleanupExecutor(
            metadataReader: FixtureMetadataReader(states: [
                source.path: .snapshot(snapshot),
                retainedSource.path: .snapshot(retainedMetadataSnapshot),
            ]),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            coordinator: HeavyWorkCoordinator()
        ).preflight(
            plan: plan,
            context: CleanupExecutionContext(
                featureConfiguration: .productDefault,
                activeSessionID: session.id,
                activeRules: rules,
                userHomeURL: URL(fileURLWithPath: "/Users/example"),
                excludedURLs: [],
                approvedPlanItemIDs: nil
            )
        )
        XCTAssertEqual(report.items.map(\.status), [.ready])

        let changedRetainedSnapshot = FileSnapshot(
            identity: retainedMetadataSnapshot.identity,
            standardizedPath: retainedMetadataSnapshot.standardizedPath,
            volumeIdentifier: retainedMetadataSnapshot.volumeIdentifier,
            logicalSizeBytes: 0,
            allocatedSizeBytes: 0,
            modificationTimeNanoseconds: 8,
            isWritableVolume: retainedMetadataSnapshot.isWritableVolume,
            isCloudItem: retainedMetadataSnapshot.isCloudItem,
            isCloudPlaceholder: retainedMetadataSnapshot.isCloudPlaceholder,
            hasSymbolicLinkComponent: retainedMetadataSnapshot.hasSymbolicLinkComponent
        )
        let changedRetainedReport = await SafeCleanupExecutor(
            metadataReader: FixtureMetadataReader(states: [
                source.path: .snapshot(snapshot),
                retainedSource.path: .snapshot(changedRetainedSnapshot),
            ]),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            coordinator: HeavyWorkCoordinator()
        ).preflight(
            plan: plan,
            context: CleanupExecutionContext(
                featureConfiguration: .productDefault,
                activeSessionID: session.id,
                activeRules: rules,
                userHomeURL: URL(fileURLWithPath: "/Users/example"),
                excludedURLs: [],
                approvedPlanItemIDs: nil
            )
        )
        XCTAssertEqual(
            changedRetainedReport.items.map(\.status),
            [.skipped(.duplicateRetainedCopyChanged)]
        )

        // D25: checking the whole group keeps one copy instead of failing the
        // plan. The most recently modified copy (`Example.app`) is kept.
        var allCopies = CleanupSelection()
        allCopies.setCandidates(
            [candidate.id, retainedCandidate.id],
            selected: true,
            in: session
        )
        XCTAssertEqual(allCopies.selectedCandidateIDs, [candidate.id])
        let groupIDs = [candidate.id, retainedCandidate.id]
        XCTAssertEqual(allCopies.groupState(for: groupIDs, in: session), .checked)
        var cleared = allCopies
        cleared.setCandidates(groupIDs, selected: false, in: session)
        XCTAssertEqual(cleared.groupState(for: groupIDs, in: session), .unchecked)
        let groupPlan = try CleanPlanBuilder.makePlan(
            session: session,
            selection: allCopies,
            activeRules: rules,
            disposition: .trash
        )
        XCTAssertEqual(groupPlan.protectedItems.map(\.sourceURL), [source])
        XCTAssertEqual(
            groupPlan.protectedItems.first?.protectedRetainedCopies.map(\.url),
            [retainedSource]
        )
        // Checking the last unchecked copy on its own keeps it unchecked.
        allCopies.setCandidate(retainedCandidate.id, selected: true, in: session)
        XCTAssertEqual(allCopies.selectedCandidateIDs, [candidate.id])
        // A selection built with every copy is reduced the same way by the plan.
        let forgedAllCopies = CleanupSelection(
            selectedCandidateIDs: [candidate.id, retainedCandidate.id],
            explicitlySelectedCandidateIDs: [candidate.id, retainedCandidate.id]
        )
        let forgedPlan = try CleanPlanBuilder.makePlan(
            session: session,
            selection: forgedAllCopies,
            activeRules: rules,
            disposition: .trash
        )
        XCTAssertEqual(forgedPlan.protectedItems.map(\.sourceURL), [source])
        XCTAssertEqual(
            forgedPlan.protectedItems.first?.protectedRetainedCopies.map(\.url),
            [retainedSource]
        )

        XCTAssertThrowsError(try CleanPlanBuilder.makePlan(
            session: session,
            selection: selection,
            activeRules: rules,
            disposition: .quarantine
        )) {
            XCTAssertEqual($0 as? CleanPlanBuildError, .invalidCandidate)
        }
    }

    /// D25: app bundles are not listed in the junk scan any more, so a rule
    /// that would remove a whole (non-duplicate) app is rejected.
    func testAllowlistedProtectedApplicationDoesNotRequireDuplicateCopy() throws {
        let source = URL(fileURLWithPath: "/Applications/Final Cut Pro.app")
        let root = URL(fileURLWithPath: "/Applications")
        let rule = CleanupRule(
            id: "applications.large-creative-apps",
            selectionPolicyVersion: 1,
            categoryID: "applications",
            categoryTitleKey: "cleanup.category.applications",
            titleKey: "cleanup.rule.largeCreativeApps.title",
            root: CleanupRuleRoot(kind: .applicationsDirectory, path: root.path),
            maximumDepth: 0,
            minimumAgeDays: 0,
            minimumBytes: 1,
            include: CleanupRuleMatch(
                entryKinds: [.directory],
                extensions: ["app"],
                nameMatcher: CleanupNameMatcher(mode: .any, values: [])
            ),
            exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
            cloudPolicy: .metadataOnly,
            risk: .protected,
            recommendation: .notRecommended,
            defaultSelection: .unselected,
            executionEligibility: .eligibleAfterProtectedReview,
            measurementRequirement: .complete,
            allowsManualSelection: true,
            action: .moveToTrashAfterProtectedReview,
            requiredClosedBundleIDs: [],
            reasonKey: "cleanup.rule.largeCreativeApps.reason",
            includedBundleIdentifiers: ["com.apple.FinalCutApp"]
        )
        let rules = CleanupRuleSet(schemaVersion: 2, rulesVersion: "allowlist-v1", rules: [rule])
        let sessionID = ScanSessionID()
        let snapshot = FileSnapshot(
            identity: FileIdentity(
                deviceID: 1,
                inode: 2,
                entryKind: .directory,
                creationTimeNanoseconds: 3
            ),
            standardizedPath: source.path,
            volumeIdentifier: "applications-volume",
            logicalSizeBytes: 8_500,
            allocatedSizeBytes: 3_500,
            modificationTimeNanoseconds: 4,
            isWritableVolume: true,
            isCloudItem: false,
            isCloudPlaceholder: false,
            hasSymbolicLinkComponent: false
        )
        let candidate = ScanCandidate(
            id: ScanCandidateID(),
            sessionID: sessionID,
            ruleID: rule.id,
            ruleSelectionPolicyVersion: rule.selectionPolicyVersion,
            categoryID: rule.categoryID,
            categoryTitle: "Applications",
            subcategoryTitle: "Large creative applications",
            sourceURL: source,
            allowedRootURL: root,
            snapshot: snapshot,
            risk: .protected,
            recommendation: CleanupRecommendation(
                level: .notRecommended,
                reasonCode: rule.reasonKey,
                evidenceCodes: [
                    "approved-application-bundle-identifier",
                    "application-bundle-identifier:com.apple.FinalCutApp",
                ]
            ),
            defaultSelection: .unselected,
            executionEligibility: .eligibleAfterProtectedReview,
            measurementCompleteness: .complete,
            isManuallySelectable: true,
            action: .moveToTrashAfterProtectedReview,
            requiredClosedBundleIDs: [],
            reason: "Fixture"
        )
        let session = ScanSession(
            id: sessionID,
            rulesVersion: rules.rulesVersion,
            startedAt: Date(),
            completedAt: Date(),
            outcome: .complete,
            categories: [CleanupScanCategory(
                id: "applications",
                title: "Applications",
                subcategories: [CleanupScanSubcategory(
                    id: rule.id,
                    title: "Large creative applications",
                    risk: .protected,
                    recommendation: .notRecommended,
                    reason: "Fixture",
                    candidates: [candidate]
                )]
            )],
            issues: [],
            permissions: [],
            metrics: ScanMetrics(
                visitedEntryCount: 1,
                candidateCount: 1,
                deduplicatedIdentityCount: 0,
                estimatedCandidateBytes: candidate.estimatedSizeBytes,
                duration: 0
            )
        )
        var selection = CleanupSelection()
        selection.setCandidate(candidate.id, selected: true, in: session)

        XCTAssertThrowsError(try CleanupRuleValidator.validate(rules))
        XCTAssertThrowsError(try CleanPlanBuilder.makePlan(
            session: session,
            selection: selection,
            activeRules: rules,
            disposition: .trash
        )) {
            XCTAssertEqual($0 as? CleanPlanBuildError, .rulesChanged)
        }
    }

    func testPlanFreezesSelectionAndRejectsCancelledSession() throws {
        let fixture = makeFixture(count: 2)
        var selection = CleanupSelection()
        selection.setCandidate(fixture.candidates[0].id, selected: true, in: fixture.session)
        let plan = try CleanPlanBuilder.makePlan(
            session: fixture.session,
            selection: selection,
            activeRules: fixture.rules,
            disposition: .trash
        )

        selection.setCandidate(fixture.candidates[0].id, selected: false, in: fixture.session)
        selection.setCandidate(fixture.candidates[1].id, selected: true, in: fixture.session)
        XCTAssertEqual(plan.items.map(\.candidateID), [fixture.candidates[0].id])

        let cancelled = makeSession(
            candidates: fixture.candidates,
            rulesVersion: fixture.rules.rulesVersion,
            outcome: .cancelled
        )
        XCTAssertThrowsError(try CleanPlanBuilder.makePlan(
            session: cancelled,
            selection: selection,
            activeRules: fixture.rules,
            disposition: .trash
        )) {
            XCTAssertEqual($0 as? CleanPlanBuildError, .cancelledSession)
        }
    }

    func testPlanRejectsStaleRuleAndDuplicateIdentity() throws {
        let fixture = makeFixture(count: 2, duplicateIdentity: true)
        let selection = CleanupSelection(selectedCandidateIDs: Set(fixture.candidates.map(\.id)))
        XCTAssertThrowsError(try CleanPlanBuilder.makePlan(
            session: fixture.session,
            selection: selection,
            activeRules: fixture.rules,
            disposition: .trash
        )) {
            XCTAssertEqual($0 as? CleanPlanBuildError, .duplicateIdentity)
        }

        let changedRules = CleanupRuleSet(
            schemaVersion: 2,
            rulesVersion: "changed",
            rules: fixture.rules.rules
        )
        XCTAssertThrowsError(try CleanPlanBuilder.makePlan(
            session: fixture.session,
            selection: CleanupSelection(selectedCandidateIDs: [fixture.candidates[0].id]),
            activeRules: changedRules,
            disposition: .trash
        )) {
            XCTAssertEqual($0 as? CleanPlanBuildError, .rulesChanged)
        }
    }

    func testPreflightRejectsIdentitySymlinkPermissionAndRunningAppChanges() async throws {
        let fixture = makeFixture(count: 4, requiredClosedBundleIDs: ["com.example.running"])
        let plan = try makePlan(fixture)
        let snapshots: [String: FixtureMetadataState] = [
            fixture.candidates[0].sourceURL.path: .snapshot(changedIdentity(
                fixture.candidates[0].snapshot
            )),
            fixture.candidates[1].sourceURL.path: .snapshot(changedSymlink(
                fixture.candidates[1].snapshot
            )),
            fixture.candidates[2].sourceURL.path: .error(.permissionDenied),
            fixture.candidates[3].sourceURL.path: .snapshot(fixture.candidates[3].snapshot)
        ]
        let executor = SafeCleanupExecutor(
            metadataReader: FixtureMetadataReader(states: snapshots),
            mover: RecordingCleanupMover(),
            volumeChecker: FixedVolumeChecker(available: true),
            runningApplicationChecker: FixedRunningApplicationChecker(running: true),
            capacityReader: FixedCapacityReader(values: []),
            coordinator: HeavyWorkCoordinator()
        )

        let report = await executor.preflight(
            plan: plan,
            context: context(for: fixture)
        )
        XCTAssertEqual(report.readyCount, 0)
        XCTAssertEqual(report.items.map(\.status), [
            .skipped(.identityChanged),
            .skipped(.symbolicLinkDetected),
            .skipped(.permissionChanged),
            .skipped(.relatedAppStillRunning)
        ])
    }

    func testPreflightMapsDisconnectedVolumeAndReadOnlyVolume() async throws {
        let fixture = makeFixture(count: 2)
        let plan = try makePlan(fixture)
        let readOnly = changedWritable(fixture.candidates[1].snapshot, isWritable: false)
        let reader = FixtureMetadataReader(states: [
            fixture.candidates[0].sourceURL.path: .error(.vanished),
            fixture.candidates[1].sourceURL.path: .snapshot(readOnly)
        ])
        let executor = SafeCleanupExecutor(
            metadataReader: reader,
            mover: RecordingCleanupMover(),
            volumeChecker: FixedVolumeChecker(available: false),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            capacityReader: FixedCapacityReader(values: []),
            coordinator: HeavyWorkCoordinator()
        )

        let report = await executor.preflight(plan: plan, context: context(for: fixture))
        XCTAssertEqual(report.items.map(\.status), [
            .skipped(.volumeUnavailable),
            .skipped(.volumeReadOnly)
        ])

        let availableExecutor = SafeCleanupExecutor(
            metadataReader: reader,
            mover: RecordingCleanupMover(),
            volumeChecker: FixedVolumeChecker(available: true),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            capacityReader: FixedCapacityReader(values: []),
            coordinator: HeavyWorkCoordinator()
        )
        let availableReport = await availableExecutor.preflight(
            plan: plan,
            context: context(for: fixture)
        )
        XCTAssertEqual(availableReport.items.map(\.status), [
            .skipped(.itemMissing),
            .skipped(.volumeReadOnly)
        ])
    }

    func testExecutorReportsPartialFailureWithoutSendingUnplannedPath() async throws {
        let fixture = makeFixture(count: 3)
        let plan = try makePlan(fixture)
        var states = fixture.states
        let destinations = fixture.candidates.enumerated().map { index, candidate in
            URL(fileURLWithPath: candidate.sourceURL.path + ".trash-\(index)")
        }
        for (candidate, destination) in zip(fixture.candidates, destinations) {
            states[destination.path] = .snapshot(candidate.snapshot)
        }
        let mover = RecordingCleanupMover(
            outcomes: [
                fixture.candidates[0].sourceURL.path: .success(destinations[0]),
                fixture.candidates[1].sourceURL.path: .failure,
                fixture.candidates[2].sourceURL.path: .success(destinations[2])
            ]
        )
        let executor = SafeCleanupExecutor(
            metadataReader: FixtureMetadataReader(states: states),
            mover: mover,
            volumeChecker: FixedVolumeChecker(available: true),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            capacityReader: FixedCapacityReader(values: [1_000, 1_250]),
            coordinator: HeavyWorkCoordinator()
        )

        let report = await executor.execute(
            plan: plan,
            context: context(
                for: fixture,
                approvedPlanItemIDs: Set(plan.items.map(\.id))
            ),
            progress: { _ in }
        )
        XCTAssertEqual(report.outcome, .partiallyCompleted)
        XCTAssertEqual(report.summary.movedItemCount, 2)
        XCTAssertEqual(report.summary.failedItemCount, 1)
        XCTAssertEqual(report.summary.notProcessedItemCount, 0)
        XCTAssertEqual(report.summary.permanentlyFreedBytes, 0)
        XCTAssertEqual(report.summary.availableSpaceDeltaBytes, 250)
        let movedPaths = await mover.paths
        XCTAssertEqual(Set(movedPaths), Set(plan.items.map { $0.sourceURL.path }))
    }

    func testExecutionNeverMovesAnItemSkippedByConfirmedPreflight() async throws {
        let fixture = makeFixture(count: 2)
        let plan = try makePlan(fixture)
        let approvedItem = try XCTUnwrap(plan.items.first)
        let destination = URL(fileURLWithPath: approvedItem.sourceURL.path + ".trash")
        var states = fixture.states
        states[destination.path] = .snapshot(approvedItem.expectedSnapshot)
        let mover = RecordingCleanupMover(outcomes: [
            approvedItem.sourceURL.path: .success(destination)
        ])
        let executor = SafeCleanupExecutor(
            metadataReader: FixtureMetadataReader(states: states),
            mover: mover,
            volumeChecker: FixedVolumeChecker(available: true),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            capacityReader: FixedCapacityReader(values: []),
            coordinator: HeavyWorkCoordinator()
        )

        let report = await executor.execute(
            plan: plan,
            context: context(for: fixture, approvedPlanItemIDs: [approvedItem.id]),
            progress: { _ in }
        )

        XCTAssertEqual(report.summary.movedItemCount, 1)
        XCTAssertEqual(report.summary.skippedItemCount, 1)
        let movedPaths = await mover.paths
        XCTAssertEqual(movedPaths, [approvedItem.sourceURL.path])
        XCTAssertTrue(report.items.contains {
            $0.outcome == .skipped(.preflightNotApproved)
        })
    }

    func testPreflightStillInUseReasonsSurviveTheExistingConfirmationRoute() async throws {
        for reason in [CleanSkipReason.candidateBecameActive, .relatedAppStillRunning] {
            let base = makeFixture(count: 2,
                requiredClosedBundleIDs: reason == .relatedAppStillRunning ? ["fixture.running"] : [])
            var candidates = base.candidates
            if reason == .candidateBecameActive {
                candidates[0].ownerResolution = .unresolved
                candidates[0].latestContentModificationTimeNanoseconds = 999
            }
            let fixture = CleanupExecutionFixture(homeURL: base.homeURL, rules: base.rules,
                candidates: candidates, session: makeSession(id: base.session.id, candidates: candidates,
                    rulesVersion: base.rules.rulesVersion, outcome: .complete), states: base.states)
            let plan = try makePlan(fixture)
            let outcomes: [String: RecordingMoveOutcome] = Dictionary(uniqueKeysWithValues: plan.items.map {
                ($0.sourceURL.path, .success($0.sourceURL.appendingPathExtension("trash")))
            })
            let mover = RecordingCleanupMover(outcomes: outcomes)
            let executor = SafeCleanupExecutor(metadataReader: FixtureMetadataReader(states: fixture.states),
                mover: mover, volumeChecker: FixedVolumeChecker(available: true),
                runningApplicationChecker: FirstCheckRunningApplicationChecker(),
                capacityReader: FixedCapacityReader(values: []), coordinator: HeavyWorkCoordinator())
            let preflight = await executor.preflight(plan: plan, context: context(for: fixture))
            XCTAssertEqual(preflight.readyCount, 1)
            XCTAssertEqual(preflight.skippedCount, 1)
            let skipped = try XCTUnwrap(preflight.items.first { $0.status == .skipped(reason) })
            // Match ScanStore: only pass ready IDs, on the same executor. No
            // store edit or explicit test-only context wiring carries the reason.
            let approved = Set(preflight.items.compactMap { $0.status == .ready ? $0.planItemID : nil })
            let report = await executor.execute(plan: plan,
                context: context(for: fixture, approvedPlanItemIDs: approved), progress: { _ in })
            XCTAssertEqual(report.items.first { $0.planItemID == skipped.planItemID }?.outcome, .skipped(reason))
            XCTAssertEqual(report.summary.movedItemCount, 1)
            XCTAssertEqual(report.summary.skippedItemCount, 1)
            XCTAssertEqual(report.summary.failedItemCount, 0)
            XCTAssertEqual(CleanupReportIssueGroup.group(for: .skipped(reason)), .stillInUse)
            XCTAssertEqual(try JSONDecoder().decode(CleanReport.self, from: JSONEncoder().encode(report)), report)
            let paths = await mover.paths
            XCTAssertEqual(paths.count, 1)
            let skippedPlanItem = try XCTUnwrap(plan.items.first { $0.id == skipped.planItemID })
            XCTAssertFalse(paths.contains(skippedPlanItem.sourceURL.path))
        }
    }

    func testPreflightReasonCacheDoesNotCrossImmutablePlans() async throws {
        let scenario = try makePreflightReasonScenario()
        let preflight = await scenario.executor.preflight(plan: scenario.plan, context: context(for: scenario.fixture))
        XCTAssertEqual(preflight.skippedCount, 1)
        let otherPlan = try makePlan(scenario.fixture)
        XCTAssertNotEqual(otherPlan.id, scenario.plan.id)
        let report = await scenario.executor.execute(plan: otherPlan,
            context: context(for: scenario.fixture, approvedPlanItemIDs: [otherPlan.items[1].id]), progress: { _ in })
        XCTAssertEqual(report.items.first { $0.planItemID == otherPlan.items[0].id }?.outcome,
            .skipped(.preflightNotApproved))
        XCTAssertEqual(report.summary.movedItemCount, 1)
        let paths = await scenario.mover.paths
        XCTAssertEqual(paths, [otherPlan.items[1].sourceURL.path])

        // A wrong cache lookup can consume the original report without matching
        // otherPlan's fresh item UUIDs. Execute the original plan to expose it.
        let originalReport = await scenario.executor.execute(plan: scenario.plan,
            context: context(for: scenario.fixture, approvedPlanItemIDs: [scenario.plan.items[1].id]), progress: { _ in })
        XCTAssertEqual(originalReport.items.first { $0.planItemID == scenario.plan.items[0].id }?.outcome,
            .skipped(.relatedAppStillRunning))
        XCTAssertEqual(originalReport.summary.movedItemCount, 1)
        let finalPaths = await scenario.mover.paths
        XCTAssertEqual(finalPaths, [otherPlan.items[1].sourceURL.path, scenario.plan.items[1].sourceURL.path])
        XCTAssertEqual(Set(finalPaths), Set([scenario.plan.items[1].sourceURL.path]),
            "Across both executions only the explicitly approved source path may reach the mover")
    }

    func testRepeatedPreflightUsesOnlyLatestCompletedReasons() async throws {
        for excludesFirstItem in [false, true] {
            let scenario = try makePreflightReasonScenario()
            let original = await scenario.executor.preflight(plan: scenario.plan, context: context(for: scenario.fixture))
            XCTAssertEqual(original.items.first?.status, .skipped(.relatedAppStillRunning))
            let latest = await scenario.executor.preflight(plan: scenario.plan,
                context: context(for: scenario.fixture,
                    excludedURLs: excludesFirstItem ? [scenario.plan.items[0].sourceURL] : []))
            XCTAssertNil(latest.failure)
            XCTAssertEqual(latest.items.first?.status, excludesFirstItem ? .skipped(.excludedByUser) : .ready)
            let report = await scenario.executor.execute(plan: scenario.plan,
                context: context(for: scenario.fixture, approvedPlanItemIDs: [scenario.plan.items[1].id]), progress: { _ in })
            XCTAssertEqual(report.items.first { $0.planItemID == scenario.plan.items[0].id }?.outcome,
                .skipped(excludesFirstItem ? .excludedByUser : .preflightNotApproved))
            XCTAssertEqual(report.summary.movedItemCount, 1)
            let paths = await scenario.mover.paths
            XCTAssertEqual(paths, [scenario.plan.items[1].sourceURL.path])
        }
    }

    func testFailedPreflightClearsEarlierReasonsWithoutChangingApproval() async throws {
        for failureKind in 0..<3 {
            let scenario = try makePreflightReasonScenario()
            let original = await scenario.executor.preflight(plan: scenario.plan, context: context(for: scenario.fixture))
            XCTAssertEqual(original.items.first?.status, .skipped(.relatedAppStillRunning))
            let invalidContext = CleanupExecutionContext(
                featureConfiguration: CleanupFeatureConfiguration(mode: failureKind == 0 ? .v2ScanOnly : .v2Full),
                activeSessionID: failureKind == 1 ? ScanSessionID() : scenario.fixture.session.id,
                activeRules: failureKind == 2
                    ? CleanupRuleSet(schemaVersion: 2, rulesVersion: "changed-rules", rules: scenario.fixture.rules.rules)
                    : scenario.fixture.rules,
                userHomeURL: scenario.fixture.homeURL, excludedURLs: [], approvedPlanItemIDs: nil)
            let failed = await scenario.executor.preflight(plan: scenario.plan, context: invalidContext)
            XCTAssertEqual(failed.failure?.code, failureKind == 0 ? .featureDisabled : .planIntegrityFailed)
            XCTAssertTrue(failed.items.isEmpty)
            let report = await scenario.executor.execute(plan: scenario.plan,
                context: context(for: scenario.fixture, approvedPlanItemIDs: [scenario.plan.items[1].id]), progress: { _ in })
            XCTAssertEqual(report.items.first { $0.planItemID == scenario.plan.items[0].id }?.outcome,
                .skipped(.preflightNotApproved))
            XCTAssertEqual(report.summary.movedItemCount, 1)
            let paths = await scenario.mover.paths
            XCTAssertEqual(paths, [scenario.plan.items[1].sourceURL.path])
        }
    }

    func testCancelledPreflightClearsEarlierReasonsWithoutChangingApproval() async throws {
        let scenario = try makePreflightReasonScenario()
        let original = await scenario.executor.preflight(plan: scenario.plan, context: context(for: scenario.fixture))
        XCTAssertEqual(original.items.first?.status, .skipped(.relatedAppStillRunning))
        let preflightContext = context(for: scenario.fixture)
        let executor = scenario.executor
        let plan = scenario.plan
        let cancelledTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await executor.preflight(plan: plan, context: preflightContext)
        }
        let cancelled = await cancelledTask.value
        XCTAssertEqual(cancelled.failure?.detailCode, "cancelled")
        XCTAssertTrue(cancelled.items.isEmpty)
        XCTAssertFalse(Task.isCancelled, "Only the child preflight task is cancelled")
        let report = await executor.execute(plan: plan,
            context: context(for: scenario.fixture, approvedPlanItemIDs: [plan.items[1].id]), progress: { _ in })
        XCTAssertEqual(report.items.first { $0.planItemID == plan.items[0].id }?.outcome, .skipped(.preflightNotApproved))
        XCTAssertEqual(report.summary.movedItemCount, 1)
        let paths = await scenario.mover.paths
        XCTAssertEqual(paths, [plan.items[1].sourceURL.path])
    }

    func testCachedReasonsNeitherApproveMovesNorReplaceLiveRechecks() async throws {
        for stillRunning in [false, true] {
            let checker = ControllableRunningApplicationChecker(running: true)
            let scenario = try makePreflightReasonScenario(runningApplicationChecker: checker)
            let original = await scenario.executor.preflight(plan: scenario.plan, context: context(for: scenario.fixture))
            XCTAssertEqual(original.skippedCount, 2)
            await checker.setRunning(stillRunning)
            let report = await scenario.executor.execute(plan: scenario.plan,
                context: context(for: scenario.fixture, approvedPlanItemIDs: [scenario.plan.items[1].id]), progress: { _ in })
            // The unapproved item always stays untouched, even after the app exits.
            XCTAssertEqual(report.items.first { $0.planItemID == scenario.plan.items[0].id }?.outcome,
                .skipped(.relatedAppStillRunning))
            XCTAssertEqual(report.summary.movedItemCount, stillRunning ? 0 : 1)
            if stillRunning {
                XCTAssertEqual(report.items.first { $0.planItemID == scenario.plan.items[1].id }?.outcome,
                    .skipped(.relatedAppStillRunning))
            }
            let paths = await scenario.mover.paths
            XCTAssertEqual(paths, stillRunning ? [] : [scenario.plan.items[1].sourceURL.path])
        }
    }

    func testRejectedApprovalRetainsReasonsForTheNextValidExecution() async throws {
        let scenario = try makePreflightReasonScenario()
        let preflight = await scenario.executor.preflight(plan: scenario.plan, context: context(for: scenario.fixture))
        XCTAssertEqual(preflight.items.first?.status, .skipped(.relatedAppStillRunning))
        for approval in [Set<UUID>(), Set([UUID()])] {
            let rejected = await scenario.executor.execute(plan: scenario.plan,
                context: context(for: scenario.fixture, approvedPlanItemIDs: approval), progress: { _ in })
            XCTAssertEqual(rejected.outcome, .failed)
            let paths = await scenario.mover.paths
            XCTAssertTrue(paths.isEmpty)
        }
        let report = await scenario.executor.execute(plan: scenario.plan,
            context: context(for: scenario.fixture, approvedPlanItemIDs: [scenario.plan.items[1].id]), progress: { _ in })
        XCTAssertEqual(report.items.first { $0.planItemID == scenario.plan.items[0].id }?.outcome,
            .skipped(.relatedAppStillRunning))
        XCTAssertEqual(report.summary.movedItemCount, 1)
        let paths = await scenario.mover.paths
        XCTAssertEqual(paths, [scenario.plan.items[1].sourceURL.path])
    }

    private func makePreflightReasonScenario(
        runningApplicationChecker: any CleanupRunningApplicationChecking = FirstCheckRunningApplicationChecker()
    ) throws -> (fixture: CleanupExecutionFixture, plan: CleanPlan, mover: RecordingCleanupMover, executor: SafeCleanupExecutor) {
        let fixture = makeFixture(count: 2, requiredClosedBundleIDs: ["fixture.running"])
        let plan = try makePlan(fixture)
        var states = fixture.states
        var outcomes: [String: RecordingMoveOutcome] = [:]
        for item in plan.items {
            let destination = item.sourceURL.appendingPathExtension("trash")
            states[destination.path] = .snapshot(item.expectedSnapshot)
            outcomes[item.sourceURL.path] = .success(destination)
        }
        let mover = RecordingCleanupMover(outcomes: outcomes)
        let executor = SafeCleanupExecutor(metadataReader: FixtureMetadataReader(states: states), mover: mover,
            volumeChecker: FixedVolumeChecker(available: true), runningApplicationChecker: runningApplicationChecker,
            capacityReader: FixedCapacityReader(values: []), coordinator: HeavyWorkCoordinator())
        return (fixture, plan, mover, executor)
    }

    func testVerifiedDuplicatePlanRequiresOneFrozenRetainedCopy() throws {
        let fixture = makeVerifiedDuplicateFixture(groupCount: 1)
        let request = try XCTUnwrap(fixture.requests.first)

        let bundle = try VerifiedDuplicateCleanPlanBuilder.makePlan(
            requests: [request],
            disposition: .trash,
            userHomeURL: fixture.homeURL
        )

        XCTAssertEqual(bundle.plan.items.count, 1)
        XCTAssertEqual(bundle.plan.items.first?.verifiedDuplicateEvidence?.digest, fixture.digest)
        XCTAssertEqual(bundle.plan.items.first?.verifiedDuplicateEvidence?.retainedCopies.count, 1)
        XCTAssertEqual(bundle.activeRules.rules.first?.risk, .reviewOnly)
        XCTAssertEqual(bundle.activeRules.rules.first?.action, .revealOnly)

        let invalid = VerifiedDuplicatePlanRequest(
            sourceURL: request.sourceURL,
            allowedRootURL: request.allowedRootURL,
            expectedSnapshot: request.expectedSnapshot,
            groupID: request.groupID,
            digest: request.digest,
            retainedCopies: []
        )
        XCTAssertThrowsError(try VerifiedDuplicateCleanPlanBuilder.makePlan(
            requests: [invalid],
            disposition: .trash,
            userHomeURL: fixture.homeURL
        )) {
            XCTAssertEqual($0 as? VerifiedDuplicatePlanBuildError, .noRetainedCopy)
        }
    }

    func testN6CancelledBlockingHashKeepsOriginalAndReleasesCleanupLease() async throws {
        let fixture = makeVerifiedDuplicateFixture(groupCount: 1)
        let bundle = try VerifiedDuplicateCleanPlanBuilder.makePlan(
            requests: fixture.requests, disposition: .trash, userHomeURL: fixture.homeURL
        )
        let context = verifiedDuplicateContext(bundle, homeURL: fixture.homeURL,
            approvedPlanItemIDs: Set(bundle.plan.items.map(\.id)))
        let coordinator = HeavyWorkCoordinator()
        let mover = RecordingCleanupMover()
        let gate = ContentReadGate()
        defer { gate.release() }
        let executor = SafeCleanupExecutor(
            metadataReader: FixtureMetadataReader(states: fixture.states),
            contentDigestReader: N6BlockingDigestReader(gate: gate), mover: mover,
            volumeChecker: FixedVolumeChecker(available: true),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            capacityReader: FixedCapacityReader(values: []), coordinator: coordinator
        )
        let worker = Task { await executor.execute(plan: bundle.plan, context: context, progress: { _ in }) }
        await fulfillment(of: [gate.entered], timeout: 1)
        let start = ProcessInfo.processInfo.systemUptime
        worker.cancel()
        let report = await worker.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertEqual(report.outcome, .cancelled)
        let moved = await mover.paths
        XCTAssertTrue(moved.isEmpty)
        let owner = await coordinator.activeOwner
        XCTAssertNil(owner)
        XCTAssertFalse(gate.didReturn)
    }

    func testN6PreflightAndFinalWriteRecheckPreserveReadRefusalReasons() async throws {
        let cases: [(FileContentReadError, CleanSkipReason)] = [
            (.cloudOnly, .contentCloudOnly), (.downloading, .contentDownloading),
            (.timedOut, .contentReadTimedOut), (.busy, .contentReadUnavailable)
        ]
        for (error, reason) in cases {
            for retainedFails in [false, true] {
                let fixture = makeVerifiedDuplicateFixture(groupCount: 1)
                let bundle = try VerifiedDuplicateCleanPlanBuilder.makePlan(
                    requests: fixture.requests, disposition: .trash, userHomeURL: fixture.homeURL
                )
                let request = try XCTUnwrap(fixture.requests.first)
                let target = retainedFails ? try XCTUnwrap(request.retainedCopies.first).url : request.sourceURL
                for failOnCall in [1, 3] {
                    let digestReader = N6RefusingDigestReader(
                        failingPath: target.path, failOnCall: failOnCall, error: error, digest: fixture.digest
                    )
                    let mover = RecordingCleanupMover()
                    let executor = SafeCleanupExecutor(
                        metadataReader: FixtureMetadataReader(states: fixture.states), contentDigestReader: digestReader,
                        mover: mover, volumeChecker: FixedVolumeChecker(available: true),
                        runningApplicationChecker: FixedRunningApplicationChecker(running: false),
                        capacityReader: FixedCapacityReader(values: []), coordinator: HeavyWorkCoordinator()
                    )
                    let context = verifiedDuplicateContext(bundle, homeURL: fixture.homeURL,
                        approvedPlanItemIDs: Set(bundle.plan.items.map(\.id)))
                    if failOnCall == 1 {
                        let report = await executor.preflight(plan: bundle.plan, context: context)
                        XCTAssertEqual(report.items.map(\.status), [.skipped(reason)])
                        XCTAssertEqual(report.readyCount, 0)
                    } else {
                        let report = await executor.execute(plan: bundle.plan, context: context, progress: { _ in })
                        XCTAssertEqual(report.items.map(\.outcome), [.skipped(reason)])
                        XCTAssertEqual(report.summary.movedItemCount, 0)
                    }
                    let moved = await mover.paths
                    XCTAssertTrue(moved.isEmpty)
                    XCTAssertFalse(CleanSkipReasonPresentation.title(reason).isEmpty)
                }
            }
        }
    }

    func testVerifiedDuplicatePreflightRejectsChangedRetainedContent() async throws {
        let fixture = makeVerifiedDuplicateFixture(groupCount: 1)
        let bundle = try VerifiedDuplicateCleanPlanBuilder.makePlan(
            requests: fixture.requests,
            disposition: .trash,
            userHomeURL: fixture.homeURL
        )
        let request = try XCTUnwrap(fixture.requests.first)
        let retained = try XCTUnwrap(request.retainedCopies.first)
        let digestReader = FixtureDigestReader(values: [
            request.sourceURL.path: fixture.digest,
            retained.url.path: Data(repeating: 0xCC, count: 32)
        ])
        let executor = SafeCleanupExecutor(
            metadataReader: FixtureMetadataReader(states: fixture.states),
            contentDigestReader: digestReader,
            mover: RecordingCleanupMover(),
            volumeChecker: FixedVolumeChecker(available: true),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            capacityReader: FixedCapacityReader(values: []),
            coordinator: HeavyWorkCoordinator()
        )

        let report = await executor.preflight(
            plan: bundle.plan,
            context: verifiedDuplicateContext(bundle, homeURL: fixture.homeURL)
        )

        XCTAssertEqual(report.readyCount, 0)
        XCTAssertEqual(report.items.map(\.status), [.skipped(.duplicateContentChanged)])
    }

    func testVerifiedDuplicateExecutionRechecksEachItemAndContinuesAfterDrift() async throws {
        let fixture = makeVerifiedDuplicateFixture(groupCount: 2)
        let bundle = try VerifiedDuplicateCleanPlanBuilder.makePlan(
            requests: fixture.requests,
            disposition: .quarantine,
            userHomeURL: fixture.homeURL
        )
        let first = try XCTUnwrap(fixture.requests.first)
        let second = try XCTUnwrap(fixture.requests.dropFirst().first)
        let firstRetained = try XCTUnwrap(first.retainedCopies.first)
        let secondRetained = try XCTUnwrap(second.retainedCopies.first)
        let secondDestination = fixture.homeURL.appendingPathComponent("quarantine-second.bin")
        var states = fixture.states
        states[secondDestination.path] = .snapshot(second.expectedSnapshot)
        let digestReader = SequencedDigestReader(values: [
            first.sourceURL.path: [fixture.digest, Data(repeating: 0xDD, count: 32)],
            firstRetained.url.path: [fixture.digest],
            // The third read occurs after the durable intent checkpoint.
            second.sourceURL.path: [fixture.digest, fixture.digest, fixture.digest],
            secondRetained.url.path: [fixture.digest, fixture.digest, fixture.digest]
        ])
        let mover = RecordingCleanupMover(outcomes: [
            second.sourceURL.path: .success(secondDestination)
        ])
        let executor = SafeCleanupExecutor(
            metadataReader: FixtureMetadataReader(states: states),
            contentDigestReader: digestReader,
            mover: mover,
            volumeChecker: FixedVolumeChecker(available: true),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            capacityReader: FixedCapacityReader(values: []),
            coordinator: HeavyWorkCoordinator()
        )

        let report = await executor.execute(
            plan: bundle.plan,
            context: verifiedDuplicateContext(
                bundle,
                homeURL: fixture.homeURL,
                approvedPlanItemIDs: Set(bundle.plan.items.map(\.id))
            ),
            progress: { _ in }
        )

        XCTAssertEqual(report.summary.movedItemCount, 1)
        XCTAssertEqual(report.summary.skippedItemCount, 1)
        XCTAssertTrue(report.items.contains { $0.outcome == .skipped(.duplicateContentChanged) })
        let movedPaths = await mover.paths
        XCTAssertEqual(movedPaths, [second.sourceURL.path])
        let movedReceipt = report.items.compactMap { item -> CleanupMoveReceipt? in
            guard case let .moved(receipt) = item.outcome else { return nil }
            return receipt
        }.first
        XCTAssertEqual(movedReceipt?.disposition, .quarantine)
        XCTAssertTrue(movedReceipt?.isRestorable == true)
    }

    func testVerifiedDuplicateTrashReportKeepsPhysicalSavingsUnknown() async throws {
        let fixture = makeVerifiedDuplicateFixture(groupCount: 1)
        let request = try XCTUnwrap(fixture.requests.first)
        let retained = try XCTUnwrap(request.retainedCopies.first)
        let bundle = try VerifiedDuplicateCleanPlanBuilder.makePlan(
            requests: [request],
            disposition: .trash,
            userHomeURL: fixture.homeURL
        )
        let destination = fixture.homeURL.appendingPathComponent("trash-source.bin")
        var states = fixture.states
        states[destination.path] = .snapshot(request.expectedSnapshot)
        let executor = SafeCleanupExecutor(
            metadataReader: FixtureMetadataReader(states: states),
            contentDigestReader: SequencedDigestReader(values: [
                request.sourceURL.path: [fixture.digest, fixture.digest, fixture.digest],
                retained.url.path: [fixture.digest, fixture.digest, fixture.digest]
            ]),
            mover: RecordingCleanupMover(outcomes: [
                request.sourceURL.path: .success(destination)
            ]),
            volumeChecker: FixedVolumeChecker(available: true),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            capacityReader: FixedCapacityReader(values: []),
            coordinator: HeavyWorkCoordinator()
        )

        let report = await executor.execute(
            plan: bundle.plan,
            context: verifiedDuplicateContext(
                bundle,
                homeURL: fixture.homeURL,
                approvedPlanItemIDs: Set(bundle.plan.items.map(\.id))
            ),
            progress: { _ in }
        )

        XCTAssertEqual(bundle.plan.estimatedMovableBytes, 4_096)
        XCTAssertEqual(report.summary.movedToRecoverableLocationBytes, 4_096)
        XCTAssertNil(report.summary.reclaimableAfterEmptyingTrashBytes)
        XCTAssertEqual(report.summary.permanentlyFreedBytes, 0)
    }

    func testImmediateSecondCheckStopsIdentitySymlinkAndPermissionSwaps() async throws {
        let fixture = makeFixture(count: 3)
        let plan = try makePlan(fixture)
        let reader = SequencedMetadataReader(states: [
            fixture.candidates[0].sourceURL.path: [
                .snapshot(fixture.candidates[0].snapshot),
                .snapshot(changedIdentity(fixture.candidates[0].snapshot))
            ],
            fixture.candidates[1].sourceURL.path: [
                .snapshot(fixture.candidates[1].snapshot),
                .snapshot(changedSymlink(fixture.candidates[1].snapshot))
            ],
            fixture.candidates[2].sourceURL.path: [
                .snapshot(fixture.candidates[2].snapshot),
                .error(.permissionDenied)
            ]
        ])
        let mover = RecordingCleanupMover()
        let executor = SafeCleanupExecutor(
            metadataReader: reader,
            mover: mover,
            volumeChecker: FixedVolumeChecker(available: true),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            capacityReader: FixedCapacityReader(values: []),
            coordinator: HeavyWorkCoordinator()
        )

        let report = await executor.execute(
            plan: plan,
            context: context(
                for: fixture,
                approvedPlanItemIDs: Set(plan.items.map(\.id))
            ),
            progress: { _ in }
        )

        XCTAssertEqual(report.items.map(\.outcome), [
            .skipped(.identityChanged),
            .skipped(.symbolicLinkDetected),
            .skipped(.permissionChanged)
        ])
        let movedPaths = await mover.paths
        XCTAssertTrue(movedPaths.isEmpty)
    }

    func testExecutorCancellationFinishesCurrentMoveAndLeavesRemainingUnprocessed() async throws {
        let fixture = makeFixture(count: 3)
        let plan = try makePlan(fixture)
        let firstDestination = URL(
            fileURLWithPath: fixture.candidates[0].sourceURL.path + ".trash"
        )
        var states = fixture.states
        states[firstDestination.path] = .snapshot(fixture.candidates[0].snapshot)
        let mover = SuspendingCleanupMover(resultURL: firstDestination)
        let coordinator = HeavyWorkCoordinator()
        let executor = SafeCleanupExecutor(
            metadataReader: FixtureMetadataReader(states: states),
            mover: mover,
            volumeChecker: FixedVolumeChecker(available: true),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            capacityReader: FixedCapacityReader(values: []),
            coordinator: coordinator
        )
        let executionContext = context(
            for: fixture,
            approvedPlanItemIDs: Set(plan.items.map(\.id))
        )

        let task = Task {
            await executor.execute(
                plan: plan,
                context: executionContext,
                progress: { _ in }
            )
        }
        await mover.waitUntilStarted()
        task.cancel()
        let drainingOwner = await coordinator.activeOwner
        XCTAssertEqual(drainingOwner, .cleanup)
        do {
            _ = try await coordinator.acquire(owner: .benchmark)
            XCTFail("Cancellation must not release a lease while a move is in flight")
        } catch { }
        await mover.finish()
        let report = await task.value
        XCTAssertEqual(report.outcome, .cancelled)
        XCTAssertEqual(report.summary.movedItemCount, 1)
        XCTAssertEqual(report.summary.notProcessedItemCount, 2)
        let cancellationCallCount = await mover.callCount
        XCTAssertEqual(cancellationCallCount, 1)
        let finishedOwner = await coordinator.activeOwner
        XCTAssertNil(finishedOwner)
    }

    func testExecutorRejectsSecondExecutionStaleSessionAndNonV2Modes() async throws {
        let fixture = makeFixture(count: 1)
        let plan = try makePlan(fixture)
        let destination = URL(fileURLWithPath: fixture.candidates[0].sourceURL.path + ".trash")
        var states = fixture.states
        states[destination.path] = .snapshot(fixture.candidates[0].snapshot)
        let mover = RecordingCleanupMover(outcomes: [
            fixture.candidates[0].sourceURL.path: .success(destination)
        ])
        let executor = SafeCleanupExecutor(
            metadataReader: FixtureMetadataReader(states: states),
            mover: mover,
            volumeChecker: FixedVolumeChecker(available: true),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            capacityReader: FixedCapacityReader(values: []),
            coordinator: HeavyWorkCoordinator()
        )

        let first = await executor.execute(
            plan: plan,
            context: context(
                for: fixture,
                approvedPlanItemIDs: Set(plan.items.map(\.id))
            ),
            progress: { _ in }
        )
        let second = await executor.execute(
            plan: plan,
            context: context(
                for: fixture,
                approvedPlanItemIDs: Set(plan.items.map(\.id))
            ),
            progress: { _ in }
        )
        XCTAssertEqual(first.summary.movedItemCount, 1)
        XCTAssertEqual(second.outcome, .failed)
        // D214＋旧值：was `XCTAssertEqual(second.summary.failedItemCount, 1)`. A plan
        // refused before it starts records its items as not run, not failed.
        XCTAssertEqual(second.summary.failedItemCount, 0)
        XCTAssertEqual(second.summary.notProcessedItemCount, 1)
        XCTAssertEqual(second.startRefusal?.code, .planIntegrityFailed)
        let firstCallCount = await mover.paths.count
        XCTAssertEqual(firstCallCount, 1)

        let freshPlan = try makePlan(fixture)
        let unapproved = await executor.execute(
            plan: freshPlan,
            context: context(for: fixture),
            progress: { _ in }
        )
        XCTAssertEqual(unapproved.outcome, .failed)
        let unapprovedCallCount = await mover.paths.count
        XCTAssertEqual(unapprovedCallCount, 1)

        let scanOnly = CleanupExecutionContext(
            featureConfiguration: CleanupFeatureConfiguration(mode: .v2ScanOnly),
            activeSessionID: fixture.session.id,
            activeRules: fixture.rules,
            userHomeURL: fixture.homeURL,
            excludedURLs: [],
            approvedPlanItemIDs: nil
        )
        let disabled = await executor.execute(
            plan: freshPlan,
            context: scanOnly,
            progress: { _ in }
        )
        XCTAssertEqual(disabled.outcome, .failed)
        let disabledCallCount = await mover.paths.count
        XCTAssertEqual(disabledCallCount, 1)

        let staleSession = CleanupExecutionContext(
            featureConfiguration: .productDefault,
            activeSessionID: ScanSessionID(),
            activeRules: fixture.rules,
            userHomeURL: fixture.homeURL,
            excludedURLs: [],
            approvedPlanItemIDs: Set(freshPlan.items.map(\.id))
        )
        let stale = await executor.execute(
            plan: freshPlan,
            context: staleSession,
            progress: { _ in }
        )
        XCTAssertEqual(stale.outcome, .failed)

        let legacy = CleanupExecutionContext(
            featureConfiguration: .legacy,
            activeSessionID: fixture.session.id,
            activeRules: fixture.rules,
            userHomeURL: fixture.homeURL,
            excludedURLs: [],
            approvedPlanItemIDs: Set(freshPlan.items.map(\.id))
        )
        let legacyRejected = await executor.execute(
            plan: freshPlan,
            context: legacy,
            progress: { _ in }
        )
        XCTAssertEqual(legacyRejected.outcome, .failed)
        let finalCallCount = await mover.paths.count
        XCTAssertEqual(finalCallCount, 1)
    }

    func testPostMoveIdentityMismatchIsReportedAndNotRestorable() async throws {
        let fixture = makeFixture(count: 1)
        let plan = try makePlan(fixture)
        let destination = URL(fileURLWithPath: fixture.candidates[0].sourceURL.path + ".trash")
        var states = fixture.states
        states[destination.path] = .snapshot(changedIdentity(
            fixture.candidates[0].snapshot
        ))
        let executor = SafeCleanupExecutor(
            metadataReader: FixtureMetadataReader(states: states),
            mover: RecordingCleanupMover(outcomes: [
                fixture.candidates[0].sourceURL.path: .success(destination)
            ]),
            volumeChecker: FixedVolumeChecker(available: true),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            capacityReader: FixedCapacityReader(values: []),
            coordinator: HeavyWorkCoordinator()
        )

        let report = await executor.execute(
            plan: plan,
            context: context(
                for: fixture,
                approvedPlanItemIDs: Set(plan.items.map(\.id))
            ),
            progress: { _ in }
        )
        XCTAssertEqual(report.outcome, .partiallyCompleted)
        XCTAssertEqual(report.summary.unverifiedMoveCount, 1)
        XCTAssertTrue(report.restorableReceipts.isEmpty)
    }

    func testProductionQuarantineMoveAndIdentityCheckedRestoreUseOnlyTemporaryFixture() async throws {
        let root = TestFileSystem.uniqueOperationRoot("CleanupQuarantine")
        TestFileSystem.registerCleanup(of: root, for: self)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let cache = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let source = cache.appendingPathComponent("fixture.bin")
        let secondSource = cache.appendingPathComponent("fixture-2.bin")
        let quarantine = home.appendingPathComponent(
            "Library/Application Support/StorageCleanerMac/CleanupQuarantine/v1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: source)
        try Data("fixture-2".utf8).write(to: secondSource)
        defer { TestFileSystem.remove(root) }
        try FileManager.default.createDirectory(
            at: quarantine,
            withIntermediateDirectories: true
        )
        XCTAssertFalse(PathSafety.containsSymbolicLinkComponent(in: quarantine.path))
        XCTAssertTrue(PathSafety.isContained(
            quarantine.path,
            in: home.path,
            resolvingSymlinks: true
        ))

        let reader = FoundationReadOnlyFileSystem()
        let original = try reader.snapshot(at: source)
        let secondOriginal = try reader.snapshot(at: secondSource)
        let mover = FoundationCleanupMover(
            quarantineRootURL: quarantine,
            userHomeURL: home
        )
        let planID = CleanPlanID()
        let movedURL = try await mover.moveToQuarantine(
            source,
            planID: planID,
            itemID: UUID()
        )
        let secondMovedURL = try await mover.moveToQuarantine(
            secondSource,
            planID: planID,
            itemID: UUID()
        )
        let moved = try reader.snapshot(at: movedURL)
        let secondMoved = try reader.snapshot(at: secondMovedURL)
        XCTAssertEqual(moved.identity, original.identity)
        XCTAssertEqual(secondMoved.identity, secondOriginal.identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondSource.path))

        let receipt = CleanupMoveReceipt(
            originalPath: source.path,
            resultingItemURL: movedURL,
            disposition: .quarantine,
            movedIdentity: moved.identity,
            verification: .identityVerified,
            movedAt: Date()
        )
        let secondReceipt = CleanupMoveReceipt(
            originalPath: secondSource.path,
            resultingItemURL: secondMovedURL,
            disposition: .quarantine,
            movedIdentity: secondMoved.identity,
            verification: .identityVerified,
            movedAt: Date()
        )
        let recovery = await CleanupRecoveryService().restore(
            receipts: [receipt, secondReceipt],
            userHomeURL: home,
            trashURL: home.appendingPathComponent(".Trash"),
            quarantineRootURL: quarantine
        )
        XCTAssertEqual(recovery.restoredCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondMovedURL.path))
    }

    func testRecoveryRejectsReplacementAtQuarantineReceiptPath() async throws {
        let root = TestFileSystem.uniqueOperationRoot("CleanupRestoreSwap")
        TestFileSystem.registerCleanup(of: root, for: self)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let cache = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let quarantine = home.appendingPathComponent("quarantine", isDirectory: true)
        let source = cache.appendingPathComponent("fixture.bin")
        let movedURL = quarantine.appendingPathComponent("receipt")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: movedURL)
        let current = try FoundationReadOnlyFileSystem().snapshot(at: movedURL)
        defer { TestFileSystem.remove(root) }

        let receipt = CleanupMoveReceipt(
            originalPath: source.path,
            resultingItemURL: movedURL,
            disposition: .quarantine,
            movedIdentity: FileIdentity(
                deviceID: current.identity.deviceID,
                inode: current.identity.inode + 1,
                entryKind: current.identity.entryKind,
                creationTimeNanoseconds: current.identity.creationTimeNanoseconds
            ),
            verification: .identityVerified,
            movedAt: Date()
        )
        let report = await CleanupRecoveryService().restore(
            receipts: [receipt],
            userHomeURL: home,
            trashURL: home.appendingPathComponent(".Trash"),
            quarantineRootURL: quarantine
        )
        XCTAssertEqual(report.items.map(\.outcome), [.identityChanged])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedURL.path))
    }

    func testMigrationIsIdempotentPreservesLegacyKeysAndRejectsOutsideHome() throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        let home = URL(fileURLWithPath: "/tmp/fixture-home-\(UUID().uuidString)")
        let valid = home.appendingPathComponent("Library/Caches/keep").path
        let existingV2 = home.appendingPathComponent("Library/Logs/preserved").path
        let laterValid = home.appendingPathComponent("Library/Caches/later").path
        let invalid = "/Applications/DoNotMigrate.app"
        defaults.set([valid, invalid, home.path, "Library/Caches/relative"], forKey: ScanExclusionService.defaultsKey)
        defaults.set([existingV2], forKey: CleanupMigration.excludedPathsKey)
        defaults.set(Data("legacy-history".utf8), forKey: CleanupHistoryService.defaultsKey)
        let rules = makeFixture(count: 1, homeURL: home).rules

        let first = CleanupMigration.migrateIfNeeded(
            defaults: defaults,
            activeRules: rules,
            userHomeURL: home
        )
        let second = CleanupMigration.migrateIfNeeded(
            defaults: defaults,
            activeRules: rules,
            userHomeURL: home
        )

        XCTAssertTrue(first.didComplete)
        XCTAssertEqual(first.migratedExclusionCount, 2)
        XCTAssertEqual(first.rejectedExclusionCount, 3)
        XCTAssertEqual(second.fromVersion, CleanupMigration.currentVersion)
        XCTAssertEqual(
            defaults.stringArray(forKey: ScanExclusionService.defaultsKey),
            [valid, invalid, home.path, "Library/Caches/relative"]
        )
        XCTAssertEqual(defaults.data(forKey: CleanupHistoryService.defaultsKey), Data("legacy-history".utf8))
        XCTAssertEqual(
            defaults.stringArray(forKey: CleanupMigration.excludedPathsKey),
            [existingV2, valid].sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        )

        defaults.set(
            [valid, invalid, home.path, "Library/Caches/relative", laterValid],
            forKey: ScanExclusionService.defaultsKey
        )
        XCTAssertEqual(
            CleanupMigration.v2ExcludedURLs(defaults: defaults, userHomeURL: home).map(\.path),
            [laterValid, existingV2, valid].sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        )
    }

    func testCleanReportStoreRoundTripsOneReportPerPlan() throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        let fixture = makeFixture(count: 1)
        let plan = try makePlan(fixture)
        let report = makeReport(plan: plan)
        XCTAssertTrue(CleanReportStore.record(report, defaults: defaults))
        XCTAssertTrue(CleanReportStore.record(report, defaults: defaults))
        XCTAssertEqual(CleanReportStore.load(defaults: defaults), [report])
    }

    @MainActor
    func testNewStoreReconnectsOnlyLatestRestorableVerifiedDuplicateReport() throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        let older = makePersistedVerifiedDuplicateReport(
            completedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let expected = makePersistedVerifiedDuplicateReport(
            completedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        XCTAssertTrue(CleanReportStore.record(older, defaults: defaults))
        XCTAssertTrue(CleanReportStore.record(expected, defaults: defaults))

        let store = try ScanStore.makeForTests(for: self, cleanReportLoader: {
            CleanReportStore.load(defaults: defaults)
        })

        XCTAssertEqual(store.duplicateCleanupReport, expected)
        store.requestRestoreLatestVerifiedDuplicateCleanup()
        XCTAssertTrue(store.isDuplicateRestoreConfirmationPresented)
    }

    @MainActor
    func testPersistedDuplicateCleanupRecoveryFailsClosedForCorruptOrConsumedReports() throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        let report = makePersistedVerifiedDuplicateReport()
        let consumed = CleanReportStore.removingRestoredReceipts(
            from: report,
            originalPaths: [try XCTUnwrap(report.restorableReceipts.first).originalPath]
        )
        XCTAssertTrue(CleanReportStore.record(consumed, defaults: defaults))

        let consumedStore = try ScanStore.makeForTests(for: self, cleanReportLoader: {
            CleanReportStore.load(defaults: defaults)
        })
        XCTAssertNil(consumedStore.duplicateCleanupReport)

        TestPreferenceDomain.cleanup(suiteName: suite)
        XCTAssertTrue(CleanReportStore.record(
            makePersistedVerifiedDuplicateReport(rulesVersion: "ordinary-cleanup-v1"),
            defaults: defaults
        ))
        let nonDuplicateStore = try ScanStore.makeForTests(for: self, cleanReportLoader: {
            CleanReportStore.load(defaults: defaults)
        })
        XCTAssertNil(nonDuplicateStore.duplicateCleanupReport)

        TestPreferenceDomain.cleanup(suiteName: suite)
        XCTAssertTrue(CleanReportStore.record(
            makePersistedVerifiedDuplicateReport(restorable: false),
            defaults: defaults
        ))
        let noReceiptStore = try ScanStore.makeForTests(for: self, cleanReportLoader: {
            CleanReportStore.load(defaults: defaults)
        })
        XCTAssertNil(noReceiptStore.duplicateCleanupReport)

        defaults.set(Data("not-json".utf8), forKey: CleanReportStore.defaultsKey)
        let corruptStore = try ScanStore.makeForTests(for: self, cleanReportLoader: {
            CleanReportStore.load(defaults: defaults)
        })
        XCTAssertNil(corruptStore.duplicateCleanupReport)
    }

    private func makePlan(_ fixture: CleanupExecutionFixture) throws -> CleanPlan {
        try CleanPlanBuilder.makePlan(
            session: fixture.session,
            selection: CleanupSelection(
                selectedCandidateIDs: Set(fixture.candidates.map(\.id))
            ),
            activeRules: fixture.rules,
            disposition: .trash
        )
    }

    private func context(
        for fixture: CleanupExecutionFixture,
        approvedPlanItemIDs: Set<UUID>? = nil,
        excludedURLs: [URL] = []
    ) -> CleanupExecutionContext {
        CleanupExecutionContext(
            featureConfiguration: CleanupFeatureConfiguration(mode: .v2Full),
            activeSessionID: fixture.session.id,
            activeRules: fixture.rules,
            userHomeURL: fixture.homeURL,
            excludedURLs: excludedURLs,
            approvedPlanItemIDs: approvedPlanItemIDs
        )
    }

    private func verifiedDuplicateContext(
        _ bundle: VerifiedDuplicatePlanBundle,
        homeURL: URL,
        approvedPlanItemIDs: Set<UUID>? = nil
    ) -> CleanupExecutionContext {
        CleanupExecutionContext(
            featureConfiguration: .productDefault,
            activeSessionID: bundle.sessionID,
            activeRules: bundle.activeRules,
            userHomeURL: homeURL,
            excludedURLs: [],
            approvedPlanItemIDs: approvedPlanItemIDs
        )
    }

    private func makeVerifiedDuplicateFixture(groupCount: Int) -> VerifiedDuplicateFixture {
        let home = URL(
            fileURLWithPath: "/tmp/verified-duplicate-\(UUID().uuidString)",
            isDirectory: true
        )
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let digest = Data(repeating: 0xAB, count: 32)
        var requests = [VerifiedDuplicatePlanRequest]()
        var states = [String: FixtureMetadataState]()

        for index in 0..<groupCount {
            let source = documents.appendingPathComponent("source-\(index).bin")
            let retained = documents.appendingPathComponent("retained-\(index).bin")
            let sourceSnapshot = duplicateSnapshot(
                url: source,
                inode: UInt64(10_000 + index * 2)
            )
            let retainedSnapshot = duplicateSnapshot(
                url: retained,
                inode: UInt64(10_001 + index * 2)
            )
            states[source.path] = .snapshot(sourceSnapshot)
            states[retained.path] = .snapshot(retainedSnapshot)
            requests.append(VerifiedDuplicatePlanRequest(
                sourceURL: source,
                allowedRootURL: documents,
                expectedSnapshot: sourceSnapshot,
                groupID: "sha256-group-\(index)",
                digest: digest,
                retainedCopies: [
                    VerifiedDuplicateRetainedCopy(
                        url: retained,
                        expectedSnapshot: retainedSnapshot
                    )
                ]
            ))
        }
        return VerifiedDuplicateFixture(
            homeURL: home,
            digest: digest,
            requests: requests,
            states: states
        )
    }

    private func duplicateSnapshot(url: URL, inode: UInt64) -> FileSnapshot {
        FileSnapshot(
            identity: FileIdentity(
                deviceID: 51,
                inode: inode,
                entryKind: .regularFile,
                creationTimeNanoseconds: Int64(inode)
            ),
            standardizedPath: url.path,
            volumeIdentifier: "duplicate-fixture-volume",
            logicalSizeBytes: 4_096,
            allocatedSizeBytes: 4_096,
            modificationTimeNanoseconds: 100,
            isWritableVolume: true,
            isCloudItem: false,
            isCloudPlaceholder: false,
            hasSymbolicLinkComponent: false
        )
    }

    private func makeFixture(
        count: Int,
        duplicateIdentity: Bool = false,
        requiredClosedBundleIDs: [String] = [],
        homeURL: URL? = nil
    ) -> CleanupExecutionFixture {
        let home = homeURL ?? URL(
            fileURLWithPath: "/tmp/cleanup-executor-\(UUID().uuidString)",
            isDirectory: true
        )
        let root = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let sessionID = ScanSessionID()
        let rule = CleanupRule(
            id: "system.user-caches",
            selectionPolicyVersion: 1,
            categoryID: "system",
            categoryTitleKey: "cleanup.category.system",
            titleKey: "cleanup.rule.userCaches.title",
            root: CleanupRuleRoot(kind: .homeRelative, path: "Library/Caches"),
            maximumDepth: 4,
            minimumAgeDays: 0,
            minimumBytes: 0,
            include: CleanupRuleMatch(
                entryKinds: [.regularFile],
                extensions: [],
                nameMatcher: CleanupNameMatcher(mode: .any, values: [])
            ),
            exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
            cloudPolicy: .skipPlaceholder,
            risk: .safe,
            recommendation: .recommended,
            defaultSelection: .selected,
            executionEligibility: .eligible,
            measurementRequirement: .complete,
            allowsManualSelection: true,
            action: .moveToTrash,
            requiredClosedBundleIDs: requiredClosedBundleIDs,
            reasonKey: "cleanup.rule.userCaches.reason"
        )
        let rules = CleanupRuleSet(
            schemaVersion: 2,
            rulesVersion: "fixture-rules",
            rules: [rule]
        )
        let candidates = (0..<count).map { index in
            let identityIndex = duplicateIdentity ? 0 : index
            let source = root.appendingPathComponent("item-\(index).bin")
            let snapshot = FileSnapshot(
                identity: FileIdentity(
                    deviceID: 7,
                    inode: UInt64(100 + identityIndex),
                    entryKind: .regularFile,
                    creationTimeNanoseconds: Int64(1_000 + identityIndex)
                ),
                standardizedPath: source.path,
                volumeIdentifier: "fixture-volume",
                logicalSizeBytes: Int64(1_024 * (index + 1)),
                allocatedSizeBytes: Int64(1_024 * (index + 1)),
                modificationTimeNanoseconds: 1_000,
                isWritableVolume: true,
                isCloudItem: false,
                isCloudPlaceholder: false,
                hasSymbolicLinkComponent: false
            )
            return ScanCandidate(
                id: ScanCandidateID(),
                sessionID: sessionID,
                ruleID: rule.id,
                ruleSelectionPolicyVersion: rule.selectionPolicyVersion,
                categoryID: rule.categoryID,
                categoryTitle: "System",
                subcategoryTitle: "Caches",
                sourceURL: source,
                allowedRootURL: root,
                snapshot: snapshot,
                risk: .safe,
                recommendation: CleanupRecommendation(
                    level: .recommended,
                    reasonCode: rule.reasonKey,
                    evidenceCodes: []
                ),
                defaultSelection: .selected,
                executionEligibility: .eligible,
                measurementCompleteness: .complete,
                isManuallySelectable: true,
                action: .moveToTrash,
                requiredClosedBundleIDs: requiredClosedBundleIDs,
                reason: "Fixture"
            )
        }
        let session = makeSession(
            id: sessionID,
            candidates: candidates,
            rulesVersion: rules.rulesVersion,
            outcome: .complete
        )
        return CleanupExecutionFixture(
            homeURL: home,
            rules: rules,
            candidates: candidates,
            session: session,
            states: Dictionary(uniqueKeysWithValues: candidates.map {
                ($0.sourceURL.path, .snapshot($0.snapshot))
            })
        )
    }

    private func makeSession(
        id: ScanSessionID? = nil,
        candidates: [ScanCandidate],
        rulesVersion: String,
        outcome: ScanOutcome
    ) -> ScanSession {
        let sessionID = id ?? candidates.first?.sessionID ?? ScanSessionID()
        return ScanSession(
            id: sessionID,
            rulesVersion: rulesVersion,
            startedAt: Date(),
            completedAt: Date(),
            outcome: outcome,
            categories: [
                CleanupScanCategory(
                    id: "system",
                    title: "System",
                    subcategories: [
                        CleanupScanSubcategory(
                            id: "system.user-caches",
                            title: "Caches",
                            risk: .safe,
                            recommendation: .recommended,
                            reason: "Fixture",
                            candidates: candidates
                        )
                    ]
                )
            ],
            issues: [],
            permissions: [],
            metrics: ScanMetrics(
                visitedEntryCount: candidates.count,
                candidateCount: candidates.count,
                deduplicatedIdentityCount: 0,
                estimatedCandidateBytes: candidates.reduce(0) {
                    $0 + $1.snapshot.logicalSizeBytes
                },
                duration: 0
            )
        )
    }

    private func changedIdentity(_ snapshot: FileSnapshot) -> FileSnapshot {
        FileSnapshot(
            identity: FileIdentity(
                deviceID: snapshot.identity.deviceID,
                inode: snapshot.identity.inode + 9_000,
                entryKind: snapshot.identity.entryKind,
                creationTimeNanoseconds: snapshot.identity.creationTimeNanoseconds
            ),
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

    private func changedSymlink(_ snapshot: FileSnapshot) -> FileSnapshot {
        FileSnapshot(
            identity: FileIdentity(
                deviceID: snapshot.identity.deviceID,
                inode: snapshot.identity.inode,
                entryKind: .symbolicLink,
                creationTimeNanoseconds: snapshot.identity.creationTimeNanoseconds
            ),
            standardizedPath: snapshot.standardizedPath,
            volumeIdentifier: snapshot.volumeIdentifier,
            logicalSizeBytes: snapshot.logicalSizeBytes,
            allocatedSizeBytes: snapshot.allocatedSizeBytes,
            modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
            isWritableVolume: true,
            isCloudItem: false,
            isCloudPlaceholder: false,
            hasSymbolicLinkComponent: true
        )
    }

    private func changedWritable(
        _ snapshot: FileSnapshot,
        isWritable: Bool
    ) -> FileSnapshot {
        FileSnapshot(
            identity: snapshot.identity,
            standardizedPath: snapshot.standardizedPath,
            volumeIdentifier: snapshot.volumeIdentifier,
            logicalSizeBytes: snapshot.logicalSizeBytes,
            allocatedSizeBytes: snapshot.allocatedSizeBytes,
            modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
            isWritableVolume: isWritable,
            isCloudItem: snapshot.isCloudItem,
            isCloudPlaceholder: snapshot.isCloudPlaceholder,
            hasSymbolicLinkComponent: snapshot.hasSymbolicLinkComponent
        )
    }

    private func makeReport(plan: CleanPlan) -> CleanReport {
        CleanReport(
            id: UUID(),
            planID: plan.id,
            sessionID: plan.sessionID,
            rulesVersion: plan.rulesVersion,
            disposition: plan.disposition,
            scanWasPartial: false,
            startedAt: Date(),
            completedAt: Date(),
            outcome: .completed,
            items: [],
            summary: CleanReportSummary(
                requestedItemCount: 0,
                movedItemCount: 0,
                skippedItemCount: 0,
                failedItemCount: 0,
                notProcessedItemCount: 0,
                unverifiedMoveCount: 0,
                plannedBytes: 0,
                movedToRecoverableLocationBytes: 0,
                reclaimableAfterEmptyingTrashBytes: 0,
                permanentlyFreedBytes: 0,
                availableSpaceDeltaBytes: nil
            )
        )
    }

    private func makePersistedVerifiedDuplicateReport(
        rulesVersion: String = VerifiedDuplicateCleanPlanBuilder.rulesVersion,
        completedAt: Date = Date(),
        restorable: Bool = true
    ) -> CleanReport {
        let receipt = CleanupMoveReceipt(
            originalPath: "/tmp/duplicate-source-\(UUID().uuidString)",
            resultingItemURL: URL(fileURLWithPath: "/tmp/duplicate-receipt-\(UUID().uuidString)"),
            disposition: .quarantine,
            movedIdentity: restorable
                ? FileIdentity(
                    deviceID: 1,
                    inode: 2,
                    entryKind: .regularFile,
                    creationTimeNanoseconds: 3
                )
                : nil,
            verification: restorable ? .identityVerified : .identityMismatch,
            movedAt: completedAt
        )
        return CleanReport(
            id: UUID(),
            planID: CleanPlanID(),
            sessionID: ScanSessionID(),
            rulesVersion: rulesVersion,
            disposition: .quarantine,
            scanWasPartial: false,
            startedAt: completedAt,
            completedAt: completedAt,
            outcome: .completed,
            items: [
                CleanReportItem(
                    id: UUID(),
                    planItemID: UUID(),
                    ruleID: VerifiedDuplicateCleanPlanBuilder.ruleID,
                    sourcePath: receipt.originalPath,
                    estimatedBytes: 1,
                    outcome: .moved(receipt)
                )
            ],
            summary: CleanReportSummary(
                requestedItemCount: 1,
                movedItemCount: 1,
                skippedItemCount: 0,
                failedItemCount: 0,
                notProcessedItemCount: 0,
                unverifiedMoveCount: restorable ? 0 : 1,
                plannedBytes: 1,
                movedToRecoverableLocationBytes: restorable ? 1 : 0,
                reclaimableAfterEmptyingTrashBytes: nil,
                permanentlyFreedBytes: 0,
                availableSpaceDeltaBytes: nil
            )
        )
    }
}

private struct CleanupExecutionFixture {
    let homeURL: URL
    let rules: CleanupRuleSet
    let candidates: [ScanCandidate]
    let session: ScanSession
    let states: [String: FixtureMetadataState]
}

private struct VerifiedDuplicateFixture {
    let homeURL: URL
    let digest: Data
    let requests: [VerifiedDuplicatePlanRequest]
    let states: [String: FixtureMetadataState]
}

private enum FixtureMetadataState: Sendable {
    case snapshot(FileSnapshot)
    case error(CleanupFileSystemError)
}

private struct FixtureMetadataReader: ReadOnlyFileSystem {
    let states: [String: FixtureMetadataState]

    func snapshot(at url: URL) throws -> FileSnapshot {
        guard let state = states[PathSafety.lexicalPath(url.path)] else {
            throw CleanupFileSystemError.vanished
        }
        switch state {
        case let .snapshot(snapshot):
            return snapshot
        case let .error(error):
            throw error
        }
    }

    func children(of directory: URL) throws -> [URL] {
        []
    }
}

private final class SequencedMetadataReader: ReadOnlyFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: [FixtureMetadataState]]

    init(states: [String: [FixtureMetadataState]]) {
        self.states = states
    }

    func snapshot(at url: URL) throws -> FileSnapshot {
        let state: FixtureMetadataState? = lock.withLock {
            let path = PathSafety.lexicalPath(url.path)
            guard var values = states[path], !values.isEmpty else { return nil }
            let value = values.removeFirst()
            states[path] = values
            return value
        }
        guard let state else {
            throw CleanupFileSystemError.vanished
        }
        switch state {
        case let .snapshot(snapshot):
            return snapshot
        case let .error(error):
            throw error
        }
    }

    func children(of directory: URL) throws -> [URL] {
        []
    }
}

private struct FixtureDigestReader: CleanupContentDigestReading {
    let values: [String: Data]

    func sha256(at url: URL) throws -> Data {
        guard let value = values[PathSafety.lexicalPath(url.path)] else {
            throw CleanupFileSystemError.vanished
        }
        return value
    }
}

private final class SequencedDigestReader: CleanupContentDigestReading, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [Data]]

    init(values: [String: [Data]]) {
        self.values = values
    }

    func sha256(at url: URL) throws -> Data {
        let value: Data? = lock.withLock {
            let path = PathSafety.lexicalPath(url.path)
            guard var pathValues = values[path], !pathValues.isEmpty else { return nil }
            let next = pathValues.removeFirst()
            values[path] = pathValues
            return next
        }
        guard let value else { throw CleanupFileSystemError.vanished }
        return value
    }
}

private enum RecordingMoveOutcome: Sendable {
    case success(URL)
    case failure
}

private actor RecordingCleanupMover: CleanupMoving {
    private(set) var paths = [String]()
    let outcomes: [String: RecordingMoveOutcome]

    init(outcomes: [String: RecordingMoveOutcome] = [:]) {
        self.outcomes = outcomes
    }

    func moveToTrash(_ url: URL) async throws -> URL {
        paths.append(url.path)
        return try outcome(for: url)
    }

    func moveToQuarantine(
        _ url: URL,
        planID: CleanPlanID,
        itemID: UUID
    ) async throws -> URL {
        paths.append(url.path)
        return try outcome(for: url)
    }

    private func outcome(for url: URL) throws -> URL {
        switch outcomes[url.path] {
        case let .success(destination):
            return destination
        case .failure, nil:
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private actor SuspendingCleanupMover: CleanupMoving {
    private let resultURL: URL
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    init(resultURL: URL) {
        self.resultURL = resultURL
    }

    func moveToTrash(_ url: URL) async throws -> URL {
        callCount += 1
        await withCheckedContinuation { continuation = $0 }
        return resultURL
    }

    func moveToQuarantine(
        _ url: URL,
        planID: CleanPlanID,
        itemID: UUID
    ) async throws -> URL {
        try await moveToTrash(url)
    }

    func waitUntilStarted() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private struct FixedVolumeChecker: CleanupVolumeChecking {
    let available: Bool

    func isAvailable(volumeIdentifier: String) async -> Bool {
        available
    }
}

private actor FirstCheckRunningApplicationChecker: CleanupRunningApplicationChecking {
    private var checks = 0
    func isRunning(bundleIdentifier: String) async -> Bool {
        checks += 1
        return checks == 1
    }
}

private actor ControllableRunningApplicationChecker: CleanupRunningApplicationChecking {
    private var running: Bool

    init(running: Bool) { self.running = running }
    func setRunning(_ running: Bool) { self.running = running }
    func isRunning(bundleIdentifier: String) async -> Bool { running }
}

private struct FixedRunningApplicationChecker: CleanupRunningApplicationChecking {
    let running: Bool

    func isRunning(bundleIdentifier: String) async -> Bool {
        running
    }
}

private actor FixedCapacityReader: CleanupCapacityReading {
    private var values: [Int64?]

    init(values: [Int64?]) {
        self.values = values
    }

    func availableCapacity(at url: URL) async -> Int64? {
        values.isEmpty ? nil : values.removeFirst()
    }
}

/// D101 G13: every volume has `usedBytes` in use; each reading is recorded.
private actor RecordingUsedCapacityReader: CleanupCapacityReading {
    private let usedBytes: Int64?
    private(set) var readURLs: [URL] = []

    init(usedBytes: Int64?) {
        self.usedBytes = usedBytes
    }

    func availableCapacity(at _: URL) async -> Int64? { nil }

    func usedCapacity(at url: URL) async -> Int64? {
        readURLs.append(url)
        return usedBytes
    }
}

extension CleanupExecutionSafetyTests {
    /// D101 G13: the check judges the items that will run, reads each
    /// volume's used space once, and leaves a normal run alone.
    func testPreflightFlagsAnUnusuallyLargeRunFromTheItemsThatWillRun() async throws {
        let fixture = makeFixture(count: 3)
        let plan = try makePlan(fixture)
        XCTAssertEqual(plan.items.map(\.estimatedSizeBytes).reduce(0, +), 6_144)
        func preflight(used: Int64?, vanished: Set<Int> = []) async -> (CleanPreflightReport, [URL]) {
            var states = [String: FixtureMetadataState]()
            for (index, candidate) in fixture.candidates.enumerated() {
                states[candidate.sourceURL.path] = vanished.contains(index)
                    ? .error(.vanished) : .snapshot(candidate.snapshot)
            }
            let reader = RecordingUsedCapacityReader(usedBytes: used)
            let executor = SafeCleanupExecutor(
                metadataReader: FixtureMetadataReader(states: states),
                mover: RecordingCleanupMover(),
                volumeChecker: FixedVolumeChecker(available: true),
                runningApplicationChecker: FixedRunningApplicationChecker(running: false),
                capacityReader: reader,
                coordinator: HeavyWorkCoordinator()
            )
            let report = await executor.preflight(plan: plan, context: context(for: fixture))
            return (report, await reader.readURLs)
        }

        let (normal, reads) = await preflight(used: 12_288)
        XCTAssertEqual(normal.readyCount, 3)
        XCTAssertNil(normal.scaleAlert, "6 KiB is exactly half of 12 KiB in use")
        XCTAssertEqual(reads.count, 1, "One volume, read once")
        XCTAssertTrue(plan.items.map(\.sourceURL).contains(try XCTUnwrap(reads.first)))

        let (large, _) = await preflight(used: 12_287)
        let alert = try XCTUnwrap(large.scaleAlert)
        XCTAssertEqual(alert.itemCount, 3)
        XCTAssertEqual(alert.bytes, 6_144)
        XCTAssertFalse(alert.exceedsItemCount)
        XCTAssertEqual(alert.largeVolumeShares, [
            .init(volumeIdentifier: "fixture-volume", plannedBytes: 6_144, usedBytes: 12_287)
        ])
        XCTAssertEqual(alert.largestRules, [.init(
            ruleID: "system.user-caches", title: CleanupRuleCopy.title(for: fixture.rules.rules[0]),
            itemCount: 3, bytes: 6_144
        )])

        // The vanished 3 KiB item is skipped and not counted: 3 KiB of 8 KiB.
        let (skipped, _) = await preflight(used: 8_192, vanished: [2])
        XCTAssertEqual(skipped.readyCount, 2)
        XCTAssertNil(skipped.scaleAlert)

        // Without the volume's use only the count is judged.
        let (unknown, _) = await preflight(used: nil)
        XCTAssertNil(unknown.scaleAlert)
    }
}

extension CleanupExecutionSafetyTests {
    func testPostJournalReplacementIsRecheckedBeforeMove() async throws {
        for change in 0..<3 {
            let fixture = makeFixture(count: 1)
            let plan = try makePlan(fixture)
            let original = try XCTUnwrap(plan.items.first).expectedSnapshot
            let replacement: FixtureMetadataState = switch change {
            case 0: .snapshot(changedIdentity(original))
            case 1: .snapshot(changedSymlink(original))
            default: .error(.permissionDenied)
            }
            let reader = JournalSwapMetadataReader(state: .snapshot(original))
            let mover = RecordingCleanupMover()
            let executor = SafeCleanupExecutor(
                metadataReader: reader, mover: mover,
                volumeChecker: FixedVolumeChecker(available: true),
                runningApplicationChecker: FixedRunningApplicationChecker(running: false),
                capacityReader: FixedCapacityReader(values: []), coordinator: HeavyWorkCoordinator(),
                persistReport: { report, _ in
                    if report.items.contains(where: {
                        if case .failed(let failure) = $0.outcome { return failure.code == .moveOutcomeUnknown }
                        return false
                    }) { reader.replace(with: replacement) }
                }
            )
            let report = await executor.execute(plan: plan,
                context: context(for: fixture, approvedPlanItemIDs: Set(plan.items.map(\.id))), progress: { _ in })
            let paths = await mover.paths
            XCTAssertTrue(paths.isEmpty, "Post-journal change \(change) reached the mover")
            XCTAssertEqual(report.summary.movedItemCount, 0)
            XCTAssertEqual(report.summary.skippedItemCount, 1)
        }
    }

    func testJournalFailureBeforeFirstMoveLeavesAllFilesUntouched() async throws {
        let fixture = makeFixture(count: 2)
        let plan = try makePlan(fixture)
        let mover = RecordingCleanupMover()
        let executor = SafeCleanupExecutor(
            metadataReader: FixtureMetadataReader(states: fixture.states), mover: mover,
            volumeChecker: FixedVolumeChecker(available: true),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            capacityReader: FixedCapacityReader(values: []), coordinator: HeavyWorkCoordinator(),
            persistReport: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        )
        let report = await executor.execute(plan: plan,
            context: context(for: fixture, approvedPlanItemIDs: Set(plan.items.map(\.id))), progress: { _ in })
        let paths = await mover.paths
        XCTAssertTrue(paths.isEmpty)
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(report.summary.movedItemCount, 0)
    }

    /// D214: another task holds the work lease — nothing is tried, every item
    /// is not run (not failed), and the report says what held the lease, for
    /// the result pages and the operation records alike.
    @MainActor
    func testABusyLeaseRefusesTheRunBeforeItsFirstItem() async throws {
        let language = CalibrationLanguageScope(.zhHans)
        defer { language.restore() }
        let fixture = makeFixture(count: 2)
        let plan = try makePlan(fixture)
        let mover = RecordingCleanupMover()
        let coordinator = HeavyWorkCoordinator()
        let executor = SafeCleanupExecutor(
            metadataReader: FixtureMetadataReader(states: fixture.states), mover: mover,
            volumeChecker: FixedVolumeChecker(available: true),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            capacityReader: FixedCapacityReader(values: []), coordinator: coordinator,
            persistReport: { _, _ in XCTFail("A refused run writes no intent") }
        )
        let held = try await coordinator.acquire(owner: .appUpdates)
        let report = await executor.execute(plan: plan,
            context: context(for: fixture, approvedPlanItemIDs: Set(plan.items.map(\.id))), progress: { _ in })
        await coordinator.release(held)
        let paths = await mover.paths
        XCTAssertTrue(paths.isEmpty)
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(report.summary.failedItemCount, 0)
        XCTAssertEqual(report.summary.notProcessedItemCount, 2)
        XCTAssertEqual(report.summary.movedItemCount, 0)
        XCTAssertTrue(report.items.allSatisfy { $0.outcome == .notProcessed })
        XCTAssertEqual(report.startRefusal, CleanFailure(code: .coordinatorBusy, detailCode: "lease-busy:appUpdates"))
        let refusal = try XCTUnwrap(report.startRefusal)
        XCTAssertEqual(CleanStartRefusalPresentation.reason(refusal),
                       HeavyWorkActivityStore.conflictMessage(activeOwner: .appUpdates))
        XCTAssertEqual(CleanStartRefusalPresentation.message(refusal),
                       "正在进行应用更新，请等待完成或取消后再试。没有移动任何文件，选中的项目都还在。")

        let presentation = OperationResultPresentation(report: report)
        XCTAssertEqual(presentation.title, "没能开始")
        XCTAssertEqual(presentation.failedCount, 0)
        XCTAssertEqual(presentation.notRunCount, 2)
        XCTAssertFalse(presentation.summary.contains("失败"), presentation.summary)
        XCTAssertTrue(presentation.summary.contains("未执行 2"), presentation.summary)
        let tally = OperationCompletionTally(report: report)
        XCTAssertEqual(tally.count(.failed), 0)
        XCTAssertEqual(tally.count(.skipped), 2)
        // The operation records list reads the index.
        let index = CleanupReportIndex(report: report, orderingDate: Date())
        XCTAssertEqual(index.presentation?.title, "没能开始")
        XCTAssertEqual(index.summary.failedItemCount, 0)

        // Receipts keep the refusal; an older receipt without it reads as a run.
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(CleanReport.self, from: data), report)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "startRefusal")
        let older = try JSONDecoder().decode(CleanReport.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(older.startRefusal)
        XCTAssertEqual(OperationResultPresentation(report: older).title, "未完成")
    }

    func testJournalFailureAfterMoveKeepsReceiptAndStopsNextMove() async throws {
        let fixture = makeFixture(count: 2)
        let plan = try makePlan(fixture)
        let first = try XCTUnwrap(plan.items.first)
        let destination = URL(fileURLWithPath: first.sourceURL.path + ".trash")
        var states = fixture.states
        states[destination.path] = .snapshot(first.expectedSnapshot)
        let mover = RecordingCleanupMover(outcomes: [first.sourceURL.path: .success(destination)])
        let writes = FailingJournalProbe(failAt: 3)
        let executor = SafeCleanupExecutor(
            metadataReader: FixtureMetadataReader(states: states), mover: mover,
            volumeChecker: FixedVolumeChecker(available: true),
            runningApplicationChecker: FixedRunningApplicationChecker(running: false),
            capacityReader: FixedCapacityReader(values: []), coordinator: HeavyWorkCoordinator(),
            persistReport: { report, _ in try writes.record(report) }
        )
        let report = await executor.execute(plan: plan,
            context: context(for: fixture, approvedPlanItemIDs: Set(plan.items.map(\.id))), progress: { _ in })
        let paths = await mover.paths
        XCTAssertEqual(paths, [first.sourceURL.path])
        XCTAssertEqual(report.restorableReceipts.count, 1)
        XCTAssertEqual(report.restorableReceipts.first?.resultingItemURL, destination)
        XCTAssertEqual(writes.reports.last?.items.filter {
            if case .failed(let failure) = $0.outcome { return failure.code == .moveOutcomeUnknown }
            return false
        }.count, 1)
    }

    func testJournalReloadRetainsIdentityAndRejectsChangedIntent() throws {
        // 回执夹具在隐藏家目录内，直接满足原有 home 和逐级符号链接检查。
        let root = TestFileSystem.uniqueOperationRoot("JournalFixture")
        defer { TestFileSystem.remove(root) }
        // Fixtures never touch the real ~/Library (P2-11).
        let realLibrary = PathSafety.lexicalPath(
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        )
        guard !PathSafety.isContained(
            PathSafety.lexicalPath(root.path),
            in: realLibrary,
            resolvingSymlinks: false
        ) else {
            return XCTFail("The fixture must not be created in the real Library: \(root.path)")
        }
        let journal = CleanupReportJournal(directory: root)
        let fixture = makeFixture(count: 1)
        let plan = try makePlan(fixture)
        let report = makeReport(plan: plan)
        let item = try XCTUnwrap(plan.items.first)
        let identities = [item.sourceURL.path: item.fileIdentity]
        try journal.checkpoint(report, expectedIdentities: identities)
        XCTAssertEqual(try journal.load(), [report])
        try Data("corrupted".utf8).write(to: root.appendingPathComponent("damaged.json"))
        let loaded = try journal.loadAvailable()
        XCTAssertEqual(loaded.reports, [report])
        XCTAssertEqual(loaded.unreadableEntries, ["damaged.json"])
        let changed = [item.sourceURL.path: FileIdentity(deviceID: 99, inode: 99,
            entryKind: .regularFile, creationTimeNanoseconds: nil)]
        XCTAssertThrowsError(try journal.checkpoint(report, expectedIdentities: changed))
        XCTAssertEqual(try journal.load(), [report])
    }
}

private final class JournalSwapMetadataReader: ReadOnlyFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var state: FixtureMetadataState
    init(state: FixtureMetadataState) { self.state = state }
    func replace(with state: FixtureMetadataState) { lock.withLock { self.state = state } }
    func snapshot(at url: URL) throws -> FileSnapshot {
        switch lock.withLock({ state }) {
        case .snapshot(let snapshot): return snapshot
        case .error(let error): throw error
        }
    }
    func children(of directory: URL) throws -> [URL] { [] }
}

private final class FailingJournalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var saved: [CleanReport] = []
    private let failAt: Int
    init(failAt: Int) { self.failAt = failAt }
    var reports: [CleanReport] { lock.withLock { saved } }
    func record(_ report: CleanReport) throws {
        try lock.withLock {
            count += 1
            if count >= failAt { throw CocoaError(.fileWriteOutOfSpace) }
            saved.append(report)
        }
    }
}

private final class N6RefusingDigestReader: CleanupContentDigestReading, @unchecked Sendable {
    let failingPath: String
    let failOnCall: Int
    let error: FileContentReadError
    let digest: Data
    private let lock = NSLock()
    private var calls = 0
    init(failingPath: String, failOnCall: Int, error: FileContentReadError, digest: Data) {
        self.failingPath = failingPath; self.failOnCall = failOnCall; self.error = error; self.digest = digest
    }
    func sha256(at url: URL) throws -> Data {
        if url.path == failingPath {
            let count = lock.withLock { calls += 1; return calls }
            if count >= failOnCall { throw error }
        }
        return digest
    }
}

private struct N6BlockingDigestReader: CleanupContentDigestReading {
    let gate: ContentReadGate
    private let pool = FileContentReadPool(maximumReaders: 1)
    init(gate: ContentReadGate) { self.gate = gate }
    func sha256(at url: URL) throws -> Data {
        try pool.read(timeout: 10) { control in
            gate.block()
            try control.check()
            return Data(repeating: 0xAB, count: 32)
        }
    }
}
