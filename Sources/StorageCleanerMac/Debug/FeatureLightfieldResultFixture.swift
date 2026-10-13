#if DEBUG
import SwiftUI

/// D67 round 6: the production result pages (CleanupScanResultsView,
/// AppUninstallerView, ComputerHealthWorkspaceView) on the real stores, fed
/// only with existing inert fixtures. Nothing scans, probes or moves files:
/// the cleanup session is the static Smart Scan fixture, the application list
/// is a fixed value list, and the health store gets a fixed evaluation.
struct FeatureLightfieldProductionResult: View {
    @ObservedObject var store: ScanStore
    let module: ReviewFilter
    let healthStore: ComputerHealthStore
    let networkStore: NetworkSpeedTestStore
    @State private var installed = false
    @StateObject private var privacyStore = BrowserPrivacyPreviewFixture.makeStore()
    var body: some View {
        Group {
            if !installed {
                Color.clear
            } else if module == .green, let session = store.cleanupScanSession {
                CleanupScanResultsView(store: store, filter: .green, session: session)
            } else if module == .uninstall {
                AppUninstallerView(store: store)
            } else if module == .privacy {
                BrowserPrivacyWorkspaceView(browserPrivacyStore: privacyStore)
            } else if module == .updater {
                AppUpdateScanSummaryPage(summary: FeatureLightfieldApplicationsFixture.updateSummary(
                    stress: ProcessInfo.processInfo.arguments.contains(FeatureLightfieldApplicationsFixture.stressArgument)),
                    warnings: [], canManage: true, canRescan: true, onUpdateAll: {}, onManage: {}, onRescan: {})
            } else if module == .healthHub {
                ComputerHealthWorkspaceView(scanStore: store, healthStore: healthStore, networkStore: networkStore)
            } else if module == .startup {
                StartupItemsDashboardView(items: store.startupDomainItems, isLoading: false, progress: nil,
                    coverageAction: AnyView(EmptyView()), onRefresh: {}, onCancel: {})
            } else if module == .memory {
                LightfieldMemoryPage(store: store, snapshot: LightfieldPerformanceFixture.memory,
                    displaySnapshot: LightfieldPerformanceFixture.memory, trendPoints: LightfieldPerformanceFixture.trend,
                    startsWithProcesses: true, showsProcesses: .constant(true))
            } else if module == .energy {
                LightfieldEnergyPage(snapshot: LightfieldPerformanceFixture.energy, searchText: .constant(""),
                    sortMode: .constant(.estimatedEnergy), canRefresh: true, refresh: {}) { EmptyView() }
            }
        }
        .task {
            guard !installed else { return }
            switch module {
            case .green: store.installDebugSmartScanSessionFixture(.results)
            case .uninstall:
                store.installedApps = ProcessInfo.processInfo.arguments.contains(FeatureLightfieldApplicationsFixture.referenceArgument)
                    ? FeatureLightfieldApplicationsFixture.uninstallApps : Self.installedApps
                store.hasScannedInstalledApps = true
            case .privacy:
                privacyStore.startScan()
                await privacyStore.waitUntilIdle()
            case .healthHub:
                healthStore.installDebugPresentationFixture(snapshot: FeatureLightfieldResultFixture.healthSnapshot,
                    evaluation: FeatureLightfieldResultFixture.evaluation)
            case .startup: MainWindowSnapshotPipeline.installStartupItemsFixture(in: store)
            case .memory:
                store.memorySnapshot = LightfieldPerformanceFixture.memory
                store.memoryShowsAllProcesses = true
                store.clearMemoryProcessSelection()
                LightfieldPerformanceFixture.memory.appsByResidentUsage.prefix(2).forEach {
                    store.setMemoryAppUsageSelection($0, isSelected: true)
                }
            default: break
            }
            installed = true
        }
    }
    /// Value-only list entries. The paths are lexical placeholders (no such
    /// bundles exist); the page needs Applications paths to list them as
    /// manageable, and selecting a row never opens the preview.
    static let installedApps: [InstalledAppItem] = (0..<36).map { index in
        InstalledAppItem(id: "lightfield-production-fixture-\(index)", name: "演示应用 \(index + 1)",
            bundleIdentifier: "invalid.example.lightfield.production.\(index)",
            path: "/Applications/Lightfield Fixture \(index + 1).app",
            version: "1.0", build: "1", category: "", appDescription: "", sizeBytes: Int64(36 - index) * 100_000_000,
            source: "fixture", modifiedAt: nil, relatedPaths: [], relatedItems: [], status: .installed)
    }
}

/// Inert values only: no ScanStore, provider, file mutation, home path or
/// operation callback. These use the production shell, summary and row types.
struct FeatureLightfieldResultFixture: View {
    let module: ReviewFilter
    var body: some View {
        FeatureLightfieldPage(module: module, phase: .result, title: module.sidebarTitle,
            status: L10n.text("演示结果 · 未执行任何操作", "Demonstration · No operation performed"),
            safety: safetyLine, actionTitle: actionTitle,
            action: {}) {
            FeatureLightfieldResults(module: module, label: resultLabel,
                value: totalValue, unit: totalUnit, precision: numberPrecision) {
                if module == .healthHub {
                    HealthFactorGrid(evaluation: Self.evaluation, snapshot: Self.healthSnapshot)
                    FeatureLightfieldStatusRow(title: L10n.text("时间机器", "Time Machine"),
                        detail: L10n.text("演示备份 · 1 天前", "Demonstration backup · 1 day ago"),
                        value: L10n.text("已配置", "Configured"), status: .normal)
                } else if module == .uninstall {
                    FeatureLightfieldUninstallList(apps: Self.apps, selectedID: Self.apps[2].id, select: { _ in }, review: { _ in })
                } else {
                    ForEach(Array(Self.cleanupRows.enumerated()), id: \.offset) { index, row in
                        FeatureLightfieldResultRow(title: row.0, detail: row.1, value: row.2) {
                            FeatureLightfieldCheck(selected: index < 3, module: .green)
                                .layoutProbe("lightfield.green.leading")
                        }.lightfieldRowEntrance(index)
                    }
                }
            }
        }
    }
    private var safetyLine: String {
        if module == .healthHub {
            return L10n.text("只读检查 · 不会更改系统设置", "Read-only check · System settings stay unchanged")
        }
        return L10n.text("演示夹具 · 确认前不会移动文件", "Demonstration fixture · No file movement before confirmation")
    }
    private var actionTitle: String {
        switch module {
        case .healthHub: L10n.text("重新检查", "Check Again")
        case .uninstall: L10n.text("卸载所选", "Uninstall Selected")
        default: L10n.text("清理所选", "Clean Selected")
        }
    }
    private var resultLabel: String {
        module == .healthHub ? L10n.text("健康评分", "Health Score") : L10n.text("可审阅总量", "Total to Review")
    }
    private var totalValue: Double {
        switch module {
        case .healthHub: 78
        case .uninstall: 43.2
        default: 12.2
        }
    }
    private var totalUnit: String { module == .healthHub ? "/ 100" : "GB" }
    private var numberPrecision: Int { module == .healthHub ? 0 : 1 }
    static let cleanupRows: [(String, String, String)] = [
        ("系统缓存", "/Fixture/Library/Caches", "8.4 GB"),
        ("日志文件", "/Fixture/Library/Logs", "1.2 GB"),
        ("临时文件", "/Fixture/Temporary", "2.6 GB"),
        ("下载残留", "/Fixture/Downloads · 需要确认", "0.6 GB")]
    static let apps: [InstalledAppItem] = (0..<36).map { index in
        InstalledAppItem(id: "lightfield-fixture-\(index)", name: "演示应用 \(index + 1)",
            bundleIdentifier: "invalid.example.lightfield.\(index)", path: "/Fixture/Applications/Sample-\(index).app",
            version: "1.0", build: "1", category: "", appDescription: "", sizeBytes: Int64(index + 1) * 100_000_000,
            source: "fixture", modifiedAt: nil, relatedPaths: [], relatedItems: [], status: .installed)
    }
    static let evaluation = ComputerHealthEvaluation(score: 78, status: .attention, coverage: 1,
        confidence: HealthConfidence(value: 100, level: .high, modelVersion: "fixture"),
        components: ComputerHealthScoring.scoredFactors.map { factor in
            HealthComponentEvaluation(factor: factor, availability: .available,
                score: factor == .battery ? 78 : 100, evaluatedAt: MiniWindowDemoData.referenceDate, modelVersion: "fixture")
        }, evaluatedAt: MiniWindowDemoData.referenceDate)
    static let healthSnapshot = ComputerHealthSnapshot(generatedAt: MiniWindowDemoData.referenceDate,
        disk: DiskHealthSnapshot(availability: .available, status: .actionRequired, smartStatus: .failing,
            isTRIMEnabled: true, fileSystem: "APFS", summaryText: nil, checkedAt: MiniWindowDemoData.referenceDate),
        capacity: CapacityTrendSnapshot(availability: .available, status: .healthy, totalBytes: 1_000_000_000_000,
            availableBytes: 112_000_000_000, availableForImportantUsageBytes: 112_000_000_000,
            sevenDayDeltaBytes: nil, recordedAt: MiniWindowDemoData.referenceDate),
        backup: TimeMachineSnapshot(availability: .available, status: .healthy, destinationState: .configured,
            isRunning: false, latestLocalSnapshot: nil, latestCompleteBackup: MiniWindowDemoData.referenceDate,
            completeBackupAvailability: .available, summaryText: nil, checkedAt: MiniWindowDemoData.referenceDate),
        stability: StabilitySummary(availability: .available, status: .healthy, crashCount: 0, hangCount: 0,
            panicCount: 0, unexpectedRestartCount: 0, filesExamined: 0, windowStart: nil, generatedAt: MiniWindowDemoData.referenceDate),
        battery: BatteryHealthSnapshot(availability: .available, status: .attention, currentChargePercent: 64,
            isCharging: false, maximumCapacityPercent: 78, cycleCount: 612, condition: .serviceRecommended,
            batteryPowerMode: nil, adapterPowerMode: nil, guidance: BatteryGuidance(kind: .serviceRecommended, detail: nil),
            sampledAt: MiniWindowDemoData.referenceDate),
        // r2-health-security: inert security rows and two journal entries so the
        // D70① result page shows the added rows and "Recent Changes" section,
        // with the same structured evidence sentences real checks produce.
        security: SystemProtectionSnapshot(findings: [
            SystemProtectionFinding(check: .systemIntegrityProtection, state: .enabled, evidence: .systemQuery),
            SystemProtectionFinding(check: .fileVault, state: .enabled, evidence: .systemQuery),
            SystemProtectionFinding(check: .gatekeeper, state: .enabled, evidence: .systemQuery),
            SystemProtectionFinding(check: .firewall, state: .disabled, evidence: .systemQuery)
        ], checkedAt: MiniWindowDemoData.referenceDate),
        recentChanges: [
            ComputerHealthChangeEvent(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                recordedAt: MiniWindowDemoData.referenceDate, check: .firewall, oldState: .enabled, newState: .disabled,
                evidence: .security(.systemQuery)),
            ComputerHealthChangeEvent(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!,
                recordedAt: MiniWindowDemoData.referenceDate.addingTimeInterval(-86_400), check: .disk,
                oldState: .normal, newState: .warning,
                evidence: .status)
        ])
}
#endif
