import Foundation
import XCTest
@testable import StorageCleanerMac

final class ComputerHealthSecuritySourceGuardTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testSecurityCommandsAreOnlyTheFourFixedReadOnlyInvocations() throws {
        let text = try source("Sources/StorageCleanerMac/Services/SystemProtectionAudit.swift")
        let start = try XCTUnwrap(text.range(of: "static func runCommand("))
        let end = try XCTUnwrap(text.range(of: "static func check("))
        let command = String(text[start.lowerBound..<end.lowerBound])
        let pattern = #"case \.(\w+):\s*executable = "([^"]+)"\s*arguments = \[([^\]]*)\]"#
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: command, range: NSRange(command.startIndex..., in: command))
        var invocations: [String: String] = [:]
        for match in matches {
            let check = try XCTUnwrap(Range(match.range(at: 1), in: command))
            let executable = try XCTUnwrap(Range(match.range(at: 2), in: command))
            let arguments = try XCTUnwrap(Range(match.range(at: 3), in: command))
            invocations[String(command[check])] = String(command[executable]) + " " + String(command[arguments])
        }
        XCTAssertEqual(matches.count, 4)
        XCTAssertEqual(invocations, [
            "systemIntegrityProtection": "/usr/bin/csrutil \"status\"",
            "fileVault": "/usr/bin/fdesetup \"status\"",
            "gatekeeper": "/usr/sbin/spctl \"--status\"",
            "firewall": "/usr/libexec/ApplicationFirewall/socketfilterfw \"--getglobalstate\""
        ])
        XCTAssertTrue(command.contains("static func runCommand(for check: SystemProtectionCheck)"))
        XCTAssertTrue(command.contains("Shell.run(executable, arguments, timeout: 3, outputByteLimit: 8_192"))
        XCTAssertTrue(command.contains("cancellationCheck:"))
        for forbidden in ["/bin/sh", "/bin/zsh", "/bin/bash", "sudo", "AuthorizationExecuteWithPrivileges", "Process(", "environment:"] {
            XCTAssertFalse(command.contains(forbidden), forbidden)
        }
        for setter in ["--setglobalstate", "--setstealthmode", "--master-disable", "--master-enable", "[\"enable\"]", "[\"disable\"]"] {
            XCTAssertFalse(text.contains(setter), setter)
        }
    }

    func testHealthProbeAndSmartScanUseTheSameSecurityAndEventPipeline() throws {
        let health = try source("Sources/StorageCleanerMac/Stores/ComputerHealthStore.swift")
        let smart = try source("Sources/StorageCleanerMac/Stores/ScanStore.swift")
        XCTAssertTrue(health.contains(".security(await SystemProtectionAudit.check())"))
        XCTAssertTrue(health.contains("eventRepository.recordChanges(snapshot)"))
        XCTAssertTrue(health.contains("changeLogWasReset = recording.recoveredUnrecognizedJournal"))
        XCTAssertTrue(health.contains("recentChanges: changes, changeLogReadFailed: changeLogReadFailed"))
        XCTAssertTrue(smart.contains("smartScanHealthOperation: @escaping SmartScanHealthOperation = {\n            try await DefaultComputerHealthProbe().probe()"))
    }

    func testResultViewsShareStatusRowsShowFiveChangesAndDoNotLaunchProcesses() throws {
        let rows = try source("Sources/StorageCleanerMac/Views/ComputerHealth/HealthSecurityChecksView.swift")
        let health = try source("Sources/StorageCleanerMac/Views/ComputerHealthView.swift")
        let smart = try source("Sources/StorageCleanerMac/Views/SmartScanHealthResultsView.swift")
        XCTAssertTrue(rows.contains("ForEach(SystemProtectionCheck.healthChecks)"))
        XCTAssertTrue(rows.contains("FeatureLightfieldStatusDisclosure("))
        XCTAssertTrue(rows.contains("CleanupService.openSecuritySettings(for: check)"))
        XCTAssertTrue(rows.contains("if !events.isEmpty"))
        XCTAssertTrue(rows.contains("maximumEntryCount : 5"))
        XCTAssertTrue(rows.contains("isExpanded.toggle()"))
        XCTAssertTrue(rows.contains("FeatureLightfieldStatusRow(title: L10n.text(\"变化日志\", \"Change Log\")"))
        XCTAssertTrue(rows.contains("if readFailed {\n                FeatureLightfieldStatusRow(title: L10n.text(\"变化日志\", \"Change Log\"),"))
        XCTAssertTrue(rows.contains("FeatureLightfieldRowButtonStyle()"))
        XCTAssertTrue(smart.contains("FeatureLightfieldStatusRow("))
        XCTAssertFalse(smart.contains("FeatureFormRow("))
        XCTAssertTrue(rows.contains("detail: finding?.evidenceSummary"))
        for text in [health, smart] {
            XCTAssertTrue(text.contains("HealthSecurityChecksView(snapshot:"))
            XCTAssertTrue(text.contains("HealthRecentChangesView(events:"))
        }
        let process = try NSRegularExpression(pattern: #"\bProcess\s*\("#)
        for (name, text) in [("health", health), ("smart", smart), ("rows", rows)] {
            XCTAssertEqual(process.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)), 0, name)
            XCTAssertFalse(text.contains("Shell.run("), name)
            XCTAssertFalse(text.contains("Shell.capture"), name)
            XCTAssertFalse(text.contains("SystemProtectionAudit.check("), name)
        }
    }

    func testSettingsDestinationsUseExistingSystemPreferencesOpenerAndLocalJournalRoot() throws {
        for destination: CleanupService.SystemSettingsDestination in [.privacySecurity, .gatekeeper, .fileVault, .firewall] {
            let urls = CleanupService.systemSettingsURLs(for: destination)
            XCTAssertFalse(urls.isEmpty)
            XCTAssertTrue(urls.allSatisfy { $0.scheme == "x-apple.systempreferences" })
        }
        XCTAssertEqual(CleanupService.systemSettingsURLs(for: .gatekeeper).first?.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Security")
        XCTAssertEqual(CleanupService.systemSettingsURLs(for: .fileVault).last?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?FDE")
        let settings = try source("Sources/StorageCleanerMac/Services/CleanupService.swift")
        XCTAssertTrue(settings.contains("static func openSecuritySettings(for check: SystemProtectionCheck)"))
        XCTAssertTrue(settings.contains("case .fileVault: openSystemSettings(.fileVault)"))
        XCTAssertTrue(settings.contains("case .firewall: openSystemSettings(.firewall)"))
        XCTAssertTrue(settings.contains("case .gatekeeper: openSystemSettings(.gatekeeper)"))
        let journal = try source("Sources/StorageCleanerMac/Services/ComputerHealthEventRepository.swift")
        XCTAssertTrue(journal.contains("AppDataDirectories.applicationSupportRoot"))
        XCTAssertTrue(journal.contains("try data.write(to: storageURL, options: .atomic)"))
        XCTAssertFalse(journal.contains("UserDefaults"))
        XCTAssertFalse(journal.contains("URLSession"))
    }
}
