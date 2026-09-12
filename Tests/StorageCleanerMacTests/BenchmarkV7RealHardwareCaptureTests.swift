import Foundation
import XCTest

@testable import StorageCleanerMac

/// Explicit local-only evidence capture. It bypasses history and leaderboard
/// writes, so repeated real-machine validation cannot affect user data.
final class BenchmarkV7RealHardwareCaptureTests: XCTestCase {
    func testOptInCaptureV7StandardSelectedCategory() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let categoryRaw = environment["MAC_BENCHMARK_V7_REAL_CATEGORY"],
              let category = BenchmarkV7Category(rawValue: categoryRaw) else {
            throw XCTSkip("Set MAC_BENCHMARK_V7_REAL_CATEGORY to opt in.")
        }
        try Self.requireReleaseCaptureBuild()
        guard let outputPath = environment["MAC_BENCHMARK_V7_REAL_CAPTURE_OUTPUT"],
              !outputPath.isEmpty else {
            throw CaptureError.missingOutputDirectory
        }
        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: SystemBenchmarkV7WorkloadRunner(),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            environmentProvider: try captureEnvironmentProvider(environment)
        )
        let result = await coordinator.run(plan: .standard, categories: [category])
        try write([result], to: outputDirectory, name: "v7-standard-\(category.rawValue)-attempt")
        guard result.failure == nil, result.isComplete else {
            throw CaptureError.runFailed(index: 1, failure: result.failure)
        }
    }

    func testOptInCaptureV7StandardRuns() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MAC_BENCHMARK_V7_REAL_CAPTURE"] == "1" else {
            throw XCTSkip("Set MAC_BENCHMARK_V7_REAL_CAPTURE=1 to opt in.")
        }
        try Self.requireReleaseCaptureBuild()
        guard let outputPath = environment["MAC_BENCHMARK_V7_REAL_CAPTURE_OUTPUT"],
              !outputPath.isEmpty else {
            throw CaptureError.missingOutputDirectory
        }
        let requestedRuns = Int(environment["MAC_BENCHMARK_V7_REAL_RUNS"] ?? "1") ?? 1
        guard (1...5).contains(requestedRuns) else {
            throw CaptureError.invalidRunCount
        }

        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: SystemBenchmarkV7WorkloadRunner(),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            environmentProvider: try captureEnvironmentProvider(environment)
        )
        var results: [BenchmarkV7Result] = []
        results.reserveCapacity(requestedRuns)
        for index in 0..<requestedRuns {
            let result = await coordinator.run(plan: .standard)
            results.append(result)
            guard result.failure == nil, result.isComplete else {
                try write(results, to: outputDirectory, name: "v7-standard-failed-attempt")
                throw CaptureError.runFailed(index: index + 1, failure: result.failure)
            }
            if index < requestedRuns - 1 {
                try await Task.sleep(for: .seconds(10))
            }
        }

        try write(
            results,
            to: outputDirectory,
            name: "v7-standard-\(requestedRuns)-runs"
        )
    }

    @MainActor
    func testOptInCaptureOfficialProductFlow() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MAC_BENCHMARK_V7_PRODUCT_CAPTURE"] == "1" else {
            throw XCTSkip("Set MAC_BENCHMARK_V7_PRODUCT_CAPTURE=1 to opt in.")
        }
        try Self.requireReleaseCaptureBuild()
        guard let outputPath = environment["MAC_BENCHMARK_V7_REAL_CAPTURE_OUTPUT"],
              !outputPath.isEmpty else {
            throw CaptureError.missingOutputDirectory
        }

        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let historyURL = outputDirectory.appendingPathComponent(
            "benchmark-v7-product-history.json",
            isDirectory: false
        )
        let completionURL = outputDirectory.appendingPathComponent(
            "v7-official-product-flow.json",
            isDirectory: false
        )
        guard !FileManager.default.fileExists(atPath: historyURL.path),
              !FileManager.default.fileExists(atPath: completionURL.path) else {
            throw CaptureError.outputAlreadyContainsCapture
        }
        let historyRepository = BenchmarkV7HistoryRepository(storageURL: historyURL)
        let heavyWorkCoordinator = HeavyWorkCoordinator()
        let environmentProvider = try captureEnvironmentProvider(environment)
        let sustainedService = MacSustainedBenchmarkService(
            heavyWorkCoordinator: heavyWorkCoordinator,
            workloadRunner: SystemMacSustainedBenchmarkWorkloadRunner(),
            environmentProvider: environmentProvider
        )
        let benchmarkProcessor = MacBenchmarkResultProcessor(
            baselineCatalog: MacBenchmarkProductionBaselineCatalog.runtimeCatalog()
        )
        let store = MacBenchmarkStore(
            service: MacBenchmarkService(heavyWorkCoordinator: heavyWorkCoordinator),
            resultProcessor: benchmarkProcessor,
            sustainedService: sustainedService,
            v7Coordinator: BenchmarkV7Coordinator(
                workloadRunner: SystemBenchmarkV7WorkloadRunner(),
                heavyWorkCoordinator: heavyWorkCoordinator,
                sustainedService: sustainedService,
                environmentProvider: environmentProvider
            ),
            v7HistoryRepository: historyRepository
        )

        store.startOfficialBenchmark()
        await store.waitUntilIdle()

        let result = try XCTUnwrap(store.v7LatestResult)
        let stored = await historyRepository.load()
        let expectedLocalBestRecordID = result.isCurrentLocalBestEligible
            ? result.recordID
            : nil
        guard result.failure == nil,
              result.isComplete,
              result.isCurrentComparableOfficialResult,
              result.session.categories == OfficialBenchmarkPlan.current.categories,
              stored.map(\.recordID) == [result.recordID],
              store.localBestOfficialV7Result?.recordID == expectedLocalBestRecordID else {
            throw CaptureError.productFlowValidationFailed(result.failure)
        }
        try write(stored, to: outputDirectory, name: "v7-official-product-flow")
    }

    private func write(
        _ results: [BenchmarkV7Result],
        to outputDirectory: URL,
        name: String
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(
            to: outputDirectory.appendingPathComponent("\(name).json"),
            options: [.atomic]
        )
    }

    func testCaptureEnvironmentUsesExplicitApplicationIdentity() {
        let provider = CaptureBenchmarkEnvironmentProvider(
            appVersion: "1.9.9",
            appBuild: "fixture-build"
        )
        let metadata = provider.metadata(preflight: BenchmarkPreflight(
            capturedAt: Date(),
            powerSource: .unknown,
            batteryPercent: nil,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            diskReliability: .unavailable,
            availableDiskBytes: 1,
            requiredDiskBytes: 0,
            warnings: []
        ))

        XCTAssertEqual(metadata.appVersion, "1.9.9")
        XCTAssertEqual(metadata.appBuild, "fixture-build")
    }

    func testRealHardwareCaptureBuildGateMatchesTheCurrentConfiguration() {
        #if DEBUG || !STORAGE_CLEANER_RELEASE_BUILD
        XCTAssertThrowsError(try Self.requireReleaseCaptureBuild()) { error in
            guard case CaptureError.releaseBuildRequired = error else {
                return XCTFail("Expected releaseBuildRequired, got \(error)")
            }
        }
        #else
        XCTAssertNoThrow(try Self.requireReleaseCaptureBuild())
        #endif
    }

    private static func requireReleaseCaptureBuild() throws {
        #if DEBUG || !STORAGE_CLEANER_RELEASE_BUILD
        throw CaptureError.releaseBuildRequired
        #else
        return
        #endif
    }

    private func captureEnvironmentProvider(
        _ environment: [String: String]
    ) throws -> CaptureBenchmarkEnvironmentProvider {
        guard let appVersion = environment["MAC_BENCHMARK_V7_APP_VERSION"]?.trimmed.nonEmpty,
              let appBuild = environment["MAC_BENCHMARK_V7_APP_BUILD"]?.trimmed.nonEmpty else {
            throw CaptureError.missingApplicationIdentity
        }
        return CaptureBenchmarkEnvironmentProvider(
            appVersion: appVersion,
            appBuild: appBuild
        )
    }

    private enum CaptureError: Error, LocalizedError {
        case missingOutputDirectory
        case invalidRunCount
        case missingApplicationIdentity
        case releaseBuildRequired
        case outputAlreadyContainsCapture
        case productFlowValidationFailed(BenchmarkV7Failure?)
        case runFailed(index: Int, failure: BenchmarkV7Failure?)

        var errorDescription: String? {
            switch self {
            case .missingOutputDirectory:
                "MAC_BENCHMARK_V7_REAL_CAPTURE_OUTPUT is required."
            case .invalidRunCount:
                "MAC_BENCHMARK_V7_REAL_RUNS must be between 1 and 5."
            case .missingApplicationIdentity:
                "MAC_BENCHMARK_V7_APP_VERSION and MAC_BENCHMARK_V7_APP_BUILD are required."
            case .releaseBuildRequired:
                "Real hardware benchmark capture requires an optimized Release test build."
            case .outputAlreadyContainsCapture:
                "MAC_BENCHMARK_V7_REAL_CAPTURE_OUTPUT must be a fresh directory."
            case let .productFlowValidationFailed(failure):
                "Official product-flow validation failed: \(String(describing: failure))."
            case let .runFailed(index, failure):
                "v7 run \(index) failed: \(String(describing: failure))."
            }
        }
    }
}

private struct CaptureBenchmarkEnvironmentProvider: MacBenchmarkEnvironmentProviding {
    let appVersion: String
    let appBuild: String

    func metadata(preflight: BenchmarkPreflight) -> BenchmarkEnvironmentMetadata {
        let base = SystemMacBenchmarkEnvironmentProvider().metadata(preflight: preflight)
        return BenchmarkEnvironmentMetadata(
            architecture: base.architecture,
            chipName: base.chipName,
            activeProcessorCount: base.activeProcessorCount,
            physicalMemoryBytes: base.physicalMemoryBytes,
            systemDiskCapacityBytes: base.systemDiskCapacityBytes,
            powerSource: base.powerSource,
            thermalState: base.thermalState,
            operatingSystemVersion: base.operatingSystemVersion,
            appVersion: appVersion,
            appBuild: appBuild
        )
    }
}
