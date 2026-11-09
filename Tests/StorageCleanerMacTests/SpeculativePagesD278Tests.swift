import Darwin
import XCTest
@testable import StorageCleanerMac

/// D278 (11-05, the user's "在这里修"). `free_count` already holds the
/// speculative pages (mach/vm_statistics.h; vm_stat prints "Pages free" as
/// `free_count - speculative_count`), and `external_page_count` holds them
/// too, as file pages read ahead. The memory page added them to free once
/// more, so its available estimate (free plus the file cache) held them three
/// times, and the release reading and budget held them up to three times. Each
/// page now counts once. The counters here are made up; nothing reads the kernel.
final class SpeculativePagesD278Tests: XCTestCase {
    private static let page: UInt64 = 16_384
    private static let gib: UInt64 = 1 << 30

    private static func statistics(free: natural_t = 100_000, speculative: natural_t = 30_000) -> vm_statistics64 {
        var stats = vm_statistics64()
        stats.free_count = free
        stats.speculative_count = speculative
        stats.active_count = 400_000
        stats.inactive_count = 300_000
        stats.external_page_count = 200_000
        stats.internal_page_count = 530_000
        stats.purgeable_count = 10_000
        stats.wire_count = 150_000
        stats.compressor_page_count = 50_000
        return stats
    }

    func testPagesFreeLeavesTheSpeculativePagesOutAsVMStatDoes() {
        let readings = SystemMemoryProbe.pageReadings(statistics: Self.statistics(), pageSize: Self.page)
        XCTAssertEqual(readings.pageSize, Self.page)
        XCTAssertEqual(readings.values["Pages free"], 70_000)
        XCTAssertEqual(readings.values["Pages speculative"], 30_000)
        XCTAssertEqual(readings.values["File-backed pages"], 200_000, "the speculative pages stay in the file cache")
        let crossed = SystemMemoryProbe.pageReadings(statistics: Self.statistics(free: 10, speculative: 30), pageSize: Self.page)
        XCTAssertEqual(crossed.values["Pages free"], 0, "never wraps when speculative exceeds free_count")
    }

    func testTheMemoryPageCountsEachPageOnce() async {
        let readings = SystemMemoryProbe.pageReadings(statistics: Self.statistics(), pageSize: Self.page)
        let probe = SystemMemoryProbe(systemPressureLevelCode: { 1 }, pageReadings: { readings })
        let snapshot = await probe.snapshot(includeProcesses: false, includePressureReading: false)
        let page = Int64(Self.page)
        XCTAssertEqual(snapshot.freeBytes, 70_000 * page)
        XCTAssertEqual(snapshot.speculativeBytes, 30_000 * page)
        XCTAssertEqual(snapshot.fileBackedBytes, 200_000 * page)
        // Free 70k + max(file-backed 200k, purgeable 10k): the 30k speculative pages once.
        XCTAssertEqual(snapshot.measurements.cachedBytes.value, 200_000 * Self.page)
        XCTAssertEqual(snapshot.measurements.availableBytes.value, 270_000 * Self.page)
        XCTAssertEqual(snapshot.availableBytes, 270_000 * page)
    }

    func testTheReleaseReadingsIdleIsFreeCount() {
        let reading = MemoryReclaimer.Reading(statistics: Self.statistics(), pageSize: Self.page,
                                              physicalBytes: 64 * Self.gib, pressureLevelCode: 1)
        XCTAssertEqual(reading.freeBytes, 70_000 * Self.page)
        XCTAssertEqual(reading.speculativeBytes, 30_000 * Self.page)
        XCTAssertEqual(reading.idleBytes, 100_000 * Self.page, "free plus speculative, once")
        XCTAssertEqual(reading.cacheBytes, 200_000 * Self.page)
        XCTAssertEqual(reading.inactiveBytes, 300_000 * Self.page)
        XCTAssertEqual(reading.compressedBytes, 50_000 * Self.page)
        XCTAssertEqual(reading.physicalBytes, 64 * Self.gib)
        XCTAssertEqual(reading.pressureLevelCode, 1)
    }

    func testTheBudgetCountsTheSpeculativePagesOnce() {
        var reading = MemoryReclaimer.Reading(
            physicalBytes: 64 * Self.gib, freeBytes: Self.gib, speculativeBytes: Self.gib / 2,
            inactiveBytes: 4 * Self.gib, fileBackedBytes: 2 * Self.gib, purgeableBytes: 0,
            compressedBytes: 0, pressureLevelCode: 1)
        // free 1 + speculative 0.5 + min(file 2 − speculative 0.5, inactive 4) − 1 GiB headroom.
        XCTAssertEqual(MemoryReclaimer.budget(for: reading), 2 * Self.gib)
        reading.fileBackedBytes = Self.gib / 4
        XCTAssertEqual(MemoryReclaimer.budget(for: reading), Self.gib / 2,
                       "never wraps when a reading shows fewer file pages than speculative ones")
    }

    func testTheCareStudioReadingTakesTheSnapshotsFreeAsItIs() {
        let snapshot = MemorySnapshot(
            generatedAt: Date(timeIntervalSince1970: 0), physicalBytes: Int64(16 * Self.gib),
            freeBytes: Int64(Self.gib), inactiveBytes: Int64(3 * Self.gib), speculativeBytes: Int64(Self.gib / 4),
            fileBackedBytes: Int64(4 * Self.gib), purgeableBytes: 0, wiredBytes: Int64(2 * Self.gib),
            compressedBytes: Int64(Self.gib), swapUsedBytes: 0, pressureFreePercentage: nil,
            pressureSummary: "", topProcesses: [])
        let reading = MemoryReclaimer.Reading(snapshot: snapshot)
        XCTAssertEqual(reading.freeBytes, Self.gib)
        XCTAssertEqual(reading.idleBytes, Self.gib + Self.gib / 4)
        XCTAssertEqual(reading.cacheBytes, 4 * Self.gib)
    }
}
