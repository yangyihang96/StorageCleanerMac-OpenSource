// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/IconRenderCoalescerTests.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import XCTest
@testable import CombinedStatusIcon

@MainActor
final class IconRenderCoalescerTests: XCTestCase {
    func testFirstRedrawInAQuietPeriodRunsImmediately() {
        var redraws: [String] = []
        let coalescer = makeCoalescer()

        coalescer.submit { redraws.append("first") }

        XCTAssertEqual(
            redraws,
            ["first"],
            "A single change must reach the icon in the same run loop turn."
        )
    }

    func testChangeAfterTheIntervalRunsImmediately() {
        var now = Date()
        var redraws: [String] = []
        let coalescer = IconRenderCoalescer(
            minimumInterval: 0.05,
            now: { now },
            sleep: { _ in }
        )

        coalescer.submit { redraws.append("first") }
        now = now.addingTimeInterval(0.2)
        coalescer.submit { redraws.append("second") }

        XCTAssertEqual(redraws, ["first", "second"])
    }

    func testBurstKeepsOnlyTheNewestTrailingRedraw() async {
        let sleeper = ManualEventSleeper()
        let fixedDate = Date()
        var redraws: [String] = []
        let coalescer = makeCoalescer(sleeper: sleeper, now: { fixedDate })

        coalescer.submit { redraws.append("prime") }
        coalescer.submit { redraws.append("oldest") }
        coalescer.submit { redraws.append("newest") }

        XCTAssertEqual(redraws, ["prime"], "The burst waits for the trailing redraw.")
        await sleeper.waitForCallCount(1)

        sleeper.releaseAll()
        await sleeper.waitForCompletionCount(1)
        await waitUntil { redraws.count == 2 }

        XCTAssertEqual(redraws, ["prime", "newest"])
        XCTAssertEqual(sleeper.durations.count, 1)
        XCTAssertLessThanOrEqual(sleeper.durations[0], .seconds(0.05))
    }

    func testBurstAfterTheIntervalStillRunsImmediately() async {
        var now = Date()
        var redraws: [String] = []
        let sleeper = ManualEventSleeper()
        let coalescer = IconRenderCoalescer(
            minimumInterval: 0.05,
            now: { now },
            sleep: { await sleeper.sleep($0) }
        )

        coalescer.submit { redraws.append("first") }
        now = now.addingTimeInterval(0.5)
        coalescer.submit { redraws.append("second") }
        coalescer.submit { redraws.append("third") }

        XCTAssertEqual(redraws, ["first", "second"])
        await sleeper.waitForCallCount(1)
        XCTAssertEqual(sleeper.callCount, 1, "Only the coalesced change waits.")

        sleeper.releaseAll()
        await sleeper.waitForCompletionCount(1)
        await waitUntil { redraws.count == 3 }
        XCTAssertEqual(redraws, ["first", "second", "third"])
    }

    func testCancelDropsThePendingRedraw() async {
        let sleeper = ManualEventSleeper()
        var redraws: [String] = []
        let coalescer = makeCoalescer(sleeper: sleeper)

        coalescer.submit { redraws.append("prime") }
        coalescer.submit { redraws.append("pending") }
        coalescer.cancel()

        sleeper.releaseAll()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(redraws, ["prime"])
    }

    private func makeCoalescer(
        sleeper: ManualEventSleeper = ManualEventSleeper(),
        now: @escaping () -> Date = { Date() }
    ) -> IconRenderCoalescer {
        IconRenderCoalescer(
            minimumInterval: 0.05,
            now: now,
            sleep: { await sleeper.sleep($0) }
        )
    }

    private func waitUntil(
        _ condition: () -> Bool,
        attempts: Int = 200
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("The coalesced redraw never ran.")
    }
}
