import SwiftUI

/// Production presentation adapters. Stores own task execution; Debug
/// captures inject values into these exact views without starting a provider.
struct MemoryRunningPage: View {
    let isOptimizing: Bool
    let onCancel: (() -> Void)?
    var body: some View {
        FeatureRunningTemplate(module: .memory,
            title: isOptimizing
                ? L10n.text("正在执行并验证内存操作", "Running and verifying memory action")
                : L10n.text("正在读取内存状态", "Reading memory status"),
            trustText: L10n.text("退出应用前确认 · 未保存内容由各应用处理", "Confirm before quitting · Each app handles unsaved work"),
            canCancel: isOptimizing, cancelTitle: L10n.text("取消", "Cancel"), onCancel: onCancel
        ) { EmptyView() } actions: { EmptyView() }
    }
}

struct HealthCheckRunningPage: View {
    let availability: InternalBatteryAvailability
    private var statusSubtitle: String {
        switch availability {
        case .present: L10n.text("读取设备状态与可用的诊断信息", "Reading device status and available diagnostics")
        case .absent: L10n.text("读取磁盘与系统状态 · 无内置电池", "Reading disk and system state · No internal battery")
        case .unknown: L10n.text("读取设备状态 · 内置电池待确认", "Reading device state · Internal battery not confirmed")
        }
    }
    var body: some View {
        FeatureRunningTemplate(module: .healthHub,
            title: L10n.text("正在检查系统健康", "Checking System Health"),
            subtitle: statusSubtitle,
            trustText: L10n.text("只读检查 · 不会更改系统设置", "Read-only check · System settings stay unchanged")
        ) { EmptyView() } actions: { EmptyView() }
    }
}

struct BrowserPrivacyRunningPage: View {
    let onCancel: () -> Void
    var body: some View {
        FeatureRunningTemplate(module: .privacy,
            title: L10n.text("正在读取浏览器记录", "Reading Browser Records"),
            subtitle: L10n.text("正在检查可访问的浏览器与历史记录", "Checking accessible browsers and history"),
            trustText: L10n.text("只读扫描 · 删除前确认", "Read-only scan · Confirm before deletion"),
            canCancel: true, cancelTitle: L10n.text("取消读取", "Cancel Reading"), onCancel: onCancel
        ) { EmptyView() } actions: { EmptyView() }
    }
}

struct EnergyImpactRunningPage: View {
    let phase: EnergyImpactScanPhase?
    var powerMetrics: AnyView? = nil
    var body: some View {
        FeatureRunningTemplate(module: .energy,
            title: L10n.text("正在测量应用能耗", "Measuring App Energy Impact"),
            subtitle: phase.map { $0.shortTitle + " · " + $0.detail }, fraction: phase.map { Double($0.fractionCompleted) },
            trustText: L10n.text("只读测量 · 不会更改电源模式或结束应用", "Read-only measurement · Power modes and apps stay unchanged")
        ) {
            VStack(alignment: .leading, spacing: 16) {
                EnergyImpactScanPipelineView(phase: phase, showsStageDetails: true)
                if let powerMetrics { powerMetrics }
            }
        } actions: { EmptyView() }
    }
}

struct AppUninstallRunningPage: View {
    var body: some View {
        FeatureRunningTemplate(module: .uninstall,
            title: L10n.text("正在读取应用信息", "Reading Application Information"),
            subtitle: L10n.text("正在检查应用大小及可能关联的文件线索", "Checking app sizes and possible related-file leads"),
            trustText: L10n.text("只读扫描 · 卸载前确认", "Read-only scan · Confirm before uninstalling")
        ) { EmptyView() } actions: { EmptyView() }
    }
}

struct PerformanceBenchmarkRunningPage: View {
    let state: BenchmarkV7State
    let isPreflighting: Bool
    let telemetryPoints: [MenuBarTelemetryPoint]
    var elapsedSeconds: TimeInterval? = nil
    var progressFraction: Double? = nil
    let onCancel: () -> Void
    var body: some View {
        let presentation = BenchmarkV7RunProgressView(state: state, isPreflighting: isPreflighting,
            accent: ReviewFilter.performance.moduleTheme.accent, canCancel: false, onCancel: {})
        FeatureRunningTemplate(module: .performance, title: presentation.phaseTitle,
            subtitle: presentation.currentTaskTitle,
            state: state.phase == .cancelling ? .stopping : .running,
            fraction: progressFraction ?? state.progress, currentItem: presentation.currentTaskTitle,
            elapsedSeconds: elapsedSeconds, taskIdentity: state.sessionID?.uuidString,
            trustText: L10n.text("结果默认只保存在本机；全球排行需确认后才上传匿名字段", "Results stay on this Mac; anonymous ranking fields upload only after confirmation"),
            canCancel: BenchmarkV7DashboardView.allowsCancellation(during: state.phase),
            cancelTitle: L10n.text("取消测试", "Cancel Test"), onCancel: onCancel
        ) {
            presentation.stageGrid
            BenchmarkSystemMonitor(telemetryPoints: telemetryPoints,
                accent: ReviewFilter.performance.moduleTheme.accent, availableHeight: 220)
        } actions: { EmptyView() }
    }
}
