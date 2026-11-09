import Darwin
import XCTest
@testable import StorageCleanerMac

/// D277 (11-04, found in the macOS 26.6.2 guest, relayed with the user's words
/// "交给执行会话"). Every `host_statistics64(HOST_VM_INFO64)` call passed the
/// SDK's whole `vm_statistics64` as its count: 104 `integer_t`s with the macOS
/// 27.2 SDK. That kernel knows 62 and logged "count is larger than expected" on
/// each call, about every 2 seconds. The readers now share one count, revision 1.
final class VMStatisticsCountD277Tests: XCTestCase {
    func testTheCountEndsWhereRevisionTwoStarts() {
        XCTAssertEqual(SystemMemoryProbe.vmStatisticsCount, 38)
    }

    /// Every counter the probe, the reclaimer and the M-series environment read
    /// lies inside the count, so none of them reads a field the kernel did not fill.
    func testEveryCounterTheReadersUseLiesInsideTheCount() throws {
        typealias S = vm_statistics64_data_t
        let end = Int(SystemMemoryProbe.vmStatisticsCount) * MemoryLayout<integer_t>.size
        let natural = MemoryLayout<natural_t>.size, wide = MemoryLayout<UInt64>.size
        let counters: [(String, PartialKeyPath<S>, Int)] = [
            ("free_count", \S.free_count, natural),
            ("active_count", \S.active_count, natural),
            ("inactive_count", \S.inactive_count, natural),
            ("wire_count", \S.wire_count, natural),
            ("purgeable_count", \S.purgeable_count, natural),
            ("speculative_count", \S.speculative_count, natural),
            ("swapins", \S.swapins, wide),
            ("swapouts", \S.swapouts, wide),
            ("compressor_page_count", \S.compressor_page_count, natural),
            ("external_page_count", \S.external_page_count, natural),
        ]
        for (name, path, size) in counters {
            let offset = try XCTUnwrap(MemoryLayout<S>.offset(of: path), name)
            XCTAssertLessThanOrEqual(offset + size, end, name)
        }
    }

    /// Read-only: the kernel takes the count and fills exactly revision 1.
    func testTheKernelFillsRevisionOne() {
        var stats = vm_statistics64()
        var count = SystemMemoryProbe.vmStatisticsCount
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        XCTAssertEqual(count, 38)
        XCTAssertGreaterThan(stats.wire_count, 0, "a real reading")
    }

    /// No call sizes the count from the whole struct again.
    func testEveryCallPassesTheSharedCount() throws {
        let calls = try SwiftSourceScanning.compactSourceCode().filter { $0.value.contains("host_statistics64(") }
        XCTAssertEqual(calls.keys.sorted(), [
            "Sources/StorageCleanerMac/Features/Memory/Infrastructure/MemoryReclaimer.swift",
            "Sources/StorageCleanerMac/Features/Memory/Infrastructure/SystemMemoryProbe.swift",
            "Sources/StorageCleanerMac/Services/Benchmark/MSeries/MSeriesProtocol.swift",
        ])
        for (path, code) in calls {
            XCTAssertTrue(code.contains("vmStatisticsCount"), path)
            for whole in ["MemoryLayout<vm_statistics64_data_t>.size", "MemoryLayout<vm_statistics64>.size"] {
                XCTAssertFalse(code.contains(whole), "\(path): \(whole)")
            }
        }
    }
}
