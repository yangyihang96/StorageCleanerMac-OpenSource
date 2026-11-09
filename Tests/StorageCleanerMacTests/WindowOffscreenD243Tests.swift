import AppKit
import XCTest
@testable import StorageCleanerMac

/// D243 (review P2-15): after a virtual display closed, the 2.0.1 main window
/// stayed at x = −1316 with no display there. The window's last screen no
/// longer decides; the screens as they are now do, for the main window and
/// the Settings window.
final class WindowOffscreenD243Tests: XCTestCase {
    /// The review Mac after the display closed: the built-in screen only.
    private let main = NSRect(x: 0, y: 0, width: 1_352, height: 845)

    func testAWindowOnNoScreenGoesBackToTheMainScreen() throws {
        let stranded = NSRect(x: -1_316, y: 85, width: 1_137, height: 690)
        let target = try XCTUnwrap(AppWindowLayoutPolicy.visibleFrame(for: stranded, screens: [main], main: main))
        XCTAssertEqual(target, main)
        XCTAssertFalse(AppWindowLayoutPolicy.isFullyVisible(stranded, in: target))
        let origin = AppWindowLayoutPolicy.clampedOrigin(stranded.origin, size: stranded.size, in: target)
        let moved = NSRect(origin: origin, size: stranded.size)
        XCTAssertTrue(AppWindowLayoutPolicy.isFullyVisible(moved, in: target), "\(moved)")
    }

    func testTheScreenAWindowOverlapsMostWinsOverTheMainScreen() {
        let right = NSRect(x: 1_352, y: -595, width: 2_560, height: 1_440)
        let window = NSRect(x: 1_200, y: 100, width: 1_000, height: 600)
        XCTAssertEqual(AppWindowLayoutPolicy.visibleFrame(for: window, screens: [main, right], main: main), right)
        let mostlyMain = NSRect(x: 400, y: 100, width: 1_000, height: 600)
        XCTAssertEqual(AppWindowLayoutPolicy.visibleFrame(for: mostlyMain, screens: [main, right], main: main), main)
        XCTAssertNil(AppWindowLayoutPolicy.visibleFrame(for: window, screens: [], main: nil))
        XCTAssertEqual(AppWindowLayoutPolicy.visibleFrame(for: window, screens: [right], main: nil), right)
    }

    func testBothWindowsListenForScreenChangesAndReadTheCurrentScreens() throws {
        func source(_ path: String) throws -> String {
            try String(contentsOf: SwiftSourceScanning.projectRoot.appendingPathComponent(path), encoding: .utf8)
        }
        // Code only: the D243 comments quote the old spelling.
        let module = try source("Sources/StorageCleanerMac/Views/ModulePresentation.swift")
        let apply = SwiftSourceScanning.code(try r2SourceDeclaration("private func applyLayout(centerWhenResized: Bool)", in: module))
        XCTAssertTrue(apply.contains("AppWindowLayoutPolicy.visibleFrame("))
        XCTAssertTrue(apply.contains("screens: NSScreen.screens.map(\\.visibleFrame)"))
        XCTAssertFalse(apply.contains("window.screen?.visibleFrame"))
        let changed = try r2SourceDeclaration("@objc private func screenParametersDidChange", in: module)
        XCTAssertTrue(changed.contains("DispatchQueue.main.async"))
        let settings = try source("Sources/StorageCleanerMac/Views/SettingsView.swift")
        let attach = try r2SourceDeclaration("func keepStandardControls(_ window: NSWindow)", in: settings)
        XCTAssertTrue(attach.contains("NSApplication.didChangeScreenParametersNotification"))
        XCTAssertTrue(attach.contains("SettingsWindowConfigurator.restoreVisibleFrameIfNeeded(window)"))
        let restore = SwiftSourceScanning.code(try r2SourceDeclaration("static func restoreVisibleFrameIfNeeded(_ window: NSWindow)", in: settings))
        XCTAssertFalse(restore.contains("window.screen?.visibleFrame"))
    }
}
