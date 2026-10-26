import Combine
import Foundation
import XCTest
@testable import StorageCleanerMac

final class MenuBarSamplingPlanTests: XCTestCase {
    private func plan(_ mode: MenuBarStatusDisplayMode = .memory, visible: Bool = false,
                      kinds: Set<MenuBarMetricKind> = [], fan: Bool = false,
                      status: Bool = true, paused: Bool = false,
                      selected: TimeInterval = 1) -> MenuBarSamplingPlan {
        .resolve(statusMode: mode, statusVisible: status, panelVisible: visible,
                 visibleKinds: kinds, customFanControlActive: fan, paused: paused,
                 selectedInterval: selected)
    }

    func testHiddenPlanContainsOnlyTheSelectedStatusSource() {
        for mode in MenuBarStatusDisplayMode.allCases {
            let value = plan(mode, kinds: MenuBarMetricKind.defaultSelection)
            XCTAssertEqual(value.primaryKinds, MenuBarMetricKind.defaultSelection)
            // D153: the combined icon draws the same status battery (was
            // `mode == .deviceStatus`); its Wi-Fi comes from its own monitor.
            XCTAssertEqual(value.needsStatusBattery, mode == .deviceStatus || mode == .combinedStatus)
            XCTAssertEqual(value.needsStatusWiFi, mode == .deviceStatus)
        }
    }

    func testVisiblePlanUnionsStatusAndCardDemandAndHiddenStatusStopsEverything() {
        XCTAssertEqual(plan(.network, visible: true, kinds: [.cpuUsage, .gpuUsage]).primaryKinds,
                       MenuBarMetricKind.defaultSelection)
        XCTAssertEqual(plan(status: false).primaryKinds, MenuBarMetricKind.defaultSelection)
        XCTAssertFalse(plan(status: false).needsStatusBattery)
        XCTAssertEqual(plan(.memory, visible: true, kinds: [.cpuUsage], status: false).primaryKinds,
                       MenuBarMetricKind.defaultSelection)
        XCTAssertTrue(plan(visible: true, kinds: MenuBarMetricKind.defaultSelection, paused: true).primaryKinds.isEmpty)
    }

    /// D127: sensors and the GPU follow the 1/2/3 s tick (was 5 s whatever
    /// the setting); custom fan control still reads sensors at least every
    /// 2 s, so only the 3 s tick is capped (was always 2 s).
    func testCustomFanDemandPreservesSafetyCadenceWithoutAddingUnrelatedSources() {
        let value = plan(.cpu, fan: true)
        XCTAssertEqual(value.primaryKinds, MenuBarMetricKind.defaultSelection)
        for selected in [1.0, 2, 3] {
            XCTAssertEqual(plan(.cpu, fan: true, selected: selected).thermalInterval, min(2, selected))
            XCTAssertEqual(plan(visible: true, kinds: [.chipTemperature], selected: selected).thermalInterval, selected)
            XCTAssertEqual(plan(.temperature, selected: selected).thermalInterval, selected)
            XCTAssertEqual(plan(visible: true, selected: selected).gpuInterval, selected)
        }
        XCTAssertEqual(MenuBarSamplingPlan.resolve(statusMode: .cpu, statusVisible: true, panelVisible: true,
            visibleKinds: [], customFanControlActive: true, paused: false, lowPower: true,
            selectedInterval: 3).thermalInterval, 30, "Low Power keeps its own tier")
    }

    func testHiddenStatusVisibilityAndLowPowerDoNotChangeTheSelectedVisibleSetting() {
        for interval in MenuBarRefreshInterval.allCases {
            XCTAssertEqual(interval.sleepNanoseconds(panelVisible: true, statusDisplayMode: .memory,
                customFanControlActive: false, lowPowerMode: true), 30_000_000_000)
            // D127: the closed panel keeps the selected tick (was 5 s).
            XCTAssertEqual(interval.sleepNanoseconds(panelVisible: false, statusDisplayMode: .cpu,
                customFanControlActive: false, lowPowerMode: false, statusVisible: false), interval.sleepNanoseconds)
            XCTAssertEqual(interval.sleepNanoseconds(panelVisible: false, statusDisplayMode: .cpu,
                customFanControlActive: false, lowPowerMode: true), 30_000_000_000)
        }
    }

    func testPSOutputLimitRejectsCombinedOverflowAndKeepsExactBoundary() {
        XCTAssertTrue(EnergyImpactService.processListOutputFitsLimit(stdoutBytes: 2_097_151, stderrBytes: 1))
        XCTAssertFalse(EnergyImpactService.processListOutputFitsLimit(stdoutBytes: 2_097_152, stderrBytes: 1))
        XCTAssertFalse(EnergyImpactService.processListOutputFitsLimit(stdoutBytes: .max, stderrBytes: 1))
        XCTAssertEqual(MenuBarPerformancePolicy.visibleProcessInterval, 10)
        XCTAssertEqual(MenuBarPerformancePolicy.firstProcessSampleInterval, 0.5)
        XCTAssertEqual(MenuBarPerformancePolicy.processSampleTimeout, 5)
    }

    /// D167: the module page (level 2) starts its process list once its first
    /// frame is drawn; the overview and pages without a process card never do.
    /// Was `testOverviewConfigurationAndSecondaryDemandDoNotStartProcessLists`:
    /// every section returned nil without a level-3 page
    /// (`section(_, tertiaryVisible: false)`), and the network list needed
    /// `tertiaryVisible: true`.
    func testOverviewDoesNotStartProcessListsButModulePagesDo() {
        var configuration = GeekDashboardConfiguration.defaultValue
        for module in GeekDashboardModule.allCases {
            configuration.setModule(module, isVisible: module == .network)
        }
        let overview = PanelDensity.geek.auxiliaryDemand(for: .overview, geekConfiguration: configuration)
        XCTAssertEqual(overview.primaryKinds, [.networkSpeed])
        XCTAssertFalse(overview.needsStorageCapacity)
        XCTAssertFalse(overview.needsBattery)
        let processPages: [PanelSection] = [.processor, .memory, .disk, .power]
        for section in PanelSection.allCases {
            // Before the first frame no page starts the network list.
            XCTAssertFalse(PanelDensity.geek.auxiliaryDemand(for: section).needsNetworkProcesses)
            XCTAssertEqual(PanelDensity.geek.auxiliaryDemand(for: section, startsProcessLists: true).needsNetworkProcesses,
                           section == .network, section.rawValue)
            XCTAssertEqual(MenuBarProcessSamplingDemand.section(section),
                           processPages.contains(section) ? section : nil, section.rawValue)
        }
        XCTAssertFalse(PanelDensity.complex.auxiliaryDemand(for: .network, startsProcessLists: true).needsNetworkProcesses)
    }

    @MainActor
    func testVisibilityAndMultipleConsumersChangeThePrimarySet() {
        let context = MenuBarSamplingContext()
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: true,
                          customFanControlActive: false, paused: false)
        let state = makeState()
        state.attachSamplingContext(context)
        let first = UUID(), second = UUID()
        state.registerConsumer(first, demand: demand(primary: [.networkSpeed]), paused: false)
        state.registerConsumer(second, demand: demand(primary: [.memoryUsage]), paused: false)
        XCTAssertEqual(context.plan?.primaryKinds, MenuBarMetricKind.defaultSelection)
        state.unregisterConsumer(first)
        XCTAssertEqual(context.plan?.primaryKinds, MenuBarMetricKind.defaultSelection)
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: false,
                          customFanControlActive: false, paused: false)
        state.setPresentationVisible(false)
        XCTAssertEqual(context.plan?.primaryKinds, MenuBarMetricKind.defaultSelection)
        state.unregisterConsumer(second)
        state.setPaused(true)
    }

    @MainActor
    func testPresentationUsesKeptTimestampBeforeFirstFreshDeltaThenReplacesIt() {
        let context = MenuBarSamplingContext()
        let start = Date(timeIntervalSinceReferenceDate: 50_000)
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: true,
                          customFanControlActive: false, paused: false, now: start)
        let kept = primarySnapshot(at: start, cpu: 31)
        context.rememberPanelSnapshot(kept)
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: false,
                          customFanControlActive: false, paused: false)
        // Reopened within the age cap (review P1-3: at most 10 s old).
        let reopened = start.addingTimeInterval(8)
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: true,
                          customFanControlActive: false, paused: false, now: reopened)
        let hidden = primarySnapshot(at: reopened.addingTimeInterval(-1), cpu: nil)
        XCTAssertEqual(context.presentationSnapshot(live: hidden, now: reopened)?.generatedAt, kept.generatedAt)
        let baseline = primarySnapshot(at: reopened, cpu: nil)
        context.rememberPanelSnapshot(baseline)
        XCTAssertEqual(context.presentationSnapshot(live: baseline, now: reopened)?.cpuUsageBreakdown?.totalPercent, 31)
        let fresh = primarySnapshot(at: reopened.addingTimeInterval(1), cpu: 42)
        context.rememberPanelSnapshot(fresh)
        XCTAssertEqual(context.presentationSnapshot(live: fresh, now: fresh.generatedAt)?.cpuUsageBreakdown?.totalPercent, 42)
        let failed = primarySnapshot(at: reopened.addingTimeInterval(6), cpu: nil)
        XCTAssertEqual(context.presentationSnapshot(live: failed, now: failed.generatedAt)?.cpuUsageBreakdown?.totalPercent, 42,
                     "D74 stored values keep their original age while a read is unavailable")
    }

    /// Review P1-3: a reading kept from a long-hidden panel is not shown as
    /// current; the live placeholder stays until fresh data replaces it.
    @MainActor
    func testKeptReadingOlderThanTheAgeCapIsNotPresentedOnReopen() {
        XCTAssertEqual(MenuBarSamplingContext.keptPresentationMaxAge, 10)
        let context = MenuBarSamplingContext()
        let start = Date(timeIntervalSinceReferenceDate: 60_000)
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: true,
                          customFanControlActive: false, paused: false, now: start)
        context.rememberPanelSnapshot(primarySnapshot(at: start, cpu: 31))
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: false,
                          customFanControlActive: false, paused: false)
        let reopened = start.addingTimeInterval(3_600)
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: true,
                          customFanControlActive: false, paused: false, now: reopened)
        let hidden = primarySnapshot(at: reopened.addingTimeInterval(-1), cpu: nil)
        let shown = context.presentationSnapshot(live: hidden, now: reopened)
        XCTAssertEqual(shown?.generatedAt, start)
        XCTAssertEqual(shown?.cpuUsageBreakdown?.totalPercent, 31, "D74 shows stored data with its age")
        let staleLive = primarySnapshot(at: start, cpu: 75)
        XCTAssertEqual(context.presentationSnapshot(live: staleLive, now: reopened)?.generatedAt, start,
                     "D74 never changes the source date when presenting a stored reading")
        let edge = start.addingTimeInterval(10)
        XCTAssertEqual(context.presentationSnapshot(live: hidden, now: edge)?.cpuUsageBreakdown?.totalPercent, 31)
        let fresh = primarySnapshot(at: reopened.addingTimeInterval(1), cpu: 42)
        context.rememberPanelSnapshot(fresh)
        XCTAssertEqual(context.presentationSnapshot(live: fresh, now: fresh.generatedAt)?.cpuUsageBreakdown?.totalPercent, 42)
    }

    /// Review P2: observers get one deduplicated plan per main-thread turn.
    @MainActor
    func testPlanChangesArePublishedOncePerMainTurn() async {
        let context = MenuBarSamplingContext()
        var received: [MenuBarSamplingPlan?] = []
        let cancellable = context.planChanges.dropFirst().sink { received.append($0) }
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: false,
                          customFanControlActive: false, paused: false)
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: true,
                          customFanControlActive: false, paused: false)
        context.setVisibleKinds([.memoryUsage, .networkSpeed])
        XCTAssertTrue(received.isEmpty, "Synchronous readers use `plan`; observers wait for the turn")
        XCTAssertEqual(context.plan?.primaryKinds, MenuBarMetricKind.defaultSelection)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.last??.primaryKinds, MenuBarMetricKind.defaultSelection)
        withExtendedLifetime(cancellable) {}
    }

    /// Review P2: the sampling context has a single pause writer (the
    /// controller's `configure`); the auxiliary monitor's own pause no longer
    /// rewrites the shared plan.
    @MainActor
    func testAuxiliaryPauseDoesNotRewriteTheSharedPlan() {
        let context = MenuBarSamplingContext()
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: true,
                          customFanControlActive: false, paused: false)
        let state = makeState()
        state.attachSamplingContext(context)
        state.setPaused(true)
        XCTAssertEqual(context.plan?.panelVisible, true)
        XCTAssertEqual(context.plan?.primaryKinds, MenuBarMetricKind.defaultSelection)
        state.registerConsumer(UUID(), demand: demand(), paused: true)
        XCTAssertEqual(context.plan?.panelVisible, true)
    }

    func testMemoryCacheSkipsHiddenReadsAndPreservesRealSampleDate() async {
        let probe = SamplingProbe()
        let sampler = MenuBarMemoryStatusSampler {
            probe.increment()
            return Self.memory(at: probe.date)
        }
        let first = await sampler.snapshot(needsRefresh: true)
        probe.advance(60)
        let hidden = await sampler.snapshot(needsRefresh: false)
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(hidden.generatedAt, first.generatedAt)
        let refreshed = await sampler.snapshot(needsRefresh: true)
        XCTAssertEqual(probe.count, 2)
        XCTAssertEqual(refreshed.generatedAt, probe.date)
        XCTAssertEqual(refreshed.physicalBytes, first.physicalBytes)
        XCTAssertTrue(refreshed.topProcesses.isEmpty)
    }

    func testElectricalCacheCoalescesSameTickAndDoesNotRetimestamp() async {
        let probe = SamplingProbe()
        let cache = MenuBarBatteryElectricalCache(clock: { probe.date.timeIntervalSinceReferenceDate }) {
            probe.increment()
            return nil
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = cache.snapshot() } }
        }
        XCTAssertEqual(probe.count, 1, "Even unsupported results are coalesced")
        probe.advance(1)
        _ = cache.snapshot()
        XCTAssertEqual(probe.count, 2)
    }

    /// Review P1-2 (N16-5, D5): while the panel is hidden the read-only
    /// battery/SMC electrical sample and its energy callback continue about
    /// every 30 s in any status mode; the charge limit is never read and the
    /// disk history stays off. Rewrites the earlier "callback 0 times"
    /// assertion: D5 forbids changing the charging state, not reading SMC.
    @MainActor
    func testHiddenBatteryKeepsReadOnlyEnergyIntegrationWithoutChargeLimit() async throws {
        let clock = SamplingProbe(), electrical = SamplingProbe(), disk = SamplingProbe(), charge = SamplingProbe()
        var callbacks = 0
        let accumulator = SystemEnergyAccumulator(fileURL: nil, now: clock.date,
            samplingGaps: MenuBarSamplingGaps(defaults: TestPreferenceDomain.make(for: self)), sampleProvider: { nil })
        let context = MenuBarSamplingContext()
        // D127: the slowest tick, 3 s (reads followed D74's 5 s before).
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: false,
                          customFanControlActive: false, paused: false, selectedInterval: 3)
        let state = MenuBarAuxiliaryMonitorState(
            collectionClock: { clock.date },
            batteryAvailabilityProvider: { .present },
            diskCounterProvider: { disk.increment(); return nil },
            batterySnapshotProvider: { electrical.increment(); return (Self.battery, Self.electrical(at: clock.date)) },
            powerHistoryURL: nil,
            chargeLimitReader: { charge.increment(); return nil }
        )
        state.onBatterySample = { battery, reading in
            callbacks += 1
            accumulator.recordBattery(battery, electrical: reading,
                uptime: clock.date.timeIntervalSinceReferenceDate)
        }
        state.attachSamplingContext(context)
        state.setPresentationVisible(false)
        state.refreshResidentSamples()
        try await waitUntil { electrical.count == 1 && !state.isLocalDataRefreshActive && !state.isDiskIOSamplingActive }
        XCTAssertEqual(callbacks, 1, "Energy integration continues while hidden")
        clock.advance(2)
        state.refreshResidentSamples()
        try await waitUntil { !state.isLocalDataRefreshActive && !state.isDiskIOSamplingActive }
        XCTAssertEqual(electrical.count, 1, "D127 every tick (3 s here), not every call (D74: 5 s)")
        clock.advance(1)
        state.refreshResidentSamples()
        try await waitUntil { electrical.count == 2 && !state.isLocalDataRefreshActive && !state.isDiskIOSamplingActive }
        XCTAssertEqual(callbacks, 2)
        XCTAssertEqual(state.powerHistory.count, 2, "Each actual read is retained in D39 history")
        XCTAssertEqual(accumulator.snapshot.batteryWattHours, 0,
                       "The existing accumulator keeps its independent 30-second integration gate")
        // D127: ten 3 s ticks span the same 30 s (D74: six 5 s ticks).
        for index in 2...10 {
            clock.advance(3)
            state.refreshResidentSamples()
            try await waitUntil { electrical.count == index + 1 && !state.isLocalDataRefreshActive && !state.isDiskIOSamplingActive }
        }
        XCTAssertEqual(callbacks, 11)
        XCTAssertEqual(state.powerHistory.count, 11)
        XCTAssertEqual(state.powerHistory.last?.date.timeIntervalSince(state.powerHistory[0].date), 30)
        XCTAssertEqual(accumulator.snapshot.batteryWattHours, 20 * 30 / 3_600, accuracy: 0.000_001,
                       "Actual hidden reads must still integrate after the unchanged accumulator gate")
        XCTAssertEqual(charge.count, 0, "Hidden sampling never reads the charge limit")
        XCTAssertEqual(disk.count, 11)
        state.setPaused(true)
        clock.advance(60)
        state.refreshResidentSamples()
        state.refreshBackgroundBatteryHistory(force: true)
        try await waitUntil { !state.isLocalDataRefreshActive && !state.isDiskIOSamplingActive }
        XCTAssertEqual(electrical.count, 11, "Paused sampling reads nothing")
    }

    @MainActor
    func testFailedResidentBatteryReadKeepsValueAndDateWithoutAcceleratingRetries() async throws {
        let clock = SamplingProbe(), reads = SamplingProbe()
        let context = MenuBarSamplingContext()
        // D127: attempts follow the 3 s tick here (D74: a 5 s floor).
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: true,
            customFanControlActive: false, paused: false, selectedInterval: 3)
        let state = MenuBarAuxiliaryMonitorState(collectionClock: { clock.date },
            batteryAvailabilityProvider: { .present }, diskCounterProvider: { nil },
            batterySnapshotProvider: {
                reads.increment()
                return reads.count == 1 ? (Self.battery, Self.electrical(at: clock.date)) : (nil, nil)
            }, powerHistoryURL: nil, chargeLimitReader: { nil })
        state.attachSamplingContext(context)
        defer { state.setPaused(true) }
        state.refreshResidentSamples()
        try await waitUntil { reads.count == 1 && !state.isLocalDataRefreshActive }
        let storedDate = state.batteryRefreshedAt
        let storedBattery = state.batterySnapshot
        clock.advance(3)
        state.refreshResidentSamples()
        try await waitUntil { reads.count == 2 && !state.isLocalDataRefreshActive }
        XCTAssertEqual(state.batterySnapshot, storedBattery)
        XCTAssertEqual(state.batteryRefreshedAt, storedDate)
        XCTAssertEqual(state.powerHistory.count, 1, "failed reads cannot create cached duplicate history")
        clock.advance(1)
        state.refreshResidentSamples()
        try await waitUntil { !state.isLocalDataRefreshActive }
        XCTAssertEqual(reads.count, 2, "a failure cannot bypass the tick's attempt floor")
        clock.advance(2)
        state.refreshResidentSamples()
        try await waitUntil { reads.count == 3 && !state.isLocalDataRefreshActive }
        XCTAssertEqual(state.batteryRefreshedAt, storedDate)
    }

    /// Review P1-1: a GPU or SMC source that leaves the plan drops its cache;
    /// a reopen much later never publishes the old value under a new time,
    /// and a read still running when the source left is not kept.
    func testSleepSuspensionDropsHardwareCachesBeforeQuickReopen() async throws {
        let gate = DispatchSemaphore(value: 0)
        let blockNext = SamplingProbe()
        let gpu = SamplingProbe(), sensors = SamplingProbe()
        let sampler = SystemMonitorSampler(gpuReader: {
            gpu.increment()
            if blockNext.count > 0 { _ = gate.wait(timeout: .now() + 3) }
            return GPUPerformanceSnapshot(usagePercent: 25, memoryUsedBytes: 1_024)
        }, temperatureAndFanReader: {
            sensors.increment()
            if blockNext.count > 0 { _ = gate.wait(timeout: .now() + 3) }
            return .init(gpuUsagePercent: nil, chipTemperatureCelsius: 55,
                         fanSpeedRPM: 0, fanCount: 1, fanSpeedsRPM: [0])
        })
        let visible = plan(.memory, visible: true, kinds: [.gpuUsage, .chipTemperature, .fanSpeed])
        let start = Date()
        func read(_ plan: MenuBarSamplingPlan, _ time: Date) async -> SystemMonitorService.SnapshotResult {
            await sampler.snapshot(enabledKinds: MenuBarMetricKind.defaultSelection,
                memorySnapshot: nil, previousNetworkSample: nil, resolvesMissingMemorySnapshot: false,
                samplingPlan: plan, now: time)
        }
        _ = await read(visible, start)
        try await Self.waitForHardware(sampler)
        let shown = await read(visible, start)
        XCTAssertEqual(shown.snapshot.gpuMemoryUsedBytes, 1_024)
        XCTAssertNotNil(shown.snapshot.sensorSampledAt)

        await sampler.suspendResidentSampling()
        _ = await read(plan(.memory, paused: true), start.addingTimeInterval(1))
        // Reopen inside both freshness windows: expiry must not hide a
        // failure to clear the caches when their sources leave the plan.
        let quickReopen = await read(visible, start.addingTimeInterval(2))
        XCTAssertNil(quickReopen.snapshot.gpuMemoryUsedBytes, "Leaving the plan invalidates even a fresh GPU cache")
        XCTAssertNil(quickReopen.snapshot.gpuSampledAt)
        XCTAssertNil(quickReopen.snapshot.sensorSampledAt)
        XCTAssertNil(quickReopen.snapshot.fanSpeedsRPM, "Leaving the plan invalidates even a fresh SMC cache")
        XCTAssertEqual(quickReopen.snapshot.sensorAvailability, .sampling)
        try await Self.waitForHardware(sampler)
        await sampler.suspendResidentSampling()
        _ = await read(plan(.memory, paused: true), start.addingTimeInterval(3))
        let reopened = await read(visible, start.addingTimeInterval(3_600))
        XCTAssertNil(reopened.snapshot.gpuMemoryUsedBytes, "An hour-old GPU reading must not be republished")
        XCTAssertNil(reopened.snapshot.gpuSampledAt)
        XCTAssertNil(reopened.snapshot.sensorSampledAt)
        XCTAssertNil(reopened.snapshot.fanSpeedsRPM, "An hour-old SMC reading must not be republished")
        XCTAssertEqual(reopened.snapshot.sensorAvailability, .sampling)

        // A read in flight when the sources leave is discarded on arrival.
        try await Self.waitForHardware(sampler)
        blockNext.increment()
        _ = await read(visible, start.addingTimeInterval(3_700))
        _ = await read(plan(.memory), start.addingTimeInterval(3_701))
        gate.signal(); gate.signal()
        try await Self.waitForHardware(sampler)
        gate.signal(); gate.signal()  // later reads in this test do not block
        let afterDiscard = await read(visible, start.addingTimeInterval(7_200))
        XCTAssertNil(afterDiscard.snapshot.gpuMemoryUsedBytes)
        XCTAssertNil(afterDiscard.snapshot.sensorSampledAt)
        try await Self.waitForHardware(sampler)
    }

    /// An in-flight GPU read must be discarded even if the panel reopens
    /// before it finishes and its timestamp remains inside the age cap.
    @MainActor
    func testGPUReadInFlightWhenSleepSuspendsSourcesIsDiscardedBeforeQuickReopen() async throws {
        let gate = DispatchSemaphore(value: 0)
        let gpu = SamplingProbe(), timeouts = SamplingProbe()
        defer { gate.signal(); gate.signal() }
        let sampler = SystemMonitorSampler(gpuReader: {
            gpu.increment()
            let call = gpu.count
            if gate.wait(timeout: .now() + 5) == .timedOut { timeouts.increment() }
            return GPUPerformanceSnapshot(usagePercent: call == 1 ? 25 : 60,
                                          memoryUsedBytes: call == 1 ? 1_024 : 2_048)
        }, temperatureAndFanReader: { .empty })
        let visible = plan(.memory, visible: true, kinds: [.gpuUsage])
        let hidden = plan(.memory, paused: true)
        let start = Date(timeIntervalSinceReferenceDate: 80_000)
        func read(_ plan: MenuBarSamplingPlan, _ seconds: TimeInterval) async -> SystemMonitorSnapshot {
            await sampler.snapshot(enabledKinds: MenuBarMetricKind.defaultSelection,
                memorySnapshot: nil, previousNetworkSample: nil, resolvesMissingMemorySnapshot: false,
                samplingPlan: plan, now: start.addingTimeInterval(seconds)).snapshot
        }
        _ = await read(visible, 0)
        try await waitUntil { gpu.count == 1 }
        _ = await read(hidden, 1)
        let beforeCompletion = await read(visible, 2)
        XCTAssertNil(beforeCompletion.gpuMemoryUsedBytes)
        XCTAssertEqual(gpu.count, 1, "Reopen cannot overlap the physical GPU read")
        let firstPending = await sampler.isHardwareReadInFlight
        XCTAssertTrue(firstPending)

        gate.signal()
        try await Self.waitForHardware(sampler)
        let afterCompletion = await read(visible, 3)
        XCTAssertNil(afterCompletion.gpuMemoryUsedBytes,
                     "A discarded completion cannot become the fresh cache on reopen")
        XCTAssertNil(afterCompletion.gpuSampledAt)
        XCTAssertEqual(afterCompletion.sensorAvailability, .sampling)
        try await waitUntil { gpu.count == 2 }
        let replacementPending = await sampler.isHardwareReadInFlight
        XCTAssertTrue(replacementPending, "Discarding the old result starts one replacement read")

        gate.signal()
        try await Self.waitForHardware(sampler)
        // D127: within the 1 s tick of the replacement (was 4 s within 5 s).
        let fresh = await read(visible, 3.5)
        XCTAssertEqual(gpu.count, 2)
        XCTAssertEqual(timeouts.count, 0, "Gates, not provider timeouts, control the test sequence")
        XCTAssertEqual(fresh.gpuMemoryUsedBytes, 2_048)
        XCTAssertEqual(fresh.gpuSampledAt, start.addingTimeInterval(3))
        XCTAssertEqual(fresh.sensorAvailability, .available)
    }

    /// Review P2: two refreshes in one burst must not divide CPU ticks by a
    /// near-zero interval (same 0.2 s floor as the network delta).
    func testCPUDeltaKeepsTheNetworkMinimumInterval() async throws {
        XCTAssertEqual(SystemMonitorSampler.minimumCPUDeltaInterval, 0.2)
        let cpu = SamplingProbe()
        let sampler = SystemMonitorSampler(gpuReader: { nil }, temperatureAndFanReader: { .empty },
            cpuCounterReader: {
                cpu.increment()
                let ticks = SystemMonitorService.CPUUsageTicks(user: UInt64(cpu.count * 20),
                    system: UInt64(cpu.count * 10), idle: UInt64(cpu.count * 70), nice: 0)
                return ([ticks], ticks)
            })
        let cpuOnly = plan(.cpu)
        let start = Date()
        func read(_ time: Date) async -> CPUUsageBreakdown? {
            await sampler.snapshot(enabledKinds: [.cpuUsage], memorySnapshot: nil, previousNetworkSample: nil,
                resolvesMissingMemorySnapshot: false, samplingPlan: cpuOnly, now: time).snapshot.cpuUsageBreakdown
        }
        _ = await read(start)
        let measuredRead = await read(start.addingTimeInterval(1))
        let measured = try XCTUnwrap(measuredRead)
        let burst = await read(start.addingTimeInterval(1.1))
        XCTAssertEqual(burst, measured, "A sample 0.1 s later repeats the last real interval")
        XCTAssertEqual(cpu.count, 2, "The baseline must not move during the minimum interval")
        let later = await read(start.addingTimeInterval(1.4))
        XCTAssertNotNil(later)
        XCTAssertEqual(cpu.count, 3)
    }

    func testHardwareHistoryKeepsSourceTimesAndRejectsExpiredSingleFlightCache() async throws {
        let gpu = SamplingProbe(), sensors = SamplingProbe()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); gate.signal() }
        let sampler = SystemMonitorSampler(gpuReader: {
            gpu.increment()
            if gpu.count == 2 { _ = gate.wait(timeout: .now() + 5) }
            return GPUPerformanceSnapshot(usagePercent: 25, memoryUsedBytes: 1_024)
        }, temperatureAndFanReader: {
            sensors.increment()
            if sensors.count == 2 { _ = gate.wait(timeout: .now() + 5) }
            return .init(gpuUsagePercent: nil, chipTemperatureCelsius: 55,
                         fanSpeedRPM: 0, fanCount: 1, fanSpeedsRPM: [0])
        })
        // D127: the slowest tick, 3 s; the cached read at 2 s stays inside it
        // (D74: 4 s inside 5 s).
        let visible = plan(.cpu, visible: true, kinds: [.gpuUsage, .chipTemperature, .fanSpeed], selected: 3)
        let start = Date(timeIntervalSinceReferenceDate: 70_000)
        func read(_ seconds: TimeInterval) async -> SystemMonitorSnapshot {
            await sampler.snapshot(enabledKinds: MenuBarMetricKind.defaultSelection,
                memorySnapshot: nil, previousNetworkSample: nil, resolvesMissingMemorySnapshot: false,
                samplingPlan: visible, now: start.addingTimeInterval(seconds)).snapshot
        }
        _ = await read(0)
        try await Self.waitForHardware(sampler)
        let first = await read(1)
        let cached = await read(2)
        XCTAssertEqual(cached.generatedAt, start.addingTimeInterval(2))
        XCTAssertEqual(cached.sensorReadingDate, start)
        XCTAssertEqual(cached.gpuReadingDate, start)
        let history = MenuBarTelemetryPoint(snapshot: cached).replacingMemory(with: nil)
        XCTAssertEqual(history.sensorSampledAt, start)
        XCTAssertEqual(history.gpuSampledAt, start)
        let restored = try JSONDecoder().decode(MenuBarTelemetryPoint.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(restored, history, "Persistence must preserve source dates")
        let channelSets: [[MenuBarTelemetryChannel]] = [[.gpu], [.chipTemperature, .fanRPM]]
        for channels in channelSets {
            let observations = MenuBarTelemetryPoint.historyPoints([.init(snapshot: first), restored], channels: channels)
            XCTAssertEqual(observations.count, 1, "Cached publications are one hardware observation")
            XCTAssertEqual(observations.first?.date, start)
        }
        XCTAssertEqual(MenuBarTelemetryChannel.cpuTotal.sampleDate(in: restored), cached.generatedAt)
        let frame = GeekPreparedLineFrame(points: [.init(snapshot: first), restored], channels: [.gpu],
            plot: CGRect(x: 0, y: 0, width: 360, height: 100), duration: 60,
            reference: cached.generatedAt, samplingInterval: 5, scale: 2, stacked: true, valueRange: 0...100)
        XCTAssertEqual(frame.sourcePoints.count, 1)
        XCTAssertEqual(frame.sourcePoints.first?.date, start)

        _ = await read(5)
        let expired = await read(11)
        let expiredHistory = MenuBarTelemetryPoint(snapshot: expired)
        XCTAssertNil(expired.gpuMemoryUsedBytes)
        XCTAssertNil(expired.sensorSampledAt)
        XCTAssertNil(expiredHistory.gpu)
        XCTAssertNil(expiredHistory.chipTemperature)
        XCTAssertNil(expiredHistory.fanRPM)
        XCTAssertEqual(expired.sensorAvailability, .sampling)
        gate.signal(); gate.signal()
        try await Self.waitForHardware(sampler)
        let fresh = await read(11)
        XCTAssertEqual(fresh.sensorSampledAt, start.addingTimeInterval(5))
        XCTAssertEqual(fresh.gpuSampledAt, start.addingTimeInterval(5))
        try await Self.waitForHardware(sampler)
    }

    @MainActor
    func testRecentPublicationCannotMakeOldHardwareCurrentOnReopen() {
        let context = MenuBarSamplingContext()
        let now = Date(timeIntervalSinceReferenceDate: 80_000)
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: true,
            customFanControlActive: false, paused: false, now: now)
        let snapshot = SystemMonitorSnapshot(generatedAt: now, metrics: [], networkThroughput: nil,
            cpuUsageBreakdown: .init(totalPercent: 31, userPercent: 31, systemPercent: 0),
            fanSpeedsRPM: [1_000], gpuMemoryUsedBytes: 1_024,
            sensorSampledAt: now.addingTimeInterval(-11), gpuSampledAt: now.addingTimeInterval(-11))
        let shown = context.presentationSnapshot(live: snapshot, now: now)
        XCTAssertEqual(shown?.cpuUsageBreakdown?.totalPercent, 31)
        XCTAssertEqual(shown?.fanSpeedsRPM, [1_000])
        XCTAssertEqual(shown?.gpuMemoryUsedBytes, 1_024)
        XCTAssertEqual(shown?.sensorSampledAt, now.addingTimeInterval(-11))
        XCTAssertEqual(shown?.gpuSampledAt, now.addingTimeInterval(-11))
        XCTAssertNil(context.presentationSnapshot(live: primarySnapshot(at: now.addingTimeInterval(1), cpu: 99), now: now),
                     "A future timestamp is not evidence of freshness")
    }

    @MainActor
    func testVisibleBatteryCadenceAndCacheFirstReopenWithFakeClock() async throws {
        let probe = SamplingProbe()
        let state = makeState(clock: probe, battery: probe)
        let consumer = UUID()
        state.registerConsumer(consumer, demand: demand(battery: true), paused: false)
        try await waitUntil { state.batteryRefreshedAt != nil && !state.isLocalDataRefreshActive }
        let sampled = state.batteryRefreshedAt
        probe.advance(4)
        state.refreshFromPrimaryMonitorUpdate()
        try await waitUntil { !state.isLocalDataRefreshActive }
        XCTAssertEqual(probe.count, 1)
        state.unregisterConsumer(consumer)
        state.registerConsumer(consumer, demand: demand(battery: true), paused: false)
        XCTAssertEqual(state.batteryRefreshedAt, sampled)
        XCTAssertEqual(state.batterySnapshot?.chargePercent, 70)
        XCTAssertEqual(probe.count, 1)
        probe.advance(1)
        state.refreshFromPrimaryMonitorUpdate()
        try await waitUntil { !state.isLocalDataRefreshActive && probe.count == 2 }
        XCTAssertEqual(state.batteryRefreshedAt, probe.date)
        XCTAssertEqual(probe.date.timeIntervalSince(try XCTUnwrap(state.batteryRefreshedAt)), 0)
        state.unregisterConsumer(consumer)
        state.setPaused(true)
    }

    @MainActor
    func testNetworkSubprocessHasTenSecondFloorAndStopsWhenDemandCloses() async throws {
        let probe = SamplingProbe()
        let state = MenuBarAuxiliaryMonitorState(
            collectionClock: { probe.date }, batteryAvailabilityProvider: { .absent },
            diskCounterProvider: { nil }, batterySnapshotProvider: { (nil, nil) },
            networkProcessProvider: {
                probe.increment()
                return NativeNetworkProcessSnapshot(generatedAt: probe.date, processes: [])
            }, powerHistoryURL: nil
        )
        let id = UUID()
        state.registerConsumer(id, demand: demand(networkProcesses: true), paused: false)
        try await waitUntil { !state.isNetworkProcessRefreshActive }
        probe.advance(9)
        state.refreshFromPrimaryMonitorUpdate()
        try await waitUntil { !state.isNetworkProcessRefreshActive }
        XCTAssertEqual(probe.count, 1)
        probe.advance(1)
        state.refreshFromPrimaryMonitorUpdate()
        try await waitUntil { !state.isNetworkProcessRefreshActive && probe.count == 2 }
        XCTAssertEqual(state.networkProcessSnapshot?.generatedAt, probe.date)
        state.updateConsumer(id, demand: demand())
        probe.advance(20)
        state.requestManualRefresh()
        try await waitUntil { !state.isNetworkProcessRefreshActive && !state.isLocalDataRefreshActive }
        XCTAssertEqual(probe.count, 2)
        XCTAssertNotNil(state.networkProcessSnapshot, "Secondary card keeps its previous Top-K")
        state.unregisterConsumer(id)
        state.setPaused(true)
    }

    func testHiddenPrimaryGateDoesNotInvokeGPUOrSensorsAndVisibleRefreshesWithinFloor() async throws {
        let gpu = SamplingProbe(), sensors = SamplingProbe()
        let sampler = SystemMonitorSampler(gpuReader: {
            gpu.increment()
            return GPUPerformanceSnapshot(usagePercent: 25, memoryUsedBytes: 1_024)
        }, temperatureAndFanReader: {
            sensors.increment()
            return .init(gpuUsagePercent: nil, chipTemperatureCelsius: 55,
                         fanSpeedRPM: 0, fanCount: 1, fanSpeedsRPM: [0])
        })
        let start = Date()
        // D127: the slowest tick, 3 s (D74: a 5 s floor whatever the setting).
        _ = await sampler.snapshot(enabledKinds: MenuBarMetricKind.defaultSelection,
            memorySnapshot: nil, previousNetworkSample: nil, resolvesMissingMemorySnapshot: false,
            samplingPlan: plan(.memory, selected: 3), now: start)
        try await Self.waitForHardware(sampler)
        XCTAssertEqual(gpu.count, 1)
        XCTAssertEqual(sensors.count, 1)
        let visible = plan(.memory, visible: true, kinds: [.gpuUsage, .chipTemperature, .fanSpeed], selected: 3)
        func read(_ time: Date) async -> SystemMonitorService.SnapshotResult {
            await sampler.snapshot(enabledKinds: MenuBarMetricKind.defaultSelection,
                memorySnapshot: nil, previousNetworkSample: nil, resolvesMissingMemorySnapshot: false,
                samplingPlan: visible, now: time)
        }
        _ = await read(start)
        var result = await read(start)
        // Functional wait for the detached fake provider (not a latency
        // budget); a fixed iteration count was flaky at load ~25.
        let firstDeadline = ContinuousClock.now + .seconds(5)
        while result.snapshot.sensorAvailability != .available || result.snapshot.gpuMemoryUsedBytes == nil,
              ContinuousClock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(2))
            result = await read(start)
        }
        try await Self.waitForHardware(sampler)
        result = await read(start)
        XCTAssertEqual(gpu.count, 1)
        XCTAssertEqual(sensors.count, 1)
        XCTAssertEqual(result.snapshot.fanSpeedsRPM, [0], "Zero RPM remains a measured stop")
        let cachedAtFour = await read(start.addingTimeInterval(2))
        try await Self.waitForHardware(sampler)
        XCTAssertEqual(cachedAtFour.snapshot.sensorSampledAt, start,
                       "Cheap publication must not retimestamp the SMC cache")
        XCTAssertEqual(gpu.count, 1)
        XCTAssertEqual(sensors.count, 1)
        _ = await read(start.addingTimeInterval(3.2))
        let secondDeadline = ContinuousClock.now + .seconds(5)
        while gpu.count < 2 || sensors.count < 2, ContinuousClock.now < secondDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(gpu.count, 2)
        XCTAssertEqual(sensors.count, 2)
    }

    /// With the 10 s process cadence, a reader that gave nothing and then
    /// recovers takes its first delta after the short N16-2 interval rather
    /// than one more full cadence; an ordinary first read stays a baseline.
    func testRecoveredProcessReaderTakesFirstDeltaWithoutAnotherFullCadence() async throws {
        let recovering = RecoveringFrameReader(missing: 1)
        let sampler = MenuBarProcessSampler(read: { recovering.next() })
        let missed = await sampler.sample()
        XCTAssertNil(missed)
        let started = ContinuousClock.now
        let recovered = await sampler.sample()
        XCTAssertNotNil(recovered, "The recovered reader must not wait another 10 s cadence")
        XCTAssertEqual(recovering.reads, 3)
        XCTAssertLessThan(started.duration(to: .now), .seconds(MenuBarPerformancePolicy.visibleProcessInterval))

        let ordinary = RecoveringFrameReader(missing: 0)
        let fresh = MenuBarProcessSampler(read: { ordinary.next() })
        let baseline = await fresh.sample()
        XCTAssertNil(baseline)
        XCTAssertEqual(ordinary.reads, 1, "A normal first read is a baseline only; no extra ps")
        let delta = await fresh.sample()
        XCTAssertNotNil(delta)
        XCTAssertEqual(ordinary.reads, 2)
    }

    func testSourceWiringKeepsD5AndTimeoutsAndCachedPresentationBeforeRefresh() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let controller = try r2ProductionSource(at: root.appendingPathComponent("Sources/StorageCleanerMac/Support/MenuBarStatusController.swift"))
        XCTAssertTrue(controller.contains("attachMenuBarResidentSampling(.shared)"))
        XCTAssertTrue(controller.contains("statusItem.observe(\\.isVisible"))
        XCTAssertTrue(controller.contains("NSWorkspace.activeSpaceDidChangeNotification"))
        XCTAssertTrue(controller.contains("Notification.Name.NSProcessInfoPowerStateDidChange"))
        let opening = try r2SourceDeclaration("private func beginPanelPresentation", in: controller)
        XCTAssertTrue(opening.contains("Task { @MainActor [weak store]"))
        XCTAssertEqual(opening.components(separatedBy: "updateSamplingContext(").count - 1, 1,
                       "Open updates the sampling plan once")
        XCTAssertTrue(opening.contains("startRefreshLoop(store: store, updatesContext: false)"))
        let loop = try r2SourceDeclaration("private func startRefreshLoop", in: controller)
        XCTAssertTrue(loop.contains("refreshTask == nil else { return }"),
                      "State changes keep the running task and its pending deadline")
        XCTAssertFalse(loop.contains("refreshTask?.cancel()"))
        XCTAssertTrue(loop.contains("refreshMenuBarResidentSamples()"))
        let auxiliary = try r2ProductionSource(at: root.appendingPathComponent("Sources/StorageCleanerMac/Support/MenuBarAuxiliaryMonitorState.swift"))
        let battery = try r2SourceDeclaration("private func refreshBattery(", in: auxiliary)
        let background = try r2SourceDeclaration("func refreshBackgroundBatteryHistory(", in: auxiliary)
        for forbidden in ["temporarilyEnableCharging", "temporarilyDisableSmartCharging", "setPreferredTarget", "requestFullCharge"] {
            XCTAssertFalse(battery.contains(forbidden), forbidden)
            XCTAssertFalse(background.contains(forbidden), forbidden)
        }
        XCTAssertFalse(auxiliary.contains("samplingContext?.setPaused"), "Single pause writer")
        let recording = try r2SourceDeclaration("private func recordBatterySample(", in: auxiliary)
        XCTAssertTrue(recording.contains("if isPresentationVisible, !isPaused, combinedDemand.needsChargeLimit"))
        let native = try r2ProductionSource(at: root.appendingPathComponent("Sources/StorageCleanerMac/Services/NativeBatteryElectricalService.swift"))
        for forbidden in ["IORegistryEntrySet", "SMCWrite", "setPreferredTarget", "temporarilyEnableCharging", "temporarilyDisableSmartCharging"] {
            XCTAssertFalse(native.contains(forbidden), forbidden)
            XCTAssertFalse(recording.contains(forbidden), forbidden)
        }
        let coordinator = try r2ProductionSource(at: root.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift"))
        XCTAssertTrue(coordinator.contains("await MenuBarSamplingContext.awaitPresentationTurn()"))
        XCTAssertTrue(coordinator.contains("planChanges.removeDuplicates()"))
        // D167: was "tertiaryVisible: tertiaryVisible && hasPresentedFirstFrame".
        XCTAssertTrue(coordinator.contains("startsProcessLists: hasPresentedFirstFrame"))
        let nettop = try r2ProductionSource(at: root.appendingPathComponent("Sources/StorageCleanerMac/Services/NativeNetworkProcessService.swift"))
        XCTAssertTrue(nettop.contains("timeout: 4"))
        XCTAssertTrue(nettop.contains("outputByteLimit: 2 * 1_024 * 1_024"))
        XCTAssertTrue(nettop.contains("cancellationCheck: cancellationCheck"))
    }

    @MainActor
    func testRapidCloseReopenKeepsPowerProviderPhysicallySingleFlight() async throws {
        let unexpectedOverlap = expectation(description: "No second physical read before release")
        unexpectedOverlap.isInverted = true
        let probe = BlockedPowerProbe(onEarlyRead: { unexpectedOverlap.fulfill() })
        let state = MenuBarAuxiliaryMonitorState(
            batteryAvailabilityProvider: { .absent }, diskCounterProvider: { nil },
            batterySnapshotProvider: { (nil, nil) }, powerTelemetryProvider: { probe.sample() },
            powerTelemetryPause: {}, powerHistoryURL: nil
        )
        let power = MenuBarAuxiliaryMonitorDemand(needsProcessorTelemetry: false,
            needsDiskIOSampling: false, needsNetworkInterface: false,
            needsPublicNetworkAddress: false, needsNetworkProcesses: false,
            needsPowerTelemetry: true, needsStorageCapacity: false, needsBattery: false)
        let id = UUID()
        defer { probe.release(); state.unregisterConsumer(id); state.setPaused(true) }
        state.registerConsumer(id, demand: power, paused: false)
        try await waitUntil { probe.count == 1 }
        state.unregisterConsumer(id)
        state.registerConsumer(id, demand: power, paused: false)
        state.requestManualRefresh()
        let noOverlap = await XCTWaiter.fulfillment(of: [unexpectedOverlap], timeout: 0.1)
        XCTAssertEqual(noOverlap, .completed)
        XCTAssertEqual(probe.count, 1, "Cancellation must not open another synchronous SMC pass")
        probe.release()
        try await waitUntil { state.powerTelemetry != nil && !state.isPowerTelemetryRefreshActive }
        XCTAssertEqual(probe.count, 2, "The cancelled completion triggers one replacement")
        XCTAssertEqual(probe.maximumActive, 1)
        XCTAssertFalse(probe.timedOut)
    }

    @MainActor
    func testVisibleConnectionReadsCoalesceAcrossRapidOpensAndStopWhenHidden() async throws {
        let context = MenuBarSamplingContext(), probe = SamplingProbe()
        // D127: visible reads share the 3 s tick here (D74: a 5 s floor).
        func visible(_ value: Bool) {
            context.configure(statusMode: .cpu, statusVisible: true, panelVisible: value,
                customFanControlActive: false, paused: false, now: probe.date, selectedInterval: 3)
        }
        func request() {
            context.refreshVisibleRead("helper.connection", now: probe.date) { probe.increment() }
        }
        visible(true)
        request()
        request()
        try await waitUntil { probe.count == 1 && context.activeVisibleReadCount == 0 }
        visible(false)
        visible(true)
        probe.advance(2)
        request()
        try await waitUntil { context.activeVisibleReadCount == 0 }
        XCTAssertEqual(probe.count, 1)
        probe.advance(1)
        request()
        try await waitUntil { probe.count == 2 && context.activeVisibleReadCount == 0 }
        probe.advance(3)
        request()
        visible(false)
        try await waitUntil { context.activeVisibleReadCount == 0 }
        XCTAssertEqual(probe.count, 2, "A queued XPC read must recheck visibility before starting")
        probe.advance(10)
        request()
        await Task.yield()
        XCTAssertEqual(probe.count, 2)
    }

    @MainActor
    func testClosingBeforeScheduledWorkStartsDoesNotLaunchExpensiveProviders() async throws {
        let network = SamplingProbe(), power = SamplingProbe(), battery = SamplingProbe()
        let state = MenuBarAuxiliaryMonitorState(
            batteryAvailabilityProvider: { .absent }, diskCounterProvider: { nil },
            batterySnapshotProvider: { battery.increment(); return (nil, nil) },
            networkProcessProvider: { network.increment(); return nil },
            powerTelemetryProvider: { power.increment(); return .unsupported(at: Date()) },
            powerTelemetryPause: {}, powerHistoryURL: nil
        )
        let id = UUID()
        state.registerConsumer(id, demand: .init(needsProcessorTelemetry: false,
            needsDiskIOSampling: false, needsNetworkInterface: false,
            needsPublicNetworkAddress: false, needsNetworkProcesses: true,
            needsPowerTelemetry: true, needsStorageCapacity: false, needsBattery: true), paused: false)
        state.unregisterConsumer(id)
        try await waitUntil { !state.isNetworkProcessRefreshActive && !state.isPowerTelemetryRefreshActive && !state.isLocalDataRefreshActive }
        XCTAssertEqual(network.count, 0)
        XCTAssertEqual(power.count, 0)
        XCTAssertEqual(battery.count, 0)
        state.setPaused(true)
    }

    private static func waitForHardware(_ sampler: SystemMonitorSampler) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await sampler.isHardwareReadInFlight, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let pending = await sampler.isHardwareReadInFlight
        XCTAssertFalse(pending, "Fake hardware provider must drain before counting reads")
    }

    @MainActor
    private func makeState(clock: SamplingProbe = SamplingProbe(), battery: SamplingProbe? = nil) -> MenuBarAuxiliaryMonitorState {
        MenuBarAuxiliaryMonitorState(collectionClock: { clock.date },
            batteryAvailabilityProvider: { .present }, diskCounterProvider: { nil },
            batterySnapshotProvider: { battery?.increment(); return (Self.battery, nil) },
            publicNetworkConsentProvider: { false }, powerHistoryURL: nil,
            chargeLimitReader: { nil })
    }

    private func demand(primary: Set<MenuBarMetricKind> = [], battery: Bool = false,
                        networkProcesses: Bool = false) -> MenuBarAuxiliaryMonitorDemand {
        .init(needsProcessorTelemetry: false, needsDiskIOSampling: false,
              needsNetworkInterface: false, needsPublicNetworkAddress: false,
              needsNetworkProcesses: networkProcesses, needsStorageCapacity: false,
              needsBattery: battery, primaryKinds: primary)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition(), "Sampling task did not complete before the test deadline")
    }

    private func primarySnapshot(at date: Date, cpu: Double?) -> SystemMonitorSnapshot {
        .init(generatedAt: date, metrics: [], networkThroughput: nil,
              cpuUsageBreakdown: cpu.map { .init(totalPercent: $0, userPercent: $0, systemPercent: 0) })
    }

    private static func electrical(at date: Date) -> NativeBatteryElectricalSnapshot {
        .init(generatedAt: date, voltageVolts: 10, amperageAmps: -2, powerWatts: -20,
              temperatureCelsius: 30, adapterPowerWatts: nil, adapterVoltageVolts: nil,
              adapterAmperageAmps: nil, adapterName: nil, designCapacityMAh: nil,
              currentCapacityMAh: nil, maximumCapacityMAh: nil, cycleCount: nil, condition: nil)
    }

    private static let battery = BatteryPowerSnapshot(chargePercent: 70, isCharging: false,
        powerSource: .batteryPower, timeToEmptyMinutes: nil, timeToFullChargeMinutes: nil)

    private static func memory(at date: Date) -> MemorySnapshot {
        .init(generatedAt: date, physicalBytes: 8_000, freeBytes: 1_000,
              inactiveBytes: 1_000, speculativeBytes: 0, fileBackedBytes: 1_000,
              purgeableBytes: 0, wiredBytes: 2_000, compressedBytes: 500, swapUsedBytes: 0,
              pressureFreePercentage: 50, pressureSummary: "", topProcesses: [])
    }
}

private final class SamplingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var time = Date(timeIntervalSinceReferenceDate: 10_000)
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var date: Date { lock.lock(); defer { lock.unlock() }; return time }
    func increment() { lock.lock(); defer { lock.unlock() }; calls += 1 }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; time.addTimeInterval(seconds) }
}

private final class BlockedPowerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var calls = 0
    private var active = 0
    private var maximum = 0
    private var timeout = false
    private var released = false
    private let onEarlyRead: @Sendable () -> Void
    init(onEarlyRead: @escaping @Sendable () -> Void) { self.onEarlyRead = onEarlyRead }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var maximumActive: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timeout }
    func release() { lock.lock(); released = true; lock.unlock(); gate.signal() }
    func sample() -> MenuBarPowerTelemetry {
        lock.lock()
        calls += 1
        active += 1
        maximum = max(maximum, active)
        let first = calls == 1
        let isEarlyRead = !first && !released
        lock.unlock()
        if isEarlyRead { onEarlyRead() }
        let didTimeOut = first && gate.wait(timeout: .now() + 2) == .timedOut
        lock.lock()
        active -= 1
        timeout = timeout || didTimeOut
        lock.unlock()
        return .unsupported(at: Date())
    }
}

private final class RecoveringFrameReader: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let missing: Int
    init(missing: Int) { self.missing = missing }
    var reads: Int { lock.withLock { calls } }
    func next() -> EnergyImpactService.MenuBarCounterFrame? {
        let call = lock.withLock { () -> Int in calls += 1; return calls }
        guard call > missing else { return nil }
        let tick = UInt64(call)
        let row = EnergyProcessRow(
            pid: 4_242, parentPID: 1, residentBytes: 1_024, elapsedSeconds: 100,
            cpuTimeSeconds: Double(tick), cpuPercent: 10,
            path: "/Applications/ProcessSnapshotFixture.app/Contents/MacOS/ProcessSnapshotFixture")
        let usage = EnergyResourceUsage(
            pid: 4_242, energyNanojoules: tick * 1_000_000_000, cpuTimeMach: tick * 1_000_000,
            processStartMach: 7, diskReadBytes: tick, diskWrittenBytes: tick)
        return .init(sampledAt: Date(timeIntervalSince1970: Double(call)), uptime: Double(call),
                     rows: [row], counters: [4_242: usage])
    }
}
