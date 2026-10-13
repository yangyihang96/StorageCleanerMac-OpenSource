import SwiftUI

enum FirstLaunchOnboardingPolicy {
    static let completionDefaultsKey = "firstLaunch.accessGuideCompleted.v1"

    static func shouldPresent(isCompleted: Bool, isApplicationHost: Bool) -> Bool {
        !isCompleted && isApplicationHost
    }
}

struct FirstLaunchOnboardingView: View {
    @ObservedObject var store: ScanStore
    @ObservedObject private var fanControl: FanControlCoordinator

    let finish: () -> Void

    @State private var isRequestingNotifications = false
    @State private var notificationsAuthorized = false
    @State private var didCheckNotifications = false
    @State private var isPreparingHelper = false

    init(store: ScanStore, finish: @escaping () -> Void) {
        self.store = store
        self.finish = finish
        _fanControl = ObservedObject(wrappedValue: .shared)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: AppDesignTokens.Spacing.medium) {
                    diskAccessCard
                    helperCard
                    notificationCard
                }
                .padding(AppDesignTokens.Layout.pagePadding)
            }

            Divider()

            HStack(spacing: AppDesignTokens.Spacing.medium) {
                Spacer()

                Button(L10n.text("暂不设置", "Not Now")) {
                    finish()
                }
                .appButtonChrome(.secondary)

                Button {
                    finish()
                } label: {
                    Text(L10n.text("完成", "Done"))
                }
                .appButtonChrome(.primary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, AppDesignTokens.Layout.pagePadding)
            .padding(.vertical, AppDesignTokens.Spacing.large)
        }
        .frame(width: 680, height: 610)
        .background(AppDesignTokens.Palette.contentBackground)
        .task {
            notificationsAuthorized = await ApplicationUpdateNotificationService.isAuthorized()
            didCheckNotifications = true
            fanControl.refreshStatus()
            await fanControl.refreshConnection()
        }
    }

    private var header: some View {
        HStack(spacing: AppDesignTokens.Spacing.large) {
            VStack(alignment: .leading, spacing: AppDesignTokens.Layout.textRegularSpacing) {
                Text(L10n.text("先把权限一次说明白", "Set Up Access Clearly"))
                    .font(AppDesignTokens.Typography.pageTitle)

                Text(L10n.text(
                    "每一步由你确认，不保存管理员密码。",
                    "You confirm every step; administrator passwords are never stored."
                ))
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(AppDesignTokens.Layout.pagePadding)
        .background(
            LinearGradient(
                colors: [
                    AppDesignTokens.Palette.accent.opacity(0.12),
                    AppDesignTokens.Palette.contentBackground,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var diskAccessCard: some View {
        PermissionSetupCard(
            title: L10n.text("扫描访问", "Scan Access"),
            requirement: L10n.text("必需", "Required"),
            status: diskAccessStatus,
            statusTint: diskAccessTint,
            detail: L10n.text(
                "可只选择桌面、文稿、下载等文件夹。",
                "You can choose only folders such as Desktop, Documents, and Downloads."
            ),
            guide: L10n.text(
                "系统设置 → 隐私与安全性 → 完全磁盘访问权限",
                "System Settings → Privacy & Security → Full Disk Access"
            )
        ) {
            Button {
                CleanupService.openFullDiskAccessSettings()
            } label: {
                Text(L10n.text("打开系统设置", "Open System Settings"))
            }
            .appButtonChrome(.primary)

            Button {
                store.requestRequiredFolderAccess()
            } label: {
                Text(L10n.text("只选择文件夹", "Choose Folders Only"))
            }
            .appButtonChrome(.secondary)

            Button {
                store.refreshScanReadiness(showCompletionMessage: true)
            } label: {
                Text(
                    store.isCheckingScanReadiness ? L10n.text("检查中", "Checking") : L10n.text("重新检查", "Check Again")
                )
            }
            .appButtonChrome(.secondary)
            .disabled(store.isCheckingScanReadiness)
        }
    }

    private var helperCard: some View {
        PermissionSetupCard(
            title: L10n.text("系统控制组件", "System Control Helper"),
            requirement: L10n.text("按功能需要", "As Needed"),
            status: fanControl.helperStatus.title,
            statusTint: fanControl.helperStatus == .enabled
                ? AppDesignTokens.Palette.success
                : AppDesignTokens.Palette.warning,
            detail: PermissionSafetyDisclosure.onboardingHelper.text,
            guide: L10n.text(
                "系统设置 → 通用 → 登录项与扩展",
                "System Settings → General → Login Items & Extensions"
            )
        ) {
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
            .appButtonChrome(.primary)
            .disabled(isPreparingHelper || fanControl.helperStatus == .enabled)
        }
    }

    private var notificationCard: some View {
        PermissionSetupCard(
            title: L10n.text("完成通知", "Completion Notifications"),
            requirement: L10n.text("可选", "Optional"),
            status: notificationStatus,
            statusTint: notificationsAuthorized
                ? AppDesignTokens.Palette.success
                : AppDesignTokens.Palette.secondaryText,
            detail: L10n.text(
                "仅发送本地通知，不上传扫描结果。",
                "Local notifications only; scan results are not uploaded."
            ),
            guide: L10n.text(
                "系统设置 → 通知 → 存储清理助手",
                "System Settings → Notifications → Storage Cleaner"
            )
        ) {
            Button {
                isRequestingNotifications = true
                Task { @MainActor in
                    notificationsAuthorized = await ApplicationUpdateNotificationService.requestAuthorization()
                    didCheckNotifications = true
                    isRequestingNotifications = false
                }
            } label: {
                Text(
                    isRequestingNotifications
                        ? L10n.text("等待系统确认", "Waiting for Confirmation")
                        : L10n.text("允许通知", "Allow Notifications")
                )
            }
            .appButtonChrome(.secondary)
            .disabled(isRequestingNotifications || notificationsAuthorized)
        }
    }

    private var diskAccessStatus: String {
        if store.isCheckingScanReadiness { return L10n.text("检查中", "Checking") }
        guard let summary = store.scanReadinessSummary else {
            return L10n.text("尚未检查", "Not Checked")
        }
        if summary.isFullDiskAccessVerified { return L10n.text("已授权", "Granted") }
        if summary.blockedCount == 0 { return L10n.text("所选位置可读取", "Selected Locations Readable") }
        return L10n.text("有 \(summary.blockedCount) 处受限", "\(summary.blockedCount) Location(s) Limited")
    }

    private var diskAccessTint: Color {
        guard let summary = store.scanReadinessSummary else {
            return AppDesignTokens.Palette.secondaryText
        }
        return summary.isFullDiskAccessVerified || summary.blockedCount == 0
            ? AppDesignTokens.Palette.success
            : AppDesignTokens.Palette.warning
    }

    private var notificationStatus: String {
        guard didCheckNotifications else { return L10n.text("检查中", "Checking") }
        return notificationsAuthorized ? L10n.text("已允许", "Allowed") : L10n.text("未允许", "Not Allowed")
    }
}

enum PermissionSafetyDisclosure: CaseIterable, Equatable, Sendable {
    case settingsHelper
    case onboardingHelper
    case unneededAccess

    var chinese: String {
        switch self {
        case .settingsHelper:
            "用于风扇、电源模式与系统级启动项；只接受白名单命令，不保存管理员密码。"
        case .onboardingHelper:
            "用于风扇、电源模式与系统级启动项；白名单操作，管理员授权一次，不保存管理员密码。"
        case .unneededAccess:
            "无需辅助功能、屏幕录制、相机、麦克风、定位或自动化权限。"
        }
    }

    var english: String {
        switch self {
        case .settingsHelper:
            "For fans, power modes and system startup items; only allow-listed commands; administrator passwords are never stored."
        case .onboardingHelper:
            "For fans, power modes and system startup items; only allow-listed operations, one administrator approval; administrator passwords are never stored."
        case .unneededAccess:
            "No Accessibility, Screen Recording, Camera, Microphone, Location or Automation permissions are required."
        }
    }

    var text: String { L10n.text(chinese, english) }
}

struct PermissionSetupCard<Actions: View>: View {
    let title: String
    let requirement: String
    let status: String
    let statusTint: Color
    let detail: String
    let guide: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    permissionTitle.fixedSize()
                    Spacer(minLength: 8)
                    permissionStatus.fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    permissionTitle
                    permissionStatus
                }
            }

            Text(detail)
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(guide)
                .font(AppDesignTokens.Typography.caption)
                .foregroundStyle(.tertiary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppDesignTokens.Spacing.small) { actions.fixedSize() }
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) { actions }
            }
            .controlSize(.regular)
            .padding(.top, AppDesignTokens.Spacing.compact)
        }
        .padding(AppDesignTokens.Layout.sectionPadding)
        .background(
            RoundedRectangle(cornerRadius: AppDesignTokens.Layout.cardRadius, style: .continuous)
                .fill(AppDesignTokens.Palette.secondaryBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppDesignTokens.Layout.cardRadius, style: .continuous)
                .strokeBorder(AppDesignTokens.Palette.separator, lineWidth: 0.5)
        }
    }

    private var permissionTitle: some View {
        HStack(spacing: 8) {
            Text(title).font(AppDesignTokens.Typography.inlineTitle)
            Text(requirement).font(AppDesignTokens.Typography.compactLabel)
                .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }

    private var permissionStatus: some View {
        Text(status)
            .font(AppDesignTokens.Typography.compactLabel)
            .foregroundStyle(statusTint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(statusTint.opacity(0.1), in: Capsule())
    }

}
