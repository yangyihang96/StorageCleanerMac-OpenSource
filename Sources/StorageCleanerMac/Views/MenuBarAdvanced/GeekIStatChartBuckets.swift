import Foundation
import CoreGraphics

/// D130, D131 (R8c): how a chart turns its points into bars.
///
/// iStat Menus 7.30 draws two kinds of graphs (spec
/// `2.0.1-小窗重写-20261018/01-iStat小窗规格.md` §6–§7, D117 history report
/// §5): a menu's graph (levels one and two) draws one bar per sample of the
/// module's 1000-sample ring, the newest at the right; a history submenu
/// (level three) draws 120 closed buckets of the selected window's tier.
enum GeekChartBucketing: Hashable, Sendable {
    /// Our earlier projection: time slots across the window, short gaps
    /// estimated, 600 averaging windows from one hour up. The main window's
    /// charts keep it.
    case projection
    /// Levels one and two (`GeekIStatSampleBars`).
    case samples
    /// Level three (`GeekIStatHistoryBuckets`).
    case history

    /// What prepares a frame again besides new points: the projection on
    /// every clock tick, the history when a bucket closes, the sample bars
    /// never.
    func clockRevision(for referenceDate: Date, duration: TimeInterval) -> TimeInterval {
        switch self {
        case .projection: floor(referenceDate.timeIntervalSince1970)
        case .samples: 0
        case .history: floor(referenceDate.timeIntervalSince1970 / GeekIStatHistoryBuckets.interval(for: duration))
        }
    }

    /// iStat draws nothing for a missing bucket: no gap block.
    var fillsGaps: Bool { self == .projection }

    /// iStat rescales on every redraw (no eased scale), and a recorded zero
    /// is a 1 pt bar, as any other value.
    var easesScale: Bool { self == .projection }
    var zeroIsBar: Bool { self != .projection }

    /// The window a frame of the sample bars does not depend on.
    func window(_ duration: TimeInterval) -> TimeInterval? {
        self == .samples ? nil : duration
    }

    /// Part of a frame's identity; empty for the projection, so its keys are
    /// unchanged.
    var preparationTag: String {
        switch self {
        case .projection: ""
        case .samples: ":samples"
        case .history: ":history"
        }
    }
}

/// D131: iStat's menu graphs. One bar per sample, the newest at the right,
/// as many as the graph has room for; time does not place a bar, so a pause
/// leaves no gap. A point that is not one sample (a folded minute) or holds
/// no reading of the chart's series is not a bar.
enum GeekIStatSampleBars {
    /// Each module keeps its last 1000 samples (`memmove` ring).
    static let ringCapacity = 1_000

    static func buckets(
        dates: [Date], plotRect: CGRect, displayScale: CGFloat,
        referenceDate: Date? = nil, isSample: (Int) -> Bool
    ) -> [GeekChartBucketSnapshot] {
        guard plotRect.width.isFinite, plotRect.width > 0 else { return [] }
        let slots = GeekChartWindow.barSlotCount(in: plotRect, displayScale: displayScale)
        let latest = referenceDate?.addingTimeInterval(GeekChartWindow.futureSampleTolerance)
        var samples = dates.indices.filter { index in
            latest.map { dates[index] <= $0 } != false && isSample(index)
        }
        if zip(samples, samples.dropFirst()).contains(where: { dates[$0.0] > dates[$0.1] }) {
            samples.sort { dates[$0] == dates[$1] ? $0 < $1 : dates[$0] < dates[$1] }
        }
        let shown = Array(samples.suffix(min(slots, ringCapacity)))
        let firstSlot = slots - shown.count
        return (0..<slots).map { slot in
            let x = GeekChartWindow.barX(forSlot: slot, in: plotRect, displayScale: displayScale)
            guard slot >= firstSlot else {
                let date = shown.first.map { dates[$0] } ?? referenceDate ?? .distantPast
                return GeekChartBucketSnapshot(indices: [], x: x, start: date, end: date)
            }
            let index = shown[slot - firstSlot]
            return GeekChartBucketSnapshot(indices: [index], x: x, start: dates[index], end: dates[index])
        }
    }
}

/// D130: iStat's history submenu (`BBRMenuCPUHistoryGraphSection`,
/// `BBRMenuBandwidthHistoryGraphSection` `drawRect:`). With T0 =
/// floor(now / iv) · iv, the bar i from the right is the bucket ending at
/// T0 − i · iv, the mean of the samples in (end − iv, end]
/// (`historyAverage:end:interval:`). A bucket without samples stays empty and
/// the bucket still collecting samples is not drawn. The bars keep the 3 pt
/// pitch, the newest at the right; a plot too narrow for all of them shows the
/// newest ones that fit.
enum GeekIStatHistoryBuckets {
    /// Bars of a history (`limit 120`) and of the battery history.
    static let slotCount = 120
    static let batterySlotCount = 96

    /// Seconds per bar of each window (`loadTimePopup`), 120 bars each. The
    /// 28-day window spans 30 days, as iStat's does; we keep 28 days, so its
    /// oldest eight bars stay empty.
    static func interval(for duration: TimeInterval) -> TimeInterval {
        switch GeekChartRange(rawValue: Int(duration.rounded())) {
        case .tenMinutes: 5
        case .oneHour: 30
        case .threeHours: 90
        case .sixHours: 180
        case .twelveHours: 360
        case .oneDay: 720
        case .threeDays: 2_160
        case .sevenDays: 5_040
        case .fourteenDays: 10_080
        case .twentyEightDays: 21_600
        default: max(1, (duration / Double(slotCount)).rounded())
        }
    }

    static func boundary(_ key: Int64, interval: TimeInterval) -> Date {
        Date(timeIntervalSince1970: Double(key) * interval)
    }

    /// floor(now / iv): the key of the newest closed bucket, which ends at
    /// `boundary(key)`. Every step compares Dates, as `GeekHistoryAveraging`
    /// does: seconds since 1970 can round onto a boundary.
    static func newestClosedKey(at referenceDate: Date, interval: TimeInterval) -> Int64? {
        guard let estimate = key(referenceDate, interval: interval, rule: .down) else { return nil }
        var key = estimate
        while referenceDate < boundary(key, interval: interval) { key -= 1 }
        while referenceDate >= boundary(key + 1, interval: interval) { key += 1 }
        return key
    }

    /// ceil(date / iv): the key of the bucket (end − iv, end] holding `date`.
    static func endKey(containing date: Date, interval: TimeInterval) -> Int64? {
        guard let estimate = key(date, interval: interval, rule: .up) else { return nil }
        var key = estimate
        while date > boundary(key, interval: interval) { key += 1 }
        while date <= boundary(key - 1, interval: interval) { key -= 1 }
        return key
    }

    private static func key(_ date: Date, interval: TimeInterval, rule: FloatingPointRoundingRule) -> Int64? {
        let value = (date.timeIntervalSince1970 / interval).rounded(rule)
        guard interval.isFinite, interval > 0, value.isFinite,
              abs(value) < Double(Int64.max / 2) else { return nil }
        return Int64(value)
    }

    /// `weight` counts the samples a point stands for: 1 for a sample, the
    /// folded sample count for a minute of the compressed history, so a
    /// bucket's value stays the mean of its samples.
    static func buckets(
        dates: [Date], interval: TimeInterval, count: Int = slotCount,
        plotRect: CGRect, referenceDate: Date, displayScale: CGFloat,
        gaps: [DateInterval] = [], isMissing: (Int) -> Bool = { _ in false },
        weight: (Int) -> Double = { _ in 1 }
    ) -> [GeekChartBucketSnapshot] {
        guard count > 0, plotRect.width.isFinite, plotRect.width > 0,
              let newest = newestClosedKey(at: referenceDate, interval: interval) else { return [] }
        let slots = GeekChartWindow.barSlotCount(in: plotRect, displayScale: displayScale)
        let shown = min(count, slots)
        let oldest = newest - Int64(shown - 1)
        let lower = boundary(oldest - 1, interval: interval)
        let upper = boundary(newest, interval: interval)
        let pauses = GeekHistoryAveraging.KnownPauses(gaps)
        var groups = Array(repeating: [Int](), count: shown)
        var weights = Array(repeating: [Double](), count: shown)
        for index in dates.indices {
            let date = dates[index]
            guard date > lower, date <= upper, !isMissing(index), !pauses.contains(date),
                  let key = endKey(containing: date, interval: interval),
                  key >= oldest, key <= newest else { continue }
            let pointWeight = weight(index)
            guard pointWeight.isFinite, pointWeight > 0 else { continue }
            groups[Int(key - oldest)].append(index)
            weights[Int(key - oldest)].append(pointWeight)
        }
        return (0..<shown).map { offset in
            var group = groups[offset], groupWeights = weights[offset]
            if zip(group, group.dropFirst()).contains(where: { dates[$0.0] > dates[$0.1] }) {
                let ordered = zip(group, groupWeights).sorted {
                    dates[$0.0] == dates[$1.0] ? $0.0 < $1.0 : dates[$0.0] < dates[$1.0]
                }
                group = ordered.map(\.0)
                groupWeights = ordered.map(\.1)
            }
            let end = boundary(oldest + Int64(offset), interval: interval)
            return GeekChartBucketSnapshot(
                indices: group,
                x: GeekChartWindow.barX(forSlot: slots - shown + offset, in: plotRect, displayScale: displayScale),
                start: end.addingTimeInterval(-interval), end: end,
                averagingGroups: [group], averagingInterval: interval, averagingWeights: [groupWeights]
            )
        }
    }

    /// The span the bars of `buckets` cover (for the timeline labels).
    static func range(of buckets: [GeekChartBucketSnapshot], fallback: Date) -> (start: Date, end: Date, dataStart: Date) {
        let start = buckets.first?.start ?? fallback
        return (start, buckets.last?.end ?? fallback, start)
    }
}

/// D132: iStat's battery graphs. The battery menu's graph
/// (`BBRBatteryMenuBatteryGraphSection drawRect:`) draws the newest 69
/// buckets of 900 s; the battery history submenu
/// (`BBRMenuBatteryHistoryGraphSection`) 96 buckets of its own tiers. Both
/// end at floor(now / iv) · iv and take a bucket's mean charge and power
/// source (on AC at ≥ 0.5), else the powerlog's mean (`combinedSamples`; we
/// read no powerlog), else the newer neighbor's value: without limit for
/// buckets of 900 s and less, at most eight times since the last empty bar
/// for longer ones.
enum GeekIStatBatteryGraph: Hashable, Sendable {
    case menu
    case history

    /// The submenu's windows (`loadTimePopup`), 1 day selected at first
    /// (`setInterval: 900`).
    static let historyRanges: [GeekChartRange] = [
        .oneHour, .threeHours, .sixHours, .twelveHours, .oneDay, .threeDays, .sevenDays,
    ]
    static let defaultHistoryRange = GeekChartRange.oneDay
    /// The battery menu draws 69 bars (90 in iStat's demo mode).
    static let menuBarCount = 69
    static let menuInterval: TimeInterval = 900

    /// A window the submenu does not offer reads as the nearest one it does.
    static func historyRange(_ range: GeekChartRange) -> GeekChartRange {
        if historyRanges.contains(range) { return range }
        return range.duration < GeekChartRange.oneHour.duration ? .oneHour : .sevenDays
    }

    /// Seconds per bar: 96 bars span the window (the 1-hour tier's whole
    /// 37 s cover 59.2 minutes).
    static func historyInterval(for duration: TimeInterval) -> TimeInterval {
        switch GeekChartRange(rawValue: Int(duration.rounded())) {
        case .oneHour: 37
        case .threeHours: 112
        case .sixHours: 225
        case .twelveHours: 450
        case .oneDay: 900
        case .threeDays: 2_700
        case .sevenDays: 6_300
        default: max(1, (duration / Double(GeekIStatHistoryBuckets.batterySlotCount)).rounded())
        }
    }

    func interval(for duration: TimeInterval) -> TimeInterval {
        self == .menu ? Self.menuInterval : Self.historyInterval(for: duration)
    }

    var barCount: Int {
        self == .menu ? Self.menuBarCount : GeekIStatHistoryBuckets.batterySlotCount
    }

    /// How far back the bars reach (one bucket more, for the one that is
    /// closing at the reference).
    func span(for duration: TimeInterval) -> TimeInterval {
        Double(barCount + 1) * interval(for: duration)
    }

    /// Fills an empty bucket (values oldest first) with its newer neighbor's
    /// value; nil for buckets of 900 s and less, else 8 (`interval > 900 &&
    /// count > 7` stops it). The count restarts only at an empty bar, and
    /// no bucket before `oldestFillable` is filled: iStat's powerlog covers
    /// the time before its own history, we have nothing to fill it from.
    static func fillLimit(interval: TimeInterval) -> Int? {
        interval > 900 ? 8 : nil
    }

    static func filled<Value>(
        _ values: [Value?], interval: TimeInterval, oldestFillable: Int = 0
    ) -> [(value: Value, isFill: Bool)?] {
        let limit = fillLimit(interval: interval)
        var result = [(value: Value, isFill: Bool)?](repeating: nil, count: values.count)
        var newer: Value?
        var fills = 0
        for index in values.indices.reversed() {
            if let value = values[index] {
                result[index] = (value, false)
                newer = value
            } else if let carried = newer, index >= oldestFillable, limit.map({ fills < $0 }) ?? true {
                result[index] = (carried, true)
                fills += 1
            } else {
                newer = nil
                fills = 0
            }
        }
        return result
    }
}
