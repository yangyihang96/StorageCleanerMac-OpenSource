import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D175: the main window's sidebar column cannot stay hidden. The old ⌃⌘S
/// (`toggleSidebar`) hid it, AppKit restored the hidden column from the split
/// view's autosave on every launch, and the window has no control that shows
/// it again (10-22: only Smart Scan was on screen).
@MainActor
final class MainWindowSidebarColumnTests: XCTestCase {
    func testAHiddenSidebarColumnComesBackWhicheverWayItWasHidden() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = NSHostingController(rootView: NavigationSplitView {
            List { Text(verbatim: "Sidebar") }
                .navigationSplitViewColumnWidth(210)
        } detail: {
            Text(verbatim: "Detail")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MainWindowChromeConfigurator().frame(width: 0, height: 0))
        })
        window.orderFront(nil)

        let controller = try await splitViewController(in: window)
        let sidebar = try XCTUnwrap(controller.splitViewItems.first { $0.behavior == .sidebar })
        let configured = await eventually { !sidebar.canCollapse }
        XCTAssertTrue(configured, "the configurator makes the sidebar column non-collapsible")

        // A hidden column restored from the autosave.
        sidebar.isCollapsed = true
        let restored = await eventually { !sidebar.isCollapsed }
        XCTAssertTrue(restored, "a hidden sidebar column is shown again")

        // The system action the old ⌃⌘S sent.
        controller.toggleSidebar(nil)
        let toggledBack = await eventually { !sidebar.isCollapsed && sidebar.viewController.view.frame.width > 100 }
        XCTAssertTrue(toggledBack, "toggleSidebar does not leave the column hidden")
    }

    private func splitViewController(in window: NSWindow) async throws -> NSSplitViewController {
        var found: NSSplitViewController?
        _ = await eventually {
            found = MainWindowSidebarColumn.controller(in: window.contentView)
            return found != nil
        }
        return try XCTUnwrap(found, "the NavigationSplitView's split view controller")
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
