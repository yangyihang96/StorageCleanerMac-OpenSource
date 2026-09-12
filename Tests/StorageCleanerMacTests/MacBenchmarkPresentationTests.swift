import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacBenchmarkPresentationTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey)
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

        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
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

        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
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

        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(MacBenchmarkPresentation.durationText(59.6), "60 秒")
        XCTAssertEqual(MacBenchmarkPresentation.durationText(61), "1 分 1 秒")

        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(MacBenchmarkPresentation.durationText(61), "1 min 1 sec")
    }

    func testBenchmarkCorePresentationIsLocalizedInChineseAndEnglish() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
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

        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
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
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)

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
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)

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
        let root = projectRoot
        let dashboard = try source(
            "Sources/StorageCleanerMac/Views/ComputerHealth/MacBenchmarkDashboardView.swift",
            root: root
        )
        let resultSections = try source(
            "Sources/StorageCleanerMac/Views/ComputerHealth/MacBenchmarkResultSections.swift",
            root: root
        )
        let leaderboard = try source(
            "Sources/StorageCleanerMac/Views/ComputerHealth/MacBenchmarkLeaderboardSection.swift",
            root: root
        )
        let accelerator = try source(
            "Sources/StorageCleanerMac/Views/ComputerHealth/MacAcceleratorBenchmarkSection.swift",
            root: root
        )
        let sustained = try source(
            "Sources/StorageCleanerMac/Views/ComputerHealth/MacSustainedBenchmarkSection.swift",
            root: root
        )
        let benchmarkV7Dashboard = try source(
            "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7DashboardView.swift",
            root: root
        )

        XCTAssertTrue(dashboard.contains("struct MacBenchmarkDashboardView: View"))
        XCTAssertTrue(dashboard.contains("MacBenchmarkPresentationProgress"))
        XCTAssertTrue(dashboard.contains("accessibilityReduceMotion"))
        XCTAssertTrue(dashboard.contains("transaction.animation = reduceMotion ? nil"))
        XCTAssertTrue(dashboard.contains("开始完整测试"))
        XCTAssertTrue(dashboard.contains("第 1/3 项"))
        XCTAssertTrue(dashboard.contains("我已接通电源"))
        XCTAssertFalse(accelerator.contains("运行加速测试"))
        XCTAssertFalse(sustained.contains("运行持续测试"))
        XCTAssertTrue(dashboard.contains("取消并清理"))
        XCTAssertTrue(dashboard.contains("MacBenchmarkPresentation.activeReferenceSummary"))
        XCTAssertTrue(dashboard.contains("Standard v6"))
        XCTAssertTrue(dashboard.contains("本机离线"))
        XCTAssertTrue(dashboard.contains("AppEmptyState("))
        XCTAssertTrue(dashboard.contains("AppSymbols.Benchmark.performance"))
        XCTAssertTrue(dashboard.contains("不是同型号排名"))
        XCTAssertTrue(dashboard.contains("hasVerifiedActiveBaseline"))
        XCTAssertTrue(dashboard.contains("v6 冻结参照未能载入 · 仅原始值"))
        XCTAssertTrue(dashboard.contains("clock.badge.exclamationmark"))
        XCTAssertTrue(dashboard.contains("private let benchmarkProfile: BenchmarkProfile = .standard"))
        XCTAssertFalse(dashboard.contains("selectedProfile"))
        XCTAssertFalse(dashboard.contains("Picker("))
        XCTAssertFalse(dashboard.contains(".pickerStyle(.segmented)"))
        XCTAssertFalse(dashboard.contains(".onAppear"))
        XCTAssertFalse(dashboard.contains(".task {"))
        XCTAssertFalse(dashboard.contains("repeatForever"))
        XCTAssertTrue(dashboard.contains("Metal 3D 离屏渲染"))
        XCTAssertTrue(dashboard.contains("262,144 INSTANCES  ·  600 FRAMES"))
        XCTAssertTrue(dashboard.contains("1.887B TRIANGLES / SAMPLE"))
        XCTAssertTrue(dashboard.contains("低频静态进度"))
        XCTAssertTrue(dashboard.contains("ProgressView(value: normalizedProgress)"))
        XCTAssertFalse(dashboard.contains("TimelineView(.animation(minimumInterval: 1.0 / 30.0"))
        XCTAssertFalse(dashboard.contains("Canvas {"))
        XCTAssertTrue(benchmarkV7Dashboard.contains("if let computerName = result.hardwareProfile?.computerName"))
        XCTAssertTrue(benchmarkV7Dashboard.contains("if let computerModel = result.hardwareProfile?.computerModel"))
        XCTAssertTrue(benchmarkV7Dashboard.contains("if let modelIdentifier = result.hardwareProfile?.modelIdentifier"))
        XCTAssertTrue(benchmarkV7Dashboard.contains("if let gpuCoreCount = result.hardwareProfile?.gpuCoreCount"))
        XCTAssertTrue(benchmarkV7Dashboard.contains("if let storageModel = result.hardwareProfile?.storageModel"))

        XCTAssertTrue(dashboard.contains("case longLocalizedText"))
        XCTAssertTrue(dashboard.contains(".frame(width: 980, height: 680)"))
        XCTAssertTrue(resultSections.contains("MacBenchmarkComponentGrid"))
        XCTAssertTrue(resultSections.contains("MacBenchmarkHistorySection"))
        XCTAssertTrue(resultSections.contains("Table(rows)"))
        XCTAssertFalse(dashboard.contains("DisclosureGroup"))
        XCTAssertFalse(resultSections.contains("MacBenchmarkMethodDisclosure"))
        XCTAssertFalse(resultSections.contains(".popover("))
        XCTAssertTrue(resultSections.contains("MacBenchmarkScoreComparisonBars"))
        XCTAssertTrue(resultSections.contains("高于基准"))
        XCTAssertTrue(resultSections.contains("低于基准"))
        XCTAssertTrue(resultSections.contains("ProgressView(value: value, total: scale)"))
        XCTAssertTrue(resultSections.contains("MacBenchmarkScoring.referenceTotalScore"))
        XCTAssertTrue(resultSections.contains("MacBenchmarkScoring.referenceScore"))
        XCTAssertTrue(resultSections.contains("GridItem(.adaptive(minimum: 270"))
        XCTAssertTrue(resultSections.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(resultSections.contains("MacBenchmarkPresentation.capacityScoreDetail"))
        XCTAssertTrue(resultSections.contains("仅显示原始值"))
        XCTAssertTrue(resultSections.contains("稳定性"))
        XCTAssertFalse(resultSections.contains("title: L10n.text(\"样本\""))
        XCTAssertFalse(resultSections.contains("算法版本"))
        XCTAssertFalse(dashboard.contains("一次完成 Standard v6"))
        XCTAssertTrue(leaderboard.contains("社区性能排行榜 · v6"))
        XCTAssertTrue(leaderboard.contains("MacBenchmarkPresentation.standardLeaderboardScoreTitle"))
        XCTAssertTrue(leaderboard.contains("entry.physicalMemoryBytes"))
        XCTAssertTrue(leaderboard.contains("entry.systemDiskCapacityBytes"))
        XCTAssertTrue(leaderboard.contains("用户 ID：\\(store.automaticDisplayName)"))
        XCTAssertFalse(leaderboard.contains("当前公共榜单使用冻结的 Standard v6"))
        XCTAssertFalse(leaderboard.contains("有效成绩完成后自动上传"))
        XCTAssertFalse(leaderboard.contains("确认上传"))
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
