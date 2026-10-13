import SwiftUI

/// Projects persisted coverage, rather than stretching a bucket's last poll
/// across missing time. Recent uncompressed charts keep their existing path.
enum GeekCompressedHistoryProjection {
    static var help: String {
        L10n.text("该时段平均按有效记录时间加权；峰值来自真实样本，末值是最后一次读数。未记录、睡眠和暂停不按 0 计入。",
                  "Period averages are weighted by recorded time; peaks are real samples and last values are final readings. Unrecorded, sleep and paused periods are excluded, not zero.")
    }

    static func hasTrend(_ points: [MenuBarTelemetryPoint], channel: MenuBarTelemetryChannel) -> Bool {
        points.contains { point in
            guard let record = point.bucketStatistics?.metrics[channel.rawValue] else { return false }
            return record.sampleCount >= PanelChartSampling.minimumRenderableSampleCount && record.coveredDuration > 0
        }
    }

    /// One pass, one gap snapshot, no per-point record allocation for raw
    /// samples. Same result as `GeekSeriesStatistics(records:current:)` over
    /// `statistic(for:previous:)` of every point.
    static func telemetryStatistics(_ points: [MenuBarTelemetryPoint], channel: MenuBarTelemetryChannel,
                                    gaps: [DateInterval]? = nil) -> GeekSeriesStatistics? {
        guard let lastPoint = points.last else { return nil }
        let gaps = gaps ?? MenuBarSamplingGaps.shared.intervals(at: lastPoint.date)
        var accumulator = GeekSeriesStatisticsAccumulator()
        var previousDate: Date?
        for point in points {
            defer { previousDate = channel.value(in: point) == nil ? nil : channel.sampleDate(in: point) }
            if let record = point.bucketStatistics?.metrics[channel.rawValue] {
                accumulator.add(mean: record.mean, minimum: record.minimum, peak: record.peak,
                                last: record.last, duration: record.coveredDuration)
                continue
            }
            if point.bucketStatistics != nil { continue }
            guard let value = channel.value(in: point), value.isFinite else { continue }
            let end = channel.sampleDate(in: point)
            if let before = previousDate, end <= before { continue }
            let duration = previousDate.map { before in
                MenuBarHistoryStatistic.coverage(from: before, to: end, gaps: gaps).first?.duration ?? 0
            } ?? 0
            accumulator.add(mean: value, minimum: value, peak: value, last: value, duration: duration)
        }
        return accumulator.statistics(current: channel.value(in: lastPoint))
    }

    /// Weight for a stored observation with no measured coverage (an isolated
    /// sample). Every weight is in seconds; an instant counts only when its
    /// bucket has nothing with real duration.
    static let instantWeight: Double = 0.001

    /// Existing screen columns keep their geometry. Their values get the
    /// actual overlapping duration of each stored coverage fragment.
    static func buckets(_ original: [GeekChartBucketSnapshot], dates: [Date],
                        records: [MenuBarHistoryStatistic?]) -> [GeekChartBucketSnapshot] {
        guard !original.isEmpty else { return [] }
        var indices = Array(repeating: [Int](), count: original.count)
        var weights = Array(repeating: [Double](), count: original.count)
        for index in records.indices {
            guard let record = records[index], dates.indices.contains(index) else { continue }
            if record.coverage.isEmpty {
                // Binary search; buckets are ordered and non-overlapping.
                let date = dates[index]
                var lower = 0, upper = original.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if original[middle].end < date { lower = middle + 1 } else { upper = middle }
                }
                if lower < original.count, date >= original[lower].start {
                    indices[lower].append(index); weights[lower].append(instantWeight)
                }
                continue
            }
            var lower = 0, upper = original.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if original[middle].end <= record.start { lower = middle + 1 } else { upper = middle }
            }
            var slot = lower
            while slot < original.count, original[slot].start < record.end {
                let weight = record.overlap(from: original[slot].start, to: original[slot].end)
                if weight > 0 { indices[slot].append(index); weights[slot].append(weight) }
                slot += 1
            }
        }
        return original.indices.map { index in
            let old = original[index]
            return GeekChartBucketSnapshot(indices: indices[index], x: old.x, start: old.start, end: old.end,
                averagingGroups: [indices[index]], averagingInterval: old.averagingInterval,
                averagingWeights: [weights[index]])
        }
    }
}

/// Streaming form of `GeekSeriesStatistics(records:current:)`.
struct GeekSeriesStatisticsAccumulator {
    private var minimum = Double.infinity
    private var maximum = -Double.infinity
    private var weightedSum = 0.0
    private var duration = 0.0
    private var commonMean: Double?
    private var hasWeighted = false
    private var mixedMeans = false
    private var lastMean: Double?
    private var lastValue: Double?

    mutating func add(mean: Double, minimum: Double, peak: Double, last: Double, duration: Double) {
        self.minimum = Swift.min(self.minimum, minimum)
        maximum = Swift.max(maximum, peak)
        weightedSum += mean * duration
        self.duration += duration
        if duration > 0 {
            if let commonMean, commonMean != mean { mixedMeans = true }
            if !hasWeighted { commonMean = mean; hasWeighted = true }
        }
        lastMean = mean
        lastValue = last
    }

    func statistics(current: Double?) -> GeekSeriesStatistics? {
        guard let lastMean, let current = current ?? lastValue else { return nil }
        // Constant real rates must stay exactly constant (no summation drift).
        let average = hasWeighted && !mixedMeans ? commonMean! : duration > 0 ? weightedSum / duration : lastMean
        return GeekSeriesStatistics(current: current, minimum: minimum, average: average, maximum: maximum)
    }
}

extension GeekSeriesStatistics {
    init(current: Double, minimum: Double, average: Double, maximum: Double) {
        self.current = current
        self.minimum = minimum
        self.average = average
        self.maximum = maximum
    }

    init?(records: [MenuBarHistoryStatistic], current: Double?) {
        guard let fallback = records.last, let current = current ?? records.last?.last,
              let minimum = records.map(\.minimum).min(), let maximum = records.map(\.peak).max() else { return nil }
        let duration = records.reduce(0) { $0 + $1.coveredDuration }
        self.current = current
        self.minimum = minimum
        self.maximum = maximum
        let weighted = records.filter { $0.coveredDuration > 0 }
        // Constant real rates must stay exactly constant (no summation drift).
        if let first = weighted.first, weighted.allSatisfy({ $0.mean == first.mean }) {
            self.average = first.mean
        } else {
            self.average = duration > 0
                ? records.reduce(0) { $0 + $1.mean * ($1.coveredDuration / duration) } : fallback.mean
        }
    }
}
