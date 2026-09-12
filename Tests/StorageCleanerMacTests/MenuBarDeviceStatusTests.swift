import AppKit
import XCTest
import IOKit.ps
@testable import StorageCleanerMac

final class MenuBarDeviceStatusTests: XCTestCase {
    func testInternalBatteryDetectionSeparatesAbsenceFailuresAndExternalPower() {
        let internalSource: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType]
        let ups: [String: Any] = [kIOPSTypeKey: "UPS", kIOPSCurrentCapacityKey: 80, kIOPSMaxCapacityKey: 100]
        let accessory: [String: Any] = [kIOPSTypeKey: "Accessory", kIOPSCurrentCapacityKey: 50]
        XCTAssertEqual(BatteryPowerService.internalBatteryAvailability(registryHasBattery: true, powerSourceDescriptions: nil), .present)
        XCTAssertEqual(BatteryPowerService.internalBatteryAvailability(registryHasBattery: false, powerSourceDescriptions: [internalSource]), .present)
        XCTAssertEqual(BatteryPowerService.internalBatteryAvailability(registryHasBattery: nil, powerSourceDescriptions: [internalSource]), .present)
        XCTAssertEqual(BatteryPowerService.internalBatteryAvailability(registryHasBattery: false, powerSourceDescriptions: []), .absent)
        XCTAssertEqual(BatteryPowerService.internalBatteryAvailability(registryHasBattery: false, powerSourceDescriptions: [ups, accessory]), .absent)
        XCTAssertEqual(BatteryPowerService.internalBatteryAvailability(registryHasBattery: nil, powerSourceDescriptions: []), .unknown)
        XCTAssertEqual(BatteryPowerService.internalBatteryAvailability(registryHasBattery: false, powerSourceDescriptions: nil), .unknown)
        XCTAssertEqual(BatteryPowerService.internalBatteryAvailability(registryHasBattery: false, powerSourceDescriptions: [[:]]), .unknown)
    }

    func testDesktopRingUsesMemoryAndDoesNotConfuseReadFailureWithNoBattery() {
        for ratio: Double? in [0, 0.64, 1, nil] {
            let desktop = desktopState(memory: ratio)
            XCTAssertTrue(desktop.showsMemoryRing)
            XCTAssertEqual(desktop.ringPercent, ratio.map { Int(($0 * 100).rounded()) })
            XCTAssertNotEqual(desktop.accessibilitySummary, state(battery: nil, memory: ratio).accessibilitySummary)
        }
        for availability in [InternalBatteryAvailability.present, .unknown] {
            let unavailable = MenuBarDeviceStatusSnapshot(
                batteryPercent: nil, isCharging: nil, memoryUsedRatio: 0.64, wiFi: .off,
                batteryAvailability: availability
            )
            XCTAssertFalse(unavailable.showsMemoryRing)
            XCTAssertNil(unavailable.ringPercent)
        }
        XCTAssertFalse(state(battery: 100).showsMemoryRing)
    }

    @MainActor
    func testBatteryCapabilityRetriesUnknownAndCachesConfirmedDesktopWithoutPanel() async throws {
        let probe = BatteryAvailabilityProbe()
        let monitor = MenuBarAuxiliaryMonitorState(
            batteryAvailabilityProvider: { probe.read() },
            batterySnapshotProvider: { (nil, nil) }, powerHistoryURL: nil
        )
        defer { monitor.setPaused(true) }
        for expected in [InternalBatteryAvailability.unknown, .absent, .absent] {
            monitor.refreshBackgroundBatteryHistory(force: true)
            let deadline = Date().addingTimeInterval(3)
            while monitor.isRefreshingLocalData, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(monitor.isRefreshingLocalData)
            XCTAssertEqual(monitor.internalBatteryAvailability, expected)
        }
        XCTAssertEqual(probe.count, 2)
        XCTAssertEqual(monitor.activeConsumerCount, 0)
    }

    func testRSSIBoundariesAndMissingSignal() {
        for (rssi, level) in [(-100, 0), (-81, 0), (-80, 1), (-68, 1),
                              (-67, 2), (-56, 2), (-55, 3), (-33, 3)] {
            XCTAssertEqual(MenuBarWiFiSignalState.connected(rssi: rssi).level, level)
        }
        XCTAssertEqual(MenuBarWiFiSignalState.resolve(rssi: 0, serviceActive: true, hasChannel: true), .unknown)
        XCTAssertEqual(MenuBarWiFiSignalState.resolve(rssi: 0, serviceActive: false, hasChannel: false), .disconnected)
        XCTAssertEqual(MenuBarWiFiSignalState.resolve(rssi: 5, serviceActive: true, hasChannel: true), .unknown)
        XCTAssertEqual(MenuBarWiFiSignalState.resolve(rssi: -500, serviceActive: true, hasChannel: true), .unknown)
        XCTAssertNil(MenuBarWiFiSignalState.off.level)
        XCTAssertNil(MenuBarWiFiSignalState.unknown.level)
    }

    func testMeasuredValuesKeepZeroFullAndMissingDistinct() {
        let zero = state(battery: 0, memory: 0)
        XCTAssertEqual(zero.batteryText, "0%")
        XCTAssertEqual(zero.memoryText, "0%")
        let full = state(battery: 100, memory: 1)
        XCTAssertEqual(full.batteryText, "100%")
        XCTAssertEqual(full.memoryText, "100%")
        XCTAssertEqual(state(battery: nil, memory: nil).batteryText, "—")
        for ratio in [Double.nan, .infinity, -0.01, 1.01] {
            XCTAssertNil(state(battery: 101, memory: ratio).memoryPercent)
            XCTAssertNil(state(battery: 101, memory: ratio).batteryPercent)
        }
    }

    @MainActor
    func testStatusAppearanceNotificationsOnlyInvalidateForAChangedThemeOrValue() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let base = MenuBarStatusRenderIdentity(summary: "电量 80%，内存 64%", appearance: light)
        for _ in 0..<100 {
            let notifiedAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
            XCTAssertEqual(base, MenuBarStatusRenderIdentity(summary: base.summary, appearance: notifiedAppearance))
        }
        XCTAssertNotEqual(base, MenuBarStatusRenderIdentity(summary: base.summary, appearance: dark))
        XCTAssertNotEqual(base, MenuBarStatusRenderIdentity(summary: "电量 79%，内存 64%", appearance: light))
        XCTAssertEqual(base.appearanceName, .aqua)
    }

    func testIndependentChangesInvalidateTheStatusSummary() {
        let base = state()
        XCTAssertNotEqual(base.accessibilitySummary, state(battery: 79).accessibilitySummary)
        XCTAssertNotEqual(base.accessibilitySummary, state(memory: 0.65).accessibilitySummary)
        XCTAssertNotEqual(base.accessibilitySummary, state(wifi: .connected(rssi: -81)).accessibilitySummary)
        XCTAssertNotEqual(base.accessibilitySummary, state(charging: true).accessibilitySummary)
        XCTAssertNotEqual(base.accessibilitySummary, state(paused: true).accessibilitySummary)
        XCTAssertNotEqual(state(wifi: .off).accessibilitySummary, state(wifi: .unknown).accessibilitySummary)
    }

    @MainActor
    func testBatteryColorBoundariesAndChargingPriority() {
        for (percent, tint) in [(0, MenuBarDeviceStatusSnapshot.BatteryTint.critical),
                                (19, .critical), (20, .low), (21, .low),
                                (49, .low), (50, .normal), (100, .normal)] {
            XCTAssertEqual(state(battery: percent).batteryTint, tint)
            XCTAssertEqual(state(battery: percent, charging: true).batteryTint, .charging)
        }
        let charged = MenuBarDeviceStatusSnapshot(
            batteryPercent: 100, isCharging: false, memoryUsedRatio: 1, wiFi: .off,
            isFullyCharged: true, isConnectedToAC: true
        )
        XCTAssertEqual(charged.batteryTint, .full)
        for dark in [false, true] {
            XCTAssertEqual(MenuBarDeviceStatusDrawing.batteryColor(.charging, dark: dark),
                           MenuBarDeviceStatusDrawing.batteryColor(.full, dark: dark))
        }
        XCTAssertNotEqual(charged.accessibilitySummary, state(battery: 100, memory: 1, wifi: .off).accessibilitySummary)
        let unplugged = MenuBarDeviceStatusSnapshot(
            batteryPercent: 100, isCharging: false, memoryUsedRatio: 1, wiFi: .off,
            isFullyCharged: true, isConnectedToAC: false
        )
        XCTAssertEqual(unplugged.batteryTint, .normal)
    }

    func testEverySavedModeRemainsReadableAndInvalidValuesUseNewDefault() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(MenuBarStatusDisplayMode.stored(in: defaults), .deviceStatus)
        for mode in MenuBarStatusDisplayMode.allCases {
            mode.save(in: defaults)
            XCTAssertEqual(MenuBarStatusDisplayMode.stored(in: defaults), mode)
        }
        defaults.set("retired-value", forKey: MenuBarStatusDisplayMode.defaultsKey)
        XCTAssertEqual(MenuBarStatusDisplayMode.stored(in: defaults), .deviceStatus)
    }

    @MainActor
    func testAllStatesHaveStableNativeColoredGeometry() throws {
        for snapshot in visualStates.map(\.1) {
            let image = MenuBarStatusRenderer.image(for: nil, mode: .deviceStatus, deviceStatus: snapshot)
            XCTAssertEqual(image.size, NSSize(width: 28, height: 24))
            XCTAssertFalse(image.isTemplate)
            XCTAssertNotNil(image.tiffRepresentation)
            XCTAssertFalse(image.representations.contains { $0 is NSCustomImageRep })
        }
        // Export only when explicitly requested for the visual review. This
        // invokes the same drawing function as the installed status item.
        if let directory = ProcessInfo.processInfo.environment["SCM_DUO_RENDER_DIR"] {
            let previous = UserDefaults.standard.object(forKey: L10n.languageDefaultsKey)
            defer {
                if let previous {
                    UserDefaults.standard.set(previous, forKey: L10n.languageDefaultsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey)
                }
                NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
            }
            for language in [AppLanguage.zhHans, .english] {
                UserDefaults.standard.set(language.rawValue, forKey: L10n.languageDefaultsKey)
                NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
                try exportNativeContactSheets(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(language.rawValue)
                )
            }
        }
    }

    @MainActor
    func testHighlightedStatusItemRetainsReadableInkOnLightBackground() throws {
        for (appearance, lightInk) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            let image = MenuBarDeviceStatusDrawing.image(
                for: state(), appearance: NSAppearance(named: appearance), highlighted: true
            )
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            var readablePixels = 0
            for x in (bitmap.pixelsWide * 9 / 28)..<(bitmap.pixelsWide * 19 / 28) {
                for y in (bitmap.pixelsHigh * 9 / 24)..<(bitmap.pixelsHigh * 15 / 24) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          color.alphaComponent > 0.8 else { continue }
                    let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    if lightInk ? brightness > 0.8 : brightness < 0.2 { readablePixels += 1 }
                }
            }
            XCTAssertGreaterThan(readablePixels, 3, "Center digits must contrast with the status background")
        }
    }

    @MainActor
    func testWiFiSamplingContinuesWithoutPanelAndHonorsPauseAndCadence() async throws {
        let probe = WiFiProbe()
        let monitor = MenuBarAuxiliaryMonitorState(
            statusWiFiProvider: { probe.read($0) }, powerHistoryURL: nil
        )
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(monitor.activeConsumerCount, 0)
        monitor.refreshStatusWiFi(lowPower: false, now: start)
        try await waitForSample(monitor, at: start)
        XCTAssertEqual(probe.count, 1)
        monitor.refreshStatusWiFi(lowPower: false, now: start.addingTimeInterval(4))
        XCTAssertEqual(probe.count, 1)
        monitor.refreshStatusWiFi(lowPower: false, now: start.addingTimeInterval(5))
        try await waitForSample(monitor, at: start.addingTimeInterval(5))
        XCTAssertEqual(probe.count, 2)
        monitor.refreshStatusWiFi(lowPower: true, now: start.addingTimeInterval(34))
        XCTAssertEqual(probe.count, 2)
        monitor.refreshStatusWiFi(lowPower: true, now: start.addingTimeInterval(35))
        try await waitForSample(monitor, at: start.addingTimeInterval(35))
        monitor.setPaused(true)
        monitor.refreshStatusWiFi(lowPower: false, force: true, now: start.addingTimeInterval(50))
        XCTAssertEqual(probe.count, 3)
        monitor.setPaused(false)
        monitor.refreshStatusWiFi(lowPower: false, force: true, now: start.addingTimeInterval(51))
        try await waitForSample(monitor, at: start.addingTimeInterval(51))
        XCTAssertEqual(probe.count, 4)
        XCTAssertEqual(monitor.activeConsumerCount, 0)
    }

    @MainActor
    private func waitForSample(_ monitor: MenuBarAuxiliaryMonitorState, at date: Date) async throws {
        let deadline = Date().addingTimeInterval(3)
        while monitor.statusWiFiSnapshot?.sampledAt != date, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(monitor.statusWiFiSnapshot?.sampledAt, date)
    }

    private func state(
        battery: Int? = 80, memory: Double? = 0.64,
        wifi: MenuBarWiFiSignalState = .connected(rssi: -55),
        charging: Bool = false, paused: Bool = false
    ) -> MenuBarDeviceStatusSnapshot {
        .init(batteryPercent: battery, isCharging: charging,
              memoryUsedRatio: memory, wiFi: wifi, isPaused: paused)
    }

    private func desktopState(memory: Double?) -> MenuBarDeviceStatusSnapshot {
        .init(batteryPercent: nil, isCharging: nil, memoryUsedRatio: memory,
              wiFi: .connected(rssi: -55), batteryAvailability: .absent)
    }

    private var visualStates: [(String, MenuBarDeviceStatusSnapshot)] {
        [
            ("Desktop · memory 64", desktopState(memory: 0.64)),
            ("Desktop · memory 0", desktopState(memory: 0)),
            ("Desktop · memory 100", desktopState(memory: 1)),
            ("Desktop · unknown", desktopState(memory: nil)),
            ("80 / 64 · strong", state()),
            ("100 / 100 unplugged", state(battery: 100, memory: 1)),
            ("full on AC", .init(batteryPercent: 100, isCharging: false, memoryUsedRatio: 0.78,
                                wiFi: .connected(rssi: -30), isFullyCharged: true, isConnectedToAC: true)),
            ("49 / 78 · orange", state(battery: 49, memory: 0.78)),
            ("50 / 78 · yellow", state(battery: 50, memory: 0.78)),
            ("20 / 9 · deep orange", state(battery: 20, memory: 0.09, wifi: .connected(rssi: -67))),
            ("19 / 64 · red", state(battery: 19)),
            ("charging at 5 · green", state(battery: 5, charging: true)),
            ("5 / 64 · weak", state(battery: 5, wifi: .connected(rssi: -80))),
            ("0 / 0 · very weak", state(battery: 0, memory: 0, wifi: .connected(rssi: -90))),
            ("charging", state(charging: true)),
            ("Wi-Fi off", state(wifi: .off)),
            ("disconnected", state(wifi: .disconnected)),
            ("unknown", state(battery: nil, memory: nil, wifi: .unknown))
        ]
    }

    @MainActor
    private func exportNativeContactSheets(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try String(describing: BatteryPowerService.internalBatteryAvailability()).write(
            to: directory.appendingPathComponent("本机电池能力.txt"), atomically: true, encoding: .utf8
        )
        for scale in [1, 2, 4] {
            let width = 580, height = 42 + visualStates.count * 38
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            rep.size = NSSize(width: width, height: height)
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            for (index, entry) in visualStates.enumerated() {
                let y = CGFloat(height - 40 - index * 38)
                (entry.0 as NSString).draw(at: NSPoint(x: 12, y: y + 5), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black
                ])
                for (column, background) in [
                    (0, NSColor(calibratedWhite: 0.93, alpha: 1)),
                    (1, NSColor(calibratedWhite: 0.12, alpha: 1)),
                    (2, NSColor(calibratedWhite: 0.84, alpha: 1))
                ] {
                    let x = CGFloat(210 + column * 116)
                    background.setFill()
                    NSRect(x: x - 5, y: y - 2, width: 82, height: 28).fill()
                    let glyph = MenuBarDeviceStatusDrawing.image(
                        for: entry.1,
                        appearance: NSAppearance(named: column == 1 ? .darkAqua : .aqua),
                        highlighted: column == 2
                    )
                    glyph.draw(at: NSPoint(x: x + 22, y: y), from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("Duo-\(scale)x.png"))
        }
    }
}

private final class WiFiProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var count: Int { lock.withLock { reads } }
    func read(_ date: Date) -> MenuBarWiFiStatusSnapshot {
        lock.withLock { reads += 1 }
        return .init(sampledAt: date, state: .connected(rssi: -55))
    }
}

private final class BatteryAvailabilityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var count: Int { lock.withLock { reads } }
    func read() -> InternalBatteryAvailability {
        lock.withLock {
            reads += 1
            return reads == 1 ? .unknown : .absent
        }
    }
}
