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

    func testOrderedAndUnorderedWindowsKeepStableTiesAndMeasuredWeights() throws {
        let start = end.addingTimeInterval(-6)
        for offsets in [[1.0, 3, 3, 5], [5.0, 3, 1, 3]] {
            let dates = offsets.map { start.addingTimeInterval($0) }
            let windows = GeekHistoryAveraging.windows(dates: dates, interval: 6,
                start: start, referenceDate: end,
                intervalStart: { dates[$0].addingTimeInterval(-offsets[$0]) })
            let window = try XCTUnwrap(windows.first)
            let expected = dates.indices.sorted {
                dates[$0] == dates[$1] ? $0 < $1 : dates[$0] < dates[$1]
            }
            XCTAssertEqual(window.indices, expected)
            XCTAssertEqual(window.weights, expected.map { offsets[$0] })
        }
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
        XCTAssertGreaterThanOrEqual(frame.downloadMaximum, displayedPeak)
        XCTAssertLessThan(frame.downloadMaximum, 10_000_000)
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

    func testPreparedLongCPUReusesCompleteBucketsWithoutChangingDisplayedMeans() throws {
        let start = end.addingTimeInterval(-3600)
        var points = (0..<3600).map { index in
            point(date: start.addingTimeInterval(Double(index) + 0.25),
                  value: index.isMultiple(of: 2) ? 10 : 90)
        }
        points[450] = .init(date: points[450].date, cpuTotal: nil, cpuUser: 7.5,
            cpuSystem: 2.5, gpu: nil, memory: nil, chipTemperature: nil, fanRPM: nil,
            downBytesPerSecond: nil, upBytesPerSecond: nil)
        let direct = GeekCPUHistoryFrame.prepare(points: points, plotRect: plot, duration: 3600,
            referenceDate: end, samplingInterval: 1, displayScale: 2)
        let prepared = GeekPreparedLineFrame(points: points, channels: [.cpuUser, .cpuSystem],
            plot: plot, duration: 3600, reference: end, samplingInterval: 1,
            scale: 2, stacked: true, valueRange: 0...100)
        let shared = try XCTUnwrap(prepared.cpu)
        XCTAssertEqual(shared.marks.count, direct.marks.count)
        for (actual, expected) in zip(shared.marks, direct.marks) {
            XCTAssertEqual(actual.bucket.x, expected.bucket.x)
            XCTAssertEqual(actual.mean.cpuUser!, expected.mean.cpuUser!, accuracy: 0.001)
            XCTAssertEqual(actual.mean.cpuSystem!, expected.mean.cpuSystem!, accuracy: 0.001)
            let bucketIndex = try XCTUnwrap(prepared.buckets.firstIndex { $0.x == actual.bucket.x })
            XCTAssertEqual(prepared.values[bucketIndex][0]!, expected.mean.cpuUser!, accuracy: 0.001)
            XCTAssertEqual(prepared.values[bucketIndex][1]!, expected.mean.cpuSystem!, accuracy: 0.001)
        }
        XCTAssertFalse(shared.marks.flatMap { $0.bucket.indices }.contains(450))
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

    // D114 (replaces the D113 rule): at this time a Date is finer than seconds
    // since 1970, so the Dates on either side of a boundary convert onto it.
    // Placement compares the Dates themselves. Windows are half-open,
    // [boundary, next boundary); only a counted observation exactly at a
    // boundary reference opens the new window. Before D113 the sample just
    // before a boundary reference trapped; D113 moved a sample at the boundary
    // into the window that ends there, and a reference just before a boundary
    // got an inverted window.
    func testDatesBesideABoundaryStayInTheirOwnHalfOpenWindows() {
        let b = Date(timeIntervalSince1970: 1_792_107_072)
        let ulp = 0x1p-23
        func step(_ date: Date, _ ulps: Int) -> Date {
            var time = date.timeIntervalSinceReferenceDate
            for _ in 0..<abs(ulps) { time = ulps < 0 ? time.nextDown : time.nextUp }
            return Date(timeIntervalSinceReferenceDate: time)
        }
        let below = step(b, -1), above = step(b, 1)
        XCTAssertEqual(b.timeIntervalSince(below), ulp)
        XCTAssertEqual(above.timeIntervalSince(b), ulp)
        for interval in [6.0, 18, 36, 72, 144, 432, 1008, 2016, 4032] {
            let title = "interval \(interval)"
            // Three boundaries: b0 starts the range, b1 is between, then b.
            let b0 = b.addingTimeInterval(-2 * interval), b1 = b.addingTimeInterval(-interval)
            for edge in [b0, b1, b] {
                XCTAssertEqual(step(edge, -1).timeIntervalSince1970, edge.timeIntervalSince1970, title)
                XCTAssertEqual(step(edge, 1).timeIntervalSince1970, edge.timeIntervalSince1970, title)
            }
            func windows(_ dates: [Date], reference: Date, from: Date? = nil, missing: Set<Int> = [],
                         gaps: [DateInterval] = [], measured: [Int: Date] = [:],
                         line: UInt = #line) -> (groups: [[Int]], weights: [[Double]]) {
                let start = from ?? b0
                let windows = GeekHistoryAveraging.windows(dates: dates, interval: interval, start: start,
                    referenceDate: reference, gaps: gaps, isMissing: { missing.contains($0) },
                    intervalStart: { measured[$0] })
                // Contiguous windows from start to the reference, none inverted.
                XCTAssertEqual(windows.first?.start, start, title, line: line)
                XCTAssertEqual(windows.last?.end, reference, title, line: line)
                XCTAssertTrue(windows.allSatisfy { $0.start <= $0.end }, title, line: line)
                XCTAssertTrue(zip(windows, windows.dropFirst()).allSatisfy { $0.end == $1.start }, title, line: line)
                // Every counted sample and nothing else: a point once, with
                // weight 1, in the window that holds its date; a measured span
                // in the windows it overlaps, its weights adding up to its
                // coverage inside the range.
                for (index, date) in dates.enumerated() {
                    let counted = date >= start && date <= reference && !missing.contains(index)
                        && !gaps.contains { date >= $0.start && date < $0.end }
                    let entries: [(window: Int, weight: Double)] = windows.indices.flatMap { place in
                        zip(windows[place].indices, windows[place].weights).filter { $0.0 == index }.map { (place, $0.1) }
                    }
                    if !counted {
                        XCTAssertTrue(entries.isEmpty, title, line: line)
                    } else if let measuredStart = measured[index], max(start, measuredStart) < date {
                        let lower = max(start, measuredStart)
                        XCTAssertEqual(entries.map(\.weight).reduce(0, +), date.timeIntervalSince(lower), title, line: line)
                        XCTAssertTrue(entries.allSatisfy {
                            $0.weight > 0 && windows[$0.window].start < date && lower < windows[$0.window].end
                        }, title, line: line)
                    } else {
                        XCTAssertEqual(entries.map(\.weight), [1], title, line: line)
                        if let place = entries.first?.window {
                            let window = windows[place]
                            XCTAssertTrue(window.start <= date
                                && (date < window.end || place == windows.count - 1 && date == reference), title, line: line)
                        }
                    }
                }
                return (windows.map(\.indices), windows.map(\.weights))
            }

            // Each boundary with the Dates beside it, and one Date before the range.
            let dates = [b0, step(b0, 1), step(b1, -1), b1, step(b1, 1), below, b, above, step(b0, -1)]
            // The reference just before b, at b, just after b.
            XCTAssertEqual(windows(dates, reference: below).groups, [[0, 1, 2], [3, 4, 5]], title)
            XCTAssertEqual(windows(dates, reference: b).groups, [[0, 1, 2], [3, 4, 5], [6]], title)
            XCTAssertEqual(windows(dates, reference: above).groups, [[0, 1, 2], [3, 4, 5], [6, 7]], title)
            // No, a missing, or a paused observation at the reference.
            XCTAssertEqual(windows(Array(dates[0...4]), reference: below).groups, [[0, 1, 2], [3, 4]], title)
            XCTAssertEqual(windows(dates, reference: below, missing: [5]).groups, [[0, 1, 2], [3, 4]], title)
            XCTAssertEqual(windows(dates, reference: below, gaps: [DateInterval(start: below, end: b)]).groups,
                [[0, 1, 2], [3, 4]], title)
            XCTAssertEqual(windows(Array(dates[0...5]), reference: b).groups, [[0, 1, 2], [3, 4, 5]], title)
            XCTAssertEqual(windows(dates, reference: b, missing: [6]).groups, [[0, 1, 2], [3, 4, 5]], title)
            XCTAssertEqual(windows(dates, reference: b, gaps: [DateInterval(start: b, duration: 1)]).groups,
                [[0, 1, 2], [3, 4, 5]], title)
            XCTAssertEqual(windows(dates, reference: b, gaps: [DateInterval(start: b1, end: b)]).groups,
                [[0, 1, 2], [], [6]], title)
            XCTAssertEqual(windows(Array(dates[0...6]), reference: above).groups, [[0, 1, 2], [3, 4, 5], [6]], title)
            XCTAssertEqual(windows(Array(dates[0...5]), reference: above).groups, [[0, 1, 2], [3, 4, 5], []], title)
            XCTAssertEqual(windows(dates, reference: above, missing: [7]).groups, [[0, 1, 2], [3, 4, 5], [6]], title)
            XCTAssertEqual(windows(dates, reference: above, gaps: [DateInterval(start: b, duration: 1)]).groups,
                [[0, 1, 2], [3, 4, 5], []], title)
            // The cases of CODEX_D113_R6_RECHECK.
            XCTAssertEqual(windows([b, above], reference: above).groups, [[], [], [0, 1]], title)
            XCTAssertEqual(windows([below], reference: below).groups, [[], [0]], title)
            XCTAssertEqual(windows([below, b], reference: b).groups, [[], [0], [1]], title)
            XCTAssertEqual(windows([below], reference: b).groups, [[], [0]], title)
            // A start beside a boundary keeps its own window, however short.
            XCTAssertEqual(windows([step(b0, -1), b0, below], reference: b, from: step(b0, -1)).groups,
                [[0], [1], [2]], title)
            XCTAssertEqual(windows([b0, step(b0, 1)], reference: b, from: step(b0, 1)).groups, [[1], []], title)
            XCTAssertEqual(windows([below, b], reference: b, from: below).groups, [[0], [1]], title)

            // Measured spans: each window gets its part of [max(start, measured start), date).
            func measured(_ date: Date, from measuredStart: Date, reference: Date = b,
                          start: Date? = nil, line: UInt = #line) -> (groups: [[Int]], weights: [[Double]]) {
                windows([date], reference: reference, from: start, measured: [0: measuredStart], line: line)
            }
            var result = measured(b1.addingTimeInterval(0.25), from: b1.addingTimeInterval(-0.5))
            XCTAssertEqual(result.groups, [[0], [0]], title)
            XCTAssertEqual(result.weights, [[0.5], [0.25]], title)
            result = measured(b1.addingTimeInterval(1), from: step(b1, -1))
            XCTAssertEqual(result.groups, [[0], [0]], title)
            XCTAssertEqual(result.weights, [[ulp], [1]], title)
            result = measured(step(b1, 1), from: b1.addingTimeInterval(-1))
            XCTAssertEqual(result.groups, [[0], [0]], title)
            XCTAssertEqual(result.weights, [[1], [ulp]], title)
            result = measured(b1, from: b1.addingTimeInterval(-1))
            XCTAssertEqual(result.groups, [[0], []], title)
            XCTAssertEqual(result.weights, [[1], []], title)
            result = measured(b1.addingTimeInterval(1), from: b1)
            XCTAssertEqual(result.groups, [[], [0]], title)
            XCTAssertEqual(result.weights, [[], [1]], title)
            // At the reference: an observation at b opens the new window, but
            // its span lies in the window before.
            result = measured(b, from: b.addingTimeInterval(-1))
            XCTAssertEqual(result.groups, [[], [0], []], title)
            XCTAssertEqual(result.weights, [[], [1], []], title)
            result = measured(b, from: b.addingTimeInterval(-1), reference: above)
            XCTAssertEqual(result.groups, [[], [0], []], title)
            XCTAssertEqual(result.weights, [[], [1], []], title)
            result = measured(above, from: below, reference: above)
            XCTAssertEqual(result.groups, [[], [0], [0]], title)
            XCTAssertEqual(result.weights, [[], [ulp], [ulp]], title)
            result = measured(above, from: b.addingTimeInterval(-1), reference: above)
            XCTAssertEqual(result.groups, [[], [0], [0]], title)
            XCTAssertEqual(result.weights, [[], [1], [ulp]], title)
            result = measured(below, from: b.addingTimeInterval(-1), reference: below)
            XCTAssertEqual(result.groups, [[], [0]], title)
            XCTAssertEqual(result.weights, [[], [1 - ulp]], title)
            result = windows([below, b], reference: b, measured: [1: below])
            XCTAssertEqual(result.groups, [[], [0, 1], []], title)
            XCTAssertEqual(result.weights, [[], [1, ulp], []], title)
            result = windows([below, b], reference: b, measured: [1: b.addingTimeInterval(-0.5)])
            XCTAssertEqual(result.groups, [[], [0, 1], []], title)
            XCTAssertEqual(result.weights, [[], [1, 0.5], []], title)
            // At the start: a span is cut at start; with nothing after start
            // the sample counts as one observation at its own time.
            result = measured(b0.addingTimeInterval(0.5), from: b0.addingTimeInterval(-0.5))
            XCTAssertEqual(result.groups, [[0], []], title)
            XCTAssertEqual(result.weights, [[0.5], []], title)
            result = measured(b0, from: b0.addingTimeInterval(-1))
            XCTAssertEqual(result.groups, [[0], []], title)
            XCTAssertEqual(result.weights, [[1], []], title)
            let later = b0.addingTimeInterval(0.5)
            result = measured(later, from: later.addingTimeInterval(-1), start: later)
            XCTAssertEqual(result.groups, [[0], []], title)
            XCTAssertEqual(result.weights, [[1], []], title)
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
