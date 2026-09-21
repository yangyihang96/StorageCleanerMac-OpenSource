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
            [LayoutProbeID.landingScopeCard(index), LayoutProbeID.landingScopeIcon(index), LayoutProbeID.landingScopeTitle(index)]
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
                let icon = try frame(LayoutProbeID.landingScopeIcon(index), in: frames)
                let title = try frame(LayoutProbeID.landingScopeTitle(index), in: frames)
                XCTAssertTrue(card.contains(icon))
                XCTAssertTrue(card.contains(title))
                XCTAssertLessThanOrEqual(icon.maxY, title.minY + 1)
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
            LayoutProbeID.landingActionButton
        ]
        for size in sizes {
            host.resize(to: size)
            let frames = try await host.waitForFrames(required: required)
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
            for index in 0..<3 {
                let card = try frame(LayoutProbeID.landingScopeCard(index), in: frames)
                XCTAssertTrue(panel.contains(card), sizeDescription(size))
            }
            if size.height < 520 {
                let revision = host.recorder.revision
                try host.scrollPageToBottom()
                let scrolled = try await host.waitForFrames(required: required, afterRevision: revision)
                let visibleFooter = try frame(LayoutProbeID.landingFooter, in: scrolled)
                let viewport = try frame(LayoutProbeID.pageViewport, in: scrolled)
                XCTAssertLessThanOrEqual(visibleFooter.maxY, viewport.maxY + 1, sizeDescription(size))
                XCTAssertGreaterThanOrEqual(visibleFooter.minY, viewport.minY, sizeDescription(size))
            }
        }
    }

    func testRuntimeStatesKeepPanelsAndLongPathsStableAcrossWindowSizes() async throws {
        let sizes = [CGSize(width: 1024, height: 734), CGSize(width: 604, height: 490), CGSize(width: 473, height: 360)]
        let required: Set<String> = [LayoutProbeID.smartScanHeader, LayoutProbeID.runtimePanel,
            LayoutProbeID.runtimeLocation, LayoutProbeID.runtimeViewport, LayoutProbeID.pageViewport, LayoutProbeID.smartScanFooter]
        for module in [ReviewFilter.overview, .green, .devCaches] {
            let fixture = RuntimeLayoutFixture()
            let theme = ModuleThemeCatalog.theme(for: module)
            let root = AdaptivePageViewport {
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
                    let frames = try await host.waitForFrames(required: required)
                    let panel = try frame(LayoutProbeID.runtimePanel, in: frames)
                    let location = try frame(LayoutProbeID.runtimeLocation, in: frames)
                    let header = try frame(LayoutProbeID.smartScanHeader, in: frames)
                    let footer = try frame(LayoutProbeID.smartScanFooter, in: frames)
                    let iconSide = size.height < 560 ? 64 : GoldenLandingMetrics.headerIconSide(for: module.systemImage)
                    XCTAssertGreaterThanOrEqual(header.height, iconSide + 2 * AppDesignTokens.Spacing.medium)
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
        let store = makeSmartScanContext(scanGate: LayoutCleanupScanGate()).scanStore
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
        let store = makeSmartScanContext(scanGate: LayoutCleanupScanGate()).scanStore
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
                let revision = host.recorder.revision
                try host.scrollPageToBottom()
                let scrolled = try await host.waitForFrames(required: required, afterRevision: revision)
                let footer = try frame(LayoutProbeID.smartScanFooter, in: scrolled)
                let viewport = try frame(LayoutProbeID.pageViewport, in: scrolled)
                XCTAssertLessThanOrEqual(footer.maxY, viewport.maxY + 1)
                XCTAssertGreaterThanOrEqual(footer.minY, viewport.minY)
            }
        }
    }

    func testSmartScanOneButtonIdleAndActivePagesKeepWindowStable() async throws {
        let size = CGSize(width: 980, height: 680)
        let scanGate = LayoutCleanupScanGate()
        let context = makeSmartScanContext(scanGate: scanGate)
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
                XCTAssertEqual(cards[2].maxX, content.maxX, accuracy: 1)
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
        let scanStore = ScanStore(
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
            computerHealthStore: ComputerHealthStore(),
            networkSpeedTestStore: NetworkSpeedTestStore(
                heavyWorkCoordinator: heavyWorkCoordinator,
                heavyWorkActivityStore: heavyWorkActivityStore
            ),
            macBenchmarkStore: makeMacBenchmarkStore(),
            heavyWorkActivityStore: heavyWorkActivityStore,
            scanner: scanner
        )
    }

    private func makeSmartScanContext(scanGate: LayoutCleanupScanGate) -> LayoutContext {
        let scanner = LayoutBrowserPrivacyScanner(response: PrivacyLayoutFixture.idle.response)
        let browserPrivacyStore = BrowserPrivacyStore(scanner: scanner)
        let heavyWorkCoordinator = HeavyWorkCoordinator()
        let heavyWorkActivityStore = HeavyWorkActivityStore(
            coordinator: heavyWorkCoordinator
        )
        let rules = LayoutCleanupScanGate.ruleSet
        let scanStore = ScanStore(
            heavyWorkCoordinator: heavyWorkCoordinator,
            heavyWorkActivityStore: heavyWorkActivityStore,
            restoreSavedAccessOperation: {},
            loadScanReadinessSummary: { ScanReadinessSummary(items: []) },
            historyLoader: EmptyLayoutHistoryLoader(),
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
            computerHealthStore: ComputerHealthStore(),
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
            historyRepository: EmptyLayoutBenchmarkHistoryRepository()
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
            macBenchmarkLeaderboardStore: BenchmarkV7LeaderboardStore(),
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
            let path = "\(PathSafety.homePath)/Library/Caches/LayoutFixture/\(index)"
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
private final class AppKitLayoutHost {
    let recorder = LayoutFrameRecorder()
    let window: NSWindow
    private let hostingController: NSHostingController<AnyView>

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

        window = NSWindow(
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

    private func pageScrollView() -> NSScrollView? {
        func find(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return window.contentView.flatMap { find(in: $0) }
    }

    func waitForFrames(
        required: Set<String>,
        afterRevision: Int? = nil,
        privacyProbeExpected: Bool? = nil,
        stablePassesRequired: Int = 3
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
            let privacyExpectationMet: Bool
            if let privacyProbeExpected {
                privacyExpectationMet = (frames[LayoutProbeID.privacy] != nil)
                    == privacyProbeExpected
            } else {
                privacyExpectationMet = true
            }

            if hasRequiredFrames, passedRevision, privacyExpectationMet {
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

        throw LayoutHarnessError.framesDidNotSettle(
            required: required,
            available: Set(recorder.frames.keys).union([LayoutProbeID.contentLayout]),
            revision: recorder.revision
        )
    }

    func close() {
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
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
            "布局未稳定；required=\(required.sorted())，available=\(available.sorted())，revision=\(revision)"
        }
    }
}
#endif
