import Foundation
import SwiftUI
import XCTest
@testable import StorageCleanerMac

final class ComputerHealthSecurityIntegrationTests: XCTestCase {
    func testSnapshotRoundTripKeepsSecurityAndRecentChanges() throws {
        let event = ComputerHealthChangeEvent(id: UUID(), recordedAt: ComputerHealthSecurityFixture.date,
            check: .fileVault, oldState: .disabled, newState: .enabled, evidenceSummary: "Fixture evidence")
        let value = ComputerHealthSecurityFixture.snapshot(changes: [event])
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(ComputerHealthSnapshot.self, from: encoded), value)
    }

    func testLegacySnapshotDoesNotInventSecurityChecksOrEvents() throws {
        let legacy = ComputerHealthSecurityFixture.snapshot(securityState: nil)
        let encoded = try JSONEncoder().encode(legacy)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(keys["security"])
        XCTAssertNil(keys["recentChanges"])
        let decoded = try JSONDecoder().decode(ComputerHealthSnapshot.self, from: encoded)
        XCTAssertNil(decoded.security)
        XCTAssertTrue(decoded.recentChanges.isEmpty)
        XCTAssertFalse(decoded.changeLogReadFailed)
        XCTAssertFalse(decoded.changeLogWasReset)
    }

    func testSmartHealthScopeRetainsFourSecurityFindingsAndDoesNoFileWork() async throws {
        let home = try TestFileSystem.makeHome(for: self)
        let expected = ComputerHealthSecurityFixture.snapshot(securityState: .disabled)
        let recorder = SecurityHealthInvocationRecorder(snapshot: expected)
        let session = try await SmartScanReadOperation.run(request: CleanupScanRequest(userHomeURL: home),
            scopes: [.health], rulesVersion: "fixture", fileRuleCount: 0,
            cleanup: { _, _ in throw SecurityHealthFixtureError.unexpectedFileScan },
            health: { await recorder.probe() }, progress: { _ in })
        XCTAssertEqual(session.smartScanHealthStatus, .completed)
        XCTAssertEqual(session.smartScanHealthSnapshot, expected)
        XCTAssertEqual(session.smartScanHealthSnapshot?.security?.findings.map(\.check), SystemProtectionCheck.healthChecks)
        XCTAssertEqual(session.outcome, .complete)
        XCTAssertTrue(session.categories.isEmpty)
        let count = await recorder.count()
        XCTAssertEqual(count, 1)
    }

    func testUnselectedHealthScopeDoesNotRunSecurityOrStoreInventedHealth() async throws {
        let home = try TestFileSystem.makeHome(for: self)
        let recorder = SecurityHealthInvocationRecorder(snapshot: ComputerHealthSecurityFixture.snapshot())
        let session = try await SmartScanReadOperation.run(request: CleanupScanRequest(userHomeURL: home),
            scopes: [], rulesVersion: "fixture", fileRuleCount: 0,
            cleanup: { _, _ in throw SecurityHealthFixtureError.unexpectedFileScan },
            health: { await recorder.probe() }, progress: { _ in })
        XCTAssertNil(session.smartScanHealthSnapshot)
        XCTAssertEqual(session.smartScanHealthStatus, .notRequested)
        let count = await recorder.count()
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testDisabledConversionAndUnreadableRowsHaveDistinctSemanticSymbols() {
        XCTAssertEqual(HealthSecurityChecksView.status(for: .enabled), .normal)
        XCTAssertEqual(HealthSecurityChecksView.status(for: .disabled), .warning)
        XCTAssertEqual(HealthSecurityChecksView.status(for: .transitioning), .warning)
        XCTAssertEqual(HealthSecurityChecksView.status(for: .unreadable), .unknown)
        XCTAssertEqual(HealthSecurityChecksView.status(for: .unknown), .unknown)
        XCTAssertNotEqual(SystemProtectionState.unreadable.displayText, SystemProtectionState.unknown.displayText)
    }

#if DEBUG
    @MainActor
    func testSecurityRowsKeepExistingSymbolValueAndDisclosureColumnsAtSevenSizes() async throws {
        let windows: [CGSize] = [.init(width: 820, height: 560), .init(width: 1000, height: 700),
            .init(width: 1280, height: 763), .init(width: 1680, height: 1050), .init(width: 2400, height: 1350),
            .init(width: 677, height: 390), .init(width: 1280, height: 390)]
        let snapshot = ComputerHealthSecurityFixture.snapshot(securityState: .disabled)
        let evaluation = ComputerHealthScoring.evaluate(snapshot: snapshot, referenceDate: snapshot.generatedAt)
        for dark in [false, true] {
            for window in windows {
                let size = CGSize(width: window.width - 210, height: window.height - 28)
                let root = VStack(spacing: 0) {
                    HealthFactorGrid(evaluation: evaluation, snapshot: snapshot)
                    HealthSecurityChecksView(snapshot: snapshot.security)
                }
                // The bare component is shorter than the window; pin the fixture
                // viewport to the host size so frames(required:size:) can settle.
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .environment(\.featureDisablesLayoutAnimations, true)
                let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: dark)
                defer { host.close() }
                let leadingID = "lightfield.health.leading.diskReliability"
                let valueID = "lightfield.value." + HealthDashboardVisuals.factorTitle(.diskReliability)
                let disclosureID = "lightfield.health.disclosure.diskReliability"
                let required = Set([leadingID, valueID, disclosureID, "fixture.viewport"]
                    + SystemProtectionCheck.healthChecks.flatMap { check in [
                        "lightfield.health.security.leading.\(check.rawValue)",
                        "lightfield.health.security.disclosure.\(check.rawValue)", "lightfield.value." + check.title
                    ] })
                let frames = try await host.frames(required: required, size: size)
                let leading = try XCTUnwrap(frames[leadingID])
                let value = try XCTUnwrap(frames[valueID])
                let disclosure = try XCTUnwrap(frames[disclosureID])
                let viewport = try XCTUnwrap(frames["fixture.viewport"])
                for check in SystemProtectionCheck.healthChecks {
                    let symbol = try XCTUnwrap(frames["lightfield.health.security.leading.\(check.rawValue)"])
                    let state = try XCTUnwrap(frames["lightfield.value." + check.title])
                    let arrow = try XCTUnwrap(frames["lightfield.health.security.disclosure.\(check.rawValue)"])
                    XCTAssertEqual(symbol.minX, leading.minX, accuracy: 0.5)
                    XCTAssertEqual(symbol.width, 20, accuracy: 0.5)
                    XCTAssertEqual(state.maxX, value.maxX, accuracy: 0.5)
                    XCTAssertEqual(arrow.minX, disclosure.minX, accuracy: 0.5)
                    XCTAssertGreaterThanOrEqual(symbol.minX, viewport.minX - 0.5)
                    XCTAssertLessThanOrEqual(arrow.maxX, viewport.maxX + 0.5)
                }
            }
        }
    }

    @MainActor
    func testSecurityDisclosureExposesAdviceAndSettingsButtonWithoutExecutingAnOpener() async throws {
        let snapshot = ComputerHealthSecurityFixture.snapshot(securityState: .unreadable)
        let host = CalibrationAppKitLayoutHost(root: HealthSecurityChecksView(snapshot: snapshot.security),
            size: CGSize(width: 878, height: 500), dark: true)
        defer { host.close() }
        let label = SystemProtectionCheck.fileVault.title + " · " + SystemProtectionState.unreadable.displayText
        try await host.waitForAccessibility(labels: [label],
            expectedValues: [label: L10n.text("已折叠", "Collapsed")], pressLabels: [label])
        XCTAssertTrue(try host.press(label: label))
        try await host.waitForAccessibility(labels: [label, L10n.text("打开系统设置", "Open System Settings")],
            expectedValues: [label: L10n.text("已展开", "Expanded")])
        // Do not press the settings button; this fixture remains read-only.
    }

    @MainActor
    func testRecentChangesHideEmptyShowFiveAndExpandAll() async throws {
        let size = CGSize(width: 878, height: 1000)
        let empty = CalibrationAppKitLayoutHost(root: HealthRecentChangesView(events: [])
            .frame(width: size.width, height: size.height, alignment: .topLeading), size: size, dark: false)
        defer { empty.close() }
        _ = try await empty.frames(required: ["fixture.viewport"], size: size)
        XCTAssertNil(empty.element(label: L10n.text("最近变化", "Recent Changes")))
        let notice = L10n.text("变化日志", "Change Log") + " · "
            + L10n.text("原变化日志无法识别，已在同一目录备份原文件，并从本次检查重新开始记录。",
                "The previous change log was not recognized. The original file was kept as a backup and logging restarted with this check.")
            + " · " + L10n.text("已重新开始", "Restarted")
        XCTAssertNil(empty.element(label: notice))
        let reset = CalibrationAppKitLayoutHost(root: HealthRecentChangesView(events: [], journalReset: true)
            .frame(width: size.width, height: size.height, alignment: .topLeading), size: size, dark: true)
        defer { reset.close() }
        try await reset.waitForAccessibility(labels: [notice])
        XCTAssertNil(reset.element(label: L10n.text("最近变化", "Recent Changes")))
        let failureNotice = L10n.text("变化日志", "Change Log") + " · "
            + L10n.text("变化日志无法读取或保存；本次检查结果仍可查看。",
                "The change log could not be read or saved; current check results remain available.")
            + " · " + L10n.text("无法读取", "Unreadable")
        let failed = CalibrationAppKitLayoutHost(root: HealthRecentChangesView(events: [], readFailed: true)
            .frame(width: size.width, height: size.height, alignment: .topLeading), size: size, dark: false)
        defer { failed.close() }
        try await failed.waitForAccessibility(labels: [failureNotice])
        XCTAssertNil(failed.element(label: L10n.text("最近变化", "Recent Changes")))
        let events = (0..<7).map { index in ComputerHealthChangeEvent(id: UUID(),
            recordedAt: ComputerHealthSecurityFixture.date.addingTimeInterval(-Double(index)),
            check: ComputerHealthEventCheck.allCases[index], oldState: .unknown, newState: .enabled,
            evidenceSummary: "fixture-event-\(index)") }
        let host = CalibrationAppKitLayoutHost(root: HealthRecentChangesView(events: events)
            .frame(width: size.width, height: size.height, alignment: .topLeading), size: size, dark: false)
        defer { host.close() }
        // Review P2-7: changes are lightfield disclosure rows; their AX label is
        // “check · new state” and the evidence sits behind the disclosure.
        let labels = events.map { $0.check.title + " · " + $0.newState.title(for: $0.check) }
        let expand = L10n.text("查看全部（7 条）", "View All (7)")
        try await host.waitForAccessibility(labels: Array(labels.prefix(5)) + [expand], pressLabels: [expand])
        XCTAssertNil(host.element(label: labels[5]))
        XCTAssertNil(host.element(label: labels[6]))
        XCTAssertTrue(try host.press(label: expand))
        let collapse = L10n.text("收起", "Show Less")
        try await host.waitForAccessibility(labels: [labels[5], labels[6], collapse], pressLabels: [collapse])
        XCTAssertTrue(try host.press(label: collapse))
        try await host.waitForAccessibility(labels: [expand], pressLabels: [expand])
        XCTAssertNil(host.element(label: labels[5]))
    }
#endif
}

private enum SecurityHealthFixtureError: Error { case unexpectedFileScan }

private actor SecurityHealthInvocationRecorder {
    let snapshot: ComputerHealthSnapshot
    private var calls = 0
    init(snapshot: ComputerHealthSnapshot) { self.snapshot = snapshot }
    func probe() -> ComputerHealthSnapshot? { calls += 1; return snapshot }
    func count() -> Int { calls }
}
