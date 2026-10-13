import Darwin
import Foundation
import FileOperationShared

enum AppUpdateCommandError: LocalizedError, Sendable, Equatable {
    case failed(Int32, String), cancelled, outputLimit, timedOut, needsReconciliation, recoveryRequired(String)
    case normalExitAwaitingVerification(Int32, String)
    case normalExit(Int32, String, AppUpdateCommandCompletionEvidence)
    case unconfirmedCommand(AppUpdateCommandCompletionEvidence)
    var isNormalExit: Bool {
        switch self { case .failed, .normalExitAwaitingVerification, .normalExit: true; default: false }
    }
    var hasLiveDescendants: Bool {
        if case .normalExitAwaitingVerification = self { return true }
        if case let .normalExit(_, _, evidence) = self { return evidence.knownProcessesAlive }
        return false
    }
    var completionEvidence: AppUpdateCommandCompletionEvidence? {
        switch self {
        case let .normalExit(_, _, evidence), let .unconfirmedCommand(evidence): evidence
        case .normalExitAwaitingVerification: .init(trackingComplete: false, knownProcessesAlive: true, processes: [])
        case .failed: .stopped // Injected legacy runners explicitly report a stopped failure.
        default: nil
        }
    }
    var permitsRetryAfterReadbackFailure: Bool { completionEvidence?.permitsRetry == true }
    var normalExitCode: Int32? {
        switch self { case let .failed(code, _), let .normalExitAwaitingVerification(code, _), let .normalExit(code, _, _): code; default: nil }
    }
    var isUnconfirmedStop: Bool {
        switch self { case .needsReconciliation, .unconfirmedCommand: true; default: false }
    }
    var errorDescription: String? {
        switch self {
        case let .failed(code, detail): L10n.text("更新命令失败 (\(code))：\(detail)", "Update command failed (\(code)): \(detail)")
        case .cancelled: L10n.text("更新命令已停止并确认取消", "Update command stopped; cancellation acknowledged")
        case .outputLimit: L10n.text("更新命令输出超限，已停止", "Update command output limit exceeded; stopped")
        case .timedOut: L10n.text("更新命令超时，已停止", "Update command timed out; stopped")
        case .needsReconciliation: L10n.text("系统安装尚未确认停止，待核验并恢复；不会自动重试", "System installation stop is unconfirmed; Verify and Recover required; no automatic retry")
        case let .normalExitAwaitingVerification(code, detail): L10n.text("主命令已正常退出 (\(code))，后代仍未结束，正在核验版本：", "Main command exited normally (\(code)); descendants still need completion readback: ") + detail
        case let .normalExit(code, detail, _): L10n.text("主命令已退出 (\(code))，正在核验安装结果：", "Main command exited (\(code)); verifying installation result: ") + detail
        case .unconfirmedCommand: AppUpdateCommandError.needsReconciliation.localizedDescription
        case let .recoveryRequired(paths): L10n.text("回滚未完成，已保留恢复文件，禁止重试：", "Rollback is incomplete; recovery files retained; retry is forbidden: ") + paths
        }
    }
}

enum AppUpdateErrorRedaction {
    static func text(_ input: String) -> String {
        var text = String(input.prefix(8192))
        for pattern in [#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, #"(https?://[^\s?]+)\?[^\s]+"#,
            #"(?i)(password|token|authorization|cookie)\s*[:=]\s*[^\s]+"#] {
            text = text.replacingOccurrences(of: pattern, with: "[已隐去]", options: [.regularExpression, .caseInsensitive])
        }
        return text
    }
}

struct AppUpdateOutputBudget: Sendable {
    let limit: Int
    private(set) var bytes = Data()
    mutating func append(_ chunk: Data) throws {
        guard chunk.count <= limit - bytes.count else { throw AppUpdateCommandError.outputLimit }
        bytes.append(chunk)
    }
}

enum AppUpdateStopReceipt {
    static func result(confirmedStopped: Bool, reason: AppUpdateCommandError, systemInstaller: Bool = false) -> AppUpdateCommandError {
        // Stopping sudo/mas/brew does not prove that an installer handed off to
        // a system service stopped. Keep those items out of any retry queue.
        confirmedStopped && !systemInstaller ? reason : .needsReconciliation
    }
    static func mayUseSystemInstaller(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains(where: { ["--install", "--update"].contains($0) })
            || (environment["SUDO_ASKPASS"] != nil && arguments.contains("upgrade"))
    }
}

/// Pipe-backed producer bound: no subprocess output is ever written to disk.
/// Visible descendants are tracked by PID and start time across process groups.
/// Normal exit uses readback; unproven cancellation remains quarantined.
struct AppUpdateCommandRunner: HomebrewCommandRunning {
    var outputLimit = 64 * 1024
    var stopTimeout: TimeInterval = 3
    var processTree: @Sendable (pid_t) throws -> any AppUpdateCommandTreeObserving = { try NativeAppUpdateCommandTree(root: $0) }
    func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Data {
        let cancellation = HomebrewCommandCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try runSync(executableURL: executableURL, arguments: arguments, environment: environment,
                    timeout: timeout, cancelled: { cancellation.isCancelled })
            }.value
        } onCancel: { cancellation.cancel() }
    }
    func runSync(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval,
        inputFD: Int32? = nil, permitsPersistentSystemService: Bool = false, captureCompletionEvidence: Bool = false, cancelled: @Sendable () -> Bool) throws -> Data {
        guard !cancelled() else { throw AppUpdateCommandError.cancelled }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        defer { close(descriptors[0]); close(descriptors[1]) }
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
        if let inputFD { posix_spawn_file_actions_adddup2(&actions, inputFD, STDIN_FILENO) }
        else { posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_START_SUSPENDED))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executableURL.path] + arguments).map { strdup($0) }
        let env = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) }
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var args = argv + [nil]; var vars = env + [nil]; var pid: pid_t = 0
        guard !cancelled() else { throw AppUpdateCommandError.cancelled }
        let code = posix_spawn(&pid, executableURL.path, &actions, &attributes, &args, &vars)
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        let tree: any AppUpdateCommandTreeObserving
        do { tree = try processTree(pid) }
        catch { _ = kill(pid, SIGKILL); _ = waitpid(pid, nil, 0); throw AppUpdateCommandError.needsReconciliation }
        let invocation = UpdateProcessSnapshot.read(pid)?.identity
        let socket = environment["STORAGE_CLEANER_ASKPASS_SOCKET"]
        if let invocation, let socket { UpdateAskpassInvocationRegistry.shared.begin(socket: socket, root: invocation) }
        defer { if let invocation, let socket { UpdateAskpassInvocationRegistry.shared.end(socket: socket, root: invocation) } }
        // Attach the process observer before allowing any fork.
        guard kill(pid, SIGCONT) == 0 else { tree.signal(SIGKILL); throw AppUpdateCommandError.needsReconciliation }
        defer { _ = waitpid(pid, nil, WNOHANG) }
        let deadline = Date().addingTimeInterval(timeout)
        let systemInstaller = AppUpdateStopReceipt.mayUseSystemInstaller(arguments: arguments, environment: environment)
        var budget = AppUpdateOutputBudget(limit: outputLimit)
        var reason: AppUpdateCommandError?
        while true {
            tree.observeRunning()
            var chunk = [UInt8](repeating: 0, count: 8192)
            let n = read(descriptors[0], &chunk, chunk.count)
            if n > 0 {
                do { try budget.append(Data(chunk.prefix(n))) } catch { reason = .outputLimit; break }
            }
            var info = siginfo_t()
            _ = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if info.si_pid == pid {
                if reason == nil && cancelled() { reason = .cancelled }
                // Drain only bounded buffered output; never wait for inherited EOF.
                while true {
                    let n = read(descriptors[0], &chunk, chunk.count)
                    if n <= 0 { break }
                    do { try budget.append(Data(chunk.prefix(n))) } catch { reason = .outputLimit; break }
                }
                if reason != nil { break }
                guard info.si_code == CLD_EXITED else { reason = .needsReconciliation; break }
                // A normal exit is not a cancellation. Wait for visible live
                // descendants without signalling any of them. NOTE_FORK's
                // incomplete stop coverage cannot override trusted readback.
                let descendantsDeadline = Date().addingTimeInterval(stopTimeout)
                while !permitsPersistentSystemService && !tree.observedProcessesStopped() && Date() < descendantsDeadline {
                    if cancelled() { reason = .cancelled; break }
                    let n = read(descriptors[0], &chunk, chunk.count)
                    if n > 0 {
                        do { try budget.append(Data(chunk.prefix(n))) } catch { reason = .outputLimit; break }
                    }
                    usleep(20_000)
                }
                if reason != nil { break }
                // A child can exit between the loop condition and the final
                // read. Drain the remaining bounded bytes without waiting for EOF.
                while true {
                    let n = read(descriptors[0], &chunk, chunk.count)
                    if n <= 0 { break }
                    do { try budget.append(Data(chunk.prefix(n))) } catch { reason = .outputLimit; break }
                }
                if reason != nil { break }
                let exitCode = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
                let completion = tree.completionEvidence()
                if !permitsPersistentSystemService && (captureCompletionEvidence || arguments.contains("upgrade") || arguments.contains("--install") || arguments.contains("--update")) {
                    throw AppUpdateCommandError.normalExit(exitCode, AppUpdateCredentialRedactor.shared.redact(bytes: budget.bytes), completion)
                }
                if !permitsPersistentSystemService && !tree.observedProcessesStopped() {
                    throw AppUpdateCommandError.normalExitAwaitingVerification(exitCode, AppUpdateCredentialRedactor.shared.redact(bytes: budget.bytes))
                }
                guard exitCode == 0 else { throw AppUpdateCommandError.failed(exitCode, AppUpdateCredentialRedactor.shared.redact(bytes: budget.bytes)) }
                return budget.bytes
            }
            if cancelled() { reason = .cancelled; break }
            if Date() >= deadline { reason = .timedOut; break }
            var poller = pollfd(fd: descriptors[0], events: Int16(POLLIN), revents: 0)
            _ = poll(&poller, 1, 20)
        }
        tree.signal(SIGTERM)
        let stopDeadline = Date().addingTimeInterval(stopTimeout)
        while Date() < stopDeadline {
            if tree.confirmedStopped() { throw AppUpdateStopReceipt.result(confirmedStopped: true, reason: reason ?? .cancelled, systemInstaller: systemInstaller) }
            var poller = pollfd(fd: descriptors[0], events: 0, revents: 0)
            _ = poll(&poller, 1, 20)
        }
        // Only tracked command identities; never signal user applications. Root-owned
        // descendants may reject this, in which case completion is unproven.
        tree.signal(SIGKILL)
        let finalDeadline = Date().addingTimeInterval(1)
        while Date() < finalDeadline {
            if tree.confirmedStopped() { throw AppUpdateStopReceipt.result(confirmedStopped: true, reason: reason ?? .cancelled, systemInstaller: systemInstaller) }
            usleep(20_000)
        }
        // Retain/reap only the PID owned by this spawn; never launch or retry an
        // installer from this observer. Its output descriptors are already bounded.
        let ownedPID = pid
        DispatchQueue.global(qos: .utility).async { _ = waitpid(ownedPID, nil, 0) }
        throw AppUpdateCommandError.unconfirmedCommand(tree.completionEvidence())
    }
}
