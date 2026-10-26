// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/NetworkConnectionMonitorTests.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import XCTest
@testable import CombinedStatusIcon

@MainActor
final class NetworkConnectionMonitorTests: XCTestCase {
    func testWiredPathUpdatePublishesTheWholePath() async {
        let pathMonitor = FakeNetworkPathMonitor()
        let monitor = NetworkConnectionMonitor(pathMonitor: pathMonitor)
        let updated = expectation(description: "path update published")
        let updateTask = Task {
            var iterator = monitor.updates.makeAsyncIterator()
            let path = await iterator.next()
            XCTAssertEqual(path?.connection, .ethernet)
            // The snapshot is forwarded whole: the popover reads the restriction
            // off the same update the connection arrives on, so dropping it here
            // would silently cost the row its second clause.
            XCTAssertEqual(path?.constrained, true)
            updated.fulfill()
        }

        monitor.start()
        pathMonitor.send(
            NetworkPathSnapshot(
                connected: true,
                wired: true,
                wireless: true,
                constrained: true
            )
        )
        await fulfillment(of: [updated], timeout: 1)

        XCTAssertEqual(pathMonitor.startCount, 1)
        updateTask.cancel()
        monitor.stop()
    }

    func testRecoverRestartsPathMonitoring() {
        let pathMonitor = FakeNetworkPathMonitor()
        let monitor = NetworkConnectionMonitor(pathMonitor: pathMonitor)

        monitor.start()
        monitor.recover()

        XCTAssertEqual(pathMonitor.startCount, 2)
        XCTAssertEqual(pathMonitor.cancelCount, 1)
        monitor.stop()
    }
}

private final class FakeNetworkPathMonitor: NetworkPathMonitoring {
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private var handler: ((NetworkPathSnapshot) -> Void)?

    func start(
        queue: DispatchQueue,
        handler: @escaping (NetworkPathSnapshot) -> Void
    ) {
        startCount += 1
        self.handler = handler
    }

    func cancel() {
        cancelCount += 1
        handler = nil
    }

    func send(_ snapshot: NetworkPathSnapshot) {
        handler?(snapshot)
    }
}
