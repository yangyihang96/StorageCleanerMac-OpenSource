import Darwin
import Foundation
import Security

public struct UpdateAskpassKernelPeer: Sendable {
    public let pid: pid_t
    public let uid: uid_t
    public let auditToken: Data
    public init(pid: pid_t, uid: uid_t, auditToken: Data) { self.pid = pid; self.uid = uid; self.auditToken = auditToken }
    public static func read(socket: Int32) -> Self? {
        var uid: uid_t = 0; var gid: gid_t = 0
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getpeereid(socket, &uid, &gid) == 0, let pid = UpdateAskpassPeer.processID(socket: socket),
            getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
            size == MemoryLayout<audit_token_t>.size else { return nil }
        return .init(pid: pid, uid: uid, auditToken: withUnsafeBytes(of: &token) { Data($0) })
    }
}
public struct UpdateAskpassCodeIdentity: Sendable {
    public let identifier: String
    public let team: String?
    public let cdhash: Data
    public let adHoc: Bool
    public init(identifier: String, team: String?, cdhash: Data, adHoc: Bool = false) {
        self.identifier = identifier; self.team = team; self.cdhash = cdhash; self.adHoc = adHoc
    }
    private static func info(_ code: SecStaticCode) -> Self? {
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess else { return nil }
        var data: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &data) == errSecSuccess,
            let info = data as? [String: Any], let identifier = info[kSecCodeInfoIdentifier as String] as? String,
            let digest = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return .init(identifier: identifier, team: info[kSecCodeInfoTeamIdentifier as String] as? String, cdhash: digest,
            adHoc: ((info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0) & 2 != 0)
    }
    public static func file(_ url: URL) -> Self? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return info(code)
    }
    public static func process(_ peer: UpdateAskpassKernelPeer) -> Self? {
        var guest: SecCode?; var code: SecStaticCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: peer.pid), kSecGuestAttributeAudit as String: peer.auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest,
            SecCodeCheckValidity(guest, [], nil) == errSecSuccess,
            SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code else { return nil }
        return info(code)
    }
}

public struct UpdateAskpassPeerPolicy: Sendable {
    public let executable: String
    public let application: UpdateAskpassCodeIdentity
    public let bundledAskpass: UpdateAskpassCodeIdentity
    public init(executable: String, application: UpdateAskpassCodeIdentity, bundledAskpass: UpdateAskpassCodeIdentity) {
        self.executable = executable; self.application = application; self.bundledAskpass = bundledAskpass
    }
    public func permits(_ peer: UpdateAskpassKernelPeer,
        process: (pid_t) -> UpdateProcessSnapshot? = UpdateProcessSnapshot.read,
        signature: (UpdateAskpassKernelPeer) -> UpdateAskpassCodeIdentity? = UpdateAskpassCodeIdentity.process) -> Bool {
        guard let caller = process(peer.pid), caller.uid == peer.uid, caller.executable == executable,
            let parent = process(caller.parentPID), parent.executable == "/usr/bin/sudo",
            let code = signature(peer), code.identifier == bundledAskpass.identifier,
            code.cdhash == bundledAskpass.cdhash,
            process(peer.pid)?.identity == caller.identity, process(parent.identity.pid)?.identity == parent.identity else { return false }
        if let team = application.team, !team.isEmpty {
            return code.team == team && bundledAskpass.team == team
        }
        // For ad-hoc builds the App's valid nested/resource seal authenticates
        // the bundled askpass cdhash; the live peer must be those exact bytes.
        return application.adHoc && bundledAskpass.adHoc && code.adHoc && !code.cdhash.isEmpty
    }
}

public enum UpdateAskpassInvocation {
    public static func permits(parentExecutable: String, stdoutMode: mode_t) -> Bool {
        parentExecutable == "/usr/bin/sudo" && stdoutMode & S_IFMT == S_IFIFO
    }
}
