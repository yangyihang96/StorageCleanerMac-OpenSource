import XCTest
import SwiftUI
import Combine
@testable import StorageCleanerMac

final class MenuBarPerformanceRegressionTests: XCTestCase {
    private func key(_ revision: Int, page: String = "cpu") -> MenuBarDerivedKey {
        .init(page: page, kind: "test", revision: String(revision), configuration: "360x100")
    }

    func testCacheRetainsOnlyCurrentRevisionAndEnforcesBytesAndPages() async {
        let cache = MenuBarDerivedCache(byteLimit: 100, pageLimit: 4)
        for index in 0..<12 {
            let _: Int = await cache.value(for: key(index), cost: 30) { index }
        }
        var stats = await cache.statistics()
        XCTAssertEqual(stats.entries, 1)
        for index in 0..<8 {
            let _: Int = await cache.value(for: key(index, page: String(index)), cost: 20) { index }
        }
        stats = await cache.statistics()
        XCTAssertLessThanOrEqual(stats.bytes, 100)
        XCTAssertEqual(stats.pages, 4)
        await cache.purge()
        stats = await cache.statistics()
        XCTAssertEqual(stats.entries, 0)
        XCTAssertEqual(stats.bytes, 0)
    }

    func testIdenticalConcurrentRequestsShareOnePreparation() async {
        let cache = MenuBarDerivedCache()
        let key = key(0)
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<20 { group.addTask { await cache.value(for: key, cost: 10) { 42 } } }
            for await value in group { XCTAssertEqual(value, 42) }
        }
        let stats = await cache.statistics()
        XCTAssertEqual(stats.builds, 1)
    }

    @MainActor
    func testUnrelatedCardChangesDoNotInvalidateMemory() {
        var cpu = 0.0
        var memory = 20.0
        let cpuCard = MenuBarCardModel(sources: [], fingerprint: { .init(values: [cpu]) })
        let memoryCard = MenuBarCardModel(sources: [], fingerprint: { .init(values: [memory]) })
        cpu = 50
        cpuCard.reconcile(); memoryCard.reconcile()
        XCTAssertEqual(cpuCard.revision.version, 1)
        XCTAssertEqual(memoryCard.revision.version, 0)
        memory = 30
        memoryCard.reconcile()
        XCTAssertEqual(memoryCard.revision.version, 1)
    }

    @MainActor
    func testLatestPreparationWinsAndClockDoesNotClearVisibleFrame() async throws {
        let model = MenuBarPreparedChartModel<Int>(cache: MenuBarDerivedCache())
        model.request(key: key(0), cost: 8) { 0 }
        for _ in 0..<100 where model.value == nil { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(model.value, 0)
        model.request(key: key(1), cost: 8) { Thread.sleep(forTimeInterval: 0.03); return 1 }
        XCTAssertEqual(model.value, 0)
        model.request(key: key(2), cost: 8) { 2 }
        for _ in 0..<100 where model.value != 2 { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(model.value, 2)
        model.request(key: key(3), cost: 8) { Thread.sleep(forTimeInterval: 0.03); return 3 }
        model.stop()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.value, 2)
    }

    @MainActor
    func testReturningToDisplayedRevisionRejectsInFlightOldIntent() async throws {
        let model = MenuBarPreparedChartModel<Int>(cache: MenuBarDerivedCache())
        model.request(key: key(0), cost: 8) { 0 }
        for _ in 0..<100 where model.value == nil { try await Task.sleep(for: .milliseconds(2)) }
        model.request(key: key(1), cost: 8) { Thread.sleep(forTimeInterval: 0.03); return 1 }
        await Task.yield()
        model.request(key: key(0), cost: 8) { 0 }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(model.value, 0)
    }

    func testProcessSamplerSkipsOverlapAndResetRejectsLateRead() async throws {
        let reader = DelayedFrameReader()
        let sampler = MenuBarProcessSampler(read: { await reader.read() })
        let first = Task { await sampler.sample() }
        while await reader.count == 0 { await Task.yield() }
        let overlap = await sampler.sample()
        XCTAssertNil(overlap)
        await sampler.reset()
        await reader.complete(Self.frame(1))
        let result = await first.value
        XCTAssertNil(result)
        let count = await reader.count
        XCTAssertEqual(count, 1)
        let next = Task { await sampler.sample() }
        while await reader.count < 2 { await Task.yield() }
        await reader.complete(Self.frame(2))
        let baseline = await next.value
        XCTAssertNil(baseline)
    }

    func testProcessRateUsesActualElapsedTimeAndRejectsPIDReuseOrReset() throws {
        let first = Self.frame(1)
        let second = Self.frame(4)
        let result = try XCTUnwrap(EnergyImpactService.menuBarSnapshot(previous: first, current: second))
        XCTAssertEqual(result.sampleSeconds, 3)
        XCTAssertEqual(result.generatedAt, second.sampledAt)
        XCTAssertNil(EnergyImpactService.menuBarSnapshot(previous: second, current: first))
        XCTAssertNil(EnergyImpactService.menuBarSnapshot(previous: first, current: Self.frame(4, identity: 2)))
    }

    @MainActor
    func testHiddenHistoryStopsAndIdenticalDemandDoesNotRepeatPreparation() async throws {
        let monitor = MenuBarMonitorState()
        monitor.restoreHistory(Self.points(count: 3600))
        monitor.setDisplayHistoryDemand([3600])
        for _ in 0..<100 where monitor.displayTelemetryVersion == 0 { try await Task.sleep(for: .milliseconds(2)) }
        let version = monitor.displayTelemetryVersion
        XCTAssertGreaterThan(version, 0)
        monitor.setDisplayHistoryDemand([3600])
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(monitor.displayTelemetryVersion, version)
        let visibleWindow = monitor.displayHistory(within: 3600)
        monitor.setDisplayHistoryDemand([])
        monitor.restoreHistory(Self.points(count: 10))
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(monitor.displayTelemetryVersion, version)
        // D39: the last visible window is kept for the next opening (not
        // released, and not prepared again from the new history while hidden).
        XCTAssertFalse(visibleWindow.isEmpty)
        XCTAssertEqual(monitor.displayHistory(within: 3600), visibleWindow)
    }

    func testDiskPreparationPreservesWeightedIntervalsAndUniformAppearance() {
        let end = Date(timeIntervalSince1970: 864000)
        let points = (0..<3600).map { index in NativeDiskIOPoint(
            date: end.addingTimeInterval(Double(index - 3599)), readBytesPerSecond: 100,
            writeBytesPerSecond: 50, readOperationsPerSecond: 0, writeOperationsPerSecond: 0,
            intervalStart: end.addingTimeInterval(Double(index - 3600))) }
        let frame = GeekPreparedDiskFrame(points: points, plot: .init(x: 0, y: 0, width: 360, height: 100),
                                          duration: 3600, reference: end, scale: 2)
        XCTAssertEqual(frame.readMarks.count, 120)
        XCTAssertTrue(frame.readMarks.allSatisfy { $0.value == 100 })
        XCTAssertTrue(frame.writeMarks.allSatisfy { $0.value == 50 })
    }

    func testDiskPeakSummaryUsesSelectedRangeAndDistinguishesEmptyFromActualZero() throws {
        let end = Date(timeIntervalSince1970: 864_000)
        let points: [NativeDiskIOPoint] = [
            .init(date: end.addingTimeInterval(-7_200), readBytesPerSecond: 900_000_000,
                  writeBytesPerSecond: 800_000_000, readOperationsPerSecond: 0, writeOperationsPerSecond: 0),
            .init(date: end.addingTimeInterval(-3_600), readBytesPerSecond: 200_000,
                  writeBytesPerSecond: 300_000, readOperationsPerSecond: 0, writeOperationsPerSecond: 0),
            .init(date: end.addingTimeInterval(-2), readBytesPerSecond: 100_000,
                  writeBytesPerSecond: 400_000, readOperationsPerSecond: 0, writeOperationsPerSecond: 0),
            .init(date: end, readBytesPerSecond: 0, writeBytesPerSecond: 0,
                  readOperationsPerSecond: 0, writeOperationsPerSecond: 0),
        ]
        let hour = GeekPreparedDiskSummary(points: points, duration: 3_600, referenceDate: end)
        XCTAssertEqual(hour.readPeakBytesPerSecond, 200_000)
        XCTAssertEqual(hour.writePeakBytesPerSecond, 400_000)
        XCTAssertEqual(try XCTUnwrap(hour.read).maximum, Double(try XCTUnwrap(hour.readPeakBytesPerSecond)))
        XCTAssertEqual(try XCTUnwrap(hour.write).maximum, Double(try XCTUnwrap(hour.writePeakBytesPerSecond)))
        XCTAssertEqual(hour.readPeakText, GeekChartUnit.bytesPerSecond.formatted(200_000))
        let short = GeekPreparedDiskSummary(points: points, duration: 60, referenceDate: end)
        XCTAssertEqual(short.readPeakBytesPerSecond, 100_000)
        let day = GeekPreparedDiskSummary(points: points, duration: 86_400, referenceDate: end)
        XCTAssertEqual(day.readPeakBytesPerSecond, 900_000_000)
        XCTAssertEqual(day.writePeakBytesPerSecond, 800_000_000)
        let empty = GeekPreparedDiskSummary(points: [], duration: 3_600, referenceDate: end)
        XCTAssertNil(empty.readPeakBytesPerSecond)
        XCTAssertEqual(empty.readPeakText, "--")
        let zero = GeekPreparedDiskSummary(points: Array(points.suffix(1)), duration: 3_600, referenceDate: end)
        XCTAssertEqual(zero.readPeakBytesPerSecond, 0)
        XCTAssertEqual(zero.readPeakText, "0 B/s")
    }

    func testDiskPeakAndChartConsumersSharePreparationButRangeChangesInvalidate() async {
        let end = Date(timeIntervalSince1970: 864_000)
        let points = [NativeDiskIOPoint(date: end, readBytesPerSecond: 256, writeBytesPerSecond: 512,
            readOperationsPerSecond: 0, writeOperationsPerSecond: 0)]
        let cache = MenuBarDerivedCache()
        let configuration = GeekPreparedDiskSummary.preparationConfiguration(duration: 3_600)
        let sharedKey = MenuBarDerivedKey(page: "disk", kind: GeekPreparedDiskSummary.preparationKind,
            revision: "fixture", configuration: configuration)
        await withTaskGroup(of: GeekPreparedDiskSummary.self) { group in
            // Peak row plus combined/read/write plot summaries use this same
            // production key; the mode changes drawing, not the statistics.
            for _ in 0..<4 {
                group.addTask { await cache.value(for: sharedKey, cost: 512) {
                    GeekPreparedDiskSummary(points: points, duration: 3_600, referenceDate: end)
                } }
            }
            for await summary in group { XCTAssertEqual(summary.readPeakBytesPerSecond, 256) }
        }
        var statistics = await cache.statistics()
        XCTAssertEqual(statistics.builds, 1)
        let dayKey = MenuBarDerivedKey(page: "disk", kind: GeekPreparedDiskSummary.preparationKind,
            revision: "fixture", configuration: GeekPreparedDiskSummary.preparationConfiguration(duration: 86_400))
        let _: GeekPreparedDiskSummary = await cache.value(for: dayKey, cost: 512) {
            GeekPreparedDiskSummary(points: points, duration: 86_400, referenceDate: end)
        }
        statistics = await cache.statistics()
        XCTAssertEqual(statistics.builds, 2)
    }

    func testDiskPeakSummaryExpiresBoundarySampleAsVisibleWindowAdvances() throws {
        let end = Date(timeIntervalSince1970: 864_000)
        let points: [NativeDiskIOPoint] = [
            .init(date: end.addingTimeInterval(-3_600), readBytesPerSecond: 900_000,
                  writeBytesPerSecond: 800_000, readOperationsPerSecond: 0, writeOperationsPerSecond: 0),
            .init(date: end.addingTimeInterval(-2), readBytesPerSecond: 100,
                  writeBytesPerSecond: 200, readOperationsPerSecond: 0, writeOperationsPerSecond: 0),
            .init(date: end, readBytesPerSecond: 100, writeBytesPerSecond: 200,
                  readOperationsPerSecond: 0, writeOperationsPerSecond: 0),
        ]
        let clockDate = end.addingTimeInterval(1)
        let frame = GeekPreparedDiskFrame(points: points,
            plot: CGRect(x: 0, y: 0, width: 280, height: 106),
            duration: 3_600, reference: clockDate, scale: 2)
        let summary = GeekPreparedDiskSummary(points: points, duration: 3_600, referenceDate: clockDate)
        XCTAssertEqual(summary.readPeakBytesPerSecond, 100,
            "A paused chart must drop the peak outside the current window, not anchor it to the last sample")
        XCTAssertEqual(summary.writePeakBytesPerSecond, 200)
        XCTAssertEqual(frame.range.end, clockDate)
        XCTAssertEqual(frame.reads.compactMap { $0 }.max(), 100)
        XCTAssertEqual(frame.writes.compactMap { $0 }.max(), 200)
    }

    func testDiskSummaryProductionKeysInvalidateWithinOneClockSecond() async {
        let end = Date(timeIntervalSince1970: 864_000)
        let points: [NativeDiskIOPoint] = [
            .init(date: end.addingTimeInterval(-3_600 + 0.25), readBytesPerSecond: 900_000,
                  writeBytesPerSecond: 800_000, readOperationsPerSecond: 0, writeOperationsPerSecond: 0),
            .init(date: end, readBytesPerSecond: 100, writeBytesPerSecond: 200,
                  readOperationsPerSecond: 0, writeOperationsPerSecond: 0),
        ]
        let beforeBoundary = end.addingTimeInterval(0.20)
        let afterBoundary = end.addingTimeInterval(0.30)
        XCTAssertEqual(floor(beforeBoundary.timeIntervalSince1970), floor(afterBoundary.timeIntervalSince1970))
        let context = MenuBarChartContext(page: "disk-clock-fixture", revision: .init(sampledAt: end, version: 1))
        let configuration = GeekPreparedDiskSummary.preparationConfiguration(duration: 3_600)
        let beforeKey = context.key(kind: GeekPreparedDiskSummary.preparationKind,
            first: points.first?.date, last: points.last?.date, count: points.count,
            clockRevision: beforeBoundary.timeIntervalSince1970, configuration: configuration)
        let afterKey = context.key(kind: GeekPreparedDiskSummary.preparationKind,
            first: points.first?.date, last: points.last?.date, count: points.count,
            clockRevision: afterBoundary.timeIntervalSince1970, configuration: configuration)
        XCTAssertNotEqual(beforeKey, afterKey)
        XCTAssertEqual(beforeKey.family, afterKey.family)
        let cache = MenuBarDerivedCache()
        let before: GeekPreparedDiskSummary = await cache.value(for: beforeKey, cost: 512) {
            GeekPreparedDiskSummary(points: points, duration: 3_600, referenceDate: beforeBoundary)
        }
        let after: GeekPreparedDiskSummary = await cache.value(for: afterKey, cost: 512) {
            GeekPreparedDiskSummary(points: points, duration: 3_600, referenceDate: afterBoundary)
        }
        XCTAssertEqual(before.referenceDate, beforeBoundary)
        XCTAssertEqual(before.readPeakBytesPerSecond, 900_000)
        XCTAssertEqual(before.writePeakBytesPerSecond, 800_000)
        XCTAssertEqual(after.referenceDate, afterBoundary)
        XCTAssertEqual(after.readPeakBytesPerSecond, 100)
        XCTAssertEqual(after.writePeakBytesPerSecond, 200)
        let cached: GeekPreparedDiskSummary = await cache.value(for: afterKey, cost: 512) {
            GeekPreparedDiskSummary(points: [], duration: 3_600, referenceDate: end)
        }
        XCTAssertEqual(cached.referenceDate, afterBoundary)
        XCTAssertEqual(cached.readPeakBytesPerSecond, 100)
        let statistics = await cache.statistics()
        XCTAssertEqual(statistics.builds, 2)
        XCTAssertEqual(statistics.entries, 1)
    }

    func testDiskSummaryExcludesFutureAndExpiresToUnknownWithoutInventingZero() {
        let end = Date(timeIntervalSince1970: 864_000)
        let points: [NativeDiskIOPoint] = [
            .init(date: end.addingTimeInterval(-1), readBytesPerSecond: 0, writeBytesPerSecond: 0,
                  readOperationsPerSecond: 0, writeOperationsPerSecond: 0),
            .init(date: end, readBytesPerSecond: 0, writeBytesPerSecond: 0,
                  readOperationsPerSecond: 0, writeOperationsPerSecond: 0),
            .init(date: end.addingTimeInterval(0.25), readBytesPerSecond: 900_000,
                  writeBytesPerSecond: 800_000, readOperationsPerSecond: 0, writeOperationsPerSecond: 0),
        ]
        let zero = GeekPreparedDiskSummary(points: points, duration: 3_600, referenceDate: end)
        XCTAssertEqual(zero.referenceDate, end)
        XCTAssertEqual(zero.readPeakBytesPerSecond, 0)
        XCTAssertEqual(zero.writePeakBytesPerSecond, 0)
        XCTAssertEqual(zero.readPeakText, "0 B/s")
        XCTAssertEqual(zero.writePeakText, "0 B/s")
        let expiredDate = end.addingTimeInterval(3_600.5)
        let expired = GeekPreparedDiskSummary(points: points, duration: 3_600, referenceDate: expiredDate)
        XCTAssertEqual(expired.referenceDate, expiredDate)
        XCTAssertFalse(expired.hasData)
        XCTAssertNil(expired.read)
        XCTAssertNil(expired.write)
        XCTAssertNil(expired.readPeakBytesPerSecond)
        XCTAssertNil(expired.writePeakBytesPerSecond)
        XCTAssertEqual(expired.readPeakText, "--")
        XCTAssertEqual(expired.writePeakText, "--")
        let frame = GeekPreparedDiskFrame(points: points,
            plot: .init(x: 0, y: 0, width: 280, height: 106), duration: 3_600,
            reference: expiredDate, scale: 2)
        XCTAssertEqual(frame.range.end, expiredDate)
        XCTAssertTrue(frame.reads.compactMap { $0 }.isEmpty)
        XCTAssertTrue(frame.writes.compactMap { $0 }.isEmpty)
    }

    @MainActor
    func testDelayedDiskSummaryRetainsItsOwnEndpointAndRejectsObsoleteClockRequests() async throws {
        let end = Date(timeIntervalSince1970: 864_000)
        let points: [NativeDiskIOPoint] = [
            .init(date: end.addingTimeInterval(-3_600 + 0.25), readBytesPerSecond: 900_000,
                  writeBytesPerSecond: 800_000, readOperationsPerSecond: 0, writeOperationsPerSecond: 0),
            .init(date: end, readBytesPerSecond: 100, writeBytesPerSecond: 200,
                  readOperationsPerSecond: 0, writeOperationsPerSecond: 0),
        ]
        let context = MenuBarChartContext(page: "disk-delayed-fixture", revision: .init(sampledAt: end, version: 1))
        func summaryKey(_ date: Date) -> MenuBarDerivedKey {
            context.key(kind: GeekPreparedDiskSummary.preparationKind,
                first: points.first?.date, last: points.last?.date, count: points.count,
                clockRevision: date.timeIntervalSince1970,
                configuration: GeekPreparedDiskSummary.preparationConfiguration(duration: 3_600))
        }
        let cache = MenuBarDerivedCache()
        let model = MenuBarPreparedChartModel<GeekPreparedDiskSummary>(cache: cache)
        let gate = DiskSummaryClockFixtureGate()
        defer { gate.release(); model.stop() }
        var deliveredReferences: [Date] = []
        let observation = model.$value.sink { value in
            if let value { deliveredReferences.append(value.referenceDate) }
        }
        defer { observation.cancel() }
        model.request(key: summaryKey(end), cost: 512) {
            GeekPreparedDiskSummary(points: points, duration: 3_600, referenceDate: end)
        }
        for _ in 0..<100 where model.value == nil { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(model.value?.referenceDate, end)
        XCTAssertEqual(model.value?.readPeakBytesPerSecond, 900_000)
        let slowDate = end.addingTimeInterval(0.20)
        model.request(key: summaryKey(slowDate), cost: 512) {
            gate.waitForRelease()
            return GeekPreparedDiskSummary(points: points, duration: 3_600, referenceDate: slowDate)
        }
        for _ in 0..<100 where !gate.hasStarted { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(gate.hasStarted)
        XCTAssertEqual(model.value?.referenceDate, end)
        XCTAssertEqual(model.value?.readPeakBytesPerSecond, 900_000)
        let intermediateDate = end.addingTimeInterval(0.30)
        let latestDate = end.addingTimeInterval(0.40)
        model.request(key: summaryKey(intermediateDate), cost: 512) {
            GeekPreparedDiskSummary(points: points, duration: 3_600, referenceDate: intermediateDate)
        }
        model.request(key: summaryKey(latestDate), cost: 512) {
            GeekPreparedDiskSummary(points: points, duration: 3_600, referenceDate: latestDate)
        }
        XCTAssertEqual(model.value?.referenceDate, end)
        gate.release()
        for _ in 0..<100 where model.value?.referenceDate != latestDate { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(model.value?.referenceDate, latestDate)
        XCTAssertEqual(model.value?.readPeakBytesPerSecond, 100)
        XCTAssertEqual(model.value?.writePeakBytesPerSecond, 200)
        XCTAssertEqual(deliveredReferences, [end, latestDate])
        let statistics = await cache.statistics()
        XCTAssertEqual(statistics.builds, 3, "The intermediate clock request must be coalesced, never prepared or published")
        XCTAssertEqual(statistics.entries, 1)
    }

    // This measures preparation and cache delivery, never claims physical screen latency.
    func testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets() async throws {
#if DEBUG
        throw XCTSkip("Timing is enforced against optimized shipping code by the local packaging gate.")
#else
        let points = Self.points(count: 44000)
        let cache = MenuBarDerivedCache()
        var preparation: [Double] = []
        var cached: [Double] = []
        for index in 0..<20 {
            let key = key(index)
            let start = ProcessInfo.processInfo.systemUptime
            let frame = await cache.value(for: key, cost: points.count * 384) {
                GeekPreparedLineFrame(points: points, channels: [.cpuUser, .cpuSystem],
                    plot: .init(x: 0, y: 0, width: 360, height: 100), duration: 28 * 86400,
                    reference: points.last!.date, samplingInterval: 1, scale: 2,
                    stacked: true, valueRange: 0...100)
            }
            preparation.append(ProcessInfo.processInfo.systemUptime - start)
            XCTAssertFalse(frame.buckets.isEmpty)
            let cachedStart = ProcessInfo.processInfo.systemUptime
            let _: GeekPreparedLineFrame = await cache.value(for: key, cost: 0) { frame }
            cached.append(ProcessInfo.processInfo.systemUptime - cachedStart)
        }
        let p95 = preparation.sorted()[18]
        let cachedP95 = cached.sorted()[18]
        print("MENU_PERF preparation_p95_ms=\(p95 * 1000) cached_delivery_p95_ms=\(cachedP95 * 1000)")
        XCTAssertLessThanOrEqual(p95, MenuBarPerformancePolicy.publicationBudget)
        XCTAssertLessThanOrEqual(cachedP95, MenuBarPerformancePolicy.warmPresentationBudget)
#endif
    }

    private static func points(count: Int) -> [MenuBarTelemetryPoint] {
        let end = Date()
        return (0..<count).map { index in .init(date: end.addingTimeInterval(Double(index - count)),
            cpuTotal: 40, cpuUser: 30, cpuSystem: 10, gpu: nil, memory: 50,
            chipTemperature: 45, fanRPM: nil, downBytesPerSecond: 100, upBytesPerSecond: 50) }
    }

    private static func frame(_ time: Double, identity: UInt64 = 1) -> EnergyImpactService.MenuBarCounterFrame {
        let rows = EnergyImpactService.processRows(fromPSOutput: "101 1 1024 user 00:01 10 /Applications/Test.app/Contents/MacOS/Test")
        return .init(sampledAt: Date(timeIntervalSince1970: time), uptime: time, rows: rows,
                     counters: [101: EnergyResourceUsage(pid: 101, energyNanojoules: UInt64(time * 1_000_000_000),
                         cpuTimeMach: UInt64(time * 1_000_000), processStartMach: identity,
                         diskReadBytes: UInt64(time * 100), diskWrittenBytes: UInt64(time * 50))])
    }
}

private actor DelayedFrameReader {
    var count = 0
    var continuation: CheckedContinuation<EnergyImpactService.MenuBarCounterFrame?, Never>?
    func read() async -> EnergyImpactService.MenuBarCounterFrame? {
        count += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func complete(_ frame: EnergyImpactService.MenuBarCounterFrame?) {
        continuation?.resume(returning: frame)
        continuation = nil
    }
}

// Only the detached fixture worker waits here. The test's main actor remains
// free to submit newer intents; release is bounded even if an assertion fails.
private final class DiskSummaryClockFixtureGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var started = false

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func waitForRelease() {
        lock.lock()
        started = true
        lock.unlock()
        _ = semaphore.wait(timeout: .now() + 2)
    }

    func release() { semaphore.signal() }
}
