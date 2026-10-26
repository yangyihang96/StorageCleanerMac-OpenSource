import Foundation
import XCTest
@testable import StorageCleanerMac

// Shared by Debug and Release tests; no DEBUG-only production test seam.
final class StartupWorkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    private var date = Date(timeIntervalSince1970: 100_000)
    func count(_ key: String) -> Int { lock.withLock { values[key, default: 0] } }
    func read(_ key: String) { lock.withLock { values[key, default: 0] += 1 } }
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

actor StartupSleepGate {
    private(set) var delays: [TimeInterval] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func sleep(_ seconds: TimeInterval) async throws {
        delays.append(seconds)
        await withCheckedContinuation { continuations.append($0) }
        try Task.checkCancellation()
    }
    func release() { let waiting = continuations; continuations = []; for item in waiting { item.resume() } }
}

enum StartupTestWait {
    @MainActor
    static func until(_ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock().now + .seconds(3)
        while !(await condition()) {
            guard clock.now < deadline else { throw NSError(domain: "StartupTestWait", code: 1) }
            await Task.yield()
        }
    }
}

final class StartupApplicationUpdateSchedulerTests: XCTestCase {
    @MainActor
    func testDueScanWaitsForPriorityWorkWithinBoundAndCoalescesActivation() async throws {
        let gate = StartupSleepGate(), calls = StartupWorkCounter()
        let scheduler = StartupApplicationUpdateScheduler(sleep: { try await gate.sleep($0) })
        scheduler.scheduleIfDue(shouldCheck: { true }, priorityReady: { false }, operation: { calls.read("scan") })
        scheduler.scheduleIfDue(shouldCheck: { true }, priorityReady: { true }, operation: { calls.read("duplicate") })
        try await StartupTestWait.until { await gate.delays.count == 1 }
        XCTAssertEqual(calls.count("scan"), 0, "No inventory or signature read during the first frame/first samples")
        await gate.release()
        try await StartupTestWait.until { await gate.delays.count == 2 }
        XCTAssertEqual(calls.count("scan"), 0)
        await gate.release()
        try await StartupTestWait.until { !scheduler.isPending }
        XCTAssertEqual(calls.count("scan"), 1)
        XCTAssertEqual(calls.count("duplicate"), 0)
        let delays = await gate.delays
        XCTAssertEqual(delays, [6, 4], "Automatic checks get a deadline at 10 seconds even with missing priority data")
    }

    @MainActor
    func testPriorityReadyUsesEarliestDeadline() async throws {
        let gate = StartupSleepGate(), calls = StartupWorkCounter()
        let scheduler = StartupApplicationUpdateScheduler(sleep: { try await gate.sleep($0) })
        scheduler.scheduleIfDue(shouldCheck: { true }, priorityReady: { true }, operation: { calls.read("scan") })
        try await StartupTestWait.until { await gate.delays.count == 1 }
        await gate.release()
        try await StartupTestWait.until { calls.count("scan") == 1 }
        let delays = await gate.delays
        XCTAssertEqual(delays, [6])
    }

    @MainActor
    func testOpeningUpdatesOrManualRefreshPromotesPendingScanExactlyOnce() async throws {
        let gate = StartupSleepGate(), calls = StartupWorkCounter()
        let scheduler = StartupApplicationUpdateScheduler(sleep: { try await gate.sleep($0) })
        scheduler.scheduleIfDue(shouldCheck: { true }, priorityReady: { false }, operation: { calls.read("scan") })
        try await StartupTestWait.until { await gate.delays.count == 1 }
        scheduler.promoteIfPending()
        scheduler.promoteIfPending()
        XCTAssertEqual(calls.count("scan"), 1, "No startup wait on explicit demand")
        await gate.release()
        await Task.yield()
        XCTAssertEqual(calls.count("scan"), 1, "A stale cancelled waiter cannot start a second scan")
    }

    @MainActor
    func testManualRequestCancelsDeferredAutomaticWorkAndRunsImmediately() async throws {
        let gate = StartupSleepGate(), calls = StartupWorkCounter()
        let scheduler = StartupApplicationUpdateScheduler(sleep: { try await gate.sleep($0) })
        scheduler.scheduleIfDue(shouldCheck: { true }, priorityReady: { false }, operation: { calls.read("automatic") })
        try await StartupTestWait.until { await gate.delays.count == 1 }
        scheduler.performUserRequest { calls.read("manual") }
        XCTAssertEqual(calls.count("manual"), 1)
        XCTAssertEqual(calls.count("automatic"), 0)
        await gate.release()
        await Task.yield()
        XCTAssertEqual(calls.count("automatic"), 0)
    }

    @MainActor
    func testWarmDisabledAndManualAutomaticChecksHaveZeroCalls() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let now = Date()
        ApplicationUpdateCheckSchedule.markChecked(at: now, defaults: defaults)
        var preferences = ApplicationUpdatePreferences.snapshot(defaults: defaults)
        for scenario in 0..<3 {
            if scenario == 1 { preferences.automaticallyChecks = false }
            if scenario == 2 { preferences.automaticallyChecks = true; preferences.checkFrequency = .manual }
            let selected = preferences, calls = StartupWorkCounter()
            let scheduler = StartupApplicationUpdateScheduler(sleep: { _ in calls.read("sleep") })
            scheduler.scheduleIfDue(shouldCheck: {
                ApplicationUpdateCheckSchedule.shouldCheck(preferences: selected, now: now, defaults: defaults)
            }, priorityReady: { true }, operation: { calls.read("scan") })
            await Task.yield()
            XCTAssertEqual(calls.count("scan"), 0)
            XCTAssertEqual(calls.count("sleep"), 0, "No scheduled work for a non-due policy")
        }
    }

    @MainActor
    func testPolicyChangeAndTerminationCannotStartDeferredScan() async throws {
        let gate = StartupSleepGate(), calls = StartupWorkCounter()
        let policy = StartupWorkCounter()
        let scheduler = StartupApplicationUpdateScheduler(sleep: { try await gate.sleep($0) })
        scheduler.scheduleIfDue(shouldCheck: { policy.count("disabled") == 0 }, priorityReady: { true }, operation: { calls.read("scan") })
        try await StartupTestWait.until { await gate.delays.count == 1 }
        policy.read("disabled")
        await gate.release()
        try await StartupTestWait.until { !scheduler.isPending }
        XCTAssertEqual(calls.count("scan"), 0)
        let other = StartupApplicationUpdateScheduler(sleep: { try await gate.sleep($0) })
        other.scheduleIfDue(shouldCheck: { true }, priorityReady: { true }, operation: { calls.read("scan") })
        try await StartupTestWait.until { await gate.delays.count == 2 }
        other.cancel()
        await gate.release()
        await Task.yield()
        XCTAssertEqual(calls.count("scan"), 0)
    }

    @MainActor
    func testBusyDeadlineRetainsIntentAndExistingOwnerReleaseRunsExactlyOnce() async throws {
        let coordinator = HeavyWorkCoordinator(), activity = HeavyWorkActivityStore(coordinator: coordinator)
        let lease = try await coordinator.acquire(owner: .mainScan)
        await activity.refresh()
        let gate = StartupSleepGate(), calls = StartupWorkCounter()
        let scheduler = StartupApplicationUpdateScheduler(sleep: { try await gate.sleep($0) })
        scheduler.observeCompletion(of: activity)
        scheduler.scheduleIfDue(shouldCheck: { true }, executionAvailable: { activity.activeOwner == nil },
            priorityReady: { true }, operation: { calls.read("scan") })
        try await StartupTestWait.until { await gate.delays.count == 1 }
        await gate.release()
        try await StartupTestWait.until { !scheduler.isDelaying }
        XCTAssertTrue(scheduler.isWaitingForAvailability, "The due intent survives a temporary busy lease")
        XCTAssertEqual(calls.count("scan"), 0)
        scheduler.executionAvailabilityDidChange()
        XCTAssertEqual(calls.count("scan"), 0, "An owner still holding the lease cannot execute")
        await coordinator.release(lease)
        await activity.refresh()
        try await StartupTestWait.until { !scheduler.isPending }
        scheduler.executionAvailabilityDidChange()
        scheduler.executionAvailabilityDidChange()
        XCTAssertEqual(calls.count("scan"), 1, "One existing heavy-work completion replays one retained intent")
        XCTAssertFalse(scheduler.isPending)
        let delays = await gate.delays
        XCTAssertEqual(delays, [6], "The busy deadline adds no polling or extra timer")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"), encoding: .utf8)
        let app = try r2SourceDeclaration("struct StorageCleanerMacApp:", in: source)
        let composition = try r2SourceDeclaration("init()", in: app)
        XCTAssertTrue(composition.contains("StartupApplicationUpdateScheduler.shared.observeCompletion(of: activityStore)"))
        XCTAssertFalse(source.contains(".onChange(of: heavyWorkActivityStore.activeOwner)"),
                       "Completion delivery must outlive main-window views")
        XCTAssertFalse(source.contains("shouldCheck: { ApplicationUpdateCheckSchedule.shouldCheck() && store.canRefreshAppUpdates }"))
    }

    @MainActor
    func testBusyIntentRechecksDisabledPolicyAndManualCompletionBeforeReplay() async throws {
        for manual in [false, true] {
            let gate = StartupSleepGate(), calls = StartupWorkCounter()
            let available = R2TestValue(false), eligible = R2TestValue(true)
            let scheduler = StartupApplicationUpdateScheduler(sleep: { try await gate.sleep($0) })
            scheduler.scheduleIfDue(shouldCheck: { eligible.value }, executionAvailable: { available.value },
                priorityReady: { true }, operation: { calls.read("automatic") })
            try await StartupTestWait.until { await gate.delays.count == 1 }
            await gate.release()
            try await StartupTestWait.until { !scheduler.isDelaying }
            XCTAssertTrue(scheduler.isWaitingForAvailability, "The due intent survives a temporary busy lease")
            if manual { scheduler.performUserRequest { calls.read("manual") } }
            eligible.value = false
            available.value = true
            scheduler.executionAvailabilityDidChange()
            scheduler.executionAvailabilityDidChange()
            XCTAssertEqual(calls.count("automatic"), 0)
            XCTAssertEqual(calls.count("manual"), manual ? 1 : 0)
            XCTAssertFalse(scheduler.isPending)
        }
    }

    @MainActor
    func testBusyIntentCannotReplayOrRescheduleAfterTermination() async throws {
        let gate = StartupSleepGate(), calls = StartupWorkCounter()
        let available = R2TestValue(false)
        let scheduler = StartupApplicationUpdateScheduler(sleep: { try await gate.sleep($0) })
        scheduler.scheduleIfDue(shouldCheck: { true }, executionAvailable: { available.value },
            priorityReady: { true }, operation: { calls.read("scan") })
        try await StartupTestWait.until { await gate.delays.count == 1 }
        await gate.release()
        try await StartupTestWait.until { !scheduler.isDelaying }
        XCTAssertTrue(scheduler.isWaitingForAvailability, "The due intent survives a temporary busy lease")
        scheduler.cancelForTermination()
        available.value = true
        scheduler.executionAvailabilityDidChange()
        scheduler.promoteIfPending()
        scheduler.scheduleIfDue(shouldCheck: { true }, priorityReady: { true }, operation: { calls.read("scan") })
        scheduler.performUserRequest { calls.read("scan") }
        XCTAssertEqual(calls.count("scan"), 0)
        XCTAssertFalse(scheduler.isPending)
    }

    @MainActor
    func testOldGenerationCannotPromoteNewDeadlineOnOwnerRelease() async throws {
        let oldGate = StartupSleepGate(), newGate = StartupSleepGate(), calls = StartupWorkCounter()
        let scheduler = StartupApplicationUpdateScheduler(sleep: { delay in
            calls.read("sleep")
            if calls.count("sleep") == 1 { try await oldGate.sleep(delay) }
            else { try await newGate.sleep(delay) }
        })
        scheduler.scheduleIfDue(shouldCheck: { true }, priorityReady: { true }, operation: { calls.read("old") })
        try await StartupTestWait.until { await oldGate.delays.count == 1 }
        scheduler.cancel()
        scheduler.scheduleIfDue(shouldCheck: { true }, priorityReady: { true }, operation: { calls.read("new") })
        try await StartupTestWait.until { await newGate.delays.count == 1 }
        await oldGate.release()
        await Task.yield()
        scheduler.executionAvailabilityDidChange()
        XCTAssertEqual(calls.count("old"), 0)
        XCTAssertEqual(calls.count("new"), 0, "An old completion cannot promote a newer first-frame deadline")
        await newGate.release()
        try await StartupTestWait.until { calls.count("new") == 1 }
        XCTAssertEqual(calls.count("old"), 0)
    }

    @MainActor
    func testProductionTerminationCancelsTimerAndBusyIntentBeforeBenchmarkAwait() async throws {
        for alreadyDue in [false, true] {
            let gate = StartupSleepGate(), benchmarkGate = StartupSleepGate(), calls = StartupWorkCounter()
            let available = R2TestValue(!alreadyDue)
            let scheduler = StartupApplicationUpdateScheduler(sleep: { try await gate.sleep($0) })
            scheduler.scheduleIfDue(shouldCheck: { true }, executionAvailable: { available.value },
                priorityReady: { true }, operation: { calls.read("scan") })
            try await StartupTestWait.until { await gate.delays.count == 1 }
            if alreadyDue {
                await gate.release()
                try await StartupTestWait.until { !scheduler.isDelaying }
                XCTAssertTrue(scheduler.isWaitingForAvailability, "The due intent survives a temporary busy lease")
            }
            let delegate = AppDelegate()
            delegate.startupApplicationUpdateScheduler = scheduler
            delegate.prepareBenchmarkForTermination = {
                calls.read("benchmark-await")
                try? await benchmarkGate.sleep(1)
            }
            let termination = Task { await delegate.prepareForTermination() }
            try await StartupTestWait.until { calls.count("benchmark-await") == 1 }
            XCTAssertFalse(scheduler.isPending, "Cancellation must precede the first termination await")
            available.value = true
            await gate.release()
            scheduler.executionAvailabilityDidChange()
            scheduler.scheduleIfDue(shouldCheck: { true }, priorityReady: { true }, operation: { calls.read("scan") })
            XCTAssertEqual(calls.count("scan"), 0)
            await benchmarkGate.release()
            await termination.value
            XCTAssertEqual(calls.count("scan"), 0)
        }
    }

    func testTerminationEntryAndImmediateCancellationHookCoverStartupScheduler() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"), encoding: .utf8)
        let entry = try r2SourceDeclaration("func applicationShouldTerminate(", in: source)
        let cancel = try XCTUnwrap(entry.range(of: "startupApplicationUpdateScheduler.cancelForTermination()"))
        let firstGuard = try XCTUnwrap(entry.range(of: "guard prepareBenchmarkForTermination"))
        XCTAssertLessThan(cancel.upperBound, firstGuard.lowerBound, "Cancel synchronously, even for immediate termination")
        let forced = try r2SourceDeclaration("func applicationWillTerminate(", in: source)
        XCTAssertTrue(forced.contains("startupApplicationUpdateScheduler.cancelForTermination()"))
        let hook = try r2SourceDeclaration("appDelegate.requestApplicationUpdateCancellation =", in: source)
        XCTAssertTrue(hook.contains("StartupApplicationUpdateScheduler.shared.cancelForTermination()"))
    }

}

final class ResidentStartupScheduleTests: XCTestCase {
    @MainActor
    func testEverySourceIsBoundedAndVisibleDemandPromotesWithoutChangingCadence() {
        let at = Date(timeIntervalSince1970: 100_000)
        let context = MenuBarSamplingContext()
        context.beginStartup(now: at)
        // D127: one loop at the selected interval (default 2 s) reads every
        // source; the test names the interval instead of relying on the
        // context's own default.
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: false,
            customFanControlActive: false, paused: false, now: at, selectedInterval: 2)
        for source in ResidentStartupSchedule.Source.allCases {
            XCTAssertFalse(context.permitsStartupSource(source, now: at))
            XCTAssertFalse(context.permitsStartupSource(source, now: at.addingTimeInterval(source.offset - 0.01)))
            XCTAssertTrue(context.permitsStartupSource(source, now: at.addingTimeInterval(source.offset)))
            XCTAssertLessThanOrEqual(source.offset, 4)
        }
        XCTAssertEqual(context.plan?.primaryKinds, MenuBarMetricKind.defaultSelection)
        // D127: process lists share the selected tick (was expensive 5, processes 15).
        XCTAssertEqual(context.plan?.cadence.expensive, 2)
        XCTAssertEqual(context.plan?.cadence.processes, 2)
        XCTAssertEqual(context.plan?.cadence.helperPower, 60)
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: true,
            customFanControlActive: false, paused: false, now: at, selectedInterval: 2)
        for source in ResidentStartupSchedule.Source.allCases { XCTAssertTrue(context.permitsStartupSource(source, now: at)) }
        XCTAssertTrue(context.plan?.permitsStartupHardware == true)
        XCTAssertEqual(context.plan?.cadence.expensive, 2)
        XCTAssertEqual(context.plan?.cadence.processes, 2)
    }

    @MainActor
    func testMetadataFirstReadWaitsUntilFourSecondsThenKeepsSixtySecondFloor() async throws {
        let at = Date(timeIntervalSince1970: 100_000), calls = StartupWorkCounter()
        let context = MenuBarSamplingContext()
        context.beginStartup(now: at)
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: false,
            customFanControlActive: false, paused: false, now: at)
        context.refreshResidentRead("helper.connection", now: at) { calls.read("helper") }
        await Task.yield()
        XCTAssertEqual(calls.count("helper"), 0)
        XCTAssertEqual(context.activeVisibleReadCount, 0)
        context.refreshResidentRead("helper.connection", now: at.addingTimeInterval(4)) { calls.read("helper") }
        try await StartupTestWait.until { calls.count("helper") == 1 && context.activeVisibleReadCount == 0 }
        context.refreshResidentRead("helper.connection", now: at.addingTimeInterval(63.99)) { calls.read("helper") }
        await Task.yield()
        XCTAssertEqual(calls.count("helper"), 1)
        context.refreshResidentRead("helper.connection", now: at.addingTimeInterval(64)) { calls.read("helper") }
        try await StartupTestWait.until { calls.count("helper") == 2 && context.activeVisibleReadCount == 0 }
    }

    @MainActor
    func testUnscheduledHardwareMakesZeroReadsAndStaysSamplingThenStarts() async throws {
        let at = Date(timeIntervalSince1970: 100_000), reads = StartupWorkCounter()
        let context = MenuBarSamplingContext()
        context.beginStartup(now: at)
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: false,
            customFanControlActive: false, paused: false, now: at)
        let sampler = SystemMonitorSampler(gpuReader: { reads.read("gpu"); return nil },
            temperatureAndFanReader: { reads.read("smc"); return .empty })
        let before = await sampler.snapshot(enabledKinds: [.gpuUsage, .chipTemperature], memorySnapshot: nil,
            previousNetworkSample: nil, samplingPlan: context.plan, now: at)
        let scheduled = await sampler.activeHardwareReadCount
        XCTAssertEqual(scheduled, 0)
        XCTAssertEqual(reads.count("gpu"), 0)
        XCTAssertEqual(reads.count("smc"), 0)
        XCTAssertEqual(before.snapshot.sensorAvailability, .sampling, "No unscheduled source is treated as a read failure")
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: false,
            customFanControlActive: false, paused: false, now: at.addingTimeInterval(0.75))
        _ = await sampler.snapshot(enabledKinds: [.gpuUsage, .chipTemperature], memorySnapshot: nil,
            previousNetworkSample: nil, samplingPlan: context.plan, now: at.addingTimeInterval(0.75))
        try await StartupTestWait.until { reads.count("gpu") == 1 && reads.count("smc") == 1 }
        await sampler.suspendResidentSampling()
    }

    @MainActor
    func testAuxiliaryPhysicalReadersAreStaggeredAndKeepAttemptFloors() async throws {
        let reads = StartupWorkCounter(), context = MenuBarSamplingContext()
        context.beginStartup(now: reads.now)
        // D127: the default 2 s tick, named instead of the context's own default.
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: false,
            customFanControlActive: false, paused: false, now: reads.now, selectedInterval: 2)
        let state = MenuBarAuxiliaryMonitorState(collectionClock: { reads.now },
            batteryAvailabilityProvider: { .present }, diskCounterProvider: { reads.read("disk"); return nil },
            storageVolumeProvider: { reads.read("volumes"); return .empty },
            batterySnapshotProvider: { reads.read("battery"); return (nil, nil) },
            publicNetworkConsentProvider: { false },
            networkProcessProvider: { reads.read("nettop"); return nil },
            processorTelemetryProvider: { reads.read("ioreport"); return nil },
            powerTelemetryProvider: { reads.read("power"); return .unsupported(at: reads.now) },
            powerTelemetryPause: {}, powerHistoryURL: nil, chargeLimitReader: { nil })
        state.attachSamplingContext(context)
        state.setPresentationVisible(false)
        defer { state.setPaused(true) }
        state.refreshResidentSamples()
        await Task.yield()
        XCTAssertEqual(reads.count("disk") + reads.count("battery") + reads.count("nettop") + reads.count("power"), 0)
        XCTAssertEqual(state.networkProcessSamplingState, .idle)
        reads.advance(1)
        state.refreshResidentSamples()
        try await StartupTestWait.until { reads.count("disk") == 1 && !state.isLocalDataRefreshActive }
        XCTAssertEqual(reads.count("nettop"), 0)
        XCTAssertEqual(reads.count("battery"), 1)
        XCTAssertEqual(reads.count("power"), 0)
        reads.advance(1)
        state.refreshResidentSamples()
        await Task.yield()
        // D127, D167: the network app list is read only while the network page
        // is open, so its startup slot reads nothing with the panel closed
        // (was: one nettop read here).
        XCTAssertEqual(reads.count("nettop"), 0)
        XCTAssertFalse(state.isNetworkProcessRefreshActive)
        XCTAssertEqual(reads.count("ioreport"), 0)
        reads.advance(0.5)
        state.refreshResidentSamples()
        try await StartupTestWait.until { reads.count("ioreport") == 1 && !state.isProcessorRefreshActive }
        reads.advance(0.5)
        state.refreshResidentSamples()
        // D127: every 2 s tick reads the disk, so the turn at 3 s is its second
        // read; the turns at 2 s and 2.5 s add none (was 1, against the old
        // 5 s expensive floor).
        try await StartupTestWait.until {
            reads.count("power") == 1 && !state.isPowerTelemetryRefreshActive && reads.count("disk") == 2
        }
        XCTAssertEqual(reads.count("disk"), 2, "No accelerated cheap reads from finite startup turns")
        XCTAssertEqual(state.powerTelemetry?.generatedAt, reads.now, "Use the real source date")
        // D127: the next read is due one tick later, less the 0.1 s tolerance
        // (was: still 1 after 2.99 s, 2 after 3 s, against the 5 s floor).
        reads.advance(1.85)
        state.refreshResidentSamples()
        await Task.yield()
        XCTAssertEqual(reads.count("disk"), 2)
        reads.advance(0.1)
        state.refreshResidentSamples()
        try await StartupTestWait.until { reads.count("disk") == 3 }
        // D127 replaced D75's hidden network reads (was 1, "D75's separate
        // hidden network floor remains"): nothing reads nettop while closed.
        XCTAssertEqual(reads.count("nettop"), 0, "D127: no network app list while its page is closed")
    }
}
