import AppKit
import ServiceManagement
import SwiftUI

enum SettingsCategory: String, CaseIterable, Hashable, Identifiable {
    case general
    case miniWindow
    case scanAndSafety
    case accessAndSetup
    case systemControl
    case updates
    case about

    var id: String { rawValue }

    var columnMaxWidth: CGFloat {
        self == .miniWindow ? .infinity : AppDesignTokens.Layout.settingsPageMaxWidth
    }

    var contentLeadingInset: CGFloat {
        switch self {
        case .miniWindow: AppDesignTokens.Layout.pagePadding
        case .accessAndSetup: AppDesignTokens.Spacing.small + AppDesignTokens.Layout.sectionPadding
        // The grouped macOS Form rows in the review capture start 30 pt in.
        case .general, .scanAndSafety, .systemControl, .updates, .about: 30
        }
    }

    var title: String {
        switch self {
        case .miniWindow: L10n.text("小窗", "Mini Window")
        case .general:
            L10n.text("通用", "General")
        case .scanAndSafety:
            L10n.text("扫描与安全", "Scan & Safety")
        case .accessAndSetup:
            L10n.text("权限", "Access")
        case .systemControl:
            L10n.text("系统控制", "System Control")
        case .updates:
            L10n.text("应用更新", "App Updates")
        case .about:
            L10n.text("关于", "About")
        }
    }

    var systemImage: String {
        switch self {
        case .miniWindow: "rectangle.split.2x1"
        case .general:
            "gearshape"
        case .scanAndSafety:
            "checkmark.shield"
        case .accessAndSetup:
            "lock.shield"
        case .systemControl:
            "fan"
        case .updates:
            "arrow.triangle.2.circlepath"
        case .about:
            "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .miniWindow: AppAppearanceColors.accent
        case .general:
            AppDesignTokens.Palette.information
        case .scanAndSafety:
            AppDesignTokens.Palette.success
        case .accessAndSetup:
            AppDesignTokens.Palette.tertiary
        case .systemControl:
            AppDesignTokens.Palette.diagnostic
        case .updates:
            AppDesignTokens.Palette.warning
        case .about:
            AppDesignTokens.Palette.storage
        }
    }
}

struct SettingsView: View {
    @Environment(\.colorScheme) var colorScheme
    let cleanupArchitectureMode: CleanupArchitectureMode
    var scanStore: ScanStore?
    @State var isSettingsVisible = false
    @State var settingsInterfaceExpanded = false
    @State var settingsMetricColorsExpanded = false
    @ObservedObject var settingsConfiguration = GeekDashboardConfigurationStore.shared
    @State var showsOperations = false
    @State var supportSnapshot: RedactedSupportSnapshot?
    @State var showsSupportExport = false
    @State var miniWindowDraft = GeekDashboardDraft(GeekDashboardConfigurationStore.shared.configuration)
    @FocusState var sidebarHasFocus: Bool
    @State var hoveredCategory: SettingsCategory?
    @State var sidebarVisibility = NavigationSplitViewVisibility.all
    @State var pendingCategory: SettingsCategory?
    @State var configurationNotice: String?

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @AppStorage(L10n.languageDefaultsKey) var languageRawValue = AppLanguage.system.rawValue
    @AppStorage(L10n.appearanceDefaultsKey) var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(AppCanvasTheme.defaultsKey) var canvasThemeRawValue = AppCanvasTheme.defaultTheme.rawValue
    @AppStorage(PanelAppearancePreferences.colorThemeKey) var panelColorThemeRawValue = PanelColorTheme.graphite.rawValue
    @AppStorage(PanelAppearancePreferences.miniWindowAppearanceKey) var miniWindowAppearanceRawValue = ""
    @AppStorage(PanelAppearancePreferences.backgroundColorKey) var panelBackgroundColor = ""
    @AppStorage(PanelAppearancePreferences.chartColorKey) var panelChartColor = ""
    @AppStorage(PanelPalettePreferences.statusThemeKey) var panelStatusPresetRaw = ""
    @AppStorage(PanelPalettePreferences.surfaceThemeKey) var panelSurfacePresetRaw = ""
    @AppStorage(PanelPalettePreferences.statusCustomDayKey) var statusCustomDayHex = ""
    @AppStorage(PanelPalettePreferences.statusCustomNightKey) var statusCustomNightHex = ""
    @AppStorage(MaintenanceReminderService.defaultsKey) var maintenanceCadenceRawValue = MaintenanceReminderService.defaultCadence.rawValue
    @State var pendingCloseWindow: NSWindow?
    @AppStorage("settings.selected-category.v1") var selectedCategory = SettingsCategory.general
    @AppStorage(PublicNetworkConsent.addressKey) var allowsPublicAddress = PublicNetworkConsent.defaultAllowsAddress
    @AppStorage(PublicNetworkConsent.countryKey) var allowsCountryLookup = false
    @State var scanHistorySummary = ScanHistorySummary(entries: [])
    @State var excludedPaths: [String] = []
    @State var exclusionNotice: SettingsNotice?
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
    @State var diagnosticNotice: SettingsNotice?
    @State var updateSourceConfiguration = AppUpdateSourcePreferences.configuration()
    @State var applicationUpdatePreferences = ApplicationUpdatePreferences.snapshot()
    @State var runtimeInfo = AppRuntimeLocationService.current()
    @State var confirmsMaximumFanMode = false
    @State var fanHardwareReadings = SMCFanSpeedService.HardwareReadings.empty
    @State var isLoadingFanCapability = false
    @StateObject var exclusionPanelCoordinator = AppOpenPanelCoordinator()
    @StateObject var fanControl: FanControlCoordinator

    init(
        cleanupArchitectureMode: CleanupArchitectureMode = .v2Full,
        scanStore: ScanStore? = nil,
        fanControl: @autoclosure @escaping @MainActor () -> FanControlCoordinator = FanControlCoordinator.shared
    ) {
        _fanControl = StateObject(wrappedValue: fanControl())
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
        GeometryReader { viewport in
            HStack(spacing: 0) {
                settingsSidebar.frame(width: viewport.size.width < 820 ? 180 : FeatureLightfield.sidebarWidth)
                settingsPane(for: selectedCategory)
            }
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

    private var settingsSidebar: some View {
        let palette = FeatureLightfieldPalette.resolve(colorScheme)
        return VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("设置", "Settings"))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.fg2)
                .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(SettingsCategory.allCases) { category in
                        let isSelected = selectedCategory == category
                        Button {
                            settingsSelection.wrappedValue = category
                            sidebarHasFocus = true
                        } label: {
                            HStack(spacing: 10) {
                                FeatureLightfieldArtwork(art: GeneratedArt.module(for: category.artworkModule), variant: .header)
                                    .frame(width: 20, height: 20)
                                Text(category.title).font(.system(size: 15)).lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }.foregroundStyle(palette.fg)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                .contentShape(Rectangle())
                                .background {
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(FeatureLightfieldPalette.accent(.overview).opacity(colorScheme == .dark ? 0.20 : 0.16))
                                    }
                                }
                        }.buttonStyle(FeatureLightfieldRowButtonStyle())
                            .accessibilityValue(isSelected ? L10n.text("已选择", "Selected") : "")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }.padding(.horizontal, 10)
            }
            .focusable().focused($sidebarHasFocus).focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard let current = SettingsCategory.allCases.firstIndex(of: selectedCategory) else { return .ignored }
                let next = press.key == .upArrow ? max(0, current - 1) : min(SettingsCategory.allCases.count - 1, current + 1)
                settingsSelection.wrappedValue = SettingsCategory.allCases[next]
                return .handled
            }
            .onMoveCommand { direction in
                guard let current = SettingsCategory.allCases.firstIndex(of: selectedCategory) else { return }
                let next: Int
                switch direction {
                case .up: next = max(0, current - 1)
                case .down: next = min(SettingsCategory.allCases.count - 1, current + 1)
                default: return
                }
                settingsSelection.wrappedValue = SettingsCategory.allCases[next]
            }
            FeatureLightfieldHairline().padding(.horizontal, 10)
            Text(SidebarVersionLabel.text).font(.system(size: 13)).foregroundStyle(palette.fg2)
                .monospacedDigit().padding(18).help(runtimeInfo.versionDisplay)
        }.background(FeatureLightfieldPalette.color(palette.sidebar))
    }

    private func settingsPane(for category: SettingsCategory) -> some View {
        SettingsLightfieldPane(category: category) {
            settingsForm(for: category)
                .controlSize(.regular)
                .buttonStyle(FeatureLightfieldRowButtonStyle())
        }
    }

    @ViewBuilder
    private func settingsForm(for category: SettingsCategory) -> some View {
        if category == .general {
            generalSettings
        } else if category == .miniWindow {
            miniWindowSettings
        } else if category == .accessAndSetup {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        permissionSetupSection
                        networkPrivacySection
                    }.padding(.bottom, 24)
                }
                .onAppear { scrollToRequestedHelper(using: proxy) }
                .onChange(of: helperSettingsNavigation.requestID) { scrollToRequestedHelper(using: proxy) }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) { settingsSections(for: category) }
                    .padding(.bottom, 24)
            }
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
        case .miniWindow: EmptyView()
        case .general:
            interfaceSection
            panelAppearanceSection
            launchBehaviorSection
        case .scanAndSafety:
            if let scanStore {
                LightfieldSettingsSection {
                    Button(L10n.text("查看逐项回执与恢复", "View receipts and recovery")) { showsOperations = true }
                        .sheet(isPresented: $showsOperations) { ReversibleOperationsView(store: scanStore) }
                } header: { Text(L10n.text("可恢复操作", "Recoverable Operations")) }
            }
            maintenanceReminderSection
            exclusionSection
        case .accessAndSetup:
            permissionSetupSection
            networkPrivacySection
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
        case .miniWindow: break
        case .general:
            refreshLaunchAtLoginStatus()
        case .accessAndSetup:
            refreshAccessStatus()
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
            excludedPaths = ScanExclusionService.excludedPaths()
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
        Toggle(isOn: $isEnabled) {
            VStack(alignment: .leading, spacing: 3) {
                Text(method.title)
                    .font(.body)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(method.title)
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
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .id(notice.text)
        .accessibilityElement(children: .combine)
    }
}

struct ExclusionPathRow: View {
    let path: String
    let remove: () -> Void

    private var displayName: String {
        ScanExclusionService.displayName(for: path)
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 15))
                    .lineLimit(1).truncationMode(.middle)
                LightfieldPathText(path: path)
            }

            Spacer(minLength: 0)

            Button(L10n.text("移除", "Remove"), action: remove)
                .buttonStyle(FeatureLightfieldRowButtonStyle())
                .accessibilityLabel(L10n.text("移除", "Remove") + " · " + displayName)
                .help(path)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        PassthroughWindowConfigurationView { window in
            configure(window)
        }
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? PassthroughWindowConfigurationView else { return }
        view.updateConfiguration { window in
            configure(window)
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
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = true

        let minimumSize = NSSize(width: 560, height: 390)
        if window.minSize != minimumSize {
            window.minSize = minimumSize
        }

        let maximumSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if window.maxSize != maximumSize {
            window.maxSize = maximumSize
        }

        restoreVisibleFrameIfNeeded(window)
    }

    private func restoreVisibleFrameIfNeeded(_ window: NSWindow) {
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
            targetFrame = window.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? visibleFrames[0]
        }
        let restoredFrame = SettingsWindowPlacement.clamped(window.frame, to: targetFrame)

        guard restoredFrame != window.frame else { return }
        window.setFrame(restoredFrame, display: true)
    }
}

enum SettingsWindowPlacement {
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
                .foregroundStyle(.secondary)
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
