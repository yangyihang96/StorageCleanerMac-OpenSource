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
        monitor.setDisplayHistoryDemand([])
        monitor.restoreHistory(Self.points(count: 10))
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(monitor.displayTelemetryVersion, version)
        XCTAssertTrue(monitor.displayHistory(within: 3600).isEmpty)
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
