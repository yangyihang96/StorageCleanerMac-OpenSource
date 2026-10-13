import XCTest
@testable import StorageCleanerMac

final class ScanPresentationStateTests: XCTestCase {
    func testOneSessionDrivesTheFullPresentationProgression() {
        let sessionID = UUID()
        var presentation = ScanPresentation()

        presentation.begin(sessionID: sessionID)
        XCTAssertEqual(presentation.sessionID, sessionID)
        XCTAssertEqual(presentation.state, .preparing)

        for state: SmartScanPresentationState in [
            .scanning,
            .finalizing,
            .results,
            .verifying,
            .confirming,
            .cleaning,
            .cancelling,
            .cancelled
        ] {
            XCTAssertTrue(presentation.transition(to: state, matching: sessionID))
            XCTAssertEqual(presentation.state, state)
        }
        XCTAssertTrue(presentation.state.isTerminal)
    }

    func testStaleSessionCannotOverwriteNewerPresentation() {
        let staleSessionID = UUID()
        let currentSessionID = UUID()
        var presentation = ScanPresentation()

        presentation.begin(sessionID: staleSessionID)
        presentation.begin(sessionID: currentSessionID)

        XCTAssertFalse(presentation.transition(to: .completed, matching: staleSessionID))
        XCTAssertEqual(presentation.sessionID, currentSessionID)
        XCTAssertEqual(presentation.state, .preparing)
        XCTAssertTrue(presentation.transition(to: .failed, matching: currentSessionID))
        XCTAssertEqual(presentation.state, .failed)
    }

    func testResetDropsTheTokenOnlyAfterATerminalState() {
        let sessionID = UUID()
        var presentation = ScanPresentation()

        presentation.begin(sessionID: sessionID)
        XCTAssertFalse(presentation.state.isTerminal)
        XCTAssertTrue(presentation.transition(to: .failed, matching: sessionID))
        XCTAssertTrue(presentation.state.isTerminal)

        presentation.reset()
        XCTAssertNil(presentation.sessionID)
        XCTAssertEqual(presentation.state, .idle)
    }

    /// Live test 2026-10-06: "完成" on a cleanup result returns to the
    /// results of the same scan. Only a terminal state of the same session
    /// can do this, and the transition table itself stays strict.
    func testOnlyATerminalStateOfTheSameSessionReturnsToResults() {
        let sessionID = UUID()
        var presentation = ScanPresentation()
        presentation.begin(sessionID: sessionID)
        for state: SmartScanPresentationState in [.scanning, .finalizing, .results, .verifying, .confirming] {
            XCTAssertTrue(presentation.transition(to: state, matching: sessionID))
            XCTAssertFalse(presentation.returnToResults(matching: sessionID), "\(state) is not terminal")
            XCTAssertEqual(presentation.state, state)
        }
        XCTAssertTrue(presentation.transition(to: .cleaning, matching: sessionID))
        XCTAssertTrue(presentation.transition(to: .verifying, matching: sessionID))
        XCTAssertTrue(presentation.transition(to: .completed, matching: sessionID))

        XCTAssertFalse(presentation.returnToResults(matching: UUID()), "Another session cannot return")
        XCTAssertEqual(presentation.state, .completed)
        XCTAssertTrue(presentation.returnToResults(matching: sessionID))
        XCTAssertEqual(presentation.state, .results)
        XCTAssertEqual(presentation.sessionID, sessionID)
        XCTAssertFalse(SmartScanPresentationState.results.canTransition(to: .cleaning))

        for terminal: SmartScanPresentationState in [.completed, .failed, .cancelled] {
            XCTAssertFalse(terminal.canTransition(to: .results), "Only returnToResults leaves \(terminal)")
        }
        var cancelled = ScanPresentation()
        cancelled.begin(sessionID: sessionID)
        XCTAssertTrue(cancelled.transition(to: .cancelled, matching: sessionID))
        XCTAssertTrue(cancelled.returnToResults(matching: sessionID))
    }

    func testTransitionTableRejectsSkippedSafetySteps() {
        XCTAssertFalse(SmartScanPresentationState.preparing.canTransition(to: .completed))
        XCTAssertFalse(SmartScanPresentationState.results.canTransition(to: .cleaning))
        XCTAssertTrue(SmartScanPresentationState.confirming.canTransition(to: .cleaning))
        XCTAssertTrue(SmartScanPresentationState.cleaning.canTransition(to: .verifying))
        XCTAssertTrue(SmartScanPresentationState.verifying.canTransition(to: .completed))
        XCTAssertTrue(SmartScanPresentationState.preparing.canTransition(to: .cancelling))
        XCTAssertTrue(SmartScanPresentationState.scanning.canTransition(to: .cancelling))
        XCTAssertTrue(SmartScanPresentationState.cancelling.canTransition(to: .cancelled))
    }

    func testCleanupCompletionAlwaysPassesThroughVerification() {
        let sessionID = UUID()
        var presentation = ScanPresentation()

        presentation.begin(sessionID: sessionID)
        for state: SmartScanPresentationState in [
            .scanning,
            .finalizing,
            .results,
            .verifying,
            .confirming,
            .cleaning,
            .verifying,
            .completed
        ] {
            XCTAssertTrue(presentation.transition(to: state, matching: sessionID))
        }
        XCTAssertEqual(presentation.state, .completed)
    }

    func testOnlyScanAndCancellationStatesUseTheExistingProgressPage() {
        XCTAssertTrue(SmartScanPresentationState.preparing.showsProgressPage)
        XCTAssertTrue(SmartScanPresentationState.scanning.showsProgressPage)
        XCTAssertTrue(SmartScanPresentationState.finalizing.showsProgressPage)
        XCTAssertTrue(SmartScanPresentationState.cancelling.showsProgressPage)
        XCTAssertFalse(SmartScanPresentationState.verifying.showsProgressPage)
        XCTAssertFalse(SmartScanPresentationState.cleaning.showsProgressPage)
    }
}
