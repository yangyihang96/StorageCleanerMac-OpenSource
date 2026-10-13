import SwiftUI

#if DEBUG
/// Debug-only recording script for the Smart Scan flow (D53 V0, §3.2.3):
/// the real landing page, the real scanning page fed with fixture progress,
/// then the fixture results page and a few selection changes.
///
/// It never starts a scan and never plans or runs a cleanup: the landing's
/// start button is not pressed (demo windows ignore the pointer), the
/// scanning page only receives fixture progress, and the results are the
/// inert `DebugSmartScanSessionFixture`, whose cleanup stays unavailable.
enum DebugSmartScanFlowDemo {
    static let launchArgument = "--debug-smartscan-flow-demo"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }
}

struct DebugSmartScanFlowDemoView: View {
    @ObservedObject var store: ScanStore
    /// The start button morphs into the progress card through this space.
    @Namespace private var flowNamespace
    @State private var stage = 0
    @State private var percent = 0

    var body: some View {
        PageTransitionContainer(key: stage) {
            switch stage {
            case 0:
                SmartCareLandingView(store: store, latestStatus: nil)
            case 1:
                SmartScanScanningPage(
                    progress: DebugScanPresentationScenario.determinate.progress(percentOverride: percent),
                    isFinalizing: percent >= 100,
                    canCancel: true,
                    isCancelling: false,
                    onCancel: {}
                )
            default:
                if let session = store.cleanupScanSession {
                    CleanupScanOverviewView(store: store, session: session)
                }
            }
        }
        .environment(\.smartScanFlowNamespace, flowNamespace)
        .task { await run() }
    }

    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }

    private func run() async {
        // A recording first places the window and starts the recorder.
        guard await pause(WindowMotionDemo.recordsWindowFrame ? 7.0 : 2.4) else { return }
        stage = 1
        for value in stride(from: 0, through: 100, by: 8) {
            guard await pause(0.42) else { return }
            percent = value
        }
        percent = 100
        guard await pause(0.9) else { return }
        store.installDebugSmartScanSessionFixture(.results)
        stage = 2
        guard await pause(2.2), let session = store.cleanupScanSession else { return }
        // Draft selection changes only; the fixture keeps cleanup disabled.
        let candidates = session.candidates.filter(\.isSelectable)
        let unselected = candidates.filter { !store.cleanupSelection.selectedCandidateIDs.contains($0.id) }
        for candidate in unselected.prefix(2) {
            store.setCleanupCandidate(candidate.id, selected: true)
            guard await pause(0.9) else { return }
        }
        if let first = candidates.first {
            store.setCleanupCandidate(first.id, selected: false)
            guard await pause(0.9) else { return }
            store.setCleanupCandidate(first.id, selected: true)
        }
    }
}
#endif
