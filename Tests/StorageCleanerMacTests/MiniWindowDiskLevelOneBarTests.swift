import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Decision D14 (2026-10-04): the level-one disk card's bar shows the used
/// share, like the level-two ring and the level-three chart, and its text is
/// the level-two summary "44% 已用 · 560 GB 可用". It replaces the earlier
/// decision that the bar showed the available share.
@MainActor
final class MiniWindowDiskLevelOneBarTests: XCTestCase {
    private let gigabyte: Int64 = 1_000_000_000
    private let scale: CGFloat = 2
    private var cardWidth: CGFloat { MiniWindowStyleTokens.overviewSize.width - 2 * MiniWindowStyleTokens.contentInset }
    private var barWidth: CGFloat { cardWidth - 2 * GeekVisualTokens.cardHorizontalPadding }

    func testBarFillIsTheUsedShare() throws {
        // 44 % used, 56 % available: the two meanings give different widths.
        for (used, total) in [(440, 1_000), (50, 1_000), (790, 1_000)] as [(Int64, Int64)] {
            let snapshot = StorageCapacitySnapshot(totalBytes: total * gigabyte, availableBytes: (total - used) * gigabyte)
            XCTAssertEqual(snapshot.pressure, .normal)
            let fill = try fillBounds(of: snapshot, matching: { $0.red > 0.8 && $0.green < 0.3 && $0.blue > 0.8 })
            let expected = barWidth * CGFloat(used) / CGFloat(total)
            XCTAssertEqual(fill.width, expected, accuracy: 1.5,
                           "\(used)/\(total) GB used: the bar must fill the used share (\(expected) pt of \(barWidth) pt)")
            XCTAssertEqual(fill.minX, GeekVisualTokens.cardHorizontalPadding, accuracy: 1,
                           "the used share grows from the leading edge")
        }
    }

    func testBarUsesTheVolumeRingColorWhenSpaceRunsLow() throws {
        // The level-two ring turns orange / red with the capacity pressure;
        // the level-one bar shows the same quantity, so it takes the same exit.
        let attention = StorageCapacitySnapshot(totalBytes: 1_000 * gigabyte, availableBytes: 150 * gigabyte)
        XCTAssertEqual(attention.pressure, .attention)
        let orange = try fillBounds(of: attention, matching: { $0.red > 0.8 && $0.green > 0.35 && $0.green < 0.8 && $0.blue < 0.35 })
        XCTAssertEqual(orange.width, barWidth * 0.85, accuracy: 1.5)

        let critical = StorageCapacitySnapshot(totalBytes: 1_000 * gigabyte, availableBytes: 40 * gigabyte)
        XCTAssertEqual(critical.pressure, .critical)
        let red = try fillBounds(of: critical, matching: { $0.red > 0.8 && $0.green < 0.4 && $0.blue < 0.4 })
        XCTAssertEqual(red.width, barWidth * 0.96, accuracy: 1.5)

        for snapshot in [attention, critical] {
            let volume = GeekDiskVolumePresentation(
                id: "fixture", name: "Macintosh HD", capacity: snapshot, healthText: "",
                smartStatus: .verified, temperature: nil, isNetwork: false)
            let colors = PanelMetricColors()
            XCTAssertEqual(
                GeekDiskVolumeColors.capacityTint(capacity: snapshot, metricColors: colors),
                GeekDiskVolumeColors.capacityTint(volume: volume, metricColors: colors),
                "one color exit for the level-one bar and the level-two ring")
        }
    }

    func testTextIsTheLevelTwoSummary() throws {
        let snapshot = StorageCapacitySnapshot(totalBytes: 1_000 * gigabyte, availableBytes: 560 * gigabyte)
        let chinese = MiniWindowLogicLanguageScope(.zhHans)
        XCTAssertEqual(GeekDiskPresentation.capacitySummary(snapshot), "44% 已用 · 560 GB 可用")
        chinese.restore()
        let english = MiniWindowLogicLanguageScope(.english)
        XCTAssertEqual(GeekDiskPresentation.capacitySummary(snapshot), "44% used · 560 GB available")
        english.restore()

        // The purgeable-inclusive "available" figure, as on the volume rows.
        let purgeable = StorageCapacitySnapshot(
            totalBytes: 1_000 * gigabyte, availableBytes: 300 * gigabyte,
            availableForImportantUsageBytes: 560 * gigabyte)
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        XCTAssertEqual(GeekDiskPresentation.capacitySummary(purgeable), "44% 已用 · 560 GB 可用")
        scope.restore()

        let overview = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekOverviewPresentation.swift")
        let disk = try MiniWindowLogicFixtures.section(
            overview, from: "struct GeekDiskPresentation: View {", to: "struct GeekBatteryPresentation")
        XCTAssertTrue(disk.contains("Text(Self.capacitySummary(storageSnapshot))"))
        XCTAssertTrue(disk.contains(".accessibilityValue(Self.capacitySummary(storageSnapshot))"),
                      "VoiceOver reads the same sentence")
        XCTAssertTrue(disk.contains("GeekDiskCapacityWording.volumeSummary("), "the level-two wording exit")
        XCTAssertFalse(disk.contains("1 - storageSnapshot.userUsedRatio"), "D14: not the available share")
        XCTAssertTrue(disk.contains(".help(GeekDiskCapacityWording.availableHelp)"))
    }

    // MARK: - Rendering

    private struct Pixel { let red, green, blue, alpha: CGFloat }

    /// Bounds, in points, of the bar pixels that satisfy `matching`.
    private func fillBounds(of snapshot: StorageCapacitySnapshot, matching: (Pixel) -> Bool) throws -> CGRect {
        let view = GeekDiskPresentation(
            storageSnapshot: snapshot, volumeName: "Macintosh HD", geekPrimaryDiskHealthText: nil,
            geekPrimaryDiskHealthTint: .secondary, healthHelp: ""
        )
        .frame(width: cardWidth)
        // A fill color no text or surface uses.
        .environment(\.panelMetricColors, PanelMetricColors(sectionHeader: "#FFFFFF", diskWrite: "#FF00FF"))
        .environment(\.colorScheme, .dark)
        .environment(\.miniWindowVisualMode, .black)
        .environment(\.displayScale, scale)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        XCTAssertEqual(CGFloat(bitmap.pixelsWide) / scale, cardWidth, accuracy: 0.5)
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9,
                      matching(Pixel(red: color.redComponent, green: color.greenComponent,
                                     blue: color.blueComponent, alpha: color.alphaComponent)) else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else {
            XCTFail("no bar pixels with the expected color")
            return .zero
        }
        let bounds = CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        XCTAssertEqual(bounds.height, 6, accuracy: 1, "only the 6 pt bar carries this color")
        return bounds
    }
}
