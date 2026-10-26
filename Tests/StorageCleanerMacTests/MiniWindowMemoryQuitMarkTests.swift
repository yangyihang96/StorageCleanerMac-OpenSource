import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D150 (user, 2026-10-19: "进程里关闭的程序要显示的都是可以关闭的"): on the
/// memory page's process section only the rows that can be quit carry the
/// selection mark. A read-only row (a system process, or one the app cannot
/// quit) keeps the mark's 12 pt slot blank, so the icons and names stay in
/// one column; its help and VoiceOver value still say it is read-only (was:
/// a dimmed circle on every row). Fixtures only; renders offscreen. No
/// window, process list or quit.
@MainActor
final class MiniWindowMemoryQuitMarkTests: XCTestCase {
    private static let scale: CGFloat = 2
    /// The process section's row width on iStat's 270 pt memory page.
    private static let width: CGFloat = 238
    private let memoryView = "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift"

    func testAnApplicationCanBeQuitExactlyWhenOneOfItsProcessesCan() throws {
        let apps = Self.apps([
            MiniWindowLogicFixtures.memoryProcess(id: 8_101, name: "D150 Editor", residentBytes: 900 * 1024 * 1024),
            MiniWindowLogicFixtures.memoryProcess(id: 8_102, name: "D150 Server", residentBytes: 800 * 1024 * 1024,
                                                  canQuit: false),
            // One bundle, so one group: a process that can be quit and one
            // that cannot.
            MiniWindowLogicFixtures.memoryProcess(id: 8_103, name: "D150 Browser", residentBytes: 700 * 1024 * 1024),
            MiniWindowLogicFixtures.memoryProcess(id: 8_104, name: "D150 Browser", residentBytes: 600 * 1024 * 1024,
                                                  canQuit: false)
        ])
        XCTAssertEqual(apps.count, 3)
        for app in apps.values {
            XCTAssertEqual(app.canQuit, !app.selectableProcessIDs.isEmpty, app.name)
        }
        XCTAssertEqual(apps["D150 Editor"]?.canQuit, true)
        XCTAssertEqual(apps["D150 Server"]?.canQuit, false)
        XCTAssertEqual(apps["D150 Browser"]?.canQuit, true)
        XCTAssertEqual(apps["D150 Browser"]?.selectableProcessIDs, [8_103])
    }

    func testOnlyARowThatCanBeQuitDrawsTheMarkAndEveryRowKeepsItsSlot() throws {
        let apps = Self.apps([
            MiniWindowLogicFixtures.memoryProcess(id: 8_111, name: "D150 Editor", residentBytes: 900 * 1024 * 1024),
            MiniWindowLogicFixtures.memoryProcess(id: 8_112, name: "D150 Server", residentBytes: 800 * 1024 * 1024,
                                                  canQuit: false)
        ])
        let editor = try XCTUnwrap(apps["D150 Editor"])
        let server = try XCTUnwrap(apps["D150 Server"])
        let slot = Int(GeekMemoryProcessLayout.selectionMarkSize * Self.scale)
        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            let canQuit = try Self.render(editor, isSelectionEnabled: true, dark: dark)
            // While a quit runs the selection is locked; the app can still
            // be quit, so its mark stays (dimmed with the row).
            let locked = try Self.render(editor, isSelectionEnabled: false, dark: dark)
            let readOnly = try Self.render(server, isSelectionEnabled: false, dark: dark)
            XCTAssertGreaterThan(Self.inkCount(canQuit, columns: 0..<slot, dark: dark), 0, "can quit, \(tag)")
            XCTAssertGreaterThan(Self.inkCount(locked, columns: 0..<slot, dark: dark), 0, "locked, \(tag)")
            XCTAssertEqual(Self.inkCount(readOnly, columns: 0..<slot, dark: dark), 0, "read-only, \(tag)")
            // The icon starts after the slot on both rows (the read-only one
            // is dimmed, so its antialiased edge may start a pixel later).
            let iconStart = try XCTUnwrap(Self.firstInkColumn(canQuit, from: slot, dark: dark), tag)
            let readOnlyIconStart = try XCTUnwrap(Self.firstInkColumn(readOnly, from: slot, dark: dark), tag)
            XCTAssertGreaterThan(iconStart, slot, tag)
            XCTAssertEqual(Double(readOnlyIconStart), Double(iconStart), accuracy: 2, tag)
        }
    }

    func testTheRowDrawsTheMarkOnlyForAnApplicationThatCanBeQuit() throws {
        let view = try MiniWindowLogicFixtures.source(memoryView)
        let mark = try MiniWindowLogicFixtures.section(
            view, from: "struct GeekCompactMemoryProcessRow: View {", to: "GeekSecondaryProcessIcon(path: process.iconPath")
        let order = try ["ZStack {", "if process.canQuit {",
                         "AppSymbolGlyph(systemImage: isSelected ? \"checkmark.circle.fill\" : \"circle\",",
                         ".frame(width: GeekMemoryProcessLayout.selectionMarkSize,",
                         ".accessibilityHidden(true)"].map {
            try XCTUnwrap(mark.range(of: $0), "the row no longer has \($0)").lowerBound
        }
        XCTAssertEqual(order, order.sorted())
        XCTAssertFalse(mark.contains("if isSelectionEnabled {"), "a quit in progress keeps the marks")
        // The read-only row keeps saying so; the card enables a row only
        // where the application can be quit.
        let row = try MiniWindowLogicFixtures.section(
            view, from: "struct GeekCompactMemoryProcessRow: View {", to: ".accessibilityHint(")
        XCTAssertTrue(row.contains(".disabled(!isSelectionEnabled)"))
        XCTAssertTrue(row.contains("\"此进程仅供查看，不能从这里退出\""))
        XCTAssertTrue(row.contains("L10n.text(\"仅查看\", \"Read Only\")"))
        XCTAssertTrue(view.contains("&& !process.selectableProcessIDs.isEmpty,"))
    }

    private static func apps(_ processes: [MemoryProcess]) -> [String: MemoryAppUsage] {
        let snapshot = MiniWindowLogicFixtures.memorySnapshot(processes: processes)
        return Dictionary(uniqueKeysWithValues: snapshot.appsByResidentUsage.map { ($0.name, $0) })
    }

    private static func render(_ app: MemoryAppUsage, isSelectionEnabled: Bool, dark: Bool) throws -> NSBitmapImageRep {
        let row = GeekCompactMemoryProcessRow(process: app, isSelected: false, isSelectionEnabled: isSelectionEnabled,
                                              selectionTint: .blue, onToggle: {})
        let renderer = ImageRenderer(content: row
            .frame(width: width)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.miniWindowVisualMode, .black)
            .environment(\.displayScale, scale)
            .background(dark ? Color.black : Color.white))
        renderer.scale = scale
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    /// The pixels in `columns` off the background by more than 6 % in any
    /// channel (the unselected mark is a dimmed secondary circle).
    private static func inkCount(_ bitmap: NSBitmapImageRep, columns: Range<Int>, dark: Bool) -> Int {
        columns.filter { $0 < bitmap.pixelsWide }.reduce(0) { count, x in
            count + (0..<bitmap.pixelsHigh).filter { isInk(bitmap, x: x, y: $0, dark: dark) }.count
        }
    }

    private static func firstInkColumn(_ bitmap: NSBitmapImageRep, from start: Int, dark: Bool) -> Int? {
        (start..<bitmap.pixelsWide).first { x in
            (0..<bitmap.pixelsHigh).contains { isInk(bitmap, x: x, y: $0, dark: dark) }
        }
    }

    private static func isInk(_ bitmap: NSBitmapImageRep, x: Int, y: Int, dark: Bool) -> Bool {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
        let background: CGFloat = dark ? 0 : 1
        return [color.redComponent, color.greenComponent, color.blueComponent].contains { abs($0 - background) > 0.06 }
    }
}
