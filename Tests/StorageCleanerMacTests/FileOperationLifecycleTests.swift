import Darwin
import FileOperationShared
import Foundation
import XCTest
@testable import StorageCleanerMac

final class FileOperationLifecycleTests: XCTestCase {
    func testIdlePolicyRequiresEverySourceOfWorkToBeEmpty() {
        for clients in [0, 1] { for requests in [0, 1] { for approval in [false, true] { for busy in [false, true] {
            XCTAssertEqual(FileOperationHelperIdlePolicy.mayExit(connectionCount: clients, pendingRequests: requests,
                hasPendingApproval: approval, updateIsBusy: busy), clients == 0 && requests == 0 && !approval && !busy)
        } } } }
    }

    func testIdleExitRequiresFifteenContinuousSecondsAndClosesAdmission() throws {
        let state = LifecycleFixture()
        let lifecycle = state.makeLifecycle()
        lifecycle.start()
        state.advance(to: 14.9); lifecycle.checkForExit()
        XCTAssertTrue(state.exits.isEmpty)
        let admission = try XCTUnwrap(lifecycle.admit(uid: 501))
        XCTAssertEqual(admission.requirement, "fixture-requirement")
        state.advance(to: 60); lifecycle.checkForExit()
        XCTAssertTrue(state.exits.isEmpty)
        lifecycle.invalidate(admission.id)
        lifecycle.invalidate(admission.id) // duplicate invalidation cannot underflow
        state.advance(to: 74.9); lifecycle.checkForExit()
        XCTAssertTrue(state.exits.isEmpty)
        state.advance(to: 75); lifecycle.checkForExit()
        XCTAssertEqual(state.exits, [EXIT_SUCCESS])
        XCTAssertNil(lifecycle.admit(uid: 501), "the final exit and admission use the same lock")
    }

    func testQueuedRequestSurvivesClientInvalidationUntilAfterReply() throws {
        let state = LifecycleFixture()
        let lifecycle = state.makeLifecycle()
        lifecycle.start()
        let admission = try XCTUnwrap(lifecycle.admit(uid: 501))
        lifecycle.beginRequest()
        lifecycle.invalidate(admission.id)
        state.advance(to: 100); lifecycle.checkForExit()
        XCTAssertTrue(state.exits.isEmpty)
        lifecycle.finishRequest()
        state.advance(to: 114.9); lifecycle.checkForExit()
        XCTAssertTrue(state.exits.isEmpty)
        state.advance(to: 115); lifecycle.checkForExit()
        XCTAssertEqual(state.exits, [EXIT_SUCCESS])
    }

    func testPendingMoveAndCacheApprovalOutlivePrepareReply() throws {
        for kind in [FileOperationHelperLifecycle.Approval.move, .systemCache] {
            let state = LifecycleFixture()
            let lifecycle = state.makeLifecycle()
            lifecycle.start()
            let admission = try XCTUnwrap(lifecycle.admit(uid: 501))
            lifecycle.beginRequest()
            lifecycle.setApproval(until: state.now.addingTimeInterval(30), connection: admission.id, kind: kind)
            lifecycle.finishRequest()
            lifecycle.invalidate(admission.id)
            state.advance(to: 29); lifecycle.checkForExit()
            XCTAssertTrue(state.exits.isEmpty)
            state.advance(to: 30); lifecycle.checkForExit()
            XCTAssertTrue(state.exits.isEmpty, "expiry starts a new idle window")
            state.advance(to: 44.9); lifecycle.checkForExit()
            XCTAssertTrue(state.exits.isEmpty)
            state.advance(to: 45); lifecycle.checkForExit()
            XCTAssertEqual(state.exits, [EXIT_SUCCESS])
        }
    }

    func testCommitConsumesApprovalAndStartsANewIdleWindow() throws {
        let state = LifecycleFixture()
        let request = AuthorizedFileMove(sessionID: UUID(), direction: .trash,
            applicationPath: "/Applications/Fixture.app", trashPath: "/Users/fixture/.Trash/Fixture.app",
            bundleIdentifier: "org.fixture.app", version: "1", build: "1", device: 1, inode: 2,
            birthNanoseconds: 3)
        var gate = AuthorizedFileCommitGate()
        try gate.approve(request, now: state.now)
        XCTAssertEqual(gate.approvalExpiration, state.now.addingTimeInterval(15))
        _ = try gate.consume(request, now: state.now.addingTimeInterval(1))
        XCTAssertNil(gate.approvalExpiration)
    }

    func testUpdateActivityBlocksIdleExit() {
        let state = LifecycleFixture()
        state.busy = true
        let lifecycle = state.makeLifecycle()
        lifecycle.start()
        state.advance(to: 100); lifecycle.checkForExit()
        XCTAssertTrue(state.exits.isEmpty)
        state.busy = false
        lifecycle.checkForExit()
        state.advance(to: 114.9); lifecycle.checkForExit()
        XCTAssertTrue(state.exits.isEmpty)
        state.advance(to: 115); lifecycle.checkForExit()
        XCTAssertEqual(state.exits, [EXIT_SUCCESS])
    }

    func testMissingSignerRejectsConnectionAndSchedulesSuccessfulExit() {
        let state = LifecycleFixture()
        let lifecycle = state.makeLifecycle(signer: { nil })
        lifecycle.start()
        XCTAssertNil(lifecycle.admit(uid: 501))
        state.advance(to: 0.49); lifecycle.checkForExit()
        XCTAssertTrue(state.exits.isEmpty)
        state.advance(to: 0.5); lifecycle.checkForExit()
        XCTAssertEqual(state.exits, [EXIT_SUCCESS])
    }

    func testMissingSignerDoesNotInterruptAnActiveMutationOrApproval() throws {
        let state = LifecycleFixture()
        let lifecycle = state.makeLifecycle(signer: { nil })
        lifecycle.start()
        lifecycle.beginRequest()
        XCTAssertNil(lifecycle.admit(uid: 501))
        state.advance(to: 1); lifecycle.checkForExit()
        XCTAssertTrue(state.exits.isEmpty)
        lifecycle.setApproval(until: state.now.addingTimeInterval(15), connection: UUID(), kind: .move)
        lifecycle.finishRequest()
        lifecycle.checkForExit()
        XCTAssertTrue(state.exits.isEmpty)
        state.advance(to: 16); state.busy = true; lifecycle.checkForExit()
        XCTAssertTrue(state.exits.isEmpty)
        state.busy = false; lifecycle.checkForExit()
        XCTAssertEqual(state.exits, [EXIT_SUCCESS])
    }

    func testEveryExportedMethodCountsWorkBeforeDispatchAndAfterReply() throws {
        let files: [(String, [String])] = [
            ("main.swift", ["prepare(", "commit("]),
            ("SystemCaches.swift", ["systemCacheInventory(", "prepareSystemCacheClear(", "commitSystemCacheClear("]),
            ("PrivilegedApplicationUpdates.swift", ["applicationReplacementCapabilities(", "prepareApplicationReplacements(",
                "replaceAuthenticatedApplication(", "finishApplicationReplacements("]),
            ("BackgroundTaskInventory.swift", ["backgroundTaskInventory("])
        ]
        for (file, methods) in files {
            let source = try String(contentsOf: SwiftSourceScanning.projectRoot
                .appendingPathComponent("Sources/FileOperationHelper/" + file), encoding: .utf8)
            for method in methods {
                let body = try r2SourceDeclaration("func " + method, in: source)
                XCTAssertTrue(body.contains("trackedReply(reply)"), method)
            }
        }
        let source = try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/FileOperationHelper/main.swift"), encoding: .utf8)
        let callback = try r2SourceDeclaration("func call(_ value: Data)", in: source)
        XCTAssertTrue(callback.contains("callback(value); didReply()"))
        XCTAssertTrue(source.contains("connection.invalidationHandler = { @Sendable [lifecycle]"))
    }
}

private final class LifecycleFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0
    private var active = false
    private var statuses: [Int32] = []
    private let epoch = Date()
    var now: Date { lock.withLock { epoch.addingTimeInterval(seconds) } }
    var exits: [Int32] { lock.withLock { statuses } }
    var busy: Bool {
        get { lock.withLock { active } }
        set { lock.withLock { active = newValue } }
    }
    func advance(to seconds: TimeInterval) { lock.withLock { self.seconds = seconds } }
    func makeLifecycle(signer: @escaping @Sendable () -> String? = { "fixture-requirement" }) -> FileOperationHelperLifecycle {
        FileOperationHelperLifecycle(signer: signer, updateIsBusy: { self.busy },
            uptime: { self.lock.withLock { self.seconds } }, date: { self.now },
            exitProcess: { status in self.lock.withLock { self.statuses.append(status) } })
    }
}
