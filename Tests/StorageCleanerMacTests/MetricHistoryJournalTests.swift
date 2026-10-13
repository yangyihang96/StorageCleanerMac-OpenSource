import XCTest
@testable import StorageCleanerMac

final class MetricHistoryJournalTests: XCTestCase {
    func testSubsequentFlushAppendsWithoutRewritingCheckpointAndRestarts() async throws {
        let root = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json")
        let now = Date()
        let store = MetricHistoryStore(url: url)
        await store.appendPower(point(now, 50), now: now)
        try await store.flush(now: now)
        let initial = try Data(contentsOf: url)
        let later = now.addingTimeInterval(60)
        await store.appendPower(point(later, 51), now: later)
        try await store.flush(now: later)
        XCTAssertEqual(try Data(contentsOf: url), initial, "Ordinary batches cannot rewrite all retained history")
        XCTAssertFalse(try Data(contentsOf: url.appendingPathExtension("events")).isEmpty)
        let restart = await MetricHistoryStore(url: url).load(now: later)
        XCTAssertEqual(restart.power.map(\.chargePercent), [50, 51])
    }

    // Damaged evidence stays protected as a byte-for-byte copy; history then
    // resumes from the last valid record instead of freezing for good.
    func testDamagedChecksumKeepsOriginalBytesAndResumesSaving() async throws {
        let root = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json"), now = Date()
        let store = MetricHistoryStore(url: url)
        await store.appendPower(point(now, 50), now: now); try await store.flush(now: now)
        let later = now.addingTimeInterval(60)
        await store.appendPower(point(later, 51), now: later); try await store.flush(now: later)
        let events = url.appendingPathExtension("events")
        let original = try String(contentsOf: events, encoding: .utf8)
        let corrupt = Data(original.replacingOccurrences(of: "\"chargePercent\":51", with: "\"chargePercent\":52").utf8)
        XCTAssertNotEqual(corrupt, Data(original.utf8))
        try corrupt.write(to: events)
        let restart = MetricHistoryStore(url: url)
        let snapshot = await restart.load(now: later)
        XCTAssertEqual(snapshot.power.map(\.chargePercent), [50])
        let failure = await restart.loadFailure; XCTAssertNil(failure)
        XCTAssertEqual(try preservedCopies(in: root).map { try Data(contentsOf: $0) }, [corrupt])
        let resumed = later.addingTimeInterval(1)
        await restart.appendPower(point(resumed, 60), now: resumed)
        try await restart.flush(now: resumed)
        let reopened = await MetricHistoryStore(url: url).load(now: resumed)
        XCTAssertEqual(reopened.power.map(\.chargePercent), [50, 60])
    }

    func testTruncatedTailKeepsOriginalBytesAndResumesSaving() async throws {
        let root = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json"), now = Date()
        let store = MetricHistoryStore(url: url)
        for i in 0..<3 {
            let t = now.addingTimeInterval(Double(i * 60))
            await store.appendPower(point(t, Double(50 + i)), now: t); try await store.flush(now: t)
        }
        let events = url.appendingPathExtension("events")
        var bytes = try Data(contentsOf: events); bytes.removeLast(10); try bytes.write(to: events)
        let restart = MetricHistoryStore(url: url)
        let resumed = now.addingTimeInterval(180)
        let snapshot = await restart.load(now: resumed)
        XCTAssertEqual(snapshot.power.map(\.chargePercent), [50, 51])
        let failure = await restart.loadFailure; XCTAssertNil(failure)
        XCTAssertEqual(try preservedCopies(in: root).map { try Data(contentsOf: $0) }, [bytes])
        await restart.appendPower(point(resumed, 53), now: resumed)
        try await restart.flush(now: resumed)
        let reopened = await MetricHistoryStore(url: url).load(now: resumed)
        XCTAssertEqual(reopened.power.map(\.chargePercent), [50, 51, 53])
    }

    func testTheSameDamagedBytesAreKeptOnlyOnce() async throws {
        let root = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json"), now = Date()
        let store = MetricHistoryStore(url: url)
        for i in 0..<2 {
            let t = now.addingTimeInterval(Double(i * 60))
            await store.appendPower(point(t, Double(50 + i)), now: t); try await store.flush(now: t)
        }
        let events = url.appendingPathExtension("events")
        var bytes = try Data(contentsOf: events); bytes.removeLast(10)
        for _ in 0..<2 {
            try bytes.write(to: events) // the same tear seen again on a later launch
            _ = try MetricHistoryJournal(url: url, maximumSnapshotBytes: 1 << 20)
                .preserveDamagedTailAndCheckpoint(now: now.addingTimeInterval(120))
        }
        XCTAssertEqual(try preservedCopies(in: root).count, 1)
    }

    func testDamagedTailStaysFrozenWhenTheOriginalCannotBeKept() async throws {
        try XCTSkipIf(geteuid() == 0, "chmod cannot deny the superuser")
        let root = fixture(); defer { chmod(root.path, 0o755); try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json"), now = Date()
        let store = MetricHistoryStore(url: url)
        for i in 0..<2 {
            let t = now.addingTimeInterval(Double(i * 60))
            await store.appendPower(point(t, Double(50 + i)), now: t); try await store.flush(now: t)
        }
        let events = url.appendingPathExtension("events")
        var bytes = try Data(contentsOf: events); bytes.removeLast(10); try bytes.write(to: events)
        chmod(root.path, 0o555) // no room for a preserved copy
        let restart = MetricHistoryStore(url: url)
        _ = await restart.load(now: now.addingTimeInterval(60))
        chmod(root.path, 0o755)
        let failure = await restart.loadFailure; XCTAssertNotNil(failure)
        XCTAssertEqual(try Data(contentsOf: events), bytes)
        XCTAssertTrue(try preservedCopies(in: root).isEmpty)
    }

    private func preservedCopies(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("history.json.events.damaged-") }
    }

    func testCheckpointBeforeOldJournalRemovalIsReplaySafe() async throws {
        let root = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json"), now = Date()
        let store = MetricHistoryStore(url: url)
        await store.appendPower(point(now, 50), now: now); try await store.flush(now: now)
        let minute = now.addingTimeInterval(60)
        await store.appendPower(point(minute, 51), now: minute); try await store.flush(now: minute)
        let events = url.appendingPathExtension("events"), oldLog = try Data(contentsOf: events)
        let later = now.addingTimeInterval(6 * 3600)
        await store.appendPower(point(later, 52), now: later); try await store.flush(now: later)
        XCTAssertTrue(try Data(contentsOf: events).isEmpty)
        // Simulate exit after durable checkpoint, before old log truncation.
        try oldLog.write(to: events)
        let snapshot = await MetricHistoryStore(url: url).load(now: later)
        XCTAssertEqual(snapshot.power.map(\.chargePercent), [50, 51, 52])
    }

    func testStaleProcessCannotOverwriteNewerHistory() async throws {
        let root = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json"), now = Date()
        let first = MetricHistoryStore(url: url)
        await first.appendPower(point(now, 50), now: now); try await first.flush(now: now)
        let stale = MetricHistoryStore(url: url); _ = await stale.load(now: now)
        let later = now.addingTimeInterval(60)
        await first.appendPower(point(later, 51), now: later); try await first.flush(now: later)
        let original = try Data(contentsOf: url.appendingPathExtension("events"))
        await stale.appendPower(point(later, 99), now: later)
        do { try await stale.flush(now: later); XCTFail("Stale writer must fail closed") } catch { }
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("events")), original)
        let restored = await MetricHistoryStore(url: url).load(now: later)
        XCTAssertEqual(restored.power.last?.chargePercent, 51)
    }

    func testLegacyImportNeverChangesSourceAndIsIdempotent() async throws {
        let root = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("legacy.json"), now = Date()
        let bytes = try JSONEncoder().encode(MetricHistorySnapshot(power: [point(now, 42)]))
        try bytes.write(to: legacy)
        let url = root.appendingPathComponent("Beta/history.json")
        let store = MetricHistoryStore(url: url, legacyMetricURL: legacy)
        _ = await store.load(now: now); try await store.flush(now: now)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        let restart = await MetricHistoryStore(url: url, legacyMetricURL: legacy).load(now: now)
        XCTAssertEqual(restart.power.count, 1)
        XCTAssertEqual(MetricHistoryStore.defaultURL?.deletingLastPathComponent().lastPathComponent, "Monitoring")
        XCTAssertNotEqual(MetricHistoryStore.defaultURL?.deletingLastPathComponent(), MenuBarPowerHistoryStore.legacyURL?.deletingLastPathComponent())
    }

    func testFailedAppendRetainsPreviousHistoryAndUnpersistedSample() async throws {
        let root = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json"), now = Date(), failure = JournalFailureSwitch()
        let store = MetricHistoryStore(url: url, beforeJournalWrite: { try failure.check() })
        await store.appendPower(point(now, 50), now: now); try await store.flush(now: now)
        failure.set(true)
        let later = now.addingTimeInterval(60)
        await store.appendPower(point(later, 51), now: later)
        do { try await store.flush(now: later); XCTFail("Injected disk-full must surface") } catch { }
        let durable = await MetricHistoryStore(url: url).load(now: later)
        XCTAssertEqual(durable.power.count, 1)
        let live = await store.load(now: later); XCTAssertEqual(live.power.count, 2)
        failure.set(false)
        try await store.flush(now: later.addingTimeInterval(31))
        let recovered = await MetricHistoryStore(url: url).load(now: later.addingTimeInterval(31))
        XCTAssertEqual(recovered.power.map(\.chargePercent), [50, 51])
    }
    private func fixture() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("MetricJournalFixture-\(UUID())") }
    private func point(_ date: Date, _ percent: Double) -> MenuBarPowerHistoryPoint {
        .init(date: date, chargePercent: percent, batteryPowerWatts: -4, isCharging: false, powerSource: .batteryPower)
    }
}
private final class JournalFailureSwitch: @unchecked Sendable {
    let lock = NSLock(); private var fails = false
    func set(_ value: Bool) { lock.withLock { fails = value } }
    func check() throws { if lock.withLock({ fails }) { throw CocoaError(.fileWriteOutOfSpace) } }
}
