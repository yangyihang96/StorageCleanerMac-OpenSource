import Combine
import FanControlShared
import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class HelperUpgradeCoordinatorTests: XCTestCase {
    private enum Failure: Error { case interrupted }
    private final class Clock {
        var seconds: TimeInterval = 0
        var rejecting = true
    }

    func testRejectedConnectionHasAtMostFifteenAttemptsInTenMinutes() async {
        let clock = Clock()
        var pings = 0
        let coordinator = make(clock: clock) { request in
            XCTAssertEqual(request.operation, .ping)
            pings += 1
            throw Failure.interrupted
        }
        // 40 demands/second reproduces the log rate, without real time/XPC.
        for tick in 0...24_000 {
            clock.seconds = Double(tick) / 40
            coordinator.refreshStatus()
            await coordinator.refreshConnection()
            _ = await coordinator.samplePowerMetrics()
            await coordinator.connectHelper()
        }
        XCTAssertGreaterThan(pings, 1, "A disabled reconnect loop is not a backoff")
        XCTAssertLessThanOrEqual(pings, 15)
        XCTAssertEqual(pings, 10, "0,1,3,7,15,31,63,127,255,511 with neutral jitter")
        XCTAssertTrue(coordinator.helperConnectionNeedsAttention)
        XCTAssertTrue(coordinator.offersHelperReconnect)
        XCTAssertTrue(coordinator.lastMessage?.contains(L10n.text("重新批准", "approve")) == true)
        XCTAssertNil(coordinator.observedMode)
    }

    func testSuccessResetsBackoffAndDoesNotClaimHardwareVerification() async {
        let clock = Clock()
        var pings = 0
        let coordinator = make(clock: clock) { request in
            if request.operation == .ping {
                pings += 1
                if clock.rejecting { throw Failure.interrupted }
            }
            return self.reply(request)
        }
        await coordinator.connectHelper() // deadline 1
        clock.seconds = 1
        await coordinator.connectHelper() // deadline 3
        clock.seconds = 2.9
        clock.rejecting = false
        await coordinator.connectHelper()
        XCTAssertEqual(pings, 2)
        clock.seconds = 3
        await coordinator.connectHelper()
        XCTAssertEqual(pings, 3)
        XCTAssertTrue(coordinator.isHelperReachable)
        XCTAssertFalse(coordinator.helperConnectionNeedsAttention)
        XCTAssertNil(coordinator.observedMode)
        coordinator.handleUnexpectedHelperInvalidation() // reset delay must be 1
        clock.seconds = 3.9
        await coordinator.connectHelper()
        XCTAssertEqual(pings, 3)
        clock.seconds = 4
        await coordinator.connectHelper()
        XCTAssertEqual(pings, 4)
        XCTAssertTrue(coordinator.isHelperReachable)
    }

    func testManualReconnectResetsDeadlineAndMakesExactlyOneAttempt() async {
        let clock = Clock()
        var pings = 0
        let coordinator = make(clock: clock) { _ in pings += 1; throw Failure.interrupted }
        await coordinator.connectHelper()
        await coordinator.connectHelper()
        XCTAssertEqual(pings, 1)
        await coordinator.reconnectHelper()
        XCTAssertEqual(pings, 2)
        await coordinator.connectHelper()
        XCTAssertEqual(pings, 2, "Manual failure must restore the first backoff")
        clock.seconds = 1
        await coordinator.connectHelper()
        XCTAssertEqual(pings, 3)
    }

    func testRapidManualClicksKeepIndependentTenSecondCooldown() async {
        let clock = Clock()
        var pings = 0
        let coordinator = make(clock: clock) { _ in pings += 1; throw Failure.interrupted }
        for tick in 0...24_000 {
            clock.seconds = Double(tick) / 40
            await coordinator.reconnectHelper()
            coordinator.refreshStatus()
            await coordinator.refreshConnection()
        }
        XCTAssertEqual(pings, 61, "One manual attempt at 0,10,...,600, regardless of 40 clicks/s")
        XCTAssertEqual(coordinator.helperReconnectWaitSeconds, 10)
        XCTAssertEqual(coordinator.helperReconnectTitle, L10n.text("等待 10 秒", "Wait 10s"))
        clock.seconds = 609.999
        await coordinator.reconnectHelper()
        XCTAssertEqual(pings, 61)
        XCTAssertEqual(coordinator.helperReconnectWaitSeconds, 1)
        clock.seconds = 610
        await coordinator.reconnectHelper()
        XCTAssertEqual(pings, 62)
    }

    func testSuccessfulConnectionCannotResetManualCooldown() async {
        let clock = Clock()
        var pings = 0
        let coordinator = make(clock: clock) { request in
            if request.operation == .ping { pings += 1 }
            return self.reply(request)
        }
        await coordinator.reconnectHelper()
        XCTAssertTrue(coordinator.isHelperReachable)
        XCTAssertEqual(pings, 1)
        coordinator.handleUnexpectedHelperInvalidation()
        for _ in 0..<100 { await coordinator.reconnectHelper() }
        XCTAssertEqual(pings, 1)
        XCTAssertEqual(coordinator.helperReconnectWaitSeconds, 10)
        clock.seconds = 10
        XCTAssertEqual(coordinator.helperReconnectTitle, L10n.text("重新连接", "Reconnect"))
        await coordinator.reconnectHelper()
        XCTAssertEqual(pings, 2)
    }

    func testConcurrentRefreshReconnectAndReadShareOneInFlightConnectionAttempt() async {
        let clock = Clock()
        var gate: CheckedContinuation<FanControlHelperReply, any Error>?
        var pings = 0
        let coordinator = make(clock: clock) { request in
            if request.operation == .ping {
                pings += 1
                guard pings == 1 else { throw Failure.interrupted }
                return try await withCheckedThrowingContinuation { gate = $0 }
            }
            return self.reply(request)
        }
        let first = Task { await coordinator.connectHelper() }
        for _ in 0..<10_000 where gate == nil { await Task.yield() }
        guard let pending = gate else {
            first.cancel(); await first.value
            return XCTFail("Fake request did not enter its gate")
        }
        for _ in 0..<100 {
            await coordinator.connectHelper()
            await coordinator.reconnectHelper()
            await coordinator.refreshConnection()
            await coordinator.refreshMacMiniMode()
            await coordinator.setMacMiniMode(.off)
            _ = await coordinator.samplePowerMetrics()
        }
        XCTAssertEqual(pings, 1)
        pending.resume(throwing: Failure.interrupted)
        await first.value
        XCTAssertEqual(pings, 1)
        XCTAssertFalse(coordinator.isRefreshingConnection)
    }

    func testCachedRefreshAndPowerAvailabilityNeverOpenAConnectionOrPublish() async {
        let clock = Clock()
        var requests = 0
        var publications = 0
        let coordinator = make(clock: clock) { _ in requests += 1; throw Failure.interrupted }
        let subscription = coordinator.objectWillChange.sink { publications += 1 }
        let monitor = HelperPowerMetricsMonitor(availability: {
            coordinator.refreshStatus() // Exact existing ScanStore callback.
            return coordinator.helperStatus == .enabled ? .ready : .needsHelper
        }, request: { await coordinator.samplePowerMetrics() }, now: { clock.seconds }, automaticSampling: false)
        let consumer = UUID()
        monitor.updateConsumer(consumer, visible: true)
        for second in 0...600 {
            clock.seconds = Double(second)
            coordinator.refreshStatus()
            await coordinator.refreshConnection()
            await coordinator.refreshMacMiniMode()
            await monitor.sampleIfDue()
        }
        monitor.updateConsumer(consumer, visible: false)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(subscription) {}
    }

    func testAutomaticSchedulerWaitsForDeadlineAndSchedulesOnlyOneWorker() async {
        let clock = Clock()
        var delays: [TimeInterval] = []
        var wake: CheckedContinuation<Void, any Error>?
        var pings = 0
        let coordinator = make(clock: clock, automaticallyReconnect: true, sleeper: { delay in
            delays.append(delay)
            try await withCheckedThrowingContinuation { wake = $0 }
        }) { request in
            if request.operation == .ping {
                pings += 1
                if pings == 1 { throw Failure.interrupted }
            }
            return self.reply(request)
        }
        await coordinator.connectHelper()
        for _ in 0..<10_000 where wake == nil { await Task.yield() }
        guard let pending = wake else { return XCTFail("No scheduled reconnect") }
        for _ in 0..<100 { await coordinator.connectHelper(); await coordinator.refreshConnection() }
        XCTAssertEqual(delays, [1])
        XCTAssertEqual(pings, 1)
        clock.seconds = 1
        pending.resume()
        for _ in 0..<10_000 where !coordinator.isHelperReachable { await Task.yield() }
        XCTAssertEqual(pings, 2)
        XCTAssertTrue(coordinator.isHelperReachable)
        XCTAssertEqual(delays, [1])
        coordinator.disconnectForTermination()
    }

    func testRejectedRestoreKeepsObligationAndCannotRestartTheFirstAttempt() async {
        let clock = Clock()
        var operations: [FanControlHelperRequest.Operation] = []
        let coordinator = make(clock: clock) { request in
            operations.append(request.operation)
            if operations.count == 1 { throw Failure.interrupted }
            return self.reply(request)
        }
        coordinator.selectedMode = .manual
        coordinator.handleUnexpectedHelperInvalidation()
        for _ in 0..<100 { await coordinator.connectHelper() }
        XCTAssertEqual(operations, [], "Interruption must wait for backoff before restoring")
        XCTAssertEqual(coordinator.selectedMode, .systemAutomatic)
        XCTAssertNil(coordinator.observedMode)
        clock.seconds = 1
        await coordinator.connectHelper() // refused ping, deadline 3
        for _ in 0..<100 { await coordinator.connectHelper() }
        XCTAssertEqual(operations, [.ping])
        clock.seconds = 3
        await coordinator.connectHelper()
        for _ in 0..<10_000 where !operations.contains(.restoreAutomatic) { await Task.yield() }
        XCTAssertEqual(operations.filter { $0 == .restoreAutomatic }.count, 1)
        XCTAssertNil(coordinator.observedMode, "Restore acknowledgment is not mode readback")
    }

    func testOldProtocolShowsUpdateWithoutImmediateRetryOrWrites() async {
        var pings = 0
        let coordinator = make { request in
            XCTAssertEqual(request.operation, .ping)
            pings += 1
            return self.reply(request, version: 3)
        }
        await coordinator.connectHelper()
        XCTAssertEqual(pings, 1)
        XCTAssertTrue(coordinator.lastMessage?.contains(L10n.text("辅助程序需要更新", "The helper needs an update")) == true)
        XCTAssertTrue(coordinator.helperConnectionNeedsAttention)
        XCTAssertFalse(coordinator.hasTrustedHelper)
    }

    func testRegisterPathMakesOnePingWithoutUnregisteringService() async {
        var pings = 0
        let coordinator = make { request in
            XCTAssertEqual(request.operation, .ping)
            pings += 1
            throw Failure.interrupted
        }
        await coordinator.registerHelper()
        XCTAssertEqual(pings, 1)
        XCTAssertTrue(coordinator.helperConnectionNeedsAttention)
        XCTAssertEqual(coordinator.helperStatus, .enabled)
        XCTAssertFalse(coordinator.isPreparingHelper)
    }

    func testCancellationIsNotReportedAsOldHelperOrRetried() async {
        var pings = 0
        let coordinator = make { _ in pings += 1; throw CancellationError() }
        await coordinator.connectHelper()
        XCTAssertEqual(pings, 1)
        XCTAssertFalse(coordinator.helperConnectionNeedsAttention)
    }

    func testStartupFaultIsStillTerminalAndDoesNotOfferUpgradeAction() async {
        var pings = 0
        let coordinator = make { request in
            pings += 1
            return FanControlHelperReply(operation: request.operation, success: false, message: "startup fault",
                appliedTargetRPMByFan: [:], errorCode: .fanCrashRecoveryFailed)
        }
        await coordinator.connectHelper()
        await coordinator.reconnectHelper()
        XCTAssertEqual(pings, 1)
        XCTAssertFalse(coordinator.offersHelperReconnect)
        XCTAssertFalse(coordinator.helperConnectionNeedsAttention)
        XCTAssertFalse(coordinator.isHelperReachable)
    }

    func testSettingsContainsReconnectAndApprovalWithoutRemovingDisableAction() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try SettingsSourceContract.source(at: root.appendingPathComponent("Sources/StorageCleanerMac/Views/SettingsView.swift"))
        XCTAssertTrue(source.contains("!fanControl.isHelperReachable, fanControl.offersHelperReconnect"))
        XCTAssertTrue(source.contains("Button(fanControl.helperReconnectTitle)"))
        XCTAssertTrue(source.contains("fanControl.helperReconnectWaitSeconds > 0"))
        XCTAssertTrue(source.contains("await fanControl.reconnectHelper()"))
        XCTAssertTrue(source.contains("在系统设置中重新批准"))
        XCTAssertTrue(source.contains("停用并恢复系统控制"))
    }

    private func make(clock: Clock = Clock(), automaticallyReconnect: Bool = false,
                      sleeper: @escaping @MainActor (TimeInterval) async throws -> Void = { _ in throw CancellationError() },
                      _ sender: @escaping @MainActor (FanControlHelperRequest) async throws -> FanControlHelperReply) -> FanControlCoordinator {
        FanControlCoordinator(defaults: TestPreferenceDomain.make(for: self), helperStatusOverride: .enabled,
            requestSender: TestOperationFactory(for: self).fanRequestSender(handling: [.ping, .readPowerConfiguration, .restoreAutomatic, .readMacMiniMode, .samplePowerMetrics], reply: sender),
            reconnectClock: { clock.seconds }, reconnectJitter: { 0.5 }, automaticallyReconnect: automaticallyReconnect, reconnectSleeper: sleeper,
            legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            legacyArtifactsSafeForRemovalProvider: { false }, legacyUninstaller: { XCTFail("No live migration") },
            serviceStatusProvider: { .enabled }, serviceRegistrar: { XCTFail("No live registration") },
            serviceUnregistrar: { XCTFail("No live removal") }, approvalSettingsOpener: { XCTFail("No live settings") })
    }

    private func reply(_ request: FanControlHelperRequest, version: Int = HardwareControlProtocol.currentVersion) -> FanControlHelperReply {
        FanControlHelperReply(protocolVersion: version, operation: request.operation, success: true,
            message: "fixture ready", appliedTargetRPMByFan: [:])
    }
}
