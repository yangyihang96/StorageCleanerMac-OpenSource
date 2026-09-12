import Foundation
import XCTest

@testable import StorageCleanerMac

final class OfficialBenchmarkPlanTests: XCTestCase {
    func testCurrentPlanIsOneFixedFullSession() {
        let official = OfficialBenchmarkPlan.current

        XCTAssertEqual(official.plan.kind, .standard)
        XCTAssertEqual(
            official.categories,
            [.cpu, .gpu, .memory, .storage, .display, .sustained]
        )
        XCTAssertEqual(Set(official.categories), Set(official.plan.categories))
        XCTAssertTrue(official.plan.isValid)
        XCTAssertEqual(
            official.plan.workloadVersion,
            BenchmarkV7Plan.standard.workloadVersion
        )
    }

    func testPerformanceWorkspaceExposesOnlyTheOfficialFlow() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkWorkspaceView.swift"
            ),
            encoding: .utf8
        )
        let dashboard = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7DashboardView.swift"
            ),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7PerformancePresentation.swift"
            ),
            encoding: .utf8
        )
        let leaderboard = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7LeaderboardSection.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("BenchmarkV7DashboardView("))
        XCTAssertTrue(source.contains("benchmarkStore.startOfficialBenchmark"))
        XCTAssertTrue(source.contains("leaderboardStore: leaderboardStore"))
        XCTAssertTrue(source.contains("localBestResult:"))
        XCTAssertTrue(source.contains("onDeleteHistoryRecord:"))
        XCTAssertTrue(source.contains("onExportHistoryRecord:"))
        XCTAssertTrue(source.contains("monitorState.history(within: 120)"))
        XCTAssertFalse(source.contains("MacBenchmarkDashboardView"))

        XCTAssertTrue(dashboard.contains("开始性能测试"))
        XCTAssertTrue(dashboard.contains("最新结果"))
        XCTAssertTrue(dashboard.contains("本机最佳"))
        XCTAssertTrue(dashboard.contains("历史记录"))
        XCTAssertTrue(dashboard.contains("case leaderboard"))
        XCTAssertTrue(dashboard.contains("全球排行"))
        XCTAssertTrue(dashboard.contains("BenchmarkV7LeaderboardSection("))
        XCTAssertTrue(dashboard.contains("Picker("))
        XCTAssertTrue(dashboard.contains("onExportHistoryRecord"))
        XCTAssertTrue(dashboard.contains("onDeleteHistoryRecord"))
        XCTAssertTrue(dashboard.contains("BenchmarkV7PerformanceSummaryView"))
        XCTAssertTrue(dashboard.contains("BenchmarkV7RunProgressView"))
        XCTAssertTrue(dashboard.contains("DisclosureGroup(L10n.text(\"7 个阶段说明\""))
        XCTAssertTrue(dashboard.contains("BenchmarkSystemMonitor("))
        XCTAssertTrue(dashboard.contains("telemetryPoints: liveTelemetry"))
        XCTAssertFalse(dashboard.contains("FileToolLandingArtwork("))
        XCTAssertTrue(dashboard.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertFalse(dashboard.contains(".shadow(color: accent.opacity(canStart"))
        XCTAssertTrue(dashboard.contains("本机实际测试记录，与 FIXTURE 固定监控数据无关"))
        XCTAssertTrue(dashboard.contains("原始指标与技术详情"))
        XCTAssertTrue(presentation.contains("相对强项"))
        XCTAssertTrue(presentation.contains("相对短板"))
        XCTAssertTrue(presentation.contains("state.workloadID"))
        XCTAssertTrue(presentation.contains("系统实时监控"))
        XCTAssertTrue(presentation.contains("GeekPrecisionLineChart("))
        XCTAssertTrue(presentation.contains("channel: .cpuTotal"))
        XCTAssertTrue(presentation.contains("channel: .gpu"))
        XCTAssertTrue(presentation.contains("Text(\"100%\")"))
        XCTAssertTrue(presentation.contains("Text(\"50%\")"))
        XCTAssertTrue(presentation.contains("Text(\"0%\")"))
        XCTAssertTrue(presentation.contains("固定监控数据"))
        XCTAssertTrue(presentation.contains("value: telemetryPoints.last?.cpuTotal"))
        XCTAssertTrue(presentation.contains("value: telemetryPoints.last?.gpu"))
        XCTAssertFalse(presentation.contains("Timer.publish"))
        XCTAssertFalse(presentation.contains("\"最大差距 (percent"))
        XCTAssertFalse(presentation.contains("\"(percent("))
        XCTAssertFalse(presentation.contains("\"第 (repetition)"))
        XCTAssertFalse(dashboard.contains("快速测试"))
        XCTAssertFalse(dashboard.contains("标准测试"))
        XCTAssertFalse(dashboard.contains("自定义测试设置"))
        XCTAssertFalse(dashboard.contains("最新排名"))
        XCTAssertFalse(dashboard.contains("旧版结果"))
        XCTAssertFalse(dashboard.contains("MacBenchmarkLeaderboardSection"))
        XCTAssertTrue(source.contains("全球排行需在对应页面确认后才上传匿名字段"))

        XCTAssertTrue(leaderboard.contains("全球 Mac 排行榜"))
        XCTAssertTrue(leaderboard.contains("发布我的最佳成绩"))
        XCTAssertTrue(leaderboard.contains("更新我的最佳成绩"))
        XCTAssertTrue(leaderboard.contains("confirmationDialog("))
        XCTAssertTrue(leaderboard.contains("await store.submitBest(results)"))
        XCTAssertFalse(leaderboard.contains("submitBestAutomatically"))
        XCTAssertTrue(leaderboard.contains("loadMore()"))
        XCTAssertTrue(leaderboard.contains("应用不会提交电脑名称、序列号、硬件 UUID、IP 地址或本机路径"))
        XCTAssertTrue(leaderboard.contains("Cloudflare 会为传输和滥用限流处理连接 IP"))
        XCTAssertTrue(leaderboard.contains("but it is not included in the public leaderboard"))
    }

    @MainActor
    func testCurrentLoadLabelsPreserveZeroAndRejectMissingOrInvalidReadings() {
        XCTAssertEqual(BenchmarkSystemMonitor.loadText(0), "0.0%")
        XCTAssertEqual(BenchmarkSystemMonitor.loadText(100), "100.0%")
        XCTAssertEqual(BenchmarkSystemMonitor.loadText(27.4), "27.4%")
        for invalid in [nil, Double.nan, Double.infinity, -1, 101] as [Double?] {
            XCTAssertEqual(BenchmarkSystemMonitor.loadText(invalid), "—")
        }
    }

    @MainActor
    func testPersistingPhaseHidesCancellationAndKeepsSavingFeedback() throws {
        XCTAssertTrue(BenchmarkV7DashboardView.allowsCancellation(during: .scoring))
        XCTAssertFalse(BenchmarkV7DashboardView.allowsCancellation(during: .persisting))
        XCTAssertFalse(BenchmarkV7DashboardView.allowsCancellation(during: .cancelling))

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dashboard = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7DashboardView.swift"
            ),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7PerformancePresentation.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue((dashboard + presentation).contains("正在保存结果"))
        XCTAssertTrue((dashboard + presentation).contains("Saving result"))
    }
}
