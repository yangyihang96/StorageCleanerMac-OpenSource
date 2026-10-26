import Foundation
import XCTest
@testable import StorageCleanerMac

/// D128: iStat Menus 7.30's number formats (BBRUtilities `*Data` /
/// `Format*` and the configurations its menus pass, R8b static).
final class IStatNumberFormatTests: XCTestCase {
    private let us = Locale(identifier: "en_US")

    func testNumbersRoundHalfUpWithGroupingAndMaximumFormsDropTrailingZeros() {
        XCTAssertEqual(IStatNumberFormat.number(1.235, decimals: 2, locale: us), "1.24")
        XCTAssertEqual(IStatNumberFormat.number(2.0, decimals: 2, locale: us), "2")
        XCTAssertEqual(IStatNumberFormat.number(1.5, decimals: 2, locale: us), "1.5")
        XCTAssertEqual(IStatNumberFormat.number(12_345, decimals: 0, locale: us), "12,345")
        XCTAssertEqual(IStatNumberFormat.decimal(12.25, fractionDigits: 1...1, locale: us), "12.3")
        XCTAssertEqual(IStatNumberFormat.decimal(.nan, fractionDigits: 0...1, locale: us), "--")
        XCTAssertEqual(IStatNumberFormat.number(1.5, decimals: 1, locale: Locale(identifier: "de_DE")), "1,5")
        XCTAssertEqual(IStatNumberFormat.percent(4.44, decimals: 1, locale: us), "4.4%")
        XCTAssertEqual(IStatNumberFormat.percent(32.0, decimals: 1, locale: us), "32%")
        XCTAssertEqual(IStatNumberFormat.percent(12.5, decimals: 0, locale: us), "13%")
    }

    func testDecimalTablesPickTheFirstStepAboveTheValueOrNone() {
        let table = IStatNumberFormat.oneDecimalBelowHundred
        XCTAssertEqual(IStatNumberFormat.DecimalStep.decimals(for: 99.9, in: table), 1)
        XCTAssertEqual(IStatNumberFormat.DecimalStep.decimals(for: 100, in: table), 0)
        XCTAssertEqual(IStatNumberFormat.DecimalStep.decimals(for: 5, in: []), 0)
        XCTAssertEqual(IStatNumberFormat.DecimalStep.decimals(for: .nan, in: table), 0)
    }

    func testMemoryCountsIn1024sKeepsTrailingZerosAndShowsKilobytesUpTo1024() {
        XCTAssertEqual(IStatNumberFormat.memory(512, locale: us), "1 KB")
        XCTAssertEqual(IStatNumberFormat.memory(1_048_576, locale: us), "1,024 KB")
        XCTAssertEqual(IStatNumberFormat.memory(1_048_577, locale: us), "1.0 MB")
        XCTAssertEqual(IStatNumberFormat.memory(150 * 1_048_576, locale: us), "150 MB")
        XCTAssertEqual(IStatNumberFormat.memory(8 * 1_073_741_824, locale: us), "8.0 GB")
        XCTAssertEqual(IStatNumberFormat.memory(Int64(12.25 * 1_073_741_824), locale: us), "12.3 GB")
        XCTAssertEqual(IStatNumberFormat.memory(2 * 1_099_511_627_776.0, locale: us), "2.00 TB")
    }

    func testBandwidthNeverShowsBytesAndUpgradesEarlyInRowsButNotInLargeValues() {
        XCTAssertEqual(IStatNumberFormat.bandwidth(0, locale: us), "0 KB/s")
        // No decimals prints "%.0f": exact halves round to even.
        XCTAssertEqual(IStatNumberFormat.bandwidth(512, locale: us), "0 KB/s")
        XCTAssertEqual(IStatNumberFormat.bandwidth(12_288, locale: us), "12 KB/s")
        XCTAssertEqual(IStatNumberFormat.bandwidth(999_999, locale: us), "977 KB/s")
        XCTAssertEqual(IStatNumberFormat.bandwidth(1_000_000, locale: us), "1.0 MB/s")
        XCTAssertEqual(IStatNumberFormat.bandwidth(150 * 1_048_576, locale: us), "150 MB/s")
        XCTAssertEqual(IStatNumberFormat.bandwidth(1e9, locale: us), "0.9 GB/s")
        XCTAssertEqual(IStatNumberFormat.bandwidth(1_000_000, style: .large, locale: us), "977 KB/s")
        XCTAssertEqual(IStatNumberFormat.bandwidth(1_048_576, style: .large, locale: us), "1.0 MB/s")
        XCTAssertEqual(IStatNumberFormat.bandwidth(1.5 * 1_073_741_824, style: .large, locale: us), "1.50 GB/s")
        XCTAssertEqual(IStatNumberFormat.bandwidth(12_288, style: .process, locale: us), "12 K")
        XCTAssertEqual(IStatNumberFormat.bandwidth(1_572_864, style: .process, locale: us), "1.5 M")
        XCTAssertEqual(IStatNumberFormat.bandwidth(500, style: .process, locale: us), "0 K", "rates ignore hide-bytes")
        XCTAssertEqual(IStatNumberFormat.bandwidth(1_000, bits: true, locale: us), "8 Kb/s")
    }

    func testDiskActivityKeepsFixedDecimalsAndProcessesHideBytes() {
        XCTAssertEqual(IStatNumberFormat.diskActivity(512, locale: us), "1 KB/s", "fixed decimals round half up")
        XCTAssertEqual(IStatNumberFormat.diskActivity(2_048_000, locale: us), "2.0 MB/s")
        XCTAssertEqual(IStatNumberFormat.diskActivity(1_048_575, style: .large, locale: us), "1,024 KB/s")
        XCTAssertEqual(IStatNumberFormat.diskActivity(512, style: .process, locale: us), "-")
        XCTAssertEqual(IStatNumberFormat.diskActivity(12_288, style: .process, locale: us), "12K")
        XCTAssertEqual(IStatNumberFormat.diskActivity(1_572_864, style: .process, locale: us), "1.5M")
        XCTAssertEqual(IStatNumberFormat.diskActivity(2e9, style: .process, locale: us), "1.9G")
    }

    func testDiskSpaceCountsIn1000sAndDropsTrailingZeros() {
        XCTAssertEqual(IStatNumberFormat.space(500_000_000_000, locale: us), "500 GB")
        XCTAssertEqual(IStatNumberFormat.space(499_963_174_912, locale: us), "500 GB")
        XCTAssertEqual(IStatNumberFormat.space(245_107_195_904, locale: us), "245.1 GB")
        XCTAssertEqual(IStatNumberFormat.space(1.5e12, locale: us), "1.5 TB")
        XCTAssertEqual(IStatNumberFormat.space(1_000_000, locale: us), "1,000 KB")
        XCTAssertEqual(IStatNumberFormat.space(1_234_567_890, style: .totals, locale: us), "1.23 GB")
    }

    func testSensorsUseIStatUnitsAndDecimals() {
        XCTAssertEqual(IStatNumberFormat.temperature(45.4, locale: us), "45°")
        XCTAssertEqual(IStatNumberFormat.temperature(45.5, locale: us), "46°")
        XCTAssertEqual(IStatNumberFormat.fanSpeed(1_234, locale: us), "1,234 rpm")
        XCTAssertEqual(IStatNumberFormat.power(0, locale: us), "0 W")
        XCTAssertEqual(IStatNumberFormat.power(0.85, locale: us), "850 mW")
        XCTAssertEqual(IStatNumberFormat.power(12.46, locale: us), "12.5 W")
        XCTAssertEqual(IStatNumberFormat.power(12, locale: us), "12 W")
        XCTAssertEqual(IStatNumberFormat.power(12.5, space: false, locale: us), "12.5W")
        XCTAssertEqual(IStatNumberFormat.power(-5.25, locale: us), "-5.3 W")
        XCTAssertEqual(IStatNumberFormat.voltage(12.34, locale: us), "12.3 V")
        XCTAssertEqual(IStatNumberFormat.current(0.5, locale: us), "500 mA")
        XCTAssertEqual(IStatNumberFormat.frequency(megahertz: 3_210, locale: us), "3.21 GHz")
        XCTAssertEqual(IStatNumberFormat.frequency(megahertz: 3_200, locale: us), "3.2 GHz")
        XCTAssertEqual(IStatNumberFormat.frequency(megahertz: 4_000, locale: us), "4 GHz")
        XCTAssertEqual(IStatNumberFormat.capacity(milliampHours: 4_382, locale: us), "4,382 mAh")
        XCTAssertEqual(IStatNumberFormat.light(120.4, locale: us), "120 Lux")
    }

    func testGraphTooltipsPrintWholePercentsAndOneLoadDecimal() {
        // `BBRMenu*HistoryGraphSection itemForIndex:`: "%.0f%%" and "%.1f".
        XCTAssertEqual(IStatNumberFormat.graphPercent(12.4), "12%")
        XCTAssertEqual(IStatNumberFormat.graphPercent(12.5), "12%", "printf rounds exact halves to even")
        XCTAssertEqual(IStatNumberFormat.graphPercent(13.5), "14%")
        XCTAssertEqual(IStatNumberFormat.graphPercent(.nan), "--")
        XCTAssertEqual(IStatNumberFormat.graphLoad(2.25), "2.2")
        XCTAssertEqual(IStatNumberFormat.graphLoad(1_234.56), "1234.6", "no grouping")
    }

    /// The charts' unit follows the graph section of each iStat menu; the
    /// benchmark page keeps its tenths (main window, not iStat). These read
    /// the machine's locale, as the panel does.
    @MainActor
    func testChartUnitsUseTheMatchingIStatGraphFormat() {
        XCTAssertEqual(GeekChartUnit.percent.formatted(27.4), "27%")
        XCTAssertEqual(GeekChartUnit.percent.formatted(27.4, compact: true), "27%")
        XCTAssertEqual(GeekChartUnit.percentWithTenths.formatted(27.4), "27.4%")
        XCTAssertEqual(GeekChartUnit.percentWithTenths.formatted(27.4, compact: true), "27%")
        XCTAssertEqual(GeekChartUnit.temperature.formatted(45.5), IStatNumberFormat.temperature(45.5))
        XCTAssertEqual(GeekChartUnit.fanRPM.formatted(1_234), IStatNumberFormat.fanSpeed(1_234))
        XCTAssertEqual(GeekChartUnit.fanRPM.formatted(1_234, compact: true), IStatNumberFormat.number(1_234, decimals: 0))
        XCTAssertEqual(GeekChartUnit.bytes.formatted(8 * 1_073_741_824), IStatNumberFormat.memory(8 * 1_073_741_824))
        XCTAssertEqual(GeekChartUnit.bytes.formatted(-5), IStatNumberFormat.memory(0))
        // A half kilobyte: bandwidth prints "%.0f" (to even), disk activity
        // rounds half up.
        XCTAssertEqual(GeekChartUnit.bytesPerSecond.formatted(512), IStatNumberFormat.bandwidth(512))
        XCTAssertEqual(GeekChartUnit.diskBytesPerSecond.formatted(512), IStatNumberFormat.diskActivity(512))
        XCTAssertNotEqual(GeekChartUnit.bytesPerSecond.formatted(512), GeekChartUnit.diskBytesPerSecond.formatted(512))
        XCTAssertNil(GeekHistoryAxisFooter.rangeText(0...1, unit: .diskBytesPerSecond))
        XCTAssertEqual(GeekHistoryAxisFooter.rangeText(0...100, unit: .percentWithTenths), "0–100%")
    }

    func testLoadAveragesAndFanSpeedsUseIStatNumbers() {
        // BBRCPUMenuLoadSection: `FormatNumber` with two decimals at most.
        let load = SystemLoadAverage(oneMinute: 1.5, fiveMinutes: 2.125, fifteenMinutes: 3)
        XCTAssertEqual(GeekProcessorLoadPresentation.text(load),
                       [1.5, 2.125, 3.0].map { IStatNumberFormat.number($0, decimals: 2) }.joined(separator: " "))
        XCTAssertEqual(IStatNumberFormat.number(2.125, decimals: 2, locale: us), "2.13")
        XCTAssertEqual(IStatNumberFormat.number(3, decimals: 2, locale: us), "3")
        XCTAssertEqual(SystemFanSpeedFormat.string(2_315), IStatNumberFormat.fanSpeed(2_315))
        XCTAssertEqual(SystemFanSpeedFormat.number(-5), IStatNumberFormat.number(0, decimals: 0))
    }
}
