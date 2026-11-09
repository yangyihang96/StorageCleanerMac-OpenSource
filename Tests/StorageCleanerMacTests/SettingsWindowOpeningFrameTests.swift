import Foundation
import XCTest
@testable import StorageCleanerMac

/// D274: pure placement logic. Apart from WindowGlassConfigurationTests so that
/// the non-window gate runs it; no window is created here.
final class SettingsWindowOpeningFrameTests: XCTestCase {
    func testTheWindowOpensAtTheContentsIdealSizeUntilTheUserDragsIt() {
        XCTAssertEqual(SettingsWindowPlacement.preferredSize(remembered: nil), NSSize(width: 1180, height: 760))
    }

    func testTheWindowOpensAtTheSizeTheUserDragged() {
        let dragged = NSStringFromSize(NSSize(width: 1000, height: 600))
        XCTAssertEqual(SettingsWindowPlacement.preferredSize(remembered: dragged), NSSize(width: 1000, height: 600))
    }

    func testARememberedSizeTheWindowCouldNotHaveIsIgnored() {
        for remembered in ["", "not a size", "{100, 100}", "{559, 390}", "{560, 389}"] {
            XCTAssertEqual(
                SettingsWindowPlacement.preferredSize(remembered: remembered),
                SettingsWindowPlacement.openingSize,
                remembered
            )
        }
        XCTAssertEqual(SettingsWindowPlacement.preferredSize(remembered: "{560, 390}"), NSSize(width: 560, height: 390))
    }

    /// The saved top-left of a real install, on its built-in display.
    func testTheOpeningFrameStaysWithinItsScreen() throws {
        let visible = NSRect(x: 0, y: 73, width: 1352, height: 776)
        let saved = NSRect(x: 344, y: 267, width: 900, height: 450)

        let opened = try XCTUnwrap(SettingsWindowPlacement.openingFrame(
            saved, size: SettingsWindowPlacement.openingSize, within: [visible]
        ))
        XCTAssertEqual(opened.size, SettingsWindowPlacement.openingSize)
        XCTAssertTrue(visible.contains(opened))
    }

    func testTheOpeningFrameKeepsTheTopLeftWhenThereIsRoom() {
        let visible = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let frame = NSRect(x: 100, y: 800, width: 900, height: 450)

        XCTAssertEqual(
            SettingsWindowPlacement.openingFrame(frame, size: NSSize(width: 1180, height: 760), within: [visible]),
            NSRect(x: 100, y: 490, width: 1180, height: 760)
        )
    }

    /// No second frame call, so a window already at its size does not visibly move.
    func testAWindowAlreadyAtItsSizeKeepsItsFrame() {
        let visible = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let frame = NSRect(x: 100, y: 490, width: 1180, height: 760)

        XCTAssertEqual(SettingsWindowPlacement.openingFrame(frame, size: frame.size, within: [visible]), frame)
    }

    func testTheOpeningFrameFitsASmallScreen() {
        let small = NSRect(x: 0, y: 0, width: 1024, height: 640)
        let frame = NSRect(x: 40, y: 40, width: 900, height: 450)

        XCTAssertEqual(
            SettingsWindowPlacement.openingFrame(frame, size: SettingsWindowPlacement.openingSize, within: [small]),
            small
        )
    }

    func testTheOpeningFrameStaysOnTheScreenHoldingMostOfTheWindow() throws {
        let left = NSRect(x: 0, y: 0, width: 1352, height: 776)
        let right = NSRect(x: 1352, y: 0, width: 1920, height: 1080)
        let frame = NSRect(x: 1300, y: 300, width: 900, height: 450)

        let opened = try XCTUnwrap(SettingsWindowPlacement.openingFrame(
            frame, size: SettingsWindowPlacement.openingSize, within: [left, right]
        ))
        XCTAssertTrue(right.contains(opened))
    }

    func testThereIsNoOpeningFrameWithoutAScreen() {
        XCTAssertNil(SettingsWindowPlacement.openingFrame(
            NSRect(x: 0, y: 0, width: 900, height: 450), size: SettingsWindowPlacement.openingSize, within: []
        ))
    }
}
