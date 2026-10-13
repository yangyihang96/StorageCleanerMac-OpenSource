#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class SafeCleanupLayoutTests: XCTestCase {
    private let supportedContentSizes = [
        CGSize(width: 820, height: 520),
        CGSize(width: 980, height: 680),
        CGSize(width: 1_160, height: 720),
        CGSize(width: 1_440, height: 900)
    ]

    func testBenchmarkViewportDoesNotScrollPersistentActionsOutsideShortWindow() async throws {
        for height: CGFloat in [230, 300, 390, 520] {
            let root = AdaptivePageViewport(resetID: .performance) {
                VStack(spacing: 0) {
                    ScrollView { Color.clear.frame(height: 1_000) }
                    Button("Cancel test") {}.padding(8).layoutProbe("benchmark.actions")
                }
            }
            let host = AppKitLayoutHost(rootView: root, contentSize: .init(width: 480, height: height))
            defer { host.close() }
            let frames = try await host.waitForFrames(required: ["benchmark.actions", LayoutProbeID.pageViewport])
            let actions = try XCTUnwrap(frames["benchmark.actions"])
            let viewport = try XCTUnwrap(frames[LayoutProbeID.pageViewport])
            XCTAssertGreaterThan(actions.height, 20)
            XCTAssertGreaterThanOrEqual(actions.minY, viewport.minY)
            XCTAssertLessThanOrEqual(actions.maxY, viewport.maxY + 1, "Height \(height)")
        }
    }

    func testFileToolActionsRemainInsideActualShortViewport() async throws {
        for route in ReviewFilter.fileWorkspaceCases {
            for height: CGFloat in [390, 490, 620] {
                let root = AdaptivePageViewport(resetID: route) {
                    FileToolLandingPage(title: "File Migration", subtitle: "Review the source and destination",
                        systemImage: route.systemImage, configurationTitle: "Options", actionTitle: "Review files",
                        actionDetail: "", actionSystemImage: "magnifyingglass", status: .idle("Not scanned"),
                        trustText: "Read-only scan", action: {}) {
                            VStack { ForEach(0..<8) { Text("Option \($0)").frame(height: 32) } }
                        }.environment(\.moduleTheme, ModuleThemeCatalog.theme(for: route))
                }
                let host = AppKitLayoutHost(rootView: root, contentSize: .init(width: 480, height: height))
                defer { host.close() }
                let frames = try await host.waitForFrames(required: ["lightfield.primary", "lightfield.canvas", LayoutProbeID.pageViewport, "lightfield.options.scrollViewport"],
                    expectedLandingSize: .init(width: 480, height: height), expectedRootProbe: "lightfield.canvas")
                let options = try XCTUnwrap(frames["lightfield.options.scrollViewport"])
                XCTAssertGreaterThanOrEqual(options.height, 79, "Configuration must remain usable: \(route) / \(height)")
                let action = try XCTUnwrap(frames["lightfield.primary"])
                let viewport = try XCTUnwrap(frames[LayoutProbeID.pageViewport])
                XCTAssertGreaterThanOrEqual(action.minY, viewport.minY)
                XCTAssertLessThanOrEqual(action.maxY, viewport.maxY + 1, "\(route) / \(height)")
            }
        }
    }

    func testLandingCardUsesItsOptionsHeightWhenTheWindowGetsTaller() async throws {
        let root = GeometryReader { proxy in
            FileToolLandingPage(title: "File Migration", subtitle: "Review source and destination",
                systemImage: ReviewFilter.migration.systemImage, configurationTitle: "Options",
                actionTitle: "Review files", actionDetail: "", actionSystemImage: "magnifyingglass",
                status: .idle("Not scanned"), trustText: "Read-only scan", action: {}) {
                    VStack(spacing: 4) {
                        ForEach(0..<3) { Text("Option \($0)").frame(height: 32) }
                    }
                }
                .environment(\.moduleTheme, ModuleThemeCatalog.theme(for: .migration))
                .environment(\.windowLayoutMetrics, WindowLayoutMetrics(contentSize: proxy.size))
        }
        // D67 supersedes the D63 card: the slot can grow, while sparse
        // options retain their natural height and the action stays separate.
        let host = AppKitLayoutHost(rootView: root, contentSize: CGSize(width: 870, height: 680))
        defer { host.close() }
        let required: Set<String> = ["lightfield.options.content", "lightfield.options.scrollViewport",
            "lightfield.canvas", "lightfield.content", "lightfield.primary", "lightfield.status"]
        var naturalOptionsHeight: CGFloat?
        for heights: [CGFloat] in [[680, 900, 1_100, 680], [560, 600, 650, 560]] {
            for height in heights {
                host.resize(to: CGSize(width: 870, height: height))
                let frames = try await host.waitForFrames(required: required,
                    expectedLandingSize: CGSize(width: 870, height: height), expectedRootProbe: "lightfield.canvas")
                let content = try frame("lightfield.options.content", in: frames)
                let viewport = try frame("lightfield.options.scrollViewport", in: frames)
                let canvas = try frame("lightfield.canvas", in: frames)
                let panel = try frame("lightfield.content", in: frames)
                let action = try frame("lightfield.primary", in: frames)
                let footer = try frame("lightfield.status", in: frames)
                // Sparse rows never stretch to fill the growing D67 slot.
                XCTAssertGreaterThanOrEqual(viewport.height, content.height - 1)
                if let naturalOptionsHeight {
                    XCTAssertEqual(content.height, naturalOptionsHeight, accuracy: 0.5)
                } else { naturalOptionsHeight = content.height }
                XCTAssertEqual(action.height, 52, accuracy: 0.5)
                XCTAssertLessThanOrEqual(action.minY - viewport.maxY, 26)
                XCTAssertLessThanOrEqual(panel.maxY, footer.minY + 1)
                let size = CGSize(width: 870, height: height)
                let geometry = FeatureLightfieldGeometry(size: size, phase: .landing)
                XCTAssertEqual(panel.height, geometry.content.height, accuracy: 0.5,
                               "D67 common content slot: \(height)")
                // Independent of the implementation's geometry/token values:
                // reserve a 52 pt action, two 24 pt gaps and 64 pt status.
                XCTAssertLessThanOrEqual(panel.height, canvas.height - (panel.minY - canvas.minY) - 164 + 0.5,
                    "D67 independent upper bound preserves the action and status")
            }
        }
    }

    func testDeveloperCategoriesUseBalancedRowsThroughWidthChanges() async throws {
        _ = NSApplication.shared
        let root = GeometryReader { proxy in
            FileToolLandingPage(title: "Developer Tools", subtitle: "",
                systemImage: ReviewFilter.devCaches.systemImage, configurationTitle: nil,
                actionTitle: "Scan", actionDetail: "", actionSystemImage: "play.fill",
                status: .idle("Not scanned"), trustText: "Read-only", action: {}) { EmptyView() }
                .environment(\.moduleTheme, ModuleThemeCatalog.theme(for: .devCaches))
                .environment(\.windowLayoutMetrics, WindowLayoutMetrics(contentSize: proxy.size))
        }
        // Realize the scroll viewport before measuring lazy grid cells.
        let host = AppKitLayoutHost(rootView: root, contentSize: CGSize(width: 1_280, height: 900))
        host.show()
        defer { host.close() }
        let required = Set((0..<4).map { LayoutProbeID.landingScopeCard($0) }
            + [LayoutProbeID.landingRoot, LayoutProbeID.landingContent,
               "landing.optionsViewport", "landing.optionsContent"])
        // D62② plus visual P2-7: scope tiles use two complete columns at
        // readable widths and one below the fit threshold. Options can scroll;
        // the primary action stays pinned outside that scroll viewport.
        let sizes: [(CGFloat, Int)] = [(1_280, 2), (900, 2), (760, 2), (660, 2), (430, 2), (280, 1), (260, 1), (1_280, 2)]
        for (width, columns) in sizes {
            let revision = host.recorder.revision
            host.resize(to: CGSize(width: width, height: 900))
            let frames = try await host.waitForFrames(required: required, afterRevision: revision)
            let cards = try (0..<4).map { try frame(LayoutProbeID.landingScopeCard($0), in: frames) }
            let rootFrame = try frame(LayoutProbeID.landingRoot, in: frames)
            let panel = try frame(LayoutProbeID.landingContent, in: frames)
            let options = try frame("landing.optionsViewport", in: frames)
            let optionsContent = try frame("landing.optionsContent", in: frames)
            XCTAssertEqual(rootFrame.width, width, accuracy: 1)
            print("Developer categories: viewport=\(rootFrame.width), panel=\(panel.width), options=\(options), content=\(optionsContent), expectedColumns=\(columns), cards=\(cards)")
            for card in cards {
                XCTAssertTrue(optionsContent.contains(card), "Every category must fit within the complete scroll content")
                if options.height >= optionsContent.height - 0.5 {
                    // The Grid snaps card edges to backing pixels while the
                    // viewport can retain a fractional point width (e.g. 362.8).
                    let pixel = 1 / host.window.backingScaleFactor
                    XCTAssertTrue(options.insetBy(dx: -pixel, dy: -pixel).contains(card),
                        "All categories must be visible when their natural content fits")
                }
            }
            for index in 1..<4 {
                if index / columns == (index - 1) / columns {
                    XCTAssertEqual(cards[index].minY, cards[index - 1].minY, accuracy: 1,
                                   "Width \(width) should use \(columns) complete columns")
                } else {
                    XCTAssertGreaterThanOrEqual(cards[index].minY, cards[index - 1].maxY,
                        "Width \(width) should begin a complete new row")
                }
            }
        }
    }

    func testLongLandingOptionsScrollWithoutTakingTheActionOffscreen() async throws {
        let root = GeometryReader { proxy in
            FileToolLandingPage(title: "Options", subtitle: "",
                systemImage: ReviewFilter.migration.systemImage, configurationTitle: "Folders",
                actionTitle: "Review files", actionDetail: "", actionSystemImage: "magnifyingglass",
                status: .idle("Not scanned"), trustText: "Read-only", action: {}) {
                    VStack(spacing: 4) {
                        ForEach(0..<30) { Text("Fixture folder \($0)").frame(height: 32) }
                    }
                }
                .environment(\.moduleTheme, ModuleThemeCatalog.theme(for: .migration))
                .environment(\.windowLayoutMetrics, WindowLayoutMetrics(contentSize: proxy.size))
        }
        .layoutProbe("landing.testViewport")
        let host = AppKitLayoutHost(rootView: root, contentSize: CGSize(width: 480, height: 390))
        defer { host.close() }
        let required: Set<String> = ["lightfield.options.content", "lightfield.options.scrollViewport",
            "lightfield.optionsEnd", "lightfield.canvas", "landing.testViewport", "lightfield.primary"]
        for height: CGFloat in [390, 620, 390] {
            host.resize(to: CGSize(width: 480, height: height))
            let frames = try await host.waitForFrames(required: required,
                expectedLandingSize: .init(width: 480, height: height), expectedRootProbe: "lightfield.canvas")
            let content = try frame("lightfield.options.content", in: frames)
            let options = try frame("lightfield.options.scrollViewport", in: frames)
            let viewport = try frame("landing.testViewport", in: frames)
            let action = try frame("lightfield.primary", in: frames)
            XCTAssertGreaterThan(content.height, options.height + 500)
            XCTAssertGreaterThanOrEqual(options.height, 79)
            XCTAssertGreaterThanOrEqual(action.minY, viewport.minY)
            XCTAssertLessThanOrEqual(action.maxY, viewport.maxY + 1)
            XCTAssertTrue(host.pageScrollIsNeeded(), "The real options document must be scrollable")
            let revision = host.recorder.revision
            try host.scrollPageToBottom()
            let scrolled = try await host.waitForFrames(required: required, afterRevision: revision,
                expectedLandingSize: .init(width: 480, height: height), expectedRootProbe: "lightfield.canvas")
            let end = try frame("lightfield.optionsEnd", in: scrolled)
            let visibleOptions = try frame("lightfield.options.scrollViewport", in: scrolled)
            XCTAssertTrue(visibleOptions.insetBy(dx: -0.5, dy: -0.5).contains(end), "The final option is reachable")
            XCTAssertEqual(try frame("lightfield.primary", in: scrolled), action, "Scrolling options cannot move the action")
            XCTAssertLessThanOrEqual(try frame("lightfield.primary", in: scrolled).maxY, viewport.maxY + 1)
        }
    }

    func testMiniSettingsPreviewStaysWithinNarrowViewportAndActionsRemainVisible() async throws {
        for width: CGFloat in [280, 320, 480, 660, 720, 900] {
            let host = AppKitLayoutHost(rootView: MiniWindowConfigurationSettingsView(
                draft: .constant(GeekDashboardDraft(.defaultValue)))
                .layoutProbe("miniSettings.viewport"),
                contentSize: CGSize(width: width, height: 500))
            defer { host.close() }
            let frames = try await host.waitForFrames(required: ["miniSettings.preview", "miniSettings.actions", "miniSettings.viewport",
                "settings.preview.panel", "settings.preview.scrollContent", "settings.preview.scrollViewport", "miniSettings.notebookExample"])
            let viewport = try XCTUnwrap(frames["miniSettings.viewport"])
            let preview = try XCTUnwrap(frames["miniSettings.preview"])
            let panel = try XCTUnwrap(frames["settings.preview.panel"])
            let scrollContent = try XCTUnwrap(frames["settings.preview.scrollContent"])
            let actions = try XCTUnwrap(frames["miniSettings.actions"])
            // B6: the 1:1 panel belongs to scrollable content, not a 280 pt clip viewport.
            XCTAssertGreaterThanOrEqual(preview.minX, scrollContent.minX - 1)
            XCTAssertLessThanOrEqual(preview.maxX, scrollContent.maxX + 1, "Width \(width)")
            XCTAssertTrue(scrollContent.insetBy(dx: -0.5, dy: -0.5).contains(preview))
            XCTAssertEqual(preview.width, 304, accuracy: 0.5)
            XCTAssertEqual(preview.height, panel.height + 54, accuracy: 0.5)
            XCTAssertEqual(panel.size, GeekPanelLayout.overviewSize(modules: GeekDashboardConfiguration.defaultModuleOrder))
            XCTAssertGreaterThanOrEqual(actions.minY, viewport.minY)
            XCTAssertLessThanOrEqual(actions.maxY, viewport.maxY + 1)
            XCTAssertGreaterThanOrEqual(actions.minX, viewport.minX)
            XCTAssertLessThanOrEqual(actions.maxX, viewport.maxX + 0.5)
            let previewViewport = try XCTUnwrap(frames["settings.preview.scrollViewport"])
            if width < 760 {
                let editorViewport = try XCTUnwrap(frames["settings.editor.scrollViewport"])
                XCTAssertLessThanOrEqual(editorViewport.maxY, actions.minY + 0.5)
                XCTAssertLessThanOrEqual(previewViewport.width, viewport.width + 0.5)
                XCTAssertTrue(host.pageScrollIsNeeded())
                _ = try host.scrollOptionIntoView(try XCTUnwrap(frames["miniSettings.notebookExample"]), viewport: editorViewport)
                let reachable = try await host.waitForFrames(required: ["miniSettings.notebookExample", "settings.editor.scrollViewport"])
                XCTAssertTrue(try XCTUnwrap(reachable["settings.editor.scrollViewport"]).insetBy(dx: -0.5, dy: -0.5)
                    .contains(try XCTUnwrap(reachable["miniSettings.notebookExample"])))
                try host.scrollPageToBottom()
                let scrolled = try await host.waitForFrames(required: ["miniSettings.actions", "settings.preview.panel", "settings.editor.scrollViewport"])
                XCTAssertEqual(scrolled["miniSettings.actions"], actions, "Actions stay fixed while settings and the full panel scroll")
                XCTAssertLessThanOrEqual(try XCTUnwrap(scrolled["settings.preview.panel"]).maxY,
                    try XCTUnwrap(scrolled["settings.editor.scrollViewport"]).maxY + 0.5)
                if width < 304 {
                    try host.scrollPreviewToTrailingEdge()
                    let trailing = try await host.waitForFrames(required: ["settings.preview.panel", "settings.preview.scrollViewport", "miniSettings.actions"])
                    XCTAssertLessThanOrEqual(try XCTUnwrap(trailing["settings.preview.panel"]).maxX,
                        try XCTUnwrap(trailing["settings.preview.scrollViewport"]).maxX + 0.5)
                    XCTAssertEqual(trailing["miniSettings.actions"], actions)
                }
            }
        }
    }

    func testManagementHeaderFitsOneRowBeforeTheOldGlobalBreakpoint() async throws {
        for width: CGFloat in [660, 839, 840, 899, 900, 901] {
            let host = AppKitLayoutHost(rootView:
                AppPageHeader(title: "卸载", subtitle: nil, systemImage: "trash") {
                    Button("刷新") {}
                    Button("卸载记录") {}
                    Button("查找残留") {}
                }.environment(\.windowLayoutMetrics, WindowLayoutMetrics(contentSize: CGSize(width: width, height: 600))),
                contentSize: CGSize(width: width, height: 120))
            defer { host.close() }
            let frames = try await host.waitForFrames(required: ["pageHeader.title", "pageHeader.actions"])
            let title = try XCTUnwrap(frames["pageHeader.title"])
            let actions = try XCTUnwrap(frames["pageHeader.actions"])
            XCTAssertLessThan(abs(title.midY - actions.midY), 2, "Width \(width)")
            XCTAssertLessThanOrEqual(title.maxX, actions.minX)
            XCTAssertLessThanOrEqual(actions.maxX, width + 1)
        }
    }

    func testSmartScanAllThreeScopeRowsRemainInsideTheVisibleConfiguration() async throws {
        let context = try await makeContext(fixture: .idle)
        defer { context.browserPrivacyStore.clearSession() }
        let root = GeometryReader { proxy in
            SmartCareLandingView(store: context.scanStore, latestStatus: nil)
                .environment(\.windowLayoutMetrics, WindowLayoutMetrics(contentSize: proxy.size))
                .environment(\.moduleTheme, ModuleThemeCatalog.theme(for: .overview))
        }
        let host = AppKitLayoutHost(rootView: root, contentSize: CGSize(width: 870, height: 620))
        defer { host.close() }
        for size in [CGSize(width: 870, height: 620), CGSize(width: 980, height: 640)] {
            host.resize(to: size)
            let ids: Set<String> = ["landing.optionsViewport", "smartScope.trash", "smartScope.doc.text.magnifyingglass", "smartScope.shield"]
            let frames: [String: CGRect]
            do { frames = try await host.waitForFrames(required: ids) }
            catch {
                XCTFail("Scope layout: \(String(describing: error)); frames=\(host.recorder.frames)")
                return
            }
            let viewport = try XCTUnwrap(frames["landing.optionsViewport"])
            for id in ids where id.hasPrefix("smartScope.") {
                let row = try XCTUnwrap(frames[id])
                XCTAssertGreaterThanOrEqual(row.minY, viewport.minY - 1)
                XCTAssertLessThanOrEqual(row.maxY, viewport.maxY + 1, "\(id), size \(size)")
            }
        }
    }

    func testSmartScanReferenceProportionsKeepAllScopesReadableInBothAppearances() async throws {
        let context = try await makeContext(fixture: .idle)
        defer { context.browserPrivacyStore.clearSession() }
        let symbols = ["trash", "doc.text.magnifyingglass", "shield"]
        let required = Set(symbols.flatMap {
            ["smartScope.\($0)", "smartScope.icon.\($0)", "smartScope.copy.\($0)"]
        } + [LayoutProbeID.landingContent, LayoutProbeID.landingActionButton,
             LayoutProbeID.landingFooter, "landing.optionsViewport", "landing.optionsContent"])
        for scheme in [ColorScheme.light, .dark] {
            let root = AdaptivePageViewport {
                SmartCareLandingView(store: context.scanStore, latestStatus: nil)
                    .environment(\.moduleTheme, ModuleThemeCatalog.theme(for: .overview))
                    .environment(\.colorScheme, scheme)
            }
            let host = AppKitLayoutHost(rootView: root, contentSize: CGSize(width: 1_024, height: 734))
            defer { host.close() }
            for size in [CGSize(width: 1_024, height: 734), CGSize(width: 980, height: 680), CGSize(width: 980, height: 640),
                         CGSize(width: 604, height: 490), CGSize(width: 473, height: 360)] {
                host.resize(to: size)
                let frames = try await host.waitForFrames(required: required)
                let panel = try frame(LayoutProbeID.landingContent, in: frames)
                _ = try frame("landing.optionsViewport", in: frames)
                let action = try frame(LayoutProbeID.landingActionButton, in: frames)
                for symbol in symbols {
                    let row = try frame("smartScope.\(symbol)", in: frames)
                    let icon = try frame("smartScope.icon.\(symbol)", in: frames)
                    let copy = try frame("smartScope.copy.\(symbol)", in: frames)
                    XCTAssertTrue(row.contains(icon), "\(symbol) / \(size)")
                    XCTAssertTrue(row.contains(copy), "\(symbol) / \(size)")
                    XCTAssertLessThanOrEqual(icon.maxX + 11, copy.minX)
                    let optionsContent = try frame("landing.optionsContent", in: frames)
                    XCTAssertTrue(optionsContent.insetBy(dx: -1, dy: -1).contains(row))
                    if !WindowLayoutMetrics(contentSize: size).isCompactLanding {
                        // D62① common list rows use a fixed icon token, independent of card width.
                        XCTAssertEqual(icon.width, FeaturePageTokens.optionIconSide, accuracy: 0.5)
                    }
                }
                XCTAssertTrue(panel.contains(action))
                XCTAssertGreaterThanOrEqual(action.height, AppControlSizes.minimumControlHeight)
                if size.width >= 980 {
                    let metrics = LandingMetrics(page: .resolve(size: size), size: size,
                                                 systemImage: ReviewFilter.overview.systemImage)
                    XCTAssertEqual(panel.width, metrics.actionWidth, accuracy: 0.5)
                }
                try host.captureRuntimeFixtureIfRequested(name: "smart-reference-\(scheme == .dark ? "night" : "day")-\(Int(size.width))x\(Int(size.height)).png")
            }
        }
    }

    func testFileAnalysisKeepsStandaloneActionAlignedWithConfigurationThroughResizes() async throws {
        let root = AdaptivePageViewport(resetID: .largeFiles) {
            FileToolLandingPage(title: "文件分析", subtitle: "查看所选位置的文件分布",
                systemImage: ReviewFilter.largeFiles.systemImage,
                configurationTitle: "分析范围", actionTitle: "分析磁盘空间", actionDetail: "",
                actionSystemImage: "magnifyingglass", status: .neverScanned,
                trustText: "只读分析", action: {}) {
                    VStack(alignment: .leading) {
                        Text("Macintosh HD").frame(height: 40)
                        Text("个人目录").frame(height: 40)
                    }
                }
                .environment(\.moduleTheme, ModuleThemeCatalog.theme(for: .largeFiles))
        }
        let host = AppKitLayoutHost(rootView: root, contentSize: CGSize(width: 1_024, height: 734))
        defer { host.close() }
        let required: Set<String> = ["lightfield.content", "lightfield.primary", "lightfield.status", "lightfield.canvas"]
        for size in [CGSize(width: 1_024, height: 734), CGSize(width: 900, height: 620),
                     CGSize(width: 604, height: 490), CGSize(width: 473, height: 360),
                     CGSize(width: 1_024, height: 734)] {
            host.resize(to: size)
            let frames = try await host.waitForFrames(required: required, expectedLandingSize: size,
                expectedRootProbe: "lightfield.canvas")
            let configuration = try frame("lightfield.content", in: frames)
            let action = try frame("lightfield.primary", in: frames)
            let footer = try frame("lightfield.status", in: frames)
            let canvas = try frame("lightfield.canvas", in: frames)
            // D67: the standalone action has the same left edge and width
            // as configuration, with a fixed 24 pt separation, without a card.
            XCTAssertEqual(action.minX - configuration.minX, 0, accuracy: 0.5)
            XCTAssertEqual(configuration.width - action.width, 0, accuracy: 0.5)
            XCTAssertEqual(action.minY - configuration.maxY, 24, accuracy: 0.5)
            XCTAssertTrue(canvas.contains(configuration))
            XCTAssertTrue(canvas.contains(action))
            XCTAssertLessThanOrEqual(action.maxY, footer.minY + 1)
            XCTAssertGreaterThanOrEqual(action.height, AppControlSizes.minimumControlHeight)
            try host.captureRuntimeFixtureIfRequested(name: "files-separated-action-\(Int(size.width))x\(Int(size.height)).png")
        }
    }

    func testFixedWindowsKeepIdleScanningAndCompletedWorkspaceBelowContentLayoutGuide() async throws {
        for size in supportedContentSizes {
            for fixture in [
                PrivacyLayoutFixture.idle,
                .scanning,
                .completedEmpty,
                .completedSmall
            ] {
                let context = try await makeContext(fixture: fixture)
                let host = makeHost(context: context, contentSize: size)
                defer {
                    context.browserPrivacyStore.clearSession()
                    host.close()
                }

                let frames = try await host.waitForFrames(required: privacyProbeIDs)

                assertWorkspaceTopIsInsideContent(
                    frames,
                    fixture: fixture,
                    size: size
                )

                if fixture == .scanning {
                    await context.scanner.finishSuspended()
                    try await waitForPrivacyState(.completed, store: context.browserPrivacyStore)
                }
            }
        }
    }

    func testLargePrivacyResultCannotPushSafeWorkspaceIntoTitlebar() async throws {
        for size in supportedContentSizes {
            let context = try await makeContext(fixture: .completedLarge)
            let host = makeHost(context: context, contentSize: size)
            defer {
                context.browserPrivacyStore.clearSession()
                host.close()
            }

            let frames = try await host.waitForFrames(required: privacyProbeIDs)

            assertWorkspaceTopIsInsideContent(
                frames,
                fixture: .completedLarge,
                size: size
            )
        }
    }

    func testOneHundredPrivacySafeCleanupSwitchesKeepWorkspaceTopStable() async throws {
        // The smallest supported window has the least vertical slack and is the
        // deterministic stress case. The other supported sizes are covered by
        // the state/large-result geometry tests above.
        let size = try XCTUnwrap(supportedContentSizes.first)
        let context = try await makeContext(fixture: .completedLarge)
        let host = makeHost(context: context, contentSize: size)
        defer {
            context.browserPrivacyStore.clearSession()
            host.close()
        }

        let initialFrames = try await host.waitForFrames(required: privacyProbeIDs)
        let initialWorkspaceTop = try frame(
            LayoutProbeID.workspace,
            in: initialFrames
        ).minY
        var maximumDrift: CGFloat = 0
        var minimumWorkspaceTop = initialWorkspaceTop

        for switchIndex in 0..<100 {
            let nextFilter: ReviewFilter = switchIndex.isMultiple(of: 2)
                ? .green
                : .privacy
            let revision = host.recorder.revision
            context.scanStore.navigationState.select(nextFilter)
            let requiredProbeIDs = nextFilter == .privacy
                ? privacyProbeIDs
                : baseProbeIDs
            let frames = try await host.waitForFrames(
                required: requiredProbeIDs,
                afterRevision: revision,
                privacyProbeExpected: nextFilter == .privacy,
                stablePassesRequired: 1
            )
            let workspaceTop = try frame(LayoutProbeID.workspace, in: frames).minY
            maximumDrift = max(maximumDrift, abs(workspaceTop - initialWorkspaceTop))
            minimumWorkspaceTop = min(minimumWorkspaceTop, workspaceTop)
        }

        let settledFrames = try await host.waitForFrames(required: privacyProbeIDs)
        let contentTop = try frame(LayoutProbeID.contentLayout, in: settledFrames).minY
        XCTAssertGreaterThanOrEqual(
            minimumWorkspaceTop,
            contentTop - 1,
            "100 次 privacy/green 切换后工作区进入标题栏：\(sizeDescription(size))；contentTop=\(contentTop)，minimumTop=\(minimumWorkspaceTop)"
        )
        XCTAssertLessThanOrEqual(
            maximumDrift,
            1,
            "100 次 privacy/green 切换改变了工作区顶部 \(maximumDrift) pt：\(sizeDescription(size))；initialTop=\(initialWorkspaceTop)，minimumTop=\(minimumWorkspaceTop)"
        )
    }

    func testGreenAndDevCachesKeepSharedItemPanesReadableWithoutOverlap() async throws {
        let size = try XCTUnwrap(supportedContentSizes.first)
        let context = try await makeContext(fixture: .completedLarge)
        let host = makeHost(context: context, contentSize: size)
        defer {
            context.browserPrivacyStore.clearSession()
            host.close()
        }

        for filter in ReviewFilter.cleanupWorkspaceCases {
            context.scanStore.navigationState.select(filter)
            let frames: [String: CGRect]
            do {
                frames = try await host.waitForFrames(
                    required: baseProbeIDs.union([
                        LayoutProbeID.itemListPane,
                        LayoutProbeID.itemDetailPane
                    ]),
                    privacyProbeExpected: false,
                    stablePassesRequired: 1
                )
            } catch {
                XCTFail("\(filter.title) frame capture failed: \(error)")
                return
            }
            let listPane = try frame(LayoutProbeID.itemListPane, in: frames)
            let detailPane = try frame(LayoutProbeID.itemDetailPane, in: frames)

            XCTAssertGreaterThanOrEqual(
                listPane.width,
                ItemListResponsiveLayout.minimumListWidth - 1,
                "\(filter.title) list pane was compressed: \(listPane)"
            )
            XCTAssertGreaterThanOrEqual(
                detailPane.width,
                ItemListResponsiveLayout.minimumDetailWidth - 1,
                "\(filter.title) detail pane was compressed: \(detailPane)"
            )
            let separatedHorizontally = listPane.maxX <= detailPane.minX + 1
                || detailPane.maxX <= listPane.minX + 1
            let separatedVertically = listPane.maxY <= detailPane.minY + 1
                || detailPane.maxY <= listPane.minY + 1
            XCTAssertTrue(
                separatedHorizontally || separatedVertically,
                "\(filter.title) panes overlapped: list=\(listPane), detail=\(detailPane)"
            )
        }
    }

    func testGoldenLandingKeepsRealControlsAndArtworkSeparateAtEverySupportedSize() async throws {
        let required = Set([
            LayoutProbeID.landingRoot,
            LayoutProbeID.landingContent,
            LayoutProbeID.landingHeader,
            LayoutProbeID.landingActionButton,
            LayoutProbeID.landingFooter,
            LayoutProbeID.landingArtwork,
        ] + (0..<3).flatMap { index in
            [LayoutProbeID.landingScopeCard(index), LayoutProbeID.landingScopeTitle(index)]
        })
        for size in supportedContentSizes {
            let host = makeConceptLandingHost(contentSize: size)
            defer { host.close() }
            let frames = try await host.waitForFrames(required: required)
            let root = try frame(LayoutProbeID.landingRoot, in: frames)
            let content = try frame(LayoutProbeID.landingContent, in: frames)
            let header = try frame(LayoutProbeID.landingHeader, in: frames)
            let action = try frame(LayoutProbeID.landingActionButton, in: frames)
            let footer = try frame(LayoutProbeID.landingFooter, in: frames)
            XCTAssertTrue(root.contains(content), sizeDescription(size))
            XCTAssertTrue(root.contains(footer), sizeDescription(size))
            XCTAssertTrue(content.contains(action), sizeDescription(size))
            XCTAssertLessThanOrEqual(header.maxY, content.minY + 1)
            XCTAssertLessThanOrEqual(content.maxY, footer.minY + 1)
            let artwork = try frame(LayoutProbeID.landingArtwork, in: frames)
            XCTAssertTrue(root.contains(artwork), sizeDescription(size))
            XCTAssertLessThanOrEqual(content.maxX, artwork.minX + 1, sizeDescription(size))
            XCTAssertLessThanOrEqual(artwork.maxY, footer.minY + 1, sizeDescription(size))
            for index in 0..<3 {
                let card = try frame(LayoutProbeID.landingScopeCard(index), in: frames)
                let title = try frame(LayoutProbeID.landingScopeTitle(index), in: frames)
                XCTAssertNil(frames[LayoutProbeID.landingScopeIcon(index)], "D64 display-only scope glyph removed")
                XCTAssertTrue(card.contains(title))
                XCTAssertGreaterThan(title.width, 0)
                XCTAssertGreaterThan(title.height, 0)
            }
        }
    }

    func testResizingDetailColumnKeepsScopeReadableAndShortPageScrollable() async throws {
        // Actual detail-column sizes, after subtracting the sidebar/titlebar.
        // Resize the same host through both breakpoints and back to wide.
        let sizes = [
            CGSize(width: 1024, height: 734),
            CGSize(width: 604, height: 490),
            CGSize(width: 473, height: 360),
            CGSize(width: 1072, height: 360),
            CGSize(width: 473, height: 734),
            CGSize(width: 1024, height: 734)
        ]
        let host = makeConceptLandingHost(contentSize: sizes[0], responsive: true)
        defer { host.close() }
        let required: Set<String> = [
            LayoutProbeID.pageViewport,
            LayoutProbeID.landingCanvas, LayoutProbeID.landingContent,
            LayoutProbeID.landingHeader, LayoutProbeID.landingFooter,
            LayoutProbeID.landingActionButton, "landing.optionsViewport",
            LayoutProbeID.landingScopeCard(0), LayoutProbeID.landingScopeCard(1), LayoutProbeID.landingScopeCard(2)
        ]
        for size in sizes {
            host.resize(to: size)
            let frames = try await host.waitForFrames(required: required, expectedLandingSize: size)
            let canvas = try frame(LayoutProbeID.landingCanvas, in: frames)
            let panel = try frame(LayoutProbeID.landingContent, in: frames)
            let header = try frame(LayoutProbeID.landingHeader, in: frames)
            let footer = try frame(LayoutProbeID.landingFooter, in: frames)
            let action = try frame(LayoutProbeID.landingActionButton, in: frames)
            XCTAssertGreaterThanOrEqual(panel.height, 210, sizeDescription(size))
            XCTAssertTrue(canvas.contains(panel), sizeDescription(size))
            XCTAssertTrue(canvas.contains(footer), sizeDescription(size))
            XCTAssertTrue(panel.contains(action), sizeDescription(size))
            XCTAssertLessThanOrEqual(header.maxY, panel.minY + 1, sizeDescription(size))
            XCTAssertLessThanOrEqual(panel.maxY, footer.minY + 1, sizeDescription(size))
            var visibleFrames = frames
            for index in 0..<3 {
                var card = try frame(LayoutProbeID.landingScopeCard(index), in: visibleFrames)
                let options = try frame("landing.optionsViewport", in: visibleFrames)
                // D62②: overflow belongs to the options scroll view. Require
                // each complete scope card to be visible after scrolling it
                // into view, while retaining the original panel containment.
                let revision = host.recorder.revision
                let scrolled = try host.scrollOptionIntoView(card, viewport: options)
                visibleFrames = try await host.waitForFrames(required: required,
                    afterRevision: scrolled ? revision : nil, expectedLandingSize: size)
                card = try frame(LayoutProbeID.landingScopeCard(index), in: visibleFrames)
                XCTAssertTrue(panel.contains(card), sizeDescription(size))
                let visibleOptions = try frame("landing.optionsViewport", in: visibleFrames)
                XCTAssertGreaterThanOrEqual(card.minY, visibleOptions.minY - 0.5, sizeDescription(size))
                XCTAssertLessThanOrEqual(card.maxY, visibleOptions.maxY + 0.5, sizeDescription(size))
                XCTAssertEqual(action, try frame(LayoutProbeID.landingActionButton, in: visibleFrames))
                XCTAssertEqual(footer, try frame(LayoutProbeID.landingFooter, in: visibleFrames))
            }
            if size.height < 520 {
                // The outer page and footer stay fixed; only options scroll.
                let visibleFooter = try frame(LayoutProbeID.landingFooter, in: visibleFrames)
                let viewport = try frame(LayoutProbeID.pageViewport, in: visibleFrames)
                XCTAssertLessThanOrEqual(visibleFooter.maxY, viewport.maxY + 1, sizeDescription(size))
                XCTAssertGreaterThanOrEqual(visibleFooter.minY, viewport.minY, sizeDescription(size))
            }
        }
    }

    func testRuntimeStatesKeepPanelsAndLongPathsStableAcrossWindowSizes() async throws {
        let sizes = [CGSize(width: 1024, height: 734), CGSize(width: 604, height: 490), CGSize(width: 473, height: 360)]
        let legacyRequired: Set<String> = [LayoutProbeID.smartScanHeader, LayoutProbeID.runtimePanel,
            LayoutProbeID.runtimeLocation, LayoutProbeID.runtimeViewport, LayoutProbeID.pageViewport, LayoutProbeID.smartScanFooter]
        let lightfieldRequired: Set<String> = ["lightfield.title", "lightfield.content", "lightfield.primary",
            "lightfield.status", "lightfield.progress.viewport", LayoutProbeID.runtimeLocation, LayoutProbeID.pageViewport]
        for module in [ReviewFilter.overview, .green, .devCaches] {
            let required = module == .green ? lightfieldRequired : legacyRequired
            let fixture = RuntimeLayoutFixture()
            let theme = ModuleThemeCatalog.theme(for: module)
            let root = AdaptivePageViewport(resetID: module) {
                ZStack {
                    ModuleBackground(theme: theme)
                    RuntimeLayoutFixtureView(fixture: fixture, module: module)
                }
                .environment(\.moduleTheme, theme)
            }
            let host = AppKitLayoutHost(rootView: root, contentSize: sizes[0])
            defer { host.close() }
            for size in sizes {
                host.resize(to: size)
                var baseline: [String: CGRect]?
                for (index, scenario) in [DebugScanPresentationScenario.preparing, .multiStage, .stageFailed, .completed, .long].enumerated() {
                    var progress = scenario.progress
                    if index == 1 {
                        progress.currentPath = "/Users/demo/" + String(repeating: "一个非常长的扫描目录/", count: 20) + "cache.db"
                    }
                    fixture.progress = progress
                    fixture.isFinalizing = index == 3
                    fixture.isCancelling = index == 4
                    var frames = try await host.waitForFrames(required: required)
                    if module == .green {
                        let panel = try frame("lightfield.content", in: frames)
                        let viewport = try frame("lightfield.progress.viewport", in: frames)
                        let title = try frame("lightfield.title", in: frames)
                        let primary = try frame("lightfield.primary", in: frames)
                        let footer = try frame("lightfield.status", in: frames)
                        var location = try frame(LayoutProbeID.runtimeLocation, in: frames)
                        if location.minY < viewport.minY - 0.5 || location.maxY > viewport.maxY + 0.5 {
                            let revision = host.recorder.revision
                            let scrolled = try host.scrollOptionIntoView(location, viewport: viewport)
                            frames = try await host.waitForFrames(required: required,
                                afterRevision: scrolled ? revision : nil)
                            location = try frame(LayoutProbeID.runtimeLocation, in: frames)
                        }
                        XCTAssertLessThanOrEqual(location.width, panel.width + 0.5, "\(module) / \(scenario) / \(size)")
                        XCTAssertGreaterThanOrEqual(location.minX, panel.minX - 0.5)
                        XCTAssertLessThanOrEqual(location.maxX, panel.maxX + 0.5)
                        XCTAssertGreaterThanOrEqual(location.minY, viewport.minY - 0.5)
                        XCTAssertLessThanOrEqual(location.maxY, viewport.maxY + 0.5)
                        XCTAssertGreaterThanOrEqual(location.height, 15)
                        XCTAssertLessThanOrEqual(location.height, 24)
                        XCTAssertLessThanOrEqual(title.maxY, panel.minY + 1)
                        XCTAssertLessThanOrEqual(viewport.maxY, primary.minY + 1)
                        XCTAssertGreaterThan(viewport.height, 80)
                        XCTAssertLessThanOrEqual(primary.maxY, footer.minY + 1)
                        XCTAssertLessThanOrEqual(footer.maxY, try frame(LayoutProbeID.pageViewport, in: frames).maxY + 1)
                        if let baseline {
                            let initial = try frame("lightfield.content", in: baseline)
                            XCTAssertEqual(panel.width, initial.width, accuracy: 1)
                            XCTAssertEqual(panel.minX, initial.minX, accuracy: 1)
                            XCTAssertEqual(panel.minY, initial.minY, accuracy: 3)
                            XCTAssertEqual(footer, try frame("lightfield.status", in: baseline))
                        } else { baseline = frames }
                        try host.captureRuntimeFixtureIfRequested(name: "\(module.rawValue)-\(Int(size.width))x\(Int(size.height))-\(scenario.rawValue).png")
                        continue
                    }
                    let panel = try frame(LayoutProbeID.runtimePanel, in: frames)
                    let location = try frame(LayoutProbeID.runtimeLocation, in: frames)
                    let header = try frame(LayoutProbeID.smartScanHeader, in: frames)
                    let footer = try frame(LayoutProbeID.smartScanFooter, in: frames)
                    // D53 §2.3: live pages use the regular or compact PageHero;
                    // D64: the title keeps its form height after deleting the decorative tile.
                    let form = PageLayout.resolve(size: size).heroForm(for: .tool)
                    XCTAssertGreaterThanOrEqual(header.height, form.titleHeaderHeight)
                    XCTAssertTrue(panel.contains(location), "\(module) / \(scenario) / \(size)")
                    XCTAssertEqual(location.height, 20, accuracy: 1)
                    XCTAssertLessThanOrEqual(header.maxY, panel.minY + 1)
                    let viewport = try frame(LayoutProbeID.runtimeViewport, in: frames)
                    XCTAssertLessThanOrEqual(viewport.maxY, footer.minY + 1)
                    XCTAssertLessThanOrEqual(header.maxY, viewport.minY + 1)
                    XCTAssertGreaterThan(viewport.height, 80)
                    XCTAssertLessThanOrEqual(footer.maxY, try frame(LayoutProbeID.pageViewport, in: frames).maxY + 1)
                    // Main-window cards grow with real stage rows inside one clipped
                    // viewport; width, origin and the separate footer remain stable.
                    if let baseline {
                        let initial = try frame(LayoutProbeID.runtimePanel, in: baseline)
                        XCTAssertEqual(panel.width, initial.width, accuracy: 1)
                        XCTAssertEqual(panel.minX, initial.minX, accuracy: 1)
                        XCTAssertEqual(panel.minY, initial.minY, accuracy: 3)
                        XCTAssertEqual(footer, try frame(LayoutProbeID.smartScanFooter, in: baseline))
                    } else { baseline = frames }
                    try host.captureRuntimeFixtureIfRequested(name: "\(module.rawValue)-\(Int(size.width))x\(Int(size.height))-\(scenario.rawValue).png")
                }
            }
        }
    }

    /// Full production execution and report pages, with inert callbacks and
    /// controlled reports. This proves layout, never a cleanup on user files.
    func testCleanupExecutionAndTerminalPagesKeepActionsInTheViewport() async throws {
        let store = try makeSmartScanContext(scanGate: LayoutCleanupScanGate()).scanStore
        let theme = ReviewFilter.green.moduleTheme
        let progress = CleanupExecutionProgress(planID: CleanPlanID(), processedItemCount: 8,
            totalItemCount: 12, movedItemCount: 6, skippedItemCount: 1, failedItemCount: 1, currentRuleID: "fixture.cache")
        var pages: [(String, AnyView)] = [
            ("preflight", AnyView(SmartScanCleanupProgressPage(store: store, progress: nil, isPreflight: true))),
            ("executing", AnyView(SmartScanCleanupProgressPage(store: store, progress: progress, onCancel: {}))),
            ("verifying", AnyView(SmartScanCleanupProgressPage(store: store, progress: progress, isVerifying: true))),
            ("stopping", AnyView(SmartScanCleanupProgressPage(store: store, progress: progress, isCancelling: true, onCancel: {})))
        ]
        for outcome in [CleanReportOutcome.completed, .partiallyCompleted, .cancelled, .failed] {
            let moved = outcome == .failed ? 0 : 6
            let report = CleanReport(id: UUID(), planID: CleanPlanID(), sessionID: ScanSessionID(),
                rulesVersion: "layout-fixture", disposition: .trash, scanWasPartial: false,
                startedAt: Date(), completedAt: Date(), outcome: outcome, items: [],
                summary: CleanReportSummary(requestedItemCount: 6, movedItemCount: moved,
                    skippedItemCount: outcome == .partiallyCompleted ? 1 : 0,
                    failedItemCount: outcome == .failed ? 6 : 0,
                    notProcessedItemCount: outcome == .cancelled ? 2 : 0,
                    unverifiedMoveCount: 0, plannedBytes: 8_000_000_000,
                    movedToRecoverableLocationBytes: Int64(moved) * 1_000_000_000,
                    reclaimableAfterEmptyingTrashBytes: Int64(moved) * 1_000_000_000,
                    permanentlyFreedBytes: 0, availableSpaceDeltaBytes: nil))
            pages.append((outcome.rawValue, AnyView(SmartScanCleanupCompletedPage(store: store, report: report, onDone: {}))))
        }
        // Skipped and failed rows are listed with their reasons; a Trash
        // deletion is reported apart from moves.
        let issueRows: [CleanReportItem] = [
            CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: "fixture.cache",
                sourcePath: "/DebugFixture/Library/Caches/com.example.running",
                estimatedBytes: 1_000_000, outcome: .skipped(.relatedAppStillRunning)),
            CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: "fixture.cache",
                sourcePath: "/DebugFixture/Library/Caches/" + String(repeating: "很长的名称", count: 12),
                estimatedBytes: 1_000_000, outcome: .failed(CleanFailure(code: .trashMoveFailed, detailCode: "permission-denied"))),
            CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: "trash.user-trash",
                sourcePath: "/DebugFixture/.Trash/old.bin", estimatedBytes: 2_000_000,
                outcome: .deleted(CleanupDeletionReceipt(originalPath: "/DebugFixture/.Trash/old.bin",
                    deletedIdentity: FileIdentity(deviceID: 1, inode: 2, entryKind: .regularFile, creationTimeNanoseconds: 3),
                    deletedAt: Date()))),
        ]
        let issuesReport = CleanReport(id: UUID(), planID: CleanPlanID(), sessionID: ScanSessionID(),
            rulesVersion: "layout-fixture", disposition: .trash, scanWasPartial: false,
            startedAt: Date(), completedAt: Date(), outcome: .partiallyCompleted, items: issueRows,
            summary: CleanReportSummary(requestedItemCount: 3, movedItemCount: 0,
                skippedItemCount: 1, failedItemCount: 1, notProcessedItemCount: 0,
                unverifiedMoveCount: 0, plannedBytes: 4_000_000,
                movedToRecoverableLocationBytes: 0, reclaimableAfterEmptyingTrashBytes: 0,
                permanentlyFreedBytes: 2_000_000, availableSpaceDeltaBytes: nil, deletedItemCount: 1))
        pages.append(("partial-with-issues", AnyView(SmartScanCleanupCompletedPage(store: store, report: issuesReport, onDone: {}))))
        for scheme in [ColorScheme.dark, .light] {
            for (name, page) in pages {
                let root = AdaptivePageViewport {
                    ZStack { ModuleBackground(theme: theme); page }
                        .environment(\.moduleTheme, theme).preferredColorScheme(scheme)
                }
                let host = AppKitLayoutHost(rootView: root, contentSize: CGSize(width: 1024, height: 734))
                defer { host.close() }
                for size in [CGSize(width: 1024, height: 734), CGSize(width: 604, height: 490), CGSize(width: 473, height: 360)] {
                    host.resize(to: size)
                    let frames = try await host.waitForFrames(required: [LayoutProbeID.runtimePanel,
                        LayoutProbeID.runtimeViewport, LayoutProbeID.smartScanHeader,
                        LayoutProbeID.smartScanFooter, LayoutProbeID.pageViewport])
                    let viewport = try frame(LayoutProbeID.pageViewport, in: frames)
                    let footer = try frame(LayoutProbeID.smartScanFooter, in: frames)
                    XCTAssertLessThanOrEqual(footer.maxY, viewport.maxY + 1, "\(name) / \(size)")
                    XCTAssertGreaterThanOrEqual(footer.minY, viewport.minY, "\(name) / \(size)")
                    XCTAssertLessThanOrEqual(try frame(LayoutProbeID.runtimeViewport, in: frames).maxY, footer.minY + 1)
                    XCTAssertLessThanOrEqual(try frame(LayoutProbeID.runtimePanel, in: frames).maxX, viewport.maxX + 1)
                    try host.captureRuntimeFixtureIfRequested(name: "cleanup-\(name)-\(scheme)-\(Int(size.width))x\(Int(size.height)).png")
                }
            }
        }
    }

    func testFullUpdatePagesRenderEverySupportedStateWithoutRunningUpdates() async throws {
        let store = try makeSmartScanContext(scanGate: LayoutCleanupScanGate()).scanStore
        let theme = ReviewFilter.updater.moduleTheme
        for scenario in DebugAppUpdatePresentationFixture.Scenario.allCases {
            store.installDebugAppUpdatePresentationFixture(scenario)
            let root = AdaptivePageViewport {
                ZStack(alignment: .top) { ModuleBackground(theme: theme); AppUpdaterView(store: store) }
                    .environment(\.moduleTheme, theme).preferredColorScheme(.dark)
            }
            let host = AppKitLayoutHost(rootView: root, contentSize: CGSize(width: 1024, height: 734))
            defer { host.close() }
            for size in [CGSize(width: 1024, height: 734), CGSize(width: 604, height: 490)] {
                host.resize(to: size)
                var required: Set<String> = [LayoutProbeID.pageViewport]
                if scenario == .managing { required.insert("appUpdateManager.footer") }
                let frames = try await host.waitForFrames(required: required)
                if scenario == .managing {
                    let footer = try frame("appUpdateManager.footer", in: frames)
                    let viewport = try frame(LayoutProbeID.pageViewport, in: frames)
                    XCTAssertLessThanOrEqual(footer.maxY, viewport.maxY + 1)
                    XCTAssertGreaterThanOrEqual(footer.minY, viewport.minY)
                }
                XCTAssertFalse(store.canRequestOneClickAppUpdates)
                XCTAssertFalse(store.canRefreshAppUpdates)
                try host.captureRuntimeFixtureIfRequested(name: "updater-\(scenario.rawValue)-\(Int(size.width))x\(Int(size.height)).png")
            }
        }
    }

    func testCancelledUpdateScanKeepsRuntimeLayoutAndActionsReachable() async throws {
        let theme = ReviewFilter.updater.moduleTheme
        let root = AdaptivePageViewport {
            ZStack {
                ModuleBackground(theme: theme)
                AppUpdateScanCancelledPage(canScan: true, onScan: {}, onBack: {})
            }
            .environment(\.moduleTheme, theme)
        }
        let host = AppKitLayoutHost(rootView: root, contentSize: CGSize(width: 1024, height: 734))
        defer { host.close() }
        let required: Set<String> = [LayoutProbeID.runtimePanel, LayoutProbeID.runtimeViewport, LayoutProbeID.smartScanHeader, LayoutProbeID.smartScanFooter, LayoutProbeID.pageViewport]
        for size in [CGSize(width: 1024, height: 734), CGSize(width: 604, height: 490), CGSize(width: 473, height: 360)] {
            host.resize(to: size)
            let frames = try await host.waitForFrames(required: required)
            let panel = try frame(LayoutProbeID.runtimePanel, in: frames)
            XCTAssertLessThanOrEqual(try frame(LayoutProbeID.smartScanHeader, in: frames).maxY, panel.minY)
            XCTAssertLessThanOrEqual(try frame(LayoutProbeID.runtimeViewport, in: frames).maxY, try frame(LayoutProbeID.smartScanFooter, in: frames).minY)
            XCTAssertLessThanOrEqual(try frame(LayoutProbeID.smartScanFooter, in: frames).maxY, try frame(LayoutProbeID.pageViewport, in: frames).maxY)
            try host.captureRuntimeFixtureIfRequested(name: "updater-cancelled-\(Int(size.width))x\(Int(size.height)).png")
            if size.height < 520 {
                // D53 §2.2: no fixed 520 pt page; scroll only when the page
                // is taller than its viewport, then the footer must be in it.
                var reachable = frames
                if host.pageScrollIsNeeded() {
                    let revision = host.recorder.revision
                    try host.scrollPageToBottom()
                    reachable = try await host.waitForFrames(required: required, afterRevision: revision)
                }
                let footer = try frame(LayoutProbeID.smartScanFooter, in: reachable)
                let viewport = try frame(LayoutProbeID.pageViewport, in: reachable)
                XCTAssertLessThanOrEqual(footer.maxY, viewport.maxY + 1)
                XCTAssertGreaterThanOrEqual(footer.minY, viewport.minY)
            }
        }
    }

    func testSmartScanOneButtonIdleAndActivePagesKeepWindowStable() async throws {
        let size = CGSize(width: 980, height: 680)
        let scanGate = LayoutCleanupScanGate()
        let context = try makeSmartScanContext(scanGate: scanGate)
        let host = makeHost(context: context, contentSize: size)
        defer {
            context.scanStore.cancelMainScan()
            Task { await scanGate.finish() }
            host.close()
        }
        let required = Set([
            LayoutProbeID.smartScanRoot,
            LayoutProbeID.smartScanHeader,
            LayoutProbeID.smartScanFooter,
            LayoutProbeID.smartScanSidebar,
        ])

        _ = try await host.waitForFrames(required: [LayoutProbeID.smartScanSidebar])
        let initialWindowFrame = host.window.frame

        context.scanStore.startScan()
        try await waitForSmartScanState(.preparing, store: context.scanStore)
        let preparingFrames = try await host.waitForFrames(required: required)

        await scanGate.advance()
        try await waitForProgressRule("layout.cache", store: context.scanStore)
        let scanningFrames = try await host.waitForFrames(required: required)

        await scanGate.advance()
        try await waitForSmartScanState(.results, store: context.scanStore)
        let resultFrames = try await host.waitForFrames(required: required)

        XCTAssertEqual(host.window.frame, initialWindowFrame)
        for frames in [scanningFrames, resultFrames] {
            assertStableSmartScanGeometry(
                baseline: preparingFrames,
                actual: frames,
                tolerance: 1
            )
        }

        let riskIDs = [CleanupRisk.safe, .reviewOnly, .protected].map(LayoutProbeID.cleanupRiskSummary)
        for resultSize in [CGSize(width: 1280, height: 740), CGSize(width: 820, height: 520), CGSize(width: 677, height: 390)] {
            let revision = host.recorder.revision
            host.resize(to: resultSize)
            let frames = try await host.waitForFrames(required: Set(riskIDs + [LayoutProbeID.smartScanContent]), afterRevision: revision)
            let content = try frame(LayoutProbeID.smartScanContent, in: frames)
            let cards = try riskIDs.map { try frame($0, in: frames) }
            for card in cards {
                XCTAssertGreaterThanOrEqual(card.minX, content.minX - 1)
                XCTAssertLessThanOrEqual(card.maxX, content.maxX + 1)
            }
            if resultSize.width == 1280 {
                XCTAssertEqual(cards[0].minX, content.minX, accuracy: 1)
                // The shell includes a legacy scrollbar gutter. Compare the
                // cards with the actual clip view, not the scrollbar's edge.
                let viewport = try XCTUnwrap(host.scrollContentFrame(matching: content))
                XCTAssertEqual(cards[2].maxX, viewport.maxX, accuracy: 1)
                XCTAssertEqual(cards[0].width, cards[2].width, accuracy: 1)
            }
            try host.captureRuntimeFixtureIfRequested(name: "results-\(Int(resultSize.width))x\(Int(resultSize.height)).png")
        }
    }

    private var baseProbeIDs: Set<String> {
        [
            LayoutProbeID.contentLayout,
            LayoutProbeID.workspace,
            LayoutProbeID.picker
        ]
    }

    private var privacyProbeIDs: Set<String> {
        [
            LayoutProbeID.contentLayout,
            LayoutProbeID.workspace,
            LayoutProbeID.privacy
        ]
    }

    private func makeContext(fixture: PrivacyLayoutFixture) async throws -> LayoutContext {
        let scanner = LayoutBrowserPrivacyScanner(response: fixture.response)
        let browserPrivacyStore = BrowserPrivacyStore(scanner: scanner)
        switch fixture {
        case .idle:
            break
        case .scanning:
            browserPrivacyStore.startScan()
            guard browserPrivacyStore.state == .scanning else {
                throw LayoutHarnessError.unexpectedPrivacyState(browserPrivacyStore.state)
            }
        case .completedEmpty, .completedSmall, .completedLarge:
            browserPrivacyStore.startScan()
            try await waitForPrivacyState(.completed, store: browserPrivacyStore)
            guard browserPrivacyStore.state == .completed else {
                throw LayoutHarnessError.unexpectedPrivacyState(browserPrivacyStore.state)
            }
        }

        let heavyWorkCoordinator = HeavyWorkCoordinator()
        let heavyWorkActivityStore = HeavyWorkActivityStore(
            coordinator: heavyWorkCoordinator
        )
        let scanStore = try ScanStore.makeForTests(for: self,
            heavyWorkCoordinator: heavyWorkCoordinator,
            heavyWorkActivityStore: heavyWorkActivityStore,
            restoreSavedAccessOperation: {},
            loadScanReadinessSummary: { ScanReadinessSummary(items: []) },
            historyLoader: EmptyLayoutHistoryLoader()
        )
        scanStore.didCompleteInitialPermissionCheck = true
        scanStore.result = makeScanResult()
        scanStore.showFilter(.privacy)

        return LayoutContext(
            scanStore: scanStore,
            browserPrivacyStore: browserPrivacyStore,
            computerHealthStore: ComputerHealthStore(probe: TestUnavailableComputerHealthProbe(), batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController()),
            networkSpeedTestStore: NetworkSpeedTestStore(
                heavyWorkCoordinator: heavyWorkCoordinator,
                heavyWorkActivityStore: heavyWorkActivityStore
            ),
            macBenchmarkStore: makeMacBenchmarkStore(),
            heavyWorkActivityStore: heavyWorkActivityStore,
            scanner: scanner
        )
    }

    private func makeSmartScanContext(scanGate: LayoutCleanupScanGate) throws -> LayoutContext {
        let scanner = LayoutBrowserPrivacyScanner(response: PrivacyLayoutFixture.idle.response)
        let browserPrivacyStore = BrowserPrivacyStore(scanner: scanner)
        let heavyWorkCoordinator = HeavyWorkCoordinator()
        let heavyWorkActivityStore = HeavyWorkActivityStore(
            coordinator: heavyWorkCoordinator
        )
        let rules = LayoutCleanupScanGate.ruleSet
        // r2-live-fixes-2 review P2-1: the completed scan's history stays
        // private to the test.
        let historyDefaults = ScanHistoryTestDefaults.make(for: self)
        let scanStore = try ScanStore.makeForTests(for: self,
            heavyWorkCoordinator: heavyWorkCoordinator,
            heavyWorkActivityStore: heavyWorkActivityStore,
            restoreSavedAccessOperation: {},
            loadScanReadinessSummary: { ScanReadinessSummary(items: []) },
            historyLoader: EmptyLayoutHistoryLoader(),
            scanHistoryDefaults: historyDefaults,
            cleanupScanOperation: { request, progress in
                try await scanGate.scan(request: request, progress: progress)
            },
            cleanupRuleSetLoader: { rules }
        )
        scanStore.didCompleteInitialPermissionCheck = true
        scanStore.showFilter(.overview)

        return LayoutContext(
            scanStore: scanStore,
            browserPrivacyStore: browserPrivacyStore,
            computerHealthStore: ComputerHealthStore(probe: TestUnavailableComputerHealthProbe(), batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController()),
            networkSpeedTestStore: NetworkSpeedTestStore(
                heavyWorkCoordinator: heavyWorkCoordinator,
                heavyWorkActivityStore: heavyWorkActivityStore
            ),
            macBenchmarkStore: makeMacBenchmarkStore(),
            heavyWorkActivityStore: heavyWorkActivityStore,
            scanner: scanner
        )
    }

    private func makeMacBenchmarkStore() -> MacBenchmarkStore {
        let catalog = try! MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "layout-fixture",
            verifiedBaselines: []
        )
        return MacBenchmarkStore(
            service: LayoutMacBenchmarkService(),
            resultProcessor: MacBenchmarkResultProcessor(baselineCatalog: catalog),
            historyRepository: EmptyLayoutBenchmarkHistoryRepository(),
            v7PromotionRevocationDefaults: TestPreferenceDomain.make(for: self)
        )
    }

    private func makeHost(
        context: LayoutContext,
        contentSize: CGSize
    ) -> AppKitLayoutHost {
        _ = NSApplication.shared
        let content = ContentView(
            store: context.scanStore,
            computerHealthStore: context.computerHealthStore,
            networkSpeedTestStore: context.networkSpeedTestStore,
            macBenchmarkStore: context.macBenchmarkStore,
            macBenchmarkLeaderboardStore: BenchmarkV7LeaderboardStore(
                identityProvider: DefaultBenchmarkV7LeaderboardIdentityProvider(
                    defaults: TestPreferenceDomain.make(for: self)
                )
            ),
            heavyWorkActivityStore: context.heavyWorkActivityStore,
            browserPrivacyStore: context.browserPrivacyStore
        )
        .environment(\.locale, Locale(identifier: "zh-Hans"))

        return AppKitLayoutHost(rootView: content, contentSize: contentSize)
    }

    private func makeConceptLandingHost(contentSize: CGSize, responsive: Bool = false) -> AppKitLayoutHost {
        _ = NSApplication.shared
        let theme = ModuleThemeCatalog.theme(for: .protection)
        let content = ZStack {
            ModuleBackground(theme: theme)
            FileToolLandingPage(
                title: L10n.text("系统健康", "System Health"),
                subtitle: L10n.text(
                    "基于磁盘、电池与关键系统状态进行检查",
                    "Check disk, battery, and key system state"
                ),
                systemImage: ReviewFilter.healthHub.systemImage,
                configurationTitle: nil,
                actionTitle: L10n.text("开始健康检查", "Start Health Check"),
                actionDetail: "",
                actionSystemImage: "waveform.path.ecg",
                status: .neverScanned,
                trustText: L10n.text(
                    "只读检查 · 完成后再生成健康分",
                    "Read-only check · Health score is generated after completion"
                ),
                action: {}
            ) { EmptyView() }
        }
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .environment(\.moduleTheme, theme)

        let root = responsive ? AnyView(AdaptivePageViewport { content }) : AnyView(
            content.environment(\.windowLayoutMetrics, WindowLayoutMetrics(contentSize: contentSize))
        )
        return AppKitLayoutHost(rootView: root, contentSize: contentSize)
    }

    private func assertWorkspaceTopIsInsideContent(
        _ frames: [String: CGRect],
        fixture: PrivacyLayoutFixture,
        size: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let content = try frame(LayoutProbeID.contentLayout, in: frames)
            let workspace = try frame(LayoutProbeID.workspace, in: frames)

            XCTAssertGreaterThanOrEqual(
                workspace.minY,
                content.minY - 1,
                "\(fixture) 工作区进入标题栏：\(sizeDescription(size))；content=\(content)，workspace=\(workspace)",
                file: file,
                line: line
            )
            if let privacy = frames[LayoutProbeID.privacy] {
                XCTAssertGreaterThanOrEqual(
                    privacy.minY,
                    content.minY - 1,
                    "\(fixture) 隐私区域进入标题栏：\(sizeDescription(size))；content=\(content)，privacy=\(privacy)",
                    file: file,
                    line: line
                )

                if let picker = frames[LayoutProbeID.picker] {
                    XCTAssertGreaterThanOrEqual(
                        picker.minY,
                        content.minY - 1,
                        "\(fixture) 分段选择器进入标题栏：\(sizeDescription(size))；content=\(content)，picker=\(picker)",
                        file: file,
                        line: line
                    )
                    XCTAssertGreaterThanOrEqual(
                        privacy.minY,
                        picker.maxY - 1,
                        "\(fixture) 隐私区域覆盖分段选择器：\(sizeDescription(size))；picker=\(picker)，privacy=\(privacy)",
                        file: file,
                        line: line
                    )
                }
            }
        } catch {
            XCTFail("缺少真实布局探针：\(error)", file: file, line: line)
        }
    }

    private func waitForPrivacyState(
        _ expectedState: BrowserPrivacyScanState,
        store: BrowserPrivacyStore
    ) async throws {
        for _ in 0..<240 {
            if store.state == expectedState {
                return
            }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        throw LayoutHarnessError.privacyStateDidNotSettle(
            expected: expectedState,
            actual: store.state
        )
    }

    private func waitForSmartScanState(
        _ expectedState: SmartScanPresentationState,
        store: ScanStore
    ) async throws {
        for _ in 0..<800 {
            if store.scanPresentationState == expectedState { return }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        throw LayoutHarnessError.smartScanStateDidNotSettle(
            expected: expectedState,
            actual: store.scanPresentationState
        )
    }

    private func waitForProgressRule(_ ruleID: String, store: ScanStore) async throws {
        for _ in 0..<400 {
            if store.mainScanProgress?.groups.contains(where: {
                $0.id == ruleID && $0.state == .scanning
            }) == true {
                return
            }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        throw LayoutHarnessError.missingProgressRule(ruleID)
    }

    private func assertStableSmartScanGeometry(
        baseline: [String: CGRect],
        actual: [String: CGRect],
        tolerance: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let baselineRoot = try frame(LayoutProbeID.smartScanRoot, in: baseline)
            let actualRoot = try frame(LayoutProbeID.smartScanRoot, in: actual)
            let baselineHeader = try frame(LayoutProbeID.smartScanHeader, in: baseline)
            let actualHeader = try frame(LayoutProbeID.smartScanHeader, in: actual)
            let baselineFooter = try frame(LayoutProbeID.smartScanFooter, in: baseline)
            let actualFooter = try frame(LayoutProbeID.smartScanFooter, in: actual)
            let baselineSidebar = try frame(LayoutProbeID.smartScanSidebar, in: baseline)
            let actualSidebar = try frame(LayoutProbeID.smartScanSidebar, in: actual)

            XCTAssertEqual(
                actualRoot.minY,
                baselineRoot.minY,
                accuracy: tolerance,
                "Smart Scan 根视图上沿发生漂移",
                file: file,
                line: line
            )
            XCTAssertEqual(
                actualRoot.height,
                baselineRoot.height,
                accuracy: tolerance,
                "Smart Scan 根视图高度发生漂移",
                file: file,
                line: line
            )
            XCTAssertEqual(
                actualHeader.minY,
                baselineHeader.minY,
                accuracy: tolerance,
                "Smart Scan 标题上沿发生漂移",
                file: file,
                line: line
            )
            XCTAssertEqual(
                actualFooter.maxY,
                baselineFooter.maxY,
                accuracy: tolerance,
                "Smart Scan 底部操作区发生漂移",
                file: file,
                line: line
            )
            XCTAssertEqual(
                actualSidebar,
                baselineSidebar,
                "Smart Scan 侧栏尺寸或位置发生漂移",
                file: file,
                line: line
            )
        } catch {
            XCTFail("Smart Scan 布局探针缺失：\(error)", file: file, line: line)
        }
    }

    private func frame(
        _ id: String,
        in frames: [String: CGRect]
    ) throws -> CGRect {
        guard let frame = frames[id] else {
            throw LayoutHarnessError.missingProbe(id)
        }
        return frame
    }

    private func makeScanResult() -> ScanResult {
        let items = (0..<24).map { index in
            let isDevelopmentCache = index.isMultiple(of: 3)
            let path = "/Users/fixture/Library/Caches/LayoutFixture/\(index)"
            return StorageItem(
                id: path,
                title: isDevelopmentCache ? ".build-\(index)" : "Cache \(index)",
                path: path,
                sourceID: isDevelopmentCache ? "dev_caches" : "caches",
                groupTitle: "Layout Fixture",
                sizeBytes: Int64((index + 1) * 1_024),
                tier: .green,
                kind: isDevelopmentCache ? "Developer Cache" : "Cache",
                reason: "Deterministic hosted layout fixture",
                recommendation: "Review",
                risk: "Low",
                requiresClose: "None",
                trashPaths: [path],
                openPath: path,
                isDirectory: true,
                status: .available
            )
        }

        return ScanResult(
            generatedAt: Date(timeIntervalSince1970: 1_789_000_000),
            scanSeconds: 0.5,
            system: SystemSnapshot(
                osName: "macOS",
                build: "LayoutTest",
                arch: "arm64",
                user: "tester",
                home: PathSafety.homePath,
                filesystem: "APFS",
                purgeable: "",
                diskName: "Macintosh HD",
                diskTotalBytes: 1_000_000,
                diskUsedBytes: 500_000,
                diskFreeBytes: 500_000
            ),
            groups: [],
            items: items,
            deniedPaths: []
        )
    }

    private func sizeDescription(_ size: CGSize) -> String {
        "\(Int(size.width))×\(Int(size.height))"
    }
}

@MainActor
private final class RuntimeLayoutFixture: ObservableObject {
    @Published var progress = DebugScanPresentationScenario.preparing.progress
    @Published var isFinalizing = false
    @Published var isCancelling = false
}

private struct RuntimeLayoutFixtureView: View {
    @ObservedObject var fixture: RuntimeLayoutFixture
    let module: ReviewFilter

    var body: some View {
        SmartScanScanningPage(progress: fixture.progress, module: module,
            isFinalizing: fixture.isFinalizing, canCancel: !fixture.isCancelling,
            isCancelling: fixture.isCancelling, onCancel: {})
    }
}

@MainActor
private final class LayoutFixtureWindow: NSWindow {
    // Match CalibrationFixtureWindow: test logical sizes must not be
    // clamped to the current display's visible frame.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class AppKitLayoutHost {
    let recorder = LayoutFrameRecorder()
    let window: NSWindow
    private let hostingController: NSHostingController<AnyView>
    private var isClosing = false

    init<Content: View>(rootView: Content, contentSize: CGSize) {
        let observedRoot = AnyView(
            rootView
                .onPreferenceChange(LayoutFramePreferenceKey.self) { [weak recorder] frames in
                    Task { @MainActor [weak recorder] in
                        recorder?.record(frames)
                    }
                }
        )
        hostingController = NSHostingController(rootView: observedRoot)
        hostingController.sizingOptions = []

        window = LayoutFixtureWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentViewController = hostingController
        window.setContentSize(contentSize)
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        // Match the V0 calibration host: an actual displayed fixture lets
        // SwiftUI finish transitions and publish its native layout/AX state.
        window.orderFront(nil)
        window.displayIfNeeded()
    }

    func captureRuntimeFixtureIfRequested(name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_RUNTIME_SNAPSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = hostingController.view
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name))
    }

    func show() {
        window.center()
        window.orderFront(nil)
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func resize(to size: CGSize) {
        window.setContentSize(size)
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        if let scroll = pageScrollView() {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// Whether the page scroll view holds more than it shows.
    func pageScrollIsNeeded() -> Bool {
        guard let scroll = pageScrollView(), let document = scroll.documentView else { return false }
        return document.bounds.height > scroll.contentView.bounds.height + 0.5
    }

    func scrollPageToBottom() throws {
        let scroll = try XCTUnwrap(pageScrollView())
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(
            x: 0,
            y: max(0, document.bounds.height - scroll.contentView.bounds.height)
        ))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func scrollPreviewToTrailingEdge() throws {
        func find(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.hasHorizontalScroller,
               let document = scroll.documentView,
               document.bounds.width > scroll.contentView.bounds.width + 0.5 {
                return scroll
            }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        let scroll = try XCTUnwrap(window.contentView.flatMap { find(in: $0) })
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertEqual(document.bounds.width, 304, accuracy: 0.5)
        scroll.contentView.scroll(to: NSPoint(
            x: document.bounds.width - scroll.contentView.bounds.width,
            y: scroll.contentView.bounds.origin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func pageScrollView() -> NSScrollView? {
        func find(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return window.contentView.flatMap { find(in: $0) }
    }

    func scrollContentFrame(matching shell: CGRect) -> CGRect? {
        func find(in view: NSView) -> CGRect? {
            if let scroll = view as? NSScrollView {
                let outer = scroll.convert(scroll.bounds, to: hostingController.view)
                if abs(outer.minX - shell.minX) <= 1 && abs(outer.width - shell.width) <= 1 {
                    return scroll.contentView.convert(scroll.contentView.bounds, to: hostingController.view)
                }
            }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return find(in: hostingController.view)
    }

    func scrollOptionIntoView(_ target: CGRect, viewport: CGRect) throws -> Bool {
        func find(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView {
                let outer = scroll.convert(scroll.bounds, to: hostingController.view)
                if abs(outer.minX - viewport.minX) <= 1 && abs(outer.width - viewport.width) <= 1 {
                    return scroll
                }
            }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        let scroll = try XCTUnwrap(find(in: hostingController.view))
        let document = try XCTUnwrap(scroll.documentView)
        let current = scroll.contentView.bounds.origin.y
        let delta: CGFloat
        if target.minY < viewport.minY { delta = target.minY - viewport.minY }
        else if target.maxY > viewport.maxY { delta = target.maxY - viewport.maxY }
        else { return false }
        let next = min(max(0, document.bounds.height - scroll.contentView.bounds.height), max(0, current + delta))
        guard abs(next - current) > 0.5 else { return false }
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: next))
        scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }

    func waitForFrames(
        required: Set<String>,
        afterRevision: Int? = nil,
        privacyProbeExpected: Bool? = nil,
        stablePassesRequired: Int = 3,
        expectedLandingSize: CGSize? = nil,
        expectedRootProbe: String = LayoutProbeID.landingRoot
    ) async throws -> [String: CGRect] {
        var stableFrames: [String: CGRect]?
        var stablePasses = 0

        for _ in 0..<120 {
            hostingController.view.needsLayout = true
            hostingController.view.layoutSubtreeIfNeeded()
            window.contentView?.needsLayout = true
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()

            var frames = recorder.frames
            frames[LayoutProbeID.contentLayout] = hostingController.view.bounds
            let hasRequiredFrames = required.isSubset(of: Set(frames.keys))
            let passedRevision = afterRevision.map { recorder.revision > $0 } ?? true
            let viewportMatches: Bool
            if let expectedLandingSize, let root = frames[expectedRootProbe] {
                viewportMatches = abs(root.width - expectedLandingSize.width) < 0.5
                    && abs(root.height - expectedLandingSize.height) < 0.5
                    && abs(hostingController.view.bounds.width - expectedLandingSize.width) < 0.5
                    && abs(hostingController.view.bounds.height - expectedLandingSize.height) < 0.5
            } else { viewportMatches = expectedLandingSize == nil }
            let privacyExpectationMet: Bool
            if let privacyProbeExpected {
                privacyExpectationMet = (frames[LayoutProbeID.privacy] != nil)
                    == privacyProbeExpected
            } else {
                privacyExpectationMet = true
            }

            if hasRequiredFrames, passedRevision, viewportMatches, privacyExpectationMet {
                if frames == stableFrames {
                    stablePasses += 1
                } else {
                    stableFrames = frames
                    stablePasses = 1
                }
                if stablePasses >= max(1, stablePassesRequired) {
                    return frames
                }
            } else {
                stableFrames = nil
                stablePasses = 0
            }

            try await Task.sleep(for: .milliseconds(5))
        }

        let failure = LayoutHarnessError.framesDidNotSettle(
            required: required,
            available: Set(recorder.frames.keys).union([LayoutProbeID.contentLayout]),
            revision: recorder.revision
        )
        // Preserve the missing IDs even if native teardown raises a second
        // error while XCTest unwinds this fixture.
        FileHandle.standardError.write(Data("Native fixture failure: \(failure); expectedLandingSize=\(String(describing: expectedLandingSize)); nativeBounds=\(hostingController.view.bounds); expectedRootProbe=\(expectedRootProbe); root=\(String(describing: recorder.frames[expectedRootProbe]))\n".utf8))
        throw failure
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        window.orderOut(nil)
        Task { @MainActor [window, hostingController, recorder] in
            await Task.yield()
            hostingController.rootView = AnyView(EmptyView())
            hostingController.view.layoutSubtreeIfNeeded()
            await Task.yield()
            window.contentViewController = nil
            window.close()
            _ = recorder
        }
    }
}

@MainActor
private final class LayoutFrameRecorder {
    private(set) var frames: [String: CGRect] = [:]
    private(set) var revision = 0

    func record(_ frames: [String: CGRect]) {
        self.frames = frames
        revision &+= 1
    }
}

@MainActor
private struct LayoutContext {
    let scanStore: ScanStore
    let browserPrivacyStore: BrowserPrivacyStore
    let computerHealthStore: ComputerHealthStore
    let networkSpeedTestStore: NetworkSpeedTestStore
    let macBenchmarkStore: MacBenchmarkStore
    let heavyWorkActivityStore: HeavyWorkActivityStore
    let scanner: LayoutBrowserPrivacyScanner
}

private struct LayoutMacBenchmarkService: MacBenchmarkServicing {
    func run(
        profile: BenchmarkProfile,
        progress: @escaping @Sendable (MacBenchmarkProgress) async -> Void
    ) async -> MacBenchmarkRawResult {
        _ = profile
        _ = progress
        fatalError("The safe-cleanup layout fixture must never start a benchmark")
    }
}

private actor EmptyLayoutBenchmarkHistoryRepository: MacBenchmarkHistoryPersisting {
    func load() async -> [MacBenchmarkResult] { [] }
    func save(_ result: MacBenchmarkResult) async throws { _ = result }
}

private enum PrivacyLayoutFixture: CaseIterable, CustomStringConvertible {
    case idle
    case scanning
    case completedEmpty
    case completedSmall
    case completedLarge

    var response: LayoutBrowserPrivacyScanner.Response {
        switch self {
        case .idle, .scanning:
            return .suspended
        case .completedEmpty:
            return .immediate(Self.makeOutcome(count: 0, profileCount: 1))
        case .completedSmall:
            return .immediate(Self.makeOutcome(count: 2, profileCount: 1))
        case .completedLarge:
            return .immediate(Self.makeOutcome(count: 96, profileCount: 12))
        }
    }

    var description: String {
        switch self {
        case .idle: "idle"
        case .scanning: "scanning"
        case .completedEmpty: "completed-empty"
        case .completedSmall: "completed-small"
        case .completedLarge: "completed-large"
        }
    }

    static func makeOutcome(
        count: Int,
        profileCount: Int
    ) -> BrowserPrivacyScanOutcome {
        let browsers = [
            BrowserPrivacyBrowser(
                id: "safari",
                displayName: "Safari",
                engine: .safari,
                bundleIdentifier: "com.apple.Safari",
                version: nil
            ),
            BrowserPrivacyBrowser(
                id: "chrome",
                displayName: "Chrome",
                engine: .chromium,
                bundleIdentifier: "com.google.Chrome",
                version: nil
            ),
            BrowserPrivacyBrowser(
                id: "edge",
                displayName: "Edge",
                engine: .chromium,
                bundleIdentifier: "com.microsoft.Edge",
                version: nil
            ),
            BrowserPrivacyBrowser(
                id: "firefox",
                displayName: "Firefox",
                engine: .firefox,
                bundleIdentifier: "org.mozilla.firefox",
                version: nil
            ),
        ]
        let records = (0..<count).map { index in
            let browser = browsers[index % browsers.count]
            let profileIndex = index % max(1, profileCount)
            let domain = "private-history-\(index).example.test"
            return BrowserPrivacyRecord(
                id: UUID(),
                browser: browser,
                profileID: "Profile-\(profileIndex)-Long-Deterministic-Name",
                source: .history,
                url: nil,
                domain: domain,
                title: nil,
                searchKeyword: nil,
                visitedAt: Date(timeIntervalSince1970: 1_789_000_000 - Double(index * 60)),
                visitCount: index + 1,
                category: index.isMultiple(of: 5) ? .finance : .other,
                selectionConfidence: .medium,
                sizeBytes: nil
            )
        }
        let coverage = browsers.map { browser in
            BrowserPrivacyProviderCoverage(
                browser: browser,
                availability: .available,
                profileCount: max(1, profileCount),
                recordCount: records.count { $0.browser.id == browser.id },
                detail: nil
            )
        }
        return BrowserPrivacyScanOutcome(
            state: .completed,
            records: records,
            coverage: coverage
        )
    }
}

private actor LayoutCleanupScanGate {
    static let ruleSet = CleanupRuleSet(
        schemaVersion: 2,
        rulesVersion: "layout-smart-scan-v1",
        rules: [
            CleanupRule(
                id: "layout.cache",
                selectionPolicyVersion: 1,
                categoryID: "system",
                categoryTitleKey: "cleanup.category.system",
                titleKey: "cleanup.rule.userCaches.title",
                root: CleanupRuleRoot(kind: .homeRelative, path: "Library/Caches"),
                maximumDepth: 1,
                minimumAgeDays: 0,
                minimumBytes: 1,
                include: CleanupRuleMatch(
                    entryKinds: [.regularFile, .directory],
                    extensions: [],
                    nameMatcher: CleanupNameMatcher(mode: .any, values: [])
                ),
                exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
                cloudPolicy: .skipPlaceholder,
                risk: .safe,
                recommendation: .recommended,
                defaultSelection: .selected,
                executionEligibility: .eligible,
                measurementRequirement: .complete,
                allowsManualSelection: true,
                action: .moveToTrash,
                requiredClosedBundleIDs: [],
                reasonKey: "cleanup.rule.userCaches.reason"
            ),
        ]
    )

    private var waiter: CheckedContinuation<Void, Never>?
    private var permits = 0

    func scan(
        request: CleanupScanRequest,
        progress: @escaping CleanupScanProgressHandler
    ) async throws -> ScanSession {
        let startedAt = Date()
        await progress(snapshot(phase: .preparing, state: .pending, completed: 0))
        await waitForAdvance()
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(160))
        await progress(snapshot(
            phase: .enumerating,
            state: .scanning,
            completed: 0,
            currentRuleID: "layout.cache",
            currentPath: request.userHomeURL.appendingPathComponent("Library/Caches").path
        ))
        await waitForAdvance()
        try Task.checkCancellation()
        await progress(snapshot(phase: .finalizing, state: .clean, completed: 1))

        return ScanSession(
            id: ScanSessionID(),
            rulesVersion: Self.ruleSet.rulesVersion,
            startedAt: startedAt,
            completedAt: Date(),
            outcome: .complete,
            categories: [],
            issues: [],
            permissions: [],
            metrics: ScanMetrics(
                visitedEntryCount: 0,
                candidateCount: 0,
                deduplicatedIdentityCount: 0,
                estimatedCandidateBytes: 0,
                duration: Date().timeIntervalSince(startedAt)
            )
        )
    }

    func advance() {
        if let waiter {
            self.waiter = nil
            waiter.resume()
        } else {
            permits += 1
        }
    }

    func finish() {
        permits = 2
        let waiter = waiter
        self.waiter = nil
        waiter?.resume()
    }

    private func waitForAdvance() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiter = $0 }
    }

    private func snapshot(
        phase: CleanupScanPhase,
        state: CleanupScanRuleState,
        completed: Int,
        currentRuleID: String? = nil,
        currentPath: String? = nil
    ) -> CleanupScanProgress {
        CleanupScanProgress(
            phase: phase,
            currentRuleID: currentRuleID,
            currentRuleTitle: "User Caches",
            currentPath: currentPath,
            completedRuleCount: completed,
            totalRuleCount: 1,
            discoveredItemCount: 0,
            discoveredBytes: 0,
            groups: [
                CleanupScanProgress.GroupSummary(
                    id: "layout.cache",
                    title: "User Caches",
                    itemCount: 0,
                    bytes: 0,
                    risk: .safe,
                    state: state,
                    currentPath: currentPath
                ),
            ]
        )
    }
}

private actor LayoutBrowserPrivacyScanner: BrowserPrivacyScanning {
    enum Response: Sendable {
        case immediate(BrowserPrivacyScanOutcome)
        case suspended
    }

    private let response: Response
    private var scanInvocationCount = 0
    private var suspendedContinuation: CheckedContinuation<BrowserPrivacyScanOutcome, Never>?

    init(response: Response) {
        self.response = response
    }

    func scan() async throws -> BrowserPrivacyScanOutcome {
        scanInvocationCount += 1
        switch response {
        case let .immediate(outcome):
            return outcome
        case .suspended:
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(
                            returning: PrivacyLayoutFixture.makeOutcome(
                                count: 0,
                                profileCount: 1
                            )
                        )
                    } else {
                        suspendedContinuation = continuation
                    }
                }
            } onCancel: {
                Task {
                    await self.finishSuspended()
                }
            }
        }
    }

    func scanCount() -> Int {
        scanInvocationCount
    }

    func finishSuspended() {
        let continuation = suspendedContinuation
        suspendedContinuation = nil
        continuation?.resume(
            returning: PrivacyLayoutFixture.makeOutcome(
                count: 2,
                profileCount: 1
            )
        )
    }

}

private struct EmptyLayoutHistoryLoader: ScanStoreHistoryLoading {
    func load() async -> ScanStoreHistorySnapshot {
        ScanStoreHistorySnapshot(
            scanHistory: ScanHistorySummary(entries: []),
            cleanupHistory: CleanupHistorySummary(entries: [])
        )
    }
}

private enum LayoutHarnessError: Error, CustomStringConvertible {
    case unexpectedPrivacyState(BrowserPrivacyScanState)
    case missingProbe(String)
    case privacyStateDidNotSettle(
        expected: BrowserPrivacyScanState,
        actual: BrowserPrivacyScanState
    )
    case smartScanStateDidNotSettle(
        expected: SmartScanPresentationState,
        actual: SmartScanPresentationState
    )
    case missingProgressRule(String)
    case framesDidNotSettle(required: Set<String>, available: Set<String>, revision: Int)

    var description: String {
        switch self {
        case let .unexpectedPrivacyState(state):
            "隐私 fixture 进入了非预期状态：\(state)"
        case let .missingProbe(id):
            "缺少 \(id)"
        case let .privacyStateDidNotSettle(expected, actual):
            "隐私状态未稳定；expected=\(expected)，actual=\(actual)"
        case let .smartScanStateDidNotSettle(expected, actual):
            "Smart Scan 状态未稳定；expected=\(expected)，actual=\(actual)"
        case let .missingProgressRule(ruleID):
            "Smart Scan 未发布扫描行：\(ruleID)"
        case let .framesDidNotSettle(required, available, revision):
            "布局未稳定；missing=\(required.subtracting(available).sorted())，required=\(required.sorted())，available=\(available.sorted())，revision=\(revision)"
        }
    }
}
#endif
