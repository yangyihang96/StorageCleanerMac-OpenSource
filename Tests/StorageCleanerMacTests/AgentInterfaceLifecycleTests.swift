import AgentBridgeCore
import AgentGatewayCore
import AgentShared
import FanControlShared
import XCTest
@testable import StorageCleanerMac

/// D265, D267 on the App side: the interface is off until the user turns it
/// on, does not depend on a window, and goes away with the process.
@MainActor
final class AgentInterfaceLifecycleTests: XCTestCase {
    struct EmptySource: AgentReadSource {
        func overview() async -> AgentOverviewState { AgentOverviewState() }
        func live() async -> AgentLiveState { AgentLiveState() }
        func health() async -> AgentHealthState { AgentHealthState() }
        func junk() async -> AgentModuleResults<ScanCandidate> { .init(status: .notScanned) }
        func startupItems() async -> AgentModuleResults<StartupItemsDomain.Item> { .init(status: .notScanned) }
        func installedApps() async -> AgentModuleResults<InstalledAppItem> { .init(status: .notScanned) }
        func appUpdates() async -> AgentModuleResults<AppUpdateItem> { .init(status: .notScanned) }
        func lastCleanupScan() async -> ScanHistoryEntry? { nil }
        func scanHistory() async -> [ScanHistoryEntry] { [] }
        func operationRecords(after cursor: CleanupReportIndex.Cursor?, limit: Int) throws -> CleanupReportJournal.SummaryPage {
            .init(reports: [], next: nil, unreadableEntries: [])
        }
        func operationRecord(_ id: CleanPlanID) throws -> CleanReport { throw CleanupReportJournal.Failure.invalidEntry }
        func hardwareOperations() async throws -> [HardwareOperationRecord] { [] }
        func capacityHistory() throws -> [CapacityHistoryPoint] { [] }
    }

    private func interface(applicationURL: URL = URL(fileURLWithPath: "/nonexistent/Fixture.app")) throws -> (AgentInterface, UserDefaults, URL) {
        let defaults = TestPreferenceDomain.make(for: self)
        let data = try shortDataDirectory()
        return (AgentInterface(defaults: defaults, dataDirectory: data, applicationURL: applicationURL, launchBlocked: false), defaults, data)
    }

    /// `sun_path` holds 103 bytes; `TestFileSystem`'s roots are too long for it.
    private func shortDataDirectory() throws -> URL {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("sca-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: data) }
        return data
    }

    func testTheSwitchIsOffByDefaultAndNothingListens() async throws {
        let (interface, defaults, data) = try interface()
        XCTAssertFalse(interface.isEnabled)
        XCTAssertEqual(AgentPreferenceKey.interfaceEnabled(in: defaults), false)
        interface.start(source: EmptySource())
        await interface.waitForStatusUpdate()
        XCTAssertEqual(interface.status, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("Agent").path), "off leaves nothing on disk")
    }

    /// What the bridge reads too; here because `TestPreferenceDomain` is here.
    func testTheSwitchKeyReadsOnlyWhatTheAppStored() {
        let defaults = TestPreferenceDomain.make(for: self)
        XCTAssertEqual(AgentPreferenceKey.interfaceEnabled(in: defaults), false, "D265: off by default")
        defaults.set(true, forKey: AgentPreferenceKey.interfaceEnabled)
        XCTAssertEqual(AgentPreferenceKey.interfaceEnabled(in: defaults), true)
        XCTAssertNil(AgentPreferenceKey.interfaceEnabled(in: nil))
    }

    func testOnWithoutASignedBridgeFailsClosedAndSaysWhy() async throws {
        let (interface, defaults, data) = try interface()
        interface.start(source: EmptySource())
        interface.setEnabled(true)
        await interface.waitForStatusUpdate()
        XCTAssertEqual(defaults.object(forKey: AgentPreferenceKey.interfaceEnabled) as? Bool, true)
        XCTAssertEqual(interface.status, .failed(.bridgeUnverifiable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AgentSocketLocation.socketPath(dataDirectory: data)))
        interface.setEnabled(false)
        await interface.waitForStatusUpdate()
        XCTAssertEqual(interface.status, .off)
        XCTAssertEqual(defaults.object(forKey: AgentPreferenceKey.interfaceEnabled) as? Bool, false)
    }

    func testASwitchLeftOnAppliesAtLaunch() async throws {
        let (interface, defaults, _) = try interface()
        defaults.set(true, forKey: AgentPreferenceKey.interfaceEnabled)
        interface.start(source: EmptySource())
        await interface.waitForStatusUpdate()
        XCTAssertEqual(interface.status, .failed(.bridgeUnverifiable), "it tried: a real App has a signed bridge")
    }

    func testAnAcceptanceSessionNeverOpensTheInterface() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let data = try shortDataDirectory()
        defaults.set(true, forKey: AgentPreferenceKey.interfaceEnabled)
        let interface = AgentInterface(defaults: defaults, dataDirectory: data, applicationURL: URL(fileURLWithPath: "/nonexistent/Fixture.app"), launchBlocked: true)
        interface.start(source: EmptySource())
        await interface.waitForStatusUpdate()
        XCTAssertEqual(interface.status, .off)
    }

    func testApprovalsAreKeptInTheAppsPreferences() async throws {
        let (interface, defaults, _) = try interface()
        interface.start(source: EmptySource())
        let client = AgentClientIdentity(kind: .signed, identifier: "com.fixture", team: "T", cdhash: nil, executablePath: "~/x", displayName: "Fixture")
        try XCTUnwrap(interface.registry).decide(client, .readOnly, at: Date())
        XCTAssertNotNil(defaults.data(forKey: AgentPreferenceKey.clients))

        let reopened = AgentInterface(defaults: defaults, dataDirectory: try shortDataDirectory(),
                                      applicationURL: URL(fileURLWithPath: "/nonexistent/Fixture.app"), launchBlocked: false)
        reopened.start(source: EmptySource())
        XCTAssertEqual(try XCTUnwrap(reopened.registry).decision(for: client), .readOnly)
    }

    /// D265: what the settings page shows and does, without the page.
    func testTheUserDecidesAndRevokesThroughTheInterface() throws {
        let (interface, _, _) = try interface()
        interface.start(source: EmptySource())
        let client = AgentClientIdentity(kind: .signed, identifier: "com.fixture", team: "T", cdhash: nil, executablePath: "~/x", displayName: "Fixture")
        _ = try XCTUnwrap(interface.registry).notePending(client, at: Date())
        interface.clientAskedForApproval(client)
        XCTAssertEqual(interface.pendingClients.map(\.identity), [client])
        XCTAssertEqual(interface.clients, [])

        interface.decide(client, .readOnly)
        XCTAssertEqual(interface.pendingClients, [])
        XCTAssertEqual(interface.clients.map(\.decision), [.readOnly])

        interface.revoke(bindingKey: client.bindingKey)
        XCTAssertEqual(interface.clients, [])
        XCTAssertNil(try XCTUnwrap(interface.registry).decision(for: client), "back to undecided")
    }

    func testAWaitingClientIsAnnounced() async throws {
        let announced = AnnouncedClients()
        let defaults = TestPreferenceDomain.make(for: self)
        let interface = AgentInterface(defaults: defaults, dataDirectory: try shortDataDirectory(), applicationURL: URL(fileURLWithPath: "/nonexistent/Fixture.app"),
                                       launchBlocked: false, announceWaitingClient: { await announced.add($0) })
        interface.start(source: EmptySource())
        let client = AgentClientIdentity(kind: .signed, identifier: "com.fixture", team: "T", cdhash: nil, executablePath: "~/x", displayName: "Fixture")
        interface.clientAskedForApproval(client)
        await interface.waitForAnnouncements()
        let names = await announced.names
        XCTAssertEqual(names, ["Fixture"])
    }

    private actor AnnouncedClients {
        private(set) var names: [String] = []
        func add(_ client: AgentClientIdentity) { names.append(client.displayName) }
    }

    func testTheConfigurationSnippetsNameThisBundlesBridge() throws {
        let application = URL(fileURLWithPath: "/Applications/测试版.app")
        let (interface, _, _) = try interface(applicationURL: application)
        let snippets = interface.configSnippets(bundleIdentifier: AgentDataLocation.betaBundleIdentifier)
        XCTAssertTrue(snippets.codex.contains("/Applications/测试版.app/Contents/Helpers/storage-cleaner-agent"))
        XCTAssertTrue(snippets.codex.contains("[mcp_servers.storage-cleaner-beta]"))
        XCTAssertTrue(snippets.claudeCode.contains("storage-cleaner-beta"))
        XCTAssertTrue(snippets.claudeDesktop.contains("storage-cleaner-beta"))
    }

    func testEveryStatusSaysWhatItMeans() {
        let failures: [AgentGatewayFailure] = [
            .location(.pathTooLong(120)), .location(.missing), .location(.notADirectory), .location(.isSymbolicLink), .location(.wrongOwner),
            .location(.wrongPermissions(0o755)), .location(.notASocket), .bridgeUnverifiable, .socket(EADDRINUSE), .socket(EIO)
        ]
        XCTAssertFalse(AgentGatewayStatus.off.settingsText.isEmpty)
        XCTAssertFalse(AgentGatewayStatus.listening.settingsText.isEmpty)
        for failure in failures { XCTAssertFalse(AgentGatewayStatus.failed(failure).settingsText.isEmpty, String(describing: failure)) }
        XCTAssertTrue(AgentGatewayStatus.failed(.location(.pathTooLong(120))).settingsText.contains("120"))
        XCTAssertNotEqual(AgentGatewayStatus.failed(.socket(EADDRINUSE)).settingsText, AgentGatewayStatus.failed(.socket(EIO)).settingsText)
    }

    func testAccessEntriesAreEmptyBeforeAnyCall() async throws {
        let (interface, _, _) = try interface()
        let none = await interface.accessEntries()
        XCTAssertEqual(none, [])
        interface.start(source: EmptySource())
        let entries = await interface.accessEntries()
        XCTAssertEqual(entries, [])
    }

    func testTerminatingWithoutAGatewayIsHarmless() throws {
        let (interface, _, _) = try interface()
        interface.terminate()
        XCTAssertEqual(interface.status, .off)
    }

    /// One source of truth for where the socket is: the bridge works it out
    /// without the App's code, so a drift would make it miss the App silently.
    func testTheBridgeAndTheAppAgreeOnTheDataDirectory() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        XCTAssertEqual(
            AgentDataLocation.dataDirectory(bundleIdentifier: AgentDataLocation.releaseBundleIdentifier, environment: [:], home: home, compiledAsBeta: false)?.path,
            support.appendingPathComponent(AppDataDirectories.applicationSupportDirectoryName(isBeta: false)).path)
        XCTAssertEqual(
            AgentDataLocation.dataDirectory(bundleIdentifier: AgentDataLocation.betaBundleIdentifier, environment: [:], home: home, compiledAsBeta: true)?.path,
            support.appendingPathComponent(AppDataDirectories.applicationSupportDirectoryName(isBeta: true)).path)
        XCTAssertEqual(StorageCleanerBuildIdentity.appBundleIdentifier,
                       StorageCleanerBuildIdentity.isBeta ? AgentDataLocation.betaBundleIdentifier : AgentDataLocation.releaseBundleIdentifier)

        // QA copies isolate only under ~/Library/Caches/StorageCleanerIntegration-*.
        let id = AgentDataLocation.integrationBundleIdentifier
        let cases: [String?] = [home.appendingPathComponent("Library/Caches/StorageCleanerIntegration-fixture").path,
                                home.appendingPathComponent("Library/Caches/Other").path,
                                home.appendingPathComponent("Library/Caches/StorageCleanerIntegration-fixture/../x").path, nil]
        for raw in cases {
            let environment = raw.map { [AgentDataLocation.integrationRootVariable: $0] } ?? [:]
            let app = AppDataDirectories.integrationRoot(fileManager: .default, bundleIdentifier: id, environment: environment)
            let bridge = AgentDataLocation.dataDirectory(bundleIdentifier: id, environment: environment, home: home, compiledAsBeta: AgentDataLocation.compiledAsBeta)
            let compiled = support.appendingPathComponent(StorageCleanerBuildIdentity.applicationSupportDirectoryName)
            XCTAssertEqual(bridge?.path, (app ?? compiled).path, String(describing: raw))
        }
    }

    func testTheInstalledBetasSocketFits() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let beta = try XCTUnwrap(AgentDataLocation.dataDirectory(bundleIdentifier: AgentDataLocation.betaBundleIdentifier, environment: [:], home: home, compiledAsBeta: true))
        XCTAssertNoThrow(try AgentSocketLocation.validateLength(AgentSocketLocation.socketPath(dataDirectory: beta)))
    }

    /// D267: started with the launch work, so no window is needed; stopped when
    /// the process really ends, not by the D256 quit that keeps the panel. It
    /// is not one of the termination preparations (D255's source constraints).
    func testTheInterfaceIsWiredToLaunchAndTerminationOnly() throws {
        let app = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift")
        let run = try MiniWindowLogicFixtures.section(app, from: "func run(delegate: AppDelegate?) {", to: "\n    }\n")
        XCTAssertTrue(run.contains("AgentInterface.shared.start(source: AgentStoreReadSource(store: store, health: computerHealthStore))"))
        let terminate = try MiniWindowLogicFixtures.section(app, from: "func applicationWillTerminate(_ notification: Notification) {", to: "\n    }\n")
        XCTAssertTrue(terminate.contains("AgentInterface.shared.terminate()"))
        let shouldTerminate = try MiniWindowLogicFixtures.section(app, from: "func applicationShouldTerminate(", to: "/// Shared by the real exit sequence")
        XCTAssertFalse(shouldTerminate.contains("AgentInterface"))
        let preparations = try MiniWindowLogicFixtures.section(app, from: "private func installTerminationWork(on appDelegate: AppDelegate) {", to: "\n    }\n")
        XCTAssertFalse(preparations.contains("AgentInterface"))
    }

    /// D268: reading live status never starts a sample of its own.
    func testTheLiveSourceOnlyReadsExistingSnapshots() throws {
        let source = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Features/Agent/AgentStoreReadSource.swift")
        for forbidden in ["refreshMenuBarLiveStatus", "refreshMemory", "MenuBarSamplingContext", "BatteryPowerService", "startMonitoring", "refresh("] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    /// D261, D262: this batch's App code can only read. Nothing here reaches a
    /// cleanup, an uninstall, a fan write or a setting.
    func testTheAgentFeatureCallsNothingThatChangesAnything() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Features/Agent", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThanOrEqual(files.count, 4)
        for file in files {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            for forbidden in ["requestClean", "confirmClean", "executeCleanup", "moveToTrash(", "uninstall", "setFan", "FanControlCoordinator", "NSWorkspace", "Process(",
                              "removeItem", "trashItem", "NSApp.terminate(", "startScan", "beginScan", "refreshStartupItems", "refreshInstalledApps", "requestMainWindow"] {
                XCTAssertFalse(text.contains(forbidden), "\(forbidden) in \(file)")
            }
        }
    }
}

/// The source on real stores: what a module says before a scan, during one,
/// after one and after D259 released it. Nothing here scans anything.
@MainActor
final class AgentStoreReadSourceTests: XCTestCase {
    private struct NoProbe: ComputerHealthProbing {
        func probe() async throws -> ComputerHealthSnapshot { throw CocoaError(.featureUnsupported) }
    }

    private func makeSource(menuBarOnly: Bool = false) throws -> (AgentStoreReadSource, ScanStore) {
        let store = try ScanStore.makeForTests(for: self)
        let health = ComputerHealthStore(probe: NoProbe(), batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController())
        return (AgentStoreReadSource(store: store, health: health, isMenuBarOnly: { menuBarOnly }), store)
    }

    private func app(_ name: String) -> InstalledAppItem {
        InstalledAppItem(id: "/Applications/\(name).app", name: name, bundleIdentifier: "com.fixture.\(name)", path: "/Applications/\(name).app", version: "1", build: "1",
                         category: "", appDescription: "", sizeBytes: 1, source: "", modifiedAt: nil, relatedPaths: [], relatedItems: [], status: .installed)
    }

    func testNothingScannedInThisRunSaysSo() async throws {
        let (source, _) = try makeSource()
        var status = await source.junk().status
        XCTAssertEqual(status, .notScanned)
        status = await source.startupItems().status
        XCTAssertEqual(status, .notScanned)
        status = await source.installedApps().status
        XCTAssertEqual(status, .notScanned)
        status = await source.appUpdates().status
        XCTAssertEqual(status, .notScanned)
    }

    func testWithOnlyThePanelRunningNoResultsMeansReleased() async throws {
        let (source, _) = try makeSource(menuBarOnly: true)
        let junk = await source.junk()
        XCTAssertEqual(junk.status, .released)
        let overview = await source.overview()
        XCTAssertTrue(overview.isMenuBarOnly)
    }

    func testAModuleGoesFromScanningToReadyAndIsReleasedByD259() async throws {
        let (source, store) = try makeSource(menuBarOnly: true)
        store.isLoadingInstalledApps = true
        var results = await source.installedApps()
        XCTAssertEqual(results.status, .scanning)
        XCTAssertEqual(results.items.count, 0, "half a scan is not an answer")

        store.isLoadingInstalledApps = false
        store.installedApps = [app("A"), app("B")]
        store.hasScannedInstalledApps = true
        results = await source.installedApps()
        XCTAssertEqual(results.status, .ready)
        XCTAssertEqual(results.items.map(\.name), ["A", "B"])

        XCTAssertTrue(store.releaseMainWindowData(privacy: nil))
        results = await source.installedApps()
        XCTAssertEqual(results.status, .released)
        XCTAssertEqual(results.items.count, 0)
    }

    func testTheBatteryReadingPrefersThePanelsAndFallsBackToTheCheck() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let live = BatteryPowerSnapshot(chargePercent: 55, isCharging: false, powerSource: .batteryPower, timeToEmptyMinutes: 90, timeToFullChargeMinutes: nil)
        let reading = AgentStoreReadSource.battery(live: live, liveTime: date, checked: nil)
        XCTAssertEqual(reading, AgentBatteryReading(chargePercent: 55, isCharging: false, powerSource: .batteryPower, minutesRemaining: 90, sampledAt: date))
        XCTAssertNil(AgentStoreReadSource.battery(live: nil, liveTime: nil, checked: nil), "a Mac without a battery has no reading")
    }

    func testLiveStatusAlwaysHasTheStartupDisk() async throws {
        let (source, _) = try makeSource()
        let live = await source.live()
        XCTAssertNotNil(live.capacity)
        XCTAssertNil(live.capacity?.availableForImportantUsageBytes, "reading that figure wakes CacheDelete (D173)")
    }
}
