import AppKit
import Foundation

/// D-FP2: state of the maintenance tasks page. Reading the statuses takes
/// no lease; running a task holds the cleanup lease so it never overlaps a
/// scan, cleanup or restore, and tasks run one at a time.
@MainActor
final class SystemMaintenanceStore: ObservableObject {
    @Published private(set) var statuses: [SystemMaintenanceTaskID: SystemMaintenanceStatus] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var selection: Set<SystemMaintenanceTaskID> = []
    @Published private(set) var runningTask: SystemMaintenanceTaskID?
    @Published private(set) var results: [SystemMaintenanceTaskID: SystemMaintenanceRunResult] = [:]
    @Published private(set) var errorMessage: String?

    private let coordinator: HeavyWorkCoordinator
    private let activityStore: HeavyWorkActivityStore?
    private let probe: SystemMaintenanceProbe
    private let runners: SystemMaintenanceRunners
    private let openURL: @MainActor (URL) -> Void
    private let copyText: @MainActor (String) -> Void
    private var task: Task<Void, Never>?
    private var generation = 0

    init(
        coordinator: HeavyWorkCoordinator,
        activityStore: HeavyWorkActivityStore? = nil,
        probe: SystemMaintenanceProbe = .init(),
        runners: SystemMaintenanceRunners = .init(),
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        copyText: @escaping @MainActor (String) -> Void = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    ) {
        self.coordinator = coordinator
        self.activityStore = activityStore
        self.probe = probe
        self.runners = runners
        self.openURL = openURL
        self.copyText = copyText
    }

    deinit { task?.cancel() }

    var isRunning: Bool { runningTask != nil }

    var hasStatuses: Bool { !statuses.isEmpty }

    func status(of id: SystemMaintenanceTaskID) -> SystemMaintenanceStatus? { statuses[id] }

    /// For the Performance results tile.
    var summary: SystemMaintenanceSummary {
        SystemMaintenanceSummary(
            runnableCount: statuses.values.filter { $0.mode.isRunnable && $0.blocker == nil }.count,
            recommendedCount: statuses.values.filter(\.isRecommended).count
        )
    }

    // MARK: Reading

    func refresh() {
        guard !isRunning else { return }
        generation += 1
        let current = generation
        isRefreshing = true
        let probe = probe
        task = Task { [weak self] in
            let statuses = await probe.statuses()
            guard let self, self.generation == current else { return }
            self.statuses = statuses
            self.selection = self.selection.filter { self.canSelect($0) }
            // Recommended tasks start ticked, as CleanMyMac's list does.
            if self.selection.isEmpty {
                self.selection = Set(statuses.filter { $0.value.isRecommended && $0.value.blocker == nil }.map(\.key))
            }
            self.isRefreshing = false
        }
    }

    // MARK: Selection

    func canSelect(_ id: SystemMaintenanceTaskID) -> Bool {
        guard let status = statuses[id], !isRunning else { return false }
        return status.mode.isRunnable && status.blocker == nil
    }

    func isSelected(_ id: SystemMaintenanceTaskID) -> Bool { selection.contains(id) }

    func toggle(_ id: SystemMaintenanceTaskID) {
        guard canSelect(id) else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// Tasks to run, in list order.
    var selectedTasks: [SystemMaintenanceTaskID] {
        SystemMaintenanceTaskID.allCases.filter { selection.contains($0) && canSelect($0) }
    }

    /// The recommended tasks that can run now, in list order: what the
    /// Performance tile's Run Tasks offers (report §4 item 13), whatever is
    /// ticked on this page.
    var recommendedTasks: [SystemMaintenanceTaskID] {
        SystemMaintenanceTaskID.allCases.filter { statuses[$0]?.isRecommended == true && canSelect($0) }
    }

    // MARK: Running

    func runSelected() {
        run(selectedTasks)
    }

    /// Runs these tasks in list order, those that can still run. D168: Smart
    /// Care passes the tasks the user confirmed, so a selection changed on
    /// this page meanwhile adds nothing to them.
    func run(_ requested: [SystemMaintenanceTaskID]) {
        let tasks = SystemMaintenanceTaskID.allCases.filter { requested.contains($0) && canSelect($0) }
        guard !tasks.isEmpty, !isRunning else { return }
        errorMessage = nil
        runningTask = tasks.first
        let coordinator = coordinator
        let runners = runners
        let activityStore = activityStore
        task = Task { [weak self] in
            do {
                try await coordinator.withLease(owner: .cleanup) { lease in
                    await activityStore?.refresh()
                    for id in tasks {
                        try await coordinator.requireValid(lease, owner: .cleanup)
                        await MainActor.run { self?.runningTask = id }
                        if let result = await runners.run(id) {
                            await MainActor.run { self?.results[id] = result }
                        }
                    }
                }
                await activityStore?.refresh()
            } catch HeavyWorkCoordinator.Error.busy(let owner) {
                activityStore?.reportConflict(activeOwner: owner)
                self?.errorMessage = HeavyWorkActivityStore.conflictMessage(activeOwner: owner)
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            guard let self else { return }
            self.runningTask = nil
            self.selection.removeAll()
            self.refresh()
        }
    }

    func dismissError() { errorMessage = nil }

    func dismissResult(_ id: SystemMaintenanceTaskID) { results[id] = nil }

    // MARK: Elsewhere

    func open(_ destination: SystemMaintenanceDestination) {
        if let url = destination.url { openURL(url) }
    }

    func copyAdministratorCommand(_ id: SystemMaintenanceTaskID) {
        if let command = id.administratorCommand { copyText(command) }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
            openURL(url)
        }
    }

#if DEBUG
    func installPreview(statuses: [SystemMaintenanceTaskID: SystemMaintenanceStatus],
                        selection: Set<SystemMaintenanceTaskID> = [],
                        results: [SystemMaintenanceTaskID: SystemMaintenanceRunResult] = [:]) {
        generation += 1
        task?.cancel()
        self.statuses = statuses
        self.selection = selection
        self.results = results
        isRefreshing = false
    }
#endif
}
