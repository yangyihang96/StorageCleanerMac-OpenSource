// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/MonitorStreamTests.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import XCTest
@testable import CombinedStatusIcon

final class MonitorStreamTests: XCTestCase {
    func testMonitorStreamKeepsOnlyNewestUnconsumedValue() async {
        let (stream, continuation) = MonitorStream.make(of: Int.self)

        continuation.yield(1)
        continuation.yield(2)
        continuation.yield(3)

        var iterator = stream.makeAsyncIterator()
        let value = await iterator.next()

        XCTAssertEqual(value, 3)
        continuation.finish()
    }
}
