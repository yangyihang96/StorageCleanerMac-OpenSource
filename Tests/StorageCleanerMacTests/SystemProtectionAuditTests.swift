import XCTest
@testable import StorageCleanerMac

final class SystemProtectionAuditTests: XCTestCase {
    func testFourHealthChecksRecognizeEnglishAndChineseStatusLines() {
        let samples: [(SystemProtectionCheck, String, SystemProtectionState)] = [
            (.systemIntegrityProtection, "System Integrity Protection status: enabled.\n", .enabled),
            (.systemIntegrityProtection, "系统完整性保护状态：已启用。", .enabled),
            (.systemIntegrityProtection, "系统完整性保护状态:已启用。", .enabled),
            (.systemIntegrityProtection, "系统完整性保护状态：已关闭。", .disabled),
            (.fileVault, "FileVault is On.", .enabled),
            (.fileVault, "FileVault is Off.", .disabled),
            (.fileVault, "FileVault 已开启。", .enabled),
            (.fileVault, "FileVault 已关闭。", .disabled),
            (.gatekeeper, "评估已启用", .enabled),
            (.gatekeeper, "评估已禁用", .disabled),
            (.firewall, "防火墙已启用。(状态 = 1)", .enabled),
            (.firewall, "防火墙已关闭。(状态 = 0)", .disabled),
            (.firewall, "Firewall is enabled. (State = 2)", .enabled)
        ]
        for (check, output, expected) in samples {
            XCTAssertEqual(SystemProtectionAudit.finding(from: result(output), for: check).state, expected, output)
        }
        XCTAssertEqual(SystemProtectionCheck.healthChecks.count, 4)
    }

    func testUnknownContradictoryCustomAndMisleadingResponsesNeverBecomeNormal() {
        let samples: [(SystemProtectionCheck, String)] = [
            (.gatekeeper, "error: assessments enabled could not be read"),
            (.gatekeeper, "assessments enabled\nassessments disabled"),
            (.fileVault, "FileVault is On.\nFileVault is Off."),
            (.fileVault, "Not FileVault is On."),
            (.systemIntegrityProtection, "System Integrity Protection status: enabled (Custom Configuration)."),
            (.firewall, "State = 10"),
            (.firewall, "Firewall is disabled. (State = 1)"),
            (.firewall, "unrecognized status"),
            (.gatekeeper, "")
        ]
        for (check, output) in samples {
            XCTAssertEqual(SystemProtectionAudit.finding(from: result(output), for: check).state, .unknown, output)
        }
    }

    /// Byte-exact stdout captured read-only on macOS 27.2 (2026-10-09). The four
    /// tools printed identical English text under en_US and zh_CN locales.
    func testRealCommandOutputsCapturedOnMacOS27() {
        let samples: [(SystemProtectionCheck, String, SystemProtectionState)] = [
            (.systemIntegrityProtection, "System Integrity Protection status: enabled.\n", .enabled),
            (.fileVault, "FileVault is On.\n", .enabled),
            (.gatekeeper, "assessments enabled\n", .enabled),
            (.firewall, "Firewall is disabled. (State = 0)\n", .disabled),
            (.firewall, "Firewall is enabled. (State = 1)\n", .enabled)
        ]
        for (check, output, expected) in samples {
            XCTAssertEqual(SystemProtectionAudit.finding(from: result(output), for: check).state, expected, output)
        }
    }

    func testTwoLineFileVaultConversionOutputIsTransitioningButOtherSecondLinesAreUnknown() {
        XCTAssertEqual(SystemProtectionAudit.parse(
            "FileVault is On.\nEncryption in progress: Percent completed = 12.34\n", for: .fileVault), .transitioning)
        XCTAssertEqual(SystemProtectionAudit.parse(
            "FileVault is Off.\nDecryption in progress: Percent completed = 80.0\n", for: .fileVault), .transitioning)
        for output in ["FileVault is On.\nDeferred enablement appears to be active for user 'fixture'.",
                       "FileVault is Off, but will be enabled after the next restart.",
                       "Encryption in progress: Percent completed = 1\nFileVault is On.",
                       "FileVault is On.\nEncryption in progress: 1\nFileVault is Off."] {
            XCTAssertEqual(SystemProtectionAudit.parse(output, for: .fileVault), .unknown, output)
        }
    }

    func testFileVaultConversionDoesNotClaimEncryptionIsComplete() {
        for output in ["Encryption in progress: Percent completed = 25", "Decryption in progress: 75%", "正在加密：25%"] {
            XCTAssertEqual(SystemProtectionAudit.parse(output, for: .fileVault), .transitioning)
        }
    }

    /// Failed reads remain unreadable; only the exact Gatekeeper off/exit-1
    /// contract below is exempt, rather than every recognized off response.
    func testNonzeroExitAndStderrDoNotEstablishAnEnabledOrDisabledState() {
        for status: Int32 in [1, 2, 69] {
            XCTAssertEqual(SystemProtectionAudit.finding(from: result("assessments enabled", status: status), for: .gatekeeper).state, .unreadable)
            XCTAssertEqual(SystemProtectionAudit.finding(from: result("FileVault is Off.", status: status), for: .fileVault).state, .unreadable)
            let gatekeeperOff = SystemProtectionAudit.finding(from: result("assessments disabled", status: status), for: .gatekeeper)
            XCTAssertEqual(gatekeeperOff.state, status == 1 ? .disabled : .unreadable)
        }
        let stderrOnly = ShellCommandResult(terminationStatus: 0, standardOutput: "", standardError: "FileVault is On.")
        XCTAssertEqual(SystemProtectionAudit.finding(from: stderrOnly, for: .fileVault).state, .unknown)
    }

    /// Apple's open-source spctl exits 1 after printing "assessments disabled".
    func testGatekeeperOffWithDocumentedExitOneIsDisabledWarning() {
        for output in ["assessments disabled", "assessments disabled\n", "  assessments disabled \n"] {
            let finding = SystemProtectionAudit.finding(from: result(output, status: 1), for: .gatekeeper)
            XCTAssertEqual(finding.state, .disabled, output)
            XCTAssertEqual(finding.evidence, .systemQuery)
            XCTAssertEqual(HealthSecurityChecksView.status(for: finding.state), .warning)
        }
        XCTAssertEqual(SystemProtectionAudit.finding(from: result("assessments disabled\n"), for: .gatekeeper).state, .disabled)
    }

    func testOnlyThatExactGatekeeperShapeEscapesTheNonzeroExitRule() {
        let unreadable: [(SystemProtectionCheck, String, Int32)] = [
            (.gatekeeper, "assessments disabled\n", 2),
            (.gatekeeper, "assessments disabled\n", 69),
            (.gatekeeper, "assessments enabled\n", 1),
            (.gatekeeper, "assessments disabled\nassessments enabled", 1),
            (.gatekeeper, "error: assessments disabled", 1),
            (.gatekeeper, "ASSESSMENTS DISABLED", 1),
            (.gatekeeper, "assessments  disabled", 1),
            (.gatekeeper, "assessments disabled.", 1),
            (.gatekeeper, "评估已禁用", 1),
            (.gatekeeper, "", 1),
            (.fileVault, "FileVault is Off.\n", 1),
            (.systemIntegrityProtection, "System Integrity Protection status: disabled.\n", 1),
            (.firewall, "Firewall is disabled. (State = 0)\n", 1),
            // The exemption belongs to spctl only, even for the same bytes.
            (.fileVault, "assessments disabled\n", 1),
            (.systemIntegrityProtection, "assessments disabled\n", 1),
            (.firewall, "assessments disabled\n", 1)
        ]
        for (check, output, status) in unreadable {
            let finding = SystemProtectionAudit.finding(from: result(output, status: status), for: check)
            XCTAssertEqual(finding.state, .unreadable, "\(check) \(status) \(output)")
            XCTAssertEqual(finding.evidence, .readFailed(exitCode: status))
        }
    }

    @MainActor
    func testEvidenceIsStructuredAndLocalizedOnlyWhenDisplayed() throws {
        let finding = SystemProtectionAudit.finding(from: result("FileVault is On.\n"), for: .fileVault)
        XCTAssertEqual(finding.evidence, .systemQuery)
        let encoded = try JSONEncoder().encode(finding)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("系统查询"))
        XCTAssertFalse(text.contains("Confirmed"))
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            XCTAssertEqual(try JSONDecoder().decode(SystemProtectionFinding.self, from: encoded).evidenceSummary,
                language == .zhHans ? "系统查询确认（fdesetup status）" : "Confirmed by fdesetup status")
        }
        let legacy = Data(#"{"check":"firewall","state":{"disabled":{}},"evidenceSummary":"旧版证据"}"#.utf8)
        let decoded = try JSONDecoder().decode(SystemProtectionFinding.self, from: legacy)
        XCTAssertEqual(decoded.state, .disabled)
        XCTAssertEqual(decoded.evidence, .legacy("旧版证据"))
        XCTAssertEqual(decoded.evidenceSummary, "旧版证据")
    }

    func testTimeoutMissingCommandOutputLimitAndDenialAreUnreadable() async {
        let errors: [ShellError] = [.timedOut("fixture", 3), .outputTooLarge("fixture", 8_192),
            .failed("fixture", 1, "permission denied"), .terminationFailed("fixture")]
        for error in errors {
            let snapshot = await SystemProtectionAudit.check(runner: { _ in throw error })
            let healthFindings = snapshot.findings.filter { SystemProtectionCheck.healthChecks.contains($0.check) }
            XCTAssertEqual(healthFindings.count, 4)
            XCTAssertTrue(healthFindings.allSatisfy { $0.state == .unreadable })
            XCTAssertFalse(healthFindings.contains { $0.evidenceSummary.contains("fixture") })
        }
        let missing = await SystemProtectionAudit.check(runner: { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: 2)
        })
        XCTAssertTrue(missing.findings.filter { SystemProtectionCheck.healthChecks.contains($0.check) }
            .allSatisfy { $0.state == .unreadable })
    }

    func testBoundedCommandResultsBecomeStructuredEvidenceWithoutRawDiagnostics() async {
        let snapshot = await SystemProtectionAudit.check(runner: { check in
            switch check {
            case .fileVault: return protectionTestResult("FileVault is Off.")
            case .gatekeeper: return protectionTestResult("assessments enabled")
            case .firewall: return protectionTestResult("Firewall is enabled. (State = 1)")
            case .systemIntegrityProtection: return protectionTestResult("System Integrity Protection status: enabled.")
            case .xProtectInstallation: return protectionTestResult("")
            }
        })
        XCTAssertEqual(snapshot.findings.first { $0.check == .fileVault }?.state, .disabled)
        XCTAssertEqual(snapshot.findings.first { $0.check == .gatekeeper }?.state, .enabled)
    }

    private func result(_ stdout: String, status: Int32 = 0) -> ShellCommandResult {
        ShellCommandResult(terminationStatus: status, standardOutput: stdout, standardError: "")
    }

    func testRecognizedProtectionResponsesAndUnknownFailures() {
        XCTAssertEqual(SystemProtectionAudit.parse("assessments enabled", for: .gatekeeper), .enabled)
        XCTAssertEqual(SystemProtectionAudit.parse("assessments disabled", for: .gatekeeper), .disabled)
        XCTAssertEqual(SystemProtectionAudit.parse("Firewall is enabled. (State = 1)", for: .firewall), .enabled)
        XCTAssertEqual(SystemProtectionAudit.parse("Firewall is disabled. (State = 0)", for: .firewall), .disabled)
        XCTAssertEqual(SystemProtectionAudit.parse(
            "System Integrity Protection status: enabled.", for: .systemIntegrityProtection
        ), .enabled)
        XCTAssertEqual(SystemProtectionAudit.parse(
            "System Integrity Protection status: disabled.", for: .systemIntegrityProtection
        ), .disabled)
        XCTAssertEqual(SystemProtectionAudit.parse("permission denied", for: .firewall), .unknown)
        XCTAssertEqual(SystemProtectionAudit.parse("", for: .gatekeeper), .unknown)
    }
}

private func protectionTestResult(_ stdout: String) -> ShellCommandResult {
    ShellCommandResult(terminationStatus: 0, standardOutput: stdout, standardError: "")
}
