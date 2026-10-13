import Foundation
import XCTest

@testable import StorageCleanerMac

final class OfficialBenchmarkPlanTests: XCTestCase {
    func testCurrentPlanIsOneFixedFullSession() {
        let official = OfficialBenchmarkPlan.current

        XCTAssertEqual(official.plan.kind, .standard)
        XCTAssertEqual(
            official.categories,
            [.cpu, .gpu, .memory, .storage]
        )
        XCTAssertEqual(Set(official.categories), Set(official.plan.categories))
        XCTAssertTrue(official.plan.isValid)
        XCTAssertEqual(
            official.plan.workloadVersion,
            MSeriesProtocol.workload
        )
    }

    /// U1 029: the dial and the load chart share the monitor's height; the
    /// dial is capped at 240 pt and gives way to the chart's minimum height.
    func testMonitorDialAndChartShareTheGivenHeight() {
        // The default window's monitor content (about 516 x 413 pt).
        let wide = BenchmarkMonitorLayout(width: 516, height: 413)
        XCTAssertEqual(wide.diameter, BenchmarkMonitorLayout.maximumDiameter)
        XCTAssertEqual(wide.chartHeight, BenchmarkMonitorLayout.maximumChartHeight)
        XCTAssertEqual(wide.gaugeSize, BenchmarkMonitorLayout.maximumGaugeSize)
        // 900 x 640: height-bound; the chart keeps a useful height.
        let compact = BenchmarkMonitorLayout(width: 288, height: 299)
        XCTAssertEqual(compact.chartHeight,
                       (299 - BenchmarkMonitorLayout.fixedChromeHeight) * BenchmarkMonitorLayout.chartShare,
                       accuracy: 0.01)
        XCTAssertGreaterThan(compact.chartHeight, BenchmarkMonitorLayout.minimumChartHeight)
        XCTAssertEqual(compact.diameter, 299 - BenchmarkMonitorLayout.fixedChromeHeight - compact.chartHeight,
                       accuracy: 0.01)
        XCTAssertGreaterThan(compact.diameter, 140)
        // A narrow column: width-bound, the dial leaves room for the gauges.
        let narrow = BenchmarkMonitorLayout(width: 204, height: 414)
        XCTAssertEqual(narrow.diameter,
                       204 - BenchmarkMonitorLayout.dialGaugeSpacing - BenchmarkMonitorLayout.maximumGaugeSize)
        XCTAssertGreaterThan(wide.diameter, compact.diameter)
        XCTAssertGreaterThan(wide.chartHeight, compact.chartHeight)
    }

    func testMonitorKeepsTheDialAndTheChartSeparateThroughContinuousSizes() {
        for width: CGFloat in stride(from: 200, through: 600, by: 10) {
            for height: CGFloat in stride(from: 234, through: 480, by: 6) {
                let metrics = BenchmarkMonitorLayout(width: width, height: height)
                let tag = "\(width)x\(height)"
                XCTAssertGreaterThan(metrics.diameter, 0, tag)
                XCTAssertLessThanOrEqual(metrics.diameter, BenchmarkMonitorLayout.maximumDiameter, tag)
                XCTAssertLessThanOrEqual(
                    metrics.diameter + BenchmarkMonitorLayout.dialGaugeSpacing + BenchmarkMonitorLayout.maximumGaugeSize,
                    width + 0.001, "Dial and gauges fit side by side: \(tag)"
                )
                XCTAssertLessThanOrEqual(
                    BenchmarkMonitorLayout.fixedChromeHeight + metrics.diameter + metrics.chartHeight,
                    height + 0.001, "Dial, chart and labels fit the given height: \(tag)"
                )
                XCTAssertGreaterThanOrEqual(metrics.chartHeight, BenchmarkMonitorLayout.minimumChartHeight, tag)
                XCTAssertLessThanOrEqual(2 * metrics.gaugeSize + BenchmarkMonitorLayout.gaugeSpacing,
                                         metrics.diameter + 0.001, "Gauges fit beside the dial: \(tag)")
            }
        }
    }

    func testInvalidMonitorDimensionsCannotProduceNonFiniteViewFrames() {
        let cases: [(CGFloat, CGFloat)] = [
            (-1, 390), (CGFloat.infinity, 390), (520, CGFloat.nan), (CGFloat.nan, CGFloat.nan), (520, -5),
        ]
        for (width, height) in cases {
            let metrics = BenchmarkMonitorLayout(width: width, height: height)
            XCTAssertEqual(metrics.diameter, 0)
            XCTAssertEqual(metrics.chartHeight, 0)
            XCTAssertEqual(metrics.gaugeSize, 0)
        }
        XCTAssertEqual(BenchmarkMonitorLayout.landingHeight(scrollViewportHeight: .nan),
                       BenchmarkMonitorLayout.landingMinimumHeight)
        XCTAssertEqual(BenchmarkMonitorLayout.landingHeight(scrollViewportHeight: -.infinity),
                       BenchmarkMonitorLayout.landingMinimumHeight)
    }

    /// The landing monitor gets the height that is visible below the page
    /// picker and above the status bar, within fixed limits.
    func testLandingMonitorHeightFollowsTheVisibleScrollArea() {
        let chrome = AppDesignTokens.Layout.pagePadding + BenchmarkMonitorLayout.pagePickerAllowance
            + AppDesignTokens.Layout.pageSpacing + AppDesignTokens.Spacing.small
        XCTAssertEqual(BenchmarkMonitorLayout.landingHeight(scrollViewportHeight: 420), 420 - chrome)
        XCTAssertEqual(BenchmarkMonitorLayout.landingHeight(scrollViewportHeight: 900),
                       BenchmarkMonitorLayout.landingMaximumHeight)
        XCTAssertEqual(BenchmarkMonitorLayout.landingHeight(scrollViewportHeight: 200),
                       BenchmarkMonitorLayout.landingMinimumHeight)
    }

    /// Review P2-3/P2-4: one first-screen arrangement for idle and running,
    /// and a compact temperature reading only where the monitor is not on the
    /// first screen (stacked below the card, or a page too short for it).
    func testFirstScreenArrangementAndCompactTemperatureReading() {
        let pagePadding = AppDesignTokens.Layout.pagePadding
        let sideBySide = BenchmarkLandingLayout.sideBySideMinimumContentWidth + 2 * pagePadding
        let tall: CGFloat = 600
        let wide = BenchmarkLandingLayout(scrollViewportSize: CGSize(width: sideBySide, height: tall))
        XCTAssertTrue(wide.placesMonitorBeside)
        XCTAssertFalse(wide.showsCompactTemperature)
        XCTAssertEqual(wide.monitorHeight, BenchmarkMonitorLayout.landingHeight(scrollViewportHeight: tall))

        let narrow = BenchmarkLandingLayout(scrollViewportSize: CGSize(width: sideBySide - 1, height: tall))
        XCTAssertFalse(narrow.placesMonitorBeside)
        XCTAssertTrue(narrow.showsCompactTemperature)

        let chrome = pagePadding + BenchmarkMonitorLayout.pagePickerAllowance
            + AppDesignTokens.Layout.pageSpacing + AppDesignTokens.Spacing.small
        let fits = BenchmarkLandingLayout(scrollViewportSize: CGSize(
            width: 1_000, height: chrome + BenchmarkMonitorLayout.landingMinimumHeight))
        XCTAssertTrue(fits.placesMonitorBeside)
        XCTAssertFalse(fits.showsCompactTemperature)
        let short = BenchmarkLandingLayout(scrollViewportSize: CGSize(
            width: 1_000, height: chrome + BenchmarkMonitorLayout.landingMinimumHeight - 1))
        XCTAssertTrue(short.placesMonitorBeside)
        XCTAssertTrue(short.showsCompactTemperature)

        // Before the first measurement, and for invalid sizes, nothing is
        // repeated and no non-finite height reaches a view frame.
        let invalid: [CGSize] = [.zero, CGSize(width: CGFloat.nan, height: 600),
                                 CGSize(width: 1_000, height: CGFloat.infinity), CGSize(width: -5, height: -5)]
        for size in invalid {
            let layout = BenchmarkLandingLayout(scrollViewportSize: size)
            XCTAssertFalse(layout.showsCompactTemperature, "\(size)")
            XCTAssertTrue(layout.monitorHeight.isFinite, "\(size)")
        }
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
        // D72 replaces the v10 entry. The old dashboard remains a history-only fallback.
        XCTAssertTrue(source.contains("benchmarkStore.startV11Benchmark(mode: selection.mode, accelerators: selection.units)"))
        XCTAssertFalse(source.contains("benchmarkStore.startOfficialBenchmark"))
        XCTAssertTrue(source.contains("PerformanceBenchmarkLandingView("))
        XCTAssertTrue(source.contains("PerformanceBenchmarkV11RunningPage("))
        XCTAssertTrue(source.contains("else if let result = displayedResult, result.mSeriesV11 != nil"))
        XCTAssertTrue(source.contains("PerformanceBenchmarkV11ResultPage("))
        XCTAssertTrue(source.contains("leaderboardStore: leaderboardStore"))
        XCTAssertTrue(source.contains("localBestResult:"))
        XCTAssertTrue(source.contains("onDeleteHistoryRecord:"))
        XCTAssertTrue(source.contains("onExportHistoryRecord:"))
        XCTAssertTrue(source.contains("monitorState.history(within: 120)"))
        XCTAssertFalse(source.contains("MacBenchmarkDashboardView"))

        XCTAssertTrue(dashboard.contains("开始性能测试"))
        XCTAssertTrue(dashboard.contains("最新结果"))
        // Review 2026-10-12: a legacy record without mSeries shows its own scores, not the newest comparable result.
        XCTAssertTrue(dashboard.contains("resultCard(result, title: L10n.text(\"所选结果\""))
        XCTAssertFalse(dashboard.contains("} else {\n                        latestResultCard\n"))
        XCTAssertTrue(dashboard.contains("本机最佳"))
        XCTAssertTrue(dashboard.contains("历史记录"))
        XCTAssertTrue(dashboard.contains("case leaderboard"))
        XCTAssertTrue(dashboard.contains("社区提交榜"))
        XCTAssertTrue(dashboard.contains("BenchmarkV7LeaderboardSection("))
        XCTAssertTrue(dashboard.contains("Picker("))
        XCTAssertTrue(dashboard.contains("onExportHistoryRecord"))
        XCTAssertTrue(dashboard.contains("onDeleteHistoryRecord"))
        XCTAssertTrue(dashboard.contains("BenchmarkV7PerformanceSummaryView"))
        XCTAssertTrue(dashboard.contains("BenchmarkV7RunProgressView"))
        XCTAssertTrue(dashboard.contains("DisclosureGroup(L10n.text(\"测试项目与边界\""))
        XCTAssertTrue(dashboard.contains("BenchmarkSystemMonitor("))
        XCTAssertTrue(dashboard.contains("telemetryPoints: liveTelemetry"))
        XCTAssertFalse(dashboard.contains("FileToolLandingArtwork("))
        XCTAssertTrue(dashboard.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertFalse(dashboard.contains(".shadow(color: accent.opacity(canStart"))
        // D64 removes the history disclaimer; real history input, comparison eligibility and errors remain.
        XCTAssertFalse(dashboard.contains("本机实际测试记录，与 FIXTURE 固定监控数据无关"))
        XCTAssertFalse(dashboard.contains("Actual local benchmark records, independent of FIXTURE monitor samples"))
        XCTAssertTrue(dashboard.contains("let history: [BenchmarkV7Result]"))
        XCTAssertTrue(dashboard.contains("history.sorted { historyTimestamp($0) > historyTimestamp($1) }"))
        XCTAssertTrue(dashboard.contains("historyCard(entry.element)"))
        XCTAssertTrue(dashboard.contains(".filter(\\.isCurrentComparableOfficialResult)"))
        XCTAssertTrue(dashboard.contains("switch Self.historyBadgeStatus(for: result)"))
        XCTAssertTrue(dashboard.contains("if let message = historyStatusMessage"))
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
