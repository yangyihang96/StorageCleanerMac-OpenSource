import XCTest
@testable import StorageCleanerMac

final class UnifiedMenuBarPanelTests: XCTestCase {
    func testPanelOffersGeekOnlyAndMigratesEarlierPreferences() throws {
        let suiteName = "UnifiedMenuBarPanelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(PanelDensity.menuBarChoices, [.geek])
        XCTAssertEqual(PanelDensity.defaultValue, .geek)
        XCTAssertEqual(PanelDensity.stored(in: defaults), .geek)
        XCTAssertEqual(defaults.string(forKey: PanelDensity.defaultsKey), "geek")

        for legacyRawValue in ["compact", "advanced"] {
            defaults.set(legacyRawValue, forKey: PanelDensity.defaultsKey)
            XCTAssertEqual(PanelDensity.stored(in: defaults), .geek)
            XCTAssertEqual(defaults.string(forKey: PanelDensity.defaultsKey), "geek")
        }

        XCTAssertEqual(PanelDensity.simple.rawValue, "compact")
        XCTAssertEqual(PanelDensity.complex.rawValue, "advanced")
        XCTAssertFalse(PanelDensity.geek.systemImage.isEmpty)
    }

    @MainActor
    func testAuxiliarySamplerMergesConsumersAndHonorsPauseAndCleanup() async {
        let state = MenuBarAuxiliaryMonitorState(
            diskCounterProvider: { nil },
            powerHistoryURL: nil
        )
        let first = UUID()
        let second = UUID()
        let diskDemand = MenuBarAuxiliaryMonitorDemand(
            needsProcessorTelemetry: false,
            needsDiskIOSampling: true,
            needsNetworkInterface: false,
            needsPublicNetworkAddress: false,
            needsNetworkProcesses: false
        )

        state.registerConsumer(first, demand: diskDemand, paused: false)
        XCTAssertEqual(state.activeConsumerCount, 1)
        XCTAssertTrue(state.isDiskIOSamplingActive)

        state.registerConsumer(second, demand: diskDemand, paused: false)
        XCTAssertEqual(state.activeConsumerCount, 2)
        XCTAssertTrue(state.isDiskIOSamplingActive)

        state.unregisterConsumer(first)
        XCTAssertEqual(state.activeConsumerCount, 1)
        XCTAssertTrue(state.isDiskIOSamplingActive)

        state.setPaused(true)
        await waitUntil { !state.isDiskIOSamplingActive }
        XCTAssertFalse(state.isDiskIOSamplingActive)

        state.setPaused(false)
        XCTAssertTrue(state.isDiskIOSamplingActive)

        state.unregisterConsumer(second)
        XCTAssertEqual(state.activeConsumerCount, 0)
        await waitUntil { !state.isDiskIOSamplingActive && !state.isProcessorRefreshActive }
        XCTAssertFalse(state.isDiskIOSamplingActive)
        XCTAssertFalse(state.isProcessorRefreshActive)
    }

    @MainActor
    func testReopeningPanelReusesFreshAuxiliarySnapshots() async {
        let storageProbe = MenuBarProbeCounter()
        let batteryProbe = MenuBarProbeCounter()
        let state = MenuBarAuxiliaryMonitorState(
            diskCounterProvider: { nil },
            storageVolumeProvider: {
                storageProbe.increment()
                return .empty
            },
            batterySnapshotProvider: {
                batteryProbe.increment()
                return (nil, nil)
            },
            powerHistoryURL: nil
        )
        let demand = MenuBarAuxiliaryMonitorDemand(
            needsProcessorTelemetry: false,
            needsDiskIOSampling: false,
            needsNetworkInterface: false,
            needsPublicNetworkAddress: false,
            needsNetworkProcesses: false,
            needsStorageVolumes: true
        )
        let firstConsumer = UUID()
        state.registerConsumer(firstConsumer, demand: demand, paused: false)
        await waitUntil {
            state.storageRefreshedAt != nil
                && state.batteryRefreshedAt != nil
                && !state.isRefreshingLocalData
        }
        XCTAssertEqual(storageProbe.value, 1)
        XCTAssertEqual(batteryProbe.value, 1)

        state.unregisterConsumer(firstConsumer)
        let secondConsumer = UUID()
        state.registerConsumer(secondConsumer, demand: demand, paused: false)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(storageProbe.value, 1)
        XCTAssertEqual(batteryProbe.value, 1)
        state.unregisterConsumer(secondConsumer)
    }

    @MainActor
    func testSlowVolumeReadDoesNotHoldBatteryUpdatesOrOverwriteNewerReadings() async {
        let volumeGate = DispatchSemaphore(value: 0)
        let batteryProbe = MenuBarProbeCounter()
        let state = MenuBarAuxiliaryMonitorState(
            diskCounterProvider: { nil },
            storageVolumeProvider: {
                _ = volumeGate.wait(timeout: .now() + 5)
                return .empty
            },
            batterySnapshotProvider: {
                batteryProbe.increment()
                return (nil, nil)
            },
            powerHistoryURL: nil
        )
        let consumer = UUID()
        state.registerConsumer(consumer, demand: .init(
            needsProcessorTelemetry: false, needsDiskIOSampling: false,
            needsNetworkInterface: false, needsPublicNetworkAddress: false,
            needsNetworkProcesses: false, needsStorageVolumes: true
        ), paused: false)
        defer {
            volumeGate.signal()
            state.unregisterConsumer(consumer)
        }
        await waitUntil { state.batteryRefreshedAt != nil }
        XCTAssertNil(state.storageRefreshedAt)
        let firstBatteryDate = state.batteryRefreshedAt
        state.requestManualRefresh()
        await waitUntil { state.batteryRefreshedAt != firstBatteryDate }
        XCTAssertEqual(batteryProbe.value, 2)
        XCTAssertNil(state.storageRefreshedAt, "Battery must publish while the volume query is still blocked")
        let latestBatteryDate = state.batteryRefreshedAt
        volumeGate.signal()
        await waitUntil { state.storageRefreshedAt != nil && !state.isRefreshingLocalData }
        XCTAssertEqual(state.batteryRefreshedAt, latestBatteryDate)
    }

    @MainActor
    func testPausedAuxiliaryMonitorDiscardsPendingBatteryRead() async {
        let batteryGate = DispatchSemaphore(value: 0)
        let state = MenuBarAuxiliaryMonitorState(
            diskCounterProvider: { nil },
            batterySnapshotProvider: {
                _ = batteryGate.wait(timeout: .now() + 5)
                return (nil, nil)
            },
            powerHistoryURL: nil
        )
        state.refreshBackgroundBatteryHistory(force: true)
        state.setPaused(true)
        batteryGate.signal()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(state.batteryRefreshedAt)
        XCTAssertFalse(state.isRefreshingLocalData)
    }

    @MainActor
    func testFrequentCapacityRefreshDoesNotRepeatMountedVolumeHealthProbe() async {
        XCTAssertEqual(MenuBarAuxiliaryMonitorState.storageVolumeSamplingInterval, 300)
        let storageProbe = MenuBarProbeCounter()
        let state = MenuBarAuxiliaryMonitorState(
            diskCounterProvider: { nil },
            storageVolumeProvider: {
                storageProbe.increment()
                return .empty
            },
            batterySnapshotProvider: { (nil, nil) },
            powerHistoryURL: nil
        )
        let consumer = UUID()
        let demand = MenuBarAuxiliaryMonitorDemand(
            needsProcessorTelemetry: false,
            needsDiskIOSampling: false,
            needsNetworkInterface: false,
            needsPublicNetworkAddress: false,
            needsNetworkProcesses: false,
            needsStorageVolumes: true
        )
        state.registerConsumer(consumer, demand: demand, paused: false)
        defer { state.unregisterConsumer(consumer) }
        await waitUntil { state.storageRefreshedAt != nil && !state.isRefreshingLocalData }

        state.requestManualRefresh()
        await waitUntil { !state.isRefreshingLocalData }

        XCTAssertEqual(storageProbe.value, 1)
    }

    @MainActor
    func testOverviewCapacityRefreshSkipsMountedVolumeHealthProbe() async {
        let storageProbe = MenuBarProbeCounter()
        let state = MenuBarAuxiliaryMonitorState(
            diskCounterProvider: { nil },
            storageVolumeProvider: {
                storageProbe.increment()
                return .empty
            },
            batterySnapshotProvider: { (nil, nil) },
            powerHistoryURL: nil
        )
        let consumer = UUID()
        state.registerConsumer(
            consumer,
            demand: MenuBarAuxiliaryMonitorDemand(
                needsProcessorTelemetry: false,
                needsDiskIOSampling: false,
                needsNetworkInterface: false,
                needsPublicNetworkAddress: false,
                needsNetworkProcesses: false
            ),
            paused: false
        )
        defer { state.unregisterConsumer(consumer) }
        await waitUntil { state.storageRefreshedAt != nil && !state.isRefreshingLocalData }

        state.requestManualRefresh()
        await waitUntil { !state.isRefreshingLocalData }

        XCTAssertEqual(storageProbe.value, 0)
    }

    @MainActor
    func testBackgroundBatteryHistoryKeepsRealSamplesWhenThePanelIsClosed() async {
        XCTAssertEqual(MenuBarAuxiliaryMonitorState.batteryHistorySamplingInterval, 30)
        let batterySnapshot = BatteryPowerSnapshot(
            chargePercent: 100,
            isCharging: false,
            powerSource: .batteryPower,
            timeToEmptyMinutes: 90,
            timeToFullChargeMinutes: nil
        )
        let state = MenuBarAuxiliaryMonitorState(
            diskCounterProvider: { nil },
            batterySnapshotProvider: { (batterySnapshot, nil) },
            powerHistoryURL: nil
        )

        XCTAssertEqual(state.activeConsumerCount, 0)
        for expectedCount in 1...3 {
            state.refreshBackgroundBatteryHistory(force: true)
            await waitUntil { state.powerHistory.count == expectedCount }
        }
        XCTAssertEqual(state.powerHistory.compactMap(\.chargePercent), [100, 100, 100])
        XCTAssertEqual(state.powerHistory.map(\.isCharging), [false, false, false])
        XCTAssertEqual(
            state.powerHistory.map(\.powerSource),
            [.batteryPower, .batteryPower, .batteryPower]
        )

        state.setPaused(true)
        state.refreshBackgroundBatteryHistory(force: true)
        await Task.yield()
        XCTAssertEqual(state.powerHistory.count, 3)
    }

    @MainActor
    func testBackgroundDiskHistoryKeepsRealSamplesWhenThePanelIsClosed() async {
        XCTAssertEqual(MenuBarAuxiliaryMonitorState.diskIOSamplingInterval, .seconds(2))
        let first = NativeDiskIOCounters(
            date: Date(timeIntervalSinceReferenceDate: 10_000),
            readBytes: 1_000,
            writtenBytes: 2_000,
            readOperations: 10,
            writeOperations: 20,
            driverCount: 1
        )
        let second = NativeDiskIOCounters(
            date: first.date.addingTimeInterval(60),
            readBytes: 7_000,
            writtenBytes: 11_000,
            readOperations: 40,
            writeOperations: 50,
            driverCount: 1
        )
        let provider = DiskCounterProviderSequence([first, second])
        let state = MenuBarAuxiliaryMonitorState(
            diskCounterProvider: { provider.next() },
            powerHistoryURL: nil
        )

        state.refreshBackgroundDiskHistory(force: true)
        await waitUntil { state.nativeDiskIOCounters == first }
        state.refreshBackgroundDiskHistory(force: true)
        await waitUntil { state.nativeDiskIOHistory.count == 1 }
        XCTAssertEqual(state.nativeDiskIOHistory[0].readBytesPerSecond, 100)
        XCTAssertEqual(state.nativeDiskIOHistory[0].writeBytesPerSecond, 150)

        state.setPaused(true)
        state.refreshBackgroundDiskHistory(force: true)
        await Task.yield()
        XCTAssertEqual(state.nativeDiskIOHistory.count, 1)
    }

    func testMenuBarRefreshKeepsClosedPanelMetricHistoryAndPauseStateInSync() throws {
        let source = try sourceText("Sources/StorageCleanerMac/Stores/ScanStore.swift")

        XCTAssertTrue(source.contains("menuBarAuxiliaryMonitorState.activeConsumerCount == 0"))
        XCTAssertTrue(source.contains("menuBarAuxiliaryMonitorState.refreshBackgroundMetricHistory()"))
        XCTAssertTrue(source.contains("menuBarAuxiliaryMonitorState.setPaused(isMenuBarRefreshPaused)"))
    }

    func testNetworkTopologyObservationUsesOneDebouncedDynamicStoreLifecycle() throws {
        let source = try sourceText("Sources/StorageCleanerMac/Support/MenuBarAuxiliaryMonitorState.swift")

        for required in [
            "private func networkTopologyStoreCallback(",
            "nonisolated func scheduleRefresh()",
            "SCDynamicStoreCreate(",
            "networkTopologyStoreCallback,",
            "SCDynamicStoreSetNotificationKeys",
            "State:/Network/Global/IPv4",
            "State:/Network/Global/IPv6",
            "State:/Network/Global/DNS",
            "State:/Network/Service/.*/PPP",
            "State:/Network/Service/.*/IPSec",
            "scheduleNetworkTopologyRefresh()",
            "try await Task.sleep(for: .milliseconds(500))",
            "SCDynamicStoreSetDispatchQueue(networkConfigurationStore, nil)",
            "networkConfigurationStore = nil"
        ] {
            XCTAssertTrue(source.contains(required), required)
        }
        XCTAssertFalse(source.contains("{ _, _, info in"))
    }

    @MainActor
    func testNetworkProcessFailureClearsPriorRatesAndPublishesUnavailable() async {
        let successfulSnapshot = NativeNetworkProcessSnapshot(
            generatedAt: Date(),
            processes: [
                NativeNetworkProcessTransfer(
                    processIdentifier: 123,
                    name: "Browser",
                    iconPath: "",
                    downloadBytesPerSecond: 4_096,
                    uploadBytesPerSecond: 1_024
                )
            ]
        )
        let provider = NetworkProcessProviderSequence([successfulSnapshot, nil])
        let state = MenuBarAuxiliaryMonitorState(
            diskCounterProvider: { nil },
            networkProcessProvider: { provider.snapshot() },
            powerHistoryURL: nil
        )
        let consumer = UUID()
        let demand = MenuBarAuxiliaryMonitorDemand(
            needsProcessorTelemetry: false,
            needsDiskIOSampling: false,
            needsNetworkInterface: false,
            needsPublicNetworkAddress: false,
            needsNetworkProcesses: true
        )

        state.registerConsumer(consumer, demand: demand, paused: false)
        defer { state.unregisterConsumer(consumer) }
        XCTAssertEqual(state.networkProcessSamplingState, .sampling)

        await waitUntil {
            state.networkProcessSamplingState == .available
        }
        XCTAssertEqual(state.networkProcessSnapshot, successfulSnapshot)

        state.requestManualRefresh()
        XCTAssertEqual(state.networkProcessSamplingState, .sampling)

        await waitUntil {
            state.networkProcessSamplingState == .unavailable
        }
        XCTAssertNil(state.networkProcessSnapshot)
        XCTAssertFalse(state.isRefreshingNetworkProcesses)
    }

    @MainActor
    func testPanelSectionsPersistAcrossSettingsAndPanelRecreation() throws {
        let suiteName = "UnifiedMenuBarPanelTests.Sections.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = MenuBarPanelSettingsState(
            initialDensity: .simple,
            defaults: defaults
        )
        XCTAssertEqual(first.selectedSection, .overview)

        first.selectSection(.network)
        first.presentGeekEditor()
        first.dismissGeekEditor()

        XCTAssertEqual(first.selectedSection, .network)

        let reopened = MenuBarPanelSettingsState(
            initialDensity: .geek,
            defaults: defaults
        )
        XCTAssertEqual(reopened.selectedSection, .network)

        defaults.removeObject(forKey: PanelSection.defaultsKey)
        defaults.set("cleanup", forKey: PanelSection.legacySimpleDefaultsKey)
        XCTAssertEqual(PanelSection.stored(in: defaults), .cleanup)
    }

    func testMiniWindowAppearanceUpdatesWithoutReplacingThePanelRoot() throws {
        let root = try sourceText("Sources/StorageCleanerMac/Views/MenuBarStatusPanelRoot.swift")
        let settings = try sourceText("Sources/StorageCleanerMac/Views/SettingsView.swift")

        XCTAssertTrue(root.contains("miniWindowAppearanceRawValue"))
        XCTAssertTrue(root.contains(".id(languageRawValue)"))
        XCTAssertFalse(root.contains(".id(languageRawValue + appearanceRawValue)"))
        XCTAssertTrue(settings.contains("MiniWindowAppearance.allCases"))
        XCTAssertTrue(settings.contains("小窗外观"))
    }

    func testComplexDemandTracksCurrentModuleAndGeekKeepsAttachedOverviewAlive() {
        var geekWithoutDisk = GeekDashboardConfiguration.defaultValue
        geekWithoutDisk.setModule(.disk, isVisible: false)
        var geekWithoutDiskOrNetwork = geekWithoutDisk
        geekWithoutDiskOrNetwork.setModule(.network, isVisible: false)
        var geekWithoutProcessorModules = GeekDashboardConfiguration.defaultValue
        geekWithoutProcessorModules.setModule(.processorGraphics, isVisible: false)
        geekWithoutProcessorModules.setModule(.sensors, isVisible: false)

        let complexOverview = PanelDensity.complex.auxiliaryDemand(for: .overview)
        let complexDisk = PanelDensity.complex.auxiliaryDemand(for: .disk)
        let complexNetwork = PanelDensity.complex.auxiliaryDemand(for: .network)
        let geekDisk = PanelDensity.geek.auxiliaryDemand(for: .disk)
        let complexProcessor = PanelDensity.complex.auxiliaryDemand(for: .processor)
        let geekNetwork = PanelDensity.geek.auxiliaryDemand(for: .network)
        let geekOverview = PanelDensity.geek.auxiliaryDemand(
            for: .overview,
            geekConfiguration: .defaultValue
        )
        let geekOverviewWithoutDisk = PanelDensity.geek.auxiliaryDemand(
            for: .overview,
            geekConfiguration: geekWithoutDisk
        )
        let geekOverviewWithoutDiskOrNetwork = PanelDensity.geek.auxiliaryDemand(
            for: .overview,
            geekConfiguration: geekWithoutDiskOrNetwork
        )
        let geekOverviewWithoutProcessorModules = PanelDensity.geek.auxiliaryDemand(
            for: .overview,
            geekConfiguration: geekWithoutProcessorModules
        )
        let complexCleanup = PanelDensity.complex.auxiliaryDemand(for: .cleanup)

        XCTAssertTrue(complexOverview.needsProcessorTelemetry)
        XCTAssertTrue(complexOverview.needsDiskIOSampling)
        XCTAssertTrue(complexOverview.needsNetworkInterface)
        XCTAssertFalse(complexOverview.needsPublicNetworkAddress)
        XCTAssertFalse(complexOverview.needsNetworkProcesses)
        XCTAssertTrue(complexDisk.needsDiskIOSampling)
        XCTAssertFalse(complexDisk.needsNetworkInterface)
        XCTAssertTrue(complexNetwork.needsNetworkInterface)
        XCTAssertFalse(complexNetwork.needsPublicNetworkAddress)
        XCTAssertFalse(complexNetwork.needsNetworkProcesses)
        XCTAssertFalse(complexNetwork.needsDiskIOSampling)
        XCTAssertTrue(geekDisk.needsDiskIOSampling)
        XCTAssertFalse(geekDisk.needsNetworkInterface)
        XCTAssertTrue(geekDisk.needsProcessorTelemetry)
        XCTAssertTrue(complexProcessor.needsProcessorTelemetry)
        XCTAssertFalse(complexProcessor.needsDiskIOSampling)
        XCTAssertTrue(geekNetwork.needsNetworkInterface)
        XCTAssertTrue(geekNetwork.needsPublicNetworkAddress)
        XCTAssertTrue(geekNetwork.needsNetworkProcesses)
        XCTAssertTrue(geekNetwork.needsDiskIOSampling)
        XCTAssertTrue(geekNetwork.needsProcessorTelemetry)
        XCTAssertTrue(geekOverview.needsProcessorTelemetry)
        XCTAssertTrue(geekOverview.needsDiskIOSampling)
        XCTAssertFalse(geekOverview.needsNetworkInterface)
        XCTAssertFalse(geekOverview.needsPublicNetworkAddress)
        XCTAssertFalse(geekOverview.needsNetworkProcesses)
        XCTAssertTrue(geekOverviewWithoutDisk.needsProcessorTelemetry)
        XCTAssertFalse(geekOverviewWithoutDisk.needsDiskIOSampling)
        XCTAssertFalse(geekOverviewWithoutDisk.needsNetworkInterface)
        XCTAssertFalse(geekOverviewWithoutDiskOrNetwork.needsNetworkInterface)
        XCTAssertFalse(geekOverviewWithoutDiskOrNetwork.needsPublicNetworkAddress)
        XCTAssertFalse(geekOverviewWithoutDiskOrNetwork.needsNetworkProcesses)
        XCTAssertFalse(geekOverviewWithoutProcessorModules.needsProcessorTelemetry)
        XCTAssertFalse(complexCleanup.needsProcessorTelemetry)
        XCTAssertFalse(complexCleanup.needsDiskIOSampling)
        XCTAssertFalse(complexCleanup.needsNetworkInterface)
        XCTAssertFalse(complexCleanup.needsNetworkProcesses)
        XCTAssertFalse(complexOverview.needsStorageVolumes)
        XCTAssertTrue(complexDisk.needsStorageVolumes)
        XCTAssertTrue(geekDisk.needsStorageVolumes)
        XCTAssertFalse(geekOverview.needsStorageVolumes)
    }

    func testOnePanelSessionPresentsGeekOnlyWhileKeepingLegacyGeometryDecodable() throws {
        let controller = try sourceText(
            "Sources/StorageCleanerMac/Support/MenuBarStatusController.swift"
        )
        let root = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarStatusPanelRoot.swift"
        )
        let advanced = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift"
        )
        let geometry = try sourceText(
            "Sources/StorageCleanerMac/Support/PanelGeometryStore.swift"
        )
        let session = try sourceText(
            "Sources/StorageCleanerMac/Support/MenuBarPanelSession.swift"
        )

        XCTAssertTrue(controller.contains("private let geometryStore = PanelGeometryStore()"))
        XCTAssertTrue(controller.contains("panelSession?.selectDensity(density)"))
        XCTAssertTrue(geometry.contains("case .simple: NSSize(width: 420, height: 280)"))
        XCTAssertTrue(geometry.contains(
            "case .complex, .geek: MiniWindowStyleTokens.overviewSize"
        ))
        XCTAssertTrue(geometry.contains("var minimumSize: NSSize {\n        idealSize"))
        XCTAssertTrue(session.contains("panel.contentMinSize = fixedSize"))
        XCTAssertTrue(session.contains("panel.contentMaxSize = fixedSize"))
        XCTAssertTrue(session.contains("geometryStore.save(frame: persistableFrame, for: density)"))
        XCTAssertTrue(session.contains("func selectDensity(_ density: PanelDensity)"))
        XCTAssertTrue(session.contains("func setGeekSection("))
        XCTAssertTrue(session.contains("_ section: PanelSection"))
        XCTAssertTrue(advanced.contains("GeekAttachedPanelShell("))
        XCTAssertTrue(advanced.contains("section: selectedSection"))
        XCTAssertTrue(advanced.contains("onHoverChange: geekAttachedPanelHoverChanged"))

        XCTAssertTrue(root.contains("struct PanelScene: View"))
        XCTAssertFalse(root.contains("case .simple:"))
        XCTAssertFalse(root.contains("case .complex, .geek:"))
        XCTAssertFalse(root.contains("presentation: panelDensity"))
        XCTAssertFalse(root.contains("MenuBarStatusView("))
        XCTAssertFalse(root.contains("presentation: .complex"))
        XCTAssertTrue(root.contains("presentation: .geek"))
        XCTAssertFalse(root.contains("WindowGroup"))

        XCTAssertTrue(advanced.contains("PanelShell("))
        XCTAssertTrue(advanced.contains("density: presentation"))
        XCTAssertTrue(advanced.contains("if presentation.usesGeekLayout"))
    }

    func testAdvancedPanelKeepsLiveObservationBelowShellAndNavigation() throws {
        let source = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift"
        )
        let rootProperties = try XCTUnwrap(
            source.components(separatedBy: "struct MenuBarAdvancedStatusView: View {").last?
                .components(separatedBy: "    init(").first
        )
        let shell = try XCTUnwrap(
            source.components(separatedBy: "    var body: some View {").dropFirst().first?
                .components(separatedBy: "    @ViewBuilder\n    private var liveHeader").first
        )
        let liveContent = try XCTUnwrap(
            source.components(separatedBy: "    private var liveCurrentContent: some View {").last?
                .components(separatedBy: "    @ViewBuilder\n    private var liveGeekOverview").first
        )

        XCTAssertTrue(rootProperties.contains("let store: ScanStore"))
        XCTAssertTrue(rootProperties.contains("let monitorState: MenuBarMonitorState"))
        XCTAssertTrue(rootProperties.contains("let auxiliaryState: MenuBarAuxiliaryMonitorState"))
        XCTAssertTrue(rootProperties.contains("let fanControl: FanControlCoordinator"))
        XCTAssertFalse(rootProperties.contains("@ObservedObject var store"))
        XCTAssertFalse(rootProperties.contains("@ObservedObject var monitorState"))
        XCTAssertFalse(rootProperties.contains("@ObservedObject var auxiliaryState"))
        XCTAssertFalse(rootProperties.contains("@ObservedObject var fanControl"))

        XCTAssertTrue(shell.contains("PanelShell("))
        XCTAssertTrue(shell.contains("liveHeader"))
        XCTAssertTrue(shell.contains("moduleRail"))
        XCTAssertTrue(shell.contains("liveCurrentContent"))
        let sharedShellSource = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift"
        )
        XCTAssertTrue(
            sharedShellSource.contains(".fixedSize(horizontal: false, vertical: true)"),
            "The fixed-size Panel must not compress its shared header when a page has dense content"
        )
        XCTAssertTrue(source.contains("private struct MenuBarObservedObjectBoundary"))
        XCTAssertTrue(source.contains("private struct MenuBarAdvancedSamplingCoordinator"))

        let expectedDependencies: [PanelSection: Set<String>] = [
            .overview: ["store", "monitorState", "auxiliaryState", "computerHealthStore", "fanControl"],
            .processor: ["store", "monitorState", "auxiliaryState"],
            .memory: ["store", "monitorState"],
            .disk: ["store", "auxiliaryState", "computerHealthStore"],
            .network: ["monitorState", "auxiliaryState", "computerHealthStore"],
            .sensors: ["monitorState", "auxiliaryState", "computerHealthStore", "fanControl"],
            .power: ["store", "auxiliaryState", "computerHealthStore"],
            .cleanup: ["store", "auxiliaryState"]
        ]
        let dependencyNames = [
            "store",
            "monitorState",
            "auxiliaryState",
            "computerHealthStore",
            "fanControl"
        ]

        for (index, section) in PanelSection.allCases.enumerated() {
            let start = "case .\(section.rawValue):"
            let suffix = try XCTUnwrap(liveContent.components(separatedBy: start).last)
            let segment: String
            if index + 1 < PanelSection.allCases.count {
                let next = "case .\(PanelSection.allCases[index + 1].rawValue):"
                segment = try XCTUnwrap(suffix.components(separatedBy: next).first)
            } else {
                segment = suffix
            }
            let actual = Set(dependencyNames.filter {
                segment.contains("MenuBarObservedObjectBoundary(model: \($0))")
            })
            XCTAssertEqual(actual, expectedDependencies[section], section.rawValue)
        }
    }

    func testIndependentAdvancedWindowWasRemovedFromApplicationLifecycle() throws {
        let app = try sourceText(
            "Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"
        )
        let settings = try sourceText(
            "Sources/StorageCleanerMac/Views/SettingsView.swift"
        )
        let chrome = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift"
        )

        XCTAssertFalse(app.contains("AdvancedMonitorWindow"))
        XCTAssertFalse(app.contains("advanced-monitor"))
        XCTAssertFalse(settings.contains("AdvancedMonitorWindow"))
        XCTAssertFalse(chrome.contains("AdvancedMonitorWindow"))
        XCTAssertFalse(chrome.contains("打开高级监控"))
        XCTAssertFalse(chrome.contains("Open Advanced Monitor"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectRoot
                .appendingPathComponent("Sources/StorageCleanerMac/Views/AdvancedMonitorWindowView.swift")
                .path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectRoot
                .appendingPathComponent("Sources/StorageCleanerMac/Support/AdvancedMonitorWindowCoordinator.swift")
                .path
        ))
    }

    func testGeekDensityKeepsAllEightRoutesAndTwentyEightDayHistory() throws {
        let panel = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )
        let telemetry = try sourceText(
            "Sources/StorageCleanerMac/Models/MenuBarTelemetryModels.swift"
        )
        let configuration = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDashboardConfiguration.swift"
        )

        for route in [
            "case .overview:",
            "case .processor:",
            "case .memory:",
            "case .disk:",
            "case .network:",
            "case .sensors:",
            "case .power:",
            "case .cleanup:"
        ] {
            XCTAssertTrue(panel.contains(route), "Missing geek panel route: \(route)")
        }
        XCTAssertTrue(panel.contains("selectedChartRange.duration"))
        XCTAssertTrue(panel.contains("selectedChartRange.title"))
        XCTAssertTrue(configuration.contains("case oneHour = 3_600"))
        XCTAssertTrue(configuration.contains("case twentyEightDays = 2_419_200"))
        XCTAssertTrue(configuration.contains("chartRange: .oneHour"))
        XCTAssertTrue(telemetry.contains("static let duration: TimeInterval = 28 * 24 * 60 * 60"))
        XCTAssertTrue(telemetry.contains("static let highResolutionDuration: TimeInterval = 60 * 60"))
        XCTAssertTrue(telemetry.contains("static let bucketDuration: TimeInterval = 60"))
        XCTAssertTrue(telemetry.contains("static let maximumMinutePointCount = 28 * 24 * 60 + 1"))
    }

    func testGeekOverviewDefersProcessReadsUntilVisiblePageDeclaresDemand() throws {
        let panel = try sourceText("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift")
        let view = try sourceText("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")
        XCTAssertFalse(panel.contains("prefetchGeekDetailSnapshots"))
        XCTAssertFalse(panel.contains("store.refreshEnergyImpact("))
        XCTAssertFalse(panel.contains("store.refreshMemory("))
        XCTAssertTrue(view.contains("store.updateMenuBarProcessConsumer(consumerID, section: selectedSection)"))
        XCTAssertTrue(view.contains("store.updateMenuBarProcessConsumer(consumerID, section: nil)"))
    }

    func testMenuBarSeparatesFreshDisplayMemoryFromProcessSnapshots() throws {
        let components = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift"
        )
        let status = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarStatusView.swift"
        )
        let geek = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )
        let memory = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift"
        )
        let combined = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarCombinedPanel.swift"
        )
        let displaySnapshot = try XCTUnwrap(
            components.components(separatedBy: "var memorySnapshot: MemorySnapshot? {").last?
                .components(separatedBy: "    var processMemorySnapshot").first
        )
        let processSnapshot = try XCTUnwrap(
            components.components(separatedBy: "var processMemorySnapshot: MemorySnapshot? {").last?
                .components(separatedBy: "    var storageSnapshot").first
        )

        XCTAssertTrue(displaySnapshot.contains("store.menuBarDisplayMemorySnapshot"))
        XCTAssertFalse(displaySnapshot.contains("store.memorySnapshot"))
        XCTAssertTrue(processSnapshot.contains("store.memorySnapshot"))
        XCTAssertTrue(status.contains("return store.menuBarDisplayMemorySnapshot"))
        XCTAssertTrue(status.contains("else if hasCurrentMemoryPressure"))
        XCTAssertTrue(status.contains("switch displayMemorySnapshot?.reportablePressureLevel"))
        XCTAssertFalse(status.contains("switch displayMemorySnapshot?.pressureLevel"))
        XCTAssertTrue(status.contains("private var snapshot: MemorySnapshot?"))
        XCTAssertTrue(status.contains("store.memorySnapshot"))
        XCTAssertTrue(geek.contains("processMemorySnapshot?.topProcesses"))
        XCTAssertTrue(memory.contains("store.menuBarPreparedMemoryApps"))
        XCTAssertTrue(combined.contains("if let memorySnapshot = processMemorySnapshot"))
    }

    func testMenuBarDiskCapacityUsesUserFacingFieldsAndDecimalFormatting() throws {
        let status = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarStatusView.swift"
        )
        let components = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift"
        )
        let diskPanel = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarDiskPanel.swift"
        )
        let combined = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarCombinedPanel.swift"
        )
        let geek = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )
        let geekDisk = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDiskView.swift"
        )
        let cleanup = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekCleanupView.swift"
        )
        let tertiary = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift"
        )
        let hover = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift"
        )
        let userFacing = [status, components, diskPanel, combined, geek, geekDisk, cleanup]
            .joined(separator: "\n")

        for field in [
            "userAvailableBytes",
            "userUsedBytes",
            "userAvailableRatio",
            "userUsedRatio",
            "userUsedPercent",
        ] {
            XCTAssertTrue(userFacing.contains(field), field)
        }
        XCTAssertTrue(components.contains("ByteFormat.storageString(abs(value))"))
        for source in [status, diskPanel, combined, geek, geekDisk, cleanup, hover] {
            XCTAssertTrue(source.contains("ByteFormat.storageString("))
        }
        XCTAssertTrue(tertiary.contains("GeekDiskIOHoverDetail("))
        XCTAssertFalse(status.contains("storageSnapshot?.usedRatio"))
        XCTAssertFalse(combined.contains("storageSnapshot.usedRatio"))
        XCTAssertFalse(geekDisk.contains("volume.capacity.usedRatio"))
    }

    func testMemoryProcessSnapshotUsesNativeIdentityAndFootprintAPIs() throws {
        let probe = try sourceText(
            "Sources/StorageCleanerMac/Features/Memory/Infrastructure/SystemMemoryProbe.swift"
        )

        XCTAssertTrue(probe.contains("proc_listpids("))
        XCTAssertTrue(probe.contains("proc_pid_rusage("))
        XCTAssertTrue(probe.contains("proc_bsdinfo"))
        XCTAssertFalse(probe.contains("\"/bin/sh\""))
        XCTAssertFalse(probe.contains("\"/bin/ps\""))
    }

    func testGeekProcessorOrdersCoreLevelsForReadableRingGrouping() {
        let levels: [CPUPerformanceStateService.PerformanceLevel] = [
            .init(index: 0, name: "Super", coreCount: 6, coresPerL2: 6),
            .init(index: 1, name: "Performance", coreCount: 12, coresPerL2: 6),
        ]
        let ordered = GeekProcessorCoreLevelOrdering.ordered(levels)

        XCTAssertEqual(ordered.map(\.name), ["Performance", "Super"])
        XCTAssertEqual(ordered.map(\.coreCount), [12, 6])
        XCTAssertEqual(GeekProcessorCoreLevelOrdering.sourceOffsets(levels), [0: 0, 1: 6])
    }

    func testGeekProcessorCoreCardExpandsWithoutTruncatingUltraCoreCounts() {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let components = try? String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPanelComponents.swift"
            ),
            encoding: .utf8
        )

        XCTAssertEqual(GeekProcessorCoreLayout.valueFontSize, 8)
        XCTAssertTrue(components?.contains(".fixedSize(horizontal: true, vertical: true)") == true)
        XCTAssertEqual(GeekProcessorCoreLayout.rowCount(for: 18), 2)
        XCTAssertEqual(GeekProcessorCoreLayout.cardHeight(for: 18), 102)
        XCTAssertEqual(GeekProcessorCoreLayout.rowCount(for: 19), 3)
        XCTAssertEqual(GeekProcessorCoreLayout.cardHeight(for: 27), 133)
        XCTAssertEqual(GeekProcessorCoreLayout.rowCount(for: 32), 4)
        XCTAssertEqual(GeekProcessorCoreLayout.cardHeight(for: 32), 164)
    }

    func testGeekProcessorCoreGridFitsTheSharedDetailWidth() {
        let gridWidth = CGFloat(GeekProcessorCoreLayout.columnCount) * GeekProcessorCoreLayout.ringSize
            + CGFloat(GeekProcessorCoreLayout.columnCount - 1) * GeekProcessorCoreLayout.spacing
        let requiredWidth = gridWidth
            + GeekVisualTokens.cardHorizontalPadding * 2
            + GeekPanelLayout.contentPadding * 2

        XCTAssertGreaterThanOrEqual(
            GeekPanelPresentationMetrics.detailWidth,
            requiredWidth
        )
    }

    func testGeekPanelLocalizesNonTechnicalEnglishLabels() throws {
        let source = try [
            "Sources/StorageCleanerMac/Models/SystemMonitorModels.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDashboardConfiguration.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekProcessorView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift",
        ].map(sourceText).joined(separator: "\n")

        for localizedLabel in [
            "L10n.text(\"风扇转速\", \"Fan Speed\")",
            "L10n.text(\"CPU 使用情况\", \"CPU Usage\")",
            "L10n.text(\"交换内存\", \"Swap Memory\")",
            "L10n.text(\"MAC 地址\", \"MAC Address\")",
            "L10n.text(\"GPU 温度\", \"GPU Temperature\")",
            "L10n.text(\"电池\", \"BATTERY\")",
            "L10n.text(\"电池健康\", \"HEALTH\")",
            "L10n.text(\"左侧风扇\", \"Left Fan\")",
            "L10n.text(\"公共 IP 地址\", \"Public IP Addresses\")",
            "L10n.text(\"频道\", \"Channel\")",
            "L10n.text(\"CPU 性能核心\", \"CPU P-Cores\")",
            "L10n.text(\"左侧雷雳\", \"Thunderbolt Left\")",
            "L10n.text(\"App 功耗\", \"APP POWER\")",
        ] {
            XCTAssertTrue(source.contains(localizedLabel), localizedLabel)
        }

        for hardCodedLabel in [
            "title: \"Fan Speed\"",
            "Text(\"Swap\")",
            "title: \"BATTERY\"",
            "title: \"GPU Temperature\"",
            "title: \"Interface / SSID\"",
            "return \"Left Fan\"",
            "Text(\"APP POWER\")",
            "case .fans: \"Fans\"",
            "geekSensorHeader(\"FANS\")",
            "title: \"Page Ins (Total)\"",
        ] {
            XCTAssertFalse(source.contains(hardCodedLabel), hardCodedLabel)
        }
    }

    private func sourceText(_ relativePath: String) throws -> String {
        try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

private final class NetworkProcessProviderSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [NativeNetworkProcessSnapshot?]

    init(_ snapshots: [NativeNetworkProcessSnapshot?]) {
        self.snapshots = snapshots
    }

    func snapshot() -> NativeNetworkProcessSnapshot? {
        lock.withLock {
            snapshots.isEmpty ? nil : snapshots.removeFirst()
        }
    }
}

private final class DiskCounterProviderSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var counters: [NativeDiskIOCounters]

    init(_ counters: [NativeDiskIOCounters]) {
        self.counters = counters
    }

    func next() -> NativeDiskIOCounters? {
        lock.withLock {
            counters.isEmpty ? nil : counters.removeFirst()
        }
    }
}

private final class MenuBarProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
