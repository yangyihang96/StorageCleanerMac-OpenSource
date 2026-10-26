import Foundation
import XCTest
@testable import StorageCleanerMac

final class MenuBarNetworkProcessCadenceTests: XCTestCase {
    /// D127 (iStat `startItemsForKey:`): nettop runs only while the network
    /// page is open, on every tick (3 s here, 60 s in Low Power); hidden or
    /// on another page it does not run. Was D75: a list prestored every 60 s
    /// hidden (10 calls in 10 min), 180 s hidden in Low Power (4), 10 s
    /// visible (60) and 60 s visible in Low Power (10), page open or not.
    @MainActor
    func testResidentNetworkProviderTenMinuteBudgetAcrossVisibilityAndPowerModes() async throws {
        for (visible, lowPower, pageOpen, expectedCalls) in [
            (false, false, false, 0), (false, true, false, 0), (false, false, true, 0),
            (true, false, false, 0), (true, false, true, 200), (true, true, true, 10)
        ] {
            let reads = StartupWorkCounter(), context = MenuBarSamplingContext()
            let state = makeState(reads)
            configure(context, reads: reads, visible: visible, lowPower: lowPower)
            state.attachSamplingContext(context)
            state.setPresentationVisible(visible)
            if pageOpen { state.registerConsumer(UUID(), demand: Self.networkPage, paused: false) }
            defer { state.setPaused(true) }
            // Drive the owner's actual three/thirty-second base clock, over
            // [0, 600). Include one initial sample; exclude the next endpoint.
            let tickSeconds = TimeInterval(MenuBarRefreshInterval.threeSeconds.sleepNanoseconds(
                panelVisible: visible, statusDisplayMode: .cpu, customFanControlActive: false,
                lowPowerMode: lowPower, statusVisible: false)) / 1_000_000_000
            XCTAssertEqual(tickSeconds, lowPower ? 30 : 3, "D127: one tick, panel open or closed (was 5 s)")
            for tick in 0..<Int(600 / tickSeconds) {
                if tick > 0 { reads.advance(tickSeconds) }
                state.refreshResidentSamples()
                try await drain(state)
            }
            XCTAssertEqual(reads.count("nettop"), expectedCalls,
                "D127 physical-provider count: visible=\(visible), lowPower=\(lowPower), page=\(pageOpen)")
            XCTAssertEqual(state.networkProcessSnapshot != nil, expectedCalls > 0)
        }
    }

    /// D127: hidden, nothing is attempted (was D75: one attempt, then a 60 s
    /// floor). With the page open, a failed read is retried on the next
    /// tick (3 s), not sooner.
    @MainActor
    func testHiddenNetworkFailureStillHonorsSixtySecondAttemptFloor() async throws {
        let reads = StartupWorkCounter(), context = MenuBarSamplingContext()
        let state = makeState(reads, network: { reads.read("nettop"); return nil })
        configure(context, reads: reads, visible: false)
        state.attachSamplingContext(context)
        state.setPresentationVisible(false)
        defer { state.setPaused(true) }
        for _ in 0..<3 {
            state.refreshResidentSamples()
            try await drain(state)
            reads.advance(60)
        }
        XCTAssertEqual(reads.count("nettop"), 0, "D127: nothing is read for a closed panel")
        XCTAssertEqual(state.networkProcessSamplingState, .idle)
        configure(context, reads: reads, visible: true)
        state.setPresentationVisible(true)
        state.registerConsumer(UUID(), demand: Self.networkPage, paused: false)
        try await drain(state)
        XCTAssertEqual(reads.count("nettop"), 1, "Opening the page reads at once")
        XCTAssertEqual(state.networkProcessSamplingState, .unavailable)
        for delta in [1.0, 1] {
            reads.advance(delta)
            state.refreshResidentSamples()
            try await drain(state)
            XCTAssertEqual(reads.count("nettop"), 1, "A failed read is not retried before the next tick")
        }
        reads.advance(1)
        state.refreshResidentSamples()
        try await drain(state)
        XCTAssertEqual(reads.count("nettop"), 2)
    }

    /// D127: nothing is stored while hidden (was D75: a list sampled hidden
    /// was shown on opening with its age, "59 秒前", until the visible
    /// refresh replaced it). Opening the page reads at once and says it is
    /// sampling; each tick reads again; closing the page drops its list,
    /// and a nettop still running when it reopens hands over to a new read.
    @MainActor
    func testOpeningNetworkShowsStoredListAndSourceTimeBeforeVisibleRefreshCompletes() async throws {
        let reads = StartupWorkCounter(), context = MenuBarSamplingContext()
        let gate = DispatchSemaphore(value: 0)
        let state = makeState(reads, network: {
            reads.read("nettop")
            let sampledAt = reads.now
            if reads.count("nettop") == 3 {
                reads.read("entered")
                if gate.wait(timeout: .now() + 3) == .timedOut { reads.read("gate-timeout") }
            }
            return Self.snapshot(at: sampledAt)
        })
        configure(context, reads: reads, visible: false)
        state.attachSamplingContext(context)
        state.setPresentationVisible(false)
        defer { gate.signal(); state.setPaused(true) }
        state.refreshResidentSamples()
        try await drain(state)
        XCTAssertNil(state.networkProcessSnapshot, "D127: nothing is stored while hidden")
        reads.advance(59)
        configure(context, reads: reads, visible: true)
        state.setPresentationVisible(true)
        let consumer = UUID()
        state.registerConsumer(consumer, demand: Self.networkPage, paused: false)
        XCTAssertTrue(state.isNetworkProcessRefreshActive, "Opening the page starts a read at once")
        XCTAssertEqual(state.networkProcessSamplingState, .sampling)
        try await drain(state)
        XCTAssertEqual(reads.count("nettop"), 1)
        XCTAssertEqual(state.networkProcessSnapshot?.generatedAt, reads.now)
        reads.advance(3)
        state.refreshResidentSamples()
        try await drain(state)
        XCTAssertEqual(reads.count("nettop"), 2, "Each tick reads again")
        // The third read is held while the page closes and reopens.
        reads.advance(3)
        state.refreshResidentSamples()
        try await StartupTestWait.until { reads.count("entered") == 1 }
        state.unregisterConsumer(consumer)
        XCTAssertNil(state.networkProcessSnapshot, "Closing the page drops its list")
        XCTAssertEqual(state.networkProcessSamplingState, .idle)
        state.registerConsumer(consumer, demand: Self.networkPage, paused: false)
        XCTAssertEqual(reads.count("nettop"), 3, "The running nettop keeps the single flight")
        gate.signal()
        try await StartupTestWait.until { reads.count("nettop") == 4 }
        try await drain(state)
        XCTAssertEqual(state.networkProcessSnapshot?.generatedAt, reads.now)
        XCTAssertEqual(reads.count("gate-timeout"), 0)
        state.unregisterConsumer(consumer)
    }

    /// D127: opening the page always reads at once (nothing was stored while
    /// hidden), then keeps the open page's floor: the tick (3 s, within the
    /// 0.1 s tick tolerance) normally, 60 s in Low Power. Was D75: opening
    /// reused a list sampled hidden unless it was older than 10 s (60 s).
    @MainActor
    func testOpeningUsesCurrentVisibleAttemptFloorIncludingThirtySecondHiddenSample() async throws {
        for (lowPower, age, expectedCalls) in [(false, 3.0, 2), (false, 2.95, 2), (false, 2.0, 1),
                                              (true, 30.0, 1), (true, 60.0, 2)] {
            let reads = StartupWorkCounter(), context = MenuBarSamplingContext()
            let state = makeState(reads)
            configure(context, reads: reads, visible: false, lowPower: lowPower)
            state.attachSamplingContext(context)
            state.setPresentationVisible(false)
            state.refreshResidentSamples()
            try await drain(state)
            XCTAssertNil(state.networkProcessSnapshot)
            reads.advance(30)
            configure(context, reads: reads, visible: true, lowPower: lowPower)
            state.setPresentationVisible(true)
            state.registerConsumer(UUID(), demand: Self.networkPage, paused: false)
            try await drain(state)
            XCTAssertEqual(state.networkProcessSnapshot?.generatedAt, reads.now, "Opening reads at once")
            reads.advance(age)
            state.refreshResidentSamples()
            try await drain(state)
            XCTAssertEqual(reads.count("nettop"), expectedCalls,
                "The open page reads on the tick: normal 3 s / low-power 60 s (age \(age))")
            state.setPaused(true)
        }
    }

    /// D127: with the page open, pause and sleep keep the list shown and start
    /// no nettop; resuming or waking starts the page again and reads at once.
    /// Calls follow production: the view pauses the state (also on
    /// `willSleep`), then the controller reports the plan's visibility.
    /// Was D75: the same with a list prestored while hidden.
    @MainActor
    func testSuspensionAndPauseKeepStoredNetworkWithoutStartingProviders() async throws {
        let reads = StartupWorkCounter(), context = MenuBarSamplingContext()
        let state = makeState(reads)
        configure(context, reads: reads, visible: true)
        state.attachSamplingContext(context)
        state.setPresentationVisible(true)
        defer { state.setPaused(true) }
        state.registerConsumer(UUID(), demand: Self.networkPage, paused: false)
        try await drain(state)
        var stored = try XCTUnwrap(state.networkProcessSnapshot)
        for (suspended, expectedCalls) in [(false, 2), (true, 3)] {
            reads.advance(600)
            state.setPaused(true)
            configure(context, reads: reads, visible: true, suspended: suspended, paused: !suspended)
            state.setPresentationVisible(context.plan?.panelVisible == true)
            state.refreshResidentSamples()
            try await drain(state)
            XCTAssertEqual(reads.count("nettop"), expectedCalls - 1)
            XCTAssertEqual(state.networkProcessSnapshot, stored, "suspended=\(suspended) keeps what is shown")
            state.setPaused(false)
            configure(context, reads: reads, visible: true)
            state.setPresentationVisible(context.plan?.panelVisible == true)
            try await drain(state)
            XCTAssertEqual(reads.count("nettop"), expectedCalls, "Resuming reads at once")
            stored = try XCTUnwrap(state.networkProcessSnapshot)
            XCTAssertEqual(stored.generatedAt, reads.now)
        }
    }

    /// D127: the slowest offered tick is 3 s (the 5 s option is gone).
    @MainActor
    private func configure(_ context: MenuBarSamplingContext, reads: StartupWorkCounter,
                           visible: Bool, lowPower: Bool = false, suspended: Bool = false,
                           paused: Bool = false) {
        context.configure(statusMode: .cpu, statusVisible: false, panelVisible: visible,
            customFanControlActive: false, paused: paused, now: reads.now,
            lowPower: lowPower, suspended: suspended, selectedInterval: 3)
    }

    private static var networkPage: MenuBarAuxiliaryMonitorDemand {
        .init(needsProcessorTelemetry: false, needsDiskIOSampling: false, needsNetworkInterface: false,
              needsPublicNetworkAddress: false, needsNetworkProcesses: true, needsPowerTelemetry: false,
              needsStorageCapacity: false, needsBattery: false)
    }

    @MainActor
    private func makeState(_ reads: StartupWorkCounter,
                           network: (@Sendable () -> NativeNetworkProcessSnapshot?)? = nil) -> MenuBarAuxiliaryMonitorState {
        MenuBarAuxiliaryMonitorState(collectionClock: { reads.now },
            batteryAvailabilityProvider: { .absent }, diskCounterProvider: { nil },
            storageVolumeProvider: { .empty }, batterySnapshotProvider: { (nil, nil) },
            publicNetworkConsentProvider: { false },
            networkProcessProvider: network ?? { reads.read("nettop"); return Self.snapshot(at: reads.now) },
            processorTelemetryProvider: { nil }, powerTelemetryProvider: { .unsupported(at: reads.now) },
            powerTelemetryPause: {}, powerHistoryURL: nil, chargeLimitReader: { nil })
    }

    @MainActor
    private func drain(_ state: MenuBarAuxiliaryMonitorState) async throws {
        try await StartupTestWait.until {
            !state.isNetworkProcessRefreshActive && !state.isLocalDataRefreshActive
                && !state.isProcessorRefreshActive && !state.isPowerTelemetryRefreshActive
        }
    }

    private static func snapshot(at date: Date) -> NativeNetworkProcessSnapshot {
        .init(generatedAt: date, processes: [.init(processIdentifier: 4_242, name: "Stored App",
            iconPath: "", downloadBytesPerSecond: 100, uploadBytesPerSecond: 10)])
    }
}
