import FanControlShared
import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacMiniModeProtocolTests: XCTestCase {
    func testNewRequestsHaveOnlyTheirOwnPayloadAndRoundTrip() throws {
        for request in [FanControlHelperRequest.readMacMiniMode, .setMacMiniMode(.off), .setMacMiniMode(.whenOnAC)] {
            let encoded = try JSONEncoder().encode(request)
            let decoded = try JSONDecoder().decode(FanControlHelperRequest.self, from: encoded)
            XCTAssertEqual(decoded.protocolVersion, 4)
            XCTAssertEqual(decoded.operation, request.operation)
            XCTAssertEqual(decoded.macMiniMode, request.macMiniMode)
            XCTAssertTrue(decoded.targetRPMByFan.isEmpty)
            XCTAssertTrue(decoded.automaticFanIDs.isEmpty)
            XCTAssertFalse(decoded.allowsRPMDecrease)
            XCTAssertEqual(decoded.watchdogSeconds, 0)
            XCTAssertNil(decoded.powerModeSource)
            XCTAssertNil(decoded.powerModeSetting)
            XCTAssertNil(decoded.powerModeValue)
            XCTAssertNil(decoded.curveProfile)
            XCTAssertNil(decoded.curveLeaseID)
        }
    }

    func testHelperContractRefusesOldFutureAndMissingVersions() {
        XCTAssertTrue(HardwareControlProtocol.accepts(4))
        for version in [nil, 1, 2, 3, 5, -1] as [Int?] {
            XCTAssertFalse(HardwareControlProtocol.accepts(version))
        }
    }

    func testAppRejectsOldHelperBeforeAcceptingMacMiniState() {
        let request = FanControlHelperRequest.setMacMiniMode(.whenOnAC)
        let reply = FanControlHelperReply(protocolVersion: 2, operation: .setMacMiniMode,
                                          success: true, message: "old", appliedTargetRPMByFan: [:])
        XCTAssertThrowsError(try reply.validated(for: request)) { error in
            XCTAssertEqual(error as? FanControlHelperProtocolError, .unsupportedProtocolVersion(2))
        }
    }

    func testVersion2CompatibilityIsLimitedToEmptyAutomaticRestore() throws {
        let reply = FanControlHelperReply(protocolVersion: 2, operation: .restoreAutomatic,
                                          success: true, message: "restored", appliedTargetRPMByFan: [:])
        XCTAssertNoThrow(try reply.validated(for: .restoreAutomaticForVersion2))
        XCTAssertThrowsError(try reply.validated(for: .restoreAutomatic))
        let contaminated = FanControlHelperRequest(protocolVersion: 2, operation: .restoreAutomatic,
            targetRPMByFan: [0: 3000], automaticFanIDs: [], allowsRPMDecrease: false,
            watchdogSeconds: 0, powerModeSource: nil, powerModeSetting: nil, powerModeValue: nil)
        XCTAssertFalse(contaminated.isVersion2RestoreOnly)
        XCTAssertThrowsError(try reply.validated(for: contaminated))
    }

    func testSuccessfulMacMiniReplyMustIncludeState() {
        let reply = FanControlHelperReply(operation: .readMacMiniMode, success: true,
                                          message: "optimistic", appliedTargetRPMByFan: [:])
        XCTAssertThrowsError(try reply.validated(for: .readMacMiniMode)) { error in
            XCTAssertEqual(error as? FanControlHelperProtocolError, .missingMacMiniModeStatus)
        }
    }

    func testSetReplyCannotConfirmTheWrongMode() {
        let status = MacMiniModeStatus(state: MacMiniPersistedState(), readings: readings)
        let reply = FanControlHelperReply(operation: .setMacMiniMode, success: true,
            message: "wrong mode", appliedTargetRPMByFan: [:], macMiniModeStatus: status)
        XCTAssertThrowsError(try reply.validated(for: .setMacMiniMode(.whenOnAC))) { error in
            XCTAssertEqual(error as? FanControlHelperProtocolError, .macMiniModeMismatch)
        }
    }

    func testStateAndRecoveryOwnerRoundTripWithoutInventingUnknownReadings() throws {
        let status = MacMiniModeStatus(
            state: MacMiniPersistedState(mode: .whenOnAC, ownsSleepDisabled: true),
            readings: readings, failure: .verificationFailed
        )
        let reply = FanControlHelperReply(operation: .readMacMiniMode, success: false,
            message: "unconfirmed", appliedTargetRPMByFan: [:], errorCode: .macMiniModeVerificationFailed,
            macMiniModeStatus: status)
        let decoded = try JSONDecoder().decode(FanControlHelperReply.self, from: JSONEncoder().encode(reply))
        XCTAssertEqual(decoded, reply)
        XCTAssertNil(decoded.macMiniModeStatus?.readings.clamshellClosed)
        XCTAssertEqual(decoded.macMiniModeStatus?.settingOwner, .helper)
    }

    private var readings: MacMiniSystemReadings {
        MacMiniSystemReadings(powerSource: .ac, sleepDisabled: false, clamshellClosed: nil, clamshellCausesSleep: nil)
    }
}
