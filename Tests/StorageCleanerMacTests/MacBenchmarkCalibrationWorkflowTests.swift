import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

/// Explicitly enabled release-calibration workflow.
///
/// This test is inert during normal test runs. It only executes real benchmark
/// workloads when `MAC_BENCHMARK_CALIBRATION_ACTION=collect` is provided to a
/// Release XCTest invocation. See `docs/benchmarks/README.md`.
final class MacBenchmarkCalibrationWorkflowTests: XCTestCase {
    func testExplicitCalibrationWorkflow() async throws {
        guard let action = environment("MAC_BENCHMARK_CALIBRATION_ACTION") else {
            return
        }
        if action == "collect" {
            guard let runGuard = environment(
                "MAC_BENCHMARK_CALIBRATION_RUN_GUARD"
            ) else {
                XCTFail("缺少一次性校准运行护栏")
                throw MacBenchmarkCalibrationError.invalidRawResult
            }
            let runGuardDigest = MacBenchmarkBaselineVerification.sha256Hex(
                Data(runGuard.utf8)
            )
            guard runGuardDigest == Self.collectionRunGuardSHA256 else {
                XCTFail("一次性校准运行护栏摘要不匹配：\(runGuardDigest)")
                throw MacBenchmarkCalibrationError.invalidRawResult
            }
        }

        #if DEBUG || !STORAGE_CLEANER_RELEASE_BUILD
        _ = action
        throw MacBenchmarkCalibrationError.debugBuildNotAllowed
        #else
        guard isOptimizedReleaseCalibrationHarness() else {
            throw MacBenchmarkCalibrationError.debugBuildNotAllowed
        }
        switch action {
        case "collect":
            try await collectReleaseRuns()
        case "aggregate":
            try aggregateReleaseRuns()
        case "validate-production":
            try validateFrozenWorkloadSourceFingerprint()
            _ = try MacBenchmarkProductionBaselineCatalog.validateForRelease(
                expectedSourceBuild: MacBenchmarkProductionBaselineCatalog
                    .calibrationSourceBuild
            )
        default:
            XCTFail("未知校准动作：\(action)")
        }
        #endif
    }

    func testFrozenV6ProtocolFingerprintMatchesCalibrationGate() throws {
        try validateFrozenWorkloadSourceFingerprint()
    }
}

private extension MacBenchmarkCalibrationWorkflowTests {
    /// One-time release calibration gate. Rotate the digest for each formal
    /// calibration instead of committing a reusable plaintext token.
    static let collectionRunGuardSHA256 =
        "9c1c97e53ffc0bddd8289f1f4718c6ef499b43a12a4efac22ef2f8afa1d9a9a9"
    static let frozenWorkloadSourceSHA256 =
        "b6f20c14c535e5d6ca025d1cc2370a924cd4f392018c7aead92ce1b8cc41510d"
    static let frozenWorkloadSourcePaths = [
        "Sources/StorageCleanerMac/Models/MacBenchmarkModels.swift",
        "Sources/StorageCleanerMac/Services/Benchmark/CPUBenchmarkKernel.swift",
        "Sources/StorageCleanerMac/Services/Benchmark/DiskBenchmarkKernel.swift",
        "Sources/StorageCleanerMac/Services/Benchmark/MacBenchmarkPreflightService.swift",
        "Sources/StorageCleanerMac/Services/Benchmark/MacBenchmarkResultProcessor.swift",
        "Sources/StorageCleanerMac/Services/Benchmark/MacBenchmarkService.swift",
        "Sources/StorageCleanerMac/Services/Benchmark/MacBenchmarkServiceProtocol.swift",
        "Sources/StorageCleanerMac/Services/Benchmark/MemoryBenchmarkKernel.swift",
        "Sources/StorageCleanerMac/Services/Benchmark/MetalBenchmarkKernel.swift",
        "Sources/StorageCleanerMac/Services/Benchmark/Metal3DBenchmarkKernel.swift",
        "Sources/StorageCleanerMac/Services/MacBenchmarkScoring.swift",
    ]

    func validateFrozenWorkloadSourceFingerprint() throws {
        var sourceData = Data()
        for relativePath in Self.frozenWorkloadSourcePaths {
            let fileURL = packageRoot().appendingPathComponent(relativePath)
            sourceData.append(Data(relativePath.utf8))
            sourceData.append(0)
            sourceData.append(try Data(contentsOf: fileURL))
            sourceData.append(0)
        }
        let actualFingerprint = MacBenchmarkBaselineVerification.sha256Hex(sourceData)
        guard actualFingerprint == Self.frozenWorkloadSourceSHA256 else {
            XCTFail(
                "跑分协议源码指纹不匹配：actual=\(actualFingerprint) "
                    + "expected=\(Self.frozenWorkloadSourceSHA256)"
            )
            throw MacBenchmarkCalibrationError.inconsistentSourceBuild
        }
    }

    func collectReleaseRuns() async throws {
        let sessionLabel = try requiredEnvironment(
            "MAC_BENCHMARK_CALIBRATION_SESSION"
        )
        let outputDirectory = URL(
            fileURLWithPath: try requiredEnvironment(
                "MAC_BENCHMARK_CALIBRATION_OUTPUT_DIR"
            ),
            isDirectory: true
        )
        let profiles = try requestedProfiles()
        guard let runCount = Int(
            try requiredEnvironment("MAC_BENCHMARK_CALIBRATION_RUNS_PER_PROFILE")
        ), (1...8).contains(runCount) else {
            throw MacBenchmarkCalibrationError.invalidRawResult
        }

        let expectedHardware = MacBenchmarkCalibrationHardware.m5ProReference
        let sourceBuild = try releaseSourceBuild()
        guard currentModelIdentifier() == expectedHardware.modelIdentifier else {
            throw MacBenchmarkCalibrationError.referenceHardwareMismatch
        }

        let aggregator = MacBenchmarkCalibrationAggregator(
            expectedHardware: expectedHardware
        )
        let sessionDirectory = outputDirectory
            .appendingPathComponent(sessionLabel, isDirectory: true)
        try ensurePrivateDirectory(sessionDirectory)

        let service = MacBenchmarkService(
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            environmentProvider: MacBenchmarkCalibrationEnvironmentProvider(
                sourceBuild: sourceBuild
            )
        )
        for profile in profiles {
            for _ in 0..<runCount {
                Self.writeProgressSummary(
                    "start profile=\(profile.rawValue) session=\(sessionLabel)"
                )
                let rawResult = await service.run(profile: profile) { progress in
                    Self.writeProgressSummary(
                        "profile=\(profile.rawValue) "
                            + "stage=\(progress.stage.rawValue) "
                            + "samples=\(progress.completedSampleCount)/"
                            + "\(progress.totalSampleCount)"
                    )
                }
                let record = MacBenchmarkCalibrationRunRecord(
                    sessionLabel: sessionLabel,
                    hardware: expectedHardware,
                    rawResult: rawResult
                )
                let data = try MacBenchmarkCalibrationCoding.canonicalData(record)
                do {
                    _ = try aggregator.validateCanonicalRecordData(data)
                } catch {
                    let rejectedDirectory = sessionDirectory.appendingPathComponent(
                        "rejected",
                        isDirectory: true
                    )
                    try ensurePrivateDirectory(rejectedDirectory)
                    let rejectedFilename = "\(profile.rawValue)-"
                        + "\(UUID().uuidString.lowercased()).rejected.json"
                    try writePrivate(
                        data,
                        to: rejectedDirectory.appendingPathComponent(rejectedFilename)
                    )
                    Self.writeProgressSummary(
                        "preserved rejected profile=\(profile.rawValue) "
                            + "file=\(rejectedFilename)"
                    )
                    Self.writeDiagnosticSummary(for: rawResult, rejection: error)
                    Self.writeProgressSummary(
                        "continuing after rejected profile=\(profile.rawValue)"
                    )
                    continue
                }

                let filename = "\(profile.rawValue)-"
                    + "\(UUID().uuidString.lowercased()).run.json"
                try writePrivate(
                    data,
                    to: sessionDirectory.appendingPathComponent(filename)
                )
                Self.writeProgressSummary(
                    "saved profile=\(profile.rawValue) file=\(filename)"
                )
            }
        }
    }

    static func writeProgressSummary(_ message: String) {
        guard let data = "[benchmark-calibration] \(message)\n".data(using: .utf8) else {
            return
        }
        FileHandle.standardError.write(data)
    }

    func aggregateReleaseRuns() throws {
        let inputDirectory = URL(
            fileURLWithPath: try requiredEnvironment(
                "MAC_BENCHMARK_CALIBRATION_INPUT_DIR"
            ),
            isDirectory: true
        )
        let outputDirectory = URL(
            fileURLWithPath: try requiredEnvironment(
                "MAC_BENCHMARK_CALIBRATION_OUTPUT_DIR"
            ),
            isDirectory: true
        )
        let baselineVersion = try requiredEnvironment(
            "MAC_BENCHMARK_CALIBRATION_BASELINE_VERSION"
        )
        guard baselineVersion == MacBenchmarkProductionBaselineCatalog
                .activeBaselineVersion
        else {
            throw MacBenchmarkCalibrationError.invalidBaselineVersion
        }
        guard let frozenAt = Self.parseISO8601(
            try requiredEnvironment("MAC_BENCHMARK_CALIBRATION_FROZEN_AT")
        ) else {
            throw MacBenchmarkCalibrationError.invalidFrozenDate
        }

        let aggregator = MacBenchmarkCalibrationAggregator()
        let records = try calibrationRunURLs(in: inputDirectory).map { url in
            try aggregator.validateCanonicalRecordData(Data(contentsOf: url))
        }
        let artifacts = try aggregator.makeArtifacts(
            records: records,
            baselineVersion: baselineVersion,
            frozenAt: frozenAt
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        for artifact in artifacts {
            let stem = "mac-benchmark-m5-pro-\(artifact.profile.rawValue)-"
                + baselineVersion
            try artifact.documentData.write(
                to: outputDirectory.appendingPathComponent("\(stem).json"),
                options: [.atomic]
            )
            try Data(markdown(for: artifact).utf8).write(
                to: outputDirectory.appendingPathComponent("\(stem).md"),
                options: [.atomic]
            )
        }
        try Data(frozenSwiftSnippet(for: artifacts).utf8).write(
            to: outputDirectory.appendingPathComponent(
                "mac-benchmark-production-frozen-snippet.txt"
            ),
            options: [.atomic]
        )
    }

    func calibrationRunURLs(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw MacBenchmarkCalibrationError.invalidRawResult
        }
        return try enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.lastPathComponent.hasSuffix(".run.json"),
                  try url.resourceValues(
                      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ).isRegularFile == true,
                  try url.resourceValues(forKeys: [.isSymbolicLinkKey])
                    .isSymbolicLink != true
            else { return nil }
            return url
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func requestedProfiles() throws -> [BenchmarkProfile] {
        let raw = try requiredEnvironment("MAC_BENCHMARK_CALIBRATION_PROFILES")
        let profiles = try raw.split(separator: ",").map { value -> BenchmarkProfile in
            guard let profile = BenchmarkProfile(rawValue: String(value)) else {
                throw MacBenchmarkCalibrationError.invalidRawResult
            }
            return profile
        }
        guard !profiles.isEmpty, Set(profiles).count == profiles.count else {
            throw MacBenchmarkCalibrationError.invalidRawResult
        }
        return profiles
    }

    func ensurePrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw MacBenchmarkCalibrationError.invalidRawResult
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MacBenchmarkCalibrationError.invalidRawResult
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    func currentModelIdentifier() -> String? {
        var size: size_t = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBytes { bytes in
            sysctlbyname("hw.model", bytes.baseAddress, &size, nil, 0)
        }
        guard status == 0 else {
            return nil
        }
        let bytes = buffer.lazy.map(UInt8.init(bitPattern:)).prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func markdown(for artifact: MacBenchmarkCalibrationArtifact) -> String {
        let document = artifact.document
        var lines = [
            "# Mac 跑分 M5 Pro \(artifact.profile.rawValue) 校准报告",
            "",
            "- Baseline: `\(document.baselineReport.key.baselineVersion)`",
            "- Workload: `\(document.baselineReport.key.workloadVersion)`",
            "- Harness: `\(document.harnessIdentifier)` (optimized Release)",
            "- Harness app version: `\(document.sourceBuild.appVersion)`",
            "- Harness app build: `\(document.sourceBuild.appBuild)`",
            "- Reference: \(document.baselineReport.referenceHardware)",
            "- Valid release runs: \(document.validRunCount)",
            "- Independent sessions: \(document.independentSessionCount)",
            "- Maximum accepted within-run and standard aggregate CV: \(Self.decimal(document.maximumAllowedCoefficientOfVariation))",
            "- Maximum accepted GPU aggregate CV: \(Self.decimal(document.maximumAllowedGPUAggregateCoefficientOfVariation))",
            "- Maximum accepted durable-write aggregate CV: \(Self.decimal(document.maximumAllowedDurableWriteAggregateCoefficientOfVariation))",
            "- Frozen at: \(Self.iso8601(document.baselineReport.frozenAt))",
            "- Calibration document SHA-256: `\(artifact.documentSHA256)`",
            "- Baseline report SHA-256: `\(document.baselineReportSHA256)`",
            "",
            "| Component | Reference median | Across-run CV |",
            "| --- | ---: | ---: |",
        ]
        for component in BenchmarkComponent.allCases {
            lines.append(
                "| \(component.rawValue) | "
                    + "\(Self.decimal(document.baselineReport.referenceMetrics[component] ?? .nan)) | "
                    + "\(Self.decimal(document.aggregateCoefficientsOfVariation[component] ?? .nan)) |"
            )
        }
        lines.append(contentsOf: [
            "",
            "本报告只含聚合指标、非设备唯一硬件描述、非设备唯一 session 标签与源记录 SHA-256；不含序列号、硬件 UUID、用户名、路径或 IP。",
            "",
        ])
        return lines.joined(separator: "\n")
    }

    func frozenSwiftSnippet(
        for artifacts: [MacBenchmarkCalibrationArtifact]
    ) -> String {
        let rows = artifacts.sorted { $0.profile.rawValue < $1.profile.rawValue }.map {
            artifact in
            "        FrozenMacBenchmarkCalibrationDocument(\n"
                + "            profile: .\(artifact.profile.rawValue),\n"
                + "            documentBase64: \"\(artifact.documentData.base64EncodedString())\",\n"
                + "            documentSHA256: \"\(artifact.documentSHA256)\"\n"
                + "        )"
        }
        return "private static let frozenDocuments: "
            + "[FrozenMacBenchmarkCalibrationDocument] = [\n"
            + rows.joined(separator: ",\n")
            + "\n]\n"
    }

    func requiredEnvironment(_ name: String) throws -> String {
        guard let value = environment(name) else {
            throw MacBenchmarkCalibrationError.invalidRawResult
        }
        return value
    }

    func releaseSourceBuild() throws -> MacBenchmarkCalibrationSourceBuild {
        let configurationURL = packageRoot()
            .appendingPathComponent("script/release_version.env")
        let contents = try String(contentsOf: configurationURL, encoding: .utf8)
        let values = Dictionary(uniqueKeysWithValues: contents.split(separator: "\n")
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            })
        guard let appVersion = values["DEFAULT_APP_VERSION"],
              let appBuild = values["DEFAULT_APP_BUILD"]
        else {
            throw MacBenchmarkCalibrationError.inconsistentSourceBuild
        }
        let sourceBuild = MacBenchmarkCalibrationSourceBuild(
            appVersion: appVersion,
            appBuild: appBuild
        )
        guard sourceBuild.isValid else {
            throw MacBenchmarkCalibrationError.inconsistentSourceBuild
        }
        return sourceBuild
    }

    func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func environment(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "invalid" }
        return String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func writeDiagnosticSummary(
        for result: MacBenchmarkRawResult,
        rejection: Error
    ) {
        let componentOrder = result.measurements
            .map(\.component.rawValue)
            .joined(separator: ",")
        let capabilitySet = result.capabilitySet.components
            .map(\.rawValue)
            .joined(separator: ",")
        let environmentSummary = [
            result.environment.architecture.rawValue,
            result.environment.chipName,
            "processors=\(result.environment.activeProcessorCount)",
            "memory=\(result.environment.physicalMemoryBytes)",
            "disk=\(String(describing: result.environment.systemDiskCapacityBytes))",
            "power=\(result.environment.powerSource.rawValue)",
            "thermal=\(result.environment.thermalState.rawValue)",
            "app=\(result.environment.appVersion)(\(result.environment.appBuild))",
        ].joined(separator: "/")
        let preflightSummary = [
            result.preflight.powerSource.rawValue,
            result.preflight.thermalState.rawValue,
            "lowPower=\(result.preflight.lowPowerModeEnabled)",
            "disk=\(result.preflight.diskReliability.rawValue)",
            "capacity=\(result.preflight.availableDiskBytes)",
            "required=\(result.preflight.requiredDiskBytes)",
            "warnings=\(result.preflight.warnings)",
        ].joined(separator: "/")
        let postflightDate = result.postflight.map { iso8601($0.capturedAt) } ?? "nil"
        let completionDate = result.completedAt.map(iso8601) ?? "nil"
        let timestampSummary = [
            iso8601(result.startedAt),
            iso8601(result.preflight.capturedAt),
            postflightDate,
            completionDate,
        ].joined(separator: "/")
        var lines = [
            "Calibration run rejected: \(rejection)",
            "profile=\(result.profile.rawValue)",
            "workload=\(result.workloadVersion)",
            "isComplete=\(result.isComplete)",
            "comparableEnvironment=\(MacBenchmarkScoring.hasComparableEnvironment(result))",
            "componentOrder=\(componentOrder)",
            "capabilitySet=\(capabilitySet)",
            "failure=\(String(describing: result.failure))",
            "environment=\(environmentSummary)",
            "preflight=\(preflightSummary)",
            "timestamps=\(timestampSummary)",
            "postflight=\(String(describing: result.postflight))",
        ]
        for measurement in result.measurements {
            let samples = measurement.samples.map { sample in
                "\(decimal(sample.value))@\(decimal(sample.elapsedSeconds))s"
            }.joined(separator: ",")
            let measurementSummary = [
                measurement.component.rawValue,
                "median=\(decimal(measurement.medianValue))",
                "cv=\(decimal(measurement.coefficientOfVariation))",
                "calibrationCV="
                    + decimal(measurement.calibrationStabilityCoefficientOfVariation),
                "samples=[\(samples)]",
            ].joined(separator: " ")
            lines.append(measurementSummary)
        }
        FileHandle.standardError.write(
            Data((lines.joined(separator: "\n") + "\n").utf8)
        )
    }
}

@inline(never)
private func isOptimizedReleaseCalibrationHarness() -> Bool {
    _isReleaseAssertConfiguration() && !_isDebugAssertConfiguration()
}

private struct MacBenchmarkCalibrationEnvironmentProvider:
    MacBenchmarkEnvironmentProviding
{
    let sourceBuild: MacBenchmarkCalibrationSourceBuild

    func metadata(preflight: BenchmarkPreflight) -> BenchmarkEnvironmentMetadata {
        let system = SystemMacBenchmarkEnvironmentProvider().metadata(
            preflight: preflight
        )
        return BenchmarkEnvironmentMetadata(
            architecture: system.architecture,
            chipName: system.chipName,
            activeProcessorCount: system.activeProcessorCount,
            physicalMemoryBytes: system.physicalMemoryBytes,
            systemDiskCapacityBytes: system.systemDiskCapacityBytes,
            powerSource: system.powerSource,
            thermalState: system.thermalState,
            operatingSystemVersion: system.operatingSystemVersion,
            appVersion: sourceBuild.appVersion,
            appBuild: sourceBuild.appBuild
        )
    }
}
