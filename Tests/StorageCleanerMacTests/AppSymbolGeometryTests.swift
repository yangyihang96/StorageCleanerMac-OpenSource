import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Native component evidence; independent of installed-window acceptance.
@MainActor
final class AppSymbolGeometryTests: XCTestCase {
    func testNavigationSymbolsShareSlotsAndRemainCentredAtBothScales() throws {
        let symbols = Set(ReviewFilter.allCases.map(\.systemImage)
            + [AppSymbols.Action.settings, "folder.fill", "trash", "hammer", "bolt.fill", "square.fill"])
        for scale: CGFloat in [1, 2] {
            for symbol in symbols.sorted() {
                let bitmap = try render(AppSymbolIcon(systemImage: symbol, role: .sidebar,
                    tint: .white, isDecorative: true), scale: scale)
                let bounds = try inkBounds(bitmap, scale: scale)
                XCTAssertEqual(CGFloat(bitmap.pixelsWide) / scale, 18, accuracy: 0.01)
                XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / scale, 18, accuracy: 0.01)
                XCTAssertLessThanOrEqual(bounds.width, 16 + 1 / scale, symbol)
                XCTAssertLessThanOrEqual(bounds.height, 16 + 1 / scale, symbol)
                // SF Symbols include designed transparent margins. Keep them;
                // the complete visible glyph must stay in the shared 16 pt slot.
                XCTAssertGreaterThanOrEqual(bounds.minX, 1 - 1 / scale, symbol)
                XCTAssertGreaterThanOrEqual(bounds.minY, 1 - 1 / scale, symbol)
                XCTAssertLessThanOrEqual(bounds.maxX, 17 + 1 / scale, symbol)
                XCTAssertLessThanOrEqual(bounds.maxY, 17 + 1 / scale, symbol)
                if symbol == "square.fill" {
                    XCTAssertEqual(max(bounds.width, bounds.height), 16, accuracy: 1 / scale)
                }
                XCTAssertEqual(bounds.midX, 9, accuracy: 1 / scale, symbol)
                XCTAssertEqual(bounds.midY, 9, accuracy: 1 / scale, symbol)
            }
        }
    }

    func testSymbolAspectRatioIsPreservedAndInteractionSlotDoesNotShrink() throws {
        for symbol in ["folder.fill", "trash", "bolt.fill"] {
            // Independent native text-sized rendering: the image canvas ratio
            // includes transparent margins and cannot be compared with ink.
            let referenceScale: CGFloat = 16
            let reference = try render(Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular)).foregroundStyle(.white), scale: referenceScale)
            let referenceInk = try inkBounds(reference, scale: referenceScale)
            let bitmap = try render(AppSymbolIcon(systemImage: symbol, role: .toolbar,
                tint: .white), scale: 2)
            let bounds = try inkBounds(bitmap, scale: 2)
            XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, AppControlSizes.iconHitRegion)
            XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, AppControlSizes.iconHitRegion)
            // Aspect fit must not stretch a narrow or wide symbol into a square.
            let ratio = referenceInk.width / referenceInk.height
            let targetPixel: CGFloat = 0.5
            let referencePixel: CGFloat = 1 / referenceScale
            let measurementBudget = (targetPixel + referencePixel) * (1 + ratio)
            XCTAssertLessThanOrEqual(abs(bounds.width - ratio * bounds.height), measurementBudget,
                "Aspect fit must preserve the independent native ink ratio: " + symbol)
        }
    }

    func testExplicitUtilityGlyphSizesAreHonouredWithinSafeInsets() throws {
        for (slot, requested) in [(CGFloat(36), CGFloat(22)), (32, 18), (40, 22)] {
            XCTAssertEqual(AppSymbolGeometry.tileGlyphSize(requested: requested, slot: slot), requested)
            let bitmap = try render(ArtworkIconTile(systemImage: "square.fill", tint: .white,
                size: slot, glyphSize: requested), scale: 2)
            let bounds = try inkBounds(bitmap, scale: 2)
            XCTAssertEqual(bounds.width, requested, accuracy: 0.5)
            XCTAssertEqual(bounds.height, requested, accuracy: 0.5)
            XCTAssertEqual(bounds.midX, slot / 2, accuracy: 0.5)
            XCTAssertEqual(bounds.midY, slot / 2, accuracy: 0.5)
        }
        XCTAssertEqual(AppSymbolGeometry.tileGlyphSize(requested: 100, slot: 36), 28)
        XCTAssertEqual(AppSymbolGeometry.tileGlyphSize(requested: .infinity, slot: 36), 36 * 0.48)
        XCTAssertEqual(AppSymbolGeometry.tileGlyphSize(requested: 22, slot: .nan), 0)
    }

    func testSettingsNavigationUsesSameVisibleGlyphWithoutChangingItsSlot() throws {
        for symbol in ["gearshape.fill", "network", "paintbrush", "info.circle"] {
            let main = try render(AppSymbolIcon(systemImage: symbol, role: .sidebar,
                tint: .white), scale: 2)
            let settings = try render(AppSymbolIcon(systemImage: symbol, role: .settingsNavigation,
                tint: .white), scale: 2)
            let a = try inkBounds(main, scale: 2), b = try inkBounds(settings, scale: 2)
            XCTAssertEqual(a.size, b.size)
            XCTAssertEqual(b.midX - a.midX, 2, accuracy: 0.5)
            XCTAssertEqual(b.midY - a.midY, 2, accuracy: 0.5)
            XCTAssertEqual(settings.pixelsWide, 44)
            XCTAssertEqual(settings.pixelsHigh, 44)
        }
    }

    func testExportsPureIconSheetWithoutStartingApplicationServices() throws {
        guard let directory = ProcessInfo.processInfo.environment["STORAGE_CLEANER_ICON_EVIDENCE"] else { return }
        let url = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for dark in [false, true] {
            for scale: CGFloat in [1, 2] {
                let sheet = VStack(alignment: .leading, spacing: 8) {
                    ForEach(ReviewFilter.allCases, id: \.self) { filter in
                        HStack(spacing: 8) {
                            AppSymbolIcon(systemImage: filter.systemImage, role: .sidebar,
                                tint: dark ? .white : .black, isDecorative: true)
                            Text(filter.rawValue).font(.system(size: 12))
                        }
                    }
                }.padding(12).environment(\.colorScheme, dark ? .dark : .light)
                    .foregroundStyle(dark ? Color.white : Color.black)
                    .background(dark ? Color.black : Color.white)
                let bitmap = try render(sheet, scale: scale)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent("navigation-\(dark ? "dark" : "light")-\(Int(scale))x.png"))
            }
        }
    }

    private func render<Content: View>(_ content: Content, scale: CGFloat) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: content.environment(\.displayScale, scale))
        renderer.scale = scale
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func inkBounds(_ bitmap: NSBitmapImageRep, scale: CGFloat) throws -> CGRect {
        var xs: [Int] = [], ys: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                xs.append(x); ys.append(y)
            }
        }
        let minX = try XCTUnwrap(xs.min()), maxX = try XCTUnwrap(xs.max())
        let minY = try XCTUnwrap(ys.min()), maxY = try XCTUnwrap(ys.max())
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}
