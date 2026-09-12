import XCTest
import SwiftUI
@testable import StorageCleanerMac

final class GeekHistoryAveragingTests: XCTestCase {
    private let end = Date(timeIntervalSince1970: 864_000)
    private let plot = CGRect(x: 0, y: 0, width: 360, height: 100)

    private func point(date: Date, value: Double) -> MenuBarTelemetryPoint {
        .init(date: date, cpuTotal: value, cpuUser: value * 0.75, cpuSystem: value * 0.25,
              gpu: nil, memory: value, chipTemperature: value, fanRPM: nil,
              downBytesPerSecond: Int64(value * 100), upBytesPerSecond: Int64(value * 10))
    }

    func testHourAndDayHave600FixedWindowsIndependentOfScreenWidth() {
        for (duration, interval) in [(3600.0, 6.0), (86400.0, 144.0)] {
            XCTAssertEqual(GeekHistoryAveraging.interval(for: duration), interval)
            let start = end.addingTimeInterval(-duration)
            let dates = (0..<600).map { start.addingTimeInterval(Double($0) * interval + 0.5) }
            let windows = GeekHistoryAveraging.windows(dates: dates, interval: interval, start: start, referenceDate: end)
            XCTAssertEqual(windows.count, 600)
            XCTAssertTrue(windows.allSatisfy { $0.end.timeIntervalSince($0.start) == interval && $0.indices.count == 1 })
        }
        XCTAssertNil(GeekHistoryAveraging.interval(for: 30))
        XCTAssertEqual(GeekHistoryAveraging.interval(for: 43200), 72)
        XCTAssertEqual(GeekHistoryAveraging.interval(for: 7 * 86400), 1008)
    }

    func testEveryLongRangeHasBoundedResolutionAndPreservesSamplesAndGaps() throws {
        let intervals: [Double] = [6, 18, 36, 72, 144, 432, 1008, 2016, 4032]
        let ranges = GeekChartRange.allCases.filter { $0.duration >= 3600 }
        XCTAssertEqual(ranges.count, intervals.count)
        for (range, interval) in zip(ranges, intervals) {
            XCTAssertEqual(GeekHistoryAveraging.interval(for: range.duration), interval)
            let alignedEnd = Date(timeIntervalSince1970: interval * 1000)
            let start = alignedEnd.addingTimeInterval(-range.duration)
            // Same number of observations per interval, with polling jitter.
            // The middle 100 intervals are a real recording interruption.
            let dates = (0..<600).filter { !(200..<300).contains($0) }.flatMap { offset in
                [0.2, 0.8].map { start.addingTimeInterval((Double(offset) + $0) * interval) }
            }
            let buckets = GeekChartWindow.displayBuckets(for: dates, in: plot,
                range: (start, alignedEnd, start), referenceDate: alignedEnd,
                displayScale: 2, unrecordedIntervals: [])
            XCTAssertEqual(buckets.count, 120, range.title)
            XCTAssertEqual(buckets.flatMap(\.indices).sorted(), Array(dates.indices), range.title)
            XCTAssertTrue(buckets[40..<60].allSatisfy { $0.mean { _ in 50 } == nil }, range.title)
            for bucket in buckets[0..<40] {
                XCTAssertEqual(try XCTUnwrap(bucket.mean { $0.isMultiple(of: 2) ? 10 : 90 }), 50, accuracy: 0.001)
                XCTAssertFalse(bucket.isEstimated)
            }
            for offset in [0.0, 0.3, interval * 0.8] {
                let reference = alignedEnd.addingTimeInterval(offset)
                let windows = GeekHistoryAveraging.windows(dates: dates, interval: interval,
                    start: reference.addingTimeInterval(-range.duration), referenceDate: reference)
                XCTAssertTrue((600...601).contains(windows.count), range.title)
            }
        }
        for duration in [Double.nan, .infinity, -1, 30, 60, 300, 600, 900, 29 * 86400] {
            XCTAssertNil(GeekHistoryAveraging.interval(for: duration))
        }
    }

    func testTenMinutePreferenceRoundTripsWithoutChangingOlderSelections() throws {
        for range in GeekChartRange.allCases {
            let restored = try JSONDecoder().decode(GeekChartRange.self, from: JSONEncoder().encode(range))
            XCTAssertEqual(restored.normalized, range)
        }
        XCTAssertEqual(GeekChartRange(rawValue: 600), .tenMinutes)
        XCTAssertEqual(GeekChartRange(rawValue: 120)?.normalized, .oneHour)
    }

    func testNetworkScaleFitsDisplayedAveragesWithoutExpandingToEveryRawSpike() throws {
        let start = end.addingTimeInterval(-3600)
        let points = (0..<3600).map { index in
            point(date: start.addingTimeInterval(Double(index) + 0.25), value: index == 1800 ? 100_000 : 10)
        }
        let frame = GeekPreparedNetworkFrame(history: .init(points: points), plotRect: plot,
            duration: 3600, referenceDate: end, displayScale: 2)
        let displayedPeak = try XCTUnwrap(frame.downloadMarks.map(\.value).max())
        XCTAssertGreaterThanOrEqual(frame.maximum, displayedPeak)
        XCTAssertLessThan(frame.maximum, 10_000_000)
        XCTAssertEqual(frame.downloadMarks.count, 120)
    }

    func testJitteredCPUAndNetworkHaveContinuousUniformBarsAndTrueMeans() {
        let start = end.addingTimeInterval(-3600)
        let points = (0..<3600).map { index in
            point(date: start.addingTimeInterval(Double(index) + (index.isMultiple(of: 2) ? 0.2 : 0.8)),
                  value: index.isMultiple(of: 2) ? 10 : 90)
        }
        let original = points
        for offset in [0.0, 0.1, 0.8, 1.2, 5.8] {
            let reference = end.addingTimeInterval(offset)
            let cpu = GeekCPUHistoryFrame.prepare(points: points, plotRect: plot, duration: 3600,
                referenceDate: reference, samplingInterval: 1, displayScale: 2)
            let network = GeekPreparedNetworkFrame(history: .init(points: points), plotRect: plot,
                duration: 3600, referenceDate: reference, displayScale: 2)
            XCTAssertEqual(cpu.marks.count, 120)
            XCTAssertEqual(network.downloadMarks.count, 120)
            XCTAssertEqual(Set(cpu.marks.map { $0.rect.width }).count, 1)
            XCTAssertFalse(cpu.marks.contains(where: \.isEstimated))
            // Interior complete bins are unaffected by redraw time and polling jitter.
            for mark in cpu.marks.dropFirst().dropLast() {
                XCTAssertEqual(mark.mean.cpuTotal!, 50, accuracy: 0.001)
                XCTAssertEqual(mark.peakTotal, 90)
            }
            for bucket in network.buckets.dropFirst().dropLast() {
                XCTAssertEqual(bucket.download!, 5000, accuracy: 0.001)
                XCTAssertEqual(bucket.upload!, 500, accuracy: 0.001)
            }
        }
        XCTAssertEqual(points, original)
    }

    func testGroupsAreAveragedBeforeScreenProjectionAndMissingIsNotZero() {
        let bucket = GeekChartBucketSnapshot(indices: [0, 1, 2, 3], x: 0, start: end, end: end,
            averagingGroups: [[0, 1, 2], [], [3]], averagingInterval: 6)
        let values: [Double?] = [10, 10, 10, 90]
        XCTAssertEqual(bucket.mean { values[$0] }, 50)
        XCTAssertEqual(bucket.displayValue { values[$0] }, 50)
        XCTAssertEqual(bucket.mean { _ in 0 }, 0)
        XCTAssertNil(bucket.mean { _ in Double.nan })
        XCTAssertNil(bucket.mean { _ in nil })
    }

    func testBoundarySampleNeverMovesBetweenAveragingWindowsAsClockAdvances() {
        let dates = [end.addingTimeInterval(-0.2), end, end.addingTimeInterval(0.2)]
        for offset in [0.0, 0.1, 0.5, 6.0] {
            let windows = GeekHistoryAveraging.windows(dates: dates, interval: 6,
                start: end.addingTimeInterval(-3600), referenceDate: end.addingTimeInterval(offset))
            let boundary = windows.first { $0.indices.contains(1) }
            XCTAssertEqual(boundary?.start, end)
            XCTAssertFalse(boundary?.indices.contains(0) ?? true)
            XCTAssertFalse(windows.flatMap(\.indices).contains(2) && offset < 0.2)
        }
    }

    func testSleepLongOutageAndStaleTailRemainEmptyWithoutMutatingHistory() {
        let start = end.addingTimeInterval(-3600)
        let dates = (0..<3600).filter { !(1200..<1800).contains($0) && $0 < 3300 }
            .map { start.addingTimeInterval(Double($0) + 0.25) }
        let gaps = [DateInterval(start: start.addingTimeInterval(2100), end: start.addingTimeInterval(2400))]
        let buckets = GeekChartWindow.displayBuckets(for: dates, in: plot,
            range: (start, end, start), referenceDate: end, displayScale: 2,
            unrecordedIntervals: gaps, holdLatestWhileFresh: true)
        XCTAssertTrue(buckets[40..<60].allSatisfy { $0.indices.isEmpty })
        XCTAssertTrue(buckets[70..<80].allSatisfy { $0.indices.isEmpty })
        XCTAssertTrue(buckets[110..<120].allSatisfy { $0.indices.isEmpty })
        XCTAssertTrue(buckets[0..<40].allSatisfy { !$0.indices.isEmpty })
        XCTAssertFalse(buckets.contains(where: \.isEstimated))
    }

    func testDayAveragesSparseExistingHistoryWithoutInventingObservations() {
        let start = end.addingTimeInterval(-86400)
        let dates = (0..<1440).map { start.addingTimeInterval(Double($0) * 60 + 0.25) }
        let buckets = GeekChartWindow.displayBuckets(for: dates, in: plot,
            range: (start, end, start), referenceDate: end, displayScale: 2, unrecordedIntervals: [])
        XCTAssertEqual(buckets.count, 120)
        XCTAssertEqual(buckets.flatMap(\.indices).count, dates.count)
        XCTAssertTrue(buckets.allSatisfy { $0.averagingInterval == 144 && $0.mean { _ in 64 } == 64 })
    }

    func testMeasuredDiskIntervalsFillTheirActualCoverageWithWeightedMeans() {
        let start = end.addingTimeInterval(-3600)
        let dates = (1...60).map { start.addingTimeInterval(Double($0) * 60) }
        let buckets = GeekChartWindow.displayBuckets(for: dates, in: plot,
            range: (start, end, start), referenceDate: end, displayScale: 2,
            intervalStart: { dates[$0].addingTimeInterval(-60) }, unrecordedIntervals: [])
        XCTAssertEqual(buckets.count, 120)
        XCTAssertTrue(buckets.allSatisfy { $0.mean { _ in 200 } == 200 && !$0.isEstimated })

        let readings = [start.addingTimeInterval(4), start.addingTimeInterval(6)]
        let weighted = GeekChartWindow.displayBuckets(for: readings,
            in: CGRect(x: 0, y: 0, width: 1800, height: 100),
            range: (start, end, start), referenceDate: end, displayScale: 2,
            intervalStart: { $0 == 0 ? start : readings[0] }, unrecordedIntervals: [])
        // 4 s at 100 B/s and 2 s at 400 B/s: 1200 bytes / 6 s = 200 B/s.
        XCTAssertEqual(weighted.first?.mean { $0 == 0 ? 100 : 400 }, 200)
        XCTAssertTrue(weighted.dropFirst().allSatisfy { $0.indices.isEmpty })
    }

    @MainActor
    func testMemoryChartAndHoverProjectionUseMeanInsteadOfLastSample() {
        let start = end.addingTimeInterval(-3600)
        let points = (0..<3600).map { index in
            point(date: start.addingTimeInterval(Double(index) + 0.25), value: index.isMultiple(of: 2) ? 10 : 90)
        }
        let chart = GeekPrecisionLineChart(points: points,
            series: [.init(id: "memory", title: "Memory", channel: .memory, color: .purple)],
            valueRange: 0...100, unit: .percent, accessibilityLabel: "Memory", style: .stackedBars, duration: 3600)
        let segments = chart.pointSegments(for: .memory, in: plot, valueRange: 0...100, referenceDate: end)
        XCTAssertEqual(segments.flatMap { $0 }.count, 120)
        XCTAssertTrue(segments.flatMap { $0 }.allSatisfy { abs($0.y - 50) < 0.001 })
    }
}
