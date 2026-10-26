import AppKit
import XCTest
@testable import StorageCleanerMac

final class UIConsistencyRegressionTests: XCTestCase {
    func testLandingScopeAndArtworkSymbolsExistOnTheRunningSystem() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/FileToolLandingPage.swift")
        let text = source as NSString
        let pattern = try NSRegularExpression(pattern: #"node\("([^"]+)""#)
        let symbols = Set(pattern.matches(in: source, range: NSRange(location: 0, length: text.length))
            .map { text.substring(with: $0.range(at: 1)) })
        XCTAssertFalse(symbols.isEmpty)
        for symbol in symbols {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }
    func testMainWindowSettingsAndItemBrowserUseNativeMacOSStructure() throws {
        let content = try sourceText(at: "Sources/StorageCleanerMac/Views/ContentView.swift")
        let sidebar = try sourceText(at: "Sources/StorageCleanerMac/Views/SidebarView.swift")
        let modulePresentation = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ModulePresentation.swift"
        )
        let itemList = try sourceText(at: "Sources/StorageCleanerMac/Views/ItemListView.swift")
        let settings = try sourceText(at: "Sources/StorageCleanerMac/Views/SettingsView.swift")
        let scanStore = try sourceText(at: "Sources/StorageCleanerMac/Stores/ScanStore.swift")
        let openPanelCoordinator = try sourceText(
            at: "Sources/StorageCleanerMac/Support/AppOpenPanelCoordinator.swift"
        )

        XCTAssertTrue(content.contains("NavigationSplitView"))
        XCTAssertTrue(content.contains("MainContentHost("))
        XCTAssertTrue(content.contains("showsIntegratedTitlebar: false"))
        XCTAssertTrue(content.contains("MainWindowChromeConfigurator()"))
        XCTAssertFalse(content.contains("ToolbarItem(placement: .primaryAction)"))
        XCTAssertFalse(content.contains("SettingsLink"))
        // D154: CleanMyMac has no Settings row in its sidebar; Settings opens
        // from the app menu (⌘,). The foot keeps the version line.
        XCTAssertFalse(sidebar.contains("SettingsLink"))
        XCTAssertTrue(sidebar.contains("private var footerLine: some View"))
        XCTAssertTrue(modulePresentation.contains("struct MainContentHost<Content: View>: View"))
        XCTAssertTrue(itemList.contains("ItemListResponsiveLayout.mode(availableWidth:"))
        XCTAssertFalse(itemList.contains("HSplitView"))
        XCTAssertTrue(itemList.contains(".appSelectableRowSurface("))
        XCTAssertGreaterThanOrEqual(occurrences(of: "LightfieldSettingsSection {", in: settings), 5)
        // D154 batch 3I (the user's decision, 2026-10-21): CleanMyMac's tabs
        // across the top replace the D3/D53 settings sidebar; the tabs keep
        // the categories, the selection binding and arrow-key movement (was
        // `private var settingsSidebar: some View` and
        // `SettingsLightfieldPane(category: category)`).
        XCTAssertTrue(settings.contains("private var settingsTabBar: some View"))
        XCTAssertTrue(settings.contains("SettingsLightfieldPane(category: category, drawsBackdrop: false)"))
        XCTAssertTrue(settings.contains("ForEach(SettingsCategory.allCases)"))
        XCTAssertTrue(settings.contains("settingsSelection.wrappedValue = category"))
        XCTAssertTrue(settings.contains(".onMoveCommand { direction in"))
        // D53 §3.2.2 still gives the main window's sidebar its sliding
        // module-gradient block.
        XCTAssertTrue(sidebar.contains("struct SidebarRowBackground: View"))
        XCTAssertTrue(sidebar.contains("SidebarSelectionBlock(family: family, onStudio: onStudio)"))
        XCTAssertTrue(sidebar.contains(".matchedGeometryEffect(id: \"sidebar.selection\", in: namespace)"))
        XCTAssertTrue(settings.contains("RoundedRectangle(cornerRadius: 8)"))
        XCTAssertTrue(settings.contains(".fill(FeatureLightfieldPalette.accent(.overview).opacity"))
        XCTAssertFalse(settings.contains("AppAppearanceColors.selectedSurface"))
        // Tab focus and B2 row interaction remain accessible.
        XCTAssertTrue(settings.contains(".focusEffectDisabled()"))
        XCTAssertTrue(settings.contains(".buttonStyle(FeatureLightfieldRowButtonStyle())"))
        // The tabs sit above the pane at every supported window width
        // (`SettingsLightfieldGeometryTests` checks them in a window; was a
        // fixed sidebar beside it: `settingsSidebar.frame(width:
        // viewport.size.width < 820 ? 180 : FeatureLightfield.sidebarWidth)`
        // in an `HStack(spacing: 0)`).
        XCTAssertTrue(settings.contains("SettingsTabBar(selected: selectedCategory)"))
        XCTAssertTrue(settings.contains("VStack(spacing: 0)"))
        XCTAssertFalse(settings.contains("settingsSidebar"))
        XCTAssertFalse(settings.contains("List(selection: settingsSelection)"))
        XCTAssertTrue(settings.contains("settingsPane(for: selectedCategory)"))
        XCTAssertTrue(settings.contains("FeatureLightfieldHairline()"))
        XCTAssertTrue(settings.contains("if category == .accessAndSetup"))
        XCTAssertEqual(occurrences(of: ".formStyle(", in: settings), 0)
        XCTAssertFalse(settings.contains("runModal()"))
        XCTAssertFalse(scanStore.contains("runModal()"))
        XCTAssertTrue(settings.contains("exclusionPanelCoordinator.present("))
        XCTAssertTrue(scanStore.contains("folderAccessPanelCoordinator.present("))
        XCTAssertTrue(openPanelCoordinator.contains("panel.beginSheetModal(for: hostWindow"))
        XCTAssertTrue(openPanelCoordinator.contains("maximumSheetDismissalChecks"))
        XCTAssertTrue(openPanelCoordinator.contains("hostWindow.attachedSheet == nil"))
    }

    func testSettingsUseLightfieldRowsAndKeepGeekPanelConfigurationCompact() throws {
        let settings = try sourceText(at: "Sources/StorageCleanerMac/Views/SettingsView.swift")
        let tokens = try sourceText(
            at: "Sources/StorageCleanerMac/Support/AppDesignTokens.swift"
        )
        let panelSettings = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarPanelSettingsView.swift"
        )
        let panelChrome = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift"
        )

        // D154 batch 3I: the tabs replace the sidebar (was
        // `private var settingsSidebar: some View`).
        XCTAssertTrue(settings.contains("private var settingsTabBar: some View"))
        XCTAssertTrue(settings.contains("FeatureLightfieldRowButtonStyle()"))
        XCTAssertTrue(settings.contains("settingsPane(for: selectedCategory)"))
        XCTAssertTrue(settings.contains("FeatureLightfieldHairline()"))
        XCTAssertEqual(occurrences(of: ".formStyle(", in: settings), 0)
        XCTAssertTrue(settings.contains("SettingsLightfieldGeometry(size: viewport.size, category: category)"))
        XCTAssertTrue(settings.contains("settings.selected-category.v1"))
        XCTAssertGreaterThanOrEqual(occurrences(of: "LabeledContent(", in: settings), 8)
        XCTAssertFalse(settings.contains("ForEach(PanelDensity.menuBarChoices)"))
        XCTAssertFalse(panelChrome.contains("ForEach(PanelDensity.menuBarChoices)"))
        XCTAssertFalse(panelChrome.contains("Picker(L10n.text(\"面板模式\", \"Panel Mode\")"))
        XCTAssertTrue(panelChrome.contains("Panel Settings…"))
        XCTAssertTrue(panelChrome.contains("启动时恢复小窗"))
        XCTAssertFalse(panelSettings.contains("struct PanelSettingsView: View"))
        XCTAssertFalse(panelSettings.contains("Form {"))
        XCTAssertFalse(settings.contains("AdvancedMonitorWindowCoordinator"))
        XCTAssertFalse(settings.contains("打开高级监控"))
        XCTAssertTrue(settings.contains("DisclosureGroup"))
        XCTAssertTrue(settings.contains("L10n.text(\"关于\", \"About\")"))
        XCTAssertFalse(settings.contains("SettingsMetricPill"))
        XCTAssertFalse(settings.contains("headerSection"))
        XCTAssertFalse(settings.contains(".appGlassSegmentedControl("))
        XCTAssertTrue(settings.contains("FeatureLightfieldBackdrop(module: .overview"))
        XCTAssertTrue(settings.contains(".environment(\\.moduleTheme, settingsTheme)"))
        XCTAssertTrue(settings.contains("ScrollView {"))
        XCTAssertFalse(settings.contains(".background(AppDesignTokens.Palette.contentBackground)"))
        XCTAssertTrue(tokens.contains("static let settingsPageMaxWidth: CGFloat = 600"))
    }

    func testSettingsConsolidatesAccessStatusAndJumpsWithoutRedundantTutorial() throws {
        let settings = try sourceText(at: "Sources/StorageCleanerMac/Views/SettingsView.swift")
        let onboarding = try sourceText(
            at: "Sources/StorageCleanerMac/Views/FirstLaunchOnboardingView.swift"
        )

        XCTAssertTrue(settings.contains("case accessAndSetup"))
        XCTAssertTrue(settings.contains("SettingsPermissionRow("))
        XCTAssertTrue(onboarding.contains("PermissionSetupCard("))
        // D64 #9 replaces the duplicated tutorial with permission cards and paths.
        XCTAssertFalse(settings.contains("var permissionTutorialSection"))
        XCTAssertFalse(settings.contains("SettingsTutorialStep("))
        XCTAssertTrue(onboarding.contains("Text(requirement)"))
        XCTAssertTrue(onboarding.contains("Text(guide)"))
        XCTAssertTrue(settings.contains("openFullDiskAccessSettings()"))
        XCTAssertTrue(settings.contains("openFilesAndFoldersSettings()"))
        XCTAssertTrue(settings.contains("openAppManagementSettings()"))
        XCTAssertTrue(settings.contains("Privacy_AppBundles"))
        XCTAssertTrue(settings.contains("fanControl.openApprovalSettings()"))
        XCTAssertTrue(settings.contains("com.apple.Notifications-Settings.extension"))
        // Keep the network-consent boundary formerly embedded in the tutorial.
        XCTAssertTrue(settings.contains("公网 IP 可关闭，地区查询须另行同意"))
        XCTAssertTrue(settings.contains("public-IP lookup can be turned off, and region lookup requires separate consent"))
        XCTAssertTrue(settings.contains("Text(PermissionSafetyDisclosure.unneededAccess.text)"))
        for word in ["辅助功能", "屏幕录制", "相机", "麦克风", "定位", "自动化"] {
            XCTAssertTrue(PermissionSafetyDisclosure.unneededAccess.chinese.contains(word), word)
        }
        for word in ["Accessibility", "Screen Recording", "Camera", "Microphone", "Location", "Automation"] {
            XCTAssertTrue(PermissionSafetyDisclosure.unneededAccess.english.contains(word), word)
        }
        XCTAssertFalse(settings.contains("AXIsProcessTrusted"))
        XCTAssertFalse(settings.contains("CGRequestScreenCaptureAccess"))
    }

    func testSharedEmptyStateStaysFlatWhileSmartScanUsesDedicatedStage() throws {
        let components = try sourceText(at: "Sources/StorageCleanerMac/Views/SmartCareComponents.swift")
        let content = try sourceText(at: "Sources/StorageCleanerMac/Views/ContentView.swift")
        let modulePresentation = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ModulePresentation.swift"
        )
        let smartScan = try sourceText(at: "Sources/StorageCleanerMac/Views/SmartScanProgressView.swift")
        let overview = try sourceText(at: "Sources/StorageCleanerMac/Views/OverviewView.swift")
        let cleanupOverlay = try sourceText(at: "Sources/StorageCleanerMac/Views/CleanupOperationOverlay.swift")
        let cleanupExecution = try sourceText(at: "Sources/StorageCleanerMac/Views/CleanupExecutionViews.swift")
        let itemList = try sourceText(at: "Sources/StorageCleanerMac/Views/ItemListView.swift")
        let health = try sourceText(at: "Sources/StorageCleanerMac/Views/ComputerHealthView.swift")
        let benchmark = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7DashboardView.swift"
        )
        let rawResults = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/MSeriesRawResultView.swift"
        )
        let leaderboard = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7LeaderboardSection.swift"
        )
        let largeFiles = try sourceText(at: "Sources/StorageCleanerMac/Views/LargeFilesView.swift")
        let utilities = try sourceText(at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let startupItems = try sourceText(
            at: "Sources/StorageCleanerMac/Features/StartupItems/Views/StartupItemsDashboardView.swift"
        )
        let appUpdates = try sourceText(
            at: "Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift"
        )
        let emptyState = try sourceSegment(
            components,
            from: "struct AppEmptyState<Action: View>: View {",
            to: "struct AppPageHeader<Actions: View>: View {"
        )
        let readyStage = try sourceSegment(
            smartScan,
            from: "struct SmartScanReadyStage: View {",
            to: "struct ScanProgressView: View {"
        )
        let benchmarkEmptyState = try sourceSegment(
            benchmark,
            from: "private var latestResultCard: some View {",
            to: "private func metricSummary("
        )
        let cleanupProgressPage = try sourceSegment(
            cleanupExecution,
            from: "struct SmartScanCleanupProgressPage: View {",
            to: "struct SmartScanCleanupCompletedPage: View {"
        )

        XCTAssertTrue(components.contains("enum AppEmptyStateDensity"))
        XCTAssertTrue(components.contains("case workspace"))
        XCTAssertTrue(components.contains("case inline"))
        XCTAssertTrue(emptyState.contains("private let action: Action"))
        XCTAssertTrue(emptyState.contains("@ViewBuilder action: () -> Action"))
        XCTAssertTrue(components.contains("struct AppStateIconRing: View"))
        XCTAssertFalse(components.contains("TimelineView(.animation("))
        XCTAssertTrue(components.contains("var progress: Double? = nil"))
        XCTAssertTrue(components.contains("if progress != nil {"))
        XCTAssertTrue(components.contains("} else if isActive {\n                ProgressView()"))
        // D64: inactive decorative glyphs own no slot; real progress and results remain.
        XCTAssertTrue(components.contains(".frame(width: renderedSize, height: renderedSize)"))
        XCTAssertTrue(components.contains("return isActive || showsStaticStatus ? 32 : 0"))
        XCTAssertFalse(components.contains("progress ?? (isActive ? 0.18 : 0)"))
        XCTAssertFalse(components.contains("progress ?? 0.70"))
        XCTAssertTrue(emptyState.contains("if isLoading {\n                AppStateIconRing(systemImage: systemImage, isActive: isLoading)"))
        XCTAssertFalse(emptyState.contains("size: density"))
        XCTAssertGreaterThanOrEqual(
            occurrences(of: ".frame(maxWidth: .infinity, alignment: .center)", in: emptyState),
            2
        )
        XCTAssertFalse(emptyState.contains(".lineLimit(1)"))
        XCTAssertTrue(emptyState.contains("minHeight: density == .workspace ? 220 : 150"))
        XCTAssertFalse(emptyState.contains(".glassPanel("))
        XCTAssertFalse(emptyState.contains("RoundedRectangle("))
        XCTAssertFalse(emptyState.contains(".background("))
        XCTAssertTrue(content.contains("HeroScanPage("))
        XCTAssertTrue(content.contains("MainContentHost("))
        XCTAssertTrue(content.contains("showsIntegratedTitlebar: false"))
        XCTAssertTrue(modulePresentation.contains("struct HeroScanPage<Accessory: View>: View"))
        XCTAssertTrue(modulePresentation.contains("FileToolLandingPage("))
        XCTAssertFalse(modulePresentation.contains("struct PrimaryActionTile: View"))
        XCTAssertTrue(modulePresentation.contains("struct ScanStatusView: View"))
        XCTAssertTrue(smartScan.contains("struct SmartScanReadyStage: View"))
        XCTAssertTrue(readyStage.contains("AppStateIconRing(systemImage: systemImage, isActive: isLoading)"))
        XCTAssertFalse(readyStage.contains("Circle()"))
        XCTAssertTrue(smartScan.contains("struct ScanProgressView: View"))
        XCTAssertTrue(smartScan.contains("FeatureRunningTemplate(")) // D62② shared progress card
        XCTAssertTrue(smartScan.contains("ModuleScanProgressHero(progress: progress)"))
        XCTAssertTrue(smartScan.contains("struct SmartScanThinProgressBar: View"))
        XCTAssertTrue(smartScan.contains("struct ModuleScanProgressRing: View"))
        XCTAssertTrue(smartScan.contains("progress.progressKind"))
        XCTAssertTrue(smartScan.contains(".trim(from: 0, to: progressFraction)"))
        XCTAssertFalse(smartScan.contains(".trim(from: 0, to: 0.22)"))
        XCTAssertTrue(smartScan.contains(".frame(width: side, height: side)"))
        XCTAssertFalse(smartScan.contains("ScanProgressStatusItem("))
        XCTAssertTrue(smartScan.contains(".progressViewStyle(.linear)"))
        XCTAssertTrue(smartScan.contains("minHeight: 44"))
        XCTAssertTrue(smartScan.contains("只读扫描 · 清理前逐项确认"))
        XCTAssertTrue(smartScan.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertFalse(smartScan.contains("TimelineView(.animation(minimumInterval: 1.0 / 30.0))"))
        XCTAssertTrue(smartScan.contains("ScrollView {"))
        XCTAssertTrue(smartScan.contains("struct SmartScanResultRing: View"))
        XCTAssertTrue(overview.contains("SmartScanResultRing("))
        XCTAssertTrue(overview.contains("tierSection"))
        XCTAssertTrue(overview.contains("L10n.text(\"选择清理项目\", \"Choose Cleanup Items\")"))
        XCTAssertTrue(content.contains("@State private var selectedItemIDs = Set<String>()"))
        XCTAssertTrue(content.contains("CleanupSelectionGroupView("))
        XCTAssertTrue(content.contains(".toggleStyle(.checkbox)"))
        XCTAssertTrue(content.contains("confirmTrashAllGreen(selectedItemIDs: selectedItemIDs)"))
        XCTAssertTrue(itemList.contains("L10n.text(\"选择清理项目\", \"Choose Cleanup Items\")"))
        XCTAssertTrue(cleanupOverlay.contains("struct CleanupOperationOverlay: View"))
        XCTAssertTrue(cleanupOverlay.contains("AppStateIconRing("))
        XCTAssertFalse(cleanupOverlay.contains("ProgressView()"))
        XCTAssertTrue(cleanupExecution.contains("progress: progress.totalItemCount > 0"))
        XCTAssertTrue(cleanupProgressPage.contains("CleanupExecutionStageList("))
        XCTAssertFalse(cleanupProgressPage.contains("ProgressView()"))
        XCTAssertTrue(cleanupExecution.contains("private struct CleanupExecutionStageRow: View"))
        XCTAssertTrue(cleanupExecution.contains("ProgressView()"))
        XCTAssertTrue(cleanupExecution.contains(".controlSize(.small)"))
        XCTAssertTrue(cleanupOverlay.contains("清空废纸篓后才会真正释放空间"))
        XCTAssertTrue(health.contains("healthEmptyState"))
        XCTAssertTrue(health.contains("FeatureLightfieldPage("))
        XCTAssertFalse(health.contains("AppEmptyState("))
        XCTAssertTrue(health.contains("actionEnabled: !healthStore.isRefreshing"))
        XCTAssertTrue(benchmarkEmptyState.contains("尚未完成当前版本的性能测试"))
        XCTAssertTrue(rawResults.contains("awaiting reference calibration"))
        XCTAssertTrue(leaderboard.contains("正在读取全球排行榜"))
        XCTAssertTrue(benchmark.contains("BenchmarkV7RunProgressView("))
        XCTAssertTrue(benchmark.contains("transaction.animation = reduceMotion ? nil : transaction.animation"))
        XCTAssertFalse(rawResults.contains("ProgressView("))
        XCTAssertTrue(leaderboard.contains("ProgressView()"))
        let migration = try sourceText(at: "Sources/StorageCleanerMac/Views/FilesLightfield/FileMigrationLightfieldView.swift")
        // D70: the bounded result body owns empty/search states, without a second card.
        XCTAssertTrue(largeFiles.contains("FileMigrationLightfieldView("))
        XCTAssertTrue(migration.contains("if visibleEntries.isEmpty"))
        XCTAssertTrue(migration.contains("尚无可安全搬移的文件"))
        XCTAssertTrue(utilities.contains("density: .workspace"))
        XCTAssertTrue(utilities.contains("density: .inline"))
        XCTAssertTrue(startupItems.contains("if presentation.visibleItems.isEmpty"))
        XCTAssertTrue(startupItems.contains("Text(isLoading ? (progress?.title"))
        XCTAssertTrue(startupItems.contains("isPerformingOperation: isPerformingOperation || isLoading"))
        XCTAssertTrue(appUpdates.contains("AppUpdateScanningPage("))
        XCTAssertTrue(appUpdates.contains("RuntimeActivityCard("))
        XCTAssertTrue(startupItems.contains("progress?.title ?? L10n.text(\"正在读取启动项\", \"Reading Startup Items\")"))
        XCTAssertTrue(startupItems.contains(".onTapGesture { selectedItemID = item.id }"))
        XCTAssertTrue(startupItems.contains(".id(item.id)"))
        XCTAssertTrue(appUpdates.contains("fraction: progress.progressFraction"))
        let results = try sourceText(at: "Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldComponents.swift")
        XCTAssertTrue(startupItems.contains("No Items Match These Filters"))
        XCTAssertTrue(startupItems.contains("Reading Startup Items"))
        XCTAssertTrue(startupItems.contains("LightfieldResultContent(listHeader:"))
        XCTAssertTrue(results.contains("LazyVStack(spacing: 0) { rows }"))
        XCTAssertFalse(startupItems.contains("AppEmptyState("))
    }

    func testV2SmartScanShowsCleanupSelectionWithoutNavigatingAway() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/CleanupScanViews.swift")
        let overview = try sourceSegment(
            source,
            from: "struct CleanupScanOverviewView: View {",
            to: "struct CleanupScanResultsView: View {"
        )

        XCTAssertTrue(overview.contains("CleanupScanResultsView("))
        XCTAssertTrue(overview.contains("filter: .overview"))
        // D64④ adds a real health-only result. That branch owns its single
        // header; file results still reuse the cleanup view's existing header.
        let fileResults = try sourceSegment(overview, from: "            } else {", to: "        }\n        .frame(")
        XCTAssertFalse(fileResults.contains("AppPageHeader("))
        XCTAssertEqual(occurrences(of: "AppPageHeader(", in: overview), 1)
        XCTAssertTrue(overview.contains("if session.smartScanScopes == [.health]"))
        XCTAssertTrue(overview.contains("SmartScanPageShell(alignsWithFeatureFlow: true)"))
        XCTAssertTrue(overview.contains("SmartScanHealthResultsView(snapshot: session.smartScanHealthSnapshot, status: session.smartScanHealthStatus)"))
        XCTAssertFalse(overview.contains("store.showCleanupReview()"))
        XCTAssertFalse(overview.contains("@Binding var selection"))
    }

    func testSmartScanFlowUsesOneMutuallyExclusivePageInsteadOfLayeredTransitions() throws {
        let content = try sourceText(at: "Sources/StorageCleanerMac/Views/ContentView.swift")
        let flowHost = try sourceSegment(
            content,
            from: "private struct SmartScanFlowHost: View {",
            to: "private struct SmartScanTerminalPage: View {"
        )

        XCTAssertTrue(flowHost.contains("switch store.scanPresentationState"))
        for stateCase in [
            "case .idle:",
            "case .preparing, .scanning, .finalizing:",
            "case .cancelling:",
            "case .results, .confirming:",
            "case .cleaning:",
            "case .verifying:",
            "case .completed:",
            "case .cancelled:",
            "case .failed:"
        ] {
            XCTAssertTrue(flowHost.contains(stateCase), "缺少 Smart Scan 展示状态：\(stateCase)")
        }
        XCTAssertTrue(flowHost.contains("SmartScanScanningPage("))
        XCTAssertTrue(flowHost.contains("CleanupScanOverviewView("))
        XCTAssertTrue(flowHost.contains("SmartScanCleanupProgressPage("))
        XCTAssertTrue(flowHost.contains("SmartScanCleanupCompletedPage("))
        // D53 §3.2.3: the stages stay mutually exclusive; only the change of
        // stage uses the shared page transition (no local layering).
        XCTAssertTrue(flowHost.contains("PageTransitionContainer(key: flowStage)"))
        XCTAssertFalse(flowHost.contains("ZStack"))
        XCTAssertFalse(flowHost.contains(".pageTransition("))
        XCTAssertFalse(flowHost.contains("CleanupV2OperationOverlay"))
        XCTAssertFalse(content.contains("CleanupV2OperationOverlay"))
    }

    func testSmartScanResultsPrioritizeDecisionListAndCollapseSecondaryDetails() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/CleanupScanViews.swift")
        let results = try sourceSegment(
            source,
            from: "struct CleanupScanResultsView: View {",
            to: "private enum CleanupResultFilter: String, CaseIterable, Identifiable {"
        )
        let body = try sourceSegment(
            results,
            from: "var body: some View {",
            to: "private var resultHeader: some View {"
        )
        let actionBar = try sourceSegment(
            results,
            from: "private var cleanupActionBar: some View {",
            to: "private func matchesCurrentFilter(_ candidate: ScanCandidate) -> Bool {"
        )
        let secondaryDetails = try sourceSegment(
            results,
            from: "private var secondaryDetailsSection: some View {",
            to: "private func discoveredBytes("
        )

        XCTAssertTrue(body.contains("resultHeader"))
        XCTAssertTrue(body.contains("SmartScanPageShell"))
        XCTAssertTrue(body.contains("riskSummary"))
        XCTAssertTrue(body.contains("selectionToolbar"))
        XCTAssertTrue(body.contains("tierSection("))
        XCTAssertTrue(body.contains("secondaryDetailsSection"))
        XCTAssertTrue(body.contains("cleanupActionBar"))
        XCTAssertEqual(occurrences(of: "ScrollView {", in: body), 1)
        XCTAssertTrue(body.contains("LazyVStack("))
        let headerRange = try XCTUnwrap(body.range(of: "resultHeader"))
        let scrollRange = try XCTUnwrap(body.range(of: "ScrollView {"))
        let footerRange = try XCTUnwrap(body.range(of: "cleanupActionBar"))
        XCTAssertLessThan(headerRange.lowerBound, scrollRange.lowerBound)
        XCTAssertGreaterThan(footerRange.lowerBound, scrollRange.lowerBound)

        let orderedSections = [
            "riskSummary",
            "selectionToolbar",
            "risk: .safe",
            "risk: .reviewOnly",
            "risk: .protected",
            "secondaryDetailsSection",
        ]
        var previousIndex = body.startIndex
        for section in orderedSections {
            let range = try XCTUnwrap(body.range(of: section, range: previousIndex..<body.endIndex))
            previousIndex = range.upperBound
        }

        XCTAssertTrue(results.contains("@State private var isSecondaryDetailsExpanded = false"))
        XCTAssertTrue(secondaryDetails.contains("DisclosureGroup(isExpanded: $isSecondaryDetailsExpanded)"))
        XCTAssertTrue(secondaryDetails.contains("storageOverviewSection"))
        XCTAssertTrue(secondaryDetails.contains("topCandidatesSection"))
        XCTAssertTrue(secondaryDetails.contains("executionAdviceSection"))
        XCTAssertTrue(secondaryDetails.contains("scanCoverageSection"))
        XCTAssertTrue(secondaryDetails.contains("longTermAdviceSection"))
        XCTAssertTrue(secondaryDetails.contains("查看磁盘与扫描详情"))
        XCTAssertTrue(results.contains("磁盘总览"))
        XCTAssertTrue(results.contains("Top 5 空间占用"))
        XCTAssertTrue(results.contains("执行建议"))
        XCTAssertTrue(results.contains("绿色 · 可安全清理"))
        XCTAssertTrue(results.contains("黄色 · 需要人工判断"))
        XCTAssertTrue(results.contains("红色 · 高风险"))
        XCTAssertTrue(results.contains("长期建议"))
        XCTAssertTrue(results.contains("displayedSubcategories(for risk:"))
        // D178: decimal sizes (was `ByteFormat.string(safeBytes)`).
        XCTAssertTrue(results.contains("发现 \\(ByteFormat.storageString(safeBytes)) 可安全清理"))
        XCTAssertTrue(results.contains("需要人工判断"))
        // D19: every listed item is selectable, so the cards and tiers count
        // only selectable items and the read-only reference card is gone.
        // D23: emptying the Trash has its own section and is not in the cards.
        // BOARD N20 (r2-live-fixes-2): the rule moved into the definition the
        // results page shares with the scan history; the page reads it.
        XCTAssertTrue(results.contains("CleanupScanTierTotals(categories: categories)"))
        let models = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Models/CleanupScanModels.swift"), encoding: .utf8)
        XCTAssertTrue(models.contains("!$0.action.permanentlyDeletes && $0.isSelectable"))
        XCTAssertTrue(results.contains("case .reviewOnly: valueCandidates = reviewCandidates"))
        XCTAssertFalse(results.contains("advisoryReviewCandidates"))
        XCTAssertFalse(results.contains("只读参考"))
        XCTAssertFalse(results.contains("仅供查看"))
        XCTAssertTrue(results.contains("trashSection"))
        XCTAssertTrue(results.contains("清空废纸篓 · 不可恢复"))
        XCTAssertTrue(results.contains("完全磁盘访问权限"))
        XCTAssertTrue(results.contains("定位到此风险分组，不会改变选择"))
        XCTAssertTrue(results.contains("accessibilityReduceMotion"))
        XCTAssertTrue(results.contains("colorSchemeContrast"))
        XCTAssertEqual(occurrences(of: "store.requestV2Cleanup(", in: actionBar), 1)
        XCTAssertTrue(actionBar.contains("disposition: .trash"))
        XCTAssertTrue(actionBar.contains("安全清理 ·"))
        XCTAssertTrue(actionBar.contains("清理所选 ·"))
        XCTAssertTrue(actionBar.contains("selectedReviewCandidates"))
        XCTAssertTrue(actionBar.contains("selectedProtectedCandidates"))
        XCTAssertFalse(actionBar.contains("disposition: .quarantine"))
    }

    func testSmartScanResultHierarchyUsesCompactNestedDisclosure() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/CleanupScanViews.swift")
        let results = try sourceSegment(
            source,
            from: "struct CleanupScanResultsView: View {",
            to: "private struct CleanupReportSectionHeader: View {"
        )
        let subcategory = try sourceSegment(
            source,
            from: "private struct CleanupSubcategorySelectionView: View {",
            to: "private struct CleanupCandidateRow: View {"
        )
        let candidate = try sourceSegment(
            source,
            from: "private struct CleanupCandidateRow: View {",
            to: "private struct CleanupTriStateButton: View {"
        )
        let candidateBody = try sourceSegment(
            candidate,
            from: "var body: some View {",
            to: "private var candidateContent: some View {"
        )

        XCTAssertTrue(results.contains("@State private var expandedRiskTierIDs: Set<String> = []"))
        XCTAssertTrue(results.contains("let isExpanded = expandedRiskTierIDs.contains(risk.rawValue)"))
        XCTAssertTrue(results.contains("if isExpanded {"))
        XCTAssertTrue(results.contains("toggleTierExpansion(risk)"))
        // D25: a duplicate-app group always keeps one copy, so tier and group
        // checkboxes judge "fully checked" without the kept copies.
        XCTAssertTrue(results.contains("store.cleanupSelection.groupState(for: Array(tierSelectionIDs), in: session)"))

        // D53 §3.2.4: the index feeds the staggered entrance.
        XCTAssertTrue(results.contains("ForEach(Array(tierSubcategories.enumerated()), id: \\.element.id)"))
        XCTAssertFalse(source.contains("private struct CleanupCategorySelectionCard"))
        XCTAssertTrue(subcategory.contains("@State private var isExpanded = false"))
        XCTAssertTrue(subcategory.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(subcategory.contains("if isExpanded {"))
        XCTAssertTrue(subcategory.contains("ForEach(candidates)"))
        XCTAssertTrue(subcategory.contains(".padding(.leading, layout.cardPadding)"))
        // D53 (UI-V2-SPEC 1.3, §3.1, §3.3): v2 card surface; expansion moves
        // the layout with the standard token (at once under Reduce Motion),
        // not animated above 200 rows; the group checkbox is one bulk update.
        XCTAssertTrue(subcategory.contains("SurfaceBackground(level: .card"))
        XCTAssertTrue(subcategory.contains("BulkUpdateScope(rowCount: candidates.count).perform(AppMotion.layout(reduceMotion: reduceMotion))"))
        XCTAssertTrue(subcategory.contains("BulkUpdateScope(rowCount: subcategory.selectableCandidateIDs.count).perform {"))
        XCTAssertTrue(subcategory.contains(".appBulkAnimationGuard(rowCount: candidates.count)"))

        XCTAssertTrue(candidate.contains("layout.cardPadding + 52"))
        XCTAssertTrue(candidate.contains("AppDesignTokens.Typography.body"))
        XCTAssertFalse(candidateBody.contains("CleanupRiskBadge(risk: candidate.risk)"))
    }

    func testSmartScanCleanupKeepsSquareSelectionAndDedicatedSafetyPages() throws {
        let scanViews = try sourceText(at: "Sources/StorageCleanerMac/Views/CleanupScanViews.swift")
        let execution = try sourceText(at: "Sources/StorageCleanerMac/Views/CleanupExecutionViews.swift")
        let triState = try sourceSegment(
            scanViews,
            from: "private struct CleanupTriStateButton: View {",
            to: "private struct CleanupResultSummaryCard: View {"
        )
        let confirmation = try sourceSegment(
            execution,
            from: "struct CleanupPlanConfirmationSheet: View {",
            to: "struct SmartScanCleanupProgressPage: View {"
        )
        let progressPage = try sourceSegment(
            execution,
            from: "struct SmartScanCleanupProgressPage: View {",
            to: "struct SmartScanCleanupCompletedPage: View {"
        )
        let completedPage = try sourceSegment(
            execution,
            from: "struct SmartScanCleanupCompletedPage: View {",
            to: "private struct CleanupExecutionStageList: View {"
        )

        XCTAssertTrue(triState.contains("return \"square\""))
        XCTAssertTrue(triState.contains("return \"checkmark.square.fill\""))
        XCTAssertTrue(triState.contains("return \"minus.square.fill\""))
        XCTAssertTrue(triState.contains(".frame(width: 28, height: 28)"))
        XCTAssertFalse(triState.contains("circle.fill"))
        XCTAssertTrue(scanViews.contains("CleanupRiskBadge(risk: subcategory.risk)"))
        XCTAssertTrue(scanViews.contains("case .safe:"))
        XCTAssertTrue(scanViews.contains("AppDesignTokens.Palette.success"))
        XCTAssertTrue(scanViews.contains("case .reviewOnly:"))
        XCTAssertTrue(scanViews.contains("AppDesignTokens.Palette.warning"))
        XCTAssertTrue(scanViews.contains("let tierSelectionIDs = selectableCandidateIDs(for: risk)"))
        XCTAssertTrue(scanViews.contains("if tierSelectionIDs.isEmpty"))
        XCTAssertFalse(scanViews.contains("if risk == .safe || risk == .reviewOnly"))
        XCTAssertFalse(scanViews.contains("isEnabled: risk != .protected"))
        XCTAssertFalse(scanViews.contains("isEnabled: subcategory.risk != .protected"))
        XCTAssertTrue(scanViews.contains("CleanupSelectionAvailabilityIndicator"))
        XCTAssertTrue(scanViews.contains("全部可操作的黄色项目"))
        XCTAssertTrue(scanViews.contains("全部可操作的红色高风险项目"))
        XCTAssertTrue(scanViews.contains("可按分组或逐项选择"))
        XCTAssertTrue(scanViews.contains("双重确认，且只会移入废纸篓"))
        // D19: nothing listed is view-only any more; D22/D25 row states.
        XCTAssertFalse(scanViews.contains("受保护，不能加入清理计划"))
        XCTAssertFalse(scanViews.contains("仅供查看，不能加入清理计划"))
        XCTAssertTrue(scanViews.contains("此分组没有可清理的项目"))
        XCTAssertTrue(scanViews.contains("正在运行，清理前需退出"))
        XCTAssertTrue(scanViews.contains("将保留此副本"))
        XCTAssertTrue(scanViews.contains("完整容量"))
        XCTAssertTrue(scanViews.contains("至少占用"))
        XCTAssertTrue(scanViews.contains("无法计算"))
        XCTAssertTrue(scanViews.contains("CleanupRecommendationBadge"))

        XCTAssertTrue(confirmation.contains("DisclosureGroup(L10n.text(\"查看详情\", \"Show Details\")"))
        XCTAssertTrue(confirmation.contains("plan.reviewItems.isEmpty && plan.protectedItems.isEmpty ? 416 : 480"))
        XCTAssertTrue(confirmation.contains("计划已冻结"))
        XCTAssertTrue(confirmation.contains("黄色项目需要额外确认"))
        XCTAssertTrue(confirmation.contains("红色高风险项目需要双重确认"))
        XCTAssertTrue(confirmation.contains("acknowledgesProtectedIdentity"))
        XCTAssertTrue(confirmation.contains("acknowledgesProtectedTrashMove"))
        XCTAssertTrue(confirmation.contains(".toggleStyle(.checkbox)"))
        XCTAssertTrue(confirmation.contains("store.cancelV2CleanupConfirmation()"))
        XCTAssertTrue(confirmation.contains("reviewRiskAcknowledged:"))
        XCTAssertTrue(confirmation.contains("protectedRiskAcknowledged:"))
        XCTAssertTrue(confirmation.contains("protectedTrashMoveAcknowledged:"))
        XCTAssertTrue(confirmation.contains("将移入废纸篓"))
        // Fix round 2 (P2-12): the release note moved into the shared model, which also
        // says nothing will move when every move item is skipped.
        XCTAssertTrue(confirmation.contains("facts.cleanupTrashReleaseNote(planHasTrashMoves:"))
        let confirmationModel = try sourceText(at: "Sources/StorageCleanerMac/Models/OperationConfirmationModels.swift")
        XCTAssertTrue(confirmationModel.contains("当前立即释放取决于废纸篓和文件系统状态"))
        // D23: permanent deletion has its own section and two confirmations.
        XCTAssertTrue(confirmation.contains("permanentDeletionConfirmation"))
        XCTAssertTrue(confirmation.contains("清空废纸篓 · 不可恢复"))
        XCTAssertTrue(confirmation.contains("acknowledgesPermanentDeletion"))
        XCTAssertTrue(confirmation.contains("acknowledgesTrashContentsReviewed"))
        // D101 G13: an unusually large run is confirmed once more, for the
        // very summary shown, and the confirm button waits for it.
        XCTAssertTrue(confirmation.contains("本次清理规模异常，需要再确认一次"))
        let compactExecution = try XCTUnwrap(
            SwiftSourceScanning.compactSourceCode()["Sources/StorageCleanerMac/Views/CleanupExecutionViews.swift"])
        for fragment in [
            "ifletscaleAlert=preflight.scaleAlert{scaleConfirmation(scaleAlert)}",
            "Toggle(isOn:Binding(get:{acknowledgedScaleAlert==alert},set:{acknowledgedScaleAlert=$0?alert:nil}))",
            "permanentDeletionAcknowledged:permanentDeletionAcknowledged,scaleAcknowledged:acknowledgedScaleAlert)",
            "||!permanentDeletionAcknowledged||!scaleAcknowledged)",
            "privatevarscaleAcknowledged:Bool{preflight.scaleAlert==nil||acknowledgedScaleAlert==preflight.scaleAlert}"
        ] {
            XCTAssertTrue(compactExecution.contains(fragment), fragment)
        }

        XCTAssertTrue(progressPage.contains("CleanupExecutionStageList("))
        XCTAssertTrue(progressPage.contains("onCancel: (() -> Void)?"))
        XCTAssertTrue(progressPage.contains("progress.processedItemCount"))
        XCTAssertTrue(completedPage.contains("DisclosureGroup(L10n.text(\"清理详情\", \"Cleanup Details\")"))
        XCTAssertTrue(completedPage.contains("movedToRecoverableLocationBytes"))
        XCTAssertTrue(completedPage.contains("reclaimableAfterEmptyingTrashBytes"))
        XCTAssertTrue(completedPage.contains("permanentlyFreedBytes"))
        XCTAssertTrue(completedPage.contains("availableSpaceDeltaBytes"))
        XCTAssertTrue(completedPage.contains("OperationResultPresentation(report: report)"))
        XCTAssertTrue(completedPage.contains("已恢复项目不计为可回收空间"))
        // Every skipped or failed item is listed with its reason.
        XCTAssertTrue(completedPage.contains("CleanupReportIssueList(report: report)"))
        XCTAssertTrue(execution.contains("struct CleanupReportIssueList: View"))
    }

    func testCleanupSelectionKeepsCheckboxesCompactWhenSelected() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/CleanupScanViews.swift")
        let selectionButton = try sourceSegment(
            source,
            from: "private struct CleanupTriStateButton: View {",
            to: "private struct CleanupSpaceMetric: View {"
        )

        XCTAssertTrue(selectionButton.contains(".buttonStyle(ResponsivePlainButtonStyle())"))
        XCTAssertFalse(selectionButton.contains(".appButtonChrome("))
        XCTAssertTrue(selectionButton.contains("state == .unchecked"))
        XCTAssertFalse(selectionButton.contains("guard isEnabled else { return \"minus.circle\" }"))
    }

    func testCleanupCandidateUsesNativeCheckboxAndSeparateRowAndFinderActions() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/CleanupScanViews.swift")
        let row = try sourceSegment(
            source,
            from: "private struct CleanupCandidateRow: View {",
            to: "private struct CleanupTriStateButton: View {"
        )
        let compactContent = try sourceSegment(
            row,
            from: "private var candidateContent: some View {",
            to: "private var candidateDetails: some View {"
        )
        let details = try sourceSegment(
            row,
            from: "private var candidateDetails: some View {",
            to: "private var accessibilitySummary: String {"
        )

        XCTAssertTrue(row.contains("Toggle(isOn: selection)"))
        // D53 (UI-V2-SPEC 1.5): the animated checkbox draws the box and
        // exposes the native checkbox to accessibility.
        XCTAssertTrue(row.contains(".toggleStyle(AnimatedCheckboxToggleStyle("))
        let controls = try sourceText(at: "Sources/StorageCleanerMac/Views/DesignSystem/SelectionControls.swift")
        XCTAssertTrue(controls.contains(".accessibilityRepresentation {\n            Toggle(isOn: configuration.$isOn) {"))
        XCTAssertTrue(controls.contains(".toggleStyle(.checkbox)"))
        XCTAssertFalse(row.contains("Button(action: toggleSelection)"))
        XCTAssertFalse(row.contains("private var riskControl"))
        XCTAssertGreaterThanOrEqual(occurrences(of: "AppIconButton(", in: row), 2)
        XCTAssertTrue(row.contains("CleanupRiskBadge(risk: candidate.risk)"))
        XCTAssertFalse(row.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(row.contains("查看 \\(candidate.sourceURL.lastPathComponent) 的详细信息"))
        // D225补＋旧值：was “在 Finder 中显示 …”; the app says “在访达中显示” everywhere (the English is unchanged).
        XCTAssertTrue(row.contains("在访达中显示 \\(candidate.sourceURL.lastPathComponent)"))
        XCTAssertFalse(compactContent.contains("candidate.snapshot.standardizedPath"))
        XCTAssertTrue(details.contains("candidate.snapshot.standardizedPath"))
        XCTAssertTrue(details.contains("candidate.reason"))
        XCTAssertTrue(row.contains("store.revealCleanupCandidate(candidate)"))
        XCTAssertTrue(row.contains(".accessibilityHint(selectionAccessibilityHint)"))
        XCTAssertTrue(row.contains("candidate.isSelectable"))
        XCTAssertFalse(row.contains(".onTapGesture"))
        XCTAssertFalse(row.contains("overlay"))
    }

    func testSmartScanProgressUsesNativeAccessibleStatusControls() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/SmartScanProgressView.swift")
        let page = try sourceSegment(
            source,
            from: "struct SmartScanScanningPage: View {",
            to: "private struct SmartScanMetric: View {"
        )
        let template = try sourceText(at: "Sources/StorageCleanerMac/Views/DesignSystem/FeatureTemplates.swift")
        // D62②: native progress/accessibility now belongs to the common running template.
        XCTAssertTrue(page.contains("FeatureRunningTemplate("))
        XCTAssertTrue(template.contains("StatusFooter(status:"))
        XCTAssertTrue(template.contains("ProgressView(value: measured ?? 0, total: 1)"))
        XCTAssertTrue(template.contains(".accessibilityLabel(L10n.text(\"进度\", \"Progress\"))"))
        XCTAssertTrue(template.contains(".accessibilityValue"))
        XCTAssertTrue(template.contains(".truncationMode(.middle)"))
        XCTAssertTrue(template.contains("FeaturePageTokens.cancelHeight"))
    }

    func testSharedMotionUsesVisiblePageTransitionAndHonorsReduceMotion() throws {
        let source = try sourceText(
            at: "Sources/StorageCleanerMac/Support/AppInteractionStyle.swift"
        )
        // D53 §3.1–3.2.1: one page transition for the whole window lives in
        // AppMotion; the compatibility name forwards to it.
        let motion = try sourceText(at: "Sources/StorageCleanerMac/Support/AppMotion.swift")

        XCTAssertTrue(source.contains(".offset(y: reduceMotion || isVisible ? 0 : distance)"))
        XCTAssertTrue(source.contains("AppMotion.pageTransition(reduceMotion: reduceMotion)"))
        // Reduce Motion: the new page only fades in.
        XCTAssertTrue(motion.contains("insertion: AnyTransition.opacity.animation(reducedFade)"))
        XCTAssertTrue(motion.contains("removal: pageRemoval.animation(reducedFade)"))
        XCTAssertTrue(motion.contains("struct AppMotionPageModifier: ViewModifier"))
        XCTAssertTrue(motion.contains("active: AppMotionPageModifier(opacity: 0, offset: 8)"))
        // The old page fades out in 0.15 s and, while it does, is neither
        // hit-testable nor visible to VoiceOver (review contract #11).
        XCTAssertTrue(motion.contains("removal: pageRemoval.animation(pageExit)"))
        XCTAssertTrue(motion.contains(".opacity(isLeaving ? 0 : 1)"))
        XCTAssertTrue(motion.contains(".allowsHitTesting(!isLeaving)"))
        XCTAssertTrue(motion.contains(".accessibilityHidden(isLeaving)"))
        XCTAssertTrue(motion.contains(".offset(y: offset)"))
        XCTAssertFalse(source.contains("scale: 0.988"))
        XCTAssertFalse(motion.contains("scaleEffect"), "A scaled page reports scaled frames while it comes in")
        XCTAssertFalse(source.contains(".snappy("))
        XCTAssertFalse(motion.contains(".snappy("))
    }

    @MainActor
    func testMainModulesUseGoldenSurfaceWithoutChangingNativeSettingsOrRouteTransitions() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/ContentView.swift")
        let presentation = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ModulePresentation.swift"
        )
        let themes = try sourceText(at: "Sources/StorageCleanerMac/Support/ModuleTheme.swift")

        XCTAssertTrue(source.contains("MainContentHost("))
        XCTAssertTrue(source.contains("showsIntegratedTitlebar: false"))
        XCTAssertFalse(source.contains("moduleTint"))
        XCTAssertTrue(presentation.contains("struct ModuleBackground: View"))
        XCTAssertTrue(presentation.contains("theme.startColor(for: colorScheme)"))
        XCTAssertFalse(presentation.contains("RadialGradient("),
                       "The night canvas must not inherit a category-coloured haze")
        XCTAssertTrue(presentation.contains("theme.endColor(for: colorScheme)"))
        XCTAssertFalse(presentation.contains("theme.isImmersive ? .dark : colorScheme"))
        XCTAssertTrue(presentation.contains("@Environment(\\.accessibilityReduceTransparency)"))
        XCTAssertFalse(presentation.contains("ModuleTechnicalBackdrop"))
        XCTAssertFalse(presentation.contains("value: route.rawValue"))
        XCTAssertTrue(presentation.contains(".environment(\\.moduleTheme, theme)"))
        XCTAssertTrue(themes.contains("enum ModuleThemeCatalog"))
        // D64③ removes the per-route subtitle switch which contained these
        // standalone cases. Check the actual route-to-theme mapping instead.
        XCTAssertEqual(ReviewFilter.startup.moduleTheme.featureGroup, .performance)
        XCTAssertEqual(ReviewFilter.startup.moduleTheme.pigment, .performance)
        XCTAssertTrue(ReviewFilter.startup.moduleTheme.isImmersive)
        XCTAssertEqual(ReviewFilter.updater.moduleTheme.featureGroup, .applications)
        XCTAssertEqual(ReviewFilter.updater.moduleTheme.pigment, .applications)
        XCTAssertTrue(ReviewFilter.updater.moduleTheme.isImmersive)
        XCTAssertTrue(themes.contains("case .largeFiles, .migration, .duplicates:"))
    }

    func testSystemUtilityPagesChangeIdentityBeforeApplyingTransition() throws {
        let source = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"
        )
        let hub = try sourceSegment(
            source,
            from: "struct SystemUtilitiesHubView: View {",
            to: "struct MemoryOptimizerView: View {"
        )

        XCTAssertTrue(hub.contains("ZStack(alignment: .top)"))
        XCTAssertTrue(hub.contains("switch selectedTool.wrappedValue"))
        XCTAssertTrue(hub.contains("StartupItemsView(store: store)"))
        XCTAssertTrue(hub.contains("MemoryOptimizerView(store: store)"))
        XCTAssertTrue(hub.contains("EnergyImpactView(store: store)"))
        XCTAssertTrue(hub.contains("AppUninstallerView(store: store)"))
        XCTAssertTrue(hub.contains("AppUpdaterView(store: store)"))
        XCTAssertFalse(hub.contains(".id(selectedTool.wrappedValue)"))
        XCTAssertTrue(hub.contains("AppMotionTokens.pageTransition(reduceMotion: reduceMotion)"))
        XCTAssertTrue(hub.contains("value: selectedTool.wrappedValue"))
    }

    func testViewsDoNotReintroduceLocalButtonColorMaterialOrMotionStyles() throws {
        let viewsRoot = projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: viewsRoot,
            includingPropertiesForKeys: nil
        ))
        let swiftFiles = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }

        let plainButtonStyleExemptions: Set<String> = [
            "ModulePresentation.swift",
            "SidebarView.swift"
        ]
        let forbiddenPatterns = [
            #"\.buttonStyle\(\.borderless\)"#,
            #"(?:tint|color): \.(blue|green|orange|red|indigo|cyan|pink|purple|mint|yellow|teal)\b"#,
            #"(?:foregroundStyle|tint)\(\.(blue|green|orange|red|indigo|cyan|pink|purple|mint|yellow|teal)\b"#,
            #"\.(ultraThinMaterial|thinMaterial|regularMaterial|thickMaterial)\b"#,
            #"\.(smooth|snappy|spring)\("#
        ]

        for file in swiftFiles {
            let source = try r2ProductionSource(at: file)
            if source.contains(".buttonStyle(.plain)") {
                XCTAssertTrue(
                    plainButtonStyleExemptions.contains(file.lastPathComponent),
                    "\(file.lastPathComponent) must use the shared button family outside immersive chrome"
                )
                XCTAssertTrue(source.contains("@Environment(\\.accessibilityReduceMotion)"))
                XCTAssertTrue(source.contains(".onHover"))
            }
            for pattern in forbiddenPatterns {
                XCTAssertNil(
                    source.range(of: pattern, options: .regularExpression),
                    "\(file.lastPathComponent) reintroduced local UI styling: \(pattern)"
                )
            }
        }
    }

    func testHealthWorkspaceUsesSharedHeaderWithoutDuplicatePickerLabel() throws {
        let source = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/ComputerHealthWorkspaceView.swift"
        )

        // D67 owns one title in the shared lightfield skeleton. The result
        // view supplies its content directly instead of adding a V1 header.
        XCTAssertTrue(source.contains("FeatureLightfieldPage(module: .healthHub"))
        XCTAssertTrue(source.contains("ComputerHealthView(scanStore: scanStore"))
        XCTAssertFalse(source.contains("AppPageHeader("))
        XCTAssertFalse(source.contains("HeroScanPage("))
        XCTAssertFalse(source.contains("ReviewFilter.healthHub.pageSubtitle"))
        XCTAssertFalse(source.contains("iconSize:"))
        XCTAssertFalse(source.contains("glyphSize:"))
        XCTAssertFalse(source.contains(".background(.ultraThinMaterial)"))
        XCTAssertFalse(source.contains(".accessibilityLabel(L10n.text(\"健康中心页面\""))
    }

    func testFileWorkspaceOwnsTheOnlyPageHeader() throws {
        let content = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ContentView.swift"
        )
        let presentation = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ModulePresentation.swift"
        )
        let largeFiles = try sourceText(
            at: "Sources/StorageCleanerMac/Views/LargeFilesView.swift"
        )
        let utilities = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"
        )
        let duplicates = try sourceSegment(
            utilities,
            from: "struct DuplicateFilesView: View",
            to: "struct DuplicateDisplayGroup: Identifiable"
        )

        XCTAssertTrue(content.contains("private struct ReviewWorkspaceShell"))
        XCTAssertTrue(content.contains("DuplicateFilesView(store: store)"))
        XCTAssertTrue(content.contains("ManagementListPage("))
        XCTAssertFalse(content.contains("GlassSegmentedControl("))
        XCTAssertFalse(content.contains(".accessibilityLabel(L10n.text(\"页面\", \"Page\"))"))
        XCTAssertTrue(presentation.contains("struct ManagementListPage<"))
        XCTAssertTrue(presentation.contains("struct ModulePageHeader<Actions: View>: View"))
        XCTAssertTrue(duplicates.contains("DuplicateFilesLightfieldView(")) // D70: the result owns its Lightfield page
        XCTAssertTrue(duplicates.contains("重新扫描重复文件"))
        XCTAssertTrue(content.contains("重新分析磁盘"))
        XCTAssertFalse(largeFiles.contains("AppPageHeader("))
        XCTAssertFalse(duplicates.contains("AppPageHeader("))
        XCTAssertFalse(largeFiles.contains("ManagementListPage("))
        XCTAssertFalse(duplicates.contains("ManagementListPage("))
    }

    func testBenchmarkScrollUsesFlatContentSurfacePolicy() throws {
        let dashboard = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7DashboardView.swift"
        )
        let glass = try sourceText(at: "Sources/StorageCleanerMac/Support/GlassStyle.swift")
        let panel = try sourceSegment(
            glass,
            from: "private struct GlassPanelModifier: ViewModifier {",
            to: "private struct GlassCapsuleModifier: ViewModifier {"
        )

        XCTAssertTrue(dashboard.contains(".environment(\\.scrollSafeGlass, true)"))
        XCTAssertTrue(panel.contains("AppAppearanceColors.panel"))
        XCTAssertFalse(panel.contains("Color(nsColor: .controlBackgroundColor)"))
        XCTAssertFalse(panel.contains("(tint ?? .clear).opacity"))
        XCTAssertTrue(panel.contains(".strokeBorder(borderColor, lineWidth: 1)"))
        XCTAssertFalse(panel.contains(".glassEffect("))
        XCTAssertFalse(panel.contains(".ultraThinMaterial"))
        XCTAssertFalse(panel.contains(".regularMaterial"))
    }

    func testMemoryEmptyStateHidesUnavailableActionsAndAvoidsRepeatedMetrics() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        // D67/D70⑤: guard the routed Lightfield page, not the retired panels.
        // Empty results use a flat row; the fixed primary action is refresh
        // until there is a selection, and unavailable selection stays disabled.
        XCTAssertTrue(source.contains("displaySnapshot: store.menuBarDisplayMemorySnapshot"))
        XCTAssertTrue(source.contains("LightfieldMemoryPage(store: store"))
        let lightfield = try sourceText(at: "Sources/StorageCleanerMac/Views/LightfieldMemoryPage.swift")
        let metrics = try sourceSegment(lightfield, from: "private var memoryMetrics:", to: "private var results:")
        let empty = try sourceSegment(lightfield, from: "if groups.isEmpty {", to: "private var resultControls:")
        let commands = try sourceSegment(lightfield, from: "private var selectionCommands:", to: "struct LightfieldMemoryAppRow:")
        let primary = try sourceSegment(lightfield, from: "private var actionTitle:", to: "private var landing:")
        XCTAssertTrue(lightfield.contains("displaySnapshot ?? snapshot"))
        XCTAssertTrue(metrics.contains("label: L10n.text(\"已用 / 总量\", \"Used / Total\")"))
        XCTAssertTrue(metrics.contains("display?.measuredUsedBytes.map"))
        XCTAssertTrue(metrics.contains("display?.measurements.physicalBytes.value.map"))
        XCTAssertEqual(metrics.components(separatedBy: "?? \"—\"").count - 1, 4)
        XCTAssertTrue(metrics.contains("display?.measurements.cachedBytes.value.map"))
        XCTAssertTrue(metrics.contains("display?.measurements.swapUsedBytes.value.map"))
        XCTAssertFalse(metrics.contains("\"Available\""))
        XCTAssertTrue(lightfield.contains("progress: display?.measuredUsedRatio,"))
        XCTAssertTrue(lightfield.contains("LightfieldTrendChart(samples: trendSamples"))
        XCTAssertTrue(lightfield.contains("Latest Process Snapshot: "))
        XCTAssertFalse(lightfield.contains("该时刻占用最多"))
        XCTAssertTrue(lightfield.contains("LightfieldPerformancePresentation.memoryOutcome(result.status) + \" · \" + result.detail"))
        XCTAssertFalse(lightfield.contains("Text(cleanupPlan.title"))
        XCTAssertTrue(empty.contains("Text(L10n.text(\"本次没有可读的进程样本\", \"No Readable Process Samples\"))"))
        XCTAssertTrue(empty.contains(".frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)"))
        for decoration in ["Image(", "Material", ".glassPanel", "SurfaceCard", ".background("] {
            XCTAssertFalse(empty.contains(decoration), decoration)
        }
        XCTAssertTrue(commands.contains(".disabled(!store.canRequestMemoryQuitActions || snapshot?.recommendedQuitApps.isEmpty != false)"))
        XCTAssertTrue(commands.contains("if store.selectedMemoryAppCount > 0"))
        XCTAssertTrue(commands.contains(".disabled(!store.canRequestMemoryQuitActions)"))
        XCTAssertFalse(commands.contains("requestQuit"), "Selection commands never perform the primary action")
        XCTAssertTrue(primary.contains("if store.selectedMemoryAppCount > 0"))
        XCTAssertTrue(primary.contains("L10n.text(\"刷新内存快照\", \"Refresh Memory Snapshot\")"))
        XCTAssertTrue(primary.contains("actionEnabled: result && store.selectedMemoryAppCount > 0 ? store.canRequestMemoryQuitActions : store.canRefreshMemory"))
        XCTAssertTrue(primary.contains("store.requestQuitSelectedMemoryProcesses()"))
        XCTAssertFalse(primary.contains("optimizeMemory("))
    }

    func testUninstallerRequiresExplicitScanAndUsesSharedLandingShell() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let landing = try sourceText(
            at: "Sources/StorageCleanerMac/Views/AppUninstallScanLandingView.swift"
        )
        let uninstaller = try sourceSegment(
            source,
            from: "struct AppUninstallerView: View {",
            to: "struct AppUpdaterView: View {"
        )

        // CleanMyMac Applications manager (handoffs/app-lifecycle-cmm.md):
        // the explicit scan still comes first; the result is the manager.
        XCTAssertTrue(uninstaller.contains("ApplicationsManagerView(store: store)"))
        XCTAssertTrue(
            uninstaller.contains(
                "if !store.hasScannedInstalledApps"
            )
        )
        // D154: the explicit scan is CleanMyMac's Applications landing.
        XCTAssertTrue(uninstaller.contains("CareStudioApplicationsStart(store: store)"))
        XCTAssertFalse(uninstaller.contains("Task.sleep(for: .milliseconds(300))"))
        XCTAssertFalse(uninstaller.contains(".task {"))
        // D67: uninstall uses the lightfield skeleton and an explicit scan callback.
        XCTAssertTrue(landing.contains("FeatureLightfieldPage("))
        XCTAssertTrue(landing.contains("L10n.text(\"读取应用列表\", \"Read App List\")"))
        XCTAssertFalse(landing.contains("actionSystemImage:"))
        XCTAssertTrue(landing.contains("action: startScan"))
    }

    func testEnergyImpactRequiresExplicitScanAndShowsRealPipeline() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let landing = try sourceText(
            at: "Sources/StorageCleanerMac/Views/EnergyImpactScanLandingView.swift"
        )
        let energy = try sourceSegment(
            source,
            from: "struct EnergyImpactView: View {",
            to: "enum EnergyImpactSortMode"
        )

        XCTAssertTrue(energy.contains("if store.hasScannedEnergyImpact, !store.isEnergyImpactPageScanActive"))
        XCTAssertTrue(energy.contains("EnergyImpactScanLandingView(store: store)"))
        // D69/D70⑥: results use the lightfield page; the real running stages
        // still come from EnergyImpactRunningPage on the explicit landing route.
        XCTAssertTrue(energy.contains("LightfieldEnergyPage(snapshot: snapshot"))
        XCTAssertTrue(landing.contains("EnergyImpactRunningPage(phase: visiblePhase"))
        XCTAssertTrue(energy.contains("store.scanEnergyImpact()"))
        XCTAssertFalse(energy.contains("autoRefreshEnergyImpact"))
        XCTAssertFalse(energy.contains("Task.sleep(for: .milliseconds(250))"))
        XCTAssertFalse(energy.contains("Task.sleep(for: .seconds(6))"))
        // The shared shell selects lightfield ownership for B3.
        XCTAssertTrue(landing.contains("FeatureLightfieldPage(module: .energy, phase: .landing"))
        XCTAssertTrue(landing.contains("L10n.text(\"开始测量\", \"Start Measurement\")"))
        XCTAssertTrue(landing.contains("EnergyImpactScanPipelineView(phase: visiblePhase, showsStageDetails: true)"))
        // D64③ removes visible option descriptions, but keeps all six actual
        // stages, their labels and the explanatory help for each stage.
        XCTAssertFalse(landing.contains("Text(step.overview)"))
        XCTAssertTrue(landing.contains("Text(step.shortTitle)"))
        XCTAssertTrue(landing.contains(".help(step.overview)"))
        XCTAssertTrue(landing.contains("actionEnabled: store.canRefreshEnergyImpact"))
        XCTAssertTrue(landing.contains("action: { store.scanEnergyImpact() }"))
        XCTAssertTrue(landing.contains("store.isEnergyImpactPageScanActive"))
        XCTAssertTrue(landing.contains("EnergyImpactScanPhase.allCases.enumerated()"))
        XCTAssertTrue(landing.contains("geometry.size.width * progressFraction"))
        XCTAssertTrue(landing.contains("accessibilityValue(\"\\(Int(progressFraction * 100))%\")"))
        XCTAssertTrue(landing.contains("HStack(spacing: AppDesignTokens.Spacing.small)"))
        XCTAssertTrue(landing.contains(".frame(width: 14)"))
        XCTAssertTrue(landing.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertFalse(landing.contains("return HStack(spacing: AppDesignTokens.Spacing.micro)"))
        let resultPage = try sourceText(at: "Sources/StorageCleanerMac/Views/LightfieldEnergyPage.swift")
        let template = try sourceText(at: "Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfield.swift")
        XCTAssertTrue(energy.contains("LightfieldEnergyPage(snapshot: snapshot"))
        XCTAssertTrue(resultPage.contains("actionTitle: L10n.text(\"重新采样能耗\", \"Sample Energy Again\")"))
        XCTAssertTrue(resultPage.contains("actionEnabled: canRefresh"))
        XCTAssertTrue(resultPage.contains("action: refresh"))
        XCTAssertTrue(template.contains("Button(actionTitle, action: action)"))
        XCTAssertTrue(source.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(source.contains("private var compactLayout: some View"))
        XCTAssertTrue(source.contains("private var evidenceColumns: some View"))
        XCTAssertTrue(source.contains("evidence: app.currentEvidence"))
        XCTAssertTrue(source.contains("evidence: app.cumulativeEvidence"))
        XCTAssertTrue(source.contains(".frame(minWidth: 700)"))

        let store = try sourceText(at: "Sources/StorageCleanerMac/Stores/ScanStore.swift")
        XCTAssertTrue(store.contains("let shouldPublishProcessPreview = energyImpactSnapshot == nil"))
        XCTAssertTrue(store.contains("shouldPublishProcessPreview,"))
    }

    func testMainWindowAndPreparationCopyAvoidRepeatedChromeAndActions() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/ContentView.swift")
        let glass = try sourceText(at: "Sources/StorageCleanerMac/Support/GlassStyle.swift")
        let presentation = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ModulePresentation.swift"
        )
        let workspace = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MainWorkspaceViews.swift"
        )
        let startView = try sourceSegment(
            source,
            from: "private struct StartView: View {",
            to: "private struct HomeStatusBoard: View {"
        )

        XCTAssertFalse(source.contains(".hidingWindowToolbarTitle()"))
        XCTAssertFalse(source.contains("toolbar(removing: .title)"))
        XCTAssertFalse(glass.contains("window.titlebarAppearsTransparent"))
        XCTAssertFalse(glass.contains("window.styleMask.insert(.fullSizeContentView)"))
        XCTAssertFalse(source.contains("WindowGlassConfigurator()"))
        XCTAssertFalse(source.contains("GlassAppBackdrop()"))
        XCTAssertTrue(source.contains("MainWindowChromeConfigurator()"))
        XCTAssertFalse(source.contains("ToolbarItem(placement: .primaryAction)"))
        XCTAssertFalse(source.contains("SettingsLink"))
        XCTAssertTrue(presentation.contains("window.titleVisibility = .hidden"))
        XCTAssertTrue(presentation.contains("window.titlebarAppearsTransparent = true"))
        XCTAssertTrue(presentation.contains("window.styleMask.insert(.fullSizeContentView)"))
        XCTAssertFalse(presentation.contains("window.toolbar = nil"))
        XCTAssertFalse(source.contains("重新扫描以确认当前缓存状态。"))
        XCTAssertFalse(source.contains("仅显示可安全清理的项目"))
        XCTAssertFalse(startView.contains("AppPageHeader("))
        XCTAssertFalse(startView.contains("idleActionCard"))
        XCTAssertFalse(startView.contains("SmartScanPageShell"))
        XCTAssertTrue(startView.contains("SmartCareLandingView(store: store"))
        XCTAssertTrue(workspace.contains("store.startScanRespectingAccessGuide"))
        XCTAssertFalse(workspace.contains("SmartCarePrimaryButton("))
        XCTAssertTrue(workspace.contains("L10n.text(\"开始扫描\", \"Start Scan\")"))
    }

    func testSmartCleanupFocusUsesLinearMetricWithoutNestedRing() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/ContentView.swift")
        let focus = try sourceSegment(
            source,
            from: "private struct SmartCleanupFocusPanel: View {",
            to: "private struct FocusInfoLabel: View {"
        )
        let metric = try sourceSegment(
            source,
            from: "private struct CleanupAmountMetric: View {",
            to: "private struct StatusToastView: View {"
        )

        XCTAssertTrue(focus.contains("CleanupAmountMetric("))
        XCTAssertFalse(focus.contains("CleanupAmountRing("))
        XCTAssertTrue(metric.contains("ProgressView(value: progress, total: 1)"))
        XCTAssertTrue(metric.contains(".progressViewStyle(.linear)"))
        XCTAssertFalse(metric.contains("Circle()"))
        XCTAssertFalse(metric.contains("AngularGradient("))
        XCTAssertFalse(metric.contains(".glassPanel("))
    }

    func testReadinessAndPermissionRowsUsePlainSemanticSymbols() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/ContentView.swift")
        let accessStep = try sourceSegment(
            source,
            from: "private struct AccessRepairStepRow: View {",
            to: "private struct HomeStatusBoard: View {"
        )
        let readiness = try sourceSegment(
            source,
            from: "private struct ScanReadinessStatusRow: View {",
            to: "private struct ScanReadinessPermissionRow: View {"
        )
        let permission = try sourceSegment(
            source,
            from: "private struct ScanReadinessPermissionRow: View {",
            to: "private struct ScanProgressView: View {"
        )

        XCTAssertTrue(accessStep.contains("Text(\"\\(number).\")"))
        XCTAssertFalse(accessStep.contains("Circle()"))
        XCTAssertTrue(readiness.contains("statusSystemImage(for: item.status)"))
        XCTAssertFalse(readiness.contains("Circle()"))
        XCTAssertFalse(permission.contains("RoundedRectangle("))
    }

    func testHealthLargeFilesAndPrivacyAvoidNestedDecorativeShapes() throws {
        let health = try [
            "Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfield.swift",
            "Sources/StorageCleanerMac/Views/ComputerHealth/HealthFactorGrid.swift",
            "Sources/StorageCleanerMac/Views/ComputerHealth/HealthActionList.swift"
        ]
            .map { try sourceText(at: $0) }
            .joined(separator: "\n")
        let largeFiles = try sourceText(
            at: "Sources/StorageCleanerMac/Views/LargeFilesView.swift"
        )
        let benchmark = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7DashboardView.swift"
        )
        let benchmarkSummary = try sourceSegment(
            benchmark,
            from: "private func metricSummary(",
            to: "private var localBestPage: some View"
        )
        let benchmarkAction = try sourceSegment(
            benchmark,
            from: "private var benchmarkPrimaryAction: some View",
            to: "private var actionCard: some View"
        )

        XCTAssertTrue(health.contains("if let measured {"))
        XCTAssertTrue(health.contains("RuntimeWorkflowState.measuredFraction(fraction)"))
        XCTAssertTrue(health.contains("Circle()"))
        XCTAssertTrue(health.contains("RoundedRectangle(cornerRadius: 2)"))
        XCTAssertFalse(health.contains(".glassPanel("))
        XCTAssertFalse(health.contains("scoreRing"))
        XCTAssertFalse(health.contains("miniRing"))
        XCTAssertFalse(health.contains("factorCard"))

        XCTAssertTrue(largeFiles.contains("FeatureRuntimePage("))
        XCTAssertFalse(largeFiles.contains("Circle()"))
        XCTAssertFalse(largeFiles.contains("miniRing"))

        XCTAssertTrue(benchmark.contains("latestResultCard"))
        XCTAssertFalse(benchmark.contains("scoreRing"))
        XCTAssertFalse(benchmark.contains("Circle()"))
        XCTAssertFalse(benchmarkSummary.contains(".system(size:"))
        XCTAssertEqual(
            occurrences(of: "Button(", in: benchmarkAction),
            2
        )
        XCTAssertTrue(benchmarkAction.contains("Button(role: .cancel, action: onCancel)"))
        XCTAssertTrue(benchmarkAction.contains("Button(action: onStart)"))
    }

    func testCompactAndGeekPanelsAvoidCardWithinShapeDecoration() throws {
        let compact = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift"
        )
        let geek = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )
        let geekComponents = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPanelComponents.swift"
        )
        let geekConfiguration = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDashboardConfiguration.swift"
        )
        let geekCharts = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift"
        )
        let advancedComponents = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift"
        )
        let panelChrome = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift"
        )
        let controls = try sourceText(
            at: "Sources/StorageCleanerMac/Support/AppControls.swift"
        )
        let selectionButton = try sourceSegment(
            controls,
            from: "struct AppSelectionButton: View",
            to: "struct AppFilterButton: View"
        )
        let smartCare = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SmartCareComponents.swift"
        )
        let geekChartSurfaces = try sourceSegment(
            geekCharts,
            from: "enum GeekChartUnit",
            to: "struct GeekHoverTooltip: View"
        )
        let combinedCard = try sourceSegment(
            geekComponents,
            from: "struct GeekCombinedCard<Content: View>: View",
            to: "private extension View"
        )
        let combinedCardDivider = try sourceSegment(
            geekComponents,
            from: "private struct GeekCombinedCardUsesDividerKey",
            to: "extension EnvironmentValues"
        )
        let chartValueLabels = try sourceSegment(
            geekCharts,
            from: "private func valueLabels(in plotRect: CGRect, range: ClosedRange<Double>)",
            to: "func pointSegments("
        )

        XCTAssertFalse(compact.contains(".background(memoryTint.opacity(0.10), in: Capsule())"))
        XCTAssertFalse(compact.contains(".background(tint.opacity(0.09), in: Circle())"))
        XCTAssertFalse(compact.contains(".background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6"))
        XCTAssertFalse(compact.contains("MenuBarIconButtonStyle"))
        XCTAssertFalse(compact.contains("MenuBarOpenButtonStyle"))
        XCTAssertTrue(compact.contains("GeekAttachedPanelShell("))
        XCTAssertEqual(panelChrome.components(separatedBy: "kind: .toolbar").count - 1, 1)
        XCTAssertTrue(panelChrome.contains("Menu {"))
        XCTAssertTrue(panelChrome.contains("AppSymbols.Action.more"))
        XCTAssertFalse(panelChrome.contains("kind: .glass"))

        XCTAssertFalse(geek.contains("private struct GeekMetricTile"))
        // D118 (2026-10-18): overview cards are iStat cards, which keep the
        // one golden combined-card surface. Was
        // `GeekCombinedCard(height: GeekPanelLayout.overviewProcessorCardHeight)`.
        XCTAssertTrue(geek.contains("GeekIStatCard(height: GeekPanelLayout.overviewProcessorCardHeight)"))
        XCTAssertTrue(geekComponents.contains("GeekCombinedCard(height: height, contentInsets: EdgeInsets())"))
        XCTAssertFalse(geek.contains("GeekBatteryLevelBar("))
        XCTAssertFalse(geek.contains(".environment(\\.geekCombinedCardUsesDivider, true)"))
        XCTAssertTrue(combinedCardDivider.contains("static let defaultValue = false"))
        XCTAssertTrue(combinedCard.contains(".frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)"))
        XCTAssertEqual(occurrences(of: ".geekCardSurface(", in: combinedCard), 1,
                       "Each fixed-height overview module keeps one golden card surface")
        let liveSensors = try sourceText(at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift")
        XCTAssertTrue(liveSensors.contains("reading.displayRPM"))
        XCTAssertFalse(geek.contains("presentation:"))
        XCTAssertTrue(geekComponents.contains("struct GeekCombinedCard<Content: View>: View"))
        XCTAssertTrue(geekComponents.contains("struct GeekCombinedRing: View"))
        XCTAssertTrue(geekComponents.contains(
            "MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)"
        ))
        XCTAssertFalse(geekComponents.contains(".shadow("))
        XCTAssertTrue(geekComponents.contains("struct GeekMetricGrid: View"))
        XCTAssertTrue(geekComponents.contains("struct GeekMetricSummaryGrid: View"))
        XCTAssertTrue(geekComponents.contains("struct GeekMetricCell: View"))
        XCTAssertTrue(geekComponents.contains("grid(columns: 3, minimumCellWidth: 136)"))
        XCTAssertTrue(geekComponents.contains("grid(columns: 2, minimumCellWidth: 126)"))
        XCTAssertFalse(geekComponents.contains("grid(columns: 6"))
        XCTAssertTrue(geekComponents.contains("PanelCircularGauge("))
        XCTAssertFalse(geekComponents.contains("ProgressView(value: progress)"))
        XCTAssertFalse(geekComponents.contains("frame(width: 112, height: 4)"))
        XCTAssertFalse(geekComponents.contains("GeekMiniRing"))
        XCTAssertFalse(geekComponents.contains("if presentation =="))
        XCTAssertFalse(geekConfiguration.contains("GeekMetricPresentation"))
        XCTAssertFalse(geekConfiguration.contains("ringMetrics"))
        XCTAssertFalse(advancedComponents.contains("var moduleRail:"))
        let moduleButton = try r2SourceDeclaration("struct GeekOverviewModuleButton<", in: geekComponents)
        XCTAssertTrue(moduleButton.contains(".appButtonChrome(.metric)"))
        XCTAssertTrue(moduleButton.contains("action(destination)"))
        XCTAssertFalse(geek.contains("private struct GeekRailButton"))
        XCTAssertFalse(geek.contains(".glassPanel(cornerRadius: 11"))
        XCTAssertTrue(selectionButton.contains("appButtonChrome(isSelected ? .primary : .toolbar"))
        XCTAssertTrue(selectionButton.contains("AppDesignTokens.Typography"))
        XCTAssertFalse(selectionButton.contains(".background("))
        XCTAssertFalse(selectionButton.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(selectionButton.contains(".system(size:"))
        XCTAssertFalse(geekChartSurfaces.contains("Circle()"))
        XCTAssertTrue(geekCharts.contains("struct GeekHoverTooltip: View"))
        XCTAssertTrue(geekCharts.contains(".frame(width: 6, height: 6)"))
        XCTAssertFalse(geekCharts.contains("Gauge("))
        XCTAssertFalse(geekCharts.contains("RoundedRectangle("))
        XCTAssertTrue(chartValueLabels.contains("Text(unit.formatted(value, compact: true))"))
        XCTAssertTrue(chartValueLabels.contains(".font(.system(size: 9, weight: .regular))"))
        XCTAssertTrue(chartValueLabels.contains(".monospacedDigit()"))
        XCTAssertFalse(
            geekCharts.replacingOccurrences(of: chartValueLabels, with: "").contains(".font(.system(size:"),
            "Only compact numeric axis labels use a local size; chart legends and tooltips keep shared typography"
        )
        XCTAssertTrue(geekCharts.contains("AdvancedPanelTypography.caption"))
        XCTAssertTrue(geekCharts.contains("LazyVGrid(columns: legendColumns"))
        XCTAssertTrue(geekCharts.contains("HStack(spacing: 6)"))
        // D121 (2026-10-18): the history tooltip is iStat's dark box, the
        // shared chrome's `.history` style (was `.miniWindowTooltipChrome()`).
        XCTAssertTrue(geekCharts.contains(".miniWindowTooltipChrome(.history)"))
        XCTAssertFalse(geekCharts.contains(".background(.regularMaterial)"))
        XCTAssertFalse(smartCare.contains(".background(tint.opacity(0.10), in: RoundedRectangle"))
    }

    func testGeekPanelKeepsEightRoutesWithoutASecondaryFooter() throws {
        let geek = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )
        let panel = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift"
        )
        let components = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift"
        )
        let detail = try sourceSegment(geek, from: "var geekDetailPage", to: "var geekCanvas")

        XCTAssertTrue(panel.contains("GeekAttachedPanelShell("))
        XCTAssertTrue(panel.contains("section: selectedSection"))
        XCTAssertTrue(panel.contains("onHoverChange: geekAttachedPanelHoverChanged"))
        XCTAssertFalse(panel.contains("var moduleRail:"))
        XCTAssertTrue(panel.contains("showsHeader: false"))
        XCTAssertTrue(panel.contains("showsNavigation: false"))
        XCTAssertFalse(panel.contains("liveHeader"))
        XCTAssertTrue(panel.contains("navigation: {\n                EmptyView()"))
        XCTAssertTrue(panel.contains("geekDetailPage"))
        XCTAssertTrue(components.contains("PanelToolbarActions("))
        XCTAssertFalse(components.contains("var moduleRail: some View"))
        XCTAssertFalse(geek.contains("geekHeader"))
        XCTAssertFalse(geek.contains("geekModuleRail"))
        XCTAssertFalse(geek.contains("geekDetailFooter"))
        XCTAssertFalse(detail.contains("Open Main Window"))
        XCTAssertFalse(detail.contains("AppSymbols.Action.showMainWindow"))
        XCTAssertFalse(detail.contains("toggleMenuBarRefreshPaused"))
        XCTAssertFalse(detail.contains("PanelRefreshControl("))
        XCTAssertFalse(detail.contains("tertiaryDetailButton("))
        XCTAssertFalse(detail.contains("dismissPanel()"))
        XCTAssertFalse(geek.contains("safeAreaInset"))
        XCTAssertFalse(geek.contains("overlay(alignment: .bottom"))

        let routes = [
            ("overview", "EmptyView()"),
            ("processor", "geekProcessorPage"),
            ("memory", "geekMemoryPage"),
            ("disk", "geekDiskPage"),
            ("network", "geekNetworkPage"),
            ("sensors", "geekSensorsPage"),
            ("power", "geekPowerPage"),
            ("cleanup", "geekCleanupPage")
        ]
        for (section, page) in routes {
            XCTAssertTrue(detail.contains("case .\(section):"), section)
            XCTAssertTrue(detail.contains(page), page)
        }
    }

    func testGeekNetworkSecondaryPageKeepsLiveSummaryAndVPNTopologyDetails() throws {
        let source = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift"
        )
        let tertiary = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift"
        )
        let processService = try sourceText(
            at: "Sources/StorageCleanerMac/Services/NativeNetworkProcessService.swift"
        )

        // D119 (2026-10-18): iStat's 150 pt bandwidth section, laid out on
        // its offsets (was `GeekCombinedCard(height: 150)`).
        XCTAssertTrue(source.contains("GeekIStatCard(height: GeekNetworkBandwidthLayout.cardHeight)"))
        XCTAssertEqual(GeekNetworkBandwidthLayout.cardHeight, 150)
        XCTAssertTrue(source.contains("GeekVPNDisclosure"))
        XCTAssertTrue(source.contains("networkTopologySnapshot?.activeVPNTunnel"))
        XCTAssertTrue(source.contains("geekPhysicalNetwork"))
        XCTAssertTrue(source.contains("geekPhysicalIPv4Address"))
        XCTAssertTrue(source.contains("GeekVPNHoverDetail"))
        XCTAssertTrue(source.contains("tunnel.tunnelIPv4"))
        XCTAssertTrue(source.contains("tunnel.tunnelIPv6"))
        XCTAssertTrue(source.contains("tunnel.scopedDNSServers"))
        // D125 (2026-10-19): every scoped DNS server is a row of the VPN's
        // IPv4 or IPv6 section, as in iStat (was three rows and "N more");
        // `MiniWindowIStatInterfaceLayoutTests` checks the rows.
        XCTAssertFalse(source.contains("additionalScopedDNSCount"))
        XCTAssertFalse(source.contains("另有 \\(additionalScopedDNSCount) 条 DNS"))
        XCTAssertTrue(source.contains("GeekIStatInterfaceModel(tunnel: tunnel)"))
        XCTAssertTrue(source.contains("VPNControlCapabilityResolver"))
        XCTAssertTrue(source.contains("下载峰值"))
        XCTAssertTrue(source.contains("上传峰值"))
        // D146 (2026-10-19): iStat's peak row has no session totals (was
        // `XCTAssertTrue(source.contains("会话累计"))`).
        XCTAssertFalse(source.contains("会话累计"))
        XCTAssertTrue(source.contains("Public IP"))
        // D140 (2026-10-19): iStat's "IP 地址" section (was "本地 IP 地址").
        XCTAssertFalse(source.contains("L10n.text(\"本地 IP 地址\""))
        XCTAssertTrue(source.contains("title: GeekIStatInterfaceModel.addressesTitle"))
        // D146: the page shows no session totals (was `XCTAssertTrue` for
        // both: the peak row read them).
        XCTAssertFalse(source.contains("sessionUploadedBytes"))
        XCTAssertFalse(source.contains("sessionDownloadedBytes"))
        XCTAssertTrue(source.contains("GeekNetworkProcessRow"))
        XCTAssertTrue(source.contains("networkProcessSnapshot"))
        XCTAssertTrue(source.contains("networkProcessSamplingState"))
        XCTAssertTrue(source.contains("正在采样…"))
        XCTAssertTrue(source.contains("正在准备采样…"))
        XCTAssertTrue(source.contains("暂时无法读取进程流量"))
        XCTAssertFalse(source.contains("等待采样"))
        XCTAssertFalse(source.contains("逐进程实时流量未采样"))
        // D119 (2026-10-18): iStat's process section at its row capacity
        // (was `GeekCombinedCard(height: geekNetworkProcessCardHeight)`).
        XCTAssertTrue(source.contains("GeekIStatProcessSection(rowCapacity: geekNetworkProcessCapacity)"))
        XCTAssertTrue(source.contains("ProgressView()"))
        // D140 (2026-10-19): one row per listed address in iStat's IP section
        // (were `if showsIPv6` and the address's `.help(value)`).
        XCTAssertFalse(source.contains("if showsIPv6"))
        XCTAssertTrue(source.contains("GeekIStatIPSection("))
        XCTAssertTrue(source.contains(".truncationMode(.middle)"))
        XCTAssertFalse(source.contains(".help(value)"))
        XCTAssertTrue(source.contains("geekNetworkProcessStatusText"))
        XCTAssertTrue(source.contains("MAC Address"))
        XCTAssertTrue(source.contains("IPv6"))
        XCTAssertTrue(source.contains("DNS"))
        XCTAssertTrue(source.contains("正在读取…"))
        XCTAssertFalse(source.contains("GeekNetworkInterfaceDisclosure"))
        XCTAssertFalse(source.contains("CoreWLAN"))
        XCTAssertTrue(processService.contains("/usr/bin/nettop"))
        XCTAssertTrue(processService.contains("-L\", \"2\", \"-d"))
        XCTAssertTrue(processService.contains("headerIndices.count >= 2"))
        for detail in ["GeekNetworkTertiaryView", "networkInterfaceSnapshot", "refreshPanelData"] {
            XCTAssertTrue(tertiary.contains(detail), detail)
        }
    }

    func testSustainedBenchmarkKeepsOneRawOnlyNativeLayout() throws {
        // D64: the unused v6 sustained view was removed; keep raw-only guards on the live renderer.
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/ComputerHealth/MSeriesRawResultView.swift")
        XCTAssertTrue(source.contains("awaiting reference calibration"))
        XCTAssertTrue(source.contains("sample stability, not statistical confidence"))
        XCTAssertTrue(source.contains("result.extensions"))
        XCTAssertTrue(source.contains("result.writtenBytes"))
        XCTAssertTrue(source.contains("statistics.sampleCount"))
        XCTAssertTrue(source.contains("DisclosureGroup("))
        XCTAssertFalse(source.contains(".appButtonChrome(.primary)"))
        XCTAssertFalse(source.contains("运行持续测试"))
        XCTAssertFalse(source.contains("MetadataPill("))
        XCTAssertFalse(source.contains("Picker("))
        XCTAssertFalse(source.contains("selectedProfile"))
        XCTAssertFalse(source.contains(".pickerStyle("))
        XCTAssertFalse(source.contains("Circle()"))
        XCTAssertFalse(source.contains("RoundedRectangle("))
        XCTAssertFalse(source.contains("Capsule()"))
    }

    func testAdvancedPanelUsesSharedNativeControlsAndCircularMetrics() throws {
        let source = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift"
        )
        let geek = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )
        let geekComponents = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPanelComponents.swift"
        )
        let geekConfiguration = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDashboardConfiguration.swift"
        )
        let chrome = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift"
        )
        let controls = try sourceText(at: "Sources/StorageCleanerMac/Support/AppControls.swift")
        let rail = try sourceSegment(controls, from: "struct AppSelectionButton: View", to: "struct AppFilterButton: View")
        let header = try r2SourceDeclaration("struct AdvancedPanelCard<", in: source)
        XCTAssertFalse(source.contains("struct AdvancedMetricTile:"))
        XCTAssertFalse(source.contains("struct AdvancedCompactGauge:"))
        XCTAssertFalse(source.contains("struct AdvancedPlainMetric:"))
        let circularGauge = try r2SourceDeclaration("struct PanelCircularGauge:", in: chrome)
        let geekMetricCell = try r2SourceDeclaration("struct GeekMetricCell:", in: geekComponents)
        let metricContent = try r2SourceDeclaration("private var content:", in: geekMetricCell)

        XCTAssertFalse(source.contains(".glassPanel(cornerRadius: 12"))
        XCTAssertTrue(controls.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertTrue(controls.contains(".buttonStyle(.bordered)"))
        XCTAssertFalse(source.contains("struct AdvancedRailButton"))
        XCTAssertFalse(source.contains("struct AdvancedRingMetric"))
        XCTAssertFalse(source.contains("AdvancedIconButtonStyle"))
        XCTAssertFalse(source.contains("AdvancedOpenButtonStyle"))
        XCTAssertFalse(source.contains("Circle()"))
        XCTAssertTrue(header.contains("Text(title)"))
        XCTAssertTrue(header.contains(".accessibilityAddTraits(.isHeader)"))
        XCTAssertFalse(header.contains("AppSymbolGlyph("))
        XCTAssertFalse(source.contains("tint: .accentColor"))
        XCTAssertFalse(source.contains("var footer: some View"))
        XCTAssertFalse(source.contains("var settingsMenu: some View"))
        XCTAssertEqual(chrome.components(separatedBy: "AppIconButton(").count - 1, 1)
        XCTAssertEqual(chrome.components(separatedBy: "kind: .toolbar").count - 1, 1)
        XCTAssertTrue(chrome.contains("struct PanelRefreshControl: View"))
        XCTAssertTrue(chrome.contains("Menu {"))
        XCTAssertTrue(chrome.contains("AppSymbols.Action.more"))
        XCTAssertFalse(chrome.contains("kind: .glass"))

        XCTAssertTrue(rail.contains("role: .panelNavigation"))
        XCTAssertFalse(rail.contains("RoundedRectangle("))
        XCTAssertFalse(rail.contains("ResponsivePlainButtonStyle"))

        XCTAssertTrue(circularGauge.contains("Gauge(value:"))
        XCTAssertTrue(circularGauge.contains(".gaugeStyle(.accessoryCircularCapacity)"))
        XCTAssertTrue(circularGauge.contains(".help(helpText)"))
        XCTAssertTrue(circularGauge.contains(".accessibilityLabel(title)"))
        XCTAssertTrue(circularGauge.contains(".accessibilityValue(accessibilityValue)"))
        XCTAssertTrue(circularGauge.contains("transaction.animation = nil"))
        XCTAssertTrue(circularGauge.contains("L10n.text(\"不可用\", \"Unavailable\")"))
        XCTAssertTrue(circularGauge.contains(".lineLimit(2)"))
        XCTAssertTrue(circularGauge.contains(".multilineTextAlignment(.center)"))
        XCTAssertFalse(circularGauge.contains("minimumScaleFactor"))
        XCTAssertFalse(circularGauge.contains("Circle()"))

        XCTAssertTrue(metricContent.contains("PanelCircularGauge("))
        XCTAssertFalse(metricContent.contains("ProgressView(value:"))
        XCTAssertFalse(metricContent.contains("Circle()"))
        XCTAssertFalse(metricContent.contains("RoundedRectangle("))
        XCTAssertTrue(metricContent.contains("if model.progress != nil"))
        XCTAssertTrue(metricContent.contains("progress: model.progress"))
        XCTAssertFalse(geek.contains("private struct GeekMetricTile"))
        // D118 (2026-10-18): overview cards are iStat cards, which keep the
        // one golden combined-card surface. Was
        // `GeekCombinedCard(height: GeekPanelLayout.overviewProcessorCardHeight)`.
        XCTAssertTrue(geek.contains("GeekIStatCard(height: GeekPanelLayout.overviewProcessorCardHeight)"))
        XCTAssertTrue(geekComponents.contains("GeekCombinedCard(height: height, contentInsets: EdgeInsets())"))
        XCTAssertFalse(geek.contains("presentation:"))
        XCTAssertTrue(geekComponents.contains("struct GeekCombinedRing: View"))
        XCTAssertTrue(geekComponents.contains("struct GeekMetricGrid: View"))
        XCTAssertTrue(geekComponents.contains("struct GeekMetricSummaryGrid: View"))
        XCTAssertGreaterThanOrEqual(
            geekComponents.components(separatedBy: "GeekMetricCell(").count - 1,
            1
        )
        XCTAssertTrue(geekMetricCell.contains("PanelCircularGauge("))
        XCTAssertFalse(geekMetricCell.contains("ProgressView(value:"))
        XCTAssertTrue(geekMetricCell.contains("if model.progress != nil"))
        XCTAssertTrue(geekMetricCell.contains("!value.contains(\"--\")"))
        XCTAssertFalse(geekMetricCell.contains("? nil : 0"))
        XCTAssertFalse(geekMetricCell.contains("Circle()"))
        XCTAssertFalse(geekMetricCell.contains("Gauge(value:"))
        XCTAssertFalse(geekComponents.contains("GeekMiniRing"))
        XCTAssertFalse(geekConfiguration.contains("GeekMetricPresentation"))
        XCTAssertFalse(geekConfiguration.contains("ringMetrics"))
    }

    func testViewsUseNativeButtonsAndPanelUsesNativeSegmentedControls() throws {
        let presentation = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ModulePresentation.swift"
        )
        let source = try [
            "Sources/StorageCleanerMac/Views/AppInstallationConflictBanner.swift",
            "Sources/StorageCleanerMac/Views/ComputerHealth/ComputerHealthWorkspaceView.swift",
            "Sources/StorageCleanerMac/Views/ComputerHealth/HealthActionList.swift",
            "Sources/StorageCleanerMac/Views/ComputerHealth/HealthScoreHero.swift",
            "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7DashboardView.swift",
            "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7LeaderboardSection.swift",
            "Sources/StorageCleanerMac/Views/ComputerHealthView.swift",
            "Sources/StorageCleanerMac/Views/ContentView.swift",
            "Sources/StorageCleanerMac/Views/ItemDetailView.swift",
            "Sources/StorageCleanerMac/Views/ItemListView.swift",
            "Sources/StorageCleanerMac/Views/LargeFilesView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarPanelSettingsView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift",
            "Sources/StorageCleanerMac/Views/OverviewView.swift",
            "Sources/StorageCleanerMac/Views/SettingsView.swift",
            "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"
        ]
            .map { path in
                let text = try sourceText(at: path)
                // D64/V1: this batch owns V7 result controls; its unchanged landing action uses native prominence.
                if path.hasSuffix("BenchmarkV7DashboardView.swift") {
                    let start = try XCTUnwrap(text.range(of: "private var latestResultCard:")).lowerBound
                    return String(text[start...])
                }
                return text
            }
            .joined(separator: "\n")

        XCTAssertFalse(source.contains(".buttonStyle(.bordered)"))
        XCTAssertFalse(source.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertTrue(source.contains(".appButtonChrome(.secondary)"))
        XCTAssertTrue(source.contains(".appButtonChrome(.primary)"))
        XCTAssertTrue(presentation.contains("struct GlassSegmentedControl<Selection: Hashable & Identifiable>: View"))
        XCTAssertTrue(presentation.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(presentation.contains("Text(title(option)).tag(option)"))
        XCTAssertFalse(presentation.contains("ModuleTechnicalBackdrop"))
        // Batch 2b deleted the never-instantiated GeekDashboardEditor.
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDashboardEditor.swift").path))
    }

    func testAppButtonFamilyOwnsNativeStatesAndRemovesLocalDuplicates() throws {
        let controls = try sourceText(at: "Sources/StorageCleanerMac/Support/AppControls.swift")
        let smartCare = try sourceText(at: "Sources/StorageCleanerMac/Views/SmartCareComponents.swift")
        let settings = try sourceText(at: "Sources/StorageCleanerMac/Views/SettingsView.swift")
        let utilities = try sourceText(at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let advanced = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift"
        )

        for kind in [
            "case primary", "case secondary", "case tertiary", "case destructive",
            "case toolbar", "case icon", "case glass", "case glassProminent",
            "case menu", "case disclosure", "case smallUtility"
        ] {
            XCTAssertTrue(controls.contains(kind), kind)
        }
        XCTAssertTrue(controls.contains("struct AppButton: View"))
        XCTAssertTrue(controls.contains("struct AppIconButton: View"))
        XCTAssertTrue(controls.contains("private struct AdaptiveAppButtonLabel: View"))
        XCTAssertTrue(controls.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(controls.contains("Label(title, systemImage: systemImage)"))
        XCTAssertTrue(controls.contains("HStack(spacing: AppDesignTokens.Spacing.small)"))
        // D64 #1: the inline icon is conditional; compact icon-only fallback stays.
        XCTAssertTrue(controls.contains("if showsInlineIcon {\n                actionIcon(systemImage: systemImage)"))
        XCTAssertTrue(controls.contains("case .primary, .glassProminent:\n            false"))
        XCTAssertTrue(controls.contains(".labelStyle(.iconOnly)"))
        XCTAssertTrue(controls.contains("case .toolbar, .icon, .smallUtility:"))
        XCTAssertTrue(controls.contains("allowsIconOnlyFallback: allowsIconOnlyFallback"))
        XCTAssertFalse(controls.contains("private var compactLabel: some View"))
        XCTAssertTrue(controls.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(controls.contains("struct AppMenuButton<Content: View>: View"))
        XCTAssertTrue(controls.contains("struct AppDisclosureButton: View"))
        XCTAssertTrue(controls.contains(".accessibilityLabel(title)"))
        XCTAssertTrue(controls.contains(".help(title)"))
        XCTAssertTrue(controls.contains(".disabled(isDisabled || isLoading)"))
        XCTAssertFalse(controls.contains("minHeight: 44"))
        XCTAssertFalse(controls.contains(".opacity(isDisabled"))

        XCTAssertFalse(smartCare.contains("SmartCarePrimaryActionButton"))
        XCTAssertFalse(settings.contains("SettingsActionButton"))
        XCTAssertFalse(utilities.contains("UpdateFilterButton"))
        XCTAssertFalse(utilities.contains("UninstallFilterButton"))
        XCTAssertFalse(advanced.contains("AdvancedActionButton"))
        XCTAssertFalse(advanced.contains("AdvancedRailButton"))
    }

    func testSharedSurfaceLayerKeepsContentAndPanelChromeFlat() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Support/GlassStyle.swift")
        let controls = try sourceText(at: "Sources/StorageCleanerMac/Support/AppControls.swift")
        let duplicateSource = try sourceText(at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let panel = try sourceSegment(
            source,
            from: "private struct GlassPanelModifier: ViewModifier {",
            to: "private struct GlassCapsuleModifier: ViewModifier {"
        )
        let group = try sourceSegment(
            source,
            from: "private struct GlassEffectGroupModifier: ViewModifier {",
            to: "struct GlassAppBackdrop: View {"
        )
        let popover = try sourceSegment(
            source,
            from: "private struct AdaptivePopoverChromeModifier: ViewModifier {",
            to: "struct GlassVisualEffectBackdrop: NSViewRepresentable {"
        )

        XCTAssertTrue(panel.contains("AppAppearanceColors.panel"))
        XCTAssertFalse(panel.contains("Color(nsColor: .controlBackgroundColor)"))
        XCTAssertFalse(panel.contains(".glassEffect("))
        XCTAssertTrue(controls.contains(".buttonStyle(.bordered)"))
        XCTAssertTrue(controls.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertFalse(source.contains("AppGlassButtonStyleModifier"))
        XCTAssertFalse(source.contains("AppGlassProminentButtonStyleModifier"))
        XCTAssertTrue(group.contains("content"))
        XCTAssertFalse(group.contains("GlassEffectContainer"))
        XCTAssertTrue(source.contains("private struct GlassSurfaceDepthKey"))
        XCTAssertTrue(source.contains("if glassSurfaceDepth > 0"))
        XCTAssertTrue(source.contains("glassSurfaceDepth + 1"))
        XCTAssertTrue(source.contains("private struct AdaptivePopoverChromeModifier"))
        XCTAssertTrue(popover.contains(".fill(panelChromePalette?.shell ?? AppDesignTokens.Palette.contentBackground)"))
        XCTAssertTrue(popover.contains(".strokeBorder(borderColor, lineWidth: borderWidth)"))
        XCTAssertTrue(popover.contains("AppDesignTokens.Palette.separator"))
        XCTAssertTrue(popover.contains("colorSchemeContrast == .increased"))
        XCTAssertTrue(popover.contains("reduceTransparency"))
        XCTAssertFalse(popover.contains(".glassEffect("))
        XCTAssertFalse(popover.contains("GlassVisualEffectBackdrop"))
        XCTAssertFalse(popover.contains(".overlay"))
        XCTAssertFalse(popover.contains(".opacity("))
        XCTAssertTrue(source.contains("view.state = .followsWindowActiveState"))
        XCTAssertEqual(
            source.components(separatedBy: "view.state = .followsWindowActiveState").count - 1,
            2
        )
        XCTAssertFalse(source.contains("GlassVisualEffectBackdrop(material: .underWindowBackground"))
        XCTAssertFalse(source.contains("RadialGradient("))
        XCTAssertFalse(source.contains("LinearGradient("))
        XCTAssertFalse(source.contains("struct MenuBarGlassBackdrop"))
        let segmented = try sourceSegment(
            source,
            from: "private struct AppGlassSegmentedControlModifier: ViewModifier {",
            to: "private struct GlassEffectGroupModifier: ViewModifier {"
        )
        XCTAssertTrue(segmented.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(segmented.contains(".tint(tint)"))
        XCTAssertFalse(segmented.contains(".glassCapsule"))
        XCTAssertFalse(segmented.contains(".padding(3)"))
        XCTAssertFalse(duplicateSource.contains(".glassPanel(cornerRadius: 22, tint: .cyan"))
    }

    func testSharedTypographyUsesNativeSemanticRoles() throws {
        let tokens = try sourceText(at: "Sources/StorageCleanerMac/Support/AppDesignTokens.swift")
        let typography = try sourceText(at: "Sources/StorageCleanerMac/Support/AppTypography.swift")
        let advanced = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift"
        )
        let compact = try sourceText(at: "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")
        let appTypography = try sourceSegment(
            typography,
            from: "enum AppTypography {",
            to: "enum AppPanelTypography {"
        )
        let menuTypography = try sourceSegment(
            typography,
            from: "enum AppPanelTypography {",
            to: "enum MenuBarPanelTypography {"
        )

        XCTAssertTrue(tokens.contains("typealias Typography = AppTypography"))
        XCTAssertTrue(appTypography.contains("static let pageTitle: Font = .system(size: 22, weight: .semibold)"))
        XCTAssertTrue(appTypography.contains("static let windowTitle"))
        XCTAssertTrue(appTypography.contains("static let pageTitle"))
        XCTAssertTrue(appTypography.contains("static let sectionTitle"))
        XCTAssertTrue(appTypography.contains("static let metricValueLarge"))
        XCTAssertTrue(appTypography.contains("static let metricValue"))
        XCTAssertTrue(appTypography.contains("static let body"))
        XCTAssertTrue(appTypography.contains("static let secondaryText"))
        XCTAssertTrue(appTypography.contains("static let caption"))
        XCTAssertTrue(appTypography.contains("static let buttonLabel"))
        XCTAssertTrue(appTypography.contains("static let monospacedMetric"))
        XCTAssertTrue(appTypography.contains("static let secondaryText: Font = .body"))
        XCTAssertTrue(appTypography.contains("static let caption: Font = .system(size: 12)"))
        XCTAssertTrue(appTypography.contains("static let metadata = caption"))
        XCTAssertTrue(appTypography.contains("static let compactLabelEmphasis: Font = .body.weight(.semibold)"))
        XCTAssertTrue(appTypography.contains(".title3.weight(.semibold)"))
        XCTAssertTrue(appTypography.contains(".body"))
        XCTAssertTrue(appTypography.contains(".footnote"))
        XCTAssertFalse(menuTypography.contains(".system(size:"))
        XCTAssertTrue(menuTypography.contains(".headline"))
        XCTAssertTrue(menuTypography.contains(".subheadline"))
        XCTAssertTrue(menuTypography.contains(".callout"))
        XCTAssertTrue(menuTypography.contains(".footnote"))
        XCTAssertTrue(advanced.contains("typealias AdvancedPanelTypography = MenuBarPanelTypography"))
        XCTAssertTrue(compact.contains("geekDetailPage"))
        XCTAssertTrue(advanced.contains(".font(AdvancedPanelTypography.body)"))
    }

    func testMainWindowTextAvoidsSmallSemanticFontOverrides() throws {
        let roots = [
            "Sources/StorageCleanerMac/Support",
            "Sources/StorageCleanerMac/Views",
            "Sources/StorageCleanerMac/Features",
        ]
        let smallOverrides = [
            ".font(.caption",
            ".font(.caption2",
            ".font(.footnote",
            ".font(.subheadline",
            ".font(.callout",
        ]

        for root in roots {
            let rootURL = projectRoot.appendingPathComponent(root)
            let files = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: nil
                )?.allObjects as? [URL]
            )
            for file in files where file.pathExtension == "swift"
                && !file.path.contains("/MenuBarAdvanced/")
                && !file.lastPathComponent.hasPrefix("MenuBar") {
                let source = try r2ProductionSource(at: file)
                for override in smallOverrides {
                    XCTAssertFalse(source.contains(override), "\(file.path): \(override)")
                }
                let relativePath = String(file.path.dropFirst(projectRoot.path.count + 1))
                let scaleViolations = MSeriesV11ScaleContract.violations(path: relativePath, source: source)
                XCTAssertTrue(scaleViolations.isEmpty, "\(relativePath): \(scaleViolations.joined(separator: "; "))")
                if source.contains(".minimumScaleFactor(") {
                    // LIGHTFIELD-R2-PLAN §B2 requires minimumScaleFactor for compact
                    // lightfield numerals (ring centre, metric/summary values, chart
                    // values). Those files are not exempt wholesale: every scaling
                    // line carries `// lightfield-scale-ok` and the count is capped,
                    // so a plain row/segment label cannot start scaling unnoticed.
                    // D69/D70 B7: extend the same line marker and per-file budget
                    // to compact numeric/date columns; the B2 budgets stay at 6.
                    let lightfieldScaleBudget = [
                        "FeatureLightfieldComponents.swift": 6, "FeatureLightfieldCharts.swift": 6,
                        // D77: only the three compact result numerals may scale;
                        // one shared call site, labels still truncate with full AX/help.
                        "FeatureLightfieldResultSpace.swift": 1,
                        "PerformanceBenchmarkV11ResultPage.swift": 2, "PerformanceBenchmarkV11RawRow.swift": 2,
                        "PerformanceBenchmarkV11RunningPage.swift": 2,
                        "LargeFilesView.swift": 1, "FileAnalysisLightfieldView.swift": 3,
                        "FileMigrationLightfieldView.swift": 3, "DuplicateFilesLightfieldView.swift": 3,
                        "FeatureLightfieldFileComponents.swift": 1,
                    ]
                    if let budget = lightfieldScaleBudget[file.lastPathComponent] {
                        let lines = source.components(separatedBy: .newlines).filter { $0.contains(".minimumScaleFactor(") }
                        for line in lines {
                            XCTAssertTrue(line.contains("// lightfield-scale-ok"), "\(file.path): unmarked scaling: \(line)")
                        }
                        XCTAssertLessThanOrEqual(lines.count, budget, "\(file.path): lightfield scaling budget")
                    } else {
                        XCTAssertTrue(
                            ["ModulePresentation.swift", "SidebarView.swift"].contains(file.lastPathComponent),
                            "\(file.path): only compact immersive controls may scale a single-line label"
                        )
                    }
                    XCTAssertTrue(
                        source.contains(".lineLimit(1)"),
                        "\(file.path): compact immersive labels must remain single-line"
                    )
                }
                XCTAssertFalse(
                    source.contains(".controlSize(.mini)"),
                    "\(file.path): main-window controls must not use mini sizing"
                )

                let lines = source.components(separatedBy: .newlines)
                for (index, line) in lines.enumerated() where line.contains(".controlSize(.small)") {
                    let contextStart = max(0, index - 8)
                    let context = lines[contextStart...index].joined(separator: "\n")
                    XCTAssertTrue(
                        context.contains("ProgressView(") || context.contains("Image(systemName:"),
                        "\(file.path):\(index + 1): small sizing is reserved for progress indicators and icon-only controls"
                    )
                }
            }
        }
    }

    func testBenchmarkShowsOneStandardWithoutRepeatedProfileChrome() throws {
        // D64: preserve the model contract and check the current official result route rather than removed v6 chrome.
        let models = try sourceText(at: "Sources/StorageCleanerMac/Models/MacBenchmarkModels.swift")
        let dashboard = try sourceText(at: "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7DashboardView.swift")
        let results = try sourceText(at: "Sources/StorageCleanerMac/Views/ComputerHealth/MSeriesRawResultView.swift")
        let leaderboard = try sourceText(at: "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7LeaderboardSection.swift")
        XCTAssertTrue(models.contains("static let allCases: [BenchmarkProfile] = [.standard]"))
        XCTAssertTrue(dashboard.contains("BenchmarkV7Category.corePerformance"))
        XCTAssertTrue(dashboard.contains("isCurrentComparableOfficialResult"))
        XCTAssertTrue(dashboard.contains("categoryScores"))
        XCTAssertFalse(dashboard.contains("selectedProfile"))
        XCTAssertFalse(dashboard.contains("No verified Standard v6 baseline is available"))
        XCTAssertFalse(dashboard.contains("1920 × 1080  OFFSCREEN METAL"))
        XCTAssertFalse(dashboard.contains("1.887B TRIANGLES / SAMPLE"))
        XCTAssertTrue(results.contains("awaiting reference calibration"))
        XCTAssertFalse(results.contains("title: L10n.text(\"模式\", \"Profile\")"))
        XCTAssertTrue(leaderboard.contains("eligible"))
        XCTAssertFalse(leaderboard.contains("L10n.text(\"模式\", \"Profile\")"))
        XCTAssertFalse(leaderboard.contains("text: MacBenchmarkPresentation.profileTitle(profile)"))
    }

    func testBenchmarkWrapsMetadataAndAvoidsNestedContentCards() throws {
        // D64: native V7 layouts replace removed v6 hero/result cards. Each adaptive status layout retains an action.
        let dashboard = try sourceText(at: "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7DashboardView.swift")
        let results = try sourceText(at: "Sources/StorageCleanerMac/Views/ComputerHealth/MSeriesRawResultView.swift")
        let leaderboard = try sourceText(at: "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7LeaderboardSection.swift")
        let hero = try sourceSegment(dashboard, from: "private func benchmarkStatusBar(", to: "private var compactTemperature: some View")
        XCTAssertTrue(hero.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(hero.contains("benchmarkStatusMessage"))
        // Each status-message alternative must expose the action; the number of fallbacks may change in V1.
        for alternative in hero.components(separatedBy: "benchmarkStatusMessage").dropFirst() {
            XCTAssertTrue(alternative.contains("benchmarkPrimaryAction"))
        }
        XCTAssertTrue(hero.contains("fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(hero.contains("benchmark.persistentActions"))
        XCTAssertFalse(hero.contains("MetadataPill("))
        XCTAssertTrue(results.contains("Text(title(metric.id)).frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertTrue(results.contains(".accessibilityElement(children: .combine)"))
        XCTAssertFalse(results.contains(".glassPanel("))
        XCTAssertFalse(results.contains("RoundedRectangle("))
        XCTAssertTrue(leaderboard.contains("AppButton("))
        XCTAssertTrue(leaderboard.contains("entry.memoryGB"))
        XCTAssertTrue(leaderboard.contains("entry.processorModel"))
        XCTAssertTrue(leaderboard.contains("GridItem(.adaptive(minimum: 150)"))
        // The V7 section already has one outer panel; no header or row may add an inner panel.
        let leaderboardBody = try sourceSegment(leaderboard, from: "var body: some View", to: "private var header:")
        XCTAssertEqual(occurrences(of: ".glassPanel(", in: leaderboard), 1)
        XCTAssertEqual(occurrences(of: ".glassPanel(", in: leaderboardBody), 1)
        XCTAssertFalse(leaderboard.contains("RoundedRectangle("))
    }

    func testSharedPageHeaderSymbolsSelectionAndChartsUseOneSemanticSystem() throws {
        let header = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SmartCareComponents.swift"
        )
        let pageHeader = try sourceSegment(
            header,
            from: "struct AppPageHeader<Actions: View>: View {",
            to: "struct TaskSearchField: View {"
        )
        let moduleHeader = try sourceSegment(
            try sourceText(at: "Sources/StorageCleanerMac/Views/ModulePresentation.swift"),
            from: "struct ModulePageHeader<Actions: View>: View {",
            to: "typealias PageHeader<Actions: View>"
        )
        let symbols = try sourceText(
            at: "Sources/StorageCleanerMac/Support/AppSymbols.swift"
        )
        let iconStyle = try sourceText(
            at: "Sources/StorageCleanerMac/Support/AppIconStyle.swift"
        )
        let designTokens = try sourceText(
            at: "Sources/StorageCleanerMac/Support/AppDesignTokens.swift"
        )
        let sidebar = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SidebarView.swift"
        )
        let charts = try sourceText(
            at: "Sources/StorageCleanerMac/Support/AppChartPalette.swift"
        )
        let controls = try sourceText(
            at: "Sources/StorageCleanerMac/Support/AppControls.swift"
        )
        let models = try sourceText(
            at: "Sources/StorageCleanerMac/Models/StorageModels.swift"
        )
        let telemetry = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarTelemetryChart.swift"
        )
        let overview = try sourceText(
            at: "Sources/StorageCleanerMac/Views/OverviewView.swift"
        )
        let utilities = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"
        )
        let panelSources = try [
            "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDiskView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekProcessorView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift",
        ].map { try sourceText(at: $0) }

        XCTAssertTrue(header.contains("struct AppPageHeader"))
        XCTAssertFalse(pageHeader.contains("AppSymbolIcon("))
        XCTAssertTrue(moduleHeader.contains("AppPageHeader("))
        XCTAssertFalse(moduleHeader.contains("AppSymbolIcon("))
        XCTAssertTrue(pageHeader.contains("Text(title)"))
        XCTAssertTrue(pageHeader.contains("var isHero = false"))
        XCTAssertTrue(pageHeader.contains("isHero && moduleTheme.isImmersive"))
        // D53 §2.3: module pages use PageHero; neutral pages keep the
        // shared page title type.
        XCTAssertTrue(pageHeader.contains("PageHero("))
        XCTAssertTrue(pageHeader.contains("AppTypography.pageTitle"))
        XCTAssertFalse(pageHeader.contains("var iconSize:"))
        XCTAssertFalse(pageHeader.contains("var glyphSize:"))
        XCTAssertFalse(pageHeader.contains("let tint: Color"))
        XCTAssertTrue(iconStyle.contains("enum AppIconRole"))
        XCTAssertTrue(iconStyle.contains("enum AppIconSizing"))
        XCTAssertTrue(iconStyle.contains("struct AppSymbolIcon: View"))
        XCTAssertTrue(iconStyle.contains("role == .pageFeature || role == .emptyState"))
        XCTAssertTrue(iconStyle.contains("size: role.glyphSize"))
        XCTAssertTrue(iconStyle.contains("weight: role.weight"))
        XCTAssertTrue(iconStyle.contains(".scaledToFit()"))
        XCTAssertTrue(iconStyle.contains(".frame(width: size, height: size, alignment: .center)"))
        XCTAssertTrue(iconStyle.contains(".frame(width: role.frameSize, height: role.frameSize)"))
        XCTAssertTrue(iconStyle.contains("static let iconHitRegion: CGFloat = 32"))
        XCTAssertTrue(iconStyle.contains("case .toolbar, .inline, .sidebar, .settingsNavigation: 16"))
        XCTAssertTrue(iconStyle.contains("case .panelNavigation, .panelHeader, .panelMode: 18"))
        XCTAssertTrue(iconStyle.contains("case .toolbar, .panelNavigation:"))
        XCTAssertTrue(iconStyle.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(iconStyle.contains("var isDecorative = false"))
        XCTAssertTrue(iconStyle.contains(".accessibilityHidden(isDecorative)"))
        XCTAssertFalse(overview.contains("AppSymbolIcon("))
        XCTAssertTrue(utilities.contains("isDecorative: true"))
        XCTAssertTrue(sidebar.contains("FeatureLightfieldArtwork(art:"))
        // D154: every sidebar row is a module mark; the Settings tile left
        // with the Settings row. The classic block keeps the module pigment.
        XCTAssertFalse(sidebar.contains("IconTile("))
        XCTAssertTrue(sidebar.contains("family.primaryRoute.moduleTheme.pigment"))
        XCTAssertTrue(symbols.contains("static let showMainWindow = \"macwindow\""))
        XCTAssertTrue(models.contains("AppSymbols.Navigation.safeCleanup"))
        XCTAssertTrue(controls.contains("AppDesignTokens.Palette.accent : nil"))
        XCTAssertTrue(controls.contains("? AppDesignTokens.Palette.onAccent"))
        XCTAssertTrue(designTokens.contains(
            "static let onAccent = Color(nsColor: .alternateSelectedControlTextColor)"
        ))
        XCTAssertFalse(designTokens.contains("static let onAccent = Color.white"))
        XCTAssertTrue(charts.contains("static let cpuUser"))
        XCTAssertTrue(charts.contains("static let cpuSystem"))
        XCTAssertTrue(telemetry.contains("AppChartPalette.download"))
        XCTAssertTrue(telemetry.contains("AppChartPalette.upload"))
        for panelSource in panelSources {
            let withoutDataArrow = panelSource.replacingOccurrences(
                of: "Image(systemName: \"arrow.right\")", with: "")
            XCTAssertFalse(withoutDataArrow.contains("Image(systemName: \""))
            XCTAssertFalse(withoutDataArrow.contains("systemImage: \""))
        }
    }

    func testGeneratedArtworkIsAllowListedForBrandSurfacesOnly() throws {
        let artwork = try sourceText(
            at: "Sources/StorageCleanerMac/Support/AppArtwork.swift"
        )
        let sidebar = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SidebarView.swift"
        )
        let components = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SmartCareComponents.swift"
        )
        let settings = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SettingsView.swift"
        )
        let workspace = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MainWorkspaceViews.swift"
        )
        let allowList = try sourceSegment(
            artwork,
            from: "enum AppArtworkAsset {",
            to: "struct AppIconView: View"
        )

        XCTAssertTrue(allowList.contains("case appMain"))
        XCTAssertTrue(allowList.contains("case smartCareHero"))
        XCTAssertEqual(occurrences(of: "case ", in: allowList), 6)
        XCTAssertFalse(allowList.contains("SidebarIcon"))
        XCTAssertFalse(allowList.contains("FeatureIcon"))
        XCTAssertTrue(artwork.contains(".interpolation(.high)"))
        XCTAssertTrue(artwork.contains(".aspectRatio(contentMode: .fit)"))
        XCTAssertTrue(settings.contains("AppIconView("))
        XCTAssertTrue(settings.contains("asset: .appMain"))
        XCTAssertFalse(sidebar.contains("AppIconView("))
        XCTAssertFalse(components.contains("AppIconView("))
        XCTAssertFalse(workspace.contains("asset: .smartCareHero"))
        XCTAssertTrue(sidebar.contains("FeatureLightfieldArtwork(art:"))
        // D67/D154: generated thumbnails belong to clickable navigation rows
        // (26 pt module marks, as CleanMyMac's sidebar).
        XCTAssertTrue(sidebar.contains(".frame(width: Self.glyphSide, height: Self.glyphSide)"))
        // D64②: the shared header has no decorative icon; the central
        // illustration remains on its agreed surface and stays decorative.
        let header = try sourceSegment(components,
            from: "struct AppPageHeader<Actions: View>: View {", to: "struct TaskSearchField: View {")
        let orbit = try sourceText(at: "Sources/StorageCleanerMac/Views/DesignSystem/OrbitLandingArtwork.swift")
        XCTAssertFalse(header.contains("AppSymbolIcon("))
        XCTAssertFalse(header.contains("GeneratedArtView("))
        XCTAssertTrue(header.contains("PageHero("))
        XCTAssertTrue(header.contains(".accessibilityAddTraits(.isHeader)"))
        XCTAssertTrue(orbit.contains("GeneratedArtView("))
        XCTAssertTrue(orbit.contains(".accessibilityHidden(true)"))
    }

    func testPageHeadersUseOneOuterPageGrid() throws {
        let tokens = try sourceText(
            at: "Sources/StorageCleanerMac/Support/AppDesignTokens.swift"
        )
        let components = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SmartCareComponents.swift"
        )
        let content = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ContentView.swift"
        )
        let modulePresentation = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ModulePresentation.swift"
        )
        let health = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/ComputerHealthWorkspaceView.swift"
        )
        let overview = try sourceText(
            at: "Sources/StorageCleanerMac/Views/OverviewView.swift"
        )
        let utilities = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"
        )
        let smartScan = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SmartScanProgressView.swift"
        )
        let settings = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SettingsView.swift"
        )
        let pageHeader = try sourceSegment(
            components,
            from: "struct AppPageHeader<Actions: View>: View {",
            to: "struct TaskSearchField: View {"
        )
        let modulePageHeader = try sourceSegment(
            modulePresentation,
            from: "struct ModulePageHeader<Actions: View>: View {",
            to: "typealias PageHeader<Actions: View>"
        )
        let reviewWorkspaceShell = try sourceSegment(
            content,
            from: "private struct ReviewWorkspaceShell<Content: View, HeaderActions: View>: View {",
            to: "private struct ToolPreparationView: View {"
        )
        let lightfieldSettings = try sourceText(at: "Sources/StorageCleanerMac/Views/Settings/SettingsLightfield.swift")
        let settingsHeader = try r2SourceDeclaration("struct SettingsLightfieldPane", in: lightfieldSettings)

        XCTAssertTrue(tokens.contains("static let pagePadding: CGFloat = 24"))
        XCTAssertFalse(pageHeader.contains(".padding(.horizontal"))
        XCTAssertTrue(pageHeader.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(pageHeader.contains(".padding(.vertical, AppDesignTokens.Spacing.medium)"))
        XCTAssertFalse(pageHeader.contains(".fixedSize(horizontal: true, vertical: false)"))
        // D64③ leaves one Text title instead of a title/subtitle VStack.
        // It measures unwrapped in the first fit, then explicitly wraps in
        // the fallback. Preserve vertical expansion and both real fit paths.
        XCTAssertTrue(pageHeader.contains(".fixedSize(horizontal: !wrapsTitle, vertical: true)"))
        XCTAssertTrue(pageHeader.contains("titleBlock(wrapsTitle: false)"))
        XCTAssertTrue(pageHeader.contains("titleBlock(wrapsTitle: true)"))
        XCTAssertTrue(pageHeader.contains("Text(title)"))
        XCTAssertTrue(pageHeader.contains(".accessibilityAddTraits(.isHeader)"))
        XCTAssertFalse(pageHeader.contains(".lineLimit("))
        XCTAssertFalse(pageHeader.contains(".frame(width: 280"))
        XCTAssertFalse(pageHeader.contains(".frame(minWidth: 560)"))
        XCTAssertTrue(modulePresentation.contains(".padding(.horizontal, layout.contentPadding)"))
        XCTAssertTrue(reviewWorkspaceShell.contains("ManagementListPage("))
        XCTAssertFalse(reviewWorkspaceShell.contains("GlassSegmentedControl("))
        XCTAssertTrue(modulePresentation.contains("struct ModulePageHeader<Actions: View>: View"))
        XCTAssertTrue(modulePageHeader.contains("AppPageHeader("))
        XCTAssertFalse(modulePageHeader.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(modulePresentation.contains("struct ManagementListPage<"))
        XCTAssertTrue(modulePresentation.contains("struct DashboardPage<"))
        XCTAssertTrue(modulePresentation.contains("struct FeatureWorkspaceSurface<"))
        XCTAssertTrue(modulePresentation.contains("FeatureWorkspaceSurface {"))
        XCTAssertFalse(modulePresentation.contains("ContentPanel {"))
        XCTAssertTrue(modulePresentation.contains(".padding(.horizontal, layout.contentPadding)"))
        XCTAssertTrue(modulePresentation.contains(".padding(.bottom, layout.contentPadding)"))
        // D67 owns the health pilot title rather than the V1 header.
        XCTAssertTrue(health.contains("FeatureLightfieldPage("))
        XCTAssertTrue(overview.contains("DashboardPage("))
        XCTAssertTrue(smartScan.contains(".padding(.top, AppDesignTokens.Layout.pagePadding)"))
        XCTAssertTrue(settingsHeader.contains("Text(category.title)"))
        // D69/B6 retains a single title and adds approved B2 header artwork.
        XCTAssertFalse(settingsHeader.contains("Text(category.subtitle)"))
        XCTAssertFalse(settingsHeader.contains("AppSymbolIcon("))
        XCTAssertTrue(settingsHeader.contains("FeatureLightfield.titleSize"))
        XCTAssertFalse(settingsHeader.contains("AppTypography.pageSubtitle"))
        XCTAssertFalse(settingsHeader.contains("Image(systemName:"))
        // B6's fixed 48 pt header uses a single line; subtitle wrapping was removed.
        XCTAssertTrue(settingsHeader.contains(".lineLimit(1)"))
        XCTAssertTrue(settingsHeader.contains(".accessibilityAddTraits(.isHeader)"))
        XCTAssertTrue(settings.contains("SettingsWindowConfigurator(title: selectedCategory.title)"))
        XCTAssertEqual(
            occurrences(of: ".padding(.top, AppDesignTokens.Layout.pagePadding)", in: utilities),
            0
        )
    }

    func testSharedControlsDegradeWithoutIconTextOverlap() throws {
        let controls = try sourceText(
            at: "Sources/StorageCleanerMac/Support/AppControls.swift"
        )
        let iconStyle = try sourceText(
            at: "Sources/StorageCleanerMac/Support/AppIconStyle.swift"
        )
        let adaptiveLabel = try sourceSegment(
            controls,
            from: "private struct AdaptiveAppButtonLabel: View {",
            to: "struct AppButton: View {"
        )
        let filterButton = try sourceSegment(
            controls,
            from: "struct AppFilterButton: View {",
            to: "struct AppMenuButton<Content: View>: View {"
        )

        XCTAssertTrue(adaptiveLabel.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(adaptiveLabel.contains("titleOnlyLabel"))
        XCTAssertTrue(adaptiveLabel.contains("wrappedTitleLabel"))
        XCTAssertTrue(adaptiveLabel.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(filterButton.contains("countedLabel(showsIcon: true, wrapsTitle: false)"))
        XCTAssertTrue(filterButton.contains("countedLabel(showsIcon: false, wrapsTitle: false)"))
        XCTAssertTrue(filterButton.contains("countedLabel(showsIcon: false, wrapsTitle: true)"))
        XCTAssertTrue(iconStyle.contains("static let minimumControlHeight: CGFloat = 28"))
    }

    func testSidebarRowsGrowForLongLocalizedTitlesInsteadOfClipping() throws {
        let sidebar = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SidebarView.swift"
        )
        // D154: the module rows and the version line of the CleanMyMac sidebar.
        let navigationRow = try sourceSegment(
            sidebar,
            from: "private struct SidebarModuleRow: View {",
            to: "private struct SidebarSelectionBlock: View {"
        )
        let footer = try sourceSegment(
            sidebar,
            from: "private var footerLine: some View {",
            to: "private var sidebarToggleButton: some View {"
        )

        XCTAssertTrue(navigationRow.contains(".lineLimit(2)"))
        XCTAssertTrue(navigationRow.contains(".frame(minHeight: rowHeight)"))
        XCTAssertFalse(navigationRow.contains(".frame(height: rowHeight)"))
        XCTAssertTrue(footer.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(footer.contains(".frame(height: AppDesignTokens.Layout.sidebarRowHeight)"))
    }

    func testPanelHeaderAdaptsStatusBeforeTextCanCollide() throws {
        // D64 removes the dormant header. The real memory process header
        // still stacks its controls before they can collide with text.
        let memory = try D64MenuBarSource.source("MenuBarAdvanced/GeekMemoryView.swift")
        let card = try r2SourceDeclaration("private var geekMemoryProcessesCard:", in: memory)
        XCTAssertTrue(card.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(card.contains("memoryProcessHeader"))
        XCTAssertTrue(card.contains("memoryProcessTitle"))
        XCTAssertTrue(card.contains("memoryProcessActions"))
        XCTAssertTrue(card.contains(".frame(maxWidth: .infinity, alignment: .trailing)"))
        // D139: the header is built for each form of the quit button (was
        // `private var memoryProcessHeader:`).
        let header = try r2SourceDeclaration("private func memoryProcessHeader(", in: memory)
        XCTAssertTrue(header.contains("memoryProcessTitle"))
        XCTAssertTrue(header.contains("memoryProcessActions"))
        XCTAssertFalse(header.contains(".frame(width:"))
    }

    func testTertiaryPanelsUseOneEqualContentInset() throws {
        let tertiary = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift"
        )
        let components = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPanelComponents.swift"
        )
        let tokens = try sourceText(
            at: "Sources/StorageCleanerMac/Support/MiniWindowStyleTokens.swift"
        )
        let chrome = try sourceSegment(
            tertiary,
            from: "private func tertiaryDetailChrome<Content: View>(",
            to: "@ViewBuilder\n    private func tertiaryDetailBody"
        )

        XCTAssertTrue(chrome.contains("contentPadding: CGFloat = GeekPanelLayout.contentPadding"))
        XCTAssertTrue(chrome.contains(".padding(contentPadding)"))
        XCTAssertTrue(components.contains("static let contentPadding = MiniWindowStyleTokens.contentInset"))
        XCTAssertTrue(tokens.contains("static let contentInset"))
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceText(at relativePath: String) throws -> String {
        return try r2ProductionSource(at: projectRoot.appendingPathComponent(relativePath))
    }

    private func sourceSegment(_ source: String, from start: String, to end: String) throws -> String {
        let tail = try XCTUnwrap(source.components(separatedBy: start).dropFirst().first)
        return try XCTUnwrap(tail.components(separatedBy: end).first)
    }

    private func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}
