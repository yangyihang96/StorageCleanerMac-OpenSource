import AppKit
import Foundation

/// D-FP3: state of the Chat Files page. Reading takes no lease; moving to
/// the Trash and copying to another drive hold the cleanup lease.
@MainActor
final class ChatFilesStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case needsFullDiskAccess
        case scanning
        case ready
        case working(String)
    }

    enum AgeFilter: String, CaseIterable, Identifiable {
        case all, older, recent
        var id: String { rawValue }
        func title(days: Int) -> String {
            switch self {
            case .all: L10n.text("全部", "All")
            case .older: L10n.text("\(days) 天前", "Older than \(days) days")
            case .recent: L10n.text("\(days) 天内", "Last \(days) days")
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var inventory: ChatFilesInventory?
    @Published private(set) var selection: Set<String> = []
    @Published var kindFilter: ChatMediaKind? = nil
    @Published var ageFilter: AgeFilter = .all
    @Published private(set) var trashOutcome: ChatFilesTrashOutcome?
    @Published private(set) var copyOutcome: ChatFilesCopyOutcome?
    @Published private(set) var volumes: [ExternalStorageVolume] = []
    @Published private(set) var errorMessage: String?

    private let coordinator: HeavyWorkCoordinator
    private let activityStore: HeavyWorkActivityStore?
    private let scanner: ChatFilesScanner
    private let environment: ChatFilesEnvironment
    private let loadVolumes: @Sendable () -> [ExternalStorageVolume]
    private let openURL: @MainActor (URL) -> Void
    private var task: Task<Void, Never>?
    private var generation = 0

    init(coordinator: HeavyWorkCoordinator, activityStore: HeavyWorkActivityStore? = nil,
         scanner: ChatFilesScanner = .init(), environment: ChatFilesEnvironment = .init(),
         loadVolumes: @escaping @Sendable () -> [ExternalStorageVolume] = { ExternalDriveMigrationService.availableVolumes() },
         openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.coordinator = coordinator
        self.activityStore = activityStore
        self.scanner = scanner
        self.environment = environment
        self.loadVolumes = loadVolumes
        self.openURL = openURL
    }

    deinit { task?.cancel() }

    var isBusy: Bool {
        switch phase {
        case .scanning, .working: true
        default: false
        }
    }

    var cutoffDays: Int { scanner.cutoffDays }

    var summary: ChatFilesSummary? { inventory?.summary }

    /// Apps with rows, in list order.
    var apps: [ChatApp] {
        let present = Set(inventory?.rows.map(\.app) ?? [])
        return ChatApp.allCases.filter(present.contains)
    }

    func rows(for app: ChatApp?) -> [ChatFilesRow] {
        (inventory?.rows ?? []).filter { row in
            (app == nil || row.app == app)
                && (kindFilter == nil || row.kind == kindFilter)
                && (ageFilter == .all || (ageFilter == .older) == row.isOlderThanCutoff)
        }
    }

    var selectedRows: [ChatFilesRow] { inventory?.rows.filter { selection.contains($0.id) } ?? [] }

    var selectedBytes: Int64 { selectedRows.reduce(0) { $0 + $1.bytes } }

    /// Rows whose copy on another drive was verified in this visit.
    var verifiedCopies: [String: String] { copyOutcome?.verified ?? [:] }

    // MARK: Scan

    func scan() {
        guard !isBusy else { return }
        guard scanner.access() == .granted else {
            phase = .needsFullDiskAccess
            return
        }
        generation += 1
        let current = generation
        phase = .scanning
        errorMessage = nil
        let scanner = scanner
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let inventory = scanner.scan()
            await MainActor.run {
                guard let self, self.generation == current else { return }
                self.inventory = inventory
                self.selection.formIntersection(Set(inventory.rows.map(\.id)))
                self.phase = .ready
            }
        }
    }

    func cancel() {
        guard phase == .scanning else { return }
        generation += 1
        task?.cancel()
        phase = inventory == nil ? .idle : .ready
    }

    // MARK: Selection

    func isSelected(_ row: ChatFilesRow) -> Bool { selection.contains(row.id) }

    func toggle(_ row: ChatFilesRow) {
        guard !isBusy else { return }
        if selection.contains(row.id) { selection.remove(row.id) } else { selection.insert(row.id) }
    }

    func setSelected(_ rows: [ChatFilesRow], selected: Bool) {
        guard !isBusy else { return }
        if selected { selection.formUnion(rows.map(\.id)) } else { selection.subtract(rows.map(\.id)) }
    }

    func selectionState(for rows: [ChatFilesRow]) -> TriStateSelection {
        guard !rows.isEmpty else { return .unchecked }
        let chosen = rows.filter { selection.contains($0.id) }.count
        return chosen == 0 ? .unchecked : (chosen == rows.count ? .checked : .mixed)
    }

    // MARK: Trash

    func moveSelectedToTrash() {
        let rows = selectedRows
        guard !rows.isEmpty, phase == .ready else { return }
        phase = .working(L10n.text("正在移到废纸篓…", "Moving to the Trash…"))
        errorMessage = nil
        trashOutcome = nil
        let coordinator = coordinator, environment = environment, activityStore = activityStore
        task = Task { [weak self] in
            do {
                let outcome = try await coordinator.withLease(owner: .cleanup) { lease in
                    await activityStore?.refresh()
                    return await ChatFilesTrashService.execute(rows, environment: environment) {
                        try await coordinator.requireValid(lease, owner: .cleanup)
                    }
                }
                await activityStore?.refresh()
                guard let self else { return }
                self.trashOutcome = outcome
                self.selection.subtract(outcome.movedRowIDs)
                self.phase = .ready
                self.scan()
            } catch HeavyWorkCoordinator.Error.busy(let owner) {
                activityStore?.reportConflict(activeOwner: owner)
                self?.errorMessage = HeavyWorkActivityStore.conflictMessage(activeOwner: owner)
                self?.phase = .ready
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.phase = .ready
            }
        }
    }

    // MARK: Copy to another drive

    func refreshVolumes() {
        let load = loadVolumes
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = load()
            await MainActor.run { self?.volumes = found }
        }
    }

    func copySelected(to volume: ExternalStorageVolume) {
        let rows = selectedRows
        guard !rows.isEmpty, phase == .ready else { return }
        phase = .working(L10n.text("正在复制并核对…", "Copying and checking…"))
        errorMessage = nil
        let coordinator = coordinator, environment = environment, activityStore = activityStore
        task = Task { [weak self] in
            do {
                let outcome = try await coordinator.withLease(owner: .cleanup) { _ in
                    await activityStore?.refresh()
                    return await Task.detached(priority: .userInitiated) {
                        ChatFilesCopyService.execute(rows, to: volume.url, availableBytes: volume.availableBytes,
                                                     environment: environment)
                    }.value
                }
                await activityStore?.refresh()
                guard let self else { return }
                var merged = self.copyOutcome ?? ChatFilesCopyOutcome()
                merged.verified.merge(outcome.verified) { $1 }
                merged.failed = outcome.failed
                merged.copiedBytes = outcome.copiedBytes
                self.copyOutcome = merged
                self.phase = .ready
            } catch HeavyWorkCoordinator.Error.busy(let owner) {
                activityStore?.reportConflict(activeOwner: owner)
                self?.errorMessage = HeavyWorkActivityStore.conflictMessage(activeOwner: owner)
                self?.phase = .ready
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.phase = .ready
            }
        }
    }

    /// After a verified copy: choose exactly those originals for the Trash.
    func selectVerifiedOriginals() {
        selection = Set(verifiedCopies.keys).intersection(Set(inventory?.rows.map(\.id) ?? []))
    }

    func dismissNotices() {
        trashOutcome = nil
        errorMessage = nil
    }

    // MARK: Elsewhere

    func reveal(_ row: ChatFilesRow) {
        NSWorkspace.shared.activateFileViewerSelecting(row.folders.prefix(20).map { URL(fileURLWithPath: $0.path) })
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
            openURL(url)
        }
    }

#if DEBUG
    func installPreview(inventory: ChatFilesInventory, selection: Set<String> = [],
                        copyOutcome: ChatFilesCopyOutcome? = nil) {
        generation += 1
        task?.cancel()
        self.inventory = inventory
        self.selection = selection
        self.copyOutcome = copyOutcome
        phase = .ready
    }
#endif
}
