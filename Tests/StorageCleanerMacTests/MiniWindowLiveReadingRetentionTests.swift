import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// BOARD N16-2 and N16-3 (live 2026-10-07, iStat comparison):
/// - a secondary page's process list was empty for 1–2 s after it opened
///   (CPU: "未测量 · 占用", network: "正在采样…") while iStat shows its list at
///   once;
/// - the overview network card briefly showed "--" after another page was
///   opened.
/// The last process measurement is kept while hidden and shown at once with
/// its sample time; the first new measurement follows sooner; the network
/// rates come from the network's own history and keep the last reading
/// through a sample without rates.
@MainActor
final class MiniWindowLiveReadingRetentionTests: XCTestCase {
    // MARK: - N16-2: process snapshots

    /// Counter frames for one application process whose counters grow.
    private final class FrameSource: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0

        func next() -> EnergyImpactService.MenuBarCounterFrame {
            let read = lock.withLock { () -> UInt64 in
                reads += 1
                return UInt64(reads)
            }
            let row = EnergyProcessRow(
                pid: 4_242, parentPID: 1, residentBytes: 1_024, elapsedSeconds: 100,
                cpuTimeSeconds: Double(read), cpuPercent: 10,
                path: "/Applications/ProcessSnapshotFixture.app/Contents/MacOS/ProcessSnapshotFixture")
            let usage = EnergyResourceUsage(
                pid: 4_242, energyNanojoules: read * 1_000_000_000, cpuTimeMach: read * 1_000_000,
                processStartMach: 7, diskReadBytes: read, diskWrittenBytes: read)
            return .init(sampledAt: Date(), uptime: ProcessInfo.processInfo.systemUptime,
                         rows: [row], counters: [4_242: usage])
        }
    }

    private func makeStore() throws -> ScanStore {
        let source = FrameSource()
        return try ScanStore.makeForTests(for: self, menuBarProcessSampler: MenuBarProcessSampler(read: { source.next() }))
    }

    func testTheFirstMeasurementFollowsSoonAfterAPageOpens() async throws {
        XCTAssertLessThanOrEqual(MenuBarPerformancePolicy.firstProcessSampleInterval, 0.5)
        let store = try makeStore()
        defer { store.setMenuBarProcessDemand(.overview) }
        XCTAssertNil(store.menuBarPreparedProcesses)

        let opened = ContinuousClock.now
        store.setMenuBarProcessDemand(.processor)
        XCTAssertTrue(store.isMenuBarProcessSamplePending, "nothing to show yet: the page says it is sampling")
        try await waitUntil(seconds: 1.5) { store.menuBarPreparedProcesses != nil }
        XCTAssertLessThan(opened.duration(to: .now), .milliseconds(1_500),
                          "the first measurement does not wait the regular 2 s interval")
        XCTAssertFalse(store.isMenuBarProcessSamplePending)
    }

    func testTheLastMeasurementIsShownAtOnceWhenThePageOpensAgain() async throws {
        let store = try makeStore()
        defer { store.setMenuBarProcessDemand(.overview) }
        store.setMenuBarProcessDemand(.processor)
        try await waitUntil(seconds: 2.5) { store.menuBarPreparedProcesses != nil }
        let first = try XCTUnwrap(store.menuBarPreparedProcesses?.snapshot.generatedAt)

        store.setMenuBarProcessDemand(.overview)
        XCTAssertEqual(store.menuBarPreparedProcesses?.snapshot.generatedAt, first, "kept while hidden")

        store.setMenuBarProcessDemand(.processor)
        XCTAssertEqual(store.menuBarPreparedProcesses?.snapshot.generatedAt, first, "shown at once when the page opens")
        XCTAssertFalse(store.isMenuBarProcessSamplePending, "a kept measurement is shown with its time, not as sampling")
        try await waitUntil(seconds: 1.5) {
            (store.menuBarPreparedProcesses?.snapshot.generatedAt ?? .distantPast) > first
        }
    }

    func testTheProcessHeadersSayWhatTheyShow() throws {
        let chinese = MiniWindowLogicLanguageScope(.zhHans)
        defer { chinese.restore() }
        XCTAssertEqual(GeekOnDemandSnapshotFreshness.statusText(generatedAt: nil, isSampling: true), "正在采样…")
        XCTAssertEqual(GeekOnDemandSnapshotFreshness.statusText(generatedAt: nil, isSampling: false), "未测量")
        let now = Date()
        XCTAssertTrue(GeekOnDemandSnapshotFreshness.statusText(generatedAt: now, now: now, isSampling: true)
            .hasPrefix("更新 "), "a kept measurement shows its time")

        let panel = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift")
        let status = try MiniWindowLogicFixtures.section(
            panel, from: "var geekOnDemandSnapshotStatusText: String {", to: "var geekDiskReadRateText")
        XCTAssertTrue(status.contains("isSampling: store.isMenuBarProcessSamplePending"))
        let processor = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekProcessorView.swift")
        XCTAssertTrue(processor.contains("isLoading: store.isLoadingEnergyImpact || store.isMenuBarProcessSamplePending"))
        // The network list names its sample time as the CPU list does.
        let network = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift")
        XCTAssertTrue(network.contains("GeekNetworkProcessHeader(status: geekNetworkProcessSampleTimeText)"))
        let sampleTime = try MiniWindowLogicFixtures.section(
            network, from: "private var geekNetworkProcessSampleTimeText: String? {", to: "private var geekNetworkProcessStatusText")
        XCTAssertTrue(sampleTime.contains("GeekOnDemandSnapshotFreshness.statusText(generatedAt: snapshot.generatedAt)"))
    }

    // MARK: - Review P2-8: a reader that gives nothing

    /// Nothing until opened, then `FrameSource`'s frames.
    private final class GatedFrameSource: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private let frames = FrameSource()

        func open() { lock.withLock { isOpen = true } }

        func next() -> EnergyImpactService.MenuBarCounterFrame? {
            guard lock.withLock({ isOpen }) else { return nil }
            return frames.next()
        }
    }

    /// r2-live-fixes-2 review P2-8: "正在采样…" cleared only when a
    /// measurement arrived, so a reader that keeps giving nothing showed it
    /// for good. After `MenuBarPerformancePolicy.processSampleTimeout` (5 s)
    /// the page says "未测量" and why; sampling continues, and a later
    /// measurement is shown as usual.
    func testAReaderThatGivesNothingEndsInNotMeasuredWithAReason() async throws {
        XCTAssertEqual(MenuBarPerformancePolicy.processSampleTimeout, 5)
        let source = GatedFrameSource()
        let store = try ScanStore.makeForTests(for: self,
            menuBarProcessSampler: MenuBarProcessSampler(read: { source.next() }),
            menuBarProcessSampleTimeout: 0.3
        )
        defer { store.setMenuBarProcessDemand(.overview) }
        store.setMenuBarProcessDemand(.processor)
        XCTAssertTrue(store.isMenuBarProcessSamplePending, "正在采样…")
        try await waitUntil(seconds: 3) { !store.isMenuBarProcessSamplePending }
        XCTAssertTrue(store.isMenuBarProcessSampleUnavailable, "nothing was measured in time")
        XCTAssertNil(store.menuBarPreparedProcesses)

        let chinese = MiniWindowLogicLanguageScope(.zhHans)
        XCTAssertEqual(GeekOnDemandSnapshotFreshness.statusText(
            generatedAt: nil, isSampling: store.isMenuBarProcessSamplePending), "未测量")
        XCTAssertEqual(GeekOnDemandSnapshotFreshness.nothingMeasuredReason(true),
                       "：5 秒内没有取得进程数据，仍在继续采样")
        XCTAssertEqual(GeekOnDemandSnapshotFreshness.nothingMeasuredReason(false), "")
        chinese.restore()

        source.open()
        try await waitUntil(seconds: 10) { store.menuBarPreparedProcesses != nil }
        XCTAssertFalse(store.isMenuBarProcessSampleUnavailable, "a later measurement is shown as usual")
    }

    /// The processor and disk lists say it in their header's help and in
    /// place of the empty list's "—".
    func testTheProcessListsSayWhyNothingWasMeasured() throws {
        for path in ["Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekProcessorView.swift",
                     "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDiskView.swift"] {
            let source = try MiniWindowLogicFixtures.source(path)
            XCTAssertTrue(source.contains(
                "按需快照 · \\(geekOnDemandSnapshotStatusText)\\(GeekOnDemandSnapshotFreshness.nothingMeasuredReason("),
                path)
            XCTAssertTrue(source.contains("GeekOnDemandSnapshotFreshness.nothingMeasuredText"), path)
        }
    }

    // MARK: - N16-3: network rates

    func testTheOverviewNetworkRatesKeepTheLastReadingOnASecondaryPage() throws {
        let page = try Page(for: self, section: .processor)
        defer { page.tearDown() }
        let monitor = page.store.menuBarMonitorState
        let now = Date()
        monitor.update(SystemMonitorSnapshot(
            generatedAt: now.addingTimeInterval(-2), metrics: [],
            networkThroughput: NetworkMonitorThroughput(downBytesPerSecond: 900, upBytesPerSecond: 30)))
        // D128 (2026-10-19): iStat's large bandwidth values start at KB/s
        // (was "900 B/s" and "30 B/s").
        XCTAssertEqual(page.view.networkDownText, "1 KB/s")

        // The next sample has no rates (taken right after the previous one,
        // or across an interface change): the card keeps the last reading.
        monitor.update(SystemMonitorSnapshot(generatedAt: now, metrics: [], networkThroughput: nil))
        XCTAssertEqual(page.view.networkDownText, "1 KB/s")
        XCTAssertEqual(page.view.networkUpText, "0 KB/s")

        // A reading that is long gone is not kept. Review P2-7: its age is
        // counted to now (the view's clock), so the old reading is a minute
        // before now here; a later sample's time no longer stands in for now
        // (`testTheKeptNetworkRatesAreCountedToNow`).
        let stalePage = try Page(for: self, section: .processor)
        defer { stalePage.tearDown() }
        let staleMonitor = stalePage.store.menuBarMonitorState
        staleMonitor.update(SystemMonitorSnapshot(
            generatedAt: now.addingTimeInterval(-60), metrics: [],
            networkThroughput: NetworkMonitorThroughput(downBytesPerSecond: 900, upBytesPerSecond: 30)))
        staleMonitor.update(SystemMonitorSnapshot(generatedAt: now, metrics: [], networkThroughput: nil))
        XCTAssertEqual(stalePage.view.networkDownText, "--")
        XCTAssertEqual(stalePage.view.networkUpText, "--")
    }

    /// r2-live-fixes-2 review P2-7: the 15 s a reading is kept are counted to
    /// now, not to the current sample's time. A kept sample without rates
    /// (D39, after the panel reopens) otherwise brought back rates read ten
    /// minutes earlier until the next sample.
    func testTheKeptNetworkRatesAreCountedToNow() {
        let sampled = Date(timeIntervalSinceReferenceDate: 10_000)
        let withoutRates = MenuBarTelemetryPoint(
            date: sampled, cpuTotal: nil, cpuUser: nil, cpuSystem: nil, gpu: nil, memory: nil,
            chipTemperature: nil, fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: nil)
        let last = MenuBarNetworkReading(date: sampled.addingTimeInterval(-5),
                                         downBytesPerSecond: 900, upBytesPerSecond: 30)
        XCTAssertEqual(MenuBarNetworkReadout.maximumAge, 15)

        let soon = MenuBarNetworkReadout.rates(current: withoutRates, lastReading: last,
                                               now: sampled.addingTimeInterval(10))
        XCTAssertEqual(soon.down, 900, "15 s after the reading")
        XCTAssertEqual(soon.up, 30)

        let later = MenuBarNetworkReadout.rates(current: withoutRates, lastReading: last,
                                                now: sampled.addingTimeInterval(600))
        XCTAssertNil(later.down, "a reading from ten minutes ago is not current")
        XCTAssertNil(later.up)
    }

    func testTheNetworkRatesReadTheNetworkHistoryNotTheOpenPages() throws {
        let components = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift")
        let rates = try MiniWindowLogicFixtures.section(
            components, from: "var networkDownText: String {", to: "func rateText(")
        XCTAssertFalse(rates.contains("selectedDisplayedHistory"), "the open page's window is not the network's")
        XCTAssertTrue(rates.contains("networkDisplayedHistory"))
    }

    // MARK: - Support

    private struct Page {
        let view: MenuBarAdvancedStatusView
        let store: ScanStore
        let defaults: UserDefaults
        let suiteName: String

        @MainActor
        init(for testCase: XCTestCase, section: PanelSection) throws {
            suiteName = TestPreferenceDomain.makeSuite()
            defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suiteName))
            store = try ScanStore.makeForTests(for: testCase, cleanupPreferences: defaults, cleanReportLoader: { [] })
            view = MenuBarAdvancedStatusView(
                store: store,
                computerHealthStore: ComputerHealthStore(probe: RetentionUnusedHealthProbe(), batteryPowerModeController: TestOperationFactory(for: testCase).batteryPowerModeController()),
                panelSettingsState: MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults),
                initialSection: section,
                fanControl: FanControlCoordinator(
                    defaults: defaults,
                    helperStatusOverride: .unavailable,
                    requestSender: { _ in throw CancellationError() }
                )
            )
        }

        func tearDown() {
            TestPreferenceDomain.cleanup(suiteName: suiteName)
        }
    }

    private func waitUntil(seconds: Double, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1_000)))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "not reached within \(seconds) s")
    }
}

private struct RetentionUnusedHealthProbe: ComputerHealthProbing {
    func probe() async throws -> ComputerHealthSnapshot {
        throw CancellationError()
    }
}
