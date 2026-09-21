import SwiftUI
import XCTest
@testable import StorageCleanerMac

final class GeekInlineTertiaryContentStoreTests: XCTestCase {
    @MainActor
    func testHiddenDetailDoesNotBuildItsHistoryView() throws {
        var buildCount = 0
        func detail() -> Text {
            buildCount += 1
            return Text("History")
        }
        let view = GeekHoverDetailTarget(
            accessibilityLabel: "History",
            popoverSize: CGSize(width: 380, height: 216),
            target: { Color.blue.frame(width: 20, height: 20) },
            detail: { detail() }
        )
        XCTAssertNotNil(ImageRenderer(content: view).cgImage)
        XCTAssertEqual(buildCount, 0, "Closed detail must not prepare a history graph on every telemetry update")
    }

    @MainActor
    func testNewReadingReachesAnOpenDetailWithinOneInteractionFrameBudget() async throws {
        let store = GeekInlineTertiaryContentStore()
        store.update(tile(.red))
        store.update(tile(.green))
        try await Task.sleep(for: .milliseconds(150))
        let color = try renderedColor(store.content)
        let expected = try renderedColor(tile(.green))
        XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.005)
    }

    @MainActor
    func testFinalThrottledUpdatePublishesWithoutAnotherSample() async throws {
        let store = GeekInlineTertiaryContentStore()
        store.update(tile(.red))
        store.update(tile(.blue))
        store.update(tile(.green))

        try await Task.sleep(for: .seconds(1.1))

        let color = try renderedColor(store.content)
        let expected = try renderedColor(tile(.green))
        XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.005)
        XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.005)
        XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.005)
    }

    @MainActor
    func testForcedRangeChangeCancelsOlderQueuedContent() async throws {
        let store = GeekInlineTertiaryContentStore()
        store.update(tile(.red))
        store.update(tile(.green))
        store.update(tile(.blue), force: true)

        try await Task.sleep(for: .seconds(1.1))

        let color = try renderedColor(store.content)
        let expected = try renderedColor(tile(.blue))
        XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.005)
        XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.005)
        XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.005)
    }

    @MainActor
    private func tile(_ color: NSColor) -> AnyView {
        AnyView(Color(nsColor: color).frame(width: 8, height: 8))
    }

    @MainActor
    private func renderedColor(_ view: AnyView) throws -> NSColor {
        let renderer = ImageRenderer(content: view)
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        return try XCTUnwrap(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB))
    }
}
