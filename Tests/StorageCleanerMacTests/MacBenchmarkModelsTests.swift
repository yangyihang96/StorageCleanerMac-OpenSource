import XCTest
@testable import StorageCleanerMac

final class MacBenchmarkModelsTests: XCTestCase {
    func testOnlyStandardProfileIsSelectableWhileLegacyProfilesRemainDecodable() throws {
        XCTAssertEqual(BenchmarkProfile.allCases, [.standard])
        XCTAssertEqual(BenchmarkProfile.legacyCases, [.quick, .full])
        XCTAssertEqual(
            BenchmarkProfile.persistedCases,
            [.standard, .quick, .full]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for profile in BenchmarkProfile.persistedCases {
            let encoded = try encoder.encode(profile)
            XCTAssertEqual(
                try decoder.decode(BenchmarkProfile.self, from: encoded),
                profile
            )
        }
    }

    func testComparisonKeySeparatesProfileArchitectureAndCapabilities() {
        let arm = BenchmarkComparisonKey(
            workloadVersion: "1",
            baselineVersion: "1",
            profile: .quick,
            architecture: .arm64,
            capabilitySet: .all
        )
        let intel = BenchmarkComparisonKey(
            workloadVersion: "1",
            baselineVersion: "1",
            profile: .quick,
            architecture: .x86_64,
            capabilitySet: .all
        )
        let cpuOnly = BenchmarkComparisonKey(
            workloadVersion: "1",
            baselineVersion: "1",
            profile: .quick,
            architecture: .arm64,
            capabilitySet: [.cpuSingle, .cpuMulti]
        )

        XCTAssertNotEqual(arm, intel)
        XCTAssertNotEqual(arm, cpuOnly)
        XCTAssertNotEqual(
            arm,
            BenchmarkComparisonKey(
                workloadVersion: "1",
                baselineVersion: "1",
                profile: .full,
                architecture: .arm64,
                capabilitySet: .all
            )
        )
    }

    func testIncompleteResultCannotExposeOverallScore() {
        let result = MacBenchmarkResult.incomplete(completed: [.cpuSingle: 100])

        XCTAssertNil(result.overallScore)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.componentScores[.cpuSingle], 100)
    }

    func testOverallScoreRequiresCompleteRawMetricsAndMatchingFrozenBaseline() throws {
        let raw = makeCompleteRawResult()
        let key = BenchmarkComparisonKey(
            workloadVersion: raw.workloadVersion,
            baselineVersion: "baseline-1",
            profile: raw.profile,
            architecture: raw.environment.architecture,
            capabilitySet: raw.capabilitySet
        )
        let componentScores = Dictionary(
            uniqueKeysWithValues: BenchmarkComponent.allCases.map { ($0, 1_000.0) }
        )

        let valid = MacBenchmarkResult(
            rawResult: raw,
            comparisonKey: key,
            matchedBaselineKey: key,
            componentScores: componentScores,
            proposedOverallScore: 1_000
        )
        XCTAssertEqual(valid.overallScore, 1_000)
        XCTAssertTrue(valid.isComplete)

        var mismatchedKey = key
        mismatchedKey.baselineVersion = "baseline-2"
        let mismatched = MacBenchmarkResult(
            rawResult: raw,
            comparisonKey: key,
            matchedBaselineKey: mismatchedKey,
            componentScores: componentScores,
            proposedOverallScore: 1_000
        )
        XCTAssertNil(mismatched.overallScore)

        var missingScore = componentScores
        missingScore[.gpu] = nil
        let incompleteScores = MacBenchmarkResult(
            rawResult: raw,
            comparisonKey: key,
            matchedBaselineKey: key,
            componentScores: missingScore,
            proposedOverallScore: 1_000
        )
        XCTAssertNil(incompleteScores.overallScore)

        let nonFinite = MacBenchmarkResult(
            rawResult: raw,
            comparisonKey: key,
            matchedBaselineKey: key,
            componentScores: componentScores,
            proposedOverallScore: .infinity
        )
        XCTAssertNil(nonFinite.overallScore)
    }

    func testRawResultCompletenessRejectsMissingAndInvalidMetrics() {
        let complete = makeCompleteRawResult()
        XCTAssertTrue(complete.isComplete)

        let missingPostflight = MacBenchmarkRawResult(
            profile: complete.profile,
            workloadVersion: complete.workloadVersion,
            startedAt: complete.startedAt,
            completedAt: complete.completedAt,
            environment: complete.environment,
            preflight: complete.preflight,
            postflight: nil,
            capabilitySet: complete.capabilitySet,
            measurements: complete.measurements,
            failure: nil
        )
        XCTAssertFalse(missingPostflight.isComplete)

        let missingGPU = MacBenchmarkRawResult(
            profile: complete.profile,
            workloadVersion: complete.workloadVersion,
            startedAt: complete.startedAt,
            completedAt: complete.completedAt,
            environment: complete.environment,
            preflight: complete.preflight,
            postflight: complete.postflight,
            capabilitySet: .all,
            measurements: complete.measurements.filter { $0.component != .gpu },
            failure: nil
        )
        XCTAssertFalse(missingGPU.isComplete)

        var invalidMeasurements = complete.measurements
        invalidMeasurements[0] = BenchmarkComponentMeasurement(
            component: .cpuSingle,
            unit: .millionOperationsPerSecond,
            samples: [
                BenchmarkComponentSample(value: .nan, elapsedSeconds: 1, checksum: 1)
            ]
        )
        let invalid = MacBenchmarkRawResult(
            profile: complete.profile,
            workloadVersion: complete.workloadVersion,
            startedAt: complete.startedAt,
            completedAt: complete.completedAt,
            environment: complete.environment,
            preflight: complete.preflight,
            postflight: complete.postflight,
            capabilitySet: .all,
            measurements: invalidMeasurements,
            failure: nil
        )
        XCTAssertFalse(invalid.isComplete)
    }

    func testRawResultCompletenessKeepsLegacyComputeAndStandard3DUnitsSeparate() {
        let legacy = makeCompleteRawResult()
        XCTAssertTrue(legacy.isComplete)

        let legacyWith3DUnit = copy(
            legacy,
            measurements: replacingGPUUnit(
                in: legacy.measurements,
                with: .millionTrianglesPerSecond
            )
        )
        XCTAssertFalse(legacyWith3DUnit.isComplete)

        let standard = copy(
            legacy,
            profile: .standard,
            workloadVersion: "mac-benchmark-standard-v6",
            measurements: replacingGPUUnit(
                in: legacy.measurements,
                with: .millionTrianglesPerSecond
            )
        )
        XCTAssertTrue(standard.isComplete)

        let standardWithComputeUnit = copy(
            standard,
            measurements: replacingGPUUnit(
                in: standard.measurements,
                with: .billionOperationsPerSecond
            )
        )
        XCTAssertFalse(standardWithComputeUnit.isComplete)
    }

    func testModelsRoundTripWithoutDeviceUniqueFields() throws {
        let raw = makeCompleteRawResult()
        let key = BenchmarkComparisonKey(
            workloadVersion: raw.workloadVersion,
            baselineVersion: "baseline-1",
            profile: raw.profile,
            architecture: raw.environment.architecture,
            capabilitySet: raw.capabilitySet
        )
        let componentScores = Dictionary(
            uniqueKeysWithValues: BenchmarkComponent.allCases.map { ($0, 1_000.0) }
        )
        let result = MacBenchmarkResult(
            rawResult: raw,
            comparisonKey: key,
            matchedBaselineKey: key,
            componentScores: componentScores,
            proposedOverallScore: 1_000
        )

        let data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(MacBenchmarkResult.self, from: data), result)

        let json = try XCTUnwrap(String(data: data, encoding: .utf8)).lowercased()
        for forbiddenKey in [
            "username", "user_name", "serialnumber", "serial_number",
            "hardwareuuid", "hardware_uuid", "udid", "ipaddress",
            "ip_address", "filepath", "file_path", "homepath", "home_path"
        ] {
            XCTAssertFalse(json.contains(forbiddenKey), "跑分报告不得包含字段：\(forbiddenKey)")
        }
    }

    func testPostflightDiskSnapshotRoundTripsAndLegacyJSONRemainsDecodable() throws {
        let postflight = BenchmarkPostflight(
            capturedAt: Date(timeIntervalSince1970: 1_790_000_020),
            powerSource: .acPower,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            diskReliability: .verified,
            availableDiskBytes: 90_000_000_000,
            requiredDiskBytes: 3_000_000_000,
            warnings: []
        )
        let encoded = try JSONEncoder().encode(postflight)
        XCTAssertEqual(
            try JSONDecoder().decode(BenchmarkPostflight.self, from: encoded),
            postflight
        )

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in [
            "diskReliability",
            "availableDiskBytes",
            "requiredDiskBytes",
            "warnings",
        ] {
            legacyObject.removeValue(forKey: key)
        }
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decodedLegacy = try JSONDecoder().decode(
            BenchmarkPostflight.self,
            from: legacyData
        )

        XCTAssertEqual(decodedLegacy.capturedAt, postflight.capturedAt)
        XCTAssertEqual(decodedLegacy.powerSource, .acPower)
        XCTAssertNil(decodedLegacy.diskReliability)
        XCTAssertNil(decodedLegacy.availableDiskBytes)
        XCTAssertNil(decodedLegacy.requiredDiskBytes)
        XCTAssertNil(decodedLegacy.warnings)
        XCTAssertFalse(decodedLegacy.hasCompleteDiskSnapshot)
    }

    func testRawOnlyRoundTripPreservesRawResultWithoutInventingBaselineVersion() throws {
        let raw = makeCompleteRawResult()
        let rawOnly = MacBenchmarkScoring.rawOnly(rawResult: raw)

        XCTAssertNil(rawOnly.comparisonKey)
        XCTAssertNil(rawOnly.matchedBaselineKey)
        XCTAssertNil(rawOnly.overallScore)
        XCTAssertTrue(rawOnly.componentScores.isEmpty)
        XCTAssertTrue(rawOnly.isComplete)

        let data = try JSONEncoder().encode(rawOnly)
        let decoded = try JSONDecoder().decode(MacBenchmarkResult.self, from: data)
        XCTAssertEqual(decoded, rawOnly)
        XCTAssertEqual(decoded.rawResult, raw)
        XCTAssertNil(decoded.comparisonKey)
    }

    func testArchitectureCurrentMatchesBuildArchitecture() {
        #if arch(arm64)
        XCTAssertEqual(BenchmarkArchitecture.current, .arm64)
        #elseif arch(x86_64)
        XCTAssertEqual(BenchmarkArchitecture.current, .x86_64)
        #else
        XCTAssertEqual(BenchmarkArchitecture.current, .unsupported)
        #endif
    }

    func testCapabilitySetIsStableCodableAndSetLike() throws {
        let capabilities: BenchmarkCapabilitySet = [.cpuSingle, .memory, .diskRead]
        XCTAssertTrue(capabilities.contains(.memory))
        XCTAssertFalse(capabilities.contains(.gpu))
        XCTAssertEqual(capabilities.count, 3)

        let data = try JSONEncoder().encode(capabilities)
        XCTAssertEqual(
            try JSONDecoder().decode(BenchmarkCapabilitySet.self, from: data),
            capabilities
        )
    }

    func testMeasurementUsesMedianAndCoefficientOfVariation() {
        let measurement = BenchmarkComponentMeasurement(
            component: .memory,
            unit: .decimalGigabytesPerSecond,
            samples: [
                BenchmarkComponentSample(value: 9, elapsedSeconds: 1, checksum: 1),
                BenchmarkComponentSample(value: 10, elapsedSeconds: 1, checksum: 1),
                BenchmarkComponentSample(value: 11, elapsedSeconds: 1, checksum: 1)
            ]
        )

        XCTAssertEqual(measurement.medianValue, 10, accuracy: 0.0001)
        XCTAssertEqual(measurement.coefficientOfVariation, 0.1, accuracy: 0.0001)
        XCTAssertTrue(measurement.isValid)
    }

    func testAlgorithmManifestUsesIndependentVersionsWithoutChangingFrozenSchema()
        throws {
        let legacy = makeCompleteRawResult()
        let standardMeasurements = replacingGPUUnit(
            in: legacy.measurements,
            with: .millionTrianglesPerSecond
        )
        let raw = MacBenchmarkRawResult(
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion,
            startedAt: legacy.startedAt,
            completedAt: legacy.completedAt,
            environment: legacy.environment,
            preflight: legacy.preflight,
            postflight: legacy.postflight,
            capabilitySet: legacy.capabilitySet,
            measurements: standardMeasurements,
            failure: nil
        )
        let key = BenchmarkComparisonKey(
            workloadVersion: raw.workloadVersion,
            baselineVersion: "reference-v6",
            profile: raw.profile,
            architecture: raw.environment.architecture,
            capabilitySet: raw.capabilitySet
        )
        let scores = Dictionary(
            uniqueKeysWithValues: BenchmarkComponent.allCases.map { ($0, 1_000.0) }
        )
        let result = MacBenchmarkResult(
            rawResult: raw,
            comparisonKey: key,
            matchedBaselineKey: key,
            componentScores: scores,
            proposedOverallScore: 6_000
        )

        XCTAssertEqual(
            result.algorithmManifest?.measurementSchemaVersion,
            BenchmarkAlgorithmManifest.measurementSchemaVersion
        )
        XCTAssertEqual(result.algorithmManifest?.workloadVersion, raw.workloadVersion)
        XCTAssertEqual(
            result.algorithmManifest?.statisticsVersion,
            BenchmarkStatistics.frozenResultVersion
        )
        XCTAssertEqual(
            result.algorithmManifest?.diagnosticStatisticsVersion,
            BenchmarkStatistics.version
        )
        XCTAssertEqual(
            result.algorithmManifest?.scoringVersion,
            "mac-benchmark-scoring-v6"
        )
        XCTAssertEqual(result.algorithmManifest?.referenceSetVersion, "reference-v6")
        XCTAssertEqual(
            result.algorithmManifest?.sessionID,
            BenchmarkSessionIdentity.stableID(for: raw)
        )

        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(MacBenchmarkResult.self, from: encoded)
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(
            decoded.algorithmManifest?.sessionID,
            result.algorithmManifest?.sessionID
        )
        let encodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNil(encodedObject["algorithmManifest"])
        let encodedRaw = try XCTUnwrap(encodedObject["rawResult"] as? [String: Any])
        XCTAssertNil(encodedRaw["sessionID"])
        XCTAssertNil(encodedRaw["measurementSchemaVersion"])
        XCTAssertNil(encodedRaw["statisticsVersion"])

        let frozenLegacy = copy(
            legacy,
            workloadVersion: "mac-benchmark-quick-v3",
            measurements: legacy.measurements
        )
        let legacyManifest = MacBenchmarkScoring.rawOnly(rawResult: frozenLegacy)
            .algorithmManifest
        XCTAssertEqual(
            legacyManifest?.statisticsVersion,
            BenchmarkStatistics.frozenResultVersion
        )
        XCTAssertEqual(
            legacyManifest?.diagnosticStatisticsVersion,
            BenchmarkStatistics.version
        )
        XCTAssertEqual(
            legacyManifest?.scoringVersion,
            "mac-benchmark-scoring-v3"
        )
    }

    func testCalibrationStabilityCoefficientToleratesOnlyOneModerateOutlier() {
        let moderateSchedulerOutlier = BenchmarkComponentMeasurement(
            component: .cpuMulti,
            unit: .millionOperationsPerSecond,
            samples: [5_457.9, 6_286.5, 6_539.5].map {
                BenchmarkComponentSample(value: $0, elapsedSeconds: 2, checksum: 1)
            }
        )
        XCTAssertGreaterThan(moderateSchedulerOutlier.coefficientOfVariation, 0.05)
        XCTAssertLessThan(
            moderateSchedulerOutlier.calibrationStabilityCoefficientOfVariation,
            0.05
        )

        let severeOutlier = BenchmarkComponentMeasurement(
            component: .cpuMulti,
            unit: .millionOperationsPerSecond,
            samples: [100, 100, 130].map {
                BenchmarkComponentSample(value: $0, elapsedSeconds: 2, checksum: 1)
            }
        )
        XCTAssertGreaterThan(
            severeOutlier.calibrationStabilityCoefficientOfVariation,
            0.05
        )

        let fullRunWithOneSevereIOOutlier = BenchmarkComponentMeasurement(
            component: .diskWrite,
            unit: .decimalGigabytesPerSecond,
            samples: [7.01, 7.08, 6.82, 6.94, 1.84].map {
                BenchmarkComponentSample(value: $0, elapsedSeconds: 1, checksum: 1)
            }
        )
        XCTAssertGreaterThan(fullRunWithOneSevereIOOutlier.coefficientOfVariation, 0.20)
        XCTAssertLessThan(
            fullRunWithOneSevereIOOutlier.calibrationStabilityCoefficientOfVariation,
            0.05
        )
    }

    func testStateAndFailureRemainCodable() throws {
        let states: [MacBenchmarkState] = [
            .idle,
            .preflighting(profile: .quick),
            .running(stage: .cpuSingle, progress: 0.25, elapsedSeconds: 1.5),
            .cancelling,
            .completed,
            .cancelled,
            .failed(.safetyCheck(.thermalNotNominal))
        ]

        let data = try JSONEncoder().encode(states)
        XCTAssertEqual(try JSONDecoder().decode([MacBenchmarkState].self, from: data), states)
    }

    func testStateMachineAcceptsOnlyDeclaredTransitions() {
        let preflight = MacBenchmarkState.preflighting(profile: .standard)
        let running = MacBenchmarkState.running(
            stage: .cpuSingle,
            progress: 0.1,
            elapsedSeconds: 1
        )

        XCTAssertTrue(MacBenchmarkState.idle.canTransition(to: preflight))
        XCTAssertTrue(preflight.canTransition(to: running))
        XCTAssertTrue(running.canTransition(to: .cancelling))
        XCTAssertTrue(MacBenchmarkState.cancelling.canTransition(to: .cancelled))
        XCTAssertTrue(MacBenchmarkState.completed.canTransition(to: preflight))
        XCTAssertTrue(MacBenchmarkState.cancelled.canTransition(to: preflight))
        XCTAssertTrue(
            MacBenchmarkState.failed(.invalidResult).canTransition(to: preflight)
        )

        XCTAssertFalse(MacBenchmarkState.idle.canTransition(to: running))
        XCTAssertFalse(MacBenchmarkState.completed.canTransition(to: .cancelled))
        XCTAssertFalse(MacBenchmarkState.cancelling.canTransition(to: .completed))
        XCTAssertFalse(running.canTransition(to: preflight))
        XCTAssertFalse(preflight.canTransition(to: .idle))
    }

    private func makeCompleteRawResult() -> MacBenchmarkRawResult {
        let samples = BenchmarkComponent.allCases.map { component in
            BenchmarkComponentMeasurement(
                component: component,
                unit: component.metricUnit,
                samples: [
                    BenchmarkComponentSample(value: 100, elapsedSeconds: 1, checksum: 42),
                    BenchmarkComponentSample(value: 101, elapsedSeconds: 1, checksum: 42),
                    BenchmarkComponentSample(value: 99, elapsedSeconds: 1, checksum: 42)
                ]
            )
        }
        return MacBenchmarkRawResult(
            profile: .quick,
            workloadVersion: "workload-1",
            startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            completedAt: Date(timeIntervalSince1970: 1_790_000_020),
            environment: BenchmarkEnvironmentMetadata(
                architecture: .current,
                chipName: "Apple M5 Pro",
                activeProcessorCount: 18,
                physicalMemoryBytes: 48 * 1_024 * 1_024 * 1_024,
                powerSource: .acPower,
                thermalState: .nominal,
                operatingSystemVersion: "macOS 26",
                appVersion: "1.5.0",
                appBuild: "202607160001"
            ),
            preflight: BenchmarkPreflight(
                capturedAt: Date(timeIntervalSince1970: 1_790_000_000),
                powerSource: .acPower,
                batteryPercent: 80,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 100 * 1_024 * 1_024 * 1_024,
                requiredDiskBytes: 3 * 1_024 * 1_024 * 1_024,
                warnings: []
            ),
            postflight: BenchmarkPostflight(
                capturedAt: Date(timeIntervalSince1970: 1_790_000_020),
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .nominal
            ),
            capabilitySet: .all,
            measurements: samples,
            failure: nil
        )
    }

    private func replacingGPUUnit(
        in measurements: [BenchmarkComponentMeasurement],
        with unit: BenchmarkMetricUnit
    ) -> [BenchmarkComponentMeasurement] {
        measurements.map { measurement in
            guard measurement.component == .gpu else { return measurement }
            return BenchmarkComponentMeasurement(
                component: .gpu,
                unit: unit,
                samples: measurement.samples
            )
        }
    }

    private func copy(
        _ raw: MacBenchmarkRawResult,
        profile: BenchmarkProfile? = nil,
        workloadVersion: String? = nil,
        measurements: [BenchmarkComponentMeasurement]
    ) -> MacBenchmarkRawResult {
        MacBenchmarkRawResult(
            profile: profile ?? raw.profile,
            workloadVersion: workloadVersion ?? raw.workloadVersion,
            startedAt: raw.startedAt,
            completedAt: raw.completedAt,
            environment: raw.environment,
            preflight: raw.preflight,
            postflight: raw.postflight,
            capabilitySet: raw.capabilitySet,
            measurements: measurements,
            failure: raw.failure
        )
    }
}
