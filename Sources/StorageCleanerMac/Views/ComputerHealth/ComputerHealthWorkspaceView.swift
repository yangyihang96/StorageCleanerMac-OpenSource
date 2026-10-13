import SwiftUI

struct ComputerHealthWorkspaceView: View {
    @ObservedObject var scanStore: ScanStore
    @ObservedObject var healthStore: ComputerHealthStore
    @ObservedObject var networkStore: NetworkSpeedTestStore
    @State private var isStartingCheck = false
    @State private var internalBatteryAvailability: InternalBatteryAvailability

    @MainActor
    init(scanStore: ScanStore, healthStore: ComputerHealthStore, networkStore: NetworkSpeedTestStore) {
        self.scanStore = scanStore
        self.healthStore = healthStore
        self.networkStore = networkStore
        _internalBatteryAvailability = State(initialValue: scanStore.menuBarAuxiliaryMonitorState.internalBatteryAvailability)
    }

    var body: some View {
        Group {
            if isStartingCheck || healthStore.isRefreshing {
                HealthCheckRunningPage(availability: internalBatteryAvailability)
            } else if healthStore.evaluation == nil {
                healthLanding
            } else {
                ComputerHealthView(scanStore: scanStore, healthStore: healthStore, networkStore: networkStore)
            }
        }
        .featureFlowTransition(value: isStartingCheck || healthStore.isRefreshing)
        .onReceive(scanStore.menuBarAuxiliaryMonitorState.internalBatteryAvailabilityPublisher) { availability in
            internalBatteryAvailability = availability
        }
    }

    private var healthLanding: some View {
        FeatureLightfieldPage(module: .healthHub, phase: .landing, title: ReviewFilter.healthHub.title,
            status: landingStatus.title,
            safety: L10n.text("只读检查 · 不会更改系统设置", "Read-only check · System settings stay unchanged"),
            actionTitle: L10n.text("开始健康检查", "Start Health Check"),
            actionEnabled: !isStartingCheck, action: startHealthCheck) {
            FeatureLightfieldHealthOptions(availability: internalBatteryAvailability)
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
