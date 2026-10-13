import Darwin
import XCTest
@testable import StorageCleanerMac

/// The memory page's "换入（累计）/换出（累计）" rows showed vm_statistics64's
/// pageins / pageouts (requests to any pager, mostly file-backed reads, and
/// file-backed pages written back) as bare counts. They now show what their
/// title says: the data read back from / written to the swap files (vm_stat's
/// Swapins / Swapouts, counted in pages) as bytes.
final class MiniWindowMemorySwapActivityTests: XCTestCase {
    func testSwapPageCountsConvertToBytesAndStayUnknownWithoutAReading() {
        XCTAssertEqual(SystemMemoryProbe.swapActivityBytes(pages: 100, pageSize: 16_384), 1_638_400)
        XCTAssertEqual(SystemMemoryProbe.swapActivityBytes(pages: 0, pageSize: 16_384), 0,
                       "a Mac that never swapped reports a real zero")
        XCTAssertNil(SystemMemoryProbe.swapActivityBytes(pages: nil, pageSize: 16_384),
                     "no VM statistics: unknown, not zero")
        XCTAssertNil(SystemMemoryProbe.swapActivityBytes(pages: 100, pageSize: nil))
        XCTAssertEqual(SystemMemoryProbe.swapActivityBytes(pages: .max, pageSize: 16_384), .max,
                       "an overflow clamps instead of wrapping")
    }

    /// Read-only: compares the probe with the kernel's own counters.
    func testProbeReportsTheKernelSwapCountersNotThePagingCounters() async throws {
        let before = try Self.vmStatistics()
        let snapshot = await SystemMemoryProbe().snapshot(includeProcesses: false, includePressureReading: false)
        let after = try Self.vmStatistics()
        let pageSize = Int64(before.pageSize)

        let swappedIn = try XCTUnwrap(snapshot.swappedInBytes)
        let swappedOut = try XCTUnwrap(snapshot.swappedOutBytes)
        XCTAssertEqual(swappedIn % pageSize, 0)
        XCTAssertEqual(swappedOut % pageSize, 0)
        XCTAssertGreaterThanOrEqual(swappedIn, Int64(clamping: before.swapins) * pageSize)
        XCTAssertLessThanOrEqual(swappedIn, Int64(clamping: after.swapins) * pageSize)
        XCTAssertGreaterThanOrEqual(swappedOut, Int64(clamping: before.swapouts) * pageSize)
        XCTAssertLessThanOrEqual(swappedOut, Int64(clamping: after.swapouts) * pageSize)
    }

    @MainActor
    func testRowsNameSwapAndShowBytesWithAUnit() {
        // 1 GiB read back, 3.5 GiB written: unlike any page-in count.
        let swappedIn: Int64 = 1 * 1_024 * 1_024 * 1_024
        let swappedOut: Int64 = 3_758_096_384
        let chinese = MiniWindowLogicLanguageScope(.zhHans)
        var rows = GeekMemorySwapActivity.rows(swappedInBytes: swappedIn, swappedOutBytes: swappedOut)
        XCTAssertEqual(rows.map(\.title), ["换入（累计）", "换出（累计）"])
        XCTAssertEqual(rows.map(\.value), [ByteFormat.string(swappedIn), ByteFormat.string(swappedOut)])
        XCTAssertEqual(rows.map(\.value), ["1.0 GiB", "3.5 GiB"])
        for row in rows {
            XCTAssertTrue(row.help.contains("交换文件"), row.help)
            XCTAssertTrue(row.help.contains("页大小"), "the page-size conversion is stated: \(row.help)")
            XCTAssertTrue(row.help.contains("压缩"), row.help)
        }
        XCTAssertTrue(rows[0].help.contains("读回"))
        XCTAssertTrue(rows[1].help.contains("写入"))

        rows = GeekMemorySwapActivity.rows(swappedInBytes: 0, swappedOutBytes: nil)
        XCTAssertEqual(rows.map(\.value), ["0 B", "—"], "zero is a reading; a missing reading is a dash")
        XCTAssertTrue(rows[1].help.contains("未能读取"), rows[1].help)
        chinese.restore()

        let english = MiniWindowLogicLanguageScope(.english)
        rows = GeekMemorySwapActivity.rows(swappedInBytes: swappedIn, swappedOutBytes: swappedOut)
        XCTAssertEqual(rows.map(\.title), ["Swapped In (Total)", "Swapped Out (Total)"])
        XCTAssertTrue(rows[0].help.contains("swap files"))
        XCTAssertTrue(rows[0].help.contains("page size"))
        english.restore()
    }

    func testMemoryPageShowsTheSwapRowsAndNoPagingCounters() throws {
        let view = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift")
        let card = try MiniWindowLogicFixtures.section(
            view, from: "private var geekMemoryPagesCard: some View {", to: "private var geekMemorySwapCard")
        XCTAssertTrue(card.contains("GeekMemorySwapActivity.rows("))
        XCTAssertTrue(card.contains("swappedInBytes: snapshot.swappedInBytes"))
        XCTAssertTrue(card.contains(".help(row.help)"))
        XCTAssertTrue(card.contains(".accessibilityHint(row.help)"))
        for removed in ["pageInsCount", "pageOutsCount", "compactPageCount", "Page Ins", "Page Outs"] {
            XCTAssertFalse(view.contains(removed), "\(removed) is not a swap figure")
        }
        let probe = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Features/Memory/Infrastructure/SystemMemoryProbe.swift")
        XCTAssertTrue(probe.contains("swappedInBytes: Self.swapActivityBytes(pages: pageReadings?.values[\"Swapins\"]"))
        XCTAssertTrue(probe.contains("swappedOutBytes: Self.swapActivityBytes(pages: pageReadings?.values[\"Swapouts\"]"))
    }

    private static func vmStatistics() throws -> (swapins: UInt64, swapouts: UInt64, pageSize: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        var pageSize: vm_size_t = 0
        XCTAssertEqual(host_page_size(mach_host_self(), &pageSize), KERN_SUCCESS)
        return (UInt64(stats.swapins), UInt64(stats.swapouts), UInt64(pageSize))
    }
}
