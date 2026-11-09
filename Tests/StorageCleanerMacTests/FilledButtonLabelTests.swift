import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D281 (D276 ②): the label on a filled button, the round main button at the
/// bottom of a page and a lightfield page's primary, is white or the day ink
/// #171221, whichever reads better on its fill. User 11-05: "换字色" (green,
/// teal and orange fills). The fill is the same by day and at night (D141), so
/// is the label.
@MainActor
final class FilledButtonLabelTests: XCTestCase {
    func testTheDayInkLabelsOnlyTheFillsWhereWhiteReadsWorse() {
        var inked: [CareStudioFamily] = []
        for family in CareStudioFamily.allCases {
            let fill = family.palette.buttonFill
            let white = worst(0xFFFFFF, on: fill), ink = worst(0x171221, on: fill)
            let label = CareStudioPalette.fillLabel(fill)
            XCTAssertEqual(hex(label), ink > white ? "171221" : "FFFFFF", "\(family) white \(white) ink \(ink)")
            if label == 0x171221 {
                inked.append(family)
                XCTAssertLessThan(white, 3.4, "\(family)")
                XCTAssertGreaterThanOrEqual(ink, 4.39, "\(family)")
            } else {
                XCTAssertGreaterThanOrEqual(white, 4.0, "\(family)")
                XCTAssertLessThan(ink, 3.8, "\(family)")
            }
        }
        XCTAssertEqual(inked, [.cleanup, .performance, .clutter, .cloudCleanup])
        // D281 记过：橙和青到 4.5；绿和云盘蓝只到 4.40、4.45（白字 3.34、3.26）。
        XCTAssertGreaterThanOrEqual(worst(0x171221, on: CareStudioFamily.performance.palette.action), 4.5)
        XCTAssertGreaterThanOrEqual(worst(0x171221, on: CareStudioFamily.clutter.palette.action), 4.5)
        XCTAssertEqual(worst(0x171221, on: CareStudioFamily.cleanup.palette.action), 4.40, accuracy: 0.01)
        XCTAssertEqual(worst(0x171221, on: CareStudioFamily.cloudCleanup.palette.action), 4.45, accuracy: 0.01)
    }

    func testTheDayInkIsTheDayPrimaryAndTheLabelIsTheSameInBothAppearances() {
        XCTAssertEqual(hex(CareStudioInk.dayHex), "171221")
        XCTAssertEqual(hex(packed(resolve(CareStudioInk.primary, .light))), "171221")
        for family in CareStudioFamily.allCases {
            let expected = hex(CareStudioPalette.fillLabel(family.palette.buttonFill))
            for scheme in [ColorScheme.light, .dark] {
                XCTAssertEqual(hex(packed(resolve(CareStudioInk.fillLabel(family.palette.buttonFill), scheme))), expected,
                               "\(family) \(scheme)")
            }
        }
    }

    /// A lightfield page's primary takes its accent pair: the cleanup result's own
    /// orange takes the ink, the overview's blue keeps white, and a page without a
    /// pair (the utility hub) keeps white.
    func testTheLightfieldPrimaryLabelFollowsItsAccentPair() {
        let expected: [(ReviewFilter, String)] = [
            (.green, "171221"), (.overview, "FFFFFF"), (.utilityHub, "FFFFFF"),
            (.startup, "171221"), (.duplicates, "171221"), (.devCaches, "171221"), (.cloudCleanup, "171221"),
            (.updater, "FFFFFF"), (.performance, "FFFFFF"), (.energy, "FFFFFF"), (.healthHub, "FFFFFF"),
            (.privacy, "FFFFFF"), (.largeFiles, "FFFFFF"), (.myActivity, "FFFFFF"),
        ]
        for (module, label) in expected {
            for scheme in [ColorScheme.light, .dark] {
                XCTAssertEqual(hex(packed(resolve(FeatureLightfieldPalette.fillLabel(module), scheme))), label, "\(module) \(scheme)")
            }
        }
        XCTAssertLessThan(worst(0xFFFFFF, on: [0xFF7A2F, 0xC4441A]), 3.3)
        XCTAssertGreaterThanOrEqual(worst(0x171221, on: [0xFF7A2F, 0xC4441A]), 4.5)
    }

    func testBothFilledButtonsDrawTheirLabelInTheFillLabel() throws {
        let button = try source("Views/CareStudio/CareStudioActionButton.swift")
        let label = try XCTUnwrap(button.components(separatedBy: "private var label: some View {").dropFirst().first)
            .components(separatedBy: "\n    }\n").first ?? ""
        // D282：原为 module.palette.action。
        XCTAssertTrue(label.contains(".foregroundStyle(CareStudioInk.fillLabel(module.palette.buttonFill))"), label)
        XCTAssertFalse(label.contains(".foregroundStyle(.white)"))

        let lightfield = try source("Views/DesignSystem/FeatureLightfield.swift")
        let style = try XCTUnwrap(lightfield.components(separatedBy: "struct FeatureLightfieldButtonStyle: ButtonStyle {").dropFirst().first)
            .components(separatedBy: "\n}\n").first ?? ""
        XCTAssertTrue(style.contains(".foregroundStyle(isCancel ? FeatureLightfieldPalette.resolve(scheme).fg : FeatureLightfieldPalette.fillLabel(module))"))
        XCTAssertFalse(style.contains(": .white)"))
    }

    /// D282 (user 11-06 "调深这两种"): applications blue and my-tools purple fill their
    /// labelled buttons a little deeper, their `action` pair under black 29/255 and 8/255:
    /// the smallest step where white reads 4.55:1 (4.5 and a margin) with each button's
    /// light. D281 measured white at 4.10:1 on the applications round button and 4.43:1 on
    /// the my-tools primary. Every other module fills with its `action`.
    func testApplicationsAndMyToolsFillTheirLabelledButtonsDeeper() {
        let deeper: [CareStudioFamily: (fill: [UInt32], black: Double)] = [
            .applications: ([0x387CE2, 0x134AB1], 29), .myTools: ([0x796ED1, 0x4D43A3], 8),
        ]
        for family in CareStudioFamily.allCases {
            let palette = family.palette
            XCTAssertEqual(palette.daylight.buttonFill, palette.buttonFill, "\(family)")
            guard let entry = deeper[family] else {
                XCTAssertEqual(palette.buttonFill, palette.action, "\(family)")
                continue
            }
            XCTAssertEqual(palette.buttonFill.map(hex), entry.fill.map(hex), "\(family)")
            XCTAssertEqual(palette.action.map { hex(blend(0x000000, entry.black / 255, over: $0)) }, entry.fill.map(hex), "\(family)")
            XCTAssertGreaterThanOrEqual(roundWorst(entry.fill), 4.55, "\(family)")
            XCTAssertGreaterThanOrEqual(primaryWorst(entry.fill), 4.55, "\(family)")
            let lighter = palette.action.map { blend(0x000000, (entry.black - 1) / 255, over: $0) }
            XCTAssertLessThan(min(roundWorst(lighter), primaryWorst(lighter)), 4.55, "\(family) one step less")
            XCTAssertLessThan(primaryWorst(palette.action), 4.5, "\(family) before D282")
        }
        // D282 记过（模型）：应用蓝圆钮 4.06→4.86、主按钮 3.77→4.55；我的工具紫圆钮 4.69→4.92、主按钮 4.39→4.61。
        XCTAssertEqual(roundWorst(CareStudioFamily.applications.palette.action), 4.06, accuracy: 0.01)
        XCTAssertEqual(primaryWorst(CareStudioFamily.myTools.palette.action), 4.39, accuracy: 0.01)
    }

    /// D282: a lightfield primary fills with its module's `buttonFill` where its accent
    /// pair is the module's `action`; its checks, charts and links keep the accent.
    func testTheLightfieldPrimaryFillsWithTheModuleButtonFill() {
        let apps = CareStudioFamily.applications.palette.buttonFill, tools = CareStudioFamily.myTools.palette.buttonFill
        let deeper: [ReviewFilter: [UInt32]] = [
            .uninstall: apps, .updater: apps, .extensions: apps,
            .healthHub: tools, .performance: tools, .energy: tools, .migration: tools, .myTools: tools,
        ]
        for module in ReviewFilter.allCases {
            XCTAssertEqual(FeatureLightfieldPalette.fills(module), deeper[module] ?? FeatureLightfieldPalette.accents(module), "\(module)")
        }
        for module in deeper.keys {
            XCTAssertEqual(FeatureLightfieldPalette.accents(module), CareStudioFamily(route: module).palette.action, "\(module)")
        }
        XCTAssertEqual(FeatureLightfieldPalette.fills(.overview), [0x4F8BFF, 0x2A55D6])
        XCTAssertEqual(FeatureLightfieldPalette.fills(.green), [0xFF7A2F, 0xC4441A])
        XCTAssertNil(FeatureLightfieldPalette.fills(.utilityHub))
    }

    func testBothFilledButtonsFillFromTheirButtonFill() throws {
        let button = try source("Views/CareStudio/CareStudioActionButton.swift")
        let roundStyle = try XCTUnwrap(button.components(separatedBy: "private struct CareStudioActionButtonStyle: ButtonStyle {").dropFirst().first)
            .components(separatedBy: "\n}\n").first ?? ""
        XCTAssertTrue(roundStyle.contains("CareStudioPalette.color(palette.buttonFill[0])"), roundStyle)
        XCTAssertTrue(roundStyle.contains("CareStudioPalette.color(palette.buttonFill[1])"), roundStyle)
        XCTAssertFalse(roundStyle.contains("palette.action["), roundStyle)

        let lightfield = try source("Views/DesignSystem/FeatureLightfield.swift")
        let style = try XCTUnwrap(lightfield.components(separatedBy: "struct FeatureLightfieldButtonStyle: ButtonStyle {").dropFirst().first)
            .components(separatedBy: "\n}\n").first ?? ""
        XCTAssertTrue(style.contains("let fill = FeatureLightfieldPalette.fills(module)"), style)
        XCTAssertTrue(style.contains("shape.fill(LinearGradient(stops: [.init(color: fill[0], location: 0),"), style)
        XCTAssertTrue(style.contains(".init(color: fill[1], location: 1)]"), style)
        XCTAssertTrue(style.contains("let rim = isCancel ? accent : fill[0]"), style)
        XCTAssertFalse(style.contains(".init(color: accent, location: 0)"), style)
    }

    // MARK: - Helpers

    /// The label's rows, t 0.35–0.65 of a fill drawn top to bottom.
    private func worst(_ label: UInt32, on fill: [UInt32]) -> Double {
        (0...6).map { blend(fill[1], 0.35 + Double($0) * 0.05, over: fill[0]) }.map { contrast(label, $0) }.min() ?? 0
    }

    /// D282: white on the round button with its light, as calibrated on the D281 window
    /// measurements: the 30% top light fades by the centre of the circle inset 3 of 84 pt,
    /// and the label's worst row sits at t 0.42.
    private func roundWorst(_ fill: [UInt32]) -> Double {
        (42...65).map { row -> Double in
            let t = Double(row) / 100, base = blend(fill[1], t, over: fill[0]), y = t * 84
            guard y >= 3, y <= 42 else { return contrast(0xFFFFFF, base) }
            return contrast(0xFFFFFF, blend(0xFFFFFF, 0.30 * (1 - (y - 3) / 39), over: base))
        }.min() ?? 0
    }

    /// D282: white on a lightfield primary with its 8% light, which fades by the bottom;
    /// the label's worst row sits at t 0.32.
    private func primaryWorst(_ fill: [UInt32]) -> Double {
        (32...65).map { row -> Double in
            let t = Double(row) / 100
            return contrast(0xFFFFFF, blend(0xFFFFFF, 0.08 * (1 - t), over: blend(fill[1], t, over: fill[0])))
        }.min() ?? 0
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

    private func packed(_ resolved: Color.Resolved) -> UInt32 {
        [resolved.red, resolved.green, resolved.blue].reduce(UInt32(0)) { $0 << 8 | UInt32((Double($1) * 255).rounded()) }
    }

    private func resolve(_ color: Color, _ scheme: ColorScheme) -> Color.Resolved {
        var environment = EnvironmentValues(); environment.colorScheme = scheme
        return color.resolve(in: environment)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/\(path)"), encoding: .utf8)
    }
}
