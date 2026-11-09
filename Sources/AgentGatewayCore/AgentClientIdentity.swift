import Darwin
import FileOperationShared
import Foundation
import Security

/// Who is asking, as the App works it out (D263). Shown in Settings and in
/// the access log; approvals bind to `bindingKey`.
public struct AgentClientIdentity: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case signed
        case adHoc = "ad_hoc"
        case unsigned
    }

    public var kind: Kind
    public var identifier: String?
    public var team: String?
    /// Hex; kept only for ad-hoc code, whose bytes are its only identity.
    public var cdhash: String?
    /// The home folder is written as `~` (D266).
    public var executablePath: String
    public var displayName: String

    public init(kind: Kind, identifier: String?, team: String?, cdhash: String?, executablePath: String, displayName: String) {
        self.kind = kind; self.identifier = identifier; self.team = team; self.cdhash = cdhash
        self.executablePath = executablePath; self.displayName = displayName
    }

    /// Signed code binds to its signer, so an update in a new folder keeps
    /// its approval; ad-hoc code to its exact bytes; anything else to its path.
    public var bindingKey: String {
        switch kind {
        case .signed: "signed:\(identifier ?? "")|\(team ?? "")"
        case .adHoc: "adhoc:\(identifier ?? "")|\(cdhash ?? "")"
        case .unsigned: "path:\(executablePath)"
        }
    }
}

/// D263: walks up from the bridge, skipping shells, launchers and language
/// runtimes, and takes the first other program as the client. What the bridge
/// or the client says about itself plays no part.
public struct AgentClientIdentifier: Sendable {
    /// Approving one of these would approve everything it runs. Bare names
    /// only: D98④ scans Sources line by line and fails on a path that ends in
    /// a shell's name.
    public static let genericProgramNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "ksh", "csh", "tcsh", "nu",
        "env", "login", "sudo", "su", "nohup", "timeout", "gtimeout", "script", "caffeinate", "arch", "time", "nice", "xcrun",
        "node", "nodejs", "bun", "deno", "npx", "npm", "pnpm", "yarn", "corepack",
        "python", "python3", "uv", "uvx", "pipx", "ruby", "perl"
    ]
    public static let maximumDepth = 16

    public static func isGeneric(_ name: String) -> Bool {
        let name = name.lowercased()
        return genericProgramNames.contains(name) || name.hasPrefix("python")
    }

    private let home: String
    private let process: @Sendable (pid_t) -> UpdateProcessSnapshot?
    private let signature: @Sendable (pid_t) -> UpdateAskpassCodeIdentity?

    public init(home: String, process: @escaping @Sendable (pid_t) -> UpdateProcessSnapshot? = { UpdateProcessSnapshot.read($0) },
                signature: @escaping @Sendable (pid_t) -> UpdateAskpassCodeIdentity? = AgentProcessSignature.read) {
        self.home = home; self.process = process; self.signature = signature
    }

    /// Nil when no client can be named: the chain ends in launchd, only
    /// generic programs were found, or a process changed while it was read.
    public func identify(bridge pid: pid_t) -> AgentClientIdentity? {
        guard let bridge = process(pid) else { return nil }
        var current = bridge.parentPID
        for _ in 0..<Self.maximumDepth {
            guard current > 1, let snapshot = process(current) else { return nil }
            if Self.isGeneric((snapshot.executable as NSString).lastPathComponent) {
                current = snapshot.parentPID
                continue
            }
            let code = signature(current)
            // The PID may have been reused between the two reads.
            guard process(current)?.identity == snapshot.identity else { return nil }
            return identity(snapshot.executable, code)
        }
        return nil
    }

    private func identity(_ path: String, _ code: UpdateAskpassCodeIdentity?) -> AgentClientIdentity {
        let shown = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        let name = Self.displayName(for: path)
        guard let code else {
            return .init(kind: .unsigned, identifier: nil, team: nil, cdhash: nil, executablePath: shown, displayName: name)
        }
        if code.adHoc {
            return .init(kind: .adHoc, identifier: code.identifier, team: nil,
                         cdhash: code.cdhash.map { String(format: "%02x", $0) }.joined(), executablePath: shown, displayName: name)
        }
        return .init(kind: .signed, identifier: code.identifier, team: code.team, cdhash: nil, executablePath: shown, displayName: name)
    }

    /// Helpers show as the app they belong to: the outermost `.app` wins.
    static func displayName(for path: String) -> String {
        if let bundleEnd = path.range(of: ".app/") {
            if let name = path[..<bundleEnd.lowerBound].split(separator: "/").last { return String(name) }
        }
        return (path as NSString).lastPathComponent
    }
}

/// The running code of a process found by PID alone: ancestors have no audit
/// token to offer, so callers read the process again afterwards.
public enum AgentProcessSignature {
    public static func read(_ pid: pid_t) -> UpdateAskpassCodeIdentity? {
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest,
              SecCodeCheckValidity(guest, [], nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let digest = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return .init(identifier: identifier, team: info[kSecCodeInfoTeamIdentifier as String] as? String, cdhash: digest,
                     adHoc: flags & 2 != 0)
    }
}
