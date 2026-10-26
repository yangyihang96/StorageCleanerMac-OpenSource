import Foundation

protocol MacBenchmarkLifecycleCleaning: Sendable {
    func cleanupOrphanedArtifactsOnLaunch() async
}

/// Launch-time recovery is intentionally separate from the frozen Standard v6
/// service. It only delegates to the kernel's existing bounded, app-private
/// orphan cleanup primitive and never starts a measurement.
struct SystemMacBenchmarkLifecycleCleaner: MacBenchmarkLifecycleCleaning {
    let diskKernel: DiskBenchmarkKernel
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
