import Foundation
import XCTest
@testable import StorageCleanerMac

final class MenuBarPanelInteractionTests: XCTestCase {
    @MainActor
    func testMoreMenuDensitySelectorCommitsSelectionImmediately() {
        let state = MenuBarPanelSettingsState(initialDensity: .simple)

        state.selectDensity(.geek)

        XCTAssertEqual(state.selectedDensity, .geek)
    }

    @MainActor
    func testGeekEditorPresentationSurvivesDensitySynchronization() {
        let state = MenuBarPanelSettingsState(initialDensity: .simple)

        state.presentGeekEditor()
        state.synchronizeDensity(.complex)

        XCTAssertEqual(state.selectedDensity, .complex)
        XCTAssertTrue(state.isGeekEditorPresented)
        state.dismissGeekEditor()
        XCTAssertFalse(state.isGeekEditorPresented)
    }

    func testPanelUsesCompactMoreMenuAndOneGeekEditorPopover() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarPanelSettingsView.swift",
            root: projectRoot
        )
        let compactSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarStatusView.swift",
            root: projectRoot
        )
        let advancedSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift",
            root: projectRoot
        )
        let rootSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarStatusPanelRoot.swift",
            root: projectRoot
        )
        let controllerSource = try source(
            "Sources/StorageCleanerMac/Support/MenuBarStatusController.swift",
            root: projectRoot
        )
        let chromeSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift",
            root: projectRoot
        )

        XCTAssertFalse(settingsSource.contains("struct PanelSettingsView"))
        XCTAssertFalse(settingsSource.contains("GeekMetricPresentation"))
        XCTAssertFalse(settingsSource.contains("Menu {"))
        XCTAssertFalse(settingsSource.contains(".popover("))
        XCTAssertFalse(settingsSource.contains("AppIconButton("))

        for source in [compactSource, advancedSource] {
            XCTAssertFalse(source.contains("panelSettingsState.togglePresentation()"))
            XCTAssertFalse(source.contains(".popover("))
        }

        XCTAssertTrue(rootSource.contains("struct PanelScene: View"))
        XCTAssertFalse(rootSource.contains("PanelSettingsView("))
        XCTAssertFalse(rootSource.contains("if panelSettingsState.isSettingsPresented"))
        XCTAssertFalse(rootSource.contains(".controlSize(.small)"))
        XCTAssertFalse(rootSource.contains("Menu {"))
        XCTAssertFalse(rootSource.contains(".popover("))
        XCTAssertFalse(rootSource.contains("DispatchQueue.main.asyncAfter"))
        XCTAssertFalse(chromeSource.contains("PanelSettingsView("))
        XCTAssertTrue(chromeSource.contains(".popover(isPresented: geekEditorBinding"))
        XCTAssertEqual(chromeSource.components(separatedBy: ".popover(isPresented:").count - 1, 1)
        XCTAssertTrue(chromeSource.contains("Menu {"))
        XCTAssertFalse(chromeSource.contains("if state.selectedDensity == .geek {"))
        XCTAssertTrue(chromeSource.contains("state.presentGeekEditor()"))
        XCTAssertEqual(
            chromeSource.components(separatedBy: "Customize Geek Overview…").count - 1,
            1
        )
        XCTAssertTrue(chromeSource.contains("GeekDashboardEditor(state: state)"))
        XCTAssertTrue(chromeSource.contains("启动时恢复小窗"))
        XCTAssertFalse(chromeSource.contains("小窗设置"))
        XCTAssertFalse(chromeSource.contains("isSettingsPresented"))
        XCTAssertFalse(controllerSource.contains("MenuBarPanelSettingsView("))
        XCTAssertFalse(controllerSource.contains("panelModeChangeState"))
        XCTAssertFalse(controllerSource.contains("pendingMode"))
        XCTAssertFalse(controllerSource.contains("settingsPanelHeight"))
        XCTAssertFalse(controllerSource.contains("panelSize(for:"))
        XCTAssertTrue(controllerSource.contains("private let geometryStore = PanelGeometryStore()"))
    }

    func testControllerUsesShortLivedPanelSessionAndLeftMouseUpOnly() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controllerSource = try source(
            "Sources/StorageCleanerMac/Support/MenuBarStatusController.swift",
            root: projectRoot
        )

        XCTAssertTrue(controllerSource.contains("private var panelSession: MenuBarPanelSession?"))
        XCTAssertTrue(controllerSource.contains("button.action = #selector(togglePanel(_:))"))
        XCTAssertTrue(controllerSource.contains("button.sendAction(on: [.leftMouseUp])"))
        XCTAssertTrue(controllerSource.contains("PanelScene("))
        XCTAssertTrue(controllerSource.contains("MenuBarPanelSession("))
        XCTAssertTrue(controllerSource.contains("session.show("))
        XCTAssertTrue(controllerSource.contains("session.panel.isOnActiveSpace"))
        XCTAssertFalse(controllerSource.contains(".leftMouseDown"))
        XCTAssertFalse(controllerSource.contains(".rightMouse"))
        XCTAssertFalse(controllerSource.contains(".otherMouse"))
        XCTAssertFalse(controllerSource.contains("NSPopover"))
        XCTAssertFalse(controllerSource.contains("NSPopoverDelegate"))
        XCTAssertFalse(controllerSource.contains("togglePopover"))
        XCTAssertFalse(controllerSource.contains("presentPopover"))
        XCTAssertFalse(controllerSource.contains("dismissPopover"))
        XCTAssertFalse(controllerSource.contains("popoverDidClose"))
        XCTAssertFalse(controllerSource.contains("NSHostingController"))
    }

    func testControllerAnchorsPanelToCurrentStatusButtonAndUsesIdentitySafeClose() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controllerSource = try source(
            "Sources/StorageCleanerMac/Support/MenuBarStatusController.swift",
            root: projectRoot
        )
        let presentSource = try methodSource(
            named: "private func presentPanel(from sender: NSStatusBarButton)",
            before: "func dismissPanel()",
            in: controllerSource
        )

        XCTAssertTrue(presentSource.contains("sender.convert(sender.bounds, to: nil)"))
        XCTAssertTrue(presentSource.contains("sender.window?.convertToScreen(rectInWindow)"))
        XCTAssertTrue(presentSource.contains("ScreenContextResolver.resolve("))
        XCTAssertTrue(presentSource.contains("statusItemScreen: sender.window?.screen"))
        XCTAssertTrue(presentSource.contains("anchorRect: resolvedAnchor"))
        XCTAssertTrue(presentSource.contains("pointerLocation: mouseLocation"))
        XCTAssertTrue(presentSource.contains("self.panelSession?.panel === capturedPanel"))
        XCTAssertTrue(presentSource.contains("[weak self, weak panel]"))
        XCTAssertFalse(presentSource.contains("NSScreen.main"))

        let assignSession = try XCTUnwrap(presentSource.range(of: "panelSession = session")?.lowerBound)
        let showSession = try XCTUnwrap(presentSource.range(
            of: "session.show(",
            range: assignSession..<presentSource.endIndex
        )?.lowerBound)
        let highlightSession = try XCTUnwrap(
            presentSource.range(
                of: "setStatusHighlighted(true)",
                range: showSession..<presentSource.endIndex
            )?.lowerBound
        )
        XCTAssertLessThan(assignSession, showSession)
        XCTAssertLessThan(showSession, highlightSession)
        XCTAssertTrue(controllerSource.contains("statusItem?.button?.highlight(highlighted)"))
        XCTAssertTrue(controllerSource.contains("updateStatusItem(snapshot: store?.menuBarMonitorSnapshot, force: true)"))
        XCTAssertFalse(controllerSource.contains("NSApp.activate"))
        XCTAssertFalse(controllerSource.contains("orderFrontRegardless"))
        XCTAssertFalse(controllerSource.contains("NSApp.keyWindow"))
        XCTAssertFalse(controllerSource.contains("NSApp.windows"))
    }

    func testDensitySelectionPersistsImmediatelyAndRestoresItsFrameWithoutDismissal() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controllerSource = try source(
            "Sources/StorageCleanerMac/Support/MenuBarStatusController.swift",
            root: projectRoot
        )
        let rootSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarStatusPanelRoot.swift",
            root: projectRoot
        )
        let selectDensitySource = try methodSource(
            named: "func selectPanelDensity(_ density: PanelDensity)",
            before: "private func updateStatusItem",
            in: controllerSource
        )

        XCTAssertTrue(selectDensitySource.contains(
            "UserDefaults.standard.set(density.rawValue, forKey: PanelDensity.defaultsKey)"
        ))
        XCTAssertTrue(selectDensitySource.contains("panelSession?.selectDensity(density)"))
        XCTAssertFalse(selectDensitySource.contains("teardown()"))
        XCTAssertFalse(selectDensitySource.contains("DispatchQueue"))
        XCTAssertFalse(controllerSource.contains("func applyPanelSize"))
        XCTAssertFalse(rootSource.contains("MenuBarStatusController.shared.applyPanelSize"))
        XCTAssertFalse(rootSource.contains("panelSettingsState.synchronizeDensity(panelDensity)"))
        XCTAssertTrue(rootSource.contains("presentation: .geek"))
    }

    func testSessionOwnsHostingControllerCompatibilityAndClearsItOnTeardown() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controllerSource = try source(
            "Sources/StorageCleanerMac/Support/MenuBarStatusController.swift",
            root: projectRoot
        )
        let sessionSource = try source(
            "Sources/StorageCleanerMac/Support/MenuBarPanelSession.swift",
            root: projectRoot
        )

        XCTAssertTrue(sessionSource.contains("let hostingController = NSHostingController(rootView: rootView)"))
        XCTAssertTrue(sessionSource.contains("if #available(macOS 26.0, *)"))
        XCTAssertTrue(sessionSource.contains(
            "hostingController.view.prefersCompactControlSizeMetrics = true"
        ))
        XCTAssertTrue(sessionSource.contains("panel.contentViewController = hostingController"))
        XCTAssertTrue(sessionSource.contains("panel.contentViewController = nil"))
        XCTAssertTrue(sessionSource.contains("hostingController = nil"))
        XCTAssertFalse(controllerSource.contains("prefersCompactControlSizeMetrics"))
    }

    func testAdvancedPanelSectionsAreIndependentViews() {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let folder = projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarAdvanced")
        let expectedFiles = [
            "MenuBarAdvancedComponents.swift",
            "MenuBarCombinedPanel.swift",
            "MenuBarProcessorPanel.swift",
            "MenuBarMemoryPanel.swift",
            "MenuBarDiskPanel.swift",
            "MenuBarNetworkPanel.swift",
            "MenuBarSensorsPanel.swift",
            "MenuBarPowerPanel.swift"
        ]

        for name in expectedFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path),
                name
            )
        }
    }

    func testPanelsExposePauseRefreshAndAccessibleMoreMenuWithoutQuitAction() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarPanelSettingsView.swift",
            root: projectRoot
        )
        let compactSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarStatusView.swift",
            root: projectRoot
        )
        let componentsSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift",
            root: projectRoot
        )
        let chromeSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift",
            root: projectRoot
        )

        let overviewSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift",
            root: projectRoot
        )

        XCTAssertFalse(settingsSource.contains("struct PanelSettingsView"))
        XCTAssertFalse(settingsSource.contains("Form {"))
        XCTAssertFalse(settingsSource.contains("AppIconButton("))
        XCTAssertFalse(settingsSource.contains("关闭面板设置"))
        XCTAssertFalse(settingsSource.contains("xmark"))
        XCTAssertTrue(chromeSource.contains(
            ".accessibilityLabel(L10n.text(\"正在刷新本机数据\", \"Refreshing local data\"))"
        ))
        XCTAssertTrue(compactSource.contains("PanelHeader("))
        XCTAssertTrue(componentsSource.contains("PanelHeader("))
        XCTAssertEqual(chromeSource.components(separatedBy: "AppIconButton(").count - 1, 1)
        XCTAssertEqual(chromeSource.components(separatedBy: "kind: .toolbar").count - 1, 1)
        XCTAssertEqual(chromeSource.components(separatedBy: "Menu {").count - 1, 2)
        XCTAssertEqual(chromeSource.components(separatedBy: ".popover(isPresented:").count - 1, 1)
        XCTAssertFalse(chromeSource.contains("Picker(L10n.text(\"面板模式\""))
        XCTAssertFalse(chromeSource.contains("Picker(L10n.text(\"刷新频率\""))
        XCTAssertTrue(chromeSource.contains("ForEach(MenuBarRefreshInterval.allCases)"))
        XCTAssertTrue(chromeSource.contains("Toggle(interval.pickerTitle"))
        XCTAssertTrue(chromeSource.contains("L10n.text(\"窗口置顶\", \"Keep Window on Top\")"))
        XCTAssertTrue(chromeSource.contains("L10n.text(\"启动时恢复小窗\", \"Restore Panel at Launch\")"))
        XCTAssertFalse(chromeSource.contains("if state.selectedDensity == .geek {"))
        XCTAssertTrue(chromeSource.contains("state.presentGeekEditor()"))
        XCTAssertEqual(
            chromeSource.components(separatedBy: "Customize Geek Overview…").count - 1,
            1
        )
        XCTAssertTrue(chromeSource.contains("GeekDashboardEditor(state: state)"))
        XCTAssertTrue(componentsSource.contains("var overviewContextMenu: some View"))
        XCTAssertTrue(componentsSource.contains("return actions.contextMenuContents"))
        XCTAssertFalse(componentsSource.contains("var overviewToolbar:"))
        XCTAssertTrue(overviewSource.components(separatedBy: ".contextMenu {").dropFirst().contains {
            $0.components(separatedBy: "}").first?.contains("overviewContextMenu") == true
        })
        let contextMenu = try XCTUnwrap(chromeSource.components(separatedBy: "var contextMenuContents: some View {").last?
            .components(separatedBy: "private var refreshControl:").first)
        XCTAssertTrue(contextMenu.contains("Button(action: togglePause)"))
        XCTAssertTrue(contextMenu.contains("Label(pauseTitle, systemImage: pauseSystemImage)"))
        XCTAssertTrue(contextMenu.contains("refreshControl.menuContents"))
        XCTAssertTrue(contextMenu.contains("moreMenuContents"))
        XCTAssertTrue(chromeSource.contains("var menuContents: some View"))
        XCTAssertTrue(chromeSource.contains(".disabled(isRefreshing)"))
        XCTAssertTrue(chromeSource.contains("state.setAlwaysOnTop(value)"))
        XCTAssertTrue(chromeSource.contains("state.setRestoresOnLaunch(value)"))
        XCTAssertTrue(chromeSource.contains("setStatusDisplayMode(mode)"))

        let pause = try XCTUnwrap(chromeSource.range(of: "AppSymbols.Action.resume")?.lowerBound)
        let refresh = try XCTUnwrap(
            chromeSource.range(of: "PanelRefreshControl(", options: .backwards)?.lowerBound
        )
        let more = try XCTUnwrap(
            chromeSource.range(of: "Customize Geek Overview…")?.lowerBound
        )
        XCTAssertLessThan(pause, refresh)
        XCTAssertLessThan(refresh, more)
        XCTAssertFalse(chromeSource.contains("L10n.text(\"小窗设置\", \"Panel Settings\")"))
        XCTAssertFalse(chromeSource.contains("Panel 设置"))
        XCTAssertFalse(chromeSource.contains("L10n.text(\"打开高级监控\", \"Open Advanced Monitor\")"))
        XCTAssertTrue(chromeSource.contains("L10n.text(\"打开主窗口\", \"Open Main Window\")"))
        XCTAssertTrue(chromeSource.contains("L10n.text(\"关闭小窗\", \"Close Panel\")"))
        XCTAssertTrue(chromeSource.contains(
            ".accessibilityLabel(L10n.text(\"更多小窗操作\", \"More Panel Actions\"))"
        ))
        XCTAssertFalse(chromeSource.contains("打开存储清理助手"))
        XCTAssertFalse(chromeSource.contains("退出存储清理助手"))
        XCTAssertFalse(settingsSource.contains("退出存储清理助手"))
        XCTAssertFalse(settingsSource.contains("NSApp.terminate"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectRoot
                .appendingPathComponent("Sources/StorageCleanerMac/Views/AdvancedMonitorWindowView.swift")
                .path
        ))
        XCTAssertTrue(chromeSource.contains("L10n.text(\"实时\", \"Live\")"))
    }

    func testGeekPanelOpensAtOverviewAndUsesCancelableHoverDrillDown() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = try source(
            "Sources/StorageCleanerMac/Views/MenuBarStatusPanelRoot.swift",
            root: projectRoot
        )
        let components = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPanelComponents.swift",
            root: projectRoot
        )
        let advanced = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift",
            root: projectRoot
        )
        let chrome = try source(
            "Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift",
            root: projectRoot
        )
        let tertiary = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift",
            root: projectRoot
        )

        XCTAssertTrue(root.contains("initialSection: .overview"))
        XCTAssertTrue(root.contains("presentation: .geek"))
        XCTAssertFalse(root.contains("case .complex, .geek:"))
        XCTAssertTrue(components.contains("scheduleModulePreview("))
        XCTAssertTrue(components.contains("SmallWindowAnchorReader("))
        XCTAssertFalse(components.contains("@State private var previewTask: Task<Void, Never>?"))
        XCTAssertFalse(components.contains("GeekOverviewHoverMetrics"))
        XCTAssertTrue(components.contains("guard hovering, !isSelected else { return }"))
        XCTAssertTrue(components.contains("action(destination)"))
        XCTAssertTrue(tertiary.contains("scheduleTertiaryPreview("))
        XCTAssertTrue(tertiary.contains("scheduleHoverDismissal("))
        XCTAssertTrue(tertiary.contains("activeTertiaryDetail = detail"))
        XCTAssertEqual(HoverIntentPolicy.menuBar.ordinaryCloseDelay, .milliseconds(260))
        XCTAssertTrue(advanced.contains("@State private var geekPanelDismissIntent: GeekPanelCoordinator.HoverIntent?"))
        XCTAssertTrue(advanced.contains("onHoverChange: geekAttachedPanelHoverChanged"))
        XCTAssertTrue(advanced.contains(".environment(\\.geekPanelHoverActivity, geekPanelHoverActivityChanged)"))
        XCTAssertTrue(advanced.contains("panelCoordinator.scheduleHoverDismissal("))
        XCTAssertTrue(advanced.contains("cancelGeekPanelDismissal()"))
        XCTAssertTrue(advanced.contains("geekPanelHoverActivityState.keepsPanelExpanded"))
        XCTAssertTrue(advanced.contains("activeTertiaryDetail == nil"))
        XCTAssertTrue(advanced.contains("activeInlineTertiaryRequest == nil"))
        XCTAssertTrue(advanced.contains("var hasActiveTertiary: Bool"))
        XCTAssertTrue(advanced.contains(".onChange(of: hasActiveTertiary)"))
        XCTAssertTrue(advanced.contains("private func synchronizeTertiaryPresentation()"))
        XCTAssertTrue(advanced.contains("preferredSize: activeTertiaryPreferredSize"))
        XCTAssertTrue(advanced.contains("sourceOffset: activeTertiarySourceOffset"))
        XCTAssertTrue(advanced.contains("@State var measuredTertiaryContentMeasurement: GeekTertiaryContentMeasurement?"))
        XCTAssertTrue(advanced.contains("if let request = activeInlineTertiaryRequest"))
        XCTAssertTrue(advanced.contains("measurement.requestID == request.id"))
        XCTAssertTrue(advanced.contains("height: measurement.size.height"))
        XCTAssertTrue(advanced.contains("func updateMeasuredTertiaryContentSize("))
        XCTAssertTrue(advanced.contains("let matchesCurrentDetail = requestID == nil"))
        XCTAssertTrue(advanced.contains("let matchesCurrentRequest ="))
        XCTAssertTrue(advanced.contains("matchesCurrentDetail || matchesCurrentRequest"))
        XCTAssertTrue(tertiary.contains("GeekTertiaryContentSizeKey"))
        XCTAssertTrue(tertiary.contains(".onPreferenceChange(GeekTertiaryContentSizeKey.self)"))
        XCTAssertTrue(tertiary.contains("requestID: request.id"))
        XCTAssertTrue(tertiary.contains("detail: detail, density: presentation"))
        XCTAssertTrue(advanced.contains("showsTertiary: hasActiveTertiary"))
        XCTAssertTrue(chrome.contains("let tertiaryPreferredSize: CGSize"))
        XCTAssertTrue(chrome.contains("tertiarySize: tertiarySize"))
        XCTAssertTrue(advanced.contains("tertiaryDetailColumnSurface"))
        XCTAssertTrue(tertiary.contains(".onContinuousHover"))
        XCTAssertTrue(tertiary.contains("request.hoverChanged(true)"))
        XCTAssertTrue(advanced.contains("panelCoordinator.reset()"))
        XCTAssertTrue(chrome.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(chrome.contains(".onContinuousHover"))
        XCTAssertTrue(advanced.contains("panelCoordinator.isPointerWithinHoverEnvelope"))
        XCTAssertFalse(advanced.contains("Timer("))
    }

    func testGeekPanelHoverActivityKeepsExpansionUntilShellAndEveryDetailAreInactive() {
        let first = UUID()
        let second = UUID()
        var state = GeekPanelHoverActivityState()

        XCTAssertFalse(state.keepsPanelExpanded)

        state.setShellHovered(true)
        XCTAssertTrue(state.keepsPanelExpanded)

        state.setDetailTarget(first, active: true)
        state.setShellHovered(false)
        XCTAssertTrue(state.keepsPanelExpanded)

        state.setDetailTarget(second, active: true)
        state.setDetailTarget(first, active: false)
        XCTAssertTrue(state.keepsPanelExpanded)

        state.setDetailTarget(second, active: false)
        XCTAssertFalse(state.keepsPanelExpanded)

        state.setShellHovered(true)
        state.setDetailTarget(first, active: true)
        state.reset()
        XCTAssertFalse(state.keepsPanelExpanded)
        XCTAssertTrue(state.activeDetailTargets.isEmpty)

        state.setShellRegion(.overview, hovered: true)
        state.setShellRegion(.detail, hovered: true)
        state.setShellRegion(.overview, hovered: false)
        XCTAssertTrue(state.keepsPanelExpanded)
        state.setShellRegion(.detail, hovered: false)
        XCTAssertFalse(state.keepsPanelExpanded)
    }

    private func source(_ relativePath: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func methodSource(named name: String, before nextName: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: name)?.lowerBound, "Missing method: \(name)")
        let end = try XCTUnwrap(
            source.range(of: nextName, range: start..<source.endIndex)?.lowerBound,
            "Missing following method: \(nextName)"
        )
        return String(source[start..<end])
    }
}
