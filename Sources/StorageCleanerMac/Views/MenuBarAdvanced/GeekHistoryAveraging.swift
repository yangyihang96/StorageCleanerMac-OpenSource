import Foundation
import CoreGraphics

/// Time resolution is independent of polling cadence and physical chart width.
/// Raw samples and persistence are deliberately not rewritten by this projection.
enum GeekHistoryAveraging {
    /// Bjango documents 6 s for 1 h and 144 s for 1 day. Both give 600
    /// observation windows. Extending that density to other long ranges is
    /// our policy; Bjango does not publish their per-point resolutions.
    static let targetWindowCount = 600

    static func interval(for duration: TimeInterval) -> TimeInterval? {
        guard duration.isFinite, duration >= 3_600,
              duration <= MenuBarHistoryRetention.duration else { return nil }
        return duration / Double(targetWindowCount)
    }

    struct Window {
        let start: Date
        let end: Date
        let indices: [Int]
        let weights: [Double]
    }

    /// Known pauses as sorted, disjoint half-open spans. `contains` answers
    /// exactly `gaps.contains { date >= $0.start && date < $0.end }` (an empty
    /// pause or a NaN bound or date contains nothing), with a binary search
    /// instead of a pass over every pause for every sample. D130: also read
    /// by `GeekIStatHistoryBuckets`.
    struct KnownPauses {
        private var starts: [TimeInterval] = []
        private var ends: [TimeInterval] = []

        init(_ gaps: [DateInterval]) {
            let spans = gaps.map { ($0.start.timeIntervalSinceReferenceDate, $0.end.timeIntervalSinceReferenceDate) }
                .filter { $0.0 < $0.1 }
                .sorted { $0.0 < $1.0 }
            for (start, end) in spans {
                if let last = ends.last, start <= last {
                    ends[ends.count - 1] = max(last, end)
                } else {
                    starts.append(start)
                    ends.append(end)
                }
            }
        }

        func contains(_ date: Date) -> Bool {
            let time = date.timeIntervalSinceReferenceDate
            var lower = 0, upper = starts.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if starts[middle] <= time { lower = middle + 1 } else { upper = middle }
            }
            return lower > 0 && time < ends[lower - 1]
        }
    }

    static func windows(
        dates: [Date], interval: TimeInterval, start: Date, referenceDate: Date,
        gaps: [DateInterval] = [], isMissing: (Int) -> Bool = { _ in false },
        intervalStart: (Int) -> Date? = { _ in nil }
    ) -> [Window] {
        guard interval.isFinite, interval > 0, referenceDate >= start,
              referenceDate.timeIntervalSince(start) <= MenuBarHistoryRetention.duration else { return [] }
        // Window k is [boundary(k), boundary(k + 1)). Seconds since 1970 are
        // coarser than a Date, so dividing them only estimates the window: a
        // date next to a boundary can convert onto it. Every placement below
        // compares the Date itself with the boundaries.
        func boundary(_ key: Int64) -> Date { Date(timeIntervalSince1970: Double(key) * interval) }
        func window(containing date: Date) -> Int64 {
            var key = Int64(floor(date.timeIntervalSince1970 / interval))
            while date < boundary(key) { key -= 1 }
            while date >= boundary(key + 1) { key += 1 }
            return key
        }
        let first = window(containing: start)
        // Samples always belong to [start, end), even at an exact boundary.
        // At the instant a new window begins, expose it only if it already has
        // an observation; otherwise retain the just-completed window on screen.
        let current = window(containing: referenceDate)
        let atBoundary = referenceDate == boundary(current)
        let hasBoundarySample = atBoundary && dates.indices.contains {
            dates[$0] == referenceDate && !isMissing($0)
                && !gaps.contains(where: { referenceDate >= $0.start && referenceDate < $0.end })
        }
        let last = max(first, current - (atBoundary && !hasBoundarySample ? 1 : 0))
        var groups = Array(repeating: [Int](), count: Int(last - first + 1))
        var weights = Array(repeating: [Double](), count: groups.count)
        let pauses = KnownPauses(gaps)
        for index in dates.indices {
            let date = dates[index]
            guard date >= start, date <= referenceDate, !isMissing(index),
                  !pauses.contains(date) else { continue }
            if let measuredStart = intervalStart(index), measuredStart < date,
               date.timeIntervalSince(measuredStart) <= 90,
               !MenuBarSamplingGaps.crosses(gaps, from: measuredStart, to: date) {
                let lower = max(start, measuredStart)
                let dateWindow = window(containing: date)
                let firstCovered = max(first, window(containing: lower))
                let lastCovered = min(last, date > boundary(dateWindow) ? dateWindow : dateWindow - 1)
                // A span with nothing inside the range (the sample is exactly
                // at `start`) counts as one observation at its own time.
                if lower < date, firstCovered <= lastCovered {
                    for key in firstCovered...lastCovered {
                        let overlap = min(date, boundary(key + 1)).timeIntervalSince(max(lower, boundary(key)))
                        if overlap > 0 {
                            groups[Int(key - first)].append(index)
                            weights[Int(key - first)].append(overlap)
                        }
                    }
                    continue
                }
            }
            let key = window(containing: date)
            groups[Int(key - first)].append(index)
            weights[Int(key - first)].append(1)
        }
        return groups.indices.map { offset in
            let key = first + Int64(offset)
            let lower = boundary(key), upper = boundary(key + 1)
            // Live history already arrives in timestamp order. Avoid allocating
            // and sorting pairs for every redraw, while retaining stable ordering
            // and matching weights for imported or out-of-order observations.
            let indices = groups[offset]
            let isOrdered = zip(indices, indices.dropFirst()).allSatisfy {
                dates[$0.0] <= dates[$0.1]
            }
            if isOrdered {
                return Window(start: max(start, lower), end: min(referenceDate, upper),
                    indices: indices, weights: weights[offset])
            }
            let ordered = zip(indices, weights[offset]).sorted {
                dates[$0.0] == dates[$1.0] ? $0.0 < $1.0 : dates[$0.0] < dates[$1.0]
            }
            return Window(start: max(start, lower), end: min(referenceDate, upper),
                indices: ordered.map(\.0), weights: ordered.map(\.1))
        }
    }

    static func displayBuckets(
        dates: [Date], interval: TimeInterval, plotRect: CGRect,
        range: (start: Date, end: Date, dataStart: Date), referenceDate: Date,
        displayScale: CGFloat, gaps: [DateInterval], isMissing: (Int) -> Bool,
        intervalStart: (Int) -> Date?
    ) -> [GeekChartBucketSnapshot] {
        guard plotRect.width.isFinite, plotRect.width > 0 else { return [] }
        let windows = windows(dates: dates, interval: interval, start: range.start,
            referenceDate: referenceDate, gaps: gaps, isMissing: isMissing, intervalStart: intervalStart)
        guard !windows.isEmpty else { return [] }
        let count = GeekChartWindow.barSlotCount(in: plotRect, displayScale: displayScale)
        let metrics = GeekChartWindow.barMetrics(displayScale: displayScale)
        let usedWidth = CGFloat(count) * metrics.width + CGFloat(count - 1) * metrics.spacing
        let inset = max(0, (plotRect.width - usedWidth) / 2)
        // Group whole time windows, rather than splitting one poll over pixel
        // slots. Empty windows contribute no value and are never treated as zero.
        return (0..<count).map { slot in
            let lower = slot * windows.count / count
            let upper = (slot + 1) * windows.count / count
            let selected = windows[lower..<upper]
            let groups = selected.map(\.indices)
            let start = selected.first?.start ?? range.start
            let end = selected.last?.end ?? start
            let center = plotRect.minX + inset + metrics.width / 2 + CGFloat(slot) * metrics.pitch
            return GeekChartBucketSnapshot(indices: groups.flatMap { $0 },
                x: MiniWindowPixel.strokeCenter(center, lineWidth: metrics.width, displayScale: displayScale),
                start: start, end: end, averagingGroups: groups, averagingInterval: interval,
                averagingWeights: selected.map(\.weights))
        }
    }
}
