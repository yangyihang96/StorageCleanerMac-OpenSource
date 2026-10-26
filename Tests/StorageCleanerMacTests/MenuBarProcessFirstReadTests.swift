import Foundation
import XCTest
@testable import StorageCleanerMac

/// D171 (iStat `-[ItemManager startItemsForKey:]`, spec §8): the CPU and
/// disk pages list their first read at once, every rate 0 (iStat's CPU is
/// Δ/Δt, 0 on the first read), read again 0.5 s later for the first rates
/// and stop when closed. Was D127/D129: "正在采样…" until that first delta.
/// The power page still waits for its first delta; the memory list is read
/// as before. The counter frames and the memory list are fakes: no real
/// process is read.
@MainActor
final class MenuBarProcessFirstReadTests: XCTestCase {
    func testCPUAndDiskPagesListTheFirstReadAtOnceThenTheFirstDeltaHalfASecondLater() async throws {
        for section in [PanelSection.processor, .disk] {
            let frames = Frames()
            let store = try makeStore(frames)
            store.attachMenuBarResidentSampling(Self.visibleContext())
            defer { store.suspendMenuBarResidentSampling() }
            await frames.hold(read: 2)
            store.setMenuBarProcessDemand(section)
            XCTAssertTrue(store.isMenuBarProcessSamplePending, "\(section): sampling while the first read runs")

            try await waitUntil { store.menuBarPreparedProcesses != nil }
            let first = try XCTUnwrap(store.menuBarPreparedProcesses)
            XCTAssertTrue(first.isFirstRead, "\(section): shown from the first read, not after the follow-up")
            XCTAssertFalse(store.isMenuBarProcessSamplePending, "\(section): no \"正在采样…\" once it is listed")
            XCTAssertEqual(first.snapshot.generatedAt, Frames.sampledAt(read: 1))
            let listed = section == .processor ? first.cpu : first.disk
            XCTAssertEqual(listed.map(\.name), ["D171Alpha", "D171Beta"], "\(section): idle apps listed by name")
            for app in listed {
                XCTAssertEqual(app.cpuPercent, 0, "\(section) \(app.name): CPU 0 (ps says 3 / 30)")
                XCTAssertEqual(app.diskReadBytesPerSecond, 0, "\(section) \(app.name)")
                XCTAssertEqual(app.diskWriteBytesPerSecond, 0, "\(section) \(app.name)")
                XCTAssertEqual(app.currentPowerWatts, 0, "\(section) \(app.name)")
            }

            try await waitUntil { await frames.isHolding }
            let starts = await frames.startedAt
            guard starts.count == 2 else { return XCTFail("\(section): \(starts.count) reads, expected 2") }
            let gap = starts[0].duration(to: starts[1])
            XCTAssertGreaterThanOrEqual(gap, .milliseconds(500), "\(section): the second read waits 0.5 s")
            XCTAssertLessThan(gap, .milliseconds(1_500), "\(section): and does not wait for a tick (2 s)")
            XCTAssertEqual(store.menuBarPreparedProcesses?.isFirstRead, true, "the first read stays until the delta")
            await frames.release()
            try await waitUntil { store.menuBarPreparedProcesses?.isFirstRead == false }
            let delta = try XCTUnwrap(store.menuBarPreparedProcesses)
            XCTAssertEqual(delta.snapshot.generatedAt, Frames.sampledAt(read: 2))
            XCTAssertEqual(delta.cpu.map(\.cpuPercent), [30, 3])
            XCTAssertEqual(delta.disk.map(\.diskReadBytesPerSecond), [8_192, 4_096])
            var reads = await frames.count
            XCTAssertEqual(reads, 2)

            store.setMenuBarProcessDemand(.overview)
            XCTAssertNil(store.menuBarPreparedProcesses, "\(section): closing drops the rates")
            XCTAssertFalse(store.isMenuBarProcessSamplePending)
            store.refreshMenuBarResidentSamples(now: Date().addingTimeInterval(60))
            try await Task.sleep(for: .milliseconds(50))
            reads = await frames.count
            XCTAssertEqual(reads, 2, "\(section): a closed page reads nothing")
        }
    }

    /// iStat's energy list keeps apps whose power reaches a configured
    /// threshold (default not in the spec); ours lists significant energy.
    /// The power page's first read stays a baseline.
    func testPowerPageStillWaitsForItsFirstDelta() async throws {
        let frames = Frames()
        let store = try makeStore(frames)
        store.attachMenuBarResidentSampling(Self.visibleContext())
        defer { store.suspendMenuBarResidentSampling() }
        await frames.hold(read: 2)
        store.setMenuBarProcessDemand(.power)
        try await waitUntil { await frames.isHolding }
        XCTAssertNil(store.menuBarPreparedProcesses, "the first read is not listed on the power page")
        XCTAssertTrue(store.isMenuBarProcessSamplePending)
        await frames.release()
        try await waitUntil { store.menuBarPreparedProcesses != nil }
        XCTAssertEqual(store.menuBarPreparedProcesses?.isFirstRead, false)
        XCTAssertEqual(store.menuBarPreparedProcesses?.energy.map(\.name), ["D171Beta", "D171Alpha"])
        XCTAssertFalse(store.isMenuBarProcessSamplePending)
        let reads = await frames.count
        XCTAssertEqual(reads, 2)
    }

    func testMemoryPageStillReadsItsListAtOnceWithoutACounterFrame() async throws {
        let frames = Frames()
        let memoryReads = Counter()
        let store = try ScanStore.makeForTests(for: self,
            menuBarMemoryStatusProvider: { Self.memory },
            menuBarMemoryProcessProvider: { memoryReads.increment(); return Self.memory },
            menuBarProcessSampler: MenuBarProcessSampler(read: { await frames.next() }))
        store.attachMenuBarResidentSampling(Self.visibleContext())
        defer { store.suspendMenuBarResidentSampling() }
        store.setMenuBarProcessDemand(.memory)
        XCTAssertFalse(store.isMenuBarProcessSamplePending, "the memory list needs no baseline")
        try await waitUntil { store.menuBarPreparedMemoryAppsSampledAt == Self.memory.generatedAt }
        XCTAssertEqual(memoryReads.value, 1, "read once, at once")
        let reads = await frames.count
        XCTAssertEqual(reads, 0, "the memory page reads no counter frame")
        XCTAssertNil(store.menuBarPreparedProcesses)
    }

    /// The standalone driver (no resident clock attached) lists the first
    /// read at once too; a page with a kept measurement keeps showing it.
    func testStandaloneDriverListsTheFirstReadAtOnceAndKeepsAKeptMeasurement() async throws {
        let frames = Frames()
        let store = try makeStore(frames)
        defer { store.setMenuBarProcessDemand(.overview) }
        await frames.hold(read: 2)
        store.setMenuBarProcessDemand(.processor)
        try await waitUntil { store.menuBarPreparedProcesses != nil }
        XCTAssertEqual(store.menuBarPreparedProcesses?.isFirstRead, true)
        XCTAssertEqual(store.menuBarPreparedProcesses?.cpu.map(\.cpuPercent), [0, 0])
        try await waitUntil { await frames.isHolding }
        let starts = await frames.startedAt
        guard starts.count == 2 else { return XCTFail("\(starts.count) reads, expected 2") }
        XCTAssertGreaterThanOrEqual(starts[0].duration(to: starts[1]), .milliseconds(500))
        await frames.release()
        try await waitUntil { store.menuBarPreparedProcesses?.isFirstRead == false }
        let measured = store.menuBarPreparedProcesses?.snapshot.generatedAt

        await frames.hold(read: 4)
        store.setMenuBarProcessDemand(.overview)
        store.setMenuBarProcessDemand(.disk)
        try await waitUntil { await frames.isHolding }
        XCTAssertEqual(store.menuBarPreparedProcesses?.snapshot.generatedAt, measured,
                       "the kept measurement is not replaced by a first read of rates 0")
        await frames.release()
        try await waitUntil { store.menuBarPreparedProcesses?.snapshot.generatedAt == Frames.sampledAt(read: 4) }
        XCTAssertEqual(store.menuBarPreparedProcesses?.isFirstRead, false)
    }

    /// MenuBarPublishLoopTests.testChangedResidentSectionWithSamePendingStateDoesNotPublish
    /// runs in a display-bound class; the same logic without a window.
    /// Changing between process pages with nothing shown and the same pending
    /// state publishes nothing (the page change assigned nil to nil).
    func testChangingProcessPagesWithNothingShownAndTheSamePendingStateDoesNotPublish() throws {
        let store = try ScanStore.makeForTests(for: self,
            menuBarMemoryStatusProvider: { Self.memory }, menuBarMemoryProcessProvider: { Self.memory },
            menuBarProcessSampler: MenuBarProcessSampler(read: { nil }))
        let context = MenuBarSamplingContext()
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: false,
            customFanControlActive: false, paused: false, suspended: false)
        store.attachMenuBarResidentSampling(context)
        defer { store.suspendMenuBarResidentSampling() }
        store.setMenuBarProcessDemand(.processor)
        XCTAssertTrue(store.isMenuBarProcessSamplePending)
        let publications = Counter()
        let subscription = store.objectWillChange.sink { publications.increment() }
        store.setMenuBarProcessDemand(.disk)
        store.setMenuBarProcessDemand(.power)
        XCTAssertTrue(store.isMenuBarProcessSamplePending)
        XCTAssertEqual(publications.value, 0, "a different page does not change what is shown")
        store.setMenuBarProcessDemand(.memory)
        XCTAssertFalse(store.isMenuBarProcessSamplePending)
        XCTAssertEqual(publications.value, 1, "the pending change still publishes")
        withExtendedLifetime(subscription) {}
    }

    /// D171 review: more than five apps on a first read, every rate 0. The
    /// top five are chosen and ordered by name, then by the lowest PID (two
    /// apps show the same name), whatever order ps lists them in and
    /// whatever %CPU it reports.
    func testFirstReadOfMoreThanFiveAppsListsAStableTopFiveByNameThenLowestPID() async throws {
        var listed: [[String]] = []
        for reversed in [false, true] {
            let frame = Self.inventoryFrame(reversed: reversed)
            let sampler = MenuBarProcessSampler(read: { frame })
            let sampled = await sampler.sample(listingFirstRead: true)
            let first = MenuBarPreparedProcesses(snapshot: try XCTUnwrap(sampled))
            XCTAssertTrue(first.isFirstRead)
            XCTAssertEqual(first.snapshot.apps.count, 8)
            for list in [first.cpu, first.disk] {
                XCTAssertEqual(list.map(\.name), ["D171Alpha", "D171Bravo · Applications",
                                                  "D171Bravo · Applications", "D171Echo", "D171Golf"])
                XCTAssertEqual(list.map(\.processIDs), [[406], [399], [404], [405], [408]],
                               "the same name is ordered by the lowest PID")
                XCTAssertTrue(list.allSatisfy {
                    $0.cpuPercent == 0 && $0.diskReadBytesPerSecond == 0 && $0.diskWriteBytesPerSecond == 0
                })
            }
            XCTAssertTrue(first.energy.isEmpty)
            listed.append(first.cpu.map(\.id) + first.disk.map(\.id))
        }
        XCTAssertEqual(listed.first, listed.last, "the order ps lists the apps in does not matter")
    }

    /// D171 review: a reader that gave nothing and then recovers takes its
    /// first delta by the recovery path (0.5 s later) even when the page
    /// lists its first read; it never lists a first read of rates 0.
    func testAReaderRecoveringFromNothingTakesItsFirstDeltaNotAFirstReadOfZeros() async throws {
        let frames = Frames()
        await frames.miss(reads: 1)
        let sampler = MenuBarProcessSampler(read: { await frames.next() })
        let missed = await sampler.sample(listingFirstRead: true)
        XCTAssertNil(missed, "the reader gave nothing")
        let recovered = await sampler.sample(listingFirstRead: true)
        let delta = MenuBarPreparedProcesses(snapshot: try XCTUnwrap(recovered))
        XCTAssertFalse(delta.isFirstRead, "a delta, not a first read of rates 0")
        XCTAssertEqual(delta.snapshot.generatedAt, Frames.sampledAt(read: 3))
        XCTAssertEqual(delta.cpu.map(\.cpuPercent), [30, 3])
        XCTAssertEqual(delta.disk.map(\.diskReadBytesPerSecond), [8_192, 4_096])
        let starts = await frames.startedAt
        guard starts.count == 3 else { return XCTFail("\(starts.count) reads, expected 3") }
        XCTAssertGreaterThanOrEqual(starts[1].duration(to: starts[2]), .milliseconds(500),
                                    "the recovery path waits 0.5 s for the delta")
    }

    /// D171 review: sampling suspended (sleep, display off: the plan's
    /// `cadence.suspended`) between the first read and its 0.5 s follow-up.
    /// The follow-up is not shown, the first read stays, and the next tick
    /// after resuming takes the first delta.
    func testSuspensionBeforeTheFollowUpKeepsTheFirstReadUntilTheNextTick() async throws {
        let frames = Frames()
        let store = try makeStore(frames)
        let context = Self.visibleContext()
        store.attachMenuBarResidentSampling(context)
        defer { store.suspendMenuBarResidentSampling() }
        await frames.hold(read: 2)
        store.setMenuBarProcessDemand(.processor)
        try await waitUntil { await frames.isHolding }
        XCTAssertEqual(store.menuBarPreparedProcesses?.isFirstRead, true)
        let followUp = try XCTUnwrap(Self.visibleProcessTask(of: store))
        Self.configure(context, suspended: true)
        await frames.release()
        await followUp.value
        XCTAssertEqual(store.menuBarPreparedProcesses?.snapshot.generatedAt, Frames.sampledAt(read: 1),
                       "the follow-up read during the suspension is not shown")
        XCTAssertEqual(store.menuBarPreparedProcesses?.isFirstRead, true)
        store.refreshMenuBarResidentSamples(now: Date().addingTimeInterval(2))
        try await Task.sleep(for: .milliseconds(50))
        var reads = await frames.count
        XCTAssertEqual(reads, 2, "a suspended tick reads nothing")

        Self.configure(context, suspended: false)
        store.refreshMenuBarResidentSamples(now: Date().addingTimeInterval(2))
        try await waitUntil { store.menuBarPreparedProcesses?.isFirstRead == false }
        XCTAssertEqual(store.menuBarPreparedProcesses?.snapshot.generatedAt, Frames.sampledAt(read: 3))
        reads = await frames.count
        XCTAssertEqual(reads, 3, "the next tick reads once")
    }

    /// The same with our pause (iStat has none): the follow-up read is
    /// dropped, the first read stays shown, and nothing is read while paused.
    func testPauseBeforeTheFollowUpKeepsTheFirstReadShown() async throws {
        let frames = Frames()
        let store = try makeStore(frames)
        store.attachMenuBarResidentSampling(Self.visibleContext())
        defer { store.suspendMenuBarResidentSampling() }
        await frames.hold(read: 2)
        store.setMenuBarProcessDemand(.processor)
        try await waitUntil { await frames.isHolding }
        let followUp = try XCTUnwrap(Self.visibleProcessTask(of: store))
        store.toggleMenuBarRefreshPaused()
        XCTAssertTrue(store.isMenuBarRefreshPaused)
        await frames.release()
        await followUp.value
        XCTAssertEqual(store.menuBarPreparedProcesses?.snapshot.generatedAt, Frames.sampledAt(read: 1),
                       "the follow-up read is dropped and the first read stays")
        XCTAssertEqual(store.menuBarPreparedProcesses?.isFirstRead, true)
        XCTAssertFalse(store.isMenuBarProcessSamplePending)
        store.refreshMenuBarResidentSamples(now: Date().addingTimeInterval(60))
        try await Task.sleep(for: .milliseconds(50))
        let reads = await frames.count
        XCTAssertEqual(reads, 2, "nothing is read while paused")
    }

    private func makeStore(_ frames: Frames) throws -> ScanStore {
        let store = try ScanStore.makeForTests(for: self,
            menuBarMemoryStatusProvider: { Self.memory }, menuBarMemoryProcessProvider: { Self.memory },
            menuBarProcessSampler: MenuBarProcessSampler(read: { await frames.next() }))
        // Runs before the factory joins the store's tasks (teardown blocks
        // run last-in first-out): a failed test must not leave a read held.
        addTeardownBlock { await frames.release() }
        return store
    }

    private static func visibleContext() -> MenuBarSamplingContext {
        let context = MenuBarSamplingContext()
        configure(context, suspended: false)
        return context
    }

    private static func configure(_ context: MenuBarSamplingContext, suspended: Bool) {
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: true,
            customFanControlActive: false, paused: false, suspended: suspended, selectedInterval: 2)
    }

    /// The running read of the open process page (a test observation point).
    private static func visibleProcessTask(of store: ScanStore) -> Task<Void, Never>? {
        store.operationReportProducersForTesting.first { $0.name == "menuBarVisibleProcessTask" }?.task
    }

    /// Eight apps on one first read. ps gives them 0–60 % CPU, which a first
    /// read does not use; two show the same name ("D171Bravo · Applications").
    nonisolated private static func inventoryFrame(reversed: Bool) -> EnergyImpactService.MenuBarCounterFrame {
        let lines = [
            "401 1 1024 01:00 00:05 50 /Applications/D171Zulu.app/Contents/MacOS/D171Zulu",
            "402 1 1024 01:00 00:04 40 /Applications/D171Mike.app/Contents/MacOS/D171Mike",
            "403 1 1024 01:00 00:00 0 /Applications/D171Kilo.app/Contents/MacOS/D171Kilo",
            "404 1 1024 01:00 00:03 30 /Users/Shared/Applications/D171Bravo.app/Contents/MacOS/D171Bravo",
            "405 1 1024 01:00 00:02 20 /Applications/D171Echo.app/Contents/MacOS/D171Echo",
            "406 1 1024 01:00 00:01 1 /Applications/D171Alpha.app/Contents/MacOS/D171Alpha",
            "408 1 1024 01:00 00:06 60 /Applications/D171Golf.app/Contents/MacOS/D171Golf",
            "399 1 1024 01:00 00:01 10 /Applications/D171Bravo.app/Contents/MacOS/D171Bravo",
        ]
        let rows = EnergyImpactService.processRows(
            fromPSOutput: (reversed ? lines.reversed() : lines).joined(separator: "\n"))
        let counters = Dictionary(uniqueKeysWithValues: rows.map { row -> (Int32, EnergyResourceUsage) in
            let pid = UInt64(row.pid)
            return (row.pid, EnergyResourceUsage(pid: row.pid, energyNanojoules: pid * 1_000_000,
                cpuTimeMach: pid * 1_000, processStartMach: pid, diskReadBytes: pid * 10, diskWrittenBytes: pid))
        })
        return .init(sampledAt: Date(timeIntervalSince1970: 3_000), uptime: 10, rows: rows, counters: counters)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let met = await condition()
        XCTAssertTrue(met, "condition not met before the deadline")
    }

    nonisolated private static var memory: MemorySnapshot {
        .init(generatedAt: Date(timeIntervalSince1970: 2_000), physicalBytes: 8_000, freeBytes: 1_000,
              inactiveBytes: 1_000, speculativeBytes: 0, fileBackedBytes: 1_000, purgeableBytes: 0,
              wiredBytes: 2_000, compressedBytes: 500, swapUsedBytes: 0, pressureFreePercentage: 50,
              pressureSummary: "", topProcesses: [])
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    /// Two apps whose counters grow by one unit per read (ps: CPU 3 % and
    /// 30 %); the chosen read waits until released, the first `miss` reads
    /// give nothing.
    private actor Frames {
        private(set) var count = 0
        private(set) var startedAt: [ContinuousClock.Instant] = []
        private(set) var isHolding = false
        private var heldRead: Int?
        private var missing = 0
        private var waiter: CheckedContinuation<Void, Never>?

        static func sampledAt(read: Int) -> Date { Date(timeIntervalSince1970: 1_000 + Double(read)) }

        func hold(read number: Int) { heldRead = number }

        func miss(reads number: Int) { missing = number }

        func release() {
            heldRead = nil
            isHolding = false
            waiter?.resume()
            waiter = nil
        }

        func next() async -> EnergyImpactService.MenuBarCounterFrame? {
            count += 1
            let number = count
            startedAt.append(.now)
            guard number > missing else { return nil }
            if number == heldRead {
                isHolding = true
                await withCheckedContinuation { waiter = $0 }
            }
            let units = UInt64(number)
            let rows = EnergyImpactService.processRows(fromPSOutput: """
                201 1 2048 01:00 00:02 3 /Applications/D171Alpha.app/Contents/MacOS/D171Alpha
                202 1 4096 01:00 00:09 30 /Applications/D171Beta.app/Contents/MacOS/D171Beta
                """)
            return .init(sampledAt: Self.sampledAt(read: number), uptime: Double(number), rows: rows, counters: [
                201: .init(pid: 201, energyNanojoules: units * 1_000_000_000, cpuTimeMach: units * 1_000_000,
                           processStartMach: 11, diskReadBytes: units * 4_096, diskWrittenBytes: units * 1_024),
                202: .init(pid: 202, energyNanojoules: units * 3_000_000_000, cpuTimeMach: units * 9_000_000,
                           processStartMach: 12, diskReadBytes: units * 8_192, diskWrittenBytes: units * 2_048),
            ])
        }
    }
}
