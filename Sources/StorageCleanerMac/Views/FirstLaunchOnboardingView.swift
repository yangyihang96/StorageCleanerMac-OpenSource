import SwiftUI

enum FirstLaunchOnboardingPolicy {
    static let completionDefaultsKey = "firstLaunch.accessGuideCompleted.v1"

    static func shouldPresent(isCompleted: Bool, isApplicationHost: Bool) -> Bool {
        !isCompleted && isApplicationHost
    }
}

/// D154 batch 3J: CleanMyMac's intro flow on the Smart Scan gradient — a
/// welcome page with the safety promise, the disk access page, then our own
/// page for the optional helper and notifications (CleanMyMac asks for
/// neither). Each page keeps one main picture (D64 keeps main pictures), and
/// each permission keeps its requirement, status, path and actions (D64 #9).
struct FirstLaunchOnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome
        case diskAccess
        case extras
    }

    static let size = CGSize(width: 680, height: 610)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ScanStore
    @ObservedObject private var fanControl: FanControlCoordinator

    let finish: () -> Void

    @State private var step: Step
    @State private var isRequestingNotifications = false
    @State private var notificationsAuthorized = false
    @State private var didCheckNotifications = false
    @State private var isPreparingHelper = false

    init(store: ScanStore, initialStep: Step = .welcome, finish: @escaping () -> Void) {
        self.store = store
        self.finish = finish
        _fanControl = ObservedObject(wrappedValue: .shared)
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CareStudioBackdrop(family: .smartCare, fillsOwnFrame: true)
            page
#if DEBUG
                .layoutProbe("onboarding.page")
#endif
                .id(step)
                .transition(.opacity)
                .padding(.horizontal, 40)
                .padding(.top, 28)
                .padding(.bottom, CareStudioMetrics.actionBand)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .task {
            notificationsAuthorized = await ApplicationUpdateNotificationService.isAuthorized()
            didCheckNotifications = true
            fanControl.refreshStatus()
            await fanControl.refreshConnection()
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: welcomePage
        case .diskAccess: diskAccessPage
        case .extras: extrasPage
        }
    }

    /// CleanMyMac's "Welcome to CleanMyMac" and privacy page in one: the
    /// picture, the welcome and the safety promise.
    private var welcomePage: some View {
        VStack(spacing: 22) {
            CareStudioArt(module: .smartScan, side: 220, art: .onboardWelcome, entrance: true)
            VStack(spacing: 10) {
                Text(L10n.text("欢迎使用\(L10n.productName)", "Welcome to \(L10n.productName)"))
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(CareStudioInk.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.text(
                    "先把权限一次说明白：每一步由你确认，不保存管理员密码。",
                    "Set up access clearly: you confirm every step; administrator passwords are never stored."
                ))
                .font(.system(size: 15))
                .foregroundStyle(CareStudioInk.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 460)
        }
    }

    /// CleanMyMac's Full Disk Access page: the disk and its key until access
    /// is granted, then the tick.
    private var diskAccessPage: some View {
        VStack(spacing: 18) {
            CareStudioArt(module: .smartScan, side: 150,
                          art: isDiskAccessGranted ? .stateSuccess : .onboardDiskAccess, entrance: true)
            diskAccessCard
        }
    }

    private var extrasPage: some View {
        VStack(spacing: 14) {
            Text(L10n.text("按需开启", "Optional Setup"))
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(CareStudioInk.primary)
                .accessibilityAddTraits(.isHeader)
            helperCard
            notificationCard
        }
        .frame(maxWidth: 560)
    }

    /// "Skip for Now" on the left as CleanMyMac's (D222: was "暂不设置" /
    /// "Not Now"), the round button in the middle and the step on the right.
    private var footer: some View {
        ZStack {
            HStack {
                if step != .extras {
                    CareStudioPillButton(title: L10n.text("暂时跳过", "Skip for Now")) {
                        finish()
                    }
#if DEBUG
                    .layoutProbe("onboarding.skip")
#endif
                }
                Spacer(minLength: 0)
                stepDots
            }
            .padding(.horizontal, 24)
            CareStudioActionButton(module: .smartScan, title: primaryTitle) {
                advance()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.bottom, CareStudioMetrics.actionBottomInset)
    }

    /// D222: once Full Disk Access is granted the page offers Begin, as
    /// CleanMyMac's granted page does; it still goes on to the optional setup.
    private var primaryTitle: String {
        switch step {
        case .welcome: L10n.text("开始", "Begin")
        case .diskAccess: isDiskAccessGranted ? L10n.text("开始", "Begin") : L10n.text("继续", "Continue")
        case .extras: L10n.text("完成", "Done")
        }
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                Capsule()
                    .fill(item == step ? CareStudioInk.primary : CareStudioInk.hairline)
                    .frame(width: item == step ? 16 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stepDescription)
#if DEBUG
        .layoutProbe("onboarding.steps")
#endif
    }

    private var stepDescription: String {
        L10n.text("第 \(step.rawValue + 1) 步，共 \(ByteFormat.count(Step.allCases.count)) 步",
                  "Step \(step.rawValue + 1) of \(ByteFormat.count(Step.allCases.count))")
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            finish()
            return
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { step = next }
    }

    private var isDiskAccessGranted: Bool {
        store.scanReadinessSummary?.isFullDiskAccessVerified == true
    }

    private var diskAccessCard: some View {
        PermissionSetupCard(
            presentation: .page,
            // D222: the page says when access is granted (CleanMyMac's granted page).
            title: isDiskAccessGranted ? L10n.text("已授予完全磁盘访问权限", "Full Disk Access Granted")
                : L10n.text("扫描访问", "Scan Access"),
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
            CareStudioPillButton(title: L10n.text("打开系统设置", "Open System Settings"), filled: true) {
                CleanupService.openFullDiskAccessSettings()
            }
            CareStudioPillButton(title: L10n.text("只选择文件夹", "Choose Folders Only")) {
                store.requestRequiredFolderAccess()
            }
            CareStudioPillButton(
                title: store.isCheckingScanReadiness ? L10n.text("检查中", "Checking") : L10n.text("重新检查", "Check Again")
            ) {
                store.refreshScanReadiness(showCompletionMessage: true)
            }
            .disabled(store.isCheckingScanReadiness)
        }
    }

    private var helperCard: some View {
        PermissionSetupCard(
            presentation: .card(.tileSystemControl),
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
            CareStudioPillButton(
                title: isPreparingHelper ? L10n.text("正在准备", "Preparing") : L10n.text("安装并授权", "Install & Approve"),
                filled: true
            ) {
                isPreparingHelper = true
                Task { @MainActor in
                    await fanControl.registerHelper()
                    isPreparingHelper = false
                }
            }
            .disabled(isPreparingHelper || fanControl.helperStatus == .enabled)
        }
    }

    private var notificationCard: some View {
        PermissionSetupCard(
            presentation: .card(.tileNotifications),
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
            CareStudioPillButton(
                title: isRequestingNotifications
                    ? L10n.text("等待系统确认", "Waiting for Confirmation")
                    : L10n.text("允许通知", "Allow Notifications")
            ) {
                isRequestingNotifications = true
                Task { @MainActor in
                    notificationsAuthorized = await ApplicationUpdateNotificationService.requestAuthorization()
                    didCheckNotifications = true
                    isRequestingNotifications = false
                }
            }
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
        return L10n.text("有 \(ByteFormat.count(summary.blockedCount)) 处受限", "\(ByteFormat.count(summary.blockedCount)) Location(s) Limited")
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

/// One permission on the guide's gradient: its name and requirement, status,
/// what it is for, where it lives in System Settings, and its actions.
struct PermissionSetupCard<Actions: View>: View {
    /// D154 batch 3J: the disk access page shows its permission as the page
    /// itself (CleanMyMac's Full Disk Access page); the optional page shows
    /// each as a card with its picture, as CleanMyMac's result cards do.
    enum Presentation {
        case page
        case card(GeneratedArt?)
    }

    var presentation: Presentation = .card(nil)
    let title: String
    let requirement: String
    let status: String
    let statusTint: Color
    let detail: String
    let guide: String
    @ViewBuilder let actions: Actions

    var body: some View {
        switch presentation {
        case .page: pageBody
        case .card(let art): cardBody(art: art)
        }
    }

    private var pageBody: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(CareStudioInk.primary)
                    .accessibilityAddTraits(.isHeader)
                requirementBadge
            }
            statusBadge
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(CareStudioInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            Text(guide)
                .font(.system(size: 12))
                .foregroundStyle(CareStudioInk.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            actionRow
                .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)
    }

    private func cardBody(art: GeneratedArt?) -> some View {
        HStack(alignment: .top, spacing: 16) {
            if let art {
                FeatureLightfieldArtwork(art: art, variant: .header)
                    .frame(width: 56, height: 56)
            }
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        cardTitle.fixedSize()
                        Spacer(minLength: 8)
                        statusBadge.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        cardTitle
                        statusBadge
                    }
                }
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(CareStudioInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(guide)
                    .font(.system(size: 11))
                    .foregroundStyle(CareStudioInk.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                actionRow
                    .padding(.top, 4)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
                .fill(CareStudioInk.panelFill)
                .overlay {
                    RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
                        .strokeBorder(CareStudioInk.hairline, lineWidth: 1)
                }
        }
    }

    private var cardTitle: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CareStudioInk.primary)
            requirementBadge
        }
    }

    private var requirementBadge: some View {
        Text(requirement)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(CareStudioInk.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(CareStudioInk.pillFill, in: Capsule())
    }

    /// The tints are light at night and dark by day, so the status sits on
    /// the gradient's own capsule, as the requirement does.
    private var statusBadge: some View {
        Text(status)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(statusTint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(CareStudioInk.pillFill, in: Capsule())
            .overlay { Capsule().strokeBorder(CareStudioInk.hairline, lineWidth: 1) }
    }

    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actions.fixedSize() }
            VStack(spacing: 8) { actions }
        }
    }
}
