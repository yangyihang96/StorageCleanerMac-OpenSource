import XCTest
@testable import StorageCleanerMac

final class DebugSmartScanSessionReleaseIsolationTests: XCTestCase {
    func testFixtureAndEntryPointsAreCompileGuarded() throws {
        let fixtureSource = try source("Sources/StorageCleanerMac/Debug/DebugSmartScanSessionFixture.swift")
        let storeSource = try source("Sources/StorageCleanerMac/Stores/ScanStore.swift")
        let contentSource = try source("Sources/StorageCleanerMac/Views/ContentView.swift")

        XCTAssertTrue(fixtureSource.contains("#if DEBUG"))
        XCTAssertTrue(storeSource.contains("#if DEBUG\n    @Published private(set) var isDebugSmartScanSessionFixtureActive"))
        XCTAssertTrue(contentSource.contains("#if DEBUG\n    private var debugSmartScanSession"))
        // Review P2-2: the screenshot-only tier expansion is Debug-only too.
        let resultsSource = try source("Sources/StorageCleanerMac/Views/CleanupScanViews.swift")
        XCTAssertTrue(resultsSource.contains(
            "#if DEBUG\n        // Review screenshots of the debug fixture open the green tier."
        ))
        XCTAssertTrue(resultsSource.contains(
            "#if DEBUG\n        // Review screenshots of the debug fixture open the green groups too."
        ))
        XCTAssertTrue(resultsSource.contains(
            "#if DEBUG\n        if store.isDebugSmartScanSessionFixtureActive { return }\n#endif"
        ))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

#if DEBUG
@MainActor
final class DebugSmartScanSessionFixtureTests: XCTestCase {
    func testLaunchArgumentRequiresTheDedicatedResultsScenario() {
        XCTAssertEqual(
            DebugSmartScanSessionFixture.scenario(arguments: [
                DebugSmartScanSessionFixture.launchArgument,
                "results",
            ]),
            .results
        )
        XCTAssertNil(DebugSmartScanSessionFixture.scenario(arguments: [
            "--debug-scan-demo",
            "results",
        ]))
        XCTAssertNil(DebugSmartScanSessionFixture.scenario(arguments: [
            DebugSmartScanSessionFixture.launchArgument,
            "unknown",
        ]))
    }

    func testFixtureContainsDeterministicSafeReviewAndProtectedCandidates() {
        let session = DebugSmartScanSessionFixture.session
        let candidates = session.candidates

        XCTAssertEqual(session.id, DebugSmartScanSessionFixture.sessionID)
        XCTAssertEqual(session.metrics.candidateCount, 4)
        XCTAssertEqual(session.metrics.completeMeasurementCandidateCount, 4)
        XCTAssertEqual(candidates.filter { $0.risk == .safe }.count, 2)
        XCTAssertEqual(candidates.filter { $0.risk == .reviewOnly }.count, 1)
        XCTAssertEqual(candidates.filter { $0.risk == .protected }.count, 1)
        XCTAssertTrue(candidates.filter { $0.risk == .protected }.allSatisfy {
            $0.isSelectable
                && $0.defaultSelection == .unselected
                && $0.action == .moveToTrashAfterProtectedReview
        })
        XCTAssertTrue(candidates.allSatisfy {
            $0.sourceURL.path.hasPrefix("/DebugFixture/")
                || $0.sourceURL.path == "/Applications/Example Beta.app"
        })
        // D47: both green rows are preselected; yellow and red are not.
        let selected = DebugSmartScanSessionFixture.selection.selectedCandidates(in: session)
        XCTAssertEqual(selected.count, 2)
        XCTAssertTrue(selected.allSatisfy { $0.risk == .safe })
        XCTAssertEqual(Set(selected.map(\.id)), Set(candidates.filter { $0.risk == .safe }.map(\.id)))
        XCTAssertEqual(
            candidates.first { $0.risk == .reviewOnly }?.selectionEligibility,
            .selectableWithReview
        )
    }

    /// Review P2-2: the D47 example rows for the results-page screenshots — a
    /// cache whose app is unknown, one whose app is running, a large cache
    /// and a recently written log — are added only with their launch
    /// argument, so the default fixture stays as it was.
    func testD47ExampleRowsCoverEachPreselectionCase() throws {
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains(DebugSmartScanSessionFixture.d47RowsArgument))
        XCTAssertEqual(DebugSmartScanSessionFixture.session.metrics.candidateCount, 4,
                       "Without the argument the fixture is unchanged")

        let session = DebugSmartScanSessionFixture.makeSession(includesD47Rows: true)
        let candidates = session.candidates
        XCTAssertEqual(candidates.count, 8)
        XCTAssertEqual(session.metrics.candidateCount, candidates.count)
        XCTAssertEqual(session.metrics.completeMeasurementCandidateCount, candidates.count)
        XCTAssertEqual(session.metrics.estimatedCandidateBytes,
                       candidates.reduce(0) { $0 + $1.estimatedSizeBytes })
        XCTAssertTrue(candidates.allSatisfy {
            $0.sourceURL.path.hasPrefix("/DebugFixture/")
                || $0.sourceURL.path == "/Applications/Example Beta.app"
        })

        let unknownOwner = try XCTUnwrap(candidates.first { $0.ownerResolution == .unresolved })
        let runningOwner = try XCTUnwrap(candidates.first(where: \.isOwnerRunning))
        let largeCache = try XCTUnwrap(candidates.first { CleanupRebuildCostPolicy.showsHint(for: $0) })
        let recentLog = try XCTUnwrap(candidates.first { $0.logWriteState == .recent })
        for row in [unknownOwner, runningOwner, largeCache, recentLog] {
            XCTAssertEqual(row.risk, .safe)
            XCTAssertEqual(row.selectionEligibility, .selectable)
        }
        XCTAssertEqual(Set([unknownOwner.id, runningOwner.id, largeCache.id, recentLog.id]).count, 4)

        // D47: every green row is preselected except the one whose app runs.
        let selected = CleanupSelection.defaults(in: session).selectedCandidateIDs
        XCTAssertEqual(selected, Set(candidates.filter { $0.risk == .safe && !$0.isOwnerRunning }.map(\.id)))
        XCTAssertFalse(selected.contains(runningOwner.id))

        XCTAssertEqual(CleanupCandidateRowHint.ownerStatus(for: unknownOwner)?.tone, .warning)
        XCTAssertEqual(CleanupCandidateRowHint.ownerStatus(for: recentLog)?.tone, .warning)
        XCTAssertNotNil(CleanupCandidateRowHint.rebuildCost(for: largeCache))
        XCTAssertNil(CleanupCandidateRowHint.ownerStatus(for: largeCache))
        XCTAssertNil(CleanupCandidateRowHint.rebuildCost(for: unknownOwner))
    }

    func testInstalledFixtureRendersResultsStateButCannotStartOrExecuteCleanup() throws {
        let store = try ScanStore.makeForTests(for: self)
        store.installDebugSmartScanSessionFixture(.results)

        XCTAssertTrue(store.isDebugSmartScanSessionFixtureActive)
        XCTAssertEqual(store.scanPresentationState, .results)
        XCTAssertEqual(store.cleanupWorkflowState, .results(sessionID: DebugSmartScanSessionFixture.sessionID))
        XCTAssertEqual(store.cleanupScanSession?.id, DebugSmartScanSessionFixture.sessionID)
        XCTAssertTrue(store.canEditV2CleanupSelection)
        XCTAssertFalse(store.canRequestV2Cleanup)

        if let candidateID = store.cleanupScanSession?.candidates.first(where: \.isSelectable)?.id {
            store.setCleanupCandidate(candidateID, selected: true)
            XCTAssertTrue(store.cleanupSelection.selectedCandidateIDs.contains(candidateID))
        } else {
            XCTFail("Fixture should contain a selectable candidate")
        }

        store.startScanRespectingAccessGuide()
        store.requestV2Cleanup(disposition: .trash)
        store.confirmV2Cleanup()

        XCTAssertFalse(store.isScanning)
        XCTAssertNil(store.pendingCleanPlan)
        XCTAssertEqual(store.scanPresentationState, .results)
        XCTAssertEqual(store.cleanupWorkflowState, .results(sessionID: DebugSmartScanSessionFixture.sessionID))
    }
}
#endif
