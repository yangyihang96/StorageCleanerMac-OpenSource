import XCTest
@testable import StorageCleanerMac

final class MonitoringPersistencePolicyTests: XCTestCase {
    func testFailureBackoffIsBoundedAndSuccessResetsIt() {
        var schedule = MonitoringSaveSchedule()
        var now = Date(timeIntervalSince1970: 1_000)
        for delay in [30.0, 60, 120, 240, 300, 300] {
            XCTAssertTrue(schedule.begin(at: now, interval: 60, force: false))
            schedule.failed(at: now)
            XCTAssertEqual(schedule.nextRetry, now.addingTimeInterval(delay))
            XCTAssertFalse(schedule.begin(at: now.addingTimeInterval(delay - 1), interval: 60, force: true))
            XCTAssertNil(schedule.lastSuccess)
            now.addTimeInterval(delay)
        }
        XCTAssertTrue(schedule.begin(at: now, interval: 60, force: false))
        schedule.succeeded(at: now)
        XCTAssertEqual(schedule.failures, 0)
        XCTAssertNil(schedule.nextRetry)
        XCTAssertFalse(schedule.begin(at: now.addingTimeInterval(59), interval: 60, force: false))
    }

    func testRejectsOversizedFileAndSymlinkBeforeDecoding() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("oversized.json")
        try Data(repeating: 0, count: 4096).write(to: file)
        XCTAssertThrowsError(try BoundedMonitoringFile.read(file, maximumBytes: 16)) {
            XCTAssertEqual($0 as? MonitoringFileError, .oversized)
        }
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try BoundedMonitoringFile.read(link, maximumBytes: 8192))
        XCTAssertThrowsError(try BoundedMonitoringFile.read(root, maximumBytes: 8192))
    }

    func testDecodeRejectsExcessiveArrayCount() throws {
        let data = Data(("[" + Array(repeating: "1", count: 60_001).joined(separator: ",") + "]").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BoundedMonitoringArray<Int>.self, from: data))
    }

    func testCorruptHistorySurvivesNewSamplesAndFlush() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("history.json")
        let original = Data("{damaged".utf8)
        try original.write(to: file)
        let store = MetricHistoryStore(url: file)
        let now = Date()
        await store.appendPower(point(at: now), now: now)
        do { try await store.flush(now: now); XCTFail("Original must remain protected") }
        catch { XCTAssertEqual(error as? MetricHistoryStoreError, .preservedUnreadableHistory) }
        XCTAssertEqual(try Data(contentsOf: file), original)
        let current = await store.load(now: now)
        XCTAssertEqual(current.power.count, 1, "New observations remain usable in memory")
        let issue = await store.loadFailure
        XCTAssertNotNil(issue)
    }

    func testFailedWriterCoalescesSamplesWithoutRetryingEveryAppend() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetricHistoryStore(url: root.appendingPathComponent("history.json"), write: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        let now = Date(timeIntervalSince1970: 1_000)
        await store.appendPower(point(at: now), now: now)
        do { try await store.flush(now: now); XCTFail("Injected failure must surface") } catch {}
        for second in 1..<30 {
            let date = now.addingTimeInterval(Double(second))
            await store.appendPower(point(at: date), now: date)
        }
        var schedule = await store.saveSchedule
        XCTAssertEqual(schedule.lastAttempt, now)
        XCTAssertEqual(schedule.failures, 1)
        XCTAssertNil(schedule.lastSuccess)
        let next = now.addingTimeInterval(30)
        await store.appendPower(point(at: next), now: next)
        do { try await store.flush(now: next); XCTFail("Injected failure must surface") } catch {}
        schedule = await store.saveSchedule
        XCTAssertEqual(schedule.lastAttempt, next)
        XCTAssertEqual(schedule.failures, 2)
        let snapshot = await store.load(now: next)
        XCTAssertEqual(snapshot.power.count, 31)
    }

    func testSlowWriterDoesNotBlockNewHistoryOrQueueParallelWrites() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = HistoryWriteGate()
        defer { gate.release() }
        let started = expectation(description: "Writer started")
        let appended = expectation(description: "New samples accepted before disk completes")
        let store = MetricHistoryStore(url: root.appendingPathComponent("history.json"), write: { data, _ in
            gate.write(data) { started.fulfill() }
        })
        let now = Date(timeIntervalSince1970: 1_000)
        await store.appendPower(point(at: now), now: now)
        await fulfillment(of: [started], timeout: 2)
        let producer = Task {
            for second in 1...100 {
                let date = now.addingTimeInterval(Double(second))
                await store.appendPower(.init(date: date, chargePercent: 50,
                    batteryPowerWatts: -5, isCharging: false, powerSource: .batteryPower), now: date)
            }
            appended.fulfill()
        }
        await fulfillment(of: [appended], timeout: 2)
        let inFlight = await store.isSaveInFlight
        XCTAssertTrue(inFlight)
        XCTAssertEqual(gate.writeCount, 1)
        gate.release()
        await producer.value
        try await store.flush(now: now.addingTimeInterval(100))
        XCTAssertEqual(gate.maximumConcurrentWrites, 1)
        XCTAssertEqual(gate.writeCount, 2, "Only the in-flight and latest state are written")
        let last = try JSONDecoder().decode(MetricHistorySnapshot.self, from: XCTUnwrap(gate.lastData))
        XCTAssertEqual(last.power.count, 101, "Slow I/O cannot discard raw retained observations")
        let dirty = await store.isSaveInFlight
        XCTAssertFalse(dirty)
    }

    private func point(at date: Date) -> MenuBarPowerHistoryPoint {
        .init(date: date, chargePercent: 50, batteryPowerWatts: -5, isCharging: false, powerSource: .batteryPower)
    }
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MonitoringFixture-\(UUID().uuidString)")
    }
}

private final class HistoryWriteGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var count = 0
    private var active = 0
    private var maximum = 0
    private var data: Data?

    var writeCount: Int { condition.withLock { count } }
    var maximumConcurrentWrites: Int { condition.withLock { maximum } }
    var lastData: Data? { condition.withLock { data } }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
    func write(_ value: Data, started: () -> Void) {
        condition.lock()
        count += 1
        active += 1
        maximum = max(maximum, active)
        if count == 1 {
            started()
            while !released { condition.wait() }
        }
        data = value
        active -= 1
        condition.unlock()
    }
}
