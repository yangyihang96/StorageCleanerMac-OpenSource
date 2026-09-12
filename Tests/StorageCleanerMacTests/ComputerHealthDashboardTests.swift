import Foundation
import XCTest
@testable import StorageCleanerMac

final class ComputerHealthDashboardTests: XCTestCase {
    func testDashboardIsComposedFromApprovedSectionsWithoutAutomaticProbe() throws {
        let root = projectRoot
        let viewSource = try source("Sources/StorageCleanerMac/Views/ComputerHealthView.swift", root: root)
        let requiredComponents = [
            "HealthScoreHero",
            "HealthActionList",
            "HealthFactorGrid",
        ]

        for component in requiredComponents {
            let path = "Sources/StorageCleanerMac/Views/ComputerHealth/\(component).swift"
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), path)
            XCTAssertTrue(viewSource.contains("\(component)("), "ComputerHealthView must compose \(component)")
        }

        XCTAssertTrue(viewSource.contains("scoreEvidenceDisclosure"))
        XCTAssertTrue(viewSource.contains("currentPowerCard"))
        XCTAssertTrue(viewSource.contains("protectionReadinessCard"))
        XCTAssertTrue(viewSource.contains("networkEnvironmentCard"))
        XCTAssertTrue(viewSource.contains("thermalReadinessCard"))
        XCTAssertTrue(viewSource.contains("snapshot.stability.spinCount"))
        XCTAssertTrue(viewSource.contains("无响应采样"))
        XCTAssertTrue(viewSource.contains("#if DEBUG"))
        XCTAssertTrue(viewSource.contains("ComputerHealthDebugFixture"))
        XCTAssertTrue(viewSource.contains("case longLocalizedText"))
        XCTAssertTrue(viewSource.contains(".frame(width: 980, height: 680)"))
        XCTAssertTrue(viewSource.contains("debugEnvironmentSection"))
        XCTAssertTrue(viewSource.contains("debugEvidenceSection"))
        XCTAssertTrue(viewSource.contains(
            "fixture == .longLocalizedText ? .unverifiable : .idle"
        ))
        XCTAssertTrue(viewSource.contains("TimelineView(.periodic"))
        XCTAssertTrue(viewSource.contains("now: timeline.date"))
        XCTAssertTrue(viewSource.contains("if !hasDashboardBatteryAction"))
        XCTAssertFalse(viewSource.contains(
            "|| healthStore.batterySettingsAdjustmentState != .idle"
        ))
        XCTAssertFalse(viewSource.contains(".onAppear"))
        XCTAssertFalse(viewSource.contains(".task { await healthStore.refresh"))

        let heroSource = try source(
            "Sources/StorageCleanerMac/Views/ComputerHealth/HealthScoreHero.swift",
            root: root
        )
        XCTAssertTrue(heroSource.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(heroSource.contains("private var evidenceMetadata"))

        let trendSource = try source(
            "Sources/StorageCleanerMac/Views/ComputerHealth/HealthTrendChart.swift",
            root: root
        )
        XCTAssertTrue(trendSource.contains("accessibilityReduceMotion"))
        XCTAssertTrue(trendSource.contains("if reduceMotion { transaction.animation = nil }"))
        XCTAssertFalse(trendSource.contains("repeatForever"))
    }

    func testHealthAndPerformanceUseIndependentWorkspaces() throws {
        let healthWorkspace = try source(
            "Sources/StorageCleanerMac/Views/ComputerHealth/ComputerHealthWorkspaceView.swift",
            root: projectRoot
        )
        let performanceWorkspace = try source(
            "Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkWorkspaceView.swift",
            root: projectRoot
        )
        let trend = try source(
            "Sources/StorageCleanerMac/Views/ComputerHealth/HealthTrendChart.swift",
            root: projectRoot
        )
        let factors = try source(
            "Sources/StorageCleanerMac/Views/ComputerHealth/HealthFactorGrid.swift",
            root: projectRoot
        )

        XCTAssertTrue(healthWorkspace.contains("AppPageHeader("))
        XCTAssertTrue(healthWorkspace.contains("ReviewFilter.healthHub.title"))
        XCTAssertFalse(healthWorkspace.contains("\"检查磁盘、电池与系统状态\""))
        XCTAssertFalse(healthWorkspace.contains("MacBenchmarkDashboardView"))
        XCTAssertFalse(healthWorkspace.contains("Picker("))
        XCTAssertTrue(performanceWorkspace.contains("DashboardPage("))
        XCTAssertTrue(performanceWorkspace.contains("性能测试"))
        XCTAssertTrue(performanceWorkspace.contains("BenchmarkV7DashboardView"))
        XCTAssertTrue(performanceWorkspace.contains("await benchmarkStore.loadHistory()"))
        XCTAssertTrue(performanceWorkspace.contains("benchmarkStore.startOfficialBenchmark"))
        XCTAssertFalse(performanceWorkspace.contains("MacBenchmarkDashboardView"))
        XCTAssertFalse(performanceWorkspace.contains("Picker("))
        XCTAssertFalse(performanceWorkspace.contains("\"Mac 跑分\""))
        XCTAssertTrue(trend.contains("完成两次检查后显示趋势"))
        XCTAssertTrue(factors.contains("ComputerHealthScoring.scoredFactors"))
        XCTAssertTrue(factors.contains("SMART 已验证只表示当前未报告故障"))
        XCTAssertTrue(factors.contains("当前电量代替寿命"))
        XCTAssertFalse(factors.contains("按有效证据加权"))
    }

    func testEmptyHealthDashboardDefersResultSectionsUntilEvaluationExists() throws {
        let viewSource = try source(
            "Sources/StorageCleanerMac/Views/ComputerHealthView.swift",
            root: projectRoot
        )

        XCTAssertTrue(viewSource.contains("if healthStore.evaluation == nil {"))
        XCTAssertTrue(viewSource.contains("healthEmptyState"))
        XCTAssertTrue(viewSource.contains("if healthStore.evaluation != nil"))
        XCTAssertTrue(viewSource.contains("HeroScanPage("))
        XCTAssertTrue(viewSource.contains("只读取系统状态，不会修改设置"))
        XCTAssertTrue(viewSource.contains("snapshot: healthStore.snapshot"))
        XCTAssertTrue(viewSource.contains("保护与当前状态（不计分）"))
        XCTAssertTrue(viewSource.contains("备份、FileVault、当前电量、温度与网络独立呈现"))
        XCTAssertFalse(viewSource.contains("HealthFactorGrid(evaluation: nil)"))
    }

    func testCompatibilitySpeedTestUsesSeparateConfirmationAndTruthfulTrafficDisclosure() throws {
        let viewSource = try source(
            "Sources/StorageCleanerMac/Views/ComputerHealthView.swift",
            root: projectRoot
        )

        XCTAssertTrue(viewSource.contains("pendingSpeedTestConsent = .compatibility"))
        XCTAssertTrue(viewSource.contains("networkStore.startCompatibility(consentGranted: true)"))
        XCTAssertTrue(viewSource.contains("networkStore.isCompatibilityAvailable"))
        XCTAssertTrue(viewSource.contains("公开测速端点 speed.cloudflare.com"))
        XCTAssertTrue(viewSource.contains("标准测试约产生"))
        XCTAssertTrue(viewSource.contains("maximumApplicationPayloadBytes"))
        XCTAssertTrue(viewSource.contains("网络重传会产生额外流量"))
        XCTAssertTrue(viewSource.contains("只保存完整结果，不保存服务器地址或 IP"))
        XCTAssertTrue(viewSource.contains("高速网络可能传输数 GB"))
        XCTAssertTrue(viewSource.contains("result.transferredBytes"))
        XCTAssertTrue(viewSource.contains("result.durationSeconds"))
        XCTAssertTrue(viewSource.contains("负载延迟 P95"))
        XCTAssertTrue(viewSource.contains("重试系统测速"))
        XCTAssertFalse(viewSource.contains("startCompatibility(consentGranted: false)"))
    }

    func testActionSelectionUsesStrictPriorityDeduplicatesFactorsAndStopsAtThree() {
        let evaluation = fixtureEvaluation(scores: [
            .diskReliability: 0,
            .capacity: 10,
            .stability: 15,
            .backup: 0,
            .battery: 25,
        ])
        let context = HealthDashboardActionContext(
            evaluation: evaluation,
            smartIsFailing: true,
            isUnderCurrentCapacityPressure: true,
            batteryServiceRecommended: true,
            backupNeedsAttention: true,
            hasRecentPanicOrRestart: true,
            forecastDaysUntilPressure: 12
        )

        let actions = HealthDashboardActionSelector.select(from: context)

        XCTAssertEqual(actions.count, 3)
        XCTAssertEqual(actions.map(\.factor), [.diskReliability, .capacity, .battery])
        XCTAssertEqual(actions.map(\.reason), [.smartFailing, .currentCapacityPressure, .batteryService])
        XCTAssertEqual(Set(actions.map(\.factor)).count, actions.count)
        XCTAssertEqual(Set(actions.map(\.safeAction)).count, actions.count)
    }

    func testCurrentPressureWinsForecastForSameCapacityFactor() {
        let context = HealthDashboardActionContext(
            evaluation: fixtureEvaluation(scores: [.capacity: 30]),
            smartIsFailing: false,
            isUnderCurrentCapacityPressure: true,
            batteryServiceRecommended: false,
            backupNeedsAttention: false,
            hasRecentPanicOrRestart: false,
            forecastDaysUntilPressure: 10
        )

        let actions = HealthDashboardActionSelector.select(from: context)

        XCTAssertEqual(actions.filter { $0.factor == .capacity }.count, 1)
        XCTAssertEqual(actions.first?.reason, .currentCapacityPressure)
        XCTAssertEqual(actions.first?.safeAction, .openSafeCleanup)
    }

    func testRemainingScoreBandTiesUseWeightedDeductionThenStableFactorOrder() {
        let evaluation = fixtureEvaluation(scores: [
            .diskReliability: 50,
            .capacity: 50,
            .stability: 50,
            .backup: 50,
            .battery: 50,
        ])
        let context = HealthDashboardActionContext(
            evaluation: evaluation,
            smartIsFailing: false,
            isUnderCurrentCapacityPressure: false,
            batteryServiceRecommended: false,
            backupNeedsAttention: false,
            hasRecentPanicOrRestart: false,
            forecastDaysUntilPressure: nil
        )

        XCTAssertEqual(
            HealthDashboardActionSelector.select(from: context).map(\.factor),
            [.diskReliability, .battery, .stability]
        )
    }

    func testWeightedDeductionsFollowV2CoreWeights() {
        let evaluation = fixtureEvaluation(scores: [
            .diskReliability: 80,
            .capacity: 76,
            .stability: 70,
            .backup: 60,
        ])
        let context = HealthDashboardActionContext(
            evaluation: evaluation,
            smartIsFailing: false,
            isUnderCurrentCapacityPressure: false,
            batteryServiceRecommended: false,
            backupNeedsAttention: false,
            hasRecentPanicOrRestart: false,
            forecastDaysUntilPressure: nil
        )

        XCTAssertEqual(
            HealthDashboardActionSelector.select(from: context).map(\.factor),
            [.diskReliability, .stability, .capacity]
        )
    }

    func testUnknownAndNotApplicableComponentsDoNotBecomePositiveActions() {
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let evaluation = ComputerHealthEvaluation.dataInsufficient(
            coverage: 0.2,
            confidence: HealthConfidence(value: 20, level: .low, modelVersion: "health-confidence-v1"),
            components: [
                HealthComponentEvaluation(
                    factor: .diskReliability,
                    availability: .unavailable,
                    score: nil,
                    evaluatedAt: date,
                    modelVersion: ComputerHealthEvaluation.currentModelVersion
                ),
                HealthComponentEvaluation(
                    factor: .battery,
                    availability: .notApplicable,
                    score: nil,
                    evaluatedAt: date,
                    modelVersion: ComputerHealthEvaluation.currentModelVersion
                ),
            ],
            evaluatedAt: date
        )
        let context = HealthDashboardActionContext(
            evaluation: evaluation,
            smartIsFailing: false,
            isUnderCurrentCapacityPressure: false,
            batteryServiceRecommended: false,
            backupNeedsAttention: false,
            hasRecentPanicOrRestart: false,
            forecastDaysUntilPressure: nil
        )

        XCTAssertTrue(HealthDashboardActionSelector.select(from: context).isEmpty)
    }

    func testSevenDayDeltaUsesClosestSameModelLocalDayAndPrefersNewerTie() throws {
        let calendar = fixedCalendar
        let currentDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 12)))
        let current = fixtureEvaluation(score: 90, date: currentDate)
        let history = [
            historyEntry(score: 70, date: date(2026, 7, 8), modelVersion: current.modelVersion),
            historyEntry(score: 80, date: date(2026, 7, 10), modelVersion: current.modelVersion),
            historyEntry(score: 5, date: date(2026, 7, 9), modelVersion: "older-model"),
        ]

        let delta = HealthScoreDeltaSelector.delta(
            current: current,
            history: history,
            targetDaysAgo: 7,
            toleranceDays: 2,
            calendar: calendar
        )

        XCTAssertEqual(try XCTUnwrap(delta), 10, accuracy: 0.0001)
    }

    func testThirtyDayDeltaRejectsCandidatesOutsideTolerance() {
        let current = fixtureEvaluation(score: 90, date: date(2026, 7, 16))
        let history = [historyEntry(score: 50, date: date(2026, 6, 9), modelVersion: current.modelVersion)]

        XCTAssertNil(HealthScoreDeltaSelector.delta(
            current: current,
            history: history,
            targetDaysAgo: 30,
            toleranceDays: 5,
            calendar: fixedCalendar
        ))
    }

    func testNetworkAndThermalRemainOutsideCoreScoreFactors() {
        let factorNames = Set(HealthFactor.allCases.map(\.rawValue))

        XCTAssertEqual(factorNames, ["diskReliability", "capacity", "stability", "backup", "battery"])
        XCTAssertFalse(factorNames.contains("network"))
        XCTAssertFalse(factorNames.contains("thermalReadiness"))
    }

    func testTrendPreservesScorelessDaysAndLatestLowCoverageEvaluation() {
        let currentDate = date(2026, 7, 16)
        let current = ComputerHealthEvaluation.dataInsufficient(
            coverage: 0.32,
            confidence: HealthConfidence(
                value: 24,
                level: .low,
                modelVersion: "health-confidence-v1"
            ),
            components: [],
            evaluatedAt: currentDate
        )
        let scorelessDate = date(2026, 7, 15)
        let scoreless = ComputerHealthEvaluation.dataInsufficient(
            coverage: 0.48,
            confidence: HealthConfidence(
                value: 35,
                level: .low,
                modelVersion: "health-confidence-v1"
            ),
            components: [],
            evaluatedAt: scorelessDate
        )
        let history = [
            historyEntry(score: 88, date: date(2026, 7, 14), modelVersion: current.modelVersion),
            ComputerHealthHistoryEntry(recordedAt: scorelessDate, evaluation: scoreless),
            historyEntry(
                score: 96,
                date: currentDate.addingTimeInterval(-3_600),
                modelVersion: current.modelVersion
            ),
        ]

        let points = HealthTrendSeries.points(
            current: current,
            history: history,
            calendar: fixedCalendar
        )

        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.map(\.date), [date(2026, 7, 14), scorelessDate, currentDate])
        XCTAssertEqual(points[0].score, 88)
        XCTAssertNil(points[1].score)
        XCTAssertEqual(points[1].coveragePercent, 48, accuracy: 0.0001)
        XCTAssertNil(points[2].score)
        XCTAssertEqual(points[2].coveragePercent, 32, accuracy: 0.0001)
    }

    func testScoreAccountingReconcilesPartialEvidenceAndNotApplicableBattery() throws {
        let checkedAt = date(2026, 7, 16)
        let components = [
            component(.diskReliability, availability: .available, score: 80, date: checkedAt),
            component(.capacity, availability: .partial, score: 50, date: checkedAt),
            component(.stability, availability: .available, score: 100, date: checkedAt),
            component(.backup, availability: .available, score: 60, date: checkedAt),
            component(.battery, availability: .notApplicable, score: nil, date: checkedAt),
        ]

        let accounting = ComputerHealthScoring.accounting(for: components)

        XCTAssertEqual(accounting.applicableWeight, 70, accuracy: 0.0001)
        XCTAssertEqual(accounting.creditedWeight, 62.5, accuracy: 0.0001)
        XCTAssertEqual(accounting.coverage, 62.5 / 70, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(accounting.normalizedScore), 5_175 / 62.5, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(accounting.component(for: .capacity)?.normalizedDeduction),
            375 / 62.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(accounting.component(for: .capacity)?.availabilityCredit),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(accounting.component(for: .capacity)?.creditedWeight),
            7.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(accounting.component(for: .battery)?.availabilityCredit),
            0,
            accuracy: 0.0001
        )
        XCTAssertNil(accounting.component(for: .battery)?.normalizedDeduction)
        XCTAssertEqual(
            accounting.components.compactMap(\.normalizedDeduction).reduce(0, +),
            100 - (5_175 / 62.5),
            accuracy: 0.0001
        )
    }

    func testBatteryTimeEstimateUsesChargingDirectionWithoutGuessingUnknownState() {
        XCTAssertEqual(
            BatteryTimeEstimateResolver.resolve(
                minutes: 38,
                isCharging: true,
                powerSource: .acPower
            ),
            BatteryTimeEstimate(kind: .untilFull, minutes: 38)
        )
        XCTAssertEqual(
            BatteryTimeEstimateResolver.resolve(
                minutes: 125,
                isCharging: false,
                powerSource: .batteryPower
            ),
            BatteryTimeEstimate(kind: .remaining, minutes: 125)
        )
        XCTAssertNil(BatteryTimeEstimateResolver.resolve(
            minutes: 20,
            isCharging: false,
            powerSource: .acPower
        ))
        XCTAssertNil(BatteryTimeEstimateResolver.resolve(
            minutes: 20,
            isCharging: nil,
            powerSource: .unknown
        ))
        XCTAssertNil(BatteryTimeEstimateResolver.resolve(
            minutes: -1,
            isCharging: true,
            powerSource: .acPower
        ))
    }

    func testBatteryActionPresentationTracksVerificationState() {
        let expectations: [(
            BatterySettingsAdjustmentState,
            BatterySettingsActionLabel,
            Bool
        )] = [
            (.idle, .openSettings, true),
            (.openingSettings, .openingSettings, false),
            (.awaitingVerification, .verifySettings, true),
            (.verifying, .verifying, false),
            (.unchanged, .verifyAgain, true),
            (.expired, .reopenSettings, true),
            (.failedToOpen, .reopenSettings, true),
            (.unverifiable, .openManually, true),
            (.verified, .recheckSettings, true),
        ]

        for (state, label, isEnabled) in expectations {
            XCTAssertEqual(
                BatterySettingsActionResolver.resolve(state),
                BatterySettingsActionPresentation(label: label, isEnabled: isEnabled)
            )
        }
        XCTAssertNotEqual(
            BatterySettingsActionResolver.resolve(.verified).label,
            .openSettings
        )
    }

    func testThermalPresentationDistinguishesNotCheckedUnknownAndStale() {
        let now = date(2026, 7, 16)

        XCTAssertEqual(
            ThermalReadinessResolver.resolve(.ready, checkedAt: nil, now: now),
            .notChecked
        )
        XCTAssertEqual(
            ThermalReadinessResolver.resolve(.unknown, checkedAt: now, now: now),
            .current(.unknown)
        )
        XCTAssertEqual(
            ThermalReadinessResolver.resolve(
                .ready,
                checkedAt: now.addingTimeInterval(-601),
                now: now
            ),
            .stale
        )
        XCTAssertEqual(
            ThermalReadinessResolver.resolve(
                .ready,
                checkedAt: now.addingTimeInterval(1),
                now: now
            ),
            .stale
        )
        XCTAssertEqual(
            ThermalReadinessResolver.resolve(
                .ready,
                checkedAt: now.addingTimeInterval(-600),
                now: now
            ),
            .current(.ready)
        )
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

    private var fixedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        fixedCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func fixtureEvaluation(
        scores: [HealthFactor: Double],
        date: Date = Date(timeIntervalSinceReferenceDate: 100)
    ) -> ComputerHealthEvaluation {
        let components = HealthFactor.allCases.compactMap { factor -> HealthComponentEvaluation? in
            guard let score = scores[factor] else { return nil }
            return HealthComponentEvaluation(
                factor: factor,
                availability: .available,
                score: score,
                evaluatedAt: date,
                modelVersion: ComputerHealthEvaluation.currentModelVersion
            )
        }
        return ComputerHealthEvaluation(
            score: scores.values.reduce(0, +) / Double(max(scores.count, 1)),
            status: .attention,
            coverage: 1,
            confidence: HealthConfidence(value: 90, level: .high, modelVersion: "health-confidence-v1"),
            components: components,
            evaluatedAt: date
        )
    }

    private func fixtureEvaluation(score: Double, date: Date) -> ComputerHealthEvaluation {
        ComputerHealthEvaluation(
            score: score,
            status: .healthy,
            coverage: 1,
            confidence: HealthConfidence(value: 90, level: .high, modelVersion: "health-confidence-v1"),
            components: [],
            evaluatedAt: date
        )
    }

    private func historyEntry(
        score: Double,
        date: Date,
        modelVersion: String
    ) -> ComputerHealthHistoryEntry {
        let evaluation = ComputerHealthEvaluation(
            score: score,
            status: .attention,
            coverage: 1,
            confidence: HealthConfidence(value: 80, level: .high, modelVersion: "health-confidence-v1"),
            components: [],
            evaluatedAt: date,
            modelVersion: modelVersion
        )
        return ComputerHealthHistoryEntry(recordedAt: date, evaluation: evaluation)
    }

    private func component(
        _ factor: HealthFactor,
        availability: HealthEvidenceAvailability,
        score: Double?,
        date: Date
    ) -> HealthComponentEvaluation {
        HealthComponentEvaluation(
            factor: factor,
            availability: availability,
            score: score,
            evaluatedAt: date,
            modelVersion: ComputerHealthEvaluation.currentModelVersion
        )
    }
}
