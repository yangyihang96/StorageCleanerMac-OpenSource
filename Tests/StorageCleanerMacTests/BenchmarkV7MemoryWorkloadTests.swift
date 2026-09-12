import Darwin
import Foundation
import XCTest

@testable import StorageCleanerMac

final class BenchmarkV7MemoryWorkloadTests: XCTestCase {
    func testProductionProfilesDeclare128And512MiBWorkingSets() {
        let configuration = BenchmarkV7MemoryWorkload.Configuration.standard

        XCTAssertEqual(
            configuration.limits(for: .quick)?.workingSetBytes,
            128 * 1_024 * 1_024
        )
        XCTAssertEqual(
            configuration.limits(for: .standard)?.workingSetBytes,
            512 * 1_024 * 1_024
        )
        XCTAssertNil(configuration.limits(for: .sustained))
    }

    func testUnsupportedPlanReportsExplicitWorkloadErrorWithoutAllocating() async {
        let allocator = TrackingV7MemoryAllocator()
        let workload = BenchmarkV7MemoryWorkload(
            configuration: .testing,
            allocator: allocator
        )

        do {
            _ = try await workload.run(planKind: .sustained)
            XCTFail("sustained 计划不应走独立 v7 内存 workload")
        } catch {
            XCTAssertEqual(
                error as? BenchmarkV7MemoryWorkloadError,
                .unsupportedPlan(.sustained)
            )
        }
        XCTAssertEqual(allocator.allocationCount, 0)
        XCTAssertEqual(allocator.liveAllocationCount, 0)
    }

    func testSmallInjectedWorkloadReturnsThreeUnitTaggedRawSampleSeries() async throws {
        let allocator = TrackingV7MemoryAllocator()
        let clock = SteppingV7MemoryClock(stepNanoseconds: 1_000_000)
        let workload = BenchmarkV7MemoryWorkload(
            configuration: .testing,
            allocator: allocator,
            clock: clock
        )

        let first = try await workload.run(planKind: .quick)
        let second = try await workload.run(planKind: .quick)

        XCTAssertEqual(first.workingSetBytes, 256 * 1_024)
        XCTAssertEqual(first.metrics.map(\.id), [
            .copyBandwidth,
            .triadBandwidth,
            .pointerChaseLatency,
        ])
        XCTAssertEqual(first.copyBandwidth.unit, "GB/s")
        XCTAssertEqual(first.triadBandwidth.unit, "GB/s")
        XCTAssertEqual(first.pointerChaseLatency.unit, "ns/access")
        XCTAssertEqual(first.copyBandwidth.direction, .higherIsBetter)
        XCTAssertEqual(first.triadBandwidth.direction, .higherIsBetter)
        XCTAssertEqual(first.pointerChaseLatency.direction, .lowerIsBetter)
        XCTAssertTrue(first.metrics.allSatisfy(\.isValid))
        XCTAssertTrue(first.metrics.allSatisfy { $0.samples.count == 2 })
        XCTAssertTrue(first.metrics.flatMap(\.samples).allSatisfy { $0.checksum != nil })
        XCTAssertEqual(
            first.metrics.map { $0.samples.compactMap(\.checksum) },
            second.metrics.map { $0.samples.compactMap(\.checksum) },
            "固定 seed 的校验值不能随计时器抖动"
        )
        XCTAssertGreaterThan(clock.callCount, 0)
        XCTAssertEqual(allocator.allocationCount, 2)
        XCTAssertEqual(allocator.deallocationCount, 2)
        XCTAssertEqual(allocator.liveAllocationCount, 0)
    }

    func testCancellationAfterAllocationReleasesWorkingSet() async throws {
        let allocator = BlockingV7MemoryAllocator()
        let workload = BenchmarkV7MemoryWorkload(
            configuration: .testing,
            allocator: allocator
        )
        let task = Task {
            try await workload.run(planKind: .quick)
        }

        guard allocator.waitForAllocation(timeout: 1) else {
            allocator.releaseAllocation()
            task.cancel()
            XCTFail("工作负载没有进入可取消的已分配状态")
            return
        }
        task.cancel()
        allocator.releaseAllocation()

        do {
            _ = try await task.value
            XCTFail("取消后不应返回 v7 内存跑分结果")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("预期 CancellationError，实际为 \(error)")
        }
        XCTAssertEqual(allocator.allocationCount, allocator.deallocationCount)
        XCTAssertEqual(allocator.liveAllocationCount, 0)
    }
}

private final class TrackingV7MemoryAllocator: BenchmarkV7MemoryAllocating, @unchecked Sendable {
    private let lock = NSLock()
    private var allocations = 0
    private var deallocations = 0
    private var liveAllocations = 0

    var allocationCount: Int { lock.withLock { allocations } }
    var deallocationCount: Int { lock.withLock { deallocations } }
    var liveAllocationCount: Int { lock.withLock { liveAllocations } }

    func allocate(byteCount: Int, alignment: Int) throws -> UnsafeMutableRawPointer {
        var pointer: UnsafeMutableRawPointer?
        guard posix_memalign(&pointer, alignment, byteCount) == 0, let pointer else {
            throw BenchmarkV7MemoryWorkloadError.unavailable
        }
        lock.withLock {
            allocations += 1
            liveAllocations += 1
        }
        return pointer
    }

    func deallocate(_ pointer: UnsafeMutableRawPointer) {
        free(pointer)
        lock.withLock {
            deallocations += 1
            liveAllocations -= 1
        }
    }
}

private final class BlockingV7MemoryAllocator: BenchmarkV7MemoryAllocating, @unchecked Sendable {
    private let lock = NSLock()
    private let didAllocate = DispatchSemaphore(value: 0)
    private let mayReturn = DispatchSemaphore(value: 0)
    private var allocations = 0
    private var deallocations = 0
    private var liveAllocations = 0

    var allocationCount: Int { lock.withLock { allocations } }
    var deallocationCount: Int { lock.withLock { deallocations } }
    var liveAllocationCount: Int { lock.withLock { liveAllocations } }

    func allocate(byteCount: Int, alignment: Int) throws -> UnsafeMutableRawPointer {
        var pointer: UnsafeMutableRawPointer?
        guard posix_memalign(&pointer, alignment, byteCount) == 0, let pointer else {
            throw BenchmarkV7MemoryWorkloadError.unavailable
        }
        lock.withLock {
            allocations += 1
            liveAllocations += 1
        }
        didAllocate.signal()
        _ = mayReturn.wait(timeout: .now() + 5)
        return pointer
    }

    func deallocate(_ pointer: UnsafeMutableRawPointer) {
        free(pointer)
        lock.withLock {
            deallocations += 1
            liveAllocations -= 1
        }
    }

    func waitForAllocation(timeout: TimeInterval) -> Bool {
        didAllocate.wait(timeout: .now() + timeout) == .success
    }

    func releaseAllocation() {
        mayReturn.signal()
    }
}

private final class SteppingV7MemoryClock: BenchmarkV7MemoryClock, @unchecked Sendable {
    private let lock = NSLock()
    private let stepNanoseconds: UInt64
    private var current: UInt64 = 0
    private var calls = 0

    init(stepNanoseconds: UInt64) {
        self.stepNanoseconds = stepNanoseconds
    }

    var callCount: Int { lock.withLock { calls } }

    func nowNanoseconds() -> UInt64 {
        lock.withLock {
            current &+= stepNanoseconds
            calls += 1
            return current
        }
    }
}
