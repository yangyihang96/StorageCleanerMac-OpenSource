import Foundation

/// Frozen by the owning Store at start; independent of any Workspace lifetime.
struct MSeriesV11RunConfiguration: Equatable, Sendable {
    let sessionID: UUID
    let mode: String
    let accelerators: [MSeriesV11AcceleratorUnit]
    private(set) var completedCoreCount = 0

    mutating func accept(_ state: BenchmarkV7State) {
        guard state.sessionID == sessionID, mode == "standard", state.phase == .running else { return }
        if let index = MSeriesProtocol.coreIDs.firstIndex(of: state.workloadID ?? "") {
            completedCoreCount = max(completedCoreCount, index)
        } else if ["power.cpu.single", "power.cpu.performanceCores", "power.cpu.allCores", "power.gpu.peak",
                   "sustained.cpu.allCores", "sustained.gpu", "accelerators"].contains(state.workloadID ?? "") {
            completedCoreCount = 18
        }
    }

    mutating func acceptPendingResult(_ result: BenchmarkV7Result) {
        guard result.session.id == sessionID else { return }
        if mode == "pressure10m" { completedCoreCount = 0; return }
        guard let core = result.mSeries else { return }
        completedCoreCount = min(18, core.metrics.filter {
            MSeriesProtocol.coreIDs.contains($0.id) && $0.availability == .available && $0.isValid
        }.count)
    }
}
