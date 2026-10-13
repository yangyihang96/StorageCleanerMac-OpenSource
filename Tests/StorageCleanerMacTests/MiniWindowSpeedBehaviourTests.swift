import Foundation
import XCTest
@testable import StorageCleanerMac

/// Batch r2-mini-speed: behaviour behind MiniWindowSpeedTests.
@MainActor
final class MiniWindowSpeedBehaviourTests: XCTestCase {
    /// Review of phase 1, P2-3: the identity `liveCard` gives a card, through
    /// the same function, for every page that can be open. A level-one card
    /// (it names the overview page, see MiniWindowSpeedTests) keeps one
    /// identity whichever level-two page is open; a card of a level-two page
    /// still has the open page in its identity.
    func testLevelOneCardIdentityDoesNotDependOnTheOpenPage() {
        func identity(named page: String?, open section: PanelSection) -> String {
            MenuBarCardIdentity.key(page: MenuBarCardIdentity.page(named: page, openSection: section),
                                    domain: .cpu, file: "MenuBarGeekPanel.swift", line: 189, column: 25)
        }
        let levelOne = Set(PanelSection.allCases.map { identity(named: MenuBarCardIdentity.overviewPage, open: $0) })
        XCTAssertEqual(levelOne.count, 1, "one identity, so switching pages does not rebuild the level-one card")
        XCTAssertEqual(MenuBarCardIdentity.page(named: MenuBarCardIdentity.overviewPage, openSection: .processor),
                       PanelSection.overview.rawValue, "the identity it had when only the overview was open")
        let levelTwo = Set(PanelSection.allCases.map { identity(named: nil, open: $0) })
        XCTAssertEqual(levelTwo.count, PanelSection.allCases.count, "a level-two card keeps its page in its identity")
    }

    /// The level-three card follows both prepared histories, so a range
    /// selected in it is drawn as soon as the monitor delivers the window.
    func testLevelThreeCardRedrawsWhenAPreparedWindowIsDelivered() async throws {
        typealias Revision = MenuBarCardHistoryRevision
        XCTAssertEqual(Revision.label(domain: .levelThree, activeHistoryMetric: nil, telemetryVersion: 7, memoryVersion: 3), "7:3")
        XCTAssertNotEqual(Revision.label(domain: .levelThree, activeHistoryMetric: nil, telemetryVersion: 7, memoryVersion: 4),
                          Revision.label(domain: .levelThree, activeHistoryMetric: nil, telemetryVersion: 7, memoryVersion: 3))
        XCTAssertNil(MenuBarCardDomain.levelThree.freshnessKey)

        let monitor = MenuBarMonitorState()
        monitor.restoreHistory(MiniWindowHistoryDemandTests.points(),
                               memoryPoints: MiniWindowHistoryDemandTests.points())
        let card = MenuBarCardModel(sources: [monitor.objectWillChange.eraseToAnyPublisher()]) {
            var fingerprint = MenuBarCardFingerprint()
            if let label = Revision.label(domain: .levelThree, activeHistoryMetric: nil,
                                          telemetryVersion: monitor.displayTelemetryVersion,
                                          memoryVersion: monitor.displayMemoryVersion) {
                fingerprint.labels.append(label)
            }
            return fingerprint
        }
        // A range is selected: the monitor prepares its window off the main
        // thread; the card is redrawn when it is delivered.
        monitor.setDisplayHistoryDemand([86_400])
        try await wait { monitor.displayTelemetryVersion > 0 }
        try await wait { card.revision.version > 0 }
        XCTAssertGreaterThan(card.revision.version, 0)
        let afterFirst = card.revision.version
        monitor.setDisplayHistoryDemand([604_800])
        let telemetry = monitor.displayTelemetryVersion
        try await wait { monitor.displayTelemetryVersion > telemetry }
        try await wait { card.revision.version > afterFirst }
        XCTAssertGreaterThan(card.revision.version, afterFirst, "another selected range redraws again")
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
