import FanControlShared
import XCTest
@testable import StorageCleanerMac

final class FanControlStartupSafetyTests: XCTestCase {
    func testRecoveryFailureTerminatesMacMiniBeforeReportingAndRejectsAllWork() {
        let startup = FanControlStartupSafety()
        var events: [String] = []
        var disabled = true
        var commands: [MacMiniPMSetCommand] = []
        var saved: [MacMiniPersistedState] = []
        let engine = MacMiniModeEngine(state: .init(mode: .whenOnAC, ownsSleepDisabled: true),
            read: { .init(powerSource: .ac, sleepDisabled: disabled, clamshellClosed: true, clamshellCausesSleep: true) },
            execute: { command in
                commands.append(command)
                if case .disableSleep(let value) = command { disabled = value }
                return true
            }, persist: { saved.append($0) })
        let state = startup.start(recoverFans: {
            events.append("fan-recovery-failed")
            return false
        }, prepareMacMiniForTermination: {
            events.append("mac-mini-termination")
            XCTAssertEqual(startup.state, .recovering)
            XCTAssertFalse(startup.dispatch(execute: { XCTFail("No write during termination"); return true },
                reject: { _ in false }))
            _ = engine.prepareForTermination()
        })
        XCTAssertEqual(state, .recoveryFailed)
        XCTAssertEqual(commands, [.disableSleep(false)], "Closed lid termination must not request sleep")
        XCTAssertEqual(saved.last?.mode, .whenOnAC)
        XCTAssertFalse(engine.state.ownsSleepDisabled)
        XCTAssertFalse(startup.startNormalWork { events.append("normal-start") })
        var rejected: [FanControlHelperRequest.Operation] = []
        let operations: [FanControlHelperRequest.Operation] = [
            .ping, .readPowerConfiguration, .applyPowerMode, .readMacMiniMode, .setMacMiniMode,
            .apply, .renewFanControlLease, .restoreAutomatic, .validateFanCurve,
            .activateFanCurve, .updateFanCurve, .getFanCurveRuntimeState, .deactivateFanCurve,
        ]
        for operation in operations {
            let response = startup.dispatch(execute: {
                events.append("write:\(operation.rawValue)")
                return true
            }, reject: { observed in
                XCTAssertEqual(observed, .recoveryFailed)
                rejected.append(operation)
                return false
            })
            XCTAssertFalse(response, "Rejected before any executor: \(operation)")
        }
        XCTAssertEqual(rejected, operations)
        events.append("fault-reported")
        XCTAssertEqual(events, ["fan-recovery-failed", "mac-mini-termination", "fault-reported"])
    }

    func testSleepRecoveryWhitelistRejectsFanOperationsModeOnAndExtraPayload() {
        XCTAssertTrue(FanControlStartupSafety.permitsSleepRecovery(operation: "readMacMiniMode", mode: nil, hasEmptyPayload: true))
        XCTAssertTrue(FanControlStartupSafety.permitsSleepRecovery(operation: "setMacMiniMode", mode: .off, hasEmptyPayload: true))
        XCTAssertFalse(FanControlStartupSafety.permitsSleepRecovery(operation: "setMacMiniMode", mode: .whenOnAC, hasEmptyPayload: true))
        for operation in ["ping", "apply", "renewFanControlLease", "restoreAutomatic", "validateFanCurve",
                          "activateFanCurve", "updateFanCurve", "getFanCurveRuntimeState", "deactivateFanCurve", "applyPowerMode"] {
            XCTAssertFalse(FanControlStartupSafety.permitsSleepRecovery(operation: operation, mode: nil, hasEmptyPayload: true))
        }
        XCTAssertFalse(FanControlStartupSafety.permitsSleepRecovery(operation: "setMacMiniMode", mode: .off, hasEmptyPayload: false))
        XCTAssertFalse(FanControlStartupSafety.permitsSleepRecovery(operation: "readMacMiniMode", mode: .whenOnAC, hasEmptyPayload: true))
    }

    func testFailedHelperAllowsOnlySeparateSleepRecoveryExecutor() {
        let startup = FanControlStartupSafety()
        var normalCalls = 0
        var recoveryCalls = 0
        XCTAssertFalse(startup.dispatchSleepRecovery(recover: { recoveryCalls += 1; return true }, reject: { _ in false }))
        _ = startup.start(recoverFans: { false }, prepareMacMiniForTermination: {
            XCTAssertFalse(startup.dispatchSleepRecovery(recover: { recoveryCalls += 1; return true }, reject: { _ in false }))
        })
        XCTAssertTrue(startup.dispatchSleepRecovery(recover: { recoveryCalls += 1; return true }, reject: { _ in false }))
        XCTAssertFalse(startup.dispatch(execute: { normalCalls += 1; return true }, reject: { _ in false }))
        XCTAssertEqual(recoveryCalls, 1)
        XCTAssertEqual(normalCalls, 0)
        XCTAssertEqual(startup.state, .recoveryFailed)
        XCTAssertFalse(startup.startNormalWork { XCTFail("Sleep recovery cannot restart fans") })
    }

    func testFaultSleepRecoveryRetriesOnlyOwnZeroWithoutStartingFans() {
        let startup = FanControlStartupSafety()
        var allowsRestore = false
        var disabled = true
        var commands: [MacMiniPMSetCommand] = []
        let engine = MacMiniModeEngine(state: .init(mode: .whenOnAC, ownsSleepDisabled: true),
            read: { .init(powerSource: .ac, sleepDisabled: disabled, clamshellClosed: true, clamshellCausesSleep: true) },
            execute: { command in
                commands.append(command)
                guard allowsRestore else { return false }
                if case .disableSleep(let value) = command { disabled = value }
                return true
            }, persist: { _ in })
        _ = startup.start(recoverFans: { false }, prepareMacMiniForTermination: { _ = engine.prepareForTermination() })
        XCTAssertTrue(engine.state.ownsSleepDisabled)
        allowsRestore = true
        let recovered = startup.dispatchSleepRecovery(recover: {
            let status = engine.disableForRemoval()
            return status.mode == .off && !status.ownsSleepDisabled && status.failure == nil
        }, reject: { _ in false })
        XCTAssertTrue(recovered)
        XCTAssertEqual(commands, [.disableSleep(false), .disableSleep(false)])
        XCTAssertFalse(startup.dispatch(execute: { XCTFail("Sleep recovery cannot admit a fan write"); return true }, reject: { _ in false }))
        XCTAssertEqual(startup.state, .recoveryFailed)
    }

    func testSuccessfulRecoveryAloneStartsNormalWorkAndAcceptsDispatch() {
        let startup = FanControlStartupSafety()
        var events: [String] = []
        XCTAssertEqual(startup.start(recoverFans: { events.append("verified-recovery"); return true },
            prepareMacMiniForTermination: { XCTFail("Successful recovery must not terminate the mode") }), .ready)
        XCTAssertTrue(startup.startNormalWork { events.append("normal-start") })
        XCTAssertTrue(startup.dispatch(execute: { events.append("fan-write"); return true }, reject: { _ in false }))
        XCTAssertEqual(events, ["verified-recovery", "normal-start", "fan-write"])
        XCTAssertTrue(startup.requiresResidentHelper(macMiniRequested: true))
    }

    func testFailedProcessCannotBecomeReadyThroughAnotherStart() {
        let startup = FanControlStartupSafety()
        var recoveries = 0
        var terminations = 0
        _ = startup.start(recoverFans: { recoveries += 1; return false },
            prepareMacMiniForTermination: { terminations += 1 })
        XCTAssertEqual(startup.start(recoverFans: { recoveries += 1; return true },
            prepareMacMiniForTermination: { terminations += 1 }), .recoveryFailed)
        XCTAssertEqual(recoveries, 1)
        XCTAssertEqual(terminations, 1)
        XCTAssertFalse(startup.isReady)
        let nextProcess = FanControlStartupSafety()
        XCTAssertEqual(nextProcess.start(recoverFans: { true }, prepareMacMiniForTermination: {}), .ready)
    }

    func testUnverifiedStartupCannotDispatchOrStartBackgroundWork() {
        let startup = FanControlStartupSafety()
        XCTAssertFalse(startup.startNormalWork { XCTFail("Background work before recovery") })
        XCTAssertFalse(startup.dispatch(execute: { XCTFail("Fan write before recovery"); return true }, reject: { state in
            XCTAssertEqual(state, .awaitingRecovery)
            return false
        }))
        _ = startup.start(recoverFans: {
            XCTAssertFalse(startup.dispatch(execute: { XCTFail("Fan write during recovery"); return true }, reject: { state in
                XCTAssertEqual(state, .recovering)
                return false
            }))
            return true
        }, prepareMacMiniForTermination: {})
    }

    func testFaultReportingKeepsClientsButMayExitAfterDisconnect() {
        let startup = FanControlStartupSafety()
        _ = startup.start(recoverFans: { false }, prepareMacMiniForTermination: {})
        let resident = startup.requiresResidentHelper(macMiniRequested: true)
        XCTAssertFalse(resident, "Do not restart the terminated Mac mini policy in a failed helper")
        XCTAssertFalse(MacMiniHelperIdlePolicy.mayExit(connectionCount: 1, pendingRequests: 0,
            hasFanWork: false, requiresResidentHelper: resident))
        XCTAssertFalse(MacMiniHelperIdlePolicy.mayExit(connectionCount: 0, pendingRequests: 1,
            hasFanWork: false, requiresResidentHelper: resident))
        XCTAssertTrue(MacMiniHelperIdlePolicy.mayExit(connectionCount: 0, pendingRequests: 0,
            hasFanWork: false, requiresResidentHelper: resident))
    }

    func testFailedSleepRestoreRetainsDebtButStillCannotStartFanWrites() {
        let startup = FanControlStartupSafety()
        var commands: [MacMiniPMSetCommand] = []
        let engine = MacMiniModeEngine(state: .init(mode: .whenOnAC, ownsSleepDisabled: true),
            read: { .init(powerSource: .ac, sleepDisabled: true, clamshellClosed: true, clamshellCausesSleep: true) },
            execute: { commands.append($0); return false }, persist: { _ in })
        _ = startup.start(recoverFans: { false }, prepareMacMiniForTermination: { _ = engine.prepareForTermination() })
        XCTAssertEqual(commands, [.disableSleep(false)])
        XCTAssertTrue(engine.state.ownsSleepDisabled)
        XCTAssertEqual(engine.status().failure, .commandFailed)
        XCTAssertFalse(startup.dispatch(execute: { XCTFail("Cannot accept fan write after failed restore"); return true },
            reject: { _ in false }))
        XCTAssertEqual(startup.state, .recoveryFailed)
    }
}
