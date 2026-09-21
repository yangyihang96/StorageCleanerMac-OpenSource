import Foundation
import XCTest
@testable import StorageCleanerMac

final class StartupItemsDashboardContractTests: XCTestCase {
    func testManagementListKeepsAllResultsInNativeScrollWithFixedHeadersAndStatus() throws {
        let source = try dashboardSource()
        XCTAssertTrue(source.contains("ForEach(presentation.visibleItems)"))
        XCTAssertFalse(source.contains("pageSize"))
        XCTAssertFalse(source.contains("startupArtwork"))
        for title in ["名称", "来源", "状态", "操作"] {
            XCTAssertTrue(source.contains("Text(L10n.text(\"\(title)\""))
        }
        XCTAssertTrue(source.contains("Showing \\(presentation.visibleItems.count) of"))
    }

    #if DEBUG || STORAGE_CLEANER_BETA
    @MainActor
    func testMainWindowSnapshotFixtureInstallsReadOnlyStartupResults() {
        let store = ScanStore()

        MainWindowSnapshotPipeline.installStartupItemsFixture(in: store)

        XCTAssertTrue(store.hasScannedStartupItems)
        XCTAssertFalse(store.isLoadingStartupItems)
        XCTAssertEqual(store.startupDomainItems.count, 5)
        XCTAssertTrue(store.startupDomainItems.contains {
            $0.state.management == .managedByOrganization
        })
        XCTAssertTrue(store.startupDomainItems.contains {
            $0.state.management == .systemProtected
        })
        XCTAssertNil(store.pendingStartupOperationPlan)
    }
    #endif

    func testDashboardIsValueDrivenManagementConsole() throws {
        let source = try dashboardSource()

        XCTAssertTrue(source.contains("struct StartupItemsDashboardView: View"))
        XCTAssertTrue(source.contains("let items: [StartupItemsDomain.Item]"))
        XCTAssertTrue(source.contains("ManagementListPage("))
        XCTAssertTrue(source.contains("ReviewFilter.startup.pageSubtitle"))
        XCTAssertTrue(source.contains("let coverageAction: AnyView"))
        XCTAssertFalse(source.contains("summaryPanel("))
        XCTAssertTrue(source.contains("startupMetric("))
        XCTAssertTrue(source.contains("overview(presentation)"))
        XCTAssertTrue(source.contains("scanStatus"))
        XCTAssertTrue(source.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(source.contains("presentation.visibleItems"))
        XCTAssertTrue(source.contains("StartupItemsCategory"))
        XCTAssertTrue(source.contains("GlassSegmentedControl("))
        XCTAssertTrue(source.contains("[.all, .loginItems, .background]"))
        XCTAssertTrue(source.contains("options: primaryCategories"))
        XCTAssertTrue(source.contains("presentation.count(for: category)"))
        XCTAssertFalse(source.contains("StartupItemsCategory.allCases"))
        XCTAssertTrue(source.contains("TaskSearchField("))
        XCTAssertTrue(source.contains("focus: $isSearchFocused"))
        XCTAssertFalse(source.contains(".foregroundStyle(.white)"))
        XCTAssertTrue(source.contains("List(selection: $selectedItemID)"))
        XCTAssertTrue(source.contains("StartupItemRow("))
        XCTAssertTrue(source.contains("StartupItemInspectorView("))
        XCTAssertTrue(source.contains("CachedAppIconView("))
        XCTAssertTrue(source.contains("Text(compactPurpose(item.resolvedPurpose.value))"))
        XCTAssertTrue(source.contains("L10n.text(\"搜索启动项\""))
        XCTAssertTrue(source.contains("Toggle("))
        XCTAssertTrue(source.contains("AppIconButton("))
        XCTAssertTrue(source.contains("Menu {"))
        XCTAssertTrue(source.contains("showsTechnicalDetails"))
        XCTAssertTrue(source.contains("includeTechnicalDetails: showsTechnicalDetails"))
        XCTAssertTrue(source.contains("@State private var showsTechnicalDetails = false"))
        XCTAssertTrue(source.contains("status: status"))
        XCTAssertTrue(source.contains("source: source"))
        XCTAssertTrue(source.contains("includeAppleSystem: showsTechnicalDetails && includeAppleSystem"))
        XCTAssertTrue(source.contains("sort: sort"))
        XCTAssertTrue(source.contains("@AppStorage(\"startupItems.category.v1\")"))
        XCTAssertTrue(source.contains("@AppStorage(\"startupItems.status.v1\")"))
        XCTAssertTrue(source.contains("@AppStorage(\"startupItems.source.v1\")"))
        XCTAssertTrue(source.contains("@AppStorage(\"startupItems.sort.v1\")"))
        XCTAssertFalse(source.contains("@AppStorage(\"startupItems.showsTechnicalDetails.v1\")"))
        XCTAssertTrue(source.contains("@AppStorage(\"startupItems.includeAppleSystem.v1\")"))
        XCTAssertTrue(source.contains("L10n.text(\"筛选与显示\", \"Filter and Display\")"))
        XCTAssertFalse(source.contains("items.filter(\\.isDirectlyManageable)"))
        XCTAssertTrue(source.contains("items: items"))
        XCTAssertTrue(source.contains("presentation.summary.manageable"))
        XCTAssertTrue(source.contains("item.fallbackSystemImage"))
        XCTAssertFalse(source.contains("Button(L10n.text(\"查看详情\", \"Details\")"))
        XCTAssertFalse(source.contains("administratorNotice("))
        XCTAssertFalse(source.contains("StartupDirectManagementButton("))
        XCTAssertFalse(source.contains("manageableCandidate"))
        XCTAssertFalse(source.contains("filter: .actionable"))
        XCTAssertFalse(source.contains("StartupCoverageReport"))
        XCTAssertFalse(source.contains("DisclosureGroup"))
        XCTAssertFalse(source.contains("Text(\"\\(item.developerDisplayName) · \\(item.kind.title)"))
    }

    func testDashboardKeepsResultsVisibleAndSupportsKeyboardNavigation() throws {
        let source = try dashboardSource()

        XCTAssertTrue(source.contains("if presentation.visibleItems.isEmpty, !isLoading"))
        XCTAssertTrue(source.contains("if isLoading {"))
        XCTAssertTrue(source.contains("StartupItemsKeyboardActions"))
        XCTAssertTrue(source.contains(".onReceive(NotificationCenter.default.publisher(for: .storageCleanerFocusStartupItemsSearch))"))
        XCTAssertTrue(source.contains(".onKeyPress(.return)"))
        XCTAssertTrue(source.contains(".onKeyPress(.space)"))
        XCTAssertTrue(source.contains("activeOperationCandidateID"))
        XCTAssertTrue(source.contains("isPerformingOperation"))
    }

    func testCoverageActionStaysInThePageHeader() throws {
        let dashboard = try dashboardSource()
        let utilities = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"
        )

        let header = try XCTUnwrap(dashboard.range(of: "ManagementListPage("))
        let coverage = try XCTUnwrap(
            dashboard.range(of: "coverageAction", range: header.upperBound..<dashboard.endIndex)
        )
        let controls = try XCTUnwrap(dashboard.range(of: "} controls: {"))
        XCTAssertLessThan(header.lowerBound, coverage.lowerBound)
        XCTAssertLessThan(coverage.lowerBound, controls.lowerBound)
        XCTAssertTrue(dashboard.contains("let coverageAction: AnyView"))
        XCTAssertTrue(dashboard.contains("overview(presentation)"))
        XCTAssertTrue(dashboard.contains("value: \"\\(presentation.summary.manageable)\""))
        XCTAssertFalse(dashboard.contains(".background(.regularMaterial"))

        XCTAssertTrue(utilities.contains("coverageAction: AnyView(startupCoverageAction)"))
        XCTAssertTrue(utilities.contains("L10n.text(\"完整扫描\", \"Full Scan\")"))
        XCTAssertTrue(utilities.contains("L10n.text(\"系统项已读取\", \"System Items Read\")"))
        XCTAssertTrue(utilities.contains("L10n.text(\"重试系统项\", \"Retry System Items\")"))
        XCTAssertTrue(utilities.contains("onRefresh: { store.refreshStartupItems() }"))
        XCTAssertTrue(utilities.contains("store.refreshStartupItems(includeBackgroundTaskDiagnostic: true)"))
        XCTAssertFalse(utilities.contains(
            "onRefresh: { store.refreshStartupItems(includeBackgroundTaskDiagnostic: true) }"
        ))
        XCTAssertFalse(utilities.contains("普通刷新保持静默"))
        XCTAssertFalse(utilities.contains("startupDiagnosticBanner"))
    }

    func testStartupItemsWaitForAnExplicitSharedLandingScan() throws {
        let utilities = try sourceText(
            at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"
        )
        let start = try XCTUnwrap(utilities.range(of: "struct StartupItemsView: View"))
        let end = try XCTUnwrap(
            utilities.range(
                of: "struct MemoryOptimizerView: View",
                range: start.upperBound..<utilities.endIndex
            )
        )
        let startup = String(utilities[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(startup.contains(
            "if !store.hasScannedStartupItems && !store.isLoadingStartupItems"
        ))
        XCTAssertTrue(startup.contains("HeroScanPage("))
        XCTAssertTrue(startup.contains("L10n.text(\"读取启动项\", \"Read Startup Items\")"))
        XCTAssertTrue(startup.contains("action: { store.refreshStartupItems() }"))
        XCTAssertFalse(startup.contains(".task {"))
    }

    func testDashboardDoesNotPerformScanningOrSystemMutation() throws {
        let source = try dashboardSource()

        XCTAssertFalse(source.contains("StartupItemService"))
        XCTAssertFalse(source.contains("StartupScanCoordinator("))
        XCTAssertFalse(source.contains("LaunchdPlistParser("))
        XCTAssertFalse(source.contains("Process("))
        XCTAssertFalse(source.contains("launchctl"))
        XCTAssertFalse(source.contains("sfltool"))
        XCTAssertFalse(source.contains("SMAppService"))
        XCTAssertFalse(source.contains("FileManager.default"))
        XCTAssertFalse(source.contains("removeItem("))
    }

    func testDashboardOnlyOffersCapabilityGatedCallbacks() throws {
        let source = try dashboardSource()

        XCTAssertTrue(source.contains("candidate.actionCapability.canEnableDirectly"))
        XCTAssertTrue(source.contains("candidate.actionCapability.canDisableDirectly"))
        XCTAssertTrue(source.contains("candidate.actionCapability.canStopCurrentSession"))
        XCTAssertTrue(source.contains("candidate.state.management == .directlyManageable"))
        XCTAssertTrue(source.contains("onOpenSystemSettings != nil && item.isSystemSettingsOnly"))
        XCTAssertTrue(source.contains("onEnable != nil"))
        XCTAssertTrue(source.contains("onDisable != nil"))
        XCTAssertTrue(source.contains("onStop"))
        XCTAssertTrue(source.contains("L10n.text(\"在系统设置中管理\", \"Manage in System Settings\")"))
        XCTAssertTrue(source.contains("L10n.text(\"需要管理员权限\", \"Administrator Permission Required\")"))
        XCTAssertTrue(source.contains("停用时，已载入或正在运行的进程会立即停止"))
        XCTAssertFalse(source.contains("不会停止当前会话中的进程"))
        XCTAssertTrue(source.contains("return candidates.count == 1 ? candidates[0] : nil"))
        XCTAssertTrue(source.contains("case .unknown:"))
        XCTAssertFalse(source.contains("Button(role: shouldEnable ? nil : .destructive)"))
        XCTAssertFalse(source.contains("清理残留"))
        XCTAssertFalse(source.contains("removeItem("))
    }

    func testAttentionProjectionCannotManufactureMutationControls() throws {
        let source = try dashboardSource()

        XCTAssertTrue(source.contains("presentation.allowsStartupMutationActions ? onEnable : nil"))
        XCTAssertTrue(source.contains("presentation.allowsStartupMutationActions ? onDisable : nil"))
        XCTAssertTrue(source.contains("presentation.allowsStartupMutationActions ? onStop : nil"))
        let keyboardStart = try XCTUnwrap(source.range(of: ".onKeyPress(.space)"))
        let keyboard = source[keyboardStart.lowerBound...].prefix(250)
        XCTAssertTrue(keyboard.contains("inspectedItem = item"))
        XCTAssertFalse(keyboard.contains("onEnable?"))
        XCTAssertFalse(keyboard.contains("onDisable?"))
    }

    func testInspectorOnlyRendersScannedEvidenceAndDelegatesActions() throws {
        let source = try inspectorSource()

        XCTAssertTrue(source.contains("struct StartupItemInspectorView: View"))
        XCTAssertTrue(source.contains("StartupInspectorIdentityPresentation.make"))
        XCTAssertTrue(source.contains("onEnable"))
        XCTAssertTrue(source.contains("onDisable"))
        XCTAssertTrue(source.contains("onStop"))
        XCTAssertTrue(source.contains("onReveal"))
        XCTAssertTrue(source.contains("onOpenSystemSettings"))
        XCTAssertTrue(source.contains("诊断信息"))
        XCTAssertFalse(source.contains("Process("))
        XCTAssertFalse(source.contains("FileManager.default"))
        XCTAssertFalse(source.contains("removeItem("))
        XCTAssertFalse(source.contains("resetbtm"))
    }

    func testInspectorMakesSingleVerifiedAdministratorRequestReachable() throws {
        let item = administratorItem(id: "administrator")
        let callback: (StartupItemsDomain.Candidate) -> Void = { _ in }

        XCTAssertNil(startupActionCandidate(
            in: item,
            onEnable: callback,
            onDisable: callback
        ))
        XCTAssertEqual(
            startupActionCandidate(
                in: item,
                onEnable: callback,
                onDisable: callback,
                includesAdministratorRequests: true
            )?.id,
            "administrator"
        )

        let inspector = try inspectorSource()
        XCTAssertTrue(inspector.contains("includesAdministratorRequests: true"))
        XCTAssertTrue(inspector.contains("请求启用（需要管理员）"))
        XCTAssertTrue(inspector.contains("请求停用（需要管理员）"))
        XCTAssertTrue(inspector.contains("当前安装可能需要先注册并批准系统控制辅助程序"))
        XCTAssertTrue(inspector.contains("管理员操作目前没有应用内撤销"))
        XCTAssertTrue(inspector.contains("Button(L10n.text(\"系统设置\", \"System Settings\")"))
    }

    func testAdministratorRequestFailsClosedWithoutCapabilityOrSingleTarget() {
        let callback: (StartupItemsDomain.Candidate) -> Void = { _ in }
        var unavailable = administratorItem(id: "unavailable")
        unavailable.components[0].actionCapability.canDisableDirectly = false

        XCTAssertNil(startupActionCandidate(
            in: unavailable,
            onEnable: callback,
            onDisable: callback,
            includesAdministratorRequests: true
        ))

        var ambiguous = administratorItem(id: "first")
        ambiguous.components.append(administratorItem(id: "second").components[0])
        XCTAssertNil(startupActionCandidate(
            in: ambiguous,
            onEnable: callback,
            onDisable: callback,
            includesAdministratorRequests: true
        ))
        XCTAssertEqual(
            startupActionCandidates(
                in: ambiguous,
                onEnable: callback,
                onDisable: callback,
                includesAdministratorRequests: true
            ).count,
            2
        )
    }

    func testSuccessfulStartupScanReconnectsTheVerifiedPersistedUndoEntry() throws {
        let source = try scanStoreSource()
        let start = try XCTUnwrap(source.range(of: "func refreshStartupItems("))
        let end = try XCTUnwrap(
            source.range(of: "func cancelStartupScan()", range: start.upperBound..<source.endIndex)
        )
        let refreshSource = String(source[start.lowerBound..<end.lowerBound])

        let lookup = try XCTUnwrap(
            refreshSource.range(of: "manager.latestRecoverableUndo(candidates: result.candidates)")
        )
        let recordAssignment = try XCTUnwrap(
            refreshSource.range(of: "lastStartupUndoRecordID = recovery?.recordID")
        )
        let candidateAssignment = try XCTUnwrap(
            refreshSource.range(of: "lastStartupUndoCandidate = recovery?.candidate")
        )
        XCTAssertLessThan(lookup.lowerBound, recordAssignment.lowerBound)
        XCTAssertLessThan(lookup.lowerBound, candidateAssignment.lowerBound)
    }

    func testAdministratorFailureKeepsPostMutationRescanEnabled() throws {
        let source = try scanStoreSource()
        let start = try XCTUnwrap(source.range(of: "func confirmStartupOperation()"))
        let end = try XCTUnwrap(
            source.range(of: "func cancelStartupOperation()", range: start.upperBound..<source.endIndex)
        )
        let operationSource = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(operationSource.contains(
            "shouldRefresh = true\n                    try await FanControlCoordinator.shared.manageStartupItem(plan)"
        ))
        XCTAssertEqual(
            operationSource.components(
                separatedBy: "shouldRefresh = shouldRefresh || recoveryRecordID != nil"
            ).count - 1,
            2
        )
        XCTAssertTrue(operationSource.contains(
            "if shouldRefresh {\n                    refreshStartupItems(priority: .utility)"
        ))
    }

    private func dashboardSource() throws -> String {
        try sourceText(at: "Sources/StorageCleanerMac/Features/StartupItems/Views/StartupItemsDashboardView.swift")
    }

    private func inspectorSource() throws -> String {
        try sourceText(at: "Sources/StorageCleanerMac/Features/StartupItems/Views/StartupItemInspectorView.swift")
    }

    private func scanStoreSource() throws -> String {
        try sourceText(at: "Sources/StorageCleanerMac/Stores/ScanStore.swift")
    }

    private func administratorItem(id: String) -> StartupItemsDomain.Item {
        var capability = StartupItemsDomain.ActionCapability.readOnly
        capability.canEnableDirectly = true
        capability.canDisableDirectly = true
        capability.canOpenSystemSettings = true
        capability.requiresAdministrator = true
        capability.isReadOnly = false
        let state = StartupItemsDomain.State(
            registration: .discoveredFromFile,
            authorization: .unknown,
            enablement: .enabled,
            load: .unknown,
            process: .unknown,
            management: .requiresAdministrator
        )
        let candidate = StartupItemsDomain.Candidate(
            id: id,
            source: .launchdPlist,
            kind: .globalLaunchAgent,
            scope: .allUsers,
            name: id,
            label: "com.example.\(id)",
            plistURL: URL(fileURLWithPath: "/Library/LaunchAgents/com.example.\(id).plist"),
            executableURL: URL(fileURLWithPath: "/Applications/Example.app/Contents/MacOS/Example"),
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            configuration: nil,
            state: state,
            attribution: nil,
            actionCapability: capability,
            diagnosticEvidence: []
        )
        return StartupItemsDomain.Item(
            id: id,
            kind: candidate.kind,
            scope: candidate.scope,
            name: candidate.name,
            components: [candidate],
            state: state,
            attribution: nil,
            actionCapability: capability,
            warnings: []
        )
    }

    private func sourceText(at path: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
    }
}
