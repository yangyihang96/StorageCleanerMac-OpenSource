import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Render the production components without creating a monitoring Store.
/// Native component checks are independent of the 49-item live visual ledger.
@MainActor
final class MenuBarSecondaryVisualConsistencyTests: XCTestCase {
    func testDiskCapacityDistinguishesUnknownFromActualZeroAndFullUsage() throws {
        let samples: [(StorageCapacitySnapshot?, Int?, Double?)] = [
            (nil, nil, nil),
            (.init(totalBytes: 0, availableBytes: 0), nil, nil),
            (.init(totalBytes: 1_000, availableBytes: 1_000), 0, 0),
            (.init(totalBytes: 1_000, availableBytes: 0), 100, 1),
            (.init(totalBytes: 1_000, availableBytes: 100,
                   availableForImportantUsageBytes: 400), 60, 0.6),
        ]
        for (capacity, percent, ratio) in samples {
            let volume = volume(capacity: capacity)
            XCTAssertEqual(volume.usagePercent, percent)
            XCTAssertEqual(volume.usageProgress, ratio)
            for dark in [false, true] {
                let bitmap = try render(GeekDiskVolumeCapacityRing(volume: volume, tint: .blue).padding(6), dark: dark)
                // D119 (2026-10-18): iStat's 26 pt volume ring with a 2 pt
                // line (was 35 pt, 47 with the padding).
                XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, 38, accuracy: 0.5)
                XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, 38, accuracy: 0.5)
                try assertGlyphsInsideRing(bitmap, size: GeekDiskVolumeLayout.ringSize, padding: 6, dark: dark,
                                           lineWidth: GeekDiskVolumeLayout.ringLineWidth)
                try export(bitmap, name: "capacity-\(percent.map { String($0) } ?? "unknown")-\(dark ? "dark" : "light")")
            }
        }
    }

    // D4 (2026-10-04): the Chinese interface shows Chinese memory terms. Free
    // keeps a legend marker in the ring-track color (the unfilled ring).
    func testMemoryCompositionTermsFollowLanguageAndFreeUsesRingTrackMarker() throws {
        let chinese = SecondaryMenuLanguageScope(.zhHans)
        // D138: iStat's 'Memory.App', 'Memory.Wired', 'Memory.Compressed'
        // (were 应用, 联动, 压缩); the color roles keep their short names.
        XCTAssertEqual(GeekMemoryComponent.allCases.map(\.title), ["App内存", "联动内存", "已压缩", "可用"])
        XCTAssertEqual([PanelMetricColorRole.memoryApp, .memoryWired, .memoryCompressed].map(\.title),
                       ["应用", "联动", "压缩"])
        for component in GeekMemoryComponent.allCases {
            for term in ["App", "Wired", "Compressed", "Free"] {
                XCTAssertFalse(component.explanation.contains(term), "\(component): \(term)")
            }
        }
        chinese.restore()

        let english = SecondaryMenuLanguageScope(.english)
        XCTAssertEqual(GeekMemoryComponent.allCases.map(\.title), ["App", "Wired", "Compressed", "Free"])
        english.restore()

        let colors = PanelMetricColors()
        for (scheme, mode) in [(ColorScheme.dark, MiniWindowVisualMode.black),
                               (.dark, .graphite), (.light, .black)] {
            try assertColor(GeekMemoryComponent.free.legendColor(in: colors, colorScheme: scheme, visualMode: mode),
                            equals: GeekVisualTokens.ringTrack(for: scheme, visualMode: mode))
            for component in GeekMemoryComponent.chartComponents {
                try assertColor(component.legendColor(in: colors, colorScheme: scheme, visualMode: mode),
                                equals: component.color(in: colors))
            }
        }
    }

    func testNativeTransferReadoutPreservesCompleteNumberAndUnitGlyphs() throws {
        // The real secondary panel is 312 pt wide; page/card insets and the
        // existing 12 pt transfer-column gap leave two 134 pt columns.
        let width: CGFloat = 134
        for (input, number, unit) in [
            ("0 B/s", "0", "B/s"), ("99999.9 GiB/s", "99999.9", "GiB/s"),
            ("—", "—", ""), ("--", "—", ""), ("", "—", ""),
        ] {
            for dark in [false, true] {
                let actual = try render(GeekSecondaryTransferReadout(value: input)
                    .foregroundStyle(.primary).frame(width: width), dark: dark)
                let expected = try render((Text(number).font(.system(size: 18, weight: .regular))
                    + Text(unit.isEmpty ? "" : " " + unit).font(.system(size: 12, weight: .regular)))
                    .monospacedDigit().foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true).frame(width: width), dark: dark)
                XCTAssertEqual(actual.pixelsWide, expected.pixelsWide)
                XCTAssertEqual(actual.pixelsHigh, expected.pixelsHigh)
                XCTAssertTrue(textMask(actual, dark: dark).elementsEqual(textMask(expected, dark: dark)),
                    "The entire number/unit must match untruncated native text: \(input)")
            }
        }
    }

    func testDiskIOCardAllocatesReferencePlotAndKeepsPeakRowVisible() throws {
        // Inject only a solid chart probe into the production card's real slot.
        // This proves native slot bounds without starting a chart timeline or
        // Store; it does not claim a 49-item live pixel-fidelity acceptance.
        let probe = Color(red: 0.17, green: 0.77, blue: 0.23)
        for language in [AppLanguage.english, .zhHans] {
            let languageScope = SecondaryMenuLanguageScope(language)
            defer { languageScope.restore() }
            for dark in [false, true] {
                let card = GeekDiskIOCard {
                    // D138: the production titles, iStat's 'Disks.Read' and
                    // 'Disks.Write' (were 读取, 写入).
                    GeekSecondaryTransferValue(title: L10n.text("读", "Read"),
                        value: "99999.9 GiB/s", tint: .pink)
                } write: {
                    GeekSecondaryTransferValue(title: L10n.text("写", "Write"),
                        value: "0 B/s", tint: .blue)
                } chart: {
                    probe
                } peak: { _ in
                    // D146: the slot is handed the graph's peaks (was `peak: {`).
                    GeekDiskPeakRow(readPeak: "1023.9 TiB/s", writePeak: "8.0 EiB/s")
                }
                .frame(width: 296)
                let bitmap = try render(card, dark: dark)
                try export(bitmap, name: "disk-io-card-\(language.rawValue)-\(dark ? "dark" : "light")")
                // D119 (2026-10-18): iStat's activity section is 130 tall:
                // the plot from 47, H − 74 = 56 tall, x 8 and W − 14 wide, the
                // peak row at H − 21 (was 180 with the plot at 45, 280 × 110,
                // the last text above 174).
                XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, 296, accuracy: 0.5)
                XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, 130, accuracy: 0.5)
                // NSBitmapImageRep(cgImage:) and the exported PNG can resolve
                // color components differently. Obtain the native expected
                // pigment through the same renderer/conversion as the card;
                // geometry and the existing 0.02 component tolerance stay fixed.
                let probeBitmap = try render(probe.frame(width: 1, height: 1), dark: dark)
                let nativeProbe = try XCTUnwrap(probeBitmap.colorAt(x: 0, y: 0))
                let expectedProbe = try XCTUnwrap(nativeProbe.usingColorSpace(.sRGB))
                let chartCenter = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 150))
                let resolvedChartCenter = try XCTUnwrap(chartCenter.usingColorSpace(.sRGB))
                print("Disk IO native color spaces: card=\(bitmap.colorSpace), probe=\(probeBitmap.colorSpace); center=\(chartCenter), sRGB=\(resolvedChartCenter); reference=\(nativeProbe), sRGB=\(expectedProbe)")
                let chart = try colorBounds(bitmap, red: expectedProbe.redComponent,
                    green: expectedProbe.greenComponent, blue: expectedProbe.blueComponent)
                XCTAssertEqual(chart.minX / 2, 8, accuracy: 0.5)
                XCTAssertEqual(chart.minY / 2, 47, accuracy: 0.5)
                XCTAssertEqual(chart.width / 2, 282, accuracy: 0.5)
                XCTAssertEqual(chart.height / 2, 56, accuracy: 0.5)
                let peak = try lastTextLineBounds(bitmap, dark: dark)
                XCTAssertGreaterThanOrEqual(peak.minY / 2, chart.maxY / 2 + 3 - 0.5,
                    "Peak values must occupy their separate readable row below the plot")
                XCTAssertLessThanOrEqual(peak.maxY / 2, 124 + 0.5,
                    "The complete last peak row must remain above the six-point bottom inset")
                let glyphs = try textBounds(bitmap, dark: dark)
                XCTAssertGreaterThanOrEqual(glyphs.minY / 2, 6 - 0.5)
                XCTAssertLessThanOrEqual(glyphs.maxY / 2, 124 + 0.5)
            }
        }
    }

    func testLiveDiskPeakPreparationShowsUnknownUntilItsWorkerDelivers() throws {
        let point = NativeDiskIOPoint(date: Date(timeIntervalSince1970: 864_000),
            readBytesPerSecond: 123_456, writeBytesPerSecond: 456_789,
            readOperationsPerSecond: 0, writeOperationsPerSecond: 0)
        let context = MenuBarChartContext(page: "fixture-unstarted-\(UUID())",
            revision: .init(sampledAt: point.date, version: 1))
        for dark in [false, true] {
            // ImageRenderer draws the initial live-context tree without a
            // window/Store. First content is explicit unknown, not blank/zero.
            // D146: the row shows the peaks of the card's graph, which has no
            // frame before its worker delivers (was the row's own summary,
            // `GeekPreparedDiskPeakRow(points: [point], duration: 3_600)` at
            // 280 × 16 against `GeekDiskPeakRow` at 280 × 16).
            let initial = try render(GeekDiskIOCard { EmptyView() } write: { EmptyView() } chart: {
                GeekDiskIOChart(points: [point], accessibilityLabel: "", duration: 3_600,
                                showsLegend: false, showsTimelineLabels: false, bucketing: .samples)
            } peak: { GeekDiskPeakRow(peaks: $0) }
                .environment(\.miniWindowPreviewDate, point.date)
                .environment(\.menuBarChartContext, context)
                .frame(width: 280), dark: dark)
            let expected = try render(GeekDiskIOCard { EmptyView() } write: { EmptyView() } chart: { Color.clear }
                peak: { _ in GeekDiskPeakRow(readPeak: "--", writePeak: "--") }
                .frame(width: 280), dark: dark)
            XCTAssertEqual(initial.pixelsWide, expected.pixelsWide)
            XCTAssertEqual(initial.pixelsHigh, expected.pixelsHigh)
            XCTAssertTrue(textMask(initial, dark: dark).elementsEqual(textMask(expected, dark: dark)))
            XCTAssertFalse(textMask(initial, dark: dark).allSatisfy { !$0 })
        }
    }

    func testDiskIOSelectionRequiresCurrentDiskHistoryIdentityAndMetric() {
        let id = UUID(), obsolete = UUID()
        let selected = GeekPanelRoute.history(module: .disk, selection: .inline(id))
        XCTAssertTrue(GeekDiskIOCardSelection.isSelected(route: selected, requestID: id, metric: .disk))
        XCTAssertFalse(GeekDiskIOCardSelection.isSelected(route: selected, requestID: obsolete, metric: .disk))
        XCTAssertFalse(GeekDiskIOCardSelection.isSelected(route: selected, requestID: nil, metric: .disk))
        XCTAssertFalse(GeekDiskIOCardSelection.isSelected(route: selected, requestID: id, metric: nil),
            "A volume inspector has no disk-chart metric and must not select the I/O card")
        XCTAssertFalse(GeekDiskIOCardSelection.isSelected(route: selected, requestID: id, metric: .network))
        XCTAssertFalse(GeekDiskIOCardSelection.isSelected(
            route: .history(module: .network, selection: .inline(id)), requestID: id, metric: .disk))
        XCTAssertFalse(GeekDiskIOCardSelection.isSelected(
            route: .history(module: .disk, selection: .builtIn("fixture")), requestID: id, metric: .disk))
        XCTAssertFalse(GeekDiskIOCardSelection.isSelected(route: .module(.disk), requestID: id, metric: .disk))
        XCTAssertFalse(GeekDiskIOCardSelection.isSelected(route: .summary, requestID: id, metric: .disk))
    }

    func testSelectedDiskCardHasOnlyOneOuterNativeBorderWithoutChangingSlots() throws {
        let accent = Color(red: 0.17, green: 0.77, blue: 0.23)
        for dark in [false, true] {
            let palette = PanelChromePalette(shell: dark ? .black : .white,
                card: dark ? .black : .white, border: .gray,
                text: dark ? .white : .black, secondaryText: .gray, tertiaryText: .gray,
                selection: dark ? .black : .white, accent: accent, controlScheme: dark ? .dark : .light)
            let card = GeekDiskIOCard {
                GeekSecondaryTransferValue(title: "Read", value: "0 B/s", tint: .pink)
            } write: {
                GeekSecondaryTransferValue(title: "Write", value: "99999.9 GiB/s", tint: .blue)
            } chart: { Color.clear } peak: { _ in
                // D146: the slot is handed the graph's peaks (was `peak: {`).
                GeekDiskPeakRow(readPeak: "1023.9 TiB/s", writePeak: "8.0 EiB/s")
            }
            .environment(\.geekCombinedCardIsSelected, true)
            .environment(\.panelChromePalette, palette)
            .frame(width: 296)
            let bitmap = try render(card, dark: dark)
            // D119 (2026-10-18): iStat's 130 pt activity section (was 180).
            XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, 296, accuracy: 0.5)
            XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, 130, accuracy: 0.5)
            let pigment = try render(accent.frame(width: 1, height: 1), dark: dark)
            let color = try XCTUnwrap(pigment.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
            let border = try colorBounds(bitmap, red: color.redComponent,
                green: color.greenComponent, blue: color.blueComponent)
            XCTAssertEqual(border.minX, 0, accuracy: 1)
            XCTAssertEqual(border.minY, 0, accuracy: 1)
            XCTAssertEqual(border.maxX, CGFloat(bitmap.pixelsWide), accuracy: 1)
            XCTAssertEqual(border.maxY, CGFloat(bitmap.pixelsHigh), accuracy: 1)
            for y in 16..<(bitmap.pixelsHigh - 16) {
                for x in 16..<(bitmap.pixelsWide - 16) {
                    guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    XCTAssertFalse(abs(pixel.redComponent - color.redComponent) < 0.02
                        && abs(pixel.greenComponent - color.greenComponent) < 0.02
                        && abs(pixel.blueComponent - color.blueComponent) < 0.02,
                        "Selected pigment must stay on the outer shell, not an inner readout/plot rectangle")
                }
            }
            let peak = try lastTextLineBounds(bitmap, dark: dark)
            XCTAssertLessThanOrEqual(peak.maxY / 2, 124 + 0.5)
            try export(bitmap, name: "disk-selected-outer-card-\(dark ? "dark" : "light")")
        }
    }

    func testDiskHeadingOverrideDoesNotReplaceVolumeCapacityRiskOrTransferPigments() throws {
        let colors = PanelMetricColors(sectionHeader: "#22AA77", diskRead: "#DD3377", diskWrite: "#3366CC")
        try assertColor(colors.sectionHeader, equals: Color(red: 0x22 / 255.0, green: 0xAA / 255.0, blue: 0x77 / 255.0))
        try assertColor(colors.diskRead, equals: Color(red: 0xDD / 255.0, green: 0x33 / 255.0, blue: 0x77 / 255.0))
        try assertColor(colors.diskWrite, equals: Color(red: 0x33 / 255.0, green: 0x66 / 255.0, blue: 0xCC / 255.0))
        for (available, pressure, expected) in [
            (Int64(500), StorageCapacityPressure.normal, colors.diskWrite),
            (Int64(150), .attention, Color.orange),
            (Int64(50), .critical, Color.red),
        ] {
            let snapshot = StorageCapacitySnapshot(totalBytes: 1_000, availableBytes: available)
            XCTAssertEqual(snapshot.pressure, pressure)
            try assertColor(GeekDiskVolumeColors.capacityTint(volume: volume(capacity: snapshot), metricColors: colors),
                            equals: expected)
        }
        try assertColor(GeekDiskVolumeColors.capacityTint(volume: volume(capacity: nil), metricColors: colors),
                        equals: .secondary)
        try assertColor(PanelMetricColors(sectionHeader: "invalid", diskWrite: "#3366CC").sectionHeader,
                        equals: PanelMetricColorRole.sectionHeader.defaultColor)
    }

    func testNativeProcessRowsAndCardsKeepLastRowWithinTheirBudget() throws {
        for rowCount in [1, 2, 4, 5] {
            for disk in [false, true] {
                let rows = (0..<rowCount).map { index -> AnyView in
                    if disk { return AnyView(GeekDiskProcessRow(app: application(index: index))) }
                    return AnyView(GeekNetworkProcessRow(process: .init(processIdentifier: Int32(index + 1),
                        name: "Long running process \(index)", iconPath: "",
                        downloadBytesPerSecond: Int64.max, uploadBytesPerSecond: 1_024)))
                }
                // D119 (2026-10-18): the pages' iStat process section, the
                // title row at 5 and the rows from 22 on the 17 pt pitch,
                // 25 + 17n tall (was a 6 pt padded card of 16 pt rows 4 pt
                // apart, 12 + 20 + 16n + 4(n − 1)).
                let content = GeekIStatProcessCard(title: "PROCESSES", rowCapacity: rowCount) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in row }
                }.frame(width: 296)
                let bitmap = try render(content, dark: true)
                let expectedHeight: CGFloat = 25 + 17 * CGFloat(rowCount)
                XCTAssertEqual(GeekSecondaryTransferLayout.processCardHeight(rowCount: rowCount), expectedHeight)
                XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, 296, accuracy: 0.5)
                XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, expectedHeight, accuracy: 0.5)
                let bounds = try textBounds(bitmap, dark: true)
                XCTAssertLessThanOrEqual(bounds.maxY / 2, expectedHeight - 6,
                    "The last row must remain above the bottom card inset")
                XCTAssertGreaterThanOrEqual(bounds.minY / 2, 6)
                try export(bitmap, name: "\(disk ? "disk" : "network")-processes-\(rowCount)")
            }
        }
        // Check the production readout-column budget against complete native glyphs,
        // independently of the process name's intentional one-line truncation.
        // D128 (2026-10-19): the columns show iStat's short process rates,
        // which stop at G (network "12 K", disk "12K", "-" under 1 KB/s), with
        // 9 pt units (was processByteString's KiB…TiB then PiB/EiB: "8.0 EiB",
        // "1.0 PiB", "1024.0 TiB", "1023.9 TiB", ByteFormat.string(1_024),
        // with a 10 pt unit always after a space).
        let columnWidth = GeekSecondaryTransferLayout.processValueColumnWidth
        let us = Locale(identifier: "en_US")
        let widestGigabytes = 999.9 * 1_073_741_824
        XCTAssertEqual(IStatNumberFormat.bandwidth(1_024, style: .process, locale: us), "1 K")
        XCTAssertEqual(IStatNumberFormat.diskActivity(1_024, style: .process, locale: us), "1K")
        XCTAssertEqual(IStatNumberFormat.diskActivity(512, style: .process, locale: us), "-")
        XCTAssertEqual(IStatNumberFormat.bandwidth(999_999_999, style: .process, locale: us), "954 M")
        XCTAssertEqual(IStatNumberFormat.bandwidth(widestGigabytes, style: .process, locale: us), "999.9 G")
        XCTAssertEqual(IStatNumberFormat.diskActivity(999_999, style: .process, locale: us), "977K")
        XCTAssertEqual(IStatNumberFormat.diskActivity(widestGigabytes, style: .process, locale: us), "999.9G")
        XCTAssertEqual(GeekSecondaryTransferLayout.processUnitFontSize, 9)
        for value in [IStatNumberFormat.bandwidth(widestGigabytes, style: .process, locale: us),
                      IStatNumberFormat.bandwidth(999_999_999, style: .process, locale: us),
                      IStatNumberFormat.diskActivity(widestGigabytes, style: .process, locale: us),
                      IStatNumberFormat.diskActivity(999_999, style: .process, locale: us),
                      "-", "—"] {
            let parts = GeekCombinedRing.splitReadout(value)
            let gap = parts.map { value.dropFirst($0.number.count).first == " " ? " " : "" } ?? ""
            // D119 (2026-10-18): the production 12 pt values with the 10 pt
            // unit in the 64 pt column (was 11 pt in 60). D128: 9 pt unit.
            XCTAssertEqual(GeekSecondaryTransferLayout.processNumberFontSize, 12)
            XCTAssertEqual(columnWidth, 64)
            let actual = try render(GeekSecondaryTransferReadout(value: value,
                numberFontSize: GeekSecondaryTransferLayout.processNumberFontSize,
                unitFontSize: GeekSecondaryTransferLayout.processUnitFontSize,
                minimumScale: GeekSecondaryTransferLayout.processMinimumScale)
                .foregroundStyle(.primary).frame(width: columnWidth, height: 16, alignment: .trailing), dark: true)
            let expected = try render((Text(parts?.number ?? value).font(.system(size: 12, weight: .regular))
                + Text(parts.map { gap + $0.unit } ?? "").font(.system(size: 9, weight: .regular)))
                .monospacedDigit().foregroundStyle(.primary).fixedSize()
                .frame(width: columnWidth, height: 16, alignment: .trailing), dark: true)
            XCTAssertTrue(textMask(actual, dark: true).elementsEqual(textMask(expected, dark: true)),
                "Native process columns must retain the complete value and unit: \(value)")
        }
    }

    func testSensorSummaryKeepsThreeRealReadoutShapesInsideCalibratedCard() throws {
        // D119 (2026-10-18): the sensors page draws the overview card's iStat
        // rings, 72 pt with a 2 pt line in 87 pt cells on an 88 pt card of
        // the 301 pt page (was 62 pt rings 24 pt apart on a 74 pt card).
        XCTAssertEqual(GeekSensorSummaryLayout.ringSize, 72)
        XCTAssertEqual(GeekSensorSummaryLayout.cardHeight, 88)
        let ringSize = GeekSensorSummaryLayout.ringSize
        let fans = fanTelemetry(rpm: 12_345, count: 2)
        let fanCaption = GeekSensorFanRingPresentation(telemetry: fans).caption
        for dark in [false, true] {
            let card = GeekIStatCard(height: GeekSensorSummaryLayout.cardHeight) {
                GeekIStatSensorCells {
                    sensorRing(title: "CPU", value: "100°C", detail: nil).frame(width: ringSize, height: ringSize)
                    sensorRing(title: "GPU", value: "—", detail: "Unavailable").frame(width: ringSize, height: ringSize)
                    GeekSensorFanRing(telemetry: fans, tint: .blue).frame(width: ringSize, height: ringSize)
                }
                .geekIStatLayer(top: (GeekSensorSummaryLayout.cardHeight - ringSize) / 2, height: ringSize,
                                leading: 0, trailing: 0)
            }.frame(width: 301)
            let bitmap = try render(card, dark: dark)
            XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, 301, accuracy: 0.5)
            XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, 88, accuracy: 0.5)
            try export(bitmap, name: "sensors-summary-\(dark ? "dark" : "light")")
            for (title, value, detail) in [
                ("CPU", "100°C", Optional<String>.none), ("GPU", "—", Optional("Unavailable")),
                ("FANS", "12,345", Optional(fanCaption)), ("风扇", "—", Optional("检测中")),
            ] {
                let ring = try render(sensorRing(title: title, value: value, detail: detail).padding(6), dark: dark)
                try assertGlyphsInsideRing(ring, size: ringSize, padding: 6, dark: dark,
                                           lineWidth: GeekIStatCardGeometry.sensorRingLineWidth)
            }
        }
    }

    func testFanCaptionKeepsCompleteUnitsAndRealStateMeaningInBothLanguages() throws {
        // D119: the fan ring is the overview's iStat ring, its caption the
        // 11 pt Thin detail line inside the 2 pt line (was 8.5 pt regular).
        let size = GeekSensorSummaryLayout.ringSize
        let lineWidth = GeekIStatCardGeometry.sensorRingLineWidth
        let captionFont = GeekIStatCardGeometry.sensorDetailFontSize
        let side = GeekCombinedRing.contentDiameter(size: size, lineWidth: lineWidth) / sqrt(2)
        for language in [AppLanguage.english, .zhHans] {
            let languageScope = SecondaryMenuLanguageScope(language)
            defer { languageScope.restore() }
            let samples: [(String, FanTelemetryState, String)] = [
                ("zero", fanTelemetry(rpm: 0, count: 1), "rpm"),
                ("single", fanTelemetry(rpm: 12_345, count: 1), "rpm"),
                ("average", fanTelemetry(rpm: 12_345, count: 2), "rpm"),
                ("reading", fanTelemetry(rpm: nil, count: 0, sampling: true), language == .english ? "Reading" : "检测中"),
                ("passive", fanTelemetry(rpm: nil, count: 0, fanless: true), language == .english ? "Passive" : "被动散热"),
                ("unavailable", fanTelemetry(rpm: nil, count: 0), language == .english ? "N/A" : "不可用"),
            ]
            for (name, telemetry, caption) in samples {
                let presentation = GeekSensorFanRingPresentation(telemetry: telemetry)
                XCTAssertEqual(presentation.caption, caption)
                XCTAssertFalse(presentation.caption.contains("…"))
                XCTAssertLessThanOrEqual((caption as NSString).size(withAttributes:
                    [.font: NSFont.systemFont(ofSize: captionFont, weight: .thin)]).width, side + 0.5,
                    "The complete caption must fit at its original readable font size")
                XCTAssertTrue(presentation.helpText.contains(presentation.accessibilityValue))
                XCTAssertTrue(presentation.helpText.contains(language == .english ? "System fan telemetry" : "系统风扇读数"))
                if let rpm = telemetry.actualRPM {
                    XCTAssertEqual(presentation.value, SystemFanSpeedFormat.number(rpm))
                    XCTAssertTrue(presentation.accessibilityValue.contains("rpm"))
                    XCTAssertTrue(presentation.accessibilityValue.contains(telemetry.fanCount > 1
                        ? (language == .english ? "Average speed across 2 fans" : "2 个风扇的平均转速")
                        : (language == .english ? "Actual fan speed" : "风扇实际转速")))
                } else {
                    XCTAssertEqual(presentation.value, telemetry.isFanless ? (language == .english ? "None" : "无") : "—")
                    XCTAssertNil(telemetry.percentage)
                    let explanation = name == "reading" ? (language == .english ? "Checking fans" : "正在检测风扇")
                        : name == "passive" ? (language == .english ? "passive cooling" : "被动散热")
                        : (language == .english ? "No valid system fan RPM reading" : "尚无有效的系统风扇转速读数")
                    XCTAssertTrue(presentation.accessibilityValue.contains(explanation))
                }
                for dark in [false, true] {
                    let actual = try render(GeekSensorFanRing(telemetry: telemetry, tint: .blue).padding(6), dark: dark)
                    let reference = try render(Text(caption).font(.system(size: captionFont, weight: .thin))
                        .foregroundStyle(.primary.opacity(0.77)).monospacedDigit()
                        .allowsTightening(true).fixedSize().padding(6), dark: dark)
                    // Preserve the native bitmaps even if a visibility or
                    // complete-glyph assertion fails in a later run.
                    try export(actual, name: "fan-caption-\(language.rawValue)-\(name)-\(dark ? "dark" : "light")")
                    try export(reference, name: "fan-caption-reference-\(language.rawValue)-\(name)-\(dark ? "dark" : "light")")
                    print("Fan caption native fixture: \(language.rawValue) \(name) \(dark ? "dark" : "light"), primary(actual/reference)=\(textMask(actual, dark: dark).filter { $0 }.count)/\(textMask(reference, dark: dark).filter { $0 }.count), caption(actual/reference)=\(captionTextMask(actual, dark: dark).filter { $0 }.count)/\(captionTextMask(reference, dark: dark).filter { $0 }.count)")
                    try assertGlyphsInsideRing(actual, size: size, padding: 6, dark: dark, lineWidth: lineWidth)
                    let actualCaption = try lastTextLineBounds(actual, dark: dark)
                    let completeCaption = try captionTextBounds(reference, dark: dark)
                    let inset = 6 + (size - side) / 2
                    XCTAssertGreaterThanOrEqual(actualCaption.minX / 2, inset - 0.5)
                    XCTAssertGreaterThanOrEqual(actualCaption.minY / 2, inset - 0.5)
                    XCTAssertLessThanOrEqual(actualCaption.maxX / 2, inset + side + 0.5)
                    XCTAssertLessThanOrEqual(actualCaption.maxY / 2, inset + side + 0.5)
                    // One physical pixel is the existing half-point glyph
                    // tolerance at 2x; do not accept a narrower ellipsis row.
                    XCTAssertEqual(actualCaption.width, completeCaption.width, accuracy: 1,
                        "Full native caption width: \(language.rawValue) \(name) \(caption)")
                    XCTAssertEqual(actualCaption.height, completeCaption.height, accuracy: 1,
                        "Full native caption height: \(language.rawValue) \(name) \(caption)")
                }
            }
        }
    }

    private func fanTelemetry(rpm: Int?, count: Int, sampling: Bool = false, fanless: Bool = false) -> FanTelemetryState {
        let readings = rpm.map { speed in (0..<count).map { index in
            SystemFanReading(index: index, actualRPM: speed, minimumRPM: 0,
                             maximumRPM: 13_000, targetRPM: nil)
        } } ?? []
        return FanTelemetryState(actualRPM: rpm, minRPM: rpm == nil ? nil : 0,
            maxRPM: rpm == nil ? nil : 13_000, targetRPM: nil, fanCount: count,
            timestamp: Date(timeIntervalSince1970: 1_000), telemetryAvailable: rpm != nil,
            isSampling: sampling, isFanless: fanless, readings: readings)
    }

    /// D119: the production sensors-page ring (the overview card's).
    private func sensorRing(title: String, value: String, detail: String?) -> some View {
        GeekIStatSensorRing(title: title, value: value, detail: detail, progress: value == "—" ? nil : 1,
            tint: .blue)
    }

    private func volume(capacity: StorageCapacitySnapshot?) -> GeekDiskVolumePresentation {
        .init(id: "fixture", name: "Fixture volume", capacity: capacity, healthText: "—",
              smartStatus: .unavailable, temperature: nil, isNetwork: false)
    }

    private func application(index: Int) -> EnergyImpactApp {
        .init(id: "fixture-\(index)", name: "Long running process \(index)", path: "", iconPath: "",
            bundlePath: nil, bundleIdentifier: nil, measuredEnergyWh: 0, estimatedSupplementEnergyWh: 0,
            estimatedEnergyWh: 0, currentPowerWatts: 0, averagePowerWatts: 0, cpuPercent: 0,
            diskReadBytesPerSecond: Int64.max, diskWriteBytesPerSecond: 1_024, residentBytes: 0,
            cumulativeCPUSeconds: 0, longestRunningSeconds: nil, processCount: 1,
            measuredProcessCount: 0, processIDs: [], isApplication: true)
    }

    private func render<Content: View>(_ content: Content, dark: Bool) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.miniWindowVisualMode, .black).environment(\.displayScale, 2)
            .background(dark ? Color.black : Color.white))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func textMask(_ bitmap: NSBitmapImageRep, dark: Bool) -> [Bool] {
        (0..<bitmap.pixelsHigh).flatMap { y in (0..<bitmap.pixelsWide).map { x in
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.8 else { return false }
            let components = [color.redComponent, color.greenComponent, color.blueComponent]
            guard let minimum = components.min(), let maximum = components.max(), maximum - minimum < 0.05 else { return false }
            return dark ? minimum > 0.7 : maximum < 0.4
        } }
    }

    private func colorBounds(_ bitmap: NSBitmapImageRep, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGRect {
        var points: [CGPoint] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.98,
                      abs(color.redComponent - red) < 0.02,
                      abs(color.greenComponent - green) < 0.02,
                      abs(color.blueComponent - blue) < 0.02 else { continue }
                points.append(CGPoint(x: x, y: y))
            }
        }
        let minX = try XCTUnwrap(points.map(\.x).min()), maxX = try XCTUnwrap(points.map(\.x).max())
        let minY = try XCTUnwrap(points.map(\.y).min()), maxY = try XCTUnwrap(points.map(\.y).max())
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func assertColor(_ actual: Color, equals expected: Color, file: StaticString = #filePath, line: UInt = #line) throws {
        let actualRGB = try XCTUnwrap(NSColor(actual).usingColorSpace(.sRGB), file: file, line: line)
        let expectedRGB = try XCTUnwrap(NSColor(expected).usingColorSpace(.sRGB), file: file, line: line)
        XCTAssertEqual(actualRGB.redComponent, expectedRGB.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualRGB.greenComponent, expectedRGB.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualRGB.blueComponent, expectedRGB.blueComponent, accuracy: 0.001, file: file, line: line)
    }

    private func textBounds(_ bitmap: NSBitmapImageRep, dark: Bool) throws -> CGRect {
        let mask = textMask(bitmap, dark: dark)
        let indices = mask.indices.filter { mask[$0] }
        XCTAssertFalse(indices.isEmpty, "Native primary text must be visible")
        let minX = try XCTUnwrap(indices.map { $0 % bitmap.pixelsWide }.min())
        let maxX = try XCTUnwrap(indices.map { $0 % bitmap.pixelsWide }.max())
        let minY = try XCTUnwrap(indices.map { $0 / bitmap.pixelsWide }.min())
        let maxY = try XCTUnwrap(indices.map { $0 / bitmap.pixelsWide }.max())
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }

    // Caption text uses .primary.opacity(0.77), whose resolved dark
    // foreground is below the primary-value mask's 0.7 cutoff (r6: 172/255).
    // Use the same neutral contrast discriminator as CompactGaugeRenderingTests
    // for this semantic foreground; geometric/font/glyph tolerances stay fixed.
    private func captionTextMask(_ bitmap: NSBitmapImageRep, dark: Bool) -> [Bool] {
        (0..<bitmap.pixelsHigh).flatMap { y in (0..<bitmap.pixelsWide).map { x in
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.8 else { return false }
            let components = [color.redComponent, color.greenComponent, color.blueComponent]
            guard let minimum = components.min(), let maximum = components.max(), maximum - minimum < 0.05 else { return false }
            return dark ? minimum > 0.5 : maximum < 0.5
        } }
    }

    private func captionTextBounds(_ bitmap: NSBitmapImageRep, dark: Bool) throws -> CGRect {
        let mask = captionTextMask(bitmap, dark: dark)
        let indices = mask.indices.filter { mask[$0] }
        XCTAssertFalse(indices.isEmpty, "Native caption's resolved foreground must be visible")
        let minX = try XCTUnwrap(indices.map { $0 % bitmap.pixelsWide }.min())
        let maxX = try XCTUnwrap(indices.map { $0 % bitmap.pixelsWide }.max())
        let minY = try XCTUnwrap(indices.map { $0 / bitmap.pixelsWide }.min())
        let maxY = try XCTUnwrap(indices.map { $0 / bitmap.pixelsWide }.max())
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }

    private func lastTextLineBounds(_ bitmap: NSBitmapImageRep, dark: Bool) throws -> CGRect {
        let mask = captionTextMask(bitmap, dark: dark)
        func hasText(_ y: Int) -> Bool {
            mask[(y * bitmap.pixelsWide)..<((y + 1) * bitmap.pixelsWide)].contains(true)
        }
        let lastY = try XCTUnwrap((0..<bitmap.pixelsHigh).last(where: hasText))
        // A slash's anti-aliased foot can be separated from its main glyph
        // by one empty physical row. Collect the complete final caption line,
        // including that row, rather than treating the foot as a new line.
        // Two empty rows delimit this caption ROI from the value/title above;
        // this changes no pixel classification or glyph-size tolerance.
        var firstY = lastY
        var emptyRows = 0
        for y in stride(from: lastY - 1, through: 0, by: -1) {
            if hasText(y) {
                firstY = y
                emptyRows = 0
            } else {
                emptyRows += 1
                if emptyRows == 2 { break }
            }
        }
        let columns = (0..<bitmap.pixelsWide).filter { x in
            (firstY...lastY).contains { y in mask[y * bitmap.pixelsWide + x] }
        }
        let minX = try XCTUnwrap(columns.min()), maxX = try XCTUnwrap(columns.max())
        return CGRect(x: CGFloat(minX), y: CGFloat(firstY),
                      width: CGFloat(maxX - minX + 1), height: CGFloat(lastY - firstY + 1))
    }

    private func assertGlyphsInsideRing(_ bitmap: NSBitmapImageRep, size: CGFloat, padding: CGFloat, dark: Bool,
                                        lineWidth: CGFloat? = nil) throws {
        let side = GeekCombinedRing.contentDiameter(size: size,
            lineWidth: lineWidth ?? GeekVisualTokens.gaugeStrokeWidth(size: size)) / sqrt(2)
        let inset = padding + (size - side) / 2
        let bounds = try textBounds(bitmap, dark: dark)
        XCTAssertGreaterThanOrEqual(bounds.minX / 2, inset - 0.5)
        XCTAssertGreaterThanOrEqual(bounds.minY / 2, inset - 0.5)
        XCTAssertLessThanOrEqual(bounds.maxX / 2, inset + side + 0.5)
        XCTAssertLessThanOrEqual(bounds.maxY / 2, inset + side + 0.5)
    }

    private func export(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_SECONDARY_MENU_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
    }
}

@MainActor
private final class SecondaryMenuLanguageScope {
    private let original: [String: Any]
    init(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var temporary = original
        temporary[L10n.languageDefaultsKey] = language.rawValue
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(L10n.appLanguage, language)
    }
    func restore() {
        UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }
}
