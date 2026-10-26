import AppKit
import Combine
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// aa1abaf9: a cached panel re-subscribes to the current plan after a store
/// publication; hidden-plan delivery wrote the same @Published Bool again.
@MainActor
final class MenuBarPublishLoopTests: XCTestCase {
    func testRepeatedResidentConsumerSectionsDoNotPublishAfterFirstChange() throws {
        let store = try makeStore()
        store.attachMenuBarResidentSampling(makeContext())
        let id = UUID()
        let sections: [PanelSection?] = [nil, .processor, .disk, .power, .memory, .overview, nil]
        for section in sections {
            store.updateMenuBarProcessConsumer(id, section: section)
            let count = Counter()
            let subscription = store.objectWillChange.sink { count.value += 1 }
            for _ in 0..<100 { store.updateMenuBarProcessConsumer(id, section: section) }
            XCTAssertEqual(count.value, 0, "Repeated \(String(describing: section)) must be a no-op")
            withExtendedLifetime(subscription) {}
        }
    }

    func testRepeatedDirectResidentDemandDoesNotPublish() throws {
        let store = try makeStore()
        store.attachMenuBarResidentSampling(makeContext())
        for section in [PanelSection.overview, .processor, .disk, .power, .memory] {
            store.setMenuBarProcessDemand(section)
            let count = Counter()
            let subscription = store.objectWillChange.sink { count.value += 1 }
            for _ in 0..<100 { store.setMenuBarProcessDemand(section) }
            XCTAssertEqual(count.value, 0)
            withExtendedLifetime(subscription) {}
        }
    }

    func testChangedResidentSectionWithSamePendingStateDoesNotPublish() throws {
        let store = try makeStore()
        store.attachMenuBarResidentSampling(makeContext())
        store.setMenuBarProcessDemand(.processor)
        XCTAssertTrue(store.isMenuBarProcessSamplePending)
        let count = Counter()
        let subscription = store.objectWillChange.sink { count.value += 1 }
        store.setMenuBarProcessDemand(.disk)
        store.setMenuBarProcessDemand(.power)
        XCTAssertTrue(store.isMenuBarProcessSamplePending)
        XCTAssertEqual(count.value, 0, "A different page does not change the pending Bool")
        store.setMenuBarProcessDemand(.memory)
        XCTAssertFalse(store.isMenuBarProcessSamplePending)
        XCTAssertEqual(count.value, 1, "A real state transition still publishes")
        withExtendedLifetime(subscription) {}
    }

    func testReplayedOlderConsumerDoesNotStealLatestPagePriority() throws {
        let store = try makeStore()
        store.attachMenuBarResidentSampling(makeContext())
        let older = UUID(), newer = UUID()
        store.updateMenuBarProcessConsumer(older, section: .processor)
        store.updateMenuBarProcessConsumer(newer, section: .disk)
        for _ in 0..<100 { store.updateMenuBarProcessConsumer(older, section: .processor) }
        XCTAssertEqual(store.menuBarProcessDemand, .disk)
        store.updateMenuBarProcessConsumer(newer, section: nil)
        XCTAssertEqual(store.menuBarProcessDemand, .processor)
        store.updateMenuBarProcessConsumer(older, section: nil)
        XCTAssertEqual(store.menuBarProcessDemand, .overview)
    }

    func testSameEffectiveDemandAcrossConsumersDoesNotPublish() throws {
        let store = try makeStore()
        store.attachMenuBarResidentSampling(makeContext())
        let first = UUID(), second = UUID()
        store.updateMenuBarProcessConsumer(first, section: .processor)
        let count = Counter()
        let subscription = store.objectWillChange.sink { count.value += 1 }
        store.updateMenuBarProcessConsumer(second, section: .processor)
        store.updateMenuBarProcessConsumer(second, section: nil)
        store.updateMenuBarProcessConsumer(UUID(), section: nil)
        XCTAssertEqual(store.menuBarProcessDemand, .processor)
        XCTAssertEqual(count.value, 0)
        withExtendedLifetime(subscription) {}
    }

    func testSameDeclaredConsumerRestoresEffectiveDemandAfterPause() throws {
        let store = try makeStore()
        store.attachMenuBarResidentSampling(makeContext(suspended: true))
        let id = UUID()
        store.updateMenuBarProcessConsumer(id, section: .processor)
        store.toggleMenuBarRefreshPaused()
        store.updateMenuBarProcessConsumer(id, section: .processor)
        XCTAssertEqual(store.menuBarProcessDemand, .overview)
        store.toggleMenuBarRefreshPaused()
        store.updateMenuBarProcessConsumer(id, section: .processor)
        XCTAssertEqual(store.menuBarProcessDemand, .processor,
            "Unchanged declaration still resolves a real pause/resume transition")
        XCTAssertTrue(store.isMenuBarProcessSamplePending)
        let count = Counter()
        let subscription = store.objectWillChange.sink { count.value += 1 }
        for _ in 0..<100 { store.updateMenuBarProcessConsumer(id, section: .processor) }
        XCTAssertEqual(count.value, 0)
        withExtendedLifetime(subscription) {}
    }

    func testRepeatedVisibleConsumerDoesNotRestartSampler() async throws {
        let reader = FrameReader()
        let store = try ScanStore.makeForTests(for: self,
            menuBarProcessSampler: MenuBarProcessSampler(read: { await reader.next() }))
        let first = UUID(), second = UUID()
        store.updateMenuBarProcessConsumer(first, section: .processor)
        defer { store.updateMenuBarProcessConsumer(first, section: nil) }
        let count = Counter()
        let subscription = store.objectWillChange.sink { count.value += 1 }
        for _ in 0..<100 {
            store.updateMenuBarProcessConsumer(first, section: .processor)
            store.updateMenuBarProcessConsumer(second, section: .processor)
            store.updateMenuBarProcessConsumer(second, section: nil)
        }
        XCTAssertEqual(count.value, 0)
        subscription.cancel()
        let deadline = ContinuousClock.now + .seconds(3)
        // D171: the first read is listed at once; this waits for the first
        // delta (was `store.menuBarPreparedProcesses == nil`).
        while store.menuBarPreparedProcesses?.isFirstRead != false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNotNil(store.menuBarPreparedProcesses)
        XCTAssertEqual(store.menuBarPreparedProcesses?.isFirstRead, false)
        let reads = await reader.reads
        XCTAssertEqual(reads, 2, "One baseline and one delta; no restart for repeated demand")
    }

    func testUnchangedRefreshIntervalDoesNotPublish() throws {
        let store = try makeStore()
        let count = Counter()
        let subscription = store.objectWillChange.sink { count.value += 1 }
        for _ in 0..<100 { store.setMenuBarRefreshInterval(store.menuBarRefreshInterval) }
        XCTAssertEqual(count.value, 0)
        withExtendedLifetime(subscription) {}
    }

    func testCurrentPlanReplaysOnEveryNewSubscriptionButDoesNotPublishStore() async throws {
        for visible in [false, true] {
            let store = try makeStore()
            let context = makeContext(visible: visible)
            store.attachMenuBarResidentSampling(context)
            await nextTurn() // coalesced planSubject delivery
            let id = UUID()
            store.updateMenuBarProcessConsumer(id, section: visible ? .processor : nil)
            let publications = Counter(), deliveries = Counter()
            let subscription = store.objectWillChange.sink { publications.value += 1 }
            for _ in 0..<100 {
                let replay = context.planChanges.removeDuplicates().sink { plan in
                    guard let plan else { return }
                    deliveries.value += 1
                    store.updateMenuBarProcessConsumer(id, section: plan.panelVisible ? .processor : nil)
                }
                replay.cancel()
            }
            XCTAssertEqual(deliveries.value, 100, "removeDuplicates is scoped to each subscription")
            XCTAssertEqual(publications.value, 0)
            withExtendedLifetime(subscription) {}
        }
    }

    func testHostedRestoredCachedPanelHasBoundedBodiesAndNoDemandPublications() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        // Synthetic trigger, never read/copy the real beta preference values.
        defaults.set(true, forKey: MenuBarPanelSettingsState.restoreOnLaunchDefaultsKey)
        defaults.set(PanelSection.processor.rawValue, forKey: PanelSection.defaultsKey)
        let settings = MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults)
        XCTAssertTrue(settings.restoresOnLaunch)
        XCTAssertEqual(settings.selectedSection, .processor)
        let store = try makeStore()
        // Suspended sampling prevents hardware reads. The hidden-plan replay
        // responsible for the loop is identical during suspension and idle.
        let context = makeContext(suspended: true)
        store.attachMenuBarResidentSampling(context)
        await nextTurn()
        _ = NSApplication.shared
        let recorder = HostRecorder()
        let host = NSHostingView(rootView: AnyView(HostedCoordinator(
            store: store, settings: settings, context: context, recorder: recorder, revision: 0)))
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        let subscription = store.objectWillChange.sink { [weak host] in
            recorder.publications += 1
            // A counterexample must fail, not wedge XCTest in flushObservers.
            // This fuse is above the assertion and never suppresses a failure.
            if recorder.publications == 64 {
                recorder.fused = true
                host?.rootView = AnyView(Color.clear)
            }
        }
        defer {
            subscription.cancel()
            host.rootView = AnyView(Color.clear)
            window.contentView = nil
            window.close()
        }
        for revision in 1...12 {
            host.layoutSubtreeIfNeeded()
            await nextTurn()
            if !recorder.fused {
                host.rootView = AnyView(HostedCoordinator(store: store, settings: settings,
                    context: context, recorder: recorder, revision: revision))
            }
        }
        host.layoutSubtreeIfNeeded()
        await nextTurn()
        XCTAssertGreaterThan(recorder.bodies, 0, "The real coordinator must have been mounted")
        XCTAssertGreaterThan(store.menuBarAuxiliaryMonitorState.activeConsumerCount, 0, "onAppear ran")
        XCTAssertFalse(recorder.fused, "Old code hit the publication fuse")
        XCTAssertEqual(recorder.publications, 0)
        XCTAssertLessThanOrEqual(recorder.bodies, 16, "12 deliberate redraws plus initial mounting")
    }

    func testFreshQAPreferencesDoNotRequestRestoredPanel() {
        let defaults = TestPreferenceDomain.make(for: self)
        let settings = MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults)
        XCTAssertFalse(settings.restoresOnLaunch)
        XCTAssertEqual(settings.selectedSection, .overview)
        // MenuBarStatusController.install only creates the panel session
        // through the restore/explicit-open branch, not at resident attachment.
    }

    func testRepeatedAuxiliaryLifecycleDemandDoesNotPublishOrStartProbes() {
        let calls = LockedCounter()
        let state = MenuBarAuxiliaryMonitorState(
            diskCounterProvider: { calls.increment(); return nil },
            batterySnapshotProvider: { calls.increment(); return (nil, nil) },
            networkProcessProvider: { calls.increment(); return nil },
            powerTelemetryPause: { calls.increment() }, powerHistoryURL: nil)
        state.attachSamplingContext(makeContext(suspended: true))
        let demand = MenuBarAuxiliaryMonitorDemand(needsProcessorTelemetry: false,
            needsDiskIOSampling: false, needsNetworkInterface: false,
            needsPublicNetworkAddress: false, needsNetworkProcesses: false,
            needsStorageCapacity: false, needsBattery: false)
        let id = UUID()
        state.registerConsumer(id, demand: demand, paused: true)
        let count = Counter()
        let subscription = state.objectWillChange.sink { count.value += 1 }
        for _ in 0..<100 {
            state.registerConsumer(id, demand: demand, paused: true)
            state.updateConsumer(id, demand: demand)
            state.setPaused(true)
        }
        state.unregisterConsumer(id)
        for _ in 0..<100 { state.unregisterConsumer(id) }
        XCTAssertEqual(state.activeConsumerCount, 0)
        XCTAssertEqual(count.value, 0)
        XCTAssertEqual(calls.value, 0)
        withExtendedLifetime(subscription) {}
    }

    private func makeStore() throws -> ScanStore {
        try ScanStore.makeForTests(for: self, menuBarProcessSampler: MenuBarProcessSampler(read: { nil }))
    }

    private func makeContext(visible: Bool = false, suspended: Bool = false) -> MenuBarSamplingContext {
        let context = MenuBarSamplingContext()
        context.configure(statusMode: .cpu, statusVisible: true, panelVisible: visible,
            customFanControlActive: false, paused: false, suspended: suspended)
        return context
    }

    private func nextTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private final class Counter { var value = 0 }
    private final class HostRecorder { var bodies = 0; var publications = 0; var fused = false }
    private struct HostedCoordinator: View {
        @ObservedObject var store: ScanStore
        let settings: MenuBarPanelSettingsState
        let context: MenuBarSamplingContext
        let recorder: HostRecorder
        let revision: Int
        var body: some View {
            recorder.bodies += 1
            return MenuBarAdvancedSamplingCoordinator(store: store,
                monitorState: store.menuBarMonitorState,
                auxiliaryState: store.menuBarAuxiliaryMonitorState, panelSettingsState: settings,
                // D167: no `tertiaryVisible: true`; the module page starts its lists.
                presentation: .geek, selectedSection: settings.selectedSection,
                samplingContext: context)
                .accessibilityIdentifier("publish-loop-\(revision)")
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    private actor FrameReader {
        private(set) var reads = 0
        func next() -> EnergyImpactService.MenuBarCounterFrame {
            reads += 1
            let time = Double(reads)
            let rows = EnergyImpactService.processRows(fromPSOutput:
                "101 1 1024 user 00:01 10 /Applications/Test.app/Contents/MacOS/Test")
            return .init(sampledAt: Date(), uptime: time, rows: rows,
                counters: [101: .init(pid: 101, energyNanojoules: UInt64(time * 1_000_000_000),
                    cpuTimeMach: UInt64(time * 1_000_000), processStartMach: 1,
                    diskReadBytes: UInt64(time * 100), diskWrittenBytes: UInt64(time * 50))])
        }
    }
}
