#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D176 (the user's choice A, CleanMyMac 1:1): one sidebar for every page —
/// full before the first scan of a launch, the icon rail from it on. (Before,
/// D141 folded it page by page on result pages, and its 2026-10-20 live check
/// found one page change that kept it full by mistake: Smart Scan's results
/// to Safe Cleanup's.) This
/// display-bound class (in-process, `script/display-bound-tests.txt`) hosts
/// the whole main window, as `MainWindowControlsTests` does, on a fixture
/// result; it runs no scanner and no executor.
@MainActor
final class CareStudioNavigationTests: XCTestCase {
    func testTheFirstScanFoldsTheSidebarOnEveryStudioPage() throws {
        CareStudioCanvas.shared.resetForTesting()
        let (window, scanStore) = try hostedMainWindow()
        defer {
            window.orderOut(nil)
            window.close()
        }

        let canvas = CareStudioCanvas.shared
        // D176: before the first scan every route keeps the full sidebar, even
        // with the fixture's results on screen (was D141: the routes showing
        // them — overview, green, devCaches — folded it to the 64 pt rail and
        // privacy gave it back).
        let route: [ReviewFilter] = [.overview, .green, .devCaches, .green, .overview, .privacy, .green, .overview]
        for filter in route {
            scanStore.showFilter(filter)
            settle(window)
            XCTAssertEqual(try sidebarWidth(in: window), FeatureLightfield.sidebarWidth, accuracy: 1,
                           "\(filter): before a scan the sidebar should be full; \(canvas.trace.suffix(8))")
        }
        // A scanning page claims the canvas (as every module's does); from then
        // on every route shows the icon rail, on a wide window too.
        let scan = UUID()
        canvas.claim(scan, animating: true, label: "test scan")
        canvas.release(scan)
        for filter in route {
            scanStore.showFilter(filter)
            settle(window)
            XCTAssertEqual(try sidebarWidth(in: window), SidebarPresentation.rail.idealWidth, accuracy: 1,
                           "\(filter): after a scan the sidebar should be the icon rail; \(canvas.trace.suffix(8))")
        }
        for width in [CGFloat(1_024), 1_500] {
            window.setContentSize(NSSize(width: width, height: 763))
            settle(window)
            XCTAssertEqual(try sidebarWidth(in: window), SidebarPresentation.rail.idealWidth, accuracy: 1,
                           "\(width) pt window after a scan: the sidebar should stay the icon rail")
        }
        canvas.resetForTesting()
    }

    /// Report §4 item 12 (CleanMyMac 1:1, `cmm/14`, `20`, `24`): a results
    /// page shows Start Over and the module's name in the window's title bar,
    /// a landing page neither. Start Over asks first: Cancel keeps the
    /// results, Start Over goes back to the landing page. The page draws the
    /// two itself (`CareStudioTitleBarRow`): r35 found the first version's
    /// toolbar items moved the window buttons and the sidebar 10 pt between
    /// results and landing pages (D94), so the window buttons and the sidebar
    /// are checked to stay put. A click on the row reaches the button only
    /// while the test app is in front (10-23 window runs), so Start Over is
    /// pressed through its own action (`CareStudioTitleBarTestHook`, only
    /// while it is enabled) and the window is asked where a click there lands.
    /// Was: the two found as the window toolbar's item views, sorted by x
    /// (`titleBarItems`), and the landing page checked for none
    /// (`XCTAssertTrue(titleBarViews(window).isEmpty, …)`); the row has no
    /// toolbar items any more, so it is found by its layout probes.
    func testResultsShowStartOverAndTheModuleNameInTheTitleBar() throws {
        CareStudioCanvas.shared.resetForTesting()
        let frames = NavigationFrames()
        let (window, scanStore) = try hostedMainWindow(frames: frames)
        defer {
            window.orderOut(nil)
            window.close()
        }
        scanStore.showFilter(.overview)
        settle(window)
        try saveTitleBarEvidence(window, name: "w23-titlebar-smartscan-results-full")
        scanStore.showFilter(.green)
        settle(window)
        try saveTitleBarEvidence(window, name: "w23-titlebar-cleanup-results-full")
        try checkTitleBarRow(window, frames, "Safe Cleanup's results show Start Over and the module's name in the title bar")
        let resultsButtons = windowButtonsFrame(window)
        let resultsSidebar = try XCTUnwrap(frames.values[LayoutProbeID.smartScanSidebar], "the sidebar")

        scanStore.showFilter(.privacy)
        settle(window)
        try saveTitleBarEvidence(window, name: "w23-titlebar-protection-landing")
        XCTAssertNil(frames.values["careStudio.titleBar.title"], "a landing page has no module name in the title bar")
        XCTAssertNil(frames.values["careStudio.titleBar.startOver"], "nor Start Over")
        // D94: the window buttons and the sidebar stay put from page to page.
        XCTAssertEqual(windowButtonsFrame(window), resultsButtons, "the window buttons stay where they are on the results")
        let landingSidebar = try XCTUnwrap(frames.values[LayoutProbeID.smartScanSidebar], "the sidebar")
        XCTAssertEqual(landingSidebar.minY, resultsSidebar.minY, accuracy: 0.5, "the sidebar stays where it is on the results")
        XCTAssertTrue((window.toolbar?.items ?? []).allSatisfy { $0.view == nil },
                      "no page gives the window a toolbar item (D94)")

        // After a scan the sidebar is the icon rail (D176): Start Over follows it.
        let scan = UUID()
        CareStudioCanvas.shared.claim(scan, animating: true, label: "test scan")
        CareStudioCanvas.shared.release(scan)
        scanStore.showFilter(.green)
        settle(window)
        try saveTitleBarEvidence(window, name: "w23-titlebar-cleanup-results-rail")
        try checkTitleBarRow(window, frames, "the icon rail's results keep both in the title bar")
        XCTAssertEqual(windowButtonsFrame(window), resultsButtons, "the icon rail moves no window button")

        let session = scanStore.cleanupScanSession?.id
        try checkTitleBarRow(window, frames, "before Start Over")
        XCTAssertTrue(try pressStartOver(), "Start Over is enabled on the results; can edit "
            + "\(scanStore.canEditV2CleanupSelection), lease \(String(describing: scanStore.heavyWorkActivityStore.activeOwner))")
        settle(window)
        let question = try XCTUnwrap(window.attachedSheet, "Start Over asks first")
        let cancel = try XCTUnwrap(accessibilityElement(label: L10n.text("取消", "Cancel"), role: "AXButton", in: question),
                                   "the question's Cancel button")
        // Report §4 item 12: was `XCTAssertTrue(press(cancel))` and, below,
        // `XCTAssertTrue(press(confirm))`. The question's buttons return false
        // from accessibilityPerformPress although their action runs (10-23
        // window run, both checks after them passed), so their return value
        // is not asserted; what each press does is checked right after it.
        _ = press(cancel)
        settle(window)
        XCTAssertNil(window.attachedSheet, "Cancel closes the question")
        XCTAssertEqual(scanStore.cleanupScanSession?.id, session, "Cancel keeps the results")

        try checkTitleBarRow(window, frames, "after Cancel")
        XCTAssertTrue(try pressStartOver())
        settle(window)
        let sheet = try XCTUnwrap(window.attachedSheet, "Start Over asks again")
        let confirm = try XCTUnwrap(accessibilityElement(label: L10n.text("重新开始", "Start Over"), role: "AXButton", in: sheet),
                                    "the question's Start Over button")
        _ = press(confirm) // was `XCTAssertTrue(press(confirm))`; see Cancel above
        settle(window)
        XCTAssertNil(scanStore.cleanupScanSession, "Start Over goes back to the landing page")
        // Item 12: was `XCTAssertTrue(titleBarViews(window).isEmpty, …)`; see above.
        XCTAssertNil(frames.values["careStudio.titleBar.startOver"], "the landing page's title bar is empty")
        XCTAssertNil(CareStudioTitleBarTestHook.pressStartOver, "and its Start Over is gone")
        XCTAssertEqual(windowButtonsFrame(window), resultsButtons, "and the window buttons did not move")
        CareStudioCanvas.shared.resetForTesting()
    }

    /// D202: a page Smart Care's Review opens shows Smart Care's result with
    /// Back to Smart Scan where Start Over would be, on the window buttons'
    /// line and clear of them, the window buttons and the sidebar where they
    /// are on other results (D94), and no toolbar item; the module's own page
    /// shows its landing for that result, and Back ends the Review.
    func testSmartCaresReviewGoesBackToSmartScanInsteadOfStartingOver() throws {
        CareStudioCanvas.shared.resetForTesting()
        let frames = NavigationFrames()
        let (window, scanStore) = try hostedMainWindow(frames: frames)
        defer {
            window.orderOut(nil)
            window.close()
        }
        scanStore.showFilter(.green)
        settle(window)
        let resultsButtons = windowButtonsFrame(window)
        let resultsSidebar = try XCTUnwrap(frames.values[LayoutProbeID.smartScanSidebar], "the sidebar")
        // Smart Care read the login items (nothing on disk is read here).
        scanStore.beginSmartCarePart(.performance)
        scanStore.hasScannedStartupItems = true
        scanStore.endSmartCarePart(.performance)

        scanStore.showFilter(.startup)
        settle(window)
        XCTAssertNil(frames.values["careStudio.titleBar.startOver"],
                     "Performance's own page keeps its landing for Smart Care's result")
        XCTAssertNil(frames.values["careStudio.titleBar.back"])

        scanStore.showSmartCareReview(.startup, part: .performance)
        settle(window)
        try saveTitleBarEvidence(window, name: "w23-titlebar-smartcare-review")
        let back = try XCTUnwrap(frames.values["careStudio.titleBar.back"], "Back to Smart Scan in Start Over's place")
        XCTAssertNil(frames.values["careStudio.titleBar.startOver"], "no Start Over: the result is Smart Care's")
        let name = try XCTUnwrap(frames.values["careStudio.titleBar.title"], "the module's name")
        let buttons = windowButtonsFrame(window)
        XCTAssertLessThanOrEqual(back.maxX, name.minX, "Back is left of the name")
        XCTAssertGreaterThanOrEqual(back.minX, buttons.maxX + 4, "Back clears the window buttons")
        XCTAssertEqual(back.midY, buttons.midY, accuracy: 2, "Back is on the window buttons' line")
        XCTAssertEqual(buttons, resultsButtons, "the window buttons stay where they are (D94)")
        let reviewSidebar = try XCTUnwrap(frames.values[LayoutProbeID.smartScanSidebar], "the sidebar")
        XCTAssertEqual(reviewSidebar.minY, resultsSidebar.minY, accuracy: 0.5, "the sidebar stays where it is (D94)")
        XCTAssertTrue((window.toolbar?.items ?? []).allSatisfy { $0.view == nil },
                      "no page gives the window a toolbar item (D94)")

        try XCTUnwrap(CareStudioTitleBarTestHook.pressBack, "Back is on screen")()
        settle(window)
        XCTAssertNil(scanStore.navigationState.smartCareReview, "Back ends the Review")
        XCTAssertEqual(scanStore.selectedFilter, .overview, "and opens Smart Scan")
        scanStore.showFilter(.startup)
        settle(window)
        XCTAssertNil(frames.values["careStudio.titleBar.back"], "Performance's own page again: its landing")
        XCTAssertEqual(windowButtonsFrame(window), resultsButtons, "and the window buttons did not move")
        CareStudioCanvas.shared.resetForTesting()
    }

    /// D202 补二 (13th build, LCU): two pages Smart Care's Review opens are no
    /// studio results pages. Applications' opens the App Updates page, whose
    /// result is a Lightfield page and whose manager is its own: Back to Smart
    /// Scan sits where the studio pages put it, on its manager too.
    /// Performance's opens the maintenance tasks when some are recommended:
    /// the manager panel's own Back goes back to Smart Scan, not to
    /// Performance's page. (r46 failed at the panel's Back: the hook was nil
    /// after Smart Scan's page gave way to the panel, as a page change can
    /// show a second copy of the new page that goes again; the hooks keep
    /// every copy now, `ViewCopyHook`, and this step saves its picture and
    /// says which page was on screen.)
    func testSmartCaresReviewOfAppUpdatesAndMaintenanceGoesBackToSmartScan() throws {
        CareStudioCanvas.shared.resetForTesting()
        let frames = NavigationFrames()
        let (window, scanStore) = try hostedMainWindow(frames: frames)
        defer {
            window.orderOut(nil)
            window.close()
        }
        scanStore.showFilter(.green)
        settle(window)
        let resultsButtons = windowButtonsFrame(window)

        // Applications: the App Updates page (a fixture result; nothing is checked online).
        scanStore.installDebugAppUpdatePresentationFixture(.summary)
        scanStore.showFilter(.updater)
        settle(window)
        XCTAssertNil(frames.values["careStudio.titleBar.back"], "the App Updates page on its own has no Back")
        scanStore.showSmartCareReview(.updater, part: .applications)
        settle(window)
        try saveTitleBarEvidence(window, name: "w23-titlebar-smartcare-review-updater")
        func checkBack(_ phase: String) throws {
            let back = try XCTUnwrap(frames.values["careStudio.titleBar.back"], "\(phase): Back to Smart Scan")
            let buttons = windowButtonsFrame(window)
            XCTAssertGreaterThanOrEqual(back.minX, buttons.maxX + 4, "\(phase): Back clears the window buttons")
            XCTAssertEqual(back.midY, buttons.midY, accuracy: 2, "\(phase): Back is on the window buttons' line")
            XCTAssertEqual(buttons, resultsButtons, "\(phase): the window buttons stay where they are (D94)")
            XCTAssertTrue((window.toolbar?.items ?? []).allSatisfy { $0.view == nil }, "\(phase): no toolbar item (D94)")
        }
        try checkBack("the result")
        scanStore.installDebugAppUpdatePresentationFixture(.managing)
        settle(window)
        try checkBack("its manager")
        try XCTUnwrap(CareStudioTitleBarTestHook.pressBack, "Back is on screen")()
        settle(window)
        XCTAssertNil(scanStore.navigationState.smartCareReview, "Back ends the Review")
        XCTAssertEqual(scanStore.selectedFilter, .overview, "and opens Smart Scan")

        // Performance with recommended maintenance tasks (a preview; nothing is read).
        ToolboxStores.of(scanStore).maintenance.installPreview(statuses: [
            .speedUpMail: SystemMaintenanceStatus(mode: .runnable, lines: ["邮件索引现在 1.2 GB。"], isRecommended: true)
        ])
        scanStore.showSmartCareReview(.maintenance, part: .performance)
        settle(window)
        try saveTitleBarEvidence(window, name: "w23-smartcare-review-maintenance")
        let state = "route \(scanStore.navigationState.route), Review \(String(describing: scanStore.navigationState.smartCareReview))"
        XCTAssertNotNil(frames.values["toolbox.manager"], "the maintenance tasks are on screen; \(state)")
        try XCTUnwrap(ToolboxManagerTestHook.pressBack, "the maintenance tasks' Back; \(state)")()
        settle(window)
        XCTAssertNil(scanStore.navigationState.smartCareReview, "the panel's Back ends the Review")
        XCTAssertEqual(scanStore.selectedFilter, .overview, "and opens Smart Scan, not Performance's page")
        scanStore.showFilter(.maintenance)
        settle(window)
        try XCTUnwrap(ToolboxManagerTestHook.pressBack, "the maintenance tasks' Back")()
        settle(window)
        XCTAssertEqual(scanStore.selectedFilter, .utilityHub, "off the Review it goes to Performance's page as before")
        XCTAssertEqual(scanStore.selectedUtilityFilter, .startup)
        CareStudioCanvas.shared.resetForTesting()
    }

    /// A results page's title bar row: Start Over on the left of the
    /// module's name, both on the window buttons' line and clear of them,
    /// and a click at Start Over lands in the page, not in the title bar.
    private func checkTitleBarRow(_ window: NSWindow, _ frames: NavigationFrames, _ message: String) throws {
        let startOver = try XCTUnwrap(frames.values["careStudio.titleBar.startOver"], "\(message): Start Over")
        let name = try XCTUnwrap(frames.values["careStudio.titleBar.title"], "\(message): the module's name")
        let buttons = windowButtonsFrame(window)
        XCTAssertLessThanOrEqual(startOver.maxX, name.minX, "\(message): Start Over is left of the name")
        XCTAssertGreaterThanOrEqual(startOver.minX, buttons.maxX + 4, "\(message): Start Over clears the window buttons")
        XCTAssertEqual(startOver.midY, buttons.midY, accuracy: 2, "\(message): Start Over is on the window buttons' line")
        XCTAssertEqual(name.midY, buttons.midY, accuracy: 2, "\(message): the name is on the window buttons' line")
        let frameView = try XCTUnwrap(window.contentView?.superview, message)
        let point = NSPoint(x: startOver.midX, y: frameView.bounds.height - startOver.midY)
        let hit = try XCTUnwrap(frameView.hitTest(point), "\(message): nothing at Start Over")
        XCTAssertTrue(hit.isDescendant(of: try XCTUnwrap(window.contentView)),
                      "\(message): a click at Start Over goes to \(type(of: hit)), not the page")
    }

    /// The close, minimise and zoom buttons together, from the window's top
    /// left, as the layout probes measure.
    private func windowButtonsFrame(_ window: NSWindow) -> CGRect {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let height = window.contentView?.superview?.bounds.height ?? window.frame.height
        return buttons.compactMap { window.standardWindowButton($0) }
            .map { button -> CGRect in
                let rect = button.convert(button.bounds, to: nil)
                return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
            }
            .reduce(CGRect.null) { $0.union($1) }
    }

    /// The whole window, title bar included (the toolbar sits above the
    /// content view, in the window's frame view), for review against
    /// `cmm/14`, `20`, `24`; only when the evidence folder is set.
    private func saveTitleBarEvidence(_ window: NSWindow, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["STORAGE_CLEANER_CARESTUDIO_EVIDENCE"] else { return }
        let frameView = try XCTUnwrap(window.contentView?.superview, name)
        let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds), name)
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        let url = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(name + ".png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), name).write(to: url)
    }

    private func hostedMainWindow(frames: NavigationFrames? = nil) throws -> (NSWindow, ScanStore) {
        let heavyWorkCoordinator = HeavyWorkCoordinator()
        let heavyWorkActivityStore = HeavyWorkActivityStore(coordinator: heavyWorkCoordinator)
        let scanStore = try ScanStore.makeForTests(for: self,
            heavyWorkCoordinator: heavyWorkCoordinator,
            heavyWorkActivityStore: heavyWorkActivityStore,
            restoreSavedAccessOperation: {},
            loadScanReadinessSummary: { ScanReadinessSummary(items: []) },
            historyLoader: EmptyNavigationHistoryLoader())
        scanStore.didCompleteInitialPermissionCheck = true
        scanStore.showFilter(.overview)
        // D202＋旧值：`installDebugSmartScanSessionFixture(.results)`, Smart Scan's
        // session, which shows on Smart Care only since D202; the Cleanup page's
        // results need its own scan's session.
        scanStore.installDebugSmartScanSessionFixture(.results, page: .green)
        let catalog = try MacBenchmarkBaselineCatalog(activeBaselineVersion: "carestudio-navigation-fixture", verifiedBaselines: [])
        let benchmarkStore = MacBenchmarkStore(service: NavigationBenchmarkService(),
            resultProcessor: MacBenchmarkResultProcessor(baselineCatalog: catalog),
            historyRepository: EmptyNavigationBenchmarkHistory(),
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
            browserPrivacyStore: BrowserPrivacyStore(scanner: NavigationPrivacyScanner()))
        // The layout probes, from the window's top left (full-size content),
        // as `SafeCleanupLayoutTests`' host records them.
        let root = frames.map { frames in
            AnyView(content.onPreferenceChange(LayoutFramePreferenceKey.self) { values in
                Task { @MainActor in frames.values = values }
            })
        } ?? AnyView(content)
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 763),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1280, height: 763))
        window.orderFront(nil)
        return (window, scanStore)
    }

    /// The element with this accessibility identifier anywhere in the window,
    /// its title bar's toolbar included.
    private func accessibilityElement(_ identifier: String, in window: NSWindow) -> NSObject? {
        findAccessibilityElement(in: window) { accessibilityText($0, "accessibilityIdentifier") == identifier }
    }

    private func accessibilityElement(label: String, role: String, in window: NSWindow) -> NSObject? {
        findAccessibilityElement(in: window) {
            accessibilityText($0, "accessibilityRole") == role
                && (accessibilityText($0, "accessibilityLabel") == label || accessibilityText($0, "accessibilityTitle") == label)
        }
    }

    private func findAccessibilityElement(in window: NSWindow, where matches: (NSObject) -> Bool) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func search(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if matches(object) { return object }
            let children = accessibilityValue(object, "accessibilityChildren") as? [Any] ?? []
            for child in children.compactMap({ $0 as? NSObject }) {
                if let match = search(child) { return match }
            }
            return nil
        }
        return search(window)
    }

    /// Presses the title bar's Start Over through its debug hook; false
    /// while the button is disabled.
    private func pressStartOver() throws -> Bool {
        try XCTUnwrap(CareStudioTitleBarTestHook.pressStartOver, "the title bar's Start Over is on screen")()
    }

    private func accessibilityText(_ object: NSObject, _ selector: String) -> String? {
        let value = accessibilityValue(object, selector)
        return (value as? String) ?? (value as? NSAttributedString)?.string
    }

    private func accessibilityValue(_ object: NSObject, _ selector: String) -> AnyObject? {
        let selector = NSSelectorFromString(selector)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func press(_ element: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard element.responds(to: selector), let implementation = element.method(for: selector) else { return false }
        typealias NativePress = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: NativePress.self)(element, selector)
    }

    private func sidebarWidth(in window: NSWindow) throws -> CGFloat {
        let controller = try XCTUnwrap(MainWindowSidebarColumn.controller(in: window.contentView),
                                       "the NavigationSplitView's split view controller")
        let sidebar = try XCTUnwrap(controller.splitViewItems.first { $0.behavior == .sidebar })
        return sidebar.viewController.view.frame.width
    }

    /// Turns the main run loop past the page transition (D53 §3.2.1).
    private func settle(_ window: NSWindow) {
        for _ in 0..<8 {
            window.contentView?.needsLayout = true
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        }
    }
}

/// The layout probes' latest frames.
@MainActor
private final class NavigationFrames {
    var values: [String: CGRect] = [:]
}

private struct EmptyNavigationHistoryLoader: ScanStoreHistoryLoading {
    func load() async -> ScanStoreHistorySnapshot {
        ScanStoreHistorySnapshot(scanHistory: ScanHistorySummary(entries: []),
            cleanupHistory: CleanupHistorySummary(entries: []))
    }
}

private actor EmptyNavigationBenchmarkHistory: MacBenchmarkHistoryPersisting {
    func load() async -> [MacBenchmarkResult] { [] }
    func save(_ result: MacBenchmarkResult) async throws { _ = result }
}

private struct NavigationPrivacyScanner: BrowserPrivacyScanning {
    func scan() async throws -> BrowserPrivacyScanOutcome {
        fatalError("The navigation fixture must never read browser records")
    }
}

private struct NavigationBenchmarkService: MacBenchmarkServicing {
    func run(profile: BenchmarkProfile,
             progress: @escaping @Sendable (MacBenchmarkProgress) async -> Void) async -> MacBenchmarkRawResult {
        _ = profile
        _ = progress
        fatalError("The navigation fixture must never start a benchmark")
    }
}
#endif
