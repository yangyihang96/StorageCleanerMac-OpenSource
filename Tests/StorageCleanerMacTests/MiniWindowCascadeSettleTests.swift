import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Batch r2-mini-speed: opening a level-two page placed the cascade three or
/// four times (audit: section, anchorRemoved, anchor, detailSize), each a
/// synchronous `setFrame(display: true)` of the whole panel. The level-one
/// cards are rebuilt when the overview moves into the attached shell; the
/// rebuilt card's anchor is removed and registered again a turn later, and
/// the placement in between used the default offset, so the page was drawn
/// misplaced for a frame and then moved back.
@MainActor
final class MiniWindowCascadeSettleTests: XCTestCase {
    func testARebuiltLevelOneCardDoesNotMoveTheOpenPage() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first, "Tests require an attached screen")
        let suiteName = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suiteName))
        defer { TestPreferenceDomain.cleanup(suiteName: suiteName) }
        let coordinator = GeekPanelCoordinator()
        let panel = MenuBarStatusPanel(contentRect: .zero)
        panel.isReleasedWhenClosed = false
        let visible = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let session = MenuBarPanelSession(
            panel: panel, rootView: AnyView(EmptyView()), initialDensity: .geek,
            geometryStore: PanelGeometryStore(defaults: defaults),
            panelSettingsState: MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults),
            panelCoordinator: coordinator,
            pointerLocationProvider: { NSPoint(x: -10_000, y: -10_000) },
            applicationIsActiveProvider: { true },
            fixedVisibleFrame: visible, presentsPanelOnShow: false, onClose: {}
        )
        defer { session.teardown() }
        session.show(anchor: NSRect(x: visible.midX - 12, y: visible.maxY - 24, width: 24, height: 20),
                     screen: screen, density: .geek)

        func registerDiskCard() {
            coordinator.registerAnchor(
                id: .module(.disk),
                screenRect: NSRect(x: 900, y: 400, width: 288, height: 78),
                contentKind: "disk",
                layoutOffset: 248
            )
        }
        registerDiskCard()
        session.setGeekSection(.disk)
        let placed = session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(placed.count, 2)
        XCTAssertEqual(placed[1].maxY - placed[0].maxY, 248, accuracy: 0.5, "aligned with the disk card")
        let defaultOffset = GeekPanelPresentationMetrics.detailVerticalOffset(for: .disk, density: .geek)
        XCTAssertNotEqual(defaultOffset, 248, accuracy: 0.5, "the default offset would misplace the page")

        var appliedFrames = 0
        session.programmaticFrameDidApplyForTesting = { appliedFrames += 1 }
        defer { session.programmaticFrameDidApplyForTesting = nil }

        // The card is rebuilt: its anchor goes away; the measured page size
        // arrives before the rebuilt card registers again.
        coordinator.removeAnchor(.module(.disk))
        XCTAssertEqual(session.visibleAttachedContentFramesForTesting, placed,
                       "the page stays at its card while the card is rebuilt")
        session.setGeekSection(.disk)
        XCTAssertEqual(session.visibleAttachedContentFramesForTesting, placed)
        registerDiskCard()
        XCTAssertEqual(session.visibleAttachedContentFramesForTesting, placed)
        XCTAssertEqual(appliedFrames, 0, "no frame is applied for a card rebuilt in place")

        // A card that really moved still moves the page.
        coordinator.registerAnchor(
            id: .module(.disk),
            screenRect: NSRect(x: 900, y: 300, width: 288, height: 78),
            contentKind: "disk",
            layoutOffset: 332
        )
        let moved = session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(moved[1].maxY - moved[0].maxY, 332, accuracy: 0.5)
        XCTAssertEqual(appliedFrames, 1)

        // A new presentation starts without remembered offsets.
        session.hide(reason: "test")
        coordinator.removeAnchor(.module(.disk))
        session.show(anchor: NSRect(x: visible.midX - 12, y: visible.maxY - 24, width: 24, height: 20),
                     screen: screen, density: .geek)
        session.setGeekSection(.disk)
        let reopened = session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(reopened[1].maxY - reopened[0].maxY, defaultOffset, accuracy: 0.5,
                       "without an anchor in this presentation the default offset applies")
    }

    // MARK: - Review of phase 1, P2-2

    @MainActor
    private struct Harness {
        let session: MenuBarPanelSession
        let coordinator: GeekPanelCoordinator
        let settings: MenuBarPanelSettingsState
        let screen: NSScreen
        let anchor: NSRect
        let defaults: UserDefaults
        let suiteName: String
        func tearDown() {
            session.teardown()
            TestPreferenceDomain.cleanup(suiteName: suiteName)
        }
    }

    private func makeHarness() throws -> Harness {
        let screen = try XCTUnwrap(NSScreen.screens.first, "Tests require an attached screen")
        let suiteName = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suiteName))
        let coordinator = GeekPanelCoordinator()
        let settings = MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults)
        let panel = MenuBarStatusPanel(contentRect: .zero)
        panel.isReleasedWhenClosed = false
        let visible = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let session = MenuBarPanelSession(
            panel: panel, rootView: AnyView(EmptyView()), initialDensity: .geek,
            geometryStore: PanelGeometryStore(defaults: defaults),
            panelSettingsState: settings,
            panelCoordinator: coordinator,
            pointerLocationProvider: { NSPoint(x: -10_000, y: -10_000) },
            applicationIsActiveProvider: { true },
            fixedVisibleFrame: visible, presentsPanelOnShow: false, onClose: {}
        )
        let anchor = NSRect(x: visible.midX - 12, y: visible.maxY - 24, width: 24, height: 20)
        session.show(anchor: anchor, screen: screen, density: .geek)
        return Harness(session: session, coordinator: coordinator, settings: settings, screen: screen,
                       anchor: anchor, defaults: defaults, suiteName: suiteName)
    }

    /// Places the disk page at its card (offset 248), then rebuilds the card
    /// so its anchor is missing while the page is placed again.
    private func placeDiskPageAndDropItsAnchor(_ harness: Harness) -> CGFloat {
        harness.coordinator.registerAnchor(
            id: .module(.disk), screenRect: NSRect(x: 900, y: 400, width: 288, height: 78),
            contentKind: "disk", layoutOffset: 248)
        harness.session.setGeekSection(.disk)
        harness.coordinator.removeAnchor(.module(.disk))
        let frames = harness.session.visibleAttachedContentFramesForTesting
        return frames[1].maxY - frames[0].maxY
    }

    private func currentDetailOffset(_ harness: Harness) -> CGFloat {
        harness.session.setGeekSection(.disk)
        let frames = harness.session.visibleAttachedContentFramesForTesting
        return frames[1].maxY - frames[0].maxY
    }

    /// The remembered offset is the card's place in one overview layout:
    /// another density, another overview size or another dashboard layout
    /// (modules reordered or hidden) forgets it.
    func testTheRememberedOffsetIsForgottenWhenTheOverviewLayoutChanges() throws {
        let defaultOffset = GeekPanelPresentationMetrics.detailVerticalOffset(for: .disk, density: .geek)

        let density = try makeHarness()
        defer { density.tearDown() }
        XCTAssertEqual(placeDiskPageAndDropItsAnchor(density), 248, accuracy: 0.5)
        density.session.selectDensity(.geek)
        XCTAssertEqual(currentDetailOffset(density), defaultOffset, accuracy: 0.5, "a new density forgets it")

        let size = try makeHarness()
        defer { size.tearDown() }
        XCTAssertEqual(placeDiskPageAndDropItsAnchor(size), 248, accuracy: 0.5)
        let overview = GeekPanelPresentationMetrics.normalizedOverviewSize(nil)
        let smaller = CGSize(width: overview.width, height: overview.height - 40)
        size.session.setOverviewSize(smaller)
        XCTAssertEqual(currentDetailOffset(size),
                       GeekPanelPresentationMetrics.detailVerticalOffset(for: .disk, density: .geek, overviewSize: smaller),
                       accuracy: 0.5, "a new overview size forgets it")

        let layout = try makeHarness()
        defer { layout.tearDown() }
        XCTAssertEqual(placeDiskPageAndDropItsAnchor(layout), 248, accuracy: 0.5)
        layout.settings.updateGeekDashboardConfiguration { configuration in
            configuration.modules.reverse()
        }
        XCTAssertEqual(currentDetailOffset(layout), defaultOffset, accuracy: 0.5,
                       "another dashboard layout forgets it, even at the same overview size")
    }

    /// A remembered offset is clamped like a registered one, against the
    /// overview frame and page height of the placement that uses it, not
    /// reused as it was clamped when it was remembered.
    func testARememberedOffsetIsClampedToTheCurrentLimit() throws {
        let clamp = MenuBarPanelSession.clampedDetailTopOffset
        XCTAssertEqual(clamp(248, 600, 400), 248)
        XCTAssertEqual(clamp(700, 600, 400), 556, "overview height minus min(44, page height)")
        XCTAssertEqual(clamp(700, 600, 30), 570)
        XCTAssertEqual(clamp(-5, 600, 400), 0)
        XCTAssertNil(clamp(.nan, 600, 400))
        let session = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Support/MenuBarPanelSession.swift")
        XCTAssertTrue(session.contains("?? anchoredDetailTopOffsets[section].flatMap {"),
                      "the remembered offset is clamped again where it is used")
    }
}
