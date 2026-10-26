import AppKit
import Foundation

/// D-FP1: state of the Extensions manager page. Listing takes no lease (it
/// only reads); moving to the Trash holds the cleanup lease, as the
/// uninstaller does, so it never runs beside a cleanup, restore or scan.
@MainActor
final class ExtensionManagerStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case removing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var inventory: ExtensionInventory?
    @Published private(set) var selection: Set<String> = []
    @Published private(set) var outcome: ExtensionRemovalOutcome?
    @Published private(set) var errorMessage: String?

    private let coordinator: HeavyWorkCoordinator
    private let activityStore: HeavyWorkActivityStore?
    private let scanner: ExtensionInventoryScanner
    private let environment: ExtensionRemovalEnvironment
    private let openURL: @MainActor (URL) -> Void
    private var task: Task<Void, Never>?
    private var generation = 0

    init(
        coordinator: HeavyWorkCoordinator,
        activityStore: HeavyWorkActivityStore? = nil,
        scanner: ExtensionInventoryScanner = .init(),
        environment: ExtensionRemovalEnvironment = .init(),
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.coordinator = coordinator
        self.activityStore = activityStore
        self.scanner = scanner
        self.environment = environment
        self.openURL = openURL
    }

    deinit { task?.cancel() }

    var isBusy: Bool { phase == .scanning || phase == .removing }

    var summary: ExtensionInventorySummary? { inventory?.summary }

    var selectedItems: [ExtensionItem] {
        inventory?.items.filter { selection.contains($0.id) } ?? []
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + max(0, $1.bytes) } }

    func items(of kind: ExtensionKind) -> [ExtensionItem] { inventory?.items(of: kind) ?? [] }

    /// Kinds with at least one row, in list order; app and Safari
    /// extensions are listed even when empty if pluginkit could not be read,
    /// so the page can say so.
    var visibleKinds: [ExtensionKind] {
        guard let inventory else { return [] }
        return ExtensionKind.allCases.filter { kind in
            !inventory.items(of: kind).isEmpty
                || (!inventory.pluginKitAvailable && (kind == .appExtension || kind == .safariExtension))
        }
    }

    // MARK: Scan

    func scan() {
        guard !isBusy else { return }
        generation += 1
        let current = generation
        phase = .scanning
        errorMessage = nil
        let scanner = scanner
        task = Task { [weak self] in
            let inventory = await scanner.scan()
            guard let self, self.generation == current else { return }
            self.inventory = inventory
            // Keep only selections that are still movable rows.
            let movable = Set(inventory.movableItems.map(\.id))
            self.selection.formIntersection(movable)
            self.phase = .ready
        }
    }

    func cancel() {
        guard phase == .scanning else { return }
        generation += 1
        task?.cancel()
        task = nil
        phase = inventory == nil ? .idle : .ready
    }

    // MARK: Selection

    func isSelected(_ item: ExtensionItem) -> Bool { selection.contains(item.id) }

    func canSelect(_ item: ExtensionItem) -> Bool {
        item.management.isMovable && item.identity != nil && !isBusy
    }

    func toggle(_ item: ExtensionItem) {
        guard canSelect(item) else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func setSelected(_ items: [ExtensionItem], selected: Bool) {
        let ids = items.filter(canSelect).map(\.id)
        if selected { selection.formUnion(ids) } else { selection.subtract(ids) }
    }

    /// Bundles macOS no longer loads: removing them changes nothing visible.
    func selectObsolete() {
        setSelected(inventory?.items.filter { $0.obsolescence != nil } ?? [], selected: true)
    }

    func selectionState(for items: [ExtensionItem]) -> TriStateSelection {
        let ids = items.filter { $0.management.isMovable && $0.identity != nil }.map(\.id)
        guard !ids.isEmpty else { return .unchecked }
        let chosen = ids.filter(selection.contains).count
        return chosen == 0 ? .unchecked : (chosen == ids.count ? .checked : .mixed)
    }

    // MARK: Remove

    func removeSelected() {
        let chosen = selectedItems.filter(\.management.isMovable)
        guard !chosen.isEmpty, phase == .ready else { return }
        phase = .removing
        errorMessage = nil
        outcome = nil
        let coordinator = coordinator
        let environment = environment
        let activityStore = activityStore
        task = Task { [weak self] in
            do {
                let result = try await coordinator.withLease(owner: .cleanup) { lease in
                    await activityStore?.refresh()
                    return await ExtensionRemovalService.execute(chosen, environment: environment) {
                        try await coordinator.requireValid(lease, owner: .cleanup)
                    }
                }
                await activityStore?.refresh()
                guard let self else { return }
                self.outcome = result
                self.selection.subtract(result.removed.map(\.path))
                self.phase = .ready
                self.scan()
            } catch HeavyWorkCoordinator.Error.busy(let owner) {
                activityStore?.reportConflict(activeOwner: owner)
                guard let self else { return }
                self.errorMessage = HeavyWorkActivityStore.conflictMessage(activeOwner: owner)
                self.phase = .ready
            } catch {
                guard let self else { return }
                self.errorMessage = error.localizedDescription
                self.phase = .ready
            }
        }
    }

    func dismissOutcome() { outcome = nil }

#if DEBUG
    /// Render reviews and previews: a listed state without reading this Mac.
    func installPreview(inventory: ExtensionInventory, selection: Set<String> = [],
                        outcome: ExtensionRemovalOutcome? = nil) {
        generation += 1
        task?.cancel()
        self.inventory = inventory
        self.selection = selection
        self.outcome = outcome
        phase = .ready
    }
#endif

    func dismissError() { errorMessage = nil }

    // MARK: Elsewhere

    func reveal(_ item: ExtensionItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    /// System Settings › General › Login Items & Extensions.
    func openExtensionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") { openURL(url) }
    }

    func openSecuritySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            openURL(url)
        }
    }
}
