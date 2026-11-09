import AppKit
import ServiceManagement
import SwiftUI

enum SettingsCategory: String, CaseIterable, Hashable, Identifiable {
    case general
    case miniWindow
    case scanAndSafety
    case ignoreList
    case accessAndSetup
    case aiAssistant
    case systemControl
    case updates
    case about

    var id: String { rawValue }

    /// D272: each name says what the page holds. The raw values stay, so the
    /// stored selection and every way into a page keep working.
    var title: String {
        switch self {
        case .general: L10n.text("通用", "General")
        case .miniWindow: L10n.text("菜单栏", "Menu Bar")
        case .scanAndSafety: L10n.text("扫描与提醒", "Scan & Reminders")
        case .ignoreList: L10n.text("忽略列表", "Ignore List")
        case .accessAndSetup: L10n.text("权限与隐私", "Access & Privacy")
        case .aiAssistant: L10n.text("AI 助手", "AI Assistant")
        case .systemControl: L10n.text("风扇控制", "Fan Control")
        case .updates: L10n.text("应用更新", "App Updates")
        case .about: L10n.text("关于", "About")
        }
    }
}

struct SettingsView: View {
    @Environment(\.colorScheme) var colorScheme
    let cleanupArchitectureMode: CleanupArchitectureMode
    var scanStore: ScanStore?
    @State var isSettingsVisible = false
    @State var settingsMetricColorsExpanded = false
    @State var updateSourcesExpanded = false
    @State var aboutDetailsExpanded = false
    @State var showsOperations = false
    @State var supportSnapshot: RedactedSupportSnapshot?
    @State var showsSupportExport = false
    @State var miniWindowDraft = GeekDashboardDraft(GeekDashboardConfigurationStore.shared.configuration)
    @State var pendingCategory: SettingsCategory?
    @State var configurationNotice: String?

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @AppStorage(L10n.languageDefaultsKey) var languageRawValue = AppLanguage.system.rawValue
    @AppStorage(L10n.appearanceDefaultsKey) var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(AppCanvasTheme.defaultsKey) var canvasThemeRawValue = AppCanvasTheme.defaultTheme.rawValue
    // D135: iStat's theme pair replaces the mini-window appearance, chart
    // color and dropdown surface preferences (their keys stay unread).
    @AppStorage(IStatMenuThemePreferences.darkThemeKey) var menuThemeDarkID = IStatMenuTheme.defaultID
    @AppStorage(IStatMenuThemePreferences.lightThemeKey) var menuThemeLightID = IStatMenuTheme.defaultID
    @AppStorage(IStatMenuThemePreferences.vibrancyKey) var menuThemeVibrancy = true
    @AppStorage(MaintenanceReminderService.defaultsKey) var maintenanceCadenceRawValue = MaintenanceReminderService.defaultCadence.rawValue
    @State var pendingCloseWindow: NSWindow?
    @AppStorage("settings.selected-category.v1") var selectedCategory = SettingsCategory.general
    @AppStorage(SettingsMenuBarPage.defaultsKey) var menuBarPage = SettingsMenuBarPage.icon
    @AppStorage(PublicNetworkConsent.addressKey) var allowsPublicAddress = PublicNetworkConsent.defaultAllowsAddress
    @AppStorage(PublicNetworkConsent.countryKey) var allowsCountryLookup = false
    @State var scanHistorySummary = ScanHistorySummary(entries: [])
    @StateObject var ignoreListModel = SettingsIgnoreListModel(store: .shared)
    @State var ignoreSelection = Set<String>()
    @State var ignoreApplicationSelection = Set<String>()
    @State var showsIgnoreApplicationPicker = false
    @ObservedObject var helperSettingsNavigation = SystemHelperSettingsNavigation.shared
    @State var permissionNotice: SettingsNotice?
    @State var fullDiskAccessState = FullDiskAccessState.unknown
    @State var notificationsAuthorized = false
    @State var launchAtLoginStatus: SMAppService.Status?
    @State var launchAtLoginReadTask: Task<Void, Never>?
    @State var isChangingLaunchAtLogin = false
    @State var launchAtLoginNotice: SettingsNotice?
    @State var accessRefreshGate = SettingsAccessRefreshGate()
    var isCheckingAccess: Bool { accessRefreshGate.isChecking }
    @State var isRequestingNotifications = false
    @State var isPreparingHelper = false
    /// D229: the file-operation helper's row in Permissions › System Helper.
    @ObservedObject var fileOperationHelper = FileOperationHelperEnabler.shared
    @State var confirmsFileOperationHelper = false
    @State var diagnosticNotice: SettingsNotice?
    @State var updateSourceConfiguration = AppUpdateSourcePreferences.configuration()
    @State var applicationUpdatePreferences = ApplicationUpdatePreferences.snapshot()
    @State var runtimeInfo = AppRuntimeLocationService.current()
    @State var confirmsMaximumFanMode = false
    @State var fanHardwareReadings = SMCFanSpeedService.HardwareReadings.empty
    @State var isLoadingFanCapability = false
    @StateObject var exclusionPanelCoordinator = AppOpenPanelCoordinator()
    @StateObject var fanControl: FanControlCoordinator
    @StateObject var agentInterface: AgentInterface

    init(
        cleanupArchitectureMode: CleanupArchitectureMode = .v2Full,
        scanStore: ScanStore? = nil,
        fanControl: @autoclosure @escaping @MainActor () -> FanControlCoordinator = FanControlCoordinator.shared,
        agentInterface: @autoclosure @escaping @MainActor () -> AgentInterface = AgentInterface.shared
    ) {
        _fanControl = StateObject(wrappedValue: fanControl())
        _agentInterface = StateObject(wrappedValue: agentInterface())
        self.cleanupArchitectureMode = cleanupArchitectureMode
        self.scanStore = scanStore
    }

    var settingsTheme: ModuleTheme {
        ModuleThemeCatalog.theme(for: .settings)
    }

    private var settingsSelection: Binding<SettingsCategory?> {
        Binding {
            selectedCategory
        } set: { category in
            if let category {
                if selectedCategory == .miniWindow, category != .miniWindow, miniWindowDraft.isDirty {
                    pendingCategory = category
                } else { selectedCategory = category }
            }
        }
    }

    var body: some View {
        // D154 batch 3I: CleanMyMac's tabs across the top replace the D3/D53
        // sidebar (the user's decision, 2026-10-21); one backdrop fills the
        // title bar, the tabs and the pane.
        VStack(spacing: 0) {
            settingsTabBar
            FeatureLightfieldHairline()
            settingsPane(for: selectedCategory)
        }
        .background {
            GeometryReader { proxy in
                let topInset = proxy.safeAreaInsets.top
                let canvas = CGSize(width: proxy.size.width, height: max(1, proxy.size.height - topInset))
                // D274: a result page's quieter halo, in the landing's place. The column
                // of actions sits on it, and at full strength measured about 3:1 there.
                FeatureLightfieldBackdrop(module: .overview, phase: .result,
                    geometry: FeatureLightfieldGeometry(size: canvas, phase: .landing),
                    canvasTopInset: topInset)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(
            minWidth: 560,
            idealWidth: 1180,
            maxWidth: .infinity,
            // Leave the native 28 pt title bar within the 390/760 pt window.
            minHeight: 362,
            idealHeight: 732,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.moduleTheme, settingsTheme)
        .foregroundStyle(settingsTheme.primaryText, settingsTheme.secondaryText, settingsTheme.tertiaryText)
        .tint(settingsTheme.actionFill)
        .overlay(alignment: .topLeading) {
            SettingsWindowConfigurator(title: selectedCategory.title)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        .background {
            WindowCloseGuard { window in
                guard miniWindowDraft.isDirty else { return true }
                pendingCloseWindow = window
                return false
            }.frame(width: 0, height: 0)
        }
        .onAppear {
            isSettingsVisible = true
            refresh(category: selectedCategory)
        }
        .onChange(of: selectedCategory) { _, category in
            refresh(category: category)
        }
        .onDisappear { isSettingsVisible = false; launchAtLoginReadTask?.cancel() }
        .modifier(SettingsActivationRefresh(isVisible: isSettingsVisible, category: selectedCategory) {
            refresh(category: selectedCategory)
        })
        .confirmationDialog(L10n.text("保留小窗布局更改？", "Keep panel layout changes?"), isPresented: Binding(
            get: { pendingCategory != nil || pendingCloseWindow != nil }, set: { if !$0 { pendingCategory = nil; pendingCloseWindow = nil } }
        ), titleVisibility: .visible) {
            Button(L10n.text("应用", "Apply")) {
                do {
                    try GeekDashboardConfigurationStore.shared.applyLive(miniWindowDraft.value)
                    miniWindowDraft.didApply(GeekDashboardConfigurationStore.shared.configuration)
                    if let pendingCategory { selectedCategory = pendingCategory }
                    pendingCategory = nil
                    let window = pendingCloseWindow
                    pendingCloseWindow = nil
                    window?.close()
                } catch { configurationNotice = error.localizedDescription }
            }
            Button(L10n.text("放弃更改", "Discard Changes"), role: .destructive) {
                miniWindowDraft.cancel()
                if let pendingCategory { selectedCategory = pendingCategory }
                pendingCategory = nil
                let window = pendingCloseWindow
                pendingCloseWindow = nil
                window?.close()
            }
            Button(L10n.text("继续编辑", "Keep Editing"), role: .cancel) { pendingCategory = nil; pendingCloseWindow = nil }
        }
        .alert(L10n.text("设置未应用", "Settings Not Applied"), isPresented: Binding(
            get: { configurationNotice != nil }, set: { if !$0 { configurationNotice = nil } }
        )) { Button(L10n.text("好", "OK")) { configurationNotice = nil } }
        message: { Text(configurationNotice ?? "") }

        .confirmationDialog(
            L10n.text("启用最大转速？", "Enable Maximum RPM?"),
            isPresented: $confirmsMaximumFanMode,
            titleVisibility: .visible
        ) {
            Button(GeekFanControlMode.maximum.title) {
                Task { await fanControl.selectMode(.maximum) }
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text(
                "噪音和功耗增加；退出或异常时恢复系统控制。",
                "Noise and power use increase; quitting or a failure restores system control."
            ))
        }
    }

    private var settingsTabBar: some View {
        SettingsTabBar(selected: selectedCategory) { category in
            settingsSelection.wrappedValue = category
        }
    }

    private func settingsPane(for category: SettingsCategory) -> some View {
        SettingsLightfieldPane(category: category, drawsBackdrop: false) {
            settingsForm(for: category)
                .controlSize(.regular)
                .buttonStyle(FeatureLightfieldRowButtonStyle())
        }
    }

    @ViewBuilder
    private func settingsForm(for category: SettingsCategory) -> some View {
        if category == .ignoreList {
            ignoreListSettings
        } else if category == .miniWindow {
            miniWindowSettings
        } else if category == .accessAndSetup {
            ScrollViewReader { proxy in
                SettingsColumn {
                    permissionSetupSection
                    networkPrivacySection
                }
                .onAppear { scrollToRequestedHelper(using: proxy) }
                .onChange(of: helperSettingsNavigation.requestID) { scrollToRequestedHelper(using: proxy) }
            }
        } else {
            SettingsColumn { settingsSections(for: category) }
        }
    }

    private func scrollToRequestedHelper(using proxy: ScrollViewProxy) {
        guard helperSettingsNavigation.requestID != nil else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(SystemHelperSettingsNavigation.anchor, anchor: .top)
            helperSettingsNavigation.requestID = nil
        }
    }

    @ViewBuilder
    private func settingsSections(for category: SettingsCategory) -> some View {
        switch category {
        case .ignoreList, .miniWindow: EmptyView()
        case .general:
            interfaceSection
            launchBehaviorSection
        case .scanAndSafety:
            maintenanceReminderSection
            AppLifecycleReminderSettingsSection()
            if let scanStore {
                LightfieldSettingsSection {
                    SettingsLinkRow(title: L10n.text("查看逐项回执与恢复", "View receipts and recovery")) {
                        showsOperations = true
                    }
                    .sheet(isPresented: $showsOperations) { ReversibleOperationsView(store: scanStore) }
                } header: { Text(L10n.text("可恢复操作", "Recoverable Operations")) }
            }
        case .accessAndSetup:
            permissionSetupSection
            networkPrivacySection
        case .aiAssistant:
            AgentSettingsPage(interface: agentInterface)
        case .systemControl:
            fanControlSection
        case .updates:
            updateAutomationSection
            updateSourceSection
        case .about:
            aboutSection
        }
    }

    private func refresh(category: SettingsCategory) {
        switch category {
        case .ignoreList: ignoreListModel.refresh()
        case .miniWindow: break
        case .general:
            refreshLaunchAtLoginStatus()
        case .accessAndSetup:
            refreshAccessStatus()
        case .aiAssistant:
            agentInterface.refreshForSettings()
        case .systemControl:
            fanControl.refreshStatus()
            isLoadingFanCapability = true
            Task {
                let hardwareReadings = await Task.detached(priority: .userInitiated) {
                    SMCFanSpeedService.currentHardwareReadings()
                }.value
                await fanControl.refreshConnection()
                fanHardwareReadings = hardwareReadings
                isLoadingFanCapability = false
            }
        case .scanAndSafety:
            scanHistorySummary = ScanHistoryService.summary()
        case .updates:
            updateSourceConfiguration = AppUpdateSourcePreferences.configuration()
            applicationUpdatePreferences = ApplicationUpdatePreferences.snapshot()
        case .about:
            runtimeInfo = AppRuntimeLocationService.current()
            fanControl.refreshStatus()
        }
    }

}

struct UpdateSourceOptionRow: View {
    let method: AppUpdateMethod
    @Binding var isEnabled: Bool

    var body: some View {
        LightfieldSettingsRow {
            SettingsToggleRow(title: method.title, isOn: $isEnabled)
        }
        .accessibilityValue(isEnabled ? L10n.text("已启用", "Enabled") : L10n.text("已停用", "Disabled"))
        .accessibilityHint(method.detail)
    }
}

enum SettingsNoticeSeverity: CaseIterable, Equatable, Sendable {
    case information
    case success
    case warning
    case failure
    case locked

    var showsSymbol: Bool {
        switch self {
        case .information, .success: false
        case .warning, .failure, .locked: true
        }
    }
}

struct SettingsNotice {
    let text: String
    let systemImage: String
    let tint: Color
    let severity: SettingsNoticeSeverity

    // Severity remains stable when artwork names or feedback colors change.
    var showsWarningSymbol: Bool { severity.showsSymbol }

    static func launchAtLoginResult(requiresApproval: Bool, shouldLaunch: Bool) -> SettingsNotice {
        SettingsNotice(
            text: requiresApproval
                ? L10n.text("登录项已提交，请在系统设置中批准。", "The login item was submitted; approve it in System Settings.")
                : shouldLaunch
                    ? L10n.text("已开启登录后自动启动。", "Launch at login is enabled.")
                    : L10n.text("已关闭登录后自动启动。", "Launch at login is disabled."),
            systemImage: requiresApproval ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
            tint: requiresApproval ? AppDesignTokens.Palette.warning : AppDesignTokens.Palette.success,
            severity: requiresApproval ? .warning : .success
        )
    }

    static func launchAtLoginFailure(_ errorDescription: String) -> SettingsNotice {
        SettingsNotice(
            text: L10n.text("无法更改登录项：\(errorDescription)", "Could not change the login item: \(errorDescription)"),
            systemImage: "exclamationmark.triangle.fill",
            tint: AppDesignTokens.Palette.warning,
            severity: .failure
        )
    }

    static func openSettingsResult(
        didOpen: Bool, openedText: String, failureText: String, openedSymbol: String
    ) -> SettingsNotice {
        SettingsNotice(
            text: didOpen ? openedText : failureText,
            systemImage: didOpen ? openedSymbol : "exclamationmark.triangle.fill",
            tint: didOpen ? AppDesignTokens.Palette.information : AppDesignTokens.Palette.warning,
            severity: didOpen ? .information : .failure
        )
    }
}

struct SettingsNoticeView: View {
    let notice: SettingsNotice

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if notice.showsWarningSymbol {
                AppSymbolIcon(systemImage: notice.systemImage, role: .notice,
                              tint: notice.tint, isDecorative: true)
            }

            Text(notice.text)
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .id(notice.text)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsWindowConfigurator: NSViewRepresentable {
    let title: String

    /// SwiftUI's Settings window style has no `.resizable` and no
    /// `.miniaturizable`, and SwiftUI takes them away again whenever the
    /// content's size limits update, even with
    /// `.windowResizability(.contentMinSize)`; that also kept the zoom button
    /// off. The panes lay out for any size from the minimum set in
    /// `configure`, so the window gets resizing back (D96), and like the main
    /// window it keeps all three window buttons (D97).
    @MainActor
    final class Coordinator {
        private static let standardControls: NSWindow.StyleMask = [.resizable, .miniaturizable]
        private weak var window: NSWindow?
        private var observation: NSKeyValueObservation?
        /// Written on the main actor only; read once more by `deinit`.
        nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
        nonisolated(unsafe) private var resizeObserver: NSObjectProtocol?

        deinit {
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        }

        func keepStandardControls(_ window: NSWindow) {
            Self.restoreStandardControls(window)
            guard self.window !== window else { return }
            self.window = window
            SettingsWindowConfigurator.applyPreferredSize(window)
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let window = self?.window else { return }
                    SettingsWindowPlacement.rememberSize(window.frame.size)
                }
            }
            observation = window.observe(\.styleMask, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    guard let window = self?.window else { return }
                    Self.restoreStandardControls(window)
                }
            }
            // D243 (review P2-15): a display that closes takes no window with it.
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let window = self?.window else { return }
                    SettingsWindowConfigurator.restoreVisibleFrameIfNeeded(window)
                }
            }
        }

        private static func restoreStandardControls(_ window: NSWindow) {
            guard !window.styleMask.isSuperset(of: standardControls) else { return }
            window.styleMask.formUnion(standardControls)
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = true
            window.standardWindowButton(.zoomButton)?.isEnabled = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        return PassthroughWindowConfigurationView { window in
            configure(window)
            coordinator.keepStandardControls(window)
        }
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? PassthroughWindowConfigurationView else { return }
        let coordinator = context.coordinator
        view.updateConfiguration { window in
            configure(window)
            coordinator.keepStandardControls(window)
        }
    }

    private func configure(_ window: NSWindow) {
        if window.title != title {
            window.title = title
        }
        // The page header already shows the title; like the main window, keep
        // it for the Window menu and accessibility but not in the title bar.
        window.titleVisibility = .hidden
        window.toolbar?.allowsUserCustomization = false
        window.toolbar?.autosavesConfiguration = false
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = true
        window.standardWindowButton(.zoomButton)?.isEnabled = true

        let minimumSize = SettingsWindowPlacement.minimumSize
        if window.minSize != minimumSize {
            window.minSize = minimumSize
        }

        let maximumSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if window.maxSize != maximumSize {
            window.maxSize = maximumSize
        }

        Self.restoreVisibleFrameIfNeeded(window)
    }

    static func restoreVisibleFrameIfNeeded(_ window: NSWindow) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard !visibleFrames.isEmpty,
              SettingsWindowPlacement.requiresRestoration(
                window.frame,
                within: visibleFrames
              ) else { return }

        let intersectingFrame = visibleFrames.max { lhs, rhs in
            lhs.intersection(window.frame).area < rhs.intersection(window.frame).area
        }
        let targetFrame: NSRect
        if let intersectingFrame,
           intersectingFrame.intersection(window.frame).area > 0 {
            targetFrame = intersectingFrame
        } else {
            // D243＋旧值“window.screen?.visibleFrame ?? …”: the window's last
            // screen may be the display that just went away.
            targetFrame = NSScreen.main?.visibleFrame ?? visibleFrames[0]
        }
        let restoredFrame = SettingsWindowPlacement.clamped(window.frame, to: targetFrame)

        guard restoredFrame != window.frame else { return }
        window.setFrame(restoredFrame, display: true)
    }

    /// D274: once per window, for a screen the size does not fit and a window opened
    /// again in the same run. Only the scene's own window: a test's host around this
    /// view keeps the size it was given.
    static func applyPreferredSize(_ window: NSWindow) {
        guard !window.frameAutosaveName.isEmpty,
              let frame = SettingsWindowPlacement.openingFrame(
                window.frame,
                size: SettingsWindowPlacement.preferredSize(),
                within: NSScreen.screens.map(\.visibleFrame)
              ),
              frame != window.frame else { return }
        window.setFrame(frame, display: true)
    }
}

enum SettingsWindowPlacement {
    /// D274: the content's ideal size (`SettingsView.body`) with the title bar.
    static let openingSize = NSSize(width: 1180, height: 760)
    static let minimumSize = NSSize(width: 560, height: 390)
    static let rememberedSizeKey = "settings.window-size.v1"

    /// The `Settings` scene's `.defaultSize`. AppKit's saved frame cannot keep the size:
    /// this window is not resizable yet when its frame is restored, so only the top-left
    /// comes back (traced 11-02), and every launch opened at SwiftUI's own 900 × 450.
    static func preferredSize() -> NSSize {
        preferredSize(remembered: UserDefaults.standard.string(forKey: rememberedSizeKey))
    }

    static func preferredSize(remembered: String?) -> NSSize {
        guard let remembered else { return openingSize }
        let size = NSSizeFromString(remembered)
        return size.width >= minimumSize.width && size.height >= minimumSize.height ? size : openingSize
    }

    /// From the end of a drag only: being clamped to a smaller display is not a choice.
    static func rememberSize(_ size: NSSize) {
        UserDefaults.standard.set(NSStringFromSize(size), forKey: rememberedSizeKey)
    }

    /// Keeps the top-left, as dragging the corner would, then stays on the screen
    /// holding most of the window.
    static func openingFrame(_ frame: NSRect, size: NSSize, within visibleFrames: [NSRect]) -> NSRect? {
        guard let visibleFrame = visibleFrames.max(by: {
            $0.intersection(frame).area < $1.intersection(frame).area
        }) else { return nil }
        let sized = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        return clamped(sized, to: visibleFrame)
    }

    static func requiresRestoration(
        _ frame: NSRect,
        within visibleFrames: [NSRect]
    ) -> Bool {
        guard frame.width > 0, frame.height > 0, !visibleFrames.isEmpty else { return false }

        let requiredWidth = min(frame.width, 120)
        let requiredHeight = min(frame.height, 48)
        return !visibleFrames.contains { visibleFrame in
            let intersection = visibleFrame.intersection(frame)
            return intersection.width >= requiredWidth
                && intersection.height >= requiredHeight
        }
    }

    static func clamped(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }

        var result = frame
        result.size.width = min(result.width, visibleFrame.width)
        result.size.height = min(result.height, visibleFrame.height)
        result.origin.x = min(
            max(result.minX, visibleFrame.minX),
            visibleFrame.maxX - result.width
        )
        result.origin.y = min(
            max(result.minY, visibleFrame.minY),
            visibleFrame.maxY - result.height
        )
        return result
    }
}

/// A history record's health evidence is text, never a decorative status icon.
struct ScanHistoryHealthStatusLine: View {
    let entry: ScanHistoryEntry

    var body: some View {
        if let status = entry.smartScanHealthStatus {
            Text(L10n.text("文件扫描 · \(status.title)", "File Scan · \(status.title)"))
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.readableSecondary)
                .lineLimit(1)
                .accessibilityIdentifier("scan-history.health-status")
        }
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }
}

#if DEBUG || STORAGE_CLEANER_BETA
/// Stored category names for the debug Settings capture.
enum SettingsCaptureCategories {
    static var all: [String] { SettingsCategory.allCases.map(\.rawValue) }
}
#endif
