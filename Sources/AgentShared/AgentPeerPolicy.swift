import Darwin
import FileOperationShared
import Foundation

/// D263: the App talks only to the bridge inside its own bundle. Built on the
/// askpass trust code unchanged: the peer's PID, UID and audit token come from
/// the kernel, its code identity from the audit token, and the process is read
/// again at the end so a reused PID cannot slip in between.
public struct AgentBridgePeerPolicy: Sendable {
    public static let identifierSuffix = ".agent-bridge"

    public let bridgeExecutable: String
    public let application: UpdateAskpassCodeIdentity
    public let bundledBridge: UpdateAskpassCodeIdentity

    public init(bridgeExecutable: String, application: UpdateAskpassCodeIdentity, bundledBridge: UpdateAskpassCodeIdentity) {
        self.bridgeExecutable = bridgeExecutable; self.application = application; self.bundledBridge = bundledBridge
    }

    public func permits(_ peer: UpdateAskpassKernelPeer, uid: uid_t = getuid(),
                        process: (pid_t) -> UpdateProcessSnapshot? = UpdateProcessSnapshot.read,
                        signature: (UpdateAskpassKernelPeer) -> UpdateAskpassCodeIdentity? = UpdateAskpassCodeIdentity.process) -> Bool {
        // The release bridge never serves the Beta, nor the other way round.
        guard peer.uid == uid, bundledBridge.identifier == application.identifier + Self.identifierSuffix,
              let caller = process(peer.pid), caller.uid == peer.uid, !caller.zombie, caller.executable == bridgeExecutable,
              let code = signature(peer), code.identifier == bundledBridge.identifier, code.cdhash == bundledBridge.cdhash,
              process(peer.pid)?.identity == caller.identity else { return false }
        if let team = application.team, !team.isEmpty {
            return code.team == team && bundledBridge.team == team
        }
        // Ad-hoc builds: the App's own seal covers the bundled bridge, so the
        // live peer must be exactly those bytes (same rule as askpass).
        return application.adHoc && bundledBridge.adHoc && code.adHoc && !code.cdhash.isEmpty
    }
}

/// D263: the bridge talks only to its own App, so a socket planted in the
/// data directory cannot answer an AI in the App's name.
public struct AgentApplicationPeerPolicy: Sendable {
    public let applicationExecutable: String
    public let applicationIdentifier: String
    /// The bridge's own static identity: its team is the App's team.
    public let bridge: UpdateAskpassCodeIdentity
    /// Ad-hoc builds only: the App bundle on disk, which the live App must match.
    public let bundledApplication: UpdateAskpassCodeIdentity?

    public init(applicationExecutable: String, applicationIdentifier: String, bridge: UpdateAskpassCodeIdentity,
                bundledApplication: UpdateAskpassCodeIdentity?) {
        self.applicationExecutable = applicationExecutable; self.applicationIdentifier = applicationIdentifier
        self.bridge = bridge; self.bundledApplication = bundledApplication
    }

    public func permits(_ peer: UpdateAskpassKernelPeer, uid: uid_t = getuid(),
                        process: (pid_t) -> UpdateProcessSnapshot? = UpdateProcessSnapshot.read,
                        signature: (UpdateAskpassKernelPeer) -> UpdateAskpassCodeIdentity? = UpdateAskpassCodeIdentity.process) -> Bool {
        guard peer.uid == uid, let app = process(peer.pid), app.uid == peer.uid, !app.zombie,
              app.executable == applicationExecutable,
              let code = signature(peer), code.identifier == applicationIdentifier,
              process(peer.pid)?.identity == app.identity else { return false }
        if let team = bridge.team, !team.isEmpty {
            return code.team == team
        }
        guard let bundled = bundledApplication else { return false }
        return bridge.adHoc && bundled.adHoc && code.adHoc && bundled.identifier == applicationIdentifier
            && !code.cdhash.isEmpty && code.cdhash == bundled.cdhash
    }
}
