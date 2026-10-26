import Combine
import Foundation

/// The sole committed configuration owner. Editors work on values, never on this
/// publisher; a single successful apply updates both presentation and demand.
@MainActor
final class GeekDashboardConfigurationStore: ObservableObject {
    static let shared = GeekDashboardConfigurationStore()
    @Published private(set) var configuration: GeekDashboardConfiguration
    @Published private(set) var revision: UInt64 = 0
    private let defaults: UserDefaults
    private let fanControlProvider: @MainActor () -> FanControlCoordinator

    init(
        defaults: UserDefaults = .standard,
        fanControlProvider: @escaping @MainActor () -> FanControlCoordinator = { FanControlCoordinator.shared }
    ) {
        self.fanControlProvider = fanControlProvider
        self.defaults = defaults
        configuration = .stored(in: defaults)
    }

    func apply(_ draft: GeekDashboardConfiguration) throws {
        let normalized = draft.normalized()
        let data = try JSONEncoder().encode(normalized)
        defaults.set(data, forKey: GeekDashboardConfiguration.defaultsKey)
        guard defaults.data(forKey: GeekDashboardConfiguration.defaultsKey) == data else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard normalized != configuration else { return }
        configuration = normalized
        revision &+= 1
    }
}

struct GeekDashboardDraft: Equatable {
    private(set) var original: GeekDashboardConfiguration
    var value: GeekDashboardConfiguration
    var isDirty: Bool { value.normalized() != original }
    init(_ configuration: GeekDashboardConfiguration) { original = configuration; value = configuration }
    mutating func cancel() { value = original }
    mutating func reset() { value = .defaultValue }
    mutating func didApply(_ configuration: GeekDashboardConfiguration) { original = configuration; value = configuration }
}

extension GeekDashboardConfiguration {
    /// Gap indices use the order before removing the dragged module. This covers
    /// both edges and every interior gap without special cases in the view.
    mutating func moveModule(_ module: GeekDashboardModule, toGap gap: Int) {
        guard (0...modules.count).contains(gap), let source = modules.firstIndex(where: { $0.module == module }) else { return }
        let item = modules.remove(at: source)
        modules.insert(item, at: gap > source ? gap - 1 : gap)
    }
}

@MainActor
extension GeekDashboardConfigurationStore {
    enum CommitFailure: LocalizedError {
        case activeControl
        var errorDescription: String? {
            L10n.text("请先完成或取消风扇控制编辑，再隐藏传感器。", "Finish or cancel fan-control edits before hiding Sensors.")
        }
    }
    func applyLive(_ draft: GeekDashboardConfiguration) throws {
        if configuration.modules.contains(where: { $0.module == .sensors && $0.isVisible }),
           !draft.modules.contains(where: { $0.module == .sensors && $0.isVisible }) {
            let fan = fanControlProvider()
            // D152: stored slider values are settings, not edits; only a value
            // not yet written holds the fan controls open (was: any per-fan value
            // the helper had not confirmed).
            guard !fan.isApplying, !fan.isSwitchingMode, !fan.curveStore.hasUnsavedDraftChanges,
                  !fan.hasPendingManualCommit else { throw CommitFailure.activeControl }
        }
        try apply(draft)
    }
}
