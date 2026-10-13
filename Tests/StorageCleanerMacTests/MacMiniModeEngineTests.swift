import FanControlShared
import XCTest

final class MacMiniModeEngineTests: XCTestCase {
    func testDecisionTableForPowerLidDisplayAndOwnership() {
        var rows = 0
        for mode in MacMiniMode.allCases {
            for power in [MacMiniPowerSource.ac, .battery] {
                for closed in [false, true] {
                    for causesSleep in [false, true] {
                        for disabled in [false, true] {
                            for owned in [false, true] {
                                let fake = FakeMacMiniSystem(
                                    mode: mode, owns: owned, power: power,
                                    disabled: disabled, closed: closed, causesSleep: causesSleep
                                )
                                let status = fake.engine.reconcile()
                                let manages = mode == .whenOnAC || owned
                                let expected = mode == .whenOnAC && power == .ac
                                let writes = manages && disabled != expected
                                var commands: [MacMiniPMSetCommand] = writes ? [.disableSleep(expected)] : []
                                if writes && !expected && closed && causesSleep { commands.append(.sleepNow) }
                                let context = "\(mode)/\(power)/lid=\(closed)/causes=\(causesSleep)/disabled=\(disabled)/owned=\(owned)"
                                XCTAssertEqual(fake.commands, commands, context)
                                XCTAssertEqual(status.readings.sleepDisabled, manages ? expected : disabled, context)
                                XCTAssertNil(status.failure, context)
                                rows += 1
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(rows, 64)
    }

    func testUnpluggedClosedLidRequestsSleepAfterVerifiedRestore() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC)
        XCTAssertNil(fake.engine.reconcile().failure)
        fake.readings.powerSource = .battery
        fake.readings.clamshellClosed = true
        _ = fake.engine.reconcile()
        XCTAssertEqual(fake.commands, [.disableSleep(true), .disableSleep(false), .sleepNow])
        XCTAssertEqual(Array(fake.events.suffix(5)), ["write:0", "read:false", "save:whenOnAC:false", "sleep", "read:false"])
        XCTAssertFalse(fake.engine.state.ownsSleepDisabled)
    }

    func testExternalDisplayAndUnknownLidNeverRequestSleep() {
        for causes in [false, nil] as [Bool?] {
            let fake = FakeMacMiniSystem(mode: .whenOnAC, owns: true, power: .battery, disabled: true,
                                         closed: true, causesSleep: causes)
            _ = fake.engine.reconcile()
            XCTAssertEqual(fake.commands, [.disableSleep(false)])
        }
        let fake = FakeMacMiniSystem(mode: .whenOnAC, owns: true, power: .battery, disabled: true,
                                     closed: nil, causesSleep: true)
        _ = fake.engine.reconcile()
        XCTAssertEqual(fake.commands, [.disableSleep(false)])
    }

    func testSleepUsesFreshLidReadbackNotTheEarlierSnapshot() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC, owns: true, power: .battery, disabled: true,
                                     closed: true, causesSleep: true)
        fake.afterWrite = { [weak fake] in fake?.readings.clamshellCausesSleep = false }
        _ = fake.engine.reconcile()
        XCTAssertEqual(fake.commands, [.disableSleep(false)])
    }

    func testOffPreservesExternallyDisabledSleep() {
        let fake = FakeMacMiniSystem(disabled: true, closed: true)
        _ = fake.engine.setMode(.off)
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertEqual(fake.engine.status().settingOwner, .externalOrUnknown)
        XCTAssertEqual(fake.readings.sleepDisabled, true)
    }

    func testOffRestoresOnlyOurRecoveryObligation() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC, owns: true, disabled: true)
        let status = fake.engine.setMode(.off)
        XCTAssertEqual(fake.commands, [.disableSleep(false)])
        XCTAssertEqual(status.mode, .off)
        XCTAssertFalse(status.ownsSleepDisabled)
        XCTAssertFalse(fake.engine.state.requiresResidentHelper)
    }

    func testAlreadyDisabledExternalSettingIsNotClaimedOnAC() {
        let fake = FakeMacMiniSystem(disabled: true)
        _ = fake.engine.setMode(.whenOnAC)
        XCTAssertFalse(fake.engine.state.ownsSleepDisabled)
        _ = fake.engine.setMode(.off)
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertEqual(fake.readings.sleepDisabled, true)
    }

    func testEnabledPolicyCorrectsExternalDriftBothWays() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC)
        _ = fake.engine.reconcile()
        fake.readings.sleepDisabled = false
        _ = fake.engine.reconcile()
        fake.readings.powerSource = .battery
        _ = fake.engine.reconcile()
        fake.readings.sleepDisabled = true
        _ = fake.engine.reconcile()
        XCTAssertEqual(fake.commands, [.disableSleep(true), .disableSleep(true), .disableSleep(false), .disableSleep(false)])
    }

    func testTerminationRestoresOursAndPreservesRequestedMode() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC, owns: true, disabled: true, closed: true)
        let status = fake.engine.prepareForTermination()
        XCTAssertEqual(fake.commands, [.disableSleep(false)])
        XCTAssertEqual(status.mode, .whenOnAC)
        XCTAssertFalse(status.ownsSleepDisabled)
        XCTAssertTrue(fake.engine.state.requiresResidentHelper)
        XCTAssertEqual(fake.savedStates.last?.mode, .whenOnAC)
    }

    func testTerminationLeavesExternalSleepSettingAlone() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC, disabled: true)
        _ = fake.engine.prepareForTermination()
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertEqual(fake.readings.sleepDisabled, true)
    }

    func testPersistedPolicyReconcilesAfterRelaunch() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC, owns: true, power: .battery, disabled: true)
        _ = fake.engine.reconcile()
        XCTAssertEqual(fake.commands, [.disableSleep(false)])
        XCTAssertTrue(fake.engine.state.requiresResidentHelper)
        let cleanOff = FakeMacMiniSystem()
        _ = cleanOff.engine.reconcile()
        XCTAssertTrue(cleanOff.commands.isEmpty)
        XCTAssertFalse(cleanOff.engine.state.requiresResidentHelper)
    }

    func testReinstallationDropsOldModeButKeepsRecoveryObligation() {
        let old = MacMiniPersistedState(mode: .whenOnAC, ownsSleepDisabled: true)
        XCTAssertEqual(old.boundToApplication(isSameInstallation: true), old)
        let replacement = old.boundToApplication(isSameInstallation: false)
        XCTAssertEqual(replacement.mode, .off)
        XCTAssertTrue(replacement.ownsSleepDisabled)
        let fake = FakeMacMiniSystem(mode: replacement.mode, owns: replacement.ownsSleepDisabled, disabled: true)
        XCTAssertNil(fake.engine.reconcile().failure)
        XCTAssertEqual(fake.commands, [.disableSleep(false)])
        XCTAssertFalse(fake.engine.state.requiresResidentHelper)
    }

    func testRecoveryJournalPrecedesEnablingWrite() {
        let fake = FakeMacMiniSystem()
        _ = fake.engine.setMode(.whenOnAC)
        let saved = fake.events.firstIndex(of: "save:whenOnAC:true")
        let write = fake.events.firstIndex(of: "write:1")
        XCTAssertNotNil(saved)
        XCTAssertNotNil(write)
        if let saved, let write { XCTAssertLessThan(saved, write) }
    }

    func testFailedJournalPreventsEnablingWrite() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC)
        fake.persistenceFails = true
        let status = fake.engine.reconcile()
        XCTAssertEqual(status.failure, .persistenceFailed)
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertFalse(fake.engine.state.ownsSleepDisabled)
    }

    func testFailedModeSaveDoesNotChangeAcceptedMode() {
        let fake = FakeMacMiniSystem()
        fake.persistenceFails = true
        let status = fake.engine.setMode(.whenOnAC)
        XCTAssertEqual(status.mode, .off)
        XCTAssertEqual(status.failure, .persistenceFailed)
        XCTAssertTrue(fake.commands.isEmpty)
    }

    func testFailedReadbackRetainsRecoveryAndDoesNotSleep() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC, owns: true, power: .battery, disabled: true,
                                     closed: true, causesSleep: true)
        fake.writesTakeEffect = false
        let status = fake.engine.reconcile()
        XCTAssertEqual(status.failure, .verificationFailed)
        XCTAssertTrue(status.ownsSleepDisabled)
        XCTAssertEqual(fake.commands, [.disableSleep(false)])
    }

    func testFailedCommandKeepsRecoveryForTheNextTick() {
        let fake = FakeMacMiniSystem(mode: .off, owns: true, disabled: true)
        fake.commandSucceeds = false
        XCTAssertEqual(fake.engine.reconcile().failure, .commandFailed)
        XCTAssertTrue(fake.engine.state.ownsSleepDisabled)
        fake.commandSucceeds = true
        XCTAssertNil(fake.engine.reconcile().failure)
        XCTAssertFalse(fake.engine.state.ownsSleepDisabled)
    }

    func testUnknownPowerRestoresOurSettingWithoutGuessingAC() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC, owns: true, power: .unknown, disabled: true, closed: true)
        XCTAssertEqual(fake.engine.reconcile().failure, .stateUnavailable)
        XCTAssertEqual(fake.commands, [.disableSleep(false)])
        let external = FakeMacMiniSystem(mode: .whenOnAC, power: .unknown, disabled: true)
        _ = external.engine.reconcile()
        XCTAssertTrue(external.commands.isEmpty)
    }

    func testUnknownSleepValueCannotEnableButOwnedRecoveryAttemptsZero() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC, disabled: nil)
        XCTAssertEqual(fake.engine.reconcile().failure, .stateUnavailable)
        XCTAssertTrue(fake.commands.isEmpty)
        let recovery = FakeMacMiniSystem(owns: true, disabled: nil)
        XCTAssertNil(recovery.engine.reconcile().failure)
        XCTAssertEqual(recovery.commands, [.disableSleep(false)])
    }

    func testRepeatedBatteryTicksDoNotIssueRepeatedSleepRequests() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC, owns: true, power: .battery, disabled: true,
                                     closed: true, causesSleep: true)
        _ = fake.engine.reconcile()
        _ = fake.engine.reconcile()
        XCTAssertEqual(fake.commands, [.disableSleep(false), .sleepNow])
    }

    func testUnknownPreviousSleepValueDoesNotCountAsAnEnabledToOffTransition() {
        let fake = FakeMacMiniSystem(owns: true, disabled: nil, closed: true, causesSleep: true)
        XCTAssertNil(fake.engine.reconcile().failure)
        XCTAssertEqual(fake.commands, [.disableSleep(false)])
    }

    func testFailedSleepRequestReportsPartialSuccessAccurately() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC, owns: true, power: .battery, disabled: true,
                                     closed: true, causesSleep: true)
        fake.sleepSucceeds = false
        let status = fake.engine.reconcile()
        XCTAssertEqual(status.failure, .sleepRequestFailed)
        XCTAssertEqual(status.readings.sleepDisabled, false)
        XCTAssertFalse(status.ownsSleepDisabled)
    }

    func testRestoreJournalFailureDoesNotSuppressVerifiedLidSleep() {
        let fake = FakeMacMiniSystem(mode: .off, owns: true, disabled: true, closed: true, causesSleep: true)
        fake.persistenceFails = true
        let status = fake.engine.reconcile()
        XCTAssertEqual(status.failure, .persistenceFailed)
        XCTAssertEqual(fake.commands, [.disableSleep(false), .sleepNow])
        XCTAssertTrue(status.ownsSleepDisabled)
    }

    func testUnknownPowerCauseCannotSleepEvenIfFreshSourceBecomesAC() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC, owns: true, power: .unknown, disabled: true, closed: true)
        fake.afterWrite = { [weak fake] in fake?.readings.powerSource = .ac }
        _ = fake.engine.reconcile()
        XCTAssertEqual(fake.commands, [.disableSleep(false)])
    }

    func testUnknownPowerAtFreshReadbackNeverRequestsSleep() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC, owns: true, power: .battery, disabled: true, closed: true)
        fake.afterWrite = { [weak fake] in fake?.readings.powerSource = .unknown }
        _ = fake.engine.reconcile()
        XCTAssertEqual(fake.commands, [.disableSleep(false)])
    }

    func testExplicitOffWithUnknownPowerNeverRequestsSleep() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC, owns: true, power: .unknown, disabled: true, closed: true)
        _ = fake.engine.setMode(.off)
        XCTAssertEqual(fake.commands, [.disableSleep(false)])
    }

    func testReadingStatusNeverRunsACommandOrPersistsPolicy() {
        let fake = FakeMacMiniSystem(mode: .whenOnAC)
        _ = fake.engine.status()
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertTrue(fake.savedStates.isEmpty)
    }

    func testFinalPMSetWhitelistIsExactAndDoesNotAdmitExtraArguments() {
        for arguments in [["-a", "disablesleep", "0"], ["-a", "disablesleep", "1"], ["sleepnow"],
                          ["-g", "custom"], ["-b", "powermode", "2"], ["-c", "lowpowermode", "1"]] {
            XCTAssertTrue(HelperPMSetWhitelist.permits(arguments), "\(arguments)")
        }
        for arguments in [["-a", "disablesleep", "2"], ["-a", "disablesleep", "-1"],
                          ["-a", "sleep", "0"], ["-b", "disablesleep", "1"], ["sleepnow", "1"],
                          ["-c", "lowpowermode", "2"], ["-c", "powermode", "3"],
                          ["-c", "powermode", "01"], ["-g"], ["-a", "disablesleep", "1", "sleepnow"], []] {
            XCTAssertFalse(HelperPMSetWhitelist.permits(arguments), "\(arguments)")
        }
    }
}

/// No live executor, preference domain, filesystem store or IOKit access exists
/// in this fake. Policy tests cannot reach hardware even if a guard regresses.
private final class FakeMacMiniSystem {
    var readings: MacMiniSystemReadings
    var commands: [MacMiniPMSetCommand] = []
    var savedStates: [MacMiniPersistedState] = []
    var events: [String] = []
    var commandSucceeds = true
    var sleepSucceeds = true
    var writesTakeEffect = true
    var persistenceFails = false
    var afterWrite: (() -> Void)?
    private let initial: MacMiniPersistedState

    lazy var engine = MacMiniModeEngine(
        state: initial,
        read: { [unowned self] in
            self.events.append("read:" + (self.readings.sleepDisabled.map(String.init) ?? "unknown"))
            return self.readings
        },
        execute: { [unowned self] command in
            self.commands.append(command)
            switch command {
            case .disableSleep(let disabled):
                self.events.append(disabled ? "write:1" : "write:0")
                if self.commandSucceeds && self.writesTakeEffect { self.readings.sleepDisabled = disabled }
                self.afterWrite?()
                return self.commandSucceeds
            case .sleepNow:
                self.events.append("sleep")
                return self.sleepSucceeds
            }
        },
        persist: { [unowned self] state in
            if self.persistenceFails { throw MacMiniModeFailure.persistenceFailed }
            self.savedStates.append(state)
            self.events.append("save:\(state.mode.rawValue):\(state.ownsSleepDisabled)")
        }
    )

    init(
        mode: MacMiniMode = .off, owns: Bool = false, power: MacMiniPowerSource = .ac,
        disabled: Bool? = false, closed: Bool? = false, causesSleep: Bool? = true
    ) {
        initial = MacMiniPersistedState(mode: mode, ownsSleepDisabled: owns)
        readings = MacMiniSystemReadings(powerSource: power, sleepDisabled: disabled,
                                         clamshellClosed: closed, clamshellCausesSleep: causesSleep)
    }
}
