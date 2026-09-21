import Combine
import SwiftUI

/// Value-only revision. Evaluating this must never enumerate processes or history.
struct MenuBarCardFingerprint: Equatable {
    var dates: [Date?] = []
    var values: [Double] = []
    var flags: [Bool] = []
    var labels: [String] = []
}

enum MenuBarCardDomain {
    case cpu, memory, capacity, diskIO, network, networkInterface
    case sensors, battery, energyProcesses, memoryProcesses, controls, availability
}

@MainActor
final class MenuBarCardModel: ObservableObject {
    private(set) var revision = MenuBarDisplayRevision(sampledAt: nil, version: 0)
    private var fingerprint: MenuBarCardFingerprint
    private let readFingerprint: () -> MenuBarCardFingerprint
    private var subscriptions: [AnyCancellable] = []
    private var updateScheduled = false
    private let traceID: String

    init(sources: [AnyPublisher<Void, Never>], traceID: String = "test", fingerprint: @escaping () -> MenuBarCardFingerprint) {
        self.traceID = traceID
        self.readFingerprint = fingerprint
        self.fingerprint = fingerprint()
        revision = MenuBarDisplayRevision(sampledAt: self.fingerprint.dates.compactMap { $0 }.max(), version: 0)
        subscriptions = sources.map { source in
            source.sink { [weak self] in
                Task { @MainActor in self?.scheduleUpdate() }
            }
        }
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateScheduled = false
            reconcile()
        }
    }

    func reconcile() {
        let next = readFingerprint()
        guard next != fingerprint else { return }
        MenuBarPresentationTrace.begin(traceID)
        objectWillChange.send()
        fingerprint = next
        revision = MenuBarDisplayRevision(sampledAt: next.dates.compactMap { $0 }.max(), version: revision.version &+ 1)
    }
}

private struct MenuBarLiveCard<Content: View>: View {
    @StateObject var model: MenuBarCardModel
    let content: () -> Content
    let page: String
    let traceID: String

    init(page: String, traceID: String, sources: [AnyPublisher<Void, Never>], fingerprint: @escaping () -> MenuBarCardFingerprint,
         @ViewBuilder content: @escaping () -> Content) {
        _model = StateObject(wrappedValue: MenuBarCardModel(sources: sources, traceID: traceID, fingerprint: fingerprint))
        self.content = content
        self.page = page
        self.traceID = traceID
    }

    var body: some View {
        let _ = model.revision
        content()
            .background {
                if MenuBarPresentationTrace.enabled {
                    MenuBarPresentationProbe(key: traceID, revision: model.revision.version)
                }
            }
            .environment(\.menuBarChartContext, MenuBarChartContext(page: page, revision: model.revision))
    }
}

extension MenuBarAdvancedStatusView {
    func liveCard<Content: View>(_ domain: MenuBarCardDomain, @ViewBuilder content: @escaping () -> Content) -> some View {
        MenuBarLiveCard(page: selectedSection.rawValue, traceID: "card:\(selectedSection.rawValue):\(domain)", sources: [store.objectWillChange.eraseToAnyPublisher(),
                                 monitorState.objectWillChange.eraseToAnyPublisher(),
                                 auxiliaryState.objectWillChange.eraseToAnyPublisher(),
                                 computerHealthStore.objectWillChange.eraseToAnyPublisher(),
                                 fanControl.objectWillChange.eraseToAnyPublisher()],
                        fingerprint: { cardFingerprint(domain) }, content: content)
    }

    private func cardFingerprint(_ domain: MenuBarCardDomain) -> MenuBarCardFingerprint {
        var value = MenuBarCardFingerprint(flags: [store.isMenuBarRefreshPaused])
        switch domain {
        case .cpu:
            value.dates = [monitorState.snapshot?.generatedAt, auxiliaryState.processorTelemetryRefreshedAt]
        case .memory:
            value.dates = [store.menuBarDisplayMemorySnapshot?.generatedAt]
        case .capacity:
            value.dates = [auxiliaryState.storageRefreshedAt, computerHealthStore.snapshot?.generatedAt]
        case .diskIO:
            value.dates = [auxiliaryState.nativeDiskIOHistory.last?.date]
        case .network:
            value.dates = [monitorState.snapshot?.generatedAt]
        case .networkInterface:
            value.dates = [auxiliaryState.networkInterfaceRefreshedAt,
                           auxiliaryState.publicNetworkAddressSnapshot?.generatedAt,
                           auxiliaryState.networkProcessSnapshot?.generatedAt]
            value.flags += [auxiliaryState.isRefreshingPublicNetworkAddress, auxiliaryState.isRefreshingNetworkProcesses]
        case .sensors:
            value.dates = [monitorState.snapshot?.generatedAt, auxiliaryState.processorTelemetryRefreshedAt]
        case .battery:
            value.dates = [auxiliaryState.batteryRefreshedAt, computerHealthStore.snapshot?.generatedAt]
            value.labels = [String(describing: auxiliaryState.internalBatteryAvailability)]
        case .energyProcesses:
            value.dates = [store.menuBarPreparedProcesses?.snapshot.generatedAt]
        case .memoryProcesses:
            value.dates = [store.memorySnapshot?.generatedAt]
            value.values = store.selectedMemoryProcessIDs.sorted().map(Double.init)
            value.flags += [store.isLoadingMemory, store.isOptimizingMemory,
                            store.isMemoryBatchQuitConfirmationPresentedInMenuBar,
                            store.memoryOptimizationResult != nil]
            value.labels = [String(describing: store.pendingMemoryProcess?.id)]
            // Prepared groups can arrive independently of the source snapshot.
            value.values.append(Double(store.menuBarPreparedMemoryAppsVersion))
        case .controls:
            value.dates = [computerHealthStore.snapshot?.generatedAt, auxiliaryState.batteryRefreshedAt]
            value.labels = [String(describing: fanControl.selectedMode), fanControl.lastMessage ?? "",
                            String(describing: fanControl.helperStatus),
                            String(describing: computerHealthStore.batteryPowerModes),
                            String(describing: computerHealthStore.batteryPowerModeAdjustmentState),
                            String(describing: computerHealthStore.batterySettingsAdjustmentState)]
            value.values = [fanControl.manualFraction] + fanControl.manualFractionByFan.sorted { $0.key < $1.key }.flatMap { [Double($0.key), $0.value] }
            value.flags += [fanControl.isApplying, fanControl.isSwitchingMode, fanControl.isHelperReachable]
        case .availability:
            value.labels = [String(describing: auxiliaryState.internalBatteryAvailability)]
        }
        switch domain {
        case .cpu, .network, .sensors: value.labels.append(String(monitorState.displayTelemetryVersion))
        case .memory: value.labels.append(String(monitorState.displayMemoryVersion))
        default: break
        }
        return value
    }
}
