import XCTest
@testable import StorageCleanerMac

/// D144: the bounded push behind "释放内存", with the system calls replaced
/// (no memory is allocated, filled or released here).
final class MemoryReclaimerTests: XCTestCase {
    private static let gib: UInt64 = 1 << 30
    private static let mib: UInt64 = 1 << 20

    private final class FakeSystem: @unchecked Sendable {
        var readings: [MemoryReclaimer.Reading?]
        var allocations = 0
        var releases = 0
        var fills = 0
        var relieved = 0
        var failAllocationAfter: Int?

        init(readings: [MemoryReclaimer.Reading?]) { self.readings = readings }

        var environment: MemoryReclaimer.Environment {
            MemoryReclaimer.Environment(
                read: { [self] in readings.count > 1 ? readings.removeFirst() : readings.first ?? nil },
                allocate: { [self] _ in
                    if let limit = failAllocationAfter, allocations >= limit { return nil }
                    allocations += 1
                    return UnsafeMutableRawPointer(bitPattern: 0x10_000 * allocations)
                },
                fill: { [self] _, _ in fills += 1 },
                release: { [self] _, _ in releases += 1 },
                relieveMallocZones: { [self] in relieved += 1 },
                now: { Date() },
                settle: {})
        }
    }

    private static func reading(free: UInt64 = 2 * gib, inactive: UInt64 = 6 * gib, fileBacked: UInt64 = 4 * gib,
                                purgeable: UInt64 = gib / 2, compressed: UInt64 = gib,
                                pressure: Int32? = 1, physical: UInt64 = 16 * gib) -> MemoryReclaimer.Reading {
        MemoryReclaimer.Reading(physicalBytes: physical, freeBytes: free, speculativeBytes: gib / 2,
                                inactiveBytes: inactive, fileBackedBytes: fileBacked, purgeableBytes: purgeable,
                                compressedBytes: compressed, pressureLevelCode: pressure)
    }

    func testBudgetIsTheDroppableMemoryLessHeadroomAndAtMostHalfTheRAM() {
        // free 2 + speculative 0.5 + purgeable 0.5 + min(file 4, inactive 6) − 1 GiB headroom.
        XCTAssertEqual(MemoryReclaimer.budget(for: Self.reading()), 6 * Self.gib)
        XCTAssertEqual(MemoryReclaimer.budget(for: Self.reading(physical: 8 * Self.gib)), 4 * Self.gib)
        XCTAssertEqual(MemoryReclaimer.budget(for: Self.reading(inactive: Self.gib)), 3 * Self.gib,
                       "only inactive file pages count as cache that can be dropped")
        XCTAssertEqual(MemoryReclaimer.budget(for: Self.reading(free: 0, inactive: 0, fileBacked: 0, purgeable: 0)), 0,
                       "under one step nothing is pushed")
    }

    func testRaisedPressureRefusesWithoutAllocating() throws {
        let system = FakeSystem(readings: [Self.reading(pressure: 2)])
        let outcome = try XCTUnwrap(MemoryReclaimer.run(environment: system.environment, isCancelled: { false }))
        XCTAssertEqual(outcome.stopReason, .pressureAlreadyRaised)
        XCTAssertEqual(outcome.pushedBytes, 0)
        XCTAssertEqual(system.allocations, 0)
        XCTAssertEqual(MemoryOptimizerService.reclaimStatus(outcome), .notNeeded)
    }

    func testPushStopsWhenTheCompressorGrowsTwiceInARowAndReturnsEverything() throws {
        let before = Self.reading()
        let system = FakeSystem(readings: [
            before,
            Self.reading(compressed: Self.gib + 64 * Self.mib),
            Self.reading(compressed: Self.gib + 128 * Self.mib),
            Self.reading(free: 3 * Self.gib, compressed: Self.gib + 128 * Self.mib)
        ])
        let outcome = try XCTUnwrap(MemoryReclaimer.run(environment: system.environment, isCancelled: { false }))
        XCTAssertEqual(outcome.stopReason, .compressorGrowing)
        XCTAssertEqual(system.allocations, 2)
        XCTAssertEqual(system.fills, 2, "every page is written so the push cannot be compressed away")
        XCTAssertEqual(system.releases, system.allocations)
        XCTAssertEqual(system.relieved, 1)
        XCTAssertEqual(outcome.pushedBytes, 2 * MemoryReclaimer.stepBytes)
        XCTAssertEqual(outcome.idleDeltaBytes, Int64(Self.gib), "measured from the readings, not from the push")
        XCTAssertEqual(MemoryOptimizerService.reclaimStatus(outcome), .completed)
    }

    func testOneGrowingStepAloneDoesNotStopThePush() throws {
        let system = FakeSystem(readings: [
            Self.reading(free: 0, inactive: 2 * Self.gib, fileBacked: 2 * Self.gib, purgeable: 0, physical: 64 * Self.gib),
            Self.reading(compressed: Self.gib + 64 * Self.mib),
            Self.reading(compressed: Self.gib + 64 * Self.mib),
            Self.reading(compressed: Self.gib + 64 * Self.mib)
        ])
        // Budget: speculative 0.5 + min(2, 2) − 1 = 1.5 GiB → six steps.
        let outcome = try XCTUnwrap(MemoryReclaimer.run(environment: system.environment, isCancelled: { false }))
        XCTAssertEqual(outcome.stopReason, .finished)
        XCTAssertEqual(system.allocations, 6)
        XCTAssertEqual(system.releases, 6)
    }

    func testPushStopsAtOnceWhenPressureLeavesNormal() throws {
        let system = FakeSystem(readings: [Self.reading(), Self.reading(pressure: 2), Self.reading()])
        let outcome = try XCTUnwrap(MemoryReclaimer.run(environment: system.environment, isCancelled: { false }))
        XCTAssertEqual(outcome.stopReason, .pressureRose)
        XCTAssertEqual(system.allocations, 1)
        XCTAssertEqual(system.releases, 1)
    }

    func testFailedAllocationAndCancellationStopAndRelease() throws {
        let failing = FakeSystem(readings: [Self.reading()])
        failing.failAllocationAfter = 3
        let failed = try XCTUnwrap(MemoryReclaimer.run(environment: failing.environment, isCancelled: { false }))
        XCTAssertEqual(failed.stopReason, .allocationFailed)
        XCTAssertEqual(failing.releases, 3)
        XCTAssertEqual(MemoryOptimizerService.reclaimStatus(failed), .partial)

        let cancelling = FakeSystem(readings: [Self.reading()])
        let cancelled = try XCTUnwrap(MemoryReclaimer.run(environment: cancelling.environment, isCancelled: { true }))
        XCTAssertEqual(cancelled.stopReason, .cancelled)
        XCTAssertEqual(cancelling.allocations, 0)
        XCTAssertEqual(MemoryOptimizerService.reclaimStatus(cancelled), .cancelled)
    }

    /// One real push on this Mac, only when asked for with
    /// `STORAGE_CLEANER_LIVE_MEMORY_RECLAIM=1`; it prints what it measured.
    func testLivePushOnThisMacReportsMeasuredCounters() throws {
        guard ProcessInfo.processInfo.environment["STORAGE_CLEANER_LIVE_MEMORY_RECLAIM"] == "1" else {
            throw XCTSkip("Runs only with STORAGE_CLEANER_LIVE_MEMORY_RECLAIM=1.")
        }
        let outcome = try XCTUnwrap(MemoryReclaimer.run(isCancelled: { false }))
        let after = try XCTUnwrap(outcome.after, "the counters are read again after the push")
        func gib(_ bytes: UInt64) -> String { String(format: "%.2f GiB", Double(bytes) / Double(Self.gib)) }
        print("LIVE reason=\(outcome.stopReason.rawValue) budget=\(gib(outcome.budgetBytes)) pushed=\(gib(outcome.pushedBytes))"
            + " duration=\(String(format: "%.1f", outcome.duration))s")
        print("LIVE idle \(gib(outcome.before.idleBytes)) -> \(gib(after.idleBytes));"
            + " cache \(gib(outcome.before.cacheBytes)) -> \(gib(after.cacheBytes));"
            + " compressed \(gib(outcome.before.compressedBytes)) -> \(gib(after.compressedBytes));"
            + " pressure \(outcome.before.pressureLevelCode.map(String.init) ?? "?") -> \(after.pressureLevelCode.map(String.init) ?? "?")")
        XCTAssertLessThanOrEqual(outcome.pushedBytes, outcome.budgetBytes)
        XCTAssertLessThanOrEqual(outcome.budgetBytes, outcome.before.physicalBytes / 2)
    }

    func testUnreadableStatisticsDoNothing() {
        let system = FakeSystem(readings: [nil])
        XCTAssertNil(MemoryReclaimer.run(environment: system.environment, isCancelled: { false }))
        XCTAssertEqual(system.allocations, 0)
        XCTAssertEqual(MemoryOptimizerService.reclaimStatus(nil), .unavailable)
    }

    func testMessagesReportMeasuredIdleMemoryAndNeverAFreedTotal() throws {
        let before = Self.reading()
        let gained = MemoryReclaimer.Outcome(before: before, after: Self.reading(free: 3 * Self.gib),
                                             budgetBytes: 6 * Self.gib, pushedBytes: 6 * Self.gib,
                                             stopReason: .finished, duration: 1.2)
        // D178: memory as Activity Monitor writes it, "1 GB" (was `ByteFormat.string`: "1.0 GiB").
        XCTAssertEqual(ScanStore.memoryReclaimMessage(gained),
                       L10n.text("空闲内存增加 \(ByteFormat.memoryString(Int64(Self.gib)))",
                                 "Idle memory up by \(ByteFormat.memoryString(Int64(Self.gib)))"))
        let flat = MemoryReclaimer.Outcome(before: before, after: before, budgetBytes: 6 * Self.gib,
                                           pushedBytes: 6 * Self.gib, stopReason: .finished, duration: 1)
        XCTAssertFalse(ScanStore.memoryReclaimMessage(flat).contains(L10n.text("增加", "up by")))
        for reason in [MemoryReclaimer.StopReason.finished, .compressorGrowing, .pressureRose, .allocationFailed,
                       .timedOut, .readingUnavailable, .cancelled, .nothingToReclaim, .pressureAlreadyRaised] {
            let outcome = MemoryReclaimer.Outcome(before: before, after: before, budgetBytes: 0, pushedBytes: 0,
                                                  stopReason: reason, duration: 0)
            let detail = MemoryOptimizerService.reclaimDetail(outcome)
            XCTAssertFalse(detail.contains("已释放"), "\(reason): D93 wording")
            XCTAssertFalse(detail.lowercased().contains("freed"), "\(reason)")
        }
    }
}
