import Foundation

actor MenuBarProcessSampler {
    typealias Frame = EnergyImpactService.MenuBarCounterFrame
    private let read: @Sendable () async -> Frame?
    private var previous: Frame?
    private var isReading = false
    private var generation = 0

    init(read: @escaping @Sendable () async -> Frame? = { await EnergyImpactService.menuBarCounterFrame() }) {
        self.read = read
    }

    func sample() async -> EnergyImpactSnapshot? {
        guard !isReading, !Task.isCancelled else { return nil }
        isReading = true
        let capturedGeneration = generation
        defer { isReading = false }
        guard let current = await read(), !Task.isCancelled,
              generation == capturedGeneration else { return nil }
        let before = previous
        previous = current
        guard let before else { return nil }
        return EnergyImpactService.menuBarSnapshot(previous: before, current: current)
    }

    func reset() {
        generation &+= 1
        previous = nil
    }
}

struct MenuBarPreparedProcesses: Sendable {
    let snapshot: EnergyImpactSnapshot
    let energy: [EnergyImpactApp]
    let cpu: [EnergyImpactApp]
    let disk: [EnergyImpactApp]

    init(snapshot: EnergyImpactSnapshot) {
        self.snapshot = snapshot
        energy = Array(snapshot.apps.filter { $0.isApplication && $0.isSignificantCurrentEnergy }
            .sorted {
                if $0.currentPowerWatts != $1.currentPowerWatts { return $0.currentPowerWatts > $1.currentPowerWatts }
                return $0.cpuPercent > $1.cpuPercent
            }.prefix(5))
        cpu = energy.sorted {
            if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        disk = energy.sorted {
            let lhs = Double($0.diskReadBytesPerSecond) + Double($0.diskWriteBytesPerSecond)
            let rhs = Double($1.diskReadBytesPerSecond) + Double($1.diskWriteBytesPerSecond)
            if lhs != rhs { return lhs > rhs }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
