import AppKit
@testable import CombinedStatusIcon
import XCTest
@testable import StorageCleanerMac

/// D153: the status-item side of the combined icon on a plain status button
/// (no status item is created): when its monitors run, when the icon holds
/// still, what the button says to VoiceOver and how it is torn down.
@MainActor
final class CombinedStatusItemDriverTests: XCTestCase {
    func testAVisibleItemRunsTheMonitorsAndDescribesTheStatus() async throws {
        let rig = DriverRig()
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        let languagePreferences = TestVolatilePreferences()
        defer { languagePreferences.restore() }
        languagePreferences.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        rig.driver.update(button: button, context: rig.context())
        defer { rig.driver.tearDown() }

        XCTAssertTrue(rig.driver.isActive)
        XCTAssertEqual(rig.wifi.last?.startCount, 1)
        XCTAssertEqual(rig.connection.last?.startCount, 1)
        XCTAssertEqual(rig.driver.snapshot?.battery, rig.context().battery)
        XCTAssertEqual(try XCTUnwrap(button.image).isTemplate, true)
        XCTAssertEqual(button.accessibilityLabel(), L10n.appName)
        XCTAssertEqual(button.accessibilityValue() as? String, "电池 64%，Wi-Fi 不可用，音量 —")

        rig.wifi.last?.send(WiFiStatus(state: .connected, rssi: -70))
        rig.reader.completeLatest(with: VolumeReading(scalar: 0.8, isMuted: false, deviceName: nil))
        try await waitUntil { (button.accessibilityValue() as? String) == "电池 64%，Wi-Fi 2 格，音量 80% · 4 格" }
        XCTAssertEqual(button.toolTip, "电池 64%，Wi-Fi 2 格，音量 80% · 4 格")
    }

    func testHiddenPausedOrSleepingItemsStopTheMonitors() {
        let rig = DriverRig()
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        defer { rig.driver.tearDown() }
        rig.driver.update(button: button, context: rig.context())
        XCTAssertEqual(rig.wifi.count, 1)
        rig.driver.update(button: button, context: rig.context(visible: false))
        XCTAssertEqual(rig.wifi.last?.stopCount, 1, "a hidden item reads nothing")
        rig.driver.update(button: button, context: rig.context())
        XCTAssertEqual(rig.wifi.count, 2, "showing it again starts fresh monitors")
        rig.driver.update(button: button, context: rig.context(paused: true))
        XCTAssertEqual(rig.wifi.last?.stopCount, 1)
        rig.driver.update(button: button, context: rig.context())
        rig.driver.update(button: button, context: rig.context(systemSleeping: true))
        XCTAssertEqual(rig.wifi.count, 3)
        XCTAssertEqual(rig.wifi.last?.stopCount, 1)
        rig.driver.update(button: button, context: rig.context())
        rig.driver.update(button: button, context: rig.context(displaySleeping: true))
        XCTAssertEqual(rig.wifi.count, 4)
        XCTAssertEqual(rig.wifi.last?.stopCount, 0, "a sleeping display only stills the icon")
        XCTAssertEqual(rig.makeCount, 1, "one status monitor for the whole session")
    }

    func testOnlyALiveVisibleItemAnimates() {
        let live = DriverRig().context()
        XCTAssertTrue(live.runsMonitors)
        XCTAssertFalse(live.holdsStill)
        for still in [DriverRig().context(visible: false), DriverRig().context(paused: true),
                      DriverRig().context(systemSleeping: true), DriverRig().context(displaySleeping: true)] {
            XCTAssertTrue(still.holdsStill)
        }
        XCTAssertTrue(DriverRig().context(displaySleeping: true).runsMonitors)
    }

    func testBatteryAndItemColourReachTheIcon() {
        let rig = DriverRig()
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        defer { rig.driver.tearDown() }
        rig.driver.update(button: button, context: rig.context())
        XCTAssertTrue(overlays(of: button).isEmpty, "an ordinary 64% icon is the template alone")
        var low = rig.context()
        low.battery = BatteryStatus(rawPercentage: 8, isPresent: true, isCharging: false,
                                    isLowPowerMode: false, isConnectedToPower: false)
        rig.driver.update(button: button, context: low)
        XCTAssertEqual(rig.driver.snapshot?.battery.percentage, 8)
        var coloured = rig.context()
        coloured.foreground = NSColor(srgbRed: 0.08, green: 0.42, blue: 0.8, alpha: 1)
        rig.driver.update(button: button, context: coloured)
        XCTAssertEqual(overlays(of: button).count, 1, "the item colour draws the icon in a layer")
    }

    func testTearDownRemovesTheIconLayerAndStopsTheMonitors() {
        let rig = DriverRig()
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        var coloured = rig.context()
        coloured.foreground = .systemPink
        rig.driver.update(button: button, context: coloured)
        XCTAssertEqual(overlays(of: button).count, 1)
        rig.driver.tearDown()
        XCTAssertFalse(rig.driver.isActive)
        XCTAssertNil(rig.driver.snapshot)
        XCTAssertTrue(overlays(of: button).isEmpty)
        XCTAssertEqual(rig.wifi.last?.stopCount, 1)
        XCTAssertEqual(rig.events.stopCount, 1)
        rig.driver.tearDown()
        XCTAssertEqual(rig.wifi.last?.stopCount, 1, "a second tear-down is a no-op")
    }

    private func overlays(of button: NSStatusBarButton) -> [CALayer] {
        (button.layer?.sublayers ?? []).filter { $0.contents != nil && $0.contentsGravity == .resize }
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
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
private final class DriverRig {
    let reader = DriverFakeAudioReader()
    let events = DriverFakeVolumeEvents()
    private(set) var wifi: [DriverFakeWiFiMonitor] = []
    private(set) var connection: [DriverFakeConnectionMonitor] = []
    private(set) var makeCount = 0
    private(set) lazy var driver = CombinedStatusItemDriver { [unowned self] battery in
        makeCount += 1
        return CombinedStatusSystemMonitor(
            battery: battery,
            makeWiFiMonitor: { [unowned self] in
                let monitor = DriverFakeWiFiMonitor()
                wifi.append(monitor)
                return monitor
            },
            makeConnectionMonitor: { [unowned self] in
                let monitor = DriverFakeConnectionMonitor()
                connection.append(monitor)
                return monitor
            },
            makeVolumeMonitor: { [unowned self] in
                CombinedStatusVolumeMonitor(statusReader: reader, eventMonitor: events)
            },
            notificationCenter: NotificationCenter()
        )
    }

    func context(visible: Bool = true, paused: Bool = false, systemSleeping: Bool = false,
                 displaySleeping: Bool = false) -> CombinedStatusItemDriver.Context {
        CombinedStatusItemDriver.Context(
            battery: BatteryStatus(rawPercentage: 64, isPresent: true, isCharging: false,
                                   isLowPowerMode: false, isConnectedToPower: false),
            settings: .standard, foreground: nil, isVisible: visible, isPaused: paused,
            isSystemSleeping: systemSleeping, isDisplaySleeping: displaySleeping
        )
    }
}

@MainActor
private final class DriverFakeWiFiMonitor: WiFiMonitoring {
    let updates: AsyncStream<WiFiStatus>
    private let continuation: AsyncStream<WiFiStatus>.Continuation
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init() { (updates, continuation) = AsyncStream.makeStream(of: WiFiStatus.self) }
    func send(_ status: WiFiStatus) { continuation.yield(status) }
    func start() { startCount += 1 }
    func stop() { stopCount += 1; continuation.finish() }
    func refresh() {}
    func recover() {}
    func requestNameAccess() -> WiFiNameAccessRequestResult { .notNeeded }
    func setDetailsVisible(_ visible: Bool) {}
}

@MainActor
private final class DriverFakeConnectionMonitor: NetworkConnectionMonitoring {
    let updates: AsyncStream<CombinedStatusIcon.NetworkPathSnapshot>
    private let continuation: AsyncStream<CombinedStatusIcon.NetworkPathSnapshot>.Continuation
    private(set) var startCount = 0

    init() { (updates, continuation) = AsyncStream.makeStream(of: CombinedStatusIcon.NetworkPathSnapshot.self) }
    func start() { startCount += 1 }
    func stop() { continuation.finish() }
    func recover() {}
}

@MainActor
private final class DriverFakeAudioReader: AudioStatusReadingProviding {
    private var pending: [@MainActor @Sendable (AudioStatusReading) -> Void] = []

    func read(includeOutputDevices: Bool, completion: @escaping @MainActor @Sendable (AudioStatusReading) -> Void) {
        pending.append(completion)
    }

    func completeLatest(with reading: VolumeReading) {
        guard let completion = pending.popLast() else { return XCTFail("no pending read") }
        completion(AudioStatusReading(volume: reading, outputDevices: nil))
    }
}

@MainActor
private final class DriverFakeVolumeEvents: VolumeEventMonitoring {
    private(set) var stopCount = 0
    func start(onDefaultDeviceChange: @escaping @MainActor @Sendable () -> Void,
               onVolumeChange: @escaping @MainActor @Sendable () -> Void) {}
    func reconcile() {}
    func recover() {}
    func stop() { stopCount += 1 }
}
