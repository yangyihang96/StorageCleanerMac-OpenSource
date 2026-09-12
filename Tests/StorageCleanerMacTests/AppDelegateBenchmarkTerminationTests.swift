import AppKit
import XCTest
@testable import StorageCleanerMac

@MainActor
final class AppDelegateBenchmarkTerminationTests: XCTestCase {
    func testAppOptsOutOfLoginSessionRelaunch() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("NSApp.disableRelaunchOnLogin()"))
        XCTAssertFalse(source.contains("NSApp.enableRelaunchOnLogin()"))
    }

    func testCleanupCompletionRepliesExactlyOnceAcrossRepeatedRequests()
        async throws {
        let delegate = AppDelegate()
        let gate = AppDelegateAsyncGate()
        var replyCount = 0
        delegate.terminationTimeout = .seconds(1)
        delegate.prepareBenchmarkForTermination = {
            await gate.waitUntilOpen()
        }
        delegate.replyToApplicationShouldTerminate = { _ in
            replyCount += 1
        }

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )
        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )
        await gate.waitUntilStarted()
        await gate.open()
        try await waitUntil { replyCount == 1 }
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(replyCount, 1)
    }

    func testTerminationTimeoutRepliesOnceWhenCleanupDoesNotFinish() async throws {
        let delegate = AppDelegate()
        let gate = AppDelegateAsyncGate()
        var replyCount = 0
        delegate.terminationTimeout = .milliseconds(10)
        delegate.prepareBenchmarkForTermination = {
            await gate.waitUntilOpen()
        }
        delegate.replyToApplicationShouldTerminate = { _ in
            replyCount += 1
        }

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )
        await gate.waitUntilStarted()
        try await waitUntil { replyCount == 1 }
        await gate.open()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(replyCount, 1)
    }

    func testTerminationWithoutInstalledBenchmarkLifecycleDoesNotDefer() {
        let delegate = AppDelegate()

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateNow
        )
    }

    func testWillTerminateRequestsEveryLifecycleCancellationHook() {
        let delegate = AppDelegate()
        var benchmarkCancellationCount = 0
        var updateCancellationCount = 0
        var startupCancellationCount = 0
        delegate.requestBenchmarkCancellation = {
            benchmarkCancellationCount += 1
        }
        delegate.requestApplicationUpdateCancellation = {
            updateCancellationCount += 1
        }
        delegate.requestStartupItemCancellation = {
            startupCancellationCount += 1
        }

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        XCTAssertEqual(benchmarkCancellationCount, 1)
        XCTAssertEqual(updateCancellationCount, 1)
        XCTAssertEqual(startupCancellationCount, 1)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for AppDelegate termination state")
    }
}

private actor AppDelegateAsyncGate {
    private var started = false
    private var isOpen = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilOpen() async {
        started = true
        let pendingStartWaiters = startWaiters
        startWaiters.removeAll()
        pendingStartWaiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let pendingOpenWaiters = openWaiters
        openWaiters.removeAll()
        pendingOpenWaiters.forEach { $0.resume() }
    }
}
