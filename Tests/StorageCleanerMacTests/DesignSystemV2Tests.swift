#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D53 V0: the UI 2.0 foundation — size classes with hysteresis, sidebar
/// presentation, list column priority, motion tokens under Reduce Motion,
/// the canvas theme default (D56) and its stored-choice migration, surface
/// contrast, and the minimum-size visibility of the main actions.
@MainActor
final class DesignSystemV2Tests: XCTestCase {
    // MARK: PageLayout (UI-V2-SPEC §2.1)

    func testDetailWidthAndHeightClassesFollowTheCalibratedBreakpoints() {
        let widths: [(CGFloat, PageLayout.Width)] = [
            (0, .compact), (719, .compact), (720, .regular), (1_039, .regular),
            (1_040, .wide), (1_499, .wide), (1_500, .extraWide), (2_204, .extraWide),
        ]
        for (width, expected) in widths {
            XCTAssertEqual(PageLayout.resolve(size: CGSize(width: width, height: 700)).width, expected, "\(width)")
        }
        let heights: [(CGFloat, PageLayout.Height, Bool)] = [
            (338, .short, false), (468, .short, false), (559, .short, false), (560, .regular, false),
            (679, .regular, false), (680, .regular, true), (899, .regular, true), (900, .tall, true),
        ]
        for (height, expected, fullHeader) in heights {
            let layout = PageLayout.resolve(size: CGSize(width: 1_084, height: height))
            XCTAssertEqual(layout.height, expected, "\(height)")
            XCTAssertEqual(layout.allowsFullHeaderHeight, fullHeader, "\(height)")
        }
    }

    func testRealWindowSizesGetTheExpectedHeaderForms() {
        // Detail sizes of the V0 acceptance windows (sidebar and the 52 pt
        // toolbar subtracted): default, middle, minimum, tiled, large.
        let cases: [(CGSize, PageLayout.HeroForm, PageLayout.HeroForm)] = [
            (CGSize(width: 1_084, height: 712), .full, .regular),       // 1280×764
            (CGSize(width: 1_084, height: 600), .regular, .regular),    // wide but 560–679 pt (§2.3)
            (CGSize(width: 804, height: 648), .regular, .regular),      // 1000×700
            (CGSize(width: 756, height: 468), .compact, .compact),      // 820×520 with the rail
            (CGSize(width: 613, height: 338), .compact, .compact),      // 677×390 tiled
            (CGSize(width: 1_084, height: 338), .compact, .compact),    // 1280×390 tiled
            (CGSize(width: 1_484, height: 998), .prominent, .regular),  // 1680×1050
            (CGSize(width: 2_204, height: 1_298), .prominent, .regular),// 2400×1350
        ]
        for (size, landing, tool) in cases {
            let layout = PageLayout.resolve(size: size)
            XCTAssertEqual(layout.heroForm(for: .landing), landing, "\(size)")
            XCTAssertEqual(layout.heroForm(for: .tool), tool, "\(size)")
        }
    }

    func testClassesOnlyStepDownSixteenPointsBelowABoundary() {
        var layout = PageLayout.resolve(size: CGSize(width: 1_084, height: 712))
        XCTAssertEqual(layout.width, .wide)
        // Dragging narrower: stays wide until below 1024 pt.
        layout = PageLayout.resolve(size: CGSize(width: 1_030, height: 712), previous: layout)
        XCTAssertEqual(layout.width, .wide)
        layout = PageLayout.resolve(size: CGSize(width: 1_024, height: 712), previous: layout)
        XCTAssertEqual(layout.width, .wide, "exactly 16 pt below is still inside the band")
        layout = PageLayout.resolve(size: CGSize(width: 1_023, height: 712), previous: layout)
        XCTAssertEqual(layout.width, .regular)
        // Dragging wider again: wide only from the threshold itself.
        layout = PageLayout.resolve(size: CGSize(width: 1_039, height: 712), previous: layout)
        XCTAssertEqual(layout.width, .regular)
        layout = PageLayout.resolve(size: CGSize(width: 1_040, height: 712), previous: layout)
        XCTAssertEqual(layout.width, .wide)

        // Heights: regular holds to 544 pt, the full header to 664 pt.
        var tall = PageLayout.resolve(size: CGSize(width: 900, height: 700))
        XCTAssertTrue(tall.allowsFullHeaderHeight)
        tall = PageLayout.resolve(size: CGSize(width: 900, height: 670), previous: tall)
        XCTAssertTrue(tall.allowsFullHeaderHeight)
        tall = PageLayout.resolve(size: CGSize(width: 900, height: 663), previous: tall)
        XCTAssertFalse(tall.allowsFullHeaderHeight)
        tall = PageLayout.resolve(size: CGSize(width: 900, height: 550), previous: tall)
        XCTAssertEqual(tall.height, .regular)
        tall = PageLayout.resolve(size: CGSize(width: 900, height: 543), previous: tall)
        XCTAssertEqual(tall.height, .short)

        // A large jump steps down several classes at once.
        let jumped = PageLayout.resolve(size: CGSize(width: 600, height: 300),
                                        previous: PageLayout.resolve(size: CGSize(width: 2_000, height: 1_200)))
        XCTAssertEqual(jumped.width, .compact)
        XCTAssertEqual(jumped.height, .short)
    }

    func testInvalidSizesResolveToTheSmallestClassesAndKeysTrackClassesOnly() {
        let nanWidth = PageLayout.resolve(size: CGSize(width: CGFloat.nan, height: 700))
        XCTAssertEqual(nanWidth.width, .compact)
        XCTAssertEqual(nanWidth.height, .regular)
        let invalid = PageLayout.resolve(size: CGSize(width: -10, height: CGFloat.infinity))
        XCTAssertEqual(invalid.width, .compact)
        XCTAssertEqual(invalid.height, .short)
        XCTAssertEqual(invalid.size, .zero)
        let a = PageLayout.resolve(size: CGSize(width: 1_100, height: 712))
        let b = PageLayout.resolve(size: CGSize(width: 1_300, height: 760))
        let c = PageLayout.resolve(size: CGSize(width: 1_300, height: 940))
        XCTAssertEqual(a.classKey, b.classKey, "a resize inside one class keeps the key")
        XCTAssertNotEqual(b.classKey, c.classKey)
        XCTAssertEqual(PageLayout.resolve(size: CGSize(width: 700, height: 500)).pagePadding, 16)
        XCTAssertEqual(PageLayout.resolve(size: CGSize(width: 900, height: 700)).pagePadding, 24)
        XCTAssertEqual(PageLayout.resolve(size: CGSize(width: 1_200, height: 700)).pagePadding, 32)
    }

    // MARK: Sidebar (§2.2)

    func testSidebarBecomesAnIconRailBelow960WithHysteresisAndKeepsAManualChoice() {
        XCTAssertEqual(SidebarPresentation.automatic(windowWidth: 1_280, previous: nil), .full)
        XCTAssertEqual(SidebarPresentation.automatic(windowWidth: 959, previous: nil), .rail)
        XCTAssertEqual(SidebarPresentation.automatic(windowWidth: 950, previous: .full), .full)
        XCTAssertEqual(SidebarPresentation.automatic(windowWidth: 943, previous: .full), .rail)
        XCTAssertEqual(SidebarPresentation.automatic(windowWidth: 959, previous: .rail), .rail)
        XCTAssertEqual(SidebarPresentation.automatic(windowWidth: 960, previous: .rail), .full)
        XCTAssertEqual(SidebarPresentation.rail.idealWidth, 64)
        XCTAssertGreaterThanOrEqual(SidebarPresentation.full.minimumWidth, 196)
        XCTAssertLessThanOrEqual(SidebarPresentation.full.maximumWidth, 228)

        var state = SidebarPresentationState()
        state.update(windowWidth: 1_280)
        XCTAssertEqual(state.effective, .full)
        state.toggle()
        XCTAssertEqual(state.effective, .rail, "the user collapsed it")
        state.update(windowWidth: 1_100)
        XCTAssertEqual(state.effective, .rail, "the choice holds while the window stays wide")
        state.update(windowWidth: 900)
        XCTAssertEqual(state.effective, .rail, "crossing into the rail range resets to automatic")
        state.toggle()
        XCTAssertEqual(state.effective, .full, "expanded by hand in a narrow window")
        state.update(windowWidth: 930)
        XCTAssertEqual(state.effective, .full)
        state.update(windowWidth: 1_000)
        XCTAssertEqual(state.effective, .full, "crossing back to wide keeps automatic full")
        state.update(windowWidth: 900)
        XCTAssertEqual(state.effective, .rail)
    }

    // MARK: List column priority (§2.4)

    func testListColumnsAppearByPriorityAcrossWidthClasses() {
        XCTAssertEqual(ListColumnPriority.visibleColumns(in: .compact), [.p1])
        XCTAssertEqual(ListColumnPriority.visibleColumns(in: .regular), [.p1, .p2])
        XCTAssertEqual(ListColumnPriority.visibleColumns(in: .wide), [.p1, .p2, .p3])
        XCTAssertEqual(ListColumnPriority.visibleColumns(in: .extraWide), [.p1, .p2, .p3])
    }

    func testCardGridAvoidsLonelyLastRows() {
        func columns(_ items: Int, _ width: CGFloat) -> Int {
            AdaptiveCardGrid.columnCount(itemCount: items, availableWidth: width,
                                         minimumColumnWidth: 260, maximumColumns: 4, spacing: 16)
        }
        XCTAssertEqual(columns(4, 1_100), 4)
        XCTAssertEqual(columns(4, 850), 2, "four cards never become 3 + 1")
        XCTAssertEqual(columns(4, 560), 2)
        XCTAssertEqual(columns(4, 300), 1)
        XCTAssertEqual(columns(3, 560), 1, "three cards never become 2 + 1")
        XCTAssertEqual(columns(3, 850), 3)
        XCTAssertEqual(columns(5, 1_100), 3, "five cards become 3 + 2")
        XCTAssertEqual(columns(6, 1_100), 3)
        XCTAssertEqual(columns(1, 1_100), 1)
        XCTAssertEqual(columns(0, 1_100), 1)
    }

    // MARK: Motion (§3.1)

    func testReduceMotionMapsMovementToFadesAndDataToImmediateUpdates() {
        XCTAssertEqual(AppMotion.reducedBehavior(.hover), .fade)
        XCTAssertEqual(AppMotion.reducedBehavior(.standard), .fade)
        XCTAssertEqual(AppMotion.reducedBehavior(.emphasized), .fade)
        XCTAssertEqual(AppMotion.reducedBehavior(.press), .immediate)
        XCTAssertEqual(AppMotion.reducedBehavior(.data), .immediate)
        for token in AppMotion.Token.allCases {
            XCTAssertNotNil(AppMotion.resolved(token, reduceMotion: false), token.rawValue)
            switch AppMotion.reducedBehavior(token) {
            case .fade: XCTAssertNotNil(AppMotion.resolved(token, reduceMotion: true), token.rawValue)
            case .immediate: XCTAssertNil(AppMotion.resolved(token, reduceMotion: true), token.rawValue)
            }
        }
        XCTAssertNil(AppMotion.selection(reduceMotion: true), "selection blocks land in place")
        XCTAssertNotNil(AppMotion.selection(reduceMotion: false))
        XCTAssertEqual(AppMotion.staggerDelay(for: 0), 0)
        XCTAssertEqual(AppMotion.staggerDelay(for: 3), 0.105, accuracy: 0.0001)
        XCTAssertEqual(AppMotion.staggerDelay(for: 40), AppMotion.staggerDelay(for: 12), "only the first 12 are staggered")
        XCTAssertTrue(AppMotion.participatesInStagger(11))
        XCTAssertFalse(AppMotion.participatesInStagger(12))
        XCTAssertTrue(AppMotion.allowsAnimation(rowCount: 200))
        XCTAssertFalse(AppMotion.allowsAnimation(rowCount: 201), "batch updates above 200 rows are not animated")
        // The legacy names use the same reduced curve.
        XCTAssertEqual(AppMotionTokens.reduced, AppMotion.reducedFade)
    }

    // MARK: Canvas theme (D53, D56)

    func testDeepSpaceIsTheDefaultAndAStoredChoiceIsKept() throws {
        XCTAssertEqual(AppCanvasTheme.defaultsKey, "app.canvasTheme")
        XCTAssertEqual(AppCanvasTheme.defaultTheme, .deepSpace)
        XCTAssertEqual(AppCanvasTheme.resolve(rawValue: nil), .deepSpace)
        XCTAssertEqual(AppCanvasTheme.resolve(rawValue: "pureBlack"), .pureBlack)
        XCTAssertEqual(AppCanvasTheme.resolve(rawValue: "deepSpace"), .deepSpace)
        XCTAssertEqual(AppCanvasTheme.resolve(rawValue: "unknown"), .deepSpace)

        // Stored settings, in a temporary absolute-path domain (D48, N24).
        let defaults = TestPreferenceDomain.make(for: self)
        XCTAssertEqual(AppCanvasTheme.resolve(defaults: defaults), .deepSpace, "nothing stored: D56 default")
        defaults.set(AppCanvasTheme.pureBlack.rawValue, forKey: AppCanvasTheme.defaultsKey)
        XCTAssertEqual(AppCanvasTheme.resolve(defaults: defaults), .pureBlack, "a chosen pure black is kept")
        defaults.set("legacy-value", forKey: AppCanvasTheme.defaultsKey)
        XCTAssertEqual(AppCanvasTheme.resolve(defaults: defaults), .deepSpace)
        defaults.removeObject(forKey: AppCanvasTheme.defaultsKey)
    }

    // MARK: Surfaces and contrast (§1.1)

    func testEverySurfaceSetKeepsReadableTextAndOpaqueReducedTransparencyCards() {
        for (spec, name) in [(AppDesignTokens.SurfaceSpec.deepSpace, "deep space"),
                             (.pureBlack, "pure black"), (.morningMist, "morning mist")] {
            for background in [spec.cardOpaque, spec.canvasTop, spec.canvasBottom, spec.cardElevated] {
                XCTAssertGreaterThanOrEqual(contrast(spec.textPrimary, background), 4.5, name)
                XCTAssertGreaterThanOrEqual(contrast(spec.textSecondary, background), 4.5, name)
                XCTAssertGreaterThanOrEqual(contrast(spec.textSecondaryIncreased, background), 4.5, name)
                XCTAssertGreaterThanOrEqual(contrast(spec.textTertiary, background), 3, name)
            }
            XCTAssertGreaterThan(spec.strokeIncreasedOpacity, spec.strokeTopOpacity, name)
        }
        // Night cards retain V0 elevation. D63 daylight content shares its
        // canvas; it does not acquire a white rectangular backplate.
        XCTAssertGreaterThan(luminance(AppDesignTokens.SurfaceSpec.pureBlack.cardOpaque),
                             luminance(AppDesignTokens.SurfaceSpec.pureBlack.canvasTop))
        XCTAssertEqual(AppDesignTokens.SurfaceSpec.morningMist.cardOpaque,
                       AppDesignTokens.SurfaceSpec.morningMist.canvasTop)
        XCTAssertEqual(AppDesignTokens.SurfaceSpec.pureBlack.canvasTop, 0x000000, "pure black stays #000")
        XCTAssertEqual(AppDesignTokens.SurfaceSpec.morningMist.canvasTop, 0xEDF3F9)
        XCTAssertEqual(AppDesignTokens.SurfaceSpec.morningMist.sidebar, 0xE7EFF7)
        XCTAssertEqual(AppDesignTokens.SurfaceSpec.morningMist.card, 0xEDF3F9)

        let reduced = AppDesignTokens.Surface.palette(theme: .deepSpace, scheme: .dark, reduceTransparency: true)
        XCTAssertEqual(resolved(reduced.card, .dark).opacity, 1, accuracy: 0.0001)
        let translucent = AppDesignTokens.Surface.palette(theme: .deepSpace, scheme: .dark)
        XCTAssertLessThan(resolved(translucent.card, .dark).opacity, 1)
        let increased = AppDesignTokens.Surface.palette(theme: .pureBlack, scheme: .dark, increasedContrast: true)
        XCTAssertEqual(resolved(increased.strokeTop, .dark).opacity, Float(AppDesignTokens.SurfaceSpec.pureBlack.strokeIncreasedOpacity), accuracy: 0.001)
    }

    func testEveryButtonAndTileGradientKeepsWhiteLabelsReadable() {
        let pigments: [(ModulePigment, String)] = [
            (.smartScan, "smartScan"), (.cleanup, "cleanup"), (.developer, "developer"),
            (.protection, "protection"), (.performance, "performance"), (.memory, "memory"),
            (.files, "files"), (.neutral, "neutral"), (.danger, "danger"),
        ]
        for (pigment, name) in pigments {
            XCTAssertGreaterThanOrEqual(contrast(pigment.gradientLight, 0xFFFFFF), 4.5, "\(name) light stop")
            XCTAssertGreaterThanOrEqual(contrast(pigment.gradientDark, 0xFFFFFF), 4.5, "\(name) dark stop")
            XCTAssertLessThan(luminance(pigment.gradientDark), luminance(pigment.gradientLight), name)
        }
        // Destructive actions never take a module color (N19, D49).
        XCTAssertNotEqual(ModulePigment.danger, ReviewFilter.memory.moduleTheme.pigment)
        for route in ReviewFilter.allCases where route.moduleTheme.isImmersive {
            XCTAssertNotEqual(route.moduleTheme.pigment, .danger, route.rawValue)
        }
    }

    // MARK: Minimum sizes keep the main actions visible (§2.1, §2.2)

    func testLandingActionAndStatusStayVisibleFromTiledToLargeWindows() async throws {
        let store = try ScanStore.makeForTests(for: self)
        let root = AdaptivePageViewport(resetID: .overview) {
            SmartCareLandingView(store: store, latestStatus: nil)
                .environment(\.moduleTheme, ReviewFilter.overview.moduleTheme)
        }
        let host = V0LayoutHost(root: root, size: CGSize(width: 1_084, height: 712))
        defer { host.close() }
        let required: Set<String> = [LayoutProbeID.pageViewport, LayoutProbeID.landingActionButton,
                                     LayoutProbeID.landingFooter, LayoutProbeID.landingHeader,
                                     LayoutProbeID.landingContent]
        // Detail areas of 1280×764, 820×520 (minimum, icon rail), 677×390 and
        // 1280×390 (tiled), 1680×1050 and 2400×1350.
        for size in [CGSize(width: 1_084, height: 712), CGSize(width: 756, height: 468),
                     CGSize(width: 613, height: 338), CGSize(width: 1_084, height: 338),
                     CGSize(width: 1_484, height: 998), CGSize(width: 2_204, height: 1_298)] {
            host.resize(to: size)
            let frames = try await host.frames(required: required)
            let viewport = try XCTUnwrap(frames[LayoutProbeID.pageViewport])
            let action = try XCTUnwrap(frames[LayoutProbeID.landingActionButton])
            let footer = try XCTUnwrap(frames[LayoutProbeID.landingFooter])
            let header = try XCTUnwrap(frames[LayoutProbeID.landingHeader])
            for (name, rect) in [("action", action), ("status", footer), ("header", header)] {
                XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(rect), "\(name) visible at \(size): \(rect) in \(viewport)")
            }
            XCTAssertGreaterThanOrEqual(action.height, 40, "\(size)")
            XCTAssertLessThanOrEqual(header.maxY, action.minY, "\(size)")
            if size.height >= 560 {
                // Review 2: the composition starts right under the header.
                let content = try XCTUnwrap(frames[LayoutProbeID.landingContent])
                XCTAssertLessThanOrEqual(content.minY - header.maxY, 33, "\(size)")
            }
        }
    }

    /// The memory sample page owns its scrolling: the overview, the list and
    /// the pinned quit bar share the visible height, from a tiled window to a
    /// large one, and only the list scrolls (D53 V0, §2.4).
    func testMemoryPageKeepsOverviewListAndQuitBarVisibleAtEverySize() async throws {
        let store = try ScanStore.makeForTests(for: self)
        let gib: Int64 = 1_024 * 1_024 * 1_024
        let processes = (0..<6).map { index in
            let bundle = "/Applications/V0Fixture\(index).app"
            return MemoryProcess(
                id: Int32(9_100 + index), name: "V0 Fixture \(index)",
                path: "\(bundle)/Contents/MacOS/V0Fixture\(index)", iconPath: bundle, bundlePath: bundle,
                residentBytes: Int64(6 - index) * gib, percent: Double(6 - index) * 5, canQuit: true
            )
        }
        // Sampled now, so the page does not start its own refresh.
        store.memorySnapshot = MemorySnapshot(
            generatedAt: Date(), physicalBytes: 16 * gib, freeBytes: 2 * gib, inactiveBytes: 0,
            speculativeBytes: 0, fileBackedBytes: gib / 2, purgeableBytes: 0, wiredBytes: 2 * gib,
            compressedBytes: gib, swapUsedBytes: 0, pressureFreePercentage: 30,
            pressureSummary: "fixture", topProcesses: processes
        )
        store.memoryShowsAllProcesses = false
        let root = AdaptivePageViewport(resetID: .memory) {
            LightfieldMemoryPage(store: store, snapshot: store.memorySnapshot, displaySnapshot: store.memorySnapshot,
                trendPoints: [], startsWithProcesses: true, showsProcesses: .constant(true))
                .environment(\.featurePresentationIsFixture, true)
                .environment(\.featureDisablesLayoutAnimations, true)
        }.defaultAppStorage(TestPreferenceDomain.make(for: self))
        let host = CalibrationAppKitLayoutHost(root: root, size: CGSize(width: 1_084, height: 712), dark: true)
        defer { host.close() }
        let required: Set<String> = [LayoutProbeID.pageViewport, "lightfield.title", "lightfield.memory.overview",
            "lightfield.primary", "lightfield.primary.hitTarget", "lightfield.status", "lightfield.content",
            "lightfield.results.scrollViewport"]
        for size in [CGSize(width: 1_084, height: 712), CGSize(width: 756, height: 468),
                     CGSize(width: 613, height: 338), CGSize(width: 1_484, height: 998)] {
            host.resize(to: size)
            let frames = try await host.frames(required: required, size: size)
            let viewport = try XCTUnwrap(frames[LayoutProbeID.pageViewport])
            let title = try XCTUnwrap(frames["lightfield.title"])
            let overview = try XCTUnwrap(frames["lightfield.memory.overview"])
            let action = try XCTUnwrap(frames["lightfield.primary"])
            for (name, rect) in [("title", title), ("refresh/quit bar", action)] {
                XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(rect), "\(name) visible at \(size)")
            }
            // D77 / fix round 1: overview lives beside the title in the 72 pt
            // result header. Its visible data must never be a zero-height probe.
            XCTAssertGreaterThan(overview.width, 0, "\(size)")
            XCTAssertGreaterThan(overview.height, 0, "\(size)")
            XCTAssertLessThanOrEqual(overview.maxY, 72.5, "\(size)")
            XCTAssertFalse(title.intersects(overview), "\(size)")
            let snapshot = try XCTUnwrap(store.memorySnapshot)
            // D178: memory as Activity Monitor writes it, in GB (was `ByteFormat.string`, in GiB).
            let expectedUsed = snapshot.measuredUsedBytes.map { ByteFormat.memoryString(Int64(clamping: $0)) } ?? "—"
            let expectedTotal = snapshot.measurements.physicalBytes.value.map { ByteFormat.memoryString(Int64(clamping: $0)) } ?? "—"
            // The summary shows a shared unit apart (2.0.1: “41.0 / 48.0 GiB”).
            let split = LightfieldMemoryResultOverview.sharedUnit(expectedUsed + " / " + expectedTotal)
            try await host.waitForAccessibility(labels: [
                L10n.text("内存总览 · 已用 / 总量", "Memory Overview · Used / Total")
                    + " · " + split.value + (split.unit.isEmpty ? "" : " " + split.unit)])
            XCTAssertEqual(action.height, 32, accuracy: 0.5)
            let target = try XCTUnwrap(frames["lightfield.primary.hitTarget"])
            let footer = try XCTUnwrap(frames["lightfield.status"])
            let options = try XCTUnwrap(frames["lightfield.results.scrollViewport"])
            XCTAssertGreaterThan(overview.intersection(viewport).height, 0, "Overview is visible: \(size)")
            XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(options), "List viewport visible: \(size)")
            XCTAssertEqual(options, try XCTUnwrap(frames["lightfield.content"]))
            XCTAssertLessThanOrEqual(options.maxY + 8, footer.minY + 0.5)
            XCTAssertLessThanOrEqual(options.maxY, target.minY)
            XCTAssertTrue(footer.insetBy(dx: -0.5, dy: -0.5).contains(target))
            let lastID = try XCTUnwrap(store.memorySnapshot?.appsByResidentUsage.last).id
            let after = try await host.bottomFrames(required: ["lightfield.primary", "lightfield.primary.hitTarget",
                "lightfield.memory.overview", "lightfield.results.scrollViewport", "memory.row." + lastID], size: size, viewport: options)
            let bar = try XCTUnwrap(after["lightfield.primary"])
            XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(bar), "Quit controls remain visible: \(size)")
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(after["lightfield.primary.hitTarget"]).height, 44, "\(size)")
            XCTAssertEqual(try XCTUnwrap(after["lightfield.memory.overview"]), overview, "Overview stays visible after scrolling")
            XCTAssertEqual(bar, action)
            let last = try XCTUnwrap(after["memory.row." + lastID])
            XCTAssertGreaterThan(last.maxY, options.minY - 0.5, "Last app remains reachable: \(size)")
            XCTAssertLessThanOrEqual(last.maxY, options.maxY + 0.5)
        }
    }

    /// §2.3: large cards, buttons and artwork need a wide or tall window
    /// and the full-header height; 560–679 pt keeps the regular sizes.
    func testLargeCompositionNeedsTheFullHeaderHeight() {
        XCTAssertFalse(PageLayout.resolve(size: CGSize(width: 1_080, height: 560)).usesLargeComposition)
        XCTAssertFalse(PageLayout.resolve(size: CGSize(width: 1_080, height: 664)).usesLargeComposition)
        XCTAssertTrue(PageLayout.resolve(size: CGSize(width: 1_080, height: 712)).usesLargeComposition)
        XCTAssertTrue(PageLayout.resolve(size: CGSize(width: 870, height: 900)).usesLargeComposition)
        XCTAssertFalse(PageLayout.resolve(size: CGSize(width: 870, height: 712)).usesLargeComposition)
        XCTAssertFalse(PageLayout.resolve(size: CGSize(width: 2_000, height: 500)).usesLargeComposition)
    }

    /// Tests and previews resolve the legacy dynamic colors for one theme
    /// without touching a defaults domain (D48); the override never leaks.
    func testCanvasThemeOverrideIsScopedToItsBody() {
        let outside = AppCanvasTheme.current
        AppCanvasTheme.withCurrent(.pureBlack) {
            XCTAssertEqual(AppCanvasTheme.current, .pureBlack)
            XCTAssertLessThan(resolved(AppAppearanceColors.canvasTop, .dark).red, 0.025)
        }
        AppCanvasTheme.withCurrent(.deepSpace) {
            XCTAssertEqual(AppCanvasTheme.current, .deepSpace)
            let canvas = resolved(AppAppearanceColors.canvasTop, .dark)
            XCTAssertGreaterThan(canvas.blue, canvas.red + 0.05)
        }
        XCTAssertEqual(AppCanvasTheme.current, outside)
    }

    /// §3.3: the scanning sweep is a render-server layer animation that only
    /// exists in a window while work runs; Reduce Motion keeps it still.
    func testScanningSweepTurnsOnlyInAWindowAndNeverUnderReduceMotion() async {
        let view = OrbitSweepView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.configure(color: .systemBlue, turns: true)
        XCTAssertFalse(view.isTurning, "No window, no animation")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.isTurning, "A hidden window must not animate")
        window.orderFront(nil)
        await Task.yield()
        view.configure(color: .systemBlue, turns: true)
        XCTAssertTrue(view.isTurning)
        view.isHidden = true
        view.configure(color: .systemBlue, turns: true)
        XCTAssertFalse(view.isTurning, "Hidden view hierarchy stops the sweep")
        view.isHidden = false
        view.configure(color: .systemBlue, turns: false)
        XCTAssertFalse(view.isTurning, "Reduce Motion or a finished scan stops it")
        view.configure(color: .systemBlue, turns: true)
        window.contentView = NSView()
        XCTAssertFalse(view.isTurning, "Leaving the window stops it")
    }

    func testButtonStatesEvidence() throws {
        // Writes a PNG only when STORAGE_CLEANER_LAYOUT_EVIDENCE is set; the
        // assertions check that enabled and disabled destructive buttons are
        // rendered differently enough to tell apart.
        func sample(enabled: Bool, kind: GradientButtonStyle.Kind) -> some View {
            Button(enabled ? L10n.text("退出 3 个应用", "Quit 3 Apps") : L10n.text("清理所选", "Clean Selected")) {}
                .buttonStyle(GradientButtonStyle(kind: kind, size: .medium))
                .disabled(!enabled)
        }
        for scheme in [ColorScheme.dark, .light] {
            let view = HStack(spacing: 16) {
                sample(enabled: true, kind: .destructive)
                sample(enabled: false, kind: .destructive)
                sample(enabled: true, kind: .primary)
                sample(enabled: false, kind: .primary)
            }
            .padding(24)
            .background(scheme == .dark ? Color(white: 0.06) : Color(white: 0.94))
            .environment(\.colorScheme, scheme)
            .environment(\.moduleTheme, ReviewFilter.overview.moduleTheme)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 96)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["STORAGE_CLEANER_LAYOUT_EVIDENCE"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent("button-states-\(scheme == .dark ? "night" : "day").png"))
            }
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        }
        // Review 6: an unavailable filled button drops its color entirely,
        // so it never reads as a muted live one.
        for scheme in [ColorScheme.dark, .light] {
            let liveDanger = try fillColor(enabled: true, kind: .destructive, scheme: scheme)
            let deadDanger = try fillColor(enabled: false, kind: .destructive, scheme: scheme)
            let livePrimary = try fillColor(enabled: true, kind: .primary, scheme: scheme)
            let deadPrimary = try fillColor(enabled: false, kind: .primary, scheme: scheme)
            XCTAssertGreaterThan(liveDanger.red - liveDanger.green, 0.3, "\(scheme)")
            XCTAssertGreaterThan(livePrimary.blue - livePrimary.red, 0.3, "\(scheme)")
            for dead in [deadDanger, deadPrimary] {
                let channels = [dead.red, dead.green, dead.blue]
                XCTAssertLessThan((channels.max() ?? 0) - (channels.min() ?? 0), 0.06, "\(scheme): \(dead)")
            }
        }
    }

    // MARK: Helpers

    /// The fill of a full-width button, sampled beside its centered label.
    private func fillColor(enabled: Bool, kind: GradientButtonStyle.Kind,
                           scheme: ColorScheme) throws -> (red: Double, green: Double, blue: Double) {
        let view = Button("OK") {}
            .buttonStyle(GradientButtonStyle(kind: kind, size: .medium, fillsWidth: true))
            .disabled(!enabled)
            .frame(width: 220, height: 40)
            .padding(10)
            .background(scheme == .dark ? Color(white: 0.06) : Color(white: 0.94))
            .environment(\.colorScheme, scheme)
            .environment(\.moduleTheme, ReviewFilter.overview.moduleTheme)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 240, height: 60)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        // 50 pt in from the left edge, vertically centered: inside the fill,
        // clear of the label, the rim and the corner radius.
        let x = Int(Double(bitmap.pixelsWide) * 50 / 240)
        let y = bitmap.pixelsHigh / 2
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }

    private func luminance(_ rgb: UInt32) -> Double {
        func linear(_ channel: UInt32) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear((rgb >> 16) & 0xff) + 0.7152 * linear((rgb >> 8) & 0xff) + 0.0722 * linear(rgb & 0xff)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let first = luminance(a), second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func resolved(_ color: Color, _ scheme: ColorScheme) -> Color.Resolved {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        return color.resolve(in: environment)
    }
}

struct LayoutNotSettled: Error, CustomStringConvertible {
    let missing: [String]
    var description: String { "Layout did not settle; missing probes: \(missing)" }
}

/// A window hosting a view at an exact size and collecting layout probes.
@MainActor
final class V0LayoutHost {
    private final class Recorder {
        var frames: [String: CGRect] = [:]
    }

    let window: NSWindow
    private let recorder = Recorder()
    private let controller: NSHostingController<AnyView>

    /// `accessibility` turns on SwiftUI's accessibility tree for this inert
    /// host (the environment an assistive technology would set; no macOS
    /// preference changes), for tests that read it.
    init<Content: View>(root: Content, size: CGSize, dark: Bool = true, accessibility: Bool = false) {
        let recorder = self.recorder
        controller = NSHostingController(rootView: AnyView(
            root
                // D141: the V0 layouts this host checks are now the classic
                // view; the studio pages have their own tests.
                .environment(\.careStudioClassicResults, true)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: LayoutFramePreferenceKey.self,
                                           value: ["v0.viewport": proxy.frame(in: .global)])
                })
                .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                    Task { @MainActor in recorder.frames = frames }
                }
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.accessibilityEnabled, accessibility)
        ))
        controller.sizingOptions = []
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentViewController = controller
        window.setContentSize(size)
    }

    func resize(to size: CGSize) {
        window.setContentSize(size)
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The hosting view, for accessibility queries.
    var hostingView: NSView { controller.view }

    /// One layout pass and a short wait, for state changes made by a test.
    func settle(milliseconds: UInt64 = 20) async {
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        await Task.yield()
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    /// The probe frames recorded so far, without waiting for them to settle.
    var currentFrames: [String: CGRect] { recorder.frames }

    /// One synchronous layout pass, without yielding to other main-actor
    /// work (tests that control what runs before a view's task).
    func layoutNow() {
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func frames(required: Set<String>) async throws -> [String: CGRect] {
        var last: [String: CGRect]?
        var stable = 0
        for _ in 0..<160 {
            controller.view.needsLayout = true
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
            try await Task.sleep(nanoseconds: 5_000_000)
            let frames = recorder.frames
            guard required.isSubset(of: Set(frames.keys)) else { continue }
            if frames == last {
                stable += 1
                if stable >= 3 { return frames }
            } else {
                stable = 0
                last = frames
            }
        }
        let missing = required.subtracting(recorder.frames.keys).sorted()
        // An explicit failure names what never appeared or settled; a thrown
        // error alone reaches the log only as a generic test-harness failure.
        XCTFail(missing.isEmpty
            ? "Layout probes did not settle: \(required.sorted())"
            : "Layout probes did not appear: \(missing)")
        throw LayoutNotSettled(missing: missing)
    }

    func close() {
        window.close()
    }
}
#endif
