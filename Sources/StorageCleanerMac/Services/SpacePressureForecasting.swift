import Foundation

struct StoragePressureSample: Equatable, Sendable {
    let recordedAt: Date
    let totalBytes: Int64
    let availableForImportantUsageBytes: Int64?
}

enum SpacePressureForecasting {
    private static let minimumSampleCount = 7
    private static let minimumSpanDays = 14
    private static let maximumSampleCount = 366
    private static let maximumTotalCapacityDrift = 0.05
    private static let minimumNegativePairFraction = 0.70
    private static let minimumDeclineBytesPerDay = 64.0 * 1_048_576
    private static let slopeMADScale = 1.4826
    private static let minimumPressureLineBytes = Int64(20) * 1_073_741_824
    private static let maximumLatestSampleAge: TimeInterval = 36 * 3_600

    static func evaluate(
        history: [ComputerHealthHistoryEntry],
        referenceDate: Date = Date()
    ) -> StoragePressureForecast? {
        evaluate(
            samples: history.compactMap { entry in
                guard entry.modelVersion == ComputerHealthHistoryEntry.currentModelVersion,
                      let totalBytes = entry.totalBytes else { return nil }
                return StoragePressureSample(
                    recordedAt: entry.recordedAt,
                    totalBytes: totalBytes,
                    availableForImportantUsageBytes: entry.availableForImportantUsageBytes
                )
            },
            referenceDate: referenceDate
        )
    }

    static func evaluate(
        samples rawSamples: [StoragePressureSample],
        referenceDate: Date = Date()
    ) -> StoragePressureForecast? {
        guard referenceDate.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let samples = distinctValidDailySamples(
            rawSamples,
            noLaterThan: referenceDate
        )
        guard samples.count >= minimumSampleCount,
              samples.count <= maximumSampleCount,
              let first = samples.first,
              let latest = samples.last else { return nil }
        let latestSampleAge = referenceDate.timeIntervalSince(latest.recordedAt)
        guard latestSampleAge.isFinite,
              latestSampleAge >= 0,
              latestSampleAge <= maximumLatestSampleAge else { return nil }

        let span = latest.recordedAt.timeIntervalSince(first.recordedAt) / 86_400
        guard span.isFinite,
              Int(floor(span + 0.000_000_1)) >= minimumSpanDays else { return nil }

        let totals = samples.map(\.totalBytes)
        guard let minimumTotal = totals.min(),
              let maximumTotal = totals.max(),
              maximumTotal > 0 else { return nil }
        let capacityDrift = Double(maximumTotal - minimumTotal) / Double(maximumTotal)
        guard capacityDrift.isFinite,
              capacityDrift <= maximumTotalCapacityDrift else { return nil }

        let trendSamples = samples.compactMap { sample -> RobustTrendSample? in
            guard let available = sample.availableForImportantUsageBytes else { return nil }
            return RobustTrendSample(
                recordedAt: sample.recordedAt,
                value: Double(available)
            )
        }
        guard trendSamples.count == samples.count,
              let estimate = RobustTrendStatistics.theilSen(samples: trendSamples),
              estimate.sampleCount == samples.count,
              estimate.spanDays >= minimumSpanDays,
              estimate.negativePairFraction >= minimumNegativePairFraction else { return nil }

        let robustSlopeRange = slopeMADScale * estimate.slopeMAD
        let slope = estimate.slopePerDay
        guard robustSlopeRange.isFinite,
              robustSlopeRange >= 0,
              -slope > max(minimumDeclineBytesPerDay, robustSlopeRange),
              slope + robustSlopeRange < -minimumDeclineBytesPerDay else { return nil }

        let fifteenPercent = Int64(Double(latest.totalBytes) * 0.15)
        let pressureLine = max(fifteenPercent, minimumPressureLineBytes)
        guard let latestAvailable = latest.availableForImportantUsageBytes else { return nil }

        if latestAvailable <= pressureLine {
            return StoragePressureForecast(
                dailyAvailableByteSlope: slope,
                slopeMAD: estimate.slopeMAD,
                pressureLineBytes: pressureLine,
                daysUntilPressure: 0,
                earliestDaysUntilPressure: 0,
                latestDaysUntilPressure: 0,
                sampleCount: estimate.sampleCount,
                spanDays: estimate.spanDays,
                evaluatedAt: referenceDate
            )
        }

        let distance = Double(latestAvailable - pressureLine)
        let centralRate = -slope
        let fastestRate = -(slope - robustSlopeRange)
        let slowestRate = -(slope + robustSlopeRange)
        guard distance.isFinite,
              distance > 0,
              let centralDays = dayCount(distance: distance, rate: centralRate, rounding: .up),
              let earliestDays = dayCount(distance: distance, rate: fastestRate, rounding: .down),
              let latestDays = dayCount(distance: distance, rate: slowestRate, rounding: .up) else {
            return nil
        }

        return StoragePressureForecast(
            dailyAvailableByteSlope: slope,
            slopeMAD: estimate.slopeMAD,
            pressureLineBytes: pressureLine,
            daysUntilPressure: centralDays,
            earliestDaysUntilPressure: min(earliestDays, centralDays),
            latestDaysUntilPressure: max(latestDays, centralDays),
            sampleCount: estimate.sampleCount,
            spanDays: estimate.spanDays,
            evaluatedAt: referenceDate
        )
    }

    private static func distinctValidDailySamples(
        _ samples: [StoragePressureSample],
        noLaterThan referenceDate: Date
    ) -> [StoragePressureSample] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var latestByDay: [Date: StoragePressureSample] = [:]

        for sample in samples {
            guard sample.recordedAt.timeIntervalSinceReferenceDate.isFinite,
                  sample.recordedAt <= referenceDate,
                  sample.totalBytes > 0,
                  let available = sample.availableForImportantUsageBytes,
                  available >= 0,
                  available <= sample.totalBytes else { continue }
            let day = calendar.startOfDay(for: sample.recordedAt)
            if let existing = latestByDay[day],
               existing.recordedAt > sample.recordedAt
            {
                continue
            }
            latestByDay[day] = sample
        }

        return latestByDay.values.sorted { $0.recordedAt < $1.recordedAt }
    }

    private static func dayCount(
        distance: Double,
        rate: Double,
        rounding: FloatingPointRoundingRule
    ) -> Int? {
        guard distance.isFinite,
              rate.isFinite,
              distance >= 0,
              rate > 0 else { return nil }
        let value = (distance / rate).rounded(rounding)
        guard value.isFinite,
              value >= 0,
              value <= Double(Int.max) else { return nil }
        return Int(value)
    }
}
