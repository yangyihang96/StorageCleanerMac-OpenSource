import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class MiniWindowSinglePageTests: XCTestCase {
    func testCompleteMeasuredPagesCanGrowBeyondOldViewportLimits() {
        for density in [PanelDensity.geek, .complex] {
            for section in PanelSection.allCases where section != .overview {
                let initial = GeekPanelPresentationMetrics.detailSize(for: section, density: density)
                let content = CGSize(width: initial.width, height: initial.height + 140)
                XCTAssertEqual(GeekPanelPresentationMetrics.normalizedDetailSize(
                    content, for: section, density: density), content)
            }
        }
        XCTAssertEqual(GeekPanelPresentationMetrics.normalizedTertiarySize(
            CGSize(width: 380, height: 680)), CGSize(width: 380, height: 680))
    }

    func testTallPagesStayInsideShortDisplayWithAllThreeLevelsPresent() {
        let visible = CGRect(x: 0, y: 0, width: 1280, height: 620)
        let parent = CGRect(x: 968, y: 16, width: 304, height: 588)
        let layout = MenuBarPanelPlacement.cascade(
            parentFrame: parent,
            childSizes: [CGSize(width: 312, height: 900), CGSize(width: 380, height: 720)],
            visibleFrame: visible)
        XCTAssertEqual(layout.childFrames.count, 2)
        XCTAssertEqual(layout.tertiaryPresentationMode, .column)
        for frame in layout.visibleFrames {
            XCTAssertTrue(visible.insetBy(dx: 8, dy: 8).contains(frame))
        }
        XCTAssertFalse(layout.childFrames[0].intersects(layout.childFrames[1]))
        XCTAssertEqual(MiniWindowPageFit.scale(content: CGSize(width: 312, height: 599),
            available: CGSize(width: 312, height: 599)), 1)
    }

    func testScreenConstrainedPageRendersBothEndsWithoutScrollViews() async throws {
        let natural = CGSize(width: 312, height: 900)
        let available = CGSize(width: 312, height: 480)
        let host = NSHostingView(rootView: MiniWindowFittedPage(contentSize: natural, availableSize: available) {
            bookends(height: natural.height)
        })
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: available)
        try await checkBothEnds(in: host)
    }

    func testDetachedPageKeepsNaturalHeightWhenItsWindowIsConstrained() async throws {
        var measured: CGSize?
        let host = NSHostingView(rootView: MiniWindowMeasuredPage(
            initialSize: CGSize(width: 280, height: 340),
            reportSize: { measured = $0 }
        ) {
            bookends(height: 900)
        })
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 480)
        try await checkBothEnds(in: host)
        XCTAssertEqual(try XCTUnwrap(measured).height, 900, accuracy: 0.5)
    }

    private func bookends(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.red.frame(height: 28)
            Color.black.frame(height: height - 56)
            Color.blue.frame(height: 28)
        }
        .frame(height: height)
    }

    private func checkBothEnds(in host: NSView) async throws {
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        func hasScrollView(_ view: NSView) -> Bool {
            view is NSScrollView || view.subviews.contains(where: hasScrollView)
        }
        XCTAssertFalse(hasScrollView(host))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var redRows: [Int] = []
        var blueRows: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.redComponent > 0.7 && color.blueComponent < 0.3 { redRows.append(y) }
            if color.blueComponent > 0.7 && color.redComponent < 0.3 { blueRows.append(y) }
        }
        XCTAssertFalse(redRows.isEmpty, "The first row must remain visible")
        XCTAssertFalse(blueRows.isEmpty, "The last row must remain visible")
        let extremes = redRows + blueRows
        XCTAssertLessThan(try XCTUnwrap(extremes.min()), 4)
        XCTAssertGreaterThan(try XCTUnwrap(extremes.max()), bitmap.pixelsHigh - 4)
    }
}
