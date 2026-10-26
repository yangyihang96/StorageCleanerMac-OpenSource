#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D124: the energy-mode page follows iStat Menus 7.30's energy-mode menu
/// (`-[BatteryMenu updateEnergyModeDisplay]`): a text section per power
/// source, its major label with the dot on the current source and the
/// supported modes as tick rows with the check on the system's mode; our
/// charge limit is a section in the same form. Renders the production page
/// offscreen with fixtures: no helper, write, window or user data.
@MainActor
final class MiniWindowIStatEnergyModeLayoutTests: XCTestCase {
    private static let cardWidth = GeekIStatDetailGeometry.pageWidth - 2 * GeekPanelLayout.contentPadding

    func testTheTextSectionHasIStatsGeometry() {
        typealias Geometry = GeekIStatTextSectionGeometry
        XCTAssertEqual([Geometry.top, Geometry.bottom, Geometry.rowHeight, Geometry.labelRowGap], [5, 5, 15, 2])
        XCTAssertEqual(Geometry.toggleRowHeight, 18)
        XCTAssertEqual([Geometry.leading, Geometry.tickLabelTrailing, Geometry.dotLabelTrailing], [8, 30, 24])
        XCTAssertEqual([Geometry.dotSize, Geometry.dotTop], [8, 3])
        XCTAssertEqual(Geometry.checkPoints.map { $0.trailing }, [16, 13, 9])
        XCTAssertEqual(Geometry.checkPoints.map { $0.y }, [8, 11, 3])
        XCTAssertEqual(Geometry.checkLineWidth, 2)
        XCTAssertEqual(Geometry.toggleTrackSize, CGSize(width: 26, height: 14))
        XCTAssertEqual([Geometry.toggleTrackRadius, Geometry.toggleKnobSize, Geometry.toggleTrailing], [8, 14, 34])
        XCTAssertEqual(Geometry.minimumWidth, 150, "setMinimumWidth: 150")
        XCTAssertEqual(Geometry.widthPadding, 16)
        XCTAssertEqual(Geometry.itemOffset, 22, "highlightConfig itemOffset")
        XCTAssertEqual(Geometry.height(labelRows: 1, tickRows: 3), 72, "a source with three modes")
        XCTAssertEqual(Geometry.height(labelRows: 1, tickRows: 2), 57)
        XCTAssertEqual(Geometry.height(labelRows: 1, tickRows: 0, toggleRows: 1), 45)
        XCTAssertEqual(GeekVisualTokens.highlightRadius(rowHeight: Geometry.rowHeight), 6)
        XCTAssertEqual(MiniWindowStyleTokens.cardSpacing, 7)
        XCTAssertEqual(ControlPaletteMetrics.powerSize.width, GeekIStatDetailGeometry.pageWidth)
    }

    /// Automatic, Low Power, High Power, keeping what the source supports,
    /// under the menu's names in both languages.
    func testTheModesFollowTheMenusOrderAndNames() throws {
        XCTAssertEqual(BatteryPowerMode.energyMenuOrder([.highPower, .lowPower, .automatic]),
                       [.automatic, .lowPower, .highPower])
        XCTAssertEqual(BatteryPowerMode.energyMenuOrder([.highPower, .automatic]), [.automatic, .highPower])
        XCTAssertEqual(BatteryPowerMode.energyMenuOrder([]), [])
        for (language, names) in [(AppLanguage.zhHans, ["自动", "低能耗", "高能耗"]),
                                  (.english, ["Automatic", "Low Power", "High Power"])] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            XCTAssertEqual([BatteryPowerMode.automatic, .lowPower, .highPower].map { $0.energyMenuTitle }, names)
        }
        let power = try Self.source("Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift")
        let page = try XCTUnwrap(power.components(separatedBy: "struct GeekEnergyModeHoverDetail: View {")
            .dropFirst().first?.components(separatedBy: "\n}\n").first)
        let battery = try XCTUnwrap(page.range(of: "title: L10n.text(\"电池\", \"Battery\")"))
        let adapter = try XCTUnwrap(page.range(of: "title: L10n.text(\"电源适配器\", \"AC\")"))
        XCTAssertLessThan(battery.lowerBound, adapter.lowerBound, "the battery section is first")
        let charge = try XCTUnwrap(page.range(of: "GeekChargeTargetSetting("))
        XCTAssertLessThan(adapter.lowerBound, charge.lowerBound, "our charge limit follows the menu's sections")
    }

    /// Each source is 72 (three modes) or 57 (two), 7 apart; the charge
    /// limit with its row of five segments (20 + 2), the full-charge row and
    /// the settings row is 79 (D149; was 132 with five tick rows). Both
    /// languages fit the rows on one line.
    func testRenderedEnergyPageStacksTheSectionsAtTheirHeights() throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let pages: [(String, GeekEnergyModeHoverDetail, CGFloat)] = [
                ("energy-mode", Self.page(batteryModes: [.automatic, .lowPower, .highPower]), 72 + 7 + 72),
                ("energy-mode-two", Self.page(batteryModes: [.automatic, .lowPower]), 57 + 7 + 72),
                ("energy-mode-charge", Self.page(batteryModes: [.automatic, .lowPower, .highPower],
                                                 chargeLimit: Self.manualLimit(effective: 85)),
                 72 + 7 + 72 + 7 + 79),
            ]
            for (name, page, contentHeight) in pages {
                let bitmap = try Self.render(page, mode: .black)
                XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, GeekIStatDetailGeometry.pageWidth, "\(language) \(name)")
                XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, contentHeight + 2 * GeekPanelLayout.contentPadding,
                               accuracy: 0.5, "\(language) \(name)")
                if language == .zhHans {
                    try Self.export(name: "l3-\(name)", night: bitmap, page: page)
                }
            }
        }
    }

    /// The check sits on the system's mode in each source, at (W − 16, 8) →
    /// (W − 13, 11) → (W − 9, 3) of its row; the dot marks the current source
    /// at (W − 16, 3) of its label. D149: the charge limit's manual limit is
    /// the filled one of its segments (was the check on the effective limit).
    func testTheCheckAndTheDotMarkTheSystemsState() throws {
        let page = Self.page(batteryModes: [.automatic, .lowPower, .highPower],
                             chargeLimit: Self.manualLimit(effective: 85))
        let bitmap = try Self.render(page, mode: .black)
        let inset = GeekPanelLayout.contentPadding
        let width = Self.cardWidth
        let section = GeekIStatTextSectionGeometry.self
        let batteryTop = inset
        let adapterTop = batteryTop + 72 + 7
        let chargeTop = adapterTop + 72 + 7
        func color(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            try XCTUnwrap(bitmap.colorAt(x: Int((x * 2).rounded(.down)), y: Int((y * 2).rounded(.down)))?
                .usingColorSpace(.sRGB))
        }
        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                abs(a.blueComponent - b.blueComponent))
        }
        // The middle of the check's long stroke, (W − 11, 7) of a row, and
        // the card in the label's 30 pt trailing inset beside the check.
        func check(cardTop: CGFloat, row: Int) throws -> (mark: NSColor, card: NSColor) {
            let rowTop = cardTop + section.itemOffset + CGFloat(row) * section.rowHeight
            return (try color(inset + width - 11, rowTop + 7), try color(inset + width - 24, rowTop + 7))
        }
        func dot(cardTop: CGFloat) throws -> (mark: NSColor, card: NSColor) {
            let center = cardTop + section.top + section.dotTop + section.dotSize / 2
            return (try color(inset + width - 12, center), try color(inset + width - 40, center))
        }
        for (cardTop, selected, rows) in [(batteryTop, 1, 3), (adapterTop, 0, 3)] {
            for row in 0..<rows {
                let sample = try check(cardTop: cardTop, row: row)
                if row == selected {
                    XCTAssertGreaterThan(distance(sample.mark, sample.card), 0.3, "check at \(cardTop) row \(row)")
                } else {
                    XCTAssertLessThan(distance(sample.mark, sample.card), 0.03, "no check at \(cardTop) row \(row)")
                }
            }
        }
        // D149: one row of five equal segments under the label, 8 in from
        // the card's sides with 1 pt between them; only the manual limit's
        // (85 %) is filled. Each is sampled 4 in from its top-left corner,
        // clear of the border and the label.
        let segmentsTop = chargeTop + section.itemOffset
        let segmentWidth = (width - 2 * section.leading - 4) / 5
        let chargeCard = try color(inset + width - 24, chargeTop + section.top + 7)
        for index in 0..<5 {
            let left = inset + section.leading + CGFloat(index) * (segmentWidth + 1)
            let fill = try color(left + 4, segmentsTop + 4)
            if index == 1 {
                XCTAssertGreaterThan(distance(fill, chargeCard), 0.3, "the manual limit's segment is filled")
            } else {
                XCTAssertLessThan(distance(fill, chargeCard), 0.03, "segment \(index) is not filled")
            }
        }
        // The full-charge and settings rows, after the 20 + 2 segment row,
        // are actions without a check.
        for rowTop in [segmentsTop + 22, segmentsTop + 22 + section.rowHeight] {
            let mark = try color(inset + width - 11, rowTop + 7)
            let card = try color(inset + width - 24, rowTop + 7)
            XCTAssertLessThan(distance(mark, card), 0.03, "action row at \(rowTop)")
        }
        let adapterDot = try dot(cardTop: adapterTop)
        XCTAssertGreaterThan(distance(adapterDot.mark, adapterDot.card), 0.15, "on AC power")
        let batteryDot = try dot(cardTop: batteryTop)
        XCTAssertLessThan(distance(batteryDot.mark, batteryDot.card), 0.03, "not the current source")
        let chargeDot = try dot(cardTop: chargeTop)
        XCTAssertLessThan(distance(chargeDot.mark, chargeDot.card), 0.03, "the charge limit has no source")
    }

    /// The switch's knob is at the trailing end when on, the leading end
    /// when off, on the 26 × 14 track at W − 34 of its row.
    func testTheSwitchMovesItsKnobWithTheState() throws {
        for isOn in [false, true] {
            let row = GeekIStatTextSectionCard {
                GeekIStatMajorLabelRow(title: "Mac mini") { GeekIStatSwitch(isOn: isOn) }
            }
            let bitmap = try Self.render(row, mode: .black)
            XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2,
                           GeekIStatTextSectionGeometry.height(labelRows: 1, tickRows: 0)
                               + 2 * GeekPanelLayout.contentPadding, accuracy: 0.5)
            let inset = GeekPanelLayout.contentPadding
            let track = inset + Self.cardWidth - GeekIStatTextSectionGeometry.toggleTrailing
            let center = inset + GeekIStatTextSectionGeometry.top + GeekIStatTextSectionGeometry.rowHeight / 2
            let knob = GeekIStatTextSectionGeometry.toggleKnobSize / 2
            let width = GeekIStatTextSectionGeometry.toggleTrackSize.width
            func brightness(_ x: CGFloat) throws -> CGFloat {
                let color = try XCTUnwrap(bitmap.colorAt(x: Int(x * 2), y: Int(center * 2))?.usingColorSpace(.sRGB))
                return (color.redComponent + color.greenComponent + color.blueComponent) / 3
            }
            let leading = try brightness(track + knob)
            let trailing = try brightness(track + width - knob)
            if isOn {
                XCTAssertGreaterThan(trailing - leading, 0.15, "on: the knob is at the trailing end")
            } else {
                XCTAssertGreaterThan(leading - trailing, 0.15, "off: the knob is at the leading end")
            }
        }
    }

    func testTheRowsKeepTheirAccessibilityContract() throws {
        let sections = try Self.source("Views/MenuBarAdvanced/GeekIStatTextSection.swift")
        let tick = try XCTUnwrap(sections.components(separatedBy: "struct GeekIStatTickRow: View {")
            .dropFirst().first?.components(separatedBy: "\n}\n").first)
        XCTAssertTrue(tick.contains("Button(action: action)"), "a row is one native button")
        XCTAssertTrue(tick.contains("L10n.text(\"已选择\", \"Selected\")"))
        XCTAssertTrue(tick.contains("L10n.text(\"未选择\", \"Not Selected\")"))
        XCTAssertTrue(tick.contains(".accessibilityAddTraits(showsCheck && isSelected ? [.isSelected] : [])"))
        let toggle = try XCTUnwrap(sections.components(separatedBy: "struct GeekIStatSwitchToggleStyle: ToggleStyle {")
            .dropFirst().first?.components(separatedBy: "\n}\n").first)
        XCTAssertTrue(toggle.contains(".accessibilityAddTraits(.isToggle)"))
        let power = try Self.source("Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift")
        XCTAssertTrue(power.contains(".accessibilityIdentifier(\"charge-limit-targets\")"))
        let mini = try Self.source("Views/MenuBarAdvanced/MacMiniModeControls.swift")
        XCTAssertTrue(mini.contains(".toggleStyle(GeekIStatSwitchToggleStyle())"))
        XCTAssertTrue(mini.contains(".accessibilityIdentifier(\"mac-mini-mode-toggle\")"))
    }

    // MARK: - Helpers

    /// On AC power, the battery on Low Power and the adapter on Automatic.
    private static func page(batteryModes: [BatteryPowerMode],
                             chargeLimit: BatteryChargeLimitState? = nil) -> GeekEnergyModeHoverDetail {
        GeekEnergyModeHoverDetail(
            batteryMode: .lowPower, batterySupportedModes: batteryModes,
            adapterMode: .automatic, adapterSupportedModes: [.automatic, .lowPower, .highPower],
            powerSource: .acPower, isCharging: false,
            showsChargeTargetSetting: chargeLimit != nil, showsFullChargeAction: true,
            chargeLimitState: chargeLimit, batteryPowerWatts: nil, adapterPowerWatts: nil,
            adjustmentState: .idle,
            onChargeToFull: { XCTFail("A render must never write"); return .accepted },
            onSetChargeTarget: { _ in XCTFail("A render must never write"); return .applied },
            onOpenBatterySettings: { XCTFail("A render must never open settings") },
            onChangeMode: { _, _ in XCTFail("A render must never write") }
        )
    }

    /// A manual limit, the targets macOS offers (80–100 % in steps of 5).
    private static func manualLimit(effective: Int) -> BatteryChargeLimitState {
        let targets = stride(from: 80, through: 100, by: 5).compactMap(BatteryChargeTarget.init(rawValue:))
        return BatteryChargeLimitState(target: BatteryChargeTarget(rawValue: effective) ?? .protected,
                                       availableTargets: targets, effectiveLimit: effective, source: .manual)
    }

    private static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/\(path)"), encoding: .utf8)
    }

    /// As a plain level-three page: the content on the card width, padded
    /// by the page's 8 pt.
    private static func render<Content: View>(_ page: Content, mode: MiniWindowVisualMode) throws -> NSBitmapImageRep {
        let content = page
            .frame(width: cardWidth, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.miniWindowPageProvidesInset, true)
            .padding(GeekPanelLayout.contentPadding)
            .metricPanelShell()
            .environment(\.miniWindowPreviewDate, MiniWindowDemoData.referenceDate)
            .modifier(PanelAppearanceEnvironment(forcedVisualMode: mode))
            .environment(\.displayScale, 2)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    /// Night is black, day is graphite (D44, D56).
    private static func export(name: String, night: NSBitmapImageRep, page: GeekEnergyModeHoverDetail) throws {
        guard let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_ISTAT_LAYOUT_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (bitmap, suffix) in [(night, "night"), (try render(page, mode: .graphite), "day")] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}

#endif
