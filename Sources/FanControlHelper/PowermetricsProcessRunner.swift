@preconcurrency import Darwin
import FanControlShared
import Foundation

/// Confined to powerSamplingQueue; it never borrows either control queue/lock.
///
/// The child is started with posix_spawn in its own process group and reaped
/// only by this runner (waitpid on its pid). SIGKILL is sent to the group only
/// while the child is known to be unreaped, under `childLock`, so the target
/// pid/pgid cannot have been recycled by the system.
final class PowermetricsProcessRunner: @unchecked Sendable {
    static let executablePath = "/usr/bin/powermetrics"
    static let arguments = ["--samplers", "cpu_power,gpu_power,ane_power", "-n", "1", "-i", "1000", "-f", "plist"]
    static let environment = ["LANG=C", "LC_ALL=C", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
    /// Bounded wait for the kernel to deliver SIGKILL before giving up on reaping.
    static let reapAttemptsAfterKill = 100
    // Only child launch/reap/termination shares this lock. Neither control queue
    // waits for sampling or acquires it during ordinary hardware operations.
    private let childLock = NSLock()
    /// Spawned and not yet reaped. Guarded by childLock.
    private var activeChild: pid_t?
    private var isStopping = false
    /// Random per helper process lifetime, never a machine identifier.
    private static let helperBootID = UUID().uuidString

    func makeCoordinator() -> PowermetricsSamplingCoordinator {
        let queue = DispatchQueue(label: "StorageCleanerMac.helper.powerSampling", qos: .utility)
        let runner = self
        return PowermetricsSamplingCoordinator {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: runner.sample()) }
            }
        }
    }

    func stopForTermination() {
        childLock.withLock {
            isStopping = true
            if let pid = activeChild { _ = Darwin.kill(-pid, SIGKILL) }
        }
    }

    /// Only the daemon's cancelled, drained handoff can reopen sampling. Keep
    /// activeChild: sample() still refuses overlap until that child is reaped.
    func resumeAfterCancelledTermination() {
        childLock.withLock { isStopping = false }
    }

    /// Non-blocking reap of the active child. Returns its wait status once reaped.
    private func reapIfExited(_ pid: pid_t) -> Int32? {
        childLock.withLock {
            guard activeChild == pid else { return nil }
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, WNOHANG) } while result == -1 && errno == EINTR
            if result == pid || (result == -1 && errno == ECHILD) {
                activeChild = nil
                return result == pid ? status : -1
            }
            return nil
        }
    }

    /// Kills the whole group only while the leader is still unreaped.
    private func killGroupIfUnreaped(_ pid: pid_t) {
        childLock.withLock {
            if activeChild == pid { _ = Darwin.kill(-pid, SIGKILL) }
        }
    }

    func sample() -> PowermetricsResult {
        // A child which has not been reaped after SIGKILL cannot overlap a new one.
        if let previous = childLock.withLock({ activeChild }) {
            guard reapIfExited(previous) != nil else { return .failure(.busy) }
        }
        var outputPipe: [Int32] = [-1, -1], errorPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else { return .failure(.launchFailed) }
        guard pipe(&errorPipe) == 0 else {
            close(outputPipe[0]); close(outputPipe[1]); return .failure(.launchFailed)
        }
        defer { for descriptor in [outputPipe[0], errorPipe[0]] { close(descriptor) } }
        var writeEndsOpen = true
        func closeWriteEnds() {
            guard writeEndsOpen else { return }
            writeEndsOpen = false
            close(outputPipe[1]); close(errorPipe[1])
        }
        defer { closeWriteEnds() }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .failure(.launchFailed) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return .failure(.launchFailed) }
        defer { posix_spawnattr_destroy(&attributes) }
        var allSignals = sigset_t(), noSignals = sigset_t()
        sigfillset(&allSignals)
        sigemptyset(&noSignals)
        // Own process group (pgid == child pid), default signal dispositions
        // (the helper ignores SIGTERM/SIGINT), empty mask, and every descriptor
        // other than 0/1/2 closed in the child.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigdefault(&attributes, &allSignals) == 0,
              posix_spawnattr_setsigmask(&attributes, &noSignals) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, "/") == 0 else {
            return .failure(.launchFailed)
        }
        let argumentVector: [UnsafeMutablePointer<CChar>?] = ([Self.executablePath] + Self.arguments).map { strdup($0) } + [nil]
        let environmentVector: [UnsafeMutablePointer<CChar>?] = Self.environment.map { strdup($0) } + [nil]
        defer { for pointer in argumentVector + environmentVector { free(pointer) } }
        guard argumentVector.dropLast().allSatisfy({ $0 != nil }),
              environmentVector.dropLast().allSatisfy({ $0 != nil }) else { return .failure(.launchFailed) }

        let startedAt = PowermetricsMonotonicClock.seconds
        var launchClock: PowermetricsMeasurementContext.Anchor?
        var spawnedPID: pid_t = 0
        let spawnStatus: Int32 = childLock.withLock {
            guard !isStopping else { return ECANCELED }
            launchClock = .capture()
            let status = posix_spawn(&spawnedPID, Self.executablePath, &actions, &attributes,
                                     argumentVector, environmentVector)
            if status == 0 { activeChild = spawnedPID }
            return status
        }
        if spawnStatus == ECANCELED { return .failure(.unavailable) }
        guard spawnStatus == 0 else { return .failure(.launchFailed) }
        let pid = spawnedPID
        closeWriteEnds()

        func forceStop() {
            killGroupIfUnreaped(pid)
            for _ in 0..<Self.reapAttemptsAfterKill {
                guard childLock.withLock({ activeChild == pid }) else { return }
                if reapIfExited(pid) != nil { return }
                usleep(10_000)
            }
            // Still unreaped: keep it as activeChild; the next sample() refuses
            // to launch until it is reaped, and termination kills its group.
        }
        let stdout = outputPipe[0], stderr = errorPipe[0]
        for descriptor in [stdout, stderr] {
            let current = fcntl(descriptor, F_GETFL)
            guard current >= 0, fcntl(descriptor, F_SETFL, current | O_NONBLOCK) == 0 else {
                forceStop(); return .failure(.commandFailed)
            }
        }
        var stdoutEOF = false, stderrEOF = false
        var waitStatus: Int32?
        var finishClock: PowermetricsMeasurementContext.Anchor?
        func chunk(_ descriptor: Int32, eof: inout Bool) throws -> Data {
            guard !eof else { return Data() }
            var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { eof = true; return Data() }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return Data() }
            throw PowermetricsFailure.commandFailed
        }
        let result = PowermetricsExecutionPolicy.collect(
            startedAt: startedAt, now: { PowermetricsMonotonicClock.seconds },
            read: {
                let out = try chunk(stdout, eof: &stdoutEOF)
                let err = try chunk(stderr, eof: &stderrEOF)
                // Retain the leader's pid until both pipes close. If a descendant
                // holds a writer open, the deadline still kills the entire group
                // before reaping its leader can make the pgid reusable.
                if stdoutEOF && stderrEOF && waitStatus == nil { waitStatus = reapIfExited(pid) }
                if waitStatus != nil && finishClock == nil { finishClock = .capture() }
                return .init(stdout: out, stderr: err, reachedEOF: stdoutEOF && stderrEOF,
                             exitStatus: waitStatus.map(PowermetricsWaitStatus.exitCode))
            }, kill: forceStop, pause: { usleep(10_000) }, measurementContext: {
                guard let launchClock, let finishClock else { return nil }
                return PowermetricsMeasurementContext(launched: launchClock, finished: finishClock,
                                                     helperBootID: Self.helperBootID)
            }
        )
        guard case .sample(let sample) = result else { return result }
        if sample.timing != nil { return result }
        // Missing lifecycle/native evidence remains diagnostic, never inferred.
        return .sample(sample.withTiming(.init(sampleID: UUID().uuidString, helperBootID: Self.helperBootID,
            clockDomain: PowermetricsMonotonicClock.clockDomain, timestampQuality: .requestBracketOnly)))
    }
}
