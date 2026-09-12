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
