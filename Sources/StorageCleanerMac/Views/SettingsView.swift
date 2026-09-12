import AppKit
import ServiceManagement
import SwiftUI

private enum SettingsCategory: String, CaseIterable, Hashable, Identifiable {
    case general
    case scanAndSafety
    case accessAndSetup
    case systemControl
    case updates
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
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

    var subtitle: String {
        switch self {
        case .general:
            L10n.text(
                "调整语言、外观、菜单栏小窗与启动行为。",
                "Adjust language, appearance, the menu-bar panel, and launch behavior."
            )
        case .scanAndSafety:
            L10n.text(
                "管理扫描提醒，以及智能扫描和重复文件共同使用的排除项。",
                "Manage scan reminders and exclusions shared by Smart Scan and Duplicates."
            )
        case .accessAndSetup:
            L10n.text(
                "检查所需权限，并直接前往对应的 macOS 设置。",
                "Check required access and open the matching macOS setting."
            )
        case .systemControl:
            L10n.text(
                "查看硬件能力，并安全管理风扇控制。",
                "Review hardware capability and manage fan control safely."
            )
        case .updates:
            L10n.text(
                "设置检查频率、自动化行为和可信更新来源。",
                "Set check frequency, automation behavior, and trusted update sources."
            )
        case .about:
            L10n.text(
                "查看版本、构建、运行位置与授权诊断。",
                "Review version, build, runtime location, and access diagnostics."
            )
        }
    }

    var systemImage: String {
        switch self {
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
    let cleanupArchitectureMode: CleanupArchitectureMode

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(L10n.languageDefaultsKey) private var languageRawValue = AppLanguage.system.rawValue
    @AppStorage(L10n.appearanceDefaultsKey) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(PanelAppearancePreferences.colorThemeKey) private var panelColorThemeRawValue = PanelColorTheme.graphite.rawValue
    @AppStorage(PanelAppearancePreferences.miniWindowAppearanceKey) private var miniWindowAppearanceRawValue = ""
    @AppStorage(PanelAppearancePreferences.backgroundColorKey) private var panelBackgroundColor = ""
    @AppStorage(PanelAppearancePreferences.chartColorKey) private var panelChartColor = ""
    @AppStorage(MaintenanceReminderService.defaultsKey) private var maintenanceCadenceRawValue = MaintenanceReminderService.defaultCadence.rawValue
    @AppStorage("settings.selected-category.v1") private var selectedCategory = SettingsCategory.general
    @State private var scanHistorySummary = ScanHistorySummary(entries: [])
    @State private var excludedPaths: [String] = []
    @State private var exclusionNotice: SettingsNotice?
    @State private var permissionNotice: SettingsNotice?
    @State private var fullDiskAccessState = FullDiskAccessState.unknown
    @State private var notificationsAuthorized = false
    @State private var launchAtLoginStatus = SMAppService.mainApp.status
    @State private var isChangingLaunchAtLogin = false
    @State private var launchAtLoginNotice: SettingsNotice?
    @State private var isCheckingAccess = false
    @State private var isRequestingNotifications = false
    @State private var isPreparingHelper = false
    @State private var diagnosticNotice: SettingsNotice?
    @State private var updateSourceConfiguration = AppUpdateSourcePreferences.configuration()
    @State private var applicationUpdatePreferences = ApplicationUpdatePreferences.snapshot()
    @State private var runtimeInfo = AppRuntimeLocationService.current()
    @State private var confirmsMaximumFanMode = false
    @State private var fanHardwareReadings = SMCFanSpeedService.HardwareReadings.empty
    @State private var isLoadingFanCapability = false
    @StateObject private var exclusionPanelCoordinator = AppOpenPanelCoordinator()
    @StateObject private var fanControl = FanControlCoordinator.shared

    init(cleanupArchitectureMode: CleanupArchitectureMode = .v2Full) {
        self.cleanupArchitectureMode = cleanupArchitectureMode
    }

    private var settingsTheme: ModuleTheme {
        ModuleThemeCatalog.theme(for: .settings)
    }

    private var selectedLanguage: Binding<AppLanguage> {
        Binding {
            AppLanguage(rawValue: languageRawValue) ?? .system
        } set: { newValue in
            languageRawValue = newValue.rawValue
        }
    }

    private var selectedAppearance: Binding<AppAppearance> {
        Binding {
            AppAppearance(rawValue: appearanceRawValue) ?? .system
        } set: { newValue in
            appearanceRawValue = newValue.rawValue
            newValue.applyAppKitPreference()
        }
    }

    private var selectedMaintenanceCadence: Binding<MaintenanceReminderCadence> {
        Binding {
            MaintenanceReminderService.cadence(from: maintenanceCadenceRawValue)
        } set: { newValue in
            maintenanceCadenceRawValue = newValue.rawValue
        }
    }

    private var selectedMiniWindowAppearance: Binding<MiniWindowAppearance> {
        Binding {
            MiniWindowAppearance(rawValue: miniWindowAppearanceRawValue) ?? .system
        } set: { appearance in
            miniWindowAppearanceRawValue = appearance.rawValue
        }
    }

    private var settingsSelection: Binding<SettingsCategory?> {
        Binding {
            selectedCategory
        } set: { category in
            if let category {
                selectedCategory = category
            }
        }
    }

    var body: some View {
        ZStack {
            ModuleBackground(theme: settingsTheme)

            NavigationSplitView {
                settingsSidebar
                    .navigationSplitViewColumnWidth(min: 180, ideal: 208, max: 240)
            } detail: {
                settingsPane(for: selectedCategory)
            }
            .navigationSplitViewStyle(.balanced)
        }
        .frame(
            minWidth: 720,
            idealWidth: 780,
            maxWidth: .infinity,
            minHeight: 500,
            idealHeight: 560,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.moduleTheme, settingsTheme)
        .foregroundStyle(settingsTheme.primaryText)
        .tint(settingsTheme.accent)
        .overlay(alignment: .topLeading) {
            SettingsWindowConfigurator(title: selectedCategory.title)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        .onAppear {
            refresh(category: selectedCategory)
        }
        .onChange(of: selectedCategory) { _, category in
            refresh(category: category)
        }
        .confirmationDialog(
            L10n.text("开启狂暴模式？", "Enable Maximum Cooling?"),
            isPresented: $confirmsMaximumFanMode,
            titleVisibility: .visible
        ) {
            Button(L10n.text("狂暴模式 · 最大转速", "Maximum Cooling · Maximum RPM")) {
                Task { await fanControl.selectMode(.maximum) }
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text(
                "噪音和功耗会明显增加；退出应用或发生异常时会恢复系统控制。",
                "Noise and power use will increase. Quitting the app or a failure restores system control."
            ))
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: settingsSelection) {
                Section {
                    ForEach(SettingsCategory.allCases) { category in
                        HStack(spacing: AppDesignTokens.Spacing.small) {
                            Image(systemName: category.systemImage)
                                .symbolRenderingMode(.hierarchical)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(category.tint)
                                .frame(width: 22, height: 22)

                            Text(category.title)
                                .font(AppTypography.sidebarItem)
                                .foregroundStyle(settingsTheme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .tag(category)
                    }
                } header: {
                    Label(L10n.text("设置", "Settings"), systemImage: "gearshape.fill")
                        .font(AppTypography.sectionTitle)
                        .foregroundStyle(settingsTheme.primaryText)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
                .overlay(Color.white.opacity(0.10))

            Text(runtimeInfo.versionDisplay)
                .font(AppTypography.sidebarVersion)
                .foregroundStyle(settingsTheme.secondaryText)
                .monospacedDigit()
                .padding(AppDesignTokens.Spacing.medium)
        }
        .background(Color.black.opacity(0.18))
    }

    private func settingsPane(for category: SettingsCategory) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsDetailHeader(for: category)

            settingsForm(for: category)
            .controlSize(.regular)
            .frame(
                maxWidth: AppDesignTokens.Layout.settingsPageMaxWidth,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private func settingsForm(for category: SettingsCategory) -> some View {
        if category == .accessAndSetup {
            Form {
                settingsSections(for: category)
            }
            .formStyle(.columns)
            .scrollContentBackground(.hidden)
        } else {
            Form {
                settingsSections(for: category)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func settingsDetailHeader(for category: SettingsCategory) -> some View {
        HStack(alignment: .center, spacing: AppDesignTokens.Spacing.medium) {
            AppSymbolIcon(
                systemImage: category.systemImage,
                role: .pageFeature,
                tint: category.tint,
                isDecorative: true
            )

            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.compact) {
                Text(category.title)
                    .font(AppTypography.pageTitle)
                    .foregroundStyle(settingsTheme.primaryText)

                Text(category.subtitle)
                    .font(AppTypography.pageSubtitle)
                    .foregroundStyle(settingsTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: AppDesignTokens.Layout.settingsPageMaxWidth, alignment: .leading)
        .padding(.horizontal, AppDesignTokens.Layout.pagePadding)
        .padding(.top, AppDesignTokens.Spacing.large)
        .padding(.bottom, AppDesignTokens.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func settingsSections(for category: SettingsCategory) -> some View {
        switch category {
        case .general:
            interfaceSection
            panelAppearanceSection
            launchBehaviorSection
        case .scanAndSafety:
            maintenanceReminderSection
            exclusionSection
        case .accessAndSetup:
            permissionSetupSection
            permissionTutorialSection
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
        case .general:
            launchAtLoginStatus = SMAppService.mainApp.status
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
                if !fanControlCapability.supportsWriting,
                   fanControl.selectedMode != .systemAutomatic {
                    await fanControl.selectMode(.systemAutomatic)
                }
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

    private var interfaceSection: some View {
        Section {
            Picker(L10n.text("界面语言", "Interface Language"), selection: selectedLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title)
                        .tag(language)
                }
            }
            .pickerStyle(.menu)

            Picker(L10n.text("外观", "Appearance"), selection: selectedAppearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title)
                        .tag(appearance)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Label(L10n.text("界面", "Interface"), systemImage: "paintpalette")
        }
    }

    private var launchBehaviorSection: some View {
        Section {
            Toggle(
                L10n.text("登录后自动打开存储清理助手", "Open Storage Cleaner at Login"),
                isOn: launchAtLoginBinding
            )
            .disabled(isChangingLaunchAtLogin)

            LabeledContent(
                L10n.text("系统状态", "System Status"),
                value: launchAtLoginStatusTitle
            )

            Button {
                SMAppService.openSystemSettingsLoginItems()
            } label: {
                Label(
                    L10n.text("打开登录项设置", "Open Login Item Settings"),
                    systemImage: "arrow.up.forward.app"
                )
            }
            .appButtonChrome(.secondary)

            if let launchAtLoginNotice {
                SettingsNoticeView(notice: launchAtLoginNotice)
            }
        } header: {
            Label(L10n.text("启动行为", "Launch Behavior"), systemImage: "power")
        } footer: {
            Text(L10n.text(
                "此开关只控制登录项。应用不会加入 macOS 的登录会话恢复列表；关闭后，即使关机前仍在运行，下次登录也不会自动打开。",
                "This switch controls only the login item. The app opts out of macOS login-session restoration, so when this is off it will not reopen after login even if it was still running before shutdown."
            ))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding {
            switch launchAtLoginStatus {
            case .enabled, .requiresApproval:
                true
            case .notRegistered, .notFound:
                false
            @unknown default:
                false
            }
        } set: { shouldLaunch in
            setLaunchAtLogin(shouldLaunch)
        }
    }

    private var launchAtLoginStatusTitle: String {
        switch launchAtLoginStatus {
        case .enabled:
            L10n.text("已开启", "Enabled")
        case .requiresApproval:
            L10n.text("等待系统批准", "Awaiting System Approval")
        case .notRegistered:
            L10n.text("已关闭", "Disabled")
        case .notFound:
            L10n.text("当前构建不可用", "Unavailable in This Build")
        @unknown default:
            L10n.text("未知", "Unknown")
        }
    }

    private func setLaunchAtLogin(_ shouldLaunch: Bool) {
        guard !isChangingLaunchAtLogin else { return }
        isChangingLaunchAtLogin = true
        launchAtLoginNotice = nil

        Task { @MainActor in
            let service = SMAppService.mainApp
            do {
                switch (shouldLaunch, service.status) {
                case (true, .notRegistered), (true, .notFound):
                    try service.register()
                case (false, .enabled), (false, .requiresApproval):
                    try service.unregister()
                default:
                    break
                }
                launchAtLoginStatus = service.status
                launchAtLoginNotice = SettingsNotice(
                    text: launchAtLoginStatus == .requiresApproval
                        ? L10n.text(
                            "登录项已提交，请在系统设置中批准。",
                            "The login item was submitted; approve it in System Settings."
                        )
                        : shouldLaunch
                            ? L10n.text("已开启登录后自动启动。", "Launch at login is enabled.")
                            : L10n.text("已关闭登录后自动启动。", "Launch at login is disabled."),
                    systemImage: launchAtLoginStatus == .requiresApproval
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill",
                    tint: launchAtLoginStatus == .requiresApproval
                        ? AppDesignTokens.Palette.warning
                        : AppDesignTokens.Palette.success
                )
            } catch {
                launchAtLoginStatus = service.status
                launchAtLoginNotice = SettingsNotice(
                    text: L10n.text(
                        "无法更改登录项：\(error.localizedDescription)",
                        "Could not change the login item: \(error.localizedDescription)"
                    ),
                    systemImage: "exclamationmark.triangle.fill",
                    tint: AppDesignTokens.Palette.warning
                )
            }
            isChangingLaunchAtLogin = false
        }
    }

    private var panelAppearanceSection: some View {
        Section {
            Picker(
                L10n.text("小窗外观", "Mini Window Appearance"),
                selection: selectedMiniWindowAppearance
            ) {
                ForEach(MiniWindowAppearance.allCases) { appearance in
                    Text(appearance.title)
                        .tag(appearance)
                }
            }
            .pickerStyle(.menu)

            Picker(
                L10n.text("小窗配色", "Panel Color Theme"),
                selection: selectedPanelColorTheme
            ) {
                ForEach(PanelColorTheme.allCases) { theme in
                    Text(panelColorThemeTitle(theme))
                        .tag(theme)
                }
            }
            .pickerStyle(.menu)

            if selectedPanelColorTheme.wrappedValue == .custom {
                ColorPicker(
                    L10n.text("小窗背景色", "Panel Background Color"),
                    selection: panelBackgroundColorBinding,
                    supportsOpacity: false
                )

                ColorPicker(
                    L10n.text("柱状图颜色", "Bar Chart Color"),
                    selection: panelChartColorBinding,
                    supportsOpacity: false
                )
            }
        } header: {
            Label(L10n.text("菜单栏小窗", "Menu-Bar Panel"), systemImage: "menubar.rectangle")
        }
    }

    private var fanControlSection: some View {
        Section {
            LabeledContent(
                L10n.text("辅助程序", "Helper"),
                value: fanControl.helperStatus.title
            )

            if isLoadingFanCapability {
                ProgressView(L10n.text("正在读取真实风扇范围…", "Reading hardware fan ranges…"))
                    .controlSize(.small)
            } else {
                switch fanControl.helperStatus {
                case .notRegistered:
                    if fanControlCapability.requiresPrivilegedHelper {
                        Button {
                            Task {
                                await fanControl.registerHelper()
                            }
                        } label: {
                            Label(
                                LegacyFanControlHelperInstaller.installedArtifactsPresent()
                                    ? L10n.text("更新系统控制", "Update System Control")
                                    : L10n.text("启用系统控制", "Enable System Control"),
                                systemImage: "fan"
                            )
                        }
                    } else {
                        fanControlReadOnlyNotice
                    }
                case .unavailable:
                    VStack(alignment: .leading, spacing: 6) {
                        Text(FanControlHelperStatus.unavailableReadOnlyDetail)
                            .font(AppTypography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        fanControlReadOnlyNotice
                    }
                case .needsMigration:
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text(
                            "检测到旧版系统控制辅助程序；迁移完成前不会启用风扇写入。",
                            "A legacy system-control helper was found; fan writes stay disabled until migration completes."
                        ))
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        if fanControlCapability.requiresPrivilegedHelper {
                            Button {
                                Task {
                                    await fanControl.migrateLegacyHelper()
                                }
                            } label: {
                                Label(
                                    L10n.text("迁移旧版系统控制", "Migrate Legacy System Control"),
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                            }
                        }
                    }
                case .requiresApproval:
                    if fanControlCapability.requiresPrivilegedHelper {
                        Button {
                            fanControl.openApprovalSettings()
                        } label: {
                            Label(
                                L10n.text("在系统设置中批准", "Approve in System Settings"),
                                systemImage: "gearshape.arrow.triangle.2.circlepath"
                            )
                        }
                    } else {
                        fanControlReadOnlyNotice
                    }
                case .enabled:
                    if fanControlCapability.supportsWriting {
                        Picker(
                            L10n.text("请求模式", "Requested Mode"),
                            selection: fanControlModeBinding
                        ) {
                            ForEach(
                                GeekFanControlAvailability.availableModes(
                                    capability: fanControlCapability
                                )
                            ) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)

                        LabeledContent(
                            L10n.text("已观察硬件模式", "Observed Hardware Mode"),
                            value: fanControlCapability.observedMode?.title
                                ?? L10n.text("未验证", "Unknown")
                        )

                        fanControlConfiguration
                    } else {
                        fanControlReadOnlyNotice
                    }

                    Button(role: .destructive) {
                        Task {
                            await fanControl.unregisterHelper()
                        }
                    } label: {
                        Label(
                            L10n.text("停用并恢复系统控制", "Disable and Restore System Control"),
                            systemImage: "fan.slash"
                        )
                    }
                }
            }

            if let message = fanControl.lastMessage {
                Text(message)
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Label(L10n.text("系统控制辅助程序", "System Control Helper"), systemImage: "switch.2")
        } footer: {
            Text(
                fanControl.helperStatus == .unavailable
                    ? L10n.text(
                        "当前构建未被 macOS 识别为可注册的控制服务；请使用包含有效 Helper 且经 Developer ID 签名、公证的构建。",
                        "macOS does not recognize this build as a registrable control service. Use a build with a valid helper that is Developer ID signed and notarized."
                    )
                    : L10n.text(
                        "首次启用需一次管理员批准；辅助程序失联或系统过热时会自动恢复 macOS 控制。",
                        "Enabling requests administrator approval once; control returns to macOS automatically if the helper disconnects or the system overheats."
                    )
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fanControlCapability: HardwareFanCapability {
        HardwareFanCapabilityProbe.probe(
            fanReadings: fanHardwareReadings.fanReadings,
            temperatureReadings: fanHardwareReadings.temperatureReadings,
            hasTrustedHelper: fanControl.hasTrustedHelper,
            observedMode: fanControl.observedMode
        )
    }

    @ViewBuilder
    private var fanControlReadOnlyNotice: some View {
        LabeledContent(
            L10n.text("硬件模式", "Hardware Mode"),
            value: L10n.text("只读 · 未验证", "Read Only · Unknown")
        )
        Text(fanControlReadOnlyReason)
        .font(AppTypography.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var fanControlReadOnlyReason: String {
        if !fanControlCapability.supportsReading {
            return L10n.text(
                "当前硬件未提供可验证的风扇读数，不支持写入控制。",
                "This hardware does not expose verifiable fan readings, so write control is unsupported."
            )
        }
        if !fanControlCapability.hasWritableRanges {
            return L10n.text(
                "未读取到所有风扇的有效硬件最小/最大 RPM，已隐藏写入模式。",
                "Valid hardware minimum/maximum RPM is unavailable for every fan, so write modes are hidden."
            )
        }
        return L10n.text(
            "辅助程序尚未完成受信任连接，写入模式保持隐藏。",
            "The helper has not completed a trusted connection, so write modes remain hidden."
        )
    }

    @ViewBuilder
    private var fanControlConfiguration: some View {
        switch fanControl.selectedMode {
        case .systemAutomatic:
            LabeledContent(
                L10n.text("请求来源", "Requested Source"),
                value: "macOS"
            )
        case .fanSet:
            Picker(
                L10n.text("风扇组", "Fan Set"),
                selection: $fanControl.selectedFanSet
            ) {
                ForEach(FanControlSet.allCases) { fanSet in
                    Text(fanSet.title).tag(fanSet)
                }
            }
            .pickerStyle(.menu)
        case .customCurve:
            FanCurveEditor(
                fanControl: fanControl,
                fanReadings: fanHardwareReadings.fanReadings
            )
        case .manual:
            fanControlSlider(
                title: L10n.text("临时目标", "Temporary Target"),
                value: Binding(
                    get: { fanControl.manualFraction * 100 },
                    set: {
                        fanControl.manualFraction = min(1, max(0, $0 / 100))
                    }
                ),
                range: 0...100,
                suffix: "%"
            )
            Text(L10n.text(
                "0% 对应每个风扇的硬件最小 RPM，100% 对应硬件最大 RPM。",
                "0% maps to each fan's hardware minimum RPM; 100% maps to its hardware maximum RPM."
            ))
            .font(AppTypography.caption)
            .foregroundStyle(.secondary)
            ForEach(fanHardwareReadings.fanReadings) { reading in
                if let minimumRPM = reading.minimumRPM,
                   let maximumRPM = reading.maximumRPM {
                    let targetRPM = FanControlPlanner.targetRPM(
                        minimumRPM: minimumRPM,
                        maximumRPM: maximumRPM,
                        fraction: fanControl.manualFraction
                    )
                    Text(L10n.text(
                        "\(reading.displayName)：目标 \(targetRPM) · 范围 \(minimumRPM)–\(maximumRPM) RPM",
                        "\(reading.displayName): target \(targetRPM) · range \(minimumRPM)–\(maximumRPM) RPM"
                    ))
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
        case .maximum:
            LabeledContent(
                L10n.text("目标", "Target"),
                value: L10n.text("所有风扇的硬件最大 RPM", "Hardware maximum RPM for every fan")
            )
        }
    }

    private func fanControlSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        HStack(spacing: AppDesignTokens.Spacing.medium) {
            Text(title)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue.rounded()))\(suffix)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private var fanControlModeBinding: Binding<GeekFanControlMode> {
        Binding {
            fanControl.selectedMode
        } set: { mode in
            if mode == .maximum {
                confirmsMaximumFanMode = true
                return
            }
            Task {
                await fanControl.selectMode(mode)
            }
        }
    }

    private var selectedPanelColorTheme: Binding<PanelColorTheme> {
        Binding {
            PanelColorTheme.resolved(
                storedTheme: panelColorThemeRawValue,
                backgroundHex: panelBackgroundColor,
                chartHex: panelChartColor
            )
        } set: { theme in
            panelColorThemeRawValue = theme.rawValue
            guard theme != .custom else {
                seedCustomPanelColorsIfNeeded()
                return
            }
            panelBackgroundColor = theme.backgroundHex ?? ""
            panelChartColor = theme.chartHex ?? ""
        }
    }

    private func panelColorThemeTitle(_ theme: PanelColorTheme) -> String {
        switch theme {
        case .system:
            L10n.text("跟随系统", "System")
        case .ocean:
            L10n.text("海洋蓝", "Ocean")
        case .violet:
            L10n.text("紫罗兰", "Violet")
        case .mint:
            L10n.text("薄荷绿", "Mint")
        case .graphite:
            L10n.text("石墨灰", "Graphite")
        case .custom:
            L10n.text("自定义", "Custom")
        }
    }

    private func seedCustomPanelColorsIfNeeded() {
        if PanelAppearancePreferences.normalizedHex(panelBackgroundColor) == nil {
            panelBackgroundColor = "#48484A"
        }
        if PanelAppearancePreferences.normalizedHex(panelChartColor) == nil {
            panelChartColor = "#0A84FF"
        }
    }

    private var panelBackgroundColorBinding: Binding<Color> {
        colorBinding(
            storedValue: $panelBackgroundColor,
            fallback: Color(nsColor: .windowBackgroundColor)
        )
    }

    private var panelChartColorBinding: Binding<Color> {
        colorBinding(
            storedValue: $panelChartColor,
            fallback: AppChartPalette.cpuUser
        )
    }

    private func colorBinding(
        storedValue: Binding<String>,
        fallback: Color
    ) -> Binding<Color> {
        Binding {
            PanelAppearancePreferences.color(from: storedValue.wrappedValue) ?? fallback
        } set: { color in
            if let value = PanelAppearancePreferences.hexString(from: color) {
                panelColorThemeRawValue = PanelColorTheme.custom.rawValue
                storedValue.wrappedValue = value
            }
        }
    }

    private var permissionSetupSection: some View {
        Section {
            VStack(spacing: AppDesignTokens.Spacing.medium) {
                PermissionSetupCard(
                    systemImage: "externaldrive.badge.checkmark",
                    title: L10n.text("完整磁盘访问", "Full Disk Access"),
                    requirement: L10n.text("完整功能需要", "Required for Full Features"),
                    status: fullDiskAccessStatus,
                    statusTint: fullDiskAccessTint,
                    detail: L10n.text(
                        "用于完整扫描受保护的缓存、Safari 与其他应用数据。未授权时仍可扫描你手动选择的文件夹。",
                        "Used for complete scans of protected caches, Safari, and other app data. Without it, you can still scan folders you choose manually."
                    ),
                    guide: L10n.text(
                        "系统设置 → 隐私与安全性 → 完整磁盘访问权限",
                        "System Settings → Privacy & Security → Full Disk Access"
                    )
                ) {
                    Button {
                        openFullDiskAccessSettings()
                    } label: {
                        Label(L10n.text("打开设置", "Open Settings"), systemImage: "arrow.up.forward.app")
                    }
                    .appButtonChrome(.primary)

                    Button {
                        refreshAccessStatus()
                    } label: {
                        Label(L10n.text("重新检查", "Check Again"), systemImage: "arrow.clockwise")
                    }
                    .appButtonChrome(.secondary)
                    .disabled(isCheckingAccess)
                }

                PermissionSetupCard(
                    systemImage: "folder.badge.plus",
                    title: L10n.text("文件与文件夹", "Files & Folders"),
                    requirement: L10n.text("按需替代", "Optional Alternative"),
                    status: L10n.text("由 macOS 按位置管理", "Managed per Location by macOS"),
                    statusTint: AppDesignTokens.Palette.information,
                    detail: L10n.text(
                        "只允许桌面、文稿、下载或外置磁盘时使用。macOS 不提供统一状态，访问会在实际选择位置时确认。",
                        "Use this when you only want Desktop, Documents, Downloads, or external-volume access. macOS has no single combined status; access is confirmed per location."
                    ),
                    guide: L10n.text(
                        "系统设置 → 隐私与安全性 → 文件与文件夹",
                        "System Settings → Privacy & Security → Files & Folders"
                    )
                ) {
                    Button {
                        openFilesAndFoldersSettings()
                    } label: {
                        Label(L10n.text("打开设置", "Open Settings"), systemImage: "arrow.up.forward.app")
                    }
                    .appButtonChrome(.secondary)
                }

                PermissionSetupCard(
                    systemImage: "shippingbox.and.arrow.backward",
                    title: L10n.text("应用管理", "App Management"),
                    requirement: L10n.text("更新与卸载需要", "Required for Updates & Removal"),
                    status: L10n.text("由 macOS 按需确认", "Confirmed on Demand by macOS"),
                    statusTint: AppDesignTokens.Palette.information,
                    detail: L10n.text(
                        "允许本应用更新或移除其他 App；只在使用应用更新或卸载时需要。App Store 管理的软件仍交给 App Store，安装前仍会验证身份与签名。",
                        "Allows this app to update or remove other apps, and is needed only for app updates or uninstalling. App Store-managed software stays with the App Store, and identity and signatures are still verified before installation."
                    ),
                    guide: L10n.text(
                        "系统设置 → 隐私与安全性 → 应用管理",
                        "System Settings → Privacy & Security → App Management"
                    )
                ) {
                    Button {
                        openAppManagementSettings()
                    } label: {
                        Label(L10n.text("打开设置", "Open Settings"), systemImage: "arrow.up.forward.app")
                    }
                    .appButtonChrome(.secondary)
                }

                PermissionSetupCard(
                    systemImage: "lock.shield",
                    title: L10n.text("系统控制组件", "System Control Helper"),
                    requirement: L10n.text("控制功能需要", "Required for Controls"),
                    status: fanControl.helperStatus.title,
                    statusTint: helperAccessTint,
                    detail: L10n.text(
                        "风扇模式、电源模式与需要系统级操作的启动项共用一个受限 Helper；只接受白名单命令，管理员密码不会由应用保存。",
                        "Fan modes, power modes, and system-level startup-item actions share one restricted helper. It accepts only allow-listed commands, and the app never stores an administrator password."
                    ),
                    guide: L10n.text(
                        "系统设置 → 通用 → 登录项与扩展 → 允许在后台",
                        "System Settings → General → Login Items & Extensions → Allow in Background"
                    )
                ) {
                    helperAccessActions
                }

                PermissionSetupCard(
                    systemImage: "bell.badge",
                    title: L10n.text("完成通知", "Completion Notifications"),
                    requirement: L10n.text("可选", "Optional"),
                    status: notificationsAuthorized
                        ? L10n.text("已允许", "Allowed")
                        : L10n.text("未允许", "Not Allowed"),
                    statusTint: notificationsAuthorized
                        ? AppDesignTokens.Palette.success
                        : AppDesignTokens.Palette.secondaryText,
                    detail: L10n.text(
                        "在应用更新或长任务完成后发送本地通知；不上传扫描内容，也不用于营销。",
                        "Sends a local notification when app updates or long tasks finish. Scan content is not uploaded and notifications are not used for marketing."
                    ),
                    guide: L10n.text(
                        "系统设置 → 通知 → 存储清理助手",
                        "System Settings → Notifications → Storage Cleaner"
                    )
                ) {
                    Button {
                        requestNotificationAccess()
                    } label: {
                        Label(
                            notificationsAuthorized
                                ? L10n.text("已允许", "Allowed")
                                : L10n.text("允许通知", "Allow Notifications"),
                            systemImage: "bell"
                        )
                    }
                    .appButtonChrome(.secondary)
                    .disabled(isRequestingNotifications || notificationsAuthorized)

                    Button {
                        openNotificationSettings()
                    } label: {
                        Label(L10n.text("打开设置", "Open Settings"), systemImage: "arrow.up.forward.app")
                    }
                    .appButtonChrome(.secondary)
                }
            }

            if let permissionNotice {
                SettingsNoticeView(notice: permissionNotice)
            }
        } header: {
            Label(L10n.text("功能权限", "Feature Access"), systemImage: "lock.shield")
        } footer: {
            Text(
                L10n.text(
                    "授权必须由你在 macOS 中确认。返回本页后点“重新检查”；应用不会绕过系统设置。",
                    "You must confirm access in macOS. Return here and choose Check Again; the app never bypasses System Settings."
                )
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionTutorialSection: some View {
        Section {
            DisclosureGroup(L10n.text("推荐设置顺序", "Recommended Setup Order")) {
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
                    SettingsTutorialStep(
                        number: 1,
                        title: L10n.text("先完成扫描访问", "Set Up Scan Access First"),
                        detail: L10n.text(
                            "需要完整扫描时启用“完整磁盘访问”；只扫描个人位置时，可改用文件夹选择。授权后返回并重新检查。",
                            "Enable Full Disk Access for complete scans, or choose folders for personal locations only. Return and check again after granting access."
                        )
                    )
                    SettingsTutorialStep(
                        number: 2,
                        title: L10n.text("更新或卸载 App 时允许应用管理", "Allow App Management for Updates or Removal"),
                        detail: L10n.text(
                            "只有需要更新或移除其他 App 时才启用“应用管理”；普通扫描、清理个人文件和监测功能不依赖它。",
                            "Enable App Management only when updating or removing other apps. Normal scans, personal-file cleanup, and monitoring do not depend on it."
                        )
                    )
                    SettingsTutorialStep(
                        number: 3,
                        title: L10n.text("需要控制时启用 Helper", "Enable the Helper for Controls"),
                        detail: L10n.text(
                            "点击“安装并授权”，再在“登录项与扩展”允许后台项目。风扇、电源和系统级启动项才会解除只读状态。",
                            "Choose Install & Approve, then allow the background item in Login Items & Extensions. Fan, power, and system-level startup controls will then leave read-only mode."
                        )
                    )
                    SettingsTutorialStep(
                        number: 4,
                        title: L10n.text("最后按需允许通知", "Allow Notifications If Wanted"),
                        detail: L10n.text(
                            "通知只用于任务完成提醒；拒绝通知不会影响扫描、清理或硬件控制。",
                            "Notifications are only for completion alerts. Denying them does not affect scanning, cleanup, or hardware control."
                        )
                    )
                }
                .padding(.top, AppDesignTokens.Spacing.small)
            }

            SettingsNoticeView(
                notice: SettingsNotice(
                    text: L10n.text(
                        "无需授权：辅助功能、屏幕录制、相机、麦克风、定位与自动化。联网仅用于应用更新、官网检查、测速和排行榜，不会触发额外的 macOS 权限。",
                        "Not required: Accessibility, Screen Recording, Camera, Microphone, Location, or Automation. Internet access is used only for app updates, official-site checks, speed tests, and leaderboards, and does not require another macOS privacy grant."
                    ),
                    systemImage: "checkmark.shield.fill",
                    tint: AppDesignTokens.Palette.success
                )
            )
        } header: {
            Label(L10n.text("设置教程", "Setup Guide"), systemImage: "list.number")
        }
    }

    @ViewBuilder
    private var helperAccessActions: some View {
        switch fanControl.helperStatus {
        case .enabled:
            Button {
                refreshAccessStatus()
            } label: {
                Label(L10n.text("重新检查", "Check Again"), systemImage: "arrow.clockwise")
            }
            .appButtonChrome(.secondary)
        case .requiresApproval:
            Button {
                fanControl.openApprovalSettings()
            } label: {
                Label(L10n.text("打开登录项", "Open Login Items"), systemImage: "arrow.up.forward.app")
            }
            .appButtonChrome(.primary)
        case .needsMigration:
            Button {
                isPreparingHelper = true
                Task { @MainActor in
                    await fanControl.migrateLegacyHelper()
                    isPreparingHelper = false
                }
            } label: {
                Label(L10n.text("迁移旧组件", "Migrate Legacy Helper"), systemImage: "arrow.triangle.2.circlepath")
            }
            .appButtonChrome(.primary)
            .disabled(isPreparingHelper)
        case .notRegistered, .unavailable:
            Button {
                isPreparingHelper = true
                Task { @MainActor in
                    await fanControl.registerHelper()
                    isPreparingHelper = false
                }
            } label: {
                Label(
                    isPreparingHelper
                        ? L10n.text("正在准备", "Preparing")
                        : L10n.text("安装并授权", "Install & Approve"),
                    systemImage: "lock.open"
                )
            }
            .appButtonChrome(.primary)
            .disabled(isPreparingHelper)
        }
    }

    private var fullDiskAccessStatus: String {
        if isCheckingAccess { return L10n.text("检查中", "Checking") }
        switch fullDiskAccessState {
        case .verified:
            return L10n.text("已验证", "Verified")
        case .notVerified:
            return L10n.text("未验证", "Not Verified")
        case .unknown:
            return L10n.text("无法判断", "Unknown")
        }
    }

    private var fullDiskAccessTint: Color {
        switch fullDiskAccessState {
        case .verified:
            AppDesignTokens.Palette.success
        case .notVerified:
            AppDesignTokens.Palette.warning
        case .unknown:
            AppDesignTokens.Palette.secondaryText
        }
    }

    private var helperAccessTint: Color {
        fanControl.helperStatus == .enabled
            ? AppDesignTokens.Palette.success
            : AppDesignTokens.Palette.warning
    }

    private func refreshAccessStatus() {
        guard !isCheckingAccess else { return }
        isCheckingAccess = true
        fanControl.refreshStatus()
        Task { @MainActor in
            async let diskState = Task.detached(priority: .utility) {
                ScanReadinessService.fullDiskAccessState()
            }.value
            async let notificationState = ApplicationUpdateNotificationService.isAuthorized()
            await fanControl.refreshConnection()
            fullDiskAccessState = await diskState
            notificationsAuthorized = await notificationState
            isCheckingAccess = false
        }
    }

    private func requestNotificationAccess() {
        guard !isRequestingNotifications else { return }
        isRequestingNotifications = true
        Task { @MainActor in
            notificationsAuthorized = await ApplicationUpdateNotificationService.requestAuthorization()
            isRequestingNotifications = false
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        let didOpen = NSWorkspace.shared.open(url)
        permissionNotice = SettingsNotice(
            text: didOpen
                ? L10n.text("已打开通知设置。", "Notification settings opened.")
                : L10n.text("无法打开通知设置，请在系统设置中手动进入“通知”。", "Could not open Notifications; open it manually in System Settings."),
            systemImage: didOpen ? "bell.fill" : "exclamationmark.triangle.fill",
            tint: didOpen
                ? AppDesignTokens.Palette.information
                : AppDesignTokens.Palette.warning
        )
    }

    private var maintenanceReminderSection: some View {
        let cadence = MaintenanceReminderService.cadence(from: maintenanceCadenceRawValue)
        let summary = MaintenanceReminderService.summary(
            cadence: cadence,
            lastScanAt: scanHistorySummary.latest?.date
        )

        return Section {
            Picker(L10n.text("提醒频率", "Reminder Frequency"), selection: selectedMaintenanceCadence) {
                ForEach(MaintenanceReminderCadence.allCases) { cadence in
                    Text(cadence.title)
                        .tag(cadence)
                }
            }
            .pickerStyle(.menu)

            LabeledContent(L10n.text("状态", "Status"), value: summary.statusTitle)
            LabeledContent(L10n.text("上次扫描", "Last Scan"), value: reminderDateText(summary.lastScanAt))
            LabeledContent(L10n.text("下次建议", "Next Due"), value: reminderDateText(summary.nextDueAt))
        } header: {
            Label(L10n.text("扫描提醒", "Scan Reminder"), systemImage: "calendar.badge.clock")
        }
    }

    private var updateAutomationSection: some View {
        Section {
            Toggle(
                L10n.text("自动检查更新", "Automatically Check for Updates"),
                isOn: updatePreferenceBinding(\.automaticallyChecks)
            )

            Picker(
                L10n.text("检查频率", "Check Frequency"),
                selection: updateFrequencyBinding
            ) {
                ForEach(ApplicationUpdateCheckFrequency.allCases) { frequency in
                    Text(frequency.title).tag(frequency)
                }
            }
            .pickerStyle(.menu)
            .disabled(!applicationUpdatePreferences.automaticallyChecks)

            Toggle(
                L10n.text("自动安装可静默更新项目", "Automatically Install Silent Updates"),
                isOn: automaticSilentUpdateBinding
            )

            Toggle(
                L10n.text("应用退出后更新", "Update After an App Quits"),
                isOn: updatePreferenceBinding(\.updatesAfterApplicationQuits)
            )

            Toggle(
                L10n.text("更新完成后通知", "Notify When Updates Finish"),
                isOn: updatePreferenceBinding(\.notifiesOnCompletion)
            )
        } header: {
            Label(L10n.text("自动化", "Automation"), systemImage: "clock.arrow.circlepath")
        }
    }

    private var updateSourceSection: some View {
        Section {
            Toggle(
                L10n.text("包含 Homebrew Formula", "Include Homebrew Formulae"),
                isOn: updatePreferenceBinding(\.includesHomebrewFormulae)
            )

            Toggle(
                L10n.text("检查带有自身更新器的 Homebrew Cask", "Check Self-updating Homebrew Casks"),
                isOn: updatePreferenceBinding(\.checksSelfUpdatingHomebrewCasks)
            )

            Toggle(
                L10n.text("扫描外置磁盘中的应用", "Scan Applications on External Volumes"),
                isOn: updatePreferenceBinding(\.scansExternalVolumes)
            )

            DisclosureGroup(L10n.text("更新来源", "Update Sources")) {
                LabeledContent(
                    L10n.text("远程检查已启用", "Remote Checks Enabled"),
                    value: "\(updateSourceConfiguration.enabledCount)/\(AppUpdateMethod.allCases.count)"
                )

                ForEach(AppUpdateMethod.allCases) { method in
                    UpdateSourceOptionRow(
                        method: method,
                        isEnabled: Binding(
                            get: { updateSourceConfiguration.includes(method) },
                            set: { setUpdateSource(method, isEnabled: $0) }
                        )
                    )
                }

                if updateSourceConfiguration != .all {
                    Button {
                        resetUpdateSources()
                    } label: {
                        Label(L10n.text("恢复全部来源", "Enable All Sources"), systemImage: "checkmark.circle")
                    }
                }
            }

            SettingsNoticeView(
                notice: SettingsNotice(
                    text: L10n.text(
                        "App Store、官网与需授权的项目始终要求确认；签名变化会阻止自动安装。",
                        "App Store, website, and authorization flows always require confirmation; signing changes block automatic installation."
                    ),
                    systemImage: "lock.shield",
                    tint: AppDesignTokens.Palette.information
                )
            )
        } header: {
            Label(
                L10n.text("范围与来源", "Coverage & Sources"),
                systemImage: "shippingbox"
            )
        } footer: {
            Text(
                L10n.text(
                    "关闭更新来源只停止对应远程检查；不影响存储清理助手自身的 Sparkle 更新。",
                    "Disabling an update source only stops its remote checks; it does not affect Storage Cleaner's own Sparkle updates."
                )
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var exclusionSection: some View {
        Section {
            LabeledContent(L10n.text("已排除", "Excluded"), value: L10n.items(excludedPaths.count))
            LabeledContent(
                L10n.text("适用范围", "Applies To"),
                value: L10n.text("智能扫描与重复文件", "Smart Scan & Duplicates")
            )

            if let exclusionNotice {
                SettingsNoticeView(notice: exclusionNotice)
            }

            if excludedPaths.isEmpty {
                Text(L10n.text("暂无排除项", "No Exclusions"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(excludedPaths, id: \.self) { path in
                    ExclusionPathRow(path: path) {
                        removeExclusion(path)
                    }
                    .transition(AppMotionTokens.listTransition(reduceMotion: reduceMotion))
                }
            }

            exclusionActionButtons
                .animation(
                    AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
                    value: excludedPaths
                )
        } header: {
            exclusionTitle
        }
    }

    private var exclusionTitle: some View {
        Label(L10n.text("扫描排除", "Scan Exclusions"), systemImage: "eye.slash")
    }

    private var exclusionActionButtons: some View {
        HStack(spacing: 8) {
            Button {
                addExclusion()
            } label: {
                Label(L10n.text("添加排除项", "Add Exclusion"), systemImage: "plus")
            }
            .disabled(exclusionPanelCoordinator.isPresenting)

            if !excludedPaths.isEmpty {
                Button {
                    copyExclusions()
                } label: {
                    Label(L10n.text("复制清单", "Copy List"), systemImage: "doc.on.doc")
                }
            }

            if !excludedPaths.isEmpty {
                Button(role: .destructive) {
                    clearExclusions()
                } label: {
                    Label(L10n.text("移除全部排除项", "Remove All Exclusions"), systemImage: "trash")
                }
            }
        }
    }

    private var aboutSection: some View {
        Section {
            HStack(spacing: AppDesignTokens.Spacing.medium) {
                AppIconView(
                    asset: .appMain,
                    size: AppIconSizing.brand,
                    cornerRadius: 9,
                    showsShadow: false
                )

                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.compact) {
                    Text(aboutAppTitle)
                        .font(AppTypography.sectionTitle)
                    Text(runtimeInfo.versionDisplay)
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let buildInfo = runtimeInfo.buildInfo, buildInfo.isBeta {
                LabeledContent("Build", value: buildInfo.build)
                LabeledContent("Commit", value: buildInfo.commitDisplay)
                LabeledContent(
                    L10n.text("构建日期", "Built"),
                    value: buildInfo.buildDate
                )
                LabeledContent(
                    L10n.text("构建配置", "Configuration"),
                    value: buildInfo.configuration
                )
            }
            LabeledContent("Bundle ID", value: runtimeInfo.bundleIdentifier)
            LabeledContent(L10n.text("运行位置", "Runtime"), value: runtimeInfo.kind.detail)
            LabeledContent(
                L10n.text("清理架构", "Cleanup Architecture"),
                value: CleanupFeatureConfiguration(
                    mode: cleanupArchitectureMode
                ).diagnosticValue
            )

            DisclosureGroup {
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
                    LabeledContent(
                        L10n.text("分发状态", "Distribution"),
                        value: runtimeInfo.distributionStatus
                    )
                    LabeledContent(
                        L10n.text("授权稳定性", "Access Stability"),
                        value: runtimeInfo.authorizationStabilityStatus
                    )
                    LabeledContent(
                        L10n.text("授权复用建议", "Access Reuse Guidance"),
                        value: runtimeInfo.authorizationStabilityAction
                    )
                    LabeledContent(
                        L10n.text("窗口关闭说明", "Window Closing"),
                        value: runtimeInfo.authorizationWindowLifecycleNote
                    )
                }
                .padding(.top, AppDesignTokens.Spacing.small)
            } label: {
                Label(
                    L10n.text("安装与授权详情", "Installation & Access Details"),
                    systemImage: "info.circle"
                )
            }

            Button {
                copyRuntimeDiagnostics()
            } label: {
                Label(
                    runtimeInfo.buildInfo?.isBeta == true
                        ? L10n.text("复制测试版信息", "Copy Beta Information")
                        : L10n.text("复制诊断信息", "Copy Diagnostics"),
                    systemImage: "doc.on.doc"
                )
            }

            if let diagnosticNotice {
                SettingsNoticeView(notice: diagnosticNotice)
            }
        } header: {
            Label(L10n.text("版本与诊断", "Version & Diagnostics"), systemImage: "info.circle")
        }
    }

    private func addExclusion() {
        guard !exclusionPanelCoordinator.isPresenting else { return }

        let panel = NSOpenPanel()
        panel.title = L10n.text("选择要排除的项目", "Choose Items to Exclude")
        panel.prompt = L10n.text("加入排除项", "Exclude")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        let completion: @MainActor @Sendable (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            applyExclusions(panel.urls)
        }

        exclusionPanelCoordinator.present(
            panel,
            attachedTo: AppOpenPanelCoordinator.preferredHostWindow(),
            completion: completion
        )
    }

    private func applyExclusions(_ urls: [URL]) {
        var addedCount = 0
        var rejectedCount = 0
        var duplicateCount = 0

        for url in urls {
            if !ScanExclusionService.canExclude(url.path) {
                rejectedCount += 1
            } else if ScanExclusionService.add(url.path) {
                addedCount += 1
            } else {
                duplicateCount += 1
            }
        }
        excludedPaths = ScanExclusionService.excludedPaths()
        exclusionNotice = noticeForExclusionResult(
            addedCount: addedCount,
            rejectedCount: rejectedCount,
            duplicateCount: duplicateCount
        )
    }

    private func copyExclusions() {
        guard !excludedPaths.isEmpty else {
            exclusionNotice = SettingsNotice(
                text: L10n.text("当前没有可复制的扫描排除项。", "There are no scan exclusions to copy."),
                systemImage: "info.circle.fill",
                tint: AppDesignTokens.Palette.information
            )
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ScanExclusionService.markdown(for: excludedPaths), forType: .string)
        exclusionNotice = SettingsNotice(
            text: L10n.text("扫描排除项清单已复制。", "Scan exclusion list copied."),
            systemImage: "doc.on.doc.fill",
            tint: AppDesignTokens.Palette.success
        )
    }

    private func removeExclusion(_ path: String) {
        ScanExclusionService.remove(path)
        excludedPaths = ScanExclusionService.excludedPaths()
        exclusionNotice = SettingsNotice(
            text: L10n.text("已从扫描排除项移除“\(ScanExclusionService.displayName(for: path))”。", "Removed \"\(ScanExclusionService.displayName(for: path))\" from scan exclusions."),
            systemImage: "minus.circle.fill",
            tint: AppDesignTokens.Palette.warning
        )
    }

    private func clearExclusions() {
        ScanExclusionService.clear()
        excludedPaths = ScanExclusionService.excludedPaths()
        exclusionNotice = SettingsNotice(
            text: L10n.text("已清空扫描排除项。", "Cleared scan exclusions."),
            systemImage: "trash.fill",
            tint: AppDesignTokens.Palette.destructive
        )
    }

    private func noticeForExclusionResult(
        addedCount: Int,
        rejectedCount: Int,
        duplicateCount: Int
    ) -> SettingsNotice? {
        if addedCount > 0 {
            return SettingsNotice(
                text: L10n.text(
                    "已添加 \(addedCount) 个排除项。",
                    "Added \(addedCount) exclusions."
                ),
                systemImage: "checkmark.circle.fill",
                tint: AppDesignTokens.Palette.success
            )
        }

        if rejectedCount > 0 {
            return SettingsNotice(
                text: L10n.text(
                    "未添加：只能排除个人目录或 /Applications 下的项目，系统根目录会被保护。",
                    "Not added: exclusions are limited to your home folder or /Applications; system root paths are protected."
                ),
                systemImage: "lock.shield.fill",
                tint: AppDesignTokens.Palette.destructive
            )
        }

        if duplicateCount > 0 {
            return SettingsNotice(
                text: L10n.text("这些项目已经在排除列表中。", "These items are already excluded."),
                systemImage: "info.circle.fill",
                tint: AppDesignTokens.Palette.information
            )
        }

        return nil
    }

    private func updatePreferenceBinding(
        _ keyPath: WritableKeyPath<ApplicationUpdatePreferencesSnapshot, Bool>
    ) -> Binding<Bool> {
        Binding {
            applicationUpdatePreferences[keyPath: keyPath]
        } set: { newValue in
            applicationUpdatePreferences[keyPath: keyPath] = newValue
            ApplicationUpdatePreferences.set(applicationUpdatePreferences)
            if keyPath == \.notifiesOnCompletion, newValue {
                Task {
                    let granted = await ApplicationUpdateNotificationService.requestAuthorization()
                    guard !granted else { return }
                    await MainActor.run {
                        applicationUpdatePreferences.notifiesOnCompletion = false
                        ApplicationUpdatePreferences.set(applicationUpdatePreferences)
                    }
                }
            }
        }
    }

    private var automaticSilentUpdateBinding: Binding<Bool> {
        Binding {
            applicationUpdatePreferences.automaticallyExecutesSilentUpdates
        } set: { isEnabled in
            applicationUpdatePreferences.setAutomaticSilentUpdateExecution(isEnabled)
            ApplicationUpdatePreferences.set(applicationUpdatePreferences)
        }
    }

    private var updateFrequencyBinding: Binding<ApplicationUpdateCheckFrequency> {
        Binding {
            applicationUpdatePreferences.checkFrequency
        } set: { newValue in
            applicationUpdatePreferences.checkFrequency = newValue
            ApplicationUpdatePreferences.set(applicationUpdatePreferences)
        }
    }

    private func setUpdateSource(_ method: AppUpdateMethod, isEnabled: Bool) {
        updateSourceConfiguration.set(method, isEnabled: isEnabled)
        AppUpdateSourcePreferences.setConfiguration(updateSourceConfiguration)
    }

    private func resetUpdateSources() {
        AppUpdateSourcePreferences.reset()
        updateSourceConfiguration = AppUpdateSourcePreferences.configuration()
    }

    private func openFullDiskAccessSettings() {
        let didOpen = CleanupService.openFullDiskAccessSettings()
        permissionNotice = didOpen
            ? SettingsNotice(
                text: L10n.text("已打开完整磁盘访问设置，授权后请重新扫描。", "Full Disk Access settings opened; grant access, then scan again."),
                systemImage: "externaldrive.fill",
                tint: AppDesignTokens.Palette.information
            )
            : SettingsNotice(
                text: L10n.text("无法打开系统设置，请手动进入“隐私与安全性”。", "Could not open System Settings; open Privacy & Security manually."),
                systemImage: "exclamationmark.triangle.fill",
                tint: AppDesignTokens.Palette.warning
            )
    }

    private func openFilesAndFoldersSettings() {
        let didOpen = CleanupService.openFilesAndFoldersSettings()
        permissionNotice = didOpen
            ? SettingsNotice(
                text: L10n.text("已打开文件与文件夹设置，授权在系统设置中完成。", "Files & Folders settings opened; access is granted in System Settings."),
                systemImage: "folder.fill",
                tint: AppDesignTokens.Palette.information
            )
            : SettingsNotice(
                text: L10n.text("无法打开系统设置，请手动进入“隐私与安全性”。", "Could not open System Settings; open Privacy & Security manually."),
                systemImage: "exclamationmark.triangle.fill",
                tint: AppDesignTokens.Palette.warning
            )
    }

    private func openAppManagementSettings() {
        let didOpen = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles"
        ).map(NSWorkspace.shared.open) ?? false
        permissionNotice = didOpen
            ? SettingsNotice(
                text: L10n.text("已打开应用管理设置；是否允许由你在 macOS 中确认。", "App Management settings opened; confirm access in macOS."),
                systemImage: "shippingbox.fill",
                tint: AppDesignTokens.Palette.information
            )
            : SettingsNotice(
                text: L10n.text("无法打开系统设置，请手动进入“隐私与安全性 → 应用管理”。", "Could not open System Settings; open Privacy & Security → App Management manually."),
                systemImage: "exclamationmark.triangle.fill",
                tint: AppDesignTokens.Palette.warning
            )
    }

    private func copyRuntimeDiagnostics() {
        runtimeInfo = AppRuntimeLocationService.current()
        let diagnostics = runtimeInfo.buildInfo?.isBeta == true
            ? runtimeInfo.buildInfo?.betaDiagnosticsMarkdown(
                helperStatus: fanControl.helperStatus.title,
                advancedControlStatus: fanControl.helperState.title
            ) ?? runtimeInfo.diagnosticsMarkdown
            : runtimeInfo.diagnosticsMarkdown
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
        diagnosticNotice = SettingsNotice(
            text: L10n.text("诊断信息已复制。", "Diagnostics copied."),
            systemImage: "doc.on.doc.fill",
            tint: AppDesignTokens.Palette.success
        )
    }

    private var aboutAppTitle: String {
        guard let buildInfo = runtimeInfo.buildInfo, buildInfo.isBeta else {
            return L10n.appName
        }
        return L10n.text(
            "存储清理助手 \(buildInfo.version) 测试版",
            "Storage Cleaner \(buildInfo.version) Beta"
        )
    }

    private func reminderDateText(_ date: Date?) -> String {
        guard let date else {
            return L10n.text("暂无", "None")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct UpdateSourceOptionRow: View {
    let method: AppUpdateMethod
    @Binding var isEnabled: Bool

    var body: some View {
        Toggle(isOn: $isEnabled) {
            VStack(alignment: .leading, spacing: 3) {
                Text(method.title)
                    .font(.body)

                Text(method.detail)
                    .font(AppTypography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

private struct SettingsNotice {
    let text: String
    let systemImage: String
    let tint: Color
}

private struct SettingsNoticeView: View {
    let notice: SettingsNotice

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: notice.systemImage)
                .font(AppDesignTokens.Typography.symbol)
                .foregroundStyle(notice.tint)
                .frame(width: AppDesignTokens.Icon.settingsNotice, height: AppDesignTokens.Icon.settingsNotice)

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

private struct ExclusionPathRow: View {
    let path: String
    let remove: () -> Void

    private var displayName: String {
        ScanExclusionService.displayName(for: path)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: path.hasSuffix(".app") ? "app.fill" : "folder")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: AppDesignTokens.Icon.settingsInline)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(AppDesignTokens.Typography.metadata)
                    .fixedSize(horizontal: false, vertical: true)
                Text(path)
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            AppIconButton(
                title: L10n.text("移除", "Remove"),
                systemImage: "minus.circle",
                kind: .destructive,
                tint: AppDesignTokens.Palette.destructive,
                action: remove
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}

private struct SettingsTutorialStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
            Text("\(number)")
                .font(AppTypography.compactLabel)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(AppDesignTokens.Palette.accent, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.compact) {
                Text(title)
                    .font(AppTypography.metadata)
                Text(detail)
                    .font(AppTypography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number). \(title). \(detail)")
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
        window.toolbar?.allowsUserCustomization = false
        window.toolbar?.autosavesConfiguration = false
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        let minimumSize = NSSize(width: 720, height: 500)
        if window.minSize != minimumSize {
            window.minSize = minimumSize
        }

        let maximumSize = NSSize(width: 820, height: CGFloat.greatestFiniteMagnitude)
        if window.maxSize != maximumSize {
            window.maxSize = maximumSize
        }

        let compactWidth: CGFloat = 780
        if window.frame.width > maximumSize.width {
            var compactFrame = window.frame
            compactFrame.origin.x += (compactFrame.width - compactWidth) / 2
            compactFrame.size.width = compactWidth
            window.setFrame(compactFrame, display: true)
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

private extension NSRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }
}
