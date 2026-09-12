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

    init(coordinator: HeavyWorkCoordinator) {
        self.coordinator = coordinator
    }

    func refresh() async {
        apply(owner: await coordinator.activeOwner)
    }

    func reportConflict(activeOwner: HeavyWorkCoordinator.Owner) {
        apply(owner: activeOwner)
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

    static func conflictMessage(
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
        }
    }

    private static func title(
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
        }
    }
}
