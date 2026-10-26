#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D153: the combined status icon's settings, every group open, in a window
/// on the test display (D106) — light and dark, Chinese and English. The
/// section is laid out at its ideal height, as in the settings column's
/// scroll view (the document of an NSScrollView here); no two rows may
/// overlap and none may be wider than the column. SCM_COMBINED_SETTINGS_RENDER_DIR
/// gets a capture of each for review. The settings are read from a test domain.
@MainActor
final class CombinedStatusIconSettingsWindowTests: XCTestCase {
    func testExpandedSettingsRowsNeitherOverlapNorOverflowTheColumn() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            for dark in [false, true] {
                let label = "\(language.rawValue)/\(dark ? "dark" : "light")"
                let defaults = TestPreferenceDomain.make(for: self)
                let width: CGFloat = 560
                let probe = SettingsRowProbe()
                let root = CombinedStatusIconSettingsSection(expandsGroups: true)
                    .padding(24)
                    .frame(width: width, alignment: .topLeading)
                    .layoutProbe("fixture.column")
                    .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                        Task { @MainActor in probe.frames = frames }
                    }
                    .defaultAppStorage(defaults)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let hosting = NSHostingView(rootView: root)
                let fitting = try await settledFittingSize(of: hosting)
                hosting.frame = NSRect(origin: .zero, size: fitting)
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 640))
                scroll.hasVerticalScroller = true
                scroll.documentView = hosting
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 640),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.animationBehavior = .none
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = scroll
                window.orderFront(nil)
                defer { window.close() }
                let rows = try await settledRows(probe, hosting: hosting)

                XCTAssertEqual(fitting.width, width, accuracy: 0.5, label)
                XCTAssertEqual(hosting.frame.height, fitting.height, accuracy: 0.5, "\(label): laid out at its ideal height")
                XCTAssertGreaterThanOrEqual(rows.count, 24, "\(label): every row of the open groups reports a frame")
                let column = try XCTUnwrap(probe.frames["fixture.column"], label)
                for (id, frame) in rows {
                    XCTAssertGreaterThan(frame.height, 0, "\(label) \(id)")
                    XCTAssertLessThanOrEqual(frame.maxX, column.maxX + 0.5, "\(label) \(id) is wider than the column")
                }
                let ordered = rows.sorted { $0.value.minY < $1.value.minY }
                for (above, below) in zip(ordered, ordered.dropFirst()) {
                    XCTAssertLessThanOrEqual(above.value.maxY, below.value.minY + 0.5,
                                             "\(label): \(above.key) overlaps \(below.key)")
                }
                if let directory = ProcessInfo.processInfo.environment["SCM_COMBINED_SETTINGS_RENDER_DIR"] {
                    let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    let name = "combined-settings-\(language.rawValue)-\(dark ? "dark" : "light").png"
                    try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                }
            }
        }
    }

    private func settledFittingSize(of view: NSView) async throws -> CGSize {
        var previous = CGSize.zero
        for _ in 0..<40 {
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            if size == previous, size.height > 0 { return size }
            previous = size
            try await Task.sleep(for: .milliseconds(25))
        }
        return previous
    }

    /// The row frames once two readings in a row agree.
    private func settledRows(_ probe: SettingsRowProbe, hosting: NSView) async throws -> [String: CGRect] {
        var previous: [String: CGRect] = [:]
        for _ in 0..<80 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
            let rows = probe.frames.filter { $0.key.hasPrefix(CombinedStatusIconSettingsSection.rowProbe) }
            if !rows.isEmpty, rows == previous { return rows }
            previous = rows
        }
        return previous
    }
}

@MainActor
private final class SettingsRowProbe {
    var frames: [String: CGRect] = [:]
}
#endif
