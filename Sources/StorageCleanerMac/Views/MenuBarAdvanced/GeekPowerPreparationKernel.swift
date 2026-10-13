import SwiftUI

struct GeekPowerPreparationKernel: Sendable {
    let points: [MenuBarPowerHistoryPoint]
    let metric: GeekPowerHistoryMetric
    let duration: TimeInterval
    let displayScale: CGFloat
    func usablePoints(endingAt referenceDate: Date) -> [(
        date: Date,
        value: Double,
        isCharging: Bool?,
        powerSource: BatteryPowerSource?
    )] {
        let end = referenceDate
        let start = end.addingTimeInterval(-duration)
        let latestAllowedDate = end.addingTimeInterval(
            GeekChartWindow.futureSampleTolerance
        )
        return points.compactMap { point in
            guard point.date >= start, point.date <= latestAllowedDate,
                  let value = metric == .charge ? metric.value(in: point)
                    : point.bucketStatistics?.metrics["batteryPower"]?.mean ?? metric.value(in: point),
                  value.isFinite else { return nil }
            return (
                min(point.date, end),
                value,
                point.isCharging,
                point.powerSource
            )
        }.sorted { $0.date < $1.date }
    }

    func batteryBuckets(
        _ livePoints: [(
            date: Date,
            value: Double,
            isCharging: Bool?,
            powerSource: BatteryPowerSource?
        )],
        plot: CGRect,
        referenceDate: Date
    ) -> [GeekChartBucketSnapshot] {
        let dates = livePoints.map(\.date)
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
        _ livePoints: [(
            date: Date,
            value: Double,
            isCharging: Bool?,
            powerSource: BatteryPowerSource?
        )],
        plot: CGRect,
        referenceDate: Date
    ) -> [GeekPreparedPowerBucket] {
        let buckets = batteryBuckets(
            livePoints,
            plot: plot,
            referenceDate: referenceDate
        )
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
        in points: [(date: Date, value: Double, isCharging: Bool?, powerSource: BatteryPowerSource?)]
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
    typealias Point = (date: Date, value: Double, isCharging: Bool?, powerSource: BatteryPowerSource?)
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
