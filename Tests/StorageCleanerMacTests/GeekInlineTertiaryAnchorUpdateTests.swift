import SwiftUI
import XCTest
@testable import StorageCleanerMac

final class GeekInlineTertiaryAnchorUpdateTests: XCTestCase {
    @MainActor
    func testMovingAnOpenSourceKeepsItsRequestContentPinAndHistoryInteraction() throws {
        let id = UUID()
        let content = GeekInlineTertiaryContentStore()
        let hover = AnchorHoverRecorder()
        let coordinator = GeekPanelCoordinator(initialSection: .sensors)
        XCTAssertTrue(coordinator.presentHistory(.inline(id), pinned: true))
        let interaction = try XCTUnwrap(coordinator.beginHistoryInteraction())
        let originalRoute = coordinator.route
        let originalContentIdentity = content.identity
        var current: GeekInlineTertiaryRequest? = request(
            id: id, store: content, hover: hover, pinned: true, offset: 74
        )

        for offset in [CGFloat(80), 133, 27, 206] {
            XCTAssertTrue(GeekInlineTertiaryRequest.updateSourceOffset(
                id: id, offset: offset, currentRequest: &current, route: coordinator.route
            ))
            let updated = try XCTUnwrap(current)
            XCTAssertEqual(updated.id, id)
            XCTAssertEqual(updated.sourceOffset, offset)
            XCTAssertTrue(updated.isPinned)
            XCTAssertEqual(updated.chartRangeMetric, .temperature)
            XCTAssertEqual(updated.preferredSize, CGSize(width: 220, height: 216))
            XCTAssertEqual(updated.accessibilityLabel, "Sensor history")
            XCTAssertTrue(updated.contentStore === content)
            XCTAssertEqual(updated.contentStore.identity, originalContentIdentity)
            XCTAssertEqual(coordinator.route, originalRoute)
            XCTAssertTrue(coordinator.isHistoryPinned)
            XCTAssertEqual(coordinator.historyInteractionToken, interaction)
        }
        try XCTUnwrap(current).hoverChanged(true)
        try XCTUnwrap(current).hoverChanged(false)
        XCTAssertEqual(hover.values, [true, false])
    }

    @MainActor
    func testUnpinnedGeometryUpdateDoesNotPromoteOrReopenHistory() throws {
        let id = UUID()
        let coordinator = GeekPanelCoordinator(initialSection: .disk)
        XCTAssertTrue(coordinator.presentHistory(.inline(id), pinned: false))
        var current: GeekInlineTertiaryRequest? = request(id: id, pinned: false, offset: 106)
        let route = coordinator.route

        XCTAssertTrue(GeekInlineTertiaryRequest.updateSourceOffset(
            id: id, offset: 159, currentRequest: &current, route: coordinator.route
        ))

        XCTAssertFalse(try XCTUnwrap(current).isPinned)
        XCTAssertEqual(coordinator.route, route)
        XCTAssertFalse(coordinator.isHistoryPinned)
        XCTAssertNil(coordinator.historyInteractionToken)
    }

    @MainActor
    func testClosedOrReplacedRouteRejectsLateGeometryEvenBeforeRequestStateIsCleared() throws {
        let id = UUID()
        let newerID = UUID()
        let rejectedRoutes: [GeekPanelRoute] = [
            .summary,
            .module(.sensors),
            .history(module: .sensors, selection: .builtIn("temperature")),
            .history(module: .sensors, selection: .inline(newerID)),
        ]
        for route in rejectedRoutes {
            var current: GeekInlineTertiaryRequest? = request(id: id, pinned: true, offset: 80)
            XCTAssertFalse(GeekInlineTertiaryRequest.updateSourceOffset(
                id: id, offset: 206, currentRequest: &current, route: route
            ))
            XCTAssertEqual(try XCTUnwrap(current).sourceOffset, 80)
            XCTAssertEqual(try XCTUnwrap(current).id, id)
            XCTAssertTrue(try XCTUnwrap(current).isPinned)
        }
        var closed: GeekInlineTertiaryRequest?
        XCTAssertFalse(GeekInlineTertiaryRequest.updateSourceOffset(
            id: id, offset: 206, currentRequest: &closed,
            route: .history(module: .sensors, selection: .inline(id))
        ))
        XCTAssertNil(closed)
    }

    @MainActor
    func testOlderTargetCannotOverwriteTheCurrentRequestOrItsContent() throws {
        let oldID = UUID()
        let activeID = UUID()
        let activeContent = GeekInlineTertiaryContentStore()
        var current: GeekInlineTertiaryRequest? = request(
            id: activeID, store: activeContent, pinned: true, offset: 159
        )
        XCTAssertFalse(GeekInlineTertiaryRequest.updateSourceOffset(
            id: oldID, offset: 27, currentRequest: &current,
            route: .history(module: .disk, selection: .inline(activeID))
        ))
        XCTAssertEqual(try XCTUnwrap(current).id, activeID)
        XCTAssertEqual(try XCTUnwrap(current).sourceOffset, 159)
        XCTAssertTrue(try XCTUnwrap(current).contentStore === activeContent)

        // Also reject inconsistent host state: the route itself still names
        // the old request, but the mounted request has already been replaced.
        XCTAssertFalse(GeekInlineTertiaryRequest.updateSourceOffset(
            id: oldID, offset: 27, currentRequest: &current,
            route: .history(module: .disk, selection: .inline(oldID))
        ))
        XCTAssertEqual(try XCTUnwrap(current).sourceOffset, 159)
    }

    @MainActor
    func testIdenticalAndNonFiniteGeometryDoNotTriggerAnotherPlacement() throws {
        let id = UUID()
        var current: GeekInlineTertiaryRequest? = request(id: id, offset: 80)
        let route = GeekPanelRoute.history(module: .sensors, selection: .inline(id))
        for offset in [CGFloat(80), .nan, .infinity, -.infinity] {
            XCTAssertFalse(GeekInlineTertiaryRequest.updateSourceOffset(
                id: id, offset: offset, currentRequest: &current, route: route
            ))
            XCTAssertEqual(try XCTUnwrap(current).sourceOffset, 80)
        }
        XCTAssertTrue(GeekInlineTertiaryRequest.updateSourceOffset(
            id: id, offset: -6, currentRequest: &current, route: route
        ))
        XCTAssertEqual(try XCTUnwrap(current).sourceOffset, 0)
        XCTAssertFalse(GeekInlineTertiaryRequest.updateSourceOffset(
            id: id, offset: -2, currentRequest: &current, route: route
        ))
    }

    @MainActor
    private func request(
        id: UUID,
        store: GeekInlineTertiaryContentStore? = nil,
        hover: AnchorHoverRecorder? = nil,
        pinned: Bool = false,
        offset: CGFloat
    ) -> GeekInlineTertiaryRequest {
        GeekInlineTertiaryRequest(
            id: id,
            accessibilityLabel: "Sensor history",
            chartRangeMetric: .temperature,
            preferredSize: CGSize(width: 220, height: 216),
            isPinned: pinned,
            sourceOffset: offset,
            contentStore: store ?? GeekInlineTertiaryContentStore(),
            hoverChanged: { hover?.values.append($0) }
        )
    }
}

@MainActor
private final class AnchorHoverRecorder {
    var values: [Bool] = []
}
