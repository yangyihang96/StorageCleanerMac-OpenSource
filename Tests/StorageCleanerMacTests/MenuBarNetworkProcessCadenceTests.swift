import Foundation
import XCTest
@testable import StorageCleanerMac

final class MenuBarNetworkProcessCadenceTests: XCTestCase {
    @MainActor
    func testResidentNetworkProviderTenMinuteBudgetAcrossVisibilityAndPowerModes() async throws {
        for (visible, lowPower, expectedCalls) in [(false, false, 10), (false, true, 4),
                                                  (true, false, 60), (true, true, 10)] {
            let reads = StartupWorkCounter(), context = MenuBarSamplingContext()
            let state = makeState(reads)
            configure(context, reads: reads, visible: visible, lowPower: lowPower)
            state.attachSamplingContext(context)
            state.setPresentationVisible(visible)
            defer { state.setPaused(true) }
            // Drive the owner's actual five/thirty-second base clock, over
            // [0, 600). Include one initial sample; exclude the next endpoint.
            let tickSeconds = TimeInterval(MenuBarRefreshInterval.fiveSeconds.sleepNanoseconds(
                panelVisible: visible, statusDisplayMode: .cpu, customFanControlActive: false,
                lowPowerMode: lowPower, statusVisible: false)) / 1_000_000_000
            XCTAssertEqual(tickSeconds, lowPower ? 30 : 5, "D75 must not alter the other sources' base clock")
            for tick in 0..<Int(600 / tickSeconds) {
                if tick > 0 { reads.advance(tickSeconds) }
                state.refreshResidentSamples()
                try await drain(state)
            }
            XCTAssertEqual(reads.count("nettop"), expectedCalls,
                "D75 physical-provider count: visible=\(visible), lowPower=\(lowPower)")
            XCTAssertNotNil(state.networkProcessSnapshot)
        }
    }

    @MainActor
    func testHiddenNetworkFailureStillHonorsSixtySecondAttemptFloor() async throws {
        let reads = StartupWorkCounter(), context = MenuBarSamplingContext()
        let state = makeState(reads, network: { reads.read("nettop"); return nil })
        configure(context, reads: reads, visible: false)
        state.attachSamplingContext(context)
        state.setPresentationVisible(false)
        defer { state.setPaused(true) }
        state.refreshResidentSamples()
        try await drain(state)
        XCTAssertEqual(reads.count("nettop"), 1)
        XCTAssertEqual(state.networkProcessSamplingState, .unavailable)
        for delta in [15.0, 15, 29] {
            reads.advance(delta)
            state.refreshResidentSamples()
            try await drain(state)
            XCTAssertEqual(reads.count("nettop"), 1, "Failed reads must not retry at the PS/memory floor")
        }
        reads.advance(1)
        state.refreshResidentSamples()
        try await drain(state)
        XCTAssertEqual(reads.count("nettop"), 2)
    }

    @MainActor
    func testOpeningNetworkShowsStoredListAndSourceTimeBeforeVisibleRefreshCompletes() async throws {
        let language = MiniWindowLogicLanguageScope(.zhHans)
        defer { language.restore() }
        let reads = StartupWorkCounter(), context = MenuBarSamplingContext()
        let gate = DispatchSemaphore(value: 0)
        let state = makeState(reads, network: {
            reads.read("nettop")
            let sampledAt = reads.now
            if reads.count("nettop") == 2 {
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
        let stored = try XCTUnwrap(state.networkProcessSnapshot)
        XCTAssertEqual(stored.processes.first?.name, "Stored App")
        reads.advance(59)
        configure(context, reads: reads, visible: true)
        state.setPresentationVisible(true)
        let consumer = UUID()
        state.registerConsumer(consumer, demand: .init(needsProcessorTelemetry: false,
            needsDiskIOSampling: false, needsNetworkInterface: false, needsPublicNetworkAddress: false,
            needsNetworkProcesses: true, needsPowerTelemetry: false, needsStorageCapacity: false,
            needsBattery: false), paused: false)
        XCTAssertEqual(state.networkProcessSnapshot, stored, "Opening keeps the list before any worker starts")
        XCTAssertEqual(PanelTimestampFormat.age(stored.generatedAt, now: reads.now), "59 秒前")
        XCTAssertEqual(reads.count("nettop"), 1)
        state.refreshResidentSamples()
        try await StartupTestWait.until { reads.count("entered") == 1 }
        XCTAssertTrue(state.isNetworkProcessRefreshActive)
        XCTAssertEqual(state.networkProcessSnapshot, stored)
        XCTAssertEqual(state.networkProcessSamplingState, .available, "Stored data must not become a blank sampling state")
        gate.signal()
        try await drain(state)
        XCTAssertEqual(state.networkProcessSnapshot?.generatedAt, reads.now)
        reads.advance(9)
        state.refreshResidentSamples()
        try await drain(state)
        XCTAssertEqual(reads.count("nettop"), 2)
        reads.advance(1)
        state.refreshResidentSamples()
        try await drain(state)
        XCTAssertEqual(reads.count("nettop"), 3, "Visible network resumes its ten-second cadence")
        XCTAssertEqual(reads.count("gate-timeout"), 0)
        state.unregisterConsumer(consumer)
    }

    @MainActor
    func testOpeningUsesCurrentVisibleAttemptFloorIncludingThirtySecondHiddenSample() async throws {
        for (lowPower, age, expectedCalls) in [(false, 30.0, 2), (false, 9.0, 1),
                                              (true, 30.0, 1), (true, 60.0, 2)] {
            let reads = StartupWorkCounter(), context = MenuBarSamplingContext()
            let state = makeState(reads)
            configure(context, reads: reads, visible: false, lowPower: lowPower)
            state.attachSamplingContext(context)
            state.setPresentationVisible(false)
            state.refreshResidentSamples()
            try await drain(state)
            let stored = try XCTUnwrap(state.networkProcessSnapshot)
            reads.advance(age)
            configure(context, reads: reads, visible: true, lowPower: lowPower)
            state.setPresentationVisible(true)
            XCTAssertEqual(state.networkProcessSnapshot, stored)
            state.refreshResidentSamples()
            try await drain(state)
            XCTAssertEqual(reads.count("nettop"), expectedCalls,
                "Opening uses current visible freshness, normal 10 s / low-power 60 s, without an unconditional read")
            state.setPaused(true)
        }
    }

    @MainActor
    func testSuspensionAndPauseKeepStoredNetworkWithoutStartingProviders() async throws {
        let reads = StartupWorkCounter(), context = MenuBarSamplingContext()
        let state = makeState(reads)
        configure(context, reads: reads, visible: false)
        state.attachSamplingContext(context)
        state.setPresentationVisible(false)
        defer { state.setPaused(true) }
        state.refreshResidentSamples()
        try await drain(state)
        let stored = state.networkProcessSnapshot
        reads.advance(600)
        for suspended in [true, false] {
            configure(context, reads: reads, visible: false, suspended: suspended, paused: !suspended)
            state.refreshResidentSamples()
            try await drain(state)
            XCTAssertEqual(reads.count("nettop"), 1)
            XCTAssertEqual(state.networkProcessSnapshot, stored)
        }
        configure(context, reads: reads, visible: false)
        state.refreshResidentSamples()
        try await drain(state)
        XCTAssertEqual(reads.count("nettop"), 2)
    }

    @MainActor
    private func configure(_ context: MenuBarSamplingContext, reads: StartupWorkCounter,
                           visible: Bool, lowPower: Bool = false, suspended: Bool = false,
                           paused: Bool = false) {
        context.configure(statusMode: .cpu, statusVisible: false, panelVisible: visible,
            customFanControlActive: false, paused: paused, now: reads.now,
            lowPower: lowPower, suspended: suspended, selectedInterval: 5)
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
