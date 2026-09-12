import AppKit
import XCTest
@testable import StorageCleanerMac

@MainActor
final class MenuBarStatusPanelTests: XCTestCase {
    func testPanelUsesFixedSizePersistentUtilityWindowPolicy() {
        let panel = MenuBarStatusPanel(contentRect: .zero)
        defer { panel.close() }

        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.styleMask.contains(.resizable))
        let expectedCollectionBehavior: NSWindow.CollectionBehavior = [
            .moveToActiveSpace,
            .ignoresCycle,
            .fullScreenAuxiliary,
            .canJoinAllApplications,
        ]
        XCTAssertEqual(panel.collectionBehavior, expectedCollectionBehavior)
        XCTAssertTrue(panel.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
        XCTAssertFalse(panel.collectionBehavior.contains(.transient))
        XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertFalse(panel.preservesContentDuringLiveResize)

        let expectedTitle = L10n.text(
            "存储清理助手菜单栏面板",
            "Storage Cleaner Menu Bar Panel"
        )
        XCTAssertEqual(panel.title, expectedTitle)
        XCTAssertEqual(panel.accessibilityLabel(), expectedTitle)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.acceptsMouseMovedEvents)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        // The shared transparent panel must not cast a union-sized shadow;
        // each SwiftUI MetricPanelShell owns its individual shadow instead.
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)

        XCTAssertEqual(panel.animationBehavior, .none)
    }

    func testAlwaysOnTopCanBeEnabledAndDisabledWithoutChangingWindowRole() {
        let panel = MenuBarStatusPanel(contentRect: .zero)
        defer { panel.close() }
        let originalStyleMask = panel.styleMask

        panel.setAlwaysOnTop(true)
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertEqual(panel.styleMask, originalStyleMask)

        panel.setAlwaysOnTop(false)
        XCTAssertFalse(panel.isFloatingPanel)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertEqual(panel.styleMask, originalStyleMask)
    }
}
