import Foundation
import XCTest
@testable import StorageCleanerMac

final class StartupItemsDashboardContractTests: XCTestCase {
    func testManagementListKeepsAllResultsInNativeScrollWithFixedHeadersAndStatus() throws {
        let source = try dashboardSource()
        XCTAssertTrue(source.contains("ForEach(presentation.visibleItems)"))
        XCTAssertTrue(source.contains("FeatureLightfieldPage(module: .startup, phase: .result"))
        XCTAssertTrue(source.contains("LightfieldResultContent"))
        XCTAssertTrue(source.contains("LightfieldSummary(module: .startup"))
        XCTAssertFalse(source.contains("pageSize"))
        XCTAssertFalse(source.contains("startupArtwork"))
        XCTAssertTrue(source.contains("Showing \\(presentation.visibleItems.count) of"))
        XCTAssertTrue(source.contains(".lightfieldResultRowBoundary()"))
    }

    #if DEBUG || STORAGE_CLEANER_BETA
    @MainActor
    func testMainWindowSnapshotFixtureInstallsReadOnlyStartupResults() throws {
        let store = try ScanStore.makeForTests(for: self)

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
        for token in ["struct StartupItemsDashboardView: View", "let items: [StartupItemsDomain.Item]",
            "FeatureLightfieldPage(", "let coverageAction: AnyView", "LightfieldSummary(", "presentation.visibleItems",
            "StartupItemsCategory", "LightfieldTextSegments(", "[.all, .loginItems, .background]", "primaryCategories.map",
            "TextField(", ".focused($isSearchFocused)", "StartupItemRow(", "StartupItemInspectorView(", "LightfieldAppIcon(",
            "Text(compactPurpose(item.resolvedPurpose.value))", "L10n.text(\"搜索启动项\"", "Toggle(", "Menu {",
            "includeTechnicalDetails: showsTechnicalDetails", "@State private var showsTechnicalDetails = false",
            "status: status", "source: source", "sort: sort", "items: items",
            "includeAppleSystem: showsTechnicalDetails && includeAppleSystem", "presentation.summary.manageable",
            "LightfieldStatusGlyph(", "@AppStorage(\"startupItems.category.v1\")", "@AppStorage(\"startupItems.status.v1\")",
            "@AppStorage(\"startupItems.source.v1\")", "@AppStorage(\"startupItems.sort.v1\")",
            "@AppStorage(\"startupItems.includeAppleSystem.v1\")"] {
            XCTAssertTrue(source.contains(token), token)
        }
        for forbidden in ["ManagementListPage(", "GlassSegmentedControl(", "List(selection:", "startupMetric(",
            "ReviewFilter.startup.pageSubtitle", "summaryPanel(", "StartupItemsCategory.allCases", ".foregroundStyle(.white)",
            "@AppStorage(\"startupItems.showsTechnicalDetails.v1\")", "administratorNotice(", "StartupDirectManagementButton(",
            "manageableCandidate", "filter: .actionable", "StartupCoverageReport", "DisclosureGroup"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
        XCTAssertFalse(source.contains("items.filter(\\.isDirectlyManageable)"))
        XCTAssertFalse(source.contains("Text(\"\\(item.developerDisplayName) · \\(item.kind.title)"))
    }

    func testDashboardKeepsResultsVisibleAndSupportsKeyboardNavigation() throws {
        let source = try dashboardSource()
        for token in ["if presentation.visibleItems.isEmpty", "if isLoading {", "StartupItemsKeyboardActions",
            ".onReceive(NotificationCenter.default.publisher(for: .storageCleanerFocusStartupItemsSearch))",
            ".onKeyPress(.return)", ".onKeyPress(.space)", ".onKeyPress(.downArrow)", ".onKeyPress(.upArrow)",
            "activeOperationCandidateID", "isPerformingOperation", "selectedItemID = item.id", "showsSearch = true"] {
            XCTAssertTrue(source.contains(token), token)
        }
    }

    func testCoverageActionStaysInThePageHeader() throws {
        let dashboard = try dashboardSource()
        let utilities = try sourceText(at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let controls = try XCTUnwrap(dashboard.range(of: "private func resultControls("))
        let coverage = try XCTUnwrap(dashboard.range(of: "coverageAction", range: controls.upperBound..<dashboard.endIndex))
        let list = try XCTUnwrap(dashboard.range(of: "struct StartupItemRow:"))
        XCTAssertLessThan(controls.lowerBound, coverage.lowerBound)
        XCTAssertLessThan(coverage.lowerBound, list.lowerBound)
        XCTAssertTrue(dashboard.contains("let coverageAction: AnyView"))
        XCTAssertTrue(dashboard.contains("presentation.summary.manageable"))
        XCTAssertTrue(dashboard.contains("if let onUndo"), "Hidden window toolbars must not hide Undo")
        XCTAssertFalse(dashboard.contains(".background(.regularMaterial"))
        for token in ["coverageAction: AnyView(startupCoverageAction)", "L10n.text(\"完整扫描\", \"Full Scan\")",
            "L10n.text(\"系统项已读取\", \"System Items Read\")", "L10n.text(\"重试系统项\", \"Retry System Items\")",
            "onRefresh: { store.refreshStartupItems() }", "store.refreshStartupItems(includeBackgroundTaskDiagnostic: true)",
            "store.undoLastStartupOperation()"] { XCTAssertTrue(utilities.contains(token), token) }
        XCTAssertFalse(utilities.contains("onRefresh: { store.refreshStartupItems(includeBackgroundTaskDiagnostic: true) }"))
        XCTAssertFalse(utilities.contains("startupDiagnosticBanner"))
        XCTAssertFalse(utilities.contains("普通刷新保持静默"))
    }

    func testStartupItemsWaitForAnExplicitSharedLandingScan() throws {
        let utilities = try sourceText(at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let start = try XCTUnwrap(utilities.range(of: "struct StartupItemsView: View"))
        let end = try XCTUnwrap(utilities.range(of: "struct MemoryOptimizerView: View", range: start.upperBound..<utilities.endIndex))
        let startup = String(utilities[start.lowerBound..<end.lowerBound])
        for token in ["else if !store.hasScannedStartupItems", "LightfieldStartupLandingView(", "FeatureRunningTemplate(module: .startup",
            "onCancel: store.cancelStartupScan", "onStart: { store.refreshStartupItems() }"] {
            XCTAssertTrue(startup.contains(token), token)
        }
        XCTAssertFalse(startup.contains(".task {"))
        let landing = try sourceText(at: "Sources/StorageCleanerMac/Views/LightfieldStartupLandingView.swift")
        XCTAssertTrue(landing.contains("FeatureLightfieldOptions(title:"))
        XCTAssertEqual(landing.components(separatedBy: "isIncluded: true").count - 1, 3)
        XCTAssertFalse(landing.contains("selection:"), "Existing startup scan scope remains fixed")
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
        for (startMarker, endMarker) in [
            ("private var actionCandidate:", "private var actionCandidates:"),
            ("private var actionCandidates:", "private var administratorActionCandidate:"),
        ] {
            let start = try XCTUnwrap(inspector.range(of: startMarker)).lowerBound
            let end = try XCTUnwrap(inspector.range(of: endMarker, range: start..<inspector.endIndex)).lowerBound
            let candidateGate = String(inspector[start..<end])
            XCTAssertTrue(candidateGate.contains("includesAdministratorRequests: true"))
            XCTAssertFalse(candidateGate.contains("includesAdministratorRequests: false"))
        }
        XCTAssertTrue(inspector.contains("请求启用（需要管理员）"))
        XCTAssertTrue(inspector.contains("请求停用（需要管理员）"))
        // D64 keeps the helper prerequisite, authorization and restoration boundary in one notice.
        XCTAssertTrue(inspector.contains("系统控制辅助程序可能需注册与批准；执行需管理员授权；无应用内撤销，可反向操作恢复"))
        XCTAssertTrue(inspector.contains("The system control helper may need registration and system approval; administrator approval required; no in-app undo, restore with the inverse action"))
        XCTAssertTrue(inspector.contains("value: administratorActionExplanation"))
        XCTAssertTrue(inspector.contains("? administratorActionExplanation"))
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
            "shouldRefresh = true\n                    try await fanControlCoordinator.manageStartupItem(plan)"
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
