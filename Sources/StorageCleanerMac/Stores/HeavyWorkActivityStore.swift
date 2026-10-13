import Foundation

enum HeavyWorkNavigationDestination: Equatable, Sendable {
    case review(ReviewFilter)
    case networkTest
}

@MainActor
final class HeavyWorkActivityStore: ObservableObject {
    @Published private(set) var activeOwner: HeavyWorkCoordinator.Owner?
    @Published private(set) var conflictMessage: String?
    @Published private(set) var navigationDestination: HeavyWorkNavigationDestination?

    private let coordinator: HeavyWorkCoordinator
    private var observationTask: Task<Void, Never>?
    private var ownerRevision: UInt64 = 0

    init(coordinator: HeavyWorkCoordinator) {
        self.coordinator = coordinator
        observationTask = Task { [weak self, coordinator] in
            let states = await coordinator.ownerStates()
            for await state in states {
                guard !Task.isCancelled else { return }
                self?.apply(state: state, acceptsEqualRevision: false)
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    func refresh() async {
        apply(state: await coordinator.ownerState, acceptsEqualRevision: true)
    }

    func reportConflict(activeOwner: HeavyWorkCoordinator.Owner) {
        apply(owner: activeOwner)
        // The busy error may reach the main actor after that lease released.
        // Reconcile once with the authoritative actor, even if its completion
        // event was already consumed before the conflict was reported.
        Task { [weak self, coordinator] in
            let state = await coordinator.ownerState
            self?.apply(state: state, acceptsEqualRevision: true)
        }
    }

    private func apply(state: HeavyWorkCoordinator.OwnerState, acceptsEqualRevision: Bool) {
        // A page refresh can return after a newer lease event has been applied.
        // The initial idle revision is already represented by this store, so
        // it must not overwrite a conflict reported while registration awaits.
        guard state.revision > ownerRevision ||
            (acceptsEqualRevision && state.revision == ownerRevision) else { return }
        ownerRevision = state.revision
        apply(owner: state.owner)
    }

    private func apply(owner: HeavyWorkCoordinator.Owner?) {
        activeOwner = owner
        if let owner {
            navigationDestination = Self.navigationDestination(for: owner)
        } else {
            navigationDestination = nil
        }

        guard let owner else {
            conflictMessage = nil
            return
        }

        conflictMessage = Self.conflictMessage(activeOwner: owner)
    }

    nonisolated static func conflictMessage(
        activeOwner: HeavyWorkCoordinator.Owner
    ) -> String {
        L10n.text(
            "正在进行\(title(for: activeOwner))，请等待完成或取消后再试。",
            "\(title(for: activeOwner)) is running. Wait for it to finish or cancel it before trying again."
        )
    }

    static func navigationDestination(
        for owner: HeavyWorkCoordinator.Owner
    ) -> HeavyWorkNavigationDestination {
        switch owner {
        case .mainScan:
            .review(.overview)
        case .largeFilesScan:
            .review(.largeFiles)
        case .duplicateScan:
            .review(.duplicates)
        case .cleanup, .restore, .emptyTrash:
            .review(.green)
        case .memoryOptimization:
            .review(.memory)
        case .appUpdates:
            .review(.updater)
        case .networkTest:
            .networkTest
        case .benchmark:
            .review(.performance)
        case .cloudLocalCopy:
            .review(.largeFiles)
        }
    }

    nonisolated private static func title(
        for owner: HeavyWorkCoordinator.Owner
    ) -> String {
        switch owner {
        case .mainScan:
            L10n.text("智能扫描", "Smart Scan")
        case .largeFilesScan:
            L10n.text("大型文件扫描", "large-file scan")
        case .duplicateScan:
            L10n.text("重复文件扫描", "duplicate scan")
        case .cleanup:
            L10n.text("安全清理", "safe cleanup")
        case .restore:
            L10n.text("废纸篓恢复", "Trash restore")
        case .emptyTrash:
            L10n.text("清空废纸篓", "Empty Trash")
        case .memoryOptimization:
            L10n.text("内存优化", "memory optimization")
        case .appUpdates:
            L10n.text("应用更新", "app updates")
        case .networkTest:
            L10n.text("网络测速", "network test")
        case .benchmark:
            L10n.text("Mac 性能测试", "Mac benchmark")
        case .cloudLocalCopy:
            L10n.text("释放本地副本", "local copy release")
        }
    }
}
