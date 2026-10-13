import XCTest
@testable import StorageCleanerMac

final class ComputerHealthSecurityScoringTests: XCTestCase {
    func testSecurityEnabledDisabledUnknownUnreadableAndConversionDoNotChangeDeviceScore() {
        let baseline = evaluation(ComputerHealthSecurityFixture.snapshot(securityState: nil))
        XCTAssertEqual(baseline.score, 100)
        XCTAssertEqual(baseline.coverage, 1)
        XCTAssertEqual(baseline.status, .healthy)
        for state: SystemProtectionState in [.enabled, .disabled, .unknown, .unreadable, .transitioning] {
            XCTAssertEqual(evaluation(ComputerHealthSecurityFixture.snapshot(securityState: state)), baseline)
        }
        XCTAssertEqual(ComputerHealthScoring.scoredFactors, [.diskReliability, .capacity, .stability, .battery])
        XCTAssertEqual(ComputerHealthScoring.modelVersion, "computer-health-v2")
    }

    func testSecurityCannotMaskFailingSMARTOrRaiseItsScore() {
        for state: SystemProtectionState in [.enabled, .disabled, .unreadable] {
            let value = evaluation(ComputerHealthSecurityFixture.snapshot(securityState: state, smart: .failing))
            XCTAssertEqual(value.status, .actionRequired)
            XCTAssertLessThanOrEqual(value.score ?? 100, 20)
        }
    }

    func testEventHistoryIsNotScoringEvidence() {
        let event = ComputerHealthChangeEvent(id: UUID(), recordedAt: ComputerHealthSecurityFixture.date,
            check: .fileVault, oldState: .enabled, newState: .disabled, evidenceSummary: "Fixture")
        XCTAssertEqual(evaluation(ComputerHealthSecurityFixture.snapshot(changes: [event])),
            evaluation(ComputerHealthSecurityFixture.snapshot()))
    }

    private func evaluation(_ snapshot: ComputerHealthSnapshot) -> ComputerHealthEvaluation {
        ComputerHealthScoring.evaluate(snapshot: snapshot, referenceDate: ComputerHealthSecurityFixture.date)
    }
}
