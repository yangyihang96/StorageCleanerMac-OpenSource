import SwiftUI

/// Keep the approximation through navigation, and expire it when the model
/// leaves its running state, even while another feature is on screen.
struct FeatureRuntimeClockHost: ViewModifier {
    @ObservedObject var store: ScanStore
    @ObservedObject var healthStore: ComputerHealthStore
    @ObservedObject var privacyStore: BrowserPrivacyStore
    @ObservedObject var benchmarkStore: MacBenchmarkStore
    @ObservedObject private var largeFiles: LargeFilesStore
    @ObservedObject private var duplicates: DuplicateFilesStore
    @State private var clock = FeatureRuntimeClock()

    init(store: ScanStore, healthStore: ComputerHealthStore,
         privacyStore: BrowserPrivacyStore, benchmarkStore: MacBenchmarkStore) {
        self.store = store
        self.healthStore = healthStore
        self.privacyStore = privacyStore
        self.benchmarkStore = benchmarkStore
        self.largeFiles = store.largeFilesWorkspace
        self.duplicates = store.duplicateFilesWorkspace
    }

    func body(content: Content) -> some View {
        content.environment(\.featureRuntimeClock, clock)
            .onChange(of: activeModules, initial: true) { _, modules in
                clock.retain(activeModules: modules)
            }
    }

    private var activeModules: Set<ReviewFilter> {
        var modules: Set<ReviewFilter> = []
        if store.scanPresentationState.showsProgressPage {
            modules.formUnion([.overview, .green, .devCaches])
        }
        if healthStore.isRefreshing { modules.insert(.healthHub) }
        if privacyStore.state == .scanning { modules.insert(.privacy) }
        if benchmarkStore.isV7BenchmarkRunning || benchmarkStore.isV7Preflighting { modules.insert(.performance) }
        if store.isLoadingStartupItems { modules.insert(.startup) }
        if store.isLoadingMemory || store.isOptimizingMemory { modules.insert(.memory) }
        if store.isEnergyImpactPageScanActive { modules.insert(.energy) }
        // Migration's application mode deliberately shares the explicit
        // installed-app inventory read, rather than starting another scan.
        if store.isLoadingInstalledApps { modules.formUnion([.uninstall, .migration]) }
        if store.appUpdatePresentationState.phase == .scanning { modules.insert(.updater) }
        if largeFiles.isAnalyzingStorage { modules.insert(.largeFiles) }
        if largeFiles.isScanning { modules.insert(.migration) }
        if duplicates.isScanning || store.isScanningDuplicates { modules.insert(.duplicates) }
        return modules
    }
}
