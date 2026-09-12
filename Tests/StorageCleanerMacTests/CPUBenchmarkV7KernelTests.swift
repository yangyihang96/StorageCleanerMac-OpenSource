import XCTest
@testable import StorageCleanerMac

final class CPUBenchmarkV7KernelTests: XCTestCase {
    func testSingleMixedWorkloadProducesDeterministicV7RawSamples() async throws {
        let kernel = CPUBenchmarkV7Kernel(configuration: .testing)
        let first = try await kernel.measureSingle(profile: .quick)
        let second = try await kernel.measureSingle(profile: .quick)

        XCTAssertEqual(first.manifest.id, "cpu.single.mixed")
        XCTAssertEqual(first.manifest.category, .cpu)
        XCTAssertEqual(first.manifest.workloadVersion, "cpu-measurement-v8")
        XCTAssertEqual(first.manifest.mode, .singleCore)
        XCTAssertEqual(first.manifest.workerCount, 1)
        XCTAssertEqual(first.manifest.workloads, CPUBenchmarkV7Kernel.WorkloadCategory.allCases)
        XCTAssertEqual(first.samples.map(\.checksum), second.samples.map(\.checksum))
        XCTAssertEqual(first.calibrationChecksum, first.samples.first?.checksum)
        XCTAssertTrue(first.samples.allSatisfy(\.isValid))
        XCTAssertTrue(try first.metricResult().isValid)
    }

    func testMultiUsesOnlyParallelParticleWorkWithStableWidthAndChecksum() async throws {
        let kernel = CPUBenchmarkV7Kernel(configuration: .testing)
        let first = try await kernel.measureMulti(profile: .standard, activeProcessorCount: 3)
        let second = try await kernel.measureMulti(profile: .standard, activeProcessorCount: 3)

        XCTAssertEqual(first.manifest.id, "cpu.multi.particle")
        XCTAssertEqual(first.manifest.mode, .multiCore)
        XCTAssertEqual(first.manifest.workloads, [.particleSimulation])
        XCTAssertEqual(first.manifest.workerCount, 2)
        XCTAssertEqual(first.samples.map(\.checksum), second.samples.map(\.checksum))
        XCTAssertEqual(first.calibrationChecksum, first.samples.first?.checksum)
        XCTAssertTrue(first.samples.allSatisfy(\.isValid))
    }

    func testCancellationIsObservedBeforeDetachedSingleWorkerRuns() async {
        let task = Task {
            try await CPUBenchmarkV7Kernel(configuration: .testing).measureSingle(profile: .quick)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled CPU measurement must not return a result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }
}
