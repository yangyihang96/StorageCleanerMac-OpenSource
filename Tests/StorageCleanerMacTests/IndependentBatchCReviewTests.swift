import FanControlShared
import Foundation
import XCTest
@testable import StorageCleanerMac

final class IndependentBatchCReviewTests: XCTestCase {
    /// The helper keeps the trigger error even when restoreAllFans returns
    /// false. Its reply has no confirmation that restoration succeeded.
    func testARecoveryTriggerDoesNotProveSuccessfulAutomaticRestore() throws {
        let request = FanControlHelperRequest(
            operation: .renewFanControlLease, targetRPMByFan: [:], automaticFanIDs: [],
            allowsRPMDecrease: false, watchdogSeconds: 10,
            powerModeSource: nil, powerModeSetting: nil, powerModeValue: nil,
            curveLeaseID: UUID())
        let cases: [(FanControlHelperErrorCode, FanCurveError, FanCurveRuntimeStatus)] = [
            (.curveLeaseExpired, .curveLeaseExpired, .leaseExpired),
            (.thermalProtectionActivated, .thermalProtectionActivated, .thermalProtection),
        ]
        for (code, reason, status) in cases {
            let state = FanCurveRuntimeState(status: status, targetRPMByFan: [0: 2_400], failureReason: reason)
            let reply = try FanControlHelperReply(
                operation: request.operation, success: false, message: reason.rawValue,
                appliedTargetRPMByFan: [:], curveRuntimeState: state, errorCode: code
            ).validated(for: request)
            let record = HardwareOperationRecord.make(
                for: request, reply: reply, at: Date(timeIntervalSinceReferenceDate: 800_000_000))
            print("REVIEW_C_UNVERIFIED_RESTORE code=\(code.rawValue) outcome=\(String(describing: record?.outcome))")
            XCTAssertNotEqual(record?.outcome, .automaticRestore,
                "The trigger error also reaches the app when restoration fails; it must not certify successful recovery")
        }
    }
}
