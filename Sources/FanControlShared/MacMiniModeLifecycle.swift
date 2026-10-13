import Foundation

public enum MacMiniHelperIdlePolicy {
    public static func mayExit(connectionCount: Int, pendingRequests: Int,
                               hasFanWork: Bool, requiresResidentHelper: Bool) -> Bool {
        connectionCount == 0 && pendingRequests == 0 && !hasFanWork && !requiresResidentHelper
    }
}

public enum MacMiniModeAvailability {
    public static func shouldOffer(hasInternalBattery: Bool, hasClamshell: Bool) -> Bool {
        hasInternalBattery && hasClamshell
    }
}

/// Inputs come only from Security-validated code, never XPC or a JSON claim.
public enum MacMiniApplicationTrust {
    public static func matches(applicationIdentifier: String, expectedIdentifier: String,
                               applicationTeam: String, helperTeam: String,
                               satisfiesDesignatedRequirement: Bool) -> Bool {
        guard applicationIdentifier == expectedIdentifier else { return false }
        if !helperTeam.isEmpty { return applicationTeam == helperTeam }
        return satisfiesDesignatedRequirement
    }
}

public struct MacMiniApplicationIdentity: Codable, Hashable, Sendable {
    public let installationPath: String
    /// Team ID, or the helper-derived designated requirement for the app.
    public let signingIdentity: String

    public init(installationPath: String, signingIdentity: String) {
        self.installationPath = installationPath
        self.signingIdentity = signingIdentity
    }

    public static func applicationURL(executableURL: URL?) -> URL? {
        guard let executableURL else { return nil }
        let executable = executableURL.standardizedFileURL
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let application = contents.deletingLastPathComponent()
        guard executable.deletingLastPathComponent().lastPathComponent == "Resources",
              contents.lastPathComponent == "Contents", application.pathExtension == "app" else { return nil }
        return application
    }
}

/// Queue-confined lifecycle with tri-state installation/capability evidence.
/// The shared lock serializes policy writes; peer ownership only blocks enabling.
/// Proven recovery may write only 0 without the lock, retaining archive evidence.
public final class MacMiniModeLifecycle {
    public let engine: MacMiniModeEngine
    private let installationIsValid: () -> Bool?
    private let otherIdentityIsHolding: () throws -> Bool
    private let hardwareIsSupported: () -> Bool?
    private let acquire: () -> Bool
    private let release: () -> Void

    public init(engine: MacMiniModeEngine, installationIsValid: @escaping () -> Bool?,
                otherIdentityIsHolding: @escaping () throws -> Bool,
                hardwareIsSupported: @escaping () -> Bool?,
                acquire: @escaping () -> Bool, release: @escaping () -> Void) {
        self.engine = engine
        self.installationIsValid = installationIsValid
        self.otherIdentityIsHolding = otherIdentityIsHolding
        self.hardwareIsSupported = hardwareIsSupported
        self.acquire = acquire
        self.release = release
    }

    public var requiresResidentHelper: Bool { engine.state.requiresResidentHelper }

    @discardableResult
    public func reconcile() -> MacMiniModeStatus {
        transaction(recovery: { self.engine.recoverWithoutPersistence(onlyWhenLeavingAC: true) }) {
            if engine.state.mode == .off { return engine.reconcile() }
            let installation = installationIsValid()
            if installation == false { return engine.applicationRemoved() }
            guard installation == true else { return engine.reconcileUnconfirmedEvidence() }
            // Boot-time false/empty telemetry is NOT removal evidence. Preserve
            // intent, but still restore our own 0 on battery/unknown power.
            if engine.state.mode == .whenOnAC, hardwareIsSupported() != true {
                return engine.reconcileUnconfirmedEvidence()
            }
            // Only our proven 0 may bypass a peer. An unowned policy cannot
            // clear the other helper's 1 while running on battery.
            if !engine.state.ownsSleepDisabled, let failure = peerEnableFailure() {
                return engine.reportFailure(failure)
            }
            return engine.reconcile(enableFailure: peerEnableFailure)
        }
    }

    @discardableResult
    public func setMode(_ mode: MacMiniMode, allowSleepRequest: Bool = true) -> MacMiniModeStatus {
        transaction(recovery: {
            mode == .off ? self.engine.recoverWithoutPersistence() : self.engine.reportFailure(.persistenceFailed)
        }) {
            if mode == .whenOnAC {
                let installation = installationIsValid()
                if installation == false { _ = engine.applicationRemoved() }
                guard installation == true, hardwareIsSupported() == true else {
                    return engine.reportFailure(.stateUnavailable)
                }
                // Refuse the new intent before saving it, as well as any 1 write.
                if let failure = peerEnableFailure() { return engine.reportFailure(failure) }
            }
            let evidenceAllowsSleep = installationIsValid() == true && hardwareIsSupported() == true
            return engine.setMode(mode, allowSleepRequest: allowSleepRequest && evidenceAllowsSleep)
        }
    }

    @discardableResult
    public func disableForRemoval() -> MacMiniModeStatus {
        transaction(recovery: { self.engine.recoverWithoutPersistence() }) { engine.disableForRemoval() }
    }

    @discardableResult
    public func prepareForTermination() -> MacMiniModeStatus {
        transaction(recovery: { self.engine.recoverWithoutPersistence() }) {
            if installationIsValid() == false { return engine.applicationRemoved() }
            // Unknown signing/capability or a peer owner must not block our 0.
            return engine.prepareForTermination()
        }
    }

    private func peerEnableFailure() -> MacMiniModeFailure? {
        do {
            guard try !otherIdentityIsHolding() else { return .conflictingIdentity }
            return nil
        } catch {
            return .persistenceFailed
        }
    }

    private func transaction(recovery: () -> MacMiniModeStatus, _ body: () -> MacMiniModeStatus) -> MacMiniModeStatus {
        guard acquire() else { return recovery() }
        defer { release() }
        return body()
    }
}
