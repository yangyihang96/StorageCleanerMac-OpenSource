import Foundation

public enum HardwareControlProtocol {
    public static let currentVersion = 4
    public static func accepts(_ version: Int?) -> Bool { version == currentVersion }
}

public enum MacMiniMode: String, Codable, CaseIterable, Equatable, Sendable {
    case off
    case whenOnAC
}

public enum MacMiniPowerSource: String, Codable, Equatable, Sendable {
    case ac
    case battery
    case unknown
}

/// Optional registry values stay unknown; a missing clamshell key is not false.
public struct MacMiniSystemReadings: Codable, Equatable, Sendable {
    public var powerSource: MacMiniPowerSource
    public var sleepDisabled: Bool?
    public var clamshellClosed: Bool?
    public var clamshellCausesSleep: Bool?

    public init(
        powerSource: MacMiniPowerSource, sleepDisabled: Bool?,
        clamshellClosed: Bool?, clamshellCausesSleep: Bool?
    ) {
        self.powerSource = powerSource
        self.sleepDisabled = sleepDisabled
        self.clamshellClosed = clamshellClosed
        self.clamshellCausesSleep = clamshellCausesSleep
    }
}

public struct MacMiniPersistedState: Codable, Equatable, Sendable {
    public var mode: MacMiniMode
    /// A recovery obligation, armed durably BEFORE writing disablesleep=1.
    /// It cannot identify a different tool that subsequently writes the same value.
    public var ownsSleepDisabled: Bool

    public init(mode: MacMiniMode = .off, ownsSleepDisabled: Bool = false) {
        self.mode = mode
        self.ownsSleepDisabled = ownsSleepDisabled
    }

    public var requiresResidentHelper: Bool { mode != .off || ownsSleepDisabled }

    /// Updates at the same signed installation preserve intent. Removal or an
    /// identity change clears intent, while retaining proven recovery debt.
    public func boundToApplication(isSameInstallation: Bool) -> Self {
        Self(mode: isSameInstallation ? mode : .off, ownsSleepDisabled: ownsSleepDisabled)
    }
}

public enum MacMiniModeFailure: String, Codable, Error, Equatable, Sendable {
    case stateUnavailable
    case persistenceFailed
    case commandFailed
    case verificationFailed
    case sleepRequestFailed
    case conflictingIdentity
}

public enum MacMiniSleepSettingOwner: String, Codable, Equatable, Sendable {
    case helper
    case externalOrUnknown
    case none
    case unknown
}

public struct MacMiniModeStatus: Codable, Equatable, Sendable {
    public let mode: MacMiniMode
    public let ownsSleepDisabled: Bool
    public let readings: MacMiniSystemReadings
    public let failure: MacMiniModeFailure?

    public init(
        state: MacMiniPersistedState, readings: MacMiniSystemReadings,
        failure: MacMiniModeFailure? = nil
    ) {
        mode = state.mode
        ownsSleepDisabled = state.ownsSleepDisabled
        self.readings = readings
        self.failure = failure
    }

    public var settingOwner: MacMiniSleepSettingOwner {
        if ownsSleepDisabled { return .helper }
        switch readings.sleepDisabled {
        case true?: return .externalOrUnknown
        case false?: return .none
        case nil: return .unknown
        }
    }

    public var expectedSleepDisabled: Bool? {
        guard mode == .whenOnAC else { return ownsSleepDisabled ? false : nil }
        switch readings.powerSource {
        case .ac: return true
        case .battery: return false
        case .unknown: return nil
        }
    }

    public var isConsistent: Bool {
        guard failure == nil else { return false }
        if let expectedSleepDisabled { return readings.sleepDisabled == expectedSleepDisabled }
        return mode == .off && !ownsSleepDisabled
    }
}

public enum MacMiniPMSetCommand: Equatable, Sendable {
    case disableSleep(Bool)
    case sleepNow

    public var arguments: [String] {
        switch self {
        case .disableSleep(let disabled): ["-a", "disablesleep", disabled ? "1" : "0"]
        case .sleepNow: ["sleepnow"]
        }
    }
}

/// Used at the final process boundary, as well as in injected policy tests.
public enum HelperPMSetWhitelist {
    public static func permits(_ arguments: [String]) -> Bool {
        if arguments == ["-g", "custom"] || arguments == ["sleepnow"] { return true }
        guard arguments.count == 3 else { return false }
        if arguments[0] == "-a", arguments[1] == "disablesleep" {
            return ["0", "1"].contains(arguments[2])
        }
        guard ["-b", "-c"].contains(arguments[0]) else { return false }
        switch arguments[1] {
        case "powermode": return ["0", "1", "2"].contains(arguments[2])
        case "lowpowermode": return ["0", "1"].contains(arguments[2])
        default: return false
        }
    }
}

/// Queue-confined policy, deliberately without live defaults or IOKit writes.
/// The helper supplies its fixed command executor, readings and root-only store.
public final class MacMiniModeEngine {
    public private(set) var state: MacMiniPersistedState
    public private(set) var lastFailure: MacMiniModeFailure?
    private let read: () -> MacMiniSystemReadings
    private let execute: (MacMiniPMSetCommand) -> Bool
    private let persist: (MacMiniPersistedState) throws -> Void
    private let persistenceUnavailable: Bool

    public init(
        state: MacMiniPersistedState,
        read: @escaping () -> MacMiniSystemReadings,
        execute: @escaping (MacMiniPMSetCommand) -> Bool,
        persist: @escaping (MacMiniPersistedState) throws -> Void,
        persistenceUnavailable: Bool = false
    ) {
        self.state = persistenceUnavailable ? state.boundToApplication(isSameInstallation: false) : state
        self.read = read
        self.execute = execute
        self.persist = persist
        self.persistenceUnavailable = persistenceUnavailable
        lastFailure = persistenceUnavailable ? .persistenceFailed : nil
    }

    /// Read requests do not run pmset or change the persisted policy.
    public func status() -> MacMiniModeStatus {
        MacMiniModeStatus(state: state, readings: read(), failure: lastFailure)
    }

    @discardableResult
    public func setMode(_ mode: MacMiniMode, allowSleepRequest: Bool = true) -> MacMiniModeStatus {
        lastFailure = persistenceUnavailable ? .persistenceFailed : nil
        guard mode == .off || !persistenceUnavailable else { return status() }
        var next = state
        next.mode = mode
        guard save(next) else {
            // Failed intent persistence must not strand our own no-sleep value.
            return mode == .off ? recoverWithoutPersistence() : status()
        }
        return reconcile(allowSleepRequest: allowSleepRequest)
    }

    /// Unknown installation/capability evidence vetoes 1, never our battery or
    /// unknown-power recovery. Keep intent and do not request immediate sleep.
    @discardableResult
    public func reconcileUnconfirmedEvidence() -> MacMiniModeStatus {
        guard state.ownsSleepDisabled else { return reportFailure(.stateUnavailable) }
        _ = reconcile(allowSleepRequest: false, enableFailure: { .stateUnavailable })
        if lastFailure == nil { lastFailure = .stateUnavailable }
        return status()
    }

    /// Emergency 0 using already trusted recovery proof. No lock means no
    /// archive mutation, no new ownership and no sleepnow. Keep the journal
    /// debt until a normal locked transaction can durably finish recovery.
    @discardableResult
    public func recoverWithoutPersistence(onlyWhenLeavingAC: Bool = false) -> MacMiniModeStatus {
        lastFailure = .persistenceFailed
        guard state.ownsSleepDisabled else { return status() }
        let observed = read()
        if onlyWhenLeavingAC, state.mode != .off, observed.powerSource == .ac { return status() }
        if observed.sleepDisabled != false {
            guard execute(.disableSleep(false)) else { return reportFailure(.commandFailed) }
            guard read().sleepDisabled == false else { return reportFailure(.verificationFailed) }
        }
        return status()
    }

    @discardableResult
    public func reconcile(allowSleepRequest: Bool = true, enableFailure: () -> MacMiniModeFailure? = { nil }) -> MacMiniModeStatus {
        lastFailure = persistenceUnavailable ? .persistenceFailed : nil
        let observed = read()
        if state.mode == .off {
            // Off never rewrites a setting for which we have no recovery obligation.
            guard state.ownsSleepDisabled else { return status() }
            return apply(false, observed: observed, allowSleepRequest: allowSleepRequest && !persistenceUnavailable)
        }
        switch observed.powerSource {
        case .ac:
            // Check the peer at the actual enabling decision, under the caller's
            // shared lock. A power-source change cannot bypass this check.
            if let failure = enableFailure() { return reportFailure(failure) }
            return apply(true, observed: observed, allowSleepRequest: allowSleepRequest)
        case .battery: return apply(false, observed: observed, allowSleepRequest: allowSleepRequest)
        case .unknown:
            // Missing power-source telemetry must not strand our own no-sleep value.
            if state.ownsSleepDisabled {
                _ = apply(false, observed: observed, allowSleepRequest: false)
            }
            if lastFailure == nil { lastFailure = .stateUnavailable }
            return status()
        }
    }

    /// Pure fault-mode removal disarms intent and restores only our setting;
    /// it must never request sleep while shutting down a failed helper.
    @discardableResult
    public func disableForRemoval() -> MacMiniModeStatus {
        if state.mode == .off { return reconcile(allowSleepRequest: false) }
        return setMode(.off, allowSleepRequest: false)
    }

    /// SIGTERM/SIGINT restore our setting, but retain the requested mode for boot.
    /// Explicit unregister/uninstall instead calls setMode(.off) before termination.
    @discardableResult
    public func prepareForTermination() -> MacMiniModeStatus {
        lastFailure = persistenceUnavailable ? .persistenceFailed : nil
        guard state.ownsSleepDisabled else { return status() }
        return apply(false, observed: read(), allowSleepRequest: false)
    }

    /// Removal, signature changes and startup recovery must never request sleep.
    @discardableResult
    public func applicationRemoved() -> MacMiniModeStatus {
        var next = state
        next.mode = .off
        // Even if the store is unavailable, do not keep a removed app's intent
        // in memory. Retain its proven recovery obligation until verified clear.
        _ = save(next)
        state.mode = .off
        return reconcile(allowSleepRequest: false)
    }

    @discardableResult
    public func reportFailure(_ failure: MacMiniModeFailure) -> MacMiniModeStatus {
        lastFailure = failure
        return status()
    }

    private func save(_ next: MacMiniPersistedState) -> Bool {
        do {
            try persist(next)
            state = next
            return true
        } catch {
            lastFailure = .persistenceFailed
            return false
        }
    }

    private func apply(_ disabled: Bool, observed: MacMiniSystemReadings, allowSleepRequest: Bool) -> MacMiniModeStatus {
        if observed.sleepDisabled == disabled {
            if !disabled, state.ownsSleepDisabled {
                var next = state
                next.ownsSleepDisabled = false
                _ = save(next)
            }
            return status()
        }
        // Enabling with unknown SleepDisabled could steal someone else's setting.
        // Restoring an armed obligation still attempts 0 even if the key disappeared.
        guard observed.sleepDisabled != nil || (!disabled && state.ownsSleepDisabled) else {
            lastFailure = .stateUnavailable
            return status()
        }
        if disabled, !state.ownsSleepDisabled {
            var next = state
            next.ownsSleepDisabled = true
            guard save(next) else { return status() }
        }
        guard execute(.disableSleep(disabled)) else {
            lastFailure = .commandFailed
            return status()
        }
        let verified = read()
        guard verified.sleepDisabled == disabled else {
            // Retain the journal on failure; the next launch/tick must retry recovery.
            lastFailure = .verificationFailed
            return status()
        }
        if !disabled {
            var next = state
            next.ownsSleepDisabled = false
            _ = save(next)
            // Only a verified 1 -> 0 transition may request sleep. Use fresh lid keys.
            if observed.sleepDisabled == true,
               allowSleepRequest,
               verified.powerSource != .unknown,
               verified.clamshellClosed == true,
               verified.clamshellCausesSleep == true,
               !execute(.sleepNow), lastFailure == nil {
                lastFailure = .sleepRequestFailed
            }
        }
        return status()
    }
}
