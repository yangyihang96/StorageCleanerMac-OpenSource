import SwiftUI

struct ComputerHealthWorkspaceView: View {
    @ObservedObject var scanStore: ScanStore
    @ObservedObject var healthStore: ComputerHealthStore
    @ObservedObject var networkStore: NetworkSpeedTestStore
    @State private var isStartingCheck = false

    var body: some View {
        if healthStore.evaluation == nil && (isStartingCheck || healthStore.isRefreshing) {
            FeatureRuntimePage(
                module: .healthHub,
                title: L10n.text("正在检查系统健康", "Checking System Health"),
                subtitle: L10n.text("读取设备状态与可用的诊断信息", "Reading device status and available diagnostics"),
                trustText: L10n.text("只读检查 · 不会更改系统设置", "Read-only check · System settings stay unchanged")
            ) { HealthCheckScopeCards() } actions: { EmptyView() }
        } else if healthStore.evaluation == nil {
            healthLanding
        } else {
            VStack(alignment: .leading, spacing: 10) {
                AppPageHeader(title: ReviewFilter.healthHub.title, subtitle: ReviewFilter.healthHub.pageSubtitle,
                              systemImage: ReviewFilter.healthHub.systemImage, isHero: true) { EmptyView() }
                    .padding(.horizontal, 22).padding(.top, 12)
                ComputerHealthView(
                    scanStore: scanStore,
                    healthStore: healthStore,
                    networkStore: networkStore
                )
            }
            .background(AppAppearanceColors.ink.opacity(0.018), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AppAppearanceColors.ink.opacity(0.10)))
            .padding(8)
        }
    }

    private var healthLanding: some View {
        HeroScanPage(
            title: ReviewFilter.healthHub.title,
            subtitle: ReviewFilter.healthHub.pageSubtitle,
            headerSystemImage: ReviewFilter.healthHub.systemImage,
            configurationTitle: L10n.text("检查项目", "Check Items"),
            actionTitle: L10n.text("开始健康检查", "Start Health Check"),
            actionDetail: "",
            actionSystemImage: "waveform.path.ecg",
            status: landingStatus,
            isLoading: isStartingCheck,
            isActionDisabled: isStartingCheck,
            trustText: L10n.text("只读检查", "Read-only check"),
            showsAccessory: true
        ) {
            startHealthCheck()
        } accessory: {
            HealthCheckScopeCards()
        }
    }

    private var landingStatus: ScanStatusPresentation {
        if isStartingCheck {
            return .scanning(L10n.text("正在检查系统健康", "Checking system health"))
        }
        if healthStore.error != nil {
            return .failed(L10n.text("检查未完成，请重试", "The check did not complete; try again"))
        }
        if let checkedAt = healthStore.lastRefreshAt {
            return .idle(L10n.text(
                "上次检查：\(checkedAt.formatted(date: .abbreviated, time: .shortened))",
                "Last check: \(checkedAt.formatted(date: .abbreviated, time: .shortened))"
            ))
        }
        return .idle(L10n.text("尚未检查系统健康", "System health not checked"))
    }

    private func startHealthCheck() {
        guard !isStartingCheck else { return }
        isStartingCheck = true
        Task {
            await healthStore.refresh(force: healthStore.snapshot != nil)
            isStartingCheck = false
        }
    }
}
