import Foundation

/// Local performance contract shared by collection, presentation and release checks.
enum MenuBarPerformancePolicy {
    static let visibleExpensiveInterval: TimeInterval = 5
    static let networkProcessInterval: TimeInterval = 10
    static let hiddenStatusInterval: TimeInterval = 5
    /// D74: cheap kernel/SMC reads share the resident tick. Process enumeration
    /// runs once per three hidden ticks; the fixed helper command once per 12.
    /// These are cost budgets, not measured energy savings (see batch handoff).
    static let hiddenProcessInterval: TimeInterval = 15
    /// D75: only per-app nettop reads move from 15 to 60 seconds when hidden.
    /// PS and memory grouping retain hiddenProcessInterval. The low-power
    /// hidden network tier uses the existing helper's 60 -> 180 (3x) budget.
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
    /// `visibleProcessInterval`.
    static let firstProcessSampleInterval: TimeInterval = 0.5
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
        return .init(cheap: visible ? selectedInterval : MenuBarPerformancePolicy.hiddenStatusInterval,
                     expensive: MenuBarPerformancePolicy.visibleExpensiveInterval,
                     processes: visible ? MenuBarPerformancePolicy.visibleProcessInterval
                         : MenuBarPerformancePolicy.hiddenProcessInterval,
                     networkProcesses: visible ? MenuBarPerformancePolicy.networkProcessInterval
                         : MenuBarPerformancePolicy.hiddenNetworkProcessInterval,
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
