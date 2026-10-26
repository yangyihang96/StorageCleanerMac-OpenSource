import SwiftUI

struct GeekPowerPreparationKernel: Sendable {
    /// A usable sample; `weight` is the number of samples it stands for (a
    /// folded minute's sample count, else 1).
    typealias Point = (date: Date, value: Double, isCharging: Bool?, powerSource: BatteryPowerSource?, weight: Double)

    let points: [MenuBarPowerHistoryPoint]
    let metric: GeekPowerHistoryMetric
    let duration: TimeInterval
    let displayScale: CGFloat
    /// D132: iStat's battery graph; nil keeps the earlier projection.
    var batteryGraph: GeekIStatBatteryGraph? = nil

    func usablePoints(endingAt referenceDate: Date) -> [Point] {
        let end = referenceDate
        let start = end.addingTimeInterval(-(batteryGraph?.span(for: duration) ?? duration))
        let latestAllowedDate = end.addingTimeInterval(
            GeekChartWindow.futureSampleTolerance
        )
        let key = metric == .charge ? "charge" : "batteryPower"
        return points.compactMap { point -> Point? in
            // D132: iStat's buckets average every sample, so a folded minute
            // counts with its mean (the projection keeps its last charge).
            let folded = point.bucketStatistics?.metrics[key]
            guard point.date >= start, point.date <= latestAllowedDate,
                  let value = metric == .charge && batteryGraph == nil ? metric.value(in: point)
                    : folded?.mean ?? metric.value(in: point),
                  value.isFinite else { return nil }
            return (
                min(point.date, end),
                value,
                point.isCharging,
                point.powerSource,
                Double(max(1, folded?.sampleCount ?? 1))
            )
        }.sorted { $0.date < $1.date }
    }

    func batteryBuckets(
        _ livePoints: [Point],
        plot: CGRect,
        referenceDate: Date
    ) -> [GeekChartBucketSnapshot] {
        let dates = livePoints.map(\.date)
        if let batteryGraph {
            return GeekIStatHistoryBuckets.buckets(dates: dates, interval: batteryGraph.interval(for: duration),
                count: batteryGraph.barCount, plotRect: plot, referenceDate: referenceDate,
                displayScale: displayScale, weight: { livePoints[$0].weight })
        }
        guard !dates.isEmpty else { return [] }
        let visibleRange = GeekChartWindow.barRange(
            for: dates,
            duration: duration,
            referenceDate: referenceDate
        )
        let unavailableDates = points.filter { metric.value(in: $0)?.isFinite != true }.map(\.date)
        let original = GeekChartWindow.displayBuckets(
            for: dates,
            in: plot,
            range: visibleRange,
            referenceDate: referenceDate,
            displayScale: displayScale,
            mayConnect: { before, after in
                livePoints[before].powerSource == livePoints[after].powerSource
                    && livePoints[before].isCharging == livePoints[after].isCharging
                    && !unavailableDates.contains { $0 > dates[before] && $0 < dates[after] }
            }
        )
        guard points.contains(where: { $0.bucketStatistics != nil }) else { return original }
        let key = metric == .charge ? "charge" : "batteryPower"
        let gaps = MenuBarSamplingGaps.shared.intervals(at: referenceDate)
        // Duplicate dates (e.g. a replayed journal entry) keep the later record
        // instead of trapping in `Dictionary(uniqueKeysWithValues:)`.
        let records = Dictionary(points.indices.map { index in
            (points[index].date, points[index].statistics(previous: index > 0 ? points[index - 1] : nil, gaps: gaps).metrics[key])
        }, uniquingKeysWith: { _, later in later })
        return GeekCompressedHistoryProjection.buckets(original, dates: dates,
            records: dates.map { records[$0] ?? nil })
    }

    func preparedBatteryBuckets(
        _ livePoints: [Point],
        plot: CGRect,
        referenceDate: Date
    ) -> [GeekPreparedPowerBucket] {
        let buckets = batteryBuckets(
            livePoints,
            plot: plot,
            referenceDate: referenceDate
        )
        if let batteryGraph {
            return iStatBatteryBuckets(buckets, livePoints: livePoints,
                                       interval: batteryGraph.interval(for: duration))
        }
        let rawPayloads = buckets.map { bucket -> GeekPowerBucketPayload? in
                guard let latestIndex = bucket.indices.last,
                      let value = (bucket.averagingGroups != nil
                        ? bucket.mean({ livePoints[$0].value })
                        : bucketValue(bucket.indices, in: livePoints)) else {
                    return nil
                }
                let point = livePoints[latestIndex]
                return GeekPowerBucketPayload(
                    value: value,
                    isCharging: point.isCharging,
                    powerSource: point.powerSource
                )
            }
        let payloads = points.contains(where: { $0.bucketStatistics != nil })
            ? rawPayloads.enumerated().map { TimeBucketValue(value: $0.element, isEstimated: false, sourceIndex: $0.offset) }
            : TimeBucketAggregator.nearestFilled(rawPayloads)
        let chargingStates = TimeBucketAggregator.forwardFilled(
            buckets.map { bucket -> Bool? in
                guard let latestIndex = bucket.indices.last else { return nil }
                return livePoints[latestIndex].isCharging
            }
        )
        let powerSources = TimeBucketAggregator.forwardFilled(
            buckets.map { bucket -> BatteryPowerSource? in
                guard let latestIndex = bucket.indices.last,
                      let source = livePoints[latestIndex].powerSource else {
                    return nil
                }
                return source == .unknown ? nil : source
            }
        )
        return buckets.indices.compactMap { index in
            guard let payload = payloads[index].value else { return nil }
            return GeekPreparedPowerBucket(
                bucket: buckets[index],
                payload: GeekPowerBucketPayload(
                    value: payload.value,
                    isCharging: chargingStates[index].value,
                    powerSource: powerSources[index].value
                ),
                isEstimated: buckets[index].isEstimated || payloads[index].isEstimated
                    || chargingStates[index].isEstimated
                    || powerSources[index].isEstimated
            )
        }
    }

    /// D132: a bucket's mean charge, on AC when at least half of its
    /// samples with a known source were (iStat averages `source` and draws
    /// ≥ 0.5 in the charging color); an empty bucket takes its newer
    /// neighbor's value (`GeekIStatBatteryGraph.filled`), never one before
    /// the first recorded sample. A filled bar looks like any other, as
    /// iStat's; `isEstimated` keeps where it came from.
    private func iStatBatteryBuckets(
        _ buckets: [GeekChartBucketSnapshot], livePoints: [Point], interval: TimeInterval
    ) -> [GeekPreparedPowerBucket] {
        let payloads = buckets.map { bucket -> GeekPowerBucketPayload? in
            guard let value = bucket.mean({ livePoints[$0].value }) else { return nil }
            var onAC = 0.0, known = 0.0
            for index in bucket.indices {
                switch livePoints[index].powerSource {
                case .acPower?: onAC += livePoints[index].weight; known += livePoints[index].weight
                case .batteryPower?: known += livePoints[index].weight
                case .unknown?, nil: break
                }
            }
            let source: BatteryPowerSource? = known > 0 ? (onAC / known >= 0.5 ? .acPower : .batteryPower) : nil
            let latest = bucket.indices.last { livePoints[$0].powerSource == source } ?? bucket.indices.last
            return GeekPowerBucketPayload(value: value, isCharging: latest.flatMap { livePoints[$0].isCharging },
                                          powerSource: source)
        }
        let firstRecorded = points.lazy.map(\.date).min() ?? .distantFuture
        let oldestFillable = buckets.firstIndex { $0.end > firstRecorded } ?? buckets.count
        let filled = GeekIStatBatteryGraph.filled(payloads, interval: interval, oldestFillable: oldestFillable)
        return buckets.indices.compactMap { index in
            filled[index].map { GeekPreparedPowerBucket(bucket: buckets[index], payload: $0.value, isEstimated: $0.isFill) }
        }
    }

    func valueRange(for values: [Double]) -> ClosedRange<Double> {
        switch metric {
        case .charge:
            return GeekPowerHistoryScale.chargeRange(values: values)
        case .batteryPower:
            let lower = min(0, (values.min() ?? 0) * 1.12)
            let upper = max(1, (values.max() ?? 1) * 1.12)
            return lower...(upper - lower < 0.5 ? lower + 1 : upper)
        }
    }

    var statistics: GeekSeriesStatistics? {
        guard let end = points.last?.date else { return nil }
        let selected = MenuBarHistoryRetention.selected(points, duration: duration, date: \.date, referenceDate: end)
        let key = metric == .charge ? "charge" : "batteryPower"
        let gaps = MenuBarSamplingGaps.shared.intervals(at: end)
        let records = selected.indices.compactMap { selected[$0].statistics(previous: $0 > 0 ? selected[$0 - 1] : nil, gaps: gaps).metrics[key] }
        return GeekSeriesStatistics(records: records, current: selected.last.flatMap { metric.value(in: $0) })
    }

    func bucketValue(
        _ indices: [Int],
        in points: [Point]
    ) -> Double? {
        let values = indices.map { points[$0].value }
        return switch metric {
        case .charge:
            TimeBucketAggregator.lastValid(values)
        case .batteryPower:
            TimeBucketAggregator.average(values)
        }
    }

}

struct GeekPreparedPowerFrame: Sendable {
    typealias Point = GeekPowerPreparationKernel.Point
    let points: [Point]
    let rawBuckets: [GeekChartBucketSnapshot]
    let buckets: [GeekPreparedPowerBucket]
    /// Whether `points` have a drawable trend, prepared here instead of on
    /// every redraw and hover move (review of phase 1, P2-1).
    let hasRenderableTrend: Bool
    init(kernel: GeekPowerPreparationKernel, plot: CGRect, reference: Date) {
        let points = kernel.usablePoints(endingAt: reference)
        self.points = points
        rawBuckets = kernel.batteryBuckets(points, plot: plot, referenceDate: reference)
        buckets = kernel.preparedBatteryBuckets(points, plot: plot, referenceDate: reference)
        hasRenderableTrend = PanelChartSampling.hasRenderableTrend(points.map {
            MenuBarChartSample(date: $0.date, value: $0.value)
        }) || kernel.points.contains { ($0.bucketStatistics?.metrics[kernel.metric == .charge ? "charge" : "batteryPower"]?.sampleCount ?? 0) >= 2 }
    }
}
