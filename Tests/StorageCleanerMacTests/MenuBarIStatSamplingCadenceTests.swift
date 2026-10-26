import Foundation
import XCTest
@testable import StorageCleanerMac

/// D127: the sampling cadence of iStat Menus 7.30 (`-[Statistics update]`,
/// `UpdateFrequency` 0 → 3 s, 1 → 2 s, 2 → 1 s; `-[ItemManager
/// startItemsForKey:]` / `stopItemsForKey:`): one 1/2/3 s tick for every
/// reading, panel open or closed, and process lists only while a page shows
/// one — read at once, again after 0.5 s, then on each tick.
final class MenuBarIStatSamplingCadenceTests: XCTestCase {
    @MainActor
    func testRefreshChoicesAreOneTwoThreeSecondsWithTwoByDefaultAndStoredFiveReadsAsThree() throws {
        XCTAssertEqual(MenuBarRefreshInterval.allCases, [.oneSecond, .twoSeconds, .threeSeconds])
        XCTAssertEqual(MenuBarRefreshInterval.allCases.map(\.seconds), [1, 2, 3])
        XCTAssertEqual(MenuBarRefreshInterval.allCases.map(\.title), ["1s", "2s", "3s"])
        XCTAssertEqual(MenuBarRefreshInterval.defaultValue, .twoSeconds)
        for interval in MenuBarRefreshInterval.allCases {
            XCTAssertEqual(MenuBarRefreshInterval.stored(interval.rawValue), interval)
        }
        XCTAssertEqual(MenuBarRefreshInterval.stored("fiveSeconds"), .threeSeconds)
        XCTAssertNil(MenuBarRefreshInterval.stored(nil))
        XCTAssertNil(MenuBarRefreshInterval.stored("tenSeconds"))
        let decoded = try JSONDecoder().decode([MenuBarRefreshInterval].self,
                                               from: Data(#"["fiveSeconds","oneSecond"]"#.utf8))
        XCTAssertEqual(decoded, [.threeSeconds, .oneSecond])
        XCTAssertThrowsError(try JSONDecoder().decode([MenuBarRefreshInterval].self,
                                                      from: Data(#"["tenSeconds"]"#.utf8)))
        let language = MiniWindowLogicLanguageScope(.zhHans)
        XCTAssertEqual(MenuBarRefreshInterval.allCases.map(\.pickerTitle), ["1 秒", "2 秒", "3 秒"])
        language.restore()
        let english = MiniWindowLogicLanguageScope(.english)
        XCTAssertEqual(MenuBarRefreshInterval.allCases.map(\.pickerTitle), ["1 second", "2 seconds", "3 seconds"])
        english.restore()

        for (stored, expected) in [("fiveSeconds", MenuBarRefreshInterval.threeSeconds),
                                   ("oneSecond", .oneSecond), ("tenSeconds", .twoSeconds)] {
            let defaults = TestPreferenceDomain.make(for: self)
            defaults.set(stored, forKey: "menuBar.refreshInterval")
            let store = try ScanStore.makeForTests(for: self, preferences: defaults)
            XCTAssertEqual(store.menuBarRefreshInterval, expected, "stored \(stored)")
        }
        let defaults = TestPreferenceDomain.make(for: self)
        let store = try ScanStore.makeForTests(for: self, preferences: defaults)
        XCTAssertEqual(store.menuBarRefreshInterval, .twoSeconds, "a new install starts at iStat's 2 s")
    }

    func testTickGatesTolerateWakeJitterButNotAnEarlierTick() {
        let at = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(MenuBarPerformancePolicy.tickTolerance, 0.1)
        XCTAssertTrue(MenuBarPerformancePolicy.isDue(since: nil, now: at, interval: 3))
        XCTAssertTrue(MenuBarPerformancePolicy.isDue(since: at, now: at.addingTimeInterval(3), interval: 3))
        XCTAssertTrue(MenuBarPerformancePolicy.isDue(since: at, now: at.addingTimeInterval(2.95), interval: 3),
                      "a tick that woke 50 ms earlier than the last still reads")
        XCTAssertFalse(MenuBarPerformancePolicy.isDue(since: at, now: at.addingTimeInterval(2.85), interval: 3))
        XCTAssertFalse(MenuBarPerformancePolicy.isDue(since: at, now: at.addingTimeInterval(0.5), interval: 1))
        XCTAssertFalse(MenuBarPerformancePolicy.isDue(since: at, now: at.addingTimeInterval(-1), interval: 1))
        for tick in [1.0, 2, 3] {
            XCTAssertEqual(MenuBarPerformancePolicy.processSpacing(tick, tick: tick), 1,
                           "an open process page reads on every tick, never twice within 1 s")
        }
        XCTAssertEqual(MenuBarPerformancePolicy.processSpacing(60, tick: 30), 60, "Low Power keeps its process budget")
        XCTAssertEqual(MenuBarPerformancePolicy.firstProcessSampleInterval, 0.5)
    }

    /// The fixed-deadline loop wakes a few milliseconds late by a varying
    /// amount, so two ticks can land slightly less than one interval apart.
    func testSensorsAndGPUReadOnEveryTickDespiteWakeJitter() async throws {
        let gpu = Probe(), sensors = Probe()
        let sampler = SystemMonitorSampler(gpuReader: {
            gpu.increment()
            return GPUPerformanceSnapshot(usagePercent: 25, memoryUsedBytes: 1_024)
        }, temperatureAndFanReader: {
            sensors.increment()
            return .init(gpuUsagePercent: nil, chipTemperatureCelsius: 55,
                         fanSpeedRPM: 0, fanCount: 1, fanSpeedsRPM: [0])
        })
        let plan = MenuBarSamplingPlan.resolve(statusMode: .cpu, statusVisible: true, panelVisible: true,
            visibleKinds: [], customFanControlActive: false, paused: false, selectedInterval: 2)
        XCTAssertEqual(plan.thermalInterval, 2)
        XCTAssertEqual(plan.gpuInterval, 2)
        let start = Date(timeIntervalSinceReferenceDate: 90_000)
        func read(_ seconds: TimeInterval) async throws {
            _ = await sampler.snapshot(enabledKinds: MenuBarMetricKind.defaultSelection,
                memorySnapshot: nil, previousNetworkSample: nil, resolvesMissingMemorySnapshot: false,
                samplingPlan: plan, now: start.addingTimeInterval(seconds))
            let deadline = ContinuousClock.now + .seconds(2)
            while await sampler.isHardwareReadInFlight, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        try await read(0)
        XCTAssertEqual([gpu.count, sensors.count], [1, 1])
        try await read(1.85)
        XCTAssertEqual([gpu.count, sensors.count], [1, 1], "inside the tick the readings are kept")
        try await read(1.97)
        XCTAssertEqual([gpu.count, sensors.count], [2, 2], "a tick 30 ms short of 2 s still reads both")
        try await read(3.94)
        XCTAssertEqual([gpu.count, sensors.count], [3, 3])
        let source = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Services/SystemMonitorService.swift")
        XCTAssertTrue(source.contains(
            "now.timeIntervalSince(thermalSampledAt) < max(1, samplingInterval) - MenuBarPerformancePolicy.tickTolerance"))
    }

    /// A page change while ps is still running: no second ps overlaps it,
    /// its result is dropped, and the new page then reads at once from a new
    /// baseline (two reads: baseline and the 0.5 s follow-up).
    @MainActor
    func testPageChangeDuringAReadHandsOverToTheNewPageWithoutAnOverlappingRead() async throws {
        let frames = HeldFrames()
        let store = try ScanStore.makeForTests(for: self, menuBarMemoryProcessProvider: { Self.memory(at: 1) },
            menuBarProcessSampler: MenuBarProcessSampler(read: { await frames.next() }))
        let context = Self.visibleContext()
        store.attachMenuBarResidentSampling(context)
        defer { store.suspendMenuBarResidentSampling() }
        await frames.hold(read: 1)
        store.setMenuBarProcessDemand(.processor)
        try await waitUntil { await frames.isHolding }
        store.setMenuBarProcessDemand(.disk)
        XCTAssertTrue(store.isMenuBarProcessSamplePending)
        store.refreshMenuBarResidentSamples(now: Date().addingTimeInterval(10))
        try await Task.sleep(for: .milliseconds(50))
        var reads = await frames.count
        XCTAssertEqual(reads, 1, "the running ps keeps the single flight")
        await frames.release()
        // D171: the disk page lists its first read at once; this waits for
        // its first delta (was `store.menuBarPreparedProcesses != nil`).
        try await waitUntil { store.menuBarPreparedProcesses?.isFirstRead == false }
        reads = await frames.count
        XCTAssertEqual(reads, 3, "the new page reads from a new baseline, not against the old page's read")
        XCTAssertFalse(store.isMenuBarProcessSamplePending)
        XCTAssertEqual(store.menuBarProcessDemand, .disk)
    }

    /// Our pause (iStat has none) freezes what is shown; resuming starts the
    /// page again like opening it.
    @MainActor
    func testPauseKeepsTheShownProcessesAndResumingReadsAgainAtOnce() async throws {
        let frames = HeldFrames()
        let store = try ScanStore.makeForTests(for: self, menuBarMemoryProcessProvider: { Self.memory(at: 1) },
            menuBarProcessSampler: MenuBarProcessSampler(read: { await frames.next() }))
        store.attachMenuBarResidentSampling(Self.visibleContext())
        defer { store.suspendMenuBarResidentSampling() }
        store.setMenuBarProcessDemand(.power)
        try await waitUntil { store.menuBarPreparedProcesses != nil }
        let shown = store.menuBarPreparedProcesses?.snapshot.generatedAt
        store.isMenuBarRefreshPaused = true
        store.setMenuBarProcessDemand(.overview)
        store.refreshMenuBarResidentSamples(now: Date().addingTimeInterval(60))
        try await Task.sleep(for: .milliseconds(50))
        var reads = await frames.count
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(store.menuBarPreparedProcesses?.snapshot.generatedAt, shown, "pause keeps what is shown")
        store.isMenuBarRefreshPaused = false
        store.setMenuBarProcessDemand(.power)
        XCTAssertNil(store.menuBarPreparedProcesses)
        try await waitUntil { store.menuBarPreparedProcesses != nil }
        reads = await frames.count
        XCTAssertEqual(reads, 4)
    }

    /// The memory list is one phys_footprint read (no baseline). Reopening the
    /// page while a read runs starts the next read when that one exits; the
    /// list itself stays while the page is closed (D127 deviation: no "未获得
    /// 进程数据" flash before the immediate read replaces it).
    @MainActor
    func testMemoryPageReopenedDuringAReadReadsAgainWhenItExits() async throws {
        let memory = HeldMemory()
        let store = try ScanStore.makeForTests(for: self, menuBarMemoryProcessProvider: { await memory.next() },
            menuBarProcessSampler: MenuBarProcessSampler(read: { nil }))
        store.attachMenuBarResidentSampling(Self.visibleContext())
        defer { store.suspendMenuBarResidentSampling() }
        await memory.hold(read: 1)
        store.setMenuBarProcessDemand(.memory)
        try await waitUntil { await memory.isHolding }
        store.setMenuBarProcessDemand(.overview)
        store.setMenuBarProcessDemand(.memory)
        try await Task.sleep(for: .milliseconds(50))
        var reads = await memory.count
        XCTAssertEqual(reads, 1, "one memory read at a time")
        await memory.release()
        try await waitUntil { store.menuBarPreparedMemoryAppsSampledAt == Self.memory(at: 2).generatedAt }
        reads = await memory.count
        XCTAssertEqual(reads, 2)
        store.setMenuBarProcessDemand(.overview)
        XCTAssertEqual(store.menuBarPreparedMemoryAppsSampledAt, Self.memory(at: 2).generatedAt)
        store.refreshMenuBarResidentSamples(now: Date().addingTimeInterval(60))
        try await Task.sleep(for: .milliseconds(50))
        reads = await memory.count
        XCTAssertEqual(reads, 2, "a closed memory page reads nothing")
    }

    @MainActor
    private static func visibleContext() -> MenuBarSamplingContext {
        let context = MenuBarSamplingContext()
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: true,
            customFanControlActive: false, paused: false, selectedInterval: 2)
        return context
    }

    @MainActor
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let met = await condition()
        XCTAssertTrue(met, "condition not met before the deadline")
    }

    private static func memory(at seconds: TimeInterval) -> MemorySnapshot {
        .init(generatedAt: Date(timeIntervalSince1970: 1_000 + seconds), physicalBytes: 8_000, freeBytes: 1_000,
              inactiveBytes: 1_000, speculativeBytes: 0, fileBackedBytes: 1_000, purgeableBytes: 0,
              wiredBytes: 2_000, compressedBytes: 500, swapUsedBytes: 0, pressureFreePercentage: 50,
              pressureSummary: "", topProcesses: [])
    }

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func increment() { lock.lock(); defer { lock.unlock() }; calls += 1 }
    }

    /// Demo counter frames; the chosen read waits until released.
    private actor HeldFrames {
        private(set) var count = 0
        private(set) var isHolding = false
        private var heldRead: Int?
        private var waiter: CheckedContinuation<Void, Never>?

        func hold(read number: Int) { heldRead = number }

        func release() {
            isHolding = false
            waiter?.resume()
            waiter = nil
        }

        func next() async -> EnergyImpactService.MenuBarCounterFrame {
            count += 1
            let number = count
            if number == heldRead {
                isHolding = true
                await withCheckedContinuation { waiter = $0 }
            }
            let time = Double(number)
            let rows = EnergyImpactService.processRows(
                fromPSOutput: "101 1 1024 user 00:01 10 /Applications/Test.app/Contents/MacOS/Test")
            return .init(sampledAt: Date(timeIntervalSince1970: time), uptime: time, rows: rows,
                counters: [101: .init(pid: 101, energyNanojoules: UInt64(time * 1_000_000_000),
                    cpuTimeMach: UInt64(time * 1_000_000), processStartMach: 1,
                    diskReadBytes: UInt64(time * 100), diskWrittenBytes: UInt64(time * 50))])
        }
    }

    private actor HeldMemory {
        private(set) var count = 0
        private(set) var isHolding = false
        private var heldRead: Int?
        private var waiter: CheckedContinuation<Void, Never>?

        func hold(read number: Int) { heldRead = number }

        func release() {
            isHolding = false
            waiter?.resume()
            waiter = nil
        }

        func next() async -> MemorySnapshot {
            count += 1
            let number = count
            if number == heldRead {
                isHolding = true
                await withCheckedContinuation { waiter = $0 }
            }
            return MenuBarIStatSamplingCadenceTests.memory(at: TimeInterval(number))
        }
    }
}
