import Foundation
import ObjectiveC
import XCTest
@testable import StorageCleanerMac

final class AppUpdaterPolicyTests: XCTestCase {
    func testSelfUpdaterPreservesSparklesHighestCompatibleSelection() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Services/AppUpdater.swift"
            ),
            encoding: .utf8
        )

        // The delegate exists only to postpone the install relaunch while heavy
        // work runs (plan batch 4a); update selection stays Sparkle's own.
        XCTAssertTrue(source.contains("updaterDelegate: self"))
        XCTAssertFalse(source.contains("LatestCompatibleUpdateSelector"))
    }

    /// The Sparkle delegate may postpone the install relaunch and end that
    /// postponement with the update cycle, nothing else. In particular it must
    /// not choose, filter, gate or take over updates, so Sparkle's own
    /// compatibility, channel, phased-rollout and skip rules stay in charge.
    @MainActor
    func testSparkleDelegateImplementsOnlyTheRelaunchHooks() throws {
        let delegateProtocol = try XCTUnwrap(NSProtocolFromString("SPUUpdaterDelegate"))
        var count: UInt32 = 0
        let methods = try XCTUnwrap(protocol_copyMethodDescriptionList(delegateProtocol, false, true, &count))
        defer { free(methods) }
        let optionalHooks = Set((0..<Int(count)).compactMap { methods[$0].name }.map(NSStringFromSelector))

        // Hooks that would affect which update is found, offered or installed
        // (Sparkle 2.9.4 names). They must exist, so the check below is real.
        let selectionHooks: Set<String> = [
            "bestValidUpdateInAppcast:forUpdater:",
            "allowedChannelsForUpdater:",
            "feedURLStringForUpdater:",
            "feedParametersForUpdater:sendingSystemProfile:",
            "updater:shouldProceedWithUpdate:updateCheck:error:",
            "versionComparatorForUpdater:",
            "updater:mayPerformUpdateCheck:error:",
            "updaterMayCheckForUpdates:",
            "updaterShouldRelaunchApplication:",
            "updater:willInstallUpdateOnQuit:immediateInstallationBlock:",
        ]
        XCTAssertTrue(selectionHooks.isSubset(of: optionalHooks))

        let implemented = optionalHooks.filter { AppUpdater.instancesRespond(to: NSSelectorFromString($0)) }
        XCTAssertEqual(implemented, [
            "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
            "updater:didFinishUpdateCycleForUpdateCheck:error:",
        ])
    }

    @MainActor
    func testInstallTakesItsLeaseAtOnceWhenNoHeavyWorkRuns() async throws {
        let coordinator = HeavyWorkCoordinator()
        let log = InstallWaitLog()

        let lease = await HeavyWorkRelaunchGate.acquireInstallLease(
            from: coordinator,
            pollInterval: .milliseconds(10)
        ) { log.notices += 1 }

        XCTAssertNotNil(lease)
        XCTAssertEqual(log.notices, 0, "Nothing to wait for, so no notice")
        // Until the app exits, no new heavy work can start.
        do {
            _ = try await coordinator.acquire(owner: .cleanup)
            XCTFail("Cleanup must not start once the install holds its lease")
        } catch {
            XCTAssertEqual(error as? HeavyWorkCoordinator.Error, .busy(activeOwner: .appUpdates))
        }
    }

    @MainActor
    func testInstallWaitsWhileHeavyWorkHoldsALease() async throws {
        let coordinator = HeavyWorkCoordinator()
        let cleanup = try await coordinator.acquire(owner: .cleanup)
        let log = InstallWaitLog()
        let waiter = Task { @MainActor in
            let lease = await HeavyWorkRelaunchGate.acquireInstallLease(
                from: coordinator,
                pollInterval: .milliseconds(10)
            ) { log.notices += 1 }
            log.finished = true
            return lease
        }

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(log.finished, "The install waits while the cleanup lease is held")
        XCTAssertEqual(log.notices, 1, "The user is told once why the install waits")

        await coordinator.release(cleanup)
        let lease = await waiter.value
        XCTAssertNotNil(lease, "The install proceeds once the cleanup lease is released")
        let owner = await coordinator.activeOwner
        XCTAssertEqual(owner, .appUpdates, "The install holds its own lease until the app exits")
    }

    @MainActor
    func testInstallWaitsWhileACleanupQuarantineRemains() async throws {
        let coordinator = HeavyWorkCoordinator()
        let cleanup = try await coordinator.acquire(owner: .cleanup)
        let quarantine = try await coordinator.beginCleanupQuarantine(cleanup)
        // The lease is gone; the quarantine of an unfinished move remains.
        await coordinator.release(cleanup)
        let log = InstallWaitLog()
        let waiter = Task { @MainActor in
            let lease = await HeavyWorkRelaunchGate.acquireInstallLease(
                from: coordinator,
                pollInterval: .milliseconds(10)
            ) { log.notices += 1 }
            log.finished = true
            return lease
        }

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(log.finished, "The install waits while the cleanup quarantine is held")
        XCTAssertEqual(log.notices, 1)

        await coordinator.clearCleanupQuarantine(quarantine)
        let lease = await waiter.value
        XCTAssertNotNil(lease, "The install proceeds once the quarantine is cleared")
    }

    @MainActor
    func testCancelledInstallWaitTakesNoLease() async throws {
        let coordinator = HeavyWorkCoordinator()
        let restore = try await coordinator.acquire(owner: .restore)
        let waiter = Task { @MainActor in
            await HeavyWorkRelaunchGate.acquireInstallLease(from: coordinator, pollInterval: .milliseconds(10)) {}
        }
        try await Task.sleep(for: .milliseconds(30))
        waiter.cancel()

        let lease = await waiter.value
        XCTAssertNil(lease)
        await coordinator.release(restore)
        let owner = await coordinator.activeOwner
        XCTAssertNil(owner, "A cancelled wait leaves no lease behind")
    }
}

@MainActor
private final class InstallWaitLog {
    var notices = 0
    var finished = false
}
