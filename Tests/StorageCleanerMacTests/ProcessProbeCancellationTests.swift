import Darwin
import XCTest
@testable import StorageCleanerMac

final class ProcessProbeCancellationTests: XCTestCase {
    func testProbeSignalsRequireTheCurrentDirectChildBirthIdentity() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        let identity = try XCTUnwrap(Shell.directChildIdentity(for: child.processIdentifier))
        XCTAssertNil(Shell.directChildIdentity(for: getpid()))
        Shell.signalDirectChild(nil, signal: SIGTERM)
        Shell.signalDirectChild(.init(processID: identity.processID,
            startSeconds: identity.startSeconds + 1, startMicroseconds: identity.startMicroseconds), signal: SIGTERM)
        XCTAssertTrue(child.isRunning, "A reused/mismatched PID must not receive a signal")
        Shell.signalDirectChild(identity, signal: SIGTERM)
        child.waitUntilExit()
        XCTAssertFalse(child.isRunning)
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
    }
}
