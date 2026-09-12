import Foundation
import XCTest

@testable import StorageCleanerMac

/// Opt-in hardware evidence capture. Normal CI never executes a workload: the
/// caller must provide both the explicit switch and a private output directory.
final class MacBenchmarkRealHardwareCaptureTests: XCTestCase {
    func testOptInCaptureCurrentV6Baseline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MAC_BENCHMARK_REAL_CAPTURE"] == "1" else { return }
        guard let outputPath = environment["MAC_BENCHMARK_REAL_CAPTURE_OUTPUT"],
              !outputPath.isEmpty else {
            throw CaptureError.missingOutputDirectory
        }

        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let service = MacBenchmarkService()
        var records: [MacBenchmarkRawResult] = []
        records.reserveCapacity(5)

        for index in 0..<5 {
            let result = await service.run(profile: .standard)
            guard result.failure == nil, result.isComplete else {
                throw CaptureError.runFailed(index: index + 1, failure: result.failure)
            }
            records.append(result)

            if index < 4 {
                try await Task.sleep(for: .seconds(5))
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try data.write(
            to: outputDirectory.appendingPathComponent("v6-current-machine-five-runs.json"),
            options: [.atomic]
        )
    }

    private enum CaptureError: Error, LocalizedError {
        case missingOutputDirectory
        case runFailed(index: Int, failure: MacBenchmarkFailure?)

        var errorDescription: String? {
            switch self {
            case .missingOutputDirectory:
                "MAC_BENCHMARK_REAL_CAPTURE_OUTPUT is required."
            case let .runFailed(index, failure):
                "Benchmark baseline run \(index) failed: \(String(describing: failure))."
            }
        }
    }
}
