import Foundation

enum SystemProtectionCheck: String, CaseIterable, Codable, Sendable, Identifiable {
    case gatekeeper
    case firewall
    case systemIntegrityProtection
    case fileVault
    case xProtectInstallation

    var id: String { rawValue }

    static let healthChecks: [Self] = [.systemIntegrityProtection, .fileVault, .gatekeeper, .firewall]

    var title: String {
        switch self {
        case .gatekeeper: L10n.text("应用来源验证", "Gatekeeper")
        case .firewall: L10n.text("应用防火墙", "Application Firewall")
        case .systemIntegrityProtection: L10n.text("系统完整性保护", "System Integrity Protection")
        case .fileVault: L10n.text("磁盘加密", "FileVault")
        case .xProtectInstallation: L10n.text("恶意软件防护组件", "XProtect")
        }
    }

    /// Display-only name of the fixed read-only query (never executed from here).
    var queryDisplayName: String? {
        switch self {
        case .systemIntegrityProtection: "csrutil status"
        case .fileVault: "fdesetup status"
        case .gatekeeper: "spctl --status"
        case .firewall: "socketfilterfw --getglobalstate"
        case .xProtectInstallation: nil
        }
    }
}

enum SystemProtectionState: Codable, Sendable, Equatable {
    case enabled
    case disabled
    case transitioning
    case detected(String)
    case unknown
    case unreadable

    var displayText: String {
        switch self {
        case .enabled: L10n.text("已开启", "On")
        case .disabled: L10n.text("已关闭", "Off")
        case .transitioning: L10n.text("转换中", "Transitioning")
        case .detected(let version): L10n.text("检测到组件 · \(version)", "Component found · \(version)")
        case .unknown: L10n.text("未知", "Unknown")
        case .unreadable: L10n.text("无法读取", "Unreadable")
        }
    }
}

/// Structured evidence. Stored as a code and localized only when displayed,
/// so a journal written in one language reads correctly in the other.
enum SystemProtectionEvidence: Codable, Sendable, Equatable {
    case systemQuery
    case outputUnrecognized
    case readFailed(exitCode: Int32)
    case readTimedOut
    case outputTooLarge
    case readCancelled
    case commandUnavailable
    /// Text written by an older build before evidence became structured.
    case legacy(String)

    func text(check: SystemProtectionCheck, state: SystemProtectionState) -> String {
        switch self {
        case .systemQuery:
            switch state {
            case .enabled, .disabled, .transitioning:
                guard let query = check.queryDisplayName else { return state.displayText }
                return L10n.text("系统查询确认（\(query)）", "Confirmed by \(query)")
            default:
                return state.displayText
            }
        case .outputUnrecognized: return L10n.text("输出无法确认状态", "Output Did Not Establish a State")
        case .readFailed(let code): return L10n.text("读取失败（退出码 \(code)）", "Read Failed (Exit \(code))")
        case .readTimedOut: return L10n.text("读取超时", "Read Timed Out")
        case .outputTooLarge: return L10n.text("输出超过读取上限", "Output Exceeded Read Limit")
        case .readCancelled: return L10n.text("读取已取消", "Read Cancelled")
        case .commandUnavailable: return L10n.text("命令不可用或读取被拒绝", "Command Unavailable or Read Denied")
        case .legacy(let text): return text
        }
    }
}

struct SystemProtectionFinding: Codable, Sendable, Equatable, Identifiable {
    let check: SystemProtectionCheck
    let state: SystemProtectionState
    let evidence: SystemProtectionEvidence

    init(check: SystemProtectionCheck, state: SystemProtectionState, evidence: SystemProtectionEvidence) {
        self.check = check
        self.state = state
        self.evidence = evidence
    }

    /// Fixture/legacy convenience: free text is kept verbatim, nil means the
    /// state came from the fixed system query.
    init(check: SystemProtectionCheck, state: SystemProtectionState, evidenceSummary: String? = nil) {
        self.init(check: check, state: state, evidence: evidenceSummary.map(SystemProtectionEvidence.legacy) ?? .systemQuery)
    }

    var id: SystemProtectionCheck { check }
    var evidenceSummary: String { evidence.text(check: check, state: state) }

    private enum CodingKeys: String, CodingKey { case check, state, evidence, evidenceSummary }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        check = try container.decode(SystemProtectionCheck.self, forKey: .check)
        state = try container.decode(SystemProtectionState.self, forKey: .state)
        if let evidence = try container.decodeIfPresent(SystemProtectionEvidence.self, forKey: .evidence) {
            self.evidence = evidence
        } else {
            evidence = .legacy(try container.decode(String.self, forKey: .evidenceSummary))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(check, forKey: .check)
        try container.encode(state, forKey: .state)
        try container.encode(evidence, forKey: .evidence)
    }
}

struct SystemProtectionSnapshot: Codable, Sendable, Equatable {
    let findings: [SystemProtectionFinding]
    let checkedAt: Date
}

enum SystemProtectionAudit {
    typealias CommandRunner = @Sendable (SystemProtectionCheck) throws -> ShellCommandResult

    /// The caller supplies a check identity, never an executable or arguments.
    static func runCommand(for check: SystemProtectionCheck) throws -> ShellCommandResult {
        let executable: String
        let arguments: [String]
        switch check {
        case .systemIntegrityProtection:
            executable = "/usr/bin/csrutil"
            arguments = ["status"]
        case .fileVault:
            executable = "/usr/bin/fdesetup"
            arguments = ["status"]
        case .gatekeeper:
            executable = "/usr/sbin/spctl"
            arguments = ["--status"]
        case .firewall:
            executable = "/usr/libexec/ApplicationFirewall/socketfilterfw"
            arguments = ["--getglobalstate"]
        case .xProtectInstallation:
            throw ShellError.failed("unsupported-check", -1, "")
        }
        return try Shell.run(executable, arguments, timeout: 3, outputByteLimit: 8_192,
            cancellationCheck: { withUnsafeCurrentTask { $0?.isCancelled ?? false } },
            cleanupReaper: .shared, cleanupWaitTimeout: 1)
    }

    static func check(runner: @escaping CommandRunner = runCommand(for:)) async -> SystemProtectionSnapshot {
        let worker = Task.detached(priority: .utility) {
            let findings = SystemProtectionCheck.healthChecks.map { check in
                guard !Task.isCancelled else {
                    return unreadable(check, evidence: .readCancelled)
                }
                do {
                    return finding(from: try runner(check), for: check)
                } catch ShellError.timedOut {
                    return unreadable(check, evidence: .readTimedOut)
                } catch ShellError.outputTooLarge {
                    return unreadable(check, evidence: .outputTooLarge)
                } catch {
                    // Do not expose arbitrary error output (paths, device names,
                    // or diagnostics) in the persisted evidence.
                    return unreadable(check, evidence: .commandUnavailable)
                }
            }
            return SystemProtectionSnapshot(
                findings: findings + [SystemProtectionFinding(
                    check: .xProtectInstallation,
                    state: inspectXProtect(),
                    evidence: .systemQuery
                )],
                checkedAt: Date()
            )
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func finding(from result: ShellCommandResult, for check: SystemProtectionCheck) -> SystemProtectionFinding {
        // Even recognized stdout cannot establish a setting after a failed
        // command, except the one documented off-state exit below. Exit zero
        // alone likewise cannot establish an enabled state.
        guard result.terminationStatus == 0 || isDocumentedDisabledExit(result, for: check) else {
            return unreadable(check, evidence: .readFailed(exitCode: result.terminationStatus))
        }
        let state = parse(result.standardOutput, for: check)
        return SystemProtectionFinding(check: check, state: state,
            evidence: state == .unknown ? .outputUnrecognized : .systemQuery)
    }

    /// Apple's open-source `spctl` prints "assessments disabled" and exits 1
    /// for `--status` when Gatekeeper is off. Only that exact shape is
    /// accepted. `socketfilterfw --getglobalstate` exits 0 when the firewall is
    /// off (measured on macOS 27.2); the off-state exit codes of `fdesetup
    /// status` and `csrutil status` could not be confirmed, so any nonzero exit
    /// from them, and every other nonzero exit, stays unreadable.
    static func isDocumentedDisabledExit(_ result: ShellCommandResult, for check: SystemProtectionCheck) -> Bool {
        check == .gatekeeper && result.terminationStatus == 1
            && result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "assessments disabled"
    }

    private static func unreadable(_ check: SystemProtectionCheck, evidence: SystemProtectionEvidence) -> SystemProtectionFinding {
        SystemProtectionFinding(check: check, state: .unreadable, evidence: evidence)
    }

    static func parse(_ output: String, for check: SystemProtectionCheck) -> SystemProtectionState {
        // Match complete status lines, not a word in an error message, a
        // custom SIP configuration or a contradictory multiline response.
        let lines = output.lowercased().replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: ":", with: ": ")
            .replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
            .components(separatedBy: .newlines).map {
                $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".。 "))
            }.filter { !$0.isEmpty }
        // Real `fdesetup status` output during conversion is two lines, e.g.
        // "FileVault is On." followed by "Encryption in progress: Percent
        // completed = 12.3". Only that exact shape counts as transitioning.
        if check == .fileVault, lines.count == 2,
           ["filevault is on", "filevault is off"].contains(lines[0]),
           isFileVaultProgressLine(lines[1]) {
            return .transitioning
        }
        guard lines.count == 1, let line = lines.first else { return .unknown }
        switch check {
        case .gatekeeper:
            if ["assessments enabled", "评估已启用", "评估已开启"].contains(line) { return .enabled }
            if ["assessments disabled", "评估已禁用", "评估已关闭"].contains(line) { return .disabled }
        case .firewall:
            // State 2 means block-all mode and is still an enabled firewall.
            let compact = line.replacingOccurrences(of: " ", with: "")
            let enabled = ["firewallisenabled.(state=1)", "firewallisenabled.(state=2)",
                "firewallissettoblockallnon-essentialincomingconnections.(state=2)",
                "防火墙已启用。(state=1)", "防火墙已启用。(状态=1)", "防火墙已开启。(状态=1)",
                "防火墙已启用。(状态=2)", "防火墙已打开。(状态=1)", "firewallisenabled"]
            if enabled.contains(compact) { return .enabled }
            if ["firewallisdisabled.(state=0)", "防火墙已禁用。(状态=0)", "防火墙已禁用。(state=0)",
                "防火墙已关闭。(状态=0)", "防火墙已关闭。(state=0)", "firewallisdisabled"].contains(compact) { return .disabled }
        case .fileVault:
            if isFileVaultProgressLine(line) {
                return .transitioning
            }
            if ["filevault is on", "filevault 已开启", "filevault 已启用", "filevault 已打开"].contains(line) { return .enabled }
            if ["filevault is off", "filevault 已关闭", "filevault 已禁用"].contains(line) { return .disabled }
        case .systemIntegrityProtection:
            if ["system integrity protection status: enabled", "系统完整性保护状态: 已启用", "系统完整性保护状态: 已开启"].contains(line) { return .enabled }
            if ["system integrity protection status: disabled", "系统完整性保护状态: 已禁用", "系统完整性保护状态: 已关闭"].contains(line) { return .disabled }
        case .xProtectInstallation:
            break
        }
        return .unknown
    }

    private static func isFileVaultProgressLine(_ line: String) -> Bool {
        line.hasPrefix("encryption in progress:") || line.hasPrefix("decryption in progress:")
            || line.hasPrefix("正在加密:") || line.hasPrefix("正在解密:")
    }

    private static func inspectXProtect() -> SystemProtectionState {
        let locations = [
            "/Library/Apple/System/Library/CoreServices/XProtect.app",
            "/Library/Apple/System/Library/CoreServices/XProtect.bundle",
        ]
        let versions = locations.compactMap { path -> String? in
            guard let bundle = Bundle(path: path) else { return nil }
            return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        }
        return versions.isEmpty ? .unknown : .detected(versions.joined(separator: " / "))
    }
}
