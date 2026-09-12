import XCTest
@testable import StorageCleanerMac

#if DEBUG
final class DebugScanPresentationTests: XCTestCase {
    func testFixturesCoverEveryRequestedPresentationBoundary() {
        let required: Set<DebugScanPresentationScenario> = [
            .idle,
            .stale,
            .long,
            .fast,
            .multiStage,
            .stageSkipped,
            .stageFailed,
            .emptyResults,
            .smallResults,
            .largeResults,
            .partialSelection,
            .allSelected,
            .preflightPassed,
            .preflightWarning,
            .cleaning,
            .singleItemComplete,
            .partialFailure,
            .recoverableCompletion
        ]

        let fixtures = Set(DebugScanPresentationScenario.allCases)
        XCTAssertGreaterThanOrEqual(fixtures.count, 18)
        XCTAssertTrue(fixtures.isSuperset(of: required))
    }

    func testProgressFixturesKeepPreparationIndeterminateAndScanningFixed() {
        XCTAssertEqual(DebugScanPresentationScenario.preparing.progress.progressKind, .indeterminate)
        XCTAssertEqual(DebugScanPresentationScenario.indeterminate.progress.progressKind, .indeterminate)
        XCTAssertEqual(DebugScanPresentationScenario.determinate.progress.progressKind, .determinate)
        XCTAssertEqual(DebugScanPresentationScenario.determinate.progress(percentOverride: 0).fractionCompleted, 0)
        XCTAssertEqual(DebugScanPresentationScenario.determinate.progress(percentOverride: 100).fractionCompleted, 1)
        XCTAssertGreaterThan(DebugScanPresentationScenario.determinate.progress.fractionCompleted, 0)
        XCTAssertEqual(DebugScanPresentationScenario.long.progress.completedGroupCount, 5)
        XCTAssertEqual(DebugScanPresentationScenario.fast.terminalDetail.contains("0.24"), true)
    }

    func testResultFixturesUseRequestedFixedSizesAndSelections() {
        XCTAssertTrue(DebugScanPresentationScenario.emptyResults.isResult)
        XCTAssertEqual(DebugScanPresentationScenario.smallResults.resultMetric, "1.1 MB")
        XCTAssertEqual(DebugScanPresentationScenario.smallResults.resultByteCount, 1_100_000)
        XCTAssertEqual(DebugScanPresentationScenario.largeResults.resultMetric, "120 GB")
        XCTAssertEqual(DebugScanPresentationScenario.largeResults.resultByteCount, 120_000_000_000)
        XCTAssertEqual(DebugScanPresentationScenario.partialSelection.resultCandidateCount, 8)
        XCTAssertTrue(DebugScanPresentationScenario.partialSelection.selectionSummary?.contains("3") == true)
        XCTAssertTrue(DebugScanPresentationScenario.allSelected.selectionSummary?.contains("8") == true)
    }

    func testPreflightCleaningAndCompletionFixturesRemainPresentationOnlyStates() {
        XCTAssertEqual(DebugScanPresentationScenario.idle.presentationKind, .idle)
        XCTAssertEqual(DebugScanPresentationScenario.preflightPassed.presentationKind, .preflight)
        XCTAssertEqual(DebugScanPresentationScenario.preflightWarning.presentationKind, .preflight)
        XCTAssertTrue(DebugScanPresentationScenario.preflightWarning.isPreflightWarning)
        XCTAssertEqual(DebugScanPresentationScenario.cleaning.presentationKind, .cleaning)
        XCTAssertTrue(DebugScanPresentationScenario.singleItemComplete.isTerminal)
        XCTAssertTrue(DebugScanPresentationScenario.partialFailure.isTerminal)
        XCTAssertTrue(DebugScanPresentationScenario.recoverableCompletion.isTerminal)
    }

    func testExistingLaunchNamesAndNewFriendlyAliasesResolve() {
        XCTAssertEqual(DebugScanPresentationScenario.scenario(named: "preparing"), .preparing)
        XCTAssertEqual(DebugScanPresentationScenario.scenario(named: "largeResults"), .largeResults)
        XCTAssertEqual(DebugScanPresentationScenario.scenario(named: "not-scanned"), .idle)
        XCTAssertEqual(DebugScanPresentationScenario.scenario(named: "last-scan-expired"), .stale)
        XCTAssertEqual(DebugScanPresentationScenario.scenario(named: "slow-scan"), .long)
        XCTAssertEqual(DebugScanPresentationScenario.scenario(named: "fast-scan"), .fast)
        XCTAssertEqual(DebugScanPresentationScenario.scenario(named: "preflight-success"), .preflightPassed)
        XCTAssertEqual(DebugScanPresentationScenario.scenario(named: "recoverable-completion"), .recoverableCompletion)
        XCTAssertNil(DebugScanPresentationScenario.scenario(named: "real-scan"))
    }
}
#endif
