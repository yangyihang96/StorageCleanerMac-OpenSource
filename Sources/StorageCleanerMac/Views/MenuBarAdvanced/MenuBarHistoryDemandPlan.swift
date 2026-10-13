import Foundation

/// A chart's points together with the window they cover.
struct MenuBarDisplayedHistory {
    let points: [MenuBarTelemetryPoint]
    /// The window the chart draws: the selected range once it is prepared,
    /// until then the range it drew before.
    let range: GeekChartRange
    let isUpdating: Bool
    /// Facts the sensors pages show, prepared with the window (P2-1); nil
    /// for memory windows and demo data.
    var summary: MenuBarTelemetryWindowSummary? = nil

    /// The reading a card shows as "now" beside this history (D39): the last
    /// point drawn while the history is current, so the number matches the
    /// chart; the live reading while the history is not prepared yet, or is a
    /// window kept from before the panel was hidden or the previous range's
    /// window, so a total shows neither "—" nor an old value right after the
    /// panel opens.
    func currentReading(live: MenuBarTelemetryPoint?) -> MenuBarTelemetryPoint? {
        if !isUpdating, let last = points.last { return last }
        return live ?? points.last
    }
}

/// A sample's network rates (`MenuBarMonitorState.lastNetworkReading`).
struct MenuBarNetworkReading: Equatable, Sendable {
    let date: Date
    let downBytesPerSecond: Int64
    let upBytesPerSecond: Int64
}

/// BOARD N16-3: the network card's rates. They are the network history's
/// current reading (D39), not the open page's window. A sample without
/// rates (taken right after the previous one, or across an interface
/// change; the chart keeps that gap) keeps the last rates read, so the
/// card does not flash "--" between samples. A reading more than
/// `maximumAge` before now is not kept (review P2-7: counted to now, not to
/// the current sample's time, which can be a kept sample from long ago).
enum MenuBarNetworkReadout {
    static let maximumAge: TimeInterval = 15

    static func rates(current: MenuBarTelemetryPoint?, lastReading: MenuBarNetworkReading?,
                      now: Date) -> (down: Int64?, up: Int64?) {
        rates(current: current, lastReading: lastReading, now: now, retainsStoredReading: false)
    }

    static func rates(
        current: MenuBarTelemetryPoint?,
        lastReading: MenuBarNetworkReading?,
        now: Date,
        retainsStoredReading: Bool
    ) -> (down: Int64?, up: Int64?) {
        if let current,
           let down = current.downBytesPerSecond,
           let up = current.upBytesPerSecond {
            return (down, up)
        }
        if let lastReading,
           (retainsStoredReading && lastReading.date <= now
            || abs(now.timeIntervalSince(lastReading.date)) <= maximumAge) {
            return (lastReading.downBytesPerSecond, lastReading.upBytesPerSecond)
        }
        return (current?.downBytesPerSecond, current?.upBytesPerSecond)
    }
}

/// The history windows the visible mini-window page reads.
///
/// The monitor prepares a small number of windows off the main thread
/// (`MenuBarMonitorState.maximumDisplayDurationCount`). A chart can only draw
/// a window that is part of this demand, so every chart's range comes from
/// here, in the order in which the windows matter on screen.
@MainActor
struct MenuBarHistoryDemandPlan: Equatable {
    /// The open history's range (its metric's own range for an inline
    /// history), otherwise the page's range.
    let selectedRange: GeekChartRange
    let cpuRange: GeekChartRange
    let networkRange: GeekChartRange

    init(
        settings: MenuBarPanelSettingsState,
        section: PanelSection,
        inlineMetric: GeekChartRangeMetric?
    ) {
        selectedRange = inlineMetric.map { settings.geekChartRange(for: $0, fallbackTo: section) }
            ?? settings.geekChartRange(for: section)
        cpuRange = settings.geekChartRange(for: .cpu, fallbackTo: .processor)
        networkRange = settings.geekChartRange(for: .network, fallbackTo: .network)
    }

    /// The window a memory history opened by route (not inline) reads. No
    /// memory-metric request is active then, so its label and picker show and
    /// change the page's range; the points must come from that same range,
    /// which is always part of `durations`.
    var routedMemoryRange: GeekChartRange {
        selectedRange
    }

    /// Windows to prepare, most visible first: the open history or the page,
    /// then the CPU and network cards.
    var durations: [TimeInterval] {
        var result: [TimeInterval] = []
        for range in [selectedRange, cpuRange, networkRange] where !result.contains(range.duration) {
            result.append(range.duration)
        }
        return result
    }
}
