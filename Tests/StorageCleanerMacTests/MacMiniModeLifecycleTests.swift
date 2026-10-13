import FanControlShared
import Foundation
import XCTest

final class MacMiniModeLifecycleTests: XCTestCase {
    func testIdleExitRequiresLastConnectionAndNoPendingWork() {
        var rows = 0
        for clients in [0, 1, 2] {
            for pending in [0, 1] {
                for fanWork in [false, true] {
                    for resident in [false, true] {
                        let expected = clients == 0 && pending == 0 && !fanWork && !resident
                        XCTAssertEqual(MacMiniHelperIdlePolicy.mayExit(connectionCount: clients, pendingRequests: pending,
                            hasFanWork: fanWork, requiresResidentHelper: resident), expected,
                            "clients=\(clients), pending=\(pending), fans=\(fanWork), resident=\(resident)")
                        rows += 1
                    }
                }
            }
        }
        XCTAssertEqual(rows, 24)
    }

    func testClientQuitKeepsEnabledPolicyAndCleanOffMayExit() {
        let fake = LifecycleSystem()
        _ = fake.lifecycle.setMode(.whenOnAC)
        XCTAssertFalse(MacMiniHelperIdlePolicy.mayExit(connectionCount: 0, pendingRequests: 0,
            hasFanWork: false, requiresResidentHelper: fake.lifecycle.requiresResidentHelper))
        _ = fake.lifecycle.setMode(.off)
        XCTAssertTrue(MacMiniHelperIdlePolicy.mayExit(connectionCount: 0, pendingRequests: 0,
            hasFanWork: false, requiresResidentHelper: fake.lifecycle.requiresResidentHelper))
        XCTAssertFalse(MacMiniHelperIdlePolicy.mayExit(connectionCount: 1, pendingRequests: 0,
            hasFanWork: false, requiresResidentHelper: fake.lifecycle.requiresResidentHelper))
    }

    func testBootAndNotificationsReconcileWithoutClientOrRepeatedWrites() {
        let fake = LifecycleSystem(state: .init(mode: .whenOnAC))
        _ = fake.lifecycle.reconcile()
        _ = fake.lifecycle.reconcile()
        fake.readings.powerSource = .battery
        _ = fake.lifecycle.reconcile()
        _ = fake.lifecycle.reconcile()
        XCTAssertEqual(fake.commands, [.disableSleep(true), .disableSleep(false), .sleepNow])
        XCTAssertEqual(fake.engine.state.mode, .whenOnAC)
        XCTAssertTrue(fake.lifecycle.requiresResidentHelper)
        XCTAssertEqual(fake.events.filter { $0 == "lock" }.count, 4)
        XCTAssertEqual(fake.events.filter { $0 == "unlock" }.count, 4)
    }

    func testMovedMissingOrWronglySignedAppClearsIntentWithoutSleep() {
        for identity in [nil, MacMiniApplicationIdentity(installationPath: "/Moved.app", signingIdentity: "team:A"),
                         MacMiniApplicationIdentity(installationPath: "/Installed.app", signingIdentity: "team:B")] {
            let fake = LifecycleSystem(state: .init(mode: .whenOnAC, ownsSleepDisabled: true), disabled: true)
            fake.currentApplication = identity
            let status = fake.lifecycle.reconcile()
            XCTAssertEqual(status.mode, .off)
            XCTAssertFalse(status.ownsSleepDisabled)
            XCTAssertEqual(fake.commands, [.disableSleep(false)])
            XCTAssertFalse(fake.lifecycle.requiresResidentHelper)
            XCTAssertEqual(fake.saved.first?.mode, .off)
        }
    }

    func testUpdateWithSamePathAndSigningIdentityPreservesIntent() {
        let fake = LifecycleSystem(state: .init(mode: .whenOnAC))
        fake.currentApplication = .init(installationPath: "/Installed.app", signingIdentity: "team:A")
        _ = fake.lifecycle.reconcile()
        XCTAssertEqual(fake.engine.state.mode, .whenOnAC)
        XCTAssertEqual(fake.commands, [.disableSleep(true)])
    }

    func testTerminationWithClosedLidRestoresOnlyOursWithoutSleep() {
        let fake = LifecycleSystem(state: .init(mode: .whenOnAC, ownsSleepDisabled: true), disabled: true)
        let status = fake.lifecycle.prepareForTermination()
        XCTAssertEqual(fake.commands, [.disableSleep(false)])
        XCTAssertEqual(status.mode, .whenOnAC)
        XCTAssertFalse(status.ownsSleepDisabled)
        let external = LifecycleSystem(state: .init(mode: .whenOnAC), disabled: true)
        _ = external.lifecycle.prepareForTermination()
        XCTAssertTrue(external.commands.isEmpty)
        // A moved app at SIGTERM also follows the no-sleep path.
        let moved = LifecycleSystem(state: .init(mode: .whenOnAC, ownsSleepDisabled: true), disabled: true)
        moved.currentApplication = nil
        XCTAssertEqual(moved.lifecycle.prepareForTermination().mode, .off)
        XCTAssertEqual(moved.commands, [.disableSleep(false)])
    }

    func testInvalidArchiveDegradesOffAndNeverClaimsExternalSetting() {
        let fake = LifecycleSystem(disabled: true, persistenceUnavailable: true)
        XCTAssertEqual(fake.lifecycle.reconcile().failure, .persistenceFailed)
        let status = fake.lifecycle.setMode(.whenOnAC)
        XCTAssertEqual(status.mode, .off)
        XCTAssertEqual(status.failure, .persistenceFailed)
        XCTAssertFalse(status.ownsSleepDisabled)
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertFalse(fake.lifecycle.requiresResidentHelper)
    }

    func testDegradedArchiveRecoversOnlyTrustedDebtAndNeverSleeps() {
        let fake = LifecycleSystem(state: .init(ownsSleepDisabled: true), disabled: true, persistenceUnavailable: true)
        fake.saveFails = true
        let status = fake.lifecycle.reconcile()
        XCTAssertEqual(fake.commands, [.disableSleep(false)])
        XCTAssertEqual(status.mode, .off)
        XCTAssertEqual(status.failure, .persistenceFailed)
        XCTAssertTrue(status.ownsSleepDisabled)
        XCTAssertTrue(fake.lifecycle.requiresResidentHelper)
    }

    func testOtherIdentityHoldingPreventsIntentAndAllHardwareWrites() {
        let fake = LifecycleSystem()
        fake.peerHolds = true
        let status = fake.lifecycle.setMode(.whenOnAC)
        XCTAssertEqual(status.mode, .off)
        XCTAssertEqual(status.failure, .conflictingIdentity)
        XCTAssertTrue(fake.saved.isEmpty)
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertEqual(fake.events, ["lock", "peer", "unlock"])
        // A trusted sibling recovery debt also holds the shared system setting.
        let recovery = LifecycleSystem(state: .init(ownsSleepDisabled: true), disabled: true)
        recovery.peerHolds = true
        _ = recovery.lifecycle.prepareForTermination()
        XCTAssertEqual(recovery.commands, [.disableSleep(false)])
        XCTAssertFalse(recovery.engine.state.ownsSleepDisabled)
    }

    func testConflictClearsAfterPeerReleasesWithoutOverwritingItsIntent() {
        let fake = LifecycleSystem()
        fake.peerHolds = true
        _ = fake.lifecycle.setMode(.whenOnAC)
        fake.peerHolds = false
        XCTAssertNil(fake.lifecycle.setMode(.whenOnAC).failure)
        XCTAssertEqual(fake.commands, [.disableSleep(true)])
        XCTAssertEqual(fake.engine.state.mode, .whenOnAC)
    }

    func testBusyLockOrUnreadablePeerCannotEnable() {
        for busy in [false, true] {
            let fake = LifecycleSystem()
            fake.lockAvailable = !busy
            fake.peerUnreadable = !busy
            XCTAssertEqual(fake.lifecycle.setMode(.whenOnAC).failure, .persistenceFailed)
            XCTAssertTrue(fake.commands.isEmpty)
            XCTAssertTrue(fake.saved.isEmpty)
            XCTAssertEqual(fake.events.last, busy ? "lock" : "unlock")
        }
    }

    func testUnsupportedHardwareCannotEnable() {
        let fake = LifecycleSystem()
        fake.hardwareSupported = false
        let status = fake.lifecycle.setMode(.whenOnAC)
        XCTAssertEqual(status.mode, .off)
        XCTAssertEqual(status.failure, .stateUnavailable)
        XCTAssertTrue(fake.commands.isEmpty)
        for battery in [false, true] {
            for clamshell in [false, true] {
                XCTAssertEqual(MacMiniModeAvailability.shouldOffer(hasInternalBattery: battery, hasClamshell: clamshell),
                               battery && clamshell)
            }
        }
    }

    func testUnknownHardwareTelemetryDoesNotEraseExistingIntentOrSleep() {
        let fake = LifecycleSystem(state: .init(mode: .whenOnAC, ownsSleepDisabled: true), disabled: true)
        fake.hardwareSupported = nil
        XCTAssertEqual(fake.lifecycle.reconcile().failure, .stateUnavailable)
        XCTAssertTrue(fake.commands.isEmpty, "Unknown capability still blocks AC enabling")
        XCTAssertTrue(fake.saved.isEmpty)
        fake.readings.powerSource = .unknown
        let status = fake.lifecycle.reconcile()
        XCTAssertEqual(status.mode, .whenOnAC)
        XCTAssertEqual(status.failure, .stateUnavailable)
        XCTAssertEqual(fake.commands, [.disableSleep(false)])
        XCTAssertEqual(fake.saved, [.init(mode: .whenOnAC)])
        XCTAssertFalse(status.ownsSleepDisabled)
        XCTAssertEqual(status.readings.sleepDisabled, false)
    }

    func testFalseOrMissingCapabilityPreservesIntentAndSettingsUntilRetry() {
        for capability in [false, nil] as [Bool?] {
            for owns in [false, true] {
                for source in [MacMiniPowerSource.ac, .battery, .unknown] {
                    let fake = LifecycleSystem(state: .init(mode: .whenOnAC, ownsSleepDisabled: owns), disabled: true)
                    fake.hardwareSupported = capability
                    fake.readings.powerSource = source
                    let status = fake.lifecycle.reconcile()
                    let restores = owns && source != .ac
                    XCTAssertEqual(status.mode, .whenOnAC)
                    XCTAssertEqual(status.failure, .stateUnavailable)
                    XCTAssertEqual(status.ownsSleepDisabled, owns && !restores)
                    XCTAssertEqual(status.readings.sleepDisabled, !restores)
                    XCTAssertEqual(fake.commands, restores ? [.disableSleep(false)] : [])
                    XCTAssertEqual(fake.saved, restores ? [.init(mode: .whenOnAC)] : [])
                    XCTAssertTrue(fake.lifecycle.requiresResidentHelper)
                    _ = fake.lifecycle.reconcile()
                    XCTAssertEqual(fake.commands, restores ? [.disableSleep(false)] : [], "Recovery is idempotent")
                    fake.hardwareSupported = true
                    fake.readings.powerSource = .ac
                    XCTAssertNil(fake.lifecycle.reconcile().failure)
                    XCTAssertEqual(fake.commands, restores ? [.disableSleep(false), .disableSleep(true)] : [])
                }
            }
        }
    }

    func testUnavailableCapabilityRejectsEnableWithoutClearingExistingIntent() {
        let fake = LifecycleSystem(state: .init(mode: .whenOnAC, ownsSleepDisabled: true), disabled: true)
        fake.hardwareSupported = false
        XCTAssertEqual(fake.lifecycle.setMode(.whenOnAC).failure, .stateUnavailable)
        XCTAssertEqual(fake.engine.state.mode, .whenOnAC)
        XCTAssertTrue(fake.saved.isEmpty)
        XCTAssertTrue(fake.commands.isEmpty)
    }

    func testUnknownSigningPreservesIntentWithoutWritesAndLaterRetries() {
        let fake = LifecycleSystem(state: .init(mode: .whenOnAC), disabled: false)
        fake.installationUnknown = true
        XCTAssertEqual(fake.lifecycle.reconcile().failure, .stateUnavailable)
        XCTAssertEqual(fake.engine.state.mode, .whenOnAC)
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertTrue(fake.saved.isEmpty)
        XCTAssertTrue(fake.lifecycle.requiresResidentHelper)
        fake.installationUnknown = false
        XCTAssertNil(fake.lifecycle.reconcile().failure)
        XCTAssertEqual(fake.commands, [.disableSleep(true)])
    }

    func testUnknownSigningRestoresOnlyOwnedZeroOnBatteryOrUnknownPower() {
        for source in [MacMiniPowerSource.ac, .battery, .unknown] {
            for owns in [false, true] {
                for disabled in [true, nil] as [Bool?] {
                    let fake = LifecycleSystem(state: .init(mode: .whenOnAC, ownsSleepDisabled: owns))
                    fake.readings.sleepDisabled = disabled
                    fake.readings.powerSource = source
                    fake.installationUnknown = true
                    fake.peerUnreadable = true
                    let result = fake.lifecycle.reconcile()
                    let restores = owns && source != .ac
                    XCTAssertEqual(result.mode, .whenOnAC)
                    XCTAssertEqual(result.failure, .stateUnavailable)
                    XCTAssertEqual(result.ownsSleepDisabled, owns && !restores)
                    XCTAssertEqual(result.readings.sleepDisabled, restores ? false : disabled)
                    XCTAssertEqual(fake.commands, restores ? [.disableSleep(false)] : [])
                    XCTAssertEqual(fake.saved, restores ? [.init(mode: .whenOnAC)] : [])
                    XCTAssertFalse(fake.events.contains("peer"))
                }
            }
        }
    }

    func testUnknownEvidenceCannotBlockOffOrTerminationOrRequestSleep() {
        for evidence in ["signing", "capabilityFalse", "capabilityMissing"] {
            for source in [MacMiniPowerSource.ac, .battery, .unknown] {
                for off in [false, true] {
                    for owns in [false, true] {
                        let fake = LifecycleSystem(state: .init(mode: .whenOnAC, ownsSleepDisabled: owns), disabled: true)
                        fake.installationUnknown = evidence == "signing"
                        fake.hardwareSupported = evidence == "capabilityMissing" ? nil : evidence != "capabilityFalse"
                        fake.readings.powerSource = source
                        let result = off ? fake.lifecycle.setMode(.off) : fake.lifecycle.prepareForTermination()
                        XCTAssertNil(result.failure)
                        XCTAssertEqual(result.mode, off ? .off : .whenOnAC)
                        XCTAssertFalse(result.ownsSleepDisabled)
                        XCTAssertEqual(fake.commands, owns ? [.disableSleep(false)] : [])
                        XCTAssertEqual(result.readings.sleepDisabled, !owns)
                    }
                }
            }
        }
    }

    func testUnknownEvidenceRecoveryFailuresKeepDebtAndSpecificError() {
        for failure in [MacMiniModeFailure.commandFailed, .verificationFailed, .persistenceFailed] {
            let fake = LifecycleSystem(state: .init(mode: .whenOnAC, ownsSleepDisabled: true), disabled: true)
            fake.installationUnknown = true
            fake.readings.powerSource = .battery
            fake.commandSucceeds = failure != .commandFailed
            fake.reflectWrites = failure != .verificationFailed
            fake.saveFails = failure == .persistenceFailed
            let result = fake.lifecycle.reconcile()
            XCTAssertEqual(result.failure, failure, "Do not mask recovery failure as unknown evidence")
            XCTAssertEqual(result.mode, .whenOnAC)
            XCTAssertTrue(result.ownsSleepDisabled)
            XCTAssertEqual(fake.commands, [.disableSleep(false)])
        }
    }

    func testUnavailableLockAllowsOnlyOwnedRecoveryWithoutChangingArchives() {
        for action in ["reconcile", "off", "removal", "termination", "enable"] {
            for source in [MacMiniPowerSource.ac, .battery, .unknown] {
                for mode in MacMiniMode.allCases {
                    for owns in [false, true] {
                        let initial = MacMiniPersistedState(mode: mode, ownsSleepDisabled: owns)
                        let fake = LifecycleSystem(state: initial, disabled: true)
                        fake.lockAvailable = false
                        fake.readings.powerSource = source
                        let result: MacMiniModeStatus
                        switch action {
                        case "off": result = fake.lifecycle.setMode(.off)
                        case "removal": result = fake.lifecycle.disableForRemoval()
                        case "termination": result = fake.lifecycle.prepareForTermination()
                        case "enable": result = fake.lifecycle.setMode(.whenOnAC)
                        default: result = fake.lifecycle.reconcile()
                        }
                        let restores = owns && action != "enable" && (action != "reconcile" || mode == .off || source != .ac)
                        XCTAssertEqual(fake.commands, restores ? [.disableSleep(false)] : [])
                        XCTAssertEqual(result.readings.sleepDisabled, !restores)
                        XCTAssertEqual(result.failure, .persistenceFailed)
                        XCTAssertEqual(fake.engine.state, initial, "No lock means no durable policy/debt change")
                        XCTAssertTrue(fake.saved.isEmpty)
                        XCTAssertEqual(fake.events, ["lock"], "No unheld unlock or peer read")
                    }
                }
            }
        }
    }

    func testUnlockedRecoveryVerifiesZeroRetainsDebtAndFinishesAfterLockReturns() {
        for failure in [MacMiniModeFailure.commandFailed, .verificationFailed] {
            let fake = LifecycleSystem(state: .init(mode: .whenOnAC, ownsSleepDisabled: true), disabled: true)
            fake.lockAvailable = false
            fake.readings.powerSource = .battery
            fake.commandSucceeds = failure != .commandFailed
            fake.reflectWrites = failure != .verificationFailed
            XCTAssertEqual(fake.lifecycle.reconcile().failure, failure)
            XCTAssertTrue(fake.engine.state.ownsSleepDisabled)
            fake.commandSucceeds = true
            fake.reflectWrites = true
            XCTAssertEqual(fake.lifecycle.reconcile().failure, .persistenceFailed)
            XCTAssertEqual(fake.readings.sleepDisabled, false)
            XCTAssertTrue(fake.engine.state.ownsSleepDisabled, "Retain durable debt until locked cleanup")
            XCTAssertEqual(fake.commands, [.disableSleep(false), .disableSleep(false)])
            _ = fake.lifecycle.reconcile()
            XCTAssertEqual(fake.commands.count, 2, "Already verified 0 needs no repeated write")
            XCTAssertTrue(fake.saved.isEmpty)
            fake.lockAvailable = true
            XCTAssertNil(fake.lifecycle.reconcile().failure)
            XCTAssertEqual(fake.engine.state, .init(mode: .whenOnAC))
            XCTAssertEqual(fake.saved, [.init(mode: .whenOnAC)])
            XCTAssertEqual(fake.commands, [.disableSleep(false), .disableSleep(false)])
        }
    }

    func testFailedOffPersistenceStillRestoresOwnedZeroWithoutClaimingSuccess() {
        let fake = LifecycleSystem(state: .init(mode: .whenOnAC, ownsSleepDisabled: true), disabled: true)
        fake.saveFails = true
        let result = fake.lifecycle.setMode(.off)
        XCTAssertEqual(result.failure, .persistenceFailed)
        XCTAssertEqual(fake.commands, [.disableSleep(false)])
        XCTAssertEqual(result.readings.sleepDisabled, false)
        XCTAssertEqual(fake.engine.state, .init(mode: .whenOnAC, ownsSleepDisabled: true))
        XCTAssertTrue(fake.saved.isEmpty)
    }

    func testOwnRecoveryBypassesHeldOrUnreadablePeerWithoutSleeping() {
        for unreadable in [false, true] {
            for explicitOff in [false, true] {
                let fake = LifecycleSystem(state: .init(mode: .whenOnAC, ownsSleepDisabled: true), disabled: true)
                fake.peerHolds = true
                fake.peerUnreadable = unreadable
                fake.installationUnknown = true
                fake.hardwareSupported = nil
                let status = explicitOff ? fake.lifecycle.disableForRemoval()
                    : fake.lifecycle.prepareForTermination()
                XCTAssertNil(status.failure)
                XCTAssertEqual(fake.commands, [.disableSleep(false)])
                XCTAssertFalse(status.ownsSleepDisabled)
                XCTAssertEqual(status.mode, explicitOff ? .off : .whenOnAC)
                XCTAssertFalse(fake.events.contains("peer"), "A peer cannot veto our recovery")
                XCTAssertEqual(fake.events.first, "lock")
                XCTAssertEqual(fake.events.last, "unlock")
            }
        }
        let external = LifecycleSystem(state: .init(mode: .whenOnAC), disabled: true)
        external.peerHolds = true
        XCTAssertNil(external.lifecycle.setMode(.off, allowSleepRequest: false).failure)
        XCTAssertTrue(external.commands.isEmpty, "Only our armed obligation may write 0")
    }

    func testBatteryRecoveryIgnoresPeerButACEnableStillChecksIt() {
        let fake = LifecycleSystem(state: .init(mode: .whenOnAC, ownsSleepDisabled: true), disabled: true)
        fake.peerHolds = true
        fake.readings.powerSource = .battery
        XCTAssertNil(fake.lifecycle.reconcile().failure)
        XCTAssertEqual(fake.commands, [.disableSleep(false), .sleepNow])
        XCTAssertFalse(fake.events.contains("peer"))
        fake.readings.powerSource = .ac
        XCTAssertEqual(fake.lifecycle.reconcile().failure, .conflictingIdentity)
        XCTAssertEqual(fake.commands, [.disableSleep(false), .sleepNow])
        XCTAssertTrue(fake.events.contains("peer"))
    }

    func testUnownedBatteryPolicyCannotClearPeersSleepSetting() {
        let fake = LifecycleSystem(state: .init(mode: .whenOnAC), disabled: true)
        fake.peerHolds = true
        fake.readings.powerSource = .battery
        XCTAssertEqual(fake.lifecycle.reconcile().failure, .conflictingIdentity)
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertFalse(fake.engine.state.ownsSleepDisabled)
    }

    func testApplicationTrustRequiresAppIdentifierAndHelperSigningIdentity() {
        func matches(_ identifier: String = "app", team: String, helperTeam: String = "A", requirement: Bool = false) -> Bool {
            MacMiniApplicationTrust.matches(applicationIdentifier: identifier, expectedIdentifier: "app",
                applicationTeam: team, helperTeam: helperTeam, satisfiesDesignatedRequirement: requirement)
        }
        XCTAssertTrue(matches(team: "A"))
        XCTAssertFalse(matches(team: "B", requirement: true))
        XCTAssertFalse(matches("other.app", team: "A", requirement: true))
        XCTAssertFalse(matches(team: "", helperTeam: ""))
        XCTAssertTrue(matches(team: "", helperTeam: "", requirement: true))
        XCTAssertFalse(matches("other.app", team: "", helperTeam: "", requirement: true))
    }

    func testExecutableURLUsesAppBundleLayoutAndRejectsLegacyOrAbsentSource() {
        XCTAssertEqual(MacMiniApplicationIdentity.applicationURL(executableURL:
            URL(fileURLWithPath: "/Applications/App.app/Contents/Resources/Helper"))?.path, "/Applications/App.app")
        XCTAssertNil(MacMiniApplicationIdentity.applicationURL(executableURL: nil))
        XCTAssertNil(MacMiniApplicationIdentity.applicationURL(executableURL:
            URL(fileURLWithPath: "/Library/PrivilegedHelperTools/Helper")))
        XCTAssertNil(MacMiniApplicationIdentity.applicationURL(executableURL:
            URL(fileURLWithPath: "/Applications/App.app/Other/Resources/Helper")))
    }
}

private final class LifecycleSystem {
    let expected = MacMiniApplicationIdentity(installationPath: "/Installed.app", signingIdentity: "team:A")
    var currentApplication: MacMiniApplicationIdentity?
    var installationUnknown = false
    var readings: MacMiniSystemReadings
    var commands: [MacMiniPMSetCommand] = []
    var saved: [MacMiniPersistedState] = []
    var events: [String] = []
    var peerHolds = false
    var peerUnreadable = false
    var lockAvailable = true
    var locked = false
    var hardwareSupported: Bool? = true
    var saveFails = false
    var commandSucceeds = true
    var reflectWrites = true
    let initial: MacMiniPersistedState
    let persistenceUnavailable: Bool

    lazy var engine: MacMiniModeEngine = MacMiniModeEngine(state: initial, read: { [unowned self] in self.readings },
        execute: { [unowned self] command in
            if !self.locked {
                XCTAssertEqual(command, .disableSleep(false), "Only proven emergency 0 may bypass the lock")
                XCTAssertTrue(self.engine.state.ownsSleepDisabled)
            }
            self.commands.append(command)
            guard self.commandSucceeds else { return false }
            if self.reflectWrites, case .disableSleep(let disabled) = command { self.readings.sleepDisabled = disabled }
            return true
        }, persist: { [unowned self] state in
            XCTAssertTrue(self.locked, "Intent must be checked/saved atomically with sibling policy")
            if self.saveFails { throw MacMiniModeFailure.persistenceFailed }
            self.saved.append(state)
        }, persistenceUnavailable: persistenceUnavailable)

    lazy var lifecycle = MacMiniModeLifecycle(engine: engine,
        installationIsValid: { [unowned self] in self.installationUnknown ? nil : self.currentApplication == self.expected },
        otherIdentityIsHolding: { [unowned self] in
            XCTAssertTrue(self.locked)
            self.events.append("peer")
            if self.peerUnreadable { throw MacMiniModeFailure.persistenceFailed }
            return self.peerHolds
        }, hardwareIsSupported: { [unowned self] in self.hardwareSupported },
        acquire: { [unowned self] in
            self.events.append("lock")
            self.locked = self.lockAvailable
            return self.lockAvailable
        }, release: { [unowned self] in self.locked = false; self.events.append("unlock") })

    init(state: MacMiniPersistedState = .init(), disabled: Bool = false, persistenceUnavailable: Bool = false) {
        initial = state
        self.persistenceUnavailable = persistenceUnavailable
        currentApplication = .init(installationPath: "/Installed.app", signingIdentity: "team:A")
        readings = .init(powerSource: .ac, sleepDisabled: disabled, clamshellClosed: true, clamshellCausesSleep: true)
    }
}
