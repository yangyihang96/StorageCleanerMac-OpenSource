import Foundation
import XCTest
@testable import StorageCleanerMac

/// D247: a level-one card's anchor registration reacts only to what it
/// registers: the card's frame in the overview's own space beside a secondary
/// page, and only the card's top offset there with the overview alone (the
/// native reader gives that rect and re-reports when the card, an ancestor or
/// the window moves, 3f78cf63). The card's frame in the window (read since
/// 181623c7, before the native reader followed moves) changed with each frame
/// the panel applied while opening, several times in one frame, and SwiftUI
/// logged "onChange(of: Trigger) action tried to update multiple times per
/// frame" once per card (install22 12:44:25.908, five reports).
@MainActor
final class GeekAnchorTriggerD247Tests: XCTestCase {
    func testTheRegistrationDoesNotReadTheCardFrameInTheWindow() throws {
        let source = SwiftSourceScanning.code(try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPanelComponents.swift"),
            encoding: .utf8))
        let registration = SwiftSourceScanning.compact(try SwiftSourceScanning.body(
            of: "struct GeekModuleAnchorRegistration: ViewModifier", in: source))
        XCTAssertFalse(registration.contains(".global"), registration)
        XCTAssertFalse(registration.contains("windowFrame"), registration)
        XCTAssertTrue(registration.contains("lettrigger=Trigger(layoutFrame:proxy.frame(in:.named(GeekOverviewAnchorSpace.name)),"
            + "placement:placement)"), registration)
        XCTAssertTrue(registration.contains(".onChange(of:trigger,initial:true)"), registration)
    }

    /// With the overview alone only the card's top offset counts: a wider,
    /// narrower or shifted layout of the same card is no new trigger.
    func testOverviewAloneTriggersOnTheCardTopOffsetOnly() {
        typealias Trigger = GeekModuleAnchorRegistration.Trigger
        let card = CGRect(x: 8, y: 135, width: 288, height: 112)
        let trigger = Trigger(layoutFrame: card, placement: .overviewOnly)
        XCTAssertEqual(trigger.layoutFrame.minY, 135)
        XCTAssertEqual(trigger, Trigger(layoutFrame: CGRect(x: 0, y: 135, width: 301, height: 90), placement: .overviewOnly))
        XCTAssertNotEqual(trigger, Trigger(layoutFrame: card.offsetBy(dx: 0, dy: 0.5), placement: .overviewOnly))
    }

    /// Beside a secondary page the whole layout frame is what is registered.
    func testBesideASecondaryPageTheWholeLayoutFrameCounts() {
        typealias Trigger = GeekModuleAnchorRegistration.Trigger
        let overview = NSRect(x: 700, y: 220, width: 304, height: 605)
        let card = CGRect(x: 8, y: 8, width: 288, height: 106)
        let trigger = Trigger(layoutFrame: card, placement: .attached(overviewScreenFrame: overview))
        XCTAssertEqual(trigger.layoutFrame, card)
        XCTAssertNotEqual(trigger, Trigger(layoutFrame: card.insetBy(dx: 1, dy: 0),
                                           placement: .attached(overviewScreenFrame: overview)))
        XCTAssertNotEqual(trigger, Trigger(layoutFrame: card, placement: .attached(overviewScreenFrame: nil)))
        XCTAssertNotEqual(Trigger(layoutFrame: card, placement: .overviewOnly),
                          Trigger(layoutFrame: card, placement: .attached(overviewScreenFrame: nil)))
    }
}
