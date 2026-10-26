#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D94: the main window keeps its close, minimize and zoom buttons on every
/// page, in one place. Hiding the window toolbar on D67 pages removed them,
/// and they stayed gone after returning to a V1 page; a toolbar on V1 pages
/// only moved them 10 pt whenever a page of the other kind opened.
@MainActor
final class MainWindowControlsTests: XCTestCase {
    /// A hosting-controller window takes each page's toolbar items, so a
    /// toolbar that only some pages have shows up here as moved buttons. It
    /// does not apply `.toolbar(.hidden, for: .windowToolbar)`, which only a
    /// WindowGroup scene does; the source check below covers that call.
    func testWindowButtonsStayInPlaceThroughD67AndV1PageSwitches() throws {
        let heavyWorkCoordinator = HeavyWorkCoordinator()
        let heavyWorkActivityStore = HeavyWorkActivityStore(coordinator: heavyWorkCoordinator)
        let scanStore = try ScanStore.makeForTests(for: self,
            heavyWorkCoordinator: heavyWorkCoordinator,
            heavyWorkActivityStore: heavyWorkActivityStore,
            restoreSavedAccessOperation: {},
            loadScanReadinessSummary: { ScanReadinessSummary(items: []) },
            historyLoader: EmptyWindowControlsHistoryLoader())
        scanStore.didCompleteInitialPermissionCheck = true
        scanStore.showFilter(.overview)
        let catalog = try MacBenchmarkBaselineCatalog(activeBaselineVersion: "window-controls-fixture", verifiedBaselines: [])
        let benchmarkStore = MacBenchmarkStore(service: WindowControlsBenchmarkService(),
            resultProcessor: MacBenchmarkResultProcessor(baselineCatalog: catalog),
            historyRepository: EmptyWindowControlsBenchmarkHistory(),
            v7PromotionRevocationDefaults: TestPreferenceDomain.make(for: self))
        let content = ContentView(
            store: scanStore,
            computerHealthStore: ComputerHealthStore(probe: TestUnavailableComputerHealthProbe(),
                batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController()),
            networkSpeedTestStore: NetworkSpeedTestStore(heavyWorkCoordinator: heavyWorkCoordinator,
                heavyWorkActivityStore: heavyWorkActivityStore),
            macBenchmarkStore: benchmarkStore,
            macBenchmarkLeaderboardStore: BenchmarkV7LeaderboardStore(identityProvider:
                DefaultBenchmarkV7LeaderboardIdentityProvider(defaults: TestPreferenceDomain.make(for: self))),
            heavyWorkActivityStore: heavyWorkActivityStore,
            browserPrivacyStore: BrowserPrivacyStore(scanner: WindowControlsPrivacyScanner()))
        let controller = NSHostingController(rootView: AnyView(content))
        controller.sizingOptions = []
        // Like the app's WindowGroup window, SwiftUI owns this window's
        // toolbar and title; a hosting controller bridges neither by default.
        controller.sceneBridgingOptions = .all
        // The app's WindowGroup window: titled, with all three buttons.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 763),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1280, height: 763))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        let route: [ReviewFilter] = [.overview, .green, .overview, .uninstall, .devCaches, .privacy, .overview]
        XCTAssertTrue(route.contains(where: FeatureLightfield.owns), "The route must cross a D67 page")
        XCTAssertTrue(route.contains(where: { !FeatureLightfield.owns($0) }), "The route must cross a V1 page")
        var firstFrames: [NSWindow.ButtonType: NSRect] = [:]
        for filter in route {
            scanStore.showFilter(filter)
            settle(window)
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try XCTUnwrap(window.standardWindowButton(kind), "\(filter): \(kind.rawValue)")
                XCTAssertTrue(button.window === window, "\(filter): \(kind.rawValue) is not in the window")
                XCTAssertFalse(button.isHiddenOrHasHiddenAncestor, "\(filter): \(kind.rawValue) is hidden")
                XCTAssertGreaterThan(Self.effectiveAlpha(of: button), 0.5, "\(filter): \(kind.rawValue) is transparent")
                XCTAssertTrue(button.isEnabled, "\(filter): \(kind.rawValue) is disabled")
                let frame = button.convert(button.bounds, to: nil)
                if let first = firstFrames[kind] {
                    XCTAssertEqual(frame, first, "\(filter): \(kind.rawValue) moved from where the first page put it")
                } else {
                    firstFrames[kind] = frame
                }
            }
            if let toolbar = window.toolbar {
                XCTAssertTrue(toolbar.isVisible, "\(filter): the window toolbar is hidden")
            }
        }
    }

    func testContentViewNeverHidesTheWindowToolbar() throws {
        let source = try String(contentsOf: Self.projectRoot.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/ContentView.swift"), encoding: .utf8)
        let hidingCalls = source.components(separatedBy: .newlines).filter {
            $0.contains(".toolbar(") && $0.contains("for: .windowToolbar")
        }
        XCTAssertEqual(hidingCalls, [], "D94: hiding the window toolbar also removes the window buttons")
        XCTAssertTrue(source.contains(".toolbarBackground(.hidden, for: .windowToolbar)"))
        // Any page that adds a toolbar item gives the window a toolbar on
        // that page alone, which moves the window buttons and the sidebar.
        let sources = Self.projectRoot.appendingPathComponent("Sources/StorageCleanerMac")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var toolbarFiles: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("ToolbarItem") || text.contains(".toolbar {") {
                toolbarFiles.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(toolbarFiles, [], "D94: a toolbar on some pages moves the window buttons")
        let presentation = try String(contentsOf: Self.projectRoot.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/ModulePresentation.swift"), encoding: .utf8)
        XCTAssertTrue(presentation.contains("MainWindowHistoryBand(open: historyAction)"),
            "V1 pages keep their “操作记录” entry")
    }

    /// Turns the main run loop, as the app does between events, so SwiftUI
    /// applies each page's toolbar to the window before it is checked.
    private func settle(_ window: NSWindow) {
        for _ in 0..<6 {
            window.contentView?.needsLayout = true
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        }
    }

    private static func effectiveAlpha(of view: NSView) -> CGFloat {
        var alpha: CGFloat = 1
        var current: NSView? = view
        while let node = current {
            alpha *= node.alphaValue
            current = node.superview
        }
        return alpha
    }

    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

private struct EmptyWindowControlsHistoryLoader: ScanStoreHistoryLoading {
    func load() async -> ScanStoreHistorySnapshot {
        ScanStoreHistorySnapshot(scanHistory: ScanHistorySummary(entries: []),
            cleanupHistory: CleanupHistorySummary(entries: []))
    }
}

private actor EmptyWindowControlsBenchmarkHistory: MacBenchmarkHistoryPersisting {
    func load() async -> [MacBenchmarkResult] { [] }
    func save(_ result: MacBenchmarkResult) async throws { _ = result }
}

private struct WindowControlsPrivacyScanner: BrowserPrivacyScanning {
    func scan() async throws -> BrowserPrivacyScanOutcome {
        fatalError("The window-controls fixture must never read browser records")
    }
}

private struct WindowControlsBenchmarkService: MacBenchmarkServicing {
    func run(profile: BenchmarkProfile,
             progress: @escaping @Sendable (MacBenchmarkProgress) async -> Void) async -> MacBenchmarkRawResult {
        _ = profile
        _ = progress
        fatalError("The window-controls fixture must never start a benchmark")
    }
}
#endif
