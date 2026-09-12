import Foundation
import XCTest

@testable import StorageCleanerMac

final class StorageRandomAccessBenchmarkV7Tests: XCTestCase {
    func testFixtureMeasuresAllRandomModesAndRemovesItsPrivateArtifact() async throws {
        let targetDirectory = try makeTargetDirectory()
        defer { try? FileManager.default.removeItem(at: targetDirectory) }
        let benchmark = StorageRandomAccessBenchmarkV7(
            configuration: .fixture(in: targetDirectory)
        )

        let result = try await benchmark.run()

        XCTAssertEqual(result.workloadVersion, "storage-random-access-v7")
        XCTAssertEqual(result.blockBytes, 4 * 1_024)
        XCTAssertEqual(result.cacheMode, .buffered)
        XCTAssertEqual(result.writeSyncMode, .afterEachWriteWorkload)
        XCTAssertEqual(result.randomWriteQD1.queueDepth, 1)
        XCTAssertEqual(result.randomWriteQD16.queueDepth, 16)
        XCTAssertEqual(result.randomReadQD1.queueDepth, 1)
        XCTAssertEqual(result.randomReadQD16.queueDepth, 16)
        XCTAssertEqual(result.randomWriteQD1.operationCount, 16)
        XCTAssertEqual(result.randomWriteQD16.operationCount, 16)
        XCTAssertEqual(
            result.randomWriteQD1.validationChecksum,
            result.randomReadQD1.validationChecksum
        )
        XCTAssertEqual(
            result.randomWriteQD16.validationChecksum,
            result.randomReadQD16.validationChecksum
        )
        XCTAssertNotNil(result.randomWriteQD1.flushLatencyNanoseconds)
        XCTAssertNotNil(result.randomWriteQD16.flushLatencyNanoseconds)
        XCTAssertNil(result.randomReadQD1.flushLatencyNanoseconds)
        XCTAssertNil(result.randomReadQD16.flushLatencyNanoseconds)
        assertMetric(
            result.randomWriteQD1.iopsSample,
            id: "storage.random.write.qd1.iops",
            direction: .higherIsBetter,
            unit: "IOPS"
        )
        assertMetric(
            result.randomReadQD16.p95LatencySample,
            id: "storage.random.read.qd16.latency.p95.ns",
            direction: .lowerIsBetter,
            unit: "ns"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: targetDirectory.path),
            []
        )
    }

    func testLatencySummaryUsesMedianAndNearestRankP95() throws {
        let summary = try StorageRandomAccessBenchmarkV7.latencySummary(
            for: [40, 10, 30, 20]
        )

        XCTAssertEqual(summary.p50Nanoseconds, 25)
        XCTAssertEqual(summary.p95Nanoseconds, 40)
    }

    func testInvalidConfigurationDoesNotCreateAnyTargetArtifact() async throws {
        let targetDirectory = try makeTargetDirectory()
        defer { try? FileManager.default.removeItem(at: targetDirectory) }
        let benchmark = StorageRandomAccessBenchmarkV7(
            configuration: .init(
                targetDirectory: targetDirectory,
                fileBytes: 4 * StorageRandomAccessBenchmarkV7.blockBytes,
                operationCount: 3
            )
        )

        do {
            _ = try await benchmark.run()
            XCTFail("Expected invalid v7 random-access configuration to fail")
        } catch let error as StorageRandomAccessBenchmarkV7.Failure {
            XCTAssertEqual(error, .invalidConfiguration)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: targetDirectory.path),
            []
        )
    }

    func testCancellationCleansThePrivateArtifact() async throws {
        let targetDirectory = try makeTargetDirectory()
        defer { try? FileManager.default.removeItem(at: targetDirectory) }
        let benchmark = StorageRandomAccessBenchmarkV7(
            configuration: .init(
                targetDirectory: targetDirectory,
                fileBytes: 8 * 1_024 * 1_024,
                operationCount: 1_024
            )
        )
        let task = Task { try await benchmark.run() }

        task.cancel()
        let taskResult = await task.result
        switch taskResult {
        case .success:
            XCTFail("A task cancelled before its first await must not publish a result")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: targetDirectory.path),
            []
        )
    }

    private func assertMetric(
        _ metric: StorageRandomAccessBenchmarkV7.MetricSample,
        id: String,
        direction: BenchmarkV7MetricDirection,
        unit: String
    ) {
        XCTAssertEqual(metric.metricID, id)
        XCTAssertEqual(metric.direction, direction)
        XCTAssertEqual(metric.unit, unit)
        XCTAssertTrue(metric.value.isFinite)
        XCTAssertGreaterThan(metric.value, 0)
        XCTAssertTrue(metric.elapsedSeconds.isFinite)
        XCTAssertGreaterThan(metric.elapsedSeconds, 0)
        XCTAssertNotEqual(metric.checksum, 0)
    }

    private func makeTargetDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageRandomAccessBenchmarkV7Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}
