import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Decision D14 (2026-10-04): the level-one disk card shows the used share,
/// like the level-two ring and the level-three chart, and what it says is the
/// level-two summary "44% 已用 · 560 GB 可用". It replaces the earlier
/// decision that the bar showed the available share.
///
/// D118 (2026-10-18): the card follows iStat's: a 26 pt ring at (8, 8) filled
/// to the used share with that share inside it, the volume name and
/// "560 GB 可用" from x 41, and the read and write lights at the trailing
/// inset. These tests measured a 6 pt bar until then; they now measure the
/// ring's arc. VoiceOver still reads the summary sentence.
@MainActor
final class MiniWindowDiskLevelOneBarTests: XCTestCase {
    private let gigabyte: Int64 = 1_000_000_000
    private let scale: CGFloat = 2
    private var cardWidth: CGFloat { MiniWindowStyleTokens.overviewSize.width - 2 * MiniWindowStyleTokens.contentInset }
    private var ringFrame: CGRect {
        CGRect(x: GeekIStatCardGeometry.inset, y: GeekIStatCardGeometry.inset,
               width: GeekIStatCardGeometry.diskRingSize, height: GeekIStatCardGeometry.diskRingSize)
    }

    func testRingArcIsTheUsedShare() throws {
        // 44 % used, 56 % available: the two meanings give different arcs.
        for (used, total) in [(440, 1_000), (50, 1_000), (790, 1_000)] as [(Int64, Int64)] {
            let snapshot = StorageCapacitySnapshot(totalBytes: total * gigabyte, availableBytes: (total - used) * gigabyte)
            XCTAssertEqual(snapshot.pressure, .normal)
            let arc = try arcDegrees(of: snapshot, matching: { $0.red > 0.8 && $0.green < 0.3 && $0.blue > 0.8 })
            let expected = 360 * Double(used) / Double(total)
            XCTAssertEqual(Double(arc.count), expected, accuracy: 3,
                           "\(used)/\(total) GB used: the ring must fill the used share (\(expected)° of 360°)")
            let first = try XCTUnwrap(arc.first)
            let last = try XCTUnwrap(arc.last)
            XCTAssertLessThanOrEqual(first, 2, "the used share starts at 12 o'clock")
            XCTAssertEqual(last - first + 1, arc.count, "one arc, clockwise from 12 o'clock")
            XCTAssertEqual(GeekDiskPresentation.ringText(snapshot), "\(snapshot.userUsedPercent)",
                           "the number inside the ring is the same share")
        }
    }

    func testRingUsesTheVolumeRingColorWhenSpaceRunsLow() throws {
        // The level-two ring turns orange / red with the capacity pressure;
        // the level-one ring shows the same quantity, so it takes the same exit.
        let attention = StorageCapacitySnapshot(totalBytes: 1_000 * gigabyte, availableBytes: 150 * gigabyte)
        XCTAssertEqual(attention.pressure, .attention)
        let orange = try arcDegrees(of: attention, matching: { $0.red > 0.8 && $0.green > 0.35 && $0.green < 0.8 && $0.blue < 0.35 })
        XCTAssertEqual(Double(orange.count), 360 * 0.85, accuracy: 3)

        let critical = StorageCapacitySnapshot(totalBytes: 1_000 * gigabyte, availableBytes: 40 * gigabyte)
        XCTAssertEqual(critical.pressure, .critical)
        let red = try arcDegrees(of: critical, matching: { $0.red > 0.8 && $0.green < 0.4 && $0.blue < 0.4 })
        XCTAssertEqual(Double(red.count), 360 * 0.96, accuracy: 3)

        for snapshot in [attention, critical] {
            let volume = GeekDiskVolumePresentation(
                id: "fixture", name: "Macintosh HD", capacity: snapshot, healthText: "",
                smartStatus: .verified, temperature: nil, isNetwork: false)
            let colors = PanelMetricColors()
            XCTAssertEqual(
                GeekDiskVolumeColors.capacityTint(capacity: snapshot, metricColors: colors),
                GeekDiskVolumeColors.capacityTint(volume: volume, metricColors: colors),
                "one color exit for the level-one ring and the level-two ring")
        }
    }

    func testTextIsTheLevelTwoSummary() throws {
        let snapshot = StorageCapacitySnapshot(totalBytes: 1_000 * gigabyte, availableBytes: 560 * gigabyte)
        let chinese = MiniWindowLogicLanguageScope(.zhHans)
        XCTAssertEqual(GeekDiskPresentation.capacitySummary(snapshot), "44% 已用 · 560 GB 可用")
        XCTAssertEqual(GeekDiskPresentation.availableText(snapshot), "560 GB 可用")
        chinese.restore()
        let english = MiniWindowLogicLanguageScope(.english)
        XCTAssertEqual(GeekDiskPresentation.capacitySummary(snapshot), "44% used · 560 GB available")
        XCTAssertEqual(GeekDiskPresentation.availableText(snapshot), "560 GB available")
        english.restore()
        XCTAssertEqual(GeekDiskPresentation.ringText(snapshot), "44")

        // The purgeable-inclusive "available" figure, as on the volume rows.
        let purgeable = StorageCapacitySnapshot(
            totalBytes: 1_000 * gigabyte, availableBytes: 300 * gigabyte,
            availableForImportantUsageBytes: 560 * gigabyte)
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        XCTAssertEqual(GeekDiskPresentation.capacitySummary(purgeable), "44% 已用 · 560 GB 可用")
        XCTAssertEqual(GeekDiskPresentation.availableText(purgeable), "560 GB 可用")
        scope.restore()

        let overview = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekOverviewPresentation.swift")
        let disk = try MiniWindowLogicFixtures.section(
            overview, from: "struct GeekDiskPresentation: View {", to: "struct GeekBatteryPresentation")
        // D118: the visible rows are iStat's; the ring carries the used share
        // (was `Text(Self.capacitySummary(storageSnapshot))`).
        XCTAssertTrue(disk.contains("Text(Self.availableText(storageSnapshot))"))
        XCTAssertTrue(disk.contains("value: Self.ringText(storageSnapshot)"))
        XCTAssertTrue(disk.contains(".accessibilityValue(Self.capacitySummary(storageSnapshot))"),
                      "VoiceOver reads the same sentence")
        XCTAssertTrue(disk.contains("GeekDiskCapacityWording.volumeSummary("), "the level-two wording exit")
        XCTAssertFalse(disk.contains("1 - storageSnapshot.userUsedRatio"), "D14: not the available share")
        XCTAssertTrue(disk.contains(".help(GeekDiskCapacityWording.availableHelp)"))
    }

    /// D118: iStat's read light above its write light, each lit while the
    /// newest sample moved bytes in that direction, the ring track otherwise.
    func testReadAndWriteLightsFollowTheLatestSample() throws {
        let snapshot = StorageCapacitySnapshot(totalBytes: 1_000 * gigabyte, availableBytes: 560 * gigabyte)
        let readOnly = NativeDiskIOPoint(date: Date(timeIntervalSince1970: 0), readBytesPerSecond: 4_000_000,
                                         writeBytesPerSecond: 0, readOperationsPerSecond: 40,
                                         writeOperationsPerSecond: 0)
        let writeOnly = NativeDiskIOPoint(date: Date(timeIntervalSince1970: 0), readBytesPerSecond: 0,
                                          writeBytesPerSecond: 2_000_000, readOperationsPerSecond: 0,
                                          writeOperationsPerSecond: 20)
        let isRead: (Pixel) -> Bool = { $0.red < 0.2 && $0.green > 0.8 && $0.blue > 0.8 }
        let isWrite: (Pixel) -> Bool = { $0.red > 0.8 && $0.green < 0.3 && $0.blue > 0.8 }
        let size = GeekIStatCardGeometry.diskLightSize
        let x = cardWidth - GeekIStatCardGeometry.inset - size / 2
        let readCenter = CGPoint(x: x, y: GeekIStatCardGeometry.diskLightTop + size / 2)
        let writeCenter = CGPoint(x: x, y: readCenter.y + size + GeekIStatCardGeometry.diskLightSpacing)
        XCTAssertEqual(readCenter.y, 12.5, accuracy: 0.001, "centered on the name row (5 + 15 / 2)")
        XCTAssertEqual(writeCenter.y, 29.5, accuracy: 0.001, "centered on the available row (22 + 15 / 2)")

        for (sample, readLit, writeLit) in [(readOnly, true, false), (writeOnly, false, true), (nil, false, false)]
            as [(NativeDiskIOPoint?, Bool, Bool)] {
            let bitmap = try render(snapshot, latestDiskIO: sample)
            let read = try XCTUnwrap(pixel(in: bitmap, at: readCenter))
            let write = try XCTUnwrap(pixel(in: bitmap, at: writeCenter))
            XCTAssertEqual(isRead(read), readLit, "read light for \(String(describing: sample))")
            XCTAssertEqual(isWrite(write), writeLit, "write light for \(String(describing: sample))")
        }
    }

    // MARK: - Rendering

    private struct Pixel { let red, green, blue, alpha: CGFloat }

    private func render(_ snapshot: StorageCapacitySnapshot, latestDiskIO: NativeDiskIOPoint? = nil) throws -> NSBitmapImageRep {
        let view = GeekDiskPresentation(
            storageSnapshot: snapshot, volumeName: "Macintosh HD", geekPrimaryDiskHealthText: nil,
            geekPrimaryDiskHealthTint: .secondary, healthHelp: "", latestDiskIO: latestDiskIO
        )
        .frame(width: cardWidth)
        // Fill colors no text or surface uses.
        .environment(\.panelMetricColors, PanelMetricColors(sectionHeader: "#FFFFFF", diskRead: "#00FFFF", diskWrite: "#FF00FF"))
        .environment(\.colorScheme, .dark)
        .environment(\.miniWindowVisualMode, .black)
        .environment(\.displayScale, scale)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        XCTAssertEqual(CGFloat(bitmap.pixelsWide) / scale, cardWidth, accuracy: 0.5)
        return bitmap
    }

    private func pixel(in bitmap: NSBitmapImageRep, at point: CGPoint) -> Pixel? {
        guard let color = bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB),
              color.alphaComponent > 0.9 else { return nil }
        return Pixel(red: color.redComponent, green: color.greenComponent,
                     blue: color.blueComponent, alpha: color.alphaComponent)
    }

    /// The whole degrees, clockwise from 12 o'clock, whose point on the ring's
    /// centerline satisfies `matching`. Every pixel of that color in the card
    /// must lie on the ring.
    private func arcDegrees(of snapshot: StorageCapacitySnapshot, matching: (Pixel) -> Bool) throws -> [Int] {
        let bitmap = try render(snapshot)
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = pixel(in: bitmap, at: CGPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale)),
                      matching(pixel) else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else {
            XCTFail("no ring pixels with the expected color")
            return []
        }
        let bounds = CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        XCTAssertTrue(ringFrame.insetBy(dx: -0.5, dy: -0.5).contains(bounds),
                      "only the ring carries this color: \(bounds) outside \(ringFrame)")

        let center = CGPoint(x: ringFrame.midX, y: ringFrame.midY)
        let radius = ringFrame.width / 2 - GeekIStatCardGeometry.diskRingLineWidth / 2
        return (0..<360).filter { degree in
            let angle = (CGFloat(degree) + 0.5) * .pi / 180
            let point = CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
            return pixel(in: bitmap, at: point).map(matching) ?? false
        }
    }
}
