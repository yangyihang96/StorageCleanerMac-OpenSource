import Foundation
import Network

/// D168: Smart Care's five scans through each module's own entry point,
/// waiting on the state the module publishes. Nothing here changes what a
/// module selects or how it confirms; the update check does not resume a
/// saved update queue, since Smart Scan only reads.
@MainActor
final class LiveSmartCareScanner: SmartCareScanning {
    private weak var store: ScanStore?
    /// The app owns the browser privacy store; the main window hands it over.
    weak var privacy: BrowserPrivacyStore?
    private var stopRequested: Set<SmartCareModule> = []

    init(store: ScanStore) {
        self.store = store
    }

    func scan(_ module: SmartCareModule) async -> SmartCareCardState {
        stopRequested.remove(module)
        guard let store else { return .skipped(Self.unavailable) }
        // D202: what this part finds is Smart Care's, not the module page's.
        store.beginSmartCarePart(module)
        defer { store.endSmartCarePart(module) }
        switch module {
        case .cleanup: return await scanJunk(store)
        case .protection: return await scanBrowsingRecords()
        case .performance: return await scanPerformance(store)
        case .applications: return await checkUpdates(store)
        case .clutter: return await scanDuplicates(store)
        }
    }

    func stop(_ module: SmartCareModule) {
        stopRequested.insert(module)
        guard let store else { return }
        switch module {
        case .cleanup: store.cancelMainScan()
        case .protection: privacy?.cancel()
        case .performance: store.cancelStartupScan()
        case .applications: store.cancelAppUpdateScan()
        case .clutter: store.cancelDuplicateFileScan()
        }
    }

    // MARK: Modules

    /// The Smart Scan junk scan, as before but always both file scopes; it
    /// still writes the scan history the menu bar and the panel read.
    private func scanJunk(_ store: ScanStore) async -> SmartCareCardState {
        store.startSmartCareJunkScan()
        guard store.scanPresentationState.showsProgressPage else { return .skipped(Self.busy) }
        await Self.wait { !store.scanPresentationState.showsProgressPage }
        switch store.scanPresentationState {
        case .cancelled: return .stopped
        case .failed: return .failed(store.errorMessage ?? Self.failed)
        default: return stopRequested.contains(.cleanup) ? .stopped : .done
        }
    }

    private func scanBrowsingRecords() async -> SmartCareCardState {
        guard let privacy else { return .skipped(Self.unavailable) }
        if privacy.state != .scanning { privacy.startScan() }
        await Self.wait { privacy.state != .scanning }
        switch privacy.state {
        case .cancelled: return .stopped
        case .failed: return .failed(Self.failed)
        case .idle: return .skipped(Self.busy)
        case .completed, .partial, .permissionDenied, .scanning:
            return stopRequested.contains(.protection) ? .stopped : .done
        }
    }

    /// Login items and the maintenance probes; both only read.
    private func scanPerformance(_ store: ScanStore) async -> SmartCareCardState {
        let maintenance = ToolboxStores.of(store).maintenance
        maintenance.refresh()
        store.refreshStartupItems()
        await Self.wait { !store.isLoadingStartupItems && !maintenance.isRefreshing }
        if stopRequested.contains(.performance) { return .stopped }
        return store.hasScannedStartupItems || maintenance.hasStatuses ? .done : .skipped(Self.busy)
    }

    /// The updater's check, without resuming a saved update queue and
    /// without installing anything (CleanMyMac shows "No Internet
    /// Connection" when offline).
    private func checkUpdates(_ store: ScanStore) async -> SmartCareCardState {
        guard await Self.isOnline() else {
            return .skipped(L10n.text("没有网络连接", "No internet connection"))
        }
        if stopRequested.contains(.applications) { return .stopped }
        store.checkAppUpdatesForSmartCare()
        guard store.isLoadingAppUpdates else { return .skipped(Self.busy) }
        await Self.wait { !store.isLoadingAppUpdates }
        switch store.appUpdateScanState {
        case .cancelled: return .stopped
        case .failed(let message): return .failed(message)
        default: return stopRequested.contains(.applications) ? .stopped : .done
        }
    }

    private func scanDuplicates(_ store: ScanStore) async -> SmartCareCardState {
        store.scanDuplicateFiles()
        guard store.duplicateFilesWorkspace.isScanning else { return .skipped(Self.busy) }
        await Self.wait { !store.duplicateFilesWorkspace.isScanning }
        return stopRequested.contains(.clutter) ? .stopped : .done
    }

    // MARK: Helpers

    private static let busy = L10n.text("另一项任务正在进行", "Another task is running")
    private static let unavailable = L10n.text("暂时无法读取", "Not available right now")
    private static let failed = L10n.text("读取失败", "Could not be read")

    /// Re-checks five times a second, and only while Smart Care scans.
    private static func wait(until done: @MainActor () -> Bool) async {
        while !done() {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// One reading of the network path; no request is sent.
    static func isOnline() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = SmartCareOnce()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: DispatchQueue(label: "smart-care.path"))
        }
    }
}

/// Lets the first of several callbacks through.
private final class SmartCareOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// D168, batch 3L: Run's two parts through the modules' own flows.
extension LiveSmartCareScanner: SmartCareRunning {
    /// The ticked junk in the Smart Scan groups, through the cleanup plan,
    /// its preflight and its confirmation sheet, as the results page did.
    func clean() async -> SmartCareRunOutcome {
        guard let store, let session = store.cleanupScanSession else { return .cancelled }
        let scope = Set(CareJunkGrouping.summaries(for: session, filter: .overview).flatMap(\.candidates).map(\.id))
        store.requestV2Cleanup(disposition: .trash, candidateIDs: scope)
        await Self.wait { !Self.isCleaning(store.cleanupWorkflowState) }
        switch store.cleanupWorkflowState {
        case .completed:
            if let report = store.lastCleanReport, OperationResultPresentation(report: report).state == .cancelled {
                return .stopped
            }
            return .done
        case .failed: return .failed(store.errorMessage ?? Self.failed)
        default: return .cancelled
        }
    }

    /// The tasks the user confirmed with the maintenance page's question
    /// (recommended ones start ticked); ones that can no longer run are
    /// left out, and nothing ticked since is added.
    func runMaintenance(_ tasks: [SystemMaintenanceTaskID]) async -> SmartCareRunOutcome {
        guard let store else { return .failed(Self.unavailable) }
        let maintenance = ToolboxStores.of(store).maintenance
        guard tasks.contains(where: maintenance.canSelect) else { return .failed(Self.unavailable) }
        maintenance.run(tasks)
        await Self.wait { !maintenance.isRunning }
        if let message = maintenance.errorMessage { return .failed(message) }
        return .done
    }

    /// From building the plan until the cleanup has finished or the sheet was
    /// cancelled.
    private static func isCleaning(_ state: CleanupWorkflowState) -> Bool {
        switch state {
        case .buildingPlan, .preflighting, .awaitingConfirmation, .executing, .cancellingExecution: true
        case .idle, .results, .completed, .failed: false
        }
    }
}

extension SmartCareCoordinator {
    private static let all = NSMapTable<ScanStore, SmartCareCoordinator>.weakToStrongObjects()

    /// One Smart Care per store, so the landing, the pages and a scan that
    /// keeps going while another page is open share the same cards.
    static func of(_ store: ScanStore) -> SmartCareCoordinator {
        if let coordinator = all.object(forKey: store) { return coordinator }
        let live = LiveSmartCareScanner(store: store)
        let coordinator = SmartCareCoordinator(scanner: live, runner: live,
                                               defaults: store.smartCarePreferences)
        coordinator.follow(store, privacy: { [weak live] in live?.privacy })
        all.setObject(coordinator, forKey: store)
        return coordinator
    }

    /// The main window passes the app's browser privacy store.
    func attach(privacy: BrowserPrivacyStore) {
        (scanner as? LiveSmartCareScanner)?.privacy = privacy
    }

    /// D219: a scan started from the reminder card waits for the main window
    /// to have passed the privacy store.
    var hasAttachedPrivacy: Bool {
        (scanner as? LiveSmartCareScanner)?.privacy != nil
    }
}
