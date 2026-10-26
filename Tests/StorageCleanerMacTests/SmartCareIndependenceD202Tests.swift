#if DEBUG
import XCTest
@testable import StorageCleanerMac

/// D202 (decided by the user on 10-24, relayed by the 2.0.1 session): Smart
/// Care's scan and the modules' own scans keep their own results. Smart Care
/// marks the parts it scans; a module page keeps its landing for a marked
/// part (Smart Care's Review excepted), its sidebar mark stays off, and the
/// module's own scan takes the part back. Smart Care's junk scan is its own
/// whatever page is on screen.
@MainActor
final class SmartCareIndependenceD202Tests: XCTestCase {
    func testSmartCareMarksThePartItScansAndTheModulesOwnScanTakesItBack() throws {
        let store = try ScanStore.makeForTests(for: self)
        var replaced: [SmartCareModule] = []
        store.onModuleScanReplacedSmartCarePart = { replaced.append($0) }

        store.beginSmartCarePart(.clutter)
        XCTAssertEqual(store.smartCareResultParts, [.clutter])
        store.noteModuleScan(.clutter)
        XCTAssertEqual(store.smartCareResultParts, [.clutter], "Smart Care's own call into the module's entry point")
        XCTAssertTrue(replaced.isEmpty)
        store.endSmartCarePart(.clutter)

        store.noteModuleScan(.clutter)
        XCTAssertTrue(store.smartCareResultParts.isEmpty, "the module's own scan takes the part back")
        XCTAssertEqual(replaced, [.clutter])
        store.noteModuleScan(.clutter)
        XCTAssertEqual(replaced, [.clutter], "a part that is the module's already is not reported again")
    }

    func testWhileSmartCareScansAPartTheModulesPageAndMarkStayOut() throws {
        let store = try ScanStore.makeForTests(for: self)
        store.beginSmartCarePart(.performance)
        store.isLoadingStartupItems = true
        XCTAssertFalse(store.moduleShowsResult(.performance), "the Performance page keeps its landing")
        let inputs = SidebarBadgeInputs(store: store, smartCare: SmartCareCoordinator.of(store),
                                        privacy: BrowserPrivacyStore(), malware: MalwareScanStore(),
                                        cloud: CloudCleanupModel.shared)
        XCTAssertFalse(inputs.startupLoading, "Performance's mark shows no progress of Smart Care's scan")
        store.isLoadingStartupItems = false
        store.hasScannedStartupItems = true
        store.endSmartCarePart(.performance)
        XCTAssertFalse(store.moduleShowsResult(.performance), "nor its result")
    }

    func testMarksPersistAndAMarkWhoseResultIsGoneCountsAsNone() throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let store = try ScanStore.makeForTests(for: self, cleanupPreferences: defaults)
        for part in [SmartCareModule.performance, .clutter] {
            store.beginSmartCarePart(part)
            store.endSmartCarePart(part)
        }
        XCTAssertEqual(ScanStore.smartCareResultParts(in: defaults), [.performance, .clutter])

        let relaunched = try ScanStore.makeForTests(for: self, cleanupPreferences: defaults)
        XCTAssertEqual(relaunched.smartCareResultParts, [.performance, .clutter], "the marks are kept across launches")
        // Nothing was restored: the marks point at no result and count as none,
        // so no page keeps its landing for nothing.
        for part in SmartCareModule.allCases {
            XCTAssertFalse(relaunched.smartCareHolds(part, privacy: BrowserPrivacyStore()), "\(part)")
            XCTAssertTrue(relaunched.moduleShowsResult(part, privacy: BrowserPrivacyStore()), "\(part)")
        }
        relaunched.hasScannedStartupItems = true
        XCTAssertTrue(relaunched.smartCareHolds(.performance), "a result that is there is Smart Care's again")
    }

    func testStartOverClearsSmartCaresOwnResultsAndTheirMarksOnly() throws {
        let store = try ScanStore.makeForTests(for: self)
        store.hasScannedStartupItems = true
        store.beginSmartCarePart(.performance)
        store.endSmartCarePart(.performance)
        store.hasScannedInstalledApps = true
        store.installDebugSmartScanSessionFixture(.results, page: .green)

        store.clearSmartCareResults(privacy: nil)
        XCTAssertTrue(store.smartCareResultParts.isEmpty, "the marks go")
        XCTAssertFalse(store.hasScannedStartupItems, "Smart Care's login items result goes")
        XCTAssertTrue(store.hasScannedInstalledApps, "the Applications page's own result stays")
        XCTAssertNotNil(store.cleanupScanSession, "and so does the Cleanup page's own session")
    }

    func testSmartCaresJunkSessionShowsOnSmartCareOnly() throws {
        let store = try ScanStore.makeForTests(for: self)
        store.installDebugSmartScanSessionFixture(.results)
        let session = try XCTUnwrap(store.cleanupScanSession)
        XCTAssertNotNil(session.smartScanScopes)
        XCTAssertNil(store.cleanupSession(for: .green), "D202: the Cleanup page keeps its landing")
        XCTAssertNil(store.cleanupSession(for: .devCaches), "and so does the developer page")
        XCTAssertFalse(ScanStore.junkFlowIsAModules(state: .results, route: nil, session: session, cancellingCleanup: false),
                       "Smart Care's page shows it")

        store.installDebugSmartScanSessionFixture(.results, page: .green)
        let own = try XCTUnwrap(store.cleanupScanSession)
        XCTAssertEqual(store.cleanupSession(for: .green)?.id, own.id, "the Cleanup page's own session")
        XCTAssertTrue(ScanStore.junkFlowIsAModules(state: .results, route: nil, session: own, cancellingCleanup: false),
                      "which Smart Care's page does not show (\"清理任务已准备好…\")")
    }

    func testSmartCaresPageLeavesAModulesJunkScanToTheModule() {
        for state in [SmartScanPresentationState.preparing, .scanning, .finalizing, .cancelling] {
            XCTAssertTrue(ScanStore.junkFlowIsAModules(state: state, route: .green, session: nil, cancellingCleanup: false), "\(state)")
            XCTAssertFalse(ScanStore.junkFlowIsAModules(state: state, route: .overview, session: nil, cancellingCleanup: false), "\(state)")
        }
        XCTAssertFalse(ScanStore.junkFlowIsAModules(state: .cancelling, route: .green, session: nil, cancellingCleanup: true),
                       "stopping a cleanup stays everyone's")
        for state in [SmartScanPresentationState.idle, .cleaning, .verifying, .completed, .cancelled, .failed] {
            XCTAssertFalse(ScanStore.junkFlowIsAModules(state: state, route: .green, session: nil, cancellingCleanup: false), "\(state)")
        }
    }

    func testTheReviewShowsSmartCaresResultAndEndsWithAnotherPage() throws {
        let store = try ScanStore.makeForTests(for: self)
        store.hasScannedStartupItems = true
        store.beginSmartCarePart(.performance)
        store.endSmartCarePart(.performance)
        XCTAssertFalse(store.moduleShowsResult(.performance))

        store.showSmartCareReview(.startup, part: .performance)
        XCTAssertEqual(store.navigationState.smartCareReview, .performance)
        XCTAssertTrue(store.moduleShowsResult(.performance), "the Review shows Smart Care's result")

        store.showFilter(.privacy)
        XCTAssertNil(store.navigationState.smartCareReview, "another page ends the Review")
        XCTAssertFalse(store.moduleShowsResult(.performance))
        // D202＋旧值 `store.navigationState.selectSidebarDestination(.startup)`
        // then `XCTAssertNil(store.navigationState.smartCareReview, "the sidebar's
        // own row too")`: the sidebar's rows do not go through that call, and
        // choosing the page on screen again keeps the Review (r42: ContentView
        // chooses it again after `showFilter`, which ended every Review). A row
        // ends it itself: testTheSidebarsRowsEndTheReview.
    }

    /// r42 (window run of 10-24): `showFilter` asks ContentView for the page,
    /// which chooses it again a moment later; that ended every Review before
    /// its page showed. The page on screen chosen again keeps it.
    func testTheReviewOutlastsThePageChosenAgain() throws {
        let store = try ScanStore.makeForTests(for: self)
        store.hasScannedStartupItems = true
        store.beginSmartCarePart(.performance)
        store.endSmartCarePart(.performance)
        let reviews: [(ReviewFilter, SmartCareModule)] = [(.startup, .performance), (.maintenance, .performance),
                                                          (.privacy, .protection), (.updater, .applications),
                                                          (.duplicates, .clutter)]
        for (filter, part) in reviews {
            store.showFilter(.overview)
            store.requestedFilter = nil
            store.showSmartCareReview(filter, part: part)
            let echo = try XCTUnwrap(store.requestedFilter, "\(filter): ContentView is asked for the page")
            XCTAssertFalse(store.navigationState.select(echo), "\(filter): it is the page on screen")
            XCTAssertEqual(store.navigationState.smartCareReview, part, "\(filter): the Review stays")
            XCTAssertFalse(store.navigationState.selectSidebarDestination(filter), "\(filter)")
            XCTAssertEqual(store.navigationState.smartCareReview, part, "\(filter): a scan's route to the page keeps it too")
            if part == .performance {
                XCTAssertTrue(store.moduleShowsResult(.performance), "\(filter): Smart Care's result on the page")
            }
        }
    }

    /// A sidebar row ends the Review, the row of the page on screen too:
    /// Performance's row on Performance's Review goes to its landing. The
    /// row's action is the view's; its source is checked.
    func testTheSidebarsRowsEndTheReview() throws {
        let store = try ScanStore.makeForTests(for: self)
        store.hasScannedStartupItems = true
        store.beginSmartCarePart(.performance)
        store.endSmartCarePart(.performance)
        store.showSmartCareReview(.startup, part: .performance)
        store.navigationState.endSmartCareReview()
        XCTAssertFalse(store.navigationState.select(.startup), "Performance's row: the page on screen")
        XCTAssertNil(store.navigationState.smartCareReview)
        XCTAssertFalse(store.moduleShowsResult(.performance), "which shows its landing again")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/SidebarView.swift"), encoding: .utf8)
        let select = try XCTUnwrap(source.components(separatedBy: "private func select(_ family: CareStudioFamily)").dropFirst().first)
        let body = try XCTUnwrap(select.components(separatedBy: "\n    }\n").first)
        let end = try XCTUnwrap(body.range(of: "navigationState.endSmartCareReview()"), "the row ends the Review")
        let choice = try XCTUnwrap(body.range(of: "selection = route"), "the row chooses its page")
        XCTAssertLessThan(end.lowerBound, choice.lowerBound, "before it chooses the page")
    }

    /// On the Review a refresh of its part, as after disabling a login item
    /// there, keeps the result Smart Care's; off the Review the module's own
    /// scan takes the part back as before.
    func testARefreshOnTheReviewKeepsThePartSmartCares() throws {
        let store = try ScanStore.makeForTests(for: self)
        var replaced: [SmartCareModule] = []
        store.onModuleScanReplacedSmartCarePart = { replaced.append($0) }
        store.hasScannedStartupItems = true
        store.beginSmartCarePart(.performance)
        store.endSmartCarePart(.performance)
        store.showSmartCareReview(.startup, part: .performance)

        store.noteModuleScan(.performance)
        XCTAssertEqual(store.smartCareResultParts, [.performance], "the Review's refresh")
        XCTAssertTrue(replaced.isEmpty, "Smart Care's cards stay")
        XCTAssertTrue(store.moduleShowsResult(.performance))
        store.noteModuleScan(.clutter)
        XCTAssertTrue(replaced.isEmpty, "another part is not the Review's")

        store.showFilter(.overview)
        store.noteModuleScan(.performance)
        XCTAssertTrue(store.smartCareResultParts.isEmpty, "off the Review the module's own scan takes it back")
        XCTAssertEqual(replaced, [.performance])
    }

    /// D202 补二: the maintenance tasks Performance's Review opens (when some
    /// are recommended) are a manager panel; on the Review its own Back goes
    /// back to Smart Care, not to Performance's page. The window class
    /// presses it; the source is checked here.
    func testTheManagerPanelsBackGoesBackToSmartCareOnTheReview() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/Toolbox/ToolboxManagerPanel.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("private var back: () -> Void { reviewReturn?.action ?? onBack }"))
        XCTAssertTrue(source.contains("Button(action: back)"), "the header's Back")
        XCTAssertTrue(source.contains(".onExitCommand(perform: back)"), "and Esc")
        XCTAssertFalse(source.contains("Button(action: onBack)"), "no Back that skips the Review")
    }

    /// r46: a page change can show a second copy of the new page that goes
    /// again. The window tests' hooks keep every copy, so the copy's leaving
    /// does not clear the page's own (`ViewCopyHook`).
    func testAHookKeepsThePageWhenASecondCopyGoes() {
        var hook = ViewCopyHook<String>()
        let page = UUID(), copy = UUID()
        hook.register(page, "page")
        hook.register(copy, "copy")
        hook.unregister(copy)
        XCTAssertEqual(hook.current, "page", "the copy's leaving keeps the page's")
        hook.register(copy, "copy")
        hook.register(page, "page again")
        XCTAssertEqual(hook.current, "page again", "the newest registration answers")
        hook.unregister(page)
        XCTAssertEqual(hook.current, "copy")
        hook.unregister(copy)
        XCTAssertNil(hook.current, "no copy on screen, no hook")
    }

    func testTheSidebarMarksFollowTheModulesOwnResultsOnly() throws {
        let store = try ScanStore.makeForTests(for: self)
        let smartCare = SmartCareCoordinator.of(store)
        func badge(_ family: CareStudioFamily) -> SidebarBadge? {
            SidebarBadge.badge(for: family, SidebarBadgeInputs(store: store, smartCare: smartCare,
                                                               privacy: BrowserPrivacyStore(), malware: MalwareScanStore(),
                                                               cloud: CloudCleanupModel.shared))
        }
        store.hasScannedStartupItems = true
        XCTAssertEqual(badge(.performance), .results, "the module's own result")
        store.beginSmartCarePart(.performance)
        store.endSmartCarePart(.performance)
        XCTAssertNil(badge(.performance), "D202＋旧值 .results: Smart Care's result lights Smart Scan only")
        store.noteModuleScan(.performance)
        XCTAssertEqual(badge(.performance), .results, "the module's own again")

        store.installDebugSmartScanSessionFixture(.results)
        XCTAssertNil(badge(.cleanup), "Smart Care's junk session gives Cleanup no mark")
        store.installDebugSmartScanSessionFixture(.results, page: .green)
        XCTAssertEqual(badge(.cleanup), .results)
    }

    func testAModulesOwnScanSendsSmartCaresCardsBackToTheLanding() async throws {
        let store = try ScanStore.makeForTests(for: self)
        let care = SmartCareCoordinator(scanner: D202InstantScanner(), defaults: TestPreferenceDomain.make(for: self))
        care.follow(store, privacy: { nil })
        care.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while care.stage != .results, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(care.stage, .results)
        store.hasScannedStartupItems = true
        store.beginSmartCarePart(.performance)
        store.endSmartCarePart(.performance)

        store.noteModuleScan(.clutter)
        XCTAssertEqual(care.stage, .results, "a part that is not Smart Care's changes nothing")
        store.noteModuleScan(.performance)
        XCTAssertEqual(care.stage, .idle, "Smart Care's login items were replaced: its cards go")
        XCTAssertFalse(store.smartCareResultParts.contains(.performance), "the part is the module's")
    }

    /// The scope fix that came with D202: Smart Care's junk scan used to take
    /// its scopes from the page on screen (on Cleanup it became that page's
    /// scan; on Duplicates it started that page's scan instead).
    func testSmartCaresJunkScanIsItsOwnWhateverPageIsOnScreen() async throws {
        let requests = D202RequestLog()
        for page in [ReviewFilter.green, .duplicates, .overview] {
            let store = try ScanStore.makeForTests(for: self,
                cleanupScanOperation: { request, _ in
                    await requests.record(request)
                    throw CancellationError()
                })
            store.selectedFilter = page
            store.startSmartCareJunkScan()
            XCTAssertEqual(store.scanPresentationRoute, .overview, "\(page): Smart Care's route")
            XCTAssertFalse(store.duplicateFilesWorkspace.isScanning, "\(page): no Duplicates scan")
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while await requests.count < 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let request = try await XCTUnwrapAsync(await requests.last, "\(page): the junk scan started")
            XCTAssertNil(request.includedRuleIDs, "\(page): Smart Scan's scopes, not the Cleanup switches")
            XCTAssertNil(request.includedCategoryIDs, "\(page)")
            await requests.reset()
        }
    }
}

/// Every part's scan finishes at once (as item 14's render test's).
private final class D202InstantScanner: SmartCareScanning {
    func scan(_ module: SmartCareModule) async -> SmartCareCardState { .done }
    func stop(_ module: SmartCareModule) {}
}

private actor D202RequestLog {
    private var requests: [CleanupScanRequest] = []
    var count: Int { requests.count }
    var last: CleanupScanRequest? { requests.last }
    func record(_ request: CleanupScanRequest) { requests.append(request) }
    func reset() { requests = [] }
}

private func XCTUnwrapAsync<T>(_ value: T?, _ message: String) async throws -> T {
    try XCTUnwrap(value, message)
}
#endif
