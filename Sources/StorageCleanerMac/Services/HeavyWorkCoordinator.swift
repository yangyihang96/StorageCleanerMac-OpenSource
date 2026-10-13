import Foundation

actor HeavyWorkCoordinator {
    enum Owner: Sendable, Equatable, CaseIterable {
        case mainScan
        case largeFilesScan
        case duplicateScan
        case cleanup
        case restore
        case emptyTrash
        case memoryOptimization
        case appUpdates
        case networkTest
        case benchmark
        /// D90: releasing cloud local copies; shares the exclusive lease, labelled on its own.
        case cloudLocalCopy
    }

    struct Lease: Sendable, Equatable {
        let token: UUID
        let owner: Owner

        init(token: UUID, owner: Owner) {
            self.token = token
            self.owner = owner
        }
    }

    struct CleanupQuarantine: Sendable, Equatable {
        let token: UUID
        let owner: Owner

        init(token: UUID, owner: Owner) {
            self.token = token
            self.owner = owner
        }
    }

    enum Error: Swift.Error, Sendable, Equatable {
        case busy(activeOwner: Owner)
        case invalidLease(expectedOwner: Owner)
    }

    private let operationLockDirectory: URL?
    private var processLock: OperationFileLock?

    /// Tests explicitly pass an isolated directory when exercising process
    /// contention. The app composition root supplies its channel data root.
    init(operationLockDirectory: URL? = nil) {
        self.operationLockDirectory = operationLockDirectory
    }

    private var activeLease: Lease?
    private var cleanupQuarantine: CleanupQuarantine?
    private var ownerRevision: UInt64 = 0
    private var ownerObservers: [UUID: AsyncStream<OwnerState>.Continuation] = [:]

    struct OwnerState: Sendable, Equatable {
        let revision: UInt64
        let owner: Owner?
    }

    var activeOwner: Owner? {
        activeLease?.owner ?? cleanupQuarantine?.owner
    }

    var ownerState: OwnerState {
        OwnerState(revision: ownerRevision, owner: activeOwner)
    }

    /// Registration and its initial snapshot share the lease actor. The app's
    /// activity store observes this stream independently of any view task.
    func ownerStates() -> AsyncStream<OwnerState> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            ownerObservers[token] = continuation
            continuation.yield(ownerState)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeOwnerObserver(token) }
            }
        }
    }

    private func removeOwnerObserver(_ token: UUID) {
        ownerObservers.removeValue(forKey: token)
    }

    private func publishOwnerState() {
        ownerRevision &+= 1
        let state = ownerState
        for observer in ownerObservers.values { observer.yield(state) }
    }

    func acquire(owner: Owner) throws -> Lease {
        if let activeLease {
            throw Error.busy(activeOwner: activeLease.owner)
        }
        if let cleanupQuarantine {
            throw Error.busy(activeOwner: cleanupQuarantine.owner)
        }

        if let operationLockDirectory {
            processLock = try OperationFileLock(directory: operationLockDirectory, name: "heavy-work.lock")
        }
        let lease = Lease(token: UUID(), owner: owner)
        activeLease = lease
        publishOwnerState()
        return lease
    }

    func requireValid(_ lease: Lease, owner: Owner) throws {
        guard activeLease == lease, lease.owner == owner else {
            throw Error.invalidLease(expectedOwner: owner)
        }
    }

    func release(_ lease: Lease) {
        guard activeLease == lease else { return }
        activeLease = nil
        if cleanupQuarantine == nil { processLock = nil }
        publishOwnerState()
    }

    func beginCleanupQuarantine(_ lease: Lease) throws -> CleanupQuarantine {
        guard activeLease == lease else {
            throw Error.invalidLease(expectedOwner: lease.owner)
        }
        if let cleanupQuarantine {
            throw Error.busy(activeOwner: cleanupQuarantine.owner)
        }

        let quarantine = CleanupQuarantine(token: UUID(), owner: lease.owner)
        cleanupQuarantine = quarantine
        publishOwnerState()
        return quarantine
    }

    func clearCleanupQuarantine(_ quarantine: CleanupQuarantine) {
        guard cleanupQuarantine == quarantine else { return }
        cleanupQuarantine = nil
        if activeLease == nil { processLock = nil }
        publishOwnerState()
    }

    func withLease<Value: Sendable>(
        owner: Owner,
        operation: @Sendable (Lease) async throws -> Value
    ) async throws -> Value {
        let lease = try acquire(owner: owner)
        defer { release(lease) }
        return try await operation(lease)
    }
}

extension HeavyWorkCoordinator {
    /// Waits for both the active lease and any cleanup quarantine owned by
    /// `owner`, for example the benchmark during termination. Returns false
    /// if the waiting task is cancelled first.
    func waitUntilOwnerInactive(
        _ owner: Owner,
        pollInterval: Duration = .milliseconds(20)
    ) async -> Bool {
        await poll(every: pollInterval) { activeOwner == owner ? nil : () } != nil
    }

    /// Takes a lease as soon as no other lease or cleanup quarantine is held.
    /// Returns nil if the waiting task is cancelled first.
    func acquireWhenIdle(owner: Owner, pollInterval: Duration) async -> Lease? {
        await poll(every: pollInterval) { try? acquire(owner: owner) }
    }

    /// The one polling loop behind the waits above. Cancellation is the
    /// bounded escape hatch for shutdown and abandoned waits.
    private func poll<Value>(every pollInterval: Duration, _ attempt: () -> Value?) async -> Value? {
        while true {
            if let value = attempt() { return value }
            guard !Task.isCancelled else { return nil }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return nil
            }
        }
    }
}
