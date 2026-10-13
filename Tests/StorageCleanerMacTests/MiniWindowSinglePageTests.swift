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

    func testScreenConstrainedPageKeepsReadableBookendsReachableByScrolling() async throws {
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
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        func findScrollView(_ view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.compactMap(findScrollView).first
        }
        let scroll = try XCTUnwrap(findScrollView(host))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThanOrEqual(document.frame.height, 899, "Preserve natural height instead of scaling")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.frame.height - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxY, document.frame.height - 1, "Last row remains reachable")
    }
}
