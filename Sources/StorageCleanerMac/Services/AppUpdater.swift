import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    private var controller: SPUStandardUpdaterController?
    /// Set by the app at launch. Installing an update takes an app-update
    /// lease from it: the relaunch waits for running heavy work, and no new
    /// heavy work can start before the app exits.
    var heavyWorkCoordinator: HeavyWorkCoordinator?
    private var relaunchWaiter: Task<Void, Never>?
    private var installLease: (coordinator: HeavyWorkCoordinator, lease: HeavyWorkCoordinator.Lease)?
    private let postponedNotice = RelaunchPostponedNotice()

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            // Each signed bundle declares its own feed and verification key.
            // Beta uses appcast-beta.xml; production keeps appcast.xml.
            startingUpdater: true,
            // The delegate only postpones the install relaunch and ends that
            // postponement with the update cycle. Sparkle still filters
            // compatibility, channels, phased rollouts and skipped releases
            // and selects the highest remaining full update by itself.
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    private func releaseInstallLease() {
        guard let installLease else { return }
        self.installLease = nil
        Task { await installLease.coordinator.release(installLease.lease) }
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    /// Installing an update relaunches the app. A cleanup, restore or other
    /// heavy task must not be cut off mid-move, and none may start between
    /// this decision and the exit. The install therefore first takes an
    /// app-update lease, waiting with a notice while heavy work runs, and
    /// holds it until the app exits.
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard let coordinator = heavyWorkCoordinator else { return false }
        relaunchWaiter?.cancel()
        // A cancelled waiter returns without releasing; a new install request
        // must not wait behind the lease of the one it replaces.
        releaseInstallLease()
        relaunchWaiter = Task { [weak self] in
            let lease = await HeavyWorkRelaunchGate.acquireInstallLease(from: coordinator) {
                self?.postponedNotice.show()
            }
            self?.postponedNotice.close()
            guard let lease else { return }
            guard !Task.isCancelled, let self else {
                await coordinator.release(lease)
                return
            }
            installLease = (coordinator, lease)
            installHandler()
            // Safety net: if neither the exit nor the end of the update cycle
            // follows, heavy work must not stay blocked.
            try? await Task.sleep(for: HeavyWorkRelaunchGate.installLeaseTimeout)
            guard !Task.isCancelled else { return }
            releaseInstallLease()
        }
        return true
    }

    /// The update cycle ended without the relaunch, for example because the
    /// installation failed: stop waiting and let heavy work run again.
    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        relaunchWaiter?.cancel()
        relaunchWaiter = nil
        postponedNotice.close()
        releaseInstallLease()
    }
}

enum HeavyWorkRelaunchGate {
    /// How long an install may hold its lease while the app neither exits nor
    /// ends the update cycle, before heavy work is allowed again.
    static let installLeaseTimeout: Duration = .seconds(120)

    /// Takes the app-update lease that keeps new heavy work from starting
    /// until the app exits. While another lease or a cleanup quarantine is
    /// held, calls `whileWaiting` once and waits. Returns nil if the wait is
    /// cancelled first.
    @MainActor
    static func acquireInstallLease(
        from coordinator: HeavyWorkCoordinator,
        pollInterval: Duration = .seconds(1),
        whileWaiting: () -> Void
    ) async -> HeavyWorkCoordinator.Lease? {
        if let lease = try? await coordinator.acquire(owner: .appUpdates) { return lease }
        whileWaiting()
        return await coordinator.acquireWhenIdle(owner: .appUpdates, pollInterval: pollInterval)
    }
}

/// Explains why Sparkle's "Ready to Install" window keeps waiting after
/// "Install and Relaunch". Non-modal, so the running task can still be
/// followed or cancelled; it closes by itself once the install proceeds.
@MainActor
private final class RelaunchPostponedNotice {
    private var panel: NSPanel?

    func show() {
        close()
        let hosting = NSHostingController(rootView: RelaunchPostponedNoticeView { [weak self] in
            self?.close()
        })
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.view.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)
        panel.title = L10n.text("软件更新", "Software Update")
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

private struct RelaunchPostponedNoticeView: View {
    let dismiss: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("更新将在当前任务完成后安装", "The update will install after the current task"))
                .font(.headline)
            Text(L10n.text(
                "当前有任务正在进行，完成后将自动安装并重启。如需立即更新，可先取消该任务。",
                "A task is in progress. When it finishes, the update will install and the app will relaunch automatically. To update now, cancel the task first."
            ))
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.text("好", "OK"), action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
