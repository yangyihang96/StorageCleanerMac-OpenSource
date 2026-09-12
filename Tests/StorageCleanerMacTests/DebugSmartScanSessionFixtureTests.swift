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
        let selected = DebugSmartScanSessionFixture.selection.selectedCandidates(in: session)
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.recommendation.level, .recommended)
        XCTAssertFalse(selected.contains { $0.recommendation.level == .optional })
        XCTAssertEqual(
            candidates.first { $0.risk == .reviewOnly }?.selectionEligibility,
            .selectableWithReview
        )
    }

    func testInstalledFixtureRendersResultsStateButCannotStartOrExecuteCleanup() {
        let store = ScanStore()
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
