import SwiftUI

enum FirstLaunchOnboardingPolicy {
    static let completionDefaultsKey = "firstLaunch.accessGuideCompleted.v1"

    static func shouldPresent(isCompleted: Bool, isApplicationHost: Bool) -> Bool {
        !isCompleted && isApplicationHost
    }
}

struct FirstLaunchOnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ScanStore
    @ObservedObject private var fanControl: FanControlCoordinator

    let finish: () -> Void

    @State private var artworkIsActive = false
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
                Text(L10n.text(
                    "只申请功能真正需要的权限；以后仍可在设置或相关功能中调整。",
                    "Only permissions needed by real features are requested; you can change them later in Settings or the related feature."
                ))
                .font(AppDesignTokens.Typography.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button(L10n.text("暂不设置", "Not Now")) {
                    finish()
                }
                .appButtonChrome(.secondary)

                Button {
                    finish()
                } label: {
                    Label(L10n.text("完成", "Done"), systemImage: "checkmark")
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
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                artworkIsActive = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: AppDesignTokens.Spacing.large) {
            ZStack {
                Circle()
                    .fill(AppDesignTokens.Palette.accent.opacity(0.13))
                    .frame(width: 76, height: 76)
                    .scaleEffect(artworkIsActive ? 1.06 : 0.96)

                Image(systemName: "hand.raised.fingers.spread.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(AppDesignTokens.Palette.accent)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppDesignTokens.Layout.textRegularSpacing) {
                Text(L10n.text("先把权限一次说明白", "Set Up Access Clearly"))
                    .font(AppDesignTokens.Typography.pageTitle)

                Text(L10n.text(
                    "这里集中显示扫描权限、管理员组件和完成通知。每一步都由你确认，应用不会保存管理员密码。",
                    "Scan access, the administrator helper, and completion notifications are shown together. You confirm every step, and the app never stores an administrator password."
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
            systemImage: "externaldrive.badge.checkmark",
            title: L10n.text("扫描访问", "Scan Access"),
            requirement: L10n.text("必需", "Required"),
            status: diskAccessStatus,
            statusTint: diskAccessTint,
            detail: L10n.text(
                "完全磁盘访问用于读取受保护的缓存与应用数据；不想授予时，也可以只选择“桌面”“文稿”“下载”等文件夹。",
                "Full Disk Access reads protected caches and app data. If you prefer not to grant it, choose only folders such as Desktop, Documents, and Downloads."
            ),
            guide: L10n.text(
                "系统设置 → 隐私与安全性 → 完全磁盘访问权限",
                "System Settings → Privacy & Security → Full Disk Access"
            )
        ) {
            Button {
                CleanupService.openFullDiskAccessSettings()
            } label: {
                Label(L10n.text("打开系统设置", "Open System Settings"), systemImage: "arrow.up.forward.app")
            }
            .appButtonChrome(.primary)

            Button {
                store.requestRequiredFolderAccess()
            } label: {
                Label(L10n.text("只选择文件夹", "Choose Folders Only"), systemImage: "folder.badge.plus")
            }
            .appButtonChrome(.secondary)

            Button {
                store.refreshScanReadiness(showCompletionMessage: true)
            } label: {
                Label(
                    store.isCheckingScanReadiness ? L10n.text("检查中", "Checking") : L10n.text("重新检查", "Check Again"),
                    systemImage: "arrow.clockwise"
                )
            }
            .appButtonChrome(.secondary)
            .disabled(store.isCheckingScanReadiness)
        }
    }

    private var helperCard: some View {
        PermissionSetupCard(
            systemImage: "lock.shield",
            title: L10n.text("系统控制组件", "System Control Helper"),
            requirement: L10n.text("按功能需要", "As Needed"),
            status: fanControl.helperStatus.title,
            statusTint: fanControl.helperStatus == .enabled
                ? AppDesignTokens.Palette.success
                : AppDesignTokens.Palette.warning,
            detail: L10n.text(
                "风扇控制、电源模式和需要系统级操作的启动项使用同一个受限辅助程序。安装时只确认一次管理员权限，之后只接受白名单操作。",
                "Fan control, power modes, and system-level startup-item actions share one restricted helper. Administrator approval is requested once, and only allow-listed operations are accepted afterwards."
            ),
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
                Label(
                    isPreparingHelper
                        ? L10n.text("正在准备", "Preparing")
                        : L10n.text("安装并授权", "Install & Approve"),
                    systemImage: "lock.open"
                )
            }
            .appButtonChrome(.primary)
            .disabled(isPreparingHelper || fanControl.helperStatus == .enabled)
        }
    }

    private var notificationCard: some View {
        PermissionSetupCard(
            systemImage: "bell.badge",
            title: L10n.text("完成通知", "Completion Notifications"),
            requirement: L10n.text("可选", "Optional"),
            status: notificationStatus,
            statusTint: notificationsAuthorized
                ? AppDesignTokens.Palette.success
                : AppDesignTokens.Palette.secondaryText,
            detail: L10n.text(
                "应用更新或较长任务结束后发送本地通知；不上传扫描结果，也不会用于营销。",
                "Send a local notification when app updates or longer tasks finish. Scan results are not uploaded and notifications aren't used for marketing."
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
                Label(
                    isRequestingNotifications
                        ? L10n.text("等待系统确认", "Waiting for Confirmation")
                        : L10n.text("允许通知", "Allow Notifications"),
                    systemImage: "bell"
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

struct PermissionSetupCard<Actions: View>: View {
    let systemImage: String
    let title: String
    let requirement: String
    let status: String
    let statusTint: Color
    let detail: String
    let guide: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.medium) {
            AppSymbolIcon(
                systemImage: systemImage,
                role: .pageFeature,
                tint: AppDesignTokens.Palette.accent,
                isDecorative: true
            )

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
        Label(status, systemImage: "circle.fill")
            .font(AppDesignTokens.Typography.compactLabel)
            .foregroundStyle(statusTint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(statusTint.opacity(0.1), in: Capsule())
    }

}
