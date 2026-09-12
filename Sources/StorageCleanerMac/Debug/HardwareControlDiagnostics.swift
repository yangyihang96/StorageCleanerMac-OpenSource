#if DEBUG || STORAGE_CLEANER_BETA
import AppKit
import FanControlShared
import Foundation
import os
@preconcurrency import ServiceManagement

/// Development-only probe for the privileged helper registration path.
///
/// Approving a system-control daemon is always a user decision in System
/// Settings; this probe never bypasses that. It only runs the same
/// `FanControlCoordinator` entry point the panel button uses and writes the
/// resulting launchd state to the unified log, so a registration failure can be
/// diagnosed without guessing which of the many preconditions rejected it.
@MainActor
enum HardwareControlDiagnostics {
    static let launchArgument = "--diagnose-hardware-control"
    static let writesLaunchArgument = "--diagnose-hardware-writes"
    static let maxHoldLaunchArgument = "--diagnose-fan-max-hold"

    private static let logger = Logger(
        subsystem: StorageCleanerBuildIdentity.appBundleIdentifier,
        category: "HardwareControlDiagnostics"
    )

    /// Written alongside the unified log because the log store is not readable
    /// in every development environment.
    static let reportPath = "/tmp/storage-cleaner-hardware-probe.txt"

    static func runRegistrationProbe() async {
        let coordinator = FanControlCoordinator.shared
        var lines: [String] = []
        func record(_ line: String) {
            lines.append(line)
            logger.log("probe: \(line, privacy: .public)")
        }

        record("plist name=\(FanControlCoordinator.helperPlistName)")
        record("bundled plist present=\(bundledPlistPresent)")
        record("bundled helper present=\(bundledHelperPresent)")
        record("service status before=\(statusDescription(serviceStatus))")
        record("coordinator status before=\(helperDescription(coordinator.helperStatus))")

        await coordinator.registerHelper()

        record("service status after=\(statusDescription(serviceStatus))")
        record("coordinator status after=\(helperDescription(coordinator.helperStatus))")
        record("helper reachable=\(coordinator.isHelperReachable)")
        record("message=\(coordinator.lastMessage ?? "none")")

        let report = lines.joined(separator: "\n") + "\n"
        try? report.write(
            to: URL(fileURLWithPath: reportPath),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Exercises the production power-mode and manual-fan paths once, with
    /// verified readbacks, then restores the original state. Every value in
    /// the report comes from the helper's own readback or the live SMC
    /// telemetry — nothing is assumed successful.
    static let writesReportPath = "/tmp/storage-cleaner-hardware-writes.txt"

    static func runWritesProbe() async {
        let coordinator = FanControlCoordinator.shared
        var lines: [String] = []
        func record(_ line: String) {
            lines.append(line)
            logger.log("writes: \(line, privacy: .public)")
        }
        func flush() {
            let report = lines.joined(separator: "\n") + "\n"
            try? report.write(
                to: URL(fileURLWithPath: writesReportPath),
                atomically: true,
                encoding: .utf8
            )
        }
        func sleepSeconds(_ seconds: Double) async {
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        }
        func fanLine(_ label: String) {
            let readings = coordinator.latestFanReadings
            guard !readings.isEmpty else {
                record("\(label): no fan telemetry yet")
                return
            }
            let summary = readings.map { reading in
                let target = reading.targetRPM.map(String.init) ?? "—"
                return "fan\(reading.index) actual=\(reading.actualRPM) target=\(target)"
                    + " range=\(reading.minimumRPM.map(String.init) ?? "?")-\(reading.maximumRPM.map(String.init) ?? "?")"
            }.joined(separator: " | ")
            record("\(label): \(summary)")
        }

        record("=== hardware writes probe ===")
        await coordinator.registerHelper()
        record("helper status=\(helperDescription(coordinator.helperStatus)) reachable=\(coordinator.isHelperReachable)")
        guard coordinator.helperStatus == .enabled, coordinator.isHelperReachable else {
            record("ABORT: helper is not enabled and reachable")
            flush()
            return
        }

        // --- Power mode: battery profile lowPower -> highPower -> automatic ---
        record("--- power mode (battery profile) ---")
        for (mode, label) in [
            (BatteryPowerMode.lowPower, "lowPower(1)"),
            (BatteryPowerMode.highPower, "highPower(2)"),
            (BatteryPowerMode.automatic, "automatic(0)")
        ] {
            guard let command = BatteryPowerModeWriteCommand.make(
                source: .batteryPower,
                mode: mode
            ) else {
                record("power \(label): command construction failed")
                continue
            }
            do {
                let verified = try await coordinator.applyPowerMode(command)
                record(
                    "power \(label): VERIFIED battery=\(verified.battery.map(String.init(describing:)) ?? "nil")"
                    + " adapter=\(verified.adapter.map(String.init(describing:)) ?? "nil")"
                )
            } catch {
                record("power \(label): FAILED \(error)")
            }
            flush()
        }

        // --- Manual fan boost, verified readback, then restore automatic ---
        record("--- manual fan control ---")
        var waited = 0.0
        while coordinator.latestFanReadings.isEmpty, waited < 40 {
            await sleepSeconds(2)
            waited += 2
        }
        fanLine("baseline")

        coordinator.manualFraction = 0.3
        record("requesting manual mode at fraction 0.30")
        await coordinator.selectMode(.manual)
        for step in 1...8 {
            await sleepSeconds(2.5)
            fanLine("manual t+\(String(format: "%.0f", Double(step) * 2.5))s")
            let confirmed = coordinator.confirmedManualFractionByFan
            if !confirmed.isEmpty {
                record("confirmed fractions=\(confirmed.sorted(by: { $0.key < $1.key }).map { "fan\($0.key)=\(String(format: "%.2f", $0.value))" }.joined(separator: " "))")
            }
            record("observedMode=\(coordinator.observedMode.map(String.init(describing:)) ?? "unverified") message=\(coordinator.lastMessage ?? "none")")
            flush()
        }

        record("restoring system automatic")
        await coordinator.selectMode(.systemAutomatic)
        for step in 1...4 {
            await sleepSeconds(2.5)
            fanLine("restore t+\(String(format: "%.0f", Double(step) * 2.5))s")
            record("observedMode=\(coordinator.observedMode.map(String.init(describing:)) ?? "unverified")")
            flush()
        }
        record("=== probe complete ===")
        flush()
    }

    /// Reproduces the reported "set to maximum, reverts by itself" flow:
    /// hold manual 100% for 45 seconds and log every state transition the
    /// safety layer makes, so the exact fail-closed trigger is visible.
    static let maxHoldReportPath = "/tmp/storage-cleaner-fan-max-hold.txt"

    static func runMaxHoldProbe() async {
        let coordinator = FanControlCoordinator.shared
        var lines: [String] = []
        func record(_ line: String) {
            lines.append(line)
            logger.log("maxHold: \(line, privacy: .public)")
        }
        func flush() {
            let report = lines.joined(separator: "\n") + "\n"
            try? report.write(
                to: URL(fileURLWithPath: maxHoldReportPath),
                atomically: true,
                encoding: .utf8
            )
        }
        func stateLine(_ label: String) {
            let readings = coordinator.latestFanReadings
            let fans = readings.map { reading in
                "fan\(reading.index) actual=\(reading.actualRPM)"
                    + " target=\(reading.targetRPM.map(String.init) ?? "—")"
                    + " max=\(reading.maximumRPM.map(String.init) ?? "?")"
            }.joined(separator: " | ")
            record(
                "\(label): \(fans.isEmpty ? "no telemetry" : fans)"
                + " selected=\(String(describing: coordinator.selectedMode))"
                + " observed=\(coordinator.observedMode.map(String.init(describing:)) ?? "nil")"
                + " message=\(coordinator.lastMessage ?? "none")"
            )
        }

        func instanceCount() -> Int {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: StorageCleanerBuildIdentity.appBundleIdentifier
            ).count
        }

        record("=== fan max-hold probe v2 ===")
        record("app instances at start=\(instanceCount())")
        await coordinator.registerHelper()
        record("helper=\(helperDescription(coordinator.helperStatus)) reachable=\(coordinator.isHelperReachable)")
        guard coordinator.helperStatus == .enabled, coordinator.isHelperReachable else {
            record("ABORT: helper not enabled/reachable")
            flush()
            return
        }
        var waited = 0.0
        while coordinator.latestFanReadings.isEmpty, waited < 40 {
            try? await Task.sleep(for: .seconds(2))
            waited += 2
        }
        stateLine("baseline")

        // Mirror the real user flow: enter manual first, then drag to 100%.
        record("selecting manual")
        await coordinator.selectMode(.manual)
        stateLine("after selectMode(manual)")
        try? await Task.sleep(for: .seconds(2))
        record("committing manual percentage 100")
        coordinator.commitManualPercentage(100)

        // High-frequency polling records every message/mode transition, so a
        // fail-closed reason cannot be masked by a later state change.
        var lastLoggedSignature = ""
        var reverted = false
        for tick in 1...100 {
            try? await Task.sleep(for: .milliseconds(500))
            let readings = coordinator.latestFanReadings
            let fans = readings.map {
                "f\($0.index)=\($0.actualRPM)/\($0.targetRPM.map(String.init) ?? "—")"
            }.joined(separator: " ")
            let signature = "sel=\(String(describing: coordinator.selectedMode))"
                + " req=\(coordinator.requestedMode.map(String.init(describing:)) ?? "nil")"
                + " obs=\(coordinator.observedMode.map(String.init(describing:)) ?? "nil")"
                + " switching=\(coordinator.isSwitchingMode) applying=\(coordinator.isApplying)"
                + " msg=\(coordinator.lastMessage ?? "none")"
            if signature != lastLoggedSignature {
                record("t+\(String(format: "%.1f", Double(tick) * 0.5))s \(fans) \(signature) instances=\(instanceCount())")
                lastLoggedSignature = signature
                flush()
            }
            if !reverted, coordinator.selectedMode == .systemAutomatic {
                reverted = true
                record("REVERTED at t+\(String(format: "%.1f", Double(tick) * 0.5))s")
                flush()
            }
        }

        record("restoring system automatic")
        await coordinator.selectMode(.systemAutomatic)
        try? await Task.sleep(for: .seconds(3))
        stateLine("restored")
        record("=== probe complete ===")
        flush()
    }

    private static var serviceStatus: SMAppService.Status {
        SMAppService.daemon(plistName: FanControlCoordinator.helperPlistName).status
    }

    private static var bundledPlistPresent: Bool {
        guard let bundleURL = Bundle.main.bundleURL as URL? else { return false }
        let plistURL = bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons")
            .appendingPathComponent(FanControlCoordinator.helperPlistName)
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    private static var bundledHelperPresent: Bool {
        Bundle.main.url(
            forResource: LegacyFanControlHelperInstaller.bundledHelperName,
            withExtension: nil
        ) != nil
    }

    private static func statusDescription(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    private static func helperDescription(_ status: FanControlHelperStatus) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .requiresApproval: "requiresApproval"
        case .enabled: "enabled"
        case .needsMigration: "needsMigration"
        case .unavailable: "unavailable"
        }
    }
}
#endif
