import Foundation
import XCTest
@testable import StorageCleanerMac

/// Batch r2-mini-speed: what made the menu-bar panel slow to show a level
/// change. Source contracts here; behaviour in MiniWindowSpeedBehaviourTests
/// and MiniWindowCascadeSettleTests.
@MainActor
final class MiniWindowSpeedTests: XCTestCase {
    /// Every level-one card took the open page into its identity, so opening
    /// or switching a level-two page rebuilt all of them: new card models and
    /// subscriptions, prepared charts started again, and each card removed and
    /// re-registered its anchor, which placed the cascade twice more.
    func testLevelOneCardsKeepOnePageWhateverPageIsOpen() throws {
        let canvas = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift")
        XCTAssertTrue(canvas.contains(
            "liveCard(overviewCardDomain(module), page: MenuBarCardIdentity.overviewPage) { geekOverviewModule(module) }"
        ), "The level-one cards use the overview page")
        let root = try source("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")
        XCTAssertTrue(root.contains(
            "liveCard(.availability, page: MenuBarCardIdentity.overviewPage) { geekOverviewPage }"
        ), "The level-one column beside a level-two page keeps the overview page")
    }

    /// A level-three page opened from its level-two page is drawn from this
    /// root view, which does not observe the monitor. It was redrawn only by
    /// an unrelated root update (in the audit, a level-two height change
    /// 0.4-9 s later), so a newly selected range stayed dimmed ("更新中…")
    /// and the history did not advance with new samples.
    func testLevelThreePagesRedrawWhenTheirDataChanges() throws {
        let tertiary = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        let surface = try XCTUnwrap(tertiary.components(separatedBy: "private func tertiaryDetailSurface(").last?
            .components(separatedBy: "func scheduleTertiaryDetailDismissal").first)
        XCTAssertTrue(surface.contains("liveCard(.levelThree) {"),
                      "The level-three page is a live card that follows its readings and prepared windows")
        let card = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarLiveCard.swift")
        let revision = try XCTUnwrap(card.components(separatedBy: "enum MenuBarCardHistoryRevision").last)
        XCTAssertTrue(revision.contains("case .levelThree:"),
                      "A level-three page redraws when a prepared window is delivered")
    }

    /// Inside its card the level-three page keeps the root's chart context.
    /// The card's revision changes with every reading it follows (about five
    /// times a second while the page is open); in a chart's preparation key
    /// it made the history frame prepare again each time, and a frame about
    /// to be delivered was dropped for the newer key. A history frame
    /// depends only on its window, which the key already contains.
    func testLevelThreeChartsArePreparedAgainOnlyForANewWindow() throws {
        let tertiary = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        let surface = try XCTUnwrap(tertiary.components(separatedBy: "private func tertiaryDetailSurface(").last?
            .components(separatedBy: "func scheduleTertiaryDetailDismissal").first)
        let card = try XCTUnwrap(surface.components(separatedBy: "liveCard(.levelThree) {").dropFirst().first)
        XCTAssertTrue(card.contains(".environment(\\.menuBarChartContext, rootChartContext)"),
                      "Charts in the level-three card use the root's preparation key")
        let root = try source("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")
        XCTAssertTrue(root.contains(".environment(\\.menuBarChartContext, rootChartContext)"),
                      "The root and the level-three page share one chart context")
    }

    // MARK: Helpers

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
