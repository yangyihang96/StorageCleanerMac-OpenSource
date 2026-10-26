#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D122: the plain level-three pages follow iStat Menus 7.30's plain
/// submenus: text sections of 15 pt rows on the 17 pt pitch (battery, sensor
/// readouts, hardware probes), the disk space menu's ring with its legend
/// inside (`BBRDisksMenuSpaceBarSection`, 220 wide) and the uptime menu's
/// title-and-value groups. Renders the production pages offscreen with the
/// demo data: no sampling, window or user data.
@MainActor
final class MiniWindowIStatDetailLayoutTests: XCTestCase {
    func testThePlainPagesHaveIStatsGeometry() {
        XCTAssertEqual(GeekIStatDetailGeometry.pageWidth, 220, "setWidth: 0xdc")
        XCTAssertEqual(GeekIStatDetailGeometry.spaceCardHeight, 200)
        XCTAssertEqual(GeekIStatDetailGeometry.spaceRingLineWidth, 10)
        XCTAssertEqual(GeekIStatDetailGeometry.spaceRingRadius(cardWidth: 204), 82, "W / 2 − 20")
        XCTAssertEqual(GeekIStatDetailGeometry.spaceLegendPitch, 37)
        XCTAssertEqual(GeekIStatDetailGeometry.spaceLegendTop(entryCount: 3), 48, "with the purgeable entry")
        XCTAssertEqual(GeekIStatDetailGeometry.spaceLegendTop(entryCount: 2), 66)
        XCTAssertEqual(GeekIStatDetailGeometry.stackedHeight(groupCount: 3), 114, "5 + 3 × 30 + 2 × 7 + 5")

        // Each page is its cards, 7 pt apart, inside the 8 pt inset. D137
        // (2026-10-19): the uptime page is its section + 20 (was
        // `GeekHoverDetailMetrics.uptimeSize`, 220 × 130).
        XCTAssertEqual(Self.uptimeDetail().popoverSize, CGSize(width: 170, height: 130))
        XCTAssertEqual(GeekDetailedTemperaturesDetail.popoverSize(readingCount: 9, hasSample: true),
                       CGSize(width: 391, height: 142), "five grid rows and the sample")
        XCTAssertEqual(GeekDetailedTemperaturesDetail.popoverSize(readingCount: 13, hasSample: false),
                       CGSize(width: 391, height: 159), "seven grid rows")
        let sampled = Self.readout(detailRowCount: 2, sampled: true)
        XCTAssertEqual(GeekSensorReadoutLayout.detailRowCount(sampled), 4)
        XCTAssertEqual(GeekSensorReadoutLayout.detailSize(sampled),
                       CGSize(width: 270, height: 16 + 24 + 4 * 17 + 7 + GeekIStatNoteCard.estimatedHeight))
        let unsampled = Self.readout(detailRowCount: 0, sampled: false)
        XCTAssertEqual(GeekSensorReadoutLayout.detailRowCount(unsampled), 1, "the source row alone")
        XCTAssertEqual(GeekSensorPowerHoverDetailMetrics.batterySize(sectionRowCounts: [3, 2]),
                       CGSize(width: 220, height: 16 + 75 + 7 + 58))
    }

    /// The rendered pages, hosted as the level-three column hosts them (the
    /// page's 8 pt inset around content that provides none), are exactly
    /// their popover sizes in both languages. The readout page's note is
    /// measured: its size estimates three lines until then.
    func testRenderedPlainPagesMatchTheirPopoverSizes() throws {
        let storage = MiniWindowDemoData.storageSnapshot
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let readout = Self.readout(detailRowCount: 2, sampled: true)
            let volume = GeekDiskVolumeHoverDetail(snapshot: storage, volumeName: MiniWindowDemoData.volumeName,
                                                   status: L10n.text("已验证", "Verified"), temperature: "38°C")
            let network = GeekDiskVolumeHoverDetail(snapshot: nil, volumeName: "NAS",
                                                    status: L10n.text("已连接", "Connected"), temperature: nil,
                                                    showsHealthTimestamp: false, isNetwork: true)
            let loading = GeekDiskVolumeHoverDetail(snapshot: nil, volumeName: MiniWindowDemoData.volumeName,
                                                    status: "—", temperature: nil)
            let battery = Self.batteryDetail()
            let probes = MiniWindowDemoData.demoTemperatureDetails
            let noteHeight = try Self.renderedHeight(GeekIStatNoteCard(text: readout.note),
                                                     width: GeekSensorReadoutLayout.detailWidth - 16)
            let pages: [(String, AnyView, CGSize)] = [
                // D137 (2026-10-19): the uptime and battery pages' sizes carry
                // their content widths (were `GeekHoverDetailMetrics.uptimeSize`
                // and `batterySize(sectionRowCounts:)`, both 220 wide).
                ("uptime", AnyView(Self.uptimeDetail()), Self.uptimeDetail().popoverSize),
                ("volume", AnyView(volume), volume.popoverSize),
                ("volume-network", AnyView(network), network.popoverSize),
                ("volume-reading", AnyView(loading), loading.popoverSize),
                ("probes", AnyView(GeekDetailedTemperaturesDetail(readings: probes,
                                                                  sampledAt: MiniWindowDemoData.referenceDate)),
                 GeekDetailedTemperaturesDetail.popoverSize(readingCount: probes.count, hasSample: true)),
                // Not "battery": the history pages export the battery history.
                ("battery-electrical", AnyView(battery), battery.popoverSize),
                ("readout", AnyView(GeekSensorReadoutDetail(readout: readout)),
                 CGSize(width: GeekSensorReadoutLayout.detailWidth,
                        height: 16 + GeekIStatSectionGeometry.rowsHeight(4, titled: true) + 7 + noteHeight)),
            ]
            XCTAssertEqual(volume.popoverSize, GeekDiskVolumeHoverDetail.popoverSize(rowCount: 4))
            XCTAssertEqual(network.popoverSize, GeekDiskVolumeHoverDetail.networkWithoutCapacitySize)
            XCTAssertEqual(loading.popoverSize, CGSize(width: 220, height: 216))
            XCTAssertEqual(battery.sectionRowCounts.count, 5, "power, battery, health, cells, USB-C")
            for (name, page, size) in pages {
                let bitmap = try Self.render(page, width: size.width, mode: .black)
                XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, size.width, accuracy: 0.5, "\(language) \(name)")
                XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, size.height, accuracy: 0.5, "\(language) \(name)")
                if language == .zhHans {
                    try Self.export(name: "l3-\(name)", night: bitmap, page: page, width: size.width)
                }
            }
        }
    }

    /// iStat's ring: 10 pt wide on radius W / 2 − 20 around the card's
    /// (W / 2, W / 2), clockwise from 12 o'clock: used, the reclaimable
    /// estimate, then the strict free space in the track's gray.
    func testTheDiskSpaceRingDrawsUsedReclaimableThenFreeFromTwelve() throws {
        let storage = MiniWindowDemoData.storageSnapshot
        let breakdown = GeekDiskCapacityBreakdown(snapshot: storage)
        XCTAssertGreaterThan(breakdown.reclaimableRatio, 0.02, "the demo shows all three segments")
        let page = GeekDiskVolumeHoverDetail(snapshot: storage, volumeName: MiniWindowDemoData.volumeName,
                                             status: "—", temperature: nil)
        // D135: iStat's dark theme, a gray card on a gray surface (the former
        // near-black chrome); the default indigo tints both.
        let bitmap = try Self.render(AnyView(page), width: GeekIStatDetailGeometry.pageWidth, mode: .black,
                                     themeID: "dark")
        let inset = GeekPanelLayout.contentPadding
        let card = GeekIStatDetailGeometry.pageWidth - 2 * inset
        let center = CGPoint(x: inset + card / 2, y: inset + card / 2)
        let radius = GeekIStatDetailGeometry.spaceRingRadius(cardWidth: card)
        func color(atFraction fraction: Double, radius: CGFloat) throws -> NSColor {
            let angle = fraction * 2 * .pi
            let x = Int(((center.x + radius * CGFloat(sin(angle))) * 2).rounded(.down))
            let y = Int(((center.y - radius * CGFloat(cos(angle))) * 2).rounded(.down))
            return try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        }
        func spread(_ color: NSColor) -> CGFloat {
            let channels = [color.redComponent, color.greenComponent, color.blueComponent]
            return (channels.max() ?? 0) - (channels.min() ?? 0)
        }
        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                abs(a.blueComponent - b.blueComponent))
        }
        let used = try color(atFraction: breakdown.usedRatio / 2, radius: radius)
        let reclaimable = try color(atFraction: breakdown.usedRatio + breakdown.reclaimableRatio / 2, radius: radius)
        let free = try color(atFraction: (breakdown.usedRatio + breakdown.reclaimableRatio + 1) / 2, radius: radius)
        let beside = try color(atFraction: breakdown.usedRatio / 2, radius: radius + 8)
        XCTAssertGreaterThan(spread(used), 0.25, "used is colored")
        XCTAssertGreaterThan(spread(reclaimable), 0.25, "the reclaimable estimate is colored")
        XCTAssertGreaterThan(distance(used, reclaimable), 0.15, "in two colors")
        XCTAssertLessThan(spread(free), 0.08, "free is the track's gray")
        XCTAssertGreaterThan(distance(free, beside), 0.04, "the track shows on the card")
        XCTAssertLessThan(spread(beside), 0.08, "the band is 10 pt: 8 pt beyond its middle is the card")
    }

    func testThePlainPagesKeepTheirAccessibilityStructure() throws {
        let target = try Self.source("Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        let sensors = try Self.source("Views/MenuBarAdvanced/GeekSensorsView.swift")
        let power = try Self.source("Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift")
        let sections = try Self.source("Views/MenuBarAdvanced/GeekIStatSections.swift")
        let uptime = try XCTUnwrap(target.components(separatedBy: "struct GeekProcessorUptimeHoverDetail: View {")
            .dropFirst().first?.components(separatedBy: "\n}\n").first)
        // D138: iStat's 'CPU.Uptime' (was "运行时间").
        XCTAssertTrue(uptime.contains(".accessibilityLabel(L10n.text(\"电脑开启时间\", \"Uptime\"))"))
        // Each group reads its title with its value.
        let stacked = try XCTUnwrap(sections.components(separatedBy: "struct GeekIStatStackedGroupsCard: View {")
            .dropFirst().first?.components(separatedBy: "\n}\n").first)
        XCTAssertTrue(stacked.contains(".accessibilityElement(children: .combine)"))
        let volume = try XCTUnwrap(target.components(separatedBy: "struct GeekDiskVolumeHoverDetail: View {")
            .dropFirst().first?.components(separatedBy: "\n}\n").first)
        XCTAssertTrue(volume.contains(".accessibilityLabel(displayName)"))
        let ring = try XCTUnwrap(target.components(separatedBy: "private struct GeekDiskSpaceCard: View {")
            .dropFirst().first?.components(separatedBy: "\n}\n").first)
        XCTAssertTrue(ring.contains(".accessibilityLabel(L10n.text(\"磁盘容量构成\", \"Disk capacity composition\"))"))
        let probes = try XCTUnwrap(sensors.components(separatedBy: "struct GeekDetailedTemperaturesDetail: View {")
            .dropFirst().first?.components(separatedBy: "\n}\n").first)
        XCTAssertTrue(probes.contains(".help(reading.sourceHelp)"))
        XCTAssertTrue(probes.contains(".accessibilityElement(children: .combine)"), "a probe reads as one element")
        let battery = try XCTUnwrap(power.components(separatedBy: "struct GeekBatteryElectricalHoverDetail: View {")
            .dropFirst().first?.components(separatedBy: "\n}\n").first)
        XCTAssertTrue(battery.contains(".accessibilityElement(children: .contain)"))
        XCTAssertTrue(battery.contains("GeekIStatRow(title: row.0, value: row.1)"),
                      "rows are iStat rows, each one element")
    }

    // MARK: - Helpers

    private static func readout(detailRowCount: Int, sampled: Bool) -> GeekSensorReadout {
        GeekSensorReadout(
            id: "demo.readout",
            title: L10n.text("环境光", "Ambient Light"),
            value: "320 lx",
            source: L10n.text("环境光传感器", "Ambient light sensor"),
            note: L10n.text(
                "由系统环境光传感器报告，随屏幕亮度自动调节使用；数值是传感器的估算，不是照度计读数。",
                "Reported by the system's ambient light sensor for automatic brightness; an estimate from the sensor, not a light-meter reading."
            ),
            sampledAt: sampled ? MiniWindowDemoData.referenceDate : nil,
            detailRows: (0..<detailRowCount).map { index in
                GeekSensorReadoutDetailRow(
                    index == 0 ? L10n.text("屏幕亮度", "Display Brightness") : L10n.text("其中自动调节", "Of Which Automatic"),
                    index == 0 ? "62%" : "40%",
                    isIndented: index > 0
                )
            }
        )
    }

    private static func uptimeDetail() -> GeekProcessorUptimeHoverDetail {
        let sinceBoot: TimeInterval = 734_400
        let bootAt = MiniWindowDemoData.referenceDate.addingTimeInterval(-sinceBoot)
        return GeekProcessorUptimeHoverDetail(
            poweredOnAt: PanelTimestampFormat.monthDayAndTime(bootAt),
            awake: GeekUptimeFormat.duration(MiniWindowDemoData.systemAwakeSeconds),
            asleep: GeekUptimeFormat.duration(GeekUptimeFormat.asleepSeconds(
                bootAt: bootAt, sinceBootSeconds: sinceBoot, awakeSeconds: MiniWindowDemoData.systemAwakeSeconds
            ))
        )
    }

    /// As the power page passes the demo's readings (GeekPowerView).
    private static func batteryDetail() -> GeekBatteryElectricalHoverDetail {
        let battery = MiniWindowDemoData.batterySnapshot
        return GeekBatteryElectricalHoverDetail(
            electrical: MiniWindowDemoData.batteryElectricalSnapshot,
            cycleCount: MiniWindowDemoData.healthSummary.batteryCycleCount,
            condition: L10n.text("正常", "Normal"),
            chargePercent: battery.chargePercent,
            healthPercent: MiniWindowDemoData.healthSummary.batteryCapacityPercent,
            statusText: L10n.text("使用电池", "On Battery"),
            isCharging: battery.isCharging,
            chargeTargetPercent: 80,
            remainingTimeMinutes: battery.remainingTimeMinutes
        )
    }

    private static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/\(path)"), encoding: .utf8)
    }

    /// As `tertiaryDetailChrome` hosts a page: content without its own
    /// inset on the page's card width, padded by the column's 8 pt.
    private static func render(_ page: AnyView, width: CGFloat, mode: MiniWindowVisualMode,
                               themeID: String? = nil) throws -> NSBitmapImageRep {
        let content = page
            .frame(width: width - 2 * GeekPanelLayout.contentPadding, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.miniWindowPageProvidesInset, true)
            .padding(GeekPanelLayout.contentPadding)
            .metricPanelShell()
            .environment(\.menuBarChartsPreparedInline, true)
            .environment(\.miniWindowPreviewDate, MiniWindowDemoData.referenceDate)
            .modifier(PanelAppearanceEnvironment(forcedVisualMode: mode, forcedThemeID: themeID))
            .environment(\.displayScale, 2)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private static func renderedHeight<Content: View>(_ view: Content, width: CGFloat) throws -> CGFloat {
        let renderer = ImageRenderer(content: view
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(PanelAppearanceEnvironment(forcedVisualMode: .black))
            .environment(\.displayScale, 2))
        renderer.scale = 2
        return CGFloat(try XCTUnwrap(renderer.cgImage).height) / 2
    }

    private static var evidenceDirectory: URL? {
        ProcessInfo.processInfo.environment["STORAGE_CLEANER_ISTAT_LAYOUT_EVIDENCE"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    /// Night is black, day is graphite (D44, D56).
    private static func export(name: String, night: NSBitmapImageRep, page: AnyView, width: CGFloat) throws {
        guard let directory = evidenceDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (bitmap, suffix) in [(night, "night"), (try render(page, width: width, mode: .graphite), "day")] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}

#endif
