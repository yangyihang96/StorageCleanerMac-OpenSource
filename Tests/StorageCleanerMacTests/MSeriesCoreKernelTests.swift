import Foundation
import XCTest
import MSeriesKernels
@testable import StorageCleanerMac

final class MSeriesCoreKernelTests: XCTestCase {
    func testPointerChaseRequiresExecutionAndValidatesWholeFixture() throws {
        let workspace = try XCTUnwrap(msc_create(6))
        defer { msc_destroy(workspace) }
        XCTAssertEqual(msc_validate(workspace), 0)
        XCTAssertEqual(msc_run_unit(workspace), 1)
        XCTAssertEqual(msc_validate(workspace), 1)
        XCTAssertNotEqual(msc_checksum(workspace), 0)
    }
    func testSessionWriteBudgetSurvivesFailedWorkerReservations() throws {
        let budget = MSeriesWriteBudget(maximum: 512)
        try budget.reserve(336)
        try budget.recordWritten(64) // failed initialization, actual partial write
        XCTAssertEqual(budget.writtenBytes, 64)
        XCTAssertThrowsError(try budget.reserve(336)) // retry cannot reset allowance
        try budget.reserve(176)
        XCTAssertThrowsError(try budget.reserve(1))
        XCTAssertThrowsError(try budget.recordWritten(449))
        XCTAssertEqual(budget.writtenBytes, 64)
    }

    func testThreadCurveIncludesAllLogicalCoresWithoutSixtyFourCoreCap() {
        XCTAssertEqual(MSeriesCPUExtensions.threadCounts(logicalCores: 1), [1])
        XCTAssertEqual(MSeriesCPUExtensions.threadCounts(logicalCores: 18), [1, 2, 4, 8, 16, 18])
        XCTAssertEqual(MSeriesCPUExtensions.threadCounts(logicalCores: 65), [1, 2, 4, 8, 16, 32, 64, 65])
        XCTAssertTrue(MSeriesCPUExtensions.threadCounts(logicalCores: 0).isEmpty)
    }
    func testCPUAndMemoryFixedKernelsProduceVerifiedPositiveSamples() throws {
        for kind in Int32(0)...6 {
            let measurement = try MSeriesCPUMemoryKernel(kind: kind, workers: 1, budgetBytes: 512 * 1024 * 1024)
                .measure(id: "fixture.\(kind)", cancellation: MSeriesCancellation())
            XCTAssertTrue(measurement.isValid)
            XCTAssertEqual(measurement.samples.count, 3)
            XCTAssertTrue(measurement.samples.allSatisfy { $0.value > 0 && $0.value.isFinite })
        }
    }
    func testMulticoreUsesRequestedWorkersAndRefusesBudgetInsteadOfReducingWorkers() throws {
        XCTAssertThrowsError(try MSeriesCPUMemoryKernel(kind: 2, workers: 65, budgetBytes: 1024))
        let result = try MSeriesCPUMemoryKernel(kind: 0, workers: 3, budgetBytes: 128 * 1024 * 1024)
            .measure(id: "cpu.multi.integer", cancellation: MSeriesCancellation())
        XCTAssertEqual(result.workers, 3)
    }
    func testCancelledKernelDoesNotPublishFakeSamples() throws {
        let cancellation = MSeriesCancellation(); cancellation.cancel()
        let kernel = try MSeriesCPUMemoryKernel(kind: 0, workers: 1, budgetBytes: 32 * 1024 * 1024)
        XCTAssertThrowsError(try kernel.measure(id: "cpu.single.integer", cancellation: cancellation))
    }
    func testMetalFixedOffscreenFP32AndFP16Outputs() throws {
        let gpu = try MSeriesGPUKernel(budget: 512 * 1024 * 1024)
        let cancellation = MSeriesCancellation()
        XCTAssertTrue(try gpu.graphics(cancellation: cancellation).isValid)
        XCTAssertTrue(try gpu.compute(halfPrecision: false, cancellation: cancellation).isValid)
        XCTAssertTrue(try gpu.compute(halfPrecision: true, cancellation: cancellation).isValid)
    }
    func testStoragePrivateFixtureBudgetsAndLatencySeparation() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Caches/StorageCleanerFixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var disk: MSeriesStorageKernel? = try MSeriesStorageKernel(root: root, sessionID: UUID(),
            budget: 512 * 1024 * 1024, cancellation: MSeriesCancellation())
        for random in [false, true] { for write in [false, true] {
            let result = try XCTUnwrap(disk).measure(random: random, write: write)
            XCTAssertTrue(result.isValid)
            XCTAssertEqual(result.ioLatencyNanoseconds?.first?.count, random ? 1024 : nil)
            XCTAssertEqual(result.statistics?.sampleCount, 3)
        } }
        XCTAssertEqual(disk?.writtenBytes, 336 * 1024 * 1024)
        disk = nil
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}

extension MSeriesCoreKernelTests {
    func testProductionCoordinatorRunsAll18IntoExistingHistoryWithoutSyntheticScore() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Caches/StorageCleanerFixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let leases = HeavyWorkCoordinator()
        let coordinator = BenchmarkV7Coordinator(workloadRunner: SystemBenchmarkV7WorkloadRunner(),
            heavyWorkCoordinator: leases, resourceJournal: CleanupReportJournal(directory: root.appendingPathComponent("receipts")))
        let result = await coordinator.run(plan: MSeriesProtocol.officialPlan, targetDirectory: root)
        let raw = try XCTUnwrap(result.mSeries)
        XCTAssertEqual(raw.metrics.count, 18)
        XCTAssertTrue(raw.isCompleteCore, String(describing: raw.metrics.filter { $0.availability != .available }))
        XCTAssertTrue(result.isPersistable)
        XCTAssertTrue(result.isComplete)
        XCTAssertNil(raw.overallIndex)
        XCTAssertNil(result.coreScore)
        XCTAssertFalse(result.isCurrentOfficialRankingEligible)
        XCTAssertEqual(raw.metrics.filter { $0.id.hasPrefix("cpu.multi") }.map(\.workers),
                       Array(repeating: raw.hardware.logicalCores, count: 4))
        let repository = BenchmarkV7HistoryRepository(storageURL: root.appendingPathComponent("history.json"))
        try await repository.save(result)
        let reloaded = await repository.load()
        XCTAssertEqual(reloaded, [result])
        let owner = await leases.activeOwner
        XCTAssertNil(owner)
        let resources = try CleanupReportJournal(directory: root.appendingPathComponent("receipts")).load()
        XCTAssertEqual(resources.count, 1)
        XCTAssertEqual(resources.first?.rulesVersion, "benchmark.fixture.v1")
        XCTAssertEqual(resources.first?.outcome, .completed)
        if let export = ProcessInfo.processInfo.environment["STORAGE_CLEANER_CORE_EVIDENCE"] {
            try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: export), options: .atomic)
        }
    }
}
