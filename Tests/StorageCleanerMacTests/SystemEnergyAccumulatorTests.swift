import Foundation
import XCTest
@testable import StorageCleanerMac

final class SystemEnergyAccumulatorTests: XCTestCase {
    func testACSamplesUseTrapezoidIntegrationAndKilowattHourConversion() {
        var session = makeSession()
        session.append(sample(at: 0, watts: 100, source: .ac))
        session.append(
            sample(at: 3_600, watts: 100, source: .ac),
            maximumInterval: 3_601
        )

        XCTAssertEqual(session.acWattHours, 100, accuracy: 0.000_1)
        XCTAssertEqual(session.batteryWattHours, 0)
        XCTAssertEqual(session.totalKilowattHours, 0.1, accuracy: 0.000_1)
    }

    func testBatterySamplesAccumulateSeparately() {
        var session = makeSession()
        session.append(sample(at: 0, watts: 20, source: .battery, confidence: .measured))
        session.append(sample(at: 60, watts: 40, source: .battery, confidence: .measured))

        XCTAssertEqual(session.batteryWattHours, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(session.acWattHours, 0)
        XCTAssertEqual(session.measuredSeconds, 60)
    }

    func testPowerSourceTransitionUsesThePreviousSourceUntilTheTransitionSample() {
        var session = makeSession()
        session.append(sample(at: 0, watts: 60, source: .battery))
        session.append(sample(at: 60, watts: 60, source: .ac))
        session.append(sample(at: 120, watts: 60, source: .ac))

        XCTAssertEqual(session.batteryWattHours, 1, accuracy: 0.000_1)
        XCTAssertEqual(session.acWattHours, 1, accuracy: 0.000_1)
    }

    func testDuplicateAndOutOfOrderSamplesCannotIncreaseOrDecreaseEnergy() {
        var session = makeSession()
        session.append(sample(at: 10, watts: 60, source: .ac))
        session.append(sample(at: 70, watts: 60, source: .ac))
        let total = session.totalWattHours

        session.append(sample(at: 70, watts: 600, source: .ac))
        session.append(sample(at: 20, watts: 600, source: .ac))

        XCTAssertEqual(session.totalWattHours, total)
    }

    func testLargeGapAndMissingSampleAreNotIntegrated() {
        var session = makeSession()
        session.append(sample(at: 0, watts: 60, source: .ac))
        session.append(sample(at: 600, watts: 60, source: .ac))
        session.markGap(at: Date(timeIntervalSince1970: 700))
        session.append(sample(at: 660, watts: 60, source: .ac))

        XCTAssertEqual(session.totalWattHours, 0)
        XCTAssertEqual(session.gapSeconds, 600)
    }

    func testEstimatedAndMeasuredCoverageStayDistinct() {
        var session = makeSession()
        session.append(sample(at: 0, watts: 10, source: .ac, confidence: .estimated))
        session.append(sample(at: 30, watts: 10, source: .ac, confidence: .estimated))
        session.append(sample(at: 60, watts: 10, source: .ac, confidence: .measured))
        session.append(sample(at: 90, watts: 10, source: .ac, confidence: .measured))

        XCTAssertEqual(session.estimatedSeconds, 60)
        XCTAssertEqual(session.measuredSeconds, 30)
        XCTAssertEqual(session.coveragePercent(uptimeSeconds: 180), 50)
        XCTAssertTrue(session.isEstimated)
    }

    @MainActor
    func testApplicationRestartRestoresTotalsWithoutBridgingTheUnobservedGap() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let boot = bootIdentity(id: "same-boot")
        var saved = SystemEnergySessionSnapshot(boot: boot, monitoringStartedAt: date(0))
        saved.append(sample(at: 0, watts: 60, source: .ac))
        saved.append(sample(at: 60, watts: 60, source: .ac))
        try SystemEnergySessionStore.save(saved, to: url)

        let accumulator = SystemEnergyAccumulator(
            fileURL: url,
            boot: boot,
            now: date(120),
            sampleProvider: { nil }
        )

        XCTAssertEqual(accumulator.snapshot.acWattHours, 1, accuracy: 0.000_1)
        XCTAssertNil(accumulator.snapshot.lastSample)
    }

    @MainActor
    func testNewBootSessionStartsAtZero() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var saved = makeSession(bootID: "old-boot")
        saved.append(sample(at: 0, watts: 60, source: .battery))
        saved.append(sample(at: 60, watts: 60, source: .battery))
        try SystemEnergySessionStore.save(saved, to: url)

        let accumulator = SystemEnergyAccumulator(
            fileURL: url,
            boot: bootIdentity(id: "new-boot"),
            now: date(120),
            sampleProvider: { nil }
        )

        XCTAssertEqual(accumulator.snapshot.totalWattHours, 0)
        XCTAssertEqual(accumulator.snapshot.bootSessionIdentifier, "new-boot")
    }

    func testPersistenceWriterCannotOverwriteNewerEnergyWithAStaleSnapshot() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = SystemEnergyPersistenceWriter()
        var older = makeSession()
        older.append(sample(at: 0, watts: 60, source: .ac))
        older.append(sample(at: 60, watts: 60, source: .ac))
        var newer = older
        newer.append(sample(at: 120, watts: 60, source: .ac))

        await writer.save(newer, to: url)
        await writer.save(older, to: url)

        let restored = try XCTUnwrap(SystemEnergySessionStore.load(from: url))
        XCTAssertEqual(restored.totalWattHours, newer.totalWattHours)
    }

    func testPersistenceWriterCoalescesFrequentSamplesAndForcedSaveFlushesLatest() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = SystemEnergyPersistenceWriter()
        var first = makeSession()
        first.append(sample(at: 0, watts: 60, source: .ac))
        first.append(sample(at: 60, watts: 60, source: .ac))
        var frequent = first
        frequent.append(sample(at: 120, watts: 60, source: .ac))

        await writer.save(first, to: url)
        await writer.save(frequent, to: url)
        var restored = try XCTUnwrap(SystemEnergySessionStore.load(from: url))
        XCTAssertEqual(restored.totalWattHours, first.totalWattHours)

        await writer.save(frequent, to: url, force: true)
        restored = try XCTUnwrap(SystemEnergySessionStore.load(from: url))
        XCTAssertEqual(restored.totalWattHours, frequent.totalWattHours)
    }

    @MainActor
    func testSleepAndWakeBreakTheIntegrationInterval() async {
        let accumulator = SystemEnergyAccumulator(
            fileURL: nil,
            boot: bootIdentity(id: "sleep-test"),
            now: date(0),
            sampleProvider: { nil }
        )
        accumulator.record(sample(at: 0, watts: 60, source: .battery))
        accumulator.markSleep(at: date(30))
        accumulator.markWake(at: date(3_630))
        accumulator.record(sample(at: 3_660, watts: 60, source: .battery))

        XCTAssertEqual(accumulator.snapshot.totalWattHours, 0)
    }

    @MainActor
    func testConcurrentRequestsCoalesceAndStopDrainsBeforeIgnoringOldResult() async {
        let gate = EnergySamplingGate()
        let accumulator = SystemEnergyAccumulator(fileURL: nil, sampleProvider: { await gate.read() })
        let first = Task { await accumulator.sampleNow() }
        while await gate.calls == 0 { await Task.yield() }
        let second = Task { await accumulator.sampleNow() }
        await Task.yield()
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        let stop = Task { await accumulator.stopAndFlush() }
        await Task.yield()
        await gate.release(sample(at: 10, watts: 60, source: .ac))
        await first.value
        await second.value
        await stop.value
        XCTAssertNil(accumulator.snapshot.lastSample, "Cancelled physical reads cannot publish")
    }

    @MainActor
    func testPassiveProductionModeDoesNotStartItsOwnSampler() async {
        let gate = EnergySamplingGate()
        let accumulator = SystemEnergyAccumulator(fileURL: nil, sampleProvider: { await gate.read() })
        accumulator.start(passive: true)
        for _ in 0..<20 { await Task.yield() }
        let calls = await gate.calls
        XCTAssertEqual(calls, 0)
        await accumulator.stopAndFlush()
    }

    func testOutOfOrderCallbackCannotBecomeAnIntegrationBaseline() {
        var session = makeSession()
        session.append(sample(at: 10, watts: 60, source: .ac))
        session.append(sample(at: 70, watts: 60, source: .ac))
        session.append(sample(at: 20, watts: 600, source: .ac))
        session.append(sample(at: 80, watts: 60, source: .ac))
        XCTAssertEqual(session.acWattHours, 70.0 / 60.0, accuracy: 0.0001)
    }

    private func makeSession(bootID: String = "boot") -> SystemEnergySessionSnapshot {
        SystemEnergySessionSnapshot(
            boot: bootIdentity(id: bootID),
            monitoringStartedAt: date(0)
        )
    }

    private func bootIdentity(id: String) -> SystemEnergyBootIdentity {
        SystemEnergyBootIdentity(identifier: id, startedAt: date(0), uptimeSeconds: 0)
    }

    private func sample(
        at seconds: TimeInterval,
        watts: Double,
        source: SystemEnergyPowerSource,
        confidence: SystemEnergySampleConfidence = .estimated
    ) -> SystemEnergyPowerSample {
        SystemEnergyPowerSample(
            monotonicSeconds: seconds,
            wallClock: date(seconds),
            watts: watts,
            powerSource: source,
            confidence: confidence,
            source: "fixture"
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerMac-SystemEnergy-\(UUID().uuidString)")
            .appendingPathComponent("session.json")
    }
}

private actor EnergySamplingGate {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<SystemEnergyPowerSample?, Never>?
    func read() async -> SystemEnergyPowerSample? {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ sample: SystemEnergyPowerSample?) {
        continuation?.resume(returning: sample)
        continuation = nil
    }
}
