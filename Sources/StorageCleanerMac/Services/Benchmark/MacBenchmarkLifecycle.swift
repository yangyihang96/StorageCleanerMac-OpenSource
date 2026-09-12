import Foundation

protocol MacBenchmarkLifecycleCleaning: Sendable {
    func cleanupOrphanedArtifactsOnLaunch() async
}

/// Launch-time recovery is intentionally separate from the frozen Standard v6
/// service. It only delegates to the kernel's existing bounded, app-private
/// orphan cleanup primitive and never starts a measurement.
struct SystemMacBenchmarkLifecycleCleaner: MacBenchmarkLifecycleCleaning {
    private let diskKernel: DiskBenchmarkKernel
    private let orphanAge: TimeInterval

    init(
        diskKernel: DiskBenchmarkKernel = DiskBenchmarkKernel(),
        orphanAge: TimeInterval = 24 * 60 * 60
    ) {
        self.diskKernel = diskKernel
        self.orphanAge = orphanAge
    }

    func cleanupOrphanedArtifactsOnLaunch() async {
        _ = try? await diskKernel.cleanupOrphans(olderThan: orphanAge)
    }
}

extension HeavyWorkCoordinator {
    /// Waits for both the active lease and any cleanup quarantine owned by the
    /// benchmark. Cancellation is the bounded-shutdown escape hatch.
    func waitUntilOwnerInactive(
        _ owner: Owner,
        pollInterval: Duration = .milliseconds(20)
    ) async -> Bool {
        while activeOwner == owner {
            guard !Task.isCancelled else { return false }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return false
            }
        }
        return true
    }
}
