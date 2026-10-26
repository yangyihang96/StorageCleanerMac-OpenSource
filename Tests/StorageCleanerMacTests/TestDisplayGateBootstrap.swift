import AppKit
import XCTest
@testable import StorageCleanerMac

/// D106: called by the load-time constructor in
/// StorageCleanerTestDisplayBootstrap, before any test class is set up, so
/// every window a test orders goes through the display gate. Without
/// STORAGE_CLEANER_TEST_DISPLAY no test may show a window or start UI in
/// another process. With it, windows appear only on that named display
/// (script/run_display_bound_tests.sh), which must not be the menu-bar
/// display. A refused or after-the-fact window fails the running test.
@_cdecl("storage_cleaner_install_test_display_gate")
func storageCleanerInstallTestDisplayGate() {
    TestDisplayGate.install(environment: ProcessInfo.processInfo.environment)
}

enum TestDisplayGate {
    static let displayKey = "STORAGE_CLEANER_TEST_DISPLAY"
    /// An absolute path for a new JSON-lines file of every gate decision.
    static let logKey = "STORAGE_CLEANER_TEST_DISPLAY_LOG"

    /// The mode the test process starts in. A requested log that could not
    /// be created refuses every window, so a display run never goes unlogged.
    static func mode(environment: [String: String], logCreated: Bool) -> DisplayConfinementGate.Mode {
        guard let name = environment[displayKey] else {
            return .denyAll(reason: "tests show no window unless \(displayKey) names a display (D106)")
        }
        guard !name.isEmpty else { return .denyAll(reason: "\(displayKey) is empty") }
        if environment[logKey] != nil, !logCreated {
            return .denyAll(reason: "\(logKey) must be an absolute path for a new file")
        }
        return .confine(displayName: name)
    }

    static func install(environment: [String: String]) {
        let observer = TestDisplayGateObserver.shared
        let onViolation: @Sendable (DisplayConfinementGate.Event) -> Void = { observer.fail($0) }
        XCTestObservationCenter.shared.addTestObserver(observer)
        guard let path = environment[logKey] else {
            DisplayConfinementGate.shared.activate(
                mode: mode(environment: environment, logCreated: false), onViolation: onViolation
            )
            return
        }
        // swift test first loads the bundle in swiftpm-xctest-helper only to
        // list the tests, with the same environment. The log belongs to the
        // process that runs them, so it is created when the tests start;
        // until then every window is refused.
        DisplayConfinementGate.shared.activate(
            mode: .denyAll(reason: "the display log opens when the tests start (D106)"), onViolation: onViolation
        )
        observer.whenTestsStart {
            let log = path.hasPrefix("/") ? AcceptanceDisplayLog(path: path) : nil
            let gateMode = mode(environment: environment, logCreated: log != nil)
            var sink: (@Sendable (DisplayConfinementGate.Event) -> Void)?
            if let log { sink = { log.record($0) } }
            DisplayConfinementGate.shared.activate(mode: gateMode, sink: sink, onViolation: onViolation)
            let process = ProcessInfo.processInfo
            log?.record(kind: DisplayConfinementGate.Event.Kind.installed.rawValue,
                        detail: "\(gateMode) in \(process.processName) \(process.processIdentifier)")
            return log == nil
                ? "\(logKey) could not be created as a new file at \(path); every window is refused"
                : nil
        }
    }
}

/// Turns gate refusals and violations into failures of the running test.
/// One that happens between tests fails the next test; one after the last
/// test fails the run.
final class TestDisplayGateObserver: NSObject, XCTestObservation, @unchecked Sendable {
    static let shared = TestDisplayGateObserver()

    private let lock = NSLock()
    private var current: XCTestCase?
    private var pending: [String] = []
    private var testsStart: (() -> String?)?

    /// Runs `body` once when this process starts running the tests; a
    /// returned problem fails the first test.
    func whenTestsStart(_ body: @escaping () -> String?) {
        locked { testsStart = body }
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        let start: (() -> String?)? = locked {
            defer { testsStart = nil }
            return testsStart
        }
        if let problem = start?() { locked { pending.append("D106 display gate: " + problem) } }
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        let earlier: [String] = locked {
            current = testCase
            defer { pending = [] }
            return pending
        }
        for text in earlier { testCase.record(Self.issue(text + " (before this test started)")) }
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        locked { if current === testCase { current = nil } }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let remaining = locked { pending }
        guard !remaining.isEmpty else { return }
        for text in remaining { FileHandle.standardError.write(Data("error: \(text) (after the last test)\n".utf8)) }
        exit(1)
    }

    func fail(_ event: DisplayConfinementGate.Event) {
        let text = "D106 display gate \(event.kind.rawValue): \(event.entry) \(event.window) \(event.detail)"
        FileHandle.standardError.write(Data((text + "\n").utf8))
        if let test = locked({ current }) {
            test.record(Self.issue(text))
        } else {
            locked { pending.append(text) }
        }
    }

    private static func issue(_ text: String) -> XCTIssue {
        XCTIssue(type: .assertionFailure, compactDescription: text)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
