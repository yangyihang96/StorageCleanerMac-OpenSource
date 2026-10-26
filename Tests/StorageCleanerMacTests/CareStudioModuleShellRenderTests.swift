#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D154: renders the CleanMyMac-style sidebar (ten modules) next to the new
/// module pages off screen — no window, no scanner — so the shell can be
/// compared with the recorded CleanMyMac screenshots. PNGs are written only
/// when `STORAGE_CLEANER_CARESTUDIO_EVIDENCE` names a directory.
@MainActor
final class CareStudioModuleShellRenderTests: XCTestCase {
    private static let windowSize = CGSize(width: 1_280, height: 763)
    private static let shortWindow = CGSize(width: 980, height: 520)

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func preloadedArt() async -> GeneratedArtLibrary {
        let library = GeneratedArtLibrary(directory: projectRoot.appendingPathComponent("Resources/Art", isDirectory: true))
        for art in GeneratedArt.allCases {
            _ = await library.image(named: art.resourceName(.landing))
            _ = await library.image(named: art.resourceName(.header))
        }
        return library
    }

    @discardableResult
    private func render<V: View>(_ view: V, name: String, size: CGSize, scheme: ColorScheme,
                                 library: GeneratedArtLibrary) throws -> NSBitmapImageRep {
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme)
            .environment(\.generatedArtLibrary, library)
            .environment(\.generatedArtWindowVisible, true)
            .environment(\.featureDisablesLayoutAnimations, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, name)
        let bitmap = NSBitmapImageRep(cgImage: image)
        XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, size.width, accuracy: 0.5, name)
        if let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_CARESTUDIO_EVIDENCE"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(name).png"))
        }
        return bitmap
    }

    /// The sidebar beside a page, as the split view lays them out.
    private func window<Page: View>(store: ScanStore, rail: Bool = false, privacy: BrowserPrivacyStore? = nil,
                                    @ViewBuilder page: () -> Page) -> some View {
        HStack(spacing: 0) {
            SidebarView(store: store, selection: .constant(store.navigationState.selectedFilter),
                        presentation: rail ? .rail : .full, onTogglePresentation: {}, privacy: privacy)
                .frame(width: rail ? SidebarPresentation.rail.railWidth : FeatureLightfield.sidebarWidth)
            page()
        }
    }

    /// Report §4 item 14: Smart Care's results laid out as CleanMyMac's
    /// (`1比1对照-20261023/cmm/14`): three cards above and two below; junk and
    /// browsing records found, the other three empty and without Review.
    func testRendersTheSmartCareResultsForReview() async throws {
        let library = await preloadedArt()
        let store = try ScanStore.makeForTests(for: self)
        store.installDebugSmartScanSessionFixture(.results)
        let privacy = BrowserPrivacyPreviewFixture.makeStore()
        privacy.startScan()
        await privacy.waitUntilIdle()
        let care = SmartCareCoordinator(scanner: InstantSmartCareScanner(), defaults: TestPreferenceDomain.make(for: self))
        care.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while care.stage != .results, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(care.stage, .results)
        store.navigationState.select(.overview)
        for (language, scheme) in [(AppLanguage.zhHans, ColorScheme.dark), (.english, .dark), (.zhHans, .light)] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            let tag = "\(language == .zhHans ? "zh" : "en")-\(scheme == .dark ? "dark" : "light")"
            try render(window(store: store, rail: true, privacy: privacy) {
                SmartCareResultsPage(store: store, smartCare: care, privacy: privacy)
            }, name: "smartcare-results-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
            try render(window(store: store, rail: true, privacy: privacy) {
                SmartCareResultsPage(store: store, smartCare: care, privacy: privacy)
            }, name: "smartcare-results-short-\(tag)", size: Self.shortWindow, scheme: scheme, library: library)
        }
    }

    /// Report §4 item 15: Smart Care while it scans Protection, laid out as
    /// CleanMyMac's (`1比1对照-20261023/cmm/12`): Protection grown in the first
    /// row, Cleanup done with its result, the others waiting.
    func testRendersTheSmartCareScanForReview() async throws {
        let library = await preloadedArt()
        let store = try ScanStore.makeForTests(for: self)
        store.installDebugSmartScanSessionFixture(.results)
        let care = await CareStudioWindowReviewTests.smartCare(holding: .protection, for: self)
        defer { care.stop() }
        XCTAssertEqual(care.stage, .scanning(.protection))
        store.navigationState.select(.overview)
        for (language, scheme) in [(AppLanguage.zhHans, ColorScheme.dark), (.english, .dark), (.zhHans, .light)] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            let tag = "\(language == .zhHans ? "zh" : "en")-\(scheme == .dark ? "dark" : "light")"
            try render(window(store: store, rail: true) {
                SmartCareScanningPage(store: store, smartCare: care, privacy: nil)
            }, name: "smartcare-scanning-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
        }
    }

    /// Report §4 item 16: the module marks on the sidebar, in the icon rail
    /// and the full sidebar (CleanMyMac `1比1对照-20261023/cmm/14`–`24`,
    /// `cmm2/01`). Smart Scan scanned and stopped at once, so its results
    /// page waits (the yellow dot); Protection, Performance and Applications
    /// show their results (white dots); then Performance reads its items
    /// again (the turning arc). The sector at the stages of `cmm/11`, `12`,
    /// `13` and `19` is drawn beside the other marks.
    func testRendersTheSidebarMarksForReview() async throws {
        let library = await preloadedArt()
        let store = try ScanStore.makeForTests(for: self)
        let privacy = BrowserPrivacyPreviewFixture.makeStore()
        privacy.startScan()
        await privacy.waitUntilIdle()
        store.hasScannedStartupItems = true
        store.hasScannedInstalledApps = true
        let smartCare = SmartCareCoordinator.of(store)
        smartCare.start()
        smartCare.stop()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while smartCare.stage != .results, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(smartCare.stage, .results)
        store.navigationState.select(.uninstall)

        let metrics = SidebarRowMetrics(height: Self.windowSize.height, isRail: true)
        /// The centre of a module's mark in the rail: on the trailing edge of
        /// its 26 pt picture, 6 pt above it.
        func markCentre(_ family: CareStudioFamily) throws -> CGPoint {
            let index = try XCTUnwrap(CareStudioFamily.allCases.filter { !$0.isFooter }.firstIndex(of: family))
            let rowTop = 4 + CGFloat(index) * (metrics.rowHeight + metrics.spacing)
            return CGPoint(x: SidebarPresentation.rail.railWidth / 2 + 13, y: rowTop + (metrics.rowHeight - 26) / 2 - 6)
        }
        func colour(_ bitmap: NSBitmapImageRep, _ point: CGPoint) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(point.x * 2), y: Int(point.y * 2))?.usingColorSpace(.sRGB))
            return (color.redComponent, color.greenComponent, color.blueComponent)
        }

        for scheme in [ColorScheme.dark, .light] {
            let tag = scheme == .dark ? "dark" : "light"
            let rail = try render(window(store: store, rail: true, privacy: privacy) { CareStudioApplicationsStart(store: store) },
                                  name: "sidebar-marks-rail-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
            try render(window(store: store, privacy: privacy) { CareStudioApplicationsStart(store: store) },
                       name: "sidebar-marks-full-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
            guard scheme == .dark else { continue }
            let yellow = try colour(rail, try markCentre(.smartCare))
            XCTAssertTrue(yellow.red > 0.8 && yellow.green > 0.65 && yellow.blue < 0.55, "Smart Scan's yellow dot: \(yellow)")
            for family in [CareStudioFamily.protection, .performance, .applications] {
                let white = try colour(rail, try markCentre(family))
                XCTAssertTrue(min(white.red, white.green, white.blue) > 0.9, "\(family)'s white dot: \(white)")
            }
            for family in [CareStudioFamily.cleanup, .clutter, .spaceMap] {
                let plain = try colour(rail, try markCentre(family))
                XCTAssertLessThan(min(plain.red, plain.green, plain.blue), 0.8, "\(family) has no mark: \(plain)")
            }
        }

        store.isLoadingStartupItems = true
        try render(window(store: store, rail: true, privacy: privacy) { CareStudioApplicationsStart(store: store) },
                   name: "sidebar-marks-rail-reading-dark", size: Self.windowSize, scheme: .dark, library: library)
        store.isLoadingStartupItems = false

        let marks: [SidebarBadge] = [.progress(0.17), .progress(0.37), .progress(0.65), .progress(0.96),
                                     .progress(nil), .attention, .results]
        for scheme in [ColorScheme.dark, .light] {
            try render(ZStack {
                CareStudioBackdrop(family: .smartCare)
                HStack(spacing: 14) {
                    ForEach(marks.indices, id: \.self) { SidebarBadgeMark(badge: marks[$0]) }
                }
                .scaleEffect(4)
            }, name: "sidebar-marks-each-\(scheme == .dark ? "dark" : "light")",
               size: CGSize(width: 900, height: 160), scheme: scheme, library: library)
        }
    }

    func testRendersTheModuleShellForReview() async throws {
        let library = await preloadedArt()
        let store = try ScanStore.makeForTests(for: self)
        for (language, scheme) in [(AppLanguage.zhHans, ColorScheme.dark), (.zhHans, .light), (.english, .dark)] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            let tag = "\(language == .zhHans ? "zh" : "en")-\(scheme == .dark ? "dark" : "light")"
            store.navigationState.select(.myTools)
            try render(window(store: store) { CareStudioMyToolsPage(store: store) },
                       name: "shell-mytools-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
            // Off-screen renders do not draw scroll views; a tall render shows every card
            // (item 20's cards are taller: 1 320 pt no longer held them).
            try render(window(store: store) { CareStudioMyToolsPage(store: store) },
                       name: "shell-mytools-tall-\(tag)", size: CGSize(width: 1_280, height: 1_600), scheme: scheme, library: library)
            store.navigationState.select(.myActivity)
            try render(window(store: store) { CareStudioMyActivityPage(store: store) },
                       name: "shell-myactivity-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
            store.navigationState.select(.cloudCleanup)
            try render(window(store: store) { CareStudioCloudCleanupPage(store: store) },
                       name: "shell-cloud-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
            store.navigationState.select(.overview)
            try render(window(store: store) { SmartCareLandingView(store: store, latestStatus: nil) },
                       name: "shell-smartscan-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
            store.navigationState.select(.myTools)
            try render(window(store: store, rail: true) { CareStudioMyToolsPage(store: store) },
                       name: "shell-mytools-rail-\(tag)", size: Self.shortWindow, scheme: scheme, library: library)
        }
    }

    /// Report §4 item 20: My Tools as CleanMyMac's (`1比1对照-20261023/cmm/09`)
    /// — three cards a row without their module, "New" on this version's
    /// tools and on My Tools in the sidebar until they are opened, then
    /// Favorites above Other Tools once a tool is saved.
    func testRendersMyToolsLikeCleanMyMacForReview() async throws {
        let library = await preloadedArt()
        let store = try ScanStore.makeForTests(for: self)
        store.navigationState.select(.myTools)
        let fresh = TestPreferenceDomain.make(for: self)
        let used = TestPreferenceDomain.make(for: self)
        used.set(MyToolsCatalog.encode(Set(MyToolsCatalog.tools.filter(\.isNew).map(\.id))),
                 forKey: MyToolsCatalog.triedDefaultsKey)
        used.set(MyToolsCatalog.encode(["benchmark", "memory"]), forKey: MyToolsCatalog.favoritesDefaultsKey)
        for (language, scheme) in [(AppLanguage.zhHans, ColorScheme.dark), (.english, .dark), (.zhHans, .light)] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            let tag = "\(language == .zhHans ? "zh" : "en")-\(scheme == .dark ? "dark" : "light")"
            // Tall enough for every card: off-screen renders do not draw scroll views.
            for (state, defaults) in [("new", fresh), ("saved", used)] {
                try render(window(store: store) { CareStudioMyToolsPage(store: store) }.defaultAppStorage(defaults),
                           name: "mytools-\(state)-\(tag)", size: CGSize(width: 1_280, height: 1_800),
                           scheme: scheme, library: library)
            }
        }
        do {
            let scope = CalibrationLanguageScope(.zhHans)
            defer { scope.restore() }
            try render(window(store: store, rail: true) { CareStudioMyToolsPage(store: store) }.defaultAppStorage(fresh),
                       name: "mytools-new-rail-zh-dark", size: Self.shortWindow, scheme: .dark, library: library)
        }

        // A card in a known place: its corner at (20, 20).
        let tool = try XCTUnwrap(MyToolsCatalog.tools.first(where: \.isNew))
        func card(isNew: Bool) -> some View {
            ZStack {
                CareStudioBackdrop(family: .myTools)
                CareStudioToolCard(tool: tool, isFavorite: false, isNew: isNew, onToggleFavorite: {}, onOpen: {})
                    .frame(width: 300, height: 240)
            }
        }
        let size = CGSize(width: 340, height: 280)
        let tagged = try render(card(isNew: true), name: "mytools-card-new-dark", size: size, scheme: .dark, library: library)
        let plain = try render(card(isNew: false), name: "mytools-card-dark", size: size, scheme: .dark, library: library)
        /// 4 pt into the tag from its left end, half way down its 16 pt; the
        /// tag stands 7 pt out of the corner.
        func isMagenta(_ bitmap: NSBitmapImageRep) throws -> Bool {
            let colour = try XCTUnwrap(bitmap.colorAt(x: (20 - 7 + 4) * 2, y: (20 - 7 + 8) * 2)?.usingColorSpace(.sRGB))
            return colour.redComponent > 0.55 && colour.blueComponent > 0.5 && colour.greenComponent < 0.42
        }
        XCTAssertTrue(try isMagenta(tagged), "New on the corner of a new tool's card")
        XCTAssertFalse(try isMagenta(plain), "no tag on an older tool's")
    }

    func testRendersTheApplicationsModuleForReview() async throws {
        let library = await preloadedArt()
        let store = try ScanStore.makeForTests(for: self)
        let model = ApplicationsManagerModel.of(store)
        for (language, scheme) in [(AppLanguage.zhHans, ColorScheme.dark), (.zhHans, .light), (.english, .dark)] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            let tag = "\(language == .zhHans ? "zh" : "en")-\(scheme == .dark ? "dark" : "light")"
            store.installedApps = []
            store.navigationState.select(.uninstall)
            try render(window(store: store) { CareStudioApplicationsStart(store: store) },
                       name: "apps-landing-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
            store.installedApps = FeatureLightfieldApplicationsFixture.uninstallApps
            model.load(inventory: store.installedApps, readsDisk: false)
            try render(window(store: store) {
                // The fixture flag keeps the extensions listing unread (D154 batch 2).
                CareStudioApplicationsOverview(model: model, store: store, showHistory: {})
                    .environment(\.featurePresentationIsFixture, true)
            }, name: "apps-overview-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
            model.showsOverview = false
            try render(window(store: store) {
                ApplicationsManagerView(store: store).environment(\.featurePresentationIsFixture, true)
            }, name: "apps-manager-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
            try render(window(store: store) {
                CareStudioApplicationsRemoving(current: "Google Chrome", index: 1, total: 3, leftovers: false)
            }, name: "apps-removing-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
        }
    }

    /// The D67 landing and running pages of every module, as the template
    /// draws them on the module gradient (production options, demo data).
    func testRendersEveryModuleLandingAndRunningPageForReview() async throws {
        let library = await preloadedArt()
        let store = try ScanStore.makeForTests(for: self)
        let health = ComputerHealthStore(probe: ShellInertProbe(),
            batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController())
        let network = NetworkSpeedTestStore(), browser = BrowserPrivacyStore()
        let routes: [ReviewFilter] = [.privacy, .duplicates, .largeFiles, .migration, .updater,
                                      .healthHub, .energy, .performance]
        for (language, scheme) in [(AppLanguage.zhHans, ColorScheme.dark), (.english, .light)] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            let tag = "\(language == .zhHans ? "zh" : "en")-\(scheme == .dark ? "dark" : "light")"
            for route in routes {
                store.navigationState.select(route)
                for phase in [FeaturePresentationDemo.Phase.landing, .running] {
                    let session = FeaturePresentationDemo()
                    session.phase = phase
                    try render(window(store: store) {
                        FeaturePresentationDemoView(session: session, store: store, module: route,
                            healthStore: health, networkStore: network, browserStore: browser,
                            isSimilarPhotosOverride: false)
                            .environment(\.careStudioSurface, true)
                    }, name: "module-\(route.rawValue)-\(phase)-\(tag)", size: Self.windowSize,
                       scheme: scheme, library: library)
                }
            }
        }
    }

    /// D154 batch 2: the My Clutter and Protection results tiles.
    func testRendersTheClutterAndProtectionResultsForReview() async throws {
        let library = await preloadedArt()
        let store = try ScanStore.makeForTests(for: self)
        let privacy = BrowserPrivacyPreviewFixture.makeStore()
        privacy.startScan()
        await privacy.waitUntilIdle()
        for (language, scheme) in [(AppLanguage.zhHans, ColorScheme.dark), (.english, .light)] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            let tag = "\(language == .zhHans ? "zh" : "en")-\(scheme == .dark ? "dark" : "light")"
            store.navigationState.select(.duplicates)
            try render(window(store: store) {
                CareStudioClutterResults(store: store, confirmedGroups: 12, confirmedFiles: 31,
                                         logicalBytes: 4_820_000_000, physicalBytes: 3_100_000_000, candidateGroups: 5,
                                         onReview: { _ in }, onStartOver: {})
            }, name: "clutter-results-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
            store.navigationState.select(.privacy)
            try render(window(store: store) {
                CareStudioProtectionResults(privacy: privacy, onReview: {}, onShowDataTypes: {})
            }, name: "protection-results-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
        }
    }

    /// D166 batch 3D: the memory result's measure cards, and the state
    /// pictures on pages without a scroll view (an image renderer leaves
    /// scroll views blank; the window review captures the managers' empty
    /// categories and the short memory result).
    func testRendersTheMemoryResultAndStatePicturesForReview() async throws {
        let library = await preloadedArt()
        let store = try ScanStore.makeForTests(for: self)
        for (language, scheme) in [(AppLanguage.zhHans, ColorScheme.dark), (.english, .light)] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            let tag = "\(language == .zhHans ? "zh" : "en")-\(scheme == .dark ? "dark" : "light")"
            let (result, pushed) = CareStudioRenderReviewTests.memoryResultFixture()
            let nothing = MemoryReclaimer.Outcome(before: pushed.before, after: nil, budgetBytes: 0, pushedBytes: 0,
                                                  stopReason: .nothingToReclaim, duration: 0.2)
            store.navigationState.select(.memory)
            try render(window(store: store, rail: true) {
                CareStudioMemoryResultPage(result: result, reclaim: pushed, onDone: {}, onShowApps: {})
            }, name: "memory-result-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
            try render(window(store: store, rail: true) {
                CareStudioMemoryResultPage(result: result, reclaim: nothing, onDone: {}, onShowApps: {})
            }, name: "memory-result-nothing-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
            store.navigationState.select(.duplicates)
            try render(window(store: store) {
                CareStudioClutterResults(store: store, confirmedGroups: 0, confirmedFiles: 0, logicalBytes: 0,
                                         physicalBytes: nil, candidateGroups: 0, onReview: { _ in }, onStartOver: {})
            }, name: "clutter-results-empty-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
            store.navigationState.select(.chatFiles)
            try render(window(store: store) {
                CareStudioLandingPage(module: .clutter, art: .statePermission, title: ReviewFilter.chatFiles.title,
                                      subtitle: L10n.text("给本应用“完全磁盘访问权限”后才能统计。",
                                                          "Give this app Full Disk Access to count them."),
                                      actionTitle: L10n.text("打开设置", "Open Settings"), action: {})
            }, name: "chatfiles-access-\(tag)", size: Self.windowSize, scheme: scheme, library: library)
        }
    }

    /// D166: the state pictures say what happened by their colour, so they
    /// are never turned to a module's colour; every other picture is.
    func testOnlyTheStatePicturesKeepTheirOwnColours() {
        let states: Set<GeneratedArt> = [.stateEmpty, .stateAllClear, .statePermission, .stateError]
        XCTAssertEqual(Set(GeneratedArt.allCases.filter(\.keepsOwnColour)), states)
    }

    func testClutterAndProtectionTilesFollowWhatTheScanFound() async throws {
        let store = try ScanStore.makeForTests(for: self)
        let found = CareStudioClutterResults(store: store, confirmedGroups: 2, confirmedFiles: 5, logicalBytes: 9_000,
                                             physicalBytes: nil, candidateGroups: 1, onReview: { _ in }, onStartOver: {})
        // D221＋旧值：was ["duplicates", "candidates", "similarPhotos", "chatFiles"]; D221 补 gives
        // Large & Old Files its tile after Similar Photos, as CleanMyMac orders its clutter tiles.
        // D226＋旧值：was ["duplicates", "candidates", "similarPhotos", "largeOld", "chatFiles"];
        // Downloads follows Large & Old Files, before Chat Files.
        XCTAssertEqual(found.tiles.map(\.id), ["duplicates", "candidates", "similarPhotos", "largeOld", "downloads", "chatFiles"])
        // No tile removes anything: each only opens a review.
        XCTAssertTrue(found.tiles.allSatisfy { $0.onClean == nil && $0.cleanTitle == nil })
        let nothing = CareStudioClutterResults(store: store, confirmedGroups: 0, confirmedFiles: 0, logicalBytes: 0,
                                               physicalBytes: nil, candidateGroups: 0, onReview: { _ in }, onStartOver: {})
        // D221＋旧值：was ["similarPhotos", "chatFiles"]; the Large & Old Files tile shows with or without duplicates.
        // D226＋旧值：was ["similarPhotos", "largeOld", "chatFiles"]; so does the Downloads tile.
        XCTAssertEqual(nothing.tiles.map(\.id), ["similarPhotos", "largeOld", "downloads", "chatFiles"])

        let privacy = BrowserPrivacyPreviewFixture.makeStore()
        privacy.startScan()
        await privacy.waitUntilIdle()
        let protection = CareStudioProtectionResults(privacy: privacy, onReview: {}, onShowDataTypes: {})
        let ids = protection.tiles.map(\.id)
        XCTAssertEqual(ids.first, privacy.records.isEmpty ? "dataTypes" : "history")
        XCTAssertTrue(ids.contains("dataTypes"))
        // The sensitive tile counts what the list folds and masks (adult and finance).
        XCTAssertEqual(ids.contains("sensitive"),
                       privacy.records.contains { BrowserPrivacyLightfieldPresentation.isSensitive($0.category) })
        XCTAssertTrue(protection.tiles.allSatisfy { $0.onClean == nil })
    }

    func testSidebarRowsKeepAllTenModulesInTheShortestWindow() {
        // 520 pt window content less the 52 pt title band.
        let metrics = SidebarRowMetrics(height: 468, isRail: false)
        XCTAssertGreaterThanOrEqual(metrics.rowHeight + metrics.spacing, SidebarRowMetrics.minimumPitch)
        XCTAssertLessThanOrEqual(CGFloat(CareStudioFamily.allCases.count) * (metrics.rowHeight + metrics.spacing) + 52, 468 + 0.5)
        let tall = SidebarRowMetrics(height: 900, isRail: false)
        XCTAssertEqual(tall.rowHeight + tall.spacing, SidebarRowMetrics.pitch)
    }

    func testEveryRouteBelongsToTheModuleCleanMyMacPutsItIn() {
        XCTAssertEqual(CareStudioFamily.allCases.map(\.primaryRoute),
                       [.overview, .green, .privacy, .startup, .uninstall, .duplicates, .largeFiles, .cloudCleanup, .myTools, .myActivity])
        XCTAssertEqual(CareStudioFamily.allCases.filter(\.isFooter), [.myTools, .myActivity])
        for family in CareStudioFamily.allCases {
            XCTAssertEqual(CareStudioFamily(route: family.primaryRoute), family, family.rawValue)
        }
        XCTAssertEqual(CareStudioFamily(route: .devCaches), .cleanup)
        XCTAssertEqual(CareStudioFamily(route: .memory), .performance)
        XCTAssertEqual(CareStudioFamily(route: .updater), .applications)
        XCTAssertEqual(CareStudioFamily(route: .utilityHub, utility: .energy), .myTools)
        for route in [ReviewFilter.healthHub, .performance, .energy, .migration] {
            XCTAssertEqual(CareStudioFamily(route: route), .myTools, route.rawValue)
        }
        // Every page that is not a module's first page is one card on My Tools.
        let firstPages = Set(CareStudioFamily.allCases.map(\.primaryRoute))
        let toolRoutes = Set(MyToolsCatalog.tools.compactMap { tool -> ReviewFilter? in
            if case .route(let route) = tool.destination { return route }
            return nil
        })
        for route in ReviewFilter.allCases where route != .utilityHub && !firstPages.contains(route) {
            XCTAssertTrue(toolRoutes.contains(route), "\(route.rawValue) has no way in from the sidebar or My Tools")
        }
    }
}

private struct ShellInertProbe: ComputerHealthProbing {
    func probe() async throws -> ComputerHealthSnapshot {
        XCTFail("No hardware reads in the D154 render")
        throw CancellationError()
    }
}

/// Item 14: every module's scan finishes at once; the cards read the store.
private final class InstantSmartCareScanner: SmartCareScanning {
    func scan(_ module: SmartCareModule) async -> SmartCareCardState { .done }
    func stop(_ module: SmartCareModule) {}
}
#endif
