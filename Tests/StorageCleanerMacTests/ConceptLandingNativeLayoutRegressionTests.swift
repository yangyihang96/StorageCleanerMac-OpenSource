#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Native production-component fixtures only. These do not certify an
/// installed App, a real energy sample, an update provider, or a golden image.
@MainActor
final class ConceptLandingNativeLayoutRegressionTests: XCTestCase {
    func testSixEnergyStagesKeepCompleteBilingualTextAndSeparateRowsAcrossResizes() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = CalibrationLanguageScope(language)
            defer { languageScope.restore() }
            for dark in [false, true] {
                let model = CalibrationEnergyFixture()
                let root = CalibrationEnergyContent(model: model)
                let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 500, height: 734), dark: dark)
                defer { host.close() }
                let required = Set(EnergyImpactScanPhase.allCases.map { "energy.stage.\($0.rawValue)" }
                    + ["fixture.energy.pipeline", "fixture.viewport"])
                let stageLabels = EnergyImpactScanPhase.allCases.flatMap { step in
                    let strings = energyStrings(step, language: language)
                    return [strings.title]
                }
                for phase: EnergyImpactScanPhase? in [nil, .capturingBaseline, .calculatingResults, nil] {
                    model.phase = phase
                    // The previous cycle ends at 500 × 734. Prove a state
                    // transition at the unchanged size before asking for any
                    // resize; GeometryReader invalidation cannot substitute.
                    try await host.waitForEnergyState(phase)
                    let unchanged = try await host.frames(required: required, size: .init(width: 500, height: 734))
                    try await host.waitForAccessibility(labels: stageLabels)
                    if let phase {
                        let current = try host.accessibilityFrame(label: L10n.text("当前步骤", "Current step"))
                        let row = try XCTUnwrap(unchanged["energy.stage.\(phase.rawValue)"])
                        XCTAssertTrue(row.insetBy(dx: -1, dy: -1).contains(current))
                        XCTAssertEqual(try host.accessibilityValue(label: L10n.text("能耗扫描进度", "Energy scan progress")),
                            "\(Int(phase.fractionCompleted * 100))%")
                    } else {
                        XCTAssertNil(host.element(label: L10n.text("当前步骤", "Current step")))
                        XCTAssertNil(host.element(label: L10n.text("能耗扫描进度", "Energy scan progress")))
                    }
                    for size in [CGSize(width: 500, height: 734), CGSize(width: 340, height: 490),
                                 CGSize(width: 280, height: 734), CGSize(width: 500, height: 734)] {
                        host.resize(to: size)
                        let frames = try await host.frames(required: required, size: size)
                        try await host.waitForAccessibility(labels: stageLabels)
                        let pipeline = try XCTUnwrap(frames["fixture.energy.pipeline"])
                        var previous: CGRect?
                        for step in EnergyImpactScanPhase.allCases {
                            let row = try XCTUnwrap(frames["energy.stage.\(step.rawValue)"])
                            XCTAssertTrue(pipeline.insetBy(dx: -1, dy: -1).contains(row))
                            XCTAssertLessThanOrEqual(row.maxX, size.width + 1)
                            if let previous { XCTAssertGreaterThanOrEqual(row.minY - previous.maxY, 6) }
                            previous = row
                            let strings = energyStrings(step, language: language)
                            let title = try host.accessibilityFrame(label: strings.title)
                            XCTAssertTrue(row.insetBy(dx: -1, dy: -1).contains(title))
                            XCTAssertNil(host.element(label: strings.description),
                                "D64 removes option prose while retaining every real phase title")
                            // Full AX text alone cannot pass: the actual text
                            // boxes must also fit their native font's complete
                            // word and naturally wrapped paragraph dimensions.
                            let titleSize = (strings.title as NSString).size(withAttributes: [
                                .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
                            ])
                            XCTAssertGreaterThanOrEqual(title.width + 1, titleSize.width)
                            XCTAssertGreaterThanOrEqual(title.height + 2,
                                NSFont.systemFont(ofSize: 13, weight: .semibold).ascender
                                    - NSFont.systemFont(ofSize: 13, weight: .semibold).descender)
                        }
                        XCTAssertEqual(EnergyImpactScanPhase.allCases.count, 6)
                    }
                }
            }
        }
    }

    func testPublicUpdateLandingKeepsFourRealSourcesAndReachableActionsWhenReflowing() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = CalibrationLanguageScope(language)
            defer { languageScope.restore() }
            let callbacks = CalibrationCallbackRecorder()
            let root = GeometryReader { proxy in
                AppUpdateIdlePage(lastSummary: nil, canScan: true,
                    onScan: { callbacks.record(.updater) }, onManage: {})
                .environment(\.windowLayoutMetrics, WindowLayoutMetrics(contentSize: proxy.size))
                .environment(\.moduleTheme, ReviewFilter.updater.moduleTheme)
                .environment(\.featureDisablesLayoutAnimations, true)
            }
            let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 1024, height: 734), dark: true)
            defer { host.close() }
            let sources = [("packages", L10n.text("软件包线索", "Package Sources")), ("store", "App Store"),
                ("feed", L10n.text("应用内更新源", "In-App Update Feeds")),
                ("website", L10n.text("开发者官网", "Developer Websites"))]
            let prefix = "lightfield.updater.option."
            let required = lightfieldLandingRequired.union(sources.map { prefix + $0.0 })
            let cases: [CGSize] = [.init(width: 1024, height: 734),
                .init(width: 1024, height: 490), .init(width: 400, height: 640),
                .init(width: 390, height: 490), .init(width: 360, height: 490),
                .init(width: 1024, height: 734)]
            for size in cases {
                host.resize(to: size)
                let frames = try await host.frames(required: required, size: size)
                let actionTitle = L10n.text("检查更新", "Check for Updates")
                let cards = try sources.map { try XCTUnwrap(frames[prefix + $0.0]) }
                let optionsViewport = try XCTUnwrap(frames["lightfield.options.scrollViewport"])
                let geometry = try await host.scrollContent(prefix: "lightfield.options")
                let content = try host.optionsDocumentFrame(matching: optionsViewport)
                // D67 replaces the compact grid with four 56 pt rows and
                // allows scrolling when the natural document is too tall.
                XCTAssertEqual(geometry.overflowing,
                    FeatureScrollGeometry.overflows(contentHeight: content.height, availableHeight: geometry.availableHeight))
                if !geometry.overflowing { XCTAssertFalse(geometry.showsHint) }
                try assertLightfieldLandingReachability(frames, size: size)
                for index in cards.indices {
                    XCTAssertTrue(content.insetBy(dx: -1, dy: -1).contains(cards[index]))
                    XCTAssertEqual(cards[index].height, 56, accuracy: 0.5)
                    if index > 0 {
                        XCTAssertEqual(cards[index].minX, cards[index - 1].minX, accuracy: 1)
                        XCTAssertEqual(cards[index].minY, cards[index - 1].maxY, accuracy: 0.5)
                    }
                }
                for (id, title) in sources {
                    let current = try await host.frames(required: required, size: size)
                    try host.scrollOptionsToReveal(try XCTUnwrap(current[prefix + id]), matching: optionsViewport)
                    let visible = try await host.frames(required: required, size: size)
                    XCTAssertTrue(optionsViewport.insetBy(dx: -0.5, dy: -0.5).contains(try XCTUnwrap(visible[prefix + id])),
                        "Every source is visible before reading native AX: \(size)/\(language)")
                    try await host.waitForAccessibility(labels: [title], hitTestViewport: optionsViewport)
                    XCTAssertNotNil(host.element(label: title), "All four production sources must remain present")
                }
                try host.scrollOptionsToBottom(matching: optionsViewport)
                let atBottom = try await host.scrollContent(prefix: "lightfield.options")
                XCTAssertFalse(atBottom.showsHint, "No more-content hint may remain after reaching the real document bottom")
                try await host.waitForAccessibility(labels: [actionTitle], pressLabels: [actionTitle])
                XCTAssertTrue(try host.press(label: L10n.text("检查更新", "Check for Updates")))
                await Task.yield()
            }
            XCTAssertEqual(callbacks.count[.updater], cases.count)
        }
    }

    func testActualInertUpdaterLastCheckKeepsFiveStatisticsAndManageButtonAtNarrowWidths() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = CalibrationLanguageScope(language)
            defer { languageScope.restore() }
            let suite = TestPreferenceDomain.makeSuite()
            let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
            defer { TestPreferenceDomain.cleanup(suiteName: suite) }
            let fixtureHome = try TestFileSystem.makeHome(for: self)
            let historyURL = fixtureHome.appendingPathComponent("layout-history.json")
            let store = try ScanStore.makeForTests(for: self, restoreSavedAccessOperation: {},
                loadScanReadinessSummary: { ScanReadinessSummary(items: []) },
                historyLoader: CalibrationEmptyHistoryLoader(),
                metricHistoryStore: MetricHistoryStore(url: historyURL),
                cleanupScanOperation: { _, _ in
                    XCTFail("An inert update layout fixture must never launch cleanup")
                    throw CancellationError()
                },
                cleanupRuleSetLoader: { CleanupRuleSet(schemaVersion: 2, rulesVersion: "native-ui-fixture", rules: []) },
                cleanupPreferences: defaults, cleanReportLoader: { [] })
            store.installDebugAppUpdatePresentationFixture(.summary)
            store.resetAppUpdatePresentation()
            guard case let .idle(saved) = store.appUpdatePresentationState,
                  let summary = saved else {
                XCTFail("Existing summary → idle API must supply the real last-check accessory")
                continue
            }
            XCTAssertTrue(store.isDebugAppUpdatePresentationFixtureActive)
            XCTAssertFalse(store.canRefreshAppUpdates)
            XCTAssertFalse(store.canRequestOneClickAppUpdates)
            let root = GeometryReader { proxy in
                AppUpdaterView(store: store)
                    .environment(\.windowLayoutMetrics, WindowLayoutMetrics(contentSize: proxy.size))
                    .environment(\.moduleTheme, ReviewFilter.updater.moduleTheme)
                    // Geometry/AX assertions describe a settled page, not
                    // D67's 560 ms content-width transition after a resize.
                    .environment(\.featureDisablesLayoutAnimations, true)
            }
            let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 1024, height: 734), dark: false)
            defer { host.close() }
            let labels = [
                ("automatic", L10n.text("可直接更新", "Automatic"), summary.automaticCount),
                ("quit", L10n.text("退出后更新", "Quit First"), summary.requiresQuitCount),
                ("authorization", L10n.text("需授权", "Authorization"), summary.requiresAuthorizationCount),
                ("manual", L10n.text("需手动", "Manual"), summary.manualCount),
                ("current", L10n.text("已是最新", "Current"), summary.currentCount),
                ("unknown", L10n.text("状态未知", "Unknown"), summary.unknownCount)
            ]
            let metricPrefix = "lightfield.updater.previousMetrics"
            let required = lightfieldLandingRequired.union([metricPrefix]).union(labels.flatMap { id, _, _ in
                ["column", "value", "label"].map { metricPrefix + "." + $0 + "." + id }
            })
            let accessibilityLabels = labels.map { _, label, count in label + " · " + String(count) + " " }
            for size in [CGSize(width: 1024, height: 734), CGSize(width: 900, height: 734),
                         CGSize(width: 899, height: 734), CGSize(width: 1024, height: 560),
                         CGSize(width: 1024, height: 559), CGSize(width: 604, height: 490),
                         CGSize(width: 400, height: 640), CGSize(width: 1024, height: 734)] {
                host.resize(to: size)
                let initialFrames = try await host.frames(required: required, size: size)
                try assertLightfieldLandingReachability(initialFrames, size: size)
                // D67/D69: the production metric group is inside the
                // lightfield options scroll, with full label/count AX text.
                // Realize the actual document before querying native frames.
                try host.scrollOptionsToBottom(matching: try XCTUnwrap(initialFrames["lightfield.options.scrollViewport"]))
                let accessibilityFrames = try await host.frames(required: required, size: size)
                let manageTitle = L10n.text("管理更新", "Manage Updates")
                try await host.waitForAccessibility(labels: accessibilityLabels + [manageTitle],
                    pressLabels: [manageTitle],
                    hitTestViewport: try XCTUnwrap(accessibilityFrames["lightfield.options.scrollViewport"]))
                // AX realization pumps native layout; use the subsequently
                // published probes for the native document and AX rectangles.
                let frames = try await host.frames(required: required, size: size)
                try assertLightfieldLandingReachability(frames, size: size)
                let options = try XCTUnwrap(frames["lightfield.options.scrollViewport"])
                let content = try host.optionsDocumentFrame(matching: options)
                // B4 P2: compact statistics add rows at readable font sizes.
                // Complete label/value glyphs are asserted in ApplicationP2Tests.
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(frames[metricPrefix]).height, 48)
                var statisticFrames = [CGRect]()
                for (id, label, expected) in labels {
                    let fullLabel = label + " · " + String(expected) + " "
                    XCTAssertEqual(try host.accessibilityLabel(label: fullLabel), fullLabel)
                    let rect = try host.accessibilityFrame(label: fullLabel)
                    XCTAssertTrue(content.insetBy(dx: -1, dy: -1).contains(rect), label)
                    let column = try XCTUnwrap(frames[metricPrefix + ".column." + id])
                    for part in ["value", "label"] {
                        let partFrame = try XCTUnwrap(frames[metricPrefix + "." + part + "." + id])
                        XCTAssertTrue(column.insetBy(dx: -0.5, dy: -0.5).contains(partFrame),
                            "\(id) \(part) must stay within its real metric column at \(size)")
                    }
                    statisticFrames.append(rect)
                }
                for index in statisticFrames.indices {
                    for other in statisticFrames.indices where other > index {
                        XCTAssertTrue(statisticFrames[index].intersection(statisticFrames[other]).isNull,
                            "The five original statistics and the unknown count must not overlap")
                    }
                }
                let manage = try host.accessibilityFrame(label: L10n.text("管理更新", "Manage Updates"))
                XCTAssertTrue(content.insetBy(dx: -1, dy: -1).contains(manage))
                XCTAssertGreaterThan(manage.width, 70)
                XCTAssertGreaterThan(manage.height, 20)
                let visibleManage = try host.accessibilityFrame(label: L10n.text("管理更新", "Manage Updates"))
                XCTAssertTrue(options.insetBy(dx: -1, dy: -1).contains(visibleManage),
                    "Manage remains reachable through the independent options scroll view")
                for statistic in statisticFrames {
                    XCTAssertTrue(manage.intersection(statistic).isNull, "Manage must not overlap a summary cell")
                }
                XCTAssertFalse(store.canRefreshAppUpdates)
                XCTAssertFalse(store.canRequestOneClickAppUpdates)
            }
        }
    }

    /// Value-only production page: exercise the same 28 pt demo inset and
    /// native AX/layout pumping without the Store's operation-home fixture.
    func testUpdaterLastCheckViewportMatchesNativeDocumentAfterAXAcrossResizes() async throws {
        let summary = LastAppScanSummary(summary: FeatureLightfieldApplicationsFixture.updateSummary())
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = CalibrationLanguageScope(language)
            defer { languageScope.restore() }
            let root = GeometryReader { proxy in
                VStack(spacing: 0) {
                    Color.clear.frame(height: 28)
                    AppUpdateIdlePage(lastSummary: summary, canScan: false,
                        onScan: { XCTFail("No scan in the native document fixture") },
                        onManage: { XCTFail("Only observe the manage action") })
                }
                .environment(\.windowLayoutMetrics, WindowLayoutMetrics(contentSize: proxy.size))
                .environment(\.moduleTheme, ReviewFilter.updater.moduleTheme)
                .environment(\.featureDisablesLayoutAnimations, true)
            }
            let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 1024, height: 734), dark: false)
            defer { host.close() }
            for size in [CGSize(width: 1024, height: 734), CGSize(width: 900, height: 734),
                         CGSize(width: 899, height: 734), CGSize(width: 1024, height: 560),
                         CGSize(width: 1024, height: 559), CGSize(width: 604, height: 490),
                         CGSize(width: 400, height: 640), CGSize(width: 1024, height: 734)] {
                host.resize(to: size)
                let initial = try await host.frames(required: lightfieldLandingRequired, size: size)
                try host.scrollOptionsToBottom(matching: try XCTUnwrap(initial["lightfield.options.scrollViewport"]))
                let accessibilityFrames = try await host.frames(required: lightfieldLandingRequired, size: size)
                let manageTitle = L10n.text("管理更新", "Manage Updates")
                try await host.waitForAccessibility(labels: [manageTitle], pressLabels: [manageTitle],
                    hitTestViewport: try XCTUnwrap(accessibilityFrames["lightfield.options.scrollViewport"]))
                let frames = try await host.frames(required: lightfieldLandingRequired, size: size)
                let viewport = try XCTUnwrap(frames["lightfield.options.scrollViewport"])
                let document = try host.optionsDocumentFrame(matching: viewport)
                XCTAssertTrue(document.insetBy(dx: -1, dy: -1).contains(try host.accessibilityFrame(label: manageTitle)))
            }
        }
    }

    func testV1CompatibilitySafetyAndDeveloperColumnsKeepTheirReferenceHierarchyWithoutOverlaps() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = CalibrationLanguageScope(language)
            defer { languageScope.restore() }
            for route in [ReviewFilter.green, .devCaches] {
                let callbacks = CalibrationCallbackRecorder()
                let root = GeometryReader { proxy in
                    HeroScanPage(
                        title: route.sidebarTitle, subtitle: "",
                        headerSystemImage: route.systemImage,
                        configurationTitle: L10n.text("扫描范围", "Scan Scope"),
                        actionTitle: L10n.text("开始扫描", "Start Scan"), actionDetail: "",
                        actionSystemImage: "play.fill", status: .neverScanned,
                        trustText: L10n.text("只显示可审阅项目，不会自动删除", "Only reviewable items are shown; nothing is deleted automatically"),
                        action: { callbacks.record(route) }
                    ) {
                        if route == .green {
                            SafeCleanupScopeCards(selectedScopes: Set(SafeCleanupScanScope.allCases), onToggle: { _ in })
                        } else { EmptyView() }
                    }
                    .environment(\.windowLayoutMetrics, WindowLayoutMetrics(contentSize: proxy.size))
                    .environment(\.moduleTheme, route.moduleTheme)
                }
                let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 1280, height: 900), dark: true)
                defer { host.close() }
                for size in [CGSize(width: 1280, height: 900), CGSize(width: 900, height: 734),
                             CGSize(width: 660, height: 640), CGSize(width: 604, height: 490),
                             CGSize(width: 400, height: 640), CGSize(width: 1280, height: 900)] {
                    host.resize(to: size)
                    let frames = try await host.frames(required: landingRequired, size: size)
                    try assertLandingReachability(frames, size: size)
                    let header = try XCTUnwrap(frames[LayoutProbeID.landingHeader])
                    let panel = try XCTUnwrap(frames[LayoutProbeID.landingActionPanel])
                    let footer = try XCTUnwrap(frames[LayoutProbeID.landingFooter])
                    XCTAssertEqual(header.minX, panel.minX, accuracy: 1)
                    XCTAssertLessThanOrEqual(header.maxY, panel.minY + 1)
                    XCTAssertLessThanOrEqual(panel.maxY, footer.minY + 1)
                    if let artwork = frames[LayoutProbeID.landingArtwork] {
                        XCTAssertGreaterThanOrEqual(artwork.minX - panel.maxX, 19)
                        XCTAssertLessThanOrEqual(artwork.maxY, footer.minY + 1)
                        XCTAssertTrue(header.intersection(artwork).isNull)
                        XCTAssertTrue(panel.intersection(artwork).isNull)
                        if size.width == 1280 {
                            // D62①: feature-specific V0 widths become one viewport-derived width.
                            let metrics = LandingMetrics(page: .resolve(size: size), size: size, systemImage: route.systemImage)
                            XCTAssertEqual(panel.width, metrics.actionWidth, accuracy: 0.5)
                        }
                    }
                    let actionTitle = L10n.text("开始扫描", "Start Scan")
                    try await host.waitForAccessibility(labels: [actionTitle], pressLabels: [actionTitle])
                    XCTAssertTrue(try host.press(label: actionTitle))
                    await Task.yield()
                }
                XCTAssertEqual(callbacks.count[route], 6)
            }
        }
    }

    /// Size sweep for the clipped last scope row (BOARD 3b, N2): the options
    /// list must show every row at ordinary window sizes instead of hiding the
    /// last one inside an unmarked inner scroll area.
    func testLandingScopeListsShowEveryRowAcrossTheCommonSizeSweep() async throws {
        let store = try ScanStore.makeForTests(for: self, cleanReportLoader: { [] })
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = CalibrationLanguageScope(language)
            defer { languageScope.restore() }
            let pages: [(String, AnyView)] = [
                ("smartScan", AnyView(SmartCareLandingView(store: store, latestStatus: nil)
                    .environment(\.moduleTheme, ReviewFilter.overview.moduleTheme))),
                ("green", AnyView(HeroScanPage(
                    title: ReviewFilter.green.sidebarTitle, subtitle: "",
                    headerSystemImage: ReviewFilter.green.systemImage,
                    configurationTitle: L10n.text("扫描范围", "Scan Scope"),
                    actionTitle: L10n.text("开始扫描", "Start Scan"), actionDetail: "",
                    actionSystemImage: "play.fill", status: .neverScanned,
                    trustText: L10n.text("只显示可审阅项目，不会自动删除", "Only reviewable items are shown; nothing is deleted automatically"),
                    action: {}
                ) {
                    SafeCleanupScopeCards(selectedScopes: Set(SafeCleanupScanScope.allCases), onToggle: { _ in })
                }.environment(\.moduleTheme, ReviewFilter.green.moduleTheme)))
            ]
            for (name, page) in pages {
                let root = GeometryReader { proxy in
                    page.environment(\.windowLayoutMetrics, WindowLayoutMetrics(contentSize: proxy.size))
                }
                let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 1080, height: 760), dark: true)
                defer { host.close() }
                var clipped: [String] = []
                for width in [700, 820, 1000, 1080] {
                    for height in [520, 560, 600, 640, 700] {
                        let size = CGSize(width: width, height: height)
                        host.resize(to: size)
                        let frames = try await host.frames(required: landingRequired, size: size)
                        try assertLandingReachability(frames, size: size)
                        let viewport = try XCTUnwrap(frames["landing.optionsViewport"])
                        let content = try XCTUnwrap(frames["landing.optionsContent"])
                        if content.height > viewport.height + 1 {
                            try host.scrollOptionsToBottom(matching: viewport)
                            let scrolled = try await host.frames(required: landingRequired.union(["landing.optionsEnd"]), size: size)
                            let end = try XCTUnwrap(scrolled["landing.optionsEnd"])
                            if !viewport.insetBy(dx: -0.5, dy: -0.5).contains(end) {
                                clipped.append("\(name) \(language) \(width)x\(height): final option is not reachable by scrolling")
                            }
                        }
                    }
                }
                XCTAssertTrue(clipped.isEmpty, "Scope rows are cut off:\n" + clipped.joined(separator: "\n"))
            }
        }
    }

    /// Every landing page inside the real page container. `AdaptivePageViewport`
    /// measures the detail column (density and the compact-landing threshold
    /// come from it); file workspaces get exactly its height, other pages a
    /// 520 pt minimum page in an outer scroll view. Across the size sweep the
    /// header reserves no action row it does not show, stays inside the page,
    /// keeps a header action beside the title at ordinary widths, and the
    /// options list is never cut off by its inner scroll area (BOARD 3b, N2).
    func testEveryLandingPageFitsInTheRealPageContainerAcrossTheSizeSweep() async throws {
        let store = try ScanStore.makeForTests(for: self, cleanReportLoader: { [] })
        // Detail columns of windows about 820 to 1280 wide.
        let widths: [CGFloat] = [655, 703, 760, 803, 903, 1000, 1083]
        // Detail columns of windows about 520 to 812 tall.
        let heights: [CGFloat] = [468, 520, 560, 600, 640, 660, 680, 712, 760]
        var problems: [String] = []
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = CalibrationLanguageScope(language)
            defer { languageScope.restore() }
            for page in realLandingPages(store: store) {
                let root = AdaptivePageViewport(resetID: page.route) {
                    page.view.environment(\.moduleTheme, page.route.moduleTheme)
                        .environment(\.featureDisablesLayoutAnimations, true)
                }
                let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 1083, height: 712), dark: true)
                defer { host.close() }
                for width in widths {
                    for height in heights {
                        let size = CGSize(width: width, height: height)
                        host.resize(to: size)
                        if FeatureLightfield.owns(page.route) {
                            let ids: Set<String> = ["lightfield.title", "lightfield.content", "lightfield.primary", "lightfield.status", "lightfield.options.scrollViewport", "lightfield.optionsEnd", "fixture.viewport"]
                            let frames = try await host.frames(required: ids, size: size)
                            let bounds = try XCTUnwrap(frames["fixture.viewport"])
                            let action = try XCTUnwrap(frames["lightfield.primary"])
                            XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(action))
                            XCTAssertEqual(action.height, 52, accuracy: 0.5)
                            let viewport = try XCTUnwrap(frames["lightfield.options.scrollViewport"])
                            let end = try XCTUnwrap(frames["lightfield.optionsEnd"])
                            if end.maxY > viewport.maxY + 0.5 {
                                try host.scrollOptionsToBottom(matching: viewport)
                                let after = try await host.frames(required: ids, size: size)
                                XCTAssertLessThanOrEqual(try XCTUnwrap(after["lightfield.optionsEnd"]).maxY, viewport.maxY + 0.5)
                            }
                            XCTAssertGreaterThanOrEqual(try XCTUnwrap(frames["lightfield.title"]).minY, 48 - 0.5)
                            continue
                        }
                        let frames = try await host.frames(required: landingRequired, size: size)
                        let tag = "\(page.name) \(language) \(Int(width))x\(Int(height))"
                        let content = try XCTUnwrap(frames["landing.optionsContent"])
                        let viewport = try XCTUnwrap(frames["landing.optionsViewport"])
                        let hidden = content.height - viewport.height
                        if hidden > 2 {
                            // D62① allows the options to scroll while the primary stays fixed.
                            try host.scrollOptionsToBottom(matching: viewport)
                            let after = try await host.frames(required: landingRequired.union(["landing.optionsEnd"]), size: size)
                            if let end = after["landing.optionsEnd"],
                               !viewport.insetBy(dx: -0.5, dy: -0.5).contains(end) {
                                problems.append("\(tag): final option is unreachable")
                            }
                        }
                        try assertLandingReachability(frames, size: size)
                        guard let titleBlock = frames["pageHeader.titleBlock"],
                              let header = frames[LayoutProbeID.landingHeader] else { continue }
                        let fixture = try XCTUnwrap(frames["fixture.viewport"])
                        if titleBlock.minY < fixture.minY - 0.5 {
                            problems.append("\(tag): header title starts above the page (\(Int(titleBlock.minY)))")
                        }
                        let actions = frames["pageHeader.actions"]
                        if page.hasHeaderAction {
                            if width >= 803, let actions, actions.minY >= titleBlock.maxY - 0.5 {
                                problems.append("\(tag): header action stacked below the title")
                            }
                        } else {
                            if actions != nil { problems.append("\(tag): header reserves an empty action row") }
                            let metrics = LandingMetrics(page: .resolve(size: CGSize(width: width, height: height)),
                                size: CGSize(width: width, height: height), systemImage: page.route.systemImage)
                            if abs(header.height - metrics.headerHeight) > 0.5 {
                                problems.append("\(tag): header differs from the common D62 slot")
                            }
                        }
                    }
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, "Landing pages in the real container:\n" + problems.joined(separator: "\n"))
    }

    private struct RealLandingPage {
        let name: String
        let route: ReviewFilter
        let view: AnyView
        var hasHeaderAction = false
    }

    private func realLandingPages(store: ScanStore) -> [RealLandingPage] {
        func hero<Accessory: View>(_ route: ReviewFilter, title: String? = nil, options: String?,
                                   action: String, symbol: String, trust: String, showsAccessory: Bool = true,
                                   @ViewBuilder accessory: () -> Accessory) -> AnyView {
            AnyView(HeroScanPage(
                title: title ?? route.sidebarTitle, subtitle: "",
                headerSystemImage: route.systemImage, configurationTitle: options,
                actionTitle: action, actionDetail: "", actionSystemImage: symbol, status: .neverScanned,
                trustText: trust, showsAccessory: showsAccessory, action: {}, accessory: accessory))
        }
        let scope = L10n.text("扫描范围", "Scan Scope")
        let start = L10n.text("开始扫描", "Start Scan")
        let reviewOnly = L10n.text("只显示可审阅项目，不会自动删除", "Only reviewable items are shown; nothing is deleted automatically")
        let readOnly = L10n.text("只读扫描", "Read-only scan")
        // D69/D70 B4: exercise the production D67 page, including its real
        // own-update text entry, rather than a legacy HeroScanPage surrogate.
        let updater = AnyView(AppUpdateIdlePage(lastSummary: nil, canScan: true, onScan: {}, onManage: {}))
        return [
            RealLandingPage(name: "overview", route: .overview,
                            view: AnyView(SmartCareLandingView(store: store, latestStatus: nil))),
            RealLandingPage(name: "largeFiles", route: .largeFiles,
                            view: AnyView(LargeFilesScanLandingView(store: store, workspace: store.largeFilesWorkspace))),
            RealLandingPage(name: "migration", route: .migration,
                            view: AnyView(LargeFilesScanLandingView(store: store, workspace: store.largeFilesWorkspace, mode: .migration))),
            RealLandingPage(name: "uninstall", route: .uninstall, view: AnyView(AppUninstallScanLandingView(store: store))),
            RealLandingPage(name: "energy", route: .energy, view: AnyView(EnergyImpactScanLandingView(store: store))),
            RealLandingPage(name: "green", route: .green, view: AnyView(ToolPreparationView(store: store, filter: .green))),
            RealLandingPage(name: "devCaches", route: .devCaches,
                            view: hero(.devCaches, options: scope, action: start, symbol: "play.fill", trust: reviewOnly) {
                DeveloperCleanupThresholdControl(store: store).frame(maxWidth: 560)
            }),
            RealLandingPage(name: "health", route: .healthHub, view: AnyView(ComputerHealthWorkspaceView(scanStore: store,
                healthStore: ComputerHealthStore(probe: CalibrationLightfieldHealthProbe(),
                    batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController()),
                networkStore: NetworkSpeedTestStore()))),
            RealLandingPage(name: "privacy", route: .privacy,
                            view: AnyView(BrowserPrivacyWorkspaceView(browserPrivacyStore: BrowserPrivacyPreviewFixture.makeStore())
                                .environment(\.featurePresentationIsFixture, true))),
            RealLandingPage(name: "duplicates", route: .duplicates,
                            view: hero(.duplicates, options: nil, action: start, symbol: "play.fill", trust: readOnly,
                                       showsAccessory: false) { EmptyView() }),
            RealLandingPage(name: "updater", route: .updater, view: updater),
            RealLandingPage(name: "updater+action", route: .updater,
                            view: AnyView(AppUpdateIdlePage(lastSummary: nil, canScan: true,
                                onScan: {}, onManage: {}, onOwnUpdate: {})),
                            hasHeaderAction: true),
        ]
    }

    private var landingRequired: Set<String> {
        ["fixture.viewport", LayoutProbeID.landingCanvas, LayoutProbeID.landingHeader,
         LayoutProbeID.landingActionPanel, LayoutProbeID.landingActionButton,
         LayoutProbeID.landingFooter, "landing.optionsContent", "landing.optionsViewport"]
    }

    private var lightfieldLandingRequired: Set<String> {
        ["fixture.viewport", "lightfield.canvas", "lightfield.title", "lightfield.content",
         "lightfield.primary", "lightfield.status", "lightfield.options.scrollViewport", "lightfield.optionsEnd"]
    }

    private func assertLightfieldLandingReachability(_ frames: [String: CGRect], size: CGSize,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let viewport = try XCTUnwrap(frames["fixture.viewport"], file: file, line: line)
        let canvas = try XCTUnwrap(frames["lightfield.canvas"], file: file, line: line)
        let action = try XCTUnwrap(frames["lightfield.primary"], file: file, line: line)
        let footer = try XCTUnwrap(frames["lightfield.status"], file: file, line: line)
        XCTAssertEqual(viewport.size.width, size.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(viewport.size.height, size.height, accuracy: 1, file: file, line: line)
        for rect in [action, footer] {
            XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(rect),
                "Actual action/footer must be reachable at \(size), rect=\(rect)", file: file, line: line)
            XCTAssertTrue(canvas.insetBy(dx: -1, dy: -1).contains(rect), file: file, line: line)
        }
        XCTAssertLessThanOrEqual(action.maxY, footer.minY + 1, file: file, line: line)
        XCTAssertGreaterThan(action.height, 40, file: file, line: line)
    }

    private func assertLandingReachability(_ frames: [String: CGRect], size: CGSize,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let viewport = try XCTUnwrap(frames["fixture.viewport"], file: file, line: line)
        let canvas = try XCTUnwrap(frames[LayoutProbeID.landingCanvas], file: file, line: line)
        let action = try XCTUnwrap(frames[LayoutProbeID.landingActionButton], file: file, line: line)
        let footer = try XCTUnwrap(frames[LayoutProbeID.landingFooter], file: file, line: line)
        XCTAssertEqual(viewport.size.width, size.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(viewport.size.height, size.height, accuracy: 1, file: file, line: line)
        for rect in [action, footer] {
            XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(rect),
                "Actual action/footer must be reachable at \(size), rect=\(rect)", file: file, line: line)
            XCTAssertTrue(canvas.insetBy(dx: -1, dy: -1).contains(rect), file: file, line: line)
        }
        XCTAssertLessThanOrEqual(action.maxY, footer.minY + 1, file: file, line: line)
        XCTAssertGreaterThan(action.height, 40, file: file, line: line)
    }

    private func energyStrings(_ step: EnergyImpactScanPhase, language: AppLanguage) -> (title: String, description: String) {
        if language == .english {
            return switch step {
            case .readingProcesses: ("Processes", "Read currently running processes")
            case .identifyingApplications: ("Apps", "Attribute child processes to their apps")
            case .capturingBaseline: ("Baseline", "Record CPU, energy, and disk baselines")
            case .preparingPreview: ("Preview", "Prepare the first attributable snapshot")
            case .measuringChanges: ("Measure", "Measure real changes over 1.2 seconds")
            case .calculatingResults: ("Results", "Calibrate and assemble results from this Mac")
            }
        } else {
            return switch step {
            case .readingProcesses: ("进程", "读取当前运行的进程")
            case .identifyingApplications: ("归属", "将子进程归属到对应应用")
            case .capturingBaseline: ("基线", "记录 CPU、能耗与磁盘计数基线")
            case .preparingPreview: ("初算", "生成第一组可归属数据")
            case .measuringChanges: ("采样", "测量 1.2 秒内的真实变化")
            case .calculatingResults: ("汇总", "按本机数据校准并汇总结果")
            }
        }
    }
}

@MainActor
private final class CalibrationEnergyFixture: ObservableObject {
    @Published var phase: EnergyImpactScanPhase?
}

private struct CalibrationEnergyContent: View {
    @ObservedObject var model: CalibrationEnergyFixture
    var body: some View {
        GeometryReader { proxy in
            EnergyImpactScanPipelineView(phase: model.phase, showsStageDetails: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .layoutProbe("fixture.energy.pipeline")
                .environment(\.windowLayoutMetrics, WindowLayoutMetrics(contentSize: proxy.size))
                .environment(\.moduleTheme, ModuleThemeCatalog.theme(for: .energy))
        }
    }
}

@MainActor
private final class CalibrationCallbackRecorder {
    var count: [ReviewFilter: Int] = [:]
    func record(_ route: ReviewFilter) { count[route, default: 0] += 1 }
}

private struct CalibrationEmptyHistoryLoader: ScanStoreHistoryLoading {
    func load() async -> ScanStoreHistorySnapshot {
        ScanStoreHistorySnapshot(scanHistory: ScanHistorySummary(entries: []),
            cleanupHistory: CleanupHistorySummary(entries: []))
    }
}

@MainActor
private final class CalibrationFrameRecorder {
    var frames: [String: CGRect] = [:]
    var globalFrames: [String: CGRect] = [:]
    var runtimeContent: [String: FeatureRuntimeRenderSnapshot] = [:]
    var scrollContent: [String: FeatureScrollRenderSnapshot] = [:]
    var backdrops: [String: Bool] = [:]
}

@MainActor
private final class CalibrationFixtureWindow: NSWindow {
    // The test viewport must remain the requested logical size even when
    // it is larger than the attached display. This is an inert fixture only.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class CalibrationAppKitLayoutHost {
    private let window: NSWindow
    private let controller: NSHostingController<AnyView>
    private let recorder = CalibrationFrameRecorder()
    private var nativeHitRoots = [NSObject]()
    private var nativeHitDiagnostics = [String]()
    private var isClosing = false

    init<Content: View>(root: Content, size: CGSize, dark: Bool) {
        _ = NSApplication.shared
        let content = root
            .environment(\.colorScheme, dark ? .dark : .light)
            // Enable the public assistive-technology environment for this
            // inert component host, without changing any macOS preference.
            // The resulting AX tree and actions still come from SwiftUI.
            .environment(\.accessibilityEnabled, true)
            .layoutProbe("fixture.viewport")
            .onPreferenceChange(FeatureRuntimeRenderPreferenceKey.self) { [weak recorder] content in
                Task { @MainActor [weak recorder] in recorder?.runtimeContent = content }
            }
            .onPreferenceChange(FeatureScrollRenderPreferenceKey.self) { [weak recorder] content in
                Task { @MainActor [weak recorder] in recorder?.scrollContent = content }
            }
            .onPreferenceChange(FeatureBackdropPreferenceKey.self) { [weak recorder] values in
                Task { @MainActor [weak recorder] in recorder?.backdrops = values }
            }
            .onPreferenceChange(LayoutFramePreferenceKey.self) { [weak recorder] frames in
                Task { @MainActor [weak recorder] in
                    recorder?.globalFrames = frames
                    guard let origin = frames["fixture.viewport"]?.origin else {
                        recorder?.frames = frames
                        return
                    }
                    // LayoutProbe uses SwiftUI global coordinates, whereas
                    // native accessibility frames are in the hosting view.
                    // Translate every frame; preserve size and out-of-bounds
                    // content so containment assertions still catch overflow.
                    recorder?.frames = frames.mapValues {
                        $0.offsetBy(dx: -origin.x, dy: -origin.y)
                    }
                }
            }
        controller = NSHostingController(rootView: AnyView(content))
        controller.sizingOptions = []
        window = CalibrationFixtureWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(size)
        layoutNativeHierarchy()
        // Realize only this inert fixture, never the installed app or a Store
        // task. Native accessibility/layout can then provide current frames.
        window.orderFront(nil)
        layoutNativeHierarchy()
    }

    func orbitAnimationStates() -> [Bool] {
        func collect(_ view: NSView) -> [Bool] {
            let current = (view as? OrbitSweepView).map { [$0.isTurning] } ?? []
            return current + view.subviews.flatMap { collect($0) }
        }
        return collect(controller.view)
    }

    func resize(to size: CGSize) {
        nativeHitRoots.removeAll()
        nativeHitDiagnostics.removeAll()
        window.setContentSize(size)
        layoutNativeHierarchy()
        if let scroll = scrollView(matching: nil) {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func frames(required: Set<String>, size: CGSize) async throws -> [String: CGRect] {
        try await settledFrames(required: required, size: size, scrollingBottom: nil)
    }

    /// Lazy document estimates change as the tail becomes real. Keep the
    /// requested bottom anchored during the original 120 x 5 ms / 3 stable
    /// frames gate; never add a sleep, tolerance or longer readiness budget.
    func bottomFrames(required: Set<String>, size: CGSize, viewport: CGRect) async throws -> [String: CGRect] {
        try await settledFrames(required: required, size: size, scrollingBottom: viewport)
    }

    private func settledFrames(required: Set<String>, size: CGSize, scrollingBottom: CGRect?) async throws -> [String: CGRect] {
        var previous: [String: CGRect]?
        var stable = 0
        for _ in 0..<120 {
            if let scrollingBottom { try scrollOptionsToBottom(matching: scrollingBottom) }
            layoutNativeHierarchy()
            await Task.yield()
            let current = recorder.frames
            if required.isSubset(of: Set(current.keys)), let viewport = current["fixture.viewport"],
               abs(viewport.width - size.width) < 1, abs(viewport.height - size.height) < 1 {
                stable = previous == current ? stable + 1 : 0
                previous = current
                if stable >= 3 { return current }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let diagnostic = "Native component frames did not settle at \(size); missing=\(required.subtracting(recorder.frames.keys).sorted()); nativeBounds=\(controller.view.bounds); contentBounds=\(String(describing: window.contentView?.bounds)); frames=\(recorder.frames.sorted { $0.key < $1.key }); globalFrames=\(recorder.globalFrames.sorted { $0.key < $1.key })"
        throw error(diagnostic)
    }

    /// ScrollView descendants are not native AX children in this host (N20).
    /// These values come from the rendered production body, not the fixture.
    func runtimeContent(module: ReviewFilter, stageTitle: String) async throws -> FeatureRuntimeRenderSnapshot {
        var previous: FeatureRuntimeRenderSnapshot?
        var stable = 0
        for _ in 0..<120 {
            layoutNativeHierarchy()
            await Task.yield()
            if let value = recorder.runtimeContent[module.rawValue], value.stageTitle == stageTitle {
                stable = previous == value ? stable + 1 : 0
                previous = value
                if stable >= 3 { return value }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw error("Rendered runtime content did not settle for \(module.rawValue)/\(stageTitle); actual=\(recorder.runtimeContent)")
    }

    func scrollContent(prefix: String) async throws -> FeatureScrollRenderSnapshot {
        var previous: FeatureScrollRenderSnapshot?
        var stable = 0
        for _ in 0..<120 {
            layoutNativeHierarchy()
            await Task.yield()
            if let value = recorder.scrollContent[prefix], value.naturalHeight > 0, value.visibleHeight > 0 {
                stable = previous == value ? stable + 1 : 0
                previous = value
                if stable >= 3 { return value }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw error("Scroll geometry did not settle for \(prefix); actual=\(recorder.scrollContent)")
    }

    func backdropValues() async throws -> [String: Bool] {
        for _ in 0..<120 {
            if recorder.backdrops.count >= 2 { return recorder.backdrops }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        throw error("Backdrop policy did not publish: \(recorder.backdrops)")
    }

    func element(label: String, requiresPress: Bool = false) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            let matches = ["accessibilityTitle", "accessibilityLabel", "accessibilityValue"].contains {
                nativeText(objectValue(object, $0)) == label
            }
            if matches, !requiresPress || isNativeButton(object) { return object }
            let children = nativeChildren(object)
            // `find` mutates `visited`. Lazy compactMap may evaluate the
            // predicate once to find an index and again to read that index;
            // the second visit returns nil and traps in its force unwrap.
            for child in children {
                if let match = find(child) { return match }
            }
            return nil
        }
        if let match = find(controller.view) ?? find(window) { return match }
        for object in nativeHitRoots {
            if let match = find(object) { return match }
        }
        return nil
    }

    func waitForAccessibility(labels: [String], expectedValues: [String: String] = [:],
                              expectedEnabled: [String: Bool] = [:],
                              pressLabels: Set<String> = [], hitTestFrames: [CGRect] = [],
                              hitTestViewport: CGRect? = nil) async throws {
        // Native accessibility publishes independently of geometry. This
        // fixture readiness gate is not an input-to-presentation measurement.
        // Reuse the existing 100 × 5 ms state wait, without changing any UI
        // performance target, frame budget, or content/selection assertion.
        var missing = labels
        for attempt in 0..<100 {
            layoutNativeHierarchy()
            await Task.yield()
            if attempt == 0, !hitTestFrames.isEmpty || hitTestViewport != nil {
                collectNativeAccessibilityHits(frames: hitTestFrames, viewport: hitTestViewport)
            }
            missing = labels.filter { label in
                guard let object = element(label: label, requiresPress: pressLabels.contains(label)) else { return true }
                if let expected = expectedEnabled[label] {
                    guard object.responds(to: NSSelectorFromString("isAccessibilityEnabled")),
                          let enabled = object.value(forKey: "accessibilityEnabled") as? Bool,
                          enabled == expected else { return true }
                }
                if let expected = expectedValues[label] {
                    return nativeText(nativeValue(object)) != expected
                }
                return false
            }
            if missing.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw error("Native AX did not publish labels/actions/values: \(missing); expectedEnabled=\(expectedEnabled); hits=\(nativeHitDiagnostics); snapshot=\(nativeAccessibilitySnapshot())")
    }

    private func collectNativeAccessibilityHits(frames: [CGRect], viewport: CGRect?) {
        // Geometry only chooses where to ask the platform. Every retained
        // object, label, value, frame, parent, and action still comes from
        // the native public accessibility implementation, never a fake node.
        var points = frames.map { CGPoint(x: $0.midX, y: $0.midY) }
        if let viewport {
            // One bounded pass over the currently visible real scroll area.
            // This is fixture discovery, not an input/presentation timing
            // measurement and does not change the original readiness budget.
            let columns = 16
            let rows = 20
            for row in 0..<rows {
                for column in 0..<columns {
                    points.append(CGPoint(
                        x: viewport.minX + (CGFloat(column) + 0.5) * viewport.width / CGFloat(columns),
                        y: viewport.minY + (CGFloat(row) + 0.5) * viewport.height / CGFloat(rows)))
                }
            }
        }
        var retained = Set(nativeHitRoots.map(ObjectIdentifier.init))
        var hitTypes = [String: Int]()
        for point in points where controller.view.bounds.contains(point) {
            // Probe rectangles were translated into the hosting view's
            // native coordinates. NSView.convert handles flipped views;
            // NSWindow then converts to bottom-left screen coordinates as
            // required by public accessibilityHitTest:, without scaling.
            let windowPoint = controller.view.convert(point, to: nil)
            let screenPoint = window.convertToScreen(CGRect(origin: windowPoint, size: .zero)).origin
            guard let object = controller.view.accessibilityHitTest(screenPoint) as? NSObject else {
                hitTypes["nil", default: 0] += 1
                continue
            }
            hitTypes[String(describing: type(of: object)), default: 0] += 1
            var current: NSObject? = object
            var parentVisits = Set<ObjectIdentifier>()
            for _ in 0..<8 {
                guard let node = current, parentVisits.insert(ObjectIdentifier(node)).inserted else { break }
                if retained.insert(ObjectIdentifier(node)).inserted {
                    nativeHitRoots.append(node)
                    if nativeHitDiagnostics.count < 80 {
                        let properties = ["accessibilityRole", "accessibilityTitle", "accessibilityLabel", "accessibilityValue"].map {
                            "\($0)=\(nativeText(objectValue(node, $0)) ?? "nil")"
                        }.joined(separator: ", ")
                        nativeHitDiagnostics.append("point=\(point), screen=\(screenPoint), \(type(of: node)): \(properties)")
                    }
                }
                current = objectValue(node, "accessibilityParent") as? NSObject
            }
        }
        nativeHitDiagnostics.append("publicHitTestPoints=\(points.count), returnedTypes=\(hitTypes), retainedActualObjects=\(nativeHitRoots.count)")
        if let scroll = scrollView(matching: viewport), let document = scroll.documentView {
            let subviews = document.subviews.map {
                "\(type(of: $0)): frame=\($0.frame), hidden=\($0.isHidden), element=\($0.isAccessibilityElement())"
            }
            nativeHitDiagnostics.append("documentSubviews=\(subviews)")
        }
        FileHandle.standardError.write(Data("Native public hit-test diagnostic: \(nativeHitDiagnostics)\n".utf8))
    }

    func accessibilityFrame(label: String) throws -> CGRect {
        let object = try XCTUnwrap(element(label: label), "Missing native element: \(label)")
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")),
              let value = object.value(forKey: "accessibilityFrame") as? NSValue else {
            throw error("Native element has no frame: \(label)")
        }
        let windowRect = window.convertFromScreen(value.rectValue)
        return controller.view.convert(windowRect, from: nil)
    }

    func accessibilityValue(label: String) throws -> String? {
        let object = try XCTUnwrap(element(label: label), "Missing native element: \(label)")
        return nativeText(nativeValue(object))
    }

    func accessibilityLabel(label: String) throws -> String? {
        let object = try XCTUnwrap(element(label: label), "Missing native element: \(label)")
        return nativeText(objectValue(object, "accessibilityLabel"))
            ?? nativeText(objectValue(object, "accessibilityTitle"))
    }

    func waitForEnergyState(_ phase: EnergyImpactScanPhase?) async throws {
        let progressLabel = L10n.text("能耗扫描进度", "Energy scan progress")
        let currentLabel = L10n.text("当前步骤", "Current step")
        for _ in 0..<100 {
            layoutNativeHierarchy()
            await Task.yield()
            let progress = element(label: progressLabel)
            if let phase, let progress,
               nativeText(nativeValue(progress)) == "\(Int(phase.fractionCompleted * 100))%",
               element(label: currentLabel) != nil { return }
            if phase == nil, progress == nil, element(label: currentLabel) == nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw error("The observed energy fixture did not publish its native progress/current stage; snapshot=\(nativeAccessibilitySnapshot())")
    }

    func press(label: String) throws -> Bool {
        let object = try XCTUnwrap(element(label: label, requiresPress: true))
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else {
            throw error("Native element cannot perform press: \(label)")
        }
        // SwiftUI accessibility elements expose the public Objective-C
        // action without adopting NSAccessibility as a static Swift protocol.
        // Its AppKit signature is BOOL with only receiver and selector args;
        // do not call NSObject.perform (which assumes an object return).
        typealias NativePress = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = try XCTUnwrap(object.method(for: selector))
        return unsafeBitCast(implementation, to: NativePress.self)(object, selector)
    }

    func scrollOptionsToBottom(matching viewport: CGRect) throws {
        let scroll = try XCTUnwrap(scrollView(matching: viewport))
        let document = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: CGPoint(x: 0,
            y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        layoutNativeHierarchy()
    }

    /// Preserve the old optionsContent containment check using the actual
    /// D67 scroll document, translated to the same native space as AX frames.
    func optionsDocumentFrame(matching viewport: CGRect) throws -> CGRect {
        let scroll = try XCTUnwrap(scrollView(matching: viewport))
        let document = try XCTUnwrap(scroll.documentView)
        return document.convert(document.bounds, to: controller.view)
    }

    func scrollOptionsToReveal(_ frame: CGRect, matching viewport: CGRect) throws {
        let scroll = try XCTUnwrap(scrollView(matching: viewport))
        let document = try XCTUnwrap(scroll.documentView)
        let row = document.convert(frame, from: controller.view)
        let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: min(maximum, max(0, row.minY))))
        scroll.reflectScrolledClipView(scroll.contentView)
        layoutNativeHierarchy()
    }

    private func scrollView(matching viewport: CGRect?) -> NSScrollView? {
        var nativeFrames = [CGRect]()
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView {
                let rect = scroll.convert(scroll.bounds, to: controller.view)
                nativeFrames.append(rect)
                if viewport == nil || (abs(rect.minX - viewport!.minX) < 1
                    && abs(rect.width - viewport!.width) < 1) { return scroll }
            }
            return view.subviews.lazy.compactMap(find).first
        }
        let result = find(controller.view)
        if let viewport, result == nil {
            let latestProbe = recorder.frames["lightfield.options.scrollViewport"]
            FileHandle.standardError.write(Data("Native scroll viewport mismatch: requested=\(viewport), latestProbe=\(String(describing: latestProbe)), nativeFrames=\(nativeFrames), hostSize=\(controller.view.bounds.size)\n".utf8))
        }
        return result
    }

    private func objectValue(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func nativeText(_ value: AnyObject?) -> String? {
        if let text = value as? String { return text }
        if let text = value as? NSAttributedString { return text.string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func nativeChildren(_ object: NSObject) -> [NSObject] {
        // AppKit exposes NSArray/[Any], not a homogeneous NSObject array.
        // One unbridgeable entry must not discard every valid sibling.
        // Scroll-area primary content is separately exposed via Contents.
        // Include that public relationship and the actual document view;
        // these remain native providers, not synthesized accessibility nodes.
        var result = [NSObject]()
        var seen = Set<ObjectIdentifier>()
        for name in ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"] {
            let children = objectValue(object, name) as? [Any] ?? []
            for case let child as NSObject in children where seen.insert(ObjectIdentifier(child)).inserted {
                result.append(child)
            }
        }
        if let scroll = object as? NSScrollView, let document = scroll.documentView,
           seen.insert(ObjectIdentifier(document)).inserted {
            result.append(document)
        }
        return result
    }

    private func legacyAttributeValue(_ object: NSObject, _ attribute: NSAccessibility.Attribute) -> AnyObject? {
        // Public, deprecated NSAccessibility getter: compare the platform's
        // legacy representation when its modern getter supplies no value.
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector, with: attribute.rawValue as NSString)?.takeUnretainedValue()
    }

    private func nativeValue(_ object: NSObject) -> AnyObject? {
        objectValue(object, "accessibilityValue")
            ?? legacyAttributeValue(object, .value)
            ?? objectValue(object, "accessibilityValueDescription")
            ?? legacyAttributeValue(object, .valueDescription)
    }

    private func isNativeButton(_ object: NSObject) -> Bool {
        object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
            && nativeText(objectValue(object, "accessibilityRole")) == NSAccessibility.Role.button.rawValue
    }

    private func nativeAccessibilitySnapshot() -> [String] {
        var visited = Set<ObjectIdentifier>()
        var rows = [String]()
        func collect(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted, rows.count < 120 else { return }
            let children = objectValue(object, "accessibilityChildren") as? [Any] ?? []
            let contents = objectValue(object, "accessibilityContents") as? [Any] ?? []
            let navigation = objectValue(object, "accessibilityChildrenInNavigationOrder") as? [Any] ?? []
            let names = ["accessibilityRole", "accessibilityTitle", "accessibilityLabel", "accessibilityValue"].map {
                "\($0)=\(nativeText(objectValue(object, $0)) ?? "nil")"
            }.joined(separator: ", ")
            var scrollDescription = ""
            if let scroll = object as? NSScrollView {
                scrollDescription = ", scrollRect=\(scroll.convert(scroll.bounds, to: controller.view)), clipBounds=\(scroll.contentView.bounds), documentBounds=\(String(describing: scroll.documentView?.bounds)), documentFlipped=\(String(describing: scroll.documentView?.isFlipped))"
            }
            let values = "modernDescription=\(nativeText(objectValue(object, "accessibilityValueDescription")) ?? "nil"), legacyValue=\(nativeText(legacyAttributeValue(object, .value)) ?? "nil"), legacyDescription=\(nativeText(legacyAttributeValue(object, .valueDescription)) ?? "nil")"
            rows.append("\(type(of: object)): \(names), \(values), children=\(children.count), bridged=\(children.compactMap { $0 as? NSObject }.count), contents=\(contents.count), navigation=\(navigation.count), press=\(isNativeButton(object))\(scrollDescription)")
            for child in nativeChildren(object) { collect(child) }
        }
        collect(controller.view)
        collect(window)
        return rows
    }

    private func layoutNativeHierarchy() {
        // NSWindow owns the actual content viewport. Pump its parent layout
        // as well as the hosting subtree, including before the first resize.
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func error(_ description: String) -> NSError {
        let failure = NSError(domain: "ConceptLandingNativeLayoutRegressionTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: description])
        // Keep the original failure available if native window teardown
        // causes XCTest to report a secondary lifecycle error instead.
        FileHandle.standardError.write(Data("Native fixture failure: \(failure.domain):\(failure.code) \(failure.localizedDescription)\n".utf8))
        return failure
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        window.orderOut(nil)
        // SwiftUI publishes preferences/accessibility on a later main-actor
        // turn. Retain the native host until those callbacks have drained;
        // detaching it synchronously can mask the original probe failure as
        // failed(deinit) in SDK 27's render state machine.
        Task { @MainActor [window, controller, recorder] in
            await Task.yield()
            controller.rootView = AnyView(EmptyView())
            controller.view.layoutSubtreeIfNeeded()
            await Task.yield()
            window.contentViewController = nil
            window.close()
            _ = recorder
        }
    }
}

private struct CalibrationLightfieldHealthProbe: ComputerHealthProbing {
    func probe() async throws -> ComputerHealthSnapshot {
        XCTFail("No live hardware in landing geometry fixture")
        throw CancellationError()
    }
}
#endif
