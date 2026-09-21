import AppKit
import XCTest

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
        XCTAssertTrue(sidebar.contains("private struct SidebarFooter: View"))
        XCTAssertTrue(sidebar.contains("SettingsLink"))
        XCTAssertTrue(modulePresentation.contains("struct MainContentHost<Content: View>: View"))
        XCTAssertTrue(itemList.contains("ItemListResponsiveLayout.mode(availableWidth:"))
        XCTAssertFalse(itemList.contains("HSplitView"))
        XCTAssertTrue(itemList.contains(".appSelectableRowSurface("))
        XCTAssertGreaterThanOrEqual(occurrences(of: "Section {", in: settings), 5)
        XCTAssertTrue(settings.contains("private var settingsSidebar: some View"))
        XCTAssertTrue(settings.contains("NavigationSplitView"))
        XCTAssertTrue(settings.contains("List(selection: settingsSelection)"))
        XCTAssertTrue(settings.contains("settingsPane(for: selectedCategory)"))
        XCTAssertTrue(settings.contains(".formStyle(.grouped)"))
        XCTAssertTrue(settings.contains("if category == .accessAndSetup"))
        XCTAssertEqual(occurrences(of: ".formStyle(.columns)", in: settings), 1)
        XCTAssertFalse(settings.contains("runModal()"))
        XCTAssertFalse(scanStore.contains("runModal()"))
        XCTAssertTrue(settings.contains("exclusionPanelCoordinator.present("))
        XCTAssertTrue(scanStore.contains("folderAccessPanelCoordinator.present("))
        XCTAssertTrue(openPanelCoordinator.contains("panel.beginSheetModal(for: hostWindow"))
        XCTAssertTrue(openPanelCoordinator.contains("maximumSheetDismissalChecks"))
        XCTAssertTrue(openPanelCoordinator.contains("hostWindow.attachedSheet == nil"))
    }

    func testSettingsUseNativeGroupedRowsAndKeepGeekPanelConfigurationCompact() throws {
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

        XCTAssertTrue(settings.contains("private var settingsSidebar: some View"))
        XCTAssertTrue(settings.contains(".listStyle(.sidebar)"))
        XCTAssertTrue(settings.contains("settingsPane(for: selectedCategory)"))
        XCTAssertTrue(settings.contains(".formStyle(.grouped)"))
        XCTAssertEqual(occurrences(of: ".formStyle(.columns)", in: settings), 1)
        XCTAssertTrue(settings.contains("AppDesignTokens.Layout.settingsPageMaxWidth"))
        XCTAssertTrue(settings.contains("settings.selected-category.v1"))
        XCTAssertGreaterThanOrEqual(occurrences(of: "LabeledContent(", in: settings), 8)
        XCTAssertFalse(settings.contains("ForEach(PanelDensity.menuBarChoices)"))
        XCTAssertFalse(panelChrome.contains("ForEach(PanelDensity.menuBarChoices)"))
        XCTAssertFalse(panelChrome.contains("Picker(L10n.text(\"面板模式\", \"Panel Mode\")"))
        XCTAssertTrue(panelChrome.contains("Customize Geek Overview…"))
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
        XCTAssertTrue(settings.contains("ModuleBackground(theme: settingsTheme)"))
        XCTAssertTrue(settings.contains(".environment(\\.moduleTheme, settingsTheme)"))
        XCTAssertTrue(settings.contains(".scrollContentBackground(.hidden)"))
        XCTAssertFalse(settings.contains(".background(AppDesignTokens.Palette.contentBackground)"))
        XCTAssertTrue(tokens.contains("static let settingsPageMaxWidth: CGFloat = 600"))
    }

    func testSettingsConsolidatesAccessStatusJumpsAndTutorial() throws {
        let settings = try sourceText(at: "Sources/StorageCleanerMac/Views/SettingsView.swift")
        let onboarding = try sourceText(
            at: "Sources/StorageCleanerMac/Views/FirstLaunchOnboardingView.swift"
        )

        XCTAssertTrue(settings.contains("case accessAndSetup"))
        XCTAssertTrue(settings.contains("PermissionSetupCard("))
        XCTAssertTrue(onboarding.contains("PermissionSetupCard("))
        XCTAssertTrue(settings.contains("private var permissionTutorialSection"))
        XCTAssertTrue(settings.contains("SettingsTutorialStep("))
        XCTAssertTrue(settings.contains("openFullDiskAccessSettings()"))
        XCTAssertTrue(settings.contains("openFilesAndFoldersSettings()"))
        XCTAssertTrue(settings.contains("openAppManagementSettings()"))
        XCTAssertTrue(settings.contains("Privacy_AppBundles"))
        XCTAssertTrue(settings.contains("fanControl.openApprovalSettings()"))
        XCTAssertTrue(settings.contains("com.apple.Notifications-Settings.extension"))
        XCTAssertTrue(settings.contains("辅助功能、屏幕录制、相机、麦克风、定位与自动化"))
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
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/MacBenchmarkDashboardView.swift"
        )
        let acceleratorBenchmark = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/MacAcceleratorBenchmarkSection.swift"
        )
        let sustainedBenchmark = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/MacSustainedBenchmarkSection.swift"
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
            from: "private var emptyResultCard: some View {",
            to: "private var displayedProgress: MacBenchmarkPresentationProgress? {"
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
        XCTAssertTrue(components.contains("width: progress == nil ? 32 : size"))
        XCTAssertFalse(components.contains("progress ?? (isActive ? 0.18 : 0)"))
        XCTAssertFalse(components.contains("progress ?? 0.70"))
        XCTAssertTrue(emptyState.contains("AppStateIconRing(systemImage: systemImage, isActive: isLoading)"))
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
        XCTAssertTrue(smartScan.contains("SmartScanProgressDashboard(progress: progress)"))
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
        XCTAssertTrue(health.contains("HeroScanPage("))
        XCTAssertFalse(health.contains("AppEmptyState("))
        XCTAssertTrue(health.contains("isLoading: healthStore.isRefreshing"))
        XCTAssertTrue(benchmarkEmptyState.contains("AppEmptyState("))
        XCTAssertTrue(acceleratorBenchmark.contains("AppStateIconRing("))
        XCTAssertTrue(sustainedBenchmark.contains("AppStateIconRing("))
        XCTAssertTrue(benchmark.contains("ProgressView(value: normalizedProgress)"))
        XCTAssertTrue(benchmark.contains("transaction.animation = nil"))
        XCTAssertFalse(acceleratorBenchmark.contains("ProgressView("))
        XCTAssertFalse(sustainedBenchmark.contains("ProgressView("))
        XCTAssertTrue(largeFiles.contains("emptyPanel(density: .workspace)"))
        XCTAssertTrue(largeFiles.contains("emptyStateTitle"))
        XCTAssertTrue(largeFiles.contains("尚无可安全搬移的文件"))
        XCTAssertTrue(utilities.contains("density: .workspace"))
        XCTAssertTrue(utilities.contains("density: .inline"))
        XCTAssertTrue(startupItems.contains("if presentation.visibleItems.isEmpty, !isLoading"))
        XCTAssertTrue(startupItems.contains("正在扫描启动项目"))
        XCTAssertTrue(startupItems.contains("isLoading: true"))
        XCTAssertTrue(appUpdates.contains("AppUpdateScanningPage("))
        XCTAssertTrue(appUpdates.contains("RuntimeActivityCard("))
        XCTAssertTrue(startupItems.contains("RuntimeInlineStatus("))
        XCTAssertTrue(startupItems.contains("List(selection: $selectedItemID)"))
        XCTAssertTrue(appUpdates.contains("fraction: progress.progressFraction"))
        XCTAssertGreaterThanOrEqual(occurrences(of: "AppEmptyState(", in: startupItems), 2)
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
        XCTAssertFalse(overview.contains("AppPageHeader("))
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
        XCTAssertTrue(results.contains("发现 \\(ByteFormat.string(safeBytes)) 可安全清理"))
        XCTAssertTrue(results.contains("需要人工判断"))
        XCTAssertTrue(results.contains("reviewCandidates.filter(\\.isSelectable)"))
        XCTAssertTrue(results.contains("reviewCandidates.filter { !$0.isSelectable }"))
        XCTAssertTrue(results.contains("case .reviewOnly: valueCandidates = actionableReviewCandidates"))
        XCTAssertTrue(results.contains("只读参考"))
        XCTAssertTrue(results.contains("仅供查看"))
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
        XCTAssertTrue(results.contains("store.cleanupSelection.state(for: Array(tierSelectionIDs))"))

        XCTAssertTrue(results.contains("ForEach(tierSubcategories)"))
        XCTAssertFalse(source.contains("private struct CleanupCategorySelectionCard"))
        XCTAssertTrue(subcategory.contains("@State private var isExpanded = false"))
        XCTAssertTrue(subcategory.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(subcategory.contains("if isExpanded {"))
        XCTAssertTrue(subcategory.contains("ForEach(candidates)"))
        XCTAssertTrue(subcategory.contains(".padding(.leading, layout.cardPadding)"))
        XCTAssertTrue(subcategory.contains(".glassPanel("))
        XCTAssertTrue(subcategory.contains(".easeInOut(duration: 0.16)"))

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
        XCTAssertTrue(scanViews.contains("受保护，不能加入清理计划"))
        XCTAssertTrue(scanViews.contains("仅供查看，不能加入清理计划"))
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
        XCTAssertTrue(confirmation.contains("当前立即释放取决于废纸篓和文件系统状态"))

        XCTAssertTrue(progressPage.contains("CleanupExecutionStageList("))
        XCTAssertTrue(progressPage.contains("onCancel: (() -> Void)?"))
        XCTAssertTrue(progressPage.contains("progress.processedItemCount"))
        XCTAssertTrue(completedPage.contains("DisclosureGroup(L10n.text(\"清理详情\", \"Cleanup Details\")"))
        XCTAssertTrue(completedPage.contains("movedToRecoverableLocationBytes"))
        XCTAssertTrue(completedPage.contains("reclaimableAfterEmptyingTrashBytes"))
        XCTAssertTrue(completedPage.contains("permanentlyFreedBytes"))
        XCTAssertTrue(completedPage.contains("availableSpaceDeltaBytes"))
        XCTAssertTrue(completedPage.contains("清空废纸篓后最多可释放这些空间"))
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
        XCTAssertTrue(row.contains(".toggleStyle(.checkbox)"))
        XCTAssertFalse(row.contains("Button(action: toggleSelection)"))
        XCTAssertFalse(row.contains("private var riskControl"))
        XCTAssertGreaterThanOrEqual(occurrences(of: "AppIconButton(", in: row), 2)
        XCTAssertTrue(row.contains("CleanupRiskBadge(risk: candidate.risk)"))
        XCTAssertFalse(row.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(row.contains("查看 \\(candidate.sourceURL.lastPathComponent) 的详细信息"))
        XCTAssertTrue(row.contains("在 Finder 中显示 \\(candidate.sourceURL.lastPathComponent)"))
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
        let progressBar = try sourceSegment(
            source,
            from: "private struct SmartScanThinProgressBar: View {",
            to: "private struct ScanProgressStageList: View {"
        )

        XCTAssertTrue(page.contains("RuntimeActivityFooter"))
        XCTAssertTrue(page.contains("L10n.text(\"只读扫描\", \"Read-only\")"))
        XCTAssertTrue(progressBar.contains("ProgressView(value: Double(fraction), total: 1)"))
        XCTAssertTrue(progressBar.contains(".accessibilityLabel(L10n.text(\"扫描进度\", \"Scan progress\"))"))
        XCTAssertTrue(progressBar.contains(".accessibilityValue"))
        XCTAssertFalse(progressBar.contains("GeometryReader"))
    }

    func testSharedMotionUsesVisiblePageTransitionAndHonorsReduceMotion() throws {
        let source = try sourceText(
            at: "Sources/StorageCleanerMac/Support/AppInteractionStyle.swift"
        )

        XCTAssertTrue(source.contains(".offset(y: reduceMotion || isVisible ? 0 : distance)"))
        XCTAssertTrue(source.contains("guard !reduceMotion else { return .opacity }"))
        XCTAssertTrue(source.contains("private struct AppPageTransitionModifier: ViewModifier"))
        XCTAssertTrue(source.contains("verticalOffset: 8"))
        XCTAssertTrue(source.contains("verticalOffset: -4"))
        XCTAssertTrue(source.contains(".offset(y: verticalOffset)"))
        XCTAssertFalse(source.contains("scale: 0.988"))
        XCTAssertFalse(source.contains(".snappy("))
    }

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
        XCTAssertTrue(presentation.contains("RadialGradient("))
        XCTAssertTrue(presentation.contains("theme.endColor(for: colorScheme)"))
        XCTAssertFalse(presentation.contains("theme.isImmersive ? .dark : colorScheme"))
        XCTAssertTrue(presentation.contains("@Environment(\\.accessibilityReduceTransparency)"))
        XCTAssertFalse(presentation.contains("ModuleTechnicalBackdrop"))
        XCTAssertFalse(presentation.contains("value: route.rawValue"))
        XCTAssertTrue(presentation.contains(".environment(\\.moduleTheme, theme)"))
        XCTAssertTrue(themes.contains("enum ModuleThemeCatalog"))
        XCTAssertTrue(themes.contains("case .startup:"))
        XCTAssertTrue(themes.contains("case .updater:"))
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
            let source = try String(contentsOf: file, encoding: .utf8)
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

        XCTAssertTrue(source.contains("AppPageHeader("))
        XCTAssertTrue(source.contains("isHero: true"))
        XCTAssertTrue(source.contains("ReviewFilter.healthHub.pageSubtitle"))
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
        XCTAssertTrue(duplicates.contains("FeatureDataPageShell("))
        XCTAssertTrue(duplicates.contains("重新扫描重复文件"))
        XCTAssertTrue(content.contains("重新分析磁盘"))
        XCTAssertFalse(largeFiles.contains("AppPageHeader("))
        XCTAssertFalse(duplicates.contains("AppPageHeader("))
        XCTAssertFalse(largeFiles.contains("ManagementListPage("))
        XCTAssertFalse(duplicates.contains("ManagementListPage("))
    }

    func testBenchmarkScrollUsesFlatContentSurfacePolicy() throws {
        let dashboard = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/MacBenchmarkDashboardView.swift"
        )
        let glass = try sourceText(at: "Sources/StorageCleanerMac/Support/GlassStyle.swift")
        let panel = try sourceSegment(
            glass,
            from: "private struct GlassPanelModifier: ViewModifier {",
            to: "private struct GlassCapsuleModifier: ViewModifier {"
        )

        XCTAssertTrue(dashboard.contains(".environment(\\.scrollSafeGlass, true)"))
        XCTAssertTrue(panel.contains("Color(nsColor: .controlBackgroundColor)"))
        XCTAssertTrue(panel.contains("(tint ?? .clear).opacity(tintOpacity)"))
        XCTAssertTrue(panel.contains(".strokeBorder(borderColor, lineWidth: 1)"))
        XCTAssertTrue(panel.contains("guard colorSchemeContrast != .increased else { return 0 }"))
        XCTAssertFalse(panel.contains(".glassEffect("))
        XCTAssertFalse(panel.contains(".ultraThinMaterial"))
        XCTAssertFalse(panel.contains(".regularMaterial"))
    }

    func testMemoryEmptyStateHidesUnavailableActionsAndAvoidsRepeatedMetrics() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let releasePanel = try sourceSegment(
            source,
            from: "private struct MemoryReleasePanel: View {",
            to: "private struct MemoryInlineMetric: View {"
        )
        let selectionPanel = try sourceSegment(
            source,
            from: "struct MemoryProcessSelectionPanel: View {",
            to: "private struct MemoryAppSelectionTableHeader: View {"
        )

        XCTAssertTrue(releasePanel.contains("title: L10n.text(\"已用 / 总量\", \"Used / Total\")"))
        XCTAssertTrue(releasePanel.contains("snapshot.measurements.physicalBytes.value.map"))
        XCTAssertTrue(releasePanel.contains("title: L10n.text(\"压力趋势估算\", \"Pressure estimate\")"))
        XCTAssertTrue(releasePanel.contains("100 − 系统压力余量"))
        XCTAssertTrue(source.contains("snapshot: store.menuBarDisplayMemorySnapshot ?? snapshot"))
        XCTAssertTrue(releasePanel.contains("processSnapshot.cleanupPlan"))
        XCTAssertTrue(selectionPanel.contains("进程快照"))
        XCTAssertFalse(releasePanel.contains("MemoryInlineMetric(title: L10n.text(\"可用\", \"Available\")"))
        XCTAssertTrue(releasePanel.contains("if !isObserving"))
        XCTAssertTrue(releasePanel.contains("L10n.text(\"退出高占用应用\", \"Quit High-Usage Apps\")"))
        XCTAssertTrue(releasePanel.contains(": cleanupPlan.title"))
        XCTAssertTrue(releasePanel.contains("\"xmark.circle.fill\""))
        XCTAssertTrue(releasePanel.contains("\"checkmark.circle\""))
        XCTAssertFalse(releasePanel.contains("Text(cleanupPlan.title"))
        XCTAssertTrue(selectionPanel.contains("if !apps.isEmpty"))
        XCTAssertTrue(selectionPanel.contains("if selectedAppCount > 0"))
        XCTAssertFalse(selectionPanel.contains("visibleApps.isEmpty || !store.canRequestMemoryQuitActions"))
        XCTAssertFalse(selectionPanel.contains("退出所选应用"))
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

        XCTAssertTrue(
            uninstaller.contains("AppUninstallListPresentation.make(")
        )
        XCTAssertTrue(
            uninstaller.contains(
                "if !store.hasScannedInstalledApps"
            )
        )
        XCTAssertTrue(uninstaller.contains("AppUninstallScanLandingView(store: store)"))
        XCTAssertFalse(uninstaller.contains("Task.sleep(for: .milliseconds(300))"))
        XCTAssertFalse(uninstaller.contains(".task {"))
        XCTAssertTrue(landing.contains("FeatureLandingPageShell("))
        XCTAssertTrue(landing.contains("L10n.text(\"读取应用列表\", \"Read App List\")"))
        XCTAssertTrue(landing.contains("actionSystemImage: \"square.grid.2x2.fill\""))
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

        XCTAssertTrue(energy.contains("if store.hasScannedEnergyImpact"))
        XCTAssertTrue(energy.contains("EnergyImpactScanLandingView(store: store)"))
        XCTAssertTrue(energy.contains("EnergyImpactScanProgressPanel(phase:"))
        XCTAssertTrue(energy.contains("store.scanEnergyImpact()"))
        XCTAssertFalse(energy.contains("autoRefreshEnergyImpact"))
        XCTAssertFalse(energy.contains("Task.sleep(for: .milliseconds(250))"))
        XCTAssertFalse(energy.contains("Task.sleep(for: .seconds(6))"))
        XCTAssertTrue(landing.contains("FeatureLandingPageShell("))
        XCTAssertTrue(landing.contains("L10n.text(\"开始测量\", \"Start Measurement\")"))
        XCTAssertTrue(landing.contains("EnergyImpactScanPipelineView(phase: visiblePhase, showsStageDetails: true)"))
        XCTAssertTrue(landing.contains("Text(step.overview)"))
        XCTAssertTrue(landing.contains("actionSystemImage: \"bolt.fill\""))
        XCTAssertTrue(landing.contains("action: { store.scanEnergyImpact() }"))
        XCTAssertTrue(landing.contains("store.isEnergyImpactPageScanActive"))
        XCTAssertTrue(landing.contains("EnergyImpactScanPhase.allCases.enumerated()"))
        XCTAssertTrue(landing.contains("geometry.size.width * progressFraction"))
        XCTAssertTrue(landing.contains("accessibilityValue(\"\\(Int(progressFraction * 100))%\")"))
        XCTAssertTrue(landing.contains("HStack(spacing: AppDesignTokens.Spacing.small)"))
        XCTAssertTrue(landing.contains(".frame(width: 14)"))
        XCTAssertTrue(landing.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertFalse(landing.contains("return HStack(spacing: AppDesignTokens.Spacing.micro)"))
        XCTAssertTrue(energy.contains("AppButton("))
        XCTAssertTrue(energy.contains("systemImage: \"arrow.clockwise\""))
        XCTAssertTrue(source.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(source.contains("private var compactLayout: some View"))
        XCTAssertTrue(source.contains("private func compactValueColumn(title: String, value: String)"))
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
            "Sources/StorageCleanerMac/Views/ComputerHealth/HealthScoreHero.swift",
            "Sources/StorageCleanerMac/Views/ComputerHealth/HealthFactorGrid.swift",
            "Sources/StorageCleanerMac/Views/ComputerHealth/HealthActionList.swift"
        ]
            .map { try sourceText(at: $0) }
            .joined(separator: "\n")
        let largeFiles = try sourceText(
            at: "Sources/StorageCleanerMac/Views/LargeFilesView.swift"
        )
        let benchmark = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/MacBenchmarkDashboardView.swift"
        )
        let benchmarkSummary = try sourceSegment(
            benchmark,
            from: "private var scoreSummary: some View",
            to: "@ViewBuilder\n    private var primaryAction"
        )
        let benchmarkAction = try sourceSegment(
            benchmark,
            from: "@ViewBuilder\n    private var primaryAction",
            to: "private var runPreparationSection"
        )

        XCTAssertTrue(health.contains("if let progress {"))
        XCTAssertTrue(health.contains("min(1, max(0, progress / 100))"))
        XCTAssertTrue(health.contains("Circle()"))
        XCTAssertTrue(health.contains("RoundedRectangle(cornerRadius: 14)"))
        XCTAssertFalse(health.contains("scoreRing"))
        XCTAssertFalse(health.contains("miniRing"))
        XCTAssertFalse(health.contains("factorCard"))

        XCTAssertTrue(largeFiles.contains("FeatureRuntimePage("))
        XCTAssertFalse(largeFiles.contains("Circle()"))
        XCTAssertFalse(largeFiles.contains("miniRing"))

        XCTAssertTrue(benchmark.contains("scoreSummary"))
        XCTAssertFalse(benchmark.contains("scoreRing"))
        XCTAssertFalse(benchmark.contains("Circle()"))
        XCTAssertFalse(benchmarkSummary.contains(".system(size:"))
        XCTAssertEqual(
            occurrences(of: ".fixedSize(horizontal: true, vertical: false)", in: benchmarkAction),
            2
        )
    }

    func testCompactAndGeekPanelsAvoidCardWithinShapeDecoration() throws {
        let compact = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarStatusView.swift"
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
        XCTAssertTrue(compact.contains("PanelHeader("))
        XCTAssertEqual(panelChrome.components(separatedBy: "kind: .toolbar").count - 1, 1)
        XCTAssertTrue(panelChrome.contains("Menu {"))
        XCTAssertTrue(panelChrome.contains("AppSymbols.Action.more"))
        XCTAssertFalse(panelChrome.contains("kind: .glass"))

        XCTAssertFalse(geek.contains("private struct GeekMetricTile"))
        XCTAssertTrue(geek.contains("GeekCombinedCard(height: GeekPanelLayout.overviewProcessorCardHeight)"))
        XCTAssertFalse(geek.contains("GeekBatteryLevelBar("))
        XCTAssertFalse(geek.contains(".environment(\\.geekCombinedCardUsesDivider, true)"))
        XCTAssertTrue(combinedCardDivider.contains("static let defaultValue = false"))
        XCTAssertTrue(combinedCard.contains(".frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)"))
        XCTAssertEqual(occurrences(of: ".geekCardSurface(", in: combinedCard), 1,
                       "Each fixed-height overview module keeps one golden card surface")
        XCTAssertTrue(geek.contains("reading.displayRPM"))
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
        XCTAssertTrue(advancedComponents.contains("AppSelectionButton("))
        XCTAssertTrue(advancedComponents.contains("showsTitle: false"))
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
        XCTAssertTrue(geekCharts.contains(".miniWindowTooltipChrome()"))
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
        XCTAssertTrue(panel.contains("let hidesChrome = presentation.usesGeekLayout"))
        XCTAssertTrue(panel.contains("showsHeader: !hidesChrome"))
        XCTAssertTrue(panel.contains("showsNavigation: !hidesChrome"))
        XCTAssertTrue(panel.contains("liveHeader"))
        XCTAssertTrue(panel.contains("navigation: {\n                moduleRail"))
        XCTAssertTrue(panel.contains("geekDetailPage"))
        XCTAssertTrue(components.contains("PanelHeader("))
        XCTAssertTrue(components.contains("var moduleRail: some View"))
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

        XCTAssertTrue(source.contains("GeekCombinedCard(height: 150)"))
        XCTAssertTrue(source.contains("GeekVPNDisclosure"))
        XCTAssertTrue(source.contains("networkTopologySnapshot?.activeVPNTunnel"))
        XCTAssertTrue(source.contains("geekPhysicalNetwork"))
        XCTAssertTrue(source.contains("geekPhysicalIPv4Address"))
        XCTAssertTrue(source.contains("GeekVPNHoverDetail"))
        XCTAssertTrue(source.contains("tunnel.tunnelIPv4"))
        XCTAssertTrue(source.contains("tunnel.tunnelIPv6"))
        XCTAssertTrue(source.contains("tunnel.scopedDNSServers"))
        XCTAssertTrue(source.contains("additionalScopedDNSCount"))
        XCTAssertTrue(source.contains("另有 \\(additionalScopedDNSCount) 条 DNS"))
        XCTAssertTrue(source.contains("VPNControlCapabilityResolver"))
        XCTAssertTrue(source.contains("下载峰值"))
        XCTAssertTrue(source.contains("上传峰值"))
        XCTAssertTrue(source.contains("会话累计"))
        XCTAssertTrue(source.contains("Public IP"))
        XCTAssertTrue(source.contains("本地 IP 地址"))
        XCTAssertTrue(source.contains("sessionUploadedBytes"))
        XCTAssertTrue(source.contains("sessionDownloadedBytes"))
        XCTAssertTrue(source.contains("GeekNetworkProcessRow"))
        XCTAssertTrue(source.contains("networkProcessSnapshot"))
        XCTAssertTrue(source.contains("networkProcessSamplingState"))
        XCTAssertTrue(source.contains("正在采样…"))
        XCTAssertTrue(source.contains("正在准备采样…"))
        XCTAssertTrue(source.contains("暂时无法读取进程流量"))
        XCTAssertFalse(source.contains("等待采样"))
        XCTAssertFalse(source.contains("逐进程实时流量未采样"))
        XCTAssertTrue(source.contains("GeekCombinedCard(height: geekNetworkProcessCardHeight)"))
        XCTAssertTrue(source.contains("ProgressView()"))
        XCTAssertTrue(source.contains("if showsIPv6"))
        XCTAssertTrue(source.contains(".truncationMode(.middle)"))
        XCTAssertTrue(source.contains(".help(value)"))
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
        let source = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/MacSustainedBenchmarkSection.swift"
        )

        XCTAssertTrue(source.contains("固定 10 分钟"))
        XCTAssertTrue(source.contains("不计分、不上传"))
        XCTAssertTrue(source.contains("AppStateIconRing("))
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
        let header = try sourceSegment(source, from: "var header: some View", to: "var moduleRail: some View")
        let tile = try sourceSegment(source, from: "struct AdvancedMetricTile: View", to: "struct AdvancedCompactGauge")
        let gauge = try sourceSegment(source, from: "struct AdvancedCompactGauge", to: "struct AdvancedPlainMetric")
        let circularGauge = try sourceSegment(chrome, from: "struct PanelCircularGauge", to: "struct PanelHeader")
        let geekMetricCell = try sourceSegment(
            geekComponents,
            from: "struct GeekMetricCell: View",
            to: "struct GeekSection"
        )

        XCTAssertFalse(source.contains(".glassPanel(cornerRadius: 12"))
        XCTAssertTrue(controls.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertTrue(controls.contains(".buttonStyle(.bordered)"))
        XCTAssertFalse(source.contains("struct AdvancedRailButton"))
        XCTAssertFalse(source.contains("struct AdvancedRingMetric"))
        XCTAssertFalse(source.contains("AdvancedIconButtonStyle"))
        XCTAssertFalse(source.contains("AdvancedOpenButtonStyle"))
        XCTAssertFalse(source.contains("Circle()"))
        XCTAssertTrue(header.contains("PanelHeader("))
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

        for metric in [tile, gauge] {
            XCTAssertTrue(metric.contains("PanelCircularGauge("))
            XCTAssertFalse(metric.contains("ProgressView(value:"))
            XCTAssertFalse(metric.contains("Circle()"))
            XCTAssertFalse(metric.contains("RoundedRectangle("))
        }
        XCTAssertTrue(tile.contains("hasSuffix(\"%\")"))
        XCTAssertTrue(tile.contains("hasSuffix(\"％\")"))
        XCTAssertFalse(geek.contains("private struct GeekMetricTile"))
        XCTAssertTrue(geek.contains("GeekCombinedCard(height: GeekPanelLayout.overviewProcessorCardHeight)"))
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
        let geekEditor = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDashboardEditor.swift"
        )
        let presentation = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ModulePresentation.swift"
        )
        let source = try [
            "Sources/StorageCleanerMac/Views/AppInstallationConflictBanner.swift",
            "Sources/StorageCleanerMac/Views/ComputerHealth/ComputerHealthWorkspaceView.swift",
            "Sources/StorageCleanerMac/Views/ComputerHealth/HealthActionList.swift",
            "Sources/StorageCleanerMac/Views/ComputerHealth/HealthScoreHero.swift",
            "Sources/StorageCleanerMac/Views/ComputerHealth/MacBenchmarkDashboardView.swift",
            "Sources/StorageCleanerMac/Views/ComputerHealth/MacBenchmarkLeaderboardSection.swift",
            "Sources/StorageCleanerMac/Views/ComputerHealthView.swift",
            "Sources/StorageCleanerMac/Views/ContentView.swift",
            "Sources/StorageCleanerMac/Views/ItemDetailView.swift",
            "Sources/StorageCleanerMac/Views/ItemListView.swift",
            "Sources/StorageCleanerMac/Views/LargeFilesView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarPanelSettingsView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarStatusView.swift",
            "Sources/StorageCleanerMac/Views/OverviewView.swift",
            "Sources/StorageCleanerMac/Views/SettingsView.swift",
            "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"
        ]
            .map { try sourceText(at: $0) }
            .joined(separator: "\n")

        XCTAssertFalse(source.contains(".buttonStyle(.bordered)"))
        XCTAssertFalse(source.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertTrue(source.contains(".appButtonChrome(.secondary)"))
        XCTAssertTrue(source.contains(".appButtonChrome(.primary)"))
        XCTAssertTrue(presentation.contains("struct GlassSegmentedControl<Selection: Hashable & Identifiable>: View"))
        XCTAssertTrue(presentation.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(presentation.contains("Text(title(option)).tag(option)"))
        XCTAssertFalse(presentation.contains("ModuleTechnicalBackdrop"))
        XCTAssertTrue(geekEditor.contains(".pickerStyle(.menu)"))
        XCTAssertTrue(geekEditor.contains(".toggleStyle(.checkbox)"))
        XCTAssertFalse(geekEditor.contains("Layout actions for"))
        XCTAssertFalse(geekEditor.contains("Module Width"))
        XCTAssertFalse(geekEditor.contains("Move Up"))
        XCTAssertFalse(geekEditor.contains("Move Down"))
        XCTAssertFalse(geekEditor.contains("GeekMetricPresentation"))
        XCTAssertFalse(geekEditor.contains("刷新频率"))
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
        XCTAssertTrue(controls.contains("actionIcon(systemImage: systemImage)"))
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

        XCTAssertTrue(panel.contains("Color(nsColor: .controlBackgroundColor)"))
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
        XCTAssertTrue(popover.contains(".fill(AppDesignTokens.Palette.contentBackground)"))
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
        let compact = try sourceText(at: "Sources/StorageCleanerMac/Views/MenuBarStatusView.swift")
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
        XCTAssertTrue(compact.contains("typealias MenuBarTypography = MenuBarPanelTypography"))
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
                let source = try String(contentsOf: file, encoding: .utf8)
                for override in smallOverrides {
                    XCTAssertFalse(source.contains(override), "\(file.path): \(override)")
                }
                if source.contains(".minimumScaleFactor(") {
                    XCTAssertTrue(
                        ["ModulePresentation.swift", "SidebarView.swift"].contains(file.lastPathComponent),
                        "\(file.path): only compact immersive controls may scale a single-line label"
                    )
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
        let models = try sourceText(
            at: "Sources/StorageCleanerMac/Models/MacBenchmarkModels.swift"
        )
        let dashboard = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/MacBenchmarkDashboardView.swift"
        )
        let results = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/MacBenchmarkResultSections.swift"
        )
        let leaderboard = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/MacBenchmarkLeaderboardSection.swift"
        )

        XCTAssertTrue(models.contains("static let allCases: [BenchmarkProfile] = [.standard]"))
        XCTAssertFalse(dashboard.contains("Picker("))
        XCTAssertFalse(dashboard.contains("selectedProfile"))
        XCTAssertTrue(dashboard.contains("return completedRawOnlyDetail"))
        XCTAssertFalse(dashboard.contains("No verified Standard v6 baseline is available"))
        XCTAssertTrue(dashboard.contains("1920 × 1080  OFFSCREEN METAL"))
        XCTAssertTrue(dashboard.contains("1.887B TRIANGLES / SAMPLE"))
        XCTAssertFalse(results.contains("title: L10n.text(\"模式\", \"Profile\")"))
        XCTAssertFalse(leaderboard.contains("L10n.text(\"模式\", \"Profile\")"))
        XCTAssertFalse(leaderboard.contains("text: MacBenchmarkPresentation.profileTitle(profile)"))
    }

    func testBenchmarkWrapsMetadataAndAvoidsNestedContentCards() throws {
        let dashboard = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/MacBenchmarkDashboardView.swift"
        )
        let results = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/MacBenchmarkResultSections.swift"
        )
        let leaderboard = try sourceText(
            at: "Sources/StorageCleanerMac/Views/ComputerHealth/MacBenchmarkLeaderboardSection.swift"
        )
        let hero = try sourceSegment(
            dashboard,
            from: "private var benchmarkHero: some View",
            to: "private var scoreSummary: some View"
        )

        XCTAssertTrue(hero.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertGreaterThanOrEqual(occurrences(of: "ViewThatFits(in: .horizontal)", in: hero), 2)
        XCTAssertTrue(hero.contains("benchmarkMetadata("))
        XCTAssertTrue(hero.contains("fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(hero.contains("MetadataPill("))
        XCTAssertFalse(hero.contains(".glassPanel("))

        XCTAssertFalse(results.contains(".glassPanel("))
        XCTAssertFalse(results.contains("RoundedRectangle("))
        XCTAssertFalse(leaderboard.contains(".glassPanel("))
        XCTAssertFalse(leaderboard.contains("RoundedRectangle("))
        XCTAssertTrue(leaderboard.contains("AppButton("))
        XCTAssertTrue(leaderboard.contains("entry.physicalMemoryBytes"))
        XCTAssertTrue(leaderboard.contains("entry.systemDiskCapacityBytes"))
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
            "Sources/StorageCleanerMac/Views/MenuBarStatusView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarCombinedPanel.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarDiskPanel.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarMemoryPanel.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarNetworkPanel.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarPowerPanel.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarProcessorPanel.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarSensorsPanel.swift",
        ].map { try sourceText(at: $0) }

        XCTAssertTrue(header.contains("struct AppPageHeader"))
        XCTAssertTrue(pageHeader.contains("AppSymbolIcon("))
        XCTAssertTrue(moduleHeader.contains("AppPageHeader("))
        XCTAssertFalse(moduleHeader.contains("AppSymbolIcon("))
        XCTAssertTrue(pageHeader.contains("role: .pageFeature"))
        XCTAssertTrue(pageHeader.contains("var isHero = false"))
        XCTAssertTrue(pageHeader.contains("isHero && moduleTheme.isImmersive"))
        XCTAssertTrue(pageHeader.contains(": AppTypography.pageTitle)"))
        XCTAssertFalse(pageHeader.contains("var iconSize:"))
        XCTAssertFalse(pageHeader.contains("var glyphSize:"))
        XCTAssertFalse(pageHeader.contains("let tint: Color"))
        XCTAssertTrue(iconStyle.contains("enum AppIconRole"))
        XCTAssertTrue(iconStyle.contains("enum AppIconSizing"))
        XCTAssertTrue(iconStyle.contains("struct AppSymbolIcon: View"))
        XCTAssertTrue(iconStyle.contains("role == .pageFeature || role == .emptyState"))
        XCTAssertTrue(iconStyle.contains(".font(.system(size: role.glyphSize, weight: role.weight))"))
        XCTAssertTrue(iconStyle.contains(".frame(width: role.frameSize, height: role.frameSize)"))
        XCTAssertTrue(iconStyle.contains("static let iconHitRegion: CGFloat = 32"))
        XCTAssertTrue(iconStyle.contains("case .toolbar, .inline, .sidebar: 16"))
        XCTAssertTrue(iconStyle.contains("case .panelNavigation, .panelHeader, .panelMode: 18"))
        XCTAssertTrue(iconStyle.contains("case .toolbar, .panelNavigation:"))
        XCTAssertTrue(iconStyle.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(iconStyle.contains("var isDecorative = false"))
        XCTAssertTrue(iconStyle.contains(".accessibilityHidden(isDecorative)"))
        XCTAssertTrue(overview.contains("isDecorative: true"))
        XCTAssertTrue(utilities.contains("isDecorative: true"))
        XCTAssertTrue(sidebar.contains("Image(systemName: filter.systemImage)"))
        XCTAssertTrue(sidebar.contains(".frame(width: 18, height: 18)"))
        XCTAssertTrue(sidebar.contains("filter.moduleTheme.sidebarIconColor"))
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
            XCTAssertFalse(panelSource.contains("Image(systemName: \""))
            XCTAssertFalse(panelSource.contains("systemImage: \""))
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
        XCTAssertTrue(sidebar.contains("Image(systemName: filter.systemImage)"))
        XCTAssertTrue(sidebar.contains("filter.moduleTheme.sidebarIconColor"))
        XCTAssertTrue(components.contains("AppSymbolIcon("))
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
        let settingsHeader = try sourceSegment(
            settings,
            from: "private func settingsDetailHeader(for category: SettingsCategory) -> some View {",
            to: "@ViewBuilder\n    private func settingsSections(for category: SettingsCategory) -> some View {"
        )

        XCTAssertTrue(tokens.contains("static let pagePadding: CGFloat = 24"))
        XCTAssertFalse(pageHeader.contains(".padding(.horizontal"))
        XCTAssertTrue(pageHeader.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(pageHeader.contains(".padding(.vertical, AppDesignTokens.Spacing.medium)"))
        XCTAssertFalse(pageHeader.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(pageHeader.contains(".fixedSize(horizontal: false, vertical: true)"))
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
        XCTAssertTrue(health.contains("AppPageHeader("))
        XCTAssertTrue(overview.contains("DashboardPage("))
        XCTAssertTrue(smartScan.contains(".padding(.top, AppDesignTokens.Layout.pagePadding)"))
        XCTAssertTrue(settingsHeader.contains("Text(category.title)"))
        XCTAssertTrue(settingsHeader.contains("Text(category.subtitle)"))
        XCTAssertTrue(settingsHeader.contains("AppTypography.pageTitle"))
        XCTAssertTrue(settingsHeader.contains("AppTypography.pageSubtitle"))
        XCTAssertFalse(settingsHeader.contains("Image(systemName:"))
        XCTAssertFalse(settingsHeader.contains(".lineLimit("))
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
        let navigationRow = try sourceSegment(
            sidebar,
            from: "private struct SidebarNavigationRow: View {",
            to: "private struct SidebarFooter: View {"
        )
        let footer = try sourceSegment(
            sidebar,
            from: "private struct SidebarFooter: View {",
            to: "#if DEBUG"
        )

        XCTAssertTrue(navigationRow.contains(".lineLimit(2)"))
        XCTAssertTrue(navigationRow.contains(".frame(minHeight: AppDesignTokens.Layout.sidebarRowHeight)"))
        XCTAssertFalse(navigationRow.contains(".frame(height: AppDesignTokens.Layout.sidebarRowHeight)"))
        XCTAssertTrue(footer.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(footer.contains(".frame(height: AppDesignTokens.Layout.sidebarRowHeight)"))
    }

    func testPanelHeaderAdaptsStatusBeforeTextCanCollide() throws {
        let chrome = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift"
        )
        let panelHeader = try XCTUnwrap(
            chrome.components(separatedBy: "struct PanelHeader: View {").dropFirst().first
        )

        XCTAssertTrue(panelHeader.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(panelHeader.contains("headerRow(showsStatusTitle: true)"))
        XCTAssertTrue(panelHeader.contains("headerRow(showsStatusTitle: false)"))
        XCTAssertTrue(panelHeader.contains("identityBlock"))
        XCTAssertTrue(panelHeader.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(panelHeader.contains(".lineLimit(1)"))
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
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSegment(_ source: String, from start: String, to end: String) throws -> String {
        let tail = try XCTUnwrap(source.components(separatedBy: start).dropFirst().first)
        return try XCTUnwrap(tail.components(separatedBy: end).first)
    }

    private func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}
