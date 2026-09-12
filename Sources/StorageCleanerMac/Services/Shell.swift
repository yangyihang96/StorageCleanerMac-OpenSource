import Darwin
import Dispatch
import Foundation

enum ShellProcessPresence: Sendable {
    case exited
    case pidReused
    case sameProcessRunning
    case unknown
}

protocol ShellProcessCleanupLifecycle: AnyObject, Sendable {
    var cleanupID: UUID { get }

    func activateRetention() -> Bool
    func cleanupPresence() -> ShellProcessPresence
    func retryVerifiedTermination()
    func releaseRetention()
}

final class ShellProcessCleanupReaper: @unchecked Sendable {
    typealias Operation = @Sendable () -> Void

    struct ScheduledOperation: Sendable {
        let run: Operation
    }

    typealias Schedule = @Sendable (TimeInterval, ScheduledOperation) -> Void

    enum LaunchWaitResult {
        case ready
        case cancelled
        case timedOut
    }

    private struct Entry {
        let lifecycle: any ShellProcessCleanupLifecycle
        var remainingRetryCount: Int
    }

    static let shared: ShellProcessCleanupReaper = {
        let queue = DispatchQueue(
            label: "StorageCleanerMac.ShellProcessCleanupReaper",
            qos: .utility
        )
        return ShellProcessCleanupReaper(retryDelay: 0.5, maximumRetryCount: 6) { delay, operation in
            queue.asyncAfter(deadline: .now() + delay) {
                operation.run()
            }
        }
    }()

    private let retryDelay: TimeInterval
    private let maximumRetryCount: Int
    private let schedule: Schedule
    private let condition = NSCondition()
    private var entries = [UUID: Entry]()
    private var exhaustedCleanupIDs = Set<UUID>()

    init(
        retryDelay: TimeInterval,
        maximumRetryCount: Int = 6,
        schedule: @escaping Schedule
    ) {
        self.retryDelay = max(0, retryDelay)
        self.maximumRetryCount = max(1, maximumRetryCount)
        self.schedule = schedule
    }

    var hasPendingCleanup: Bool {
        withEntriesLock { !entries.isEmpty }
    }

    var hasExhaustedCleanup: Bool {
        withEntriesLock { !exhaustedCleanupIDs.isEmpty }
    }

    func retain(_ lifecycle: any ShellProcessCleanupLifecycle) {
        guard lifecycle.activateRetention() else { return }
        withEntriesLock {
            entries[lifecycle.cleanupID] = Entry(
                lifecycle: lifecycle,
                remainingRetryCount: maximumRetryCount
            )
            condition.broadcast()
        }

        switch lifecycle.cleanupPresence() {
        case .exited, .pidReused:
            finishCleanup(lifecycle.cleanupID)
        case .sameProcessRunning, .unknown:
            guard hasEntry(lifecycle.cleanupID) else { return }
            scheduleRetry(for: lifecycle.cleanupID)
        }
    }

    func waitForLaunchPermission(
        timeout: TimeInterval,
        cancellationCheck: (@Sendable () -> Bool)?
    ) -> LaunchWaitResult {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        condition.lock()
        defer { condition.unlock() }

        while !entries.isEmpty {
            if cancellationCheck?() == true {
                return .cancelled
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                return .timedOut
            }
            _ = condition.wait(until: Date().addingTimeInterval(min(remaining, 0.05)))
        }
        return .ready
    }

    func processDidTerminate(_ identifier: UUID) {
        finishCleanup(identifier)
    }

    private func withEntriesLock<T>(_ body: () throws -> T) rethrows -> T {
        condition.lock()
        defer { condition.unlock() }
        return try body()
    }

    private func hasEntry(_ identifier: UUID) -> Bool {
        withEntriesLock { entries[identifier] != nil }
    }

    private func finishCleanup(_ identifier: UUID) {
        let lifecycle = withEntriesLock { () -> (any ShellProcessCleanupLifecycle)? in
            guard let entry = entries.removeValue(forKey: identifier) else { return nil }
            exhaustedCleanupIDs.remove(identifier)
            condition.broadcast()
            return entry.lifecycle
        }
        lifecycle?.releaseRetention()
    }

    private func finishRetryAttempt(_ identifier: UUID) -> Bool {
        withEntriesLock {
            guard var entry = entries[identifier] else { return false }
            entry.remainingRetryCount -= 1
            if entry.remainingRetryCount <= 0 {
                entry.remainingRetryCount = maximumRetryCount
                exhaustedCleanupIDs.insert(identifier)
                condition.broadcast()
            }
            entries[identifier] = entry
            return true
        }
    }

    private func scheduleRetry(for identifier: UUID) {
        let retryDelay = self.retryDelay
        schedule(
            retryDelay,
            ScheduledOperation { [weak self] in
                self?.retryTermination(for: identifier)
            }
        )
    }

    private func retryTermination(for identifier: UUID) {
        guard let lifecycle = withEntriesLock({ entries[identifier]?.lifecycle }) else { return }
        switch lifecycle.cleanupPresence() {
        case .exited, .pidReused:
            finishCleanup(identifier)
            return
        case .sameProcessRunning:
            lifecycle.retryVerifiedTermination()
        case .unknown:
            break
        }
        switch lifecycle.cleanupPresence() {
        case .exited, .pidReused:
            finishCleanup(identifier)
            return
        case .sameProcessRunning, .unknown:
            break
        }
        guard finishRetryAttempt(identifier) else { return }
        scheduleRetry(for: identifier)
    }
}

enum ShellError: LocalizedError {
    case failed(String, Int32, String)
    case timedOut(String, TimeInterval)
    case cancelled(String)
    case outputTooLarge(String, Int)
    case terminationFailed(String)
    case cleanupPending(String)

    var errorDescription: String? {
        switch self {
        case let .failed(command, status, output):
            L10n.text("命令失败：\(command) (\(status)) \(output)", "Command failed: \(command) (\(status)) \(output)")
        case let .timedOut(command, timeout):
            L10n.text("命令超时：\(command)（\(timeout.formatted()) 秒）", "Command timed out: \(command) (\(timeout.formatted()) seconds)")
        case let .cancelled(command):
            L10n.text("命令已取消：\(command)", "Command cancelled: \(command)")
        case let .outputTooLarge(command, limit):
            L10n.text("命令输出超过限制：\(command)（\(limit) 字节）", "Command output exceeded limit: \(command) (\(limit) bytes)")
        case let .terminationFailed(command):
            L10n.text("无法安全结束命令：\(command)", "Could not safely terminate command: \(command)")
        case let .cleanupPending(command):
            L10n.text("上一个命令仍在安全收尾：\(command)", "A previous command is still being cleaned up safely: \(command)")
        }
    }
}

struct ShellCommandResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String

    var combinedOutput: String {
        standardOutput + standardError
    }
}

enum Shell {
    static let containedProcessSpawnFlags = Int16(
        POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_START_SUSPENDED
            | POSIX_SPAWN_CLOEXEC_DEFAULT
    )

    static func capture(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil) throws -> String {
        let result = try run(executable, arguments, timeout: timeout)
        let command = ([executable] + arguments).joined(separator: " ")

        guard result.terminationStatus == 0 else {
            throw ShellError.failed(command, result.terminationStatus, result.standardError + result.standardOutput)
        }

        return result.standardOutput
    }

    static func captureCancellable(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        outputByteLimit: Int,
        cancellationCheck: @escaping @Sendable () -> Bool,
        cleanupReaper: ShellProcessCleanupReaper = .shared,
        cleanupWaitTimeout: TimeInterval = 1
    ) throws -> String {
        let result = try run(
            executable,
            arguments,
            timeout: timeout,
            outputByteLimit: outputByteLimit,
            environment: environment,
            cancellationCheck: cancellationCheck,
            cleanupReaper: cleanupReaper,
            cleanupWaitTimeout: cleanupWaitTimeout
        )
        let command = ([executable] + arguments).joined(separator: " ")
        guard result.terminationStatus == 0 else {
            throw ShellError.failed(
                command,
                result.terminationStatus,
                result.standardError + result.standardOutput
            )
        }
        return result.standardOutput
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval? = nil,
        outputByteLimit: Int? = nil,
        environment: [String: String]? = nil,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        cleanupReaper: ShellProcessCleanupReaper? = nil,
        cleanupWaitTimeout: TimeInterval = 0,
        permitsPersistentSystemService: Bool = false
    ) throws -> ShellCommandResult {
        let command = ([executable] + arguments).joined(separator: " ")
        if let outputByteLimit, outputByteLimit <= 0 {
            throw ShellError.outputTooLarge(command, max(0, outputByteLimit))
        }
        if cancellationCheck?() == true {
            throw ShellError.cancelled(command)
        }
        if let cleanupReaper {
            switch cleanupReaper.waitForLaunchPermission(
                timeout: cleanupWaitTimeout,
                cancellationCheck: cancellationCheck
            ) {
            case .ready:
                break
            case .cancelled:
                throw ShellError.cancelled(command)
            case .timedOut:
                throw ShellError.cleanupPending(command)
            }
        }
        // Pipes can keep readDataToEndOfFile blocked forever when a spawned
        // descendant inherits a write descriptor. File-backed output remains
        // readable immediately even if a misbehaving descendant outlives the
        // command, so timeout handling never waits for pipe EOF.
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerMac-Shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let stdoutURL = outputDirectory.appendingPathComponent("stdout")
        let stderrURL = outputDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)

        defer {
            try? stdout.close()
            try? stderr.close()
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let processCleanupReaper = cleanupReaper ?? .shared
        if cancellationCheck?() == true {
            throw ShellError.cancelled(command)
        }
        let process = try spawnSuspendedProcessGroup(
            executable: executable,
            arguments: arguments,
            standardOutput: stdout.fileDescriptor,
            standardError: stderr.fileDescriptor,
            environment: environment,
            command: command
        )
        let cleanupLifecycle = POSIXProcessGroupCleanupLifecycle(process: process)
        process.setTerminationHandler { _ in
            cleanupLifecycle.markRootTerminated()
            switch cleanupLifecycle.cleanupPresence() {
            case .exited, .pidReused:
                processCleanupReaper.processDidTerminate(cleanupLifecycle.cleanupID)
            case .sameProcessRunning, .unknown:
                break
            }
        }

        if cancellationCheck?() == true {
            let didTerminate = terminateProcessGroup(
                process,
                lifecycle: cleanupLifecycle
            )
            guard didTerminate else {
                processCleanupReaper.retain(cleanupLifecycle)
                throw ShellError.terminationFailed(command)
            }
            throw ShellError.cancelled(command)
        }
        do {
            try process.resumeVerified(command: command)
        } catch {
            let didTerminate = terminateProcessGroup(
                process,
                lifecycle: cleanupLifecycle
            )
            if !didTerminate {
                processCleanupReaper.retain(cleanupLifecycle)
            }
            throw ShellError.terminationFailed(command)
        }
        cleanupLifecycle.captureCurrentMembers()

        let deadline = timeout.map { DispatchTime.now() + $0 }
        if deadline != nil || cancellationCheck != nil || outputByteLimit != nil {
            while !process.waitForExit(timeout: 0.05) {
                cleanupLifecycle.captureCurrentMembers()
                let stopError: ShellError?
                if cancellationCheck?() == true {
                    stopError = .cancelled(command)
                } else if let outputByteLimit,
                          outputExceedsLimit(
                            stdoutURL: stdoutURL,
                            stderrURL: stderrURL,
                            limit: outputByteLimit
                          ) {
                    stopError = .outputTooLarge(command, outputByteLimit)
                } else if let deadline, DispatchTime.now() >= deadline {
                    stopError = .timedOut(command, timeout ?? 0)
                } else {
                    stopError = nil
                }

                if let stopError {
                    let didTerminate = terminateProcessGroup(
                        process,
                        lifecycle: cleanupLifecycle
                    )
                    guard didTerminate else {
                        processCleanupReaper.retain(cleanupLifecycle)
                        throw ShellError.terminationFailed(command)
                    }
                    throw stopError
                }
            }
        } else {
            while !process.waitForExit(timeout: 0.05) {
                cleanupLifecycle.captureCurrentMembers()
            }
        }

        let preservesProcessGroup = permitsPersistentSystemService
            && process.terminationStatus == 0
        if !preservesProcessGroup {
            let didVerifyContainedGroupExit = waitForProcessGroupExit(
                processGroupID: process.processGroupID,
                rootIdentity: process.rootIdentity,
                initiallyTracked: cleanupLifecycle.trackedMemberSnapshot(),
                timeout: 2,
                additionalTracked: { cleanupLifecycle.trackedMemberSnapshot() },
                onDiscovered: { cleanupLifecycle.updateTrackedMembers($0) },
                onDiscoveryIncomplete: { cleanupLifecycle.markDiscoveryIncomplete() },
                onVerifiedRunning: { identities in
                    signalProcesses(identities, signal: SIGKILL)
                }
            )
            guard cleanupLifecycle.hasCompleteDiscovery,
                  didVerifyContainedGroupExit else {
                processCleanupReaper.retain(cleanupLifecycle)
                throw ShellError.terminationFailed(command)
            }
        }

        try? stdout.synchronize()
        try? stderr.synchronize()
        try? stdout.close()
        try? stderr.close()

        if let outputByteLimit,
           outputExceedsLimit(
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            limit: outputByteLimit
           ) {
            throw ShellError.outputTooLarge(command, outputByteLimit)
        }
        let output = String(data: (try? Data(contentsOf: stdoutURL)) ?? Data(), encoding: .utf8) ?? ""
        let error = String(data: (try? Data(contentsOf: stderrURL)) ?? Data(), encoding: .utf8) ?? ""

        return ShellCommandResult(
            terminationStatus: process.terminationStatus,
            standardOutput: output,
            standardError: error
        )
    }

    private static func outputSize(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func outputExceedsLimit(
        stdoutURL: URL,
        stderrURL: URL,
        limit: Int
    ) -> Bool {
        let stdoutSize = outputSize(stdoutURL)
        guard stdoutSize <= limit else { return true }
        return outputSize(stderrURL) > limit - stdoutSize
    }

    struct ProcessTreeExitOperations: Sendable {
        let descendants: @Sendable (ProcessIdentity) -> [ProcessIdentity]
        let presence: @Sendable (ProcessIdentity) -> ShellProcessPresence
        let monotonicNow: @Sendable () -> UInt64
        let pause: @Sendable (TimeInterval) -> Void

        static let live = ProcessTreeExitOperations(
            descendants: { descendantProcessIdentities(of: $0) },
            presence: { processPresence(for: $0) },
            monotonicNow: { DispatchTime.now().uptimeNanoseconds },
            pause: { interval in
                guard interval > 0 else { return }
                Thread.sleep(forTimeInterval: interval)
            }
        )
    }

    struct ProcessGroupExitOperations: Sendable {
        let members: @Sendable (pid_t) -> [ProcessIdentity]?
        let presence: @Sendable (ProcessIdentity) -> ShellProcessPresence
        let monotonicNow: @Sendable () -> UInt64
        let pause: @Sendable (TimeInterval) -> Void

        static let live = ProcessGroupExitOperations(
            members: { processGroupIdentities(processGroupID: $0) },
            presence: { processPresence(for: $0) },
            monotonicNow: { DispatchTime.now().uptimeNanoseconds },
            pause: { interval in
                guard interval > 0 else { return }
                Thread.sleep(forTimeInterval: interval)
            }
        )
    }

    struct ProcessGroupMembershipOperations: Sendable {
        let processIDs: @Sendable (pid_t) -> [pid_t]?
        let processGroupID: @Sendable (pid_t) -> pid_t
        let witness: @Sendable (pid_t) -> ProcessGroupWitness?

        static let live = ProcessGroupMembershipOperations(
            processIDs: { processGroupProcessIDs(processGroupID: $0) },
            processGroupID: { getpgid($0) },
            witness: { processGroupWitness(for: $0) }
        )
    }

    struct TerminationSignalOperations: Sendable {
        let processTree: @Sendable (ProcessIdentity?, [ProcessIdentity], Int32) -> Void
        let processes: @Sendable ([ProcessIdentity], Int32) -> Void

        static let live = TerminationSignalOperations(
            processTree: { root, descendants, signal in
                signalProcessTree(root: root, descendants: descendants, signal: signal)
            },
            processes: { identities, signal in
                signalProcesses(identities, signal: signal)
            }
        )
    }

    static func waitForProcessTreeExit(
        _ identities: [ProcessIdentity],
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.02,
        operations: ProcessTreeExitOperations = .live,
        discoveryRoots: [ProcessIdentity] = [],
        onDiscovered: @escaping @Sendable ([ProcessIdentity]) -> Void = { _ in },
        onVerifiedRunning: @escaping @Sendable ([ProcessIdentity]) -> Void = { _ in }
    ) -> Bool {
        var identities = Set(identities)
        let roots = Set(discoveryRoots).union(identities)
        let maximumTrackedIdentityCount = 4_096

        let startedAt = operations.monotonicNow()
        let boundedTimeout = min(max(0, timeout), Double(UInt64.max) / 1_000_000_000)
        let timeoutNanoseconds = UInt64(boundedTimeout * 1_000_000_000)
        let (candidateDeadline, overflowed) = startedAt.addingReportingOverflow(timeoutNanoseconds)
        let deadline = overflowed ? UInt64.max : candidateDeadline
        let boundedPollInterval = max(0.001, pollInterval)

        while true {
            var queue = Array(roots.union(identities))
            var expandedParents = Set<ProcessIdentity>()
            var newlyDiscovered = [ProcessIdentity]()
            var exceededDiscoveryLimit = false

            while let parent = queue.popLast() {
                guard expandedParents.insert(parent).inserted else { continue }
                guard expandedParents.count <= maximumTrackedIdentityCount else {
                    exceededDiscoveryLimit = true
                    break
                }

                for descendant in operations.descendants(parent) {
                    guard !roots.contains(descendant) else { continue }
                    if !identities.contains(descendant),
                       identities.count >= maximumTrackedIdentityCount {
                        exceededDiscoveryLimit = true
                        continue
                    }
                    if identities.insert(descendant).inserted {
                        newlyDiscovered.append(descendant)
                        queue.append(descendant)
                    }
                }
            }

            if !newlyDiscovered.isEmpty {
                onDiscovered(newlyDiscovered)
            }

            var allExited = !exceededDiscoveryLimit
            var verifiedRunning = [ProcessIdentity]()
            for identity in identities {
                switch operations.presence(identity) {
                case .exited, .pidReused:
                    break
                case .sameProcessRunning:
                    allExited = false
                    verifiedRunning.append(identity)
                case .unknown:
                    allExited = false
                }
            }
            if !verifiedRunning.isEmpty {
                onVerifiedRunning(verifiedRunning)
            }
            if allExited { return true }

            let now = operations.monotonicNow()
            guard now < deadline else { return false }
            let remaining = TimeInterval(deadline - now) / 1_000_000_000
            operations.pause(min(boundedPollInterval, remaining))
        }
    }

    static func waitForProcessGroupExit(
        processGroupID: pid_t,
        rootIdentity: ProcessIdentity,
        initiallyTracked: [ProcessIdentity],
        timeout: TimeInterval,
        quietInterval: TimeInterval = 0.04,
        pollInterval: TimeInterval = 0.02,
        operations: ProcessGroupExitOperations = .live,
        additionalTracked: @escaping @Sendable () -> [ProcessIdentity] = { [] },
        onDiscovered: @escaping @Sendable ([ProcessIdentity]) -> Void = { _ in },
        onDiscoveryIncomplete: @escaping @Sendable () -> Void = {},
        onVerifiedRunning: @escaping @Sendable ([ProcessIdentity]) -> Void = { _ in }
    ) -> Bool {
        guard processGroupID > 1,
              rootIdentity.processID == processGroupID else {
            return false
        }

        let maximumTrackedIdentityCount = 4_096
        var tracked = Set(initiallyTracked + [rootIdentity])
        let startedAt = operations.monotonicNow()
        let boundedTimeout = min(max(0, timeout), Double(UInt64.max) / 1_000_000_000)
        let timeoutNanoseconds = UInt64(boundedTimeout * 1_000_000_000)
        let (candidateDeadline, overflowed) = startedAt.addingReportingOverflow(timeoutNanoseconds)
        let deadline = overflowed ? UInt64.max : candidateDeadline
        let boundedQuietInterval = min(
            max(0, quietInterval),
            Double(UInt64.max) / 1_000_000_000
        )
        let quietNanoseconds = UInt64(boundedQuietInterval * 1_000_000_000)
        let boundedPollInterval = max(0.001, pollInterval)
        var quietStartedAt: UInt64?
        var quietConfirmationCount = 0

        while true {
            let rootPresence = operations.presence(rootIdentity)
            let memberSnapshot: [ProcessIdentity]?
            if rootPresence == .pidReused {
                // A new process group can reuse the numeric PGID only after the
                // contained group is gone. Never adopt members from that new group.
                memberSnapshot = []
            } else {
                memberSnapshot = operations.members(processGroupID)
            }

            var membershipComplete = memberSnapshot != nil
            let currentMembers = memberSnapshot ?? []
            let capturedEvidence = additionalTracked()
            if currentMembers.count > maximumTrackedIdentityCount
                || capturedEvidence.count > maximumTrackedIdentityCount {
                membershipComplete = false
            }
            if !membershipComplete {
                onDiscoveryIncomplete()
            }
            var newlyDiscovered = [ProcessIdentity]()
            for identity in capturedEvidence.prefix(maximumTrackedIdentityCount)
                where tracked.insert(identity).inserted {
                newlyDiscovered.append(identity)
            }
            for identity in currentMembers.prefix(maximumTrackedIdentityCount)
                where tracked.insert(identity).inserted {
                newlyDiscovered.append(identity)
            }
            if !newlyDiscovered.isEmpty {
                onDiscovered(newlyDiscovered)
            }

            var allTrackedSafe = true
            var verifiedRunning = [ProcessIdentity]()
            for identity in tracked {
                let presence = identity == rootIdentity
                    ? rootPresence
                    : operations.presence(identity)
                switch presence {
                case .exited, .pidReused:
                    break
                case .sameProcessRunning:
                    allTrackedSafe = false
                    verifiedRunning.append(identity)
                case .unknown:
                    allTrackedSafe = false
                }
            }
            if !verifiedRunning.isEmpty {
                onVerifiedRunning(verifiedRunning)
            }

            let now = operations.monotonicNow()
            let isQuiet = membershipComplete
                && currentMembers.isEmpty
                && allTrackedSafe
            if isQuiet {
                if quietStartedAt == nil {
                    quietStartedAt = now
                    quietConfirmationCount = 1
                } else {
                    quietConfirmationCount += 1
                }
                if let quietStartedAt,
                   quietConfirmationCount >= 2,
                   now >= quietStartedAt,
                   now - quietStartedAt >= quietNanoseconds {
                    return true
                }
            } else {
                quietStartedAt = nil
                quietConfirmationCount = 0
            }

            guard now < deadline else { return false }
            let remaining = TimeInterval(deadline - now) / 1_000_000_000
            operations.pause(min(boundedPollInterval, remaining))
        }
    }

    // Deterministic seam for identity/barrier tests around externally-created
    // Foundation processes. Production Shell.run always uses the contained
    // POSIX process-group path below and never falls back to this ancestry path.
    static func terminate(
        _ process: Process,
        launchedIdentity: ProcessIdentity?,
        finished: DispatchSemaphore,
        signals: TerminationSignalOperations = .live,
        descendantIdentities: [ProcessIdentity]? = nil,
        trackDescendants: @escaping @Sendable ([ProcessIdentity]) -> Void = { _ in },
        processTreeExitTimeout: TimeInterval = 2,
        exitOperations: ProcessTreeExitOperations = .live
    ) -> Bool {
        guard let launchedIdentity else { return !process.isRunning }
        var descendants = descendantIdentities ?? descendantProcessIdentities(of: launchedIdentity)
        trackDescendants(descendants)
        signals.processTree(launchedIdentity, descendants, SIGTERM)
        if process.isRunning,
           finished.wait(timeout: .now() + 0.5) == .timedOut {
            descendants.append(contentsOf: descendantProcessIdentities(of: launchedIdentity))
            descendants = Array(Set(descendants))
            trackDescendants(descendants)
            signals.processTree(launchedIdentity, descendants, SIGKILL)
            _ = finished.wait(timeout: .now() + 0.5)
        } else {
            signals.processes(descendants, SIGKILL)
        }
        guard !process.isRunning else { return false }
        return waitForProcessTreeExit(
            descendants,
            timeout: processTreeExitTimeout,
            operations: exitOperations,
            discoveryRoots: [launchedIdentity],
            onDiscovered: { identities in
                trackDescendants(identities)
            },
            onVerifiedRunning: { identities in
                signals.processes(identities, SIGKILL)
            }
        )
    }

    struct ProcessIdentity: Hashable, Sendable {
        let processID: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    struct ProcessGroupWitness: Equatable, Sendable {
        let identity: ProcessIdentity
        let processGroupID: pid_t
    }

    fileprivate final class POSIXSpawnedProcess: @unchecked Sendable {
        typealias TerminationHandler = @Sendable (Int32) -> Void

        let rootIdentity: ProcessIdentity
        let processGroupID: pid_t

        private let condition = NSCondition()
        private var rawWaitStatus: Int32?
        private var terminationHandler: TerminationHandler?

        init(rootIdentity: ProcessIdentity, processGroupID: pid_t) {
            self.rootIdentity = rootIdentity
            self.processGroupID = processGroupID
            let processID = rootIdentity.processID
            DispatchQueue.global(qos: .utility).async { [self] in
                var status: Int32 = 0
                var result: pid_t
                repeat {
                    result = waitpid(processID, &status, 0)
                } while result == -1 && errno == EINTR
                markExited(rawStatus: result == processID ? status : Int32.max)
            }
        }

        var terminationStatus: Int32 {
            waitUntilExit()
            let status = condition.withLock { rawWaitStatus ?? Int32.max }
            if status == Int32.max { return -1 }
            let signal = status & 0x7f
            return signal == 0 ? (status >> 8) & 0xff : signal
        }

        func setTerminationHandler(_ handler: @escaping TerminationHandler) {
            let completedStatus = condition.withLock { () -> Int32? in
                if let rawWaitStatus {
                    return Self.decodedTerminationStatus(rawWaitStatus)
                }
                terminationHandler = handler
                return nil
            }
            if let completedStatus {
                handler(completedStatus)
            }
        }

        func resumeVerified(command: String) throws {
            guard Shell.processPresence(for: rootIdentity) == .sameProcessRunning,
                  getpgid(rootIdentity.processID) == processGroupID,
                  Darwin.kill(rootIdentity.processID, SIGCONT) == 0 else {
                forceKillSuspendedProcess()
                throw ShellError.terminationFailed(command)
            }
        }

        func waitForExit(timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(max(0, timeout))
            condition.lock()
            defer { condition.unlock() }
            while rawWaitStatus == nil {
                guard condition.wait(until: deadline) else { return false }
            }
            return true
        }

        func waitUntilExit() {
            condition.lock()
            defer { condition.unlock() }
            while rawWaitStatus == nil {
                condition.wait()
            }
        }

        private func forceKillSuspendedProcess() {
            if Shell.processPresence(for: rootIdentity) == .sameProcessRunning {
                if getpgid(rootIdentity.processID) == processGroupID {
                    _ = Darwin.kill(-processGroupID, SIGKILL)
                } else {
                    _ = Darwin.kill(rootIdentity.processID, SIGKILL)
                }
            }
            _ = waitForExit(timeout: 1)
        }

        private func markExited(rawStatus: Int32) {
            let handler = condition.withLock { () -> TerminationHandler? in
                guard rawWaitStatus == nil else { return nil }
                self.rawWaitStatus = rawStatus
                let handler = terminationHandler
                terminationHandler = nil
                condition.broadcast()
                return handler
            }
            handler?(Self.decodedTerminationStatus(rawStatus))
        }

        private static func decodedTerminationStatus(_ status: Int32) -> Int32 {
            if status == Int32.max { return -1 }
            let signal = status & 0x7f
            return signal == 0 ? (status >> 8) & 0xff : signal
        }
    }

    private static func spawnSuspendedProcessGroup(
        executable: String,
        arguments: [String],
        standardOutput: Int32,
        standardError: Int32,
        environment: [String: String]?,
        command: String
    ) throws -> POSIXSpawnedProcess {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var fileActionsInitialized = false
        var attributesInitialized = false
        let standardInput = Darwin.open("/dev/null", O_RDONLY)
        guard standardInput >= 0 else {
            throw ShellError.failed(command, errno, String(cString: strerror(errno)))
        }
        defer { Darwin.close(standardInput) }

        var result = posix_spawn_file_actions_init(&fileActions)
        guard result == 0 else {
            throw ShellError.failed(command, result, String(cString: strerror(result)))
        }
        fileActionsInitialized = true
        defer {
            if fileActionsInitialized {
                posix_spawn_file_actions_destroy(&fileActions)
            }
        }

        result = posix_spawnattr_init(&attributes)
        guard result == 0 else {
            throw ShellError.failed(command, result, String(cString: strerror(result)))
        }
        attributesInitialized = true
        defer {
            if attributesInitialized {
                posix_spawnattr_destroy(&attributes)
            }
        }

        for (source, destination) in [
            (standardInput, STDIN_FILENO),
            (standardOutput, STDOUT_FILENO),
            (standardError, STDERR_FILENO)
        ] {
            result = posix_spawn_file_actions_adddup2(&fileActions, source, destination)
            guard result == 0 else {
                throw ShellError.failed(command, result, String(cString: strerror(result)))
            }
        }

        result = posix_spawnattr_setflags(&attributes, containedProcessSpawnFlags)
        guard result == 0 else {
            throw ShellError.failed(command, result, String(cString: strerror(result)))
        }
        result = posix_spawnattr_setpgroup(&attributes, 0)
        guard result == 0 else {
            throw ShellError.failed(command, result, String(cString: strerror(result)))
        }

        let rawArguments = ([executable] + arguments).map { strdup($0) }
        guard rawArguments.allSatisfy({ $0 != nil }) else {
            rawArguments.forEach { pointer in
                if let pointer { free(pointer) }
            }
            throw ShellError.failed(command, ENOMEM, String(cString: strerror(ENOMEM)))
        }
        var argumentVector = rawArguments + [nil]
        defer {
            rawArguments.forEach { pointer in
                if let pointer { free(pointer) }
            }
        }

        let environmentEntries: [String]
        if let environment {
            guard environment.allSatisfy({ key, value in
                !key.isEmpty
                    && !key.contains("=")
                    && !key.contains("\0")
                    && !value.contains("\0")
            }) else {
                throw ShellError.failed(command, EINVAL, String(cString: strerror(EINVAL)))
            }
            environmentEntries = environment
                .map { "\($0.key)=\($0.value)" }
                .sorted()
        } else {
            environmentEntries = []
        }
        let rawEnvironment = environmentEntries.map { strdup($0) }
        guard rawEnvironment.allSatisfy({ $0 != nil }) else {
            rawEnvironment.forEach { pointer in
                if let pointer { free(pointer) }
            }
            throw ShellError.failed(command, ENOMEM, String(cString: strerror(ENOMEM)))
        }
        var environmentVector = rawEnvironment + [nil]
        defer {
            rawEnvironment.forEach { pointer in
                if let pointer { free(pointer) }
            }
        }

        var processID: pid_t = 0
        result = argumentVector.withUnsafeMutableBufferPointer { buffer in
            if environment == nil {
                return posix_spawn(
                    &processID,
                    executable,
                    &fileActions,
                    &attributes,
                    buffer.baseAddress!,
                    environ
                )
            }
            return environmentVector.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &processID,
                    executable,
                    &fileActions,
                    &attributes,
                    buffer.baseAddress!,
                    environmentBuffer.baseAddress!
                )
            }
        }
        guard result == 0 else {
            throw ShellError.failed(command, result, String(cString: strerror(result)))
        }

        guard let rootIdentity = processIdentity(for: processID),
              getpgid(processID) == processID else {
            _ = Darwin.kill(processID, SIGKILL)
            var status: Int32 = 0
            while waitpid(processID, &status, 0) == -1, errno == EINTR {}
            throw ShellError.terminationFailed(command)
        }

        return POSIXSpawnedProcess(
            rootIdentity: rootIdentity,
            processGroupID: processID
        )
    }

    private static func terminateProcessGroup(
        _ process: POSIXSpawnedProcess,
        lifecycle: POSIXProcessGroupCleanupLifecycle
    ) -> Bool {
        let rootIdentity = process.rootIdentity
        let processGroupID = process.processGroupID
        let initialSnapshot = processGroupIdentities(processGroupID: processGroupID)
        lifecycle.recordMemberSnapshot(initialSnapshot)
        let initialMembers = initialSnapshot ?? []
        let capturedMembers = lifecycle.trackedMemberSnapshot()

        if verifiedProcessGroupLeader(process) {
            guard Darwin.kill(-processGroupID, SIGSTOP) == 0 || errno == ESRCH else {
                return false
            }
            if verifiedProcessGroupLeader(process) {
                guard Darwin.kill(-processGroupID, SIGKILL) == 0 || errno == ESRCH else {
                    return false
                }
            }
        }

        let individuallyVerified = Set(capturedMembers + initialMembers + [rootIdentity]).filter {
            processPresence(for: $0) == .sameProcessRunning
        }
        signalProcesses(individuallyVerified, signal: SIGKILL)
        _ = process.waitForExit(timeout: 0.5)

        return waitForProcessGroupExit(
            processGroupID: processGroupID,
            rootIdentity: rootIdentity,
            initiallyTracked: capturedMembers + initialMembers + [rootIdentity],
            timeout: 2,
            additionalTracked: { lifecycle.trackedMemberSnapshot() },
            onDiscovered: { lifecycle.updateTrackedMembers($0) },
            onDiscoveryIncomplete: { lifecycle.markDiscoveryIncomplete() },
            onVerifiedRunning: { identities in
                signalProcesses(identities, signal: SIGKILL)
            }
        ) && lifecycle.hasCompleteDiscovery
    }

    private static func verifiedProcessGroupLeader(
        _ process: POSIXSpawnedProcess
    ) -> Bool {
        processPresence(for: process.rootIdentity) == .sameProcessRunning
            && getpgid(process.rootIdentity.processID) == process.processGroupID
            && process.rootIdentity.processID == process.processGroupID
    }

    final class POSIXProcessGroupCleanupLifecycle:
        ShellProcessCleanupLifecycle,
        @unchecked Sendable {
        let cleanupID = UUID()

        private let lock = NSLock()
        private let rootIdentity: ProcessIdentity
        private let processGroupID: pid_t
        private let memberSnapshot: @Sendable (pid_t) -> [ProcessIdentity]?
        private let identityPresence: @Sendable (ProcessIdentity) -> ShellProcessPresence
        private weak var observedProcess: POSIXSpawnedProcess?
        private var retainedProcess: POSIXSpawnedProcess?
        private var trackedMembers = Set<ProcessIdentity>()
        private var quietStartedAt: UInt64?
        private var quietConfirmationCount = 0
        private var discoveryComplete = true
        private var lastMemberCaptureAt: UInt64?

        fileprivate init(process: POSIXSpawnedProcess) {
            rootIdentity = process.rootIdentity
            processGroupID = process.processGroupID
            memberSnapshot = { processGroupIdentities(processGroupID: $0) }
            identityPresence = { processPresence(for: $0) }
            observedProcess = process
            trackedMembers.insert(process.rootIdentity)
        }

        init(
            testingRootIdentity: ProcessIdentity,
            processGroupID: pid_t,
            memberSnapshot: @escaping @Sendable (pid_t) -> [ProcessIdentity]?,
            presence: @escaping @Sendable (ProcessIdentity) -> ShellProcessPresence
        ) {
            rootIdentity = testingRootIdentity
            self.processGroupID = processGroupID
            self.memberSnapshot = memberSnapshot
            identityPresence = presence
            trackedMembers.insert(testingRootIdentity)
        }

        func updateTrackedMembers(_ identities: [ProcessIdentity]) {
            lock.withLock { trackedMembers.formUnion(identities) }
        }

        func trackedMemberSnapshot() -> [ProcessIdentity] {
            lock.withLock { Array(trackedMembers) }
        }

        var hasCompleteDiscovery: Bool {
            lock.withLock { discoveryComplete }
        }

        func recordMemberSnapshot(_ identities: [ProcessIdentity]?) {
            guard let identities, identities.count <= 4_096 else {
                markDiscoveryIncomplete()
                return
            }
            updateTrackedMembers(identities)
        }

        func markDiscoveryIncomplete() {
            lock.withLock { discoveryComplete = false }
        }

        func captureCurrentMembers() {
            let now = DispatchTime.now().uptimeNanoseconds
            let shouldCapture = lock.withLock { () -> Bool in
                if let lastMemberCaptureAt,
                   now >= lastMemberCaptureAt,
                   now - lastMemberCaptureAt < 250_000_000 {
                    return false
                }
                lastMemberCaptureAt = now
                return true
            }
            guard shouldCapture else { return }
            let rootPresence = identityPresence(rootIdentity)
            if rootPresence == .pidReused {
                return
            }
            recordMemberSnapshot(memberSnapshot(processGroupID))
        }

        func markRootTerminated() {}

        func activateRetention() -> Bool {
            lock.withLock {
                guard let observedProcess else { return false }
                retainedProcess = observedProcess
                return true
            }
        }

        func cleanupPresence() -> ShellProcessPresence {
            let rootPresence = identityPresence(rootIdentity)
            let members: [ProcessIdentity]?
            if rootPresence == .pidReused {
                members = []
            } else {
                members = memberSnapshot(processGroupID)
            }
            guard let members, members.count <= 4_096 else {
                lock.withLock { discoveryComplete = false }
                resetQuietConfirmation()
                return .unknown
            }
            updateTrackedMembers(members)
            let tracked = lock.withLock { trackedMembers }
            let presences = tracked.map { identity in
                identity == rootIdentity
                    ? rootPresence
                    : identityPresence(identity)
            }

            if presences.contains(where: { $0 == .sameProcessRunning }) {
                resetQuietConfirmation()
                return .sameProcessRunning
            }
            if presences.contains(where: { $0 == .unknown }) || !members.isEmpty {
                resetQuietConfirmation()
                return .unknown
            }
            guard hasCompleteDiscovery else {
                resetQuietConfirmation()
                return .unknown
            }

            let now = DispatchTime.now().uptimeNanoseconds
            let quietConfirmed = lock.withLock { () -> Bool in
                if quietStartedAt == nil {
                    quietStartedAt = now
                    quietConfirmationCount = 1
                    return false
                }
                quietConfirmationCount += 1
                guard let quietStartedAt else { return false }
                return quietConfirmationCount >= 2
                    && now >= quietStartedAt
                    && now - quietStartedAt >= 40_000_000
            }
            guard quietConfirmed else { return .unknown }
            return rootPresence == .pidReused ? .pidReused : .exited
        }

        func retryVerifiedTermination() {
            if let process = lock.withLock({ retainedProcess ?? observedProcess }),
               verifiedProcessGroupLeader(process) {
                _ = Darwin.kill(-process.processGroupID, SIGKILL)
            }
            recordMemberSnapshot(memberSnapshot(processGroupID))
            let verifiedRunning = lock.withLock { trackedMembers }.filter {
                identityPresence($0) == .sameProcessRunning
            }
            signalProcesses(verifiedRunning, signal: SIGKILL)
        }

        func releaseRetention() {
            lock.withLock {
                retainedProcess = nil
                trackedMembers.removeAll()
                quietStartedAt = nil
                quietConfirmationCount = 0
                discoveryComplete = true
                lastMemberCaptureAt = nil
            }
        }

        private func resetQuietConfirmation() {
            lock.withLock {
                quietStartedAt = nil
                quietConfirmationCount = 0
            }
        }
    }

    private static func descendantProcessIdentities(of root: ProcessIdentity) -> [ProcessIdentity] {
        guard root.processID > 1, processIdentity(for: root.processID) == root else { return [] }

        var descendants = [ProcessIdentity]()
        var queue = [root]
        var seen: Set<pid_t> = [root.processID]

        while let parent = queue.popLast(), descendants.count < 4_096 {
            guard processIdentity(for: parent.processID) == parent else { continue }
            for childPID in childProcessIDs(of: parent.processID)
                where childPID > 1 && seen.insert(childPID).inserted {
                guard let child = childProcessIdentity(
                    for: childPID,
                    parent: parent
                ) else { continue }
                descendants.append(child)
                queue.append(child)
            }
        }

        return descendants
    }

    private static func childProcessIDs(of parentPID: pid_t) -> [pid_t] {
        var capacity = 32

        while capacity <= 4_096 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let processCount = buffer.withUnsafeMutableBytes { bytes in
                proc_listchildpids(parentPID, bytes.baseAddress, Int32(bytes.count))
            }
            guard processCount > 0 else { return [] }

            let count = min(Int(processCount), buffer.count)
            let children = Array(buffer.prefix(count)).filter { $0 > 1 }
            if Int(processCount) < buffer.count {
                return children
            }
            capacity *= 2
        }

        return []
    }

    static func processGroupIdentities(
        processGroupID: pid_t,
        operations: ProcessGroupMembershipOperations = .live
    ) -> [ProcessIdentity]? {
        guard processGroupID > 1,
              let processIDs = operations.processIDs(processGroupID) else {
            return nil
        }

        var identities = [ProcessIdentity]()
        identities.reserveCapacity(min(processIDs.count, 64))
        for processID in processIDs where processID > 1 {
            guard let witness = operations.witness(processID) else {
                // A successful PGID fallback proves that a real group member
                // exists, but without an atomic start identity it is unsafe to
                // treat the membership snapshot as complete.
                guard operations.processGroupID(processID) != processGroupID else {
                    return nil
                }
                continue
            }
            guard witness.processGroupID == processGroupID else { continue }
            identities.append(witness.identity)
            if identities.count > 4_096 {
                break
            }
        }
        return identities
    }

    static func processGroupProcessIDs(processGroupID: pid_t) -> [pid_t]? {
        guard processGroupID > 1 else { return nil }
        let maximumMemberCount = 4_096
        let probeCount = proc_listpgrppids(processGroupID, nil, 0)
        guard probeCount >= 0 else { return nil }
        var capacity = min(max(32, Int(probeCount) + 16), maximumMemberCount + 1)

        while capacity <= maximumMemberCount + 1 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let processCount = buffer.withUnsafeMutableBytes { bytes in
                proc_listpgrppids(
                    processGroupID,
                    bytes.baseAddress,
                    Int32(bytes.count)
                )
            }
            guard processCount >= 0 else { return nil }
            let count = min(Int(processCount), buffer.count)
            let processIDs = Array(buffer.prefix(count)).filter { $0 > 1 }
            if Int(processCount) < buffer.count {
                return processIDs
            }
            guard capacity < maximumMemberCount + 1 else { return nil }
            capacity = min(capacity * 2, maximumMemberCount + 1)
        }

        return nil
    }

    private static func processIdentity(for processID: pid_t) -> ProcessIdentity? {
        processGroupWitness(for: processID)?.identity
    }

    private static func processGroupWitness(
        for processID: pid_t
    ) -> ProcessGroupWitness? {
        guard processID > 1 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, pointer, expectedSize)
        }
        guard result == expectedSize, info.pbi_pid == UInt32(processID) else { return nil }
        return ProcessGroupWitness(
            identity: ProcessIdentity(
                processID: processID,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec
            ),
            processGroupID: pid_t(bitPattern: info.pbi_pgid)
        )
    }

    private static func childProcessIdentity(
        for processID: pid_t,
        parent: ProcessIdentity
    ) -> ProcessIdentity? {
        guard processID > 1,
              parent.processID > 1,
              processIdentity(for: parent.processID) == parent else {
            return nil
        }

        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, pointer, expectedSize)
        }
        guard result == expectedSize,
              info.pbi_pid == UInt32(processID),
              info.pbi_ppid == UInt32(parent.processID),
              processIdentity(for: parent.processID) == parent else {
            return nil
        }

        return ProcessIdentity(
            processID: processID,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    private static func processPresence(
        for identity: ProcessIdentity
    ) -> ShellProcessPresence {
        if let currentIdentity = processIdentity(for: identity.processID) {
            return currentIdentity == identity ? .sameProcessRunning : .pidReused
        }

        errno = 0
        if Darwin.kill(identity.processID, 0) == -1, errno == ESRCH {
            return .exited
        }
        return .unknown
    }

    private static func signalProcessTree(
        root: ProcessIdentity?,
        descendants: [ProcessIdentity],
        signal: Int32
    ) {
        signalProcesses(descendants.reversed(), signal: signal)
        if let root, processIdentity(for: root.processID) == root {
            _ = Darwin.kill(root.processID, signal)
        }
    }

    private static func signalProcesses<S: Sequence>(
        _ identities: S,
        signal: Int32
    ) where S.Element == ProcessIdentity {
        for identity in identities
            where processIdentity(for: identity.processID) == identity {
            _ = Darwin.kill(identity.processID, signal)
        }
    }
}
