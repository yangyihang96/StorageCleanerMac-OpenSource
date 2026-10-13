import XCTest
@testable import StorageCleanerMac

/// Review of batch 4b, P2-7: history older than an hour keeps one sample per
/// minute, and the persisted history older than a day one sample per five
/// minutes. The newest sample of a bucket stands for it; the pressure level
/// of the bucket is the most severe system level recorded in it, so a short
/// elevated or high period survives compaction.
final class MiniWindowPressureHistoryCompactionTests: XCTestCase {
    /// Minute-aligned, `hoursAgo` hours before now.
    private static func bucketStart(hoursAgo: Double) -> Date {
        let date = Date().addingTimeInterval(-hoursAgo * 3_600)
        return Date(timeIntervalSinceReferenceDate: floor(date.timeIntervalSinceReferenceDate / 300) * 300)
    }

    private static func point(_ date: Date, code: Int?, percent: Double = 30) -> MenuBarTelemetryPoint {
        MenuBarTelemetryPoint(
            date: date, cpuTotal: nil, cpuUser: nil, cpuSystem: nil, gpu: nil, memory: 50,
            memoryPressure: percent, memoryPressureLevelCode: code,
            chipTemperature: nil, fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: nil
        )
    }

    /// A critical sample, then two normal ones in the same minute.
    private static func minute(at start: Date) -> [MenuBarTelemetryPoint] {
        [point(start, code: 4), point(start.addingTimeInterval(20), code: 1), point(start.addingTimeInterval(40), code: 1)]
    }

    private static func code(in points: [MenuBarTelemetryPoint], minuteOf start: Date) -> Int?? {
        let bucket = MenuBarHistoryRetention.minuteBucket(for: start)
        let matches = points.filter { MenuBarHistoryRetention.minuteBucket(for: $0.date) == bucket }
        guard matches.count == 1 else { return nil }
        return .some(matches[0].memoryPressureLevelCode)
    }

    func testTheLiveHistoryKeepsTheMostSevereLevelOfAMinute() throws {
        let start = Self.bucketStart(hoursAgo: 3)
        var history = MenuBarTelemetryHistory()
        for point in Self.minute(at: start) { history.append(point) }
        // A later sample moves the minute out of the high-resolution hour.
        history.append(Self.point(start.addingTimeInterval(2 * 3_600), code: 1))
        XCTAssertEqual(Self.code(in: history.points, minuteOf: start), .some(4),
                       "the newest sample stands for the minute with the minute's most severe level")

        // The same when older samples are restored into the history.
        var restored = MenuBarTelemetryHistory()
        restored.restore(Self.minute(at: start) + [Self.point(start.addingTimeInterval(2 * 3_600), code: 1)])
        XCTAssertEqual(Self.code(in: restored.points, minuteOf: start), .some(4))
    }

    func testTheRetainedArrayKeepsTheMostSevereLevelOfAMinute() {
        let start = Self.bucketStart(hoursAgo: 3)
        var points: [MenuBarTelemetryPoint] = []
        for point in Self.minute(at: start) + [Self.point(start.addingTimeInterval(2 * 3_600), code: 1)] {
            MenuBarHistoryRetention.append(point, to: &points, date: \.date)
        }
        XCTAssertEqual(Self.code(in: points, minuteOf: start), .some(4))
    }

    func testThePersistedHistoryKeepsTheMostSevereLevelOfEachBucket() {
        // Two days ago five-minute buckets, three hours ago minute buckets.
        let old = Self.bucketStart(hoursAgo: 48)
        let recent = Self.bucketStart(hoursAgo: 3)
        let oldBucket = [
            Self.point(old, code: 1),
            Self.point(old.addingTimeInterval(90), code: 2),
            Self.point(old.addingTimeInterval(200), code: 1),
        ]
        let now = Self.point(Date(), code: 1)
        let snapshot = MetricHistorySnapshot(
            telemetry: oldBucket + Self.minute(at: recent) + [now],
            memoryTelemetry: oldBucket + Self.minute(at: recent) + [now]
        )
        let persisted = MetricHistoryStore.checkpointSnapshot(snapshot, longRangeBucket: 5 * 60)
        for points in [persisted.telemetry, persisted.memoryTelemetry] {
            let old = points.filter { $0.date >= oldBucket[0].date && $0.date <= oldBucket[2].date }
            XCTAssertEqual(old.count, 1, "one sample stands for the five minutes")
            XCTAssertEqual(old.first?.memoryPressureLevelCode, 2, "the elevated sample of the bucket")
            XCTAssertEqual(old.first?.date, oldBucket[2].date, "the newest sample's values")
            XCTAssertEqual(Self.code(in: points, minuteOf: recent), .some(4))
        }
    }

    func testAMissingOrLowerNewerLevelKeepsTheOlderSystemLevel() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_020)
        let critical = Self.point(start, code: 4)
        // The newer sample has no system level and an estimate of normal.
        let merged = Self.point(start.addingTimeInterval(10), code: nil, percent: 40)
            .standingForBucket(replacing: critical)
        XCTAssertEqual(merged.memoryPressureLevelCode, 4)
        XCTAssertEqual(merged.memoryPressure, 40, "the newest sample's values stay")
        // A newer estimate that is at least as severe stays an estimate.
        let estimated = Self.point(start.addingTimeInterval(10), code: nil, percent: 96)
            .standingForBucket(replacing: critical)
        XCTAssertNil(estimated.memoryPressureLevelCode)
        XCTAssertEqual(estimated.memoryPressureLevel, .critical)
        // No recorded level in the older sample: nothing to keep.
        let plain = Self.point(start.addingTimeInterval(10), code: 1)
            .standingForBucket(replacing: Self.point(start, code: nil, percent: 99))
        XCTAssertEqual(plain.memoryPressureLevelCode, 1)
    }
}
