import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D118: the level-one panel follows the iStat Menus 7.30 combined menu as
/// measured on the 2026-10-07 capture (`round2/istat/istat-real-combined.jpg`,
/// 2x) and the static reverse-engineering report. Renders the Settings sample
/// cards only: no Store, sampling, window or user data.
@MainActor
final class MiniWindowIStatLayoutTests: XCTestCase {
    private let overviewModules: [GeekDashboardModule] = [
        .processorGraphics, .coreMetrics, .disk, .network, .sensors, .power,
    ]

    func testRenderedOverviewForSideBySideReview() throws {
        // Night is black, day is graphite (D44, D56); both are dark panels.
        // D135: a fixture render pins iStat's default theme (indigo) in both
        // slots; the themes' own renders are in the next test.
        for mode in [MiniWindowVisualMode.black, .graphite] {
            let bitmap = try render(overview(), mode: mode)
            XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, MiniWindowStyleTokens.overviewSize.width, accuracy: 0.5)
            try export(bitmap, name: "overview-\(mode == .black ? "night" : "day")")
        }
    }

    /// D135 (R9a): the overview in iStat's themes, for review beside iStat
    /// (`overview-theme-<id>.png`). The surface between the edge and the
    /// cards is the theme's own, as a plain fill of that color draws it. A
    /// transparent theme's material does not render offscreen, so its image
    /// shows the clear surface only.
    func testRenderedOverviewInIStatsThemesForReview() throws {
        for id in ["indigo", "dark", "light", "navy", "purple", "blue-dark", "vibrant-dark"] {
            let theme = try XCTUnwrap(IStatMenuTheme.theme(id: id), id)
            let mode: MiniWindowVisualMode = theme.isLight ? .graphite : .black
            let bitmap = try render(overview(), mode: mode, themeID: id)
            XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, MiniWindowStyleTokens.overviewSize.width, accuracy: 0.5, id)
            if !theme.vibrantMenu {
                // 4 pt in from the left edge: between the edge and the cards.
                let pixel = try XCTUnwrap(bitmap.colorAt(x: 8, y: bitmap.pixelsHigh / 2), id)
                let swatch = try render(theme.surface.color.frame(width: 4, height: 4), mode: mode, themeID: id)
                let expected = try XCTUnwrap(swatch.colorAt(x: 4, y: 4), id)
                for (actual, wanted) in zip(
                    [pixel.redComponent, pixel.greenComponent, pixel.blueComponent, pixel.alphaComponent],
                    [expected.redComponent, expected.greenComponent, expected.blueComponent, expected.alphaComponent]
                ) {
                    XCTAssertEqual(actual, wanted, accuracy: 0.005, id)
                }
            }
            try export(bitmap, name: "overview-theme-\(id)")
        }
    }

    private func overview() -> some View {
        GeekOverviewPanel(modules: overviewModules) { module in
            MiniWindowConfigurationPreviewCard(module: module)
        }
        .metricPanelShell()
        .environment(\.controlPaletteCoordinator, nil)
        .environment(\.miniWindowPreviewDate, MiniWindowConfigurationPreviewCard.history.last?.date)
    }

    private func render<Content: View>(_ content: Content, mode: MiniWindowVisualMode,
                                       themeID: String? = nil) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: content
            .modifier(PanelAppearanceEnvironment(forcedVisualMode: mode, forcedThemeID: themeID))
            .environment(\.displayScale, 2))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func export(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_ISTAT_LAYOUT_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
    }
}
