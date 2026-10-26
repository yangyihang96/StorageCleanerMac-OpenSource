import FanControlShared
import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class HelperPowerMetricsMonitorTests: XCTestCase {
    func testAutomaticReopenWaitsForOldFlightToDrainThenDispatchesAtDue() async {
        let gate = Box<CheckedContinuation<PowermetricsResult, Never>?>(nil)
        let time = Box(100.0), starts = Box<[Double]>([]), sleeps = Box<[Double]>([])
        let observed = Box<[HelperPowerMetricsReading]>([])
        let holder = Box<HelperPowerMetricsMonitor?>(nil), id = UUID()
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            starts.value.append(time.value)
            if starts.value.count == 1 { return await withCheckedContinuation { gate.value = $0 } }
            holder.value?.updateConsumer(id, visible: false)
            return .sample(self.sample)
        }, now: { time.value }, sleep: { duration in
            sleeps.value.append(duration); throw CancellationError()
        })
        holder.value = monitor
        let observer = monitor.observeReadings { observed.value.append($0) }
        monitor.updateConsumer(id, visible: true)
        for _ in 0..<10_000 {
            if gate.value != nil { break }
            await Task.yield()
        }
        guard let continuation = gate.value else {
            monitor.updateConsumer(id, visible: false); holder.value = nil
            return XCTFail("automatic request did not enter gate")
        }
        time.value = 104
        monitor.updateConsumer(id, visible: false)
        monitor.updateConsumer(id, visible: true)
        // Give a mistakenly recreated worker a chance to enter its sleep.
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(starts.value, [100])
        XCTAssertTrue(sleeps.value.isEmpty, "reopened demand waits for drain, not another polling interval")
        continuation.resume(returning: .sample(sample))
        for _ in 0..<10_000 {
            if starts.value.count == 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(starts.value, [100, 104], "an overdue request dispatches immediately after drain")
        XCTAssertTrue(observed.value.isEmpty, "cancelled generations cannot publish")
        monitor.updateConsumer(id, visible: false)
        monitor.removeReadingObserver(observer); holder.value = nil
    }

    func testAutomaticLoopSubtractsRequestTimeAndKeepsTwoSecondStarts() async {
        let time = Box(100.0), starts = Box<[Double]>([]), sleeps = Box<[Double]>([])
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            starts.value.append(time.value)
            time.value += 1
            return .sample(self.sample)
        }, now: { time.value }, sleep: { duration in
            sleeps.value.append(duration)
            guard sleeps.value.count < 3 else { throw CancellationError() }
            time.value += duration
        })
        let id = UUID()
        monitor.updateConsumer(id, visible: true)
        for _ in 0..<10_000 {
            if sleeps.value.count >= 3 { break }
            await Task.yield()
        }
        monitor.updateConsumer(id, visible: false)
        XCTAssertEqual(starts.value, [100, 102, 104], "request starts, not completion times, define the schedule")
        XCTAssertEqual(sleeps.value, [1, 1, 1], "a one-second request consumes half the interval")
    }

    func testSlowRequestDoesNotAddAnotherSleepBeforeNextDispatch() async {
        let time = Box(100.0), starts = Box<[Double]>([]), sleeps = Box<[Double]>([])
        let holder = Box<HelperPowerMetricsMonitor?>(nil)
        let id = UUID()
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            starts.value.append(time.value)
            time.value += 2.5
            if starts.value.count == 2 { holder.value?.updateConsumer(id, visible: false) }
            return .sample(self.sample)
        }, now: { time.value }, sleep: { duration in
            sleeps.value.append(duration)
            throw CancellationError()
        })
        holder.value = monitor
        monitor.updateConsumer(id, visible: true)
        for _ in 0..<10_000 {
            if starts.value.count >= 2 || !sleeps.value.isEmpty { break }
            await Task.yield()
        }
        monitor.updateConsumer(id, visible: false)
        holder.value = nil
        XCTAssertEqual(starts.value, [100, 102.5])
        XCTAssertTrue(sleeps.value.isEmpty, "an already-due request starts after the previous request drains")
    }

    func testAutomaticLoopWaitsWhenHelperBecomesUnavailable() async {
        let time = Box(100.0), availability = Box(HelperPowerMetricsAvailability.ready)
        let calls = Box(0), sleeps = Box<[Double]>([])
        let monitor = HelperPowerMetricsMonitor(availability: { availability.value }, request: {
            calls.value += 1; time.value = 110; availability.value = .needsHelper
            return .sample(self.sample)
        }, now: { time.value }, sleep: { duration in
            sleeps.value.append(duration); throw CancellationError()
        })
        let id = UUID()
        monitor.updateConsumer(id, visible: true)
        for _ in 0..<10_000 {
            if !sleeps.value.isEmpty { break }
            await Task.yield()
        }
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(sleeps.value, [2], "an unavailable helper cannot spin on an expired due time")
        XCTAssertEqual(monitor.state, .needsHelper)
        monitor.updateConsumer(id, visible: false)
    }

    func testInFlightCannotOverlapEvenAfterDueTimeAndVisibilityReopen() async {
        let gate = Box<CheckedContinuation<PowermetricsResult, Never>?>(nil)
        let time = Box(100.0), calls = Box(0)
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            calls.value += 1
            guard calls.value == 1 else { return .sample(self.sample) }
            return await withCheckedContinuation { gate.value = $0 }
        }, now: { time.value }, automaticSampling: false)
        let id = UUID()
        monitor.updateConsumer(id, visible: true)
        let pending = Task { await monitor.sampleIfDue() }
        for _ in 0..<10_000 {
            if gate.value != nil { break }
            await Task.yield()
        }
        guard let continuation = gate.value else {
            pending.cancel(); monitor.updateConsumer(id, visible: false)
            await pending.value
            return XCTFail("request did not enter gate")
        }
        time.value = 104
        await monitor.sampleIfDue()
        monitor.updateConsumer(id, visible: false)
        monitor.updateConsumer(id, visible: true)
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 1, "due and reopening cannot overlap an unfinished request")
        continuation.resume(returning: .sample(sample))
        await pending.value
        XCTAssertNil(monitor.latestReading, "old generation cannot publish telemetry")
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 2)
        monitor.updateConsumer(id, visible: false)
    }

    func testRequestBracketUsesContinuousNanosecondsIndependentlyOfWallClock() async throws {
        let nanos = Box<UInt64>(100_000_000_000)
        let wall = Box(Date(timeIntervalSince1970: 1_000))
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            nanos.value = 101_000_000_000
            wall.value = Date(timeIntervalSince1970: 500)
            return .sample(self.sample)
        }, wallClock: { wall.value }, automaticSampling: false, monotonicNanoseconds: { nanos.value })
        let id = UUID()
        monitor.updateConsumer(id, visible: true)
        await monitor.sampleIfDue()
        let reading = try XCTUnwrap(monitor.latestReading)
        XCTAssertEqual(reading.requestStartMonotonicNs, 100_000_000_000)
        XCTAssertEqual(reading.responseReceivedMonotonicNs, 101_000_000_000)
        XCTAssertEqual(reading.clockDomain, "mach-continuous-v1")
        XCTAssertEqual(monitor.state, .available(sample, sampledAt: wall.value))
        monitor.updateConsumer(id, visible: false)
        XCTAssertNil(monitor.latestReading)
    }

    func testObserverAloneNeverCreatesDemandAndFailureClearsTelemetry() async {
        let calls = Box(0), time = Box(100.0), observed = Box<[HelperPowerMetricsReading]>([])
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            calls.value += 1
            return calls.value == 1 ? .sample(self.sample) : .failure(.timedOut)
        }, now: { time.value }, automaticSampling: false)
        let observer = monitor.observeReadings { observed.value.append($0) }
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 0)
        let id = UUID()
        monitor.updateConsumer(id, visible: true)
        await monitor.sampleIfDue()
        time.value = 102
        await monitor.sampleIfDue()
        XCTAssertEqual(observed.value.count, 1)
        XCTAssertNil(monitor.latestReading)
        XCTAssertEqual(monitor.state, .failed(.timedOut))
        monitor.removeReadingObserver(observer)
        monitor.updateConsumer(id, visible: false)
    }

    func testNoDemandAndUnavailableHelpersNeverRequest() async {
        let availability = Box(HelperPowerMetricsAvailability.ready)
        let calls = Box(0)
        let monitor = HelperPowerMetricsMonitor(availability: { availability.value }, request: {
            calls.value += 1; return .sample(self.sample)
        }, automaticSampling: false)
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 0)
        let id = UUID()
        monitor.updateConsumer(id, visible: true)
        availability.value = .needsHelper
        await monitor.sampleIfDue()
        XCTAssertEqual(monitor.state, .needsHelper)
        availability.value = .needsUpdate
        await monitor.sampleIfDue()
        XCTAssertEqual(monitor.state, .needsUpdate)
        XCTAssertEqual(calls.value, 0)
        monitor.updateConsumer(id, visible: false)
    }

    func testMultipleVisibleModulesShareOneStreamAndRespectTwoSeconds() async {
        let time = Box(100.0), calls = Box(0)
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            calls.value += 1; return .sample(self.sample)
        }, now: { time.value }, automaticSampling: false)
        let energy = UUID(), power = UUID(), sensors = UUID()
        for id in [energy, power, sensors] { monitor.updateConsumer(id, visible: true) }
        await monitor.sampleIfDue()
        time.value = 101.999
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 1)
        time.value = 102
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 2)
        monitor.updateConsumer(energy, visible: false)
        monitor.updateConsumer(power, visible: false)
        XCTAssertTrue(monitor.hasDemand)
        monitor.updateConsumer(sensors, visible: false)
        XCTAssertFalse(monitor.hasDemand)
        time.value = 200
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 2)
    }

    func testClosingOrSleepingDuringRequestDiscardsLateReplyAndReopenIsThrottled() async {
        let gate = Box<CheckedContinuation<PowermetricsResult, Never>?>(nil)
        let time = Box(100.0), calls = Box(0)
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: {
            calls.value += 1
            // Only the first request is gated; a regression that sends a second
            // one must fail the call count below instead of hanging the test.
            guard calls.value == 1 else { return .failure(.throttled) }
            return await withCheckedContinuation { gate.value = $0 }
        }, now: { time.value }, automaticSampling: false)
        let id = UUID()
        monitor.updateConsumer(id, visible: true)
        let pending = Task { await monitor.sampleIfDue() }
        for _ in 0..<10_000 {
            if gate.value != nil { break }
            await Task.yield()
        }
        guard let continuation = gate.value else {
            pending.cancel()
            monitor.updateConsumer(id, visible: false)
            await pending.value
            return XCTFail("request did not enter its continuation gate")
        }
        monitor.updateConsumer(id, visible: false)
        monitor.updateConsumer(id, visible: true)
        continuation.resume(returning: .sample(sample))
        await pending.value
        XCTAssertEqual(monitor.state, .sampling, "the old visibility generation cannot publish")
        time.value = 101.99
        await monitor.sampleIfDue()
        XCTAssertEqual(calls.value, 1, "rapid reopening cannot bypass the interval")
        monitor.updateConsumer(id, visible: false)
    }

    func testApprovalRevokedWhileInFlightDiscardsTheResult() async {
        let availability = Box(HelperPowerMetricsAvailability.ready)
        let monitor = HelperPowerMetricsMonitor(availability: { availability.value }, request: {
            availability.value = .needsHelper
            return .sample(self.sample)
        }, automaticSampling: false)
        let id = UUID()
        monitor.updateConsumer(id, visible: true)
        await monitor.sampleIfDue()
        XCTAssertEqual(monitor.state, .needsHelper)
        monitor.updateConsumer(id, visible: false)
    }

    func testFailureReplacesEarlierLiveNumbersAndDoesNotInventZero() async {
        let result = Box(PowermetricsResult.sample(sample))
        let time = Box(100.0)
        let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: { result.value },
                                                now: { time.value }, automaticSampling: false)
        let id = UUID()
        monitor.updateConsumer(id, visible: true)
        await monitor.sampleIfDue()
        if case .available = monitor.state {} else { XCTFail("sample was not published") }
        time.value = 102
        result.value = .failure(.timedOut)
        await monitor.sampleIfDue()
        XCTAssertEqual(monitor.state, .failed(.timedOut))
        XCTAssertTrue(HelperPowerMetricsPresentation.rows(monitor.state, now: Date()).allSatisfy { $0.value == "—" })
        monitor.updateConsumer(id, visible: false)
    }

    func testFallbackMeasuredZeroSourceAndExpirationAreDistinct() {
        let language = MiniWindowLogicLanguageScope(.zhHans)
        defer { language.restore() }
        let at = Date(timeIntervalSince1970: 100)
        for state in [HelperPowerMetricsState.needsHelper, .needsUpdate, .sampling, .failed(.invalidOutput)] {
            XCTAssertTrue(HelperPowerMetricsPresentation.rows(state, now: at).allSatisfy { $0.value == "—" })
        }
        XCTAssertEqual(HelperPowerMetricsPresentation.detail(.needsHelper, now: at), "需要系统助手")
        XCTAssertEqual(HelperPowerMetricsPresentation.source, "系统助手 · powermetrics")
        let available = HelperPowerMetricsState.available(sample, sampledAt: at)
        let rows = HelperPowerMetricsPresentation.rows(available, now: at)
        // D128 (2026-10-19): iStat's power and frequency formats (was
        // "5.00 W", "0.00 W", "3200 MHz").
        XCTAssertEqual(rows.first { $0.id == "cpu" }?.value, "5 W")
        XCTAssertEqual(rows.first { $0.id == "ane" }?.value, "0 W")
        XCTAssertEqual(rows.first { $0.id == "P0" }?.value, "3.2 GHz")
        XCTAssertEqual(rows.first { $0.id == "efficiency" }?.value, "—")
        XCTAssertTrue(HelperPowerMetricsPresentation.detail(available, now: at).contains("1.00"))
        let expired = at.addingTimeInterval(6.01)
        XCTAssertEqual(HelperPowerMetricsPresentation.rows(available, now: expired).first?.value, "5 W", "D128: was 5.00 W")
        XCTAssertTrue(HelperPowerMetricsPresentation.detail(available, now: expired).contains("6 秒前"))
    }

    func testEverySurfaceUsesTheSameMonitorAndWindowVisibilityControlsDemand() throws {
        let source = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/HelperPowerMetricsView.swift")
        for event in ["didChangeOcclusionStateNotification", "didMiniaturizeNotification", "willCloseNotification",
                      "willSleepNotification", "screensDidSleepNotification", "didHideNotification", "onDisappear"] {
            XCTAssertTrue(source.contains(event), event)
        }
        XCTAssertTrue(try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift").contains("HelperPowerMetricsView(monitor: store.helperPowerMetricsMonitor"))
        // D119 (2026-10-18): the helper rows are the sensors page's power and
        // frequency groups, as on iStat; the power page no longer lists them.
        XCTAssertTrue(try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift").contains("geekHelperPowerMetricsCards"))
        XCTAssertTrue(try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift").contains("geekSensorFrequencyGroup"))
        XCTAssertFalse(try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift").contains("geekHelperPowerMetricsCards"))
        let miniCards = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHelperPowerMetricsCards.swift")
        XCTAssertTrue(miniCards.contains("GeekHelperPowerMetricsCards(monitor: store.helperPowerMetricsMonitor)"))
        XCTAssertTrue(miniCards.contains("@ObservedObject var monitor: HelperPowerMetricsMonitor"))
        XCTAssertFalse(miniCards.contains("updateConsumer"), "The passive mini leaf uses the resident cadence; rendering adds no demand")
        let store = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Stores/ScanStore.swift")
        let property = try MiniWindowLogicFixtures.section(store, from: "lazy var helperPowerMetricsMonitor", to: "@Published var energyImpactSnapshot")
        XCTAssertTrue(property.contains("self?.fanControlCoordinator"), "isolated stores retain their injected helper")
        XCTAssertFalse(property.contains(".shared"))
        let settings = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/SettingsView.swift")
        XCTAssertTrue(source.contains("settingsCategory = .accessAndSetup"))
        XCTAssertTrue(settings.contains("proxy.scrollTo(SystemHelperSettingsNavigation.anchor"))
        XCTAssertTrue(settings.contains(".id(SystemHelperSettingsNavigation.anchor)"))
        XCTAssertFalse(source.contains("registerHelper"))
        XCTAssertFalse(source.contains("openApprovalSettings"))
        XCTAssertTrue(source.contains("!MiniWindowDemoData.isEnabled"))
        XCTAssertTrue(source.contains("visible && permitsLiveDemand"), "capture/demo views cannot invoke the real helper")
    }

    /// Production wiring through ScanStore: an unregistered helper degrades to
    /// "—" plus "需要系统助手". The factory's fan fake records and fails the test on
    /// any XPC request, registration, unregistration or approval-settings call.
    func testScanStoreWiringDegradesWithoutRequestingOrAuthorizing() async throws {
        let language = MiniWindowLogicLanguageScope(.zhHans)
        defer { language.restore() }
        let store = try ScanStore.makeForTests(for: self)
        let monitor = store.helperPowerMetricsMonitor
        XCTAssertTrue(monitor === store.helperPowerMetricsMonitor, "one shared demand stream")
        XCTAssertEqual(monitor.state, .needsHelper)
        let id = UUID()
        monitor.updateConsumer(id, visible: true)
        await monitor.sampleIfDue()
        monitor.updateConsumer(id, visible: false)
        await monitor.sampleIfDue()
        let now = Date()
        XCTAssertTrue(HelperPowerMetricsPresentation.rows(.needsHelper, now: now).allSatisfy { $0.value == "—" })
        XCTAssertEqual(HelperPowerMetricsPresentation.detail(.needsHelper, now: now), "需要系统助手")
    }

    func testUnavailableAndUnauthorizedRepliesShowNeedsHelperWithoutNumbers() async {
        for failure in [PowermetricsFailure.unavailable, .unauthorized] {
            let monitor = HelperPowerMetricsMonitor(availability: { .ready }, request: { .failure(failure) },
                                                    automaticSampling: false)
            let id = UUID()
            monitor.updateConsumer(id, visible: true)
            await monitor.sampleIfDue()
            XCTAssertEqual(monitor.state, .needsHelper, failure.rawValue)
            XCTAssertTrue(HelperPowerMetricsPresentation.rows(monitor.state, now: Date()).allSatisfy { $0.value == "—" })
            monitor.updateConsumer(id, visible: false)
        }
    }

    @MainActor
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private var sample: PowermetricsSample {
        PowermetricsSample(cpuMilliwatts: 5_000, gpuMilliwatts: 2_000, aneMilliwatts: 0,
            clusters: [.init(name: "P0", kind: .performance, megahertz: 3_200)], gpuMegahertz: 800, durationSeconds: 1)
    }
}
