import Darwin
@testable import FanControlShared
import Foundation
import XCTest

/// Per-connection admission in front of the helper's signing checks.
final class PowermetricsClientGateTests: XCTestCase {
    // Retained for the whole test so the identifiers stay distinct.
    private let firstConnection = NSObject(), secondConnection = NSObject()
    private var first: ObjectIdentifier { ObjectIdentifier(firstConnection) }
    private var second: ObjectIdentifier { ObjectIdentifier(secondConnection) }
    private let app = PowermetricsClientGate.ClientProcess(pid: 501, pidVersion: 7)

    func testCheapCheckRunsEveryTimeAndSealOnlyOncePerConnectionAndProcessInstance() throws {
        let gate = PowermetricsClientGate()
        gate.register(connection: first)
        gate.register(connection: second)
        var cheap = 0, seal = 0
        var now: TimeInterval = 0
        func authorize(_ connection: ObjectIdentifier, _ process: PowermetricsClientGate.ClientProcess,
                       cheapResult: Bool = true, sealResult: Bool = true) -> Bool {
            now += 1
            guard let admission = gate.admitAttempt(connection: connection, now: now) else {
                XCTFail("expected admission"); return false
            }
            return gate.authorize(admission: admission, process: process,
                                  cheapCheck: { cheap += 1; return cheapResult }, sealCheck: { seal += 1; return sealResult })
        }
        XCTAssertTrue(authorize(first, app))
        XCTAssertEqual([cheap, seal], [1, 1])
        XCTAssertTrue(authorize(first, app))
        XCTAssertEqual([cheap, seal], [2, 1], "cached seal; cheap identity check still runs")
        // A recycled pid (new pidversion) or another connection is a new instance.
        XCTAssertTrue(authorize(first, .init(pid: 501, pidVersion: 8)))
        XCTAssertEqual(seal, 2)
        XCTAssertTrue(authorize(second, .init(pid: 501, pidVersion: 8)))
        XCTAssertEqual(seal, 3)
        // A failed cheap check denies before the seal check, even with a cache entry.
        XCTAssertFalse(authorize(second, .init(pid: 501, pidVersion: 8), cheapResult: false))
        XCTAssertEqual(seal, 3)
        // A failed seal check is not cached.
        let other = PowermetricsClientGate.ClientProcess(pid: 900, pidVersion: 1)
        XCTAssertFalse(authorize(first, other, sealResult: false))
        XCTAssertFalse(authorize(first, other, sealResult: false))
        XCTAssertEqual(seal, 5)
        // Throwing checks deny.
        let admission = try XCTUnwrap(gate.admitAttempt(connection: first, now: now + 1))
        XCTAssertFalse(gate.authorize(admission: admission, process: app, cheapCheck: { throw CancellationError() }, sealCheck: { true }))
        XCTAssertFalse(gate.authorize(admission: admission, process: .init(pid: 1, pidVersion: 1),
                                      cheapCheck: { true }, sealCheck: { throw CancellationError() }))
    }

    func testForgettingAConnectionDropsItsSealCacheAndAttemptHistory() throws {
        let gate = PowermetricsClientGate()
        gate.register(connection: first)
        var seal = 0
        let old = try XCTUnwrap(gate.admitAttempt(connection: first, now: 10))
        XCTAssertTrue(gate.authorize(admission: old, process: app, cheapCheck: { true }, sealCheck: { seal += 1; return true }))
        XCTAssertEqual(gate.trackedConnectionCount, 1)
        gate.forget(connection: first)
        XCTAssertEqual(gate.trackedConnectionCount, 0)
        XCTAssertNil(gate.admitAttempt(connection: first, now: 10.1), "an invalidated connection cannot recreate state")
        gate.register(connection: first)
        let fresh = try XCTUnwrap(gate.admitAttempt(connection: first, now: 10.1), "a new connection starts fresh")
        XCTAssertTrue(gate.authorize(admission: fresh, process: app, cheapCheck: { true }, sealCheck: { seal += 1; return true }))
        XCTAssertEqual(seal, 2)
    }

    func testPerConnectionIntervalCountsEveryAttemptIncludingRefusedOnes() {
        let gate = PowermetricsClientGate()
        gate.register(connection: first)
        gate.register(connection: second)
        XCTAssertEqual(PowermetricsClientGate.minimumAttemptInterval, 1)
        XCTAssertNotNil(gate.admitAttempt(connection: first, now: 100))
        XCTAssertNil(gate.admitAttempt(connection: first, now: 100.999))
        // The refused attempt at 100.999 restarts the interval: a flood stays refused.
        XCTAssertNil(gate.admitAttempt(connection: first, now: 101.5))
        XCTAssertNotNil(gate.admitAttempt(connection: first, now: 102.5))
        // Connections are independent; NaN and clock regression are refused.
        XCTAssertNotNil(gate.admitAttempt(connection: second, now: 102.6))
        XCTAssertNil(gate.admitAttempt(connection: second, now: .nan))
        XCTAssertNil(gate.admitAttempt(connection: second, now: 50))
    }

    func testInvalidationDuringEitherCheckCannotRecreateCacheOrAuthorize() throws {
        for duringCheap in [true, false] {
            let gate = PowermetricsClientGate()
            gate.register(connection: first)
            let admission = try XCTUnwrap(gate.admitAttempt(connection: first, now: 0))
            var seal = 0
            XCTAssertFalse(gate.authorize(admission: admission, process: app, cheapCheck: {
                if duringCheap { gate.forget(connection: self.first) }
                return true
            }, sealCheck: {
                seal += 1
                gate.forget(connection: self.first)
                return true
            }))
            XCTAssertEqual(seal, duringCheap ? 0 : 1)
            XCTAssertEqual(gate.trackedConnectionCount, 0, "late checks cannot resurrect an invalidated connection")
        }
    }

    func testQueuedOldAdmissionCannotUseReplacementConnectionOrItsSealCache() throws {
        let gate = PowermetricsClientGate()
        gate.register(connection: first)
        let old = try XCTUnwrap(gate.admitAttempt(connection: first, now: 0))
        gate.forget(connection: first)
        // Model ObjectIdentifier reuse without relying on allocator behavior.
        gate.register(connection: first)
        let replacement = try XCTUnwrap(gate.admitAttempt(connection: first, now: 0))
        XCTAssertTrue(gate.authorize(admission: replacement, process: app, cheapCheck: { true }, sealCheck: { true }))
        XCTAssertFalse(gate.authorize(admission: old, process: app, cheapCheck: {
            XCTFail("old ticket must be rejected before Security work"); return true
        }, sealCheck: { XCTFail("old ticket must not reach seal verification"); return true }))
        XCTAssertEqual(gate.trackedConnectionCount, 1)
        // Even a cache hit is refused if its cheap check invalidates the connection.
        XCTAssertFalse(gate.authorize(admission: replacement, process: app, cheapCheck: {
            gate.forget(connection: self.first); return true
        }, sealCheck: { XCTFail("invalidated cache must not reach seal verification"); return true }))
        XCTAssertEqual(gate.trackedConnectionCount, 0)
    }

    /// The helper reads pid/pidversion as audit_token_t.val.5 / val.7 (the fields
    /// libbsm uses) instead of linking libbsm. Check the layout on this process.
    func testAuditTokenLayoutUsedByTheHelper() throws {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        XCTAssertEqual(status, KERN_SUCCESS)
        XCTAssertEqual(Int32(bitPattern: token.val.5), getpid())
        XCTAssertNotEqual(token.val.7, 0, "pidversion is populated")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FanControlHelper/main.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("pid: Int32(bitPattern: auditToken.val.5)"))
        XCTAssertTrue(source.contains("pidVersion: Int32(bitPattern: auditToken.val.7)"))
    }
}
