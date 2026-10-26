import Foundation

actor MenuBarProcessSampler {
    typealias Frame = EnergyImpactService.MenuBarCounterFrame
    private let read: @Sendable () async -> Frame?
    private var previous: Frame?
    private var isReading = false
    private var generation = 0
    /// A read gave nothing since the last baseline (reader unavailable).
    private var missedRead = false

    init(read: @escaping @Sendable () async -> Frame? = { await EnergyImpactService.menuBarCounterFrame() }) {
        self.read = read
    }

    /// `listingFirstRead` (D171): a fresh baseline is returned at once as
    /// `EnergyImpactService.menuBarFirstReadSnapshot(of:)`, every rate 0,
    /// instead of nil; the caller reads the first delta 0.5 s later. A reader
    /// that recovers from giving nothing still takes its first delta here.
    func sample(listingFirstRead: Bool = false) async -> EnergyImpactSnapshot? {
        guard !isReading, !Task.isCancelled else { return nil }
        isReading = true
        let capturedGeneration = generation
        defer { isReading = false }
        let read = read
        guard let current = await MenuBarPresentationTrace.measureAsyncSample("process.ps-libproc", operation: read) else {
            if !Task.isCancelled, generation == capturedGeneration { missedRead = true }
            return nil
        }
        guard !Task.isCancelled, generation == capturedGeneration else { return nil }
        guard Self.fitsCache(current) else { missedRead = true; return nil }
        let before = previous
        previous = current
        guard let before else {
            if listingFirstRead, !missedRead { return EnergyImpactService.menuBarFirstReadSnapshot(of: current) }
            // D71④ reads every 10 s; after a reader that gave nothing
            // recovers, take its first delta after the short N16-2 interval
            // instead of waiting a second full cadence with nothing shown.
            guard missedRead else { return nil }
            missedRead = false
            try? await Task.sleep(for: .seconds(MenuBarPerformancePolicy.firstProcessSampleInterval))
            guard !Task.isCancelled, generation == capturedGeneration,
                  let next = await MenuBarPresentationTrace.measureAsyncSample("process.ps-libproc", operation: read),
                  !Task.isCancelled, generation == capturedGeneration,
                  Self.fitsCache(next) else { return nil }
            previous = next
            return EnergyImpactService.menuBarSnapshot(previous: current, current: next)
        }
        missedRead = false
        return EnergyImpactService.menuBarSnapshot(previous: before, current: current)
    }

    static func fitsCache(_ frame: Frame) -> Bool {
        guard frame.rows.count <= MenuBarPerformancePolicy.processCacheRowLimit,
              frame.counters.count <= MenuBarPerformancePolicy.processCacheRowLimit else { return false }
        let bytes = frame.rows.reduce(frame.counters.count * 256) { bytes, row in
            bytes + 512 + 2 * (row.path.utf8.count)
        }
        return MenuBarProcessCacheBudget.fits(rowCount: frame.rows.count, estimatedBytes: bytes)
    }

    func reset() {
        generation &+= 1
        previous = nil
        missedRead = false
    }
}

struct MenuBarPreparedProcesses: Sendable {
    let snapshot: EnergyImpactSnapshot
    let energy: [EnergyImpactApp]
    let cpu: [EnergyImpactApp]
    let disk: [EnergyImpactApp]

    /// D171: a first read listed before any interval was measured (every
    /// rate 0); the first delta replaces it.
    var isFirstRead: Bool { snapshot.sampleSeconds <= 0 }

    static func fitsCache(_ snapshot: EnergyImpactSnapshot) -> Bool {
        guard snapshot.apps.count <= MenuBarPerformancePolicy.processCacheRowLimit else { return false }
        let bytes = snapshot.apps.reduce(0) { bytes, app in
            bytes + 1_024 + 2 * (app.id.utf8.count + app.name.utf8.count + app.path.utf8.count
                + app.iconPath.utf8.count + (app.bundlePath?.utf8.count ?? 0)
                + (app.bundleIdentifier?.utf8.count ?? 0)) + app.processIDs.count * 8
        }
        return MenuBarProcessCacheBudget.fits(rowCount: snapshot.apps.count, estimatedBytes: bytes)
    }

    /// D79: one sampled inventory, independent candidate sets; no provider reads.
    /// D129: as iStat's `processesWithConfig:`, only the energy list has a
    /// threshold; the CPU and disk lists are the top five of the measured
    /// snapshot, idle apps included (was positive CPU% / read + write only).
    init(snapshot: EnergyImpactSnapshot, limit: Int = 5) {
        self.snapshot = snapshot
        let apps = snapshot.apps.filter(\.isApplication)
        let count = max(0, limit)
        energy = Self.top(apps.filter { $0.isSignificantCurrentEnergy && $0.currentPowerWatts.isFinite },
                          count: count, metric: { $0.currentPowerWatts })
        cpu = Self.top(apps.filter { $0.cpuPercent.isFinite }, count: count, metric: { $0.cpuPercent })
        disk = Self.top(apps, count: count, metric: Self.diskRate)
    }

    private static func diskRate(_ app: EnergyImpactApp) -> Double {
        Double(max(0, app.diskReadBytesPerSecond)) + Double(max(0, app.diskWriteBytesPerSecond))
    }

    private static func top(_ apps: [EnergyImpactApp], count: Int,
                            metric: (EnergyImpactApp) -> Double) -> [EnergyImpactApp] {
        Array(apps.sorted {
            let lhs = metric($0), rhs = metric($1)
            if lhs != rhs { return lhs > rhs }
            if $0.name != $1.name { return $0.name.compare($1.name, options: .literal) == .orderedAscending }
            let lhsPID = $0.processIDs.min() ?? Int32.max
            let rhsPID = $1.processIDs.min() ?? Int32.max
            if lhsPID != rhsPID { return lhsPID < rhsPID }
            return $0.id < $1.id
        }.prefix(count))
    }
}
