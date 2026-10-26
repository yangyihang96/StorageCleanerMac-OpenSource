#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D136: iStat Menus 7.30's hidden items and the disk space section's two
/// buttons (`r9-istat/R9-hide-evidence.txt`): the Finder icon at (8, 8) and
/// the visibility icon at (W − 24, 8), 16 pt each, a click inside the 32 pt
/// corner square acting 0.1 s later; hiding appends the volume's key to the
/// stored list; the settings show every hidden volume again. Offscreen with
/// demo data: nothing opens Finder and no real preference is written.
@MainActor
final class MiniWindowIStatHiddenItemsTests: XCTestCase {
    func testStoredListAppendsEachKeyOnceAndFiltersInOrder() {
        XCTAssertEqual(MiniWindowHiddenItems.keys(from: ""), [])
        XCTAssertEqual(MiniWindowHiddenItems.keys(from: "not json"), [])
        let one = MiniWindowHiddenItems.raw(appending: "/Volumes/Backup", to: "")
        XCTAssertEqual(MiniWindowHiddenItems.keys(from: one), ["/Volumes/Backup"])
        let two = MiniWindowHiddenItems.raw(appending: "/", to: one)
        XCTAssertEqual(MiniWindowHiddenItems.keys(from: two), ["/Volumes/Backup", "/"])
        XCTAssertEqual(MiniWindowHiddenItems.raw(appending: "/", to: two), two, "an item hides once")
        XCTAssertEqual(MiniWindowHiddenItems.visible(["/", "/Volumes/A", "/Volumes/Backup"], raw: two, key: { $0 }),
                       ["/Volumes/A"])
        XCTAssertEqual(MiniWindowHiddenItems.visible(["/", "/Volumes/A"], raw: "", key: { $0 }), ["/", "/Volumes/A"])
        XCTAssertEqual(MiniWindowHiddenItems.disksKey, "menuBar.disks.hidden.v1")
        XCTAssertEqual(MiniWindowHiddenItems.actionDelay, 0.1, "iStat dispatches the click 0.1 s later")
        XCTAssertEqual(GeekIStatDetailGeometry.spaceActionIconSize, 16)
        XCTAssertEqual(GeekIStatDetailGeometry.spaceActionHitSize, 32)
    }

    /// Only the two 16 pt squares change when the buttons are drawn, and the
    /// visibility glyph takes the theme's value color. With the system's
    /// Finder icon the renderer writes the page in BT.2100 PQ (16 bit), so
    /// every color value differs and coverage does not: the page is compared
    /// by alpha, the glyph against a swatch drawn in the same image.
    func testVolumePageDrawsTheFinderAndVisibilityIconsAtIStatsPlaces() throws {
        let plain = try renderVolumePage(actions: nil)
        let withButtons = try renderVolumePage(actions: .inert)
        if let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_ISTAT_LAYOUT_EVIDENCE"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (bitmap, name) in [(plain, "l3-disk-volume-plain-night"), (withButtons, "l3-disk-volume-buttons-night")] {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
        XCTAssertEqual(plain.pixelsWide, withButtons.pixelsWide)
        XCTAssertEqual(plain.pixelsHigh, withButtons.pixelsHigh)
        XCTAssertEqual(CGFloat(withButtons.pixelsWide) / 2, GeekIStatDetailGeometry.pageWidth, accuracy: 0.5)

        // The space card starts at the page's inset; its width is W.
        let inset = GeekPanelLayout.contentPadding
        let cardWidth = GeekIStatDetailGeometry.pageWidth - 2 * inset
        let icon = GeekIStatDetailGeometry.spaceActionIconSize
        let finder = CGRect(x: 8, y: 8, width: icon, height: icon)
        let visibility = CGRect(x: cardWidth - 24, y: 8, width: icon, height: icon)

        var finderChanged = 0
        var visibilityChanged = 0
        var outside: [(Int, Int)] = []
        for y in 0..<withButtons.pixelsHigh {
            for x in 0..<withButtons.pixelsWide {
                guard let a = plain.colorAt(x: x, y: y), let b = withButtons.colorAt(x: x, y: y),
                      abs(a.alphaComponent - b.alphaComponent) > 0.02 else { continue }
                // In the card's points, with half a point of resampling.
                let point = CGPoint(x: (CGFloat(x) + 0.5) / 2 - inset, y: (CGFloat(y) + 0.5) / 2 - inset)
                if finder.insetBy(dx: -0.5, dy: -0.5).contains(point) {
                    finderChanged += 1
                } else if visibility.insetBy(dx: -0.5, dy: -0.5).contains(point) {
                    visibilityChanged += 1
                } else {
                    outside.append((x, y))
                }
            }
        }
        XCTAssertTrue(outside.isEmpty, "nothing outside the two squares changes: \(outside.prefix(8))")
        // The Finder icon fills most of its square; the eye is a thin glyph.
        XCTAssertGreaterThan(finderChanged, Int(icon * icon * 4 * 0.4), "the Finder icon at (8, 8)")
        XCTAssertGreaterThan(visibilityChanged, Int(icon * icon * 4 * 0.05), "the visibility icon at (W − 24, 8)")

        // The buttons in the card's top 32 pt, a value-colored swatch below.
        let hit = GeekIStatDetailGeometry.spaceActionHitSize
        let probe = try render(VStack(alignment: .leading, spacing: 0) {
            GeekDiskSpaceActionButtons(volumeName: MiniWindowDemoData.volumeName, actions: .inert)
                .frame(width: cardWidth, height: hit, alignment: .top)
            Rectangle().modifier(GeekIStatTextColor(role: .value)).frame(width: 8, height: 8)
        })
        let value = try XCTUnwrap(probe.colorAt(x: 8, y: Int(hit * 2) + 8))
        var glyph: NSColor?
        for y in Int(visibility.minY * 2)..<Int(visibility.maxY * 2) {
            for x in Int(visibility.minX * 2)..<Int(visibility.maxX * 2) {
                guard let color = probe.colorAt(x: x, y: y),
                      color.alphaComponent > (glyph?.alphaComponent ?? 0) else { continue }
                glyph = color
            }
        }
        let core = try XCTUnwrap(glyph)
        XCTAssertGreaterThan(core.alphaComponent, 0.9, "the glyph's stroke is opaque")
        for (drawn, expected) in [(core.redComponent, value.redComponent), (core.greenComponent, value.greenComponent),
                                  (core.blueComponent, value.blueComponent)] {
            XCTAssertEqual(drawn, expected, accuracy: 0.02, "the glyph takes the theme's value color")
        }
    }

    /// The buttons act through `actions` after iStat's delay; the Finder
    /// button opens the volume's path and the settings reset the list.
    func testButtonsAndSettingsFollowIStatsSources() throws {
        let buttons = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        XCTAssertTrue(buttons.contains("DispatchQueue.main.asyncAfter(deadline: .now() + MiniWindowHiddenItems.actionDelay)"))
        XCTAssertTrue(buttons.contains("MainActor.assumeIsolated { action() }"))
        XCTAssertTrue(buttons.contains("static let finderPath = \"/System/Library/CoreServices/Finder.app\""))
        XCTAssertTrue(buttons.contains("NSWorkspace.shared.icon(forFile: finderPath)"))
        XCTAssertTrue(buttons.contains(".overlay(alignment: .top) { spaceActionButtons }"))
        XCTAssertTrue(buttons.contains(".buttonStyle(ResponsivePlainButtonStyle())\n        .help(title)"),
                      "the app's shared plain button, which looks the same at rest")
        let actions = try source("Sources/StorageCleanerMac/Support/MiniWindowHiddenItems.swift")
        XCTAssertTrue(actions.contains("NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))"))
        let disk = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDiskView.swift")
        XCTAssertTrue(disk.contains("showInFinder: { MiniWindowVolumeActions.showInFinder(path: volume.id) }"))
        XCTAssertTrue(disk.contains("hide: { hideDiskVolume(volume.id) }"))
        let settingsView = try source("Sources/StorageCleanerMac/Views/SettingsView.swift")
        XCTAssertTrue(settingsView.contains("@AppStorage(MiniWindowHiddenItems.disksKey) var hiddenDiskKeysRaw = \"\""))
        // The panel reads the same key in its store, the standard defaults
        // Settings writes, outside tests.
        let panel = try source("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")
        XCTAssertTrue(panel.contains("_hiddenDiskKeysRaw = AppStorage(wrappedValue: \"\", MiniWindowHiddenItems.disksKey,"))
        XCTAssertTrue(panel.contains("store: panelSettingsState.defaults)"))
        let panelSettings = try source("Sources/StorageCleanerMac/Views/MenuBarPanelSettingsView.swift")
        XCTAssertTrue(panelSettings.contains("defaults: UserDefaults = .standard"))
        let general = try source("Sources/StorageCleanerMac/Views/Settings/SettingsGeneral.swift")
        XCTAssertTrue(general.contains("hiddenDiskKeysRaw = \"\""), "Reset Disk Filtering clears the list")
        XCTAssertTrue(general.contains(".disabled(hiddenDiskCount == 0)"))
    }

    private func renderVolumePage(actions: GeekDiskVolumeActions?) throws -> NSBitmapImageRep {
        try render(GeekDiskVolumeHoverDetail(
            snapshot: MiniWindowDemoData.storageSnapshot,
            volumeName: MiniWindowDemoData.volumeName,
            status: "—",
            temperature: nil,
            showsHealthTimestamp: false,
            actions: actions
        )
        .frame(width: GeekIStatDetailGeometry.pageWidth)
        .fixedSize(horizontal: false, vertical: true))
    }

    private func render(_ view: some View) throws -> NSBitmapImageRep {
        let content = view
            .modifier(PanelAppearanceEnvironment(forcedVisualMode: .black))
            .environment(\.displayScale, 2)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
#endif
