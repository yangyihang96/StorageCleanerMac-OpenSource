#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor final class BrowserPrivacyPerformanceTests: XCTestCase {
    func testNativeSearchFieldRemainsEditableDuringDebounce() async throws {
        let store = await BrowserPrivacyPreviewFixture.makeResultStore()
        // N20: this native TextField cell publishes its placeholder rather
        // than a label through the generic AX host. Inspect the actual
        // AppKit text control hosted by the complete production result page.
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: BrowserPrivacyRecordResultsView(store: store)
            .environment(\.featureDisablesLayoutAnimations, true))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1070, height: 650),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        func fields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        // Let the initial onAppear/search binding and native view settle.
        try await Task.sleep(for: .milliseconds(50))
        controller.view.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(fields(in: controller.view).first { $0.isEditable },
            "The production result page must host a real editable text control")
        store.filters.query = "superseded-query"
        try await Task.sleep(for: .milliseconds(50))
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(store.isFiltering)
        XCTAssertTrue(field.isEnabled && field.isEditable,
            "A pending search must not disable the native text field and lose subsequent keystrokes")
        store.filters.query = "step-2"
        await store.waitForFilteredResults()
        XCTAssertEqual(store.filteredRecords.count, 1)
        XCTAssertTrue(store.filteredRecords[0].url?.contains("step-2") == true)
    }

    func testFiftyThousandRecordsCacheDebounceAndSearchStayResponsive() async throws {
        // A small index distinguishes deliberate debounce from an expensive
        // worker merely taking longer than a frame to finish.
        let small = await BrowserPrivacyPreviewFixture.makeResultStore()
        let smallBuilds = small.presentationBuildCount
        small.filters.query = "step-2"
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(small.presentationBuildCount, smallBuilds, "Do not publish immediately after a keystroke")
        XCTAssertTrue(small.isFiltering)
        await small.waitForFilteredResults()
        XCTAssertEqual(small.filteredRecords.count, 1)
        let start = ContinuousClock.now
        let store = await BrowserPrivacyPreviewFixture.makeResultStore(outcome: Self.largeOutcome())
        let initial = start.duration(to: .now).seconds
        XCTAssertEqual(store.records.count, 50_000)
        XCTAssertEqual(store.resultPresentation?.groups.flatMap(\.sites).count, 2_000)
        XCTAssertLessThan(initial, 6, "50k scan-to-index budget; fixture scan includes no disk IO")
        let buildCount = store.presentationBuildCount
        let request = ContinuousClock.now
        store.filters.query = "needle-target"
        let requestSeconds = request.duration(to: .now).seconds
        XCTAssertLessThan(requestSeconds, 0.05, "A keystroke cannot synchronously aggregate 50k records on the main actor")
        let heartbeat = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertLessThan(heartbeat.duration(to: .now).seconds, 0.15, "The main actor remains schedulable during search")
        XCTAssertEqual(store.presentationBuildCount, buildCount, "200ms debounce cannot publish on the first keystroke")
        await store.waitForFilteredResults()
        let response = request.duration(to: .now).seconds
        XCTAssertLessThan(response, 0.8, "Search response includes the 200ms debounce")
        XCTAssertEqual(store.filteredRecords.count, 1)
        XCTAssertEqual(store.filteredRecords[0].title, "needle-target")
        store.filters.query = "superseded"
        store.filters.query = "domain0000.example"
        await store.waitForFilteredResults()
        XCTAssertEqual(store.filteredRecords.count, 25, "Only the newest generation may publish")
        let count = store.presentationBuildCount
        store.filters.query = "needle-target"
        await store.waitForFilteredResults()
        XCTAssertEqual(store.presentationBuildCount, count, "Repeated scan-version/filter reuses the aggregate snapshot")
        XCTAssertGreaterThan(store.presentationCacheHitCount, 0)
        store.setSelected(true, recordID: store.filteredRecords[0].id)
        XCTAssertEqual(store.presentationBuildCount, count, "Selection redraw does not rebuild the index")
        store.startScan()
        await store.waitUntilIdle()
        XCTAssertGreaterThan(store.presentationBuildCount, count, "A new record-set version invalidates the cache")
        print("B5 performance: initial=\(initial)s keystroke=\(requestSeconds)s search=\(response)s")
    }

    func testFiftyThousandExpandedPagesBuildOnlyViewportRows() async throws {
        // Report the original row-budget failure on bounded fixtures before
        // an eager-stack mutation can exhaust the host with 50,000 pages.
        guard try await viewportFitsBudget(recordCount: 1_000, domainCount: 1) else { return }
        guard try await viewportFitsBudget(recordCount: 400, domainCount: 400) else { return }
        // Keep both original stress cases after the preflight passes.
        for domainCount in [2_000, 1] {
            guard try await viewportFitsBudget(recordCount: 50_000, domainCount: domainCount) else { return }
        }
    }

    private func viewportFitsBudget(recordCount: Int, domainCount: Int) async throws -> Bool {
        let store = await BrowserPrivacyPreviewFixture.makeResultStore(
            outcome: Self.largeOutcome(recordCount: recordCount, domainCount: domainCount))
        store.expandedSiteIDs = Set(store.resultPresentation!.groups.flatMap(\.sites).map(\.id))
        BrowserPrivacyRenderProbe.reset(); BrowserPrivacyRenderProbe.isEnabled = true
        defer { BrowserPrivacyRenderProbe.isEnabled = false }
        let start = ContinuousClock.now
        let size = CGSize(width: 1070, height: 650)
        let host = CalibrationAppKitLayoutHost(root: BrowserPrivacyRecordResultsView(store: store)
            .environment(\.featureDisablesLayoutAnimations, true), size: size, dark: true)
        defer { host.close() }
        _ = try await host.frames(required: ["lightfield.privacy.page", "lightfield.privacy.document", "fixture.viewport"], size: size)
        let elapsed = start.duration(to: .now).seconds
        let domains = BrowserPrivacyRenderProbe.domains, pages = BrowserPrivacyRenderProbe.pages
        print("B5 viewport: records=\(recordCount) domains=\(domainCount) \(elapsed)s domain-builds=\(domains) page-builds=\(pages)")
        XCTAssertGreaterThan(domains, 0)
        XCTAssertGreaterThan(pages, 0)
        XCTAssertLessThan(domains, 200, "Do not construct all domain views; preserve the original viewport budget")
        XCTAssertLessThan(pages, 300, "Do not construct all page views; preserve the original viewport budget")
        guard domains > 0, pages > 0, domains < 200, pages < 300 else { return false }
        XCTAssertLessThan(elapsed, 1, "First viewport budget with every domain expanded")
        return elapsed < 1
    }

    nonisolated static func largeOutcome(recordCount: Int = 50_000, domainCount: Int = 2_000) -> BrowserPrivacyScanOutcome {
        let browser = BrowserPrivacyBrowser(id: "chrome", displayName: "Chrome", engine: .chromium,
            bundleIdentifier: nil, version: "fixture")
        let base = Date()
        let records = (0..<recordCount).map { index in
            let domain = String(format: "domain%04d.example", index % domainCount)
            return BrowserPrivacyRecord(id: UUID(), browser: browser, profileID: "chrome:Fixture", profileDisplayName: "Fixture",
                source: .history, url: "https://\(domain)/page/\(index / domainCount)", domain: domain,
                title: index == recordCount - 1 ? "needle-target" : "Page \(index)", searchKeyword: nil,
                visitedAt: base.addingTimeInterval(Double(-index)), visitCount: 1, category: .news,
                selectionConfidence: .medium, sizeBytes: nil)
        }
        return .init(state: .completed, records: records, coverage: [])
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
#endif
