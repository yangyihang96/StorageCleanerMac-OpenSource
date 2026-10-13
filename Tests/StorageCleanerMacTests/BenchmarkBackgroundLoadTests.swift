import Foundation
import XCTest
@testable import StorageCleanerMac

/// BOARD N22 (live 2026-10-07): the environment check did not notice a busy
/// machine (the multi-thread image result was 22 % of the previous run and
/// still rated A). It only compared the 1-minute load average with 75 % of
/// the processors. It now also measures the busy share of all CPU time over
/// its one-second window; at 25 % or more (or the load average rule) the
/// result says the background was busy and results may read low. The test
/// still runs.
final class BenchmarkBackgroundLoadTests: XCTestCase {
    private final class Ticks: @unchecked Sendable {
        private let lock = NSLock()
        private var readings: [BenchmarkV7PreflightService.CPUTicks]
        init(_ readings: [BenchmarkV7PreflightService.CPUTicks]) { self.readings = readings }
        func next() -> BenchmarkV7PreflightService.CPUTicks? {
            lock.withLock { readings.isEmpty ? nil : readings.removeFirst() }
        }
    }

    /// Own CPU seconds read before and after the window.
    private final class OwnSeconds: @unchecked Sendable {
        private let lock = NSLock()
        private var readings: [TimeInterval]
        init(_ readings: [TimeInterval]) { self.readings = readings }
        func next() -> TimeInterval? {
            lock.withLock { readings.isEmpty ? nil : readings.removeFirst() }
        }
    }

    /// `busyShare` of all CPU time was busy over the window, `ownShare` of it
    /// in this app's own process.
    private func capture(busyShare: Double, loadAverage: Double, ownShare: Double = 0) async -> BenchmarkV7PreflightReport {
        let total: UInt64 = 10_000
        let ticks = Ticks([(busy: 1_000, total: 10_000),
                           (busy: 1_000 + UInt64(busyShare * Double(total)), total: 10_000 + total)])
        let ownSeconds = ownShare * Double(total) / BenchmarkV7PreflightService.ticksPerSecond
        let own = OwnSeconds([12, 12 + ownSeconds])
        let service = BenchmarkV7PreflightService(
            sleep: { _ in }, loadAverageRatio: { loadAverage }, cpuTicks: { ticks.next() },
            processCPUSeconds: { own.next() })
        return await service.capture(plan: .quick, categories: [.cpu],
                                     targetDirectory: FileManager.default.temporaryDirectory)
    }

    func testABusyBackgroundIsReportedWithoutBlocking() async {
        XCTAssertEqual(BenchmarkV7PreflightService.highBackgroundCPUBusyRatio, 0.25)
        let report = await capture(busyShare: 0.30, loadAverage: 0.2)
        XCTAssertEqual(report.backgroundCPUBusyRatio ?? 0, 0.30, accuracy: 0.000_1)
        let warning = report.warnings.first { $0.issue == .highBackgroundLoad }
        XCTAssertNotNil(warning, "30 % of all CPU time was busy before the test")
        XCTAssertTrue(warning?.detail.contains("30%") == true, warning?.detail ?? "")
        XCTAssertFalse(report.hasBlockingIssue, "the test still runs")
        XCTAssertTrue(report.blockedCategories.isEmpty)
    }

    func testAQuietMachineHasNoBackgroundWarning() async {
        let report = await capture(busyShare: 0.05, loadAverage: 0.2)
        XCTAssertFalse(report.warnings.contains { $0.issue == .highBackgroundLoad })
    }

    func testTheLoadAverageRuleStillApplies() async {
        let report = await capture(busyShare: 0.05, loadAverage: 0.8)
        XCTAssertTrue(report.warnings.contains { $0.issue == .highBackgroundLoad })
    }

    /// Review P2-10: the window's busy time includes this app's own work (its
    /// interface, monitors and the preflight itself); that is not background
    /// load and is subtracted. The threshold stays 25 % of all CPU time.
    func testThisAppsOwnCPUTimeIsNotBackgroundLoad() async {
        let mostlyOwn = await capture(busyShare: 0.30, loadAverage: 0.2, ownShare: 0.10)
        XCTAssertEqual(mostlyOwn.backgroundCPUBusyRatio ?? 0, 0.20, accuracy: 0.000_1)
        XCTAssertFalse(mostlyOwn.warnings.contains { $0.issue == .highBackgroundLoad },
                       "30 % busy, 10 % of it this app: 20 % background")

        let busy = await capture(busyShare: 0.40, loadAverage: 0.2, ownShare: 0.10)
        XCTAssertEqual(busy.backgroundCPUBusyRatio ?? 0, 0.30, accuracy: 0.000_1)
        XCTAssertTrue(busy.warnings.contains { $0.issue == .highBackgroundLoad })

        XCTAssertEqual(BenchmarkV7PreflightService.busyRatio(
            from: (100, 1_000), to: (400, 2_000), ownCPUSeconds: 400 / BenchmarkV7PreflightService.ticksPerSecond,
            minimumTotalTicks: 1_000) ?? -1,
            0, accuracy: 0.000_1, "never below zero")
        XCTAssertEqual(BenchmarkV7PreflightService.busyRatio(
            from: (100, 1_000), to: (400, 2_000), ownCPUSeconds: nil, minimumTotalTicks: 1_000) ?? 0,
            0.3, accuracy: 0.000_1, "without the own reading nothing is subtracted")
    }

    /// The live readers: this process's CPU time grows with work, and the
    /// host's tick rate matches the clock. The host counters advance about
    /// once a second for all processors, so the rate is timed between two of
    /// those updates.
    func testTheOwnCPUTimeAndTheTickRateAreReadHere() async throws {
        let before = try XCTUnwrap(BenchmarkV7PreflightService.ownProcessCPUSeconds())
        var accumulator = 0.0
        for index in 0..<3_000_000 { accumulator += sin(Double(index)) }
        XCTAssertNotEqual(accumulator, .infinity)
        let after = try XCTUnwrap(BenchmarkV7PreflightService.ownProcessCPUSeconds())
        XCTAssertGreaterThan(after, before, "this process's CPU time grew")

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(6))
        let bulk = BenchmarkV7PreflightService.minimumWindowTicks
        func nextUpdate() async throws -> (ticks: UInt64, at: ContinuousClock.Instant)? {
            var last = try XCTUnwrap(BenchmarkV7PreflightService.systemCPUTicks()).total
            while clock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
                let current = try XCTUnwrap(BenchmarkV7PreflightService.systemCPUTicks()).total
                if current >= last + bulk { return (current, clock.now) }
                last = current
            }
            return nil
        }
        let first = try await nextUpdate()
        let second = try await nextUpdate()
        guard let first, let second else {
            return XCTFail("the host CPU counters did not advance in bulk within 6 s")
        }
        let elapsed = first.at.duration(to: second.at)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let rate = Double(second.ticks - first.ticks) / seconds / Double(ProcessInfo.processInfo.activeProcessorCount)
        XCTAssertEqual(rate, BenchmarkV7PreflightService.ticksPerSecond,
                       accuracy: BenchmarkV7PreflightService.ticksPerSecond * 0.25,
                       "ticks per processor-second over \(seconds) s")
    }

    func testTheBusyShareComesFromTwoTickReadings() {
        XCTAssertEqual(BenchmarkV7PreflightService.busyRatio(from: (100, 1_000), to: (400, 2_000),
                                                             minimumTotalTicks: 1_000) ?? 0, 0.3,
                       accuracy: 0.000_1)
        XCTAssertNil(BenchmarkV7PreflightService.busyRatio(from: (100, 1_000), to: (100, 1_000)), "no time passed")
        XCTAssertNil(BenchmarkV7PreflightService.busyRatio(from: (100, 1_000), to: (104, 1_010), minimumTotalTicks: 900),
                     "only the reading processor's own ticks: no share")
        XCTAssertNil(BenchmarkV7PreflightService.busyRatio(from: nil, to: (400, 2_000)))
        XCTAssertNotNil(BenchmarkV7PreflightService.systemCPUTicks(), "this Mac reports its CPU ticks")
    }

    /// The result card names it with the result (the preflight is kept with
    /// the result), in the words the live test asked for.
    func testTheResultCardSaysResultsMayReadLow() throws {
        let dashboard = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7DashboardView.swift")
        let warning = try MiniWindowLogicFixtures.section(
            dashboard, from: "case .highBackgroundLoad:", to: "case .lowAvailableMemory:")
        XCTAssertTrue(warning.contains("后台负载高，结果可能偏低"))
    }
}
