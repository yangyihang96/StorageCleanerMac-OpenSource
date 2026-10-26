import XCTest
import StorageCleanerTestDisplayBootstrap
@testable import StorageCleanerMac

/// D106: the acceptance launch's argument contract, its log, the test
/// bundle's gate mode and what an acceptance session leaves out. Private
/// temporary directories and fake helpers only.
final class AcceptanceLaunchTests: XCTestCase {
    private let app = "/Applications/Fixture.app/Contents/MacOS/StorageCleanerMac"
    private let display = "虚拟屏 1 · Codex"
    private let log = "/private/tmp/d106-fixture/acceptance.jsonl"

    func testANormalLaunchIsNoAcceptanceRequest() {
        XCTAssertEqual(AcceptanceLaunch.request(in: [app]), .success(nil))
        XCTAssertEqual(AcceptanceLaunch.request(in: [app, "-psn_0_12345", "--open-menu-bar-panel"]), .success(nil))
        XCTAssertEqual(AcceptanceLaunch.request(in: ["--acceptance-display"]), .success(nil),
                       "the executable path is not an argument")
        XCTAssertFalse(AcceptanceLaunch.isActive, "tests and release builds never run in acceptance mode")
    }

    func testAnAcceptanceRequestNeedsADisplayAndANewAbsoluteLog() {
        XCTAssertEqual(
            AcceptanceLaunch.request(in: [app, "--acceptance-display", display, "--acceptance-log", log]),
            .success(.init(displayName: display, logPath: log, opensPanel: false))
        )
        XCTAssertEqual(
            AcceptanceLaunch.request(in: [app, "-psn_0_1", "--acceptance-log", log, "--open-menu-bar-panel",
                                          "-ApplePersistenceIgnoreState", "YES", "--acceptance-display", display]),
            .success(.init(displayName: display, logPath: log, opensPanel: true))
        )
        let refused: [([String], AcceptanceLaunch.RequestError)] = [
            ([app, "--acceptance-display"], .missingValue("--acceptance-display")),
            ([app, "--acceptance-display", "--acceptance-log", log], .missingValue("--acceptance-display")),
            ([app, "--acceptance-display", display, "--acceptance-log"], .missingValue("--acceptance-log")),
            ([app, "--acceptance-display", display], .missingLog),
            ([app, "--acceptance-display", display, "--acceptance-log", "relative.jsonl"], .relativeLogPath),
            ([app, "--acceptance-display", display, "--acceptance-display", display, "--acceptance-log", log],
             .repeated("--acceptance-display")),
            ([app, "--acceptance-display", display, "--acceptance-log", log, "--acceptance-log", log],
             .repeated("--acceptance-log")),
            ([app, "--acceptance-display", display, "--acceptance-log", log, "--diagnose-scan"],
             .unsupportedArgument("--diagnose-scan")),
            ([app, "--acceptance-display", display, "--acceptance-log", log, "--open-menu-bar-panel-on-launch"],
             .unsupportedArgument("--open-menu-bar-panel-on-launch")),
            ([app, "--acceptance-display", display, "--acceptance-log", log, "capture"], .unsupportedArgument("capture")),
            ([app, "--acceptance-display", display, "--acceptance-log", log, "-NSDebug"], .missingValue("-NSDebug")),
            // A partial or misspelt request is refused, never started as a
            // normal launch on the menu-bar display.
            ([app, "--acceptance-log", log], .missingValue("--acceptance-display")),
            ([app, "--acceptance-dispaly", display, "--acceptance-log", log], .unsupportedArgument("--acceptance-dispaly")),
            ([app, "--acceptance"], .unsupportedArgument("--acceptance")),
            ([app, "--open-menu-bar-panel", "--acceptance-logs", log], .unsupportedArgument("--acceptance-logs"))
        ]
        for (arguments, error) in refused {
            XCTAssertEqual(AcceptanceLaunch.request(in: arguments), .failure(error), "\(arguments)")
        }
    }

    /// D106-R3: the app finds its diagnostic, capture and fixture switches
    /// with `arguments.contains`, wherever they stand, so the parser may not
    /// take one for the value of a defaults override either.
    func testNoLaunchSwitchRidesAlongInAnyArgumentPosition() {
        let request = [app, "--acceptance-display", display, "--acceptance-log", log]
        for diagnostic in ["--diagnose-hardware-control", "--diagnose-hardware-writes", "--diagnose-fan-max-hold",
                           "--debug-mini-window-demo-data", "--capture-main-window-directory=/private/tmp/d106-fixture"] {
            let positions: [[String]] = [
                request + [diagnostic],
                request + ["-ApplePersistenceIgnoreState", diagnostic],
                request + ["-Fixture", diagnostic, "-ApplePersistenceIgnoreState", "YES"],
                [app, "-Fixture", diagnostic] + request.dropFirst(),
                [app, "--acceptance-display", display, "-Fixture", diagnostic, "--acceptance-log", log],
                [app, "--acceptance-display", diagnostic, "--acceptance-log", log]
            ]
            for arguments in positions {
                XCTAssertEqual(AcceptanceLaunch.request(in: arguments), .failure(.unsupportedArgument(diagnostic)),
                               "\(arguments)")
            }
        }
        let refused: [([String], AcceptanceLaunch.RequestError)] = [
            // The request's own switches are no defaults value either: the app would still see them.
            (request + ["-Fixture", "--open-menu-bar-panel"], .missingValue("-Fixture")),
            ([app, "-Fixture", "--acceptance-display", display, "--acceptance-log", log], .missingValue("-Fixture")),
            (request + ["-ApplePersistenceIgnoreState"], .missingValue("-ApplePersistenceIgnoreState")),
            (request + ["--open-menu-bar-panel", "-psn_0_1", "--open-menu-bar-panel"], .repeated("--open-menu-bar-panel"))
        ]
        for (arguments, error) in refused {
            XCTAssertEqual(AcceptanceLaunch.request(in: arguments), .failure(error), "\(arguments)")
        }
        XCTAssertEqual(
            AcceptanceLaunch.request(in: request + ["-ApplePersistenceIgnoreState", "YES", "-FixtureOffset", "-1"]),
            .success(.init(displayName: display, logPath: log, opensPanel: false)),
            "volatile defaults overrides, with values that start with one dash, stay allowed"
        )
    }

    /// Every `--` literal in the app's sources (launch switches and their
    /// `=` prefixes) is refused next to a valid request, both on its own and
    /// as a defaults value, so a new switch needs no entry here.
    func testEverySwitchTheSourcesNameIsRefusedInAcceptance() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/StorageCleanerMac")
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects ?? [])
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let literal = try NSRegularExpression(pattern: #""(--[A-Za-z][A-Za-z0-9-]*=?)"#)
        var switches = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                switches.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        XCTAssertTrue(switches.isSuperset(of: ["--diagnose-hardware-control", "--diagnose-hardware-writes",
                                               "--diagnose-fan-max-hold", "--open-menu-bar-panel"]),
                      "the scan sees the app's launch switches")
        let request = [app, "--acceptance-display", display, "--acceptance-log", log]
        let own: Set = [AcceptanceLaunch.displayArgument, AcceptanceLaunch.logArgument, AcceptanceLaunch.openPanelArgument]
        for found in switches.subtracting(own).sorted() {
            XCTAssertEqual(AcceptanceLaunch.request(in: request + [found]), .failure(.unsupportedArgument(found)), found)
            XCTAssertEqual(AcceptanceLaunch.request(in: request + ["-ApplePersistenceIgnoreState", found]),
                           .failure(.unsupportedArgument(found)), found)
        }
    }

    func testTheLogIsAlwaysANewOwnerOnlyFileOfJSONLines() throws {
        let directory = try makePrivateDirectory()
        let path = directory.appendingPathComponent("acceptance.jsonl").path
        let log = try XCTUnwrap(AcceptanceDisplayLog(path: path))
        XCTAssertNil(AcceptanceDisplayLog(path: path), "an existing log is never appended to or replaced")
        let link = directory.appendingPathComponent("link.jsonl").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        XCTAssertNil(AcceptanceDisplayLog(path: link))
        XCTAssertNil(AcceptanceDisplayLog(path: directory.appendingPathComponent("missing/acceptance.jsonl").path))

        log.record(kind: "installed", detail: "fixture")
        log.record(DisplayConfinementGate.Event(kind: .moved, entry: "orderFront:", window: "NSWindow#1",
                                                before: CGRect(x: 1, y: 2, width: 3, height: 4),
                                                after: CGRect(x: 5, y: 6, width: 7, height: 8), detail: ""))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(first["kind"] as? String, "installed")
        XCTAssertNotNil(first["time"] as? String)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(second["entry"] as? String, "orderFront:")
        XCTAssertEqual(second["before"] as? [Double], [1, 2, 3, 4])
        XCTAssertEqual(second["after"] as? [Double], [5, 6, 7, 8])
        XCTAssertNil(second["detail"])
    }

    func testTheTestBundleRefusesWindowsUnlessADisplayIsNamed() {
        XCTAssertEqual(storage_cleaner_test_display_bootstrap_linked(), 1)
        guard case .denyAll = TestDisplayGate.mode(environment: [:], logCreated: false) else {
            return XCTFail("no display named: no window may appear")
        }
        guard case .denyAll = TestDisplayGate.mode(environment: [TestDisplayGate.displayKey: ""], logCreated: false) else {
            return XCTFail("an empty display name refuses every window")
        }
        let named = [TestDisplayGate.displayKey: display]
        XCTAssertEqual(TestDisplayGate.mode(environment: named, logCreated: false), .confine(displayName: display))
        var logged = named
        logged[TestDisplayGate.logKey] = log
        XCTAssertEqual(TestDisplayGate.mode(environment: logged, logCreated: true), .confine(displayName: display))
        guard case .denyAll = TestDisplayGate.mode(environment: logged, logCreated: false) else {
            return XCTFail("a requested log that could not be created refuses every window")
        }
    }

    @MainActor
    func testAnAcceptanceCoordinatorNeverReachesTheHelper() async {
        let requests = RequestCounter()
        let coordinator = FanControlCoordinator.makeAcceptanceInstance(
            defaults: TestPreferenceDomain.make(for: self),
            requestSender: { request in
                requests.record(request.operation.rawValue)
                throw CancellationError()
            }
        )
        // Two independent layers: every entry point returns early, and the
        // helper never reads as enabled, so neither alone can start a write.
        XCTAssertTrue(coordinator.isDataOnlyFixture, "every helper entry point returns before it can register, connect or send")
        XCTAssertEqual(coordinator.helperStatus, .unavailable)
        await coordinator.refreshConnection()
        await coordinator.prepareForTermination()
        coordinator.disconnectForTermination()
        XCTAssertEqual(requests.operations, [], "quitting an acceptance session sends nothing, so nothing is restored or written")
    }

    /// The launch-time work an acceptance session leaves out, pinned at its
    /// source so a refactor cannot drop a guard silently.
    func testAnAcceptanceSessionLeavesOutLaunchSideEffects() throws {
        let app = compact(try source("App/StorageCleanerMacApp.swift"))
        XCTAssertTrue(app.contains(
            "#if STORAGE_CLEANER_BETA // D106: first, so a refused acceptance launch exits before any // window, status item, store or helper connection exists. AcceptanceLaunch.configureOrExit() #endif Self.terminateIfDuplicateInstance()"
        ))
        XCTAssertTrue(app.contains(
            "if !AcceptanceLaunch.isActive { Task.detached(priority: .utility) { SQLiteSnapshotService().cleanupOrphans() } BrowserPrivacyRecoveryMaintenance.enableAndPurge() }"
        ))
        let updater = compact(try source("Services/AppUpdater.swift"))
        XCTAssertTrue(updater.contains("startingUpdater: !AcceptanceLaunch.isActive,"))
        XCTAssertTrue(updater.contains("func checkForUpdates() { // D106: not even on request; an acceptance session installs nothing. guard !AcceptanceLaunch.isActive else { return }"))
        let coordinator = compact(try source("Services/FanControlCoordinator.swift"))
        XCTAssertTrue(coordinator.contains("static let shared = AcceptanceLaunch.isActive ? makeAcceptanceInstance()"))
        let menuBar = compact(try source("Support/MenuBarStatusController.swift"))
        XCTAssertTrue(menuBar.contains("if AcceptanceLaunch.isActive { installWithoutStatusItem(store: store) return }"))
        let store = compact(try source("Stores/ScanStore.swift"))
        for guardSite in [
            "func refreshAppUpdates() { // D106: the scan runs brew, mas and msupdate, contacts update servers // and can resume a saved queue that relaunches or installs apps. guard !AcceptanceLaunch.isActive else {",
            // D168: Smart Care's read-only check has the same guard first.
            "func checkAppUpdatesForSmartCare() { // D106: an acceptance session checks nothing (see above). guard !AcceptanceLaunch.isActive else { return }",
            "func prepareApplicationUpdatesOnLaunch() { guard !AcceptanceLaunch.isActive else { return }",
            "func checkAccessAfterReturn() { // D106: no protected-folder probe in an acceptance session (see above). guard !AcceptanceLaunch.isActive else { return }"
        ] {
            XCTAssertTrue(store.contains(guardSite), guardSite)
        }
        XCTAssertTrue(store.contains("restoreFolderAccessForLaunch() return } // D106: the first check lists protected folders, and macOS shows its // permission prompts on the menu-bar display. guard !AcceptanceLaunch.isActive else { return }"))
        let benchmark = compact(try source("Stores/MacBenchmarkStore.swift"))
        XCTAssertTrue(benchmark.contains("if !AcceptanceLaunch.isActive { await lifecycleCleaner.cleanupOrphanedArtifactsOnLaunch() }"))
        let settings = compact(try source("Views/Settings/SettingsGeneral.swift"))
        XCTAssertTrue(settings.contains("guard DisplayConfinementGate.shared.permitsExternal( \"SMAppService.mainApp\""))
        let mover = compact(try source("Services/AuthorizedApplicationMover.swift"))
        XCTAssertTrue(mover.contains("guard DisplayConfinementGate.shared.permitsExternal(\"FileOperationHelper\", detail: \"register and authorize\") else { throw AuthorizedMoveError.unavailable }"))
        let launch = compact(try source("Support/AcceptanceLaunch.swift"))
        XCTAssertTrue(launch.contains("guard access == .verified else {"))
    }

    // MARK: Helpers

    private func makePrivateDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcceptanceLaunchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/" + path), encoding: .utf8)
    }

    private func compact(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var operations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ operation: String) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(operation)
    }
}
