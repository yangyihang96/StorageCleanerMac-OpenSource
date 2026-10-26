#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class CompactGaugeRenderingTests: XCTestCase {
    func testProcessorCardRendersCalibratedGeometryWithReadoutAtTrailingInset() throws {
        // D118 (iStat `cpu-cpu`): 120 pt card, graph from 25 to H − 24
        // (was 106 / 60). User 2026-10-11 (c) still holds: the CPU plot
        // sits directly under its header, as in iStat.
        XCTAssertEqual(GeekPanelLayout.overviewProcessorCardHeight, 120)
        XCTAssertEqual(GeekPanelLayout.overviewProcessorChartHeight, 71)
        XCTAssertEqual(GeekIStatCardGeometry.processorGraphTop,
                       GeekIStatCardGeometry.titleTop + GeekIStatCardGeometry.titleHeight + 5)
        let width = MiniWindowStyleTokens.overviewSize.width - 2 * MiniWindowStyleTokens.contentInset
        let scale: CGFloat = 2
        let sampleDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let clock = PanelChartClock(anchor: .init(wallDate: sampleDate, instant: ContinuousClock().now))
        // Batch 2b review (P2 #4): the readout is not in the title's
        // section-header color. D118: it is in the value color (iStat), so
        // its pixels are the neutral ones that contrast with the card. D43:
        // the readout is the frequency and the temperature (was the total,
        // which now only the legend expresses), whatever the total is.
        for dark in [false, true] {
            for total: Double? in [0, 100, nil] {
                let point = MenuBarTelemetryPoint(
                    date: sampleDate, cpuTotal: total, cpuUser: total.map { $0 * 0.6 },
                    cpuSystem: total.map { $0 * 0.4 }, gpu: nil, memory: nil,
                    chipTemperature: nil, fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: nil
                )
                let view = GeekProcessorPresentation(
                    cpuChartHistory: [point], cpuChartRange: .oneMinute, samplingInterval: 1,
                    processorTint: .orange, geekCPUUserBarColor: .blue, geekCPUSystemBarColor: .pink,
                    headerFrequencyText: "4.43 GHz", headerTemperatureText: "80°C"
                )
                .frame(width: width)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.miniWindowVisualMode, .black)
                .environment(\.panelChartClock, clock)
                .environment(\.displayScale, scale)
                let renderer = ImageRenderer(content: view)
                renderer.scale = scale
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                XCTAssertEqual(CGFloat(bitmap.pixelsWide) / scale, width, accuracy: 0.5)
                XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / scale,
                               GeekPanelLayout.overviewProcessorCardHeight, accuracy: 0.5)
                let headerBounds = try readoutHeaderBounds(in: bitmap, scale: scale, dark: dark)
                XCTAssertEqual(headerBounds.maxX, width - GeekIStatCardGeometry.inset,
                               accuracy: 2, "The current readout must end at the card inset, including 0%, 100% and unknown")
                if let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_MENU_CALIBRATION_EVIDENCE"] {
                    let directory = URL(fileURLWithPath: path, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let name = "cpu-\(dark ? "dark" : "light")-\(total.map { String(Int($0)) } ?? "unknown").png"
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: directory.appendingPathComponent(name))
                }
            }
        }
    }

    private func readoutHeaderBounds(in bitmap: NSBitmapImageRep, scale: CGFloat, dark: Bool) throws -> CGRect {
        var minimumX = bitmap.pixelsWide
        var maximumX = -1
        // Only the header row is inspected: the CPU title uses the
        // section-header color, the readout the neutral value color.
        // Exclude the graph and legend.
        let headerBottom = Int((GeekIStatCardGeometry.titleTop + GeekIStatCardGeometry.titleHeight) * scale)
        for y in 0..<min(bitmap.pixelsHigh, headerBottom) {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                let neutral = (channels.max() ?? 0) - (channels.min() ?? 0) < 0.1
                let brightness = channels.reduce(0, +) / 3
                let isValueColor = neutral && (dark ? brightness > 0.75 : brightness < 0.3)
                guard color.alphaComponent > 0.8, isValueColor else { continue }
                minimumX = min(minimumX, x)
                maximumX = max(maximumX, x)
            }
        }
        XCTAssertGreaterThanOrEqual(maximumX, minimumX, "The value-colored header readout must be visible")
        return CGRect(x: CGFloat(minimumX) / scale, y: 0,
                      width: CGFloat(maximumX - minimumX + 1) / scale, height: CGFloat(headerBottom) / scale)
    }

    func testNativePressureLabelsRenderCompleteLinesAtOverviewAndDetailSizes() throws {
        for size: CGFloat in [88, 112] {
            let side = GeekCombinedRing.contentDiameter(
                size: size, lineWidth: GeekVisualTokens.gaugeStrokeWidth(size: size)
            ) / sqrt(2)
            let fontSize: CGFloat = size == 88 ? 10 : 11
            for (title, completeText, lineCount) in [
                ("Pressure estimate", "PRESSURE\nESTIMATE", 2),
                ("压力评估", "压力评估", 1),
                ("CPU", "CPU", 1),
                ("GPU", "GPU", 1),
            ] {
                let metrics = GeekRingLabelMetrics.measure(text: title.uppercased(), fontSize: fontSize, width: side)
                XCTAssertEqual(metrics.lineCount, lineCount)
                let expectedFontSize: CGFloat = size == 88 && lineCount == 2 ? 9 : fontSize
                XCTAssertEqual(metrics.fontSize, expectedFontSize, "Only an over-wide word uses the fixed readable size")
                XCTAssertGreaterThanOrEqual(metrics.fontSize, 9)
                for dark in [false, true] {
                    let actual = try labelBitmap(
                        GeekCombinedRingLabel(text: title, fontSize: fontSize, width: side), dark: dark
                    )
                    let expected = try labelBitmap(
                        Text(completeText).font(.system(size: expectedFontSize, weight: .regular))
                            .foregroundStyle(.primary.opacity(0.77))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true).frame(width: side),
                        dark: dark
                    )
                    XCTAssertEqual(actual.pixelsWide, expected.pixelsWide)
                    XCTAssertEqual(actual.pixelsHigh, expected.pixelsHigh)
                    let actualBands = textBands(in: actual, dark: dark)
                    let expectedBands = textBands(in: expected, dark: dark)
                    XCTAssertEqual(actualBands.count, lineCount, "Native Text must draw every complete label line")
                    assertMatchingBands(actualBands, expectedBands, title: title)
                    // The full bitmap is compared with explicit, untruncated
                    // native text, not an AX label or a source-string check.
                    XCTAssertTrue(textMask(in: actual, dark: dark).elementsEqual(textMask(in: expected, dark: dark)),
                                  "The native label must match all glyphs in \(completeText)")
                    XCTAssertLessThanOrEqual(CGFloat(actual.pixelsHigh) / 2, metrics.height + 1,
                                             "The value budget must reserve the native wrapped text height")
                    if lineCount == 2 {
                        let truncated = try labelBitmap(
                            Text("PRESSUR\nESTIM…").font(.system(size: expectedFontSize, weight: .regular))
                                .foregroundStyle(.primary.opacity(0.77)).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true).frame(width: side), dark: dark
                        )
                        XCTAssertFalse(textMask(in: truncated, dark: dark).elementsEqual(textMask(in: expected, dark: dark)),
                                       "The complete-glyph comparison must reject the actual previous truncation")
                    }
                }
            }
        }
    }

    func testCompletePressureLinesStayInsidePercentUnknownAndFiveDigitRPMRings() throws {
        for size: CGFloat in [88, 112] {
            let side = GeekCombinedRing.contentDiameter(
                size: size, lineWidth: GeekVisualTokens.gaugeStrokeWidth(size: size)
            ) / sqrt(2)
            let fontSize: CGFloat = size == 88 ? 10 : 11
            for (title, completeText, labelLines) in [
                ("Pressure estimate", "PRESSURE\nESTIMATE", 2), ("压力评估", "压力评估", 1),
            ] {
                let expectedFontSize: CGFloat = size == 88 && labelLines == 2 ? 9 : fontSize
                for dark in [false, true] {
                    let reference = try labelBitmap(
                        Text(completeText).font(.system(size: expectedFontSize, weight: .regular))
                            .foregroundStyle(.primary.opacity(0.77)).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true).frame(width: side), dark: dark
                    )
                    let expectedBands = textBands(in: reference, dark: dark)
                    for (index, value) in ["100%", "—", "12000 rpm"].enumerated() {
                        let bitmap = try labelBitmap(
                            GeekCombinedRing(title: title, value: value,
                                progress: value == "—" ? nil : 1, tint: MonitorPalette.blue,
                                size: size, fixedValueFontSize: 28)
                                .padding(6), dark: dark
                        )
                        let inset = 6 + (size - side) / 2
                        let crop = CGRect(x: inset * 2, y: inset * 2, width: side * 2, height: side * 2)
                        let bands = textBands(in: bitmap, dark: dark, crop: crop)
                        XCTAssertEqual(bands.count, labelLines + 1,
                                       "The numeric line and every full label line must remain visible in the circle")
                        assertMatchingBands(Array(bands.suffix(labelLines)), expectedBands, title: title)
                        assertReadoutStaysInsideSafeSquare(in: bitmap, dark: dark, square: crop)
                        if let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_RING_LABEL_EVIDENCE"] {
                            let directory = URL(fileURLWithPath: path, isDirectory: true)
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            let name = "pressure-\(Int(size))-\(labelLines == 2 ? "en" : "zh")-\(dark ? "dark" : "light")-\(index).png"
                            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                                .write(to: directory.appendingPathComponent(name))
                        }
                    }
                }
            }
        }
    }

    private func labelBitmap<Content: View>(_ content: Content, dark: Bool) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: content
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.miniWindowVisualMode, .black)
            .background(dark ? Color.black : Color.white))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func textMask(in bitmap: NSBitmapImageRep, dark: Bool) -> [Bool] {
        (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).map { x in isTextPixel(in: bitmap, x: x, y: y, dark: dark) }
        }
    }

    private func isTextPixel(in bitmap: NSBitmapImageRep, x: Int, y: Int, dark: Bool) -> Bool {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.8 else { return false }
        let components = [color.redComponent, color.greenComponent, color.blueComponent]
        guard let minimum = components.min(), let maximum = components.max(), maximum - minimum < 0.05 else { return false }
        return dark ? minimum > 0.5 : maximum < 0.5
    }

    private func textBands(in bitmap: NSBitmapImageRep, dark: Bool, crop: CGRect? = nil) -> [CGRect] {
        let rect = crop ?? CGRect(x: 0, y: 0, width: CGFloat(bitmap.pixelsWide), height: CGFloat(bitmap.pixelsHigh))
        let minX = max(0, Int(ceil(rect.minX)))
        let maxX = min(bitmap.pixelsWide, Int(floor(rect.maxX)))
        let minY = max(0, Int(ceil(rect.minY)))
        let maxY = min(bitmap.pixelsHigh, Int(floor(rect.maxY)))
        guard minX < maxX, minY < maxY else { return [] }
        var bands: [CGRect] = []
        var active: CGRect?
        for y in minY..<maxY {
            let pixels = (minX..<maxX).filter { isTextPixel(in: bitmap, x: $0, y: y, dark: dark) }
            if let first = pixels.first, let last = pixels.last {
                let row = CGRect(x: CGFloat(first), y: CGFloat(y), width: CGFloat(last - first + 1), height: 1)
                active = active.map { $0.union(row) } ?? row
            } else if let finished = active {
                bands.append(finished)
                active = nil
            }
        }
        if let finished = active { bands.append(finished) }
        return bands
    }

    private func assertReadoutStaysInsideSafeSquare(in bitmap: NSBitmapImageRep, dark: Bool, square: CGRect) {
        var outsidePixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where isTextPixel(in: bitmap, x: x, y: y, dark: dark) {
                if !square.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) { outsidePixels += 1 }
            }
        }
        XCTAssertEqual(outsidePixels, 0, "All numeric and label glyphs must remain inside the ring's inscribed safe square")
    }

    private func assertMatchingBands(_ actual: [CGRect], _ expected: [CGRect], title: String) {
        XCTAssertEqual(actual.count, expected.count, title)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(actual.width, expected.width, accuracy: 2, "Full native glyph width: \(title)")
            XCTAssertEqual(actual.height, expected.height, accuracy: 2, "Full native glyph height: \(title)")
        }
    }

    func testCurrentMenuGaugeRendersLongReadoutsAtProductionSizes() throws {
        let directory = ProcessInfo.processInfo.environment["STORAGE_CLEANER_GAUGE_EVIDENCE"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let values = ["100%", "12000 rpm", "3.25 GHz", "45°C", "12.34 GiB", "—"]
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            for size: CGFloat in [28, 30, 35, 56, 72, 88, 112] {
                for (index, value) in values.enumerated() {
                    let canvasWidth = max(110, size + 16)
                    let canvasHeight = max(140, size + 16)
                    let host = NSHostingView(rootView: GeekCombinedRing(
                        title: "CPU Frequency", value: value,
                        progress: value == "—" ? nil : 1, tint: MonitorPalette.blue, size: size
                    ).padding(8).frame(width: canvasWidth)
                        .environment(\.colorScheme, scheme)
                        .background(dark ? Color.black : AppAppearanceColors.panel))
                    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    defer { window.contentView = nil; window.close() }
                    host.layoutSubtreeIfNeeded()
                    let fitting = host.fittingSize
                    XCTAssertLessThanOrEqual(fitting.width, canvasWidth + 0.5)
                    XCTAssertLessThanOrEqual(fitting.height, canvasHeight)
                    XCTAssertGreaterThanOrEqual(fitting.height, size)
                    if let directory {
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: directory.appendingPathComponent("\(dark ? "dark" : "light")-\(Int(size))-\(index).png"))
                    }
                }
            }
        }
    }
}
#endif
