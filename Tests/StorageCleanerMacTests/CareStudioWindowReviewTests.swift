#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D141: the studio managers and the completed page hold scroll views,
/// fields, menus and spinners, which ImageRenderer cannot draw. This display-bound class (in-process,
/// `script/display-bound-tests.txt`) hosts them in a window on the test
/// display and captures it for review. It runs no scanner and no executor;
/// with no `STORAGE_CLEANER_CARESTUDIO_EVIDENCE` it renders nothing.
@MainActor
final class CareStudioWindowReviewTests: XCTestCase {
    private static let size = CGSize(width: 1_070, height: 735)

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testStudioManagersRenderInAWindowForReview() async throws {
        guard let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_CARESTUDIO_EVIDENCE"] else {
            throw XCTSkip("Review captures are written only when STORAGE_CLEANER_CARESTUDIO_EVIDENCE is set.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = GeneratedArtLibrary(directory: projectRoot.appendingPathComponent("Resources/Art", isDirectory: true))
        for art in GeneratedArt.allCases {
            _ = await library.image(named: art.resourceName(.landing))
            _ = await library.image(named: art.resourceName(.header))
        }

        for (language, light) in [(AppLanguage.zhHans, false), (.zhHans, true), (.english, false)] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let suffix = (language == .english ? "en" : "zh") + (light ? "-light" : "-dark")
            let store = try ScanStore.makeForTests(for: self)
            store.installDebugSmartScanSessionFixture(.results)
            let session = try XCTUnwrap(store.cleanupScanSession)
            let summaries = CareJunkGrouping.summaries(for: session, filter: .green)
            try await capture(CareStudioJunkManager(store: store, module: .cleanup, session: session,
                                                    summaries: summaries, focus: summaries.first?.group,
                                                    onShowClassicList: {}, onBack: {}),
                              name: "w08-cleanup-manager-\(suffix)", library: library, directory: directory)
            try await capture(CleanupScanResultsView(store: store, filter: .green, session: session),
                              name: "w06-cleanup-results-\(suffix)", library: library, directory: directory)
            try await capture(SmartScanCleanupProgressPage(store: store,
                                                           progress: CareStudioRenderReviewTests.executionFixture(),
                                                           onCancel: {}),
                              name: "w09-cleaning-\(suffix)", library: library, directory: directory)
            try await capture(SmartScanCleanupCompletedPage(store: store,
                                                            report: CareStudioRenderReviewTests.completedReportFixture(),
                                                            onDone: {}),
                              name: "w10-completed-\(suffix)", library: library, directory: directory)
            let items = Self.startupItems()
            let actions = CareStudioStartupActions(onRefresh: {}, onEnable: { _ in }, onDisable: { _ in },
                                                   onStop: { _ in }, onReveal: { _ in },
                                                   onOpenParentApplication: { _ in }, onCopyText: { _ in },
                                                   onOpenSystemSettings: {}, onUndo: {})
            // Report §4 item 13 (`cmm/24`): the maintenance tile leads, with
            // Review and Run Tasks; its own preview store leaves the other
            // captures' maintenance store alone.
            let maintenance = SystemMaintenanceStore(coordinator: HeavyWorkCoordinator(), probe: SystemMaintenanceProbe(),
                                                     runners: SystemMaintenanceRunners(), openURL: { _ in }, copyText: { _ in })
            maintenance.installPreview(statuses: ToolboxWindowReviewTests.maintenanceStatuses())
            // D195: the page now reads the coverage report; these items stand
            // for a successful read. The second capture is the unread case.
            try await capture(CareStudioStartupResultsPage(items: items, activeOperationCandidateID: nil,
                                                           isPerformingOperation: false,
                                                           coverageAction: AnyView(Button("完整扫描") {}),
                                                           actions: actions, onShowClassicList: {},
                                                           leadingTiles: [.maintenance(maintenance, onReview: {}) { _ in }],
                                                           coverage: Self.readStartupCoverage()),
                              name: "w11-startup-results-\(suffix)", library: library, directory: directory)
            try await capture(CareStudioStartupResultsPage(items: items, activeOperationCandidateID: nil,
                                                           isPerformingOperation: false,
                                                           coverageAction: AnyView(Button("完整扫描") {}),
                                                           actions: actions, onShowClassicList: {},
                                                           leadingTiles: [.maintenance(maintenance, onReview: {}) { _ in }],
                                                           coverage: .empty),
                              name: "w11b-startup-results-unread-\(suffix)", library: library, directory: directory)
            try await capture(CareStudioStartupManager(items: items, initialCategory: .all,
                                                       activeOperationCandidateID: nil, isPerformingOperation: false,
                                                       coverageAction: AnyView(Button("完整扫描") {}),
                                                       actions: actions, onShowClassicList: {}, onBack: {}),
                              name: "w12-startup-manager-\(suffix)", library: library, directory: directory)
            // D166 batch 3D: an empty category's state picture, and the
            // memory result's measure cards in a full and a short window.
            try await capture(CareStudioStartupManager(items: [], initialCategory: .all,
                                                       activeOperationCandidateID: nil, isPerformingOperation: false,
                                                       coverageAction: AnyView(EmptyView()),
                                                       actions: actions, onBack: {}),
                              name: "w13-startup-manager-empty-\(suffix)", library: library, directory: directory)
            let (memoryResult, memoryPush) = CareStudioRenderReviewTests.memoryResultFixture()
            try await capture(CareStudioMemoryResultPage(result: memoryResult, reclaim: memoryPush, onDone: {}, onShowApps: {}),
                              name: "w14-memory-result-\(suffix)", library: library, directory: directory)
            try await capture(CareStudioMemoryResultPage(result: memoryResult, reclaim: memoryPush, onDone: {}, onShowApps: {}),
                              name: "w14b-memory-result-short-\(suffix)", library: library, directory: directory,
                              size: CGSize(width: 604, height: 490))
            // D154 batch 3E: the Protection manager on the preview records.
            let privacy = BrowserPrivacyPreviewFixture.makeStore()
            privacy.startScan()
            await privacy.waitUntilIdle()
            await privacy.waitForFilteredResults()
            try await capture(BrowserPrivacyRecordResultsView(store: privacy, onShowDataTypes: {}, onShowResults: {},
                                                              presentsManager: true),
                              name: "w15-protection-manager-\(suffix)", library: library, directory: directory)
            try await capture(BrowserPrivacyRecordResultsView(store: privacy, onShowDataTypes: {}, onShowResults: {},
                                                              presentsManager: true),
                              name: "w15b-protection-manager-short-\(suffix)", library: library, directory: directory,
                              size: CGSize(width: 604, height: 490))
            // D154 batch 3F: the Cookies and Other Data manager.
            let dataStore = Self.dataTypesStore(defaults: TestPreferenceDomain.make(for: self))
            try await capture(BrowserPrivacyDataView(store: dataStore),
                              name: "w16-data-types-manager-\(suffix)", library: library, directory: directory)
            try await capture(BrowserPrivacyDataView(store: dataStore),
                              name: "w16b-data-types-manager-short-\(suffix)", library: library, directory: directory,
                              size: CGSize(width: 604, height: 490))
            // D154 batch 3I: the settings window's tabs over a pane, on the
            // window's one backdrop (inert rows; no settings state is read).
            for (tag, width) in [("", CGFloat(1_180)), ("-narrow", 560)] {
                try await capture(Self.settingsChrome(), name: "w17-settings-tabs\(tag)-\(suffix)", library: library,
                                  directory: directory, size: CGSize(width: width, height: 732))
            }
            // D154 batch 3J: the first-launch guide's three pages (the store
            // has not checked access, so nothing reads the system).
            for step in FirstLaunchOnboardingView.Step.allCases {
                try await capture(FirstLaunchOnboardingView(store: store, initialStep: step) {},
                                  name: "w18-onboarding-\(step)-\(suffix)", library: library, directory: directory,
                                  size: FirstLaunchOnboardingView.size)
            }
            // D168: Smart Care's landing (five modules), scanning page
            // (Performance held) and five cards, on stand-in scans.
            let scanningCare = await Self.smartCare(holding: .performance, for: self)
            let finishedCare = await Self.smartCare(holding: nil, for: self)
            try await capture(SmartCareLandingView(store: store, latestStatus: nil),
                              name: "w19-smartcare-landing-\(suffix)", library: library, directory: directory)
            // D154 batch 3O: the landing after a scan (above: a first visit).
            try await capture(SmartCareLandingView(store: store, latestStatus: SmartCareTests.scannedBefore()),
                              name: "w19-smartcare-landing-again-\(suffix)", library: library, directory: directory)
            try await capture(SmartCareScanningPage(store: store, smartCare: scanningCare, privacy: nil),
                              name: "w19-smartcare-scanning-\(suffix)", library: library, directory: directory)
            try await capture(SmartCareResultsPage(store: store, smartCare: finishedCare, privacy: nil),
                              name: "w19-smartcare-results-\(suffix)", library: library, directory: directory)
            scanningCare.stop()
            // D168, batch 3L: Run's maintenance page and its finished page.
            // (The fixture cannot request a cleanup, so the cleanup card shows
            // no tick here.)
            try await capture(SmartCareMaintenanceRunningPage(maintenance: ToolboxStores.of(store).maintenance),
                              name: "w19-smartcare-maintenance-\(suffix)", library: library, directory: directory)
            try await capture(SmartScanCleanupCompletedPage(
                store: store, report: CareStudioRenderReviewTests.completedReportFixture(), onDone: {},
                otherResults: [L10n.text("性能：维护任务已运行完", "Performance: the maintenance tasks have run")]),
                              name: "w19-smartcare-run-done-\(suffix)", library: library, directory: directory)
        }
    }

    /// D154 batch 3J: every page of the first-launch guide stays in the sheet
    /// above the round button, with "Not Now" and the step dots beside it, in
    /// both languages.
    func testFirstLaunchGuideKeepsEveryPageAboveItsButtons() async throws {
        let store = try ScanStore.makeForTests(for: self)
        let size = FirstLaunchOnboardingView.size
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            for step in FirstLaunchOnboardingView.Step.allCases {
                let root = FirstLaunchOnboardingView(store: store, initialStep: step) {}
                    .environment(\.featureDisablesLayoutAnimations, true)
                let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: true)
                defer { host.close() }
                var ids: Set<String> = ["onboarding.page", "onboarding.steps", "careStudio.action", "fixture.viewport"]
                if step != .extras { ids.insert("onboarding.skip") }
                let frames = try await host.frames(required: ids, size: size)
                let sheet = try XCTUnwrap(frames["fixture.viewport"]).insetBy(dx: -0.5, dy: -0.5)
                let page = try XCTUnwrap(frames["onboarding.page"])
                let action = try XCTUnwrap(frames["careStudio.action"])
                let steps = try XCTUnwrap(frames["onboarding.steps"])
                let label = "\(language)/\(step)"
                XCTAssertTrue(sheet.contains(page), "\(label): the page leaves the sheet")
                XCTAssertTrue(sheet.contains(action), "\(label): the round button leaves the sheet")
                XCTAssertLessThanOrEqual(page.maxY, action.minY + 0.5, "\(label): the page runs into the round button")
                XCTAssertTrue(sheet.contains(steps), "\(label)")
                XCTAssertFalse(steps.intersects(action), "\(label): the step dots run into the round button")
                if step != .extras {
                    let skip = try XCTUnwrap(frames["onboarding.skip"])
                    XCTAssertTrue(sheet.contains(skip), "\(label)")
                    XCTAssertFalse(skip.intersects(action), "\(label): Not Now runs into the round button")
                }
            }
        }
    }

    private static func settingsChrome() -> some View {
        VStack(spacing: 0) {
            SettingsTabBar(selected: .scanAndSafety) { _ in }
            FeatureLightfieldHairline()
            SettingsLightfieldPane(category: .scanAndSafety, drawsBackdrop: false) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        LightfieldSettingsSection {
                            LightfieldSettingsRow { Text("示例设置行") }
                            LightfieldSettingsRow { Text("另一行设置") }
                        } header: { Text("示例分组") }
                    }
                }
            }
        }
        .background {
            GeometryReader { proxy in
                FeatureLightfieldBackdrop(module: .overview, phase: .landing,
                    geometry: FeatureLightfieldGeometry(size: proxy.size, phase: .landing), canvasTopInset: 0)
            }
        }
    }

    /// D141 keeps the D77 rule for the new pages: at every supported window
    /// size the round main button stays wholly inside the window.
    func testStudioRoundActionStaysInsideEverySupportedWindowSize() async throws {
        let store = try ScanStore.makeForTests(for: self)
        store.installDebugSmartScanSessionFixture(.results)
        let session = try XCTUnwrap(store.cleanupScanSession)
        // D168: Smart Care scanning (Performance held) and its five cards.
        let scanningCare = await Self.smartCare(holding: .performance, for: self)
        let finishedCare = await Self.smartCare(holding: nil, for: self)
        defer { scanningCare.stop() }
        let pages: [(String, AnyView)] = [
            // D154 batch 3O: a first visit says "Welcome to …"; after a scan
            // the landing has the module's own title.
            ("smartscan-landing", AnyView(SmartCareLandingView(store: store, latestStatus: nil))),
            ("smartscan-landing-again", AnyView(SmartCareLandingView(store: store,
                                                                     latestStatus: SmartCareTests.scannedBefore()))),
            ("smartcare-scanning", AnyView(SmartCareScanningPage(store: store, smartCare: scanningCare, privacy: nil))),
            ("smartcare-results", AnyView(SmartCareResultsPage(store: store, smartCare: finishedCare, privacy: nil))),
            // D168, batch 3L: Run's maintenance part and its finished page.
            ("smartcare-maintenance", AnyView(SmartCareMaintenanceRunningPage(maintenance: ToolboxStores.of(store).maintenance))),
            ("smartcare-run-done", AnyView(SmartScanCleanupCompletedPage(
                store: store, report: CareStudioRenderReviewTests.completedReportFixture(), onDone: {},
                otherResults: [L10n.text("性能：维护任务已运行完", "Performance: the maintenance tasks have run")]))),
            ("cleanup-landing", AnyView(ToolPreparationView(store: store, filter: .green))),
            ("devtools-landing", AnyView(ToolPreparationView(store: store, filter: .devCaches))),
            ("scanning", AnyView(SmartScanScanningPage(progress: CareStudioRenderReviewTests.scanProgress(),
                                                       module: .green, canCancel: true, onCancel: {}))),
            ("smartscan-results", AnyView(CleanupScanResultsView(store: store, filter: .overview, session: session))),
            ("cleaning", AnyView(SmartScanCleanupProgressPage(store: store,
                                                              progress: CareStudioRenderReviewTests.executionFixture(),
                                                              onCancel: {}))),
            ("completed", AnyView(SmartScanCleanupCompletedPage(store: store,
                                                                report: CareStudioRenderReviewTests.completedReportFixture(),
                                                                onDone: {}))),
            ("memory-landing", AnyView(CareStudioMemoryLanding(snapshot: nil, isLoading: true, canFreeUp: false,
                                                               onFreeUp: {}, onShowApps: {}))),
            ("memory-result", AnyView(CareStudioMemoryResultPage(result: CareStudioRenderReviewTests.memoryResultFixture().0,
                                                                 reclaim: CareStudioRenderReviewTests.memoryResultFixture().1,
                                                                 onDone: {}, onShowApps: {}))),
            // D154 batch 3G: the Space Lens result on the inert index.
            ("largeFiles-result", AnyView(MainContentHost(route: .largeFiles, showsIntegratedTitlebar: false) {
                FeatureLightfieldFileResultFixture(module: .largeFiles)
            }))
        ]
        for (name, page) in pages {
            let recorder = ProbeRecorder()
            // Probe frames are global (window) coordinates, which include
            // the title bar; the root's own probe gives the content origin.
            let root = page
                .environment(\.featureDisablesLayoutAnimations, true)
                .layoutProbe("careStudio.review.viewport")
                .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                    Task { @MainActor in recorder.frames = frames }
                }
            let controller = NSHostingController(rootView: AnyView(root))
            controller.sizingOptions = []
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1_024, height: 734),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.contentViewController = controller
            window.orderFront(nil)
            defer {
                window.orderOut(nil)
                window.close()
            }
            for size in [CGSize(width: 1_024, height: 734), CGSize(width: 604, height: 490), CGSize(width: 473, height: 360)] {
                window.setContentSize(size)
                var action: CGRect?
                for _ in 0..<40 {
                    controller.view.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(15))
                    if let frame = recorder.frames["careStudio.action"],
                       let viewport = recorder.frames["careStudio.review.viewport"],
                       abs(viewport.width - size.width) < 0.5, abs(viewport.height - size.height) < 0.5 {
                        action = frame.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
                        break
                    }
                }
                let frame = try XCTUnwrap(action, "\(name) \(size): the round button is not on the page")
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1)
                XCTAssertTrue(bounds.contains(frame), "\(name) \(size): \(frame) leaves the window")
                // D141 revision (live check 2026-10-20): the result tiles stay
                // above the round button; they fit in their grid, or it scrolls.
                if let grid = recorder.frames["careStudio.tiles"], let button = recorder.frames["careStudio.action"] {
                    XCTAssertLessThanOrEqual(grid.maxY, button.minY + 0.5,
                                             "\(name) \(size): the tile area reaches the round button")
                    if recorder.frames["careStudio.tiles.scroll"] == nil {
                        for (key, tile) in recorder.frames where key.hasPrefix("careStudio.tile.") {
                            XCTAssertTrue(grid.insetBy(dx: -0.5, dy: -0.5).contains(tile),
                                          "\(name) \(size): \(key) \(tile) runs out of its grid \(grid)")
                        }
                    }
                }
                // D154 batch 3N: every bubble's icon stays inside its circle.
                for (key, picture) in recorder.frames where key.hasPrefix("lightfield.bubble.picture.") {
                    guard let bubble = recorder.frames["lightfield.bubble." + key.dropFirst("lightfield.bubble.picture.".count)]
                    else { continue }
                    let center = CGPoint(x: bubble.midX, y: bubble.midY)
                    let radius = min(bubble.width, bubble.height) / 2
                    let corners = [CGPoint(x: picture.minX, y: picture.minY), CGPoint(x: picture.maxX, y: picture.minY),
                                   CGPoint(x: picture.minX, y: picture.maxY), CGPoint(x: picture.maxX, y: picture.maxY)]
                    XCTAssertTrue(corners.allSatisfy { hypot($0.x - center.x, $0.y - center.y) <= radius + 0.5 },
                                  "\(name) \(size): \(key) \(picture) pokes out of its bubble \(bubble)")
                }
                // D154 batch 3S: every bubble at least labelThreshold across
                // shows its name (cut at the end when long) inside its circle.
                for (key, bubble) in recorder.frames where key.hasPrefix("lightfield.bubble.")
                    && !key.hasPrefix("lightfield.bubble.picture.") && !key.hasPrefix("lightfield.bubble.label.") {
                    guard min(bubble.width, bubble.height) >= LightfieldBubbleLayout.labelThreshold else { continue }
                    let id = key.dropFirst("lightfield.bubble.".count)
                    guard let label = recorder.frames["lightfield.bubble.label." + id] else {
                        XCTFail("\(name) \(size): \(key) \(bubble) shows no name")
                        continue
                    }
                    let center = CGPoint(x: bubble.midX, y: bubble.midY)
                    let radius = min(bubble.width, bubble.height) / 2
                    let corners = [CGPoint(x: label.minX, y: label.minY), CGPoint(x: label.maxX, y: label.minY),
                                   CGPoint(x: label.minX, y: label.maxY), CGPoint(x: label.maxX, y: label.maxY)]
                    XCTAssertTrue(corners.allSatisfy { hypot($0.x - center.x, $0.y - center.y) <= radius + 0.5 },
                                  "\(name) \(size): \(key)'s name \(label) runs out of its bubble \(bubble)")
                }
                // D154 batch 3G: the Space Lens list stays above the round
                // button, the bubbles beside it, the path clear of More.
                if let list = recorder.frames["careStudio.spaceLens.list"], let button = recorder.frames["careStudio.action"] {
                    XCTAssertLessThanOrEqual(list.maxY, button.minY + 0.5, "\(name) \(size): the list reaches the round button")
                    XCTAssertGreaterThan(list.height, 40, "\(name) \(size): the list has no room")
                    if let bubbles = recorder.frames["careStudio.spaceLens.bubbles"] {
                        XCTAssertFalse(bubbles.intersects(list.insetBy(dx: 1, dy: 1)), "\(name) \(size): the bubbles cover the list")
                    }
                    if let path = recorder.frames["careStudio.spaceLens.path"], let more = recorder.frames["careStudio.spaceLens.more"] {
                        XCTAssertFalse(path.intersects(more), "\(name) \(size): the path runs under More")
                    }
                }
                // D166: the memory result's measure cards stay above the round
                // button's band without scrolling in the two larger windows
                // (the smallest one scrolls the page in place).
                if size.height >= 490, let measures = recorder.frames["careStudio.memory.measures"],
                   let viewport = recorder.frames["careStudio.review.viewport"] {
                    XCTAssertLessThanOrEqual(measures.maxY, viewport.maxY - CareStudioMetrics.actionBand + 0.5,
                                             "\(name) \(size): the measure cards run under the round button")
                }
            }
            if name == "memory-result" {
                XCTAssertNotNil(recorder.frames["careStudio.memory.measures"], "the memory result shows its measure cards")
            }
        }
    }

    /// D154: every module's landing and running page is the studio template
    /// (Applications and Cloud Cleanup have their own). At every supported
    /// window size the text, the page's options and the picture keep apart,
    /// all of them stay above the round button and inside the window, and
    /// the button stays inside the window (D77).
    func testTemplatePagesKeepTextOptionsArtAndActionApartAtEverySize() async throws {
        let store = try ScanStore.makeForTests(for: self)
        for (name, page) in try templatePages(store: store) {
            let recorder = ProbeRecorder()
            let root = page
                .environment(\.featureDisablesLayoutAnimations, true)
                .layoutProbe("careStudio.review.viewport")
                .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                    Task { @MainActor in recorder.frames = frames }
                }
            let controller = NSHostingController(rootView: AnyView(root))
            controller.sizingOptions = []
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1_024, height: 734),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.contentViewController = controller
            window.orderFront(nil)
            defer {
                window.orderOut(nil)
                window.close()
            }
            for size in [CGSize(width: 1_500, height: 960), CGSize(width: 1_024, height: 734),
                         CGSize(width: 604, height: 490), CGSize(width: 473, height: 360)] {
                window.setContentSize(size)
                var settled: [String: CGRect]?
                var previous: [String: CGRect] = [:]
                for _ in 0..<60 {
                    controller.view.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(15))
                    guard let viewport = recorder.frames["careStudio.review.viewport"],
                          abs(viewport.width - size.width) < 0.5, abs(viewport.height - size.height) < 0.5,
                          recorder.frames["careStudio.action"] != nil else { continue }
                    let local = recorder.frames.mapValues { $0.offsetBy(dx: -viewport.minX, dy: -viewport.minY) }
                    // The options settle after their document is measured.
                    if local == previous { settled = local; break }
                    previous = local
                }
                let frames = try XCTUnwrap(settled, "\(name) \(size): the page did not settle")
                let action = try XCTUnwrap(frames["careStudio.action"])
                let bounds = CGRect(origin: .zero, size: size)
                XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(action), "\(name) \(size): \(action) leaves the window")
                let text = ["careStudio.template.title", "careStudio.template.options", "careStudio.template.runningTitle",
                            "careStudio.title", "careStudio.status", "careStudio.running.title", "careStudio.running.detail"]
                    .compactMap { key in frames[key].map { (key, $0) } }
                XCTAssertFalse(text.isEmpty, "\(name) \(size): no title on the page")
                for (key, frame) in text + (frames["careStudio.art"].map { [("careStudio.art", $0)] } ?? []) {
                    XCTAssertLessThanOrEqual(frame.maxY, action.minY + 0.5, "\(name) \(size): \(key) \(frame) reaches the round button")
                    XCTAssertGreaterThanOrEqual(frame.minY, -0.5, "\(name) \(size): \(key) \(frame) starts above the window")
                    XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(name) \(size): \(key) \(frame) leaves the window")
                    XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(name) \(size): \(key) \(frame) leaves the window")
                }
                if let art = frames["careStudio.art"] {
                    for (key, frame) in text {
                        XCTAssertFalse(art.insetBy(dx: 1, dy: 1).intersects(frame), "\(name) \(size): the picture covers \(key)")
                    }
                }
                if let footnote = frames["careStudio.footnote"] {
                    XCTAssertFalse(footnote.intersects(action), "\(name) \(size): the safety line runs under the round button")
                }
            }
        }
    }

    /// D154 review captures in a real window: the template pages with their
    /// options lists (scroll views, which ImageRenderer leaves blank) next
    /// to the sidebar, and the Applications pages.
    func testTemplatePagesRenderInAWindowForReview() async throws {
        guard let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_CARESTUDIO_EVIDENCE"] else {
            throw XCTSkip("Review captures are written only when STORAGE_CLEANER_CARESTUDIO_EVIDENCE is set.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = GeneratedArtLibrary(directory: projectRoot.appendingPathComponent("Resources/Art", isDirectory: true))
        for art in GeneratedArt.allCases { _ = await library.image(named: art.resourceName(.landing)) }
        for (language, light) in [(AppLanguage.zhHans, false), (.english, true)] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let suffix = (language == .english ? "en" : "zh") + (light ? "-light" : "-dark")
            let store = try ScanStore.makeForTests(for: self)
            let managers: [(String, AnyView)] = [
                ("duplicates-manager", AnyView(MainContentHost(route: .duplicates, showsIntegratedTitlebar: false) {
                    Self.clutterManager(store: store, filter: .all)
                })),
                ("duplicates-similarManager", AnyView(MainContentHost(route: .duplicates, showsIntegratedTitlebar: false) {
                    Self.clutterManager(store: store, filter: .similarImage)
                }))
            ]
            for (name, page) in try templatePages(store: store, phases: FeaturePresentationDemo.Phase.allCases)
                + (try await resultTilePages(store: store)) + managers {
                let route = Self.route(of: name)
                store.navigationState.select(route)
                let shell = HStack(spacing: 0) {
                    SidebarView(store: store, selection: .constant(store.navigationState.selectedFilter),
                                presentation: .full, onTogglePresentation: {})
                        .frame(width: FeatureLightfield.sidebarWidth)
                    page
                }
                try await capture(shell, name: "t-\(name)-\(suffix)", library: library, directory: directory,
                                  size: CGSize(width: 1_280, height: 763))
            }
        }
    }

    /// D154 batch 2: the results tile pages (My Clutter, Protection,
    /// Applications) keep their headline and tiles in the window at every
    /// supported size; tiles stay in their grid or the grid scrolls.
    func testResultTilePagesStayInsideEverySupportedWindowSize() async throws {
        let store = try ScanStore.makeForTests(for: self)
        for (name, page) in try await resultTilePages(store: store) {
            let recorder = ProbeRecorder()
            let root = page
                .environment(\.featureDisablesLayoutAnimations, true)
                .layoutProbe("careStudio.review.viewport")
                .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                    Task { @MainActor in recorder.frames = frames }
                }
            let controller = NSHostingController(rootView: AnyView(root))
            controller.sizingOptions = []
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1_024, height: 734),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.contentViewController = controller
            window.orderFront(nil)
            defer {
                window.orderOut(nil)
                window.close()
            }
            for size in [CGSize(width: 1_500, height: 960), CGSize(width: 1_024, height: 734),
                         CGSize(width: 604, height: 490), CGSize(width: 473, height: 360)] {
                window.setContentSize(size)
                var settled: [String: CGRect]?
                var previous: [String: CGRect] = [:]
                for _ in 0..<60 {
                    controller.view.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(15))
                    guard let viewport = recorder.frames["careStudio.review.viewport"],
                          abs(viewport.width - size.width) < 0.5, abs(viewport.height - size.height) < 0.5,
                          recorder.frames["careStudio.tiles"] != nil else { continue }
                    let local = recorder.frames.mapValues { $0.offsetBy(dx: -viewport.minX, dy: -viewport.minY) }
                    if local == previous { settled = local; break }
                    previous = local
                }
                let frames = try XCTUnwrap(settled, "\(name) \(size): the page did not settle")
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
                let grid = try XCTUnwrap(frames["careStudio.tiles"])
                XCTAssertTrue(bounds.contains(grid), "\(name) \(size): the tiles \(grid) leave the window")
                if let headline = frames["careStudio.results.headline"] {
                    XCTAssertTrue(bounds.contains(headline), "\(name) \(size): the headline \(headline) leaves the window")
                    XCTAssertLessThanOrEqual(headline.maxY, grid.minY + 0.5, "\(name) \(size): the headline runs into the tiles")
                }
                if frames["careStudio.tiles.scroll"] == nil {
                    for (key, tile) in frames where key.hasPrefix("careStudio.tile.") {
                        XCTAssertTrue(grid.insetBy(dx: -0.5, dy: -0.5).contains(tile),
                                      "\(name) \(size): \(key) \(tile) runs out of its grid \(grid)")
                    }
                }
                if let footnote = frames["careStudio.footnote"] {
                    XCTAssertTrue(bounds.contains(footnote), "\(name) \(size): the safety line leaves the window")
                }
            }
        }
    }

    private func resultTilePages(store: ScanStore) async throws -> [(String, AnyView)] {
        let privacy = BrowserPrivacyPreviewFixture.makeStore()
        privacy.startScan()
        await privacy.waitUntilIdle()
        store.installedApps = FeatureLightfieldApplicationsFixture.uninstallApps
        let model = ApplicationsManagerModel.of(store)
        model.load(inventory: store.installedApps, readsDisk: false)
        return [
            ("duplicates-results", AnyView(MainContentHost(route: .duplicates, showsIntegratedTitlebar: false) {
                CareStudioClutterResults(store: store, confirmedGroups: 12, confirmedFiles: 31, logicalBytes: 4_820_000_000,
                                         physicalBytes: 3_100_000_000, candidateGroups: 5,
                                         onReview: { _ in }, onStartOver: {})
            })),
            ("privacy-results", AnyView(MainContentHost(route: .privacy, showsIntegratedTitlebar: false) {
                CareStudioProtectionResults(privacy: privacy, onReview: {}, onShowDataTypes: {})
            })),
            ("uninstall-results", AnyView(MainContentHost(route: .uninstall, showsIntegratedTitlebar: false) {
                CareStudioApplicationsOverview(model: model, store: store, showHistory: {})
                    .environment(\.featurePresentationIsFixture, true)
            }))
        ]
    }

    /// D154: with motion on, a landing picture and the result tiles come to
    /// rest exactly where the still layout puts them.
    func testMotionComesToRestOnTheStillLayout() async throws {
        let store = try ScanStore.makeForTests(for: self)
        let pages: [(String, (Bool) -> AnyView)] = [
            ("clutter-results", { still in AnyView(CareStudioClutterResults(store: store, confirmedGroups: 12, confirmedFiles: 31,
                logicalBytes: 4_820_000_000, physicalBytes: 3_100_000_000, candidateGroups: 5,
                onReview: { _ in }, onStartOver: {}).environment(\.featureDisablesLayoutAnimations, still)) }),
            ("smartscan-landing", { still in AnyView(SmartCareLandingView(store: store, latestStatus: nil)
                .environment(\.featureDisablesLayoutAnimations, still)) })
        ]
        let size = CGSize(width: 1_024, height: 734)
        for (name, make) in pages {
            var rest: [[String: CGRect]] = []
            for still in [true, false] {
                let recorder = ProbeRecorder()
                let root = make(still)
                    .layoutProbe("careStudio.review.viewport")
                    .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                        Task { @MainActor in recorder.frames = frames }
                    }
                let controller = NSHostingController(rootView: AnyView(root))
                controller.sizingOptions = []
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.animationBehavior = .none
                window.contentViewController = controller
                window.setContentSize(size)
                window.orderFront(nil)
                defer {
                    window.orderOut(nil)
                    window.close()
                }
                // Long enough for the springs and the last tile's delay.
                for _ in 0..<90 {
                    controller.view.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard let viewport = recorder.frames["careStudio.review.viewport"] else {
                    return XCTFail("\(name): the page did not lay out")
                }
                rest.append(recorder.frames.filter { $0.key.hasPrefix("careStudio.tile.") || $0.key == "careStudio.art" }
                    .mapValues { $0.offsetBy(dx: -viewport.minX, dy: -viewport.minY) })
            }
            XCTAssertFalse(rest[0].isEmpty, name)
            XCTAssertEqual(Set(rest[0].keys), Set(rest[1].keys), name)
            for (key, frame) in rest[0] {
                let moved = try XCTUnwrap(rest[1][key])
                XCTAssertEqual(moved.minX, frame.minX, accuracy: 0.5, "\(name) \(key)")
                XCTAssertEqual(moved.minY, frame.minY, accuracy: 0.5, "\(name) \(key)")
                XCTAssertEqual(moved.width, frame.width, accuracy: 0.5, "\(name) \(key)")
            }
        }
    }

    /// D154 batch 3B: the My Clutter manager keeps its categories, the
    /// review list and the footer action inside the light panel at every
    /// supported size, and offers nothing to remove until copies are chosen.
    func testClutterManagerKeepsTheReviewInsideThePanelAtEverySize() async throws {
        let store = try ScanStore.makeForTests(for: self)
        let page = AnyView(MainContentHost(route: .duplicates, showsIntegratedTitlebar: false) {
            Self.clutterManager(store: store, filter: .all)
        })
        let recorder = ProbeRecorder()
        let root = page
            .environment(\.featureDisablesLayoutAnimations, true)
            .layoutProbe("careStudio.review.viewport")
            .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                Task { @MainActor in recorder.frames = frames }
            }
        let controller = NSHostingController(rootView: AnyView(root))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1_024, height: 734),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentViewController = controller
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        for size in [CGSize(width: 1_500, height: 960), CGSize(width: 1_024, height: 734),
                     CGSize(width: 604, height: 490), CGSize(width: 473, height: 360)] {
            window.setContentSize(size)
            var settled: [String: CGRect]?
            var previous: [String: CGRect] = [:]
            for _ in 0..<60 {
                controller.view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(15))
                guard let viewport = recorder.frames["careStudio.review.viewport"],
                      abs(viewport.width - size.width) < 0.5, abs(viewport.height - size.height) < 0.5,
                      recorder.frames["careStudio.manager.primary"] != nil else { continue }
                let local = recorder.frames.mapValues { $0.offsetBy(dx: -viewport.minX, dy: -viewport.minY) }
                if local == previous { settled = local; break }
                previous = local
            }
            let frames = try XCTUnwrap(settled, "\(size): the manager did not settle")
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
            let panel = try XCTUnwrap(frames["careStudio.manager.clutter"])
            let primary = try XCTUnwrap(frames["careStudio.manager.primary"])
            let list = try XCTUnwrap(frames["lightfield.results.scrollViewport"])
            let categories = try XCTUnwrap(frames["careStudio.manager.clutter.categories"])
            XCTAssertTrue(bounds.contains(panel), "\(size): the panel \(panel) leaves the window")
            for (key, frame) in [("primary", primary), ("list", list), ("categories", categories)] {
                XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(size): \(key) \(frame) leaves the panel")
            }
            XCTAssertLessThanOrEqual(list.maxY, primary.minY + 0.5, "\(size): the list runs under the footer")
            XCTAssertNotNil(frames["lightfield.duplicates.group.group-0"], "\(size): the first group is listed")
            let title = try XCTUnwrap(frames["careStudio.manager.title"])
            let controls = try XCTUnwrap(frames["careStudio.manager.controls"])
            XCTAssertFalse(title.intersects(controls), "\(size): the title \(title) runs under the search \(controls)")
        }
        // Nothing is selected, so nothing can be moved.
        XCTAssertTrue(store.duplicateFilesWorkspace.selectedItemIDs.isEmpty)
    }

    /// D221: Large & Old Files keeps its filters, the file list and the
    /// footer action inside the light panel at every supported size, the
    /// filters above the list and the list above the footer; it lists the
    /// large-file list's files and selects none of them.
    func testClutterLargeOldFilesKeepsTheListInsideThePanelAtEverySize() async throws {
        let store = try ScanStore.makeForTests(for: self)
        let kinds = ["pdf", "mov", "zip", "jpg"]
        let items = (0..<12).map { index in
            let path = "/DebugFixture/Documents/Large file \(index).\(kinds[index % kinds.count])"
            return StorageItem(id: "large-\(index)", title: URL(fileURLWithPath: path).lastPathComponent, path: path,
                               sourceID: "large_files", groupTitle: "", sizeBytes: Int64(index + 1) * 300_000_000, tier: .yellow,
                               kind: "file", reason: "", recommendation: "", risk: "", requiresClose: "",
                               trashPaths: [path], openPath: path,
                               modifiedAt: Date().addingTimeInterval(-Double(index) * 40 * 24 * 60 * 60), status: .available)
        }
        store.largeFilesWorkspace.replaceItemsForTesting(items)
        let largeOld = ToolboxStores.of(store).largeOldFiles
        XCTAssertEqual(largeOld.rows.count, items.count)
        let page = AnyView(MainContentHost(route: .duplicates, showsIntegratedTitlebar: false) {
            Self.clutterManager(store: store, filter: .all, showsLargeOld: true)
        })
        let recorder = ProbeRecorder()
        let root = page
            .environment(\.featureDisablesLayoutAnimations, true)
            .layoutProbe("careStudio.review.viewport")
            .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                Task { @MainActor in recorder.frames = frames }
            }
        let controller = NSHostingController(rootView: AnyView(root))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1_024, height: 734),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentViewController = controller
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        for size in [CGSize(width: 1_500, height: 960), CGSize(width: 1_024, height: 734),
                     CGSize(width: 604, height: 490), CGSize(width: 473, height: 360)] {
            window.setContentSize(size)
            var settled: [String: CGRect]?
            var previous: [String: CGRect] = [:]
            for _ in 0..<60 {
                controller.view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(15))
                guard let viewport = recorder.frames["careStudio.review.viewport"],
                      abs(viewport.width - size.width) < 0.5, abs(viewport.height - size.height) < 0.5,
                      recorder.frames["careStudio.manager.primary"] != nil,
                      recorder.frames["careStudio.manager.clutter.largeOld"] != nil else { continue }
                let local = recorder.frames.mapValues { $0.offsetBy(dx: -viewport.minX, dy: -viewport.minY) }
                if local == previous { settled = local; break }
                previous = local
            }
            let frames = try XCTUnwrap(settled, "\(size): Large & Old Files did not settle")
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
            let panel = try XCTUnwrap(frames["careStudio.manager.clutter"])
            let primary = try XCTUnwrap(frames["careStudio.manager.primary"])
            let list = try XCTUnwrap(frames["careStudio.manager.clutter.largeOld"])
            let filters = try XCTUnwrap(frames["careStudio.manager.clutter.largeOld.filters"])
            let categories = try XCTUnwrap(frames["careStudio.manager.clutter.categories"])
            XCTAssertTrue(bounds.contains(panel), "\(size): the panel \(panel) leaves the window")
            for (key, frame) in [("primary", primary), ("list", list), ("filters", filters), ("categories", categories)] {
                XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(size): \(key) \(frame) leaves the panel")
            }
            XCTAssertLessThanOrEqual(filters.maxY, list.minY + 0.5, "\(size): the filters run into the list")
            XCTAssertLessThanOrEqual(list.maxY, primary.minY + 0.5, "\(size): the list runs under the footer")
            XCTAssertFalse(categories.intersects(filters), "\(size): the filters run into the categories")
            let title = try XCTUnwrap(frames["careStudio.manager.title"])
            let controls = try XCTUnwrap(frames["careStudio.manager.controls"])
            XCTAssertFalse(title.intersects(controls), "\(size): the title \(title) runs under the search \(controls)")
        }
        // Nothing is selected, so nothing can be moved.
        XCTAssertTrue(largeOld.selectedIDs.isEmpty)
        XCTAssertNil(largeOld.trashPlan)
    }

    /// D226: Downloads keeps its grouped list, the line to Applications →
    /// Installers and the footer action inside the light panel at every
    /// supported size, the list above the line and the line above the
    /// footer; nothing is selected.
    func testClutterDownloadsKeepsTheListInsideThePanelAtEverySize() async throws {
        let store = try ScanStore.makeForTests(for: self)
        let folder = "/DebugFixture/Downloads"
        let names = (0..<14).map { "Download \($0).\(["pdf", "zip", "mov", "txt"][$0 % 4])" }
        let entries = names.enumerated().map { index, name in
            StorageMapIndexedEntry(name: name, kind: "file", sizeBytes: Int64(index + 1) * 120_000_000, isDirectory: false,
                                   canDescend: false, isEstimated: false)
        }
        let index = StorageMapAnalysisIndex(rootPath: folder, rootVolumeIdentifier: nil,
                                            directories: [folder: StorageMapDirectoryAggregate(immediateChildCount: entries.count)],
                                            childrenByDirectory: [folder: entries], blockedDirectoryPaths: [], duplicateFilePaths: [])
        let analysis = StorageMapAnalysisResult(
            target: .init(path: folder, title: "Downloads", kind: .homeDirectory), volumeTotalBytes: 1_000_000_000_000,
            volumeAvailableBytes: 500_000_000_000, inspectedItemCount: entries.count, omittedItemCount: 0, scanSeconds: 1,
            index: index, rootSnapshot: try DiskScanner(excludedPaths: []).storageMapSnapshot(at: folder, using: index))
        let sources: [DownloadSource] = [.application("Safari"), .site("github.com"), .other]
        let downloads = ToolboxStores.of(store).downloads
        downloads.replaceReadingForTesting(.init(analysis: analysis, sources: Dictionary(uniqueKeysWithValues: names.enumerated().map {
            (folder + "/" + $0.element, sources[$0.offset % sources.count])
        }), modifiedDates: [:]))
        XCTAssertEqual(downloads.rows.count, names.count)
        let page = AnyView(MainContentHost(route: .duplicates, showsIntegratedTitlebar: false) {
            Self.clutterManager(store: store, filter: .all, showsDownloads: true)
        })
        let recorder = ProbeRecorder()
        let root = page
            .environment(\.featureDisablesLayoutAnimations, true)
            .layoutProbe("careStudio.review.viewport")
            .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                Task { @MainActor in recorder.frames = frames }
            }
        let controller = NSHostingController(rootView: AnyView(root))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1_024, height: 734),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentViewController = controller
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        for size in [CGSize(width: 1_500, height: 960), CGSize(width: 1_024, height: 734),
                     CGSize(width: 604, height: 490), CGSize(width: 473, height: 360)] {
            window.setContentSize(size)
            var settled: [String: CGRect]?
            var previous: [String: CGRect] = [:]
            for _ in 0..<60 {
                controller.view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(15))
                guard let viewport = recorder.frames["careStudio.review.viewport"],
                      abs(viewport.width - size.width) < 0.5, abs(viewport.height - size.height) < 0.5,
                      recorder.frames["careStudio.manager.primary"] != nil,
                      recorder.frames["careStudio.manager.clutter.downloads"] != nil else { continue }
                let local = recorder.frames.mapValues { $0.offsetBy(dx: -viewport.minX, dy: -viewport.minY) }
                if local == previous { settled = local; break }
                previous = local
            }
            let frames = try XCTUnwrap(settled, "\(size): Downloads did not settle")
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
            let panel = try XCTUnwrap(frames["careStudio.manager.clutter"])
            let primary = try XCTUnwrap(frames["careStudio.manager.primary"])
            let list = try XCTUnwrap(frames["careStudio.manager.clutter.downloads"])
            let installers = try XCTUnwrap(frames["careStudio.manager.clutter.downloads.installers"])
            let categories = try XCTUnwrap(frames["careStudio.manager.clutter.categories"])
            XCTAssertTrue(bounds.contains(panel), "\(size): the panel \(panel) leaves the window")
            for (key, frame) in [("primary", primary), ("list", list), ("installers", installers), ("categories", categories)] {
                XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(size): \(key) \(frame) leaves the panel")
            }
            XCTAssertLessThanOrEqual(list.maxY, installers.minY + 0.5, "\(size): the list runs into the installers line")
            XCTAssertLessThanOrEqual(installers.maxY, primary.minY + 0.5, "\(size): the installers line runs under the footer")
            XCTAssertFalse(categories.intersects(installers), "\(size): the installers line runs into the categories")
            let title = try XCTUnwrap(frames["careStudio.manager.title"])
            let controls = try XCTUnwrap(frames["careStudio.manager.controls"])
            XCTAssertFalse(title.intersects(controls), "\(size): the title \(title) runs under the search \(controls)")
        }
        // Nothing is selected, so nothing can be moved.
        XCTAssertTrue(downloads.selectedIDs.isEmpty)
        XCTAssertNil(downloads.trashPlan)
    }

    /// D154 batch 3E: the Protection manager keeps the review inside the
    /// panel at every size — the browsers column, the records and the
    /// footer's action in the panel, the records above the action, the first
    /// browser's rows listed. Nothing is selected, so nothing can be deleted.
    func testProtectionManagerKeepsTheReviewInsideThePanelAtEverySize() async throws {
        let privacy = BrowserPrivacyPreviewFixture.makeStore()
        privacy.startScan()
        await privacy.waitUntilIdle()
        await privacy.waitForFilteredResults()
        // The list's first row is the first browser's first profile (the
        // index puts Safari before Chrome).
        let firstProfile = try XCTUnwrap(privacy.resultPresentation?.browserGroups.first?.profiles.first?.id.profileID)
        let page = AnyView(MainContentHost(route: .privacy, showsIntegratedTitlebar: false) {
            BrowserPrivacyRecordResultsView(store: privacy, onShowDataTypes: {}, onShowResults: {}, presentsManager: true)
        })
        let recorder = ProbeRecorder()
        let root = page
            .environment(\.featureDisablesLayoutAnimations, true)
            .layoutProbe("careStudio.review.viewport")
            .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                Task { @MainActor in recorder.frames = frames }
            }
        let controller = NSHostingController(rootView: AnyView(root))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1_024, height: 734),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentViewController = controller
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        for size in [CGSize(width: 1_500, height: 960), CGSize(width: 1_024, height: 734),
                     CGSize(width: 604, height: 490), CGSize(width: 473, height: 360)] {
            window.setContentSize(size)
            var settled: [String: CGRect]?
            var previous: [String: CGRect] = [:]
            for _ in 0..<60 {
                controller.view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(15))
                guard let viewport = recorder.frames["careStudio.review.viewport"],
                      abs(viewport.width - size.width) < 0.5, abs(viewport.height - size.height) < 0.5,
                      recorder.frames["careStudio.manager.primary"] != nil else { continue }
                let local = recorder.frames.mapValues { $0.offsetBy(dx: -viewport.minX, dy: -viewport.minY) }
                if local == previous { settled = local; break }
                previous = local
            }
            let frames = try XCTUnwrap(settled, "\(size): the manager did not settle")
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
            let panel = try XCTUnwrap(frames["careStudio.manager.protection"])
            let primary = try XCTUnwrap(frames["careStudio.manager.primary"])
            let list = try XCTUnwrap(frames["careStudio.manager.protection.list"])
            let categories = try XCTUnwrap(frames["careStudio.manager.protection.categories"])
            XCTAssertTrue(bounds.contains(panel), "\(size): the panel \(panel) leaves the window")
            for (key, frame) in [("primary", primary), ("list", list), ("categories", categories)] {
                XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(size): \(key) \(frame) leaves the panel")
            }
            XCTAssertLessThanOrEqual(list.maxY, primary.minY + 0.5, "\(size): the records run under the footer")
            XCTAssertNotNil(frames["lightfield.privacy.profile." + firstProfile], "\(size): the first browser is listed")
            // The title moves aside (or truncates) in a narrow panel, never under the search.
            let title = try XCTUnwrap(frames["careStudio.manager.title"])
            let controls = try XCTUnwrap(frames["careStudio.manager.controls"])
            XCTAssertFalse(title.intersects(controls), "\(size): the title \(title) runs under the search \(controls)")
        }
        // History is never selected by default, so the footer's action stays off.
        XCTAssertTrue(privacy.selectedRecordIDs.isEmpty)
    }

    /// D154 batch 3F: the Cookies and Other Data manager keeps its review
    /// inside the panel at every size — the types column, the rows and the
    /// footer's action in the panel, the rows above the action, the first row
    /// listed, the title clear of the search. Nothing is selected by default.
    func testDataTypesManagerKeepsTheReviewInsideThePanelAtEverySize() async throws {
        let store = Self.dataTypesStore(defaults: TestPreferenceDomain.make(for: self))
        let page = AnyView(MainContentHost(route: .privacy, showsIntegratedTitlebar: false) {
            BrowserPrivacyDataView(store: store)
        })
        let recorder = ProbeRecorder()
        let root = page
            .environment(\.featureDisablesLayoutAnimations, true)
            .layoutProbe("careStudio.review.viewport")
            .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                Task { @MainActor in recorder.frames = frames }
            }
        let controller = NSHostingController(rootView: AnyView(root))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1_024, height: 734),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentViewController = controller
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        for size in [CGSize(width: 1_500, height: 960), CGSize(width: 1_024, height: 734),
                     CGSize(width: 604, height: 490), CGSize(width: 473, height: 360)] {
            window.setContentSize(size)
            var settled: [String: CGRect]?
            var previous: [String: CGRect] = [:]
            for _ in 0..<60 {
                controller.view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(15))
                guard let viewport = recorder.frames["careStudio.review.viewport"],
                      abs(viewport.width - size.width) < 0.5, abs(viewport.height - size.height) < 0.5,
                      recorder.frames["toolbox.footer.action"] != nil else { continue }
                let local = recorder.frames.mapValues { $0.offsetBy(dx: -viewport.minX, dy: -viewport.minY) }
                if local == previous { settled = local; break }
                previous = local
            }
            let frames = try XCTUnwrap(settled, "\(size): the manager did not settle")
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
            let panel = try XCTUnwrap(frames["toolbox.manager"])
            let action = try XCTUnwrap(frames["toolbox.footer.action"])
            let list = try XCTUnwrap(frames["careStudio.manager.dataTypes.list"])
            let categories = try XCTUnwrap(frames["careStudio.manager.dataTypes.categories"])
            XCTAssertTrue(bounds.contains(panel), "\(size): the panel \(panel) leaves the window")
            for (key, frame) in [("action", action), ("list", list), ("categories", categories)] {
                XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(size): \(key) \(frame) leaves the panel")
            }
            XCTAssertLessThanOrEqual(list.maxY, action.minY + 0.5, "\(size): the rows run under the footer")
            XCTAssertNotNil(frames["toolbox.row"], "\(size): the first row is listed")
            let title = try XCTUnwrap(frames["careStudio.manager.title"])
            let controls = try XCTUnwrap(frames["careStudio.manager.controls"])
            XCTAssertFalse(title.intersects(controls), "\(size): the title \(title) runs under the search \(controls)")
        }
        // Reading never selects anything, so the footer's action stays off.
        XCTAssertTrue(store.selection.isEmpty)
    }

    /// Chrome's cookies for four sites and its download list, as read.
    private static func dataTypesStore(defaults: UserDefaults) -> BrowserPrivacyDataStore {
        let chrome = BrowserPrivacyBrowser(id: "chrome", displayName: "Google Chrome", engine: .chromium,
                                           bundleIdentifier: "com.google.Chrome", version: "Fixture")
        let root = URL(fileURLWithPath: "/DebugFixture/Chrome/Default", isDirectory: true)
        let profile = BrowserPrivacyProfile(id: "chrome:Default", browser: chrome, displayName: "Default",
                                            historyDatabaseURL: root.appendingPathComponent("History"),
                                            sourceTrustedParentURL: root)
        let cookies = ["news.example", "shop.example", "mail.example", "video.example"].enumerated().map { index, site in
            BrowserPrivacyDataGroup(profile: profile, contract: .chromiumCookies, key: site, count: 3 + index,
                                    identities: [], writable: true)
        }
        let downloads = BrowserPrivacyDataGroup(profile: profile, contract: .chromiumDownloads, key: "downloads",
                                                count: 12, identities: [], writable: true)
        let store = BrowserPrivacyDataStore(defaults: defaults)
        store.applyScanResults(cookies + [downloads])
        return store
    }

    /// The clutter manager on the fixture groups (four proven groups, three
    /// similar-photo groups), as the duplicates page shows it. D221:
    /// `showsLargeOld` offers and shows Large & Old Files. D226:
    /// `showsDownloads` offers and shows Downloads.
    private static func clutterManager(store: ScanStore, filter: DuplicateResultFilter,
                                       showsLargeOld: Bool = false, showsDownloads: Bool = false) -> some View {
        let items = FeatureLightfieldFileResultFixture.duplicateGroups(similar: false).flatMap(\.items)
            + FeatureLightfieldFileResultFixture.duplicateGroups(similar: true).flatMap(\.items).map { item in
                StorageItem(id: "similar-" + item.id, title: item.title, path: item.path + ".similar", groupTitle: item.groupTitle,
                            sizeBytes: item.sizeBytes, tier: item.tier, kind: item.kind, reason: item.reason,
                            recommendation: item.recommendation, risk: item.risk, requiresClose: item.requiresClose,
                            trashPaths: [], openPath: "", isDirectory: false,
                            duplicateGroupID: "similar-" + (item.duplicateGroupID ?? ""),
                            duplicateMatchKind: item.duplicateMatchKind, status: .available)
            }
        store.duplicateFilesWorkspace.replaceItemsForTesting(items)
        let groups = DuplicateFilesPresenter.groups(from: items, filter: filter, sort: .reclaimable)
        return CareStudioClutterManager(store: store, workspace: store.duplicateFilesWorkspace, allItems: items,
                                        groups: groups, filter: filter, details: AnyView(EmptyView()),
                                        onFilter: { _ in }, onBack: {},
                                        showsLargeOld: showsLargeOld, onLargeOld: showsLargeOld ? {} : nil,
                                        showsDownloads: showsDownloads, onDownloads: showsDownloads ? {} : nil)
    }

    /// The pages `testTemplatePages…` check, named "route-phase". Results
    /// keep the D67 layout on the module gradient; they are captured only.
    private func templatePages(store: ScanStore,
                               phases: [FeaturePresentationDemo.Phase] = [.landing, .running]) throws -> [(String, AnyView)] {
        let health = ComputerHealthStore(probe: ReviewInertProbe(),
            batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController())
        let network = NetworkSpeedTestStore(), browser = BrowserPrivacyStore()
        var pages: [(String, AnyView)] = []
        for route in [ReviewFilter.privacy, .duplicates, .largeFiles, .migration, .updater, .healthHub, .energy, .performance] {
            for phase in phases {
                let session = FeaturePresentationDemo()
                session.phase = phase
                // In the window's content host, as the detail router shows it.
                pages.append(("\(route.rawValue)-\(phase.rawValue)", AnyView(
                    MainContentHost(route: route, showsIntegratedTitlebar: false) {
                        FeaturePresentationDemoView(session: session, store: store, module: route, healthStore: health,
                                                    networkStore: network, browserStore: browser,
                                                    isSimilarPhotosOverride: false)
                    })))
            }
        }
        // The D141 studio landings share the frame and its safety line.
        pages.append(("overview-landing", AnyView(MainContentHost(route: .overview, showsIntegratedTitlebar: false) {
            SmartCareLandingView(store: store, latestStatus: nil)
        })))
        for route in [ReviewFilter.green, .devCaches] {
            pages.append(("\(route.rawValue)-landing", AnyView(MainContentHost(route: route, showsIntegratedTitlebar: false) {
                ToolPreparationView(store: store, filter: route)
            })))
        }
        pages.append(("memory-landing", AnyView(MainContentHost(route: .memory, showsIntegratedTitlebar: false) {
            CareStudioMemoryLanding(snapshot: nil, isLoading: true, canFreeUp: false, onFreeUp: {}, onShowApps: {})
        })))
        pages.append(("uninstall-landing", AnyView(MainContentHost(route: .uninstall, showsIntegratedTitlebar: false) {
            CareStudioApplicationsStart(store: store)
        })))
        pages.append(("uninstall-removing", AnyView(MainContentHost(route: .uninstall, showsIntegratedTitlebar: false) {
            CareStudioApplicationsRemoving(current: "Google Chrome", index: 1, total: 3, leftovers: false)
        })))
        pages.append(("cloudCleanup-landing", AnyView(MainContentHost(route: .cloudCleanup, showsIntegratedTitlebar: false) {
            CareStudioCloudCleanupPage(store: store)
        })))
        return pages
    }

    private static func route(of name: String) -> ReviewFilter {
        ReviewFilter(rawValue: String(name.split(separator: "-").first ?? "")) ?? .overview
    }

    /// D144 revision (live check 2026-10-20): the way back from the classic
    /// memory page sits in its status line, as other pages' secondary
    /// actions do; in the header's corner it ran into "已采样应用与进程".
    func testClassicMemoryPageOffersTheWayBackInItsStatusLine() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let store = try ScanStore.makeForTests(for: self)
        let snapshot = LightfieldPerformanceFixture.memory
        store.memorySnapshot = snapshot
        let size = CGSize(width: 1_070, height: 735)
        let root = LightfieldMemoryPage(store: store, snapshot: snapshot, displaySnapshot: snapshot, trendPoints: [],
                                        startsWithProcesses: true, showsProcesses: .constant(true),
                                        backToFreeUp: {})
            .defaultAppStorage(defaults).environment(\.featurePresentationIsFixture, true)
            .environment(\.featureDisablesLayoutAnimations, true)
        let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: true)
        defer { host.close() }
        let frames = try await host.frames(required: ["lightfield.status.action", "lightfield.memory.overview"], size: size)
        let back = try XCTUnwrap(frames["lightfield.status.action"])
        let overview = try XCTUnwrap(frames["lightfield.memory.overview"])
        XCTAssertGreaterThan(back.minY, overview.maxY, "the link is in the status line, below the header")
        XCTAssertFalse(back.intersects(overview))
    }

    @MainActor
    private final class ProbeRecorder {
        var frames: [String: CGRect] = [:]
    }

    /// D176: the full 210 pt sidebar now also shows beside the result,
    /// scanning and cleaning pages — before the first scan of a launch, and
    /// whenever the user expands it by hand (before, those pages always
    /// folded it). Beside it the pages still fit a 960–1280 pt window: the
    /// page gets the rest of the width, and its title, cards and round button
    /// stay inside it, the text above the button. Whole-window screenshots go
    /// to the evidence folder. The real sidebar sits at its full width beside
    /// the page; that the window's split view gives it 210 pt is
    /// `CareStudioNavigationTests`' check. (A NavigationSplitView here laid
    /// the page out in a 100 pt column first and its probes kept those
    /// frames, so the first window run read them.)
    func testResultAndScanningPagesFitBesideTheFullSidebar() async throws {
        let store = try ScanStore.makeForTests(for: self)
        store.installDebugSmartScanSessionFixture(.results)
        let session = try XCTUnwrap(store.cleanupScanSession)
        let scanningCare = await Self.smartCare(holding: .performance, for: self)
        let finishedCare = await Self.smartCare(holding: nil, for: self)
        defer { scanningCare.stop() }
        let evidence = ProcessInfo.processInfo.environment["STORAGE_CLEANER_CARESTUDIO_EVIDENCE"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let pages: [(name: String, filter: ReviewFilter, page: AnyView)] = [
            ("smartcare-results", .overview, AnyView(SmartCareResultsPage(store: store, smartCare: finishedCare, privacy: nil))),
            ("smartcare-scanning", .overview, AnyView(SmartCareScanningPage(store: store, smartCare: scanningCare, privacy: nil))),
            ("cleanup-results", .green, AnyView(CleanupScanResultsView(store: store, filter: .green, session: session))),
            ("cleanup-scanning", .green, AnyView(SmartScanScanningPage(progress: CareStudioRenderReviewTests.scanProgress(),
                                                                       module: .green, canCancel: true, onCancel: {}))),
            ("cleaning", .green, AnyView(SmartScanCleanupProgressPage(store: store,
                                                                      progress: CareStudioRenderReviewTests.executionFixture(),
                                                                      onCancel: {}))),
        ]
        for entry in pages {
            for size in [CGSize(width: 960, height: 700), CGSize(width: 1_024, height: 734), CGSize(width: 1_280, height: 763)] {
                let recorder = ProbeRecorder()
                let root = HStack(spacing: 0) {
                    SidebarView(store: store, selection: .constant(entry.filter), presentation: .full,
                                onTogglePresentation: nil)
                        .frame(width: FeatureLightfield.sidebarWidth)
                    entry.page
                        .layoutProbe("careStudio.review.viewport")
                }
                .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                    Task { @MainActor in recorder.frames = frames }
                }
                .environment(\.featureDisablesLayoutAnimations, true)
                let controller = NSHostingController(rootView: AnyView(root))
                controller.sizingOptions = []
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                                      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.animationBehavior = .none
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentViewController = controller
                window.setContentSize(size)
                window.orderFront(nil)
                defer {
                    window.orderOut(nil)
                    window.close()
                }
                let label = "\(entry.name) \(Int(size.width))"
                var settled: [String: CGRect]?
                var previous: [String: CGRect] = [:]
                var stable = 0
                // Wait for the page to fill the rest of the window and hold
                // still for three passes. (The Cleanup module's own results
                // have no round button — only Smart Scan's do — so the button
                // is not part of settling.)
                for _ in 0..<160 {
                    controller.view.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(15))
                    guard let viewport = recorder.frames["careStudio.review.viewport"],
                          abs(viewport.width - (size.width - FeatureLightfield.sidebarWidth)) < 3 else { stable = 0; continue }
                    stable = recorder.frames == previous ? stable + 1 : 0
                    previous = recorder.frames
                    if stable >= 3 { settled = recorder.frames; break }
                }
                guard let frames = settled else {
                    let viewport = recorder.frames["careStudio.review.viewport"]
                    XCTFail("\(label): the page did not settle: page \(viewport.map { "\($0)" } ?? "missing"), "
                            + "expected width \(size.width - FeatureLightfield.sidebarWidth), "
                            + "\(recorder.frames.count) probes: \(recorder.frames.keys.sorted().prefix(40))")
                    continue
                }
                let viewport = try XCTUnwrap(frames["careStudio.review.viewport"])
                XCTAssertEqual(viewport.width, size.width - FeatureLightfield.sidebarWidth, accuracy: 3,
                               "\(label): the page gets the rest of the width")
                let action = frames["careStudio.action"]
                if let action {
                    XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(action), "\(label): \(action) leaves the page")
                }
                let keys = ["careStudio.title", "careStudio.status", "careStudio.running.title", "careStudio.running.detail",
                            "smartCare.results.title", "careStudio.results.headline", "careStudio.tiles"]
                let shown = keys.compactMap { key in frames[key].map { (key, $0) } }
                XCTAssertFalse(shown.isEmpty, "\(label): no title or cards on the page")
                for (key, frame) in shown {
                    XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                                  "\(label): \(key) \(frame) leaves the page \(viewport)")
                    if let action {
                        XCTAssertLessThanOrEqual(frame.maxY, action.minY + 0.5, "\(label): \(key) reaches the round button")
                    }
                }
                if let evidence {
                    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
                    let hosted = try XCTUnwrap(window.contentView, label)
                    let bitmap = try XCTUnwrap(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds), label)
                    hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: evidence.appendingPathComponent("w22-fullsidebar-\(entry.name)-\(Int(size.width)).png"))
                }
            }
        }
    }

    /// D154 batch 3P: the counts as they play in a window (animations on, a
    /// frame every 50 ms), for review: the completion page's amount after its
    /// success mark, and Smart Care's cards counting as they arrive.
    func testCountsPlayInAWindowForReview() async throws {
        guard let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_CARESTUDIO_EVIDENCE"] else {
            throw XCTSkip("Review captures are written only when STORAGE_CLEANER_CARESTUDIO_EVIDENCE is set.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("w21-counting", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = GeneratedArtLibrary(directory: projectRoot.appendingPathComponent("Resources/Art", isDirectory: true))
        for art in GeneratedArt.allCases {
            _ = await library.image(named: art.resourceName(.landing))
            _ = await library.image(named: art.resourceName(.header))
        }
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }
        let store = try ScanStore.makeForTests(for: self)
        store.installDebugSmartScanSessionFixture(.results)
        let finishedCare = await Self.smartCare(holding: nil, for: self)
        try await playFrames(SmartScanCleanupCompletedPage(store: store,
                                                           report: CareStudioRenderReviewTests.completedReportFixture(),
                                                           onDone: {}),
                             name: "completed", library: library, directory: directory)
        try await playFrames(SmartCareResultsPage(store: store, smartCare: finishedCare, privacy: nil),
                             name: "smartcare-results", library: library, directory: directory)
    }

    /// Hosts `view` with its animations on and writes a frame every 50 ms.
    private func playFrames<V: View>(_ view: V, name: String, library: GeneratedArtLibrary, directory: URL,
                                     count: Int = 26) async throws {
        let size = Self.size
        let root = view
            .frame(width: size.width, height: size.height)
            .environment(\.generatedArtLibrary, library)
            .environment(\.generatedArtWindowVisible, true)
        let controller = NSHostingController(rootView: AnyView(root))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        for index in 0..<count {
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let hosted = controller.view
            let bitmap = try XCTUnwrap(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds), name)
            hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(String(format: "%@-%02d.png", name, index)))
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func capture<V: View>(_ view: V, name: String, library: GeneratedArtLibrary,
                                  directory: URL, size: CGSize = CareStudioWindowReviewTests.size) async throws {
        let root = view
            .frame(width: size.width, height: size.height)
            .environment(\.generatedArtLibrary, library)
            .environment(\.generatedArtWindowVisible, true)
            .environment(\.featureDisablesLayoutAnimations, true)
        let controller = NSHostingController(rootView: AnyView(root))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: name.hasSuffix("-light") ? .aqua : .darkAqua)
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        for _ in 0..<24 {
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        let hosted = controller.view
        let bitmap = try XCTUnwrap(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds), name)
        hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// D195: a coverage report whose system (BTM) inventory was read, so the
    /// review items render as counted login items rather than "not read".
    static func readStartupCoverage() -> StartupCoverageReport {
        var coverage = StartupCoverageReport.empty
        coverage.managedItemCoverageAvailable = true
        return coverage
    }

    /// Also the off-screen Performance render's items (report §4 item 13).
    static func startupItems() -> [StartupItemsDomain.Item] {
        func item(_ id: String, _ name: String, kind: StartupItemsDomain.ItemKind,
                  enablement: StartupItemsDomain.EnablementState = .enabled,
                  manageable: Bool = false, purpose: String? = nil) -> StartupItemsDomain.Item {
            var capability = StartupItemsDomain.ActionCapability.readOnly
            if manageable {
                capability.canDisableDirectly = enablement == .enabled
                capability.canEnableDirectly = enablement == .disabled
                capability.canStopCurrentSession = true
                capability.isReadOnly = false
            }
            let candidate = StartupItemsDomain.Candidate(
                id: id, source: kind == .openAtLogin ? .openAtLogin : .launchdPlist, kind: kind,
                scope: .currentUser, name: name, label: "com.example.\(id)",
                plistURL: kind == .openAtLogin ? nil
                    : URL(fileURLWithPath: "/Users/fixture/Library/LaunchAgents/com.example.\(id).plist"),
                executableURL: URL(fileURLWithPath: "/Applications/\(name).app/Contents/MacOS/\(name)"),
                applicationURL: nil, configuration: nil,
                state: StartupItemsDomain.State(registration: .registered, authorization: .approved,
                                                enablement: enablement, load: .loaded,
                                                process: enablement == .enabled ? .running(pid: 400) : .stopped,
                                                management: manageable ? .directlyManageable : .manageableInSystemSettings),
                attribution: StartupItemsDomain.Attribution(
                    applicationBundleIdentifier: "com.example.\(id)", applicationURL: nil,
                    applicationName: name, developerName: purpose ?? "Example Labs", teamIdentifier: "TEAM123",
                    designatedRequirement: nil,
                    evidence: [.init(kind: .associatedBundleIdentifier, value: id, confidence: .verified)]),
                actionCapability: capability, diagnosticEvidence: [])
            return StartupItemsDomain.Item(id: id, kind: kind, scope: .currentUser, name: name,
                                           components: [candidate], state: candidate.state,
                                           attribution: candidate.attribution, actionCapability: capability,
                                           warnings: [])
        }
        return [
            item("notes", "Notes Helper", kind: .openAtLogin),
            item("drive", "Cloud Drive", kind: .openAtLogin, purpose: "Sync"),
            item("paste", "Clipboard", kind: .openAtLogin),
            item("agent", "Menu Agent", kind: .userLaunchAgent, manageable: true),
            item("updater", "Product Updater", kind: .userLaunchAgent, enablement: .disabled, manageable: true,
                 purpose: "Update"),
            item("helper", "Render Helper", kind: .appBackgroundTask),
            item("orphan", "Removed Tool", kind: .orphanedItem)
        ]
    }
}

extension CareStudioWindowReviewTests {
    /// D168: a Smart Care whose stand-in scans finish at once, except the
    /// held module, which scans until stopped.
    static func smartCare(holding: SmartCareModule?, for testCase: XCTestCase) async -> SmartCareCoordinator {
        let care = SmartCareCoordinator(scanner: ReviewSmartCareScanner(holding: holding),
                                        defaults: TestPreferenceDomain.make(for: testCase))
        care.start()
        for _ in 0..<200 {
            if let holding, care.stage == .scanning(holding) { break }
            if holding == nil, care.stage == .results { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return care
    }
}

@MainActor
private final class ReviewSmartCareScanner: SmartCareScanning {
    let holding: SmartCareModule?
    private var gate: CheckedContinuation<Void, Never>?

    init(holding: SmartCareModule?) {
        self.holding = holding
    }

    func scan(_ module: SmartCareModule) async -> SmartCareCardState {
        guard module == holding else { return .done }
        await withCheckedContinuation { gate = $0 }
        return .stopped
    }

    func stop(_ module: SmartCareModule) {
        gate?.resume()
        gate = nil
    }
}

private struct ReviewInertProbe: ComputerHealthProbing {
    func probe() async throws -> ComputerHealthSnapshot {
        XCTFail("No hardware reads in the D154 window review")
        throw CancellationError()
    }
}
#endif
