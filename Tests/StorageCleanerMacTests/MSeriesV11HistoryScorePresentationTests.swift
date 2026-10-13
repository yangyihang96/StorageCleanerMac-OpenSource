#if DEBUG
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class MSeriesV11HistoryScorePresentationTests: XCTestCase {
    static func record(restrictedIDs: [String]) throws -> BenchmarkV7Result {
        let base = MSeriesV11PageFixture.result()
        var envelope = try XCTUnwrap(base.mSeriesV11)
        let scores = try XCTUnwrap(envelope.scores)
        var labels = scores.labels
        for id in restrictedIDs { labels[id] = .init(status: .restricted, reasonCodes: ["batteryPower", "lowPower"]) }
        envelope.scores = .init(componentScores: scores.componentScores, labels: labels,
            referenceIdentity: scores.referenceIdentity, scoreStatus: scores.scoreStatus)
        return .init(recordID: base.recordID, mSeries: base.mSeries, mSeriesV11: envelope,
            session: base.session, preflight: base.preflight, versions: base.versions,
            metrics: [], coreScore: nil, completedAt: base.completedAt, failure: base.failure)
    }

    func testCurrentRestrictedHistoryUsesSummaryStatusReasonAndNumbers() throws {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            let current = try Self.record(restrictedIDs: ["chip", "system", "efficiency"])
            let envelope = try XCTUnwrap(current.mSeriesV11)
            let history = MSeriesV11PagePresentation.historyScores(current, current: current)
            XCTAssertEqual(history.map(\.id), ["chip", "system", "efficiency"])
            XCTAssertFalse(MSeriesV11PagePresentation.scoreComparable(current, current))
            for display in history {
                let summary = MSeriesV11PagePresentation.ScoreDisplay(id: display.id, result: envelope)
                XCTAssertEqual(display.metric, summary.metric)
                XCTAssertEqual(display.metric.status, .unknown)
                XCTAssertEqual(display.historyMetric.status, summary.metric.status)
                XCTAssertEqual(display.historyMetric.value, summary.metric.valuePrefix + summary.metric.value)
                XCTAssertEqual(display.reason, summary.reason)
                let reason = try XCTUnwrap(display.reason)
                XCTAssertTrue(reason.contains(L10n.text("电池供电", "Battery power")))
                XCTAssertTrue(reason.contains(L10n.text("省电模式", "Low Power Mode")))
                XCTAssertEqual(display.historyMetric.caption, reason)
                for scheme in [ColorScheme.light, .dark] {
                    let palette = FeatureLightfieldPalette.resolve(scheme)
                    XCTAssertEqual(display.historyMetric.status?.color(palette), palette.fg3)
                }
            }
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let historySource = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkV11RawRow.swift"), encoding: .utf8)
        XCTAssertTrue(historySource.contains("MSeriesV11PagePresentation.historyScores(record, current: current)"))
        XCTAssertTrue(historySource.contains("metrics: displays.map(\\.historyMetric)"))
        XCTAssertTrue(historySource.contains("if let reason = display.reason"))
        XCTAssertTrue(historySource.contains("Text(display.metric.label + \" · \" + reason)"))
    }

    func testComparableChipCannotMakeRestrictedSystemOrEfficiencyComparable() throws {
        let current = MSeriesV11PageFixture.result()
        let comparable = MSeriesV11PageFixture.result()
        XCTAssertTrue(MSeriesV11PagePresentation.scoreComparable(current, comparable))
        for id in ["system", "efficiency"] {
            let restricted = try Self.record(restrictedIDs: [id])
            XCTAssertEqual(restricted.mSeriesV11?.scores?.labels["chip"]?.status, .comparable)
            XCTAssertEqual(restricted.mSeriesV11?.scores?.labels[id]?.status, .restricted)
            XCTAssertFalse(MSeriesV11PagePresentation.scoreComparable(current, restricted))
            XCTAssertFalse(MSeriesV11PagePresentation.scoreComparable(restricted, current))
            XCTAssertTrue(MSeriesV11PagePresentation.historyScores(restricted, current: current).isEmpty)
            XCTAssertTrue(MSeriesV11PagePresentation.historyScores(current, current: restricted).isEmpty)
            let sameRecord = MSeriesV11PagePresentation.historyScores(restricted, current: restricted)
            XCTAssertEqual(sameRecord.count, 3)
            XCTAssertEqual(sameRecord.first(where: { $0.id == id })?.metric.status, .unknown)
            XCTAssertNotNil(sameRecord.first(where: { $0.id == id })?.reason)
        }
    }
}
#endif
