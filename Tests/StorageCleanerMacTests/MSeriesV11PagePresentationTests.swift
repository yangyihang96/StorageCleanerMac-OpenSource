import Foundation
import XCTest
@testable import StorageCleanerMac

/// The page fixture is deliberately unavailable to Release. These tests are
/// value-only; they never start a runner, coordinator, helper or benchmark store.
#if DEBUG
final class MSeriesV11PagePresentationTests: XCTestCase {
    private typealias Page = MSeriesV11PagePresentation

    func testRatioColumnsRoundDownWithoutChangingGapsOrBreakpoint() {
        for width in [CGFloat(408), 645.5, 646, 646.75, 739.5, 740, 740.75, 1_284.5] {
            let layout = Page.RatioLayout(availableWidth: width)
            XCTAssertEqual(layout.count, width >= 740 ? 4 : 2)
            XCTAssertEqual(layout.gap, 24)
            XCTAssertEqual(layout.columnWidth, floor(layout.columnWidth))
            XCTAssertLessThanOrEqual(layout.fittedWidth, width)
            XCTAssertLessThan(width - layout.fittedWidth, CGFloat(layout.count))
        }
    }

    func testStandardFixtureHasCore18AlignedEfficiencyAndSustained18Windows() throws {
        let result = MSeriesV11PageFixture.result()
        let core = try XCTUnwrap(result.mSeries)
        let envelope = try XCTUnwrap(result.mSeriesV11)
        XCTAssertEqual(core.metrics.map(\.id), MSeriesProtocol.coreIDs)
        XCTAssertTrue(core.metrics.allSatisfy(\.isValid))
        XCTAssertTrue(result.isPersistable)
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(Page.hasMeasuredEfficiency(envelope))
        let point = try XCTUnwrap(envelope.efficiencyPoints.first { $0.id == "power.cpu.allCores" })
        XCTAssertTrue(MSeriesV11Windows.validatesEfficiency(point, envelope: envelope))
        XCTAssertEqual(point.expectedSampleCount, 5)
        XCTAssertEqual(point.validSampleCount, 5)
        for sustained in [try XCTUnwrap(envelope.sustainedCPU), try XCTUnwrap(envelope.sustainedGPU)] {
            XCTAssertEqual(sustained.durationSeconds, 90)
            XCTAssertEqual(sustained.windows.count, 18)
            XCTAssertTrue(sustained.windows.allSatisfy { $0.validityReasons.isEmpty })
            let first = try XCTUnwrap(sustained.first10Median)
            let tail = try XCTUnwrap(sustained.tail30Metric?.statistics?.median)
            XCTAssertEqual(try XCTUnwrap(sustained.retention), tail / first, accuracy: 1e-12)
            XCTAssertLessThan(tail / first, 1)
        }
        XCTAssertTrue(envelope.telemetry.allSatisfy { $0.helperBootID == nil && $0.helperProcessOrdinal == 1 })
        XCTAssertFalse(MSeriesV11PageFixture.telemetry.isEmpty)
    }

    func testRunningTelemetryPreservesMeasuredIntervalsAndUsesRecentMonotonicEpoch() throws {
        let samples = MSeriesV11PageFixture.telemetry
        XCTAssertEqual(samples.count, 34)
        XCTAssertEqual(MSeriesV11Windows.measuredTelemetry(samples, gpu: false).count, samples.count)
        let end = try XCTUnwrap(samples.last?.responseReceivedMonotonicNs)
        let now = MSeriesV11Clock.nanoseconds
        XCTAssertLessThanOrEqual(end, now)
        XCTAssertLessThanOrEqual(MSeriesV11Windows.seconds(end, now), 60)
        XCTAssertTrue(samples.allSatisfy { ($0.cpuMilliwatts ?? 0) > 0 && $0.clusters?.isEmpty == false })
    }

    @MainActor
    func testFinalScoreCaptionsAndRatiosFollowD72GeometricWeights() throws {
        try withLanguage(.zhHans) {
            let envelope = try XCTUnwrap(MSeriesV11PageFixture.result().mSeriesV11)
            let gpuTail = try XCTUnwrap(envelope.sustainedGPU?.tail30Metric?.statistics?.median)
            let cpu = pow(1.5, 0.3) * pow(1.8, 0.7)
            let gpu = sqrt(1.6 * (gpuTail / 1_600))
            let chip = pow(cpu, 0.7) * pow(gpu, 0.3)
            let system = pow(chip, 0.55) * pow(1.45, 0.20) * pow(1.7, 0.25)
            XCTAssertEqual(try XCTUnwrap(envelope.scores?.chipScore), chip * 1_000, accuracy: 1e-8)
            XCTAssertEqual(try XCTUnwrap(envelope.scores?.systemScore), system * 1_000, accuracy: 1e-8)
            XCTAssertEqual(Page.referenceCaption(envelope), "相对 Apple M1＝1000")
            for id in ["chip", "system", "efficiency"] {
                let caption = Page.score(id, result: envelope)
                XCTAssertFalse(caption.hasPrefix("暂定"))
                XCTAssertNotEqual(caption, Page.calibration)
                XCTAssertNotEqual(caption, Page.helperRequired)
            }
            for (id, ratio) in [("cpu", cpu), ("gpu", gpu), ("memory", 1.45), ("storage", 1.7)] {
                XCTAssertEqual(try XCTUnwrap(Page.ratio(id, result: envelope)), ratio, accuracy: 1e-10)
            }
        }
    }

    @MainActor
    func testProvisionalPrefixIsOnEveryScoreAndNamesActualReference() throws {
        try withLanguage(.zhHans) {
            let envelope = try XCTUnwrap(MSeriesV11PageFixture.result(variant: "provisional").mSeriesV11)
            XCTAssertEqual(Page.reference(envelope).referenceStatus, .provisional)
            for id in ["chip", "system", "efficiency", "cpu", "gpu", "memory", "storage"] {
                XCTAssertTrue(Page.score(id, result: envelope).hasPrefix("暂定 "), id)
                XCTAssertEqual(try XCTUnwrap(Page.ratio(id, result: envelope)), 1, accuracy: 1e-10)
            }
            XCTAssertEqual(Page.referenceCaption(envelope), "相对 Apple M5 Pro 参考机＝1000")
            XCTAssertTrue(Page.referenceExplanation(envelope).contains("暂定基准＝Apple M5 Pro 受控采集"))
            XCTAssertTrue(Page.referenceExplanation(envelope).contains("取得 M1 数据后自动重算"))
        }
    }

    @MainActor
    func testEnglishProvisionalAndFinalReferenceCaptions() throws {
        try withLanguage(.english) {
            let provisional = try XCTUnwrap(MSeriesV11PageFixture.result(variant: "provisional").mSeriesV11)
            for id in ["chip", "system", "efficiency"] {
                XCTAssertTrue(Page.score(id, result: provisional).hasPrefix("Provisional "))
            }
            XCTAssertEqual(Page.referenceCaption(provisional), "Relative to Apple M5 Pro reference = 1000")
            XCTAssertTrue(Page.referenceExplanation(provisional).contains("controlled Apple M5 Pro runs"))
            let final = try XCTUnwrap(MSeriesV11PageFixture.result().mSeriesV11)
            XCTAssertEqual(Page.referenceCaption(final), "Relative to Apple M1 = 1000")
        }
    }

    @MainActor
    func testNoHelperLeavesPowerAndEfficiencyNilWhileKeepingChipAndSystemScores() throws {
        try withLanguage(.zhHans) {
            let result = MSeriesV11PageFixture.result(variant: "nohelper")
            let envelope = try XCTUnwrap(result.mSeriesV11)
            XCTAssertTrue(result.isComplete)
            XCTAssertEqual(envelope.telemetryAvailability, "unavailable")
            XCTAssertTrue(envelope.telemetry.isEmpty)
            XCTAssertFalse(Page.hasMeasuredEfficiency(envelope))
            XCTAssertNil(envelope.scores?.efficiencyScore)
            XCTAssertNil(Page.ratio("efficiency", result: envelope))
            XCTAssertEqual(Page.score("efficiency", result: envelope), "需要系统助手")
            for point in envelope.efficiencyPoints {
                XCTAssertNotNil(point.throughput?.statistics)
                XCTAssertNil(point.efficiency)
                XCTAssertNil(point.meanPowerW)
                XCTAssertNil(point.joules)
                XCTAssertNil(point.matchedWorkUnits)
                XCTAssertTrue(point.windows.allSatisfy { $0.powerW == nil && $0.frequencies.isEmpty })
            }
            let standard = try XCTUnwrap(MSeriesV11PageFixture.result().mSeriesV11)
            XCTAssertEqual(envelope.scores?.chipScore, standard.scores?.chipScore)
            XCTAssertEqual(envelope.scores?.systemScore, standard.scores?.systemScore)
            XCTAssertNotEqual(Page.score("chip", result: envelope), Page.helperRequired)
            XCTAssertNotEqual(Page.score("system", result: envelope), Page.calibration)
        }
    }

    @MainActor
    func testUnavailableReferenceShowsCalibrationButRetainsRawEfficiencyAndCore() throws {
        try withLanguage(.zhHans) {
            let result = MSeriesV11PageFixture.result(variant: "unavailable")
            let envelope = try XCTUnwrap(result.mSeriesV11)
            XCTAssertTrue(result.isComplete)
            XCTAssertEqual(Page.reference(envelope).referenceStatus, .unavailable)
            XCTAssertTrue(Page.hasMeasuredEfficiency(envelope))
            for id in ["chip", "system", "efficiency", "cpu", "gpu", "memory", "storage"] {
                XCTAssertEqual(Page.score(id, result: envelope), "待校准", id)
                XCTAssertNil(Page.ratio(id, result: envelope), id)
            }
            XCTAssertEqual(result.mSeries?.metrics.count, 18)
            XCTAssertTrue(result.mSeries?.metrics.allSatisfy { $0.statistics != nil } == true)
            XCTAssertTrue(Page.referenceCaption(envelope).contains("参考未就绪"))
            XCTAssertTrue(Page.referenceExplanation(envelope).contains("保留原始测量值"))
        }
    }

    @MainActor
    func testPartialFixtureDoesNotClaimCompletionOrAggregateScore() throws {
        try withLanguage(.zhHans) {
            let result = MSeriesV11PageFixture.result(variant: "partial")
            let envelope = try XCTUnwrap(result.mSeriesV11)
            XCTAssertTrue(result.isPersistable)
            XCTAssertFalse(result.isComplete)
            XCTAssertEqual(result.failure, .cancelled)
            XCTAssertEqual(envelope.state, "cancelled")
            XCTAssertEqual(result.mSeries?.metrics.count, 7)
            XCTAssertTrue(envelope.efficiencyPoints.isEmpty)
            XCTAssertNil(envelope.scores?.chipScore)
            XCTAssertNil(envelope.scores?.systemScore)
            XCTAssertEqual(Page.score("chip", result: envelope), "待校准")
        }
    }

    func testPointerChaseDecreaseIsImprovementAndThroughputDecreaseIsRegression() throws {
        let oldLatency = try metric("memory.pointerChase", value: 100)
        let lowerLatency = try metric("memory.pointerChase", value: 80)
        let latencyChange = try XCTUnwrap(compare(lowerLatency, previous: oldLatency))
        XCTAssertEqual(latencyChange.percent, -20, accuracy: 1e-10)
        XCTAssertTrue(latencyChange.improved)
        XCTAssertFalse(try XCTUnwrap(compare(oldLatency, previous: lowerLatency)).improved)
        let oldThroughput = try metric("memory.copy", value: 100)
        let throughputChange = try XCTUnwrap(compare(try metric("memory.copy", value: 80), previous: oldThroughput))
        XCTAssertEqual(throughputChange.percent, -20, accuracy: 1e-10)
        XCTAssertFalse(throughputChange.improved)
        XCTAssertTrue(try XCTUnwrap(compare(try metric("memory.copy", value: 120), previous: oldThroughput)).improved)
    }

    func testRawComparisonRejectsDifferentIDsUnitsAndMissingReadings() throws {
        let value = try metric("memory.copy", value: 100)
        XCTAssertNil(try compare(value, previous: nil))
        XCTAssertNil(try compare(value, previous: try metric("memory.triad", value: 100)))
        XCTAssertNil(try compare(value, previous: try metric("memory.copy", value: 100, unit: "MB/s")))
        let unknown = MSeriesMeasurement(id: "memory.copy", unit: value.unit, availability: .unknown,
            reason: "notRead", samples: [], statistics: nil, repetitions: 3, workers: 1)
        XCTAssertNil(try compare(unknown, previous: value))
    }

    func testUnchangedV10CoreRemainsRawComparableButV9AndContractChangesDoNot() throws {
        let current = MSeriesV11PageFixture.result()
        let legacy = MSeriesV11PageFixture.result(variant: "legacy-v10")
        XCTAssertTrue(Page.rawComparable(current, legacy))
        XCTAssertFalse(Page.scoreComparable(current, legacy))
        XCTAssertFalse(Page.rawComparable(current, current))
        XCTAssertFalse(Page.rawComparable(current, MSeriesV11PageFixture.result(variant: "legacy-v9")))
        let core = try XCTUnwrap(legacy.mSeries)
        for key in ["contractHash", "workload", "fixture", "statisticsVersion"] {
            let changed: MSeriesResult = try changing(core, key: key, value: "different-protocol")
            XCTAssertFalse(Page.rawComparable(current, copy(legacy, core: changed)), key)
        }
    }

    func testScoreComparisonRequiresSameProtocolAndExactReferenceIdentity() throws {
        let current = MSeriesV11PageFixture.result()
        let other = MSeriesV11PageFixture.result()
        XCTAssertTrue(Page.scoreComparable(current, other))
        XCTAssertFalse(Page.scoreComparable(current, MSeriesV11PageFixture.result(variant: "provisional")))
        XCTAssertFalse(Page.scoreComparable(current, MSeriesV11PageFixture.result(variant: "unavailable")))
        XCTAssertFalse(Page.scoreComparable(current, MSeriesV11PageFixture.result(variant: "legacy-v9")))
        let envelope = try XCTUnwrap(other.mSeriesV11)
        for key in ["schema", "mode", "coreContractHash", "extensionContractHash", "scoringContractHash"] {
            let changed: MSeriesV11Result = try changing(envelope, key: key, value: "different-contract")
            XCTAssertFalse(Page.scoreComparable(current, copy(other, envelope: changed)), key)
        }
        let scores = try XCTUnwrap(envelope.scores)
        for identity in [
            MSeriesReferenceIdentity(version: "another-reference", sha256: scores.referenceIdentity.sha256,
                referenceStatus: .final, provisionalAgainst: nil),
            MSeriesReferenceIdentity(version: scores.referenceIdentity.version, sha256: String(repeating: "f", count: 64),
                referenceStatus: .final, provisionalAgainst: nil)
        ] {
            var changed = envelope
            changed.scores = .init(componentScores: scores.componentScores, labels: scores.labels,
                referenceIdentity: identity, scoreStatus: scores.scoreStatus)
            XCTAssertFalse(Page.scoreComparable(current, copy(other, envelope: changed)))
        }
        var restricted = envelope
        var labels = scores.labels
        labels["chip"] = .init(status: .restricted, reasonCodes: ["batteryPower"])
        restricted.scores = .init(componentScores: scores.componentScores, labels: labels,
            referenceIdentity: scores.referenceIdentity, scoreStatus: scores.scoreStatus)
        XCTAssertFalse(Page.scoreComparable(current, copy(other, envelope: restricted)))
    }

    func testPreviousCorePicksNearestEarlierCompatibleRecord() throws {
        let current = MSeriesV11PageFixture.result()
        let date = try XCTUnwrap(current.completedAt)
        let oldest = copy(MSeriesV11PageFixture.result(), completedAt: date.addingTimeInterval(-200))
        let nearest = copy(MSeriesV11PageFixture.result(variant: "legacy-v10"), completedAt: date.addingTimeInterval(-10))
        let later = copy(MSeriesV11PageFixture.result(), completedAt: date.addingTimeInterval(10))
        let legacyV9 = copy(MSeriesV11PageFixture.result(variant: "legacy-v9"), completedAt: date.addingTimeInterval(-1))
        XCTAssertEqual(Page.previousCore(for: current, history: [later, legacyV9, oldest, current, nearest])?.session.id,
            nearest.session.id)
        XCTAssertNil(Page.previousCore(for: current, history: [current, later, legacyV9]))
    }

    func testEveryVariantRoundTripsAndLegacyMissingKeysDecodeWithoutV11Reinterpretation() throws {
        for variant in ["standard", "provisional", "nohelper", "unavailable", "partial", "legacy-v10", "legacy-v9"] {
            let result = MSeriesV11PageFixture.result(variant: variant)
            let decoded = try JSONDecoder().decode(BenchmarkV7Result.self, from: JSONEncoder().encode(result))
            XCTAssertEqual(decoded, result, variant)
        }
        for variant in ["legacy-v10", "legacy-v9"] {
            let result = MSeriesV11PageFixture.result(variant: variant)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
            for key in ["mSeriesV11", "completionStatus", "workloadExecutions", "hardwareProfile", "runtimeWarnings"] {
                object.removeValue(forKey: key)
            }
            let decoded = try JSONDecoder().decode(BenchmarkV7Result.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(decoded.mSeriesV11)
            XCTAssertTrue(decoded.isPersistable, variant)
            XCTAssertEqual(decoded.versions, result.versions)
            XCTAssertEqual(decoded.session.plan, result.session.plan)
            if variant == "legacy-v10" {
                XCTAssertEqual(decoded.mSeries?.metrics.count, 18)
                XCTAssertNil(decoded.mSeries?.overallIndex)
            } else {
                XCTAssertNil(decoded.mSeries)
                XCTAssertEqual(decoded.session.plan.planVersion, "benchmark-standard-plan-v9")
                XCTAssertEqual(decoded.coreScore?.overallScore, 6_000)
                XCTAssertFalse(Page.scoreComparable(decoded, MSeriesV11PageFixture.result()))
            }
        }
    }

    func testRunCapsEveryUnsavedPhaseAndOnlyCompletedMayDisplay100Percent() throws {
        let phases: [BenchmarkV7Phase] = [.preflighting, .preparing, .warmingUp, .calibrating, .running,
            .validating, .aggregating, .scoring, .persisting, .cancelling, .cancelled, .failed]
        for phase in phases {
            for fraction in [0, 0.5, 0.99, 1, 2] {
                let run = Page.Run(state: .phase(phase, sessionID: UUID()), weightedFraction: fraction, elapsedSeconds: 100)
                XCTAssertLessThanOrEqual(try XCTUnwrap(run.displayedFraction), 0.99, phase.rawValue)
            }
        }
        let completed = Page.Run(state: .phase(.completed, sessionID: UUID()), weightedFraction: 1, elapsedSeconds: 452)
        XCTAssertEqual(completed.displayedFraction, 1)
        let unknownFractions: [Double?] = [nil, .nan, .infinity, -.infinity]
        for fraction in unknownFractions {
            XCTAssertNil(Page.Run(state: MSeriesV11PageFixture.runState, weightedFraction: fraction, elapsedSeconds: nil).displayedFraction)
        }
        XCTAssertEqual(Page.Run(state: MSeriesV11PageFixture.runState, weightedFraction: -1, elapsedSeconds: 0).displayedFraction, 0)
    }

    func testRunCancellationIsAvailableDuringWorkAndDisabledWhileSavingOrStopping() {
        for phase in [BenchmarkV7Phase.preflighting, .preparing, .warmingUp, .calibrating,
                      .running, .validating, .aggregating, .scoring] {
            XCTAssertTrue(Page.Run(state: .phase(phase, sessionID: UUID()), weightedFraction: 0.5, elapsedSeconds: 100).canCancel)
        }
        for phase in [BenchmarkV7Phase.idle, .ready, .persisting, .cancelling, .cancelled, .failed, .completed] {
            XCTAssertFalse(Page.Run(state: .phase(phase, sessionID: UUID()), weightedFraction: 0.99, elapsedSeconds: 100).canCancel)
        }
    }

    @MainActor
    func testRunUsesChineseSubitemNamesAndExtensionIsNotCore19Of18() throws {
        try withLanguage(.zhHans) {
            for (index, id) in MSeriesProtocol.coreIDs.enumerated() {
                let run = Page.Run(state: .phase(.running, sessionID: UUID(), workloadID: id),
                    weightedFraction: 0.1, elapsedSeconds: 68)
                XCTAssertEqual(run.completedCoreCount, index)
                XCTAssertEqual(run.position, "核心第 \(index + 1) / 18 项")
                XCTAssertTrue(run.title.contains(MSeriesRunItemTitles.chineseTitle(for: id)))
                XCTAssertFalse(run.title.contains(id))
            }
            let extensionRun = Page.Run(state: .phase(.running, sessionID: UUID(), workloadID: "sustained.gpu"),
                weightedFraction: 0.8, elapsedSeconds: 350)
            XCTAssertEqual(extensionRun.completedCoreCount, 18)
            XCTAssertEqual(extensionRun.position, "扩展阶段 · 核心 18/18")
            XCTAssertFalse(extensionRun.position.contains("19"))
        }
    }

    func test460WeightedTimelineDoesNotRegressAndFreezesOnCancel() throws {
        XCTAssertEqual(MSeriesStageBudget.standardV11.map(\.weight), [5, 180, 45, 35, 95, 95, 5])
        var timeline = try MSeriesStageProgress(budgets: MSeriesStageBudget.standardV11, nowNanoseconds: 0)
        XCTAssertEqual(timeline.fraction(nowNanoseconds: 2_500_000_000), 2.5 / 460, accuracy: 1e-12)
        try timeline.advance(to: "core", nowNanoseconds: 5_000_000_000)
        XCTAssertEqual(timeline.fraction(nowNanoseconds: 95_000_000_000), 95.0 / 460, accuracy: 1e-12)
        let before = timeline.fraction(nowNanoseconds: 185_000_000_000)
        try timeline.advance(to: "cpuEfficiency", nowNanoseconds: 185_000_000_000)
        XCTAssertGreaterThanOrEqual(timeline.fraction(nowNanoseconds: 185_000_000_000), before)
        let frozen = timeline.fraction(nowNanoseconds: 200_000_000_000)
        timeline.stop(nowNanoseconds: 200_000_000_000)
        XCTAssertEqual(timeline.fraction(nowNanoseconds: 1_000_000_000_000), frozen)
        XCTAssertThrowsError(try timeline.advance(to: "gpuPeak", nowNanoseconds: 300_000_000_000))
        XCTAssertThrowsError(try timeline.didSave())

        var completed = try MSeriesStageProgress(budgets: MSeriesStageBudget.standardV11, nowNanoseconds: 0)
        var previous = 0.0
        var now: UInt64 = 0
        for budget in MSeriesStageBudget.standardV11 {
            try completed.advance(to: budget.id, nowNanoseconds: now)
            let entered = completed.fraction(nowNanoseconds: now)
            XCTAssertGreaterThanOrEqual(entered, previous)
            now += UInt64(budget.plannedSeconds * 1e9)
            previous = completed.fraction(nowNanoseconds: now)
            XCTAssertGreaterThanOrEqual(previous, entered)
            XCTAssertLessThanOrEqual(previous, 0.99)
        }
        XCTAssertEqual(previous, 0.99)
        try completed.didSave()
        XCTAssertEqual(completed.fraction(nowNanoseconds: now), 1)
    }

    func testPressureAndAcceleratorSelectionAreIndependentAndDurationUsesUnitBudgets() {
        var selection = MSeriesV11Selection()
        XCTAssertEqual(selection.mode, "standard")
        XCTAssertEqual(selection.estimatedSeconds, 420.0...480.0)
        XCTAssertTrue(selection.units.isEmpty)
        selection.accelerators = true
        let units: [MSeriesV11AcceleratorUnit] = [.media(.h264), .media(.hevc), .media(.proRes422), .rayTracing, .tensorFP16, .av1]
        XCTAssertEqual(selection.units, units)
        XCTAssertFalse(selection.pressure)
        XCTAssertFalse(selection.units.contains(.smallModel))
        let extra = units.reduce(0.0) { $0 + $1.collectionDeadlineSeconds }
        XCTAssertGreaterThan(extra, 0)
        XCTAssertEqual(selection.estimatedSeconds, (420 + extra)...(480 + extra))
        selection.pressure = true
        XCTAssertEqual(selection.mode, "pressure10m")
        XCTAssertEqual(selection.units, units)
        XCTAssertEqual(selection.estimatedSeconds, (600 + extra)...(660 + extra))
        selection.accelerators = false
        XCTAssertTrue(selection.pressure)
        XCTAssertEqual(selection.estimatedSeconds, 600.0...660.0)
        XCTAssertTrue(selection.units.isEmpty)
        selection.pressure = false
        XCTAssertEqual(selection, MSeriesV11Selection())
    }

    @MainActor
    func testChineseUnitsMissingChipFieldsAndAcceleratorStatesRemainDistinct() throws {
        try withLanguage(.zhHans) {
            XCTAssertEqual(Page.unit("fixed-fixtures/s"), "固定负载/秒")
            XCTAssertEqual(Page.unit("fixed-fixtures/J"), "固定负载/焦")
            XCTAssertEqual(Page.unit("fixtures/s"), "固定负载/秒")
            XCTAssertEqual(Page.unit("fixtures/J"), "固定负载/焦")
            XCTAssertEqual(Page.unit("ns/access"), "纳秒/次")
            XCTAssertEqual(Page.unit("IOPS"), "次/秒")
            XCTAssertEqual(Page.chipLine(nil, catalog: MSeriesV11PageFixture.catalog), "未读取")
            let identity = try XCTUnwrap(MSeriesV11PageFixture.identity)
            XCTAssertEqual(identity.identificationStatus, .matched)
            XCTAssertEqual(identity.matchedSKU?.id, "m5-pro-18c-20g")
            XCTAssertTrue(Page.catalogMatches(identity, MSeriesV11PageFixture.catalog))
            let line = Page.chipLine(identity, catalog: MSeriesV11PageFixture.catalog)
            for component in ["Apple M5 Pro", "6 超级", "12 性能", "GPU 20 核", "48 GB", "主动散热"] {
                XCTAssertTrue(line.contains(component), component)
            }
            XCTAssertEqual(Page.availability("unsupported"), "无此单元")
            XCTAssertEqual(Page.availability("unknown"), "未知")
            XCTAssertEqual(Page.availability("unavailable"), "当前不可用")
            XCTAssertEqual(Page.availability("notImplemented"), "阶段 2 · 尚未实现")
            let accelerators = try XCTUnwrap(MSeriesV11PageFixture.result().mSeriesV11).accelerators
            XCTAssertEqual(Set(accelerators.map(\.availability)),
                Set(["available", "unsupported", "unknown", "unavailable", "notImplemented"]))
            XCTAssertEqual(Page.community, "暂不可提交（服务端未上线）")
        }
    }

    func testDebugFixtureSourceHasOneStrictDebugBoundaryAndNoLiveExecutionOrActivation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Debug/MSeriesV11PageFixture.swift"), encoding: .utf8)
        XCTAssertTrue(source.hasPrefix("#if DEBUG\n"))
        XCTAssertTrue(source.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
        XCTAssertFalse(source.contains("#else"))
        for forbidden in ["Bundle.main", "MSeriesCoreRunner.run(", "MSeriesV11Runner(",
                          "SystemMSeriesV11BatchDriver(", "AppleSiliconHardwareCollector.capture",
                          "BenchmarkV7HistoryRepository(", "activateReference", ".write(to:"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    @MainActor
    private func withLanguage(_ language: AppLanguage, _ body: () throws -> Void) rethrows {
        let defaults = TestPreferenceDomain.make(for: self)
        defaults.set(language.rawValue, forKey: L10n.languageDefaultsKey)
        let preferences = TestVolatilePreferences()
        preferences.set(defaults.string(forKey: L10n.languageDefaultsKey) ?? language.rawValue,
            forKey: L10n.languageDefaultsKey)
        defer { preferences.restore() }
        XCTAssertEqual(L10n.usesChinese, language == .zhHans)
        try body()
    }

    private func compare(_ metric: MSeriesMeasurement, previous: MSeriesMeasurement?) throws -> Page.Comparison? {
        let current = try MSeriesV11EvidencePresentationTests.record(metric)
        let prior = try previous.map { try MSeriesV11EvidencePresentationTests.record($0) }
        return Page.comparison(metric, previous: previous, currentResult: current, previousResult: prior)
    }

    private func metric(_ id: String, value: Double, unit: String? = nil) throws -> MSeriesMeasurement {
        let samples = [BenchmarkV7RawSample](repeating:
            .init(value: value, elapsedSeconds: 1, wallElapsedSeconds: 1, checksum: 1), count: 3)
        return .init(id: id, unit: unit ?? MSeriesScoringV11.metricContract(id, extensionHash: "").unit,
            availability: .available, reason: nil, samples: samples,
            statistics: try BenchmarkStatistics.summarize(samples.map(\.value)), repetitions: 3, workers: 1)
    }

    private func changing<T: Codable>(_ value: T, key: String, value replacement: String) throws -> T {
        let encoder = JSONEncoder()
        encoder.userInfo[MSeriesV11CompactStorage.expandedEncoding] = true
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
        object[key] = replacement
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func copy(_ result: BenchmarkV7Result, core: MSeriesResult? = nil,
                      envelope: MSeriesV11Result? = nil, completedAt: Date? = nil) -> BenchmarkV7Result {
        .init(recordID: result.recordID, mSeries: core ?? result.mSeries, mSeriesV11: envelope ?? result.mSeriesV11,
            session: result.session, preflight: result.preflight, environment: result.environment,
            hardwareProfile: result.hardwareProfile, versions: result.versions, metrics: result.metrics,
            coreScore: result.coreScore, experienceScore: result.experienceScore, sustainedResult: result.sustainedResult,
            confidence: result.confidence, runtimeWarnings: result.runtimeWarnings, completionStatus: result.completionStatus,
            workloadFailure: result.workloadFailure, workloadExecutions: result.workloadExecutions,
            completedAt: completedAt ?? result.completedAt, failure: result.failure)
    }
}
#endif
