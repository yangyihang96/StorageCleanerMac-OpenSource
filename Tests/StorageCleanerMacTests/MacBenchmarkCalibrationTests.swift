import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacBenchmarkCalibrationTests: XCTestCase {
    func testProductionV6UsesTheFreshFrozenBaseline() throws {
        let raw = makeRawResult(profile: .standard, runIndex: 0)
        let runtimeCatalog = MacBenchmarkProductionBaselineCatalog.runtimeCatalog()
        guard case let .matched(verified) = runtimeCatalog.lookup(matching: raw) else {
            return XCTFail("Standard v6 应匹配正式冻结基线")
        }
        XCTAssertEqual(
            verified.baseline.comparisonKey.baselineVersion,
            MacBenchmarkProductionBaselineCatalog.activeBaselineVersion
        )
        XCTAssertEqual(
            verified.baseline.comparisonKey.workloadVersion,
            MacBenchmarkScoring.balancedCompositeWorkloadVersion
        )

        let emptyVerified = try MacBenchmarkFrozenCatalogLoader.verifiedBaselines(
            from: [],
            activeBaselineVersion: "m5-pro-2026-07-v1",
            requireCompleteProfileSet: false
        )
        let rawOnlyCatalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "m5-pro-2026-07-v1",
            verifiedBaselines: emptyVerified
        )

        XCTAssertEqual(
            rawOnlyCatalog.lookup(matching: raw),
            .notFound
        )
        XCTAssertThrowsError(
            try MacBenchmarkFrozenCatalogLoader.verifiedBaselines(
                from: [],
                activeBaselineVersion: "m5-pro-2026-07-v1",
                requireCompleteProfileSet: true
            )
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkCalibrationError,
                .incompleteProfileSet
            )
        }
    }

    func testProductionV6NeverRekeysLegacyReferencesIntoTheActiveScore() {
        let catalog = MacBenchmarkProductionBaselineCatalog.runtimeCatalog()

        for profile in BenchmarkProfile.legacyCases {
            let seed = makeRawResult(profile: profile, runIndex: 0)
            XCTAssertEqual(catalog.lookup(matching: seed), .notFound)
        }

        let activeSeed = makeRawResult(profile: .standard, runIndex: 0)
        guard case .matched = catalog.lookup(matching: activeSeed) else {
            return XCTFail("Standard v6 不应被旧版基线隔离规则误伤")
        }
    }

    func testEightRunsAcrossTwoSessionsProduceMedianArtifactsForBothProfiles() throws {
        let records = validRecords()
        let artifacts = try MacBenchmarkCalibrationAggregator().makeArtifacts(
            records: records,
            baselineVersion: "m5-pro-2026-07-v1",
            frozenAt: frozenAt
        )

        XCTAssertEqual(Set(artifacts.map(\.profile)), Set(BenchmarkProfile.legacyCases))
        for artifact in artifacts {
            XCTAssertEqual(artifact.document.validRunCount, 8)
            XCTAssertEqual(artifact.document.independentSessionCount, 2)
            XCTAssertEqual(
                artifact.document.baselineReport.sourceRunSHA256s.count,
                8
            )
            XCTAssertEqual(
                artifact.document.baselineReport.key.profile,
                artifact.profile
            )
            XCTAssertEqual(
                artifact.document.baselineReport.referenceHardware,
                MacBenchmarkCalibrationHardware.m5ProReference.referenceDescription
            )
            for component in BenchmarkComponent.allCases {
                XCTAssertLessThanOrEqual(
                    try XCTUnwrap(
                        artifact.document.aggregateCoefficientsOfVariation[component]
                    ),
                    0.05
                )
            }
        }

        let frozen = artifacts.map {
            return FrozenMacBenchmarkCalibrationDocument(
                profile: $0.profile,
                documentBase64: $0.documentData.base64EncodedString(),
                documentSHA256: $0.documentSHA256
            )
        }
        let verified = try MacBenchmarkFrozenCatalogLoader.verifiedBaselines(
            from: frozen,
            activeBaselineVersion: "m5-pro-2026-07-v1",
            requireCompleteProfileSet: true,
            requiredProfiles: BenchmarkProfile.legacyCases
        )
        XCTAssertEqual(verified.count, 2)

        let catalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "m5-pro-2026-07-v1",
            verifiedBaselines: verified
        )
        let ordinaryArmMacResult = rawResult(
            replacingEnvironmentIn: makeRawResult(profile: .quick, runIndex: 20),
            chipName: "Apple M4",
            processorCount: 10,
            memoryBytes: 16 * 1_024 * 1_024 * 1_024
        )
        guard case .matched = catalog.lookup(matching: ordinaryArmMacResult) else {
            return XCTFail("冻结基线应按 comparison key 服务所有匹配的 arm64 Mac")
        }
    }

    func testCalibrationRejectsFewerThanEightRunsForEitherProfile() {
        let records = validRecords().enumerated().filter { index, record in
            !(index == 0 && record.rawResult.profile == .quick)
        }.map(\.element)

        XCTAssertThrowsError(
            try MacBenchmarkCalibrationAggregator().makeArtifacts(
                records: records,
                baselineVersion: "m5-pro-2026-07-v1",
                frozenAt: frozenAt
            )
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkCalibrationError,
                .insufficientValidRuns(profile: .quick, actual: 7)
            )
        }
    }

    func testCalibrationRejectsOneSessionEvenWithEightRuns() {
        let records = BenchmarkProfile.legacyCases.flatMap { profile in
            (0..<8).map { index in
                MacBenchmarkCalibrationRunRecord(
                    sessionLabel: "session-1",
                    hardware: .m5ProReference,
                    rawResult: makeRawResult(profile: profile, runIndex: index)
                )
            }
        }

        XCTAssertThrowsError(
            try MacBenchmarkCalibrationAggregator().makeArtifacts(
                records: records,
                baselineVersion: "m5-pro-2026-07-v1",
                frozenAt: frozenAt
            )
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkCalibrationError,
                .insufficientIndependentSessions(profile: .quick, actual: 1)
            )
        }
    }

    func testCalibrationRejectsSevenPlusOneSessionDistribution() {
        let records = BenchmarkProfile.legacyCases.flatMap { profile in
            (0..<8).map { index in
                MacBenchmarkCalibrationRunRecord(
                    sessionLabel: index < 7 ? "session-1" : "session-2",
                    hardware: .m5ProReference,
                    rawResult: makeRawResult(
                        profile: profile,
                        runIndex: index < 7 ? index : 8
                    )
                )
            }
        }

        XCTAssertThrowsError(
            try MacBenchmarkCalibrationAggregator().makeArtifacts(
                records: records,
                baselineVersion: "m5-pro-2026-07-v1",
                frozenAt: Date(timeIntervalSince1970: 1_800_030_000)
            )
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkCalibrationError,
                .insufficientRunsPerSession(
                    profile: .quick,
                    sessionLabel: "session-2",
                    actual: 1
                )
            )
        }
    }

    func testCalibrationRejectsUnsafeSessionLabelsAndWrongReferenceHardware() {
        for label in ["session-01", "session-١", "my-session", "session-"] {
            var records = validRecords()
            records[0] = MacBenchmarkCalibrationRunRecord(
                sessionLabel: label,
                hardware: .m5ProReference,
                rawResult: records[0].rawResult
            )
            XCTAssertThrowsError(
                try MacBenchmarkCalibrationAggregator().makeArtifacts(
                    records: records,
                    baselineVersion: "m5-pro-2026-07-v1",
                    frozenAt: frozenAt
                )
            ) { error in
                XCTAssertEqual(
                    error as? MacBenchmarkCalibrationError,
                    .invalidSessionLabel
                )
            }
        }

        var records = validRecords()
        records[0] = MacBenchmarkCalibrationRunRecord(
            sessionLabel: "session-1",
            hardware: MacBenchmarkCalibrationHardware(
                modelIdentifier: "Mac99,9",
                chipName: "Apple M5 Pro",
                activeProcessorCount: 18,
                physicalMemoryBytes: 48 * 1_024 * 1_024 * 1_024,
                architecture: .arm64
            ),
            rawResult: records[0].rawResult
        )
        XCTAssertThrowsError(
            try MacBenchmarkCalibrationAggregator().makeArtifacts(
                records: records,
                baselineVersion: "m5-pro-2026-07-v1",
                frozenAt: frozenAt
            )
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkCalibrationError,
                .referenceHardwareMismatch
            )
        }
    }

    func testCalibrationRejectsWithinRunCVAboveFivePercent() {
        var records = validRecords()
        records[0] = MacBenchmarkCalibrationRunRecord(
            sessionLabel: "session-1",
            hardware: .m5ProReference,
            rawResult: makeRawResult(
                profile: .quick,
                runIndex: 0,
                unstableComponent: .cpuSingle
            )
        )

        XCTAssertThrowsError(
            try MacBenchmarkCalibrationAggregator().makeArtifacts(
                records: records,
                baselineVersion: "m5-pro-2026-07-v1",
                frozenAt: frozenAt
            )
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkCalibrationError,
                .excessiveWithinRunVariation(.cpuSingle)
            )
        }
    }

    func testCalibrationRejectsCrossRunStandardComponentCVAboveFivePercent() {
        let records = BenchmarkProfile.legacyCases.flatMap { profile in
            (0..<8).map { index in
                MacBenchmarkCalibrationRunRecord(
                    sessionLabel: index < 4 ? "session-1" : "session-2",
                    hardware: .m5ProReference,
                    rawResult: makeRawResult(
                        profile: profile,
                        runIndex: index,
                        runScale: profile == .quick && index == 7 ? 1.30 : 1
                    )
                )
            }
        }

        XCTAssertThrowsError(
            try MacBenchmarkCalibrationAggregator().makeArtifacts(
                records: records,
                baselineVersion: "m5-pro-2026-07-v1",
                frozenAt: frozenAt
            )
        ) { error in
            guard let calibrationError = error as? MacBenchmarkCalibrationError,
                  case let .excessiveAggregateVariation(profile, component) =
                    calibrationError
            else {
                return XCTFail("应拒绝跨 run 波动过大的校准，实际：\(error)")
            }
            XCTAssertEqual(profile, .quick)
            XCTAssertNotEqual(component, .gpu)
            XCTAssertNotEqual(component, .diskWrite)
        }
    }

    func testCalibrationAcceptsGPUAggregateCVBetweenFiveAndTenPercent() throws {
        let records = BenchmarkProfile.legacyCases.flatMap { profile in
            (0..<8).map { index in
                MacBenchmarkCalibrationRunRecord(
                    sessionLabel: index < 4 ? "session-1" : "session-2",
                    hardware: .m5ProReference,
                    rawResult: makeRawResult(
                        profile: profile,
                        runIndex: index,
                        runScale: profile == .quick && index >= 4 ? 0.85 : 1,
                        runScaleComponent: .gpu
                    )
                )
            }
        }

        let artifacts = try MacBenchmarkCalibrationAggregator().makeArtifacts(
            records: records,
            baselineVersion: "m5-pro-2026-07-v1",
            frozenAt: frozenAt
        )
        let quick = try XCTUnwrap(artifacts.first { $0.profile == .quick })
        let gpuCV = try XCTUnwrap(
            quick.document.aggregateCoefficientsOfVariation[.gpu]
        )
        XCTAssertGreaterThan(gpuCV, 0.05)
        XCTAssertLessThanOrEqual(gpuCV, 0.10)
        XCTAssertEqual(
            quick.document.maximumAllowedGPUAggregateCoefficientOfVariation,
            0.10
        )
    }

    func testCalibrationRejectsGPUAggregateCVAboveTenPercent() {
        let records = BenchmarkProfile.legacyCases.flatMap { profile in
            (0..<8).map { index in
                MacBenchmarkCalibrationRunRecord(
                    sessionLabel: index < 4 ? "session-1" : "session-2",
                    hardware: .m5ProReference,
                    rawResult: makeRawResult(
                        profile: profile,
                        runIndex: index,
                        runScale: profile == .quick && index >= 4 ? 0.75 : 1,
                        runScaleComponent: .gpu
                    )
                )
            }
        }

        XCTAssertThrowsError(
            try MacBenchmarkCalibrationAggregator().makeArtifacts(
                records: records,
                baselineVersion: "m5-pro-2026-07-v1",
                frozenAt: frozenAt
            )
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkCalibrationError,
                .excessiveAggregateVariation(profile: .quick, component: .gpu)
            )
        }
    }

    func testCalibrationAcceptsDurableWriteAggregateCVBetweenFiveAndTenPercent() throws {
        let records = BenchmarkProfile.legacyCases.flatMap { profile in
            (0..<8).map { index in
                MacBenchmarkCalibrationRunRecord(
                    sessionLabel: index < 4 ? "session-1" : "session-2",
                    hardware: .m5ProReference,
                    rawResult: makeRawResult(
                        profile: profile,
                        runIndex: index,
                        runScale: profile == .quick && index >= 4 ? 0.85 : 1,
                        runScaleComponent: .diskWrite
                    )
                )
            }
        }

        let artifacts = try MacBenchmarkCalibrationAggregator().makeArtifacts(
            records: records,
            baselineVersion: "m5-pro-2026-07-v1",
            frozenAt: frozenAt
        )
        let quick = try XCTUnwrap(artifacts.first { $0.profile == .quick })
        let diskWriteCV = try XCTUnwrap(
            quick.document.aggregateCoefficientsOfVariation[.diskWrite]
        )
        XCTAssertGreaterThan(diskWriteCV, 0.05)
        XCTAssertLessThanOrEqual(diskWriteCV, 0.10)
        XCTAssertEqual(
            quick.document.maximumAllowedDurableWriteAggregateCoefficientOfVariation,
            0.10
        )
    }

    func testCalibrationRejectsDurableWriteAggregateCVAboveTenPercent() {
        let records = BenchmarkProfile.legacyCases.flatMap { profile in
            (0..<8).map { index in
                MacBenchmarkCalibrationRunRecord(
                    sessionLabel: index < 4 ? "session-1" : "session-2",
                    hardware: .m5ProReference,
                    rawResult: makeRawResult(
                        profile: profile,
                        runIndex: index,
                        runScale: profile == .quick && index >= 4 ? 0.75 : 1,
                        runScaleComponent: .diskWrite
                    )
                )
            }
        }

        XCTAssertThrowsError(
            try MacBenchmarkCalibrationAggregator().makeArtifacts(
                records: records,
                baselineVersion: "m5-pro-2026-07-v1",
                frozenAt: frozenAt
            )
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkCalibrationError,
                .excessiveAggregateVariation(
                    profile: .quick,
                    component: .diskWrite
                )
            )
        }
    }

    func testFrozenLoaderRejectsOuterHashAndInnerEvidenceTampering() throws {
        let artifacts = try MacBenchmarkCalibrationAggregator().makeArtifacts(
            records: validRecords(),
            baselineVersion: "m5-pro-2026-07-v1",
            frozenAt: frozenAt
        )
        let valid = artifacts.map {
            FrozenMacBenchmarkCalibrationDocument(
                profile: $0.profile,
                documentBase64: $0.documentData.base64EncodedString(),
                documentSHA256: $0.documentSHA256
            )
        }
        var badHash = valid
        badHash[0] = FrozenMacBenchmarkCalibrationDocument(
            profile: badHash[0].profile,
            documentBase64: badHash[0].documentBase64,
            documentSHA256: String(repeating: "0", count: 64)
        )
        XCTAssertThrowsError(
            try MacBenchmarkFrozenCatalogLoader.verifiedBaselines(
                from: badHash,
                activeBaselineVersion: "m5-pro-2026-07-v1",
                requireCompleteProfileSet: true,
                requiredProfiles: BenchmarkProfile.legacyCases
            )
        )

        var document = artifacts[0].document
        let tampered = MacBenchmarkCalibrationDocument(
            schemaVersion: document.schemaVersion,
            baselineReport: document.baselineReport,
            baselineReportBase64: document.baselineReportBase64,
            baselineReportSHA256: document.baselineReportSHA256,
            hardware: document.hardware,
            harnessIdentifier: document.harnessIdentifier,
            sourceBuild: document.sourceBuild,
            validRunCount: document.validRunCount + 1,
            independentSessionCount: document.independentSessionCount,
            maximumAllowedCoefficientOfVariation:
                document.maximumAllowedCoefficientOfVariation,
            maximumAllowedGPUAggregateCoefficientOfVariation:
                document.maximumAllowedGPUAggregateCoefficientOfVariation,
            maximumAllowedDurableWriteAggregateCoefficientOfVariation:
                document.maximumAllowedDurableWriteAggregateCoefficientOfVariation,
            aggregateCoefficientsOfVariation:
                document.aggregateCoefficientsOfVariation,
            runs: document.runs
        )
        document = tampered
        let tamperedData = try MacBenchmarkCalibrationCoding.canonicalData(document)
        var innerTampering = valid
        innerTampering[0] = FrozenMacBenchmarkCalibrationDocument(
            profile: artifacts[0].profile,
            documentBase64: tamperedData.base64EncodedString(),
            documentSHA256: MacBenchmarkBaselineVerification.sha256Hex(tamperedData)
        )
        XCTAssertThrowsError(
            try MacBenchmarkFrozenCatalogLoader.verifiedBaselines(
                from: innerTampering,
                activeBaselineVersion: "m5-pro-2026-07-v1",
                requireCompleteProfileSet: true,
                requiredProfiles: BenchmarkProfile.legacyCases
            )
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkCalibrationError,
                .invalidCalibrationDocument
            )
        }
    }

    func testFrozenLoaderRejectsSevenPlusOneSessionDistribution() throws {
        let artifacts = try MacBenchmarkCalibrationAggregator().makeArtifacts(
            records: validRecords(),
            baselineVersion: "m5-pro-2026-07-v1",
            frozenAt: frozenAt
        )
        let frozen = try artifacts.map { artifact in
            guard artifact.profile == .quick else {
                return FrozenMacBenchmarkCalibrationDocument(
                    profile: artifact.profile,
                    documentBase64: artifact.documentData.base64EncodedString(),
                    documentSHA256: artifact.documentSHA256
                )
            }

            var sessionTwoRunsSeen = 0
            let runs = artifact.document.runs.map { summary in
                guard summary.sessionLabel == "session-2" else { return summary }
                sessionTwoRunsSeen += 1
                guard sessionTwoRunsSeen < 4 else { return summary }
                return runSummary(
                    replacingSessionLabelIn: summary,
                    with: "session-1"
                )
            }
            let document = MacBenchmarkCalibrationDocument(
                schemaVersion: artifact.document.schemaVersion,
                baselineReport: artifact.document.baselineReport,
                baselineReportBase64: artifact.document.baselineReportBase64,
                baselineReportSHA256: artifact.document.baselineReportSHA256,
                hardware: artifact.document.hardware,
                harnessIdentifier: artifact.document.harnessIdentifier,
                sourceBuild: artifact.document.sourceBuild,
                validRunCount: artifact.document.validRunCount,
                independentSessionCount: artifact.document.independentSessionCount,
                maximumAllowedCoefficientOfVariation:
                    artifact.document.maximumAllowedCoefficientOfVariation,
                maximumAllowedGPUAggregateCoefficientOfVariation:
                    artifact.document
                        .maximumAllowedGPUAggregateCoefficientOfVariation,
                maximumAllowedDurableWriteAggregateCoefficientOfVariation:
                    artifact.document
                        .maximumAllowedDurableWriteAggregateCoefficientOfVariation,
                aggregateCoefficientsOfVariation:
                    artifact.document.aggregateCoefficientsOfVariation,
                runs: runs
            )
            let data = try MacBenchmarkCalibrationCoding.canonicalData(document)
            return FrozenMacBenchmarkCalibrationDocument(
                profile: artifact.profile,
                documentBase64: data.base64EncodedString(),
                documentSHA256: MacBenchmarkBaselineVerification.sha256Hex(data)
            )
        }

        XCTAssertThrowsError(
            try MacBenchmarkFrozenCatalogLoader.verifiedBaselines(
                from: frozen,
                activeBaselineVersion: "m5-pro-2026-07-v1",
                requireCompleteProfileSet: true,
                requiredProfiles: BenchmarkProfile.legacyCases
            )
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkCalibrationError,
                .invalidCalibrationDocument
            )
        }
    }

    func testSourceRecordsMustRemainCanonicalAndContainNoUniqueDeviceFields() throws {
        let record = validRecords()[0]
        let data = try MacBenchmarkCalibrationCoding.canonicalData(record)
        XCTAssertEqual(
            try MacBenchmarkCalibrationAggregator().validateCanonicalRecordData(data),
            record
        )
        var nonCanonical = data
        nonCanonical.append(0x0A)
        XCTAssertThrowsError(
            try MacBenchmarkCalibrationAggregator()
                .validateCanonicalRecordData(nonCanonical)
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkCalibrationError,
                .nonCanonicalSourceRun
            )
        }

        let json = try XCTUnwrap(String(data: data, encoding: .utf8)).lowercased()
        for forbidden in [
            "serialnumber", "serial_number", "hardwareuuid", "hardware_uuid",
            "udid", "username", "user_name", "ipaddress", "ip_address",
            "filepath", "file_path", "homepath", "home_path"
        ] {
            XCTAssertFalse(json.contains(forbidden), "不得写入设备唯一或个人字段：\(forbidden)")
        }
    }

    func testInputOrderDoesNotChangeFrozenDocumentBytes() throws {
        let forward = try MacBenchmarkCalibrationAggregator().makeArtifacts(
            records: validRecords(),
            baselineVersion: "m5-pro-2026-07-v1",
            frozenAt: frozenAt
        )
        let reversed = try MacBenchmarkCalibrationAggregator().makeArtifacts(
            records: Array(validRecords().reversed()),
            baselineVersion: "m5-pro-2026-07-v1",
            frozenAt: frozenAt
        )

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: forward.map { ($0.profile, $0.documentData) }),
            Dictionary(uniqueKeysWithValues: reversed.map { ($0.profile, $0.documentData) })
        )
    }

    func testCalibrationRejectsUncooledSessionsAndEarlyFrozenDate() {
        var uncooled = validRecords()
        for index in uncooled.indices where uncooled[index].sessionLabel == "session-2" {
            let original = uncooled[index]
            uncooled[index] = MacBenchmarkCalibrationRunRecord(
                sessionLabel: "session-2",
                hardware: .m5ProReference,
                rawResult: makeRawResult(
                    profile: original.rawResult.profile,
                    runIndex: (index % 8) % 4
                )
            )
        }
        XCTAssertThrowsError(
            try MacBenchmarkCalibrationAggregator().makeArtifacts(
                records: uncooled,
                baselineVersion: "m5-pro-2026-07-v1",
                frozenAt: frozenAt
            )
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkCalibrationError,
                .insufficientCoolingInterval
            )
        }

        XCTAssertThrowsError(
            try MacBenchmarkCalibrationAggregator().makeArtifacts(
                records: validRecords(),
                baselineVersion: "m5-pro-2026-07-v1",
                frozenAt: Date(timeIntervalSince1970: 1_800_000_001)
            )
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkCalibrationError,
                .invalidFrozenDate
            )
        }
    }

    func testCalibrationRejectsMixedHarnessBuilds() {
        var records = validRecords()
        let original = records[0]
        records[0] = MacBenchmarkCalibrationRunRecord(
            sessionLabel: original.sessionLabel,
            hardware: .m5ProReference,
            rawResult: rawResult(
                replacingSourceBuildIn: original.rawResult,
                appVersion: "1.5.0",
                appBuild: "202607169999"
            )
        )

        XCTAssertThrowsError(
            try MacBenchmarkCalibrationAggregator().makeArtifacts(
                records: records,
                baselineVersion: "m5-pro-2026-07-v1",
                frozenAt: frozenAt
            )
        ) { error in
            XCTAssertEqual(
                error as? MacBenchmarkCalibrationError,
                .inconsistentSourceBuild
            )
        }
    }

    func testRuntimeLoaderUsesFrozenBytesWithoutCrossPlatformReencoding() throws {
        let artifacts = try MacBenchmarkCalibrationAggregator().makeArtifacts(
            records: validRecords(),
            baselineVersion: "m5-pro-2026-07-v1",
            frozenAt: frozenAt
        )
        let nonCanonical = try artifacts.map { artifact in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(artifact.document)
            return FrozenMacBenchmarkCalibrationDocument(
                profile: artifact.profile,
                documentBase64: data.base64EncodedString(),
                documentSHA256: MacBenchmarkBaselineVerification.sha256Hex(data)
            )
        }

        XCTAssertEqual(
            try MacBenchmarkFrozenCatalogLoader.verifiedBaselines(
                from: nonCanonical,
                activeBaselineVersion: "m5-pro-2026-07-v1",
                requireCompleteProfileSet: true,
                requireCanonicalEncoding: false,
                requiredProfiles: BenchmarkProfile.legacyCases
            ).count,
            2
        )
        XCTAssertThrowsError(
            try MacBenchmarkFrozenCatalogLoader.verifiedBaselines(
                from: nonCanonical,
                activeBaselineVersion: "m5-pro-2026-07-v1",
                requireCompleteProfileSet: true,
                requireCanonicalEncoding: true,
                requiredProfiles: BenchmarkProfile.legacyCases
            )
        )
    }
}

private extension MacBenchmarkCalibrationTests {
    var frozenAt: Date { Date(timeIntervalSince1970: 1_800_020_000) }

    func validRecords() -> [MacBenchmarkCalibrationRunRecord] {
        BenchmarkProfile.legacyCases.flatMap { profile in
            (0..<8).map { index in
                MacBenchmarkCalibrationRunRecord(
                    sessionLabel: index < 4 ? "session-1" : "session-2",
                    hardware: .m5ProReference,
                    rawResult: makeRawResult(profile: profile, runIndex: index)
                )
            }
        }
    }

    func runSummary(
        replacingSessionLabelIn summary: MacBenchmarkCalibrationRunSummary,
        with sessionLabel: String
    ) -> MacBenchmarkCalibrationRunSummary {
        MacBenchmarkCalibrationRunSummary(
            sourceRunSHA256: summary.sourceRunSHA256,
            sessionLabel: sessionLabel,
            startedAt: summary.startedAt,
            completedAt: summary.completedAt,
            profile: summary.profile,
            workloadVersion: summary.workloadVersion,
            sourceBuild: summary.sourceBuild,
            componentMedians: summary.componentMedians,
            componentCoefficientsOfVariation:
                summary.componentCoefficientsOfVariation
        )
    }

    func makeRawResult(
        profile: BenchmarkProfile,
        runIndex: Int,
        unstableComponent: BenchmarkComponent? = nil,
        runScale: Double = 1,
        runScaleComponent: BenchmarkComponent? = nil
    ) -> MacBenchmarkRawResult {
        let sessionIndex = runIndex / 4
        let indexWithinSession = runIndex % 4
        let profileOffset = profile == .quick ? 0 : 1_000
        let startedAt = Date(
            timeIntervalSince1970: 1_800_000_000
                + Double(sessionIndex * 10_000)
                + Double(profileOffset + indexWithinSession * 100)
        )
        let measurements = BenchmarkComponent.allCases.enumerated().map {
            componentIndex, component in
            let componentScale = runScaleComponent.map { $0 == component }
                ?? true
            let base = (1_000 + Double(componentIndex) * 100)
                * (1 + (Double(runIndex) - 3.5) * 0.001)
                * (componentScale ? runScale : 1)
            let factors = component == unstableComponent
                ? [0.5, 1.0, 1.5]
                : [0.995, 1.0, 1.005]
            return BenchmarkComponentMeasurement(
                component: component,
                unit: component.metricUnit,
                samples: factors.enumerated().map { sampleIndex, factor in
                    BenchmarkComponentSample(
                        value: base * factor,
                        elapsedSeconds: 1 + Double(sampleIndex) / 100,
                        checksum: UInt64(componentIndex + 1)
                    )
                }
            )
        }
        let hardware = MacBenchmarkCalibrationHardware.m5ProReference
        return MacBenchmarkRawResult(
            profile: profile,
            workloadVersion: MacBenchmarkService.workloadVersion(for: profile),
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(60),
            environment: BenchmarkEnvironmentMetadata(
                architecture: .arm64,
                chipName: hardware.chipName,
                activeProcessorCount: hardware.activeProcessorCount,
                physicalMemoryBytes: hardware.physicalMemoryBytes,
                powerSource: .acPower,
                thermalState: .nominal,
                operatingSystemVersion: "macOS 26",
                appVersion: "1.5.0",
                appBuild: "202607160001"
            ),
            preflight: BenchmarkPreflight(
                capturedAt: startedAt.addingTimeInterval(1),
                powerSource: .acPower,
                batteryPercent: 80,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 100_000_000_000,
                requiredDiskBytes: 3_000_000_000,
                warnings: []
            ),
            postflight: BenchmarkPostflight(
                capturedAt: startedAt.addingTimeInterval(59),
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .nominal
            ),
            capabilitySet: .all,
            measurements: measurements,
            failure: nil
        )
    }

    func rawResult(
        replacingMeasurementsIn raw: MacBenchmarkRawResult,
        with referenceMetrics: [BenchmarkComponent: Double]
    ) -> MacBenchmarkRawResult {
        let measurements = BenchmarkComponent.allCases.compactMap { component in
            referenceMetrics[component].map { value in
                BenchmarkComponentMeasurement(
                    component: component,
                    unit: component.metricUnit,
                    samples: (0..<3).map { sampleIndex in
                        BenchmarkComponentSample(
                            value: value,
                            elapsedSeconds: 1 + Double(sampleIndex) / 100,
                            checksum: UInt64(sampleIndex + 1)
                        )
                    }
                )
            }
        }
        return MacBenchmarkRawResult(
            profile: raw.profile,
            workloadVersion: raw.workloadVersion,
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

    func rawResult(
        replacingEnvironmentIn raw: MacBenchmarkRawResult,
        chipName: String,
        processorCount: Int,
        memoryBytes: UInt64
    ) -> MacBenchmarkRawResult {
        MacBenchmarkRawResult(
            profile: raw.profile,
            workloadVersion: raw.workloadVersion,
            startedAt: raw.startedAt,
            completedAt: raw.completedAt,
            environment: BenchmarkEnvironmentMetadata(
                architecture: .arm64,
                chipName: chipName,
                activeProcessorCount: processorCount,
                physicalMemoryBytes: memoryBytes,
                powerSource: raw.environment.powerSource,
                thermalState: raw.environment.thermalState,
                operatingSystemVersion: raw.environment.operatingSystemVersion,
                appVersion: raw.environment.appVersion,
                appBuild: raw.environment.appBuild
            ),
            preflight: raw.preflight,
            postflight: raw.postflight,
            capabilitySet: raw.capabilitySet,
            measurements: raw.measurements,
            failure: raw.failure
        )
    }

    func rawResult(
        replacingSourceBuildIn raw: MacBenchmarkRawResult,
        appVersion: String,
        appBuild: String
    ) -> MacBenchmarkRawResult {
        MacBenchmarkRawResult(
            profile: raw.profile,
            workloadVersion: raw.workloadVersion,
            startedAt: raw.startedAt,
            completedAt: raw.completedAt,
            environment: BenchmarkEnvironmentMetadata(
                architecture: raw.environment.architecture,
                chipName: raw.environment.chipName,
                activeProcessorCount: raw.environment.activeProcessorCount,
                physicalMemoryBytes: raw.environment.physicalMemoryBytes,
                powerSource: raw.environment.powerSource,
                thermalState: raw.environment.thermalState,
                operatingSystemVersion: raw.environment.operatingSystemVersion,
                appVersion: appVersion,
                appBuild: appBuild
            ),
            preflight: raw.preflight,
            postflight: raw.postflight,
            capabilitySet: raw.capabilitySet,
            measurements: raw.measurements,
            failure: raw.failure
        )
    }
}
