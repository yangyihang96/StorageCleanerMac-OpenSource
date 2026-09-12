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

    static func windows(
        dates: [Date], interval: TimeInterval, start: Date, referenceDate: Date,
        gaps: [DateInterval] = [], isMissing: (Int) -> Bool = { _ in false },
        intervalStart: (Int) -> Date? = { _ in nil }
    ) -> [Window] {
        guard interval.isFinite, interval > 0, referenceDate >= start,
              referenceDate.timeIntervalSince(start) <= MenuBarHistoryRetention.duration else { return [] }
        let first = Int64(floor(start.timeIntervalSince1970 / interval))
        // Samples always belong to [start, end), even at an exact boundary.
        // At the instant a new window begins, expose it only if it already has
        // an observation; otherwise retain the just-completed window on screen.
        let current = Int64(floor(referenceDate.timeIntervalSince1970 / interval))
        let atBoundary = referenceDate.timeIntervalSince1970 == Double(current) * interval
        let hasBoundarySample = atBoundary && dates.indices.contains {
            dates[$0] == referenceDate && !isMissing($0)
                && !gaps.contains(where: { referenceDate >= $0.start && referenceDate < $0.end })
        }
        let last = max(first, current - (atBoundary && !hasBoundarySample ? 1 : 0))
        var groups = Array(repeating: [Int](), count: Int(last - first + 1))
        var weights = Array(repeating: [Double](), count: groups.count)
        for index in dates.indices {
            let date = dates[index]
            guard date >= start, date <= referenceDate, !isMissing(index),
                  !gaps.contains(where: { date >= $0.start && date < $0.end }) else { continue }
            if let measuredStart = intervalStart(index), measuredStart < date,
               date.timeIntervalSince(measuredStart) <= 90,
               !MenuBarSamplingGaps.crosses(gaps, from: measuredStart, to: date) {
                let lower = max(start, measuredStart)
                let firstCovered = max(first, Int64(floor(lower.timeIntervalSince1970 / interval)))
                let lastCovered = min(last, Int64(ceil(date.timeIntervalSince1970 / interval)) - 1)
                if firstCovered <= lastCovered {
                    for key in firstCovered...lastCovered {
                        let left = Date(timeIntervalSince1970: Double(key) * interval)
                        let overlap = min(date, left.addingTimeInterval(interval)).timeIntervalSince(max(lower, left))
                        if overlap > 0 {
                            groups[Int(key - first)].append(index)
                            weights[Int(key - first)].append(overlap)
                        }
                    }
                    continue
                }
            }
            let key = Int64(floor(date.timeIntervalSince1970 / interval))
            groups[Int(key - first)].append(index)
            weights[Int(key - first)].append(1)
        }
        return groups.indices.map { offset in
            let lower = Date(timeIntervalSince1970: Double(first + Int64(offset)) * interval)
            let ordered = zip(groups[offset], weights[offset]).sorted {
                dates[$0.0] == dates[$1.0] ? $0.0 < $1.0 : dates[$0.0] < dates[$1.0]
            }
            return Window(start: max(start, lower), end: min(referenceDate, lower.addingTimeInterval(interval)),
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
