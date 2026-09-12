import SwiftUI

enum GeekChartUnit {
    case percent
    case temperature
    case fanRPM
    case bytes
    case bytesPerSecond

    func formatted(_ value: Double, compact: Bool = false) -> String {
        switch self {
        case .percent:
            return String(format: compact ? "%.0f%%" : "%.1f%%", value)
        case .temperature:
            return String(format: compact ? "%.0f°C" : "%.1f°C", value)
        case .fanRPM:
            return "\(Int(value.rounded()))" + (compact ? "" : " rpm")
        case .bytes:
            return ByteFormat.string(Int64(max(0, value).rounded()))
        case .bytesPerSecond:
            return "\(ByteFormat.string(Int64(max(0, value).rounded())))/s"
        }
    }
}

enum GeekPrecisionChartStyle {
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

struct GeekLiveChartTimeline<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelChartClock) private var sharedClock

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
        if let sharedClock {
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
        // Keep the existing time-slot pitch while using a one-physical-pixel gap.
        let pitch = MiniWindowPixel.snappedLength(barMarkWidth + barSpacing, displayScale: displayScale)
        let spacing = MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
        return (max(spacing, pitch - spacing), spacing, pitch)
    }

    static func stackedBarRect(
        x: CGFloat, width: CGFloat,
        lower: Double, upper: Double,
        in plotRect: CGRect,
        range: ClosedRange<Double>,
        displayScale: CGFloat
    ) -> CGRect {
        let span = max(Double.ulpOfOne, range.upperBound - range.lowerBound)
        let lowerY = plotRect.maxY - plotRect.height * CGFloat((lower - range.lowerBound) / span)
        let upperY = plotRect.maxY - plotRect.height * CGFloat((upper - range.lowerBound) / span)
        let height = max(
            MiniWindowPixel.onePhysicalPixel(displayScale: displayScale),
            MiniWindowPixel.snappedLength(abs(lowerY - upperY), displayScale: displayScale)
        )
        return CGRect(
            x: MiniWindowPixel.aligned(x, displayScale: displayScale),
            y: MiniWindowPixel.aligned(min(plotRect.maxY - height, min(lowerY, upperY)), displayScale: displayScale),
            width: width,
            height: height
        )
    }

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

    private static func barX(
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

struct GeekChartBucketSnapshot {
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
        let gaps = MenuBarSamplingGaps.shared.intervals()
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

enum GeekBarChartScale {
    static func throughputUpperBound(for values: [Double]) -> Double {
        // Callers pass the actual displayed averages, not unaggregated polls.
        // Every visible peak must fit; a percentile ceiling clips real activity.
        guard let peak = values.filter({ $0.isFinite && $0 > 0 }).max() else { return 1 }
        return MenuBarChartGeometry.niceCeiling(for: [peak], minimum: 1)
    }

}

struct GeekNetworkHistorySnapshot {
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
        var dates: [Date] = []
        var uploadSamples: [MenuBarChartSample] = []
        var downloadSamples: [MenuBarChartSample] = []
        dates.reserveCapacity(points.count)
        uploadSamples.reserveCapacity(points.count)
        downloadSamples.reserveCapacity(points.count)

        for point in points {
            let upload = point.upBytesPerSecond.map(Double.init)
            let download = point.downBytesPerSecond.map(Double.init)
            dates.append(point.date)
            uploadSamples.append(MenuBarChartSample(date: point.date, value: upload))
            downloadSamples.append(MenuBarChartSample(date: point.date, value: download))
        }

        self.dates = dates
        self.uploadSamples = uploadSamples
        self.downloadSamples = downloadSamples
        uploadHasRenderableData = PanelChartSampling.hasRenderableTrend(uploadSamples)
        downloadHasRenderableData = PanelChartSampling.hasRenderableTrend(downloadSamples)
        uploadStatistics = GeekSeriesStatistics(values: uploadSamples.compactMap(\.value))
        downloadStatistics = GeekSeriesStatistics(values: downloadSamples.compactMap(\.value))
    }
}

struct GeekPreparedNetworkBucket {
    let x: CGFloat
    let end: Date
    let upload: Double?
    let download: Double?
    let uploadIsEstimated: Bool
    let downloadIsEstimated: Bool
}

struct GeekPreparedNetworkFrame {
    let range: (start: Date, end: Date, dataStart: Date)
    let buckets: [GeekPreparedNetworkBucket]
    let uploadMarks: [GeekMirroredBarMark]
    let downloadMarks: [GeekMirroredBarMark]
    let maximum: Double

    init(
        history: GeekNetworkHistorySnapshot,
        plotRect: CGRect,
        duration: TimeInterval,
        referenceDate: Date,
        displayScale: CGFloat
    ) {
        let range = GeekChartWindow.barRange(
            for: history.dates,
            duration: duration,
            referenceDate: referenceDate
        )
        let snapshots = GeekChartWindow.displayBuckets(
            for: history.dates,
            in: plotRect,
            range: range,
            referenceDate: referenceDate,
            displayScale: displayScale,
            isValid: { history.uploadSamples[$0].value != nil && history.downloadSamples[$0].value != nil },
            isMissing: { history.uploadSamples[$0].value == nil && history.downloadSamples[$0].value == nil },
            holdLatestWhileFresh: true
        )
        let rawUploads = snapshots.map { bucket in
            bucket.mean { history.uploadSamples[$0].value }
        }
        let rawDownloads = snapshots.map { bucket in
            bucket.mean { history.downloadSamples[$0].value }
        }
        let uploads = TimeBucketAggregator.nearestFilled(rawUploads)
        let downloads = TimeBucketAggregator.nearestFilled(rawDownloads)
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
        var scaleValues: [Double] = []
        if history.uploadHasRenderableData {
            scaleValues.append(contentsOf: rawUploads.compactMap { $0 })
        }
        if history.downloadHasRenderableData {
            scaleValues.append(contentsOf: rawDownloads.compactMap { $0 })
        }

        self.range = range
        self.buckets = buckets
        self.uploadMarks = uploadMarks
        self.downloadMarks = downloadMarks
        maximum = GeekBarChartScale.throughputUpperBound(for: scaleValues)
    }
}

struct GeekMirroredBarMark {
    let x: CGFloat
    let value: Double
    var isEstimated = false
}

enum GeekChartDrawing {
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
                context.fill(Path(rect), with: .color(.secondary.opacity(0.045)))
                // Keep the true time gap quiet. Its meaning is available in
                // the chart help rather than repeated over every metric plot.
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

    var body: some View {
        let metrics = GeekChartWindow.barMetrics(displayScale: displayScale)
        let halfHeight = max(1, plotRect.height / 2 - 3)
        let safeMaximum = max(Double.ulpOfOne, maximum)

        Canvas { context, _ in
            context.clip(to: Path(plotRect))
            let hairline = MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
            let baselineY = MiniWindowPixel.strokeCenter(
                plotRect.midY,
                lineWidth: hairline,
                displayScale: displayScale
            )

            if upward {
                GeekChartDrawing.gaps(in: context, plot: plotRect,
                    occupiedX: marks.map(\.x), displayScale: displayScale)
            }
            for mark in marks {
                let amplitude = halfHeight * CGFloat(
                    min(1, max(0, mark.value) / safeMaximum)
                )
                let endY = MiniWindowPixel.aligned(
                    upward ? baselineY - amplitude : baselineY + amplitude,
                    displayScale: displayScale
                )
                let height = max(
                    hairline,
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
struct GeekCPUHistoryFrame {
    struct Mark {
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
        displayScale: CGFloat
    ) -> Self {
        guard duration.isFinite, duration > 0, duration <= MenuBarHistoryRetention.duration,
              plotRect.width.isFinite, plotRect.width > 0,
              plotRect.minX.isFinite else {
            return Self(marks: [], bucketDuration: 1)
        }
        if GeekHistoryAveraging.interval(for: duration) != nil {
            let range = GeekChartWindow.barRange(for: points.map(\.date), duration: duration,
                referenceDate: referenceDate)
            let buckets = GeekChartWindow.displayBuckets(for: points.map(\.date), in: plotRect,
                range: range, referenceDate: referenceDate, displayScale: displayScale,
                isMissing: { !isComplete(points[$0]) })
            let width = GeekChartWindow.barMetrics(displayScale: displayScale).width
            let marks = buckets.compactMap { bucket -> Mark? in
                guard let latestIndex = bucket.indices.last,
                      let peakIndex = bucket.indices.max(by: { points[$0].cpuTotal! < points[$1].cpuTotal! })
                else { return nil }
                let mean = MenuBarTelemetryPoint(date: bucket.end,
                    cpuTotal: bucket.mean { points[$0].cpuTotal },
                    cpuUser: bucket.mean { points[$0].cpuUser },
                    cpuSystem: bucket.mean { points[$0].cpuSystem },
                    gpu: nil, memory: nil, chipTemperature: nil, fanRPM: nil,
                    downBytesPerSecond: nil, upBytesPerSecond: nil)
                return Mark(bucket: bucket,
                    rect: CGRect(x: MiniWindowPixel.aligned(bucket.x - width / 2, displayScale: displayScale),
                                 y: plotRect.minY, width: width, height: plotRect.height),
                    latest: points[latestIndex], mean: mean, peak: points[peakIndex],
                    peakTotal: points[peakIndex].cpuTotal!, isEstimated: false)
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
        let gaps = MenuBarSamplingGaps.shared.intervals(at: referenceDate)
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

    private static func isComplete(_ point: MenuBarTelemetryPoint) -> Bool {
        [point.cpuTotal, point.cpuUser, point.cpuSystem].allSatisfy {
            guard let value = $0 else { return false }
            return value.isFinite && (0...100).contains(value)
        }
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

    var body: some View {
        let dates = points.map(\.date)
        let timeRange = GeekChartWindow.barRange(
            for: dates,
            duration: duration,
            referenceDate: referenceDate
        )
        let buckets = cpuFrame == nil ? GeekChartWindow.displayBuckets(
            for: dates,
            in: plotRect,
            range: timeRange,
            referenceDate: referenceDate,
            displayScale: displayScale,
            isValid: { index in series.allSatisfy { $0.channel.value(in: points[index])?.isFinite == true } },
            isMissing: { index in series.allSatisfy { $0.channel.value(in: points[index]) == nil } },
            holdLatestWhileFresh: true
        ) : []
        let bucketValues = buckets.map { bucket in
            series.map { item in
                bucket.displayValue { index in
                    guard series.allSatisfy({ $0.channel.value(in: points[index])?.isFinite == true }) else { return nil }
                    return item.channel.value(in: points[index])
                }
            }
        }
        let metrics = GeekChartWindow.barMetrics(displayScale: displayScale)

        Canvas { context, _ in
            context.clip(to: Path(plotRect))

            let observations: [(values: [Double?], x: CGFloat, width: CGFloat, estimated: Bool)]
            if let cpuFrame {
                observations = cpuFrame.marks.map { mark in
                    (series.map { $0.channel.value(in: mark.mean) }, mark.rect.minX, mark.rect.width, mark.isEstimated)
                }
            } else {
                observations = zip(buckets, bucketValues).compactMap { bucket, values in
                    guard values.contains(where: { $0 != nil }) else { return nil }
                    return (values, bucket.x - metrics.width / 2, metrics.width, bucket.isEstimated)
                }
            }
            GeekChartDrawing.gaps(in: context, plot: plotRect,
                occupiedX: observations.map { $0.x + $0.width / 2 }, displayScale: displayScale)
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
                    guard value > 0 || (total == 0 && index == firstValidIndex) else { continue }

                    let rect = GeekChartWindow.stackedBarRect(
                        x: observation.x, width: observation.width,
                        lower: lower, upper: base,
                        in: plotRect, range: valueRange,
                        displayScale: displayScale
                    )
                    GeekChartDrawing.bar(in: context, rect: rect, color: colors[index],
                        estimated: observation.estimated, displayScale: displayScale)
                }
            }
        }
    }
}

struct GeekSeriesStatistics {
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
    var domainPolicy: ChartDomainPolicy?
    var showsValueLabels = false
    var lineWidth: CGFloat = 1.35
    var fillOpacity: Double = 0
    var cpuSamplingInterval: TimeInterval = 1

    @State private var hoverLocation: CGPoint?

    var body: some View {
        let visibleSeries = renderableSeries
        let visibleAccessibilitySummary = accessibilitySummary(for: visibleSeries)

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
                                y: 4,
                                width: max(1, proxy.size.width - horizontalInset * 2 - (showsValueLabels ? 56 : 0)),
                                height: max(1, proxy.size.height - (showsTimelineLabels ? 20 : 4))
                            )
                            let visibleValueRange = resolvedValueRange
                            let cpuFrame = usesCPUHistoryBuckets ? GeekCPUHistoryFrame.prepare(
                                points: points,
                                plotRect: plotRect,
                                duration: duration,
                                referenceDate: referenceDate,
                                samplingInterval: cpuSamplingInterval,
                                displayScale: displayScale
                            ) : nil

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
                                        cpuFrame: cpuFrame
                                    )
                                } else {
                                    ForEach(visibleSeries, id: \.id) { item in
                                        let color = resolvedColor(for: item, renderableSeries: visibleSeries)
                                        let segments = pointSegments(
                                            for: item.channel,
                                            in: plotRect,
                                            valueRange: visibleValueRange,
                                            referenceDate: referenceDate
                                        )
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
                                    timelineLabels(
                                        in: plotRect,
                                        referenceDate: referenceDate
                                    )
                                }
                                if showsTooltip {
                                    hoverOverlay(
                                        in: plotRect,
                                        renderableSeries: visibleSeries,
                                        referenceDate: referenceDate,
                                        cpuFrame: cpuFrame
                                    )
                                }
                            }
                            .onContinuousHover { phase in
                                guard showsTooltip else { return }
                                switch phase {
                                case let .active(location):
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(visibleAccessibilitySummary)
        .accessibilityHint(samplingWindowDescription)
        .help(samplingWindowDescription)
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
        case .percent:
            return .fixed(min: 0, max: 100)
        case .bytes, .bytesPerSecond:
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
        if [.cpuUser, .cpuSystem, .compressedMemoryBytes, .swapUsedBytes].contains(item.channel) {
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
        cpuFrame: GeekCPUHistoryFrame?
    ) -> some View {
        if let cpuFrame {
            cpuHoverOverlay(in: plotRect, series: renderableSeries, frame: cpuFrame)
        } else if hoverLocation != nil {
            let buckets = chartBuckets(
                in: plotRect,
                referenceDate: referenceDate
            )
            if let hoveredPoint = hoveredPoint(
                in: plotRect,
                buckets: buckets
            ), let hoverLocation {
                let hairline = MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
                let indicatorX = MiniWindowPixel.strokeCenter(
                    hoveredPoint.bucket.x,
                    lineWidth: hairline,
                    displayScale: displayScale
                )
                Path { path in
                    path.move(to: CGPoint(x: indicatorX, y: plotRect.minY))
                    path.addLine(to: CGPoint(x: indicatorX, y: plotRect.maxY))
                }
                .stroke(.primary.opacity(0.72), style: StrokeStyle(lineWidth: hairline))

                GeekHoverTooltip(
                    date: hoveredPoint.bucket.end,
                    values: hoverValues(
                        at: hoveredPoint.index,
                        in: buckets,
                        renderableSeries: renderableSeries
                    ),
                    visibleDuration: duration,
                    detail: bucketDescription(hoveredPoint.bucket, series: renderableSeries)
                )
                .position(
                    x: min(plotRect.maxX - 72, max(plotRect.minX + 72, hoverLocation.x)),
                    y: plotRect.minY + 39
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
                    title: item.title, value: unit.formatted(value), color: item.color, isEstimated: mark.isEstimated
                )
            } + (mark.isEstimated ? [] : [GeekHoverValue(
                title: L10n.text("该段总 CPU 峰值", "Segment total CPU peak"),
                value: unit.formatted(mark.peakTotal),
                color: .primary, isEstimated: false
            )])
            let start = PanelChartDateFormatting.string(for: mark.bucket.start, visibleDuration: duration)
            let end = PanelChartDateFormatting.string(for: mark.bucket.end, visibleDuration: duration)
            let peakDate = observationDate(mark.peak)
            let hairline = MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
            Path { path in
                path.move(to: CGPoint(x: mark.rect.midX, y: plotRect.minY))
                path.addLine(to: CGPoint(x: mark.rect.midX, y: plotRect.maxY))
            }
            .stroke(.primary.opacity(0.72), style: StrokeStyle(lineWidth: hairline))
            GeekHoverTooltip(
                date: mark.latest.date,
                values: values,
                visibleDuration: duration,
                detail: mark.isEstimated
                    ? L10n.text("\(start)–\(end) · 短缺口估算", "\(start)–\(end) · Short-gap estimate")
                    : L10n.text("\(start)–\(end) · 平均值；峰值实测 \(peakDate)",
                                "\(start)–\(end) · Mean; peak observed \(peakDate)")
            )
            .position(
                x: min(plotRect.maxX - 72, max(plotRect.minX + 72, hoverLocation.x)),
                y: plotRect.minY + 39
            )
        }
    }

    private func bucketDescription(
        _ bucket: GeekChartBucketSnapshot,
        series: [MenuBarTelemetrySeries]
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
        renderableSeries: [MenuBarTelemetrySeries]
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
        for renderableSeries: [MenuBarTelemetrySeries]
    ) -> String {
        let summary = renderableSeries.compactMap { item -> String? in
            guard let stats = statistics(for: item.channel) else { return nil }
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

    @State private var hoverLocation: CGPoint?
    @StateObject private var dynamicAxisScale = PanelChartAxisScale()

    var body: some View {
        let history = GeekNetworkHistorySnapshot(points: points)
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
                                y: 4,
                                width: max(1, proxy.size.width - horizontalInset * 2),
                                height: max(1, proxy.size.height - (showsTimelineLabels ? 20 : 4))
                            )
                            let preparedFrame = GeekPreparedNetworkFrame(
                                history: history,
                                plotRect: plotRect,
                                duration: duration,
                                referenceDate: referenceDate,
                                displayScale: displayScale
                            )
                            let targetMaximum = preparedFrame.maximum
                            let maximum = dynamicAxisScale.displayedMaximum(
                                fallback: targetMaximum
                            )

                            ZStack(alignment: .topLeading) {
                                Color.clear

                                if showsBaseline {
                                    zeroBaseline(in: plotRect)
                                }

                                if history.uploadHasRenderableData {
                                    networkBars(
                                        marks: preparedFrame.uploadMarks,
                                        in: plotRect,
                                        maximum: maximum,
                                        color: uploadBarColor,
                                        upward: true
                                    )
                                }
                                if history.downloadHasRenderableData {
                                    networkBars(
                                        marks: preparedFrame.downloadMarks,
                                        in: plotRect,
                                        maximum: maximum,
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
                            .onContinuousHover { phase in
                                guard showsTooltip else { return }
                                switch phase {
                                case let .active(location):
                                    hoverLocation = location
                                case .ended:
                                    hoverLocation = nil
                                }
                            }
                            .onAppear {
                                dynamicAxisScale.update(
                                    targetMaximum: targetMaximum,
                                    at: referenceDate
                                )
                            }
                            .onChange(of: targetMaximum) { _, maximum in
                                dynamicAxisScale.update(
                                    targetMaximum: maximum,
                                    at: referenceDate
                                )
                            }
                            .onChange(of: referenceDate) { _, date in
                                dynamicAxisScale.update(
                                    targetMaximum: targetMaximum,
                                    at: date
                                )
                            }
                            .font(AdvancedPanelTypography.caption)
                            .monospaced()
                            .foregroundStyle(.tertiary)
                            .transaction { transaction in
                                transaction.animation = nil
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
        MenuBarNetworkPalette.upload
    }

    private var downloadBarColor: Color {
        MenuBarNetworkPalette.download
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
            upward: upward
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
        ), let hoverLocation {
            let hairline = MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
            let indicatorX = MiniWindowPixel.strokeCenter(
                hoveredPoint.x,
                lineWidth: hairline,
                displayScale: displayScale
            )
            Path { path in
                path.move(to: CGPoint(x: indicatorX, y: plotRect.minY))
                path.addLine(to: CGPoint(x: indicatorX, y: plotRect.maxY))
            }
            .stroke(.primary.opacity(0.72), style: StrokeStyle(lineWidth: hairline))

            GeekHoverTooltip(
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
            .position(
                x: min(plotRect.maxX - 72, max(plotRect.minX + 72, hoverLocation.x)),
                y: plotRect.minY + 39
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

struct GeekDiskIOChart: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.panelChartAccentColor) private var panelChartAccentColor

    let points: [NativeDiskIOPoint]
    let accessibilityLabel: String
    var duration: TimeInterval = GeekChartWindow.defaultDuration
    var showsLegend = true
    var showsTimelineLabels = true
    var showsTooltip = false
    var horizontalInset: CGFloat = 6

    @State private var hoverLocation: CGPoint?
    @StateObject private var dynamicAxisScale = PanelChartAxisScale()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsLegend {
                HStack(spacing: 14) {
                    GeekChartLegend(
                        title: L10n.text("读取", "Read"),
                        color: diskReadColor
                    )
                    GeekChartLegend(
                        title: L10n.text("写入", "Write"),
                        color: diskWriteColor
                    )
                }
            }

            Group {
                if !hasRenderableData {
                    PanelChartSamplingPlaceholder()
                } else {
                    GeekLiveChartTimeline(duration: duration) { referenceDate in
                        GeometryReader { proxy in
                            let plotRect = CGRect(
                                x: horizontalInset,
                                y: 4,
                                width: max(1, proxy.size.width - horizontalInset * 2),
                                height: max(1, proxy.size.height - (showsTimelineLabels ? 20 : 4))
                            )
                            let targetMaximum = chartMaximum(
                                in: plotRect,
                                referenceDate: referenceDate
                            )
                            let maximum = dynamicAxisScale.displayedMaximum(
                                fallback: targetMaximum
                            )

                            ZStack(alignment: .topLeading) {
                                Color.clear

                                zeroBaseline(in: plotRect)
                                bars(
                                    values: readValues,
                                    dates: points.map(\.date),
                                    in: plotRect,
                                    maximum: maximum,
                                    color: diskReadColor,
                                    upward: true,
                                    referenceDate: referenceDate
                                )
                                bars(
                                    values: writeValues,
                                    dates: points.map(\.date),
                                    in: plotRect,
                                    maximum: maximum,
                                    color: diskWriteColor,
                                    upward: false,
                                    referenceDate: referenceDate
                                )

                                if showsTimelineLabels {
                                    GeekBarTimelineLabels(
                                        timeRange: GeekChartWindow.barRange(
                                            for: points.map(\.date),
                                            duration: duration,
                                            referenceDate: referenceDate
                                        ),
                                        plotRect: plotRect
                                    )
                                }
                                if showsTooltip {
                                    hoverOverlay(
                                        in: plotRect,
                                        referenceDate: referenceDate
                                    )
                                }
                            }
                            .onContinuousHover { phase in
                                guard showsTooltip else { return }
                                switch phase {
                                case let .active(location):
                                    hoverLocation = location
                                case .ended:
                                    hoverLocation = nil
                                }
                            }
                            .onAppear {
                                dynamicAxisScale.update(
                                    targetMaximum: targetMaximum,
                                    at: referenceDate
                                )
                            }
                            .onChange(of: targetMaximum) { _, maximum in
                                dynamicAxisScale.update(
                                    targetMaximum: maximum,
                                    at: referenceDate
                                )
                            }
                            .onChange(of: referenceDate) { _, date in
                                dynamicAxisScale.update(
                                    targetMaximum: targetMaximum,
                                    at: date
                                )
                            }
                            .font(AdvancedPanelTypography.caption)
                            .monospaced()
                            .foregroundStyle(.tertiary)
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint(TimeBucketAggregator.nearestFillDescription)
    }

    private var readValues: [Double] {
        points.map { Double($0.readBytesPerSecond) }
    }

    private var writeValues: [Double] {
        points.map { Double($0.writeBytesPerSecond) }
    }

    private var diskReadColor: Color {
        AppChartPalette.cpuSystem
    }

    private var diskWriteColor: Color {
        AppChartPalette.primary
    }

    private var hasRenderableData: Bool {
        PanelChartSampling.hasRenderableTrend(
            points.map {
                MenuBarChartSample(date: $0.date, value: Double($0.readBytesPerSecond))
            }
        ) || PanelChartSampling.hasRenderableTrend(
            points.map {
                MenuBarChartSample(date: $0.date, value: Double($0.writeBytesPerSecond))
            }
        )
    }

    private var readStatistics: GeekSeriesStatistics? {
        GeekSeriesStatistics(values: readValues)
    }

    private var writeStatistics: GeekSeriesStatistics? {
        GeekSeriesStatistics(values: writeValues)
    }

    private func chartMaximum(
        in plotRect: CGRect,
        referenceDate: Date
    ) -> Double {
        let timeRange = GeekChartWindow.barRange(
            for: points.map(\.date),
            duration: duration,
            referenceDate: referenceDate
        )
        let values = GeekChartWindow.displayBuckets(
            for: points.map(\.date),
            in: plotRect,
            range: timeRange,
            referenceDate: referenceDate,
            displayScale: displayScale,
            intervalStart: { points[$0].intervalStart },
            holdLatestWhileFresh: true
        ).flatMap { bucket in
            return [
                bucket.displayValue { readValues[$0] },
                bucket.displayValue { writeValues[$0] },
            ].compactMap { $0 }
        }
        return GeekBarChartScale.throughputUpperBound(for: values)
    }

    private func bars(
        values: [Double],
        dates: [Date],
        in plotRect: CGRect,
        maximum: Double,
        color: Color,
        upward: Bool,
        referenceDate: Date
    ) -> some View {
        let timeRange = GeekChartWindow.barRange(
            for: dates,
            duration: duration,
            referenceDate: referenceDate
        )
        let buckets = GeekChartWindow.displayBuckets(
            for: dates,
            in: plotRect,
            range: timeRange,
            referenceDate: referenceDate,
            displayScale: displayScale,
            intervalStart: { points[$0].intervalStart },
            holdLatestWhileFresh: true
        )
        let preparedValues = TimeBucketAggregator.nearestFilled(
            buckets.map { bucket in
                bucket.displayValue { values[$0] }
            }
        )
        let marks = zip(buckets, preparedValues).compactMap { bucket, prepared in
            prepared.value.map {
                GeekMirroredBarMark(
                    x: bucket.x,
                    value: $0,
                    isEstimated: bucket.isEstimated || prepared.isEstimated
                )
            }
        }

        return GeekMirroredBarSeries(
            marks: marks,
            plotRect: plotRect,
            maximum: maximum,
            color: color,
            upward: upward
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

    @ViewBuilder
    private func hoverOverlay(
        in plotRect: CGRect,
        referenceDate: Date
    ) -> some View {
        if let hoveredPoint = hoveredPoint(
            in: plotRect,
            referenceDate: referenceDate
        ), let hoverLocation {
            let hairline = MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
            let indicatorX = MiniWindowPixel.strokeCenter(
                hoveredPoint.x,
                lineWidth: hairline,
                displayScale: displayScale
            )
            Path { path in
                path.move(to: CGPoint(x: indicatorX, y: plotRect.minY))
                path.addLine(to: CGPoint(x: indicatorX, y: plotRect.maxY))
            }
            .stroke(.primary.opacity(0.72), style: StrokeStyle(lineWidth: hairline))

            GeekHoverTooltip(
                date: hoveredPoint.end,
                values: [
                    hoveredPoint.displayValue { readValues[$0] }.map { value in
                        GeekHoverValue(
                        title: L10n.text("读取", "Read"),
                        value: GeekChartUnit.bytesPerSecond.formatted(value),
                        color: diskReadColor,
                        isEstimated: hoveredPoint.isEstimated
                        )
                    },
                    hoveredPoint.displayValue { writeValues[$0] }.map { value in
                        GeekHoverValue(
                        title: L10n.text("写入", "Write"),
                        value: GeekChartUnit.bytesPerSecond.formatted(value),
                        color: diskWriteColor,
                        isEstimated: hoveredPoint.isEstimated
                        )
                    }
                ].compactMap { $0 },
                visibleDuration: duration
            )
            .position(
                x: min(plotRect.maxX - 72, max(plotRect.minX + 72, hoverLocation.x)),
                y: plotRect.minY + 39
            )
        }
    }

    private func hoveredPoint(
        in plotRect: CGRect,
        referenceDate: Date
    ) -> GeekChartBucketSnapshot? {
        guard let hoverLocation,
              plotRect.insetBy(dx: -4, dy: -4).contains(hoverLocation),
              !points.isEmpty else { return nil }
        let dates = points.map(\.date)
        let timeRange = GeekChartWindow.barRange(
            for: dates,
            duration: duration,
            referenceDate: referenceDate
        )
        let marks = GeekChartWindow.displayBuckets(
            for: dates,
            in: plotRect,
            range: timeRange,
            referenceDate: referenceDate,
            displayScale: displayScale,
            intervalStart: { points[$0].intervalStart },
            holdLatestWhileFresh: true
        )
        let candidates = marks.filter { !$0.indices.isEmpty }
        let nearest = candidates
        .min { abs($0.x - hoverLocation.x) < abs($1.x - hoverLocation.x) }
        guard let nearest,
              abs(nearest.x - hoverLocation.x) <= max(
                8,
                GeekChartWindow.barMarkWidth * 2
              ) else {
            return nil
        }
        return nearest
    }

    private var accessibilitySummary: String {
        guard hasRenderableData,
              let readStatistics,
              let writeStatistics else {
            return PanelChartSampling.statusText
        }
        return L10n.text(
            "读取当前 \(GeekChartUnit.bytesPerSecond.formatted(readStatistics.current))，平均 \(GeekChartUnit.bytesPerSecond.formatted(readStatistics.average))，峰值 \(GeekChartUnit.bytesPerSecond.formatted(readStatistics.maximum))；写入当前 \(GeekChartUnit.bytesPerSecond.formatted(writeStatistics.current))，平均 \(GeekChartUnit.bytesPerSecond.formatted(writeStatistics.average))，峰值 \(GeekChartUnit.bytesPerSecond.formatted(writeStatistics.maximum))",
            "Read current \(GeekChartUnit.bytesPerSecond.formatted(readStatistics.current)), average \(GeekChartUnit.bytesPerSecond.formatted(readStatistics.average)), peak \(GeekChartUnit.bytesPerSecond.formatted(readStatistics.maximum)); write current \(GeekChartUnit.bytesPerSecond.formatted(writeStatistics.current)), average \(GeekChartUnit.bytesPerSecond.formatted(writeStatistics.average)), peak \(GeekChartUnit.bytesPerSecond.formatted(writeStatistics.maximum))"
        )
    }
}

struct GeekHoverValue: Identifiable {
    let title: String
    let value: String
    let color: Color
    var isEstimated = false

    var id: String { title }
}

struct GeekHoverTooltip: View {
    let date: Date
    let values: [GeekHoverValue]
    let visibleDuration: TimeInterval
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(PanelChartDateFormatting.string(
                for: date,
                visibleDuration: visibleDuration
            ))
                .font(AdvancedPanelTypography.captionStrong)
                .monospaced()

            ForEach(values) { item in
                HStack(spacing: 5) {
                    Circle()
                        .fill(item.color)
                        .frame(width: 6, height: 6)
                    Text(item.title)
                        .foregroundStyle(item.color)
                    Spacer(minLength: 8)
                    Text(item.value)
                        .monospacedDigit()
                }
                .font(AdvancedPanelTypography.caption)
            }
            if let detail {
                Text(detail)
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(3)
            }
        }
        .foregroundStyle(.white.opacity(0.95))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 156)
        .miniWindowTooltipChrome()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
