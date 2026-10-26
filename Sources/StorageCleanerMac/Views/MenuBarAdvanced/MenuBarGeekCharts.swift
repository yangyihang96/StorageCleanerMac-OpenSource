import SwiftUI

enum GeekChartUnit {
    case percent
    /// The benchmark page's load (main window, not iStat): "27.4%", "27%"
    /// when compact, the charts' percent before D128.
    case percentWithTenths
    case temperature
    case fanRPM
    case bytes
    /// Network rates.
    case bytesPerSecond
    /// D128: disk rates (iStat's disk activity format, not bandwidth's).
    case diskBytesPerSecond

    /// D128: iStat's graph formats (`BBRMenu*HistoryGraphSection`): usage
    /// "%.0f%%", whole degrees "45°", memory in 1024s with its fixed
    /// decimals, rates as the menus' rows. `compact` only drops the fan unit
    /// (was "%.1f%%"/"%.1f°C" outside compact, ByteFormat's KiB and "/s").
    func formatted(_ value: Double, compact: Bool = false) -> String {
        switch self {
        case .percent:
            return IStatNumberFormat.graphPercent(value)
        case .percentWithTenths:
            return String(format: compact ? "%.0f%%" : "%.1f%%", value)
        case .temperature:
            return IStatNumberFormat.temperature(value)
        case .fanRPM:
            return compact ? IStatNumberFormat.number(value, decimals: 0) : IStatNumberFormat.fanSpeed(value)
        case .bytes:
            return IStatNumberFormat.memory(max(0, value))
        case .bytesPerSecond:
            return IStatNumberFormat.bandwidth(max(0, value))
        case .diskBytesPerSecond:
            return IStatNumberFormat.diskActivity(max(0, value))
        }
    }
}

enum GeekPrecisionChartStyle: Sendable {
    case line
    case stackedBars
}

enum ChartDomainPolicy: Equatable, Sendable {
    case fixed(min: Double, max: Double)
    case symmetricDynamic
    case positiveDynamic

    func resolvedRange(fallback: ClosedRange<Double>) -> ClosedRange<Double> {
        switch self {
        case let .fixed(minimum, maximum):
            guard minimum.isFinite,
                  maximum.isFinite,
                  maximum > minimum else {
                return fallback
            }
            return minimum...maximum
        case .positiveDynamic:
            return 0...max(1, fallback.upperBound)
        case .symmetricDynamic:
            let maximum = max(abs(fallback.lowerBound), abs(fallback.upperBound), 1)
            return -maximum...maximum
        }
    }
}

private struct MiniWindowPreviewDateKey: EnvironmentKey { static let defaultValue: Date? = nil }
extension EnvironmentValues {
    var miniWindowPreviewDate: Date? {
        get { self[MiniWindowPreviewDateKey.self] }
        set { self[MiniWindowPreviewDateKey.self] = newValue }
    }
}

struct GeekLiveChartTimeline<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelChartClock) private var sharedClock
    @Environment(\.miniWindowPreviewDate) private var previewDate

    let duration: TimeInterval
    private let content: (Date) -> Content

    init(
        duration: TimeInterval,
        @ViewBuilder content: @escaping (Date) -> Content
    ) {
        self.duration = duration
        self.content = content
    }

    @ViewBuilder
    var body: some View {
        if let previewDate {
            content(previewDate)
        } else if let sharedClock {
            SharedPanelChartClockContent(clock: sharedClock, content: content)
        } else {
            TimelineView(
                .periodic(
                    from: .now,
                    by: Self.refreshInterval(
                        for: duration,
                        reduceMotion: reduceMotion
                    )
                )
            ) { timeline in
#if DEBUG || STORAGE_CLEANER_BETA
                content(MiniWindowDemoData.chartDate(liveDate: timeline.date))
#else
                content(timeline.date)
#endif
            }
        }
    }

    nonisolated static func refreshInterval(
        for duration: TimeInterval,
        reduceMotion: Bool
    ) -> TimeInterval {
        // Use the densest supported 120-slot plot as the shared clock. Real
        // samples still redraw immediately; this only avoids empty 1 Hz ticks
        // between meaningful bucket boundaries on longer ranges.
        return max(1, duration / 120)
    }
}

private struct SharedPanelChartClockContent<Content: View>: View {
    @ObservedObject var clock: PanelChartClock
    let content: (Date) -> Content

    var body: some View {
        content(clock.referenceDate)
    }
}

enum GeekChartWindow {
    static let defaultDuration: TimeInterval = 120
    static let barMarkWidth = MiniWindowStyleTokens.barWidth
    static let barSpacing = MiniWindowStyleTokens.barSpacing
    static let barPitch = MiniWindowStyleTokens.barPitch
    static let futureSampleTolerance: TimeInterval = 2

    static func elapsedLabel(_ duration: TimeInterval) -> String {
        let value: Double
        let suffix: String
        if duration >= 86_400 {
            value = duration / 86_400
            suffix = "d"
        } else if duration >= 3_600 {
            value = duration / 3_600
            suffix = "h"
        } else {
            value = duration / 60
            suffix = "m"
        }
        let number = value.rounded() == value
            ? String(Int(value))
            : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
        return "−\(number)\(suffix)"
    }

    static func range(
        for dates: [Date],
        duration: TimeInterval,
        referenceDate: Date? = nil
    ) -> (start: Date, end: Date) {
        let end = referenceDate ?? dates.max() ?? Date()
        return (end.addingTimeInterval(-duration), end)
    }

    static func barRange(
        for dates: [Date],
        duration: TimeInterval,
        referenceDate: Date? = nil
    ) -> (start: Date, end: Date, dataStart: Date) {
        let fullRange = range(
            for: dates,
            duration: duration,
            referenceDate: referenceDate
        )
        let dataStart: Date?
        if let referenceDate {
            dataStart = dates.lazy
                .filter { $0 <= referenceDate.addingTimeInterval(futureSampleTolerance) }
                .map { min($0, referenceDate) }
                .min()
        } else {
            dataStart = dates.min()
        }
        guard let dataStart else {
            return (fullRange.start, fullRange.end, fullRange.start)
        }

        return (fullRange.start, fullRange.end, dataStart)
    }

    static func x(for date: Date, in plotRect: CGRect, range: (start: Date, end: Date)) -> CGFloat? {
        guard date >= range.start, date <= range.end else { return nil }
        let span = max(1, range.end.timeIntervalSince(range.start))
        let fraction = date.timeIntervalSince(range.start) / span
        return plotRect.minX + plotRect.width * CGFloat(fraction)
    }

    static func barMetrics(
        displayScale: CGFloat = 1
    ) -> (width: CGFloat, spacing: CGFloat, pitch: CGFloat) {
        // D120: iStat's 2 pt bar and 1 pt gap at every scale, snapped to whole
        // pixels (D76 kept a one-physical-pixel gap: a 2.5 pt bar at 2x).
        let pitch = MiniWindowPixel.snappedLength(barMarkWidth + barSpacing, displayScale: displayScale)
        let spacing = max(MiniWindowPixel.onePhysicalPixel(displayScale: displayScale),
                          MiniWindowPixel.snappedLength(barSpacing, displayScale: displayScale))
        return (max(spacing, pitch - spacing), spacing, pitch)
    }

    /// D130, D131: with `zeroIsBar` a recorded zero is 1 pt tall, as iStat
    /// draws every value (`GeekChartBucketing.zeroIsBar`).
    static func stackedBarRect(
        x: CGFloat, width: CGFloat,
        lower: Double, upper: Double,
        in plotRect: CGRect,
        range: ClosedRange<Double>,
        displayScale: CGFloat,
        zeroIsBar: Bool = false
    ) -> CGRect {
        let span = max(Double.ulpOfOne, range.upperBound - range.lowerBound)
        let lowerY = plotRect.maxY - plotRect.height * CGFloat((lower - range.lowerBound) / span)
        let upperY = plotRect.maxY - plotRect.height * CGFloat((upper - range.lowerBound) / span)
        let height = max(
            minimumBarHeight(hasValue: upper > lower || zeroIsBar, displayScale: displayScale),
            MiniWindowPixel.snappedLength(abs(lowerY - upperY), displayScale: displayScale)
        )
        return CGRect(
            x: MiniWindowPixel.aligned(x, displayScale: displayScale),
            y: MiniWindowPixel.aligned(min(plotRect.maxY - height, min(lowerY, upperY)), displayScale: displayScale),
            width: width,
            height: height
        )
    }

    /// D121: a bar with a value is at least 1 pt tall, as iStat's are; a
    /// recorded zero stays one physical pixel, apart from an unrecorded gap.
    static func minimumBarHeight(hasValue: Bool, displayScale: CGFloat) -> CGFloat {
        hasValue
            ? max(MiniWindowPixel.onePhysicalPixel(displayScale: displayScale),
                  MiniWindowPixel.snappedLength(valuedBarMinimumHeight, displayScale: displayScale))
            : MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
    }

    static let valuedBarMinimumHeight: CGFloat = 1

    static func barSlotCount(
        in plotRect: CGRect,
        displayScale: CGFloat = 1
    ) -> Int {
        let metrics = barMetrics(displayScale: displayScale)
        return max(1, Int(floor((plotRect.width + metrics.spacing) / metrics.pitch)))
    }

    static func barBucketDuration(
        duration: TimeInterval,
        in plotRect: CGRect,
        displayScale: CGFloat = 1
    ) -> TimeInterval {
        max(1, duration) / Double(barSlotCount(in: plotRect, displayScale: displayScale))
    }

    static func barX(
        for date: Date,
        in plotRect: CGRect,
        range: (start: Date, end: Date, dataStart: Date),
        displayScale: CGFloat = 1
    ) -> CGFloat? {
        let metrics = barMetrics(displayScale: displayScale)
        let slotCount = barSlotCount(in: plotRect, displayScale: displayScale)
        guard let slot = barSlot(
            for: date,
            range: range,
            slotCount: slotCount,
            span: max(1, range.end.timeIntervalSince(range.start))
        ) else { return nil }
        return barX(
            forSlot: slot,
            in: plotRect,
            displayScale: displayScale,
            metrics: metrics,
            slotCount: slotCount
        )
    }

    /// D130, D131: also read by `GeekIStatHistoryBuckets` and
    /// `GeekIStatSampleBars`.
    static func barX(
        forSlot slot: Int,
        in plotRect: CGRect,
        displayScale: CGFloat
    ) -> CGFloat {
        let metrics = barMetrics(displayScale: displayScale)
        let slotCount = barSlotCount(in: plotRect, displayScale: displayScale)
        return barX(
            forSlot: slot,
            in: plotRect,
            displayScale: displayScale,
            metrics: metrics,
            slotCount: slotCount
        )
    }

    private static func barX(
        forSlot slot: Int,
        in plotRect: CGRect,
        displayScale: CGFloat,
        metrics: (width: CGFloat, spacing: CGFloat, pitch: CGFloat),
        slotCount: Int
    ) -> CGFloat {
        let usedWidth = CGFloat(slotCount) * metrics.width
            + CGFloat(max(0, slotCount - 1)) * metrics.spacing
        let leadingInset = max(0, (plotRect.width - usedWidth) / 2)
        let rawCenter = plotRect.minX
            + leadingInset
            + metrics.width / 2
            + CGFloat(slot) * metrics.pitch
        return MiniWindowPixel.strokeCenter(
            rawCenter,
            lineWidth: metrics.width,
            displayScale: displayScale
        )
    }

    static func barBucketSnapshots(
        for dates: [Date],
        in plotRect: CGRect,
        range: (start: Date, end: Date, dataStart: Date),
        referenceDate: Date? = nil,
        displayScale: CGFloat = 1
    ) -> [GeekChartBucketSnapshot] {
        let slotCount = barSlotCount(in: plotRect, displayScale: displayScale)
        let bucketDuration = max(1, range.end.timeIntervalSince(range.start)) / Double(slotCount)
        let observed: [(slot: Int, indices: [Int])] = barBucketMarksWithSlots(
            for: dates,
            in: plotRect,
            range: range,
            referenceDate: referenceDate,
            displayScale: displayScale
        ).compactMap { mark in
            guard let latestIndex = mark.indices.last,
                  dates.indices.contains(latestIndex) else { return nil }
            return (slot: mark.slot, indices: mark.indices)
        }
        guard !observed.isEmpty else {
            return []
        }
        let observedBySlot: [Int: [Int]] = Dictionary(
            uniqueKeysWithValues: observed.map { ($0.slot, $0.indices) }
        )

        return (0..<slotCount).map { slot in
            let start = range.start.addingTimeInterval(Double(slot) * bucketDuration)
            return GeekChartBucketSnapshot(
                indices: observedBySlot[slot] ?? [],
                x: barX(
                    forSlot: slot,
                    in: plotRect,
                    displayScale: displayScale
                ),
                start: start,
                end: min(range.end, start.addingTimeInterval(bucketDuration))
            )
        }
    }

    static func observedHoldBuckets(
        for dates: [Date], in plotRect: CGRect,
        range: (start: Date, end: Date, dataStart: Date),
        referenceDate: Date, displayScale: CGFloat
    ) -> [GeekChartBucketSnapshot] {
        displayBuckets(for: dates, in: plotRect, range: range,
            referenceDate: referenceDate, displayScale: displayScale)
    }

    /// A display-only reconstruction. Raw history and its statistics never
    /// receive these held estimates. Long failures and known pauses break a run.
    static func displayBuckets(
        for dates: [Date], in plotRect: CGRect,
        range: (start: Date, end: Date, dataStart: Date),
        referenceDate: Date, displayScale: CGFloat,
        isValid: (Int) -> Bool = { _ in true },
        isMissing: (Int) -> Bool = { _ in false },
        mayConnect: (Int, Int) -> Bool = { _, _ in true },
        intervalStart: (Int) -> Date? = { _ in nil },
        unrecordedIntervals: [DateInterval]? = nil,
        holdLatestWhileFresh: Bool = false
    ) -> [GeekChartBucketSnapshot] {
        let gaps = unrecordedIntervals ?? MenuBarSamplingGaps.shared.intervals(at: referenceDate)
        if let interval = GeekHistoryAveraging.interval(for: range.end.timeIntervalSince(range.start)) {
            return GeekHistoryAveraging.displayBuckets(dates: dates, interval: interval,
                plotRect: plotRect, range: range, referenceDate: referenceDate,
                displayScale: displayScale, gaps: gaps, isMissing: isMissing,
                intervalStart: intervalStart)
        }
        let buckets = barBucketSnapshots(for: dates, in: plotRect, range: range,
            referenceDate: referenceDate, displayScale: displayScale)
        var ordered = dates.indices.filter { dates[$0] <= referenceDate }
        if zip(ordered, ordered.dropFirst()).contains(where: { dates[$0.0] > dates[$0.1] }) {
            ordered.sort { dates[$0] < dates[$1] }
        }
        let rawOrder = ordered
        let rawPositions = Dictionary(uniqueKeysWithValues: rawOrder.enumerated().map { ($0.element, $0.offset) })
        // A wholly missing poll can be reconstructed only inside an otherwise
        // short, observed run. Partial readings remain untouched, as do pauses.
        ordered.removeAll(where: isMissing)
        // The clock can advance before the next poll arrives. Hold only the
        // freshest observed value during its normal cadence; never extend a
        // stopped run, failed latest poll, or a known pause into the present.
        let freshTail: Int? = {
            guard holdLatestWhileFresh, rawOrder.count >= 4,
                  let last = rawOrder.last, isValid(last), !isMissing(last) else { return nil }
            let recent = Array(rawOrder.suffix(9))
            let intervals = zip(recent, recent.dropFirst()).map { dates[$1].timeIntervalSince(dates[$0]) }
            guard intervals.allSatisfy({ $0 > 0 }) else { return nil }
            let sorted = intervals.sorted()
            let cadence = sorted[(sorted.count - 1) / 2]
            let freshness = min(90, cadence * 1.75)
            guard cadence <= 90, let latestInterval = intervals.last,
                  latestInterval <= freshness,
                  referenceDate.timeIntervalSince(dates[last]) <= freshness,
                  !MenuBarSamplingGaps.crosses(gaps, from: dates[last], to: referenceDate)
            else { return nil }
            return last
        }()
        guard ordered.count > 1 else { return buckets }
        var cursor = 0
        return buckets.map { bucket in
            guard bucket.indices.isEmpty || bucket.indices.allSatisfy(isMissing) else { return bucket }
            let midpoint = bucket.start.addingTimeInterval(bucket.end.timeIntervalSince(bucket.start) / 2)
            if let freshTail, midpoint > dates[freshTail] {
                return GeekChartBucketSnapshot(indices: [freshTail], x: bucket.x,
                    start: bucket.start, end: bucket.end, isEstimated: true)
            }
            while cursor + 1 < ordered.count && dates[ordered[cursor + 1]] <= midpoint { cursor += 1 }
            guard cursor + 1 < ordered.count else { return bucket }
            let before = ordered[cursor], after = ordered[cursor + 1]
            guard dates[before] <= midpoint, dates[after] > midpoint,
                  isValid(before), isValid(after), mayConnect(before, after),
                  !MenuBarSamplingGaps.crosses(gaps, from: dates[before], to: dates[after]) else { return bucket }
            // Rates measured from counters cover the interval ending at the
            // later reading. Its average is observed, not an invented poll.
            if let start = intervalStart(after), start <= bucket.start,
               dates[after] >= bucket.end {
                return GeekChartBucketSnapshot(indices: [after], x: bucket.x,
                    start: bucket.start, end: bucket.end)
            }
            let rawPosition = rawPositions[before] ?? 0
            let neighbourhood = max(0, rawPosition - 4)..<min(rawOrder.count - 1, rawPosition + 5)
            let intervals = neighbourhood.compactMap { position -> TimeInterval? in
                let interval = dates[rawOrder[position + 1]].timeIntervalSince(dates[rawOrder[position]])
                return interval > 0 && interval <= 90 ? interval : nil
            }.sorted()
            // A single isolated pair cannot establish a slow sampling cadence.
            let cadence = intervals.count >= 3 ? intervals[(intervals.count - 1) / 2] : 1
            let gapLimit = min(90, cadence * 3)
            guard dates[after].timeIntervalSince(dates[before]) <= gapLimit else { return bucket }
            let nearest = midpoint.timeIntervalSince(dates[before]) <= dates[after].timeIntervalSince(midpoint)
                ? before : after
            return GeekChartBucketSnapshot(indices: [nearest], x: bucket.x,
                start: bucket.start, end: bucket.end, isEstimated: true)
        }
    }

    private static func barSlot(
        for date: Date,
        range: (start: Date, end: Date, dataStart: Date),
        slotCount: Int,
        span: TimeInterval
    ) -> Int? {
        guard date >= range.dataStart,
              date >= range.start,
              date <= range.end else { return nil }
        let fraction = date.timeIntervalSince(range.start) / span
        return fraction >= 1
            ? slotCount - 1
            : min(slotCount - 1, max(0, Int(floor(fraction * Double(slotCount)))))
    }

    static func barMarks(
        for dates: [Date],
        in plotRect: CGRect,
        range: (start: Date, end: Date, dataStart: Date),
        referenceDate: Date? = nil,
        displayScale: CGFloat = 1
    ) -> [(index: Int, x: CGFloat)] {
        barBucketMarks(
            for: dates,
            in: plotRect,
            range: range,
            referenceDate: referenceDate,
            displayScale: displayScale
        ).compactMap { mark in
            mark.indices.last.map { (index: $0, x: mark.x) }
        }
    }

    static func barBucketMarks(
        for dates: [Date],
        in plotRect: CGRect,
        range: (start: Date, end: Date, dataStart: Date),
        referenceDate: Date? = nil,
        displayScale: CGFloat = 1
    ) -> [(indices: [Int], x: CGFloat)] {
        barBucketMarksWithSlots(
            for: dates,
            in: plotRect,
            range: range,
            referenceDate: referenceDate,
            displayScale: displayScale
        ).map { (indices: $0.indices, x: $0.x) }
    }

    private static func barBucketMarksWithSlots(
        for dates: [Date],
        in plotRect: CGRect,
        range: (start: Date, end: Date, dataStart: Date),
        referenceDate: Date? = nil,
        displayScale: CGFloat = 1
    ) -> [(indices: [Int], slot: Int, x: CGFloat)] {
        let metrics = barMetrics(displayScale: displayScale)
        let slotCount = barSlotCount(in: plotRect, displayScale: displayScale)
        let span = max(1, range.end.timeIntervalSince(range.start))
        let lowerBound = max(range.start, range.dataStart)
        let futureLimit = referenceDate?.addingTimeInterval(futureSampleTolerance)
        let orderedDates = dates.enumerated()
            .filter { element in
                let rawDate = element.element
                guard futureLimit.map({ rawDate <= $0 }) ?? true else {
                    return false
                }
                let date = referenceDate.map { min(rawDate, $0) } ?? rawDate
                return date >= lowerBound && date <= range.end
            }
            .sorted { lhs, rhs in
                if lhs.element != rhs.element { return lhs.element < rhs.element }
                return lhs.offset < rhs.offset
            }
        var slotMarks: [(indices: [Int], slot: Int, x: CGFloat)] = []
        for (index, rawDate) in orderedDates {
            let date = referenceDate.map { min(rawDate, $0) } ?? rawDate
            guard let slot = barSlot(
                for: date,
                range: range,
                slotCount: slotCount,
                span: span
            ) else { continue }
            let x = barX(
                forSlot: slot,
                in: plotRect,
                displayScale: displayScale,
                metrics: metrics,
                slotCount: slotCount
            )
            if slotMarks.last?.x == x {
                slotMarks[slotMarks.count - 1].indices.append(index)
            } else {
                slotMarks.append(([index], slot, x))
            }
        }
        return slotMarks
    }

}

struct GeekChartBucketSnapshot: Sendable {
    let indices: [Int]
    let x: CGFloat
    let start: Date
    let end: Date
    var isEstimated = false
    /// Each group is one fixed observation window for the selected range. Several groups
    /// may share a screen column, but window means receive equal weight.
    var averagingGroups: [[Int]]? = nil
    var averagingInterval: TimeInterval? = nil
    var averagingWeights: [[Double]]? = nil

    func mean(_ value: (Int) -> Double?) -> Double? {
        let groups = averagingGroups ?? [indices]
        return TimeBucketAggregator.average(groups.enumerated().compactMap { offset, group in
            var sum = 0.0, total = 0.0
            for (position, index) in group.enumerated() {
                guard let value = value(index), value.isFinite else { continue }
                let weight = averagingWeights?[offset][position] ?? 1
                sum += value * weight
                total += weight
            }
            return total > 0 ? sum / total : nil
        })
    }

    func displayValue(_ value: (Int) -> Double?) -> Double? {
        if averagingGroups != nil { return mean(value) }
        return TimeBucketAggregator.lastValid(indices.compactMap(value))
    }
}

struct TimeBucketValue<Value> {
    let value: Value?
    let isEstimated: Bool
    let sourceIndex: Int?
}

enum TimeBucketAggregator {
    static var nearestFillDescription: String {
        L10n.text(
            "短暂漏读按相邻样本估算，悬停可查看；空档表示该时段没有采样（应用未运行、睡眠或暂停），不是零。",
            "Hover to inspect short-gap estimates. Empty spans have no samples (app not running, sleep or pause); they are not zero."
        )
    }

    static func average(_ values: [Double]) -> Double? {
        let valid = values.filter(\.isFinite)
        guard !valid.isEmpty else { return nil }
        return valid.reduce(0, +) / Double(valid.count)
    }

    static func lastValid(_ values: [Double]) -> Double? {
        values.reversed().first(where: \.isFinite)
    }

    static func lastSample<T>(
        in indices: [Int],
        from samples: [T]
    ) -> T? {
        indices.reversed().compactMap { index in
            samples.indices.contains(index) ? samples[index] : nil
        }.first
    }

    static func lastSample<T>(
        in indices: [Int],
        from samples: [T],
        satisfying predicate: (T) -> Bool
    ) -> T? {
        indices.reversed().compactMap { index in
            samples.indices.contains(index) ? samples[index] : nil
        }.first(where: predicate)
    }

    // Compatibility names retained for chart callers; empty buckets are never imputed.
    static func nearestFilled<Value>(_ values: [Value?]) -> [TimeBucketValue<Value>] {
        values.indices.map { index in
            TimeBucketValue(
                value: values[index],
                isEstimated: false,
                sourceIndex: values[index] == nil ? nil : index
            )
        }
    }

    static func forwardFilled<Value>(_ values: [Value?]) -> [TimeBucketValue<Value>] {
        nearestFilled(values)
    }

    static func observedSegments<Value>(
        _ values: [Value?],
        in buckets: [GeekChartBucketSnapshot],
        sampleDates: [Date],
        unrecordedIntervals: [DateInterval]? = nil,
        isSampleValid: (Int) -> Bool
    ) -> [[(index: Int, value: Value)]] {
        guard values.count == buckets.count else { return [] }
        let bucketDuration = buckets.first.map { $0.end.timeIntervalSince($0.start) } ?? 1
        // Reuse the normal cadence tolerance, bounded by the existing history epoch
        // gap so a sparse first pair cannot imply continuity across a long sleep.
        let gapThreshold = min(
            PanelChartSampling.samplingGapThreshold(for: sampleDates),
            max(MenuBarTelemetryHistory.epochGapDuration, bucketDuration * 3)
        )
        var result: [[(index: Int, value: Value)]] = []
        let gaps = unrecordedIntervals ?? MenuBarSamplingGaps.shared.intervals()
        var current: [(index: Int, value: Value)] = []
        var previousDate: Date?

        func finishSegment() {
            if !current.isEmpty { result.append(current) }
            current.removeAll(keepingCapacity: true)
            previousDate = nil
        }

        for index in values.indices {
            let bucket = buckets[index]
            guard let value = values[index] else {
                // No observation in a narrow pixel bucket is normal for slower sources.
                // An observed sample whose channel is unavailable is an explicit break.
                if !bucket.indices.isEmpty { finishSegment() }
                continue
            }
            let sampleIndices = bucket.indices.filter { sampleDates.indices.contains($0) }
            guard let lastValidPosition = sampleIndices.lastIndex(where: isSampleValid) else {
                finishSegment()
                continue
            }
            // Compare the raw observations across and inside buckets. A wide
            // display bucket can contain many normal samples; comparing only
            // its last date with the previous bucket invents a sampling gap.
            var connectsToPrevious = previousDate != nil
            var lastSampleDate = previousDate
            for sampleIndex in sampleIndices[...lastValidPosition] {
                guard isSampleValid(sampleIndex) else {
                    connectsToPrevious = false
                    lastSampleDate = nil
                    continue
                }
                let date = sampleDates[sampleIndex]
                if let lastSampleDate,
                   date.timeIntervalSince(lastSampleDate) > gapThreshold
                    || MenuBarSamplingGaps.crosses(gaps, from: lastSampleDate, to: date) {
                    connectsToPrevious = false
                }
                lastSampleDate = date
            }
            if !connectsToPrevious { finishSegment() }
            current.append((index, value))
            previousDate = lastSampleDate
            if lastValidPosition != sampleIndices.count - 1 {
                // A later failed observation must also break the next bucket.
                finishSegment()
            }
        }
        finishSegment()
        return result
    }

}

struct GeekBarTimelineLabels: View {
    let timeRange: (start: Date, end: Date, dataStart: Date)
    let plotRect: CGRect

    init(
        timeRange: (start: Date, end: Date, dataStart: Date),
        plotRect: CGRect
    ) {
        self.timeRange = timeRange
        self.plotRect = plotRect
    }

    init(
        timeRange: (start: Date, end: Date),
        plotRect: CGRect
    ) {
        self.timeRange = (timeRange.start, timeRange.end, timeRange.start)
        self.plotRect = plotRect
    }

    init(
        dates: [Date],
        duration: TimeInterval,
        plotRect: CGRect,
        referenceDate: Date
    ) {
        timeRange = GeekChartWindow.barRange(
            for: dates,
            duration: duration,
            referenceDate: referenceDate
        )
        self.plotRect = plotRect
    }

    var body: some View {
        let visibleDuration = timeRange.end.timeIntervalSince(timeRange.start)
        let includesDate = PanelChartDateFormatting.includesDate(for: visibleDuration)
        let startLabel = includesDate
            ? PanelChartDateFormatting.string(
                for: timeRange.start,
                visibleDuration: visibleDuration
            )
            : GeekChartWindow.elapsedLabel(visibleDuration)
        let middleLabel = includesDate
            ? PanelChartDateFormatting.string(
                for: timeRange.start.addingTimeInterval(visibleDuration / 2),
                visibleDuration: visibleDuration
            )
            : GeekChartWindow.elapsedLabel(visibleDuration / 2)
        let endLabel = includesDate
            ? PanelChartDateFormatting.string(
                for: timeRange.end,
                visibleDuration: visibleDuration
            )
            : L10n.text("现在", "Now")

        Group {
            if includesDate {
                HStack(spacing: 0) {
                    Text(startLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(middleLabel)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text(endLabel)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(width: plotRect.width, alignment: .leading)
                .position(x: plotRect.midX, y: plotRect.maxY + 10)
            } else {
                Text(startLabel)
                    .position(x: plotRect.minX + 17, y: plotRect.maxY + 10)
                Text(middleLabel)
                    .position(x: plotRect.midX, y: plotRect.maxY + 10)
                Text(endLabel)
                    .position(x: plotRect.maxX - 13, y: plotRect.maxY + 10)
            }
        }
        .font(AdvancedPanelTypography.caption)
        .monospaced()
        .lineLimit(1)
        .minimumScaleFactor(includesDate ? 0.65 : 1)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
}

/// Axis line under a tertiary history chart: where the window starts, that it
/// ends now, the vertical scale and what the quiet gap blocks mean. The plot
/// keeps its built-in timeline and value labels off, so its viewport, hover
/// tooltips and prepared frames are unchanged; this row is static text that
/// depends only on the selected duration and adds no per-frame chart work.
/// Place it with `geekHistoryAxis(_:)`, directly under the chart.
struct GeekHistoryAxisFooter: View {
    static let height = MiniWindowStyleTokens.historyAxisRowHeight

    /// The window the plot above draws.
    let duration: TimeInterval
    /// Visible vertical range such as "0–100%"; nil for an automatic scale.
    var valueRange: String?
    /// A mirrored throughput chart whose two halves each fit their own peak
    /// (network upload/download, disk read/write; D117).
    var halvesScaleSeparately = false
    /// Bar charts drew unrecorded periods as gap blocks; line charts leave a
    /// break instead and do not need the legend. D130: the histories draw
    /// iStat's empty buckets (no block), so no history shows it by default
    /// (was true).
    var showsGapLegend = false
    /// The history still draws the previous window while the selected one is
    /// prepared (`MenuBarDisplayedHistory.isUpdating`, passed by the
    /// history's owner). The plot block also sets it while the chart shows
    /// the previous window's frame.
    var isUpdating = false

    var body: some View {
        HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
            Text(Self.startLabel(for: duration))
            Spacer(minLength: MiniWindowStyleTokens.rowSpacing)
            if showsGapLegend, !isUpdating {
                HStack(spacing: 3) {
                    GeekChartGapSwatch()
                    Text(L10n.text("未记录", "Unrecorded"))
                }
                .help(Self.gapHelp)
                Text("·")
                    .foregroundStyle(.tertiary)
            }
            Text(Self.centerLabel(valueRange: valueRange, isUpdating: isUpdating,
                                  halvesScaleSeparately: halvesScaleSeparately))
                .help(isUpdating ? Self.updatingHelp
                      : halvesScaleSeparately && valueRange == nil ? Self.halvesHelp : "")
            Spacer(minLength: MiniWindowStyleTokens.rowSpacing)
            Text(L10n.text("现在", "Now"))
        }
        .font(AdvancedPanelTypography.chartLabel)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        // D121: history plots keep the card's 8 pt inset (iStat's 8 + 359 +
        // 8); the end labels sit on the plot's first and last columns.
        .padding(.horizontal, MiniWindowStyleTokens.historyChartInset)
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("图表坐标", "Chart axes"))
        .accessibilityValue(accessibilitySummary)
    }

    static func startLabel(for duration: TimeInterval) -> String {
        "−" + (GeekChartRange(rawValue: Int(duration.rounded()))?.title ?? fallbackTitle(duration))
    }

    /// "0–100%", "0–100°C", "0–4,000 rpm"; nil for byte scales, which grow
    /// with the visible peak.
    static func rangeText(_ range: ClosedRange<Double>, unit: GeekChartUnit) -> String? {
        switch unit {
        case .percent, .percentWithTenths, .temperature:
            return "\(Int(range.lowerBound.rounded()))–\(unit.formatted(range.upperBound, compact: true))"
        case .fanRPM:
            return "\(Int(range.lowerBound.rounded()))–\(unit.formatted(range.upperBound))"
        case .bytes, .bytesPerSecond, .diskBytesPerSecond:
            return nil
        }
    }

    static func scaleLabel(_ valueRange: String?, halvesScaleSeparately: Bool = false) -> String {
        if let valueRange {
            return L10n.text("纵轴 \(valueRange)", "Scale \(valueRange)")
        }
        return halvesScaleSeparately
            ? L10n.text("上下各自缩放", "Each half auto-scaled")
            : L10n.text("纵轴自动", "Auto scale")
    }

    /// The plot still shows the previous window while the newly selected one
    /// is prepared: the window it draws is not the selected one.
    /// Text between the start and "now" labels.
    static func centerLabel(valueRange: String?, isUpdating: Bool, halvesScaleSeparately: Bool = false) -> String {
        isUpdating
            ? L10n.text("更新中…", "Updating…")
            : scaleLabel(valueRange, halvesScaleSeparately: halvesScaleSeparately)
    }

    static var halvesHelp: String {
        L10n.text(
            "上下两半各自按本方向的峰值缩放，柱高做了压缩，流量小时也看得见；两半的柱高不能直接比较，具体数值看悬停提示。",
            "Each half fits its own direction's peak, and bar heights are compressed so light traffic stays visible. The two halves are not to the same scale; hover for the measured values."
        )
    }

    static var updatingHelp: String {
        L10n.text(
            "图表仍是上一个时间范围的数据，正在更新为所选时间范围。",
            "The chart still shows the previous time range and is updating to the selected one."
        )
    }

    static var gapHelp: String {
        L10n.text(
            "浅灰色块：这段时间没有采样记录（应用未运行、电脑休眠或暂停采样），不代表数值为 0。",
            "Light gray blocks: no samples were recorded (app not running, sleep or paused sampling); they do not mean zero."
        )
    }

    private var accessibilitySummary: String {
        Self.accessibilitySummary(duration: duration, valueRange: valueRange, showsGapLegend: showsGapLegend,
                                  isUpdating: isUpdating, halvesScaleSeparately: halvesScaleSeparately)
    }

    /// The row is one accessibility element, so the gap legend's meaning is
    /// part of its value rather than only a hover tooltip.
    static func accessibilitySummary(
        duration: TimeInterval, valueRange: String?, showsGapLegend: Bool, isUpdating: Bool = false,
        halvesScaleSeparately: Bool = false
    ) -> String {
        let scale = scaleLabel(valueRange, halvesScaleSeparately: halvesScaleSeparately)
            + (halvesScaleSeparately && valueRange == nil
                ? L10n.text("，两半的柱高不能直接比较", ", the two halves are not to the same scale")
                : "")
        let axes = L10n.text(
            "横轴从\(startLabel(for: duration))到现在；\(scale)",
            "From \(startLabel(for: duration)) to now; \(scale)"
        )
        let updating = isUpdating
            ? L10n.text("；图表仍是上一个时间范围，正在更新为所选时间范围",
                        "; the chart still shows the previous time range and is updating to the selected one")
            : ""
        guard showsGapLegend else { return axes + updating }
        return axes + L10n.text(
            "；浅灰色块表示未记录，没有采样，不代表数值为 0",
            "; light gray blocks are unrecorded periods with no samples, not zero"
        ) + updating
    }

    private static func fallbackTitle(_ duration: TimeInterval) -> String {
        if duration >= 86_400 {
            let days = Int((duration / 86_400).rounded())
            return L10n.text("\(days) 天", "\(days) Days")
        }
        if duration >= 3_600 {
            let hours = Int((duration / 3_600).rounded())
            return L10n.text("\(hours) 小时", "\(hours) Hours")
        }
        let minutes = max(1, Int((duration / 60).rounded()))
        return L10n.text("\(minutes) 分钟", "\(minutes) Minutes")
    }
}

extension View {
    /// One history plot block: this chart (or its placeholder) framed to
    /// `historyChartHeight`, with the axis row directly below and no gap, so
    /// the block is `historyPlotHeight` tall on every page whatever the page's
    /// own row spacing.
    func geekHistoryAxis(_ footer: GeekHistoryAxisFooter) -> some View {
        GeekHistoryPlotBlock(chart: self, footer: footer)
    }
}

/// The plot block of a history: chart and axis row. `footer.duration` is the
/// window the chart draws. Right after another range was selected that can
/// still be the previous window (`footer.isUpdating`, from the history's
/// slice), or the chart can still show the previous window's prepared frame
/// while the selected one is built (`GeekHistoryPreviousFrameKey`). Either
/// way the block dims the plot and the axis row says "更新中…" instead of the
/// scale, until the selected window is on screen. Nothing is inferred from
/// the environment's selected range.
struct GeekHistoryPlotBlock<Chart: View>: View {
    static var updatingOpacity: Double { 0.45 }

    let chart: Chart
    var footer: GeekHistoryAxisFooter
    @State private var isShowingPreviousFrame = false

    static func showsUpdating(historyIsUpdating: Bool, isShowingPreviousFrame: Bool) -> Bool {
        historyIsUpdating || isShowingPreviousFrame
    }

    var body: some View {
        let isUpdating = Self.showsUpdating(
            historyIsUpdating: footer.isUpdating,
            isShowingPreviousFrame: isShowingPreviousFrame
        )
        VStack(spacing: 0) {
            chart
                .frame(height: MiniWindowStyleTokens.historyChartHeight)
                .onPreferenceChange(GeekHistoryPreviousFrameKey.self) { showsPrevious in
                    isShowingPreviousFrame = showsPrevious
                }
                .opacity(isUpdating ? GeekHistoryPlotBlock.updatingOpacity : 1)
                .menuBarTraceChartIsStale(isUpdating)
            updatedFooter(isUpdating)
        }
        .menuBarPresentationProbe("range.dimmed", revision: UInt64(footer.duration.isFinite ? max(0, footer.duration) : 0), when: isUpdating)
        // The state belongs to this block only.
        .transformPreference(GeekHistoryPreviousFrameKey.self) { $0 = false }
        .transaction { $0.animation = nil }
    }

    private func updatedFooter(_ isUpdating: Bool) -> GeekHistoryAxisFooter {
        var footer = footer
        footer.isUpdating = isUpdating
        return footer
    }
}

/// A prepared chart is showing the previous window's frame
/// (`MenuBarPreparedChartModel.isShowingPreviousValue`); read by the history
/// plot block that contains it.
struct GeekHistoryPreviousFrameKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// D146: the peaks of the bars a mirrored throughput chart draws, of its
/// upward half (upload, read) and its downward half (download, write); nil
/// for a half it draws no bars of. iStat's peak rows show these values
/// (`BBRNetworkMenuBandwidthView`, `BBRDisksMenuActivityView` `drawRect:`).
struct GeekMirroredChartPeaks: Equatable, Sendable {
    var upward: Double?
    var downward: Double?
}

/// D146: the peaks of the chart in a card's graph layer; read by the card's
/// peak row.
struct GeekMirroredChartPeaksKey: PreferenceKey {
    static let defaultValue: GeekMirroredChartPeaks? = nil

    static func reduce(value: inout GeekMirroredChartPeaks?, nextValue: () -> GeekMirroredChartPeaks?) {
        value = value ?? nextValue()
    }
}


/// Legend swatch for an unrecorded period: the same square block and fill
/// the plot draws, plus a hairline so it stays visible at legend size.
struct GeekChartGapSwatch: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(GeekChartDrawing.gapFill)
            .overlay {
                Rectangle().strokeBorder(
                    Color.secondary.opacity(0.45),
                    lineWidth: MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
                )
            }
            .frame(width: 9, height: 7)
            .accessibilityHidden(true)
    }
}

enum GeekBarChartScale {
    /// Smallest scale of one throughput direction (1 KiB/s): idle traffic
    /// of a few bytes stays a sliver instead of filling its half.
    static let throughputFloor: Double = 1_024
    /// Bars of a mirrored throughput chart fill (value / scale)^0.75 of
    /// their half, so a quiet stretch stays visible next to a burst while
    /// the peak still fills it. Tooltips keep the measured values.
    static let mirroredExponent = 0.75

    /// Scale of one throughput direction. Each direction of a chart fits its
    /// own peak (DECISIONS D117, as iStat Menus 7.30 does), so a busy
    /// download no longer flattens the upload half to a hairline.
    /// D120: the scale is the visible peak itself, not a rounded tier, so the
    /// tallest bar of each half reaches its edge as iStat's does. No axis
    /// label shows this value; `PanelChartAxisScale` still eases it down.
    static func throughputUpperBound(for values: [Double]) -> Double {
        // Callers pass the actual displayed averages, not unaggregated polls.
        // Every visible peak must fit; a percentile ceiling clips real activity.
        guard let peak = values.filter({ $0.isFinite && $0 > 0 }).max() else { return throughputFloor }
        return max(throughputFloor, peak)
    }

    /// Share of its half (or plot, for a single direction) one bar fills.
    static func barFraction(value: Double, maximum: Double, exponent: Double) -> Double {
        guard value > 0 else { return 0 }
        guard maximum.isFinite, maximum > 0 else { return 1 }
        let linear = min(1, value / maximum)
        return exponent == 1 ? linear : pow(linear, exponent)
    }
}

struct GeekNetworkHistorySnapshot: Sendable {
    let points: [MenuBarTelemetryPoint]
    let dates: [Date]
    let uploadSamples: [MenuBarChartSample]
    let downloadSamples: [MenuBarChartSample]
    let uploadHasRenderableData: Bool
    let downloadHasRenderableData: Bool
    let uploadStatistics: GeekSeriesStatistics?
    let downloadStatistics: GeekSeriesStatistics?

    var hasRenderableData: Bool {
        uploadHasRenderableData || downloadHasRenderableData
    }

    init(points: [MenuBarTelemetryPoint]) {
        self.points = points
        var dates: [Date] = []
        var uploadSamples: [MenuBarChartSample] = []
        var downloadSamples: [MenuBarChartSample] = []
        dates.reserveCapacity(points.count)
        uploadSamples.reserveCapacity(points.count)
        downloadSamples.reserveCapacity(points.count)

        for point in points {
            let upload = MenuBarTelemetryChannel.upload.mean(in: point)
            let download = MenuBarTelemetryChannel.download.mean(in: point)
            dates.append(point.date)
            uploadSamples.append(MenuBarChartSample(date: point.date, value: upload))
            downloadSamples.append(MenuBarChartSample(date: point.date, value: download))
        }

        self.dates = dates
        self.uploadSamples = uploadSamples
        self.downloadSamples = downloadSamples
        uploadHasRenderableData = PanelChartSampling.hasRenderableTrend(uploadSamples) || GeekCompressedHistoryProjection.hasTrend(points, channel: .upload)
        downloadHasRenderableData = PanelChartSampling.hasRenderableTrend(downloadSamples) || GeekCompressedHistoryProjection.hasTrend(points, channel: .download)
        uploadStatistics = GeekCompressedHistoryProjection.telemetryStatistics(points, channel: .upload)
        downloadStatistics = GeekCompressedHistoryProjection.telemetryStatistics(points, channel: .download)
    }
}

struct GeekPreparedNetworkBucket: Sendable {
    let x: CGFloat
    let end: Date
    let upload: Double?
    let download: Double?
    let uploadIsEstimated: Bool
    let downloadIsEstimated: Bool
}

struct GeekPreparedNetworkFrame: Sendable {
    let range: (start: Date, end: Date, dataStart: Date)
    let buckets: [GeekPreparedNetworkBucket]
    let uploadMarks: [GeekMirroredBarMark]
    let downloadMarks: [GeekMirroredBarMark]
    /// Scale of the upload half and of the download half (D117).
    let uploadMaximum: Double
    let downloadMaximum: Double

    /// D130, D131: `bucketing` as `GeekPreparedLineFrame`'s.
    init(
        history: GeekNetworkHistorySnapshot,
        plotRect: CGRect,
        duration: TimeInterval,
        referenceDate: Date,
        displayScale: CGFloat,
        bucketing: GeekChartBucketing = .projection
    ) {
        var range = GeekChartWindow.barRange(
            for: history.dates,
            duration: duration,
            referenceDate: referenceDate
        )
        let isMissing: (Int) -> Bool = { history.uploadSamples[$0].value == nil && history.downloadSamples[$0].value == nil }
        var snapshots: [GeekChartBucketSnapshot]
        switch bucketing {
        case .samples:
            snapshots = GeekIStatSampleBars.buckets(dates: history.dates, plotRect: plotRect,
                displayScale: displayScale, referenceDate: referenceDate,
                isSample: { history.points[$0].bucketStatistics == nil && !isMissing($0) })
            range = GeekIStatHistoryBuckets.range(of: snapshots.filter { !$0.indices.isEmpty }, fallback: referenceDate)
        case .history:
            snapshots = GeekIStatHistoryBuckets.buckets(dates: history.dates,
                interval: GeekIStatHistoryBuckets.interval(for: duration), plotRect: plotRect,
                referenceDate: referenceDate, displayScale: displayScale,
                gaps: MenuBarSamplingGaps.shared.intervals(at: referenceDate), isMissing: isMissing,
                weight: { index in
                    let metrics = history.points[index].bucketStatistics?.metrics
                    return Double(max(1, metrics?["download"]?.sampleCount ?? metrics?["upload"]?.sampleCount ?? 1))
                })
            range = GeekIStatHistoryBuckets.range(of: snapshots, fallback: referenceDate)
        case .projection:
            snapshots = GeekChartWindow.displayBuckets(
                for: history.dates,
                in: plotRect,
                range: range,
                referenceDate: referenceDate,
                displayScale: displayScale,
                isValid: { history.uploadSamples[$0].value != nil && history.downloadSamples[$0].value != nil },
                isMissing: isMissing,
                holdLatestWhileFresh: true
            )
        }
        let compressed = bucketing == .projection && history.points.contains { $0.bucketStatistics != nil }
        // D130: iStat's bars and tooltip show a bucket's mean, never an estimate.
        let estimates = bucketing == .projection && !compressed
        if compressed {
            let gaps = MenuBarSamplingGaps.shared.intervals(at: referenceDate)
            let points = history.points
            snapshots = GeekCompressedHistoryProjection.buckets(snapshots, dates: history.dates,
                records: points.indices.map { index in
                    let previous = index > 0 ? points[index - 1] : nil
                    return points[index].statistic(for: .download, previous: previous, gaps: gaps)
                        ?? points[index].statistic(for: .upload, previous: previous, gaps: gaps)
                })
        }
        let rawUploads = snapshots.map { bucket in
            bucket.mean { history.uploadSamples[$0].value }
        }
        let rawDownloads = snapshots.map { bucket in
            bucket.mean { history.downloadSamples[$0].value }
        }
        let uploads = !estimates
            ? rawUploads.enumerated().map { TimeBucketValue(value: $0.element, isEstimated: false, sourceIndex: $0.offset) }
            : TimeBucketAggregator.nearestFilled(rawUploads)
        let downloads = !estimates
            ? rawDownloads.enumerated().map { TimeBucketValue(value: $0.element, isEstimated: false, sourceIndex: $0.offset) }
            : TimeBucketAggregator.nearestFilled(rawDownloads)
        let buckets = snapshots.indices.map { index in
            let bucket = snapshots[index]
            return GeekPreparedNetworkBucket(
                x: bucket.x,
                end: bucket.end,
                upload: uploads[index].value,
                download: downloads[index].value,
                uploadIsEstimated: bucket.isEstimated || uploads[index].isEstimated,
                downloadIsEstimated: bucket.isEstimated || downloads[index].isEstimated
            )
        }
        let uploadMarks = buckets.compactMap { bucket in
            bucket.upload.map {
                GeekMirroredBarMark(
                    x: bucket.x,
                    value: $0,
                    isEstimated: bucket.uploadIsEstimated
                )
            }
        }
        let downloadMarks = buckets.compactMap { bucket in
            bucket.download.map {
                GeekMirroredBarMark(
                    x: bucket.x,
                    value: $0,
                    isEstimated: bucket.downloadIsEstimated
                )
            }
        }
        self.range = range
        self.buckets = buckets
        self.uploadMarks = uploadMarks
        self.downloadMarks = downloadMarks
        uploadMaximum = GeekBarChartScale.throughputUpperBound(
            for: history.uploadHasRenderableData ? rawUploads.compactMap { $0 } : []
        )
        downloadMaximum = GeekBarChartScale.throughputUpperBound(
            for: history.downloadHasRenderableData ? rawDownloads.compactMap { $0 } : []
        )
    }
}

struct GeekMirroredBarMark: Sendable {
    let x: CGFloat
    let value: Double
    var isEstimated = false
}

enum GeekChartDrawing {
    /// Fill of an unrecorded period. The axis footer's legend uses the same
    /// pigment, so the quiet block and its "未记录" swatch always match.
    static let gapFill = Color.secondary.opacity(0.045)

    static func bar(in context: GraphicsContext, rect: CGRect, color: Color,
                    estimated: Bool, displayScale: CGFloat) {
        // Estimated coverage shares the normal appearance; provenance stays in the tooltip.
        context.fill(Path(rect), with: .color(color))
    }

    static func gaps(in context: GraphicsContext, plot: CGRect,
                     occupiedX: [CGFloat], displayScale: CGFloat) {
        let metrics = GeekChartWindow.barMetrics(displayScale: displayScale)
        let ordered = occupiedX.sorted()
        var left = plot.minX
        for right in ordered.map({ $0 - metrics.width / 2 }) + [plot.maxX] {
            if right - left > metrics.pitch * 2 {
                let rect = CGRect(x: left, y: plot.minY, width: right - left, height: plot.height)
                context.fill(Path(rect), with: .color(gapFill))
                // Keep the true time gap quiet inside the plot. Tertiary
                // histories name it once in GeekHistoryAxisFooter's legend.
            }
            left = right + metrics.width + metrics.spacing
        }
    }
}

private struct GeekMirroredBarSeries: View {
    @Environment(\.displayScale) private var displayScale

    let marks: [GeekMirroredBarMark]
    let plotRect: CGRect
    let maximum: Double
    let color: Color
    let upward: Bool
    var singleDirection = false
    /// Space kept between a mirrored half's longest bar and the plot edge.
    /// D118: 0 on the overview card, where iStat's halves reach the edges.
    var halfInset: CGFloat = 3
    /// D130, D131: `GeekChartBucketing.fillsGaps`, `.zeroIsBar`.
    var fillsGaps = true
    var zeroIsBar = false

    var body: some View {
        let metrics = GeekChartWindow.barMetrics(displayScale: displayScale)
        // D121: one direction (the disk read or write history) stands on the
        // plot's bottom edge and spans its height, as the other history bars
        // do; the mirrored halves meet at the center hairline.
        let halfHeight = max(1, singleDirection ? plotRect.height : plotRect.height / 2 - halfInset)
        // A single-direction chart stays linear; only the mirrored halves are
        // compressed (D117).
        let exponent = singleDirection ? 1 : GeekBarChartScale.mirroredExponent

        Canvas { context, _ in
            context.clip(to: Path(plotRect))
            let hairline = MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
            let baselineY = singleDirection
                ? (upward ? plotRect.maxY : plotRect.minY)
                : MiniWindowPixel.strokeCenter(plotRect.midY, lineWidth: hairline, displayScale: displayScale)

            if upward, fillsGaps {
                GeekChartDrawing.gaps(in: context, plot: plotRect,
                    occupiedX: marks.map(\.x), displayScale: displayScale)
            }
            for mark in marks {
                let amplitude = halfHeight * CGFloat(GeekBarChartScale.barFraction(
                    value: mark.value, maximum: maximum, exponent: exponent
                ))
                let endY = MiniWindowPixel.aligned(
                    upward ? baselineY - amplitude : baselineY + amplitude,
                    displayScale: displayScale
                )
                let height = max(
                    GeekChartWindow.minimumBarHeight(hasValue: mark.value > 0 || zeroIsBar, displayScale: displayScale),
                    MiniWindowPixel.snappedLength(
                        abs(endY - baselineY),
                        displayScale: displayScale
                    )
                )
                let rawY = upward ? baselineY - height : baselineY
                let rect = CGRect(
                    x: MiniWindowPixel.aligned(
                        mark.x - metrics.width / 2,
                        displayScale: displayScale
                    ),
                    y: MiniWindowPixel.aligned(rawY, displayScale: displayScale),
                    width: metrics.width,
                    height: height
                )
                GeekChartDrawing.bar(in: context, rect: rect, color: color,
                    estimated: mark.isEstimated, displayScale: displayScale)
            }
        }
    }
}

/// CPU columns share one preparation result with hit testing. The configured
/// interval bounds measured coverage; plot width alone determines column geometry.
struct GeekCPUHistoryFrame: Sendable {
    struct Mark: Sendable {
        let bucket: GeekChartBucketSnapshot
        let rect: CGRect
        let latest: MenuBarTelemetryPoint
        let mean: MenuBarTelemetryPoint
        let peak: MenuBarTelemetryPoint
        let peakTotal: Double
        var isEstimated = false
    }

    let marks: [Mark]
    let bucketDuration: TimeInterval

    static func prepare(
        points: [MenuBarTelemetryPoint],
        plotRect: CGRect,
        duration: TimeInterval,
        referenceDate: Date,
        samplingInterval: TimeInterval,
        displayScale: CGFloat,
        preparedAveragedBuckets: [GeekChartBucketSnapshot]? = nil,
        unrecordedIntervals: [DateInterval]? = nil
    ) -> Self {
        guard duration.isFinite, duration > 0, duration <= MenuBarHistoryRetention.duration,
              plotRect.width.isFinite, plotRect.width > 0,
              plotRect.minX.isFinite else {
            return Self(marks: [], bucketDuration: 1)
        }
        let hasCompressedHistory = points.contains { $0.bucketStatistics != nil }
        if GeekHistoryAveraging.interval(for: duration) != nil || hasCompressedHistory {
            var buckets: [GeekChartBucketSnapshot]
            if let preparedAveragedBuckets {
                buckets = preparedAveragedBuckets
            } else {
                let dates = points.map(\.date)
                let range = GeekChartWindow.barRange(for: dates, duration: duration,
                    referenceDate: referenceDate)
                buckets = GeekChartWindow.displayBuckets(for: dates, in: plotRect,
                    range: range, referenceDate: referenceDate, displayScale: displayScale,
                    isMissing: { !isComplete(points[$0]) }, unrecordedIntervals: unrecordedIntervals)
            }
            if hasCompressedHistory {
                let gaps = unrecordedIntervals ?? MenuBarSamplingGaps.shared.intervals(at: referenceDate)
                buckets = GeekCompressedHistoryProjection.buckets(buckets, dates: points.map(\.date),
                    records: points.indices.map { index in isComplete(points[index])
                        ? points[index].statistic(for: .cpuTotal, previous: index > 0 ? points[index - 1] : nil, gaps: gaps) : nil })
            }
            let width = GeekChartWindow.barMetrics(displayScale: displayScale).width
            let marks = buckets.compactMap { bucket -> Mark? in
                guard let latestIndex = bucket.indices.last,
                      let peakIndex = bucket.indices.max(by: {
                          if hasCompressedHistory {
                              return MenuBarTelemetryChannel.cpuTotal.peak(in: points[$0])!
                                  < MenuBarTelemetryChannel.cpuTotal.peak(in: points[$1])!
                          }
                          return points[$0].cpuTotal! < points[$1].cpuTotal!
                      })
                else { return nil }
                let mean = MenuBarTelemetryPoint(date: bucket.end,
                    cpuTotal: bucket.mean { hasCompressedHistory
                        ? MenuBarTelemetryChannel.cpuTotal.mean(in: points[$0]) : points[$0].cpuTotal },
                    cpuUser: bucket.mean { hasCompressedHistory
                        ? MenuBarTelemetryChannel.cpuUser.mean(in: points[$0]) : points[$0].cpuUser },
                    cpuSystem: bucket.mean { hasCompressedHistory
                        ? MenuBarTelemetryChannel.cpuSystem.mean(in: points[$0]) : points[$0].cpuSystem },
                    gpu: nil, memory: nil, chipTemperature: nil, fanRPM: nil,
                    downBytesPerSecond: nil, upBytesPerSecond: nil)
                return Mark(bucket: bucket,
                    rect: CGRect(x: MiniWindowPixel.aligned(bucket.x - width / 2, displayScale: displayScale),
                                 y: plotRect.minY, width: width, height: plotRect.height),
                    latest: points[latestIndex], mean: mean,
                    peak: hasCompressedHistory ? points[peakIndex].cpuPeakSample : points[peakIndex],
                    peakTotal: hasCompressedHistory
                        ? MenuBarTelemetryChannel.cpuTotal.peak(in: points[peakIndex])! : points[peakIndex].cpuTotal!,
                    isEstimated: false)
            }
            return Self(marks: marks, bucketDuration: buckets.first.map { $0.end.timeIntervalSince($0.start) } ?? 1)
        }
        let interval = [1.0, 2.0, 5.0].contains(samplingInterval) ? samplingInterval : 1
        let start = referenceDate.addingTimeInterval(-duration)
        let metrics = GeekChartWindow.barMetrics(displayScale: displayScale)
        let slotCount = GeekChartWindow.barSlotCount(in: plotRect, displayScale: displayScale)
        let bucketDuration = duration / Double(slotCount)
        let range = (start: start, end: referenceDate, dataStart: start)
        let buckets = GeekChartWindow.barBucketSnapshots(
            for: points.map(\.date), in: plotRect, range: range,
            referenceDate: referenceDate, displayScale: displayScale
        )
        // A CPU delta belongs to the interval ending at its timestamp. Split that
        // measured interval across fixed display slots, never invent extra polls.
        // A pause, failed sample or long gap does not establish interval coverage.
        var ordered = points.indices.filter {
            points[$0].date >= start.addingTimeInterval(-interval * 1.75)
                && points[$0].date <= referenceDate
        }
        if zip(ordered, ordered.dropFirst()).contains(where: { points[$0.0].date > points[$0.1].date }) {
            ordered.sort { points[$0].date == points[$1].date ? $0 < $1 : points[$0].date < points[$1].date }
        }
        var contributions = Array(repeating: [(index: Int, weight: Double)](), count: slotCount)
        let gaps = unrecordedIntervals ?? MenuBarSamplingGaps.shared.intervals(at: referenceDate)
        var previous: Int?
        for index in ordered {
            defer { previous = index }
            guard isComplete(points[index]) else { continue }
            let end = points[index].date
            let delta = previous.map { end.timeIntervalSince(points[$0].date) }
            let continuous = previous.map { isComplete(points[$0]) } == true
                && delta.map { $0 > 0 && $0 <= interval * 1.75 } == true
                && previous.map { !MenuBarSamplingGaps.crosses(gaps, from: points[$0].date, to: end) } == true
            if continuous, let delta {
                let lower = max(start, end.addingTimeInterval(-delta))
                guard end > lower else { continue }
                let first = max(0, min(slotCount - 1, Int(floor(lower.timeIntervalSince(start) / bucketDuration))))
                let last = max(0, min(slotCount - 1, Int(ceil(end.timeIntervalSince(start) / bucketDuration)) - 1))
                if first <= last {
                    for slot in first...last {
                        let left = start.addingTimeInterval(Double(slot) * bucketDuration)
                        let right = left.addingTimeInterval(bucketDuration)
                        let overlap = min(end, right).timeIntervalSince(max(lower, left))
                        if overlap > 0 { contributions[slot].append((index, overlap)) }
                    }
                }
            } else if end >= start {
                // An isolated real observation remains a single mark. It cannot
                // extend into neighbouring slots or cover the preceding outage.
                let slot = min(slotCount - 1, max(0, Int(floor(end.timeIntervalSince(start) / bucketDuration))))
                contributions[slot].append((index, min(interval, bucketDuration)))
            }
        }
        let reconstructed = GeekChartWindow.displayBuckets(
            for: points.map(\.date), in: plotRect, range: range,
            referenceDate: referenceDate, displayScale: displayScale,
            isValid: { isComplete(points[$0]) },
            isMissing: { points[$0].cpuTotal == nil && points[$0].cpuUser == nil && points[$0].cpuSystem == nil },
            unrecordedIntervals: unrecordedIntervals,
            holdLatestWhileFresh: true
        )
        var marks: [Mark] = []
        for slot in buckets.indices {
            let isEstimated = contributions[slot].isEmpty && reconstructed.indices.contains(slot)
                && reconstructed[slot].indices.contains { isComplete(points[$0]) }
            let values = isEstimated
                ? reconstructed[slot].indices.filter { isComplete(points[$0]) }.map { (index: $0, weight: bucketDuration) }
                : contributions[slot]
            guard let latestIndex = values.last?.index,
                  let peakIndex = values.max(by: { points[$0.index].cpuTotal! < points[$1.index].cpuTotal! })?.index else { continue }
            let weight = values.reduce(0) { $0 + $1.weight }
            func mean(_ key: KeyPath<MenuBarTelemetryPoint, Double?>) -> Double {
                values.reduce(0) { $0 + points[$1.index][keyPath: key]! * $1.weight } / weight
            }
            let bucket = buckets[slot]
            let rect = CGRect(
                x: MiniWindowPixel.aligned(bucket.x - metrics.width / 2, displayScale: displayScale),
                y: plotRect.minY, width: metrics.width, height: plotRect.height
            )
            marks.append(Mark(
                bucket: GeekChartBucketSnapshot(indices: values.map(\.index), x: bucket.x, start: bucket.start, end: bucket.end),
                rect: rect, latest: points[latestIndex],
                mean: MenuBarTelemetryPoint(
                    date: points[latestIndex].date,
                    cpuTotal: mean(\.cpuTotal), cpuUser: mean(\.cpuUser), cpuSystem: mean(\.cpuSystem),
                    gpu: nil, memory: nil, chipTemperature: nil, fanRPM: nil,
                    downBytesPerSecond: nil, upBytesPerSecond: nil
                ),
                peak: points[peakIndex], peakTotal: points[peakIndex].cpuTotal!, isEstimated: isEstimated
            ))
        }
        return Self(marks: marks, bucketDuration: bucketDuration)
    }

    func mark(at x: CGFloat) -> Mark? {
        marks.first { x >= $0.rect.minX && x <= $0.rect.maxX }
    }

    static func isComplete(_ point: MenuBarTelemetryPoint) -> Bool {
        // Raw histories retain the direct-field path used by the preparation
        // budget. Only compressed points need a lookup of bucket statistics.
        let compressed = point.bucketStatistics != nil
        guard let total = compressed ? MenuBarTelemetryChannel.cpuTotal.mean(in: point) : point.cpuTotal,
              let user = compressed ? MenuBarTelemetryChannel.cpuUser.mean(in: point) : point.cpuUser,
              let system = compressed ? MenuBarTelemetryChannel.cpuSystem.mean(in: point) : point.cpuSystem else { return false }
        return total.isFinite && user.isFinite && system.isFinite
            && (0...100).contains(total) && (0...100).contains(user) && (0...100).contains(system)
    }
}

private struct GeekStackedBarSeries: View {
    @Environment(\.displayScale) private var displayScale

    let points: [MenuBarTelemetryPoint]
    let series: [MenuBarTelemetrySeries]
    let colors: [Color]
    let plotRect: CGRect
    let valueRange: ClosedRange<Double>
    let duration: TimeInterval
    let referenceDate: Date
    var cpuFrame: GeekCPUHistoryFrame?
    var prepared: GeekPreparedLineFrame?
    /// A single-series chart may color each bucket's bar on its own (the
    /// memory-pressure history: every sample's level). Nil keeps the series
    /// color for that bucket.
    var bucketColor: ((Int) -> Color?)? = nil
    /// D130, D131: `GeekChartBucketing.fillsGaps`, `.zeroIsBar`.
    var fillsGaps = true
    var zeroIsBar = false
    /// D133: `GeekPrecisionLineChart.drawsZero`.
    var drawsZero = true

    var body: some View {
        let buckets = prepared?.buckets ?? []
        let bucketValues = prepared?.values ?? []
        let metrics = GeekChartWindow.barMetrics(displayScale: displayScale)

        Canvas { context, _ in
            context.clip(to: Path(plotRect))

            let observations: [(values: [Double?], x: CGFloat, width: CGFloat, estimated: Bool, color: Color?)]
            if let cpuFrame {
                observations = cpuFrame.marks.map { mark in
                    (series.map { $0.channel.value(in: mark.mean) }, mark.rect.minX, mark.rect.width, mark.isEstimated, nil)
                }
            } else {
                observations = zip(buckets, bucketValues).enumerated().compactMap { index, pair in
                    let (bucket, values) = pair
                    guard values.contains(where: { $0 != nil }) else { return nil }
                    return (values, bucket.x - metrics.width / 2, metrics.width, bucket.isEstimated,
                            values.count == 1 ? bucketColor?(index) : nil)
                }
            }
            if fillsGaps {
                GeekChartDrawing.gaps(in: context, plot: plotRect,
                    occupiedX: observations.map { $0.x + $0.width / 2 }, displayScale: displayScale)
            }
            for observation in observations {
                let values = observation.values
                let total = values.compactMap { $0 }.reduce(0) { partial, value in
                    partial + max(0, value)
                }
                let firstValidIndex = values.indices.first { values[$0] != nil }
                var base = 0.0

                for index in values.indices {
                    guard let rawValue = values[index] else { continue }
                    let value = max(0, rawValue)
                    let lower = base
                    base += value
                    guard value > 0 || (drawsZero && total == 0 && index == firstValidIndex) else { continue }

                    let rect = GeekChartWindow.stackedBarRect(
                        x: observation.x, width: observation.width,
                        lower: lower, upper: base,
                        in: plotRect, range: valueRange,
                        displayScale: displayScale, zeroIsBar: zeroIsBar
                    )
                    GeekChartDrawing.bar(in: context, rect: rect, color: observation.color ?? colors[index],
                        estimated: observation.estimated, displayScale: displayScale)
                }
            }
        }
    }
}

struct GeekSeriesStatistics: Sendable, Equatable {
    let current: Double
    let minimum: Double
    let average: Double
    let maximum: Double

    init?(values: [Double]) {
        let usableValues = values.filter(\.isFinite)
        guard let current = usableValues.last,
              let minimum = usableValues.min(),
              let maximum = usableValues.max() else {
            return nil
        }
        self.current = current
        self.minimum = minimum
        average = usableValues.reduce(0, +) / Double(usableValues.count)
        self.maximum = maximum
    }
}

struct GeekPrecisionLineChart: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.panelChartAccentColor) private var panelChartAccentColor
    @Environment(\.displayScale) private var displayScale

    let points: [MenuBarTelemetryPoint]
    let series: [MenuBarTelemetrySeries]
    let valueRange: ClosedRange<Double>
    let unit: GeekChartUnit
    let accessibilityLabel: String
    var style: GeekPrecisionChartStyle = .line
    var duration: TimeInterval = GeekChartWindow.defaultDuration
    var showsLegend = true
    var showsTimelineLabels = true
    var showsTooltip = false
    var horizontalInset: CGFloat = 6
    /// Compact CPU cards use their full plot height directly under the header;
    /// other charts retain the existing breathing room above the plot.
    var verticalInset: CGFloat = 4
    var domainPolicy: ChartDomainPolicy?
    var showsValueLabels = false
    var lineWidth: CGFloat = 1.35
    var fillOpacity: Double = 0
    var cpuSamplingInterval: TimeInterval = 1
    var showsSamplingDetails = true
    /// Memory-pressure bars take the color of each sample's own level
    /// instead of one series color.
    var pressureLevelColor: ((MemoryPressureLevel?) -> Color)? = nil
    /// D130, D131: iStat's history buckets (level three) or one bar per
    /// sample (levels one and two); the main window keeps the projection.
    var bucketing: GeekChartBucketing = .projection
    /// D133: iStat's pressure and swap histories draw no bar for a zero
    /// bucket (`fcmp #0.0` before `moveToPoint:`); its other graphs draw a
    /// 1 pt one.
    var drawsZero = true

    @State private var hoverLocation: CGPoint?

    /// The prepared frame's identity. The series ids are part of it: a
    /// caller that rewrites the points before drawing them (a fan history
    /// draws one fan's speed in the fan channel) names the data with its
    /// series, so frames of different data never share a cache entry.
    static func preparationConfiguration(
        series: [MenuBarTelemetrySeries], plotRect: CGRect, duration: TimeInterval, displayScale: CGFloat,
        style: GeekPrecisionChartStyle, valueRange: ClosedRange<Double>, samplingInterval: TimeInterval,
        bucketing: GeekChartBucketing = .projection
    ) -> String {
        "\(preparationShape(series: series, plotRect: plotRect, displayScale: displayScale, style: style, bucketing: bucketing)):\(duration):\(valueRange):\(samplingInterval)"
    }

    /// The part of the identity that is not the time window: a frame of
    /// another window of the same data may stand in while the new one is
    /// prepared; a frame of other data may not.
    static func preparationShape(
        series: [MenuBarTelemetrySeries], plotRect: CGRect, displayScale: CGFloat, style: GeekPrecisionChartStyle,
        bucketing: GeekChartBucketing = .projection
    ) -> String {
        "\(series.map { "\($0.id)=\($0.channel.rawValue)" }):\(plotRect):\(displayScale):\(style)\(bucketing.preparationTag)"
    }

    var body: some View {
        let channels = series.map(\.channel)
        return MenuBarChartPreparation(kind: "line-summary", first: points.first?.date, last: points.last?.date,
            count: points.count, configuration: channels.map(\.rawValue).joined(separator: ","),
            cost: max(256, points.count * 64), build: { [points] in
                GeekPreparedLineSummary(points: points, channels: channels)
            }) { summary in chartBody(summary: summary) }
    }

    private func chartBody(summary: GeekPreparedLineSummary) -> some View {
        let visibleSeries = series.filter { summary.channels.contains($0.channel) }
        let visibleAccessibilitySummary = accessibilitySummary(for: visibleSeries, statistics: summary.statistics)

        return VStack(alignment: .leading, spacing: 2) {
            if showsLegend {
                LazyVGrid(columns: legendColumns, alignment: .leading, spacing: 2) {
                    ForEach(series) { item in
                        GeekChartLegend(
                            title: item.title,
                            color: resolvedColor(for: item, renderableSeries: visibleSeries)
                        )
                    }
                }
            }

            Group {
                if visibleSeries.isEmpty {
                    PanelChartSamplingPlaceholder()
                } else {
                    GeekLiveChartTimeline(duration: duration) { referenceDate in
                        GeometryReader { proxy in
                            let plotRect = CGRect(
                                x: horizontalInset + (showsValueLabels ? 56 : 0),
                                y: verticalInset,
                                width: max(1, proxy.size.width - horizontalInset * 2 - (showsValueLabels ? 56 : 0)),
                                height: max(1, proxy.size.height - (showsTimelineLabels ? 20 : verticalInset))
                            )
                            let visibleValueRange = resolvedValueRange
                            let channels = visibleSeries.map(\.channel)
                            MenuBarChartPreparation(kind: "line-frame", first: points.first?.date, last: points.last?.date,
                                count: points.count,
                                configuration: Self.preparationConfiguration(
                                    series: visibleSeries, plotRect: plotRect, duration: duration,
                                    displayScale: displayScale, style: style, valueRange: visibleValueRange,
                                    samplingInterval: cpuSamplingInterval, bucketing: bucketing
                                ),
                                shape: Self.preparationShape(
                                    series: visibleSeries, plotRect: plotRect, displayScale: displayScale, style: style,
                                    bucketing: bucketing
                                ),
                                window: bucketing.window(duration),
                                clockRevision: bucketing.clockRevision(for: referenceDate, duration: duration),
                                cost: max(512, points.count * 512),
                                build: { [points, duration, cpuSamplingInterval, displayScale, style, bucketing] in
                                    GeekPreparedLineFrame(points: points, channels: channels, plot: plotRect,
                                        duration: duration, reference: referenceDate, samplingInterval: cpuSamplingInterval,
                                        scale: displayScale, stacked: style == .stackedBars, valueRange: visibleValueRange,
                                        bucketing: bucketing)
                                }) { prepared in
                            let cpuFrame = prepared.cpu

                            ZStack(alignment: .topLeading) {
                                Color.clear

                                if showsValueLabels {
                                    valueLabels(in: plotRect, range: visibleValueRange)
                                }

                                if style == .stackedBars {
                                    GeekStackedBarSeries(
                                        points: points,
                                        series: visibleSeries,
                                        colors: visibleSeries.map {
                                            resolvedColor(
                                                for: $0,
                                                renderableSeries: visibleSeries
                                            )
                                        },
                                        plotRect: plotRect,
                                        valueRange: visibleValueRange,
                                        duration: duration,
                                        referenceDate: referenceDate,
                                        cpuFrame: cpuFrame,
                                        prepared: prepared,
                                        bucketColor: pressureLevelColor.map { color in
                                            { prepared.pressureLevels.indices.contains($0) ? color(prepared.pressureLevels[$0]) : nil }
                                        },
                                        fillsGaps: bucketing.fillsGaps,
                                        zeroIsBar: bucketing.zeroIsBar,
                                        drawsZero: drawsZero
                                    )
                                } else {
                                    ForEach(visibleSeries, id: \.id) { item in
                                        let color = resolvedColor(for: item, renderableSeries: visibleSeries)
                                        let segments = prepared.segments[item.channel] ?? []
                                        let path = directPath(segments)

                                        if fillOpacity > 0 {
                                            filledPath(segments, baseline: plotRect.maxY)
                                            .fill(color.opacity(reduceTransparency ? 0 : fillOpacity))
                                        }

                                        if item.dash.isEmpty,
                                           !reduceTransparency,
                                           colorSchemeContrast != .increased {
                                            path
                                                .stroke(
                                                    color.opacity(0.18),
                                                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                                                )
                                        }

                                        path
                                            .stroke(
                                                color,
                                                style: StrokeStyle(
                                                    lineWidth: colorSchemeContrast == .increased ? max(1.85, lineWidth) : lineWidth,
                                                    lineCap: .round,
                                                    lineJoin: .round,
                                                    dash: item.dash
                                                )
                                            )
                                        isolatedPointPath(segments)
                                            .fill(color)
                                    }
                                }

                                if showsTimelineLabels {
                                    GeekBarTimelineLabels(timeRange: prepared.range, plotRect: plotRect)
                                }
                                if showsTooltip {
                                    hoverOverlay(
                                        in: plotRect,
                                        renderableSeries: visibleSeries,
                                        referenceDate: referenceDate,
                                        cpuFrame: cpuFrame,
                                        preparedBuckets: prepared.buckets,
                                        preparedPoints: prepared.sourcePoints,
                                        preparedValues: prepared.hoverValues,
                                        preparedEstimated: prepared.hoverEstimated,
                                        preparedPressureLevels: prepared.pressureLevels
                                    )
                                }
                            }
                            .menuBarPresentationProbe("hover", revision: MenuBarPresentationProbe.revision(hoverLocation), when: showsTooltip)
                            .menuBarScriptHover("hover.line", enabled: showsTooltip) { hoverLocation = $0 }
                            .onContinuousHover { phase in
                                guard showsTooltip else { return }
                                switch phase {
                                case let .active(location):
                                    MenuBarPresentationTrace.beginInput("hover", label: "hover.line")
                                    hoverLocation = location
                                case .ended:
                                    hoverLocation = nil
                                }
                            }
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(visibleAccessibilitySummary)
        .accessibilityHint(samplingWindowDescription)
        .help(usesCPUHistoryBuckets || !showsSamplingDetails ? "" : samplingWindowDescription)
    }

    var samplingWindowDescription: String {
        let title = GeekChartRange(rawValue: Int(duration))?.title
            ?? String(GeekChartWindow.elapsedLabel(duration).dropFirst())
        return L10n.text("时间窗：最近 \(title)。", "Window: last \(title).")
            + " " + (style == .stackedBars ? TimeBucketAggregator.nearestFillDescription
                : L10n.text("实测曲线；采样前、休眠和长缺口不连线。",
                            "Observed trend; no line before sampling, across sleep, or across long gaps."))
    }

    private var usesCPUHistoryBuckets: Bool {
        style == .stackedBars && !series.isEmpty && series.allSatisfy {
            [.cpuTotal, .cpuUser, .cpuSystem].contains($0.channel)
        }
    }

    private var legendColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 8, alignment: .leading),
            count: max(1, min(3, series.count))
        )
    }

    private var renderableSeries: [MenuBarTelemetrySeries] {
        series.filter { item in
            PanelChartSampling.hasRenderableTrend(
                points.map {
                    MenuBarChartSample(date: $0.date, value: item.channel.value(in: $0))
                }
            )
        }
    }

    private var resolvedValueRange: ClosedRange<Double> {
        let policy = domainPolicy ?? inferredDomainPolicy
        return policy.resolvedRange(fallback: valueRange)
    }

    private var inferredDomainPolicy: ChartDomainPolicy {
        switch unit {
        case .percent, .percentWithTenths:
            return .fixed(min: 0, max: 100)
        case .bytes, .bytesPerSecond, .diskBytesPerSecond:
            return .positiveDynamic
        case .temperature, .fanRPM:
            return .fixed(min: valueRange.lowerBound, max: valueRange.upperBound)
        }
    }

    private func resolvedColor(
        for item: MenuBarTelemetrySeries,
        renderableSeries: [MenuBarTelemetrySeries]
    ) -> Color {
        // Values, rings and external legends share these metric colors.
        // Recoloring only the plot would give the same metric two meanings.
        if [.cpuUser, .cpuSystem, .compressedMemoryBytes, .swapUsedBytes, .swapUsedPercent].contains(item.channel) {
            return item.color
        }
        if style == .stackedBars, let panelChartAccentColor {
            if colorSchemeContrast == .increased,
               item.id != renderableSeries.first?.id {
                return AppDesignTokens.Palette.primaryText
            }
            return item.id == renderableSeries.first?.id
                ? panelChartAccentColor
                : panelChartAccentColor.opacity(0.56)
        }
        return item.color
    }

    private func statistics(for channel: MenuBarTelemetryChannel) -> GeekSeriesStatistics? {
        GeekSeriesStatistics(values: points.compactMap { channel.value(in: $0) })
    }

    private func valueLabels(in plotRect: CGRect, range: ClosedRange<Double>) -> some View {
        ForEach(0..<3) { index in
            let fraction = Double(index) / 2
            let value = range.upperBound - (range.upperBound - range.lowerBound) * fraction
            let y = plotRect.minY + plotRect.height * fraction
            Path { path in
                path.move(to: CGPoint(x: plotRect.minX, y: y))
                path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
            }
            .stroke(.secondary.opacity(0.16), style: StrokeStyle(lineWidth: 0.5))
            Text(unit.formatted(value, compact: true))
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 54, alignment: .trailing)
                .position(x: plotRect.minX - 29, y: min(plotRect.maxY - 5, max(plotRect.minY + 5, y)))
        }
    }

    func pointSegments(
        for channel: MenuBarTelemetryChannel,
        in plotRect: CGRect,
        valueRange: ClosedRange<Double>,
        referenceDate: Date
    ) -> [[CGPoint]] {
        let buckets = chartBuckets(
            in: plotRect,
            referenceDate: referenceDate
        )
        let values = TimeBucketAggregator.nearestFilled(
            buckets.map { bucket in
                bucket.displayValue { channel.value(in: points[$0]) }
            }
        )
        let valueSpan = max(
            Double.ulpOfOne,
            valueRange.upperBound - valueRange.lowerBound
        )
        let usableHeight = max(1, plotRect.height - 4)
        return TimeBucketAggregator.observedSegments(
            values.map(\.value),
            in: buckets,
            sampleDates: points.map(\.date),
            isSampleValid: { channel.value(in: points[$0])?.isFinite == true }
        ).map { segment in
            segment.map { sample in
                let value = min(
                    valueRange.upperBound,
                    max(valueRange.lowerBound, sample.value)
                )
                let normalized = (value - valueRange.lowerBound) / valueSpan
                let y = plotRect.minY + 2 + usableHeight * CGFloat(1 - normalized)
                return CGPoint(x: buckets[sample.index].x, y: y)
            }
        }
    }

    func directPath(_ segments: [[CGPoint]]) -> Path {
        return Path { path in
            for segment in segments {
                guard segment.count >= PanelChartSampling.minimumRenderableSampleCount,
                      let first = segment.first else { continue }
                path.move(to: first)
                for point in segment.dropFirst() {
                    path.addLine(to: point)
                }
            }
        }
    }

    func filledPath(_ segments: [[CGPoint]], baseline: CGFloat) -> Path {
        Path { path in
            for segment in segments where segment.count > 1 {
                guard let first = segment.first, let last = segment.last else { continue }
                path.move(to: CGPoint(x: first.x, y: baseline))
                for point in segment {
                    path.addLine(to: point)
                }
                path.addLine(to: CGPoint(x: last.x, y: baseline))
                path.closeSubpath()
            }
        }
    }

    func isolatedPointPath(_ segments: [[CGPoint]]) -> Path {
        Path { path in
            for segment in segments where segment.count == 1 {
                guard let point = segment.first else { continue }
                path.addEllipse(in: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3))
            }
        }
    }

    @ViewBuilder
    private func hoverOverlay(
        in plotRect: CGRect,
        renderableSeries: [MenuBarTelemetrySeries],
        referenceDate: Date,
        cpuFrame: GeekCPUHistoryFrame?,
        preparedBuckets: [GeekChartBucketSnapshot],
        preparedPoints: [MenuBarTelemetryPoint],
        preparedValues: [[Double?]],
        preparedEstimated: [[Bool]],
        preparedPressureLevels: [MemoryPressureLevel?] = []
    ) -> some View {
        if let cpuFrame {
            cpuHoverOverlay(in: plotRect, series: renderableSeries, frame: cpuFrame)
        } else if hoverLocation != nil {
            let buckets = preparedBuckets
            if let hoveredPoint = hoveredPoint(
                in: plotRect,
                buckets: buckets
            ) {
                GeekHistoryHoverIndicator(
                    barCenterX: hoveredPoint.bucket.x,
                    plotRect: plotRect,
                    tooltip: GeekHoverTooltip(
                        date: hoveredPoint.bucket.end,
                        values: renderableSeries.enumerated().compactMap { column, item in
                            guard preparedValues.indices.contains(hoveredPoint.index),
                                  preparedValues[hoveredPoint.index].indices.contains(column),
                                  let value = preparedValues[hoveredPoint.index][column] else { return nil }
                            // The tooltip dot matches the hovered bar's own level color.
                            let levelColor = preparedPressureLevels.indices.contains(hoveredPoint.index)
                                ? pressureLevelColor?(preparedPressureLevels[hoveredPoint.index]) : nil
                            return GeekHoverValue(title: item.title, value: unit.formatted(value), color: levelColor ?? item.color,
                                                  isEstimated: preparedEstimated[hoveredPoint.index][column])
                        },
                        visibleDuration: duration,
                        // D130: iStat's tooltip is the time and the values.
                        detail: showsSamplingDetails && bucketing == .projection
                            ? bucketDescription(hoveredPoint.bucket, series: renderableSeries, points: preparedPoints) : nil
                    )
                )
            }
        }
    }

    @ViewBuilder
    private func cpuHoverOverlay(
        in plotRect: CGRect,
        series: [MenuBarTelemetrySeries],
        frame: GeekCPUHistoryFrame
    ) -> some View {
        if let hoverLocation, plotRect.contains(hoverLocation),
           let mark = frame.mark(at: hoverLocation.x) {
            let values = series.compactMap { item -> GeekHoverValue? in
                guard let value = item.channel.value(in: mark.mean) else { return nil }
                return GeekHoverValue(
                    title: item.title, value: unit.formatted(value), color: item.color, isEstimated: mark.isEstimated, showsTitle: false
                )
            } + [GeekHoverValue(
                title: L10n.text("该段总 CPU 峰值", "Segment total CPU peak"),
                value: mark.isEstimated ? "—" : unit.formatted(mark.peakTotal),
                color: .primary, isEstimated: false
            )]
            GeekHistoryHoverIndicator(
                barCenterX: mark.rect.midX,
                plotRect: plotRect,
                tooltip: GeekHoverTooltip(
                    date: mark.latest.date,
                    values: values,
                    visibleDuration: duration
                )
            )
        }
    }

    private func bucketDescription(
        _ bucket: GeekChartBucketSnapshot,
        series: [MenuBarTelemetrySeries], points: [MenuBarTelemetryPoint]
    ) -> String {
        let start = PanelChartDateFormatting.string(for: bucket.start, visibleDuration: duration)
        let end = PanelChartDateFormatting.string(for: bucket.end, visibleDuration: duration)
        let observations: String
        if let interval = bucket.averagingInterval {
            return L10n.text("\(start)–\(end) · 每 \(Int(interval)) 秒平均", "\(start)–\(end) · \(Int(interval)) s averages")
        }
        if style == .stackedBars {
            let sample = TimeBucketAggregator.lastSample(in: bucket.indices, from: points) { point in
                series.allSatisfy { $0.channel.value(in: point)?.isFinite == true }
            }
            observations = L10n.text("实测 ", "Observed ") + observationDate(sample)
                + L10n.text(" · 桶内末点；短区间阶梯保持，非新增采样", " · Last observation; short slots hold readings, not extra samples")
        } else {
            observations = series.map { item in
                let sample = TimeBucketAggregator.lastSample(in: bucket.indices, from: points) {
                    item.channel.value(in: $0)?.isFinite == true
                }
                return "\(item.title) \(observationDate(sample))"
            }.joined(separator: "\n")
        }
        return L10n.text("时间桶 \(start)–\(end)", "Bucket \(start)–\(end)") + "\n" + observations
    }

    private func observationDate(_ sample: MenuBarTelemetryPoint?) -> String {
        sample.map {
            PanelChartDateFormatting.string(for: $0.date, visibleDuration: duration)
        } ?? L10n.text("缺测", "Missing")
    }

    private func hoveredPoint(
        in plotRect: CGRect,
        buckets: [GeekChartBucketSnapshot]
    ) -> (index: Int, bucket: GeekChartBucketSnapshot)? {
        guard let hoverLocation,
              plotRect.insetBy(dx: -4, dy: -4).contains(hoverLocation),
              !buckets.isEmpty else { return nil }
        let nearest = buckets.enumerated().min {
            abs($0.element.x - hoverLocation.x) < abs($1.element.x - hoverLocation.x)
        }
        guard let nearest,
              abs(nearest.element.x - hoverLocation.x) <= max(
                8,
                GeekChartWindow.barMarkWidth * 2
              ) else {
            return nil
        }
        return (nearest.offset, nearest.element)
    }

    private func chartBuckets(
        in plotRect: CGRect,
        referenceDate: Date
    ) -> [GeekChartBucketSnapshot] {
        let timeRange = GeekChartWindow.barRange(
            for: points.map(\.date),
            duration: duration,
            referenceDate: referenceDate
        )
        if style == .stackedBars || GeekHistoryAveraging.interval(for: duration) != nil {
            // Resolve once. The validity closures run for every sample; reading
            // the computed property there rescans/sorts the entire history N times.
            let visibleSeries = style == .stackedBars ? renderableSeries : series
            return GeekChartWindow.displayBuckets(for: points.map(\.date), in: plotRect,
                range: timeRange, referenceDate: referenceDate, displayScale: displayScale,
                isValid: { index in visibleSeries.allSatisfy { $0.channel.value(in: points[index])?.isFinite == true } },
                isMissing: { index in style == .stackedBars && visibleSeries.allSatisfy { $0.channel.value(in: points[index]) == nil } },
                holdLatestWhileFresh: true)
        }
        return GeekChartWindow.barBucketSnapshots(
            for: points.map(\.date),
            in: plotRect,
            range: timeRange,
            referenceDate: referenceDate,
            displayScale: displayScale
        )
    }

    private func hoverValues(
        at bucketIndex: Int,
        in buckets: [GeekChartBucketSnapshot],
        renderableSeries: [MenuBarTelemetrySeries], points: [MenuBarTelemetryPoint]
    ) -> [GeekHoverValue] {
        if buckets[bucketIndex].averagingGroups != nil {
            return renderableSeries.compactMap { item in
                let value = buckets[bucketIndex].mean { index -> Double? in
                    if style == .stackedBars,
                       !renderableSeries.allSatisfy({ $0.channel.value(in: points[index])?.isFinite == true }) { return nil }
                    return item.channel.value(in: points[index])
                }
                return value.map { GeekHoverValue(title: item.title, value: unit.formatted($0),
                    color: item.color, isEstimated: false) }
            }
        }
        if style == .stackedBars {
            let preparedPoints = TimeBucketAggregator.nearestFilled(
                buckets.map { bucket in
                    TimeBucketAggregator.lastSample(
                        in: bucket.indices,
                        from: points,
                        satisfying: { point in
                            renderableSeries.allSatisfy { item in
                                item.channel.value(in: point)?.isFinite == true
                            }
                        }
                    )
                }
            )
            guard preparedPoints.indices.contains(bucketIndex),
                  let point = preparedPoints[bucketIndex].value else {
                return []
            }
            return renderableSeries.compactMap { item -> GeekHoverValue? in
                guard let value = item.channel.value(in: point), value.isFinite else {
                    return nil
                }
                return GeekHoverValue(
                    title: item.title,
                    value: unit.formatted(value),
                    color: item.color,
                    isEstimated: buckets[bucketIndex].isEstimated || preparedPoints[bucketIndex].isEstimated
                )
            }
        }

        return renderableSeries.compactMap { item -> GeekHoverValue? in
            let values = TimeBucketAggregator.nearestFilled(
                buckets.map { bucket in
                    TimeBucketAggregator.lastValid(
                        bucket.indices.compactMap { item.channel.value(in: points[$0]) }
                    )
                }
            )
            guard values.indices.contains(bucketIndex),
                  let value = values[bucketIndex].value else {
                return nil
            }
            return GeekHoverValue(
                title: item.title,
                value: unit.formatted(value),
                color: item.color,
                isEstimated: buckets[bucketIndex].isEstimated || values[bucketIndex].isEstimated
            )
        }
    }

    private func timelineLabels(
        in plotRect: CGRect,
        referenceDate: Date
    ) -> some View {
        Group {
            if style == .stackedBars {
                GeekBarTimelineLabels(
                    timeRange: GeekChartWindow.barRange(
                        for: points.map(\.date),
                        duration: duration,
                        referenceDate: referenceDate
                    ),
                    plotRect: plotRect
                )
            } else {
                GeekBarTimelineLabels(
                    timeRange: GeekChartWindow.range(
                        for: points.map(\.date),
                        duration: duration,
                        referenceDate: referenceDate
                    ),
                    plotRect: plotRect
                )
            }
        }
    }

    private func accessibilitySummary(
        for renderableSeries: [MenuBarTelemetrySeries],
        statistics: [MenuBarTelemetryChannel: GeekSeriesStatistics]
    ) -> String {
        let summary = renderableSeries.compactMap { item -> String? in
            guard let stats = statistics[item.channel] else { return nil }
            return L10n.text(
                "\(item.title)：当前 \(unit.formatted(stats.current))，平均 \(unit.formatted(stats.average))，最低 \(unit.formatted(stats.minimum))，最高 \(unit.formatted(stats.maximum))",
                "\(item.title): current \(unit.formatted(stats.current)), average \(unit.formatted(stats.average)), minimum \(unit.formatted(stats.minimum)), maximum \(unit.formatted(stats.maximum))"
            )
        }
        .joined(separator: L10n.text("；", "; "))
        return summary.isEmpty ? PanelChartSampling.statusText : summary
    }
}

struct GeekPrecisionNetworkChart: View {
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.panelChartAccentColor) private var panelChartAccentColor
    @Environment(\.displayScale) private var displayScale

    let points: [MenuBarTelemetryPoint]
    let accessibilityLabel: String
    var duration: TimeInterval = GeekChartWindow.defaultDuration
    var showsLegend = true
    var showsTimelineLabels = true
    var showsBaseline = true
    var showsTooltip = false
    var horizontalInset: CGFloat = 6
    /// The plot's top inset (and bottom inset without timeline labels).
    var verticalInset: CGFloat = 4
    /// `GeekMirroredBarSeries.halfInset`.
    var mirroredHalfInset: CGFloat = 3
    /// D121: a history recomputes each half's scale on every redraw, as
    /// iStat's does; the live cards keep easing it down (D117). D131: the
    /// sample bars rescale on every redraw too (only the projection eases).
    var easesScale = true
    /// D130, D131: as `GeekPrecisionLineChart.bucketing`.
    var bucketing: GeekChartBucketing = .projection

    @State private var hoverLocation: CGPoint?
    // Each direction keeps its own scale and decay (D117).
    @StateObject private var uploadAxisScale = PanelChartAxisScale()
    @StateObject private var downloadAxisScale = PanelChartAxisScale()

    private var eases: Bool { easesScale && bucketing.easesScale }

    var body: some View {
        MenuBarChartPreparation(kind: "network-summary", first: points.first?.date, last: points.last?.date,
            count: points.count, configuration: "network", cost: max(256, points.count * 96),
            build: { [points] in GeekNetworkHistorySnapshot(points: points) }) { history in
                chartBody(history: history)
            }
    }

    private func chartBody(history: GeekNetworkHistorySnapshot) -> some View {
        let visibleAccessibilitySummary = accessibilitySummary(for: history)

        return VStack(alignment: .leading, spacing: 2) {
            if showsLegend {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8, alignment: .leading),
                        GridItem(.flexible(), spacing: 8, alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 2
                ) {
                    GeekChartLegend(
                        title: L10n.text("上传", "Upload"),
                        color: uploadBarColor
                    )
                    GeekChartLegend(
                        title: L10n.text("下载", "Download"),
                        color: downloadBarColor
                    )
                }
            }

            Group {
                if !history.hasRenderableData {
                    PanelChartSamplingPlaceholder()
                } else {
                    GeekLiveChartTimeline(duration: duration) { referenceDate in
                        GeometryReader { proxy in
                            let plotRect = CGRect(
                                x: horizontalInset,
                                y: verticalInset,
                                width: max(1, proxy.size.width - horizontalInset * 2),
                                height: max(1, proxy.size.height - verticalInset - (showsTimelineLabels ? 16 : 0))
                            )
                            MenuBarChartPreparation(kind: "network-frame", first: points.first?.date, last: points.last?.date,
                                count: points.count,
                                configuration: "\(plotRect):\(duration):\(displayScale)\(bucketing.preparationTag)",
                                shape: "\(plotRect):\(displayScale)\(bucketing.preparationTag)",
                                window: bucketing.window(duration),
                                clockRevision: bucketing.clockRevision(for: referenceDate, duration: duration),
                                cost: max(512, points.count * 128),
                                build: { [duration, displayScale, bucketing] in
                                    GeekPreparedNetworkFrame(history: history, plotRect: plotRect,
                                        duration: duration, referenceDate: referenceDate, displayScale: displayScale,
                                        bucketing: bucketing)
                                }) { preparedFrame in
                            let uploadTarget = preparedFrame.uploadMaximum
                            let downloadTarget = preparedFrame.downloadMaximum

                            ZStack(alignment: .topLeading) {
                                Color.clear

                                if showsBaseline {
                                    zeroBaseline(in: plotRect)
                                }

                                if history.uploadHasRenderableData {
                                    networkBars(
                                        marks: preparedFrame.uploadMarks,
                                        in: plotRect,
                                        maximum: eases ? uploadAxisScale.displayedMaximum(fallback: uploadTarget) : uploadTarget,
                                        color: uploadBarColor,
                                        upward: true
                                    )
                                }
                                if history.downloadHasRenderableData {
                                    networkBars(
                                        marks: preparedFrame.downloadMarks,
                                        in: plotRect,
                                        maximum: eases ? downloadAxisScale.displayedMaximum(fallback: downloadTarget) : downloadTarget,
                                        color: downloadBarColor,
                                        upward: false
                                    )
                                }

                                if showsTimelineLabels {
                                    timelineLabels(
                                        in: plotRect,
                                        frame: preparedFrame
                                    )
                                }
                                if showsTooltip {
                                    hoverOverlay(
                                        in: plotRect,
                                        frame: preparedFrame
                                    )
                                }
                            }
                            .menuBarPresentationProbe("hover", revision: MenuBarPresentationProbe.revision(hoverLocation), when: showsTooltip)
                            .menuBarScriptHover("hover.network", enabled: showsTooltip) { hoverLocation = $0 }
                            .onContinuousHover { phase in
                                guard showsTooltip else { return }
                                switch phase {
                                case let .active(location):
                                    MenuBarPresentationTrace.beginInput("hover", label: "hover.network")
                                    hoverLocation = location
                                case .ended:
                                    hoverLocation = nil
                                }
                            }
                            .onAppear {
                                uploadAxisScale.update(targetMaximum: uploadTarget, at: referenceDate)
                                downloadAxisScale.update(targetMaximum: downloadTarget, at: referenceDate)
                            }
                            .onChange(of: uploadTarget) { _, maximum in
                                uploadAxisScale.update(targetMaximum: maximum, at: referenceDate)
                            }
                            .onChange(of: downloadTarget) { _, maximum in
                                downloadAxisScale.update(targetMaximum: maximum, at: referenceDate)
                            }
                            .onChange(of: referenceDate) { _, date in
                                uploadAxisScale.update(targetMaximum: uploadTarget, at: date)
                                downloadAxisScale.update(targetMaximum: downloadTarget, at: date)
                            }
                            .font(AdvancedPanelTypography.caption)
                            .monospaced()
                            .foregroundStyle(.tertiary)
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                            // D146: iStat's peaks are each half's scale, the
                            // drawn samples' maximum and at least 1 KB/s.
                            .preference(key: GeekMirroredChartPeaksKey.self, value: GeekMirroredChartPeaks(
                                upward: history.uploadHasRenderableData ? uploadTarget : nil,
                                downward: history.downloadHasRenderableData ? downloadTarget : nil))
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(visibleAccessibilitySummary)
        .accessibilityHint(TimeBucketAggregator.nearestFillDescription)
    }

    private var uploadBarColor: Color {
        metricColors.networkUpload
    }

    private var downloadBarColor: Color {
        metricColors.networkDownload
    }

    private func networkBars(
        marks: [GeekMirroredBarMark],
        in plotRect: CGRect,
        maximum: Double,
        color: Color,
        upward: Bool
    ) -> some View {
        GeekMirroredBarSeries(
            marks: marks,
            plotRect: plotRect,
            maximum: maximum,
            color: color,
            upward: upward,
            halfInset: mirroredHalfInset,
            fillsGaps: bucketing.fillsGaps,
            zeroIsBar: bucketing.zeroIsBar
        )
    }

    private func zeroBaseline(in plotRect: CGRect) -> some View {
        let hairline = MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
        let baselineY = MiniWindowPixel.strokeCenter(
            plotRect.midY,
            lineWidth: hairline,
            displayScale: displayScale
        )
        return Path { path in
            path.move(to: CGPoint(x: plotRect.minX, y: baselineY))
            path.addLine(to: CGPoint(x: plotRect.maxX, y: baselineY))
        }
        .stroke(
            .primary.opacity(contrast == .increased ? 0.24 : 0.13),
            style: StrokeStyle(lineWidth: hairline)
        )
        .accessibilityHidden(true)
    }

    private func timelineLabels(
        in plotRect: CGRect,
        frame: GeekPreparedNetworkFrame
    ) -> some View {
        GeekBarTimelineLabels(
            timeRange: frame.range,
            plotRect: plotRect
        )
    }

    @ViewBuilder
    private func hoverOverlay(
        in plotRect: CGRect,
        frame: GeekPreparedNetworkFrame
    ) -> some View {
        if let hoveredPoint = hoveredPoint(
            in: plotRect,
            frame: frame
        ) {
            GeekHistoryHoverIndicator(
                barCenterX: hoveredPoint.x,
                plotRect: plotRect,
                tooltip: GeekHoverTooltip(
                    date: hoveredPoint.date,
                    values: [
                        hoveredPoint.upload.map { value in
                            GeekHoverValue(
                            title: L10n.text("上传", "Upload"),
                            value: GeekChartUnit.bytesPerSecond.formatted(value),
                            color: uploadBarColor,
                            isEstimated: hoveredPoint.uploadIsEstimated
                            )
                        },
                        hoveredPoint.download.map { value in
                            GeekHoverValue(
                            title: L10n.text("下载", "Download"),
                            value: GeekChartUnit.bytesPerSecond.formatted(value),
                            color: downloadBarColor,
                            isEstimated: hoveredPoint.downloadIsEstimated
                            )
                        },
                    ].compactMap { $0 },
                    visibleDuration: duration
                )
            )
        }
    }

    private func hoveredPoint(
        in plotRect: CGRect,
        frame: GeekPreparedNetworkFrame
    ) -> (
        date: Date,
        x: CGFloat,
        upload: Double?,
        download: Double?,
        uploadIsEstimated: Bool,
        downloadIsEstimated: Bool
    )? {
        guard let hoverLocation,
              plotRect.insetBy(dx: -4, dy: -4).contains(hoverLocation),
              let bucket = frame.buckets.min(by: {
                  abs($0.x - hoverLocation.x) < abs($1.x - hoverLocation.x)
              }),
              abs(bucket.x - hoverLocation.x) <= max(
                8,
                GeekChartWindow.barMarkWidth * 2
              ) else {
            return nil
        }
        return (
            bucket.end,
            bucket.x,
            bucket.upload,
            bucket.download,
            bucket.uploadIsEstimated,
            bucket.downloadIsEstimated
        )
    }

    private func accessibilitySummary(
        for history: GeekNetworkHistorySnapshot
    ) -> String {
        guard history.hasRenderableData else {
            return PanelChartSampling.statusText
        }

        var summaries: [String] = []
        if history.downloadHasRenderableData, let stats = history.downloadStatistics {
            summaries.append(L10n.text(
                "下载当前 \(GeekChartUnit.bytesPerSecond.formatted(stats.current))，平均 \(GeekChartUnit.bytesPerSecond.formatted(stats.average))，峰值 \(GeekChartUnit.bytesPerSecond.formatted(stats.maximum))",
                "Download current \(GeekChartUnit.bytesPerSecond.formatted(stats.current)), average \(GeekChartUnit.bytesPerSecond.formatted(stats.average)), peak \(GeekChartUnit.bytesPerSecond.formatted(stats.maximum))"
            ))
        }
        if history.uploadHasRenderableData, let stats = history.uploadStatistics {
            summaries.append(L10n.text(
                "上传当前 \(GeekChartUnit.bytesPerSecond.formatted(stats.current))，平均 \(GeekChartUnit.bytesPerSecond.formatted(stats.average))，峰值 \(GeekChartUnit.bytesPerSecond.formatted(stats.maximum))",
                "Upload current \(GeekChartUnit.bytesPerSecond.formatted(stats.current)), average \(GeekChartUnit.bytesPerSecond.formatted(stats.average)), peak \(GeekChartUnit.bytesPerSecond.formatted(stats.maximum))"
            ))
        }
        return summaries.joined(separator: L10n.text("；", "; "))
    }
}

/// Read and write each fit their own peak in every mode (D117): the combined
/// chart's halves (`GeekPreparedDiskFrame.readMaximum` / `writeMaximum`) and
/// the single-direction charts alike.
enum GeekDiskIOChartMode: Sendable {
    case combined
    case read
    case write
}

struct GeekDiskIOChart: View {
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.panelChartAccentColor) private var panelChartAccentColor

    let points: [NativeDiskIOPoint]
    let accessibilityLabel: String
    var mode: GeekDiskIOChartMode = .combined
    var duration: TimeInterval = GeekChartWindow.defaultDuration
    var showsLegend = true
    var showsTimelineLabels = true
    var showsTooltip = false
    var horizontalInset: CGFloat = 6
    /// The plot's top inset (and bottom inset without timeline labels).
    var verticalInset: CGFloat = 4
    /// `GeekMirroredBarSeries.halfInset`. D120: 0 on the disk module page's
    /// activity card, where iStat's halves reach the graph's edges.
    var mirroredHalfInset: CGFloat = 3
    /// D121: see `GeekPrecisionNetworkChart.easesScale`.
    var easesScale = true
    /// D130, D131: as `GeekPrecisionLineChart.bucketing`.
    var bucketing: GeekChartBucketing = .projection

    @State private var hoverLocation: CGPoint?
    // Each direction keeps its own scale and decay (D117).
    @StateObject private var readAxisScale = PanelChartAxisScale()
    @StateObject private var writeAxisScale = PanelChartAxisScale()

    private var eases: Bool { easesScale && bucketing.easesScale }

    var body: some View {
        GeekLiveChartTimeline(duration: duration) { referenceDate in
            MenuBarChartPreparation(kind: GeekPreparedDiskSummary.preparationKind, first: points.first?.date, last: points.last?.date,
                count: points.count, configuration: GeekPreparedDiskSummary.preparationConfiguration(duration: duration),
                shape: GeekPreparedDiskSummary.preparationShape,
                clockRevision: referenceDate.timeIntervalSince1970, cost: 512,
                build: { GeekPreparedDiskSummary(points: points, duration: duration, referenceDate: referenceDate) }) { summary in
                chartBody(summary)
            }
        }
    }

    private func chartBody(_ summary: GeekPreparedDiskSummary) -> some View {
        // A pending clock update retains this complete prior window; never
        // prepare a new frame against an older summary's statistics.
        let referenceDate = summary.referenceDate
        return VStack(alignment: .leading, spacing: 2) {
            if showsLegend {
                HStack(spacing: 14) {
                    if mode != .write {
                        // D138: iStat's 'Disks.Read', 'Disks.Write' (were 读取, 写入).
                        GeekChartLegend(title: L10n.text("读", "Read"), color: diskReadColor)
                    }
                    if mode != .read {
                        GeekChartLegend(title: L10n.text("写", "Write"), color: diskWriteColor)
                    }
                }
            }

            Group {
                if !summary.hasData {
                    PanelChartSamplingPlaceholder()
                } else {
                    GeometryReader { proxy in
                        let plotRect = CGRect(
                            x: horizontalInset,
                            y: verticalInset,
                            width: max(1, proxy.size.width - horizontalInset * 2),
                            height: max(1, proxy.size.height - verticalInset - (showsTimelineLabels ? 16 : 0))
                        )
                        MenuBarChartPreparation(kind: "disk-frame", first: points.first?.date, last: points.last?.date,
                            count: points.count, configuration: "\(plotRect):\(duration):\(displayScale)\(bucketing.preparationTag)",
                            shape: "\(plotRect):\(displayScale)\(bucketing.preparationTag)",
                            window: bucketing.window(duration),
                            clockRevision: bucketing == .projection ? referenceDate.timeIntervalSince1970
                                : bucketing.clockRevision(for: referenceDate, duration: duration),
                            cost: max(1024, points.count * 128),
                            build: { [points, duration, displayScale, bucketing] in GeekPreparedDiskFrame(points: points, plot: plotRect, duration: duration,
                                reference: referenceDate, scale: displayScale, bucketing: bucketing) }) { prepared in
                        let readTarget = prepared.readMaximum
                        let writeTarget = prepared.writeMaximum

                        ZStack(alignment: .topLeading) {
                            Color.clear

                            // D121: one direction draws no baseline, as the
                            // other single-series histories.
                            if mode == .combined {
                                zeroBaseline(in: plotRect)
                            }
                            if mode != .write {
                                GeekMirroredBarSeries(marks: prepared.readMarks, plotRect: plotRect,
                                    maximum: eases ? readAxisScale.displayedMaximum(fallback: readTarget) : readTarget,
                                    color: diskReadColor, upward: true,
                                    singleDirection: mode != .combined, halfInset: mirroredHalfInset,
                                    fillsGaps: bucketing.fillsGaps, zeroIsBar: bucketing.zeroIsBar)
                            }
                            if mode != .read {
                                GeekMirroredBarSeries(marks: prepared.writeMarks, plotRect: plotRect,
                                    maximum: eases ? writeAxisScale.displayedMaximum(fallback: writeTarget) : writeTarget,
                                    color: diskWriteColor,
                                    upward: mode == .write, singleDirection: mode != .combined,
                                    halfInset: mirroredHalfInset,
                                    fillsGaps: bucketing.fillsGaps, zeroIsBar: bucketing.zeroIsBar)
                            }

                            if showsTimelineLabels {
                                GeekBarTimelineLabels(
                                    timeRange: prepared.range,
                                    plotRect: plotRect
                                )
                            }
                            if showsTooltip {
                                hoverOverlay(
                                    in: plotRect,
                                    prepared: prepared
                                )
                            }
                        }
                        .menuBarPresentationProbe("hover", revision: MenuBarPresentationProbe.revision(hoverLocation), when: showsTooltip)
                        .menuBarScriptHover("hover.disk", enabled: showsTooltip) { hoverLocation = $0 }
                        .onContinuousHover { phase in
                            guard showsTooltip else { return }
                            switch phase {
                            case let .active(location):
                                MenuBarPresentationTrace.beginInput("hover", label: "hover.disk")
                                hoverLocation = location
                            case .ended:
                                hoverLocation = nil
                            }
                        }
                        .onAppear {
                            readAxisScale.update(targetMaximum: readTarget, at: referenceDate)
                            writeAxisScale.update(targetMaximum: writeTarget, at: referenceDate)
                        }
                        .onChange(of: readTarget) { _, maximum in
                            readAxisScale.update(targetMaximum: maximum, at: referenceDate)
                        }
                        .onChange(of: writeTarget) { _, maximum in
                            writeAxisScale.update(targetMaximum: maximum, at: referenceDate)
                        }
                        .onChange(of: referenceDate) { _, date in
                            readAxisScale.update(targetMaximum: readTarget, at: date)
                            writeAxisScale.update(targetMaximum: writeTarget, at: date)
                        }
                        .font(AdvancedPanelTypography.caption)
                        .monospaced()
                        .foregroundStyle(.tertiary)
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                        // D146: iStat's disk peaks are the drawn samples'
                        // maximum, without the scale's 1 KB/s floor.
                        .preference(key: GeekMirroredChartPeaksKey.self, value: GeekMirroredChartPeaks(
                            upward: mode != .write ? prepared.readPeak : nil,
                            downward: mode != .read ? prepared.writePeak : nil))
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilitySummary(summary))
        .accessibilityHint(TimeBucketAggregator.nearestFillDescription)
    }

    private var diskReadColor: Color {
        metricColors.diskRead
    }

    private var diskWriteColor: Color {
        metricColors.diskWrite
    }

    private func zeroBaseline(in plotRect: CGRect) -> some View {
        let hairline = MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
        let baselineY = MiniWindowPixel.strokeCenter(plotRect.midY, lineWidth: hairline, displayScale: displayScale)
        return Path { path in
            path.move(to: CGPoint(x: plotRect.minX, y: baselineY))
            path.addLine(to: CGPoint(x: plotRect.maxX, y: baselineY))
        }
        .stroke(
            .primary.opacity(contrast == .increased ? 0.24 : 0.13),
            style: StrokeStyle(lineWidth: hairline)
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func hoverOverlay(
        in plotRect: CGRect,
        prepared: GeekPreparedDiskFrame
    ) -> some View {
        if let index = hoveredIndex(in: plotRect, prepared: prepared) {
            let hoveredPoint = prepared.buckets[index]
            GeekHistoryHoverIndicator(
                barCenterX: hoveredPoint.x,
                plotRect: plotRect,
                tooltip: GeekHoverTooltip(
                    date: hoveredPoint.end,
                    values: [
                        (mode == .write ? nil : prepared.reads[index]).map { value in
                            // D138: iStat's tooltip rows, 'Disks.Read' and
                            // 'Disks.Write' (were 读取, 写入).
                            GeekHoverValue(
                            title: L10n.text("读", "Read"),
                            value: GeekChartUnit.diskBytesPerSecond.formatted(value),
                            color: diskReadColor,
                            isEstimated: hoveredPoint.isEstimated
                            )
                        },
                        (mode == .read ? nil : prepared.writes[index]).map { value in
                            GeekHoverValue(
                            title: L10n.text("写", "Write"),
                            value: GeekChartUnit.diskBytesPerSecond.formatted(value),
                            color: diskWriteColor,
                            isEstimated: hoveredPoint.isEstimated
                            )
                        }
                    ].compactMap { $0 },
                    visibleDuration: duration
                )
            )
        }
    }

    private func hoveredIndex(in plotRect: CGRect, prepared: GeekPreparedDiskFrame) -> Int? {
        guard let hoverLocation, plotRect.insetBy(dx: -4, dy: -4).contains(hoverLocation) else { return nil }
        let nearest = prepared.buckets.indices.filter { !prepared.buckets[$0].indices.isEmpty }.min {
            abs(prepared.buckets[$0].x - hoverLocation.x) < abs(prepared.buckets[$1].x - hoverLocation.x)
        }
        guard let nearest, abs(prepared.buckets[nearest].x - hoverLocation.x) <= max(8, GeekChartWindow.barMarkWidth * 2) else { return nil }
        return nearest
    }

    private func accessibilitySummary(_ summary: GeekPreparedDiskSummary) -> String {
        guard summary.hasData else {
            return PanelChartSampling.statusText
        }
        if mode == .read, let stats = summary.read {
            return L10n.text(
                "读取当前 \(GeekChartUnit.diskBytesPerSecond.formatted(stats.current))，平均 \(GeekChartUnit.diskBytesPerSecond.formatted(stats.average))，峰值 \(GeekChartUnit.diskBytesPerSecond.formatted(stats.maximum))",
                "Read current \(GeekChartUnit.diskBytesPerSecond.formatted(stats.current)), average \(GeekChartUnit.diskBytesPerSecond.formatted(stats.average)), peak \(GeekChartUnit.diskBytesPerSecond.formatted(stats.maximum))"
            )
        }
        if mode == .write, let stats = summary.write {
            return L10n.text(
                "写入当前 \(GeekChartUnit.diskBytesPerSecond.formatted(stats.current))，平均 \(GeekChartUnit.diskBytesPerSecond.formatted(stats.average))，峰值 \(GeekChartUnit.diskBytesPerSecond.formatted(stats.maximum))",
                "Write current \(GeekChartUnit.diskBytesPerSecond.formatted(stats.current)), average \(GeekChartUnit.diskBytesPerSecond.formatted(stats.average)), peak \(GeekChartUnit.diskBytesPerSecond.formatted(stats.maximum))"
            )
        }
        guard let readStatistics = summary.read,
              let writeStatistics = summary.write else {
            return PanelChartSampling.statusText
        }
        return L10n.text(
            "读取当前 \(GeekChartUnit.diskBytesPerSecond.formatted(readStatistics.current))，平均 \(GeekChartUnit.diskBytesPerSecond.formatted(readStatistics.average))，峰值 \(GeekChartUnit.diskBytesPerSecond.formatted(readStatistics.maximum))；写入当前 \(GeekChartUnit.diskBytesPerSecond.formatted(writeStatistics.current))，平均 \(GeekChartUnit.diskBytesPerSecond.formatted(writeStatistics.average))，峰值 \(GeekChartUnit.diskBytesPerSecond.formatted(writeStatistics.maximum))",
            "Read current \(GeekChartUnit.diskBytesPerSecond.formatted(readStatistics.current)), average \(GeekChartUnit.diskBytesPerSecond.formatted(readStatistics.average)), peak \(GeekChartUnit.diskBytesPerSecond.formatted(readStatistics.maximum)); write current \(GeekChartUnit.diskBytesPerSecond.formatted(writeStatistics.current)), average \(GeekChartUnit.diskBytesPerSecond.formatted(writeStatistics.average)), peak \(GeekChartUnit.diskBytesPerSecond.formatted(writeStatistics.maximum))"
        )
    }
}

struct GeekHoverValue: Identifiable {
    let title: String
    let value: String
    let color: Color
    var isEstimated = false
    var showsTitle = true

    var id: String { title }
}

/// D121: iStat's history tooltip (`BBRMenuHistorySubmenuOverlay`): the
/// bucket's time, then one 15 pt row per value (dot, name, value on the
/// right), inside an 8 pt inset on a dark box with corner 8. Its width is
/// the widest row up to 200 (`GeekHistoryTooltipLayout`); the height is
/// 8 + 15 + 8 + 15 × rows + 8.
struct GeekHoverTooltip: View {
    let date: Date
    let values: [GeekHoverValue]
    let visibleDuration: TimeInterval
    var detail: String? = nil

    /// Nothing to show: iStat hides the tooltip over a bucket without data.
    var isEmpty: Bool { values.isEmpty && detail == nil }

    var body: some View {
        let header = PanelChartDateFormatting.tooltipLines(for: date, visibleDuration: visibleDuration)
        VStack(alignment: .leading, spacing: 0) {
            // The time, and from 3 days up the date on its own row (+15).
            VStack(alignment: .leading, spacing: 0) {
                Text(header.time)
                    .frame(height: GeekIStatHistoryGeometry.tooltipRowHeight)
                if let day = header.date {
                    Text(day)
                        .frame(height: GeekIStatHistoryGeometry.tooltipRowHeight)
                }
            }
            .font(AdvancedPanelTypography.captionStrong)
            .monospacedDigit()
            .padding(.bottom, GeekIStatHistoryGeometry.tooltipInset)

            ForEach(values) { item in
                HStack(spacing: 0) {
                    Circle()
                        .fill(item.color)
                        .frame(width: 6, height: 6)
                        .padding(.trailing, 4)
                    if item.showsTitle {
                        Text(item.title)
                            .foregroundStyle(.white.opacity(GeekIStatCardGeometry.labelOpacity))
                    }
                    Spacer(minLength: 12)
                    Text(item.value)
                        .monospacedDigit()
                }
                .font(AdvancedPanelTypography.caption)
                .frame(height: GeekIStatHistoryGeometry.tooltipRowHeight)
            }
            if let detail {
                Text(detail)
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(GeekIStatHistoryGeometry.tooltipInset)
        .miniWindowTooltipChrome(.history)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// D121: the hover state of a history chart: a 2 pt indicator over the
/// hovered bar from the plot's top to its bottom, and the tooltip beside it
/// (`GeekHistoryTooltipLayout`). Without values for the bucket neither is
/// drawn. No animation; the parent redraws only when the bucket changes.
struct GeekHistoryHoverIndicator: View {
    @Environment(\.displayScale) private var displayScale
    let barCenterX: CGFloat
    let plotRect: CGRect
    let tooltip: GeekHoverTooltip

    var body: some View {
        if !tooltip.isEmpty {
            let width = MiniWindowPixel.snappedLength(GeekIStatHistoryGeometry.indicatorWidth, displayScale: displayScale)
            let minX = MiniWindowPixel.aligned(barCenterX - width / 2, displayScale: displayScale)
            ZStack(alignment: .topLeading) {
                Path(CGRect(x: minX, y: plotRect.minY, width: width, height: plotRect.height))
                    .fill(.primary.opacity(0.45))
                GeekHistoryTooltipLayout(indicatorMinX: minX, indicatorMaxX: minX + width, top: plotRect.minY) {
                    tooltip
                }
            }
            .allowsHitTesting(false)
            .transaction { $0.animation = nil }
        }
    }
}

/// D121: places the tooltip 8 pt right of the indicator, its top at the
/// plot's top; when it would pass the chart's trailing edge it goes 6 pt
/// left of the indicator instead. Its width is its ideal width, at most 200.
struct GeekHistoryTooltipLayout: Layout {
    let indicatorMinX: CGFloat
    let indicatorMaxX: CGFloat
    let top: CGFloat

    static func originX(indicatorMinX: CGFloat, indicatorMaxX: CGFloat, width: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let trailing = indicatorMaxX + GeekIStatHistoryGeometry.tooltipGap
        guard trailing + width > containerWidth else { return trailing }
        return max(0, indicatorMinX - GeekIStatHistoryGeometry.tooltipFlippedGap - width)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for subview in subviews {
            let width = min(GeekIStatHistoryGeometry.tooltipMaximumWidth, subview.sizeThatFits(.unspecified).width)
            let x = Self.originX(indicatorMinX: indicatorMinX, indicatorMaxX: indicatorMaxX,
                                 width: width, containerWidth: bounds.width)
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + top),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: nil)
            )
        }
    }
}

private struct GeekChartLegend: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            Text(title)
                .font(AdvancedPanelTypography.captionStrong)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}
