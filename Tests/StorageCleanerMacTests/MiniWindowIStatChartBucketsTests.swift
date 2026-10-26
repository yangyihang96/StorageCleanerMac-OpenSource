import CoreGraphics
import XCTest
@testable import StorageCleanerMac

/// D130, D131 (R8c): iStat Menus 7.30's two kinds of graphs. A history
/// (level three, `BBRMenu…HistoryGraphSection drawRect:`) draws 120 closed
/// buckets (T − iv, T] of its window's tier, the ends multiples of iv since
/// 1970, the newest at the right; a bucket without samples stays empty and
/// the bucket still collecting samples is not drawn. A menu graph (levels one
/// and two) draws one bar per sample of the module's 1000-sample ring, the
/// newest at the right, whatever time separates the samples. Neither
/// estimates a missing bar, fills a gap or eases its scale, and a recorded
/// zero is a 1 pt bar. Geometry and fixtures only: no sampling, window or
/// user data.
final class MiniWindowIStatChartBucketsTests: XCTestCase {
    private static let scale: CGFloat = 2
    /// iStat's 375 pt card less 8 pt each side: exactly 120 bars of 3 pt.
    private static let plot = CGRect(x: 0, y: 0, width: 359, height: 100)
    /// A multiple of every tier's interval (their least common multiple is
    /// 151 200 s), so the newest closed bucket of a reference at `t0` ends at
    /// `t0`.
    private static let t0: TimeInterval = 11_905 * 151_200

    private static func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: t0 + offset)
    }

    // MARK: - D130: level three

    func testEachWindowHasIStatsSecondsPerBar() {
        XCTAssertEqual(GeekChartWindow.barSlotCount(in: Self.plot, displayScale: Self.scale), 120)
        XCTAssertEqual(GeekIStatHistoryBuckets.slotCount, 120)
        XCTAssertEqual(GeekIStatHistoryBuckets.batterySlotCount, 96)
        XCTAssertEqual(GeekChartRange.allCases.map { GeekIStatHistoryBuckets.interval(for: $0.duration) },
                       [5, 30, 90, 180, 360, 720, 2_160, 5_040, 10_080, 21_600], "loadTimePopup")
        for range in GeekChartRange.allCases where range != .twentyEightDays {
            XCTAssertEqual(GeekIStatHistoryBuckets.interval(for: range.duration) * 120, range.duration, "\(range)")
        }
        XCTAssertEqual(GeekIStatHistoryBuckets.interval(for: GeekChartRange.twentyEightDays.duration) * 120,
                       30 * 86_400, "iStat's 28 days spans 30")
        // Any other window: whole seconds per bar, at least one.
        XCTAssertEqual(GeekIStatHistoryBuckets.interval(for: 1_200), 10)
        XCTAssertEqual(GeekIStatHistoryBuckets.interval(for: 30), 1)
        for t0Multiple in GeekChartRange.allCases.map({ GeekIStatHistoryBuckets.interval(for: $0.duration) }) {
            XCTAssertEqual(Self.t0.truncatingRemainder(dividingBy: t0Multiple), 0, "fixture: \(t0Multiple)")
        }
    }

    func testBucketsEndOnMultiplesOfTheIntervalAndTheOpenBucketIsNotDrawn() throws {
        let interval: TimeInterval = 30
        let dates = [-45, -30, -29.5, 0, 5].map(Self.date)
        // 17 s into the bucket that ends at t0 + 30.
        let buckets = GeekIStatHistoryBuckets.buckets(dates: dates, interval: interval, plotRect: Self.plot,
                                                      referenceDate: Self.date(17), displayScale: Self.scale)
        XCTAssertEqual(buckets.count, 120)
        let newest = try XCTUnwrap(buckets.last)
        XCTAssertEqual(newest.end, Self.date(0), "T0 = floor(now / iv) · iv")
        XCTAssertEqual(newest.start, Self.date(-interval))
        XCTAssertEqual(newest.indices, [2, 3], "(T − iv, T]: a sample at T is in the bucket that ends at T")
        XCTAssertEqual(buckets[118].indices, [0, 1], "a sample at T − iv is in the bucket before")
        XCTAssertFalse(buckets.contains { $0.indices.contains(4) }, "the bucket still collecting is not drawn")
        XCTAssertEqual(buckets.first?.end, Self.date(-119 * interval))
        for (older, newer) in zip(buckets, buckets.dropFirst()) {
            XCTAssertEqual(newer.start, older.end)
            XCTAssertEqual(newer.end.timeIntervalSince(older.end), interval)
        }
        XCTAssertTrue(buckets.allSatisfy { $0.averagingInterval == interval && $0.averagingGroups?.count == 1 })

        // A reference exactly on a boundary closes that bucket.
        let onBoundary = GeekIStatHistoryBuckets.buckets(dates: dates, interval: interval, plotRect: Self.plot,
                                                         referenceDate: Self.date(30), displayScale: Self.scale)
        XCTAssertEqual(onBoundary.last?.end, Self.date(30))
        XCTAssertEqual(onBoundary.last?.indices, [4])
        XCTAssertEqual(GeekIStatHistoryBuckets.newestClosedKey(at: Self.date(29.999), interval: interval),
                       GeekIStatHistoryBuckets.newestClosedKey(at: Self.date(0), interval: interval))
        XCTAssertEqual(GeekIStatHistoryBuckets.endKey(containing: Self.date(0), interval: interval),
                       GeekIStatHistoryBuckets.endKey(containing: Self.date(-29.999), interval: interval))
    }

    func testABucketWithoutSamplesStaysEmpty() {
        let interval: TimeInterval = 30
        let dates = [-100, -10].map(Self.date)
        let buckets = GeekIStatHistoryBuckets.buckets(dates: dates, interval: interval, plotRect: Self.plot,
                                                      referenceDate: Self.date(0), displayScale: Self.scale)
        XCTAssertEqual(buckets.indices.filter { !buckets[$0].indices.isEmpty }, [116, 119])
        XCTAssertNil(buckets[117].mean { _ in 1 }, "no value, not zero")
        XCTAssertNil(buckets[0].mean { _ in 1 })

        // A known pause, a missing reading and a point that stands for no
        // sample are not part of any bucket.
        let skipped = GeekIStatHistoryBuckets.buckets(
            dates: [-100, -50, -10, -5].map(Self.date), interval: interval, plotRect: Self.plot,
            referenceDate: Self.date(0), displayScale: Self.scale,
            gaps: [DateInterval(start: Self.date(-20), end: Self.date(-8))],
            isMissing: { $0 == 0 }, weight: { $0 == 1 ? 0 : 1 })
        XCTAssertEqual(skipped.flatMap(\.indices), [3])
        let unweighted = GeekIStatHistoryBuckets.buckets(
            dates: [Self.date(-5)], interval: interval, plotRect: Self.plot, referenceDate: Self.date(0),
            displayScale: Self.scale, weight: { _ in .nan })
        XCTAssertTrue(unweighted.allSatisfy(\.indices.isEmpty))
    }

    func testTheNewestBucketsFillTheRightOfANarrowPlot() {
        let interval: TimeInterval = 5
        let dates = (0..<120).map { Self.date(-5 * Double(119 - $0)) }
        let full = GeekIStatHistoryBuckets.buckets(dates: dates, interval: interval, plotRect: Self.plot,
                                                   referenceDate: Self.date(0), displayScale: Self.scale)
        XCTAssertEqual(full.map(\.indices), dates.indices.map { [$0] })
        XCTAssertEqual(full.map(\.x), (0..<120).map {
            GeekChartWindow.barX(forSlot: $0, in: Self.plot, displayScale: Self.scale)
        })
        XCTAssertEqual(full[1].x - full[0].x, 3, "2 pt bars, 1 pt apart")

        let narrow = CGRect(x: 0, y: 0, width: 149, height: 100)
        let slots = GeekChartWindow.barSlotCount(in: narrow, displayScale: Self.scale)
        XCTAssertEqual(slots, 50)
        let shown = GeekIStatHistoryBuckets.buckets(dates: dates, interval: interval, plotRect: narrow,
                                                    referenceDate: Self.date(0), displayScale: Self.scale)
        XCTAssertEqual(shown.count, 50)
        XCTAssertEqual(shown.map(\.indices), (70..<120).map { [$0] }, "the newest 50")
        XCTAssertEqual(shown.last?.x, GeekChartWindow.barX(forSlot: 49, in: narrow, displayScale: Self.scale))

        // Fewer bars than the plot has room for (the battery's 96) end at its
        // trailing edge.
        let battery = GeekIStatHistoryBuckets.buckets(dates: dates, interval: interval,
            count: GeekIStatHistoryBuckets.batterySlotCount, plotRect: Self.plot,
            referenceDate: Self.date(0), displayScale: Self.scale)
        XCTAssertEqual(battery.count, 96)
        XCTAssertEqual(battery.first?.x, GeekChartWindow.barX(forSlot: 24, in: Self.plot, displayScale: Self.scale))
        XCTAssertEqual(battery.last?.x, full.last?.x)
        XCTAssertTrue(GeekIStatHistoryBuckets.buckets(dates: dates, interval: interval, count: 0, plotRect: Self.plot,
                                                      referenceDate: Self.date(0), displayScale: Self.scale).isEmpty)
    }

    func testABucketIsTheMeanOfItsSamplesAndAFoldedMinuteCountsEachOfItsSamples() throws {
        let interval: TimeInterval = 30
        let buckets = GeekIStatHistoryBuckets.buckets(dates: [-20, -10].map(Self.date), interval: interval,
            plotRect: Self.plot, referenceDate: Self.date(0), displayScale: Self.scale,
            weight: { $0 == 0 ? 30 : 1 })
        let newest = try XCTUnwrap(buckets.last)
        XCTAssertEqual(newest.averagingWeights, [[30, 1]])
        XCTAssertEqual(try XCTUnwrap(newest.mean { [10, 100][$0] }), 400.0 / 31, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(newest.displayValue { [10, 100][$0] }), 400.0 / 31, accuracy: 1e-9,
                       "a history shows the mean, not the last sample")

        // Through the prepared frame: a folded minute of 30 samples at 10 %
        // and one raw sample at 100 % share a 1 h window's 30 s bucket.
        var minute = Self.point(at: -20, memory: 10)
        minute.bucketStatistics = MenuBarHistoryStatistics(metrics: ["memory": Self.folded(10, count: 30, end: Self.date(-20))])
        let frame = GeekPreparedLineFrame(points: [minute, Self.point(at: -10, memory: 100)], channels: [.memory],
            plot: Self.plot, duration: 3_600, reference: Self.date(0), samplingInterval: 1, scale: Self.scale,
            stacked: true, valueRange: 0...100, unrecordedIntervals: [], bucketing: .history)
        XCTAssertEqual(frame.buckets.count, 120)
        XCTAssertEqual(try XCTUnwrap(frame.values.last?.first ?? nil), 400.0 / 31, accuracy: 1e-9)
        XCTAssertEqual(frame.range.end, Self.date(0))
        XCTAssertEqual(frame.range.start, Self.date(-120 * interval))
    }

    func testAHistoryNeitherEstimatesNorFillsAMissingBucket() throws {
        let points = [Self.point(at: -600, memory: 20), Self.point(at: -10, memory: 80)]
        let history = GeekPreparedLineFrame(points: points, channels: [.memory], plot: Self.plot,
            duration: 3_600, reference: Self.date(0), samplingInterval: 1, scale: Self.scale, stacked: true,
            valueRange: 0...100, unrecordedIntervals: [], bucketing: .history)
        let filled = history.values.indices.filter { (history.values[$0].first ?? nil) != nil }
        XCTAssertEqual(filled, [99, 119])
        XCTAssertNil(history.hoverValues[110].first ?? nil, "an empty bucket has no tooltip value")
        XCTAssertFalse(history.hoverEstimated.joined().contains(true))
        XCTAssertFalse(history.buckets.contains(where: \.isEstimated))
        XCTAssertNil(history.cpu)

        // Network: one bucket's mean, no estimate; a recorded zero is a bar.
        let rates = [(-25.0, Int64(100)), (-10, 300), (-200, 0)].map { offset, rate in
            MenuBarTelemetryPoint(date: Self.date(offset), cpuTotal: nil, cpuUser: nil, cpuSystem: nil, gpu: nil,
                                  memory: nil, chipTemperature: nil, fanRPM: nil,
                                  downBytesPerSecond: rate, upBytesPerSecond: rate)
        }.sorted { $0.date < $1.date }
        let network = GeekPreparedNetworkFrame(history: GeekNetworkHistorySnapshot(points: rates),
            plotRect: Self.plot, duration: 3_600, referenceDate: Self.date(0), displayScale: Self.scale,
            bucketing: .history)
        XCTAssertEqual(network.buckets.count, 120)
        XCTAssertEqual(network.downloadMarks.map(\.value), [0, 200])
        XCTAssertFalse(network.downloadMarks.contains(where: \.isEstimated) || network.uploadMarks.contains(where: \.isEstimated))
    }

    // MARK: - D131: levels one and two

    func testAMenuGraphDrawsOneBarPerSampleNewestAtTheRight() {
        let dates = [-7_200, -3_600, -2, -1, 0].map(Self.date)
        let bars = GeekIStatSampleBars.buckets(dates: dates, plotRect: Self.plot, displayScale: Self.scale,
                                               referenceDate: Self.date(0), isSample: { _ in true })
        XCTAssertEqual(bars.count, 120)
        XCTAssertEqual(bars.suffix(5).map(\.indices), [[0], [1], [2], [3], [4]], "an hour apart or a second apart: adjacent")
        XCTAssertTrue(bars.prefix(115).allSatisfy(\.indices.isEmpty))
        XCTAssertEqual(bars.map(\.x), (0..<120).map {
            GeekChartWindow.barX(forSlot: $0, in: Self.plot, displayScale: Self.scale)
        })
        XCTAssertEqual(bars.last?.start, Self.date(0))
        XCTAssertEqual(bars.last?.end, Self.date(0))
        XCTAssertNil(bars.last?.averagingGroups, "a bar is its sample")

        // Not a sample (a folded minute, a missing reading), a sample after
        // now, or out of order.
        let picked = GeekIStatSampleBars.buckets(dates: dates + [Self.date(10)], plotRect: Self.plot,
            displayScale: Self.scale, referenceDate: Self.date(0), isSample: { $0 != 1 })
        XCTAssertEqual(picked.filter { !$0.indices.isEmpty }.map(\.indices), [[0], [2], [3], [4]])
        let unordered = GeekIStatSampleBars.buckets(dates: [Self.date(0), Self.date(-1)], plotRect: Self.plot,
            displayScale: Self.scale, referenceDate: Self.date(0), isSample: { _ in true })
        XCTAssertEqual(unordered.suffix(2).map(\.indices), [[1], [0]])
        XCTAssertTrue(GeekIStatSampleBars.buckets(dates: dates, plotRect: .zero, displayScale: Self.scale,
                                                  isSample: { _ in true }).isEmpty)
    }

    func testAMenuGraphShowsAtMostItsRingOfOneThousandSamples() {
        XCTAssertEqual(GeekIStatSampleBars.ringCapacity, 1_000)
        let wide = CGRect(x: 0, y: 0, width: 3_100, height: 100)
        XCTAssertGreaterThan(GeekChartWindow.barSlotCount(in: wide, displayScale: Self.scale), 1_000)
        let dates = (0..<1_100).map { Self.date(Double($0 - 1_099)) }
        let bars = GeekIStatSampleBars.buckets(dates: dates, plotRect: wide, displayScale: Self.scale,
                                               referenceDate: Self.date(0), isSample: { _ in true })
        let shown = bars.flatMap(\.indices)
        XCTAssertEqual(shown.count, 1_000)
        XCTAssertEqual(shown.first, 100)
        XCTAssertEqual(shown.last, 1_099)
    }

    func testAMenuGraphFrameDoesNotDependOnTheWindowOrFoldedMinutes() throws {
        var minute = Self.point(at: -120, memory: 10)
        minute.bucketStatistics = MenuBarHistoryStatistics(metrics: ["memory": Self.folded(10, count: 30, end: Self.date(-120))])
        let points = [minute] + [-3, -2, -1, 0].map { Self.point(at: $0, memory: 40 + $0) }
        func frame(_ duration: TimeInterval) -> GeekPreparedLineFrame {
            GeekPreparedLineFrame(points: points, channels: [.memory], plot: Self.plot, duration: duration,
                reference: Self.date(0), samplingInterval: 1, scale: Self.scale, stacked: true,
                valueRange: 0...100, unrecordedIntervals: [], bucketing: .samples)
        }
        let tenMinutes = frame(600), oneDay = frame(86_400)
        XCTAssertEqual(tenMinutes.buckets.map(\.indices), oneDay.buckets.map(\.indices))
        XCTAssertEqual(tenMinutes.values.compactMap { $0.first ?? nil }, [37, 38, 39, 40], "the folded minute is no bar")
        XCTAssertEqual(tenMinutes.range.start, Self.date(-3))
        XCTAssertEqual(tenMinutes.range.end, Self.date(0))
        XCTAssertFalse(tenMinutes.hoverEstimated.joined().contains(true))

        // Disk: the same rule.
        let disk = (0..<3).map { index in
            NativeDiskIOPoint(date: Self.date(Double(index) * 600 - 1_200), readBytesPerSecond: 1_000 * Int64(index + 1),
                              writeBytesPerSecond: 0, readOperationsPerSecond: 1, writeOperationsPerSecond: 0)
        }
        let diskFrame = GeekPreparedDiskFrame(points: disk, plot: Self.plot, duration: 3_600, reference: Self.date(0),
                                              scale: Self.scale, bucketing: .samples)
        XCTAssertEqual(diskFrame.readMarks.map(\.value), [1_000, 2_000, 3_000])
        XCTAssertEqual(diskFrame.writeMarks.map(\.value), [0, 0, 0], "a recorded zero is a bar")
        XCTAssertEqual(diskFrame.readMarks.last?.x, GeekChartWindow.barX(forSlot: 119, in: Self.plot, displayScale: Self.scale))
    }

    // MARK: - Drawing

    func testOnlyTheProjectionFillsGapsEasesItsScaleOrFollowsTheClock() {
        for bucketing: GeekChartBucketing in [.samples, .history] {
            XCTAssertFalse(bucketing.fillsGaps, "\(bucketing)")
            XCTAssertFalse(bucketing.easesScale, "\(bucketing)")
            XCTAssertTrue(bucketing.zeroIsBar, "\(bucketing)")
        }
        XCTAssertTrue(GeekChartBucketing.projection.fillsGaps)
        XCTAssertTrue(GeekChartBucketing.projection.easesScale)
        XCTAssertFalse(GeekChartBucketing.projection.zeroIsBar)
        XCTAssertEqual(GeekChartBucketing.projection.preparationTag, "", "the main window's keys are unchanged")
        XCTAssertNotEqual(GeekChartBucketing.samples.preparationTag, GeekChartBucketing.history.preparationTag)
        XCTAssertNil(GeekChartBucketing.samples.window(3_600))
        XCTAssertEqual(GeekChartBucketing.history.window(3_600), 3_600)
        XCTAssertEqual(GeekChartBucketing.projection.window(3_600), 3_600)

        // A history prepares again when a bucket closes, the sample bars only
        // for new samples, the projection every second.
        let history = { GeekChartBucketing.history.clockRevision(for: Self.date($0), duration: 3_600) }
        XCTAssertEqual(history(1), history(29.9))
        XCTAssertEqual(history(30), history(1) + 1)
        XCTAssertEqual(GeekChartBucketing.samples.clockRevision(for: Self.date(1), duration: 3_600),
                       GeekChartBucketing.samples.clockRevision(for: Self.date(5_000), duration: 3_600))
        XCTAssertEqual(GeekChartBucketing.projection.clockRevision(for: Self.date(1.5), duration: 3_600), Self.t0 + 1)

        // A recorded zero: iStat's 1 pt bar; the projection's hairline.
        let zero = GeekChartWindow.stackedBarRect(x: 10, width: 2, lower: 0, upper: 0, in: Self.plot,
                                                  range: 0...100, displayScale: Self.scale, zeroIsBar: true)
        XCTAssertEqual(zero.height, 1)
        XCTAssertEqual(zero.maxY, Self.plot.maxY)
        let hairline = GeekChartWindow.stackedBarRect(x: 10, width: 2, lower: 0, upper: 0, in: Self.plot,
                                                      range: 0...100, displayScale: Self.scale)
        XCTAssertEqual(hairline.height, 0.5)
    }

    func testEveryMiniWindowChartPicksIStatsBuckets() throws {
        // Each chart built by a mini-window page names its graph: level
        // three the history buckets, levels one and two the sample bars.
        let constructors = ["GeekPrecisionLineChart(", "GeekPrecisionNetworkChart(", "GeekDiskIOChart("]
        let expected: [(String, history: Int, samples: Int)] = [
            ("Views/MenuBarAdvanced/GeekHoverDetailTarget.swift", 8, 0),
            ("Views/MenuBarAdvanced/GeekMemoryCompositionView.swift", 1, 0),
            ("Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift", 2, 0),
            ("Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift", 2, 0),
            ("Views/MenuBarAdvanced/GeekOverviewPresentation.swift", 0, 2),
            ("Views/MenuBarAdvanced/GeekNetworkView.swift", 0, 1),
            ("Views/MenuBarAdvanced/GeekDiskView.swift", 0, 1),
            ("Support/PanelPaletteCatalog.swift", 0, 1),
        ]
        for (path, history, samples) in expected {
            let source = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/\(path)")
            let charts = constructors.reduce(0) { $0 + source.components(separatedBy: $1).count - 1 }
            XCTAssertEqual(source.components(separatedBy: "bucketing: .history").count - 1, history, path)
            XCTAssertEqual(source.components(separatedBy: "bucketing: .samples").count - 1, samples, path)
            XCTAssertEqual(charts, history + samples, "\(path): every chart names its graph")
        }
        // The main window keeps its projection.
        let main = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7PerformancePresentation.swift")
        XCTAssertTrue(main.contains("GeekPrecisionLineChart("))
        XCTAssertFalse(main.contains("bucketing:"))
        // A history draws iStat's empty buckets, so no gap block is named.
        let charts = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift")
        XCTAssertTrue(charts.contains("var showsGapLegend = false"))
    }

    // MARK: - Fixtures

    private static func point(at offset: TimeInterval, memory: Double) -> MenuBarTelemetryPoint {
        MenuBarTelemetryPoint(date: date(offset), cpuTotal: nil, cpuUser: nil, cpuSystem: nil, gpu: nil,
                              memory: memory, chipTemperature: nil, fanRPM: nil,
                              downBytesPerSecond: nil, upBytesPerSecond: nil)
    }

    /// `count` samples of `value`, one a second, the last at `end`.
    private static func folded(_ value: Double, count: Int, end: Date) -> MenuBarHistoryStatistic {
        func sample(_ index: Int) -> MenuBarHistoryStatistic {
            let date = end.addingTimeInterval(Double(index - count + 1))
            return MenuBarHistoryStatistic(value: value, date: date,
                                           coverage: [DateInterval(start: date.addingTimeInterval(-1), end: date)])
        }
        return (1..<count).reduce(sample(0)) { $0.merging(sample($1)) }
    }
}
