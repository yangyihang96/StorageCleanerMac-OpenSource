import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D279: grey type, and the status words on the updates and health pages,
/// read 4.5:1 on the module gradient they stand on (`CareStudioText`). Off a
/// gradient they keep their values; as fills, lines and charts they keep them
/// too. D280: so do SwiftUI's own grey levels (`CareStudioHierarchyText`).
@MainActor
final class MainWindowGreyTextTests: XCTestCase {
    /// The four greys and the status colours the updates and health pages write in.
    private func inks(_ scheme: ColorScheme) -> [(String, Color)] {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        return [("CareStudio secondary", CareStudioInk.secondary.base), ("CareStudio tertiary", CareStudioInk.tertiary.base),
                ("lightfield fg2", palette.fg2.base), ("lightfield fg3", palette.fg3.base),
                ("destructive", AppDesignTokens.Palette.destructive), ("success", AppDesignTokens.Palette.success),
                ("warning", AppDesignTokens.Palette.warning), ("information", AppDesignTokens.Palette.information),
                ("accent", .accentColor), ("secondary", .secondary), ("lightfield warning", palette.warningColor)]
    }

    func testGreyAndStatusTypeReadsOnEveryModuleGradientInBothAppearances() {
        var whiteAtNight: Set<CareStudioFamily> = []
        for family in CareStudioFamily.allCases {
            let palette = family.palette
            XCTAssertEqual(palette.textGrounds(night: false), dayGrounds(palette), "\(family) day grounds")
            XCTAssertEqual(palette.textGrounds(night: true), nightGrounds(palette), "\(family) night grounds")
            for scheme in [ColorScheme.light, .dark] {
                let grounds = scheme == .dark ? nightGrounds(palette) : dayGrounds(palette)
                for (name, ink) in inks(scheme) {
                    let base = resolve(ink, scheme, on: nil), text = resolve(ink, scheme, on: family, asText: true)
                    // As drawn: the resolved colour carries a float opacity, and a raised one is a
                    // whole 8-bit step (`readableOpacity`), so it blends as it was solved.
                    let worst = grounds.map { contrast(blend(text.hex, text.opacity, over: $0), $0) }.min() ?? 0
                    if worst < 4.5 {
                        // Only white is left: the ground itself is too bright for any type.
                        XCTAssertEqual(scheme, .dark, "\(family) \(name) day \(worst)")
                        XCTAssertEqual(hex(text.hex), "FFFFFF", "\(family) \(name)")
                        XCTAssertEqual(text.opacity, 1, accuracy: 0.001, "\(family) \(name)")
                        whiteAtNight.insert(family)
                        continue
                    }
                    if base.opacity < 0.999, text.hex == base.hex {
                        // A translucent ink grows more opaque, and no more than it has to.
                        XCTAssertGreaterThanOrEqual(text.opacity, base.opacity - 0.001, "\(family) \(name) \(scheme)")
                        if text.opacity > base.opacity + 0.01 {
                            let less = text.opacity - 0.01
                            XCTAssertLessThan(grounds.map { contrast(blend(text.hex, less, over: $0), $0) }.min() ?? 0, 4.5,
                                              "\(family) \(name) \(scheme) is darker than it needs")
                        }
                    } else {
                        // A solid colour moves toward black by day, toward white at night.
                        let moved = channels(text.hex), original = channels(blend(base.hex, base.opacity, over: scheme == .dark ? 0 : 0xFFFFFF))
                        XCTAssertTrue(scheme == .dark ? moved.elementsEqual(original, by: >=) : moved.elementsEqual(original, by: <=),
                                      "\(family) \(name) \(scheme) #\(hex(text.hex))")
                    }
                }
            }
        }
        XCTAssertEqual(whiteAtNight, [.performance, .clutter, .cloudCleanup])
    }

    func testOffTheGradientTheTypeKeepsItsValues() {
        for scheme in [ColorScheme.light, .dark] {
            for (name, ink) in inks(scheme) {
                let base = resolve(ink, scheme, on: nil), text = resolve(ink, scheme, on: nil, asText: true)
                XCTAssertEqual(hex(text.hex), hex(base.hex), "\(name) \(scheme)")
                XCTAssertEqual(text.opacity, base.opacity, accuracy: 0.0001, "\(name) \(scheme)")
            }
        }
        // Where code needs a colour (a fill, a chart, a canvas), the greys keep their values.
        for scheme in [ColorScheme.light, .dark] {
            let palette = FeatureLightfieldPalette.resolve(scheme)
            XCTAssertEqual(FeatureLightfieldStatus.unknown.color(palette), palette.fg3.base)
            for status in [MetadataPillStatus.locked, .readOnly, .systemSettingsOnly] {
                XCTAssertEqual(status.lightfieldColor(palette), palette.fg3.base, "\(status)")
            }
            XCTAssertEqual(MetadataPillStatus.warning.lightfieldColor(palette), FeatureLightfieldStatus.warning.color(palette))
        }
    }

    /// The main window's pages and the sidebar beside them stand on the module's
    /// gradient; the white manager panels and the readiness panel do not.
    func testTheMainWindowSetsTheGroundAndTheWhitePanelsClearIt() throws {
        let all = Dictionary(try sources(), uniquingKeysWith: { first, _ in first })
        XCTAssertTrue(try XCTUnwrap(all["ModulePresentation.swift"]).contains(".environment(\\.careStudioTextGround, studio?.family)"))
        XCTAssertTrue(try XCTUnwrap(all["SidebarView.swift"]).contains(".environment(\\.careStudioTextGround, studioFamily)"))
        var cleared: [String] = []
        for (name, source) in try sources() {
            cleared += Array(repeating: name, count: source.components(separatedBy: ".environment(\\.careStudioTextGround, nil)").count - 1)
        }
        XCTAssertEqual(cleared.sorted(), ["CareStudioJunkManager.swift", "CareStudioManagerChrome.swift", "CareStudioStartup.swift",
                                          "ContentView.swift", "ToolboxManagerPanel.swift"])
        let white = try NSRegularExpression(pattern: #"\.environment\(\\\.colorScheme, \.light\)\n\s*// D279: the panel is white, not the module's gradient\.\n\s*\.environment\(\\\.careStudioTextGround, nil\)"#)
        for name in ["CareStudioJunkManager.swift", "CareStudioManagerChrome.swift", "CareStudioStartup.swift", "ToolboxManagerPanel.swift"] {
            let source = try XCTUnwrap(all[name])
            XCTAssertEqual(white.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)), 1, name)
        }
        let content = try XCTUnwrap(all["ContentView.swift"])
        let start = try XCTUnwrap(content.range(of: "private struct ScanReadinessPanel: View {"))
        let end = content.range(of: "\nprivate struct ", range: start.upperBound..<content.endIndex)?.lowerBound ?? content.endIndex
        XCTAssertTrue(content[start.upperBound..<end].contains(".environment(\\.careStudioTextGround, nil)"))
    }

    /// The status words on the two pages where they were measured; their glyphs
    /// and fills keep the status colours.
    func testStatusWordsOnTheUpdatesAndHealthPagesTakeTheReadableColour() throws {
        let all = Dictionary(try sources(), uniquingKeysWith: { first, _ in first })
        for (name, count) in ["AppUpdatesView.swift": 14, "AppUpdateLightfieldPresentation.swift": 1, "HealthActionList.swift": 1] {
            let source = try XCTUnwrap(all[name])
            XCTAssertEqual(source.components(separatedBy: ".foregroundStyle(CareStudioText(").count - 1, count, name)
        }
        let updates = try XCTUnwrap(all["AppUpdatesView.swift"])
        for raw in [".foregroundStyle(AppDesignTokens.Palette.destructive)", ".foregroundStyle(AppDesignTokens.Palette.success)",
                    ".foregroundStyle(AppDesignTokens.Palette.warning)", ".foregroundStyle(entry.category.color)",
                    ".foregroundStyle(item.state.color)", ".foregroundStyle(item.task.state.color)", ".foregroundStyle(color)"] {
            XCTAssertFalse(updates.contains(raw), raw)
        }
        // The one state colour left as a foreground is the glyph in the history row.
        XCTAssertEqual(updates.components(separatedBy: "Image(systemName: entry.state.systemImage)\n                .foregroundStyle(entry.state.color)").count - 1, 1)
    }

    /// The greys keep their old values only where code needs a colour and nothing reads as type.
    func testTheGreysKeepTheirValuesOnlyWhereCodeNeedsAColour() throws {
        let marker = try NSRegularExpression(pattern: #"(fg2|fg3|CareStudioInk\.secondary|CareStudioInk\.tertiary)\.base"#)
        var kept: [String] = []
        for (name, source) in try sources() {
            kept += Array(repeating: name, count: marker.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)))
        }
        XCTAssertEqual(kept.sorted(), ["CareStudioActivityCards.swift", // the capacity bar
                                       "FeatureLightfield.swift", // FeatureLightfieldStatus.color(_:)
                                       "FeatureLightfieldCharts.swift", // the "other" bubble
                                       "FeatureLightfieldComponents.swift", // MetadataPillStatus.lightfieldColor(_:)
                                       "LightfieldComponentGallery.swift", // a chart series (debug gallery)
                                       "SidebarView.swift", // the sidebar toggle's icon tint
                                       "SpaceMapTreemapPainter.swift"]) // the hovered tile's outline
    }

    /// D280: SwiftUI's own grey levels read 4.5:1 on every module gradient for
    /// each page type they can inherit (the window's ink, the studio ink, the
    /// lightfield rows' type), with the least whole 8-bit opacity that does;
    /// where SwiftUI's own level already reads it stays as SwiftUI draws it.
    func testHierarchicalGreysReadOnEveryModuleGradientInBothAppearances() {
        var fullAtNight: Set<CareStudioFamily> = []
        for family in CareStudioFamily.allCases {
            for night in [false, true] {
                let grounds = family.palette.textGrounds(night: night)
                let inks: [UInt32] = night ? [0xFFFFFF, 0xF2F5FF] : [0x242426, 0x171221, 0x121A33]
                for (level, own) in [(CareStudioHierarchyText.Level.secondary, 0.5), (.tertiary, 0.25)] {
                    let raised = CareStudioHierarchyText.opacity(level, on: family, night: night)
                    if let raised {
                        XCTAssertGreaterThan(raised, own, "\(family) \(level) night \(night)")
                        XCTAssertEqual(raised * 255, (raised * 255).rounded(), accuracy: 0.0001, "\(family) \(level): a whole 8-bit step")
                    }
                    let opacity = Double(Float(raised ?? own))
                    let worst = inks.flatMap { ink in grounds.map { contrast(blend(ink, opacity, over: $0), $0) } }.min() ?? 0
                    if worst < 4.5 {
                        // Only the full type is left: the ground itself is too bright.
                        XCTAssertTrue(night, "\(family) \(level) day \(worst)")
                        XCTAssertEqual(raised, 1, "\(family) \(level)")
                        fullAtNight.insert(family)
                        continue
                    }
                    if let raised, raised - 1.0 / 255 > own {
                        let judge: UInt32 = night ? 0xF2F5FF : 0x242426, less = Double(Float(raised - 1.0 / 255))
                        XCTAssertLessThan(grounds.map { contrast(blend(judge, less, over: $0), $0) }.min() ?? 0, 4.5,
                                          "\(family) \(level) night \(night) is more opaque than it needs")
                    }
                }
            }
        }
        XCTAssertEqual(fullAtNight, [.performance, .clutter, .cloudCleanup])
    }

    /// D280: off a gradient the readable levels draw exactly as SwiftUI's own;
    /// on one they draw the inherited type at the raised opacity.
    func testReadableLevelsDrawAsSwiftUIsOwnOffTheGradientAndRaiseTheTypeOnIt() throws {
        // The updates page, where the grey lines measured 2.55–2.86:1 by day.
        let family = try XCTUnwrap(CareStudioModule(filter: .updater)?.family)
        for (readable, own, level) in [(AnyShapeStyle(.readableSecondary), AnyShapeStyle(.secondary), CareStudioHierarchyText.Level.secondary),
                                       (AnyShapeStyle(.readableTertiary), AnyShapeStyle(.tertiary), .tertiary)] {
            XCTAssertEqual(try drawnText(readable, ground: nil), try drawnText(own, ground: nil), "\(level) off the gradient")
            let raised = try XCTUnwrap(CareStudioHierarchyText.opacity(level, on: family, night: false), "\(family) \(level)")
            let drawn = try drawnText(readable, ground: family)
            XCTAssertEqual(drawn, try drawnText(AnyShapeStyle(.primary.opacity(raised)), ground: nil), "\(family) \(level)")
            XCTAssertTrue(channels(drawn).elementsEqual(channels(try drawnText(own, ground: family)), by: <), "\(family) \(level) is darker")
        }
    }

    /// D280: no type or icon in the app takes SwiftUI's own grey level directly.
    func testEveryHierarchicalGreyTakesTheReadableLevel() throws {
        let plain = try NSRegularExpression(pattern: #"^(?!\s*//).*\.foregroundStyle\(\.(secondary|tertiary)\)"#, options: .anchorsMatchLines)
        var found: [String] = []
        for (name, source) in try sources() {
            let count = plain.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
            if count > 0 { found.append("\(name) \(count)") }
        }
        XCTAssertEqual(found, [])
    }

    // MARK: - Helpers

    /// A full block in `style` over white by day, with the window's ink as the
    /// type it inherits, sampled at its centre.
    private func drawnText(_ style: AnyShapeStyle, ground family: CareStudioFamily?) throws -> UInt32 {
        let view = Text("\u{2588}").font(.system(size: 60)).foregroundStyle(style)
            .frame(width: 40, height: 40).clipped()
            .background(Color.white)
            .foregroundStyle(AppAppearanceColors.ink)
            .environment(\.careStudioTextGround, family)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        let offset = ((height / 2) * width + width / 2) * 4
        return UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
    }

    private struct Resolved { let hex: UInt32; let opacity: Double }

    /// The colour as it is drawn, or as type (`CareStudioText`) on `family`'s gradient.
    private func resolve(_ color: Color, _ scheme: ColorScheme, on family: CareStudioFamily?, asText: Bool = false) -> Resolved {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        environment.careStudioTextGround = family
        let resolved = (asText ? CareStudioText(color).resolve(in: environment) : color).resolve(in: environment)
        let hex = [resolved.red, resolved.green, resolved.blue].reduce(UInt32(0)) {
            $0 << 8 | UInt32((min(1, max(0, Double($1))) * 255).rounded())
        }
        return Resolved(hex: hex, opacity: Double(resolved.opacity))
    }

    private func dayGrounds(_ palette: CareStudioPalette) -> [UInt32] {
        let day = palette.daylight
        return [day.deep, day.base] + day.glows
    }

    private func nightGrounds(_ palette: CareStudioPalette) -> [UInt32] {
        [palette.base, palette.deep, blend(0xFFFFFF, 0.16, over: palette.base)]
            + CareStudioBackdrop.glows.map { blend(palette.glows[min($0.colorIndex, palette.glows.count - 1)], $0.opacity, over: palette.base) }
    }

    private func blend(_ top: UInt32, _ opacity: Double, over bottom: UInt32) -> UInt32 {
        zip(channels(top), channels(bottom)).reduce(0) { packed, pair in
            packed << 8 | UInt32((Double(pair.0) * opacity + Double(pair.1) * (1 - opacity)).rounded())
        }
    }

    private func channels(_ hex: UInt32) -> [UInt32] { [hex >> 16 & 0xff, hex >> 8 & 0xff, hex & 0xff] }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            let linear = channels(hex).map { channel -> Double in
                let value = Double(channel) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let first = luminance(a), second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func hex(_ value: UInt32) -> String { String(format: "%06X", value) }

    /// Every app source file, by file name.
    private func sources() throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }
}
