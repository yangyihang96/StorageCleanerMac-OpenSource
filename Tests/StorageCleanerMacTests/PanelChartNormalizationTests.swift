import XCTest
import SwiftUI
@testable import StorageCleanerMac

final class PanelChartNormalizationTests: XCTestCase {
    func testCPUColumnsMatchForChronologicalAndOutOfOrderHistory() {
        let end = Date(timeIntervalSince1970: 100_000)
        let points = (-60...0).map {
            cpuPoint(date: end.addingTimeInterval(Double($0)), value: Double($0 + 60))
        }
        func frame(_ samples: [MenuBarTelemetryPoint]) -> GeekCPUHistoryFrame {
            GeekCPUHistoryFrame.prepare(
                points: samples, plotRect: CGRect(x: 0, y: 0, width: 280, height: 100),
                duration: 60, referenceDate: end, samplingInterval: 1, displayScale: 2
            )
        }
        let live = frame(points)
        let imported = frame(Array(points.reversed()))
        XCTAssertEqual(live.marks.map(\.rect), imported.marks.map(\.rect))
        XCTAssertEqual(live.marks.map(\.latest.date), imported.marks.map(\.latest.date))
        XCTAssertEqual(live.marks.map(\.peakTotal), imported.marks.map(\.peakTotal))
    }

    func testFixedColumnGeometryDoesNotChangeWithRangeOrPollingCadence() {
        let end = Date(timeIntervalSince1970: 100_000)
        let plot = CGRect(x: 0, y: 0, width: 360, height: 100)
        for scale in [CGFloat(1), CGFloat(2)] {
            for interval in [1.0, 2.0, 5.0] {
                let points = stride(from: -3600.0 - interval, through: 0, by: interval).map {
                    cpuPoint(date: end.addingTimeInterval($0), value: 25)
                }
                var expected: [CGRect]?
                for duration in [30.0, 60.0, 3600.0] {
                    let frame = GeekCPUHistoryFrame.prepare(points: points, plotRect: plot,
                        duration: duration, referenceDate: end, samplingInterval: interval, displayScale: scale)
                    XCTAssertEqual(frame.marks.count, 120)
                    if duration < 3600 {
                        XCTAssertEqual(frame.bucketDuration, duration / 120, accuracy: 0.000_001)
                    } else {
                        XCTAssertTrue(frame.marks.allSatisfy { $0.bucket.averagingInterval == 6 })
                        XCTAssertEqual(frame.marks.last?.bucket.end, end)
                    }
                    if let expected { XCTAssertEqual(frame.marks.map(\.rect), expected) }
                    expected = frame.marks.map(\.rect)
                    XCTAssertTrue(frame.marks.allSatisfy { abs(($0.mean.cpuTotal ?? 0) - 25) < 0.000_001 })
                    for (left, right) in zip(frame.marks, frame.marks.dropFirst()) {
                        XCTAssertEqual((right.rect.minX - left.rect.maxX) * scale, 1, accuracy: 0.000_001)
                    }
                }
            }
        }
    }

    func testCPUColumnHeightsKeepLowLoadAndZeroOnTheFixedHundredPercentScale() {
        let plot = CGRect(x: 0, y: 0, width: 280, height: 100)
        for scale in [CGFloat(1), CGFloat(2)] {
            for value in [0.0, 6, 10, 70, 90] {
                let rect = GeekChartWindow.stackedBarRect(x: 0, width: 4, lower: 0, upper: value,
                    in: plot, range: 0...100, displayScale: scale)
                XCTAssertEqual(rect.height, max(1 / scale, CGFloat(value)), accuracy: 0.000_001)
                XCTAssertEqual(rect.maxY, plot.maxY, accuracy: 0.000_001)
            }
        }
    }

    func testCPUNormalTimerJitterDoesNotChangeSlotsOrCreateHoles() {
        let end = Date(timeIntervalSince1970: 100_000)
        let points = (0...60).map { cpuPoint(date: end.addingTimeInterval(Double($0 - 60) * 1.08), value: 10) }
        let frame = GeekCPUHistoryFrame.prepare(points: points,
            plotRect: CGRect(x: 0, y: 0, width: 360, height: 100), duration: 60,
            referenceDate: end, samplingInterval: 1, displayScale: 2)
        XCTAssertEqual(frame.marks.count, 120)
        XCTAssertEqual(frame.bucketDuration, 0.5, accuracy: 0.000_001)
        XCTAssertTrue(frame.marks.allSatisfy { abs(($0.mean.cpuTotal ?? 0) - 10) < 0.000_001 })
    }

    func testCPUDeltaIntervalsAreWeightedAndRetainObservedPeak() throws {
        let end = Date(timeIntervalSince1970: 100_000)
        let points = [cpuPoint(date: end.addingTimeInterval(-3), value: 0),
                      cpuPoint(date: end.addingTimeInterval(-1.5), value: 20),
                      cpuPoint(date: end, value: 80)]
        // One display slot covers the final 2 s: 0.5 s at 20%, 1.5 s at 80%.
        let frame = GeekCPUHistoryFrame.prepare(points: points,
            plotRect: CGRect(x: 0, y: 0, width: 3, height: 100), duration: 2,
            referenceDate: end, samplingInterval: 1, displayScale: 1)
        let mark = try XCTUnwrap(frame.marks.first)
        XCTAssertEqual(try XCTUnwrap(mark.mean.cpuTotal), 65, accuracy: 0.000_001)
        XCTAssertEqual(mark.mean.cpuUser! + mark.mean.cpuSystem!, 65, accuracy: 0.000_001)
        XCTAssertEqual(mark.peakTotal, 80)
        XCTAssertEqual(mark.latest.date, end)
        XCTAssertEqual(frame.mark(at: mark.rect.midX)?.peak.date, end)
    }

    func testCPUOutageAndUnavailableSamplesDoNotExpandToNeighbouringSlots() {
        let end = Date(timeIntervalSince1970: 100_000)
        let plot = CGRect(x: 0, y: 0, width: 360, height: 100)
        let points = (-61...0).map { second in
            cpuPoint(date: end.addingTimeInterval(Double(second)), value: (-30 ... -21).contains(second) ? nil : 10)
        }
        let frame = GeekCPUHistoryFrame.prepare(points: points, plotRect: plot,
            duration: 60, referenceDate: end, samplingInterval: 1, displayScale: 1)
        XCTAssertNil(frame.mark(at: 211)) // t = -25 s inside the outage
        XCTAssertNotNil(frame.marks.first)
        let sparse = [-60.0, -30.0, 0.0].map { cpuPoint(date: end.addingTimeInterval($0), value: 0) }
        let sparseFrame = GeekCPUHistoryFrame.prepare(points: sparse, plotRect: plot,
            duration: 60, referenceDate: end, samplingInterval: 1, displayScale: 1)
        XCTAssertEqual(sparseFrame.marks.count, 3)
        XCTAssertTrue(sparseFrame.marks.allSatisfy { $0.rect.width == 2 && $0.mean.cpuTotal == 0 })
        XCTAssertNil(sparseFrame.mark(at: 91))
        XCTAssertNil(sparseFrame.mark(at: 271))
    }

    func testMemoryCompositionHistoryPreservesSnapshotAndDecodesOlderHistory() throws {
        let point = MenuBarTelemetryPoint(date: Date(timeIntervalSince1970: 1000),
            cpuTotal: nil, cpuUser: nil, cpuSystem: nil, gpu: nil, memory: 75,
            memoryAppOrOtherBytes: 4, memoryWiredBytes: 3, memoryPhysicalBytes: 12,
            compressedMemoryBytes: 2, chipTemperature: nil, fanRPM: nil,
            downBytesPerSecond: nil, upBytesPerSecond: nil)
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(point)
        XCTAssertEqual(try JSONDecoder().decode(MenuBarTelemetryPoint.self, from: encoded), point)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["memoryAppOrOtherBytes", "memoryWiredBytes", "memoryPhysicalBytes"] { old.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(MenuBarTelemetryPoint.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.memoryAppOrOtherBytes)
        XCTAssertEqual(decoded.compressedMemoryBytes, 2)
        XCTAssertEqual(point.replacingFanRPM(with: 1000).memoryWiredBytes, 3)
        XCTAssertEqual(point.replacingMemory(with: 75).memoryAppOrOtherBytes, 4)
        XCTAssertEqual([MenuBarTelemetryChannel.memoryAppOrOtherBytes, .memoryWiredBytes, .compressedMemoryBytes].compactMap { $0.value(in: point) }.reduce(0, +), 9)
    }

    func testShortSlotsHoldOnlyBetweenConsecutiveObservedReadings() {
        let end = Date(timeIntervalSince1970: 1000)
        let plot = CGRect(x: 0, y: 0, width: 360, height: 100)
        let dates = (-31...0).map { end.addingTimeInterval(Double($0)) }
        let range = (start: end.addingTimeInterval(-30), end: end, dataStart: dates[0])
        let buckets = GeekChartWindow.observedHoldBuckets(for: dates, in: plot, range: range,
            referenceDate: end, displayScale: 1)
        XCTAssertEqual(buckets.count, 120)
        XCTAssertTrue(buckets.allSatisfy { !$0.indices.isEmpty })
        let sparse = dates.filter { $0 < end.addingTimeInterval(-20) || $0 > end.addingTimeInterval(-10) }
        let withGap = GeekChartWindow.observedHoldBuckets(for: sparse, in: plot, range: range,
            referenceDate: end, displayScale: 1)
        XCTAssertTrue(withGap[60].indices.isEmpty)
        let stopped = GeekChartWindow.observedHoldBuckets(for: dates, in: plot,
            range: (start: end.addingTimeInterval(-25), end: end.addingTimeInterval(5), dataStart: dates[0]),
            referenceDate: end.addingTimeInterval(5), displayScale: 1)
        XCTAssertTrue(stopped.suffix(15).allSatisfy { $0.indices.isEmpty })
        XCTAssertEqual(dates.count, 32, "Display resampling must never insert history observations")
    }

    private func cpuPoint(date: Date, value: Double?) -> MenuBarTelemetryPoint {
        MenuBarTelemetryPoint(
            date: date, cpuTotal: value, cpuUser: value.map { $0 * 0.75 }, cpuSystem: value.map { $0 * 0.25 },
            gpu: nil, memory: nil, chipTemperature: nil, fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: nil
        )
    }

    func testHistoryFillReachesBaselineWithoutDiagonalWedgesOrBridgingMissingSegments() {
        let chart = memoryChart(samples: [], reference: Date(timeIntervalSince1970: 0))
        let area = chart.filledPath([
            [CGPoint(x: 0, y: 20), CGPoint(x: 40, y: 20)],
            [CGPoint(x: 60, y: 30), CGPoint(x: 100, y: 30)],
            [CGPoint(x: 120, y: 10)]
        ], baseline: 100)
        XCTAssertTrue(area.contains(CGPoint(x: 2, y: 95)))
        XCTAssertTrue(area.contains(CGPoint(x: 38, y: 95)))
        XCTAssertTrue(area.contains(CGPoint(x: 62, y: 95)))
        XCTAssertFalse(area.contains(CGPoint(x: 50, y: 80)))
        XCTAssertFalse(area.contains(CGPoint(x: 20, y: 10)))
        XCTAssertFalse(area.contains(CGPoint(x: 120, y: 80)))
    }

    func testShortHistoryRangesFilterRealDatesAndChangeBucketsAndStatisticsWithoutLosingPeaks() throws {
        let end = Date(timeIntervalSince1970: 100_000)
        var history = MenuBarTelemetryHistory()
        for (offset, value) in [(-290.0, 90.0), (-45.0, 20.0), (-5.0, 40.0)] {
            history.append(MenuBarTelemetryPoint(
                date: end.addingTimeInterval(offset), cpuTotal: value,
                cpuUser: value * 0.75, cpuSystem: value * 0.25,
                gpu: nil, memory: nil, chipTemperature: nil, fanRPM: nil,
                downBytesPerSecond: nil, upBytesPerSecond: nil
            ))
        }
        let original = history.points
        let minute = history.points(within: GeekChartRange.oneMinute.duration, referenceDate: end)
        let fiveMinutes = history.points(within: GeekChartRange.fiveMinutes.duration, referenceDate: end)
        XCTAssertEqual(minute.map(\.date), Array(original.suffix(2)).map(\.date))
        XCTAssertEqual(fiveMinutes, original)
        let shortStats = try XCTUnwrap(GeekSeriesStatistics(values: minute.compactMap(\.cpuTotal)))
        let longStats = try XCTUnwrap(GeekSeriesStatistics(values: fiveMinutes.compactMap(\.cpuTotal)))
        XCTAssertEqual(shortStats.average, 30)
        XCTAssertEqual(shortStats.maximum, 40)
        XCTAssertEqual(longStats.average, 50)
        XCTAssertEqual(longStats.maximum, 90)
        let plot = CGRect(x: 0, y: 0, width: 300, height: 120)
        let shortBucket = GeekChartWindow.barBucketDuration(duration: 60, in: plot)
        let longBucket = GeekChartWindow.barBucketDuration(duration: 300, in: plot)
        XCTAssertEqual(longBucket, shortBucket * 5, accuracy: 0.000_001)
        let buckets = GeekChartWindow.barBucketSnapshots(
            for: fiveMinutes.map(\.date), in: plot,
            range: GeekChartWindow.barRange(for: fiveMinutes.map(\.date), duration: 300, referenceDate: end),
            referenceDate: end
        )
        XCTAssertTrue(buckets.contains { $0.indices.isEmpty })
        for bucket in buckets {
            for index in bucket.indices {
                XCTAssertGreaterThanOrEqual(fiveMinutes[index].date, bucket.start)
                XCTAssertLessThanOrEqual(fiveMinutes[index].date, bucket.end)
            }
        }
        XCTAssertEqual(history.points, original)
    }

    @MainActor
    func testSharedClockScheduleStartSurvivesAdvance() {
        let clock = PanelChartClock()
        let scheduleStart = clock.scheduleStart

        clock.advance()

        XCTAssertEqual(clock.scheduleStart, scheduleStart)
    }

    @MainActor
    func testRealSampleAdvancesStaleLongRangeClockWithoutChangingTimerPolicy() {
        let continuous = ContinuousClock()
        let instant = continuous.now
        let start = Date(timeIntervalSinceReferenceDate: 100_000)
        let clock = PanelChartClock(anchor: PanelChartTimeAnchor(wallDate: start, instant: instant))
        let next = start.addingTimeInterval(20)
        let points = [cpuPoint(date: next, value: 70)]
        let plot = CGRect(x: 0, y: 0, width: 280, height: 100)
        let normal = ChartActivityPolicy(
            isPanelVisible: true, isDisplayAwake: true, isLowPowerModeEnabled: false,
            thermalState: .nominal, reduceMotion: false
        )
        let stoppedAnimation = ChartActivityPolicy(
            isPanelVisible: true, isDisplayAwake: true, isLowPowerModeEnabled: false,
            thermalState: .nominal, reduceMotion: true
        )
        XCTAssertEqual(normal.refreshInterval(for: 3600), 30)
        XCTAssertNil(stoppedAnimation.refreshInterval(for: 3600))
        XCTAssertTrue(GeekCPUHistoryFrame.prepare(
            points: points, plotRect: plot, duration: 300, referenceDate: clock.referenceDate,
            samplingInterval: 1, displayScale: 2
        ).marks.isEmpty)

        clock.receiveSampleDate(next, wallDate: next, instant: instant.advanced(by: .seconds(20)))

        XCTAssertEqual(GeekCPUHistoryFrame.prepare(
            points: points, plotRect: plot, duration: 300, referenceDate: clock.referenceDate,
            samplingInterval: 1, displayScale: 2
        ).marks.first?.latest.cpuTotal, 70)
        XCTAssertEqual(clock.scheduleStart, start)
        XCTAssertEqual(normal.refreshInterval(for: 3600), 30)
        XCTAssertNil(stoppedAnimation.refreshInterval(for: 3600))
        let published = clock.referenceDate
        clock.receiveSampleDate(nil, wallDate: next.addingTimeInterval(2))
        clock.receiveSampleDate(next, wallDate: next.addingTimeInterval(2))
        XCTAssertEqual(clock.referenceDate, published)
    }

    @MainActor
    func testSharedClockIgnoresNormalWallClockDrift() {
        let continuous = ContinuousClock()
        let instant = continuous.now
        let start = Date(timeIntervalSinceReferenceDate: 100_000)
        let clock = PanelChartClock(anchor: PanelChartTimeAnchor(
            wallDate: start,
            instant: instant
        ))

        clock.advance(
            wallDate: start.addingTimeInterval(5.5),
            instant: instant.advanced(by: .seconds(5))
        )

        XCTAssertEqual(clock.epoch, 0)
        XCTAssertNil(clock.lastEpochReason)
        XCTAssertEqual(
            clock.referenceDate.timeIntervalSinceReferenceDate,
            start.addingTimeInterval(5).timeIntervalSinceReferenceDate,
            accuracy: 0.001
        )
    }

    @MainActor
    func testSharedClockStartsNewEpochForForwardAndBackwardWallClockJumps() {
        let continuous = ContinuousClock()
        let instant = continuous.now
        let start = Date(timeIntervalSinceReferenceDate: 110_000)
        let clock = PanelChartClock(anchor: PanelChartTimeAnchor(
            wallDate: start,
            instant: instant
        ))

        clock.advance(
            wallDate: start.addingTimeInterval(3_600),
            instant: instant.advanced(by: .seconds(5))
        )
        XCTAssertEqual(clock.epoch, 1)
        XCTAssertEqual(clock.referenceDate, start.addingTimeInterval(3_600))
        guard case let .significantWallClockDrift(forwardDrift)? = clock.lastEpochReason else {
            return XCTFail("Expected a forward wall-clock epoch")
        }
        XCTAssertGreaterThan(forwardDrift, 3_500)

        let nextInstant = instant.advanced(by: .seconds(10))
        clock.advance(
            wallDate: start.addingTimeInterval(-300),
            instant: nextInstant
        )
        XCTAssertEqual(clock.epoch, 2)
        XCTAssertEqual(clock.referenceDate, start.addingTimeInterval(-300))
        guard case let .significantWallClockDrift(backwardDrift)? = clock.lastEpochReason else {
            return XCTFail("Expected a backward wall-clock epoch")
        }
        XCTAssertLessThan(backwardDrift, -300)
    }

    @MainActor
    func testSharedClockReanchorsAfterSleepWakeGapWithoutClearingHistory() {
        let continuous = ContinuousClock()
        let instant = continuous.now
        let start = Date(timeIntervalSinceReferenceDate: 120_000)
        let clock = PanelChartClock(anchor: PanelChartTimeAnchor(
            wallDate: start,
            instant: instant
        ))

        clock.advance(
            wallDate: start.addingTimeInterval(10),
            instant: instant.advanced(by: .seconds(10))
        )
        clock.advance(
            wallDate: start.addingTimeInterval(600),
            instant: instant.advanced(by: .seconds(10))
        )

        XCTAssertEqual(clock.epoch, 1)
        XCTAssertEqual(clock.referenceDate, start.addingTimeInterval(600))
    }

    func testRingBufferWrapsInOrderAndKeepsFixedCapacity() {
        var buffer = RingBuffer<Int>(capacity: 3)
        XCTAssertEqual(buffer.allocatedSlotCount, 0)
        XCTAssertNil(buffer.append(1))
        XCTAssertEqual(buffer.allocatedSlotCount, 1)
        XCTAssertNil(buffer.append(2))
        XCTAssertNil(buffer.append(3))
        XCTAssertEqual(buffer.allocatedSlotCount, 3)
        XCTAssertEqual(buffer.elements, [1, 2, 3])
        XCTAssertEqual(buffer.append(4), 1)
        XCTAssertEqual(buffer.elements, [2, 3, 4])
        XCTAssertEqual(buffer.capacity, 3)
        XCTAssertEqual(buffer.count, 3)
        buffer.replaceLast(with: 5)
        XCTAssertEqual(buffer.elements, [2, 3, 5])
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.capacity, 3)
    }

    func testRingBufferAllocatesOnlyForRealSamplesAndCanGrowAfterRemoval() {
        var buffer = RingBuffer<Int>(capacity: 40_323)
        XCTAssertEqual(buffer.allocatedSlotCount, 0)

        for value in 0..<8 {
            XCTAssertNil(buffer.append(value))
        }
        XCTAssertEqual(buffer.allocatedSlotCount, 8)

        buffer.removeFirst(3)
        XCTAssertEqual(buffer.elements, [3, 4, 5, 6, 7])
        for value in 8..<13 {
            XCTAssertNil(buffer.append(value))
        }

        XCTAssertEqual(buffer.elements, Array(3..<13))
        XCTAssertEqual(buffer.allocatedSlotCount, 10)
        XCTAssertEqual(buffer.capacity, 40_323)
    }

    func testPartiallyAllocatedRingKeepsOrderAcrossManyHeadWraps() {
        var buffer = RingBuffer<Int>(capacity: 17)
        for value in 0..<5 {
            XCTAssertNil(buffer.append(value))
        }

        for value in 5..<80 {
            buffer.removeFirst()
            XCTAssertNil(buffer.append(value))
            XCTAssertEqual(buffer.elements, Array((value - 4)...value))
        }

        XCTAssertEqual(buffer.allocatedSlotCount, 5)
    }

    func testSharedClockKeepsOneStablePeriodicSchedule() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/PanelChartTimeline.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("var scheduleStart: Date { anchor.wallDate }"))
        XCTAssertTrue(source.contains(
            ".periodic(from: sharedClock.scheduleStart, by: interval)"
        ))
        XCTAssertFalse(source.contains(".periodic(from: .now, by: interval)"))
    }

    func testCompactPanelDensityBudgetRemainsBounded() {
        XCTAssertEqual(PanelDensity.simple.idealSize, .init(width: 420, height: 280))
        XCTAssertEqual(PanelDensity.complex.idealSize, MiniWindowStyleTokens.overviewSize)
        XCTAssertEqual(PanelDensity.geek.idealSize, MiniWindowStyleTokens.overviewSize)
        XCTAssertEqual(PanelDensity.complex.minimumSize, PanelDensity.complex.idealSize)
        XCTAssertEqual(PanelDensity.geek.minimumSize, PanelDensity.geek.idealSize)
        XCTAssertEqual(PanelLayoutMetrics.navigationWidth, 44)
        XCTAssertLessThanOrEqual(GeekPanelLayout.moduleMinimumWidth, 220)
        XCTAssertLessThanOrEqual(GeekPanelLayout.metricMinimumHeight, 60)
        XCTAssertLessThanOrEqual(GeekPanelLayout.primaryChartHeight, 64)
        XCTAssertLessThanOrEqual(GeekPanelLayout.overviewChartHeight, 56)
    }

    func testTrendRequiresTwoFiniteSamples() {
        XCTAssertFalse(PanelChartSampling.hasRenderableTrend([] as [Double?]))
        XCTAssertFalse(PanelChartSampling.hasRenderableTrend([42.0] as [Double]))
        XCTAssertFalse(PanelChartSampling.hasRenderableTrend([nil, .nan, .infinity]))
        XCTAssertTrue(PanelChartSampling.hasRenderableTrend([0.0, 0.0] as [Double]))
        XCTAssertTrue(PanelChartSampling.hasRenderableTrend([nil, 1, 2]))
        XCTAssertFalse(PanelChartSampling.hasRenderableTrend([nil, 1, .nan, 2]))

        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(PanelChartSampling.hasRenderableTrend([
            MenuBarChartSample(date: start, value: 1),
            MenuBarChartSample(date: start.addingTimeInterval(1), value: 2)
        ]))
        XCTAssertTrue(PanelChartSampling.hasRenderableTrend([
            MenuBarChartSample(date: start, value: 1),
            MenuBarChartSample(
                date: start.addingTimeInterval(PanelChartSampling.minimumRenderableTimeSpan),
                value: 2
            )
        ]))
        XCTAssertTrue(PanelChartSampling.hasRenderableTrend([
            MenuBarChartSample(date: start, value: 1),
            MenuBarChartSample(date: start.addingTimeInterval(1), value: nil),
            MenuBarChartSample(date: start.addingTimeInterval(100), value: 2)
        ]))
    }

    func testBarChartsPreserveSamplesAcrossSamplingGap() {
        let start = Date(timeIntervalSince1970: 1_000)
        let dates = [
            start,
            start.addingTimeInterval(1),
            start.addingTimeInterval(30),
            start.addingTimeInterval(31)
        ]
        let plot = CGRect(x: 0, y: 0, width: 240, height: 54)
        let range = GeekChartWindow.barRange(for: dates, duration: 120)

        XCTAssertNotNil(GeekChartWindow.barX(for: dates[0], in: plot, range: range))
        XCTAssertNotNil(GeekChartWindow.barX(for: dates[2], in: plot, range: range))
        XCTAssertNotNil(GeekChartWindow.barX(for: dates[3], in: plot, range: range))
    }

    func testTimeBucketsKeepFixedSlotsAndUseMetricAppropriateAggregation() {
        let reference = Date(timeIntervalSinceReferenceDate: 15_000)
        let dates = [
            reference.addingTimeInterval(-2),
            reference.addingTimeInterval(-0.5),
            reference,
        ]
        let plot = CGRect(x: 0, y: 0, width: 240, height: 54)
        let range = GeekChartWindow.barRange(
            for: dates,
            duration: 120,
            referenceDate: reference
        )
        let buckets = GeekChartWindow.barBucketMarks(
            for: dates,
            in: plot,
            range: range,
            referenceDate: reference
        )
        let snapshots = GeekChartWindow.barBucketSnapshots(
            for: dates,
            in: plot,
            range: range,
            referenceDate: reference
        )

        XCTAssertEqual(GeekChartWindow.barSlotCount(in: plot), 80)
        XCTAssertEqual(buckets.map(\.indices), [[0], [1, 2]])
        XCTAssertEqual(snapshots.count, 80)
        XCTAssertTrue(snapshots.dropLast(2).allSatisfy(\.indices.isEmpty))
        XCTAssertEqual(snapshots.suffix(2).map(\.indices), [[0], [1, 2]])
        XCTAssertEqual(snapshots.first?.start, reference.addingTimeInterval(-120))
        XCTAssertEqual(snapshots.first?.end, reference.addingTimeInterval(-118.5))
        XCTAssertEqual(snapshots.last?.end, reference)
        XCTAssertEqual(TimeBucketAggregator.average([20, 40]), 30)
        XCTAssertEqual(TimeBucketAggregator.lastValid([20, 40]), 40)
        XCTAssertNil(TimeBucketAggregator.average([.nan, .infinity]))
    }

    func testDenseBucketSnapshotsKeepUnobservedSlotsEmptyAfterSamplingStarts() {
        let start = Date(timeIntervalSinceReferenceDate: 20_000)
        let duration: TimeInterval = 30
        let plot = CGRect(x: 0, y: 0, width: 30, height: 54)
        let slotDuration = duration / Double(GeekChartWindow.barSlotCount(in: plot))
        let dates = [
            start.addingTimeInterval(slotDuration * 0.5),
            start.addingTimeInterval(slotDuration * 2.5),
        ]
        let snapshots = GeekChartWindow.barBucketSnapshots(
            for: dates,
            in: plot,
            range: (start, start.addingTimeInterval(duration), start)
        )

        XCTAssertEqual(snapshots.count, GeekChartWindow.barSlotCount(in: plot))
        XCTAssertEqual(snapshots.prefix(3).map(\.indices), [[0], [], [1]])
        XCTAssertTrue(snapshots.dropFirst(3).allSatisfy(\.indices.isEmpty))
        XCTAssertEqual(
            snapshots[1].x - snapshots[0].x,
            GeekChartWindow.barMetrics(displayScale: 1).pitch,
            accuracy: 0.001
        )
        XCTAssertEqual(
            snapshots[2].x - snapshots[1].x,
            GeekChartWindow.barMetrics(displayScale: 1).pitch,
            accuracy: 0.001
        )

        let measuredValues: [Double] = [40, 60]
        let filled = TimeBucketAggregator.nearestFilled(
            snapshots.map { bucket in
                TimeBucketAggregator.lastValid(
                    bucket.indices.map { measuredValues[$0] }
                )
            }
        )
        XCTAssertEqual(filled.compactMap(\.value), [40, 60])
        XCTAssertNil(filled[1].value)
        XCTAssertNil(filled.last?.value)
        XCTAssertTrue(filled.allSatisfy { !$0.isEstimated })
    }

    func testDenseBucketSnapshotsKeepPreSamplingSlotsEmpty() throws {
        let start = Date(timeIntervalSinceReferenceDate: 21_000)
        let duration: TimeInterval = 30
        let plot = CGRect(x: 0, y: 0, width: 30, height: 54)
        let slotCount = GeekChartWindow.barSlotCount(in: plot)
        let slotDuration = duration / Double(slotCount)
        let dates = [start.addingTimeInterval(slotDuration * 2.5)]
        let snapshots = GeekChartWindow.barBucketSnapshots(
            for: dates,
            in: plot,
            range: (start, start.addingTimeInterval(duration), dates[0])
        )

        XCTAssertEqual(snapshots.count, slotCount)
        XCTAssertEqual(snapshots.prefix(3).map(\.indices), [[], [], [0]])

        let filled = TimeBucketAggregator.nearestFilled(
            snapshots.map { bucket in
                TimeBucketAggregator.lastValid(
                    bucket.indices.map { _ in 42.0 }
                )
            }
        )
        XCTAssertEqual(filled.compactMap(\.value), [42])
        XCTAssertNil(filled[0].value)
        XCTAssertNil(filled[1].value)
        XCTAssertTrue(filled.dropFirst(3).allSatisfy { $0.value == nil })
        XCTAssertTrue(filled.allSatisfy { !$0.isEstimated })
    }

    func testBucketValuesPreserveMissingIntervalsAndMeasuredZero() {
        let filled = TimeBucketAggregator.nearestFilled(
            [10.0, nil, 30.0] as [Double?]
        )

        XCTAssertEqual(filled.map(\.value), [10, nil, 30])
        XCTAssertEqual(filled.map(\.isEstimated), [false, false, false])
        XCTAssertEqual(filled.map(\.sourceIndex), [0, nil, 2])

        let zero = TimeBucketAggregator.nearestFilled([0.0] as [Double?])
        XCTAssertEqual(zero.first?.value, 0)
        XCTAssertEqual(zero.first?.isEstimated, false)
        XCTAssertEqual(zero.first?.sourceIndex, 0)

        let edgeGaps = TimeBucketAggregator.nearestFilled(
            [nil, 42.0, nil] as [Double?]
        )
        XCTAssertEqual(edgeGaps.map(\.value), [nil, 42, nil])
        XCTAssertEqual(edgeGaps.map(\.isEstimated), [false, false, false])
        XCTAssertEqual(edgeGaps.map(\.sourceIndex), [nil, 1, nil])

        let unavailable = TimeBucketAggregator.nearestFilled(
            [nil, nil] as [Double?]
        )
        XCTAssertTrue(unavailable.allSatisfy {
            $0.value == nil && !$0.isEstimated && $0.sourceIndex == nil
        })
    }

    func testStateBucketsNeverBorrowPastOrFutureObservations() {
        let filled = TimeBucketAggregator.forwardFilled(
            [nil, false, nil, nil, true, nil] as [Bool?]
        )

        XCTAssertEqual(filled.map(\.value), [nil, false, nil, nil, true, nil])
        XCTAssertEqual(filled.map(\.sourceIndex), [nil, 1, nil, nil, 4, nil])
        XCTAssertTrue(filled.allSatisfy { !$0.isEstimated })

        let unavailable = TimeBucketAggregator.forwardFilled(
            [nil, nil] as [Bool?]
        )
        XCTAssertTrue(unavailable.allSatisfy {
            $0.value == nil && !$0.isEstimated && $0.sourceIndex == nil
        })
    }

    func testObservedSegmentsKeepSlowCadenceButBreakMissingSamplesAndSleep() {
        let start = Date(timeIntervalSinceReferenceDate: 22_000)
        func segments(_ samples: [(Int, Double?)]) -> [[Double]] {
            let dates = samples.map { start.addingTimeInterval(Double($0.0)) }
            let buckets = (0..<120).map { slot in
                GeekChartBucketSnapshot(
                    indices: samples.indices.filter { samples[$0].0 == slot },
                    x: CGFloat(slot),
                    start: start.addingTimeInterval(Double(slot)),
                    end: start.addingTimeInterval(Double(slot + 1))
                )
            }
            let values = buckets.map { bucket -> Double? in
                bucket.indices.last.flatMap { samples[$0].1 }
            }
            return TimeBucketAggregator.observedSegments(
                values,
                in: buckets,
                sampleDates: dates,
                isSampleValid: { samples[$0].1?.isFinite == true }
            )
                .map { $0.map(\.value) }
        }

        XCTAssertEqual(segments([(2, 0), (10, 20), (18, 30)]), [[0, 20, 30]])
        XCTAssertEqual(segments([(2, 0), (10, 20), (12, nil), (18, 30)]), [[0, 20], [30]])
        XCTAssertEqual(segments([(2, 0), (10, 20), (100, 30), (108, 40)]), [[0, 20], [30, 40]])
        XCTAssertEqual(segments([(2, 0), (100, 30)]), [[0], [30]])
        XCTAssertEqual(segments([(2, nil), (10, nil)]), [])
        XCTAssertEqual(segments((0..<8).map { ($0, Double($0)) }), [Array(0..<8).map(Double.init)])
    }

    func testPrecisionMemoryPathKeepsContinuousSamplesAcrossOneHourBuckets() {
        let reference = Date(timeIntervalSinceReferenceDate: 22_500)
        let chart = memoryChart(
            samples: stride(from: -168, through: 0, by: 8).map { (Double($0), 64.0) },
            reference: reference
        )
        let plot = CGRect(x: 0, y: 4, width: 272, height: 31)

        for channel in [MenuBarTelemetryChannel.memory, .memoryPressure] {
            let segments = chart.pointSegments(
                for: channel,
                in: plot,
                valueRange: 0...100,
                referenceDate: reference
            )
            XCTAssertEqual(segments.count, 1)
            XCTAssertGreaterThan(segments.first?.count ?? 0, 3)
            XCTAssertGreaterThan(segments.first?.first?.x ?? 0, plot.width * 0.9)
            XCTAssertFalse(chart.directPath(segments).isEmpty)
            XCTAssertEqual(pathLineCount(chart.directPath(segments)), (segments.first?.count ?? 1) - 1)
            XCTAssertTrue(chart.isolatedPointPath(segments).isEmpty)
            XCTAssertTrue(segments.flatMap { $0 }.allSatisfy { plot.contains($0) })
        }
        XCTAssertTrue(chart.samplingWindowDescription.contains(GeekChartRange.oneHour.title))
        XCTAssertTrue(chart.samplingWindowDescription.contains(L10n.text("实测曲线", "Observed trend")))
        XCTAssertFalse(chart.samplingWindowDescription.contains(TimeBucketAggregator.nearestFillDescription))
    }

    func testPrecisionMemoryPathBreaksFailedObservationInsideWideBucket() {
        let reference = Date(timeIntervalSinceReferenceDate: 22_600)
        let regular = stride(from: -240, through: 0, by: 8).map { (Double($0), 64.0 as Double?) }
        let plot = CGRect(x: 0, y: 4, width: 272, height: 31)
        for missingOffsets: Set<Double> in [[-144], [-152, -144, -136, -128]] {
            let chart = memoryChart(
                samples: regular.map { ($0.0, missingOffsets.contains($0.0) ? nil : $0.1) },
                reference: reference
            )
            let segments = chart.pointSegments(
                for: .memory,
                in: plot,
                valueRange: 0...100,
                referenceDate: reference
            )
            XCTAssertEqual(segments.count, 2)
            XCTAssertTrue(segments.allSatisfy { $0.count >= 2 })
            XCTAssertEqual(pathLineCount(chart.directPath(segments)), segments.reduce(0) { $0 + $1.count - 1 })
        }
    }

    func testPrecisionMemoryPathDoesNotBridgeSleepAcrossWideBuckets() {
        let reference = Date(timeIntervalSinceReferenceDate: 22_700)
        let samples = (stride(from: -320, through: -248, by: 8).map { (Double($0), 64.0 as Double?) }
            + stride(from: -72, through: 0, by: 8).map { (Double($0), 62.0 as Double?) })
        let chart = memoryChart(samples: samples, reference: reference)
        let segments = chart.pointSegments(
            for: .memory,
            in: CGRect(x: 0, y: 4, width: 272, height: 31),
            valueRange: 0...100,
            referenceDate: reference
        )
        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments.allSatisfy { $0.count >= 2 })
        XCTAssertEqual(pathLineCount(chart.directPath(segments)), segments.reduce(0) { $0 + $1.count - 1 })
    }

    func testPrecisionMemoryIsolatedMeasuredZeroHasMarkerWithoutInventedLine() {
        let reference = Date(timeIntervalSinceReferenceDate: 22_800)
        let chart = memoryChart(samples: [(-8, nil), (0, 0)], reference: reference)
        let segments = chart.pointSegments(
            for: .memory,
            in: CGRect(x: 0, y: 4, width: 272, height: 31),
            valueRange: 0...100,
            referenceDate: reference
        )
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.count, 1)
        XCTAssertEqual(segments.first?.first?.y, 33)
        XCTAssertTrue(chart.directPath(segments).isEmpty)
        XCTAssertFalse(chart.isolatedPointPath(segments).isEmpty)
        XCTAssertFalse(PanelChartSampling.hasRenderableTrend([
            MenuBarChartSample(date: reference, value: 0)
        ]))

        let missing = memoryChart(samples: [(-8, nil), (0, nil)], reference: reference)
        XCTAssertTrue(missing.pointSegments(
            for: .memory,
            in: CGRect(x: 0, y: 4, width: 272, height: 31),
            valueRange: 0...100,
            referenceDate: reference
        ).isEmpty)
    }

    private func memoryChart(
        samples: [(Double, Double?)],
        reference: Date
    ) -> GeekPrecisionLineChart {
        GeekPrecisionLineChart(
            points: samples.map { offset, value in
                MenuBarTelemetryPoint(
                    date: reference.addingTimeInterval(offset),
                    cpuTotal: nil, cpuUser: nil, cpuSystem: nil, gpu: nil,
                    memory: value, memoryPressure: value.map { $0 / 2 },
                    chipTemperature: nil, fanRPM: nil,
                    downBytesPerSecond: nil, upBytesPerSecond: nil
                )
            },
            series: [
                MenuBarTelemetrySeries(id: "memory", title: "Memory", channel: .memory, color: .blue),
                MenuBarTelemetrySeries(id: "pressure", title: "Pressure", channel: .memoryPressure, color: .orange)
            ],
            valueRange: 0...100,
            unit: .percent,
            accessibilityLabel: "Memory",
            duration: GeekChartRange.oneHour.duration,
            showsLegend: false,
            showsTimelineLabels: false,
            horizontalInset: 0
        )
    }

    private func pathLineCount(_ path: Path) -> Int {
        var count = 0
        path.forEach { if case .line = $0 { count += 1 } }
        return count
    }

    func testLastSampleUsesLatestCompleteSnapshotInsideBucket() {
        let snapshots = [
            (user: 10.0 as Double?, system: 5.0 as Double?),
            (user: 20.0 as Double?, system: nil),
        ]

        let selected = TimeBucketAggregator.lastSample(
            in: [0, 1],
            from: snapshots,
            satisfying: { $0.user?.isFinite == true && $0.system?.isFinite == true }
        )

        XCTAssertEqual(selected?.user, 10)
        XCTAssertEqual(selected?.system, 5)
    }

    func testMiniWindowPixelAlignmentIsExactAtOneAndTwoTimesScale() throws {
        let plot = CGRect(x: 0, y: 0, width: 359.5, height: 168)
        let end = Date(timeIntervalSince1970: 10_000)
        let range = GeekChartWindow.barRange(
            for: [end.addingTimeInterval(-3_600), end],
            duration: 3_600,
            referenceDate: end
        )

        for scale in [CGFloat(1), CGFloat(1.5), CGFloat(2)] {
            let pixel = MiniWindowPixel.onePhysicalPixel(displayScale: scale)
            XCTAssertEqual(pixel * scale, 1, accuracy: 0.000_001)

            let aligned = MiniWindowPixel.aligned(10.25, displayScale: scale)
            XCTAssertEqual((aligned * scale).rounded(), aligned * scale, accuracy: 0.000_001)

            let metrics = GeekChartWindow.barMetrics(displayScale: scale)
            XCTAssertEqual(metrics.spacing * scale, 1, accuracy: 0.000_001)
            XCTAssertEqual((metrics.width * scale).rounded(), metrics.width * scale, accuracy: 0.000_001)
            XCTAssertEqual((metrics.spacing * scale).rounded(), metrics.spacing * scale, accuracy: 0.000_001)
            let x = try XCTUnwrap(
                GeekChartWindow.barX(
                    for: end,
                    in: plot,
                    range: range,
                    displayScale: scale
                )
            )
            XCTAssertEqual(
                ((x - metrics.width / 2) * scale).rounded(),
                (x - metrics.width / 2) * scale,
                accuracy: 0.000_001
            )
            let strokeCenter = MiniWindowPixel.strokeCenter(
                10.25,
                lineWidth: pixel,
                displayScale: scale
            )
            XCTAssertEqual(
                ((strokeCenter - pixel / 2) * scale).rounded(),
                (strokeCenter - pixel / 2) * scale,
                accuracy: 0.000_001
            )
        }
        XCTAssertEqual(GeekChartWindow.barMarkWidth, MiniWindowStyleTokens.barWidth)
        XCTAssertEqual(GeekChartWindow.barSpacing, MiniWindowStyleTokens.barSpacing)
    }

    func testActiveMiniWindowCardBorderReplacesTheHairlineAtOneAndTwoTimesScale() throws {
        for scale in [CGFloat(1), CGFloat(2)] {
            XCTAssertEqual(
                GeekVisualTokens.cardBorderLineWidth(isActive: true, displayScale: scale),
                1
            )
            XCTAssertEqual(
                GeekVisualTokens.cardBorderLineWidth(isActive: false, displayScale: scale),
                1 / scale
            )
        }

        let components = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPanelComponents.swift"
        )
        XCTAssertTrue(
            components.contains(
                ".environment(\\.geekCombinedCardIsActive, isHovering)"
            )
        )
        XCTAssertTrue(components.contains(".environment(\\.geekCombinedCardIsSelected, isSelected)"))
        XCTAssertTrue(components.contains("isSelected: isSelected"))
        XCTAssertFalse(components.contains("GeekVisualTokens.selectedBorder"))
    }

    func testMiniWindowUsesOneEqualOuterInsetAndOneSmallerCardGap() throws {
        XCTAssertEqual(GeekPanelLayout.contentPadding, MiniWindowStyleTokens.contentInset)
        XCTAssertEqual(GeekPanelLayout.sectionSpacing, MiniWindowStyleTokens.cardSpacing)
        XCTAssertEqual(GeekPanelLayout.detailSpacing, MiniWindowStyleTokens.cardSpacing)
        XCTAssertGreaterThan(MiniWindowStyleTokens.contentInset, MiniWindowStyleTokens.cardSpacing)

        let overviewCardHeights: [CGFloat] = [
            GeekPanelLayout.overviewProcessorCardHeight,
            GeekPanelLayout.overviewMemoryCardHeight,
            GeekPanelLayout.overviewDiskCardHeight,
            GeekPanelLayout.overviewNetworkCardHeight,
            GeekPanelLayout.overviewSensorsCardHeight,
            GeekPanelLayout.overviewPowerCardHeight,
        ]
        let overviewContentHeight = overviewCardHeights.reduce(0, +)
            + CGFloat(overviewCardHeights.count - 1) * GeekPanelLayout.sectionSpacing
            + GeekPanelLayout.contentPadding * 2
        XCTAssertEqual(
            GeekPanelLayout.overviewSize(showsPowerModule: true).height,
            overviewContentHeight
        )

        let overview = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )
        let tertiary = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift"
        )
        let palette = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift"
        )

        XCTAssertTrue(overview.contains(".padding(GeekPanelLayout.contentPadding)"))
        XCTAssertTrue(overview.contains(
            ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"
        ))
        XCTAssertTrue(tertiary.contains(
            "contentPadding: CGFloat = GeekPanelLayout.contentPadding"
        ))
        XCTAssertTrue(palette.contains(
            ".padding(GeekPanelLayout.contentPadding)"
        ))
        XCTAssertTrue(palette.contains(".controlPaletteContentLayout(presentation)"))
        XCTAssertTrue(palette.contains("reportSize: presentation.reportNaturalContentSize"))
        XCTAssertFalse(palette.contains(
            ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)"
        ))
        XCTAssertFalse(palette.contains(".padding(8)"))
    }

    func testGeekBarsMatchReferenceGeometryAndScrollLeft() throws {
        let largePlot = CGRect(x: 0, y: 0, width: 359.5, height: 168)
        let compactPlot = CGRect(x: 0, y: 0, width: 240, height: 54)
        let end = Date(timeIntervalSince1970: 10_000)
        let duration: TimeInterval = 3_600
        let observedPoint = end.addingTimeInterval(-60)
        let initialRange = GeekChartWindow.barRange(
            for: [
                end.addingTimeInterval(-duration),
                end
            ],
            duration: duration
        )
        let advancedRange = GeekChartWindow.barRange(
            for: [
                end.addingTimeInterval(-duration + 30),
                end.addingTimeInterval(30)
            ],
            duration: duration
        )

        XCTAssertEqual(GeekChartWindow.barMarkWidth, 2)
        XCTAssertEqual(GeekChartWindow.barSpacing, 1)
        XCTAssertEqual(GeekChartWindow.barSlotCount(in: largePlot), 120)
        XCTAssertEqual(GeekChartWindow.barSlotCount(in: compactPlot), 80)

        let firstX = try XCTUnwrap(
            GeekChartWindow.barX(
                for: initialRange.start,
                in: largePlot,
                range: initialRange
            )
        )
        let lastX = try XCTUnwrap(
            GeekChartWindow.barX(
                for: initialRange.end,
                in: largePlot,
                range: initialRange
            )
        )
        XCTAssertEqual(firstX, 1, accuracy: 0.001)
        XCTAssertEqual(lastX, 358, accuracy: 0.001)

        let originalX = try XCTUnwrap(
            GeekChartWindow.barX(
                for: observedPoint,
                in: largePlot,
                range: initialRange
            )
        )
        let scrolledX = try XCTUnwrap(
            GeekChartWindow.barX(
                for: observedPoint,
                in: largePlot,
                range: advancedRange
            )
        )
        XCTAssertLessThan(scrolledX, originalX)
        XCTAssertEqual(originalX - scrolledX, 3, accuracy: 0.001)
    }

    func testReferencePlotWidthsProduceMeasuredStandardAndBatteryBucketDurations() {
        let standardPlot = CGRect(x: 0, y: 0, width: 359, height: 120)
        let batteryPlot = CGRect(x: 0, y: 0, width: 287, height: 90)
        let historyPlot = CGRect(
            x: 2,
            y: 0,
            width: MiniWindowStyleTokens.historyWidth
                - MiniWindowStyleTokens.contentInset * 2
                - 4,
            height: 120
        )

        XCTAssertEqual(GeekChartWindow.barPitch, 3)
        XCTAssertEqual(GeekChartWindow.barMarkWidth * 2, 4)
        XCTAssertEqual(GeekChartWindow.barSpacing * 2, 2)
        XCTAssertEqual(GeekChartWindow.barSlotCount(in: standardPlot), 120)
        XCTAssertEqual(GeekChartWindow.barSlotCount(in: historyPlot), 120)
        XCTAssertEqual(GeekChartWindow.barSlotCount(in: batteryPlot), 96)

        XCTAssertEqual(
            GeekChartWindow.barBucketDuration(duration: 3_600, in: standardPlot),
            30,
            accuracy: 0.001
        )
        XCTAssertEqual(
            GeekChartWindow.barBucketDuration(duration: 86_400, in: standardPlot),
            12 * 60,
            accuracy: 0.001
        )
        XCTAssertEqual(
            GeekChartWindow.barBucketDuration(duration: 259_200, in: standardPlot),
            36 * 60,
            accuracy: 0.001
        )
        XCTAssertEqual(
            GeekChartWindow.barBucketDuration(duration: 3_600, in: batteryPlot),
            37.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            GeekChartWindow.barBucketDuration(duration: 86_400, in: batteryPlot),
            15 * 60,
            accuracy: 0.001
        )
        XCTAssertEqual(
            GeekChartWindow.barBucketDuration(duration: 259_200, in: batteryPlot),
            45 * 60,
            accuracy: 0.001
        )
    }

    func testLiveBarWindowAdvancesOnlyAtDiscreteSlotBoundaries() throws {
        let plot = CGRect(x: 0, y: 0, width: 240, height: 54)
        let referenceDate = Date(timeIntervalSinceReferenceDate: 15_000)
        let sampleDate = referenceDate.addingTimeInterval(-2)
        let duration: TimeInterval = 120
        let initialRange = GeekChartWindow.barRange(
            for: [sampleDate],
            duration: duration,
            referenceDate: referenceDate
        )
        let advancedReferenceDate = referenceDate.addingTimeInterval(0.25)
        let advancedRange = GeekChartWindow.barRange(
            for: [sampleDate],
            duration: duration,
            referenceDate: advancedReferenceDate
        )

        XCTAssertEqual(
            initialRange.end.timeIntervalSince(initialRange.start),
            duration,
            accuracy: 0.001
        )
        let initialX = try XCTUnwrap(
            GeekChartWindow.barX(
                for: sampleDate,
                in: plot,
                range: initialRange
            )
        )
        let advancedX = try XCTUnwrap(
            GeekChartWindow.barX(
                for: sampleDate,
                in: plot,
                range: advancedRange
            )
        )
        XCTAssertEqual(advancedX, initialX, accuracy: 0.001)

        let shiftedRange = GeekChartWindow.barRange(
            for: [sampleDate],
            duration: duration,
            referenceDate: referenceDate.addingTimeInterval(1.6)
        )
        let shiftedX = try XCTUnwrap(
            GeekChartWindow.barX(
                for: sampleDate,
                in: plot,
                range: shiftedRange
            )
        )
        XCTAssertEqual(initialX - shiftedX, GeekChartWindow.barPitch, accuracy: 0.001)
    }

    func testLiveBarPositionDoesNotSubpixelScrollBetweenSamples() throws {
        let plot = CGRect(x: 0, y: 0, width: 240, height: 54)
        let boundary = Date(timeIntervalSinceReferenceDate: 15_000)
        let sampleDate = boundary.addingTimeInterval(-2)
        let before = boundary.addingTimeInterval(-0.001)
        let after = boundary.addingTimeInterval(0.001)
        let beforeRange = GeekChartWindow.barRange(
            for: [sampleDate],
            duration: 120,
            referenceDate: before
        )
        let afterRange = GeekChartWindow.barRange(
            for: [sampleDate],
            duration: 120,
            referenceDate: after
        )
        let beforeX = try XCTUnwrap(
            GeekChartWindow.barX(
                for: sampleDate,
                in: plot,
                range: beforeRange
            )
        )
        let afterX = try XCTUnwrap(
            GeekChartWindow.barX(
                for: sampleDate,
                in: plot,
                range: afterRange
            )
        )

        XCTAssertEqual(afterX, beforeX, accuracy: 0.001)
    }

    func testLiveChartRefreshRateScalesWithRangeAndReduceMotion() {
        XCTAssertEqual(
            GeekLiveChartTimeline<EmptyView>.refreshInterval(
                for: 120,
                reduceMotion: false
            ),
            1
        )
        XCTAssertEqual(
            GeekLiveChartTimeline<EmptyView>.refreshInterval(
                for: 3_600,
                reduceMotion: false
            ),
            30
        )
        XCTAssertEqual(
            GeekLiveChartTimeline<EmptyView>.refreshInterval(
                for: 86_400,
                reduceMotion: false
            ),
            720
        )
        XCTAssertEqual(
            GeekLiveChartTimeline<EmptyView>.refreshInterval(
                for: 120,
                reduceMotion: true
            ),
            1
        )
    }

    func testSharedChartActivityPolicyPausesAndDegradesForSystemConditions() {
        let normal = ChartActivityPolicy(
            isPanelVisible: true,
            isDisplayAwake: true,
            isLowPowerModeEnabled: false,
            thermalState: .nominal,
            reduceMotion: false
        )
        XCTAssertEqual(normal.refreshInterval(for: 120), 1)
        XCTAssertEqual(
            ChartActivityPolicy(
                isPanelVisible: true,
                isDisplayAwake: true,
                isLowPowerModeEnabled: true,
                thermalState: .nominal,
                reduceMotion: false
            ).refreshInterval(for: 120),
            2
        )
        XCTAssertEqual(
            ChartActivityPolicy(
                isPanelVisible: true,
                isDisplayAwake: true,
                isLowPowerModeEnabled: false,
                thermalState: .serious,
                reduceMotion: false
            ).refreshInterval(for: 120),
            2
        )
        XCTAssertNil(ChartActivityPolicy(
            isPanelVisible: true,
            isDisplayAwake: true,
            isLowPowerModeEnabled: false,
            thermalState: .critical,
            reduceMotion: false
        ).refreshInterval(for: 120))
        XCTAssertNil(ChartActivityPolicy(
            isPanelVisible: false,
            isDisplayAwake: true,
            isLowPowerModeEnabled: false,
            thermalState: .nominal,
            reduceMotion: false
        ).refreshInterval(for: 120))
        XCTAssertNil(ChartActivityPolicy(
            isPanelVisible: true,
            isDisplayAwake: false,
            isLowPowerModeEnabled: false,
            thermalState: .nominal,
            reduceMotion: false
        ).refreshInterval(for: 120))
        XCTAssertNil(ChartActivityPolicy(
            isPanelVisible: true,
            isDisplayAwake: true,
            isLowPowerModeEnabled: false,
            thermalState: .nominal,
            reduceMotion: true
        ).refreshInterval(for: 120))
    }

    func testSharedChartAnchorUsesMonotonicElapsedTime() {
        let clock = ContinuousClock()
        let instant = clock.now
        let wallDate = Date(timeIntervalSince1970: 10_000)
        let anchor = PanelChartTimeAnchor(wallDate: wallDate, instant: instant)

        XCTAssertEqual(
            anchor.referenceDate(now: instant.advanced(by: .seconds(5)))
                .timeIntervalSince(wallDate),
            5,
            accuracy: 0.001
        )
    }

    func testLiveBarsSortOutOfOrderSamplesAndBoundFutureClockSkew() {
        let referenceDate = Date(timeIntervalSinceReferenceDate: 20_000)
        let dates = [
            referenceDate.addingTimeInterval(-3),
            referenceDate.addingTimeInterval(20),
            referenceDate.addingTimeInterval(-2),
            referenceDate.addingTimeInterval(1),
        ]
        let plot = CGRect(x: 0, y: 0, width: 240, height: 54)
        let range = GeekChartWindow.barRange(
            for: dates,
            duration: 120,
            referenceDate: referenceDate
        )
        let marks = GeekChartWindow.barMarks(
            for: dates,
            in: plot,
            range: range,
            referenceDate: referenceDate
        )

        XCTAssertEqual(range.end, referenceDate)
        XCTAssertFalse(marks.contains { $0.index == 1 })
        XCTAssertEqual(marks.map(\.index), [2, 3])
        XCTAssertEqual(marks.map(\.x), marks.map(\.x).sorted())
    }

    func testRenderableTrendKeepsOlderContinuousSegmentsAcrossGaps() {
        let start = Date(timeIntervalSince1970: 1_000)
        let oldSegment = [
            MenuBarChartSample(date: start, value: 1),
            MenuBarChartSample(date: start.addingTimeInterval(6), value: 2),
        ]
        let resumed = MenuBarChartSample(
            date: start.addingTimeInterval(100),
            value: 3
        )

        XCTAssertTrue(PanelChartSampling.hasRenderableTrend(oldSegment + [resumed]))
        XCTAssertTrue(PanelChartSampling.hasRenderableTrend(oldSegment + [
            resumed,
            MenuBarChartSample(
                date: start.addingTimeInterval(106),
                value: 4
            ),
        ]))
    }

    func testGeekBarMarksKeepOnlyNewestSamplePerVisualSlot() {
        let start = Date(timeIntervalSince1970: 10_000)
        let dates = (0...120).map { start.addingTimeInterval(Double($0)) }
        let plot = CGRect(x: 0, y: 0, width: 240, height: 54)
        let range = GeekChartWindow.barRange(for: dates, duration: 120)
        let marks = GeekChartWindow.barMarks(for: dates, in: plot, range: range)

        XCTAssertEqual(marks.count, GeekChartWindow.barSlotCount(in: plot))
        XCTAssertEqual(marks.last?.index, dates.indices.last)
        XCTAssertTrue(zip(marks, marks.dropFirst()).allSatisfy { $0.x < $1.x })

        for mark in marks {
            let lastIndexAtX = dates.indices.last { index in
                GeekChartWindow.barX(for: dates[index], in: plot, range: range) == mark.x
            }
            XCTAssertEqual(mark.index, lastIndexAtX)
        }
    }

    func testChannelBarMarksKeepLatestFiniteValueWhenLaterSameSlotIsMissing() throws {
        let end = Date(timeIntervalSince1970: 10_000)
        let dates = [end.addingTimeInterval(-0.5), end]
        let samples = zip(dates, [42.0, nil] as [Double?]).compactMap { date, value in
            value.map { (date: date, value: $0) }
        }
        let plot = CGRect(x: 0, y: 0, width: 240, height: 54)
        let range = GeekChartWindow.barRange(for: dates, duration: 120)
        let marks = GeekChartWindow.barMarks(
            for: samples.map(\.date),
            in: plot,
            range: range
        )

        XCTAssertEqual(marks.count, 1)
        let mark = try XCTUnwrap(marks.first)
        XCTAssertEqual(samples[mark.index].value, 42)

        let source = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift"
        )
        XCTAssertTrue(source.contains(
            "bucket.mean { history.downloadSamples[$0].value }"
        ))
        XCTAssertTrue(source.contains(
            "bucket.mean { history.uploadSamples[$0].value }"
        ))
        XCTAssertTrue(source.contains("referenceDate: referenceDate"))
    }

    func testPrecisionLinesBucketByRealTimeBeforeBuildingPaths() throws {
        let source = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift"
        )
        let precisionChart = try XCTUnwrap(
            source.components(separatedBy: "struct GeekPrecisionLineChart: View {").last?
                .components(separatedBy: "struct GeekPrecisionNetworkChart: View {").first
        )
        let pointSegments = try XCTUnwrap(
            source.components(separatedBy: "    func pointSegments(").last?
                .components(separatedBy: "    func directPath(").first
        )

        XCTAssertTrue(precisionChart.contains("GeekChartWindow.barBucketSnapshots("))
        XCTAssertTrue(pointSegments.contains("TimeBucketAggregator.nearestFilled("))
        XCTAssertTrue(pointSegments.contains("bucket.displayValue"))
        XCTAssertFalse(pointSegments.contains("for point in points"))
    }

    func testGeekBarsKeepTrueRangeWhileLongRangeWarmsUp() throws {
        let plot = CGRect(x: 0, y: 0, width: 359.5, height: 168)
        let start = Date(timeIntervalSince1970: 10_000)
        let firstWindow = (0...60).map {
            start.addingTimeInterval(Double($0) * 5)
        }
        let firstRange = GeekChartWindow.barRange(
            for: firstWindow,
            duration: 3_600,
            referenceDate: firstWindow.last!
        )

        XCTAssertEqual(
            firstRange.end.timeIntervalSince(firstRange.start),
            3_600,
            accuracy: 0.001
        )
        let firstX = try XCTUnwrap(
            GeekChartWindow.barX(
                for: firstWindow.first!,
                in: plot,
                range: firstRange
            )
        )
        let previousLatestX = try XCTUnwrap(
            GeekChartWindow.barX(
                for: firstWindow.last!,
                in: plot,
                range: firstRange
            )
        )
        XCTAssertGreaterThan(firstX, plot.width * 0.90)
        XCTAssertGreaterThan(previousLatestX, plot.width * 0.98)

        let advancedReferenceDate = firstWindow.last!.addingTimeInterval(31)
        let extendedRange = GeekChartWindow.barRange(
            for: firstWindow,
            duration: 3_600,
            referenceDate: advancedReferenceDate
        )
        let shiftedLatestX = try XCTUnwrap(
            GeekChartWindow.barX(
                for: firstWindow.last!,
                in: plot,
                range: extendedRange
            )
        )
        XCTAssertEqual(
            previousLatestX - shiftedLatestX,
            GeekChartWindow.barPitch,
            accuracy: 0.001
        )

        let firstMinuteRange = GeekChartWindow.barRange(
            for: [
                start,
                start.addingTimeInterval(60)
            ],
            duration: 3_600
        )
        XCTAssertEqual(
            firstMinuteRange.end.timeIntervalSince(firstMinuteRange.start),
            3_600,
            accuracy: 0.001
        )
    }

    func testGeekTimelineLabelsScaleFromMinutesThroughDays() {
        XCTAssertEqual(GeekChartWindow.defaultDuration, 120)
        XCTAssertEqual(GeekChartWindow.elapsedLabel(1_800), "−30m")
        XCTAssertEqual(GeekChartWindow.elapsedLabel(3_600), "−1h")
        XCTAssertEqual(GeekChartWindow.elapsedLabel(5_400), "−1.5h")
        XCTAssertEqual(GeekChartWindow.elapsedLabel(86_400), "−1d")
        XCTAssertEqual(GeekChartWindow.elapsedLabel(1_209_600), "−14d")
    }

    func testMultiDayChartDateFormattingUsesLocalDateAndAMPMAtMidnight() {
        let timeZone = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let beforeMidnight = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 3, hour: 15, minute: 20)
        )!
        let afterMidnight = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 4, hour: 0, minute: 5)
        )!
        let noon = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 4, hour: 12, minute: 0)
        )!
        let chinese = Locale(identifier: "zh_CN")

        XCTAssertFalse(PanelChartDateFormatting.includesDate(for: 3_600))
        XCTAssertFalse(PanelChartDateFormatting.includesDate(for: PanelChartDateFormatting.oneDay))
        XCTAssertTrue(PanelChartDateFormatting.includesDate(for: PanelChartDateFormatting.oneDay + 1))
        XCTAssertTrue(PanelChartDateFormatting.includesDate(for: 3 * PanelChartDateFormatting.oneDay))
        XCTAssertTrue(PanelChartDateFormatting.includesDate(for: 7 * PanelChartDateFormatting.oneDay))

        let concise = PanelChartDateFormatting.string(
            for: beforeMidnight,
            visibleDuration: 3_600,
            locale: chinese,
            timeZone: timeZone
        )
        let expectedConcise = DateFormatter()
        expectedConcise.locale = chinese
        expectedConcise.timeZone = timeZone
        expectedConcise.dateStyle = .none
        expectedConcise.timeStyle = .medium
        XCTAssertEqual(concise, expectedConcise.string(from: beforeMidnight))

        let expectedDate = "8月3日 下午 3:20"
        XCTAssertEqual(
            PanelChartDateFormatting.string(
                for: beforeMidnight,
                visibleDuration: 3 * PanelChartDateFormatting.oneDay,
                locale: chinese,
                timeZone: timeZone
            ),
            expectedDate
        )
        XCTAssertEqual(
            PanelChartDateFormatting.string(
                for: beforeMidnight,
                visibleDuration: 7 * PanelChartDateFormatting.oneDay,
                locale: chinese,
                timeZone: timeZone
            ),
            expectedDate
        )
        XCTAssertEqual(
            PanelChartDateFormatting.string(
                for: afterMidnight,
                visibleDuration: 3 * PanelChartDateFormatting.oneDay,
                locale: chinese,
                timeZone: timeZone
            ),
            "8月4日 上午 12:05"
        )
        XCTAssertEqual(
            PanelChartDateFormatting.string(
                for: noon,
                visibleDuration: 3 * PanelChartDateFormatting.oneDay,
                locale: chinese,
                timeZone: timeZone
            ),
            "8月4日 下午 12:00"
        )

        let english = PanelChartDateFormatting.string(
            for: beforeMidnight,
            visibleDuration: 3 * PanelChartDateFormatting.oneDay,
            locale: Locale(identifier: "en_US"),
            timeZone: timeZone
        )
        XCTAssertTrue(english.contains("Aug"))
        XCTAssertTrue(english.contains("3"))
        XCTAssertTrue(english.localizedCaseInsensitiveContains("pm"))
    }

    func testTertiaryHistoryShowsTimeAxesAndHoverTooltipsKeepTimestamps() throws {
        for path in [
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift",
        ] {
            let source = try source(path)
            let tooltipCount = source.components(separatedBy: "showsTooltip: true").count - 1
            XCTAssertGreaterThan(tooltipCount, 0, path)
        }

        let detail = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        let cpuHistory = try XCTUnwrap(detail.components(separatedBy: "struct GeekProcessorActivityHoverDetail: View {").last?.components(separatedBy: "struct GeekGPUHoverDetail").first)
        let memoryHistory = try XCTUnwrap(detail.components(separatedBy: "struct GeekMemoryHistoryHoverDetail: View {").last?.components(separatedBy: "struct GeekSwapHoverDetail").first)
        XCTAssertTrue(memoryHistory.contains("showsTimelineLabels: false"))
        XCTAssertTrue(memoryHistory.contains("showsValueLabels: true"))
        XCTAssertFalse(memoryHistory.contains("GeekHistoryStatisticsRow("))
        XCTAssertFalse(memoryHistory.contains("GeekHistoryCoverageRow("))
        XCTAssertFalse(memoryHistory.contains(".swapUsedBytes"))

        XCTAssertTrue(cpuHistory.contains("showsTimelineLabels: false"))
        XCTAssertFalse(cpuHistory.contains("GeekHistoryStatisticsRow("))
        XCTAssertFalse(cpuHistory.contains("GeekHistoryCoverageRow("))
        XCTAssertFalse(cpuHistory.contains("固定柱槽"))

        let chartSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift"
        )
        XCTAssertTrue(chartSource.contains("isEstimated: mark.isEstimated, showsTitle: false"))
        XCTAssertTrue(cpuHistory.contains("showsLegend: false"))
        XCTAssertTrue(cpuHistory.contains("title: \"\","))

        let powerSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift"
        )
        XCTAssertTrue(powerSource.contains("let shouldShowTimelineLabels = showsTimelineLabels"))
        XCTAssertTrue(powerSource.contains("- (shouldShowTimelineLabels ? 20 : 4)"))
    }

    func testGeekThroughputScaleContainsEveryDisplayedPeak() {
        XCTAssertEqual(GeekBarChartScale.throughputUpperBound(for: []), 1)
        XCTAssertEqual(GeekBarChartScale.throughputUpperBound(for: [100, 200]), 250)

        let traffic = Array(repeating: 1_000.0, count: 10) + [1_000_000]
        XCTAssertGreaterThanOrEqual(GeekBarChartScale.throughputUpperBound(for: traffic), 1_000_000)
        XCTAssertEqual(GeekBarChartScale.throughputUpperBound(for: [.nan, .infinity, -1, 0]), 1)
        XCTAssertEqual(GeekBarChartScale.throughputUpperBound(for: [.nan, .infinity, 100, 200]), 250)
    }

    func testDynamicChartAxisExpandsImmediatelyAndDecaysToTheExistingTier() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        var scale = PanelChartAxisScaleState()

        XCTAssertEqual(scale.update(targetMaximum: 30, at: start), 30)
        XCTAssertEqual(
            scale.update(targetMaximum: 100, at: start.addingTimeInterval(1)),
            100
        )

        XCTAssertEqual(
            scale.update(targetMaximum: 30, at: start.addingTimeInterval(2)),
            100
        )
        XCTAssertEqual(
            scale.update(targetMaximum: 30, at: start.addingTimeInterval(7)),
            65,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            scale.update(targetMaximum: 30, at: start.addingTimeInterval(12)),
            30,
            accuracy: 0.0001
        )

        XCTAssertEqual(
            scale.update(targetMaximum: 75, at: start.addingTimeInterval(13)),
            75
        )
    }

    func testChartDomainsKeepPercentMetricsFixedAndDynamicMetricsTyped() {
        XCTAssertEqual(
            ChartDomainPolicy.fixed(min: 0, max: 100).resolvedRange(fallback: 0 ... 34),
            0 ... 100
        )
        XCTAssertEqual(
            ChartDomainPolicy.positiveDynamic.resolvedRange(fallback: 0 ... 42),
            0 ... 42
        )
        XCTAssertEqual(
            ChartDomainPolicy.symmetricDynamic.resolvedRange(fallback: -18 ... 42),
            -42 ... 42
        )
    }

    func testLatestCPUVisualBucketUsesOneTelemetrySnapshotAndKeepsThirtyFourPercentTotal() throws {
        let reference = Date(timeIntervalSinceReferenceDate: 12_000)
        let points = [
            MenuBarTelemetryPoint(
                date: reference.addingTimeInterval(-0.6),
                cpuTotal: 7,
                cpuUser: 4,
                cpuSystem: 3,
                gpu: nil,
                memory: nil,
                chipTemperature: nil,
                fanRPM: nil,
                downBytesPerSecond: 100,
                upBytesPerSecond: 10
            ),
            MenuBarTelemetryPoint(
                date: reference,
                cpuTotal: 34,
                cpuUser: 22,
                cpuSystem: 12,
                gpu: nil,
                memory: nil,
                chipTemperature: nil,
                fanRPM: nil,
                downBytesPerSecond: 900,
                upBytesPerSecond: 90
            ),
        ]
        let plot = CGRect(x: 0, y: 0, width: 240, height: 54)
        let range = GeekChartWindow.barRange(
            for: points.map(\.date),
            duration: 120,
            referenceDate: reference
        )
        let bucket = try XCTUnwrap(
            GeekChartWindow.barBucketSnapshots(
                for: points.map(\.date),
                in: plot,
                range: range,
                referenceDate: reference
            ).last
        )
        let latest = TimeBucketAggregator.lastSample(
            in: bucket.indices,
            from: points
        )

        XCTAssertEqual(bucket.indices, [0, 1])
        XCTAssertEqual(latest?.date, reference)
        XCTAssertEqual(latest?.cpuUser, 22)
        XCTAssertEqual(latest?.cpuSystem, 12)
        XCTAssertEqual((latest?.cpuUser ?? 0) + (latest?.cpuSystem ?? 0), 34)
        XCTAssertEqual(TimeBucketAggregator.lastValid(bucket.indices.map {
            Double(points[$0].downBytesPerSecond ?? 0)
        }), 900)
    }

    func testNetworkHeadlineAndMirroredBarsUseTheirLatestHistorySample() throws {
        let components = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift"
        )
        let charts = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift"
        )
        let mirroredBars = try XCTUnwrap(
            charts.components(separatedBy: "private struct GeekMirroredBarSeries: View").last?
                .components(separatedBy: "private struct GeekStackedBarSeries: View").first
        )

        XCTAssertEqual(
            components.components(separatedBy: "if let latest = geekChartHistory.last").count - 1,
            2
        )
        XCTAssertTrue(charts.contains("struct GeekPreparedNetworkFrame"))
        XCTAssertTrue(charts.contains("TimeBucketAggregator.lastValid("))
        XCTAssertFalse(mirroredBars.contains("TimeBucketAggregator.average("))
    }

    func testPreparedNetworkFrameReusesBucketsAndAveragesObservedChannelValues() throws {
        let reference = Date(timeIntervalSinceReferenceDate: 12_000)
        let points = [
            MenuBarTelemetryPoint(
                date: reference.addingTimeInterval(-8), cpuTotal: nil, cpuUser: nil,
                cpuSystem: nil, gpu: nil, memory: nil, chipTemperature: nil,
                fanRPM: nil, downBytesPerSecond: 100, upBytesPerSecond: 10
            ),
            MenuBarTelemetryPoint(
                date: reference.addingTimeInterval(-1), cpuTotal: nil, cpuUser: nil,
                cpuSystem: nil, gpu: nil, memory: nil, chipTemperature: nil,
                fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: 20
            ),
            MenuBarTelemetryPoint(
                date: reference, cpuTotal: nil, cpuUser: nil, cpuSystem: nil,
                gpu: nil, memory: nil, chipTemperature: nil, fanRPM: nil,
                downBytesPerSecond: 200, upBytesPerSecond: nil
            ),
        ]
        let history = GeekNetworkHistorySnapshot(points: points)
        let frame = GeekPreparedNetworkFrame(
            history: history,
            plotRect: CGRect(x: 0, y: 0, width: 30, height: 54),
            duration: 120,
            referenceDate: reference,
            displayScale: 1
        )

        let slotCount = GeekChartWindow.barSlotCount(
            in: CGRect(x: 0, y: 0, width: 30, height: 54)
        )
        XCTAssertEqual(frame.buckets.count, slotCount)
        let bucket = try XCTUnwrap(frame.buckets.last)
        XCTAssertEqual(bucket.upload, 15)
        XCTAssertEqual(bucket.download, 150)
        XCTAssertEqual(
            frame.uploadMarks.map(\.value),
            [15]
        )
        XCTAssertEqual(
            frame.downloadMarks.map(\.value),
            [150]
        )
        XCTAssertTrue(frame.buckets.dropLast().allSatisfy { $0.upload == nil && !$0.uploadIsEstimated })
        XCTAssertTrue(frame.buckets.dropLast().allSatisfy { $0.download == nil && !$0.downloadIsEstimated })
        XCTAssertFalse(bucket.uploadIsEstimated)
        XCTAssertFalse(bucket.downloadIsEstimated)
        XCTAssertEqual(frame.maximum, 200)

        let charts = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift"
        )
        let networkChart = try XCTUnwrap(
            charts.components(separatedBy: "struct GeekPrecisionNetworkChart: View {").last?
                .components(separatedBy: "struct GeekDiskIOChart: View {").first
        )
        XCTAssertEqual(
            networkChart.components(separatedBy: "GeekPreparedNetworkFrame(").count - 1,
            1
        )
        XCTAssertFalse(networkChart.contains("networkMarks("))
    }

    func testPreparedNetworkFrameKeepsContinuousZeroNetworkSlotsAndPitchAcrossWidths() {
        let reference = Date(timeIntervalSinceReferenceDate: 15_000)
        let duration: TimeInterval = 120

        for width in [CGFloat(30), 95.5, 240, 359.5] {
            let plot = CGRect(x: 0, y: 0, width: width, height: 54)
            let slotCount = GeekChartWindow.barSlotCount(in: plot)
            let bucketDuration = duration / Double(slotCount)
            let start = reference.addingTimeInterval(-duration)
            let points = (0..<slotCount).map { slot in
                makeNetworkPoint(
                    date: start.addingTimeInterval((Double(slot) + 0.5) * bucketDuration),
                    upload: 0,
                    download: 0
                )
            }
            let frame = GeekPreparedNetworkFrame(
                history: GeekNetworkHistorySnapshot(points: points),
                plotRect: plot,
                duration: duration,
                referenceDate: reference,
                displayScale: 1
            )

            XCTAssertEqual(frame.buckets.count, slotCount, "width=\(width)")
            XCTAssertEqual(frame.uploadMarks.count, slotCount, "width=\(width)")
            XCTAssertEqual(frame.downloadMarks.count, slotCount, "width=\(width)")
            XCTAssertTrue(frame.uploadMarks.allSatisfy { $0.value == 0 }, "width=\(width)")
            XCTAssertTrue(frame.downloadMarks.allSatisfy { $0.value == 0 }, "width=\(width)")
            XCTAssertTrue(frame.uploadMarks.allSatisfy { !$0.isEstimated }, "width=\(width)")
            XCTAssertTrue(frame.downloadMarks.allSatisfy { !$0.isEstimated }, "width=\(width)")
            XCTAssertEqual(frame.maximum, 1, accuracy: 0.000_001, "width=\(width)")

            let expectedPitch = GeekChartWindow.barMetrics(displayScale: 1).pitch
            for (left, right) in zip(frame.uploadMarks, frame.uploadMarks.dropFirst()) {
                XCTAssertEqual(right.x - left.x, expectedPitch, accuracy: 0.001, "width=\(width)")
            }
        }
    }

    func testPreparedNetworkFrameEstimatesSingleMissingSlotWithoutInventingRawReading() throws {
        let reference = Date(timeIntervalSinceReferenceDate: 16_000)
        let duration: TimeInterval = 120
        let plot = CGRect(x: 0, y: 0, width: 240, height: 54)
        let slotCount = GeekChartWindow.barSlotCount(in: plot)
        let bucketDuration = duration / Double(slotCount)
        let start = reference.addingTimeInterval(-duration)
        let missingSlot = slotCount / 2
        let points = (0..<slotCount).map { slot in
            makeNetworkPoint(
                date: start.addingTimeInterval((Double(slot) + 0.5) * bucketDuration),
                upload: slot == missingSlot
                    ? nil
                    : (slot < missingSlot ? 10 : 30),
                download: slot == missingSlot
                    ? nil
                    : (slot < missingSlot ? 20 : 40)
            )
        }

        let frame = GeekPreparedNetworkFrame(
            history: GeekNetworkHistorySnapshot(points: points),
            plotRect: plot,
            duration: duration,
            referenceDate: reference,
            displayScale: 1
        )
        let missingBucket = try XCTUnwrap(
            frame.buckets.indices.contains(missingSlot) ? frame.buckets[missingSlot] : nil
        )

        XCTAssertEqual(frame.buckets.count, slotCount)
        XCTAssertEqual(missingBucket.upload, 10)
        XCTAssertEqual(missingBucket.download, 20)
        XCTAssertTrue(missingBucket.uploadIsEstimated)
        XCTAssertTrue(missingBucket.downloadIsEstimated)
        XCTAssertEqual(frame.uploadMarks.count, slotCount)
        XCTAssertEqual(frame.downloadMarks.count, slotCount)
        XCTAssertTrue(frame.uploadMarks.contains { abs($0.x - missingBucket.x) < 0.001 })
        XCTAssertTrue(frame.downloadMarks.contains { abs($0.x - missingBucket.x) < 0.001 })
        XCTAssertNil(points[missingSlot].upBytesPerSecond)
        XCTAssertNil(points[missingSlot].downBytesPerSecond)
    }

    func testEstimatedNeighborDataUsesTheSameVisibleStyleAsMeasuredData() throws {
        let charts = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift"
        )
        let battery = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift"
        )

        XCTAssertFalse(charts.contains("color.opacity(mark.isEstimated ?"))
        XCTAssertFalse(charts.contains("colors[index].opacity(preparedPoint.isEstimated ?"))
        XCTAssertFalse(battery.contains("opacity(prepared.isEstimated ?"))
        XCTAssertTrue(charts.contains("Text(item.value)"))
        XCTAssertFalse(charts.contains("Text(item.isEstimated ?"))
        XCTAssertFalse(charts.contains("if values.contains(where: \\.isEstimated)"))
        XCTAssertFalse(charts.contains(
            "L10n.text(\"邻近样本补全\", \"Filled from neighboring sample\")"
        ))
    }

    func testGeekStackedBarsReusePreparedSeriesAndRangeInsidePath() throws {
        let source = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift"
        )
        let stackedBars = try XCTUnwrap(
            source.components(separatedBy: "private struct GeekStackedBarSeries: View").last?
                .components(separatedBy: "struct GeekSeriesStatistics").first
        )

        XCTAssertTrue(source.contains("let visibleSeries = series.filter { summary.channels.contains($0.channel) }"))
        XCTAssertTrue(source.contains("let visibleValueRange = resolvedValueRange"))
        XCTAssertTrue(source.contains("case .percent:\n            return .fixed(min: 0, max: 100)"))
        XCTAssertTrue(stackedBars.contains("Canvas"))
        XCTAssertTrue(stackedBars.contains("valueRange: ClosedRange<Double>"))
        XCTAssertTrue(stackedBars.contains("prepared?.values"))
        XCTAssertFalse(stackedBars.contains("TimeBucketAggregator.average("))
        XCTAssertFalse(stackedBars.contains("LinearGradient"))
    }

    func testPanelAppearancePreferencesNormalizePersistedColors() {
        XCTAssertEqual(PanelAppearancePreferences.normalizedHex("#0a84ff"), "#0A84FF")
        XCTAssertEqual(PanelAppearancePreferences.normalizedHex("bf5af2"), "#BF5AF2")
        XCTAssertNil(PanelAppearancePreferences.normalizedHex("#12345"))
        XCTAssertNil(PanelAppearancePreferences.normalizedHex("automatic"))

        XCTAssertEqual(
            PanelColorTheme.resolved(storedTheme: "", backgroundHex: "", chartHex: ""),
            .system
        )
        XCTAssertEqual(
            PanelColorTheme.resolved(
                storedTheme: "",
                backgroundHex: "#0a84ff",
                chartHex: "#64d2ff"
            ),
            .ocean
        )
        XCTAssertEqual(
            PanelColorTheme.resolved(
                storedTheme: "custom",
                backgroundHex: "#0A84FF",
                chartHex: "#64D2FF"
            ),
            .custom
        )
        XCTAssertNil(
            PanelColorTheme.resolvedChartHex(
                storedTheme: "system",
                backgroundHex: "#0A84FF",
                customHex: "#64D2FF"
            )
        )
        XCTAssertEqual(
            PanelColorTheme.resolvedBackgroundHex(
                storedTheme: "violet",
                customHex: "#48484A",
                chartHex: "#0A84FF"
            ),
            "#5E5CE6"
        )
        XCTAssertEqual(
            PanelColorTheme.resolvedChartHex(
                storedTheme: "custom",
                backgroundHex: "#48484A",
                customHex: "#0a84ff"
            ),
            "#0A84FF"
        )
    }

    func testPanelAppearanceControlsLiveInMainSettingsAndFansRequireRealReadings() throws {
        let settings = try source("Sources/StorageCleanerMac/Views/SettingsView.swift")
        let panel = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )

        XCTAssertFalse(settings.contains("Show Fans in Panel Overview"))
        XCTAssertTrue(settings.contains("Panel Color Theme"))
        XCTAssertTrue(settings.contains("ForEach(PanelColorTheme.allCases)"))
        XCTAssertTrue(settings.contains("Panel Background Color"))
        XCTAssertTrue(settings.contains("Bar Chart Color"))
        XCTAssertTrue(settings.contains("ColorPicker("))
        XCTAssertTrue(panel.contains("if !geekOverviewFanReadings.isEmpty"))
        XCTAssertFalse(panel.contains("panelShowsFans"))
        XCTAssertFalse(panel.contains("modules.insert(.fans"))
    }

    func testPanelAccentThemePreservesSemanticContrastForPairedSeries() throws {
        let root = try source("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")
        let charts = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift")
        let cpuColorRule = try XCTUnwrap(charts.range(of:
            "if [.cpuUser, .cpuSystem, .compressedMemoryBytes, .swapUsedBytes].contains(item.channel) {\n            return item.color"
        ))
        let accentColorRule = try XCTUnwrap(charts.range(of:
            "if style == .stackedBars, let panelChartAccentColor"
        ))
        XCTAssertLessThan(cpuColorRule.lowerBound, accentColorRule.lowerBound)
        XCTAssertTrue(root.contains("var resolvedPrimaryTint: Color"))
        XCTAssertTrue(root.contains("var resolvedSecondaryTint: Color"))
        XCTAssertTrue(root.contains("var resolvedGPUTint: Color"))
        XCTAssertTrue(root.contains("var resolvedThermalTint: Color"))
        XCTAssertTrue(root.contains("var resolvedEnergyTint: Color"))
        XCTAssertTrue(root.contains("var resolvedUploadTint: Color"))
        XCTAssertTrue(root.contains("var resolvedDownloadTint: Color"))
        XCTAssertTrue(root.contains("var resolvedPrimaryTint: Color {\n        AppChartPalette.cpuUser"))
        XCTAssertTrue(root.contains("var resolvedSecondaryTint: Color {\n        AppChartPalette.cpuSystem"))
        XCTAssertTrue(root.contains("var resolvedUploadTint: Color {\n        MenuBarNetworkPalette.upload"))
        XCTAssertTrue(root.contains("var resolvedDownloadTint: Color {\n        MenuBarNetworkPalette.download"))

        let geekFiles = [
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarProcessorPanel.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarNetworkPanel.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarCombinedPanel.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekProcessorView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDiskView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift",
        ]
        for file in geekFiles {
            let source = try source(file)
            XCTAssertTrue(
                source.contains("resolvedPrimaryTint")
                    || source.contains("resolvedSecondaryTint")
                    || source.contains("resolvedGPUTint")
                    || source.contains("resolvedThermalTint")
                    || source.contains("resolvedEnergyTint")
                    || source.contains("resolvedUploadTint")
                    || source.contains("resolvedDownloadTint")
                    // Battery charts intentionally keep semantic colors
                    // (external power/battery/health) instead of the user
                    // accent, so the legend stays truthful when the theme
                    // changes.
                    || (file.hasSuffix("GeekPowerView.swift")
                        && source.contains("GeekBatteryChartPalette")),
                "\(file) must route its data-series colors through the accent resolver"
            )
        }

        // Direct palette references for themed series must not linger inside the
        // MenuBarAdvancedStatusView extensions; the accent resolver is the only path.
        for file in geekFiles {
            let source = try source(file)
            XCTAssertFalse(
                source.contains("tint: AppChartPalette.cpuUser")
                    || source.contains("tint: AppChartPalette.cpuSystem")
                    || source.contains("color: AppChartPalette.cpuUser")
                    || source.contains("color: AppChartPalette.cpuSystem")
                    || source.contains("tint: MenuBarNetworkPalette.upload")
                    || source.contains("tint: MenuBarNetworkPalette.download"),
                "\(file) still bypasses the accent resolver"
            )
        }
    }

    func testPanelChartsShareSamplingPlaceholderAndPreserveAxisRules() throws {
        // The geek charts are the only production chart surface. The legacy
        // "standard" chart views were dead code and were removed in 1.9.11;
        // MenuBarTelemetryChart.swift now carries only the shared series,
        // sample, and geometry types.
        let shared = try source("Sources/StorageCleanerMac/Views/MenuBarTelemetryChart.swift")
        let geek = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift")

        XCTAssertTrue(geek.contains("PanelChartSamplingPlaceholder()"))
        XCTAssertTrue(geek.contains("case .percent:"))
        XCTAssertTrue(geek.contains("MenuBarChartGeometry.niceCeiling"))
        XCTAssertTrue(geek.contains("let targetMaximum = prepared.maximum"))
        XCTAssertTrue(geek.contains("@StateObject private var dynamicAxisScale"))
        XCTAssertTrue(geek.contains("GeekChartWindow.barBucketSnapshots("))
        XCTAssertTrue(geek.contains("TimeBucketAggregator.nearestFilled("))

        XCTAssertTrue(shared.contains("static func pointSegments("))
        XCTAssertTrue(shared.contains("static func niceCeiling("))
        XCTAssertFalse(shared.contains("struct MenuBarTelemetryLineChart"))
        XCTAssertFalse(shared.contains("struct MenuBarTelemetryNetworkChart"))
    }

    func testGeekOverviewUsesCompactCombinedStackAndDetailsRemainResponsive() throws {
        let geekPanelSource = try [
            "MenuBarGeekPanel.swift",
            "GeekProcessorView.swift",
            "GeekMemoryView.swift",
            "GeekDiskView.swift",
            "GeekNetworkView.swift",
            "GeekSensorsView.swift",
            "GeekPowerView.swift",
            "GeekCleanupView.swift"
        ]
        .map { try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/\($0)") }
        .joined(separator: "\n")
        let components = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPanelComponents.swift"
        )
        let processor = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekProcessorView.swift"
        )
        let memory = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift"
        )
        let advancedStatus = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift"
        )

        for token in [
            "overviewProcessorCardHeight",
            "overviewMemoryCardHeight",
            "overviewDiskCardHeight",
            "overviewNetworkCardHeight",
            "overviewSensorsCardHeight",
        ] {
            XCTAssertTrue(
                geekPanelSource.contains("GeekPanelLayout.\(token)"),
                token
            )
        }
        XCTAssertGreaterThanOrEqual(
            geekPanelSource.components(
                separatedBy: "height: GeekPanelLayout.overviewPowerCardHeight"
            ).count - 1,
            3
        )
        XCTAssertEqual(GeekPanelLayout.sectionSpacing, MiniWindowStyleTokens.cardSpacing)
        XCTAssertTrue(components.contains("struct GeekCombinedRing: View"))
        XCTAssertTrue(components.contains("struct GeekCombinedRingSegment: Identifiable"))
        XCTAssertTrue(components.contains("all explanatory text inside the ring"))
        XCTAssertEqual(GeekCombinedRing.contentDiameter(size: 30, lineWidth: 2), 22)
        XCTAssertEqual(GeekCombinedRing.contentDiameter(size: 96, lineWidth: 6), 80)
        XCTAssertGreaterThanOrEqual(
            geekPanelSource.components(separatedBy: ".frame(height: 72)").count - 1,
            1
        )
        XCTAssertFalse(processor.contains(".frame(height: 72)"))
        XCTAssertFalse(memory.contains(".frame(height: 72)"))
        XCTAssertFalse(memory.contains("Grid(horizontalSpacing: 12, verticalSpacing: 2)"))
        XCTAssertTrue(memory.contains("geekMemoryPagesCard"))
        XCTAssertTrue(memory.contains("geekMemorySwapCard"))
        XCTAssertTrue(geekPanelSource.contains("geekVisibleOverviewModules"))
        XCTAssertTrue(advancedStatus.contains(
            "$0.isVisible && $0.module.isAvailableInOverview"
        ))
        XCTAssertFalse(geekPanelSource.contains("ForEach(geekDashboardBlocks)"))
        XCTAssertTrue(components.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(components.contains("struct GeekResponsiveColumns"))
        XCTAssertTrue(components.contains("minimumScaleFactor(0.72)"))
    }

    func testGoldenOverviewKeepsRealHistoryAndSeparatePressureAndRPMReadouts() throws {
        let panel = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )
        let charts = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift"
        )

        XCTAssertGreaterThanOrEqual(
            panel.components(separatedBy: "horizontalInset: 0").count - 1,
            2
        )
        let memoryPage = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift")
        XCTAssertTrue(memoryPage.contains("points: memoryHistory"))
        XCTAssertTrue(panel.contains("geekMemoryPressureRing(size: GeekVisualTokens.overviewMemoryGaugeSize)"))
        XCTAssertTrue(panel.contains("value: memoryRingUsedPercentText"))
        XCTAssertTrue(panel.contains("progress: memoryRingUsedProgress"))
        XCTAssertTrue(panel.contains("geekFanTelemetry.actualRPM.map(String.init)"))
        XCTAssertFalse(panel.contains(".environment(\\.geekCombinedCardUsesDivider, true)"))
        let pressureRing = try XCTUnwrap(panel.components(separatedBy: "func geekMemoryPressureRing(size: CGFloat)").last?
            .components(separatedBy: "var geekNetworkCard").first)
        XCTAssertTrue(pressureRing.contains("progress: percent.map { Double($0) / 100 }"))
        XCTAssertFalse(pressureRing.contains("isStatusOnly:"))
        XCTAssertFalse(pressureRing.contains("memoryPressureStateProgress"))
        XCTAssertTrue(charts.contains("var horizontalInset: CGFloat = 6"))
        XCTAssertTrue(charts.contains("proxy.size.width - horizontalInset * 2"))

        let processorCard = try XCTUnwrap(
            panel.components(separatedBy: "var geekProcessorCard: some View").last?
                .components(separatedBy: "var geekProcessorFrequencyTextCompact").first
        )
        let networkCard = try XCTUnwrap(
            panel.components(separatedBy: "var geekNetworkCard: some View").last?
                .components(separatedBy: "var geekDiskCard: some View").first
        )
        // Horizontal legend spacing is intentional; the chart retains its fixed height below.
        XCTAssertTrue(processorCard.contains(
            ".frame(height: GeekPanelLayout.overviewProcessorChartHeight)"
        ))
        XCTAssertTrue(networkCard.contains(
            ".frame(height: GeekPanelLayout.overviewNetworkChartHeight)"
        ))
    }

    func testGoldenOverviewKeepsReferenceLabelsAndFixtureThemeDeterministic() throws {
        let panel = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )
        let scene = try source(
            "Sources/StorageCleanerMac/Views/MenuBarStatusPanelRoot.swift"
        )

        XCTAssertTrue(panel.contains("L10n.text(\"网络\", \"Network\")"))
        XCTAssertTrue(panel.contains("L10n.text(\"传感器\", \"Sensors\")"))
        XCTAssertTrue(panel.contains("storageSnapshot.totalBytes"))
        XCTAssertTrue(panel.contains("Image(systemName: AppSymbols.Monitor.battery)"))
        XCTAssertTrue(panel.contains("batterySnapshot?.chargePercent.map"))
        XCTAssertTrue(panel.contains("value: geekCompactTemperatureText"))
        XCTAssertFalse(panel.contains("geekProcessorFrequencyAndTemperatureText"))
        XCTAssertFalse(scene.contains("if MiniWindowDemoData.isEnabled { return nil }"))
        XCTAssertTrue(scene.contains("PanelColorTheme.resolvedBackgroundHex("))
        XCTAssertTrue(scene.contains("PanelColorTheme.chartColor("))
    }

    func testMemoryRingsUseMeasuredCompositionAndThreeStableSemanticColors() throws {
        let components = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift"
        )
        let geek = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )
        let combined = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarCombinedPanel.swift"
        )
        let palette = try source(
            "Sources/StorageCleanerMac/Support/AppChartPalette.swift"
        )
        let segments = try XCTUnwrap(
            components.components(separatedBy: "var memoryRingSegments: [GeekCombinedRingSegment] {").last?
                .components(separatedBy: "    var memoryRingUsedPercentText").first
        )

        XCTAssertTrue(segments.contains("memorySnapshot?.ringComposition"))
        XCTAssertEqual(
            segments.components(separatedBy: "GeekCombinedRingSegment(").count - 1,
            3
        )
        for required in [
            "composition.appOrOtherRatio",
            "composition.wiredRatio",
            "composition.compressedRatio",
            "AppChartPalette.memoryAppOrOther",
            "AppChartPalette.memoryWired",
            "AppChartPalette.memoryCompressed",
        ] {
            XCTAssertTrue(segments.contains(required), required)
        }
        XCTAssertFalse(segments.contains("measurements.appBytes"))
        XCTAssertTrue(palette.contains(
            "memoryAppOrOther = AppDesignTokens.Palette.storage"
        ))
        XCTAssertTrue(palette.contains(
            "memoryWired = AppDesignTokens.Palette.diagnostic"
        ))
        XCTAssertTrue(palette.contains("memoryCompressed = activityRose"))
        XCTAssertTrue(components.contains("memorySnapshot?.measuredUsedRatio"))
        XCTAssertFalse(components.contains("?? metricPercent(.memoryUsage)"))
        XCTAssertTrue(geek.contains("value: memoryRingUsedPercentText"))
        XCTAssertTrue(geek.contains("progress: memoryRingUsedProgress"))
        XCTAssertTrue(combined.contains("segments: memoryRingSegments"))
        XCTAssertFalse(geek.contains(".help(memoryRingExplanation"))
        XCTAssertTrue(combined.contains(".accessibilityHint(memoryRingExplanation)"))
    }

    func testMemoryStatusAgesWithoutANewSampleAndKeepsPauseResumeDistinct() {
        let snapshot = memoryStatusSnapshot()
        let timestamp = PanelTimestampFormat.display(snapshot.generatedAt)
        func status(at seconds: TimeInterval, paused: Bool = false) -> String {
            MemorySampleStatusPresentation.text(
                snapshot: snapshot, isPaused: paused,
                referenceDate: snapshot.generatedAt.addingTimeInterval(seconds)
            )
        }
        XCTAssertEqual(status(at: 59), timestamp)
        XCTAssertEqual(status(at: 61), L10n.text("已过期 · ", "Stale · ") + timestamp)
        XCTAssertEqual(status(at: 61, paused: true), L10n.text("已暂停 · ", "Paused · ") + timestamp)
        XCTAssertEqual(status(at: 62), L10n.text("已过期 · ", "Stale · ") + timestamp)
        XCTAssertEqual(MemorySampleStatusPresentation.text(
            snapshot: nil, isPaused: false, referenceDate: snapshot.generatedAt
        ), L10n.text("首次采样中", "Sampling"))
        XCTAssertEqual(MemorySampleStatusPresentation.text(
            snapshot: nil, isPaused: true, referenceDate: snapshot.generatedAt
        ), L10n.text("已暂停 · 尚未采样", "Paused · Not sampled"))
    }

    func testMemoryStatusRejectsInvalidPresentValuesAndPreservesMeasuredZero() {
        let invalidSnapshots = [
            memoryStatusSnapshot(physical: .available(0), available: .available(0)),
            memoryStatusSnapshot(physical: .available(100), available: .available(101)),
            memoryStatusSnapshot(available: MemoryMeasurement(
                value: 2_000, availability: .invalidSample, reason: "Rejected measurement."
            )),
        ]
        for snapshot in invalidSnapshots {
            XCTAssertEqual(MemorySampleStatusPresentation.text(
                snapshot: snapshot, isPaused: false, referenceDate: snapshot.generatedAt
            ), MeasurementAvailability.invalidSample.title)
        }
        let denied = memoryStatusSnapshot(available: .unavailable(.permissionDenied, reason: "Denied."))
        XCTAssertEqual(MemorySampleStatusPresentation.text(
            snapshot: denied, isPaused: false, referenceDate: denied.generatedAt
        ), MeasurementAvailability.permissionDenied.title)
        let zeroUsed = memoryStatusSnapshot(physical: .available(8_000), available: .available(8_000))
        XCTAssertEqual(zeroUsed.measuredUsedRatio, 0)
        XCTAssertEqual(MemorySampleStatusPresentation.text(
            snapshot: zeroUsed, isPaused: false, referenceDate: zeroUsed.generatedAt
        ), PanelTimestampFormat.display(zeroUsed.generatedAt))
    }

    func testMemoryStatusLabelsUseIndependentLowFrequencyClockWithoutSampling() throws {
        XCTAssertEqual(MemorySampleStatusPresentation.refreshInterval, 15)
        for file in ["GeekMemoryView.swift"] {
            let view = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/\(file)")
            let label = try XCTUnwrap(view.components(separatedBy:
                "TimelineView(.periodic(from: .now, by: MemorySampleStatusPresentation.refreshInterval)) { timeline in"
            ).dropFirst().first?.components(separatedBy: "                    }").first)
            XCTAssertTrue(label.contains("Text(memorySampleStatusText(at: timeline.date))"))
            XCTAssertTrue(label.contains(".help(memorySampleEvidenceText)"))
            XCTAssertTrue(label.contains(".accessibilityHint(memorySampleEvidenceText)"))
            XCTAssertFalse(label.contains("refreshMemory"))
            XCTAssertFalse(label.contains("refreshMenuBar"))
        }
        let components = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift")
        let helper = try XCTUnwrap(components.components(separatedBy:
            "func memorySampleStatusText(at date: Date) -> String"
        ).dropFirst().first?.components(separatedBy: "    var memoryUsageAmountText").first)
        XCTAssertTrue(helper.contains("MiniWindowDemoData.chartDate(liveDate: date)"))
        XCTAssertFalse(helper.contains("historyReferenceDate"))
        XCTAssertFalse(helper.contains("refreshMemory"))
        let snapshot = memoryStatusSnapshot()
        let timestamp = snapshot.generatedAt.formatted(.dateTime.year().month().day().hour().minute().second())
        let evidence = MemorySampleStatusPresentation.evidence(snapshot: snapshot)
        XCTAssertTrue(evidence.contains(timestamp))
        XCTAssertTrue(evidence.contains(L10n.text("本应用根据系统数据评估", "app-assessed grade based on system data")))
    }

    private func memoryStatusSnapshot(
        physical: MemoryMeasurement<UInt64> = .available(8_000),
        available: MemoryMeasurement<UInt64> = .available(2_000)
    ) -> MemorySnapshot {
        MemorySnapshot(
            generatedAt: Date(timeIntervalSince1970: 100_000),
            physicalBytes: Int64(clamping: physical.value ?? 0),
            freeBytes: 0, inactiveBytes: 0, speculativeBytes: 0,
            fileBackedBytes: 0, purgeableBytes: 0, wiredBytes: 1_000,
            compressedBytes: 500, swapUsedBytes: 0,
            pressureFreePercentage: nil, pressureSummary: "", topProcesses: [],
            measurements: MemoryMeasurements(
                pressure: .available(.normal), physicalBytes: physical, availableBytes: available,
                appBytes: .available(0), wiredBytes: .available(1_000), compressedBytes: .available(500),
                cachedBytes: .available(0), swapUsedBytes: .available(0),
                swapInRate: .available(0), swapOutRate: .available(0)
            )
        )
    }

    func testMemoryCompositionSegmentsNeverExceedTheUsedBudget() throws {
        let composition = try XCTUnwrap(MemoryRingComposition(
            physicalBytes: 1_000,
            availableBytes: 100,
            wiredBytes: 800,
            compressedBytes: 800
        ))

        XCTAssertEqual(
            composition.appOrOtherBytes + composition.wiredBytes + composition.compressedBytes,
            composition.usedBytes
        )
        XCTAssertEqual(
            composition.appOrOtherRatio + composition.wiredRatio + composition.compressedRatio,
            composition.usedRatio,
            accuracy: 0.000_001
        )
        XCTAssertLessThanOrEqual(composition.usedBytes, composition.physicalBytes)
    }

    func testVisibleMemoryPressureKeepsStateAndHeadroomWithoutRedundantExplanation() throws {
        let components = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift"
        )
        let status = try source(
            "Sources/StorageCleanerMac/Views/MenuBarStatusView.swift"
        )
        let combined = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarCombinedPanel.swift"
        )
        let overview = try source(
            "Sources/StorageCleanerMac/Views/OverviewView.swift"
        )
        let utilities = try source(
            "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"
        )
        let telemetry = try source(
            "Sources/StorageCleanerMac/Models/MenuBarTelemetryModels.swift"
        )

        XCTAssertTrue(components.contains("var memoryPressureDisplayText: String"))
        XCTAssertTrue(components.contains("L10n.text(\"高\", \"High\")"))
        XCTAssertTrue(components.contains("L10n.text(\"正常\", \"Normal\")"))
        XCTAssertTrue(components.contains("var memoryPressureStateProgress: Double?"))
        XCTAssertTrue(components.contains("memorySnapshot?.reportablePressureLevel"))
        XCTAssertTrue(components.contains("2 / 3"))
        XCTAssertFalse(components.contains("memoryPressureEstimateProgress"))
        XCTAssertFalse(components.contains("不是 iStat 或活动监视器的压力百分比"))
        XCTAssertFalse(components.contains("iStat or Activity Monitor pressure percentage"))
        XCTAssertFalse(components.contains("圆环表示三级状态，不是百分比"))
        XCTAssertTrue(components.contains("余量不可用"))
        XCTAssertFalse(components.contains("pressure state and headroom are unavailable"))
        XCTAssertTrue(combined.contains("L10n.text(\"内存压力\", \"Memory Pressure\")"))
        XCTAssertTrue(combined.contains("value: memoryPressureDisplayText"))
        XCTAssertTrue(status.contains("for: .memoryUsage"))
        XCTAssertTrue(status.contains("displayMemorySnapshot?.reportablePressureLevel"))
        XCTAssertFalse(status.contains("displayMemorySnapshot?.pressureLevel"))
        XCTAssertTrue(overview.contains("$0.reportablePressureLevel?.title"))
        XCTAssertTrue(utilities.contains("snapshot.reportablePressureLevel"))
        XCTAssertTrue(utilities.contains("private var pressureSummary: some View"))
        XCTAssertTrue(utilities.contains("snapshot.pressureHeadroomPercent.map"))
        XCTAssertTrue(utilities.contains("L10n.text(\"内存压力\", \"Memory Pressure\")"))
        XCTAssertTrue(utilities.contains("result.snapshot.reportablePressureLevel"))
        XCTAssertTrue(utilities.contains("execution.snapshotBefore.reportablePressureLevel"))
        XCTAssertTrue(utilities.contains("execution.snapshotAfter?.reportablePressureLevel"))
        XCTAssertTrue(telemetry.contains("snapshot.pressureEstimatePercent.map(Double.init)"))
        XCTAssertFalse(components.contains("var memoryPressurePercentText"))
    }

    func testGeekOverviewKeepsPrimaryTrendsAndSensorsUseCompactRegionalRows() throws {
        let panelSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )
        let sensorSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift"
        )
        let overview = try XCTUnwrap(
            panelSource.components(separatedBy: "var geekCanvas: some View").last?
                .components(separatedBy: "var geekProcessorPage: some View").first
        )
        let networkCard = try XCTUnwrap(
            panelSource.components(separatedBy: "var geekNetworkCard: some View").last?
                .components(separatedBy: "var geekDiskCard: some View").first
        )
        XCTAssertTrue(overview.contains("geekProcessorCard"))
        XCTAssertTrue(overview.contains("geekNetworkCard"))
        XCTAssertFalse(overview.contains("geekMemoryCard"))
        XCTAssertEqual(
            networkCard.components(separatedBy: "GeekPrecisionNetworkChart(").count - 1,
            1
        )
        XCTAssertEqual(
            sensorSource.components(separatedBy: "GeekPrecisionLineChart(").count - 1,
            0
        )
        XCTAssertEqual(
            GeekSensorTemperatureLayout.temperatureCardHeight(itemCount: 10),
            116
        )
        XCTAssertFalse(sensorSource.contains("GeekTemperatureMiniRing("))
        XCTAssertTrue(sensorSource.contains("Image(systemName: AppSymbols.Panel.disclosure)"))
        XCTAssertTrue(sensorSource.contains(
            "minHeight: GeekSensorTemperatureLayout.gridRowHeight"
        ))
        XCTAssertTrue(sensorSource.contains("LazyVGrid("))
        XCTAssertFalse(sensorSource.contains("GeekHardwareAuthorizationCard("))
        XCTAssertFalse(sensorSource.contains("GeekFanControlCard("))
        XCTAssertFalse(sensorSource.contains("GeekPowerModeControlCard("))
        XCTAssertTrue(sensorSource.contains("geekHardwareControlSummaryCard"))
        // Fan history and the inline control button share the fan row;
        // the control palette still supports hover and click pinning.
        XCTAssertTrue(sensorSource.contains("ControlPaletteHoverAnchor("))
        XCTAssertTrue(sensorSource.contains("selectedFanIndex: reading.index"))
        XCTAssertEqual(
            sensorSource.components(
                separatedBy: "GeekSensorTemperatureLayout.cardHeight("
            ).count - 1,
            0
        )
        XCTAssertEqual(
            sensorSource.components(
                separatedBy: "GeekSensorTemperatureLayout.temperatureCardHeight("
            ).count - 1,
            1
        )
        XCTAssertFalse(sensorSource.contains("GeekCombinedCard(height: 59)"))
        XCTAssertFalse(sensorSource.contains("GeekCombinedCard(height: 76)"))
        XCTAssertFalse(sensorSource.contains("GeekCombinedCard(height: 93)"))
        XCTAssertFalse(sensorSource.contains("GeekCombinedCard(height: 42)"))
        XCTAssertEqual(
            GeekPanelPresentationMetrics.detailSize(for: .sensors),
            .init(width: MiniWindowStyleTokens.detailWidth, height: GeekPanelPresentationMetrics.sensorsDetailHeight)
        )
        XCTAssertEqual(
            GeekPanelPresentationMetrics.detailVerticalOffset(for: .sensors),
            0
        )
        XCTAssertFalse(sensorSource.contains("geekFrequencyCard"))
        XCTAssertTrue(sensorSource.contains("compactFanHistoryRow"))
        XCTAssertTrue(sensorSource.contains("GeekFanHoverDetail("))
        XCTAssertFalse(sensorSource.contains("geekSensorPowerCard"))
        XCTAssertFalse(sensorSource.contains("geekSensorElectricalCard"))
        XCTAssertFalse(sensorSource.contains("if geekHasSensorPowerData"))
        XCTAssertFalse(sensorSource.contains("if monitorSnapshot == nil || geekHasFanData"))
    }

    func testGeekDiskCardHidesUnavailableActivityPlaceholder() throws {
        let panelSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )
        let diskCard = try XCTUnwrap(
            panelSource.components(separatedBy: "var geekDiskCard: some View").last?
                .components(separatedBy: "var geekSensorsCard: some View").first
        )

        XCTAssertTrue(diskCard.contains("storageSnapshot.userAvailableBytes"))
        XCTAssertTrue(diskCard.contains("storageSnapshot.totalBytes"))
        XCTAssertTrue(diskCard.contains("if let health = geekPrimaryDiskHealthText"))
        XCTAssertTrue(diskCard.contains("GeekDiskHealthTimestamp.checkedAt("))
        XCTAssertTrue(diskCard.contains("fallbackRemainingLifePercent: healthSummary?.diskRemainingLifePercent"))
        XCTAssertTrue(diskCard.contains("AppSymbols.Monitor.storage"))
    }

    func testGeekDiskChartUsesTimestampedSamplesForRenderability() throws {
        let charts = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift")
        let worker = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarPreparedChart.swift")
        let disk = try XCTUnwrap(charts.components(separatedBy: "struct GeekDiskIOChart: View {").last?
            .components(separatedBy: "struct GeekHoverValue").first)
        XCTAssertTrue(disk.contains("GeekPreparedDiskSummary(points: points, duration: duration)"))
        XCTAssertTrue(disk.contains("GeekPreparedDiskFrame(points: points"))
        XCTAssertFalse(disk.contains("GeekChartWindow.displayBuckets("))
        XCTAssertFalse(disk.contains("points.map"))
        XCTAssertTrue(worker.contains("MenuBarChartSample(date: $0.date"))
        XCTAssertTrue(worker.contains("intervalStart: { points[$0].intervalStart }"))
        XCTAssertTrue(disk.contains("prepared.reads[index]"))
        XCTAssertTrue(disk.contains("prepared.writes[index]"))
    }

    func testGeekChartsUseSingleLineLegendsAndKeepStatisticsInAccessibility() throws {
        let source = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift"
        )
        let legend = try XCTUnwrap(
            source.components(separatedBy: "private struct GeekChartLegend: View {").last
        )

        XCTAssertTrue(legend.contains("HStack(spacing: 6)"))
        XCTAssertFalse(legend.contains("AVG"))
        XCTAssertFalse(legend.contains("statistics"))
        XCTAssertTrue(source.contains(#"average \(unit.formatted(stats.average))"#))
        XCTAssertTrue(source.contains(#"maximum \(unit.formatted(stats.maximum))"#))
    }

    func testReadOnlyMiniWindowChartsExplainTheRealTimeWindowOnDemand() throws {
        let charts = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift"
        )
        let power = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift"
        )
        let lineChart = try XCTUnwrap(
            charts.components(separatedBy: "struct GeekPrecisionLineChart: View {").last?
                .components(separatedBy: "struct GeekPrecisionNetworkChart: View {").first
        )
        let networkChart = try XCTUnwrap(
            charts.components(separatedBy: "struct GeekPrecisionNetworkChart: View {").last?
                .components(separatedBy: "struct GeekDiskIOChart: View {").first
        )
        let powerChart = try XCTUnwrap(
            power.components(separatedBy: "struct GeekPowerHistoryChart: View {").last?
                .components(separatedBy: "struct GeekFanHoverDetail: View {").first
        )

        XCTAssertTrue(lineChart.contains(".accessibilityHint(samplingWindowDescription)"))
        XCTAssertTrue(lineChart.contains(".help(usesCPUHistoryBuckets || !showsSamplingDetails ? \"\" : samplingWindowDescription)"))
        XCTAssertTrue(lineChart.contains("GeekChartRange(rawValue: Int(duration))?.title"))
        XCTAssertTrue(lineChart.contains("style == .stackedBars ? TimeBucketAggregator.nearestFillDescription"))
        XCTAssertTrue(lineChart.contains("实测曲线；采样前、休眠和长缺口不连线。"))
        XCTAssertFalse(lineChart.contains("Text(samplingWindowDescription)"))
        XCTAssertTrue(networkChart.contains(
            ".accessibilityHint(TimeBucketAggregator.nearestFillDescription)"
        ))
        XCTAssertFalse(networkChart.contains(".help("))
        XCTAssertTrue(powerChart.contains(".accessibilityHint(helpText(statistics: statistics))"))
        XCTAssertFalse(powerChart.contains(".help(helpText)"))
        XCTAssertFalse(power.contains(".help(statisticsHelpText)"))
    }

    func testGeekSensorsPrioritizeRegionalRowsOverRedundantPeakCopy() throws {
        let processor = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekProcessorView.swift"
        )
        let sensors = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift"
        )

        XCTAssertTrue(processor.contains("geekProcessorCard"))
        XCTAssertFalse(processor.contains("geekPeakTemperature"))
        XCTAssertFalse(sensors.contains("geekPeakTemperature"))
        XCTAssertFalse(sensors.contains("GeekPrecisionLineChart("))
        XCTAssertTrue(sensors.contains("ForEach(geekDisplayedTemperatures)"))
        XCTAssertTrue(sensors.contains("geekTemperatureRow("))
        XCTAssertTrue(sensors.contains("compactMap { byZone[$0] }"))
        XCTAssertTrue(sensors.contains("private func geekTemperatureRow("))
        XCTAssertFalse(sensors.contains(
            "title: L10n.text(\"芯片温度\", \"Chip Temperature\")"
        ))
        XCTAssertFalse(sensors.contains(
            "L10n.text(\"芯片最高温\", \"Peak Chip Temp\"), value: metricValue(.chipTemperature)"
        ))
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeNetworkPoint(
        date: Date,
        upload: Int64?,
        download: Int64?
    ) -> MenuBarTelemetryPoint {
        MenuBarTelemetryPoint(
            date: date,
            cpuTotal: nil,
            cpuUser: nil,
            cpuSystem: nil,
            gpu: nil,
            memory: nil,
            chipTemperature: nil,
            fanRPM: nil,
            downBytesPerSecond: download,
            upBytesPerSecond: upload
        )
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
