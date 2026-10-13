import Darwin
import FileOperationShared
import Foundation

struct AppUpdateTrackedProcess: Codable, Hashable, Sendable {
    let pid: Int32
    let startTime: UInt64
    init(_ identity: UpdateProcessIdentity) { pid = identity.pid; startTime = identity.startTime }
    var identity: UpdateProcessIdentity { .init(pid: pid, startTime: startTime) }
}

/// A normal parent exit and an empty observed set do not imply complete tracking.
/// Persist identities, including descendants observed during completion waiting,
/// so recovery can check them without confusing a reused PID with the old process.
struct AppUpdateCommandCompletionEvidence: Codable, Hashable, Sendable {
    var trackingComplete: Bool
    var knownProcessesAlive: Bool
    var processes: [AppUpdateTrackedProcess]
    static let stopped = Self(trackingComplete: true, knownProcessesAlive: false, processes: [])
    var permitsRetry: Bool { trackingComplete && !knownProcessesAlive }
}

enum AppUpdateInstallationProcessStatus: Equatable, Sendable {
    case stopped, running, unavailable
    var detail: String {
        switch self {
        case .stopped: L10n.text("已确认安装进程结束", "Installation processes have been confirmed stopped")
        case .running: L10n.text("仍有更新或安装进程运行，继续隔离；结束后可再次核验", "Update or installation processes are still running; quarantine remains until another verification after they exit")
        case .unavailable: L10n.text("无法完整读取安装进程状态，继续隔离", "Installation process state could not be read completely; quarantine remains")
        }
    }
}

struct AppUpdateInstallationProcessSafety: Sendable {
    // nil selects the native table with the task's frozen Homebrew prefix.
    // An injected table returning nil is unavailable; never fall back to the host.
    var processTable: (@Sendable () -> [UpdateProcessSnapshot]?)? = nil
    var completionWaitTimeout: TimeInterval = 60
    var pollInterval: TimeInterval = 0.2
    static let defaultHomebrewPrefixes = ["/opt/homebrew", "/usr/local"]
    /// Homebrew's own executables: the brew entry point and its repository
    /// (including portable Ruby). Formula kegs under Cellar/opt and binary casks
    /// under Caskroom (claude-code, codex, conda) are user programs and only
    /// count as installing when they descend from an installer client.
    static func homebrewOwnPaths(_ prefixes: [String]) -> (files: [String], trees: [String]) {
        let roots = (defaultHomebrewPrefixes + prefixes).map { URL(fileURLWithPath: $0).standardizedFileURL.path.lowercased() }
        return (roots.map { $0 + "/bin/brew" },
                roots.map { $0 + "/library/homebrew/" } + ["/usr/local/homebrew/"])
    }

    private func readTable(homebrewPrefixes: [String]) -> [UpdateProcessSnapshot]? {
        if let processTable { return processTable() }
        return Self.nativeProcessTable(homebrewPrefixes: homebrewPrefixes)
    }

    func knownProcessStatus(_ evidence: AppUpdateCommandCompletionEvidence) -> AppUpdateInstallationProcessStatus {
        var evidence = evidence
        return knownProcessStatus(&evidence)
    }
    private func knownProcessStatus(_ evidence: inout AppUpdateCommandCompletionEvidence, homebrewPrefixes: [String] = []) -> AppUpdateInstallationProcessStatus {
        // A legacy live-child receipt without identities cannot prove its end.
        guard !evidence.processes.isEmpty || !evidence.knownProcessesAlive else { return .unavailable }
        guard let table = readTable(homebrewPrefixes: homebrewPrefixes) else { return .unavailable }
        let identities = AppUpdateCommandProcessTree.includingDescendants(of: Set(evidence.processes.map(\.identity)), in: table)
        evidence.processes = Self.recorded(identities)
        evidence.knownProcessesAlive = table.contains { identities.contains($0.identity) && !$0.zombie }
        return evidence.knownProcessesAlive ? .running : .stopped
    }

    // inout retains newly observed identities even on cancellation or timeout.
    // No stop signal is sent during normal completion waiting.
    func waitForKnownProcesses(_ evidence: inout AppUpdateCommandCompletionEvidence, homebrewPrefixes: [String] = []) async throws -> Bool {
        let deadline = Date().addingTimeInterval(min(120, max(0, completionWaitTimeout)))
        while true {
            try Task.checkCancellation()
            let status = knownProcessStatus(&evidence, homebrewPrefixes: homebrewPrefixes)
            if status == .stopped { return true }
            if status == .unavailable || Date() >= deadline { return false }
            try await Task.sleep(for: .seconds(min(max(0.001, pollInterval), max(0, deadline.timeIntervalSinceNow))))
        }
    }

    /// Recovery checks installer clients and their descendants, plus identities
    /// saved by this task. Resident installation services are not evidence of
    /// an active transaction: readback supplies the remaining completion check.
    func releaseStatus(_ evidence: AppUpdateCommandCompletionEvidence?) -> AppUpdateInstallationProcessStatus {
        var evidence = evidence ?? .stopped
        return releaseStatus(&evidence)
    }
    func releaseStatus(_ evidence: inout AppUpdateCommandCompletionEvidence, homebrewPrefixes: [String] = []) -> AppUpdateInstallationProcessStatus {
        guard let table = readTable(homebrewPrefixes: homebrewPrefixes) else { return .unavailable }
        let roots = Set(table.filter { !$0.zombie && Self.isInstaller($0.executable, homebrewPrefixes: homebrewPrefixes) }.map(\.identity))
        let identities = AppUpdateCommandProcessTree.includingDescendants(of: Set(evidence.processes.map(\.identity)).union(roots), in: table)
        evidence.processes = Self.recorded(identities)
        evidence.knownProcessesAlive = table.contains { !$0.zombie && identities.contains($0.identity) }
        guard !evidence.knownProcessesAlive else { return .running }
        return .stopped
    }

    private static func recorded(_ identities: Set<UpdateProcessIdentity>) -> [AppUpdateTrackedProcess] {
        identities.map(AppUpdateTrackedProcess.init).sorted { $0.pid == $1.pid ? $0.startTime < $1.startTime : $0.pid < $1.pid }
    }
    private static func isInstaller(_ executable: String, homebrewPrefixes: [String] = [], pathlessRubyIsInstaller: Bool = true) -> Bool {
        let path = executable.lowercased()
        let name = URL(fileURLWithPath: path).lastPathComponent
        let own = homebrewOwnPaths(homebrewPrefixes)
        return ["brew", "brew.rb", "brew.sh", "mas", "installer", "softwareupdate"].contains(name)
            || own.files.contains(path) || own.trees.contains { path.hasPrefix($0) }
            // BSD comm without a visible path cannot prove which Ruby this is.
            // (The native table already reports unavailable for unreadable Ruby
            // argv; argv words pass false so a plain `ruby` word never matches.)
            || (pathlessRubyIsInstaller && name == "ruby" && !path.contains("/"))
    }

    /// proc_pidpath reports the interpreter, not its script. Inspect complete
    /// argv (including shell -c text), never envp or logs. Missing/truncated argv
    /// is unavailable, even when an interpreter's path already looks relevant.
    static func releaseExecutable(_ executable: String, arguments: [String]?, homebrewPrefixes: [String] = []) -> String? {
        guard ["bash", "sh", "zsh", "ruby"].contains(URL(fileURLWithPath: executable).lastPathComponent.lowercased()) else { return executable }
        guard let arguments else { return nil }
        if isInstaller(executable, homebrewPrefixes: homebrewPrefixes) { return executable }
        // Split shell -c text into words so `/opt/homebrew/bin/npx` or a script
        // merely named homebrew.sh is not mistaken for Homebrew itself.
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";&|()<>'\"`="))
        for argument in arguments {
            for token in argument.components(separatedBy: separators) where !token.isEmpty {
                if isInstaller(token, homebrewPrefixes: homebrewPrefixes, pathlessRubyIsInstaller: false) { return "brew" }
            }
        }
        return executable
    }

    /// Parse exactly argc strings, stopping before envp. A shortened kernel
    /// response or unterminated argument cannot become a negative process proof.
    static func parseCommandArguments(_ bytes: [UInt8], byteCount: Int) -> [String]? {
        guard byteCount <= bytes.count, byteCount >= MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, Int(argc) <= byteCount - MemoryLayout<Int32>.size else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < byteCount && bytes[index] != 0 { index += 1 }
        guard index < byteCount else { return nil }
        while index < byteCount && bytes[index] == 0 { index += 1 }
        var arguments = [String]()
        for _ in 0..<Int(argc) {
            guard index < byteCount else { return nil }
            let start = index
            while index < byteCount && bytes[index] != 0 { index += 1 }
            guard index < byteCount, let argument = String(bytes: bytes[start..<index], encoding: .utf8) else { return nil }
            arguments.append(argument)
            index += 1
        }
        return arguments
    }
    private static func nativeCommandArguments(_ pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size >= MemoryLayout<Int32>.size, size <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        defer { bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        return parseCommandArguments(bytes, byteCount: size)
    }

    /// Unlike the inventory's compactMap table, an unreadable live PID must not
    /// silently disappear from a global no-installer assertion. BSD comm supplies
    /// a process name when an executable path is not visible for another user.
    static func nativeProcessTable(homebrewPrefixes: [String] = []) -> [UpdateProcessSnapshot]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 256)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0, found < pids.count else { return nil }
        var result = [UpdateProcessSnapshot]()
        for pid in pids.prefix(Int(found)) where pid > 0 {
            if let snapshot = UpdateProcessSnapshot.read(pid) {
                let name = URL(fileURLWithPath: snapshot.executable).lastPathComponent.lowercased()
                let interpreter = ["bash", "sh", "zsh", "ruby"].contains(name) && !snapshot.zombie
                guard let executable = interpreter ? releaseExecutable(snapshot.executable, arguments: nativeCommandArguments(pid), homebrewPrefixes: homebrewPrefixes) : snapshot.executable else { return nil }
                if interpreter {
                    guard let checked = UpdateProcessSnapshot.read(pid), checked.identity == snapshot.identity else {
                        if kill(pid, 0) == -1 && errno == ESRCH { continue }
                        return nil
                    }
                }
                result.append(.init(pid: pid, startTime: snapshot.identity.startTime, parentPID: snapshot.parentPID,
                    groupPID: snapshot.groupPID, uid: snapshot.uid, executable: executable, zombie: snapshot.zombie))
                continue
            }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
                let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
                guard !name.isEmpty || info.pbi_status == SZOMB else { return nil }
                guard let executable = info.pbi_status == SZOMB ? name : releaseExecutable(name, arguments: nil, homebrewPrefixes: homebrewPrefixes) else { return nil }
                result.append(.init(pid: pid, startTime: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
                    parentPID: pid_t(info.pbi_ppid), groupPID: pid_t(info.pbi_pgid), uid: info.pbi_uid,
                    executable: executable, zombie: info.pbi_status == SZOMB))
            } else if !(kill(pid, 0) == -1 && errno == ESRCH) { return nil }
        }
        return result
    }
}
