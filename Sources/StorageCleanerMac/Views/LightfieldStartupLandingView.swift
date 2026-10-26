import SwiftUI

/// Every listed scope is already included by refreshStartupItems. A fixed
/// checked row reports that fact without introducing a cosmetic scan toggle.
struct LightfieldStartupLandingView: View {
    let items: [StartupItemsDomain.Item]
    let canRefresh: Bool
    let onStart: () -> Void
    /// Tests of the D70 landing set `careStudioClassicResults`.
    @Environment(\.careStudioClassicResults) private var usesClassicLanding

    /// D143: the CleanMyMac Performance landing; every scope is still read
    /// by `refreshStartupItems`, so the list states what it covers. The D70
    /// landing stays as the classic view.
    var body: some View {
        if usesClassicLanding {
            classicLanding
        } else {
            CareStudioStartupLanding(items: items, canRefresh: canRefresh, onStart: onStart)
        }
    }

    private var classicLanding: some View {
        FeatureLightfieldPage(module: .startup, phase: .landing,
            title: ReviewFilter.startup.sidebarTitle,
            status: items.isEmpty ? L10n.text("尚未读取启动项", "Startup Items Not Read")
                : L10n.text("尚未重新检查 · 上次 \(ByteFormat.count(items.count)) 项", "Not Rechecked · \(ByteFormat.count(items.count)) Previous Items"),
            safety: L10n.text("只读检查 · 受保护项目仅查看", "Read-only Check · Protected Items Stay Read-only"),
            actionTitle: L10n.text("开始检查", "Start Check"), actionEnabled: canRefresh, action: onStart) {
            FeatureLightfieldOptions(title: L10n.text("扫描范围", "Scan Scope")) {
                LightfieldOptionRow(title: L10n.text("登录时打开", "Open at Login"), icon: .startupLogin, module: .startup,
                    isIncluded: true, metadata: LightfieldPerformancePresentation.startupScopeMetadata(items: items, kinds: [.openAtLogin, .loginItem]))
                LightfieldOptionRow(title: L10n.text("后台任务", "Background Tasks"), icon: .startupBackground, module: .startup,
                    isIncluded: true, metadata: LightfieldPerformancePresentation.startupScopeMetadata(items: items, kinds: [.appBackgroundTask, .embeddedHelper, .privilegedHelper, .managedItem]))
                LightfieldOptionRow(title: L10n.text("启动代理", "Startup Agents"), icon: .startupStartupAgent, module: .startup,
                    isIncluded: true, metadata: LightfieldPerformancePresentation.startupScopeMetadata(items: items,
                        kinds: [.userLaunchAgent, .globalLaunchAgent, .systemLaunchAgent, .launchDaemon, .systemLaunchDaemon, .orphanedItem, .unknown]))
            }
        }
    }
}
