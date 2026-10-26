import Foundation

/// D-FP3: one "Merge into clones" action for the duplicates manager: the
/// groups and kept copies go in; a preview (what can merge, what cannot and
/// why, how much space comes back) and the result come out. Merging holds
/// the cleanup lease, as moving files to the Trash does elsewhere.
@MainActor
final class DuplicateCloneMergeAction: ObservableObject {
    enum Phase: Equatable {
        case idle
        case previewing
        case ready
        case merging(CloneMergeProgress)
        case finished
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var preview: CloneMergePreview?
    @Published private(set) var outcome: CloneMergeOutcome?
    @Published private(set) var errorMessage: String?
    @Published private(set) var groups: [DuplicateFileGroup]
    @Published private(set) var keepers: [String: String]

    private let coordinator: HeavyWorkCoordinator
    private let activityStore: HeavyWorkActivityStore?
    private let environment: CloneMergeEnvironment
    private var task: Task<Void, Never>?
    private var generation = 0

    init(groups: [DuplicateFileGroup] = [], keepers: [String: String] = [:], coordinator: HeavyWorkCoordinator,
         activityStore: HeavyWorkActivityStore? = nil, environment: CloneMergeEnvironment = .init()) {
        self.groups = groups
        self.keepers = keepers
        self.coordinator = coordinator
        self.activityStore = activityStore
        self.environment = environment
    }

    deinit { task?.cancel() }

    var isMerging: Bool { if case .merging = phase { true } else { false } }

    var canMerge: Bool { phase == .ready && !(preview?.ready.isEmpty ?? true) }

    /// Only proven duplicates that are not already clones can be offered.
    static func isOffered(for group: DuplicateFileGroup) -> Bool {
        group.matchKind == .logicalContentSHA256 && group.relationship != .apfsClone && group.relationship != .hardLink
            && group.files.count > 1
    }

    func update(groups: [DuplicateFileGroup], keepers: [String: String] = [:]) {
        guard !isMerging else { return }
        generation += 1
        task?.cancel()
        self.groups = groups.filter(Self.isOffered)
        self.keepers = keepers
        preview = nil
        outcome = nil
        errorMessage = nil
        phase = .idle
    }

    func preparePreview() {
        guard !isMerging else { return }
        generation += 1
        let current = generation
        phase = .previewing
        outcome = nil
        errorMessage = nil
        let groups = groups, keepers = keepers, environment = environment
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let preview = DuplicateCloneMergeService.preview(groups: groups, keepers: keepers, environment: environment)
            await MainActor.run {
                guard let self, self.generation == current else { return }
                self.preview = preview
                self.phase = .ready
            }
        }
    }

    func merge() {
        guard canMerge, let preview else { return }
        let groups = groups, environment = environment, coordinator = coordinator, activityStore = activityStore
        phase = .merging(CloneMergeProgress(processed: 0, total: preview.ready.count, currentName: nil))
        errorMessage = nil
        let report: @Sendable (CloneMergeProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.isMerging else { return }
                self.phase = .merging(progress)
            }
        }
        task = Task { [weak self] in
            do {
                let result = try await coordinator.withLease(owner: .cleanup) { lease in
                    await activityStore?.refresh()
                    return await DuplicateCloneMergeService.execute(
                        preview, groups: groups, environment: environment,
                        beforeEachMerge: { try await coordinator.requireValid(lease, owner: .cleanup) },
                        progress: report)
                }
                await activityStore?.refresh()
                guard let self else { return }
                self.outcome = result
                self.phase = .finished
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

    func reset() {
        guard !isMerging else { return }
        generation += 1
        task?.cancel()
        preview = nil
        outcome = nil
        errorMessage = nil
        phase = .idle
    }

    /// Skip reasons with how many copies each holds back, most first.
    var skipSummary: [(reason: CloneMergeSkipReason, count: Int)] {
        let reasons = (preview?.candidates ?? []).compactMap(\.skip)
            + (preview?.refusedGroups.values.map { $0 } ?? [])
        return Dictionary(grouping: reasons, by: { $0 }).map { ($0.key, $0.value.count) }
            .sorted { $0.count == $1.count ? $0.reason.rawValue < $1.reason.rawValue : $0.count > $1.count }
    }
}
