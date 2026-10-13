import AppKit
import XCTest
@testable import StorageCleanerMac

final class MSeriesV11CurvePresentationTests: XCTestCase {
    func testEnlargedAxisValuesFitThirtySixPointsAtApprovedMinimumAndKeepUnits() {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for value in [0.0, 50, 9999, 10_000, 1e13, 9.876e100, Double.greatestFiniteMagnitude,
                      -1e13, -Double.greatestFiniteMagnitude] {
            let original = String(value)
            let text = LightfieldAxisLabel.display(original)
            let width = (text as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(width * 0.75, 36, original + " → " + text)
            if abs(value) >= 10_000 { XCTAssertTrue(text.contains("e")); XCTAssertLessThanOrEqual(text.count, 7) }
        }
        XCTAssertEqual(LightfieldAxisLabel.display("100°C"), "100°C")
        XCTAssertEqual(LightfieldAxisLabel.display("12,345,678 W"), "1.2e7 W")
        XCTAssertEqual(LightfieldAxisLabel.display("未读取"), "未读取")
    }
    func testApprovedRunningHierarchyCPUThreadPointLabelsAndSustainedLegend() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let running = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkV11RunningPage.swift"), encoding: .utf8)
        XCTAssertTrue(running.contains("Text(MSeriesV11PagePresentation.number(currentObservation?.efficiency)).font(.system(size: 24, weight: .semibold))"))
        let result = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkV11ResultPage.swift"), encoding: .utf8)
        XCTAssertTrue(result.contains("pointLabels: points.map { ($0.resolvedWorkers.map(String.init)"))
        XCTAssertTrue(result.contains("primaryName: L10n.text(\"吞吐\", \"Throughput\")"))
        XCTAssertTrue(result.contains("name: L10n.text(\"温度\", \"Temperature\")"))
        XCTAssertTrue(result.contains("legend: .series, showsPressureBands: false"))
    }
}
