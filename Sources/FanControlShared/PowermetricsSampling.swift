import Darwin
import Foundation

public enum PowermetricsMonotonicClock {
    /// System-wide continuous domain, shared by the helper and workload clocks.
    /// Unlike `seconds`, this has no process-local origin and includes sleep.
    public static let clockDomain = "mach-continuous-v1"
    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()
    public static var nanoseconds: UInt64 {
        let ticks = mach_continuous_time()
        // Split before multiplication to preserve integer nanoseconds and avoid
        // overflowing ticks * numer on long uptimes.
        let divisor = UInt64(timebase.denom)
        let multiplier = UInt64(timebase.numer)
        return (ticks / divisor) * multiplier + (ticks % divisor) * multiplier / divisor
    }
    private static let origin = ContinuousClock.now
    public static var seconds: TimeInterval {
        let duration = origin.duration(to: ContinuousClock.now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
}

/// Pure execution policy, shared with deterministic tests. The privileged
/// adapter starts the one constant command and supplies nonblocking pipe reads.
public enum PowermetricsExecutionPolicy {
    public static let timeoutSeconds: TimeInterval = 5
    public struct Read: Sendable {
        public let stdout: Data
        public let stderr: Data
        public let reachedEOF: Bool
        public let exitStatus: Int32?
        public init(stdout: Data, stderr: Data, reachedEOF: Bool, exitStatus: Int32?) {
            self.stdout = stdout; self.stderr = stderr
            self.reachedEOF = reachedEOF; self.exitStatus = exitStatus
        }
    }

    public static func collect(startedAt: TimeInterval,
                               now: () -> TimeInterval,
                               read: () throws -> Read,
                               kill: () -> Void,
                               pause: () -> Void,
                               measurementContext: () -> PowermetricsMeasurementContext? = { nil }) -> PowermetricsResult {
        var output = Data()
        var byteCount = 0
        while now() - startedAt < timeoutSeconds {
            let chunk: Read
            do { chunk = try read() }
            catch { kill(); return .failure(.commandFailed) }
            let remaining = PowermetricsPlistParser.maximumOutputBytes - byteCount
            guard chunk.stdout.count <= remaining,
                  chunk.stderr.count <= remaining - chunk.stdout.count else {
                kill()
                return .failure(.outputTooLarge)
            }
            byteCount += chunk.stdout.count + chunk.stderr.count
            output.append(chunk.stdout)
            if let status = chunk.exitStatus, chunk.reachedEOF {
                guard status == 0 else { return .failure(.commandFailed) }
                do { return .sample(try PowermetricsPlistParser.parse(output, measurementContext: measurementContext())) }
                catch let error as PowermetricsFailure { return .failure(error) }
                catch { return .failure(.invalidOutput) }
            }
            pause()
        }
        // No grace period: even a SIGTERM-ignoring child is killed at 5 s.
        kill()
        return .failure(.timedOut)
    }
}

/// One daemon-wide flight. Joined requests receive the same structured result;
/// rapid later requests are refused instead of queuing a backlog of processes.
public actor PowermetricsSamplingCoordinator {
    public static let minimumInterval: TimeInterval = 2
    public static let maximumWaiters = 32
    private let now: @Sendable () -> TimeInterval
    private let run: @Sendable () async -> PowermetricsResult
    private var lastStart: TimeInterval?
    private var inFlight: Task<PowermetricsResult, Never>?
    private var waiters = 0
    // Internal readback for deterministic concurrency tests, not XPC state.
    var pendingRequestCount: Int { waiters }

    public init(now: @escaping @Sendable () -> TimeInterval = { PowermetricsMonotonicClock.seconds },
                run: @escaping @Sendable () async -> PowermetricsResult) {
        self.now = now; self.run = run
    }

    public func request(authorized: Bool) async -> PowermetricsResult {
        guard authorized else { return .failure(.unauthorized) }
        guard waiters < Self.maximumWaiters else { return .failure(.busy) }
        if let inFlight {
            waiters += 1
            defer { waiters -= 1 }
            return await inFlight.value
        }
        let time = now()
        guard time.isFinite,
              lastStart.map({ time - $0 >= Self.minimumInterval }) ?? true else {
            return .failure(.throttled)
        }
        lastStart = time
        let task = Task { await run() }
        inFlight = task
        waiters += 1
        defer { waiters -= 1; inFlight = nil }
        return await task.value
    }
}

/// Per-connection admission for the sampling operation, kept separate from the
/// daemon so its ordering and cache rules are unit tested.
///
/// - Every attempt (including refused ones) counts against a cheap per-connection
///   interval before any Security framework work happens.
/// - The cheap identity check (dynamic validity + identifier/team/path) runs on
///   every request. The full static seal check runs only when this connection has
///   not yet passed it for the same process instance (pid + pidversion from the
///   audit token). A lifetime ticket prevents in-flight checks from recreating a
///   forgotten cache or authorizing a recycled connection identifier.
public final class PowermetricsClientGate: @unchecked Sendable {
    public static let minimumAttemptInterval: TimeInterval = 1
    public struct ClientProcess: Hashable, Sendable {
        public let pid: Int32
        public let pidVersion: Int32
        public init(pid: Int32, pidVersion: Int32) { self.pid = pid; self.pidVersion = pidVersion }
    }
    public struct Admission: Sendable {
        fileprivate let connection: ObjectIdentifier
        fileprivate let lifetime: UUID
    }
    private struct ConnectionState {
        let lifetime = UUID()
        var lastAttempt: TimeInterval?
        var sealed: ClientProcess?
    }
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: ConnectionState] = [:]

    public init() {}

    /// Register only accepted XPC connections, before resuming delivery.
    public func register(connection: ObjectIdentifier) {
        lock.withLock { connections[connection] = ConnectionState() }
    }

    /// Cheap; call synchronously on the XPC delivery thread.
    public func admitAttempt(connection: ObjectIdentifier, now: TimeInterval) -> Admission? {
        lock.withLock {
            guard now.isFinite, var state = connections[connection] else { return nil }
            let previous = state.lastAttempt
            state.lastAttempt = now
            connections[connection] = state
            guard previous.map({ now - $0 >= Self.minimumAttemptInterval }) ?? true else { return nil }
            return Admission(connection: connection, lifetime: state.lifetime)
        }
    }

    /// Runs off the XPC delivery thread. Checks are never run while holding the lock.
    public func authorize(admission: Admission, process: ClientProcess,
                          cheapCheck: () throws -> Bool, sealCheck: () throws -> Bool) -> Bool {
        guard lock.withLock({ connections[admission.connection]?.lifetime == admission.lifetime }) else { return false }
        guard (try? cheapCheck()) == true else { return false }
        let cached: Bool? = lock.withLock {
            guard let state = connections[admission.connection], state.lifetime == admission.lifetime else { return nil }
            return state.sealed == process
        }
        guard let cached else { return false }
        if cached { return true }
        guard (try? sealCheck()) == true else { return false }
        return lock.withLock {
            guard var state = connections[admission.connection], state.lifetime == admission.lifetime else { return false }
            state.sealed = process
            connections[admission.connection] = state
            return true
        }
    }

    public func forget(connection: ObjectIdentifier) {
        lock.withLock { connections[connection] = nil }
    }

    // Internal readback for tests.
    var trackedConnectionCount: Int { lock.withLock { connections.count } }
}

public enum PowermetricsWaitStatus {
    /// Exit code from a `waitpid` status. A signal death or an unknown status
    /// (-1, e.g. ECHILD) is always nonzero, so it can never read as success.
    public static func exitCode(_ status: Int32) -> Int32 {
        guard status >= 0 else { return 255 }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}
