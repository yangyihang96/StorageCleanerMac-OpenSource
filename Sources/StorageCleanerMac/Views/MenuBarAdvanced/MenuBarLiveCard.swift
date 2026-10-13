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
    /// A level-three page opened from its level-two page: it draws prepared
    /// histories and live readings of every kind (see `cardFingerprint`).
    case levelThree

    /// Audit key of the live reading a card shows (`fresh.<key>`).
    var freshnessKey: String? {
        switch self {
        case .cpu: "cpu"
        case .memory: "memory"
        case .network: "network"
        case .capacity: "capacity"
        case .sensors: "sensors"
        case .battery: "battery"
        case .diskIO, .networkInterface, .energyProcesses, .memoryProcesses, .controls, .availability,
             .levelThree: nil
        }
    }
}

/// Stable call-site identity distinguishes siblings that consume one metric domain.
/// Data revisions never participate in component identity.
enum MenuBarCardIdentity {
    /// The page of every level-one card, whichever level-two page is open
    /// beside it. Opening or switching a level-two page then keeps the
    /// level-one cards, their samples, prepared charts and registered
    /// anchors instead of rebuilding them for the new page.
    static let overviewPage = PanelSection.overview.rawValue

    /// The page in a card's identity: the page the caller names (every
    /// level-one card names `overviewPage`), otherwise the page that is open.
    static func page(named explicitPage: String?, openSection: PanelSection) -> String {
        explicitPage ?? openSection.rawValue
    }

    static func key(page: String, domain: MenuBarCardDomain, file: String, line: UInt, column: UInt) -> String {
        "card:\(page):\(domain):\(file):\(line):\(column)"
    }
}

@MainActor
final class MenuBarCardModel: ObservableObject {
    private(set) var revision = MenuBarDisplayRevision(sampledAt: nil, version: 0)
    private var fingerprint: MenuBarCardFingerprint
    private let readFingerprint: () -> MenuBarCardFingerprint
    private var subscriptions: [AnyCancellable] = []
    private var updateScheduled = false
    private var isVisible = true
    private var pendingPublicationTime: Double?
    private let traceID: String

    init(sources: [AnyPublisher<Void, Never>], traceID: String = "test", fingerprint: @escaping () -> MenuBarCardFingerprint) {
        self.traceID = traceID
        self.readFingerprint = fingerprint
        self.fingerprint = fingerprint()
        revision = MenuBarDisplayRevision(sampledAt: self.fingerprint.dates.compactMap { $0 }.max(), version: 0)
        subscriptions = sources.map { source in
            source.sink { [weak self] in
                let publishedAt = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in self?.scheduleUpdate(publishedAt: publishedAt) }
            }
        }
    }

    private func scheduleUpdate(publishedAt: Double) {
        guard isVisible else { return }
        guard !updateScheduled else { return }
        updateScheduled = true
        pendingPublicationTime = publishedAt
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateScheduled = false
            MenuBarPresentationTrace.measure("card.reconcile") { reconcile() }
        }
    }

    func reconcile() {
        guard isVisible else { return }
        let publishedAt = pendingPublicationTime
        pendingPublicationTime = nil
        let next = readFingerprint()
        guard next != fingerprint else { return }
        MenuBarPresentationTrace.begin(traceID, publishedAt: publishedAt)
        objectWillChange.send()
        fingerprint = next
        revision = MenuBarDisplayRevision(sampledAt: next.dates.compactMap { $0 }.max(), version: revision.version &+ 1)
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if visible { reconcile() }
        else {
            pendingPublicationTime = nil
            MenuBarPresentationTrace.cancel(traceID)
        }
    }
}

private struct MenuBarLiveCard<Content: View>: View {
    @StateObject var model: MenuBarCardModel
    let content: () -> Content
    let page: String
    let traceID: String
    /// Audit only: `fresh.<domain>` for cards that show live readings.
    let freshnessKey: String?

    init(page: String, traceID: String, freshnessKey: String? = nil,
         sources: [AnyPublisher<Void, Never>], fingerprint: @escaping () -> MenuBarCardFingerprint,
         @ViewBuilder content: @escaping () -> Content) {
        _model = StateObject(wrappedValue: MenuBarCardModel(sources: sources, traceID: traceID, fingerprint: fingerprint))
        self.content = content
        self.page = page
        self.traceID = traceID
        self.freshnessKey = freshnessKey
    }

    var body: some View {
        let _ = model.revision
        content()
            .menuBarPresentationProbe(traceID, revision: model.revision.version)
            // The first draw of a reading sampled after the panel was opened.
            .menuBarPresentationProbe(
                "fresh.\(freshnessKey ?? "")",
                revision: model.revision.version,
                when: freshnessKey != nil && MenuBarPresentationTrace.freshnessThreshold.map {
                    (model.revision.sampledAt ?? .distantPast) > $0
                } == true
            )
            .environment(\.menuBarChartContext, MenuBarChartContext(page: page, revision: model.revision))
            .onAppear { model.setVisible(true) }
            .onDisappear { model.setVisible(false) }
    }
}

extension MenuBarAdvancedStatusView {
    /// `page` defaults to the open page; level-one cards pass
    /// `MenuBarCardIdentity.overviewPage`.
    func liveCard<Content: View>(_ domain: MenuBarCardDomain,
                                 page explicitPage: String? = nil,
                                 file: StaticString = #fileID, line: UInt = #line, column: UInt = #column,
                                 @ViewBuilder content: @escaping () -> Content) -> some View {
        let page = MenuBarCardIdentity.page(named: explicitPage, openSection: selectedSection)
        let identity = MenuBarCardIdentity.key(page: page, domain: domain,
                                               file: String(describing: file), line: line, column: column)
        return MenuBarLiveCard(page: page, traceID: identity,
                               freshnessKey: MenuBarPresentationTrace.enabled ? domain.freshnessKey : nil,
                               sources: [store.objectWillChange.eraseToAnyPublisher(),
                                 monitorState.objectWillChange.eraseToAnyPublisher(),
                                 auxiliaryState.objectWillChange.eraseToAnyPublisher(),
                                 computerHealthStore.objectWillChange.eraseToAnyPublisher(),
                                 fanControl.objectWillChange.eraseToAnyPublisher()],
                        fingerprint: { cardFingerprint(domain) }, content: {
                            content().environment(\.panelStoredSampleDate, storedSampleDate(domain))
                        })
            .id(identity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identity)
    }

    private func storedSampleDate(_ domain: MenuBarCardDomain) -> Date? {
        switch domain {
        case .memory: memorySnapshot?.generatedAt
        case .capacity: auxiliaryState.storageRefreshedAt
        case .diskIO: auxiliaryState.nativeDiskIOHistory.last?.date
        case .sensors: monitorSnapshot?.sensorSampledAt
        case .battery: auxiliaryState.batteryRefreshedAt
        case .networkInterface: auxiliaryState.networkProcessSnapshot?.generatedAt ?? auxiliaryState.networkInterfaceRefreshedAt
        case .energyProcesses: store.menuBarPreparedProcesses?.snapshot.generatedAt
        case .memoryProcesses: store.menuBarPreparedMemoryAppsSampledAt
        default: monitorSnapshot?.generatedAt
        }
    }

    private func cardFingerprint(_ domain: MenuBarCardDomain) -> MenuBarCardFingerprint {
        var value = MenuBarCardFingerprint(flags: [store.isMenuBarRefreshPaused])
        switch domain {
        case .cpu:
            value.dates = [monitorSnapshot?.generatedAt, monitorSnapshot?.gpuSampledAt,
                           auxiliaryState.processorTelemetryRefreshedAt]
        case .memory:
            value.dates = [store.menuBarDisplayMemorySnapshot?.generatedAt]
        case .capacity:
            value.dates = [auxiliaryState.storageRefreshedAt, computerHealthStore.snapshot?.generatedAt]
        case .diskIO:
            value.dates = [auxiliaryState.nativeDiskIOHistory.last?.date]
        case .network:
            value.dates = [monitorSnapshot?.generatedAt]
        case .networkInterface:
            value.dates = [auxiliaryState.networkInterfaceRefreshedAt,
                           auxiliaryState.publicNetworkAddressSnapshot?.generatedAt,
                           auxiliaryState.networkProcessSnapshot?.generatedAt]
            value.flags += [auxiliaryState.isRefreshingPublicNetworkAddress, auxiliaryState.isRefreshingNetworkProcesses]
        case .sensors:
            value.dates = [monitorSnapshot?.sensorSampledAt, monitorSnapshot?.gpuSampledAt,
                           auxiliaryState.processorTelemetryRefreshedAt]
        case .battery:
            value.dates = [auxiliaryState.batteryRefreshedAt, computerHealthStore.snapshot?.generatedAt,
                           auxiliaryState.powerTelemetryRefreshedAt]
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
        case .levelThree:
            // The CPU, memory, sensor, disk, network and power histories and
            // the readings beside them; the prepared windows are added below.
            value.dates = [monitorSnapshot?.generatedAt, store.menuBarDisplayMemorySnapshot?.generatedAt,
                           auxiliaryState.processorTelemetryRefreshedAt, auxiliaryState.nativeDiskIOHistory.last?.date,
                           auxiliaryState.networkInterfaceRefreshedAt, auxiliaryState.batteryRefreshedAt,
                           computerHealthStore.snapshot?.generatedAt, auxiliaryState.powerTelemetryRefreshedAt]
        }
        if let revision = MenuBarCardHistoryRevision.label(
            domain: domain,
            activeHistoryMetric: activeInlineTertiaryRequest?.chartRangeMetric,
            telemetryVersion: monitorState.displayTelemetryVersion,
            memoryVersion: monitorState.displayMemoryVersion
        ) {
            value.labels.append(revision)
        }
        return value
    }
}

/// The prepared history a card's content reads. The card redraws when a new
/// preparation of that history is delivered.
enum MenuBarCardHistoryRevision {
    static func label(
        domain: MenuBarCardDomain,
        activeHistoryMetric: GeekChartRangeMetric?,
        telemetryVersion: UInt64,
        memoryVersion: UInt64
    ) -> String? {
        switch domain {
        case .cpu, .network, .sensors:
            String(telemetryVersion)
        case .memory:
            String(memoryVersion)
        case .levelThree:
            // A newly selected range is drawn as soon as its window is ready.
            "\(telemetryVersion):\(memoryVersion)"
        case .controls:
            // The fan rows of the hardware-control card host the fan history.
            // Without this the open history only redrew when a control value
            // changed, 1-4 s after a newly selected window was ready. The
            // card is not redrawn by every sample while no fan history is open.
            activeHistoryMetric == .fan ? String(telemetryVersion) : nil
        case .capacity, .diskIO, .networkInterface, .battery, .energyProcesses,
             .memoryProcesses, .availability:
            nil
        }
    }
}
