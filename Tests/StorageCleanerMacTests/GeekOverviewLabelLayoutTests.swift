#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class GeekOverviewLabelLayoutTests: XCTestCase {
    func testSensorRingTextStaysCompleteAtOriginalDiameterAcrossSizeLanguageAndAppearance() async throws {
        // The seven existing mini-window/card widths, including the tightest
        // 248 pt fixture: gaps may flex, the 72 pt rings and fonts may not.
        for language in [AppLanguage.zhHans, .english] {
            let scope = OverviewLabelLanguageScope(language)
            defer { scope.restore() }
            for dark in [false, true] {
                for width: CGFloat in [248, 280, 304, 312, 320, 360, 400] {
                    for state: MiniWindowDemoData.HardwareControlDemoState in [.fanManual65, .dualFanManual, .fanless] {
                        let telemetry = MiniWindowDemoData.fanTelemetry(for: state)
                        let profile = MiniWindowDemoData.hardwareControlProfile(for: state)
                        let entry = FanControlEntryPresentation(telemetry: telemetry, helperState: profile.helperState,
                            observedMode: profile.observedMode, manualPercentage: profile.manualPercentage)
                        let view = GeekSensorsPresentation(geekCompactTemperatureText: "53°C", geekCompactFrequencyText: "3.60 GHz",
                            temperatureProgress: 0.53, temperatureTint: .blue, geekOverviewGPUTemperature: 49,
                            gpuUsageText: "42%", gpuUsageProgress: 0.42, resolvedGPUTint: .blue,
                            geekFanTelemetry: telemetry, openDetail: { XCTFail("Geometry must remain read-only") },
                            geekCompactGPUFrequencyText: "0.34 GHz", fanControlEntry: entry)
                            // A colored arc stays outside the neutral glyph mask;
                            // a white fan arc in dark mode would look like text.
                            .environment(\.panelChartAccentColor, .blue)
                        let host = OverviewLabelHost(content: view,
                            size: CGSize(width: width, height: GeekPanelLayout.overviewSensorsCardHeight), dark: dark)
                        defer { host.close() }
                        let frames = try await host.frames(required: ["overview.sensor.card", "overview.sensor.header",
                            "overview.sensor.cpu", "overview.sensor.gpu", "overview.sensor.fan"])
                        let card = try XCTUnwrap(frames["overview.sensor.card"])
                        XCTAssertEqual(card.height, 108, accuracy: 0.5)
                        if width == 304, let directory = ProcessInfo.processInfo.environment["STORAGE_CLEANER_FIX2_EVIDENCE"] {
                            let bitmap = try host.capture(card)
                            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("sensor-\(language.rawValue)-\(dark ? "dark" : "light")-\(state.rawValue).png"))
                        }
                        if telemetry.isFanless {
                            XCTAssertNil(host.recordedFrames["overview.sensor.entry"], "Passive cooling must not advertise a control")
                        }
                        let readings: [(String, String, String, String)] = [
                            ("cpu", "CPU", "53°C", "3.60 GHz"),
                            ("gpu", "GPU", "49°C", "0.34 GHz"),
                            ("fan", telemetry.fanCount > 1 ? L10n.text("风扇均值", "Fans") : L10n.text("风扇", "Fan"),
                             telemetry.actualRPM.map(SystemFanSpeedFormat.number) ?? L10n.text("无风扇", "Fanless"),
                             telemetry.actualRPM == nil ? L10n.text("不可用", "Unavailable") : "rpm")
                        ]
                        var previousRing: CGRect?
                        for (id, title, value, detail) in readings {
                            let tag = "\(language) dark=\(dark) width=\(width) state=\(state) \(id)"
                            let ring = try XCTUnwrap(frames["overview.sensor.\(id)"])
                            XCTAssertGreaterThanOrEqual(ring.width, 72, tag)
                            XCTAssertEqual(ring.width, 72, accuracy: 0.5, tag)
                            XCTAssertEqual(ring.height, 72, accuracy: 0.5, tag)
                            XCTAssertTrue(card.insetBy(dx: GeekVisualTokens.cardHorizontalPadding - 0.5, dy: 0).contains(ring), tag)
                            if let previousRing { XCTAssertLessThanOrEqual(previousRing.maxX, ring.minX + 0.5, tag) }
                            previousRing = ring
                            let progress = id == "cpu" ? 0.53 : id == "gpu" ? 0.49 : telemetry.percentage.map { $0 / 100 }
                            let referenceRing = GeekCombinedRing(title: title, value: value, detail: detail,
                                progress: progress, tint: .blue, size: 72, labelPlacement: .aboveValue, strokeWidth: 4)
                            XCTAssertEqual(referenceRing.labelFontSize, 10, "Restore the pre-fix1 label size")
                            XCTAssertEqual(referenceRing.detailFontSize, 10, "Restore the pre-fix1 secondary size")
                            let diameter = GeekCombinedRing.contentDiameter(size: ring.width, lineWidth: 4)
                            let boxWidth = diameter / sqrt(2)
                            let titleWidth = (title.uppercased() as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
                            let detailWidth = (detail as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)]).width
                            let split = GeekCombinedRing.splitReadout(value)
                            let valueWidth = ((split?.number ?? value) as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: referenceRing.valueFontSize, weight: .regular)]).width
                                + ((split?.unit ?? "") as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: referenceRing.valueFontSize * 0.62, weight: .regular)]).width
                            for (text, naturalWidth) in [(title, titleWidth), (value, valueWidth), (detail, detailWidth)] {
                                XCTAssertFalse(text.contains("…") || text.contains("..."), tag)
                                XCTAssertLessThanOrEqual(naturalWidth, diameter, "Full text must fit inside the inner diameter: \(tag) \(text)")
                                XCTAssertLessThanOrEqual(naturalWidth * 0.75, boxWidth, "The original native fit range must contain every glyph: \(tag) \(text)")
                            }
                            if id != "fan" { XCTAssertEqual(referenceRing.valueFontSize, 15, accuracy: 0.01, "Restore the pre-fix1 number size") }
                            // Compare actual production pixels with a separate original-
                            // diameter ring containing the complete expected strings.
                            // AX text and outer frames alone do not detect an ellipsis.
                            let bitmap = try host.capture(ring)
                            let reference = try await nativeSensorReference(referenceRing, dark: dark)
                            XCTAssertEqual(bitmap.pixelsWide, reference.pixelsWide, tag)
                            XCTAssertEqual(bitmap.pixelsHigh, reference.pixelsHigh, tag)
                            let scale = host.window.backingScaleFactor
                            let inset = (72 - diameter) / 2
                            let interior = Int(ceil(inset * scale))..<Int(floor((72 - inset) * scale))
                            let actualMask = glyphMask(bitmap, rows: interior, columns: interior, dark: dark)
                            let expectedMask = glyphMask(reference, rows: interior, columns: interior, dark: dark)
                            let match = max(glyphCoverage(actualMask, expectedMask), glyphCoverage(verticallyFlipped(actualMask), expectedMask))
                            XCTAssertGreaterThanOrEqual(match, 0.95, "Every original-size glyph must render without truncation: \(tag)")
                        }
                    }
                }
            }
        }
    }

    private func nativeSensorReference(_ ring: GeekCombinedRing, dark: Bool) async throws -> NSBitmapImageRep {
        let view = ring.background(GeekVisualTokens.cardFill(for: dark ? .dark : .light, visualMode: .black))
        let host = OverviewLabelHost(content: view, size: CGSize(width: 72, height: 72), dark: dark)
        defer { host.close() }
        _ = try await host.frames(required: [])
        return try host.capture(CGRect(x: 0, y: 0, width: 72, height: 72))
    }

    func testEnglishNetworkTitlesRenderCompletelyAndLeaveTheRealPlotReadable() async throws {
        let language = OverviewLabelLanguageScope(.english)
        defer { language.restore() }
        let width = MiniWindowStyleTokens.overviewSize.width - 2 * MiniWindowStyleTokens.contentInset
        let bodyFont = NSFont.systemFont(ofSize: 11)
        let titleHeight = ceil(("Download" as NSString).size(withAttributes: [.font: bodyFont]).height)

        for dark in [false, true] {
            for rates in [("0 B/s", "0 B/s"), ("1.6 MiB/s", "72 KiB/s"), ("999.9 MiB/s", "12.3 GiB/s")] {
                let host = OverviewLabelHost(
                    content: GeekNetworkPresentation(
                        networkUpText: rates.0, networkDownText: rates.1,
                        networkChartHistory: [], networkChartRange: .oneMinute,
                        resolvedUploadTint: .pink, resolvedDownloadTint: .blue
                    ),
                    size: CGSize(width: width, height: GeekPanelLayout.overviewNetworkCardHeight),
                    dark: dark
                )
                defer { host.close() }
                let frames = try await host.frames(required: ["overview.network.row",
                    "overview.network.upload", "overview.network.chart", "overview.network.download"])
                let row = try XCTUnwrap(frames["overview.network.row"])
                let chart = try XCTUnwrap(frames["overview.network.chart"])
                let upload = try XCTUnwrap(frames["overview.network.upload"])
                let download = try XCTUnwrap(frames["overview.network.download"])
                let pixel = 1 / host.window.backingScaleFactor
                XCTAssertEqual(upload.width, download.width, accuracy: pixel)
                XCTAssertEqual(upload.width, GeekNetworkPresentation.valueColumnWidth, accuracy: pixel)
                XCTAssertGreaterThanOrEqual(chart.width, 116 - pixel)
                for frame in [upload, chart, download] {
                    XCTAssertTrue(row.insetBy(dx: -pixel, dy: -pixel).contains(frame))
                }
                XCTAssertEqual(chart.minX - upload.maxX, 6, accuracy: pixel)
                XCTAssertEqual(download.minX - chart.maxX, 6, accuracy: pixel)

                for (title, frame) in [("Upload", upload), ("Download", download)] {
                    let naturalWidth = (title as NSString).size(withAttributes: [.font: bodyFont]).width
                    XCTAssertGreaterThanOrEqual(frame.width, naturalWidth + 9 + 4,
                        "The full existing-font label, dot and gap must fit before rendering")
                    let bitmap = try host.capture(frame)
                    let reference = try referenceText(title, fontSize: 11, dark: dark,
                        scale: CGFloat(bitmap.pixelsWide) / frame.width, secondary: true)
                    // Compare actual rasterized glyphs with an unconstrained native
                    // Text. A full AX label or a wide outer frame alone cannot pass.
                    assertCompleteGlyphs(in: bitmap, reference: reference, bandHeight: titleHeight,
                        dark: dark, message: "\(title) must render without an ellipsis for \(rates)")
                }
            }
        }
    }

    func testEnglishGPUDetailRendersInsideItsProductionRingWithoutInventingTemperature() async throws {
        let language = OverviewLabelLanguageScope(.english)
        defer { language.restore() }
        let width = MiniWindowStyleTokens.overviewSize.width - 2 * MiniWindowStyleTokens.contentInset
        let detailFont = NSFont.systemFont(ofSize: 10)
        let contentSide = GeekCombinedRing.contentDiameter(size: 72, lineWidth: 4) / sqrt(2)
        for dark in [false, true] {
            for temperature: Double? in [69, 0, nil] {
                let presentation = sensorPresentation(temperature: temperature, usage: "42%", progress: 0.42)
                let expected = temperature == nil ? "Usage" : "Temp"
                XCTAssertEqual(presentation.gpuDetailTitle, expected)
                let natural = (expected as NSString).size(withAttributes: [.font: detailFont])
                XCTAssertLessThanOrEqual(natural.width, contentSide)
                let host = OverviewLabelHost(content: presentation,
                    size: CGSize(width: width, height: GeekPanelLayout.overviewSensorsCardHeight), dark: dark)
                defer { host.close() }
                let frames = try await host.frames(required: ["overview.sensor.gpu"])
                let ring = try XCTUnwrap(frames["overview.sensor.gpu"])
                XCTAssertEqual(ring.width, 72, accuracy: 0.5)
                XCTAssertEqual(ring.height, 72, accuracy: 0.5)
                let inset = (ring.width - contentSide) / 2
                let inner = ring.insetBy(dx: inset, dy: inset)
                XCTAssertTrue(ring.contains(inner))
                // Capture the integral 72 pt ring first. A 42.426 pt inner
                // crop becomes 85 pixels at 2x; deriving scale from that crop
                // incorrectly produced a 2.00347x, 145-pixel reference ring.
                let bitmap = try host.capture(ring)
                let reference = try await nativeGPUReference(
                    temperature: temperature, detail: expected, dark: dark)
                XCTAssertEqual(bitmap.pixelsWide, reference.pixelsWide)
                XCTAssertEqual(bitmap.pixelsHigh, reference.pixelsHigh)
                let scale = host.window.backingScaleFactor
                XCTAssertEqual(CGFloat(bitmap.pixelsWide), ring.width * scale, accuracy: 0.5)
                XCTAssertEqual(CGFloat(bitmap.pixelsHigh), ring.height * scale, accuracy: 0.5)
                let firstPixel = Int(ceil(inset * scale))
                let lastPixel = Int(floor((ring.width - inset) * scale))
                let interior = firstPixel..<lastPixel
                let actualMask = glyphMask(bitmap, rows: interior, columns: interior, dark: dark)
                let expectedMask = glyphMask(reference, rows: interior, columns: interior, dark: dark)
                let match = max(glyphCoverage(actualMask, expectedMask),
                                glyphCoverage(verticallyFlipped(actualMask), expectedMask))
                XCTAssertGreaterThanOrEqual(match, 0.95,
                    "Actual production GPU text must match complete native \(expected), including the real value; dark=\(dark), temperature=\(String(describing: temperature))")
                if temperature == 69 {
                    // The corrected comparison must still reject the original
                    // long/ellipsized word, rather than make every ring pass.
                    let truncatedReference = try await nativeGPUReference(
                        temperature: temperature, detail: "Temperature", dark: dark)
                    let truncatedMask = glyphMask(truncatedReference,
                        rows: interior, columns: interior, dark: dark)
                    let invalidMatch = max(glyphCoverage(actualMask, truncatedMask),
                        glyphCoverage(verticallyFlipped(actualMask), truncatedMask))
                    XCTAssertLessThan(invalidMatch, 0.95,
                        "The native glyph guard must detect the old clipped Temperature label")
                }
            }
        }
    }

    func testChineseGPUDetailKeepsItsExistingMeaningIncludingUnknownAndMeasuredZero() {
        let language = OverviewLabelLanguageScope(.zhHans)
        defer { language.restore() }
        XCTAssertEqual(sensorPresentation(temperature: 0, usage: "—", progress: nil).gpuDetailTitle, "温度")
        XCTAssertEqual(sensorPresentation(temperature: nil, usage: "42%", progress: 0.42).gpuDetailTitle, "占用")
        XCTAssertEqual(sensorPresentation(temperature: nil, usage: "—", progress: nil).gpuDetailTitle, "占用")
    }

    private func sensorPresentation(temperature: Double?, usage: String, progress: Double?) -> GeekSensorsPresentation {
        GeekSensorsPresentation(
            geekCompactTemperatureText: "70°C", geekCompactFrequencyText: "3.25 GHz",
            temperatureProgress: 0.7, temperatureTint: .blue,
            geekOverviewGPUTemperature: temperature, gpuUsageText: usage,
            gpuUsageProgress: progress, resolvedGPUTint: .blue,
            geekFanTelemetry: FanTelemetryState.resolve(snapshot: nil),
            openDetail: { XCTFail("Rendering must not issue a navigation or hardware command") }
        )
    }

    private func nativeGPUReference(temperature: Double?, detail: String,
                                    dark: Bool) async throws -> NSBitmapImageRep {
        let ring = GeekCombinedRing(
            title: "GPU", value: temperature.map { String(format: "%.0f°C", $0) } ?? "42%",
            detail: detail, progress: temperature.map { $0 / 100 } ?? 0.42,
            tint: .blue, size: 72, labelPlacement: .aboveValue, strokeWidth: 4
        )
        // Same native capture backend, appearance and actual production card
        // fill: translucent glyph edges must not be compared with white/black.
        .background(GeekVisualTokens.cardFill(for: dark ? .dark : .light, visualMode: .black))
        let host = OverviewLabelHost(content: ring, size: CGSize(width: 72, height: 72), dark: dark)
        defer { host.close() }
        _ = try await host.frames(required: [])
        return try host.capture(CGRect(x: 0, y: 0, width: 72, height: 72))
    }

    private func referenceText(_ text: String, fontSize: CGFloat, dark: Bool,
                               scale: CGFloat, secondary: Bool) throws -> NSBitmapImageRep {
        let view = Text(text)
            .font(.system(size: fontSize, weight: .regular))
            .foregroundStyle(secondary ? Color.secondary : Color.primary.opacity(0.77))
            .monospacedDigit()
            .fixedSize()
            .background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func assertCompleteGlyphs(in bitmap: NSBitmapImageRep, reference: NSBitmapImageRep,
                                     bandHeight: CGFloat, dark: Bool, message: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let expected = glyphMask(reference, rows: 0..<reference.pixelsHigh, dark: dark)
        XCTAssertFalse(expected.isEmpty, file: file, line: line)
        let scale = CGFloat(reference.pixelsHigh) / bandHeight
        let band = min(bitmap.pixelsHigh, Int(ceil(bandHeight * scale)))
        // AppKit bitmap row orientation varies between capture backends. Both
        // end bands are checked; numeric rate glyphs cannot match the word.
        let candidates = [0..<band, (bitmap.pixelsHigh - band)..<bitmap.pixelsHigh]
            .map { glyphMask(bitmap, rows: $0, dark: dark) }
        let best = candidates.map { glyphCoverage($0, expected) }.max() ?? 0
        XCTAssertGreaterThanOrEqual(best, 0.95, message, file: file, line: line)
    }

    private struct Pixel: Hashable { let x: Int; let y: Int }

    private func verticallyFlipped(_ mask: Set<Pixel>) -> Set<Pixel> {
        guard let maxY = mask.map(\.y).max() else { return [] }
        return Set(mask.map { Pixel(x: $0.x, y: maxY - $0.y) })
    }

    private func glyphMask(_ bitmap: NSBitmapImageRep, rows: Range<Int>,
                           columns: Range<Int>? = nil, dark: Bool) -> Set<Pixel> {
        var mask = Set<Pixel>()
        for y in rows {
            for x in columns ?? (0..<bitmap.pixelsWide) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.2 else { continue }
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                let maximum = channels.max() ?? 0
                let minimum = channels.min() ?? 0
                let brightness = channels.reduce(0, +) / 3
                // Ignore colored dots, curves and the neutral card background.
                if maximum - minimum < 0.12,
                   dark ? brightness > 0.27 && brightness < 0.93 : brightness > 0.08 && brightness < 0.75 {
                    mask.insert(Pixel(x: x, y: y))
                }
            }
        }
        guard let minX = mask.map(\.x).min(), let minY = mask.map(\.y).min() else { return [] }
        return Set(mask.map { Pixel(x: $0.x - minX, y: $0.y - minY) })
    }

    private func glyphCoverage(_ actual: Set<Pixel>, _ expected: Set<Pixel>) -> Double {
        guard !actual.isEmpty, !expected.isEmpty else { return 0 }
        // One physical pixel tolerates subpixel positioning, not missing letters.
        func coverage(_ source: Set<Pixel>, _ target: Set<Pixel>) -> Double {
            let matches = source.filter { point in
                (-1...1).contains(where: { dx in (-1...1).contains(where: { dy in
                    target.contains(Pixel(x: point.x + dx, y: point.y + dy))
                }) })
            }.count
            return Double(matches) / Double(source.count)
        }
        return min(coverage(actual, expected), coverage(expected, actual))
    }
}

@MainActor
private final class OverviewLabelLanguageScope {
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

@MainActor
private final class OverviewLabelRecorder { var frames: [String: CGRect] = [:] }

@MainActor
private final class OverviewLabelHost {
    let window: NSWindow
    private let host: NSHostingView<AnyView>
    private let recorder = OverviewLabelRecorder()
    var recordedFrames: [String: CGRect] { recorder.frames }

    init<Content: View>(content: Content, size: CGSize, dark: Bool) {
        _ = NSApplication.shared
        let root = content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.miniWindowVisualMode, .black)
            .onPreferenceChange(LayoutFramePreferenceKey.self) { [weak recorder] frames in
                Task { @MainActor [weak recorder] in recorder?.frames = frames }
            }
        host = NSHostingView(rootView: AnyView(root))
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
    }

    func frames(required: Set<String>) async throws -> [String: CGRect] {
        var previous: [String: CGRect]?
        var stablePasses = 0
        for _ in 0..<100 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            if required.isSubset(of: Set(recorder.frames.keys)) {
                let current = recorder.frames.filter { required.contains($0.key) }
                stablePasses = previous == current ? stablePasses + 1 : 0
                previous = current
                if stablePasses >= 2 { return current }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "GeekOverviewLabelLayoutTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Native overview label frames did not stabilize"])
    }

    func capture(_ rect: CGRect) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
        host.cacheDisplay(in: rect, to: bitmap)
        return bitmap
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}
#endif
