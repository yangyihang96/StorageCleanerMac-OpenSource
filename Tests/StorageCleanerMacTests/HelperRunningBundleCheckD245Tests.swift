import FileOperationShared
import XCTest

/// D245 (review P2-5): the file-operation helper refuses to move an app whose
/// main program runs. It asked `NSRunningApplication`, which from a root
/// LaunchDaemon sees no user's applications and always answered "none"; it
/// now reads the process table, with the client's own scope (the app's
/// instances, not programs embedded elsewhere in the bundle).
final class HelperRunningBundleCheckD245Tests: XCTestCase {
    private func process(_ executable: String, pid: pid_t = 501, zombie: Bool = false) -> UpdateProcessSnapshot {
        UpdateProcessSnapshot(pid: pid, startTime: 1, parentPID: 1, groupPID: pid, uid: 501,
                              executable: executable, zombie: zombie)
    }

    func testOnlyTheBundlesLiveMainProgramCounts() {
        let bundle = "/Applications/Example.app"
        let main = process("/Applications/Example.app/Contents/MacOS/Example")
        XCTAssertTrue(RunningBundleCheck.mainExecutableIsRunning(bundlePath: bundle, executableName: "Example", processes: [main]))
        XCTAssertTrue(RunningBundleCheck.mainExecutableIsRunning(bundlePath: bundle + "/", executableName: "Example", processes: [main]))
        XCTAssertFalse(RunningBundleCheck.mainExecutableIsRunning(bundlePath: bundle, executableName: "Example",
                                                                 processes: [process(main.executable, zombie: true)]),
                       "an exited process is not running")
        let embedded = process("/Applications/Example.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper")
        let sibling = process("/Applications/Example.app/Contents/MacOS/Updater")
        XCTAssertFalse(RunningBundleCheck.mainExecutableIsRunning(bundlePath: bundle, executableName: "Example",
                                                                 processes: [embedded, sibling]),
                       "as the client's check: other programs in the bundle do not count")
        XCTAssertFalse(RunningBundleCheck.mainExecutableIsRunning(bundlePath: bundle, executableName: "Example",
                                                                 processes: [process("/Applications/Example.app.old/Contents/MacOS/Example")]))
    }

    func testWithoutAUsableExecutableNameAnyDirectProgramCounts() {
        let bundle = "/Applications/Example.app"
        let direct = process("/Applications/Example.app/Contents/MacOS/Whatever")
        let nested = process("/Applications/Example.app/Contents/MacOS/Tools/Whatever")
        for name in [nil, "", "../Escape"] as [String?] {
            XCTAssertTrue(RunningBundleCheck.mainExecutableIsRunning(bundlePath: bundle, executableName: name, processes: [direct]))
            XCTAssertFalse(RunningBundleCheck.mainExecutableIsRunning(bundlePath: bundle, executableName: name, processes: [nested]))
        }
    }

    /// The live table, read as this (non-root) test user: Finder always runs
    /// in a logged-in session; a bundle that does not exist never does.
    func testTheLiveProcessTableFindsARunningApplication() throws {
        let table = try XCTUnwrap(UpdateProcessSnapshot.table())
        XCTAssertTrue(RunningBundleCheck.mainExecutableIsRunning(
            bundlePath: "/System/Library/CoreServices/Finder.app", executableName: "Finder", processes: table))
        XCTAssertFalse(RunningBundleCheck.mainExecutableIsRunning(
            bundlePath: "/Applications/StorageCleanerNoSuch-\(UUID().uuidString).app", executableName: "None", processes: table))
    }
}
