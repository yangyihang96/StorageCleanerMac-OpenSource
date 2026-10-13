import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Found while reviewing batch 4b: a fan history replaces every point's fan
/// speed with the selected fan's before it is drawn, but the line chart's
/// prepared-frame key named only the channel. The average and each fan (same
/// points' dates and count, same channel) shared one cached frame, so one fan
/// could be drawn with another's speeds until the next sample.
@MainActor
final class MiniWindowFanHistoryCacheTests: XCTestCase {
    func testEachFanAndTheAverageHaveTheirOwnPreparedFrame() {
        let series = [nil, 0, 1].map { GeekFanHoverDetail.chartSeries(selectedFanIndex: $0, title: "Fan", color: .red) }
        XCTAssertEqual(Set(series.flatMap { $0.map(\.id) }).count, 3, "the series name its fan")

        let configurations = series.map {
            GeekPrecisionLineChart.preparationConfiguration(
                series: $0, plotRect: CGRect(x: 8, y: 4, width: 344, height: 136), duration: 3_600,
                displayScale: 2, style: .line, valueRange: 0...6_000, samplingInterval: 1
            )
        }
        XCTAssertEqual(Set(configurations).count, 3, "one prepared frame per fan and one for the average")

        // The same fan keeps its frame.
        let again = GeekPrecisionLineChart.preparationConfiguration(
            series: GeekFanHoverDetail.chartSeries(selectedFanIndex: 1, title: "Fan", color: .blue),
            plotRect: CGRect(x: 8, y: 4, width: 344, height: 136), duration: 3_600,
            displayScale: 2, style: .line, valueRange: 0...6_000, samplingInterval: 1
        )
        XCTAssertEqual(again, configurations[2], "colors and titles are not part of the frame")
    }

    func testTheChartUsesTheSharedConfiguration() throws {
        let charts = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift")
        let call = try XCTUnwrap(charts.components(separatedBy: "MenuBarChartPreparation(kind: \"line-frame\"").dropFirst().first?
            .components(separatedBy: "build:").first)
        XCTAssertTrue(call.contains("configuration: Self.preparationConfiguration("))
        let fan = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift")
        XCTAssertTrue(fan.contains("series: Self.chartSeries(selectedFanIndex: selectedFanIndex"))
    }
}
