import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacBenchmarkKernelTests: XCTestCase {
    func testCPUChecksumIsRepeatableForFixedSeed() async throws {
        let kernel = CPUBenchmarkKernel(configuration: .testing)

        let firstSingle = try await kernel.runSingle(profile: .quick)
        let secondSingle = try await kernel.runSingle(profile: .quick)
        XCTAssertEqual(firstSingle.sample.checksum, secondSingle.sample.checksum)
        XCTAssertEqual(firstSingle.operationCount, secondSingle.operationCount)

        let firstMulti = try await kernel.runMulti(
            profile: .quick,
            activeProcessorCount: 4
        )
        let secondMulti = try await kernel.runMulti(
            profile: .quick,
            activeProcessorCount: 4
        )
        XCTAssertEqual(firstMulti.sample.checksum, secondMulti.sample.checksum)
        XCTAssertEqual(firstMulti.operationCount, secondMulti.operationCount)
    }

    func testTestingWorkloadGoldenChecksumsPreventSilentBaselineDrift() async throws {
        let cpu = CPUBenchmarkKernel(configuration: .testing)
        let memory = MemoryBenchmarkKernel(configuration: .testing)
        let quickSingle = try await cpu.runSingle(profile: .quick)
        let quickMultiOne = try await cpu.runMulti(
            profile: .quick,
            activeProcessorCount: 1
        )
        let quickMultiFour = try await cpu.runMulti(
            profile: .quick,
            activeProcessorCount: 4
        )
        let quickMemory = try await memory.run(profile: .quick)
        let fullSingle = try await cpu.runSingle(profile: .full)
        let fullMultiOne = try await cpu.runMulti(
            profile: .full,
            activeProcessorCount: 1
        )
        let fullMultiFour = try await cpu.runMulti(
            profile: .full,
            activeProcessorCount: 4
        )
        let fullMemory = try await memory.run(profile: .full)

        XCTAssertEqual(quickSingle.sample.checksum, 10_146_440_459_600_736_323)
        XCTAssertEqual(quickMultiOne.sample.checksum, 4_256_289_723_909_816_940)
        XCTAssertEqual(quickMultiFour.sample.checksum, 1_610_267_209_792_995_621)
        XCTAssertEqual(quickMemory.sample.checksum, 3_801_174_294_099_444_008)
        XCTAssertEqual(fullSingle.sample.checksum, 5_519_952_010_790_022_009)
        XCTAssertEqual(fullMultiOne.sample.checksum, 16_343_230_955_865_674_105)
        XCTAssertEqual(fullMultiFour.sample.checksum, 9_198_201_133_509_007_347)
        XCTAssertEqual(fullMemory.sample.checksum, 6_847_585_153_541_089_418)
    }

    func testCPUExecutionWidthReservesOneLogicalProcessor() async throws {
        let kernel = CPUBenchmarkKernel(configuration: .testing)

        let single = try await kernel.runSingle(profile: .quick)
        XCTAssertEqual(single.workerCount, 1)

        let oneProcessor = try await kernel.runMulti(
            profile: .quick,
            activeProcessorCount: 1
        )
        XCTAssertEqual(oneProcessor.workerCount, 1)

        let twelveProcessors = try await kernel.runMulti(
            profile: .quick,
            activeProcessorCount: 12
        )
        XCTAssertEqual(twelveProcessors.workerCount, 11)
        XCTAssertEqual(CPUBenchmarkKernel.workerCount(activeProcessorCount: 12), 11)
    }

    func testCPUProfilesHaveHardWorkAndTimeLimits() throws {
        let configuration = CPUBenchmarkKernel.Configuration.standard
        let quick = configuration.limits(for: .quick)
        let full = configuration.limits(for: .full)

        XCTAssertGreaterThan(quick.operationCount, 0)
        XCTAssertLessThanOrEqual(
            quick.operationCount,
            CPUBenchmarkKernel.maximumQuickOperationCount
        )
        XCTAssertLessThanOrEqual(
            full.operationCount,
            CPUBenchmarkKernel.maximumFullOperationCount
        )
        XCTAssertLessThanOrEqual(
            quick.maximumElapsedSeconds,
            CPUBenchmarkKernel.maximumQuickElapsedSeconds
        )
        XCTAssertLessThanOrEqual(
            full.maximumElapsedSeconds,
            CPUBenchmarkKernel.maximumFullElapsedSeconds
        )
        XCTAssertLessThanOrEqual(quick.chunkSize, 65_536)
        XCTAssertLessThanOrEqual(full.chunkSize, 65_536)
        XCTAssertEqual(quick.operationCount, 96_000_000)
        XCTAssertEqual(full.operationCount, 384_000_000)
        XCTAssertEqual(quick.multiOperationCountPerWorker, 768_000_000)
        XCTAssertEqual(full.multiOperationCountPerWorker, 1_024_000_000)
        XCTAssertEqual(quick.warmupOperationCount, 32_000_000)
        XCTAssertEqual(full.warmupOperationCount, 64_000_000)
        XCTAssertEqual(quick.multiWarmupOperationCount, 128_000_000)
        XCTAssertEqual(full.multiWarmupOperationCount, 256_000_000)
    }

    func testCPURejectsMoreThanAbsoluteWorkerLimit() async {
        let kernel = CPUBenchmarkKernel(configuration: .testing)

        await XCTAssertThrowsErrorAsync(
            try await kernel.runMulti(
                profile: .quick,
                activeProcessorCount: CPUBenchmarkKernel.maximumWorkerCount + 2
            )
        ) { error in
            XCTAssertEqual(error as? BenchmarkKernelError, .resourceLimit)
        }
    }

    func testCPURejectsConfigurationBeyondAbsoluteWorkLimit() async {
        let excessive = CPUBenchmarkKernel.Limits(
            operationCount: CPUBenchmarkKernel.maximumQuickOperationCount + 1,
            chunkSize: 1_024,
            maximumElapsedSeconds: 1
        )
        let kernel = CPUBenchmarkKernel(
            configuration: .init(quick: excessive, full: excessive)
        )

        await XCTAssertThrowsErrorAsync(try await kernel.runSingle(profile: .quick)) {
            XCTAssertEqual($0 as? BenchmarkKernelError, .resourceLimit)
        }
    }

    func testCPUSafetyDeadlineIncludesInputPreparation() async {
        let limits = CPUBenchmarkKernel.Limits(
            operationCount: 1_024,
            chunkSize: 64,
            maximumElapsedSeconds: .leastNonzeroMagnitude
        )
        let kernel = CPUBenchmarkKernel(
            configuration: .init(quick: limits, full: limits)
        )

        await XCTAssertThrowsErrorAsync(try await kernel.runSingle(profile: .quick)) {
            XCTAssertEqual($0 as? BenchmarkKernelError, .resourceLimit)
        }
    }

    func testCPUCancellationStopsAtABoundedChunkBoundary() async throws {
        let limits = CPUBenchmarkKernel.Limits(
            operationCount: CPUBenchmarkKernel.maximumFullOperationCount,
            chunkSize: 256,
            maximumElapsedSeconds: CPUBenchmarkKernel.maximumFullElapsedSeconds
        )
        let kernel = CPUBenchmarkKernel(
            configuration: .init(quick: limits, full: limits)
        )
        let task = Task {
            try await kernel.runSingle(profile: .full)
        }

        try await Task.sleep(for: .milliseconds(2))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消后不应返回 CPU 跑分结果")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("预期 CancellationError，实际为 \(error)")
        }
    }

    func testCPUMultiCancellationReleasesWorkersWaitingAtStartGate() async throws {
        let limits = CPUBenchmarkKernel.Limits(
            operationCount: CPUBenchmarkKernel.maximumFullOperationCount,
            warmupOperationCount: CPUBenchmarkKernel.maximumWarmupOperationCount,
            chunkSize: 256,
            maximumElapsedSeconds: CPUBenchmarkKernel.maximumFullElapsedSeconds
        )
        let kernel = CPUBenchmarkKernel(
            configuration: .init(quick: limits, full: limits)
        )
        let task = Task {
            try await kernel.runMulti(profile: .full, activeProcessorCount: 8)
        }

        try await Task.sleep(for: .milliseconds(2))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消后不应返回多核跑分结果")
        } catch is CancellationError {
            // Expected. The gate must resume every waiting worker.
        } catch {
            XCTFail("预期 CancellationError，实际为 \(error)")
        }
    }

    func testMemoryProfilesUseDistinct64And192MiBWorkingSets() {
        let configuration = MemoryBenchmarkKernel.Configuration.standard
        let quick = configuration.limits(for: .quick)
        let full = configuration.limits(for: .full)

        XCTAssertGreaterThan(quick.totalAllocatedBytes, 0)
        XCTAssertLessThanOrEqual(
            quick.totalAllocatedBytes,
            MemoryBenchmarkKernel.maximumQuickAllocatedBytes
        )
        XCTAssertLessThanOrEqual(quick.totalAllocatedBytes, 64 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(
            full.totalAllocatedBytes,
            MemoryBenchmarkKernel.maximumFullAllocatedBytes
        )
        XCTAssertEqual(quick.totalAllocatedBytes, 64 * 1_024 * 1_024)
        XCTAssertEqual(full.totalAllocatedBytes, 192 * 1_024 * 1_024)
        XCTAssertEqual(quick.passCount, 384)
        XCTAssertEqual(full.passCount, 512)
        XCTAssertLessThanOrEqual(
            quick.passCount,
            MemoryBenchmarkKernel.maximumQuickPassCount
        )
        XCTAssertLessThanOrEqual(
            full.passCount,
            MemoryBenchmarkKernel.maximumFullPassCount
        )
        XCTAssertLessThanOrEqual(quick.copyChunkBytes, 1 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(full.copyChunkBytes, 1 * 1_024 * 1_024)
    }

    func testMemoryChecksumIsRepeatableAndBuffersAreReleased() async throws {
        let allocator = TrackingMemoryBenchmarkAllocator()
        let kernel = MemoryBenchmarkKernel(
            configuration: .testing,
            allocator: allocator
        )

        let first = try await kernel.run(profile: .quick)
        let second = try await kernel.run(profile: .quick)

        XCTAssertEqual(first.sample.checksum, second.sample.checksum)
        XCTAssertEqual(first.totalAllocatedBytes, second.totalAllocatedBytes)
        XCTAssertEqual(
            first.processedBytes,
            UInt64(first.totalAllocatedBytes / 2 * first.passCount),
            "吞吐量只能统计每轮实际复制的源缓冲区字节，不能把目标缓冲区重复计入"
        )
        XCTAssertEqual(allocator.allocationCount, 2)
        XCTAssertEqual(allocator.deallocationCount, 2)
        XCTAssertEqual(allocator.liveAllocationCount, 0)
    }

    func testMemoryRejectsConfigurationBeyondAbsoluteAllocationLimit() async {
        let excessive = MemoryBenchmarkKernel.Limits(
            totalAllocatedBytes: MemoryBenchmarkKernel.maximumQuickAllocatedBytes + 64,
            passCount: 1,
            copyChunkBytes: 1_024,
            scanChunkBytes: 1_024,
            maximumElapsedSeconds: 1
        )
        let kernel = MemoryBenchmarkKernel(
            configuration: .init(quick: excessive, full: excessive)
        )

        await XCTAssertThrowsErrorAsync(try await kernel.run(profile: .quick)) {
            XCTAssertEqual($0 as? BenchmarkKernelError, .resourceLimit)
        }
    }

    func testMemoryAllocationFailureReturnsResourceLimit() async {
        let kernel = MemoryBenchmarkKernel(
            configuration: .testing,
            allocator: FailingMemoryBenchmarkAllocator()
        )

        await XCTAssertThrowsErrorAsync(try await kernel.run(profile: .quick)) {
            XCTAssertEqual($0 as? BenchmarkKernelError, .resourceLimit)
        }
    }

    func testMemoryCancellationReleasesItsAllocation() async throws {
        let allocator = TrackingMemoryBenchmarkAllocator()
        let limits = MemoryBenchmarkKernel.Limits(
            totalAllocatedBytes: MemoryBenchmarkKernel.maximumFullAllocatedBytes,
            passCount: MemoryBenchmarkKernel.maximumFullPassCount,
            copyChunkBytes: 64 * 1_024,
            scanChunkBytes: 64 * 1_024,
            maximumElapsedSeconds: MemoryBenchmarkKernel.maximumFullElapsedSeconds
        )
        let kernel = MemoryBenchmarkKernel(
            configuration: .init(quick: limits, full: limits),
            allocator: allocator
        )
        let task = Task {
            try await kernel.run(profile: .full)
        }

        for _ in 0..<1_000 where allocator.allocationCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(allocator.allocationCount, 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消后不应返回内存跑分结果")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("预期 CancellationError，实际为 \(error)")
        }
        XCTAssertEqual(allocator.allocationCount, allocator.deallocationCount)
        XCTAssertEqual(allocator.liveAllocationCount, 0)
    }

    func testMemoryTimeLimitFailureReleasesItsAllocation() async {
        let allocator = TrackingMemoryBenchmarkAllocator()
        let limits = MemoryBenchmarkKernel.Limits(
            totalAllocatedBytes: 2 * 1_024 * 1_024,
            passCount: 2,
            copyChunkBytes: 64 * 1_024,
            scanChunkBytes: 64 * 1_024,
            maximumElapsedSeconds: 0.000_000_001
        )
        let kernel = MemoryBenchmarkKernel(
            configuration: .init(quick: limits, full: limits),
            allocator: allocator
        )

        await XCTAssertThrowsErrorAsync(try await kernel.run(profile: .quick)) {
            XCTAssertEqual($0 as? BenchmarkKernelError, .resourceLimit)
        }
        XCTAssertEqual(allocator.allocationCount, 1)
        XCTAssertEqual(allocator.deallocationCount, 1)
        XCTAssertEqual(allocator.liveAllocationCount, 0)
    }

    func testMemorySafetyDeadlineIncludesAllocationAndInitialization() async {
        let allocator = TrackingMemoryBenchmarkAllocator(allocationDelay: 0.003)
        let limits = MemoryBenchmarkKernel.Limits(
            totalAllocatedBytes: 2 * 1_024 * 1_024,
            passCount: 1,
            copyChunkBytes: 64 * 1_024,
            scanChunkBytes: 64 * 1_024,
            maximumElapsedSeconds: 0.001
        )
        let kernel = MemoryBenchmarkKernel(
            configuration: .init(quick: limits, full: limits),
            allocator: allocator
        )

        await XCTAssertThrowsErrorAsync(try await kernel.run(profile: .quick)) {
            XCTAssertEqual($0 as? BenchmarkKernelError, .resourceLimit)
        }
        XCTAssertEqual(allocator.allocationCount, 1)
        XCTAssertEqual(allocator.deallocationCount, 1)
        XCTAssertEqual(allocator.liveAllocationCount, 0)
    }

    func testSuccessfulKernelsReturnFinitePositiveMetricsOffMainThread() async throws {
        let cpu = CPUBenchmarkKernel(configuration: .testing)
        let memory = MemoryBenchmarkKernel(configuration: .testing)

        let single = try await cpu.runSingle(profile: .quick)
        let multi = try await cpu.runMulti(profile: .quick, activeProcessorCount: 4)
        let memoryResult = try await memory.run(profile: .quick)

        for sample in [single.sample, multi.sample, memoryResult.sample] {
            XCTAssertTrue(sample.value.isFinite)
            XCTAssertGreaterThan(sample.value, 0)
            XCTAssertTrue(sample.elapsedSeconds.isFinite)
            XCTAssertGreaterThan(sample.elapsedSeconds, 0)
            XCTAssertNotEqual(sample.checksum, 0)
        }
        XCTAssertFalse(single.ranOnMainThread)
        XCTAssertFalse(multi.ranOnMainThread)
        XCTAssertFalse(memoryResult.ranOnMainThread)
    }

    func testStandardQuickKernelsCompleteWithinDeclaredLimits() async throws {
        guard ProcessInfo.processInfo.environment["CI"] != "true" else {
            throw XCTSkip("Production benchmark timing requires dedicated local hardware")
        }
        let cpu = try await CPUBenchmarkKernel().runSingle(profile: .quick)
        let memory = try await MemoryBenchmarkKernel().run(profile: .quick)

        XCTAssertLessThanOrEqual(
            cpu.operationCount,
            CPUBenchmarkKernel.maximumQuickOperationCount
        )
        XCTAssertLessThanOrEqual(
            cpu.sample.elapsedSeconds,
            CPUBenchmarkKernel.maximumQuickElapsedSeconds
        )
        XCTAssertLessThanOrEqual(
            memory.totalAllocatedBytes,
            MemoryBenchmarkKernel.maximumQuickAllocatedBytes
        )
        XCTAssertLessThanOrEqual(
            memory.sample.elapsedSeconds,
            MemoryBenchmarkKernel.maximumQuickElapsedSeconds
        )
        XCTAssertFalse(cpu.ranOnMainThread)
        XCTAssertFalse(memory.ranOnMainThread)
    }

    func testRequestedOptimizedQuickMultiHasAStableSamplingWindow() async throws {
        guard ProcessInfo.processInfo.environment["RUN_RELEASE_BENCHMARK_VALIDATION"] == "1"
        else {
            throw XCTSkip("Only run during explicit optimized benchmark validation")
        }

        let kernel = CPUBenchmarkKernel()
        var values: [Double] = []
        var durations: [Double] = []
        for index in 0..<3 {
            let result = try await kernel.runMulti(profile: .quick)
            values.append(result.sample.value)
            durations.append(result.sample.elapsedSeconds)
            if index < 2 {
                try await Task.sleep(
                    for: MacBenchmarkService.cpuMultiRecoveryDelay(for: .quick)
                )
            }
        }
        let measurement = BenchmarkComponentMeasurement(
            component: .cpuMulti,
            unit: .millionOperationsPerSecond,
            samples: zip(values, durations).map { value, duration in
                BenchmarkComponentSample(
                    value: value,
                    elapsedSeconds: duration,
                    checksum: 1
                )
            }
        )

        XCTAssertTrue(
            durations.allSatisfy { $0 >= 1.5 && $0 <= 5.0 },
            "durations=\(durations)"
        )
        XCTAssertLessThan(
            measurement.calibrationStabilityCoefficientOfVariation,
            0.05,
            "values=\(values), rawCV=\(measurement.coefficientOfVariation), "
                + "calibrationCV=\(measurement.calibrationStabilityCoefficientOfVariation)"
        )
    }
}

private final class TrackingMemoryBenchmarkAllocator:
    MemoryBenchmarkAllocating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let allocationDelay: TimeInterval
    private var allocations = 0
    private var deallocations = 0

    init(allocationDelay: TimeInterval = 0) {
        self.allocationDelay = allocationDelay
    }

    var allocationCount: Int {
        lock.withLock { allocations }
    }

    var deallocationCount: Int {
        lock.withLock { deallocations }
    }

    var liveAllocationCount: Int {
        lock.withLock { allocations - deallocations }
    }

    func allocate(byteCount: Int, alignment: Int) throws -> UnsafeMutableRawPointer {
        if allocationDelay > 0 {
            Thread.sleep(forTimeInterval: allocationDelay)
        }
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: alignment
        )
        lock.withLock { allocations += 1 }
        return pointer
    }

    func deallocate(_ pointer: UnsafeMutableRawPointer) {
        pointer.deallocate()
        lock.withLock { deallocations += 1 }
    }
}

private struct FailingMemoryBenchmarkAllocator: MemoryBenchmarkAllocating {
    private struct ExpectedFailure: Error {}

    func allocate(byteCount: Int, alignment: Int) throws -> UnsafeMutableRawPointer {
        throw ExpectedFailure()
    }

    func deallocate(_ pointer: UnsafeMutableRawPointer) {
        XCTFail("分配失败时不应尝试释放不存在的指针")
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
