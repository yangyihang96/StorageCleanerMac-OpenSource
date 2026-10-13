import Foundation

/// D59：打开面板与用户操作后立即读；仅可见采样使用 30 秒缓存。
enum BatteryChargeLimitReadReason: Equatable, Sendable {
    case panelOpened
    case visibleSampling
    case userOperation
}

enum BatteryChargeLimitAccess {
    static func allowsLiveAccess(isDemo: Bool, isFixture: Bool) -> Bool {
        !isDemo && !isFixture
    }

    static var allowsLiveAccess: Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        let arguments = ProcessInfo.processInfo.arguments
        let fixture = arguments.contains { argument in
            argument.hasPrefix(MiniWindowDemoData.menuBarPanelSnapshotCaptureArgumentPrefix)
                || argument.hasPrefix(MiniWindowDemoData.menuBarPanelSnapshotScenarioArgumentPrefix)
                || argument == MiniWindowDemoData.menuBarPanelSnapshotPowerArgument
                || argument == MiniWindowDemoData.menuBarPanelSnapshotPowerModeArgument
        }
        return allowsLiveAccess(isDemo: MiniWindowDemoData.isEnabled, isFixture: fixture)
#else
        return true
#endif
    }
}

@MainActor
final class BatteryChargeLimitReadCache {
    private let clock: @MainActor () -> TimeInterval
    private let read: @MainActor () -> BatteryChargeLimitState?
    private var lastReadAt: TimeInterval?
    private var cachedState: BatteryChargeLimitState?

    init(
        clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        read: @escaping @MainActor () -> BatteryChargeLimitState?
    ) {
        self.clock = clock
        self.read = read
    }

    func refresh(
        reason: BatteryChargeLimitReadReason,
        hasInternalBattery: Bool,
        isPanelVisible: Bool,
        allowsLiveAccess: Bool
    ) -> BatteryChargeLimitState? {
        guard hasInternalBattery, allowsLiveAccess else {
            cachedState = nil
            lastReadAt = nil
            return nil
        }
        if reason == .visibleSampling {
            guard isPanelVisible else { return cachedState }
            if let lastReadAt, clock() - lastReadAt < 30 { return cachedState }
        }
        lastReadAt = clock()
        cachedState = read()
        return cachedState
    }
}
