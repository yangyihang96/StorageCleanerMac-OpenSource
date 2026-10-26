import AppKit
import Combine
import CoreWLAN
import XCTest
@testable import CombinedStatusIcon

/// D153: this app's facade over the ported icon — the settings value, the
/// status monitor, the volume monitor and the status-item presenter. The
/// ported Status Trio suites beside this file cover the pipeline itself.
@MainActor
final class CombinedStatusIconFacadeTests: XCTestCase {
    // MARK: - Settings

    func testStandardSettingsAreStatusTriosFirstLaunchValues() {
        let settings = CombinedStatusIconSettings.standard
        XCTAssertEqual(settings.iconSize, 24)
        XCTAssertTrue(settings.showsBatteryPercentage)
        XCTAssertTrue(settings.showsChargingIndicator)
        XCTAssertTrue(settings.showsChargingEffect)
        XCTAssertTrue(settings.showsChargingBoltHeartbeat)
        XCTAssertFalse(settings.showsPercentageWhenConnected)
        XCTAssertTrue(settings.usesBatteryStatusColors)
        XCTAssertEqual(settings.batteryCriticalThreshold, 20)
        XCTAssertEqual(settings.batteryFullThreshold, 100)
        XCTAssertEqual(settings.batterySymbolScale, 1)
        XCTAssertFalse(settings.showsWiFiIconForEthernet)
        XCTAssertFalse(settings.showsWiFiIconForHotspot)
        XCTAssertFalse(settings.showsWiFiIconForTemporaryConnection)
        XCTAssertFalse(settings.showsWiFiIconForInternetSharing)
        XCTAssertFalse(settings.showsBatteryPercentageInConnectionSlot)
        XCTAssertEqual(settings.wifiSymbolScale, 1.6)
        XCTAssertEqual(settings.volumeDisplayStyle, .dots)
        XCTAssertEqual(settings.ringStrokeStyle, .regular)
        XCTAssertFalse(settings.replacesNetworkIconWithBluetoothAudio)
        XCTAssertFalse(settings.usesBluetoothAudioVolumeColor)
        XCTAssertTrue(settings.prioritizesNetworkErrorsOverBluetoothAudio)
        XCTAssertEqual(settings.bluetoothSymbolScale, 1.6)
        XCTAssertEqual(settings.bluetoothAudioIconChoice, .automatic)
    }

    func testSettingsClampLikeStatusTrio() {
        let high = CombinedStatusIconSettings(iconSize: 100, batteryCriticalThreshold: 140, batteryFullThreshold: 120,
                                              batterySymbolScale: 2, wifiSymbolScale: 3, bluetoothSymbolScale: 9)
        XCTAssertEqual(high.iconSize, 36)
        XCTAssertEqual(high.batteryCriticalThreshold, 100)
        XCTAssertEqual(high.batteryFullThreshold, 100)
        XCTAssertEqual(high.batterySymbolScale, 1.1)
        XCTAssertEqual(high.wifiSymbolScale, 1.8)
        XCTAssertEqual(high.bluetoothSymbolScale, 1.8)
        let low = CombinedStatusIconSettings(iconSize: 4, batteryCriticalThreshold: -5, batteryFullThreshold: 10,
                                             batterySymbolScale: 0.1, wifiSymbolScale: 0.5, bluetoothSymbolScale: 0)
        XCTAssertEqual(low.iconSize, 16)
        XCTAssertEqual(low.batteryCriticalThreshold, 0)
        XCTAssertEqual(low.batteryFullThreshold, 50)
        XCTAssertEqual(low.batterySymbolScale, 0.9)
        XCTAssertEqual(low.wifiSymbolScale, 1.0)
        XCTAssertEqual(low.bluetoothSymbolScale, 1.0)
        let invalid = CombinedStatusIconSettings(iconSize: .nan, batteryCriticalThreshold: .infinity,
                                                 batteryFullThreshold: -.infinity, batterySymbolScale: .nan,
                                                 wifiSymbolScale: .nan, bluetoothSymbolScale: .infinity)
        XCTAssertEqual(invalid, .standard)
    }

    func testConfigurationAssemblesTheUpstreamPresentation() {
        let settings = CombinedStatusIconSettings(
            iconSize: 30, showsBatteryPercentage: false, showsChargingIndicator: true, showsChargingEffect: false,
            showsChargingBoltHeartbeat: false, showsPercentageWhenConnected: true, usesBatteryStatusColors: false,
            batteryCriticalThreshold: 14.6, batteryFullThreshold: 80.4, batterySymbolScale: 1.1,
            showsWiFiIconForEthernet: true, showsWiFiIconForHotspot: true, showsWiFiIconForTemporaryConnection: true,
            showsWiFiIconForInternetSharing: true, showsBatteryPercentageInConnectionSlot: true, wifiSymbolScale: 1.2,
            volumeDisplayStyle: .arc, ringStrokeStyle: .bold, replacesNetworkIconWithBluetoothAudio: true,
            usesBluetoothAudioVolumeColor: true, prioritizesNetworkErrorsOverBluetoothAudio: false,
            bluetoothSymbolScale: 1.4, bluetoothAudioIconChoice: .headphones
        )
        let configuration = settings.configuration
        XCTAssertEqual(configuration.battery, BatteryIconOptions(
            showsPercentage: false, showsChargingIndicator: true, showsChargingEffect: false,
            showsChargingBoltHeartbeat: false, usesStatusColors: false, criticalThreshold: 15,
            showsPercentageWhenConnected: true, fullThreshold: 80,
            textScale: 1.1 * BatteryIconOptions.defaultTextScale, ringStrokeScale: 1.5
        ))
        XCTAssertEqual(configuration.connection, ConnectionIconOptions(
            showsWiFiIconForEthernet: true, showsWiFiIconForHotspot: true, showsWiFiIconForTemporaryConnection: true,
            showsWiFiIconForInternetSharing: true, showsBatteryPercentageInConnectionSlot: true, wifiScale: 1.2
        ))
        XCTAssertEqual(configuration.volume, VolumeIconOptions(displayStyle: .arc, ringStrokeScale: 1.5))
        XCTAssertTrue(configuration.bluetooth.replacesNetworkIcon)
        XCTAssertTrue(configuration.bluetooth.usesVolumeColor)
        XCTAssertFalse(configuration.bluetooth.prioritizesNetworkErrors)
        XCTAssertEqual(configuration.bluetooth.symbolScale, 1.4)
        XCTAssertNil(configuration.bluetooth.networkIconSymbolOverride)
        XCTAssertEqual(configuration.bluetooth.iconChoice, .headphones)
        XCTAssertEqual(settings.presentationSettings.menuBarSize, 30)
        XCTAssertFalse(settings.presentationSettings.testsChargingEffect)
        XCTAssertEqual(CombinedStatusIconSettings.standard.configuration.battery.textScale,
                       BatteryIconOptions.defaultTextScale)
        XCTAssertEqual(CombinedStatusIconSettings.standard.configuration.battery.ringStrokeScale, 1.25)
    }

    func testMappingsAreStatusTriosThresholds() {
        XCTAssertEqual([-40, -60, -61, -78, -79, -88, -89].map { CombinedStatusIconMappings.wifiBars(rssi: $0) },
                       [3, 3, 2, 2, 1, 1, 0])
        XCTAssertEqual(CombinedStatusIconMappings.wifiBars(rssi: nil), 0)
        XCTAssertNil(CombinedStatusIconMappings.volumeSteps(scalar: nil, isMuted: false))
        XCTAssertEqual([0, 0.01, 0.25, 0.26, 0.5, 0.51, 0.75, 0.76, 1, 1.4].map {
            CombinedStatusIconMappings.volumeSteps(scalar: $0, isMuted: false)
        }, [0, 1, 1, 2, 2, 3, 3, 4, 4, 4])
        XCTAssertEqual(CombinedStatusIconMappings.volumeSteps(scalar: 0.9, isMuted: true), 0)
    }

    // MARK: - Status monitor

    func testMonitorStartsFreshMonitorsAndMergesTheirUpdates() async throws {
        let rig = MonitorRig()
        let monitor = rig.makeMonitor()
        monitor.start()
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(rig.wifiMonitors.count, 1, "a second start is a no-op")
        XCTAssertEqual(rig.wifiMonitors[0].startCount, 1)
        XCTAssertEqual(rig.connectionMonitors[0].startCount, 1)
        XCTAssertEqual(rig.events.startCount, 1)

        rig.wifiMonitors[0].send(WiFiStatus(state: .connected, rssi: -50))
        rig.connectionMonitors[0].send(NetworkPathSnapshot(connected: true, wired: true, wireless: false,
                                                            constrained: false))
        rig.reader.complete(with: VolumeReading(scalar: 0.3, isMuted: false, deviceName: "Speakers"))
        try await waitUntil { monitor.snapshot.wifi.state == .connected
            && monitor.snapshot.connection == .ethernet && monitor.snapshot.volume.scalar == 0.3 }
        XCTAssertEqual(monitor.snapshot.wifi.rssi, -50)
        XCTAssertEqual(monitor.snapshot.battery, .placeholder)

        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(rig.wifiMonitors[0].stopCount, 1)
        XCTAssertEqual(rig.connectionMonitors[0].stopCount, 1)
        XCTAssertEqual(rig.events.stopCount, 1)

        monitor.start()
        XCTAssertEqual(rig.wifiMonitors.count, 2, "a stopped upstream monitor is never restarted")
        XCTAssertEqual(rig.connectionMonitors.count, 2)
        monitor.stop()
    }

    func testBatteryUpdatesAreTheAppsAndUnchangedOnesPublishNothing() {
        let rig = MonitorRig()
        let monitor = rig.makeMonitor()
        var published = 0
        let subscription = monitor.$snapshot.dropFirst().sink { _ in published += 1 }
        defer { subscription.cancel() }
        let charging = BatteryStatus(rawPercentage: 48, isPresent: true, isCharging: true, timeToFullChargeMinutes: 70,
                                     isLowPowerMode: false, isConnectedToPower: true)
        monitor.updateBattery(charging)
        monitor.updateBattery(charging)
        XCTAssertEqual(monitor.snapshot.battery, charging)
        XCTAssertEqual(published, 1)
    }

    func testWakeRecoversTheMonitorsAndScreenSleepIsTracked() async throws {
        let rig = MonitorRig()
        let monitor = rig.makeMonitor()
        monitor.start()
        rig.center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertTrue(monitor.isDisplayAsleep)
        rig.center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertFalse(monitor.isDisplayAsleep)
        rig.center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        rig.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertFalse(monitor.isDisplayAsleep)
        XCTAssertEqual(rig.wifiMonitors[0].recoverCount, 1)
        XCTAssertEqual(rig.connectionMonitors[0].recoverCount, 1)
        XCTAssertEqual(rig.events.recoverCount, 1)
        monitor.stop()
        rig.center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertFalse(monitor.isDisplayAsleep, "a stopped monitor no longer observes")
    }

    func testTheIconsWiFiMonitorNeverReadsTheNetworkName() async throws {
        let reader = SSIDReadRecorder()
        let monitor = CombinedStatusSystemMonitor.iconWiFiMonitor(WiFiMonitor(
            statusReader: reader, eventMonitor: SilentWiFiEvents(), pathMonitor: SilentWiFiPath()))
        monitor.start()
        defer { monitor.stop() }
        try await waitUntil { !reader.includeSSID.isEmpty }
        XCTAssertEqual(reader.includeSSID, [false], "no SSID read, so no Location request")
    }

    // MARK: - Volume monitor

    func testVolumeMonitorReadsOnStartWithoutListingDevicesAndPublishes() async throws {
        let rig = MonitorRig()
        let volume = rig.makeVolumeMonitor()
        var iterator = volume.updates.makeAsyncIterator()
        volume.start()
        XCTAssertEqual(rig.events.startCount, 1)
        XCTAssertEqual(rig.reader.requests, [false], "the icon never enumerates output devices")
        rig.reader.complete(with: VolumeReading(scalar: 0.62, isMuted: true, deviceName: "AirPods"))
        let status = await iterator.next()
        XCTAssertEqual(status?.scalar, 0.62)
        XCTAssertEqual(status?.isMuted, true)
        XCTAssertEqual(volume.latestStatus.deviceName, "AirPods")
        volume.stop()
        XCTAssertEqual(rig.events.stopCount, 1)
        volume.refresh()
        XCTAssertEqual(rig.reader.requests.count, 1, "a stopped monitor reads nothing")
    }

    func testVolumeMonitorKeepsOneReadInFlightAndFollowsUpOnce() async throws {
        let rig = MonitorRig()
        let volume = rig.makeVolumeMonitor()
        volume.start()
        volume.refresh()
        volume.refresh()
        XCTAssertEqual(rig.reader.requests.count, 1)
        rig.reader.complete(with: VolumeReading(scalar: 0.2, isMuted: false, deviceName: nil))
        XCTAssertEqual(rig.reader.requests.count, 2, "the queued refresh runs once after the read")
        rig.reader.complete(with: VolumeReading(scalar: 0.25, isMuted: false, deviceName: nil))
        XCTAssertEqual(rig.reader.requests.count, 2)
        XCTAssertEqual(volume.latestStatus.scalar, 0.25)
        volume.stop()
    }

    func testDefaultOutputChangeClearsTheVolumeThenRereadsAfterTheDebounce() async throws {
        let rig = MonitorRig()
        let volume = rig.makeVolumeMonitor()
        volume.start()
        rig.reader.complete(with: VolumeReading(scalar: 0.7, isMuted: false, deviceName: "Speakers"))
        XCTAssertEqual(volume.latestStatus.scalar, 0.7)
        rig.events.changeDefaultDevice()
        XCTAssertNil(volume.latestStatus.scalar, "the old output's volume is not shown for the new one")
        XCTAssertFalse(volume.latestStatus.canSetVolume)
        let slept = await rig.sleeper.waitForCallCount(1, timeout: .seconds(2))
        XCTAssertTrue(slept)
        XCTAssertEqual(rig.sleeper.durations, [.milliseconds(150)])
        XCTAssertEqual(rig.reader.requests.count, 1, "the reread waits out the debounce")
        rig.sleeper.releaseAll()
        try await waitUntil { rig.reader.requests.count == 2 }
        rig.reader.complete(with: VolumeReading(scalar: 0.4, isMuted: false, deviceName: "AirPods"))
        XCTAssertEqual(volume.latestStatus.scalar, 0.4)
        volume.stop()
    }

    func testAReadStartedBeforeAVolumeEventIsNotPublished() async throws {
        let rig = MonitorRig()
        let volume = rig.makeVolumeMonitor()
        volume.start()
        rig.events.changeVolume()
        rig.reader.complete(at: 0, with: VolumeReading(scalar: 0.9, isMuted: false, deviceName: nil))
        XCTAssertNil(volume.latestStatus.scalar, "a read that predates the event is stale")
        let slept = await rig.sleeper.waitForCallCount(1, timeout: .seconds(2))
        XCTAssertTrue(slept)
        rig.sleeper.releaseAll()
        try await waitUntil { rig.reader.requests.count == 2 }
        rig.reader.complete(at: 1, with: VolumeReading(scalar: 0.4, isMuted: false, deviceName: nil))
        XCTAssertEqual(volume.latestStatus.scalar, 0.4)
        volume.stop()
    }

    func testAStuckVolumeReadIsAbandonedAndItsLateResultIgnored() async throws {
        let rig = MonitorRig()
        let firstTimeout = FirstCallOnly()
        let volume = rig.makeVolumeMonitor(readTimeoutSleep: { _ in
            // The first read times out at once; the retry waits as usual.
            if await firstTimeout.isFirst() { return }
            try await Task.sleep(for: .seconds(3_600))
        })
        volume.start()
        try await waitUntil { rig.reader.requests.count == 2 }
        rig.reader.complete(at: 0, with: VolumeReading(scalar: 0.9, isMuted: false, deviceName: "Late"))
        XCTAssertNil(volume.latestStatus.scalar, "the abandoned read's completion is ignored")
        rig.reader.complete(at: 1, with: VolumeReading(scalar: 0.33, isMuted: false, deviceName: "Speakers"))
        XCTAssertEqual(volume.latestStatus.scalar, 0.33)
        XCTAssertEqual(rig.reader.requests.count, 2)
        volume.stop()
    }

    // MARK: - Presenter

    func testAttachDrawsATemplateBaseOfTheIconSize() throws {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        let presenter = CombinedStatusIconStatusItemPresenter(snapshot: Self.ordinary, settings: .standard)
        presenter.attach(to: button)
        defer { presenter.detach() }
        let image = try XCTUnwrap(button.image)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 24, height: 24))
        XCTAssertEqual(presenter.iconSize, 24)
        XCTAssertTrue(presenter.isAttached)
        XCTAssertEqual(button.imagePosition, .imageOnly)
    }

    func testStatusColoursGoToALayerAboveTheTemplateAndDetachRemovesIt() throws {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        let presenter = CombinedStatusIconStatusItemPresenter(snapshot: Self.critical, settings: .standard)
        presenter.attach(to: button)
        XCTAssertEqual(try XCTUnwrap(button.image).isTemplate, true)
        XCTAssertEqual(overlayLayers(of: button).count, 1, "a red low-battery ring is drawn above the template")
        presenter.detach()
        XCTAssertTrue(overlayLayers(of: button).isEmpty)
        XCTAssertFalse(presenter.isAttached)
    }

    func testCustomItemColourDrawsTheWholeIconInALayer() throws {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        let presenter = CombinedStatusIconStatusItemPresenter(snapshot: Self.ordinary, settings: .standard)
        presenter.attach(to: button)
        defer { presenter.detach() }
        XCTAssertTrue(overlayLayers(of: button).isEmpty, "an ordinary scene is the template alone")
        presenter.update(foreground: NSColor(srgbRed: 0.08, green: 0.42, blue: 0.8, alpha: 1))
        XCTAssertEqual(overlayLayers(of: button).count, 1)
        let base = try XCTUnwrap(button.image)
        XCTAssertTrue(base.isTemplate)
        XCTAssertEqual(alphaSum(of: base), 0, "the template under a custom colour is transparent")
        presenter.update(foreground: nil)
        XCTAssertTrue(overlayLayers(of: button).isEmpty)
        XCTAssertGreaterThan(alphaSum(of: try XCTUnwrap(button.image)), 0)
    }

    func testSettingsResizeTheIcon() async throws {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        let presenter = CombinedStatusIconStatusItemPresenter(snapshot: Self.ordinary, settings: .standard)
        presenter.attach(to: button)
        defer { presenter.detach() }
        presenter.update(settings: CombinedStatusIconSettings(iconSize: 30))
        try await waitUntil { button.image?.size == NSSize(width: 30, height: 30) }
        XCTAssertEqual(presenter.iconSize, 30)
    }

    /// The view model debounces a status for 500 ms; an unchanged status sent
    /// again (every UserDefaults change sends one) must not keep postponing it.
    func testRepeatedUnchangedStatusDoesNotPostponeAChange() async throws {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        let presenter = CombinedStatusIconStatusItemPresenter(snapshot: Self.ordinary, settings: .standard)
        presenter.attach(to: button)
        defer { presenter.detach() }
        let before = try XCTUnwrap(button.image)
        let changed = Self.snapshot(battery: Self.battery(35))
        let started = ContinuousClock.now
        presenter.update(snapshot: changed, isDisplayAsleep: false)
        var redrawn = false
        while ContinuousClock.now - started < .milliseconds(1_500) {
            presenter.update(snapshot: changed, isDisplayAsleep: false)
            try await Task.sleep(for: .milliseconds(100))
            if button.image !== before { redrawn = true; break }
        }
        XCTAssertTrue(redrawn)
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(1_200))
    }

    func testPreviewImageDrawsInTheGivenItemColour() throws {
        let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let image = try XCTUnwrap(CombinedStatusIconStatusItemPresenter.previewImage(
            snapshot: Self.ordinary, settings: .standard, size: 24, scale: 2,
            appearance: NSAppearance(named: .darkAqua), foreground: blue))
        XCTAssertEqual(image.size, NSSize(width: 24, height: 24))
        var bluePixels = 0, otherInk = 0
        for pixel in try XCTUnwrap(rgbaPixels(of: image)) where pixel.a > 230 {
            if Int(pixel.b) - Int(max(pixel.r, pixel.g)) > 128 { bluePixels += 1 } else { otherInk += 1 }
        }
        XCTAssertGreaterThan(bluePixels, 100)
        XCTAssertEqual(otherInk, 0, "an ordinary scene has no status colour")
        let plain = try XCTUnwrap(CombinedStatusIconStatusItemPresenter.previewImage(
            snapshot: Self.ordinary, settings: CombinedStatusIconSettings(iconSize: 36), size: 36, scale: 2,
            appearance: NSAppearance(named: .aqua)))
        XCTAssertEqual(plain.size, NSSize(width: 36, height: 36))
    }

    // MARK: - Review sheet

    /// Writes every icon state on a light and a dark menu bar for review when
    /// SCM_COMBINED_RENDER_DIR names a folder; checks only that each renders.
    func testEveryStateRendersAndCanBeExportedForReview() throws {
        let airPods = AudioOutputDevice(id: 7, name: "AirPods Pro", isCurrent: true, volume: 0.6,
                                        transport: .bluetooth, modelUID: "200e 4c")
        func state(_ battery: BatteryStatus, wifi: WiFiStatus = WiFiStatus(state: .connected, rssi: -52),
                   connection: NetworkConnection = .wifi,
                   volume: VolumeStatus = VolumeStatus(scalar: 0.5, isMuted: false, deviceName: nil)) -> StatusSnapshot {
            StatusSnapshot(battery: battery, wifi: wifi, connection: connection, volume: volume)
        }
        let onAC = BatteryStatus(rawPercentage: 80, isPresent: true, isCharging: false,
                                 isLowPowerMode: false, isConnectedToPower: true)
        let lowPower = BatteryStatus(rawPercentage: 35, isPresent: true, isCharging: false,
                                     isLowPowerMode: true, isConnectedToPower: false)
        let full = BatteryStatus(rawPercentage: 100, isPresent: true, isCharging: false, isCharged: true,
                                 isLowPowerMode: false, isConnectedToPower: true)
        let none = BatteryStatus(rawPercentage: nil, isPresent: false, isCharging: false,
                                 isLowPowerMode: false, isConnectedToPower: false)
        let cases: [(String, StatusSnapshot, CombinedStatusIconSettings)] = [
            ("76% · Wi-Fi 3 · 50%", Self.ordinary, .standard),
            ("charging 48%", state(Self.battery(48, charging: true)), .standard),
            ("on AC 80%", state(onAC), .standard),
            ("low 9%", Self.critical, .standard),
            ("Low Power 35%", state(lowPower), .standard),
            ("full", state(full), .standard),
            ("no battery", state(none), .standard),
            ("Ethernet", state(Self.battery(76), connection: .ethernet), .standard),
            ("Wi-Fi off", state(Self.battery(76), wifi: WiFiStatus(state: .off, rssi: nil)), .standard),
            ("no internet", state(Self.battery(76), wifi: WiFiStatus(state: .noInternet, rssi: -60)), .standard),
            ("hotspot", state(Self.battery(76), wifi: WiFiStatus(state: .hotspot, rssi: -60)), .standard),
            ("not associated", state(Self.battery(76), wifi: WiFiStatus(state: .notAssociated, rssi: nil)), .standard),
            ("weak 1 bar", state(Self.battery(76), wifi: WiFiStatus(state: .connected, rssi: -85)), .standard),
            ("muted", state(Self.battery(76), volume: VolumeStatus(scalar: 0.7, isMuted: true, deviceName: nil)),
             .standard),
            ("arc 70%", state(Self.battery(76), volume: VolumeStatus(scalar: 0.7, isMuted: false, deviceName: nil)),
             CombinedStatusIconSettings(volumeDisplayStyle: .arc)),
            ("AirPods", state(Self.battery(76), volume: VolumeStatus(scalar: 0.6, isMuted: false,
                                                                    deviceName: airPods.name, currentDevice: airPods)),
             CombinedStatusIconSettings(replacesNetworkIconWithBluetoothAudio: true, usesBluetoothAudioVolumeColor: true)),
            ("% in slot", Self.ordinary, CombinedStatusIconSettings(showsBatteryPercentageInConnectionSlot: true)),
            ("bold ring", Self.ordinary, CombinedStatusIconSettings(ringStrokeStyle: .bold)),
        ]
        var tiles: [(String, NSImage, NSImage)] = []
        for (label, snapshot, settings) in cases {
            let light = try XCTUnwrap(CombinedStatusIconStatusItemPresenter.previewImage(
                snapshot: snapshot, settings: settings, size: 24, scale: 4, appearance: NSAppearance(named: .aqua)), label)
            let dark = try XCTUnwrap(CombinedStatusIconStatusItemPresenter.previewImage(
                snapshot: snapshot, settings: settings, size: 24, scale: 4, appearance: NSAppearance(named: .darkAqua)), label)
            XCTAssertGreaterThan(alphaSum(of: light), 0, label)
            tiles.append((label, light, dark))
        }
        guard let directory = ProcessInfo.processInfo.environment["SCM_COMBINED_RENDER_DIR"] else { return }
        let cell = NSSize(width: 150, height: 150), columns = 6
        let rows = (tiles.count + columns - 1) / columns
        let sheet = NSImage(size: NSSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows)))
        sheet.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (index, tile) in tiles.enumerated() {
            let origin = NSPoint(x: CGFloat(index % columns) * cell.width,
                                 y: sheet.size.height - CGFloat(index / columns + 1) * cell.height)
            for (offset, (image, background)) in [(tile.1, NSColor(white: 0.93, alpha: 1)),
                                                  (tile.2, NSColor(white: 0.17, alpha: 1))].enumerated() {
                let box = NSRect(x: origin.x + 6 + CGFloat(offset) * 70, y: origin.y + 50, width: 66, height: 66)
                background.setFill()
                NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
                image.draw(in: box.insetBy(dx: 9, dy: 9))
            }
            (tile.0 as NSString).draw(at: NSPoint(x: origin.x + 8, y: origin.y + 22),
                                      withAttributes: [.font: NSFont.systemFont(ofSize: 13),
                                                       .foregroundColor: NSColor.black])
        }
        sheet.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(sheet.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("combined-status-icon-states.png"))
    }

    // MARK: - Helpers

    static func battery(_ percent: Int, charging: Bool = false) -> BatteryStatus {
        BatteryStatus(rawPercentage: percent, isPresent: true, isCharging: charging,
                      isLowPowerMode: false, isConnectedToPower: charging)
    }

    static func snapshot(battery: BatteryStatus) -> StatusSnapshot {
        StatusSnapshot(battery: battery, wifi: WiFiStatus(state: .connected, rssi: -52), connection: .wifi,
                       volume: VolumeStatus(scalar: 0.5, isMuted: false, deviceName: nil))
    }

    static let ordinary = snapshot(battery: battery(76))
    static let critical = snapshot(battery: battery(9))

    private func overlayLayers(of button: NSStatusBarButton) -> [CALayer] {
        (button.layer?.sublayers ?? []).filter { $0.contents != nil && $0.contentsGravity == .resize }
    }

    private func alphaSum(of image: NSImage) -> Int {
        (rgbaPixels(of: image) ?? []).reduce(0) { $0 + Int($1.a) }
    }

    /// The image drawn at 2x into an sRGB, premultiplied RGBA buffer.
    private func rgbaPixels(of image: NSImage) -> [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)]? {
        let width = Int(image.size.width * 2), height = Int(image.size.height * 2)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return (0..<(width * height)).map { index in
            (bytes[index * 4], bytes[index * 4 + 1], bytes[index * 4 + 2], bytes[index * 4 + 3])
        }
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
        let started = ContinuousClock.now
        while !condition() {
            guard ContinuousClock.now - started < timeout else {
                return XCTFail("condition not met within \(timeout)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - Fakes

@MainActor
private final class SSIDReadRecorder: WiFiStatusReadingProviding {
    private(set) var includeSSID: [Bool] = []
    func read(includeSSID: Bool, completion: @escaping @MainActor @Sendable (WiFiStatusReading) -> Void) {
        self.includeSSID.append(includeSSID)
    }
}

private final class SilentWiFiEvents: WiFiEventMonitoring {
    func start(delegate: any CWEventDelegate, events: [CWEventType]) {}
    func restart(delegate: any CWEventDelegate, events: [CWEventType]) {}
    func stop() {}
}

private final class SilentWiFiPath: WiFiPathMonitoring {
    func start(queue: DispatchQueue, handler: @escaping (WiFiPathUpdate) -> Void) {}
    func cancel() {}
}

private actor FirstCallOnly {
    private var called = false
    func isFirst() -> Bool {
        defer { called = true }
        return !called
    }
}

@MainActor
private final class MonitorRig {
    let center = NotificationCenter()
    let reader = FakeAudioReader()
    let events = FakeVolumeEvents()
    let sleeper = ManualEventSleeper()
    private(set) var wifiMonitors: [FakeWiFiMonitor] = []
    private(set) var connectionMonitors: [FakeConnectionMonitor] = []

    func makeVolumeMonitor(
        readTimeoutSleep: @escaping @Sendable (Duration) async throws -> Void = { _ in
            try await Task.sleep(for: .seconds(3_600))
        }
    ) -> CombinedStatusVolumeMonitor {
        let sleeper = sleeper
        return CombinedStatusVolumeMonitor(statusReader: reader, eventMonitor: events,
                                           refreshDebounceSleep: { duration in await sleeper.sleep(duration) },
                                           readTimeoutSleep: readTimeoutSleep)
    }

    func makeMonitor() -> CombinedStatusSystemMonitor {
        CombinedStatusSystemMonitor(
            battery: .placeholder,
            makeWiFiMonitor: { [unowned self] in
                let monitor = FakeWiFiMonitor()
                wifiMonitors.append(monitor)
                return monitor
            },
            makeConnectionMonitor: { [unowned self] in
                let monitor = FakeConnectionMonitor()
                connectionMonitors.append(monitor)
                return monitor
            },
            makeVolumeMonitor: { [unowned self] in makeVolumeMonitor() },
            notificationCenter: center
        )
    }
}

@MainActor
private final class FakeWiFiMonitor: WiFiMonitoring {
    let updates: AsyncStream<WiFiStatus>
    private let continuation: AsyncStream<WiFiStatus>.Continuation
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var recoverCount = 0

    init() { (updates, continuation) = AsyncStream.makeStream(of: WiFiStatus.self) }
    func send(_ status: WiFiStatus) { continuation.yield(status) }
    func start() { startCount += 1 }
    func stop() { stopCount += 1; continuation.finish() }
    func refresh() {}
    func recover() { recoverCount += 1 }
    func requestNameAccess() -> WiFiNameAccessRequestResult { .notNeeded }
    func setDetailsVisible(_ visible: Bool) {}
}

@MainActor
private final class FakeConnectionMonitor: NetworkConnectionMonitoring {
    let updates: AsyncStream<NetworkPathSnapshot>
    private let continuation: AsyncStream<NetworkPathSnapshot>.Continuation
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var recoverCount = 0

    init() { (updates, continuation) = AsyncStream.makeStream(of: NetworkPathSnapshot.self) }
    func send(_ path: NetworkPathSnapshot) { continuation.yield(path) }
    func start() { startCount += 1 }
    func stop() { stopCount += 1; continuation.finish() }
    func recover() { recoverCount += 1 }
}

@MainActor
private final class FakeAudioReader: AudioStatusReadingProviding {
    private(set) var requests: [Bool] = []
    private var pending: [Int: @MainActor @Sendable (AudioStatusReading) -> Void] = [:]

    func read(includeOutputDevices: Bool, completion: @escaping @MainActor @Sendable (AudioStatusReading) -> Void) {
        pending[requests.count] = completion
        requests.append(includeOutputDevices)
    }

    /// Completes the newest pending read, or the read made `index`-th.
    func complete(at index: Int? = nil, with reading: VolumeReading) {
        guard let index = index ?? pending.keys.max(), let completion = pending.removeValue(forKey: index) else {
            return XCTFail("no pending read \(String(describing: index))")
        }
        completion(AudioStatusReading(volume: reading, outputDevices: nil))
    }
}

@MainActor
private final class FakeVolumeEvents: VolumeEventMonitoring {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var recoverCount = 0
    private var onDefaultDeviceChange: (@MainActor @Sendable () -> Void)?
    private var onVolumeChange: (@MainActor @Sendable () -> Void)?

    func start(onDefaultDeviceChange: @escaping @MainActor @Sendable () -> Void,
               onVolumeChange: @escaping @MainActor @Sendable () -> Void) {
        startCount += 1
        self.onDefaultDeviceChange = onDefaultDeviceChange
        self.onVolumeChange = onVolumeChange
    }
    func reconcile() {}
    func recover() { recoverCount += 1 }
    func stop() { stopCount += 1 }
    func changeDefaultDevice() { onDefaultDeviceChange?() }
    func changeVolume() { onVolumeChange?() }
}
