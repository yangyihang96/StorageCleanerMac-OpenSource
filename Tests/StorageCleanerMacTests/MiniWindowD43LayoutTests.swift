import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D43 (2026-10-06, iStat comparison): the memory rings are pressure on the
/// left and usage on the right (was D4's usage left, pressure right), in the
/// overview, on the memory page and in the settings preview; the CPU card's
/// title shows the frequency and the temperature (was the total usage,
/// which the legend expresses), only what was read.
@MainActor
final class MiniWindowD43LayoutTests: XCTestCase {
    func testTheMemoryRingsArePressureLeftAndUsageRight() throws {
        let overview = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekOverviewPresentation.swift")
        let card = try MiniWindowLogicFixtures.section(
            overview, from: "struct GeekMemoryPresentation: View {", to: "struct GeekNetworkPresentation: View {")
        try assertPressureBeforeUsage(card, pressure: "L10n.text(\"压力评估\", \"Pressure estimate\")",
                                      usage: "L10n.text(\"占用\", \"Used\")", where: "overview / settings preview")

        let memoryPage = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift")
        let rings = try MiniWindowLogicFixtures.section(
            memoryPage, from: "private var geekMemoryRingsCard: some View {", to: "private var geekMemoryProcessesCard")
        try assertPressureBeforeUsage(rings, pressure: "geekMemoryPressureRing(size:",
                                      usage: "L10n.text(\"占用\", \"Used\")", where: "memory page")

        // The settings preview draws the overview's presentation.
        let settings = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MiniWindowConfigurationSettingsView.swift")
        XCTAssertTrue(settings.contains("GeekMemoryPresentation(memoryRingUsedPercentText:"))
    }

    func testTheCPUTitleShowsFrequencyAndTemperatureOnlyWhenRead() throws {
        XCTAssertEqual(GeekProcessorPresentation.headerReadout(frequency: "4.43 GHz", temperature: "80°C"),
                       "4.43 GHz · 80°C")
        XCTAssertEqual(GeekProcessorPresentation.headerReadout(frequency: nil, temperature: "80°C"), "80°C")
        XCTAssertEqual(GeekProcessorPresentation.headerReadout(frequency: "4.43 GHz", temperature: nil), "4.43 GHz")
        XCTAssertNil(GeekProcessorPresentation.headerReadout(frequency: nil, temperature: nil),
                     "nothing read: nothing shown, no made-up value")

        let overview = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekOverviewPresentation.swift")
        let card = try MiniWindowLogicFixtures.section(
            overview, from: "struct GeekProcessorPresentation: View {", to: "struct GeekMemoryPresentation: View {")
        let header = try MiniWindowLogicFixtures.section(
            card, from: "GeekModuleHeader(systemImage: AppSymbols.Monitor.processor, title: \"CPU\") {",
            to: "GeekPrecisionLineChart(")
        XCTAssertTrue(header.contains("Self.headerReadout(frequency: headerFrequencyText, temperature: headerTemperatureText)"))
        XCTAssertFalse(header.contains("Text(Self.totalText("), "the total is in the legend, not the title")

        let panel = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift")
        let live = try MiniWindowLogicFixtures.section(panel, from: "var geekProcessorCard: some View {",
                                                       to: "private var geekCPUUserBarColor")
        XCTAssertTrue(live.contains("headerFrequencyText: geekCompactFrequencyText"))
        XCTAssertTrue(live.contains("headerTemperatureText: temperatureValue.map(geekCompactTemperature)"))
    }

    /// The header readout ends at the card's trailing inset; without a
    /// reading the title row has no readout at all.
    func testTheCPUTitleReadoutRendersAtTheTrailingInset() throws {
        let width = MiniWindowStyleTokens.overviewSize.width - 2 * MiniWindowStyleTokens.contentInset
        let scale: CGFloat = 2
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let clock = PanelChartClock(anchor: .init(wallDate: date, instant: ContinuousClock().now))
        let point = MenuBarTelemetryPoint(
            date: date, cpuTotal: 40, cpuUser: 24, cpuSystem: 16, gpu: nil, memory: nil,
            chipTemperature: nil, fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: nil)
        let readoutTint = Color(red: 0, green: 0.78, blue: 0)
        func headerReadoutMaxX(frequency: String?, temperature: String?) throws -> CGFloat? {
            let view = GeekProcessorPresentation(
                cpuChartHistory: [point], cpuChartRange: .oneMinute, samplingInterval: 1,
                processorTint: .orange, geekCPUUserBarColor: .blue, geekCPUSystemBarColor: .pink,
                headerFrequencyText: frequency, headerTemperatureText: temperature,
                headerReadoutTint: readoutTint)
                .frame(width: width)
                .environment(\.colorScheme, .dark)
                .environment(\.miniWindowVisualMode, .black)
                .environment(\.panelChartClock, clock)
                .environment(\.displayScale, scale)
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let headerBottom = Int((GeekVisualTokens.cardVerticalPadding + MiniWindowStyleTokens.dataRowHeight) * scale)
            var maximumX = -1
            for y in 0..<min(bitmap.pixelsHigh, headerBottom) {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          color.alphaComponent > 0.8, color.greenComponent > 0.5,
                          color.redComponent < 0.3, color.blueComponent < 0.3 else { continue }
                    maximumX = max(maximumX, x)
                }
            }
            return maximumX < 0 ? nil : CGFloat(maximumX + 1) / scale
        }
        for (frequency, temperature) in [("4.43 GHz", "80°C"), (nil, "80°C"), ("4.43 GHz", nil)] as [(String?, String?)] {
            let maxX = try XCTUnwrap(try headerReadoutMaxX(frequency: frequency, temperature: temperature),
                                     "the readout is drawn: \(frequency ?? "-") \(temperature ?? "-")")
            XCTAssertEqual(maxX, width - GeekVisualTokens.cardHorizontalPadding, accuracy: 2)
        }
        XCTAssertNil(try headerReadoutMaxX(frequency: nil, temperature: nil), "no readout without a reading")
    }

    /// r2-live-fixes-2 review P2-2: the total left the title, so the header
    /// is one accessibility element ("CPU", the readout) whose value is the
    /// total. Without `.accessibilityElement(children: .combine)` the value
    /// sat on a plain HStack that VoiceOver need not read. (In this test
    /// process the accessibility tree of a SwiftUI view is empty, so the
    /// modifiers and their order are what is checked.)
    func testTheCPUHeaderIsOneAccessibilityElementWhoseValueIsTheTotal() throws {
        let overview = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekOverviewPresentation.swift")
        let header = try MiniWindowLogicFixtures.section(
            overview,
            from: "GeekModuleHeader(systemImage: AppSymbols.Monitor.processor, title: \"CPU\") {",
            to: "GeekPrecisionLineChart(")
        let combine = try XCTUnwrap(header.range(of: ".accessibilityElement(children: .combine)"),
                                    "the header is one element").lowerBound
        let value = try XCTUnwrap(header.range(of: ".accessibilityValue(L10n.text(\"总占用 \\(total)\", \"Total \\(total)\"))"),
                                  "its value is the total").lowerBound
        let help = try XCTUnwrap(header.range(of: ".help(L10n.text(\"CPU 总占用 \\(total)\", \"CPU total \\(total)\"))"),
                                 "its help is the total").lowerBound
        XCTAssertLessThan(combine, value, "the value is set on the combined element")
        XCTAssertLessThan(combine, help)
    }

    private func assertPressureBeforeUsage(_ source: String, pressure: String, usage: String,
                                           where place: String) throws {
        let pressureAt = try XCTUnwrap(source.range(of: pressure), "\(place): no pressure ring").lowerBound
        let usageAt = try XCTUnwrap(source.range(of: usage), "\(place): no usage ring").lowerBound
        XCTAssertLessThan(pressureAt, usageAt, "\(place): D43 puts the pressure ring on the left")
    }
}
