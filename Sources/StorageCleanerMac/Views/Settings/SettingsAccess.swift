import AppKit
import ServiceManagement
import SwiftUI

extension SettingsView {
    var networkPrivacySection: some View {
        LightfieldSettingsSection {
            Toggle(L10n.text("查询公网 IP", "Look up public IP"), isOn: $allowsPublicAddress)
            Text(L10n.text("默认开启；会向 api.ipify.org / api6.ipify.org 发起请求，服务方可见连接 IP，可随时关闭。", "Enabled by default; requests api.ipify.org / api6.ipify.org. Providers can see your connecting IP; you can turn this off at any time."))
                .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
            Toggle(L10n.text("查询 IP 所属国家或地区", "Look up IP country or region"), isOn: $allowsCountryLookup)
                .disabled(!allowsPublicAddress)
            Text(L10n.text("会向 api.country.is 发送公网 IP，须另行同意。", "Sends your public IP to api.country.is with separate consent."))
                .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
            Text(L10n.text("更新、官网检查、测速和排行会联网；公网 IP 可关闭，地区查询须另行同意。",
                "Updates, website checks, speed tests and leaderboards use the network; public-IP lookup can be turned off, and region lookup requires separate consent."))
                .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
            Text(PermissionSafetyDisclosure.unneededAccess.text)
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: { Text(L10n.text("联网与隐私", "Network & Privacy")) }
    }

    var permissionSetupSection: some View {
        VStack(alignment: .leading, spacing: 0) {
#if DEBUG
            if let demo = SettingsAccessDemo.current {
                Text(L10n.text("演示状态 · ", "Demo state · ") + demo.diskTitle)
                    .font(.system(size: 13)).padding(.bottom, 12)
            }
#endif
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("功能权限", "Feature Access"))
                Spacer(minLength: 12)
                Text(L10n.text("在 macOS 中完成授权，返回后重新检查", "Grant access in macOS; status refreshes when you return."))
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(colorScheme).fg2)
                .padding(.bottom, 14)
            FeatureLightfieldHairline()
            SettingsPermissionRow(title: L10n.text("完整磁盘访问", "Full Disk Access"),
                detail: L10n.text("读取受保护目录，完整扫描；未授权仍可扫描手动选择的文件夹。", "Read protected folders for a complete scan. Without access, you can still scan folders you choose manually."),
                status: fullDiskAccessStatus,
                statusKind: fullDiskAccessState == .verified ? .none : (fullDiskAccessState == .unknown ? .systemSettingsOnly : .warning),
                open: openFullDiskAccessSettings, refresh: refreshAccessStatus, isChecking: isCheckingAccess, isGranted: fullDiskAccessState == .verified)
            SettingsPermissionRow(title: L10n.text("文件与文件夹", "Files & Folders"),
                detail: L10n.text("访问所选文件夹和外置盘", "Access selected folders and external volumes"),
                status: L10n.text("由 macOS 按位置管理", "Managed per Location by macOS"), statusKind: .systemSettingsOnly,
                open: openFilesAndFoldersSettings, refresh: refreshAccessStatus, isChecking: isCheckingAccess)
            SettingsPermissionRow(title: L10n.text("应用管理", "App Management"),
                detail: L10n.text("在更新或卸载时按需确认；安装前验证身份与签名。", "Confirmed for updates or removal; identity and signatures checked before installation."),
                status: L10n.text("由 macOS 按需确认", "Confirmed on Demand by macOS"), statusKind: .systemSettingsOnly,
                open: openAppManagementSettings, refresh: refreshAccessStatus, isChecking: isCheckingAccess)
            SettingsPermissionRow(title: L10n.text("完成通知", "Completion Notifications"),
                detail: L10n.text("发送本地完成通知，不上传扫描内容。", "Local completion notifications; scan content is not uploaded."),
                status: notificationsAuthorized ? L10n.text("已允许", "Allowed") : L10n.text("待授权", "Awaiting Access"),
                statusKind: notificationsAuthorized ? .none : .warning,
                open: openNotificationSettings, refresh: refreshAccessStatus, isChecking: isCheckingAccess, isGranted: notificationsAuthorized)
            Button(L10n.text("允许通知", "Allow Notifications")) { requestNotificationAccess() }
                .buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(isRequestingNotifications || notificationsAuthorized)
                .padding(.vertical, 12)
            LightfieldSettingsSection {
                HStack {
                    Text(L10n.text("风扇控制与 Mac mini 模式", "Fan Control & Mac mini Mode"))
                    Spacer(minLength: 12)
                    Text(settingsHelperStatusText).font(.system(size: 13)).foregroundStyle(helperAccessTint)
                }
                Text(PermissionSafetyDisclosure.settingsHelper.text).font(.system(size: 13))
                HStack(spacing: 16) {
                    helperAccessActions
                    if fanControl.helperStatus != .enabled {
                        Button(L10n.text("重新检查", "Check Again")) { refreshAccessStatus() }.disabled(isCheckingAccess)
                    }
                }.buttonStyle(FeatureLightfieldRowButtonStyle())
            } header: { Text(L10n.text("系统助手", "System Helper")) }
            .id(SystemHelperSettingsNavigation.anchor)
            .padding(.top, 20)
            if let permissionNotice { SettingsNoticeView(notice: permissionNotice) }
        }
    }

    var settingsHelperStatusText: String {
#if DEBUG
        if let demo = SettingsAccessDemo.current { return demo.helperTitle }
#endif
        if fanControl.helperStatus == .enabled {
            return fanControl.hasTrustedHelper && fanControl.helperState == .enabled
                ? L10n.text("已批准运行中", "Approved and Connected")
                : L10n.text("已安装 · 尚未连接", "Installed · Not Connected")
        }
        return fanControl.helperStatus.title
    }

    @ViewBuilder
    var helperAccessActions: some View {
#if DEBUG
        if SettingsAccessDemo.current != nil {
            Button(L10n.text("打开登录项", "Open Login Items")) { /* inert screenshot action */ }
            Button(L10n.text("重新检查", "Check Again")) { refreshAccessStatus() }
        } else { realHelperAccessActions }
#else
        realHelperAccessActions
#endif
    }

    @ViewBuilder
    var realHelperAccessActions: some View {
        switch fanControl.helperStatus {
        case .enabled:
            if fanControl.macMiniHelperNeedsUpdate {
                Button(L10n.text("更新并重新授权系统助手", "Update and Authorize System Helper")) {
                    Task { @MainActor in await fanControl.updateMacMiniModeHelper() }
                }
                .buttonStyle(FeatureLightfieldRowButtonStyle())
                .disabled(fanControl.isChangingMacMiniMode || fanControl.isPreparingHelper)
            }
            Button {
                refreshAccessStatus()
            } label: {
                Text(L10n.text("重新检查", "Check Again"))
            }
            .buttonStyle(FeatureLightfieldRowButtonStyle())
        case .requiresApproval:
            Button {
                fanControl.openApprovalSettings()
            } label: {
                Text(L10n.text("打开登录项", "Open Login Items"))
            }
            .buttonStyle(FeatureLightfieldRowButtonStyle())
        case .needsMigration:
            Button {
                isPreparingHelper = true
                Task { @MainActor in
                    await fanControl.migrateLegacyHelper()
                    isPreparingHelper = false
                }
            } label: {
                Text(L10n.text("迁移旧组件", "Migrate Legacy Helper"))
            }
            .buttonStyle(FeatureLightfieldRowButtonStyle())
            .disabled(isPreparingHelper)
        case .notRegistered, .unavailable:
            Button {
                isPreparingHelper = true
                Task { @MainActor in
                    await fanControl.registerHelper()
                    isPreparingHelper = false
                }
            } label: {
                Text(
                    isPreparingHelper
                        ? L10n.text("正在准备", "Preparing")
                        : L10n.text("安装并授权", "Install & Approve")
                )
            }
            .buttonStyle(FeatureLightfieldRowButtonStyle())
            .disabled(isPreparingHelper)
        }
    }

    var fullDiskAccessStatus: String {
#if DEBUG
        if let demo = SettingsAccessDemo.current { return demo.diskTitle }
#endif
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

    var fullDiskAccessTint: Color {
        switch fullDiskAccessState {
        case .verified:
            AppDesignTokens.Palette.success
        case .notVerified:
            AppDesignTokens.Palette.warning
        case .unknown:
            AppDesignTokens.Palette.secondaryText
        }
    }

    var helperAccessTint: Color {
        fanControl.helperStatus == .enabled
            ? FeatureLightfieldPalette.accent(.green)
            : MetadataPillStatus.warning.lightfieldColor(FeatureLightfieldPalette.resolve(colorScheme))
    }

    func refreshAccessStatus() {
#if DEBUG
        if let demo = SettingsAccessDemo.current {
            fullDiskAccessState = demo.diskState
            notificationsAuthorized = demo.notificationsAuthorized
            accessRefreshGate = SettingsAccessRefreshGate()
            return
        }
#endif
        guard accessRefreshGate.request() else { return }
        Task { @MainActor in
            repeat {
                fanControl.refreshStatus()
                async let diskState = Task.detached(priority: .utility) {
                    ScanReadinessService.fullDiskAccessState()
                }.value
                async let notificationState = ApplicationUpdateNotificationService.isAuthorized()
                await fanControl.refreshConnection()
                fullDiskAccessState = await diskState
                notificationsAuthorized = await notificationState
            } while accessRefreshGate.finish()
        }
    }

    func requestNotificationAccess() {
#if DEBUG
        guard SettingsAccessDemo.current == nil else { return }
#endif
        guard !isRequestingNotifications else { return }
        isRequestingNotifications = true
        Task { @MainActor in
            notificationsAuthorized = await ApplicationUpdateNotificationService.requestAuthorization()
            isRequestingNotifications = false
        }
    }

    func openNotificationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        let didOpen = NSWorkspace.shared.open(url)
        permissionNotice = SettingsNotice.openSettingsResult(
            didOpen: didOpen,
            openedText: L10n.text("已打开通知设置。", "Notification settings opened."),
            failureText: L10n.text("无法打开通知设置，请在系统设置中手动进入“通知”。", "Could not open Notifications; open it manually in System Settings."),
            openedSymbol: "bell.fill"
        )
    }

    func openFullDiskAccessSettings() {
        let didOpen = CleanupService.openFullDiskAccessSettings()
        permissionNotice = SettingsNotice.openSettingsResult(
            didOpen: didOpen,
            openedText: L10n.text("已打开完整磁盘访问设置，授权后请重新扫描。", "Full Disk Access settings opened; grant access, then scan again."),
            failureText: L10n.text("无法打开系统设置，请手动进入“隐私与安全性”。", "Could not open System Settings; open Privacy & Security manually."),
            openedSymbol: "externaldrive.fill"
        )
    }

    func openFilesAndFoldersSettings() {
        let didOpen = CleanupService.openFilesAndFoldersSettings()
        permissionNotice = SettingsNotice.openSettingsResult(
            didOpen: didOpen,
            openedText: L10n.text("已打开文件与文件夹设置，授权在系统设置中完成。", "Files & Folders settings opened; access is granted in System Settings."),
            failureText: L10n.text("无法打开系统设置，请手动进入“隐私与安全性”。", "Could not open System Settings; open Privacy & Security manually."),
            openedSymbol: "folder.fill"
        )
    }

    func openAppManagementSettings() {
        let didOpen = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles"
        ).map(NSWorkspace.shared.open) ?? false
        permissionNotice = SettingsNotice.openSettingsResult(
            didOpen: didOpen,
            openedText: L10n.text("已打开应用管理设置；是否允许由你在 macOS 中确认。", "App Management settings opened; confirm access in macOS."),
            failureText: L10n.text("无法打开系统设置，请手动进入“隐私与安全性 → 应用管理”。", "Could not open System Settings; open Privacy & Security → App Management manually."),
            openedSymbol: "shippingbox.fill"
        )
    }

}
