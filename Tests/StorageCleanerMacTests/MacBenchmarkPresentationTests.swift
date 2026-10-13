import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacBenchmarkPresentationTests: XCTestCase {
    private var languagePreferences: TestVolatilePreferences!

    override func setUp() {
        super.setUp()
        languagePreferences = TestVolatilePreferences()
    }

    override func tearDown() {
        languagePreferences.restore()
        languagePreferences = nil
        super.tearDown()
    }

    func testPresentationProgressClampsUntrustedValuesAndBuildsStateFallback() {
        let progress = MacBenchmarkPresentationProgress(
            stage: .gpu,
            completedSampleCount: -4,
            totalSampleCount: -8,
            progress: 2.4,
            elapsedSeconds: -.infinity
        )

        XCTAssertEqual(progress.completedSampleCount, 0)
        XCTAssertEqual(progress.totalSampleCount, 0)
        XCTAssertEqual(progress.progress, 1)
        XCTAssertEqual(progress.elapsedSeconds, 0)

        let fallback = MacBenchmarkPresentationProgress.stateFallback(
            .running(stage: .memory, progress: 0.42, elapsedSeconds: 12.5)
        )
        XCTAssertEqual(fallback?.stage, .memory)
        XCTAssertEqual(fallback?.progress, 0.42)
        XCTAssertEqual(fallback?.elapsedSeconds, 12.5)
        XCTAssertNil(MacBenchmarkPresentationProgress.stateFallback(.idle))
    }

    func testComponentRowsAlwaysUseSixStableComponentsWithScoresRawValuesAndCV() {
        let result = scoredResult()
        let rows = MacBenchmarkPresentation.componentRows(result)

        XCTAssertEqual(rows.map(\.component), BenchmarkComponent.allCases)
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.map(\.unit), BenchmarkComponent.allCases.map(\.metricUnit))
        XCTAssertEqual(rows.map(\.sampleCount), Array(repeating: 3, count: 6))
        XCTAssertEqual(rows[0].score, 900)
        XCTAssertEqual(try XCTUnwrap(rows[0].medianValue), 100, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(rows[0].coefficientOfVariation),
            0.1,
            accuracy: 0.000_001
        )

        let rawRows = MacBenchmarkPresentation.componentRows(
            MacBenchmarkScoring.rawOnly(rawResult: completeRawResult())
        )
        XCTAssertTrue(rawRows.allSatisfy { $0.score == nil })
        XCTAssertTrue(rawRows.allSatisfy { $0.medianValue != nil })
    }

    func testStandardRowsUseMetal3DUnitsAndExposeCapacityWeightsWithoutASecondScore() throws {
        let raw = completeRawResult(
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion,
            systemDiskCapacityBytes: 1_000_000_000_000
        )
        let result = MacBenchmarkScoring.rawOnly(rawResult: raw)
        let rows = MacBenchmarkPresentation.componentRows(result)
        let gpu = try XCTUnwrap(rows.first { $0.component == .gpu })

        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(gpu.unit, .millionTrianglesPerSecond)

        languagePreferences.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(
            MacBenchmarkPresentation.componentTitle(gpu.component, unit: gpu.unit),
            "Metal GPU 3D"
        )
        XCTAssertEqual(
            MacBenchmarkPresentation.capacityScoreDetail(for: .memory, result: result),
            "48 GB · 权重 25%"
        )
        let diskRead = try XCTUnwrap(
            MacBenchmarkPresentation.capacityScoreDetail(for: .diskRead, result: result)
        )
        XCTAssertTrue(diskRead.contains("权重 10%"))
        XCTAssertEqual(
            diskRead,
            MacBenchmarkPresentation.capacityScoreDetail(for: .diskWrite, result: result)
        )
        XCTAssertNil(MacBenchmarkPresentation.capacityScoreDetail(for: .gpu, result: result))

        languagePreferences.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(
            MacBenchmarkPresentation.capacityScoreDetail(for: .memory, result: result),
            "48 GB · 25% weight"
        )
    }

    func testRawOnlyReasonDoesNotTurnMissingComparabilityIntoZeroScore() {
        XCTAssertNil(MacBenchmarkPresentation.rawOnlyReason(for: scoredResult()))

        let comparableRaw = MacBenchmarkScoring.rawOnly(rawResult: completeRawResult())
        XCTAssertEqual(
            MacBenchmarkPresentation.rawOnlyReason(for: comparableRaw),
            .baselineUnavailable
        )
        XCTAssertEqual(
            MacBenchmarkPresentation.rawOnlyReason(
                for: comparableRaw,
                explicitReason: .baselineAmbiguous
            ),
            .baselineAmbiguous
        )

        let unsupported = MacBenchmarkScoring.rawOnly(rawResult: completeRawResult(
            architecture: .x86_64
        ))
        XCTAssertEqual(
            MacBenchmarkPresentation.rawOnlyReason(for: unsupported),
            .unsupportedArchitecture
        )

        let changedEnvironment = MacBenchmarkScoring.rawOnly(rawResult: completeRawResult(
            postflightThermalState: .fair
        ))
        XCTAssertEqual(
            MacBenchmarkPresentation.rawOnlyReason(for: changedEnvironment),
            .environmentNotComparable
        )

        let unstable = MacBenchmarkScoring.rawOnly(rawResult: completeRawResult(
            profile: .standard,
            workloadVersion: MacBenchmarkScoring.balancedCompositeWorkloadVersion
        ))
        XCTAssertEqual(
            MacBenchmarkPresentation.rawOnlyReason(for: unstable),
            .unstableSamples
        )

        XCTAssertEqual(
            MacBenchmarkPresentation.rawOnlyReason(for: .incomplete(completed: [:])),
            .incompleteResult
        )
    }

    func testMetricScoreVariabilityAndDurationFormattingKeepUnitsExplicit() {
        XCTAssertEqual(
            MacBenchmarkPresentation.metricText(123.456, unit: .millionOperationsPerSecond),
            "123.5 Mops/s"
        )
        XCTAssertEqual(
            MacBenchmarkPresentation.metricText(123.456, unit: .billionOperationsPerSecond),
            "123.5 Gops/s"
        )
        XCTAssertEqual(
            MacBenchmarkPresentation.metricText(123.456, unit: .millionTrianglesPerSecond),
            "123.5 Mtri/s"
        )
        XCTAssertEqual(
            MacBenchmarkPresentation.metricText(12.345, unit: .decimalGigabytesPerSecond),
            "12.35 GB/s"
        )
        XCTAssertEqual(MacBenchmarkPresentation.metricText(.nan, unit: .decimalGigabytesPerSecond), "—")
        XCTAssertEqual(MacBenchmarkPresentation.scoreText(nil), "—")
        XCTAssertEqual(MacBenchmarkPresentation.variabilityText(0.0123), "CV 1.2%")

        languagePreferences.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(MacBenchmarkPresentation.durationText(59.6), "60 秒")
        XCTAssertEqual(MacBenchmarkPresentation.durationText(61), "1 分 1 秒")

        languagePreferences.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(MacBenchmarkPresentation.durationText(61), "1 min 1 sec")
    }

    func testBenchmarkCorePresentationIsLocalizedInChineseAndEnglish() {
        languagePreferences.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(MacBenchmarkPresentation.performanceIndexTitle, "性能指数")
        XCTAssertEqual(MacBenchmarkPresentation.profileTitle(.standard), "标准")
        XCTAssertEqual(
            MacBenchmarkPresentation.standardLeaderboardScoreTitle,
            "v6 性能指数"
        )
        XCTAssertEqual(MacBenchmarkPresentation.profileTitle(.quick), "旧版快速")
        XCTAssertEqual(MacBenchmarkPresentation.profileTitle(.full), "旧版完整")
        XCTAssertEqual(MacBenchmarkPresentation.stageTitle(.preflight), "安全前置检查")
        XCTAssertEqual(MacBenchmarkPresentation.componentTitle(.diskWrite), "磁盘写入")
        XCTAssertEqual(
            MacBenchmarkPresentation.componentTitle(
                .gpu,
                unit: .billionOperationsPerSecond
            ),
            "Metal GPU 计算"
        )
        XCTAssertEqual(
            MacBenchmarkPresentation.componentTitle(
                .gpu,
                unit: .millionTrianglesPerSecond
            ),
            "Metal GPU 3D"
        )
        XCTAssertTrue(
            MacBenchmarkPresentation.rawOnlyTitle(.baselineUnavailable).contains("仅保留原始值")
        )

        languagePreferences.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(MacBenchmarkPresentation.performanceIndexTitle, "Performance Index")
        XCTAssertEqual(MacBenchmarkPresentation.profileTitle(.standard), "Standard")
        XCTAssertEqual(
            MacBenchmarkPresentation.standardLeaderboardScoreTitle,
            "v6 Performance Index"
        )
        XCTAssertEqual(MacBenchmarkPresentation.profileTitle(.quick), "Legacy Quick")
        XCTAssertEqual(MacBenchmarkPresentation.profileTitle(.full), "Legacy Full")
        XCTAssertEqual(MacBenchmarkPresentation.stageTitle(.preflight), "Safety Preflight")
        XCTAssertEqual(MacBenchmarkPresentation.componentTitle(.diskWrite), "Disk Write")
        XCTAssertEqual(
            MacBenchmarkPresentation.componentTitle(
                .gpu,
                unit: .billionOperationsPerSecond
            ),
            "Metal GPU Compute"
        )
        XCTAssertTrue(
            MacBenchmarkPresentation.rawOnlyTitle(.baselineUnavailable).contains("Raw Metrics Only")
        )
    }

    func testPerformanceIndexCopySupportsMultipleAppleChipFamiliesWithoutClaimingRank() throws {
        languagePreferences.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)

        XCTAssertEqual(MacBenchmarkPresentation.referenceScoreText, "1000")
        XCTAssertEqual(MacBenchmarkPresentation.referenceTotalScoreText, "6000")
        XCTAssertEqual(MacBenchmarkPresentation.activeReferenceSummary, "M5 Pro = 6000")

        for chipName in ["Apple M1", "Apple M2 Pro", "  Apple   M3 Max  ", "Apple M4", "Apple M5 Ultra"] {
            let result = scoredResult(chipName: chipName)
            let hardware = MacBenchmarkPresentation.hardwareSummary(
                try XCTUnwrap(result.rawResult).environment
            )

            XCTAssertTrue(hardware.contains(chipName.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")))
            XCTAssertEqual(MacBenchmarkPresentation.referenceSummary(for: result), "M5 Pro = 6000")
            XCTAssertEqual(
                MacBenchmarkPresentation.comparisonScope(for: result),
                "可跨 Apple 芯片比较 · 不是同型号排名"
            )
        }

        let rawOnly = MacBenchmarkScoring.rawOnly(rawResult: completeRawResult(chipName: "Apple M1"))
        XCTAssertEqual(
            MacBenchmarkPresentation.comparisonScope(for: rawOnly),
            "不满足条件时只保留原始值"
        )
    }

    func testSafetyAndFailureMessagesStateAnActionableBoundary() {
        languagePreferences.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)

        XCTAssertTrue(
            MacBenchmarkPresentation.failureDetail(.busy(activeTask: "private task name"))
                .contains("Another heavy task")
        )
        XCTAssertFalse(
            MacBenchmarkPresentation.failureDetail(.busy(activeTask: "private task name"))
                .contains("private task name")
        )
        XCTAssertTrue(
            MacBenchmarkPresentation.safetyIssueDetail(.acPowerRequired)
                .contains("external power")
        )
        XCTAssertTrue(
            MacBenchmarkPresentation.failureDetail(.timedOut(.diskWrite))
                .contains("safety timeout")
        )
    }

    @MainActor
    func testHistoryBadgeUsesCancelledTerminalStatusBeforeFailure() {
        XCTAssertEqual(
            BenchmarkV7DashboardView.historyBadgeStatus(for: historyResult(failure: .cancelled)),
            .cancelled
        )
        XCTAssertEqual(
            BenchmarkV7DashboardView.historyBadgeStatus(for: historyResult(failure: .internalFailure)),
            .failed
        )
        XCTAssertEqual(
            BenchmarkV7DashboardView.historyBadgeStatus(for: historyResult(failure: nil)),
            .incomplete
        )
    }

    func testDashboardSourcePreservesManualSafetyExplainabilityAndLayoutContracts() throws {
        // D64 removes the unreferenced v6 views, not scoring/history services or presentation value tests.
        let root = projectRoot
        let dashboard = try source("Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7DashboardView.swift", root: root)
        let leaderboard = try source("Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7LeaderboardSection.swift", root: root)
        let raw = try source("Sources/StorageCleanerMac/Views/ComputerHealth/MSeriesRawResultView.swift", root: root)
        for name in ["MacBenchmarkDashboardView", "MacBenchmarkResultSections", "MacBenchmarkLeaderboardSection", "MacAcceleratorBenchmarkSection", "MacSustainedBenchmarkSection"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/StorageCleanerMac/Views/ComputerHealth/" + name + ".swift").path), name)
        }
        XCTAssertTrue(dashboard.contains("struct BenchmarkV7DashboardView: View"))
        XCTAssertTrue(dashboard.contains("accessibilityReduceMotion"))
        XCTAssertTrue(dashboard.contains("transaction.animation = reduceMotion ? nil"))
        XCTAssertTrue(dashboard.contains("开始性能测试"))
        XCTAssertTrue(dashboard.contains("benchmarkPrimaryAction"))
        XCTAssertTrue(dashboard.contains("onStart"))
        XCTAssertTrue(dashboard.contains("onCancel"))
        XCTAssertTrue(dashboard.contains("isCurrentComparableOfficialResult"))
        XCTAssertTrue(dashboard.contains("localBestResult"))
        XCTAssertTrue(dashboard.contains("onDeleteHistoryRecord"))
        XCTAssertTrue(dashboard.contains("onExportHistoryRecord"))
        XCTAssertTrue(dashboard.contains("BenchmarkV7RunProgressView("))
        XCTAssertTrue(dashboard.contains("!latest.isCompleteCore"))
        XCTAssertTrue(dashboard.contains("onDeleteHistoryRecord(recordID)"))
        XCTAssertTrue(dashboard.contains("guard let data = onExportHistoryRecord(recordID)"))
        XCTAssertTrue(dashboard.contains("if result.failure == nil, !result.isCurrentComparableOfficialResult"))
        XCTAssertTrue(dashboard.contains("comparisonRecordIDs.contains(recordID)"))
        XCTAssertTrue(dashboard.contains(".filter(\\.isCurrentComparableOfficialResult)"))
        XCTAssertTrue(dashboard.contains("if let computerName = result.hardwareProfile?.computerName"))
        XCTAssertTrue(dashboard.contains("if let computerModel = result.hardwareProfile?.computerModel"))
        XCTAssertTrue(dashboard.contains("if let modelIdentifier = result.hardwareProfile?.modelIdentifier"))
        XCTAssertTrue(dashboard.contains("if let gpuCoreCount = result.hardwareProfile?.gpuCoreCount"))
        XCTAssertTrue(dashboard.contains("if let storageModel = result.hardwareProfile?.storageModel"))
        XCTAssertTrue(dashboard.contains("physicalMemoryBytes"))
        XCTAssertTrue(dashboard.contains("systemDiskCapacityBytes"))
        XCTAssertTrue(dashboard.contains("LazyVStack("))
        XCTAssertTrue(dashboard.contains("GridItem(.adaptive(minimum: 170)"))
        XCTAssertTrue(dashboard.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(dashboard.contains("原始指标与技术详情"))
        XCTAssertTrue(dashboard.contains("仅保存在本机"))
        XCTAssertTrue(dashboard.contains("删除后无法从应用内恢复"))
        XCTAssertTrue(dashboard.contains("if case .failure = historyFeedback"))
        XCTAssertFalse(dashboard.contains("selectedProfile"))
        XCTAssertFalse(dashboard.contains("repeatForever"))
        XCTAssertFalse(dashboard.contains("MacBenchmarkDashboardView"))
        XCTAssertFalse(dashboard.contains("一次完成 Standard v6"))
        XCTAssertTrue(raw.contains("result.metrics"))
        XCTAssertTrue(raw.contains("statistics.sampleCount"))
        XCTAssertTrue(raw.contains("statistics.median"))
        XCTAssertTrue(raw.contains("statistics.confidence.rawValue"))
        XCTAssertTrue(raw.contains("sample stability, not statistical confidence"))
        XCTAssertTrue(raw.contains("awaiting reference calibration"))
        XCTAssertTrue(raw.contains("result.extensions"))
        XCTAssertTrue(raw.contains("result.writtenBytes"))
        XCTAssertTrue(raw.contains("result.plan"))
        XCTAssertFalse(raw.contains("运行加速测试"))
        XCTAssertFalse(raw.contains("运行持续测试"))
        XCTAssertFalse(raw.contains("Canvas {"))
        XCTAssertFalse(raw.contains("TimelineView(.animation("))
        XCTAssertTrue(leaderboard.contains("全球 Mac 排行榜"))
        XCTAssertTrue(leaderboard.contains("entry.memoryGB"))
        XCTAssertTrue(leaderboard.contains("entry.processorModel"))
        XCTAssertTrue(leaderboard.contains("publishConfirmationMessage"))
        XCTAssertTrue(leaderboard.contains("showsPublishConfirmation"))
        XCTAssertTrue(leaderboard.contains("showsRemovalConfirmation"))
        XCTAssertTrue(leaderboard.contains("canPublish"))
        XCTAssertTrue(leaderboard.contains("store.submit"))
        XCTAssertTrue(leaderboard.contains("store.remove"))
        XCTAssertTrue(leaderboard.contains("系统"))
        XCTAssertTrue(leaderboard.contains("匿名名称"))
        XCTAssertFalse(leaderboard.contains("有效成绩完成后自动上传"))
        XCTAssertFalse(leaderboard.contains("社区性能排行榜 · v4"))
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func historyResult(failure: BenchmarkV7Failure?) -> BenchmarkV7Result {
        let plan = BenchmarkV7Plan.quick
        let storageTarget = BenchmarkV7StorageTarget(
            volumeName: "Fixture",
            fileSystem: "APFS",
            availableBytes: 1,
            isReadOnly: false
        )
        let preflight = BenchmarkV7PreflightReport(
            capturedAt: Date(timeIntervalSinceReferenceDate: 1),
            powerSource: .acPower,
            batteryPercent: 100,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            backgroundLoadRatio: 0,
            availableMemoryBytes: 1,
            storageTarget: storageTarget,
            displayDescription: "Fixture display",
            checks: [],
            blockedCategories: []
        )
        return BenchmarkV7Result(
            session: BenchmarkV7Session(plan: plan, storageTarget: storageTarget),
            preflight: preflight,
            versions: BenchmarkV7VersionManifest(
                planVersion: plan.planVersion,
                workloadVersion: plan.workloadVersion,
                statisticsVersion: "fixture",
                scoringVersion: "fixture",
                referenceSetVersion: "fixture"
            ),
            metrics: [],
            coreScore: nil,
            completedAt: nil,
            failure: failure
        )
    }

    private func scoredResult(chipName: String = "Apple M5 Pro") -> MacBenchmarkResult {
        let raw = completeRawResult(chipName: chipName)
        let key = BenchmarkComparisonKey(
            workloadVersion: raw.workloadVersion,
            baselineVersion: "m5-pro-v1",
            profile: raw.profile,
            architecture: raw.environment.architecture,
            capabilitySet: raw.capabilitySet
        )
        let scores = Dictionary(uniqueKeysWithValues: BenchmarkComponent.allCases.enumerated().map {
            ($0.element, 900 + Double($0.offset * 40))
        })
        return MacBenchmarkResult(
            rawResult: raw,
            comparisonKey: key,
            matchedBaselineKey: key,
            componentScores: scores,
            proposedOverallScore: 1_000
        )
    }

    private func completeRawResult(
        architecture: BenchmarkArchitecture = .arm64,
        chipName: String = "Apple M5 Pro",
        postflightThermalState: BenchmarkThermalState = .nominal,
        profile: BenchmarkProfile = .quick,
        workloadVersion: String = "mac-benchmark-quick-v3",
        systemDiskCapacityBytes: UInt64? = nil
    ) -> MacBenchmarkRawResult {
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let completedAt = startedAt.addingTimeInterval(30)
        let measurements = BenchmarkComponent.allCases.enumerated().map { index, component in
            let scale = Double(index + 1)
            return BenchmarkComponentMeasurement(
                component: component,
                unit: component.metricUnit(for: profile),
                samples: [90, 100, 110].enumerated().map { sampleIndex, value in
                    BenchmarkComponentSample(
                        value: Double(value) * scale,
                        elapsedSeconds: 1 + Double(sampleIndex) * 0.1,
                        checksum: UInt64(index + 1)
                    )
                }
            )
        }
        return MacBenchmarkRawResult(
            profile: profile,
            workloadVersion: workloadVersion,
            startedAt: startedAt,
            completedAt: completedAt,
            environment: BenchmarkEnvironmentMetadata(
                architecture: architecture,
                chipName: chipName,
                activeProcessorCount: 18,
                physicalMemoryBytes: 48 * 1_024 * 1_024 * 1_024,
                systemDiskCapacityBytes: systemDiskCapacityBytes,
                powerSource: .acPower,
                thermalState: .nominal,
                operatingSystemVersion: "macOS 26.0",
                appVersion: "1.5.0",
                appBuild: "1"
            ),
            preflight: BenchmarkPreflight(
                capturedAt: startedAt.addingTimeInterval(1),
                powerSource: .acPower,
                batteryPercent: 80,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 100_000_000_000,
                requiredDiskBytes: 2_000_000_000,
                warnings: []
            ),
            postflight: BenchmarkPostflight(
                capturedAt: completedAt.addingTimeInterval(-1),
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: postflightThermalState,
                diskReliability: .verified,
                availableDiskBytes: 100_000_000_000,
                requiredDiskBytes: 2_000_000_000,
                warnings: []
            ),
            capabilitySet: .all,
            measurements: measurements,
            failure: nil
        )
    }
}
