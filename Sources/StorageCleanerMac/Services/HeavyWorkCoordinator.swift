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

    private var activeLease: Lease?
    private var cleanupQuarantine: CleanupQuarantine?

    var activeOwner: Owner? {
        activeLease?.owner ?? cleanupQuarantine?.owner
    }

    func acquire(owner: Owner) throws -> Lease {
        if let activeLease {
            throw Error.busy(activeOwner: activeLease.owner)
        }
        if let cleanupQuarantine {
            throw Error.busy(activeOwner: cleanupQuarantine.owner)
        }

        let lease = Lease(token: UUID(), owner: owner)
        activeLease = lease
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
        return quarantine
    }

    func clearCleanupQuarantine(_ quarantine: CleanupQuarantine) {
        guard cleanupQuarantine == quarantine else { return }
        cleanupQuarantine = nil
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
