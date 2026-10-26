import Foundation

/// Local performance contract shared by collection, presentation and release checks.
enum MenuBarPerformancePolicy {
    /// Interval of the standalone readers (no resident controller attached).
    /// D127: the resident plan reads these sources on every main-loop tick.
    static let visibleExpensiveInterval: TimeInterval = 5
    static let networkProcessInterval: TimeInterval = 10
    /// D74 hidden budgets (status 5 s, process lists 15 s, per-app nettop 60 s),
    /// retired from the resident plan by D127: iStat reads every source on the
    /// same tick whether its menu is open or not, and reads process lists only
    /// while a module menu that shows one is open. Low Power Mode keeps its own
    /// slower tier below (iStat does not throttle; ours does, D127 deviation).
    static let hiddenStatusInterval: TimeInterval = 5
    static let hiddenProcessInterval: TimeInterval = 15
    static let hiddenNetworkProcessInterval: TimeInterval = 60
    static let lowPowerHiddenNetworkProcessInterval: TimeInterval = 180
    static let hiddenHelperPowerInterval: TimeInterval = 60
    static let visibleHelperPowerInterval: TimeInterval = 5
    /// Low Power Mode reduces polling even while visible. Sleep/display sleep
    /// suspend all resident reads; no activity or power assertion is acquired.
    static let lowPowerStatusInterval: TimeInterval = 30
    static let lowPowerProcessInterval: TimeInterval = 60
    static let lowPowerHelperPowerInterval: TimeInterval = 180
    /// One latest process frame/list, bounded separately from D39 chart windows.
    /// PS already has a 2 MiB output cap. Also bound retained parsed rows/apps.
    static let processCacheByteLimit = derivedCacheByteLimit / 4
    static let processCacheRowLimit = 4_096
    static let hiddenNoStatusInterval: TimeInterval = 30
    static let visibleProcessInterval: TimeInterval = 10
    /// BOARD N16-2: the first measurement after a process page opens. Its
    /// baseline is read at once; the first delta does not wait a full
    /// `visibleProcessInterval`. D127: iStat's `-[ItemManager startItemsForKey:]`
    /// reads at once and again after 0.5 s (0x1DCD6500 ns), then every tick.
    static let firstProcessSampleInterval: TimeInterval = 0.5
    /// D127: a reading due on every tick must not skip one because two
    /// wake-ups of the main loop landed a few milliseconds closer together.
    static let tickTolerance: TimeInterval = 0.1

    static func isDue(since last: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval - tickTolerance
    }

    /// D127: an open process page reads on every tick, never two reads less
    /// than a second apart (no 0.2 s deltas when a tick lands right after the
    /// 0.5 s follow-up). A process budget slower than the tick (Low Power
    /// Mode) is kept as is.
    static let processMinimumSpacing: TimeInterval = 1

    static func processSpacing(_ processes: TimeInterval, tick: TimeInterval) -> TimeInterval {
        processes > tick ? processes : processMinimumSpacing
    }
    /// Review P2-8: how long a process page may say "正在采样…" before it says
    /// nothing was measured (a reader that keeps giving nothing).
    static let processSampleTimeout: TimeInterval = 5
    static let cachedWindowLifetime: Duration = .seconds(300)
    static let derivedCacheByteLimit = 32 * 1_024 * 1_024
    static let derivedCachePageLimit = 4
    static let warmPresentationBudget: TimeInterval = 0.100
    static let coldPresentationBudget: TimeInterval = 0.250
    static let publicationBudget: TimeInterval = 0.100
    static let mainThreadBlockBudget: TimeInterval = 0.050
    static let contentCoalescingInterval: TimeInterval = 0.016
}

struct MenuBarSamplingCadence: Equatable, Sendable {
    let cheap: TimeInterval
    let expensive: TimeInterval
    let processes: TimeInterval
    let networkProcesses: TimeInterval
    let helperPower: TimeInterval
    let suspended: Bool

    static func resolve(visible: Bool, lowPower: Bool, suspended: Bool,
                        selectedInterval: TimeInterval = 1) -> Self {
        if lowPower {
            return .init(cheap: MenuBarPerformancePolicy.lowPowerStatusInterval,
                         expensive: MenuBarPerformancePolicy.lowPowerStatusInterval,
                         processes: MenuBarPerformancePolicy.lowPowerProcessInterval,
                         networkProcesses: visible ? MenuBarPerformancePolicy.lowPowerProcessInterval
                             : MenuBarPerformancePolicy.lowPowerHiddenNetworkProcessInterval,
                         helperPower: MenuBarPerformancePolicy.lowPowerHelperPowerInterval,
                         suspended: suspended)
        }
        // D127 (iStat `-[Statistics update]`): one loop at the selected interval
        // reads every source, menu open or closed, and the open menu redraws
        // from it. Process lists use the same tick but only run while their
        // page is open (ScanStore / MenuBarAuxiliaryMonitorState). The helper's
        // power command keeps its own budget (G3, waiting for the user).
        return .init(cheap: selectedInterval,
                     expensive: selectedInterval,
                     processes: selectedInterval,
                     networkProcesses: selectedInterval,
                     helperPower: visible ? MenuBarPerformancePolicy.visibleHelperPowerInterval
                         : MenuBarPerformancePolicy.hiddenHelperPowerInterval,
                     suspended: suspended)
    }
}

struct MenuBarDisplayRevision: Equatable, Sendable {
    let sampledAt: Date?
    let version: UInt64
}

/// Conservative retained-payload budget: fixed row overhead plus twice UTF-8
/// bytes (covers UTF-16 storage), with a count bound on dictionaries/arrays.
/// This bounds each latest parsed cache; there is no process-list history.
enum MenuBarProcessCacheBudget {
    static func fits(rowCount: Int, estimatedBytes: Int) -> Bool {
        rowCount >= 0 && rowCount <= MenuBarPerformancePolicy.processCacheRowLimit
            && estimatedBytes >= 0 && estimatedBytes <= MenuBarPerformancePolicy.processCacheByteLimit
    }

    static func memoryApps(_ apps: [MemoryAppUsage]) -> [MemoryAppUsage] {
        var bytes = 0
        return Array(apps.prefix(MenuBarPerformancePolicy.processCacheRowLimit).prefix { app in
            let cost = 512 + 2 * (app.id.utf8.count + app.name.utf8.count
                + app.iconPath.utf8.count + (app.bundlePath?.utf8.count ?? 0))
                + 8 * (app.processIDs.count + app.selectableProcessIDs.count)
            guard cost <= MenuBarPerformancePolicy.processCacheByteLimit - bytes else { return false }
            bytes += cost
            return true
        })
    }
}
