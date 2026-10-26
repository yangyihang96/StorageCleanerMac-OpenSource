import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Native rendering of display-only primitives, independent of live monitoring
/// and the original 49-item visual acceptance ledger.
@MainActor
final class MiniWindowIconConsistencyTests: XCTestCase {
    private let symbols = [AppSymbols.Monitor.processor, AppSymbols.Monitor.memory,
                           AppSymbols.Monitor.storage, AppSymbols.Monitor.network,
                           AppSymbols.Monitor.sensors, AppSymbols.Monitor.battery]
    private let iconColor = Color(red: 1, green: 0, blue: 1)
    private let textColor = Color(red: 0, green: 1, blue: 0)

    func testNativeModuleGlyphsFitEqualCenteredSlotsAtBothDisplayScales() throws {
        for scale: CGFloat in [1, 2] {
            for symbol in symbols {
                let bitmap = try render(GeekModuleIcon(systemImage: symbol, tint: iconColor), scale: scale)
                XCTAssertEqual(CGFloat(bitmap.pixelsWide) / scale, 16, accuracy: 0.01)
                XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / scale, 16, accuracy: 0.01)
                let ink = try coloredBounds(bitmap, red: true, green: false)
                XCTAssertLessThanOrEqual(ink.width / scale, 12 + 1 / scale)
                XCTAssertLessThanOrEqual(ink.height / scale, 12 + 1 / scale)
                XCTAssertGreaterThanOrEqual(max(ink.width, ink.height) / scale, 10.5,
                    "A wide or tall symbol must not become a tiny font-advance glyph: \(symbol)")
                XCTAssertEqual(ink.midX / scale, 8, accuracy: 1)
                XCTAssertEqual(ink.midY / scale, 8, accuracy: 1)
            }
        }
    }

    func testNativeHeadersKeepIconAndTitleWithinStableHeightAndSixPointGap() throws {
        let titles = ["CPU", "内存", "Macintosh HD", "Network", "传感器", "Battery"]
        for (symbol, title) in zip(symbols, titles) {
            let header = GeekModuleLabel(systemImage: symbol, tint: iconColor) {
                Text(title).foregroundStyle(textColor)
            }
            .font(AdvancedPanelTypography.header)
            .frame(width: 180, height: 20, alignment: .leading)
            let bitmap = try render(header, scale: 2)
            let icon = try coloredBounds(bitmap, red: true, green: false)
            let text = try coloredBounds(bitmap, red: false, green: true)
            XCTAssertEqual(icon.midY / 2, 10, accuracy: 1)
            XCTAssertGreaterThanOrEqual(text.minX / 2, 22 - 0.5,
                "The 16-point icon slot and 6-point gap must precede every title")
            XCTAssertLessThanOrEqual(text.minX / 2, 24,
                "Font side bearings must not turn the shared gap into extra padding")
            XCTAssertGreaterThanOrEqual(text.minY, 0)
            XCTAssertLessThanOrEqual(text.maxY, 40)
            XCTAssertLessThanOrEqual(text.maxX, 360)
            XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, 20, accuracy: 0.01)
        }
    }

    func testNativeProcessFallbacksKeepSixteenPointLayoutWithoutScaledParent() throws {
        for fallback in ["app.fill", "gearshape.2", "terminal", AppSymbols.Monitor.network,
                         AppSymbols.Monitor.power] {
            let icon = GeekSecondaryProcessIcon(path: "", fallback: fallback)
            let bitmap = try render(icon, scale: 2)
            XCTAssertEqual(bitmap.pixelsWide, 32)
            XCTAssertEqual(bitmap.pixelsHigh, 32)
            // An empty icon path never schedules a decoder request. The native
            // fallback remains a real, visible symbol inside the same row slot.
            let visible = try neutralBounds(bitmap)
            XCTAssertGreaterThan(visible.width, 0)
            XCTAssertGreaterThan(visible.height, 0)
            XCTAssertLessThanOrEqual(visible.maxX, 32)
            XCTAssertLessThanOrEqual(visible.maxY, 32)
        }
    }

    func testAllProcessTablesUseSharedCacheAndOverviewHeadersStayDisplayOnly() throws {
        let base = "Sources/StorageCleanerMac/Views/MenuBarAdvanced/"
        for file in ["GeekProcessorView.swift", "GeekMemoryView.swift", "GeekPowerView.swift",
                     "GeekDiskView.swift", "GeekNetworkView.swift"] {
            let content = try source(base + file)
            // D119: a page built on iStat's shared process row draws the
            // cached icon through it (`GeekIStatProcessRow`, checked below).
            XCTAssertTrue(content.contains("GeekSecondaryProcessIcon(path:")
                || content.contains("GeekIStatProcessRow(iconPath:"), file)
            XCTAssertFalse(content.contains(".scaleEffect(0.62)"), file)
            XCTAssertFalse(content.contains("AdvancedAppIcon(path:"), file)
        }
        let sections = try source(base + "GeekIStatSections.swift")
        let istatRow = try XCTUnwrap(sections.components(separatedBy: "struct GeekIStatProcessRow<Values: View>: View {").last)
            .components(separatedBy: "struct GeekIStatProcessPlaceholder")[0]
        XCTAssertTrue(istatRow.contains("GeekSecondaryProcessIcon(path: iconPath"))
        let components = try source(base + "GeekPanelComponents.swift")
        let processIcon = try XCTUnwrap(components.components(separatedBy: "struct GeekSecondaryProcessIcon: View {").last)
            .components(separatedBy: "enum GeekPanelLayout")[0]
        XCTAssertTrue(processIcon.contains("CachedAppIconView(path: path, size: MiniWindowStyleTokens.processIconSize)"))
        XCTAssertFalse(processIcon.contains("scaleEffect"))
        XCTAssertFalse(processIcon.contains("FileManager"))
        let overview = try source(base + "GeekOverviewPresentation.swift")
        XCTAssertFalse(overview.contains("Image(systemName:"), "Module labels must use the shared glyph slot")
        for forbidden in [".task", ".onAppear", "MetricHistoryStore", "SystemMonitorService", "NSWorkspace"] {
            XCTAssertFalse(overview.contains(forbidden), "Presentation previews cannot gain monitoring effects")
        }
    }

    private func render<Content: View>(_ content: Content, scale: CGFloat) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, .dark)
            .environment(\.displayScale, scale).background(Color.black))
        renderer.scale = scale
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func coloredBounds(_ bitmap: NSBitmapImageRep, red: Bool, green: Bool) throws -> CGRect {
        try bounds(bitmap) { color in
            if red { return color.redComponent > 0.5 && color.blueComponent > 0.5 && color.greenComponent < 0.2 }
            if green { return color.greenComponent > 0.5 && color.redComponent < 0.2 && color.blueComponent < 0.2 }
            return false
        }
    }

    private func neutralBounds(_ bitmap: NSBitmapImageRep) throws -> CGRect {
        try bounds(bitmap) { color in
            min(color.redComponent, color.greenComponent, color.blueComponent) > 0.15
        }
    }

    private func bounds(_ bitmap: NSBitmapImageRep, predicate: (NSColor) -> Bool) throws -> CGRect {
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.8, predicate(color) else { continue }
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, minX, "A visible native glyph must be present")
        XCTAssertGreaterThanOrEqual(maxY, minY, "A visible native glyph must be present")
        guard maxX >= minX, maxY >= minY else { throw NSError(domain: "MiniIconRendering", code: 1) }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
