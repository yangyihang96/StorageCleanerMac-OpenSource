#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D67: retain D62/D63 geometry for the eleven V1 compatibility routes.
/// The three pilots have equally strict native contracts in FeatureLightfieldContractTests.
/// Frame comparison is independent of the formula used by LandingMetrics.
@MainActor
final class FeatureTemplateContractTests: XCTestCase {
    private let sizes: [CGSize] = [
        .init(width: 756, height: 508), .init(width: 804, height: 648),
        .init(width: 1084, height: 712), .init(width: 1484, height: 998),
        .init(width: 2204, height: 1298), .init(width: 613, height: 338),
        .init(width: 1084, height: 338)
    ]

    func testAllFourteenLandingActionsAndIllustratedPagesHaveIdenticalNativeFrames() async throws {
        XCTAssertEqual(FeaturePresentationDemo.modules.count, 14)
        let appearances: [(Bool, AppCanvasTheme, AppDaylightTheme)] =
            AppDaylightTheme.allCases.map { (false, AppCanvasTheme.deepSpace, $0) }
            + [(true, AppCanvasTheme.deepSpace, AppDaylightTheme.morningMist),
               (true, AppCanvasTheme.pureBlack, AppDaylightTheme.morningMist)]
        for (dark, canvas, daylight) in appearances {
            var reference: [String: [String: CGRect]] = [:]
            for module in FeaturePresentationDemo.modules where !FeatureLightfield.owns(module) {
                let fixture = try makeFixture(module: module, phase: .landing)
                    .environment(\.canvasTheme, canvas)
                    .environment(\.daylightTheme, daylight)
                let host = CalibrationAppKitLayoutHost(root: fixture, size: sizes[0], dark: dark)
                defer { host.close() }
                for size in sizes {
                    host.resize(to: size)
                    var ids: Set<String> = [LayoutProbeID.landingActionButton,
                        LayoutProbeID.landingActionPanel, LayoutProbeID.landingHeader, LayoutProbeID.landingFooter,
                        "landing.optionsViewport", "landing.optionsEnd", "fixture.viewport"]
                    if module != .memory { ids.insert(LayoutProbeID.landingArtwork) }
                    let frames = try await host.frames(required: ids, size: size)
                    let action = try XCTUnwrap(frames[LayoutProbeID.landingActionButton])
                    let viewport = try XCTUnwrap(frames["fixture.viewport"])
                    XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(action), "\(module) / \(size)")
                    XCTAssertEqual(action.height, 52, accuracy: 0.5)
                    if let expected = reference["\(size.width)x\(size.height)"] {
                        let panel = try XCTUnwrap(frames[LayoutProbeID.landingActionPanel])
                        let expectedPanel = try XCTUnwrap(expected[LayoutProbeID.landingActionPanel])
                        XCTAssertEqual(panel.height, expectedPanel.height, accuracy: 0.5, "All fourteen cards share the viewport height")
                        XCTAssertEqual(panel.minY, expectedPanel.minY, accuracy: 0.5, "All fourteen cards share the vertical slot")
                        for id in [LayoutProbeID.landingActionButton] + (module == .memory ? [] : [LayoutProbeID.landingArtwork]) {
                            assertSameFrame(try XCTUnwrap(frames[id]), try XCTUnwrap(expected[id]), "\(module) / \(size) / \(id)")
                        }
                    } else { reference["\(size.width)x\(size.height)"] = frames }
                    let options = try XCTUnwrap(frames["landing.optionsViewport"])
                    try host.scrollOptionsToBottom(matching: options)
                    let after = try await host.frames(required: ids, size: size)
                    XCTAssertTrue(options.insetBy(dx: -0.5, dy: -0.5).contains(try XCTUnwrap(after["landing.optionsEnd"])),
                        "The final option remains reachable: \(module) / \(size)")
                    assertSameFrame(try XCTUnwrap(after[LayoutProbeID.landingActionButton]), action, "Pinned action after scroll")
                }
            }
        }
    }

    func testEveryRunningPageContainsProgressElementsAndAnIdenticalCancelFrame() async throws {
        var reference: [String: CGRect] = [:]
        var artworkReference: [String: CGRect] = [:]
        for module in FeaturePresentationDemo.modules where !FeatureLightfield.owns(module) {
            // frames(required:size:) waits for stable probes. The native
            // sweep rotates independently of SwiftUI's layout frames.
            let fixture = try makeFixture(module: module, phase: .running)
            let host = CalibrationAppKitLayoutHost(root: fixture, size: sizes[0], dark: true)
            defer { host.close() }
            for size in sizes {
                host.resize(to: size)
                let ids: Set<String> = ["runtime.stage", "runtime.progress", LayoutProbeID.runtimeLocation,
                    "runtime.elapsed", "runtime.cancel", LayoutProbeID.runtimeArtwork,
                    LayoutProbeID.runtimePanel, LayoutProbeID.runtimeViewport,
                    LayoutProbeID.smartScanHeader, LayoutProbeID.smartScanFooter, "fixture.viewport"]
                let frames = try await host.frames(required: ids, size: size)
                let viewport = try XCTUnwrap(frames["fixture.viewport"])
                let cancel = try XCTUnwrap(frames["runtime.cancel"])
                XCTAssertEqual(cancel.height, 40, accuracy: 0.5)
                XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(cancel))
                let bodyViewport = try XCTUnwrap(frames[LayoutProbeID.runtimeViewport])
                assertSameFrame(bodyViewport, try XCTUnwrap(frames[LayoutProbeID.runtimePanel]),
                                "Runtime viewport measures the content column")
                XCTAssertLessThanOrEqual(try XCTUnwrap(frames[LayoutProbeID.smartScanHeader]).maxY,
                                         bodyViewport.minY + 0.5)
                XCTAssertLessThanOrEqual(bodyViewport.maxY,
                    try XCTUnwrap(frames[LayoutProbeID.smartScanFooter]).minY + 0.5)
                for id in ["runtime.stage", "runtime.progress", LayoutProbeID.runtimeLocation, "runtime.elapsed"] {
                    let element = try XCTUnwrap(frames[id])
                    XCTAssertGreaterThan(element.width, 0, id)
                    XCTAssertGreaterThan(element.height, 0, id)
                }
                if let expected = reference["\(size.width)x\(size.height)"] { assertSameFrame(cancel, expected, "\(module) / \(size)") }
                else { reference["\(size.width)x\(size.height)"] = cancel }
                let artwork = try XCTUnwrap(frames[LayoutProbeID.runtimeArtwork])
                let key = "\(size.width)x\(size.height)"
                if let expected = artworkReference[key] { assertSameFrame(artwork, expected, "Running artwork: \(module)/\(size)") }
                else { artworkReference[key] = artwork }
            }
        }
    }

    func testProductionStartupAndMemoryRunningPagesUsePublishedStateAndCancellationSlots() async throws {
        let cases: [(module: ReviewFilter, isOptimizing: Bool)] = [(.startup, false), (.memory, false), (.memory, true)]
        var reference: [String: CGRect] = [:]
        for state in cases {
            let store = try makeStore()
            let stageTitle: String
            let cancelTitle: String
            if state.module == .startup {
                stageTitle = L10n.text("正在读取夹具启动项", "Reading fixture startup items")
                cancelTitle = L10n.text("取消读取", "Cancel Reading")
                store.isLoadingStartupItems = true
                store.startupScanProgress = StartupItemsScanProgress(title: stageTitle, discoveredCount: 7)
            } else {
                store.isOptimizingMemory = state.isOptimizing
                store.isLoadingMemory = !state.isOptimizing
                stageTitle = state.isOptimizing
                    ? L10n.text("正在执行并验证内存操作", "Running and verifying memory action")
                    : L10n.text("正在读取内存状态", "Reading memory status")
                cancelTitle = state.isOptimizing
                    ? L10n.text("取消", "Cancel")
                    : L10n.text("此任务不可取消", "Cancellation unavailable")
            }
            let root = AdaptivePageViewport(resetID: state.module) {
                if state.module == .startup { StartupItemsView(store: store) }
                else { MemoryOptimizerView(store: store) }
            }
            // D144: the D70 running page is the memory module's classic view.
            .environment(\.careStudioClassicResults, true)
            .environment(\.featurePresentationIsFixture, true)
            .environment(\.moduleTheme, state.module.moduleTheme)
            let host = CalibrationAppKitLayoutHost(root: root, size: sizes[2], dark: true)
            defer { host.close() }
            for size in [sizes[2], sizes[5]] {
                host.resize(to: size)
                let frames = try await host.frames(required: ["runtime.stage", "lightfield.primary", "fixture.viewport"], size: size)
                let cancel = try XCTUnwrap(frames["lightfield.primary"])
                let viewport = try XCTUnwrap(frames["fixture.viewport"])
                XCTAssertEqual(cancel.height, 52, accuracy: 0.5)
                XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(cancel))
                // N20: this SDK's hosted ScrollView stops its AX tree at the
                // document. Check actual rendered inputs plus native frames;
                // do not mistake that host limitation for a missing stage.
                let rendered = try await host.runtimeContent(module: state.module, stageTitle: stageTitle)
                XCTAssertEqual(rendered.stageTitle, stageTitle)
                XCTAssertEqual(rendered.cancellationTitle, cancelTitle)
                let hasAction = state.module == .startup || state.isOptimizing
                XCTAssertEqual(rendered.cancellationHasAction, hasAction)
                XCTAssertEqual(rendered.cancellationIsEnabled, hasAction)
                let stage = try XCTUnwrap(frames["runtime.stage"])
                XCTAssertGreaterThan(stage.width, 0)
                XCTAssertGreaterThan(stage.height, 0)
                if hasAction {
                    // The pinned action is outside the scrolling content:
                    // retain its real native press-action contract.
                    try await host.waitForAccessibility(labels: [cancelTitle], pressLabels: [cancelTitle],
                        hitTestFrames: [cancel], hitTestViewport: viewport)
                }
                if state.module == .startup {
                    let nextTitle = stageTitle + " · 2"
                    store.startupScanProgress = StartupItemsScanProgress(title: nextTitle, discoveredCount: 8)
                    let next = try await host.runtimeContent(module: .startup, stageTitle: nextTitle)
                    XCTAssertEqual(next.stageTitle, nextTitle, "Probe follows newly published production state")
                    XCTAssertEqual(next.cancellationTitle, cancelTitle)
                    XCTAssertTrue(next.cancellationHasAction)
                    store.startupScanProgress = StartupItemsScanProgress(title: stageTitle, discoveredCount: 7)
                    _ = try await host.runtimeContent(module: .startup, stageTitle: stageTitle)
                }
                let key = "\(size.width)x\(size.height)"
                if let expected = reference[key] { assertSameFrame(cancel, expected, "Production running state: \(state)") }
                else { reference[key] = cancel }
            }
        }
    }

    // D69/D70 replace the V1 tiled dashboard; retain actual selection, pinned
    // action and native scrolling contracts in the production Lightfield page.
    func testMemoryDashboardKeepsOverviewListAndSelectionCommandsInsideTheContentColumn() async throws {
        let store = try makeStore()
        store.memorySnapshot = LightfieldPerformanceFixture.memory
        let snapshot = try XCTUnwrap(store.memorySnapshot)
        let apps = snapshot.appsByResidentUsage.filter { $0.canQuit && $0.bundlePath?.hasSuffix(".app") == true }
        XCTAssertFalse(apps.isEmpty)
        let root = AdaptivePageViewport(resetID: .memory) {
            LightfieldMemoryPage(store: store, snapshot: snapshot, displaySnapshot: snapshot,
                trendPoints: LightfieldPerformanceFixture.trend, startsWithProcesses: true, showsProcesses: .constant(true))
        }.environment(\.featurePresentationIsFixture, true).environment(\.featureDisablesLayoutAnimations, true)
        let host = CalibrationAppKitLayoutHost(root: root, size: sizes[2], dark: true)
        defer { host.close() }
        for size in sizes {
            host.resize(to: size)
            for count in [0, 1, apps.count] {
                store.clearMemoryProcessSelection()
                apps.prefix(count).forEach { store.setMemoryAppUsageSelection($0, isSelected: true) }
                let frames = try await host.frames(required: ["lightfield.content", "lightfield.primary", "lightfield.primary.hitTarget",
                    "lightfield.memory.overview", "lightfield.status", "lightfield.results.scrollViewport", "fixture.viewport"], size: size)
                let content = try XCTUnwrap(frames["lightfield.content"])
                let primary = try XCTUnwrap(frames["lightfield.primary"])
                let viewport = try XCTUnwrap(frames["lightfield.results.scrollViewport"])
                XCTAssertTrue(content.insetBy(dx: -0.5, dy: -0.5).contains(viewport))
                // D77 replaces the old 24 pt/52 pt visual slots. The hit
                // target and footer remain disjoint from the actual viewport.
                XCTAssertEqual(primary.minY - content.maxY, 16, accuracy: 0.5)
                XCTAssertEqual(primary.height, 32, accuracy: 0.5)
                XCTAssertEqual(viewport, content)
                let target = try XCTUnwrap(frames["lightfield.primary.hitTarget"])
                let footer = try XCTUnwrap(frames["lightfield.status"])
                XCTAssertGreaterThanOrEqual(target.height, 44)
                XCTAssertLessThanOrEqual(viewport.maxY + 8, footer.minY + 0.5)
                XCTAssertFalse(viewport.intersects(target))
                let overview = try XCTUnwrap(frames["lightfield.memory.overview"])
                XCTAssertGreaterThan(overview.width, 0)
                XCTAssertGreaterThan(overview.height, 0)
                XCTAssertLessThanOrEqual(overview.maxY, content.minY)
                XCTAssertEqual(store.selectedMemoryAppCount, count)
                let title = count == 0 ? L10n.text("刷新内存快照", "Refresh Memory Snapshot")
                    : L10n.text("退出所选应用 · \(count) 个", "Quit Selected Apps · \(count)")
                try await host.waitForAccessibility(labels: [title], pressLabels: [title],
                    hitTestFrames: [target], hitTestViewport: try XCTUnwrap(frames["fixture.viewport"]))
                let native = try host.accessibilityFrame(label: title)
                XCTAssertEqual(native.minX, target.minX, accuracy: 0.5)
                XCTAssertEqual(native.minY, target.minY, accuracy: 0.5)
                XCTAssertEqual(native.width, target.width, accuracy: 0.5)
                XCTAssertEqual(native.height, target.height, accuracy: 0.5)
                let geometry = try await host.scrollContent(prefix: "lightfield.results")
                XCTAssertEqual(geometry.overflowing, geometry.naturalHeight > geometry.availableHeight + 0.5)
                XCTAssertFalse(geometry.showsHint, "D67 uses a fading boundary instead of a V1 overflow label")
                XCTAssertNil(store.pendingMemoryQuitSummary, "Presentation and selection must not request a quit")
            }
        }
    }

    func testMemorySampledListViewportEndsBeforeRefreshAndAdvertisesHiddenRows() async throws {
        let store = try makeStore()
        store.memorySnapshot = LightfieldPerformanceFixture.memory
        let snapshot = try XCTUnwrap(store.memorySnapshot)
        let root = AdaptivePageViewport(resetID: .memory) {
            LightfieldMemoryPage(store: store, snapshot: snapshot, displaySnapshot: snapshot,
                trendPoints: [], startsWithProcesses: true, showsProcesses: .constant(true))
        }.environment(\.featurePresentationIsFixture, true).environment(\.featureDisablesLayoutAnimations, true)
        let host = CalibrationAppKitLayoutHost(root: root, size: sizes[0], dark: true)
        defer { host.close() }
        for size in [sizes[0], sizes[2], sizes[5], sizes[6]] {
            host.resize(to: size)
            let frames = try await host.frames(required: ["lightfield.content", "lightfield.results.scrollViewport",
                "lightfield.results.fade", "lightfield.primary", "lightfield.primary.hitTarget", "lightfield.status"], size: size)
            let primary = try XCTUnwrap(frames["lightfield.primary"])
            let viewport = try XCTUnwrap(frames["lightfield.results.scrollViewport"])
            XCTAssertLessThanOrEqual(viewport.maxY, primary.minY - 16 + 0.5)
            XCTAssertLessThanOrEqual(viewport.maxY + 8, try XCTUnwrap(frames["lightfield.status"]).minY + 0.5)
            XCTAssertFalse(viewport.intersects(try XCTUnwrap(frames["lightfield.primary.hitTarget"])))
            XCTAssertEqual(viewport, try XCTUnwrap(frames["lightfield.content"]))
            XCTAssertTrue(try XCTUnwrap(frames["lightfield.content"]).insetBy(dx: -0.5, dy: -0.5).contains(viewport))
            let fade = try XCTUnwrap(frames["lightfield.results.fade"])
            XCTAssertEqual(fade.maxY, viewport.maxY, accuracy: 0.5)
            XCTAssertEqual(fade.height, min(24, viewport.height), accuracy: 0.5)
            let geometry = try await host.scrollContent(prefix: "lightfield.results")
            XCTAssertEqual(geometry.overflowing, geometry.naturalHeight > geometry.availableHeight + 0.5)
            XCTAssertFalse(geometry.showsHint)
        }
        let source = try source("Views/DesignSystem/FeatureLightfieldComponents.swift")
        XCTAssertTrue(source.contains("usesLightfield: true, fadesResults: true, preservesLazyLayout: true"))
    }

    func testDemoArgumentsRequireFixtureModeAndExactlyOneValidFeaturePhase() {
        let inert = MiniWindowDemoData.launchArgument
        for module in FeaturePresentationDemo.modules {
            for phase in FeaturePresentationDemo.Phase.allCases {
                let flag = "--debug-feature-page=\(module.rawValue):\(phase.rawValue)"
                if phase == .result && !FeatureLightfield.owns(module) {
                    XCTAssertNil(FeaturePresentationDemo.configuration(arguments: [inert, flag]))
                } else {
                    XCTAssertEqual(FeaturePresentationDemo.configuration(arguments: [inert, flag]),
                                   .init(module: module, phase: phase))
                }
                XCTAssertNil(FeaturePresentationDemo.configuration(arguments: [flag]))
            }
        }
        for invalid in ["utilityHub:landing", "unknown:running", "overview:results", "overview:", "overview:landing:extra"] {
            XCTAssertNil(FeaturePresentationDemo.configuration(arguments: [inert, "--debug-feature-page=\(invalid)"]))
        }
        XCTAssertNil(FeaturePresentationDemo.configuration(arguments: [inert,
            "--debug-feature-page=overview:landing", "--debug-feature-page=memory:running"]))
        XCTAssertEqual(FeaturePresentationDemo.configuration(arguments: [inert, "--debug-feature-page=all:running"]),
                       .init(module: nil, phase: .running))
        XCTAssertEqual(FeaturePresentationDemo.duplicateFilter(arguments: []), .all)
        XCTAssertEqual(FeaturePresentationDemo.duplicateFilter(arguments: ["--debug-feature-similar-photos"]), .similarImage)
    }

    func testApproximateClockRetainsTaskThroughNavigationAndExpiresEndedModules() {
        let clock = FeatureRuntimeClock()
        let first = Date(timeIntervalSince1970: 1_000)
        let later = first.addingTimeInterval(30)
        XCTAssertEqual(clock.start(module: .performance, identity: nil, now: first), first)
        XCTAssertEqual(clock.start(module: .performance, identity: "first-session", now: later), first)
        clock.retain(activeModules: [.performance, .startup])
        XCTAssertEqual(clock.start(module: .performance, identity: "first-session", now: later), first)
        XCTAssertEqual(clock.start(module: .startup, identity: nil, now: later), later)
        clock.retain(activeModules: [.startup])
        XCTAssertEqual(clock.start(module: .performance, identity: "second-session", now: later), later)
        clock.retain(activeModules: [])
        XCTAssertEqual(clock.start(module: .startup, identity: nil, now: later.addingTimeInterval(10)),
                       later.addingTimeInterval(10))
    }

    func testShortestLandingHasAnOverflowHintAndKeepsItsPinnedAction() async throws {
        let root = try makeFixture(module: .overview, phase: .landing)
        let host = CalibrationAppKitLayoutHost(root: root, size: sizes[5], dark: true)
        defer { host.close() }
        let frames = try await host.frames(required: ["landing.scrollHint", "landing.optionsViewport",
            LayoutProbeID.landingActionButton, "fixture.viewport"], size: sizes[5])
        let hint = try XCTUnwrap(frames["landing.scrollHint"])
        let options = try XCTUnwrap(frames["landing.optionsViewport"])
        XCTAssertEqual(hint.height, FeaturePageTokens.scrollHintHeight, accuracy: 0.5)
        let visible = try await host.frames(required: ["landing.scrollViewport"], size: sizes[5])
        XCTAssertLessThanOrEqual(try XCTUnwrap(visible["landing.scrollViewport"]).maxY, hint.minY + 0.5,
                                 "The hint occupies a separate slot below the content")
        XCTAssertTrue(options.insetBy(dx: -0.5, dy: -0.5).contains(hint))
        XCTAssertLessThanOrEqual(hint.maxY, try XCTUnwrap(frames[LayoutProbeID.landingActionButton]).minY)
        let action = try XCTUnwrap(frames[LayoutProbeID.landingActionButton])
        try host.scrollOptionsToBottom(matching: options)
        let after = try await host.frames(required: ["landing.optionsViewport", "landing.optionsEnd",
            LayoutProbeID.landingActionButton, "fixture.viewport"], size: sizes[5])
        XCTAssertNil(after["landing.scrollHint"], "The hint disappears once the final option is visible")
        XCTAssertTrue(options.insetBy(dx: -0.5, dy: -0.5).contains(try XCTUnwrap(after["landing.optionsEnd"])))
        assertSameFrame(try XCTUnwrap(after[LayoutProbeID.landingActionButton]), action, "Pinned action after overflow scroll")
    }

    func testSparseLandingOptionsAreCenteredWithoutStretchingRowSpacing() async throws {
        let root = try makeFixture(module: .overview, phase: .landing)
        let host = CalibrationAppKitLayoutHost(root: root, size: sizes[2], dark: true)
        defer { host.close() }
        let rows = ["smartScope.trash", "smartScope.doc.text.magnifyingglass", "smartScope.shield"]
        for size in [sizes[2], sizes[3], sizes[4]] {
            host.resize(to: size)
            let frames = try await host.frames(required: Set(rows + ["landing.optionsContent", "landing.optionsViewport"]), size: size)
            let content = try XCTUnwrap(frames["landing.optionsContent"])
            let viewport = try XCTUnwrap(frames["landing.optionsViewport"])
            XCTAssertLessThan(content.height, viewport.height)
            XCTAssertEqual(content.midY, viewport.midY, accuracy: 0.5)
            for pair in zip(rows, rows.dropFirst()) {
                let preceding = try XCTUnwrap(frames[pair.0])
                let following = try XCTUnwrap(frames[pair.1])
                XCTAssertEqual(following.minY - preceding.maxY, FeaturePageTokens.optionRowSpacing, accuracy: 0.5)
            }
        }
    }

    func testBenchmarkDemoUsesTheProductionMonitorAndStages() async throws {
        // D69/D72 and the approved v11 running page replace the single dial with
        // three independent axes and two progress bars. Exercise the production route.
        // The real shell constructs the v11 page; makeFixture also retains the
        // fail-fast live status/process/cleanup and hardware providers.
        let root = try makeFixture(module: .performance, phase: .running)
        let host = CalibrationAppKitLayoutHost(root: root, size: sizes[2], dark: true)
        defer { host.close() }
        let axes = ["power", "frequency", "temperature"]
        let ids: Set<String> = Set(axes.map { "performance.running.chart." + $0 }
            + axes.map { "performance.running.metrics.value." + $0 }
            + ["performance.running.monitor", "performance.running.stage",
               "performance.running.progress.total", "performance.running.progress.core",
               "lightfield.primary", "fixture.viewport"])
        let frames = try await host.frames(required: ids, size: sizes[2])
        let monitor = try XCTUnwrap(frames["performance.running.monitor"])
        XCTAssertGreaterThan(monitor.height, 100)
        var preceding: CGRect?
        for axis in axes {
            let chart = try XCTUnwrap(frames["performance.running.chart." + axis])
            let value = try XCTUnwrap(frames["performance.running.metrics.value." + axis])
            XCTAssertGreaterThan(chart.height, 0, axis)
            XCTAssertGreaterThan(chart.width, 0, axis)
            XCTAssertGreaterThan(value.width, 0, axis)
            XCTAssertGreaterThan(value.height, 0, axis)
            XCTAssertTrue(monitor.insetBy(dx: -0.5, dy: -0.5).contains(chart), axis)
            XCTAssertTrue(monitor.insetBy(dx: -0.5, dy: -0.5).contains(value), axis)
            if let preceding { XCTAssertLessThanOrEqual(preceding.maxX, chart.minX + 0.5, axis) }
            preceding = chart
        }
        XCTAssertGreaterThan(try XCTUnwrap(frames["performance.running.stage"]).width, 0)
        for id in ["performance.running.progress.total", "performance.running.progress.core"] {
            let progress = try XCTUnwrap(frames[id])
            XCTAssertGreaterThan(progress.width, 0, id)
            XCTAssertGreaterThan(progress.height, 0, id)
        }
        let cancel = try XCTUnwrap(frames["lightfield.primary"])
        XCTAssertEqual(cancel.height, 52, accuracy: 0.5)
        XCTAssertTrue(try XCTUnwrap(frames["fixture.viewport"]).insetBy(dx: -0.5, dy: -0.5).contains(cancel))
        try await host.waitForAccessibility(labels: [L10n.text("取消", "Cancel")],
                                             pressLabels: [L10n.text("取消", "Cancel")])
    }

    func testOrbitMotionPolicyIsOffForIdleHiddenAndReducedMotionStates() {
        for active in [false, true] {
            for visible in [false, true] {
                for reduced in [false, true] {
                    XCTAssertEqual(AppMotion.runsOrbit(isActive: active, isVisible: visible, reduceMotion: reduced),
                                   active && visible && !reduced)
                }
            }
        }
        XCTAssertFalse(AppMotion.morphsGeometry(reduceMotion: true))
        for token in AppMotion.Token.allCases {
            XCTAssertNotNil(AppMotion.resolved(token, reduceMotion: false), token.rawValue)
            switch token {
            case .hover, .standard, .emphasized:
                XCTAssertEqual(AppMotion.reducedBehavior(token), .fade)
                XCTAssertNotNil(AppMotion.resolved(token, reduceMotion: true), token.rawValue)
            case .press, .data:
                XCTAssertEqual(AppMotion.reducedBehavior(token), .immediate)
                XCTAssertNil(AppMotion.resolved(token, reduceMotion: true), token.rawValue)
            }
        }
    }

    func testNativeArtworkLayerDoesNotAnimateIdleOrReducedMotionPages() async throws {
        // The production idle page must never install a rotating layer,
        // regardless of the machine's current accessibility preferences.
        let root = try makeFixture(module: .overview, phase: .landing)
        let host = CalibrationAppKitLayoutHost(root: root, size: sizes[2], dark: true)
        defer { host.close() }
        _ = try await host.frames(required: [LayoutProbeID.landingArtwork], size: sizes[2])
        XCTAssertFalse(host.orbitAnimationStates().contains(true), "Idle pages must not run an animation")

        // SDK 27 exposes accessibilityReduceMotion as read-only. Pass the
        // pure motion policy into the native layer's existing explicit turns
        // input, following DesignSystemV2Tests, without changing system state.
        let sweep = OrbitSweepView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let color = NSColor(ReviewFilter.overview.moduleTheme.actionFill)
        sweep.configure(color: color, turns: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = sweep
        window.orderFront(nil)
        await Task.yield()
        for phase in [FeaturePresentationDemo.Phase.landing, .running] {
            for reduced in [false, true] {
                sweep.configure(color: color, turns: AppMotion.runsOrbit(
                    isActive: phase == .running, isVisible: true, reduceMotion: reduced))
                sweep.layoutSubtreeIfNeeded()
                if phase == .running && !reduced {
                    XCTAssertTrue(sweep.isTurning, "Visible running layers turn")
                } else {
                    XCTAssertFalse(sweep.isTurning, "Idle/reduced pages must not run an animation")
                }
            }
        }
    }

    func testNativeSweepTracksPublishedOcclusionWithoutChangingSystemSettings() async {
        let sweep = OrbitSweepView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let window = FeatureOcclusionFixtureWindow(contentRect: sweep.frame,
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = sweep
        window.orderFront(nil)
        await Task.yield()
        sweep.configure(color: NSColor(ReviewFilter.overview.moduleTheme.actionFill), turns: true)
        XCTAssertTrue(sweep.isTurning)
        window.reportedOcclusion = []
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertFalse(sweep.isTurning, "Published full occlusion removes the running animation")
        window.reportedOcclusion = [.visible]
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertTrue(sweep.isTurning, "Published visibility resumes an active sweep")
        sweep.configure(color: NSColor(ReviewFilter.overview.moduleTheme.actionFill), turns: false)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertFalse(sweep.isTurning, "Visibility never restarts an idle or reduced-motion sweep")
    }

    func testD63ColumnsHaveNoBackplateAndLargeCompositionsAreCenteredAndBounded() async throws {
        for phase in [FeaturePresentationDemo.Phase.landing, .running] {
            for module in FeaturePresentationDemo.modules where !FeatureLightfield.owns(module) {
                let root = try makeFixture(module: module, phase: phase)
                let host = CalibrationAppKitLayoutHost(root: root, size: sizes[3], dark: false)
                defer { host.close() }
                let prefix = phase == .landing ? "landing" : "runtime"
                let panelID = phase == .landing ? LayoutProbeID.landingActionPanel : LayoutProbeID.runtimePanel
                for size in [sizes[3], sizes[4]] {
                    host.resize(to: size)
                    var required: Set<String> = [panelID, LayoutProbeID.landingHeader,
                        prefix + ".composition", prefix + ".compositionArea"]
                    if phase == .running || module != .memory {
                        required.insert(phase == .running ? LayoutProbeID.runtimeArtwork : LayoutProbeID.landingArtwork)
                    }
                    let frames = try await host.frames(required: required, size: size)
                    let panel = try XCTUnwrap(frames[panelID])
                    let group = try XCTUnwrap(frames[prefix + ".composition"])
                    let area = try XCTUnwrap(frames[prefix + ".compositionArea"])
                    XCTAssertLessThanOrEqual(panel.height, 380.5, "D63 content column cap: \(module)/\(phase)")
                    XCTAssertEqual(group.midY, area.midY, accuracy: 0.5, "D63 centered composition")
                    XCTAssertTrue(area.insetBy(dx: -0.5, dy: -0.5).contains(group))
                    // A background attached after a drawing offset can report
                    // an unmoved group. Actual child frames must agree with it.
                    for id in [panelID, LayoutProbeID.landingHeader] +
                        ((phase == .landing && module == .memory) ? [] :
                            [phase == .running ? LayoutProbeID.runtimeArtwork : LayoutProbeID.landingArtwork]) {
                        XCTAssertTrue(group.insetBy(dx: -0.5, dy: -0.5).contains(try XCTUnwrap(frames[id])),
                                      "The measured composition contains its real child: \(id)/\(module)/\(phase)")
                    }
                    let backdrops = try await host.backdropValues()
                    XCTAssertEqual(backdrops["feature.column"], false)
                    XCTAssertEqual(backdrops["feature.status"], false)
                    if phase == .running || module != .memory {
                        let geometry = try await host.scrollContent(prefix: prefix)
                        if !geometry.overflowing {
                            let whitespace = (geometry.visibleHeight - geometry.naturalHeight) / 2
                            XCTAssertLessThanOrEqual(whitespace, 80, "Each option-space band is bounded: \(module)")
                        }
                    }
                }
            }
        }
    }

    func testD63SourceKeepsTheColumnAndStatusOnTheCanvas() throws {
        let templates = try source("Views/DesignSystem/FeatureTemplates.swift")
        let landing = try source("Views/FileToolLandingPage.swift")
        let legacyStart = try XCTUnwrap(landing.range(of: "struct LegacyTerminalLandingPage"))
        let commonLanding = String(landing.prefix(upTo: legacyStart.lowerBound))
        XCTAssertFalse(templates.contains(".surfaceBackground(.card)"), "No running/scaffold backplate")
        XCTAssertFalse(commonLanding.contains("SurfaceBackground(level: .card)"), "No landing backplate")
        XCTAssertFalse(commonLanding.contains(".surfaceBackground(.card)"))
        XCTAssertTrue(templates.contains("isIntegrated: true"), "Status line shares the canvas")
        XCTAssertTrue(templates.contains(".system(size: 15, weight: .semibold)"), "V0 option title size")
        XCTAssertFalse(templates.contains("Text(detail)"), "D64 deletes option descriptions")
        let surfaces = try source("Views/DesignSystem/SurfaceComponents.swift")
        XCTAssertTrue(surfaces.contains("if !isIntegrated"), "Legacy consumers retain their containers")
        let memory = try source("Views/LightfieldMemoryPage.swift")
        XCTAssertTrue(memory.contains("FeatureLightfieldPage(module: .memory"))
        XCTAssertFalse(memory.contains(".surfaceBackground(.card)"))
        XCTAssertFalse(memory.contains("SurfaceCard"))
        let options = try source("Views/DesignSystem/FeatureOptionsPresentation.swift")
        XCTAssertFalse(options.contains("featureOptionsHeight"), "Unused height environment cannot dictate overflow")
    }

    func testLandingAndRunningKeepIdenticalBottomSlotsAcrossAllSevenSizes() async throws {
        for module in FeaturePresentationDemo.modules where !FeatureLightfield.owns(module) {
            let landing = try makeFixture(module: module, phase: .landing)
            let running = try makeFixture(module: module, phase: .running)
            let landingHost = CalibrationAppKitLayoutHost(root: landing, size: sizes[0], dark: true)
            let runningHost = CalibrationAppKitLayoutHost(root: running, size: sizes[0], dark: true)
            defer { landingHost.close(); runningHost.close() }
            for size in sizes {
                landingHost.resize(to: size)
                runningHost.resize(to: size)
                let before = try await landingHost.frames(required: [LayoutProbeID.landingFooter,
                    LayoutProbeID.landingActionPanel, LayoutProbeID.landingActionButton,
                    LayoutProbeID.landingHeader], size: size)
                let after = try await runningHost.frames(required: [LayoutProbeID.landingFooter,
                    LayoutProbeID.runtimePanel, "runtime.cancel", LayoutProbeID.landingHeader], size: size)
                assertSameFrame(try XCTUnwrap(after[LayoutProbeID.landingHeader]),
                    try XCTUnwrap(before[LayoutProbeID.landingHeader]), "Two-state header: \(module)/\(size)")
                assertSameFrame(try XCTUnwrap(after[LayoutProbeID.landingFooter]),
                    try XCTUnwrap(before[LayoutProbeID.landingFooter]), "Two-state status line: \(module)/\(size)")
                XCTAssertEqual(try XCTUnwrap(after[LayoutProbeID.runtimePanel]).maxY,
                    try XCTUnwrap(before[LayoutProbeID.landingActionPanel]).maxY, accuracy: 0.5)
                XCTAssertEqual(try XCTUnwrap(after["runtime.cancel"]).maxY,
                    try XCTUnwrap(before[LayoutProbeID.landingActionButton]).maxY, accuracy: 0.5)
            }
        }
    }

    func testSmartScanNaturalRowsDoNotShowAFalseHintAndKeepV0Scale() async throws {
        for daylight in AppDaylightTheme.allCases {
            for dark in [false, true] {
                let root = try makeFixture(module: .overview, phase: .landing)
                    .environment(\.daylightTheme, daylight)
                let host = CalibrationAppKitLayoutHost(root: root, size: sizes[0], dark: dark)
                defer { host.close() }
                for size in [sizes[0], sizes[1], sizes[2]] {
                    host.resize(to: size)
                    let rows = ["trash", "doc.text.magnifyingglass", "shield"]
                    let ids = Set(rows.flatMap { ["smartScope.\($0)", "smartScope.icon.\($0)"] }
                        + ["landing.optionsContent", "landing.optionsViewport", LayoutProbeID.landingActionButton])
                    let frames = try await host.frames(required: ids, size: size)
                    let geometry = try await host.scrollContent(prefix: "landing")
                    XCTAssertFalse(geometry.overflowing, "Three complete rows: \(size)/\(daylight)/\(dark)")
                    XCTAssertFalse(geometry.showsHint)
                    XCTAssertNil(frames["landing.scrollHint"])
                    for row in rows {
                        let icon = try XCTUnwrap(frames["smartScope.icon.\(row)"])
                        XCTAssertEqual(icon.width, 48, accuracy: 0.5)
                        XCTAssertEqual(icon.height, 48, accuracy: 0.5)
                        XCTAssertGreaterThanOrEqual(try XCTUnwrap(frames["smartScope.\(row)"]).height, 56)
                    }
                    if size == sizes[2] {
                        let finalRow = try XCTUnwrap(frames["smartScope.shield"])
                        let primary = try XCTUnwrap(frames[LayoutProbeID.landingActionButton])
                        XCTAssertGreaterThanOrEqual(primary.minY - finalRow.maxY, 0)
                        XCTAssertLessThanOrEqual(primary.minY - finalRow.maxY, 48)
                    }
                }
            }
        }
    }

    func testOverflowHintReservesItsOwnSlotInEveryShortestProductionPage() async throws {
        for phase in [FeaturePresentationDemo.Phase.landing, .running] {
            for module in FeaturePresentationDemo.modules where !FeatureLightfield.owns(module) && (phase == .running || module != .memory) {
                let root = try makeFixture(module: module, phase: phase)
                let host = CalibrationAppKitLayoutHost(root: root, size: sizes[5], dark: true)
                defer { host.close() }
                let prefix = phase == .landing ? "landing" : "runtime"
                let actionID = phase == .landing ? LayoutProbeID.landingActionButton : "runtime.cancel"
                for size in [sizes[5], sizes[6]] {
                    host.resize(to: size)
                    let geometry = try await host.scrollContent(prefix: prefix)
                    XCTAssertEqual(geometry.overflowing, geometry.naturalHeight > geometry.availableHeight + 0.5)
                    XCTAssertEqual(geometry.showsHint, geometry.overflowing, "New document at scroll origin")
                    var required: Set<String> = [prefix + ".scrollViewport", actionID]
                    if geometry.showsHint { required.insert(prefix + ".scrollHint") }
                    let frames = try await host.frames(required: required, size: size)
                    let content = try XCTUnwrap(frames[prefix + ".scrollViewport"])
                    let action = try XCTUnwrap(frames[actionID])
                    XCTAssertLessThanOrEqual(content.maxY, action.minY + 0.5)
                    if geometry.showsHint {
                        let hint = try XCTUnwrap(frames[prefix + ".scrollHint"])
                        XCTAssertEqual(hint.height, 24, accuracy: 0.5)
                        XCTAssertLessThanOrEqual(content.maxY, hint.minY + 0.5)
                        XCTAssertLessThanOrEqual(hint.maxY, action.minY + 0.5)
                    } else { XCTAssertNil(frames[prefix + ".scrollHint"]) }
                }
            }
        }
    }

    func testSimilarPhotoRuntimeUsesItsOwnBilingualSubtitle() async throws {
        // D64: replace the deleted subtitle with the mode's safety line.
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = CalibrationLanguageScope(language)
            defer { languageScope.restore() }
            let similarSafety = L10n.text("只读扫描 · 相似候选须人工确认，不会自动清理",
                "Read-only scan · Review similar candidates; no automatic cleanup")
            // Scanning retains originals. Only verified duplicate copies may
            // later enter a confirmed quarantine/Trash plan; similar candidates
            // cannot enter safe cleanup at all. Do not promise a Trash-only flow.
            let duplicateSafety = L10n.text("只读扫描 · 保留原件，清理前确认",
                "Read-only scan · Originals retained until cleanup is confirmed")
            for similar in [false, true] {
                let title = L10n.text("正在比对夹具", "Comparing fixture")
                let root = AdaptivePageViewport(resetID: .duplicates) {
                    DuplicateFilesRunningPage(progress: .initial, state: .running, title: title,
                        pageTitle: similar ? L10n.text("相似照片", "Similar Photos") : ReviewFilter.duplicates.sidebarTitle,
                        isSimilarPhotos: similar, canCancel: true, onCancel: {}, onPauseOrResume: {})
                }.environment(\.moduleTheme, ReviewFilter.duplicates.moduleTheme)
                let host = CalibrationAppKitLayoutHost(root: root, size: sizes[2], dark: true)
                defer { host.close() }
                // D70 B7 routes duplicates through D67: cancellation remains the
                // primary button, with the same actual-frame requirement.
                _ = try await host.frames(required: ["runtime.stage", FeatureLightfield.owns(.duplicates)
                    ? "lightfield.primary" : "runtime.cancel"], size: sizes[2])
                let rendered = try await host.runtimeContent(module: .duplicates, stageTitle: title)
                XCTAssertEqual(rendered.safetyText, similar ? similarSafety : duplicateSafety)
                if similar { XCTAssertNotEqual(rendered.safetyText, duplicateSafety) }
            }
        }
    }

    func testScrollGeometryUsesTheSameStrictHalfPointToleranceForEveryPage() {
        XCTAssertFalse(FeatureScrollGeometry.overflows(contentHeight: 200, availableHeight: 200))
        XCTAssertFalse(FeatureScrollGeometry.overflows(contentHeight: 200.5, availableHeight: 200))
        XCTAssertTrue(FeatureScrollGeometry.overflows(contentHeight: 200.51, availableHeight: 200))
        let viewport = CGRect(x: 10, y: 20, width: 200, height: 100)
        XCTAssertFalse(FeatureScrollGeometry.hasContentBelow(content: viewport, viewport: viewport))
        XCTAssertTrue(FeatureScrollGeometry.hasContentBelow(
            content: CGRect(x: 10, y: 20, width: 200, height: 101), viewport: viewport))
    }

    func testOrbitFourNodeOrderMatchesTheOptionReadingOrder() throws {
        // D64 supersedes node reading order: no satellites or satellite labels
        // are rendered. The remaining central mark has identical geometry.
        let geometry = OrbitArtworkGeometry.resolve(side: 420)
        XCTAssertEqual(geometry.center, CGPoint(x: 210, y: 210))
        let orbit = try source("Views/DesignSystem/OrbitLandingArtwork.swift")
        for old in ["ForEach(Array(nodes", "nodeView(", "orbCenter(", "showsLabels"] {
            XCTAssertFalse(orbit.contains(old), old)
        }
        XCTAssertTrue(orbit.contains("centerMark(side: drawing)"))
        for route in [ReviewFilter.green, .largeFiles, .performance] {
            XCTAssertNotNil(GeneratedArt.module(for: route), route.rawValue)
        }
    }

    func testSnapshotSelectionExplicitlyDiscardsItsReturnValue() throws {
        XCTAssertTrue(try source("Debug/MainWindowSnapshotPipeline.swift")
            .contains("_ = withTransaction(transaction) { navigationState.select(module) }"))
    }

    func testD64SharedDecorationAndProseAreRemovedWithoutLosingTheCentralArtOrSafety() throws {
        let hero = try source("Views/DesignSystem/PageHero.swift")
        let allHeaders = try source("Views/SmartCareComponents.swift")
        let start = try XCTUnwrap(allHeaders.range(of: "struct AppPageHeader"))
        let end = try XCTUnwrap(allHeaders.range(of: "struct TaskSearchField", range: start.upperBound..<allHeaders.endIndex))
        let header = String(allHeaders[start.lowerBound..<end.lowerBound])
        for value in [hero, header] {
            for deleted in ["Image(", "IconTile(", "GeneratedArtView(", "Text(subtitle)", "let subtitle:"] {
                XCTAssertFalse(value.contains(deleted), deleted)
            }
            XCTAssertTrue(value.contains("Text(title)"))
            XCTAssertTrue(value.contains(".accessibilityAddTraits(.isHeader)"))
        }
        let templates = try source("Views/DesignSystem/FeatureTemplates.swift")
        for deleted in ["Text(state.title)", "Text(subtitle)", "Text(detail)", "folder", "systemImage: \"clock\""] {
            XCTAssertFalse(templates.contains(deleted), deleted)
        }
        let runtime = try source("Views/RuntimeWorkflowPresentation.swift")
        XCTAssertFalse(runtime.contains("Text(state.title)"))
        XCTAssertFalse(runtime.contains("Text(subtitle)"))
        XCTAssertFalse(runtime.contains("Label(currentItem"))
        let footer = try source("Views/RuntimeActivityLayout.swift")
        XCTAssertFalse(footer.contains("checkmark.shield"))
        XCTAssertTrue(footer.contains("Text(text).lineLimit(1)"))
        let surfaces = try source("Views/DesignSystem/SurfaceComponents.swift")
        let footerStart = try XCTUnwrap(surfaces.range(of: "struct StatusFooter"))
        let footerEnd = try XCTUnwrap(surfaces.range(of: "// MARK: - SkeletonBlock"))
        let status = String(surfaces[footerStart.lowerBound..<footerEnd.lowerBound])
        XCTAssertFalse(status.contains("Circle()"))
        XCTAssertFalse(status.contains("checkmark.shield"))
        XCTAssertTrue(status.contains("Text(trustText)"))
        XCTAssertTrue(status.contains(".lineLimit(1)"))
        XCTAssertTrue(status.contains("if isWarning"), "Genuine warning information survives")
        let button = try source("Views/DesignSystem/GradientButtonStyle.swift")
        XCTAssertTrue(button.contains(".labelStyle(.titleOnly)"))
        let labelStart = try XCTUnwrap(button.range(of: "struct PrimaryActionLabel"))
        let label = String(button[labelStart.lowerBound...])
        XCTAssertTrue(label.contains("Text(title)"))
        for deleted in ["Image(", "Circle()", "SmartScanEmblem(", "ProgressView()"] {
            XCTAssertFalse(label.contains(deleted), deleted)
        }
        XCTAssertFalse(try source("Support/ModuleTheme.swift").contains("var pageSubtitle:"))
        let landing = try source("Views/FileToolLandingPage.swift")
        XCTAssertFalse(landing.contains("struct FileToolLandingArtwork:"), "Delete the dead drawing, not only its call")
        XCTAssertFalse(landing.contains("private func satellite("))
        let templateEnd = try XCTUnwrap(landing.range(of: "private struct FeatureScopeCatalog"))
        XCTAssertFalse(String(landing[..<templateEnd.lowerBound]).contains("Image("), "Only real option controls retain icons")
    }

    func testD64PrimaryTextIsCenteredForEveryFeatureInAllSevenSizes() async throws {
        for module in FeaturePresentationDemo.modules where !FeatureLightfield.owns(module) {
            let root = try makeFixture(module: module, phase: .landing)
            let host = CalibrationAppKitLayoutHost(root: root, size: sizes[0], dark: true)
            defer { host.close() }
            for size in sizes {
                host.resize(to: size)
                let frames = try await host.frames(required: [LayoutProbeID.landingActionButton,
                    "landing.actionText"], size: size)
                let action = try XCTUnwrap(frames[LayoutProbeID.landingActionButton])
                let text = try XCTUnwrap(frames["landing.actionText"])
                XCTAssertEqual(text.midX, action.midX, accuracy: 0.5, "D64 centered text: \(module)/\(size)")
                XCTAssertEqual(text.midY, action.midY, accuracy: 0.5, "D64 centered text: \(module)/\(size)")
                XCTAssertTrue(action.insetBy(dx: -0.5, dy: -0.5).contains(text))
                XCTAssertEqual(action.height, 52, accuracy: 0.5)
            }
        }
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/" + path), encoding: .utf8)
    }

    private func assertSameFrame(_ actual: CGRect, _ expected: CGRect, _ context: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, context, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, context, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, context, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, context, file: file, line: line)
    }

    private func makeFixture(module: ReviewFilter, phase: FeaturePresentationDemo.Phase) throws -> some View {
        let store = try makeStore()
        let session = FeaturePresentationDemo()
        session.phase = phase
        let health = ComputerHealthStore(probe: TemplateFixtureHealthProbe(),
            batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController())
        let network = NetworkSpeedTestStore()
        let browser = BrowserPrivacyStore()
        return AdaptivePageViewport(resetID: module) {
            FeaturePresentationDemoView(session: session, store: store, module: module,
                healthStore: health, networkStore: network, browserStore: browser)
        }
        .transaction { transaction in transaction.disablesAnimations = true }
    }

    private func makeStore() throws -> ScanStore {
        let defaults = TestPreferenceDomain.make(for: self)
        return try ScanStore.makeForTests(for: self, restoreSavedAccessOperation: {},
            loadScanReadinessSummary: { ScanReadinessSummary(items: []) },
            scanHistoryDefaults: defaults,
            menuBarMemoryStatusProvider: {
                XCTFail("A presentation fixture must not start a live status provider")
                return MiniWindowDemoData.memorySnapshot
            }, menuBarMemoryProcessProvider: {
                XCTFail("A presentation fixture must not start a live process provider")
                return MiniWindowDemoData.memorySnapshot
            },
            cleanupScanOperation: { _, _ in
                XCTFail("A presentation fixture must not execute cleanup")
                throw CancellationError()
            }, cleanupPreferences: defaults, cleanReportLoader: { [] }, interruptedOperationReconciler: { [] })
    }
}

@MainActor
private final class FeatureOcclusionFixtureWindow: NSWindow {
    // Test only: deterministic window-server reports, no system preference.
    var reportedOcclusion: NSWindow.OcclusionState = [.visible]
    override var occlusionState: NSWindow.OcclusionState { reportedOcclusion }
}

private struct TemplateFixtureHealthProbe: ComputerHealthProbing {
    func probe() async throws -> ComputerHealthSnapshot {
        XCTFail("A template fixture must not inspect real hardware")
        throw CancellationError()
    }
}
#endif
