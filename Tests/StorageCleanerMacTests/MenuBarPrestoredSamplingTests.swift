import FanControlShared
import Foundation
import XCTest
@testable import StorageCleanerMac

final class MenuBarPrestoredSamplingTests: XCTestCase {
    func testSchedulingMatrixAndStatusVisibilityDoesNotDisablePrestorage() {
        for visible in [false, true] {
            for lowPower in [false, true] {
                for suspended in [false, true] {
                    for selected in [1.0, 2.0, 5.0] {
                        let cadence = MenuBarSamplingCadence.resolve(visible: visible, lowPower: lowPower,
                            suspended: suspended, selectedInterval: selected)
                        XCTAssertEqual(cadence.cheap, lowPower ? 30 : (visible ? selected : 5))
                        XCTAssertEqual(cadence.expensive, lowPower ? 30 : 5)
                        XCTAssertEqual(cadence.processes, lowPower ? 60 : (visible ? 10 : 15))
                        XCTAssertEqual(cadence.networkProcesses, lowPower ? (visible ? 60 : 180) : (visible ? 10 : 60),
                            "D75 changes only hidden nettop; existing visible and low-power-visible policies remain")
                        XCTAssertEqual(cadence.helperPower, lowPower ? 180 : (visible ? 5 : 60))
                        XCTAssertEqual(cadence.suspended, suspended)
                        let plan = MenuBarSamplingPlan.resolve(statusMode: .memory, statusVisible: false,
                            panelVisible: visible, visibleKinds: [], customFanControlActive: false,
                            paused: false, lowPower: lowPower, suspended: suspended, selectedInterval: selected)
                        XCTAssertEqual(plan.primaryKinds, suspended ? [] : MenuBarMetricKind.defaultSelection)
                    }
                }
            }
        }
    }

    @MainActor
    func testHiddenSampleIsShownImmediatelyAfterLongGapWithOriginalTime() {
        let language = MiniWindowLogicLanguageScope(.zhHans)
        defer { language.restore() }
        let at = Date(timeIntervalSince1970: 100_000)
        let context = MenuBarSamplingContext()
        context.configure(statusMode: .memory, statusVisible: false, panelVisible: false,
            customFanControlActive: false, paused: false, now: at)
        context.rememberPanelSnapshot(.init(generatedAt: at, metrics: [], networkThroughput: nil,
            cpuUsageBreakdown: .init(totalPercent: 30, userPercent: 20, systemPercent: 10)))
        let opened = at.addingTimeInterval(3_600)
        context.configure(statusMode: .memory, statusVisible: false, panelVisible: true,
            customFanControlActive: false, paused: false, now: opened)
        let shown = context.presentationSnapshot(live: nil, now: opened)
        XCTAssertEqual(shown?.generatedAt, at)
        XCTAssertEqual(shown?.cpuUsageBreakdown?.totalPercent, 30)
        XCTAssertEqual(PanelTimestampFormat.age(at, now: opened), "3600 秒前")
        XCTAssertFalse(PanelChartSampling.placeholderText(sampledAt: shown?.generatedAt, isPaused: false, now: opened)
            .contains("正在采样"))
    }

    @MainActor
    func testCheapPublicationRetainsEachStoredHardwareDateWithoutWritingHistory() {
        let at = Date(timeIntervalSince1970: 100_000)
        let context = MenuBarSamplingContext()
        context.configure(statusMode: .cpu, statusVisible: false, panelVisible: false,
            customFanControlActive: false, paused: false)
        let hardware = SystemMonitorSnapshot(generatedAt: at, metrics: [], networkThroughput: nil,
            cpuUsageBreakdown: .init(totalPercent: 30, userPercent: 20, systemPercent: 10),
            fanSpeedsRPM: [0], fanCount: 1, gpuMemoryUsedBytes: 1_024,
            sensorAvailability: .available, fanAvailability: .available,
            sensorSampledAt: at.addingTimeInterval(-1), gpuSampledAt: at.addingTimeInterval(-2))
        context.rememberPanelSnapshot(hardware)
        let cheap = SystemMonitorSnapshot(generatedAt: at.addingTimeInterval(3_600), metrics: [], networkThroughput: nil,
            cpuUsageBreakdown: .init(totalPercent: 40, userPercent: 20, systemPercent: 20),
            sensorAvailability: .sampling, fanAvailability: .sampling)
        context.rememberPanelSnapshot(cheap)
        context.configure(statusMode: .cpu, statusVisible: false, panelVisible: true,
            customFanControlActive: false, paused: false)
        let shown = context.presentationSnapshot(live: cheap, now: cheap.generatedAt)
        XCTAssertEqual(shown?.cpuUsageBreakdown?.totalPercent, 40)
        XCTAssertEqual(shown?.generatedAt, cheap.generatedAt)
        XCTAssertEqual(shown?.sensorSampledAt, hardware.sensorSampledAt)
        XCTAssertEqual(shown?.gpuSampledAt, hardware.gpuSampledAt)
        XCTAssertEqual(shown?.fanSpeedsRPM, [0])
        XCTAssertEqual(shown?.gpuMemoryUsedBytes, 1_024)
        XCTAssertEqual(cheap.sensorAvailability, .sampling, "raw collection snapshot remains untouched for history")
        XCTAssertNil(cheap.sensorSampledAt)
    }

    @MainActor
    func testWaitingOnlyWithoutSampleAndRelativeTimeUsesSourceDate() {
        let language = MiniWindowLogicLanguageScope(.zhHans)
        defer { language.restore() }
        let at = Date(timeIntervalSince1970: 10_000), now = Date(timeIntervalSince1970: 10_012.9)
        XCTAssertEqual(PanelTimestampFormat.age(at, now: now), "12 秒前")
        XCTAssertEqual(PanelTimestampFormat.age(now, now: at), "采样时间未知")
        XCTAssertEqual(PanelChartSampling.placeholderText(sampledAt: nil, isPaused: false, now: now), "正在采样…")
        XCTAssertEqual(PanelChartSampling.placeholderText(sampledAt: nil, isPaused: true, now: now), "已暂停")
        XCTAssertEqual(GeekOnDemandSnapshotFreshness.statusText(generatedAt: at, now: now, isSampling: true), "更新 12 秒前")
        XCTAssertEqual(GeekOnDemandSnapshotFreshness.statusText(generatedAt: nil, now: now, isSampling: true), "正在采样…")
        let reading = MenuBarNetworkReading(date: at, downBytesPerSecond: 100, upBytesPerSecond: 10)
        let rates = MenuBarNetworkReadout.rates(current: nil, lastReading: reading,
            now: at.addingTimeInterval(3_600), retainsStoredReading: true)
        XCTAssertEqual(rates.down, 100)
        XCTAssertEqual(rates.up, 10)
    }

    @MainActor
    func testHiddenHelperUsesSixtySecondsAndOpeningRetainsSampleThenRefreshes() async {
        let time = Box(0.0), calls = Box(0)
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            calls.value += 1; return .sample(Self.power)
        }, now: { time.value }, wallClock: { Date(timeIntervalSince1970: time.value) }, automaticSampling: false)
        monitor.useResidentScheduler()
        monitor.setResidentCadence(.resolve(visible: false, lowPower: false, suspended: false))
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 1)
        let original = monitor.state
        for tick in [5.0, 15, 30, 59.99] { time.value = tick; await monitor.sampleIfDue() }
        XCTAssertEqual(calls.value, 1)
        time.value = 60
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 2)
        let kept = monitor.state
        let consumer = UUID()
        monitor.updateConsumer(consumer, visible: true)
        XCTAssertEqual(monitor.state, kept, "opening does not introduce a wait state")
        monitor.setResidentCadence(.resolve(visible: true, lowPower: false, suspended: false))
        time.value = 65
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 3)
        monitor.updateConsumer(consumer, visible: false)
        XCTAssertNotEqual(monitor.state, original)
        XCTAssertEqual(monitor.history.map(\.date), [0.0, 60, 65].map { Date(timeIntervalSince1970: $0) })
    }

    @MainActor
    func testHelperSingleFlightSleepRejectsReplyAndLowPowerHonorsLongInterval() async {
        let time = Box(100.0), calls = Box(0)
        let gate = Box<CheckedContinuation<PowermetricsResult, Never>?>(nil)
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            calls.value += 1
            guard calls.value == 1 else { return .sample(Self.power) }
            return await withCheckedContinuation { gate.value = $0 }
        }, now: { time.value }, automaticSampling: false)
        monitor.useResidentScheduler()
        monitor.setResidentCadence(.resolve(visible: false, lowPower: false, suspended: false))
        let pending = Task { await monitor.sampleIfDue() }
        for _ in 0..<10_000 where gate.value == nil { await Task.yield() }
        guard let continuation = gate.value else { pending.cancel(); return XCTFail("helper gate did not start") }
        time.value = 200
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 1, "one physical request even after its interval elapsed")
        monitor.setResidentSuspended(true)
        continuation.resume(returning: .sample(Self.power))
        await pending.value
        XCTAssertNil(monitor.state.sampledAt, "sleep-invalidated reply is not stored")
        XCTAssertTrue(monitor.history.isEmpty)
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 1)
        monitor.setResidentCadence(.resolve(visible: true, lowPower: true, suspended: false))
        time.value = 279.99
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 1)
        time.value = 280
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 2)
    }

    @MainActor
    func testFailedResidentRefreshKeepsSuccessfulHelperReadingAndCacheIsBounded() async {
        let time = Box(0.0), failure = Box(false)
        let manyClusters = PowermetricsSample(cpuMilliwatts: 5_000, gpuMilliwatts: nil, aneMilliwatts: nil,
            clusters: (0..<16).map { .init(name: "P\($0)", kind: .performance, megahertz: 3_000) },
            gpuMegahertz: nil, durationSeconds: 1)
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            failure.value ? .failure(.timedOut) : .sample(manyClusters)
        }, now: { time.value }, wallClock: { Date(timeIntervalSince1970: time.value) }, automaticSampling: false)
        monitor.useResidentScheduler()
        monitor.setResidentCadence(.resolve(visible: false, lowPower: false, suspended: false))
        await monitor.sampleIfDue()
        let successful = monitor.state
        failure.value = true; time.value = 60
        await monitor.sampleIfDue()
        XCTAssertEqual(monitor.state, successful)
        XCTAssertEqual(monitor.lastFailure, .timedOut)
        failure.value = false
        for index in 2..<4_002 { time.value = Double(index) * 60; await monitor.sampleIfDue() }
        XCTAssertLessThanOrEqual(monitor.historyBytes, MenuBarPerformancePolicy.processCacheByteLimit)
        XCTAssertLessThan(monitor.history.count, 4_000, "eviction must happen, not just a documented limit")
        XCTAssertEqual(monitor.history.last?.date, Date(timeIntervalSince1970: time.value))
    }

    @MainActor
    func testResidentMetadataUsesSharedFlightGateAndKeepsHiddenCadence() async throws {
        let context = MenuBarSamplingContext()
        let calls = Box(0)
        let at = Date(timeIntervalSince1970: 100_000)
        context.configure(statusMode: .memory, statusVisible: false, panelVisible: false,
            customFanControlActive: false, paused: false)
        func request(_ date: Date) {
            context.refreshResidentRead("metadata", now: date) { calls.value += 1 }
        }
        request(at); request(at)
        try await waitUntil { context.activeVisibleReadCount == 0 }
        XCTAssertEqual(calls.value, 1)
        request(at.addingTimeInterval(59.99))
        XCTAssertEqual(context.activeVisibleReadCount, 0)
        request(at.addingTimeInterval(60))
        try await waitUntil { context.activeVisibleReadCount == 0 }
        XCTAssertEqual(calls.value, 2)
        context.configure(statusMode: .memory, statusVisible: false, panelVisible: true,
            customFanControlActive: false, paused: false)
        context.refreshVisibleRead("metadata", now: at.addingTimeInterval(65)) { calls.value += 1 }
        try await waitUntil { context.activeVisibleReadCount == 0 }
        XCTAssertEqual(calls.value, 3, "visible read shares the resident source gate")
        context.configure(statusMode: .memory, statusVisible: false, panelVisible: true,
            customFanControlActive: false, paused: false, suspended: true)
        request(at.addingTimeInterval(600))
        XCTAssertEqual(context.activeVisibleReadCount, 0)
        XCTAssertEqual(calls.value, 3)
    }

    func testProcessCacheRejectsRowOrByteOverflowAndBoundsMemoryGroups() async {
        XCTAssertTrue(MenuBarProcessCacheBudget.fits(rowCount: 4_096, estimatedBytes: 8 * 1_024 * 1_024))
        XCTAssertFalse(MenuBarProcessCacheBudget.fits(rowCount: 4_097, estimatedBytes: 1))
        XCTAssertFalse(MenuBarProcessCacheBudget.fits(rowCount: 1, estimatedBytes: 8 * 1_024 * 1_024 + 1))
        let row = EnergyImpactService.processRows(fromPSOutput: "101 1 1024 user 00:01 10 /Applications/Test.app/Contents/MacOS/Test")[0]
        let frame = EnergyImpactService.MenuBarCounterFrame(sampledAt: Date(), uptime: 1,
            rows: Array(repeating: row, count: 4_097), counters: [:])
        let sampler = MenuBarProcessSampler(read: { frame })
        let result = await sampler.sample()
        XCTAssertNil(result)
        XCTAssertFalse(MenuBarProcessSampler.fitsCache(frame))
        let app = MemoryAppUsage(id: "test", name: String(repeating: "x", count: 1_024 * 1_024),
            iconPath: "", bundlePath: nil, bytes: 100, canQuit: false, isActive: false,
            percent: 1, processCount: 1, processIDs: [1], selectableProcessIDs: [])
        let bounded = MenuBarProcessCacheBudget.memoryApps(Array(repeating: app, count: 10))
        XCTAssertEqual(bounded.count, 3)
    }

    @MainActor
    func testResidentProcessSampleExistsBeforeAnyPageAndReopenDoesNotResetIt() async throws {
        let reader = Frames()
        let store = try ScanStore.makeForTests(for: self,
            menuBarMemoryProcessProvider: { Self.memory },
            menuBarProcessSampler: MenuBarProcessSampler(read: { await reader.next() }))
        let context = MenuBarSamplingContext()
        context.configure(statusMode: .memory, statusVisible: false, panelVisible: false,
            customFanControlActive: false, paused: false)
        store.attachMenuBarResidentSampling(context)
        defer { store.suspendMenuBarResidentSampling() }
        let at = Date()
        store.refreshMenuBarResidentSamples(now: at)
        try await waitUntil { store.menuBarPreparedProcesses != nil && store.menuBarPreparedMemoryAppsSampledAt != nil }
        let sampleDate = store.menuBarPreparedProcesses?.snapshot.generatedAt
        XCTAssertNotNil(sampleDate)
        let calls = await reader.count
        XCTAssertEqual(calls, 2, "one baseline plus first delta, before a panel opens")
        for section in [PanelSection.processor, .disk, .power, .overview, .processor] {
            store.setMenuBarProcessDemand(section)
            XCTAssertEqual(store.menuBarPreparedProcesses?.snapshot.generatedAt, sampleDate)
            XCTAssertFalse(store.isMenuBarProcessSamplePending)
        }
        store.refreshMenuBarResidentSamples(now: at.addingTimeInterval(14.99))
        let before = await reader.count
        XCTAssertEqual(before, calls)
        store.refreshMenuBarResidentSamples(now: at.addingTimeInterval(15))
        try await waitUntil { store.menuBarPreparedProcesses?.snapshot.generatedAt != sampleDate }
        let after = await reader.count
        XCTAssertEqual(after, 3, "visibility changes must not reset the baseline")
    }

    @MainActor
    func testResidentFirstNoSampleWaitsThenBecomesUnavailableOnSharedTick() async throws {
        let store = try ScanStore.makeForTests(for: self, menuBarMemoryProcessProvider: { Self.memory },
            menuBarProcessSampler: MenuBarProcessSampler(read: { nil }))
        let context = MenuBarSamplingContext()
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: false,
            customFanControlActive: false, paused: false)
        store.attachMenuBarResidentSampling(context)
        defer { store.suspendMenuBarResidentSampling() }
        let at = Date()
        store.refreshMenuBarResidentSamples(now: at)
        store.setMenuBarProcessDemand(.processor)
        XCTAssertTrue(store.isMenuBarProcessSamplePending)
        store.refreshMenuBarResidentSamples(now: at.addingTimeInterval(5))
        XCTAssertFalse(store.isMenuBarProcessSamplePending)
        XCTAssertTrue(store.isMenuBarProcessSampleUnavailable)
        XCTAssertNil(store.menuBarPreparedProcesses)
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(predicate())
    }

    @MainActor private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    private actor Frames {
        private(set) var count = 0
        func next() -> EnergyImpactService.MenuBarCounterFrame {
            count += 1
            let time = Double(count)
            let rows = EnergyImpactService.processRows(fromPSOutput: "101 1 1024 user 00:01 10 /Applications/Test.app/Contents/MacOS/Test")
            return .init(sampledAt: Date(timeIntervalSince1970: time), uptime: time, rows: rows,
                counters: [101: .init(pid: 101, energyNanojoules: UInt64(time * 1_000_000_000),
                    cpuTimeMach: UInt64(time * 1_000_000), processStartMach: 1,
                    diskReadBytes: UInt64(time * 100), diskWrittenBytes: UInt64(time * 50))])
        }
    }
    private static var power: PowermetricsSample {
        .init(cpuMilliwatts: 5_000, gpuMilliwatts: 2_000, aneMilliwatts: 0,
            clusters: [], gpuMegahertz: 800, durationSeconds: 1)
    }
    private static var memory: MemorySnapshot {
        .init(generatedAt: Date(), physicalBytes: 8_000, freeBytes: 1_000, inactiveBytes: 1_000,
            speculativeBytes: 0, fileBackedBytes: 1_000, purgeableBytes: 0, wiredBytes: 2_000,
            compressedBytes: 500, swapUsedBytes: 0, pressureFreePercentage: 50,
            pressureSummary: "", topProcesses: [])
    }
}
