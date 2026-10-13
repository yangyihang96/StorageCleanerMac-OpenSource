#if DEBUG
import Foundation
import SwiftUI

/// D62 captures use production landing and running views with inert values.
/// The flag requires the existing inert monitor mode; no provider task is
/// started, and primary actions only change this presentation session.
@MainActor
final class FeaturePresentationDemo: ObservableObject {
    enum Phase: String, CaseIterable { case landing, running, result }
    struct Configuration: Equatable {
        let module: ReviewFilter?
        let phase: Phase
    }
    static let argumentPrefix = "--debug-feature-page="
    static let modules: [ReviewFilter] = [.overview, .green, .devCaches, .healthHub, .privacy,
        .performance, .startup, .memory, .energy, .uninstall, .updater, .largeFiles, .migration, .duplicates]

    static func configuration(arguments: [String]) -> Configuration? {
        guard arguments.contains(MiniWindowDemoData.launchArgument) else { return nil }
        let values = arguments.filter { $0.hasPrefix(argumentPrefix) }
        guard values.count == 1 else { return nil }
        let parts = values[0].dropFirst(argumentPrefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let phase = Phase(rawValue: String(parts[1])) else { return nil }
        if parts[0] == "all" { return Configuration(module: nil, phase: phase) }
        guard let module = ReviewFilter(rawValue: String(parts[0])), modules.contains(module) else { return nil }
        guard phase != .result || FeatureLightfield.owns(module) else { return nil }
        return Configuration(module: module, phase: phase)
    }
    static let launchConfiguration = configuration(arguments: ProcessInfo.processInfo.arguments)
    static var isEnabled: Bool { launchConfiguration != nil }
    static let shared = FeaturePresentationDemo()
    static var disablesLayoutAnimations: Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix(MainWindowSnapshotPipeline.launchArgumentPrefix) }
            || ProcessInfo.processInfo.arguments.contains("--debug-feature-disable-layout-animations")
    }
    static func analysisView(arguments: [String]) -> Int {
        if arguments.contains("--debug-feature-analysis-types") { return 1 }
        if arguments.contains("--debug-feature-analysis-largest") { return 2 }
        return 0
    }
    static func duplicateFilter(arguments: [String]) -> DuplicateResultFilter {
        arguments.contains("--debug-feature-similar-photos") ? .similarImage : .all
    }
    @Published var phase: Phase = FeaturePresentationDemo.launchConfiguration?.phase ?? .landing
}

private struct FeaturePresentationFixtureKey: EnvironmentKey {
    static let defaultValue = false
}

private struct FeatureDemoPrimaryActionKey: EnvironmentKey {
    static var defaultValue: (() -> Void)? { nil }
}
extension EnvironmentValues {
    var featurePresentationIsFixture: Bool {
        get { self[FeaturePresentationFixtureKey.self] }
        set { self[FeaturePresentationFixtureKey.self] = newValue }
    }

    var featureDemoPrimaryAction: (() -> Void)? {
        get { self[FeatureDemoPrimaryActionKey.self] }
        set { self[FeatureDemoPrimaryActionKey.self] = newValue }
    }
}

/// The factory is also hosted by native D62 tests, so screenshots and tests
/// exercise the production options and their real titles/defaults.
struct FeaturePresentationDemoView: View {
    @Environment(\.featureDisablesLayoutAnimations) private var disablesLayoutAnimations
    @ObservedObject var session: FeaturePresentationDemo
    @ObservedObject var store: ScanStore
    let module: ReviewFilter
    let healthStore: ComputerHealthStore
    let networkStore: NetworkSpeedTestStore
    @ObservedObject var browserStore: BrowserPrivacyStore
    var isSimilarPhotosOverride: Bool? = nil
    private var similarPhotos: Bool {
        isSimilarPhotosOverride ?? (FeaturePresentationDemo.duplicateFilter(arguments: ProcessInfo.processInfo.arguments) == .similarImage)
    }

    var body: some View {
        Group {
            if module == .performance {
                PerformanceBenchmarkV11DemoPage(phase: session.phase,
                    variant: PerformanceBenchmarkV11DemoPage.argument("variant", fallback: "standard"),
                    initialSection: Int(PerformanceBenchmarkV11DemoPage.argument("section", fallback: "0")) ?? 0,
                    stage: PerformanceBenchmarkV11DemoPage.argument("stage", fallback: "core"))
            } else if session.phase == .result {
                // Screenshots of the result phase use the production pages.
                if [.largeFiles, .migration, .duplicates].contains(module) {
                    FeatureLightfieldFileResultFixture(module: module,
                        isSimilarPhotos: similarPhotos)
                } else {
                    FeatureLightfieldProductionResult(store: store, module: module,
                        healthStore: healthStore, networkStore: networkStore)
                }
            } else if session.phase == .running {
                FeatureDemoRunningFixture(module: module, onCancel: { session.phase = .landing }, isSimilarPhotos: similarPhotos)
                    .environment(\.featureDemoElapsedSeconds, 12)
            } else {
                landing
                    .environment(\.featureDemoPrimaryAction, { session.phase = .running })
            }
        }
        .environment(\.featurePresentationIsFixture, true)
        .environment(\.moduleTheme, module.moduleTheme)
        .environment(\.featureLightfieldModule, FeatureLightfield.owns(module) ? module : nil)
        .featureFlowTransition(value: session.phase)
        .environment(\.featureDisablesLayoutAnimations, disablesLayoutAnimations || FeaturePresentationDemo.disablesLayoutAnimations)
        .allowsHitTesting(false)
        .preferredColorScheme(forcedColorScheme)
        .onAppear {
            // Fixed sample data, without calling the live refresh provider.
            if module == .memory { store.memorySnapshot = LightfieldPerformanceFixture.memory }
        }
    }

    private var forcedColorScheme: ColorScheme? {
        switch MiniWindowDemoData.forcedColorScheme {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    @ViewBuilder var landing: some View {
        switch module {
        case .overview: SmartCareLandingView(store: store, latestStatus: nil)
        case .green, .devCaches: ToolPreparationView(store: store, filter: module)
        case .healthHub: ComputerHealthWorkspaceView(scanStore: store, healthStore: healthStore, networkStore: networkStore)
        case .privacy: BrowserPrivacyWorkspaceView(browserPrivacyStore: browserStore)
        case .performance:
            PerformanceBenchmarkLandingView(canStart: true, onStart: { session.phase = .running }, onShowSaved: {})
        case .startup:
            LightfieldStartupLandingView(items: MainWindowSnapshotPipeline.startupItemsFixture, canRefresh: true,
                onStart: { session.phase = .running })
        case .memory:
            LightfieldMemoryPage(store: store, snapshot: LightfieldPerformanceFixture.memory,
                displaySnapshot: LightfieldPerformanceFixture.memory, trendPoints: LightfieldPerformanceFixture.trend,
                showsProcesses: .constant(false))
        case .energy: EnergyImpactScanLandingView(store: store)
        case .uninstall: AppUninstallScanLandingView(store: store)
        case .updater: AppUpdaterView(store: store)
        case .largeFiles: LargeFilesScanLandingView(store: store, workspace: store.largeFilesWorkspace)
        case .migration: LargeFilesScanLandingView(store: store, workspace: store.largeFilesWorkspace, mode: .migration)
        case .duplicates: DuplicateFilesView(store: store, presentationFilter: similarPhotos ? .similarImage : .all)
        case .utilityHub: EmptyView()
        }
    }

}

/// The same running presentation types are used by the production workspaces.
/// Only published measurements/capabilities are replaced with inert values.
struct FeatureDemoRunningFixture: View {
    let module: ReviewFilter
    let onCancel: () -> Void
    var isSimilarPhotos = false
    private let path = "/Fixture/Presentation/" + String(repeating: "Long Folder/", count: 8) + "sample.dat"

    @ViewBuilder var body: some View {
        switch module {
        case .overview, .green, .devCaches:
            SmartScanScanningPage(progress: scanProgress, module: module, canCancel: true, onCancel: onCancel)
        case .healthHub:
            HealthCheckRunningPage(availability: .present)
        case .privacy:
            BrowserPrivacyRunningPage(onCancel: onCancel)
        case .performance:
            PerformanceBenchmarkV11RunningPage(run: .init(state: MSeriesV11PageFixture.runState, weightedFraction: 0.42, elapsedSeconds: 68),
                telemetry: MSeriesV11PageFixture.telemetry, systemTelemetry: PerformanceBenchmarkV11DemoPage.systemTelemetry, onCancel: onCancel)
        case .startup:
            StartupItemsRunningPage(title: L10n.text("正在读取启动项", "Reading Startup Items"),
                discoveredCount: 128, onCancel: onCancel)
        case .memory:
            MemoryRunningPage(isOptimizing: false, onCancel: nil)
        case .energy:
            EnergyImpactRunningPage(phase: .measuringChanges)
        case .uninstall:
            AppUninstallRunningPage()
        case .updater:
            AppUpdateScanningPage(progress: .init(sessionID: sessionID,
                generatedAt: MiniWindowDemoData.referenceDate, stage: .readingMetadata,
                completedUnitCount: 42, totalUnitCount: 100, currentApplicationID: "fixture.app",
                currentApplicationName: "Fixture Application"), canCancel: true, onCancel: onCancel)
        case .largeFiles, .migration:
            LargeFilesRunningPage(module: module,
                title: module == .migration ? L10n.text("正在扫描可搬移文件", "Scanning Movable Files")
                    : L10n.text("正在分析磁盘空间", "Analyzing Disk Space"),
                fraction: module == .migration ? 0.42 : nil,
                metrics: [.init(title: module == .migration ? L10n.text("已发现", "Items Found") : L10n.text("已读取", "Items Read"), value: "128"),
                    .init(title: module == .migration ? L10n.text("候选大小", "Candidate Size") : L10n.text("已测量大小", "Measured Size"), value: ByteFormat.string(2_362_232_013))],
                currentItem: path,
                trustText: module == .migration
                    ? L10n.text("只读扫描 · 先复制并验证，另行确认后原件才会移到废纸篓", "Read-only scan · Copy and verify first; originals move to Trash only after a separate confirmation")
                    : L10n.text("只读分析 · 不会自动打开访达，也不会删除或修改文件", "Read-only analysis · Never opens Finder or changes files automatically"),
                canCancel: true, onCancel: onCancel)
        case .duplicates:
            let similar = isSimilarPhotos
            DuplicateFilesRunningPage(progress: duplicateProgress, state: .running,
                title: L10n.text("正在确认文件内容", "Verifying File Contents"),
                pageTitle: similar ? L10n.text("相似照片", "Similar Photos") : ReviewFilter.duplicates.sidebarTitle,
                isSimilarPhotos: similar, canCancel: true, onCancel: onCancel, onPauseOrResume: {})
        case .utilityHub: EmptyView()
        }
    }

    private var sessionID: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000062")! }
    private var scanProgress: DiskScanProgress {
        let groups: [CleanupScanProgress.GroupSummary] = [
            .init(id: "fixture.user-cache", title: L10n.text("用户缓存", "User Caches"),
                itemCount: 64, bytes: 1_288_490_189, risk: .safe, state: .scanning),
            .init(id: "fixture.browser", title: L10n.text("浏览器数据", "Browser Data"),
                itemCount: 48, bytes: 858_993_459, risk: .safe, state: .pending),
            .init(id: "fixture.logs", title: L10n.text("日志文件", "Log Files"),
                itemCount: 16, bytes: 214_748_365, risk: .safe, state: .pending)
        ]
        var progress = CleanupScanProgress(phase: .enumerating,
            currentRuleTitle: L10n.text("正在扫描应用缓存", "Scanning app caches"),
            completedRuleCount: 60, totalRuleCount: 100, discoveredItemCount: 128,
            discoveredBytes: 2_362_232_013, groups: groups)
        progress.currentPath = path
        return DiskScanProgress(cleanupProgress: progress)
    }
    private var duplicateProgress: DuplicateFileScanProgress {
        var progress = DuplicateFileScanProgress.initial
        progress.phase = .hashing
        progress.currentPath = path
        progress.scannedDirectories = 12
        progress.scannedFiles = 128
        progress.hashedFiles = 64
        progress.hashedBytes = 2_362_232_013
        return progress
    }
}
#endif
