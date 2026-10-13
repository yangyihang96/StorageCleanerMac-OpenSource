import Darwin
import Foundation
import FileOperationShared
import XCTest
@testable import StorageCleanerMac

final class AppUpdateRepair3Tests: XCTestCase {
    func testNormalParentExitWaitsForLiveOwnedDescendantWithoutSendingTermination() throws {
        // The root is our own short-lived printf. An injected observer models
        // a recorded descendant outliving it; it reports completion after a
        // bounded wait and records every signal at the actual runner boundary.
        let tree = Repair3LiveDescendantObserver()
        let output = try AppUpdateCommandRunner(stopTimeout: 0.5, processTree: { _ in tree }).runSync(executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["root-finished"],
            environment: [:], timeout: 2, cancelled: { false })
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "root-finished")
        XCTAssertTrue(tree.signals.isEmpty, "A normally exiting parent must not terminate its still-completing child")
        XCTAssertGreaterThan(tree.waitChecks, 3)
    }
    func testNativeForkNormalExitCompletesAndReopensEveryOriginallyRunningArtifact() async throws {
        let apps = suite()
        let state = Repair3PackageState(apps: apps, running: Set(apps.map(\.path)))
        let installer = installer(state, mode: .nativeFork)
        let results = await installer.install(applications: [apps[0]]) { _ in }
        XCTAssertEqual(results.map(\.state), [.completed], results.map(\.detail).joined(separator: "\n"))
        let events = await state.events
        XCTAssertEqual(events, ["quit:A.app", "quit:B.app", "upgrade", "reopen:A.app", "reopen:B.app"])
        XCTAssertEqual(results.first?.recoveryEvidence?.reopenOutcomes.count, 2)
    }

    func testNativeForkCancellationRemainsPendingEvenWhenReadbackAlreadyReachedTarget() async throws {
        let apps = suite()
        let state = Repair3PackageState(apps: apps, running: Set(apps.map(\.path)))
        let results = await installer(state, mode: .nativeCancelledFork).install(applications: [apps[0]]) { _ in }
        XCTAssertEqual(results.map(\.state), [.needsReconciliation], results.map(\.detail).joined(separator: "\n"))
        XCTAssertEqual(results.first?.recoveryEvidence?.pendingReopenPaths, apps.map(\.path))
        let events = await state.events
        XCTAssertFalse(events.contains(where: { $0.hasPrefix("reopen:") }))
        XCTAssertEqual(events.filter { $0 == "upgrade" }.count, 1)
    }

    func testNormalExitWithLiveDescendantReceiptStillUsesImmediateReadbackAndNeverRetries() async throws {
        let apps = suite()
        let state = Repair3PackageState(apps: apps, running: Set(apps.map(\.path)))
        let results = await installer(state, mode: .normalLiveDescendant).install(applications: [apps[0]]) { _ in }
        XCTAssertEqual(results.first?.state, .completed)
        let calls = await state.upgrades
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(results.first?.recoveryEvidence?.reopenOutcomes.count, 0)
        XCTAssertEqual(results.first?.installationIsolated, true)
        XCTAssertEqual(results.first?.recoveryEvidence?.pendingReopenPaths, apps.map(\.path))
    }

    func testNormalExitConclusiveOldVersionOrIdentityMismatchFailsButUnreadableEvidenceStaysPending() async throws {
        for mode in [Repair3CommandMode.normalOldVersion, .normalChangedTeam, .normalUnreadable] {
            let apps = suite()
            let state = Repair3PackageState(apps: apps, running: [])
            let results = await installer(state, mode: mode).install(applications: [apps[0]]) { _ in }
            XCTAssertEqual(results.first?.state, mode == .normalUnreadable ? .needsReconciliation : .failed, "\(mode)")
            let calls = await state.upgrades
            XCTAssertEqual(calls, 1)
        }
    }

    func testKnownLiveDescendantAndOldReadbackCannotAuthorizeConcurrentRetry() async throws {
        let apps = suite()
        let state = Repair3PackageState(apps: apps, running: [])
        let results = await installer(state, mode: .normalLiveOldVersion).install(applications: [apps[0]]) { _ in }
        XCTAssertEqual(results.first?.state, .needsReconciliation, "A current old-version snapshot cannot prove a live descendant finished")
        let calls = await state.upgrades
        XCTAssertEqual(calls, 1)
    }

    func testReconciliationRejectsUnselectedArtifactOldVersionAndChangedIdentityDespiteShorterRescan() async throws {
        for change in ["old", "team", "bundle"] {
            let apps = suite()
            let state = Repair3PackageState(apps: apps, running: Set(apps.map(\.path)))
            let installer = installer(state, mode: .injectedPending)
            let frozen = try await installer.recoveryEvidence(for: apps[0])
            XCTAssertEqual(frozen.artifacts.map(\.path), apps.map(\.path))
            var task = ApplicationUpdateTask(sessionID: UUID(), application: apps[0], state: .needsReconciliation)
            task.recoveryEvidence = frozen
            await state.setVersions([apps[0].path: "2.0", apps[1].path: change == "old" ? "1.0" : "2.0"])
            if change == "team" { await state.changeTeam(at: apps[1].path) }
            if change == "bundle" { await state.changeBundle(at: apps[1].path) }
            var shortenedRescan = apps[0]
            shortenedRescan.installedVersion = .init(marketing: "2.0")
            shortenedRescan.homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(token: "suite", installedVersions: ["2.0"], appBundlePaths: [apps[0].path])
            do { _ = try await installer.reconcile(application: shortenedRescan, task: task); XCTFail("Unselected B must participate: \(change)") }
            catch {
                if change == "old" { XCTAssertEqual(error as? ProviderBackedUpdateExecutorError, .versionDidNotChange) }
                else { XCTAssertEqual((error as NSError).domain, "Homebrew.UpdateIdentity") }
            }
            let events = await state.events
            XCTAssertFalse(events.contains(where: { $0.hasPrefix("reopen:") }))
            let upgrades = await state.upgrades
            XCTAssertEqual(upgrades, 0, "Recovery must never execute a new install")
        }
    }

    func testPersistedPendingArtifactReopenListSurvivesRestartAndReconciliationReopensEachCopyOnce() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let queueURL = root.appendingPathComponent("queue.json")
        let apps = suite()
        let state = Repair3PackageState(apps: apps, running: Set(apps.map(\.path)))
        let installer = installer(state, mode: .injectedPending)
        let results = await installer.install(applications: [apps[0]]) { _ in }
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.state, .needsReconciliation)
        var task = ApplicationUpdateTask(sessionID: UUID(), application: apps[0], state: result.state)
        task.recoveryEvidence = result.recoveryEvidence
        let plan = ApplicationUpdatePlanBuilder().build(applications: [apps[0]], id: task.sessionID)
        let repository = ApplicationUpdateQueueRepository(fileURL: queueURL)
        try await repository.save(.init(schemaVersion: ApplicationUpdateQueueRepository.currentSchemaVersion, plan: plan, tasks: [task], isPaused: false, updatedAt: Date()))
        let reopenedRepository = ApplicationUpdateQueueRepository(fileURL: queueURL)
        let persisted = try await reopenedRepository.load()
        let restored = try XCTUnwrap(persisted?.tasks.first)
        XCTAssertEqual(restored.recoveryEvidence?.pendingReopenPaths, apps.map(\.path))
        // No current scan row is available. The saved metadata/artifact evidence
        // must suffice, while still re-reading every path and package version.
        let completed = try await installer.reconcile(application: nil, task: restored)
        XCTAssertEqual(completed.state, .completed)
        var finishedTask = restored; finishedTask.recoveryEvidence = completed.recoveryEvidence
        try await reopenedRepository.save(.init(schemaVersion: ApplicationUpdateQueueRepository.currentSchemaVersion, plan: plan, tasks: [finishedTask], isPaused: false, updatedAt: Date()))
        let secondRead = try await repository.load()
        let finished = try XCTUnwrap(secondRead?.tasks.first)
        XCTAssertTrue(finished.recoveryEvidence?.pendingReopenPaths.isEmpty == true)
        _ = try await installer.reconcile(application: nil, task: finished)
        let events = await state.events
        XCTAssertEqual(events.filter { $0.hasPrefix("reopen:") }, ["reopen:A.app", "reopen:B.app"])
        let upgrades = await state.upgrades
        XCTAssertEqual(upgrades, 1)
    }

    func testFrozenArtifactBaselineCannotBeReplacedByPreExecutionRescan() async throws {
        let apps = suite()
        let state = Repair3PackageState(apps: apps, running: [])
        let installer = installer(state, mode: .nativeFork)
        let evidence = try await installer.recoveryEvidence(for: apps[0])
        await state.setVersions([apps[1].path: "1.5"])
        let results = await installer.install(applications: [apps[0]], recoveryEvidenceByID: [apps[0].id: evidence]) { _ in }
        XCTAssertEqual(results.first?.state, .failed)
        let upgrades = await state.upgrades
        XCTAssertEqual(upgrades, 0)
    }

    func testMixedPendingAndFailedRetryPreservesQuarantineAcrossRestartRescanAndFreshBatch() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = root.appendingPathComponent("queue.json")
        let repository = ApplicationUpdateQueueRepository(fileURL: url)
        let a = formula("A"), b = formula("B"), c = formula("C")
        let executor = Repair3MixedExecutor()
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor)
        let original = try await coordinator.start(applications: [a, b])
        try await waitUntil(coordinator) { $0.tasks.contains { $0.applicationID == "A" && $0.state == .needsReconciliation } && $0.tasks.contains { $0.applicationID == "B" && $0.state == .failed } }
        try await coordinator.retry(applicationID: b.id)
        try await waitUntil(coordinator) { $0.tasks.contains { $0.applicationID == "B" && $0.state == .completed } }
        let persisted = try await repository.load()
        let afterRetry = try XCTUnwrap(persisted)
        XCTAssertNotEqual(afterRetry.plan.id, original.plan.id)
        XCTAssertEqual(afterRetry.tasks.first { $0.applicationID == a.id }?.state, .needsReconciliation)
        XCTAssertEqual(afterRetry.tasks.first { $0.applicationID == a.id }?.originalSessionID, original.plan.id)
        XCTAssertEqual(afterRetry.plan.batchApplicationIDs, [b.id])
        let restarted = ApplicationUpdateCoordinator(repository: ApplicationUpdateQueueRepository(fileURL: url), executor: executor)
        _ = try await restarted.restore(applications: [a, b], autoResume: false)
        let alias = rescanned(a, id: "rescan-row-for-A")
        var otherPath = alias; otherPath.bundleURL = URL(fileURLWithPath: "/fixture/another-artifact-in-A")
        for rescan in [alias, otherPath] {
            do { _ = try await restarted.start(applications: [rescan]); XCTFail("A package cannot escape quarantine under a fresh scan ID/path") }
            catch ApplicationUpdateCoordinatorError.pendingInstallation {}
        }
        _ = try await restarted.start(applications: [c])
        try await waitUntil(restarted) { $0.tasks.contains { $0.applicationID == c.id && $0.state == .completed } }
        let final = try await repository.load()
        XCTAssertEqual(final?.tasks.first { $0.applicationID == a.id }?.state, .needsReconciliation)
        XCTAssertNotNil(final?.tasks.first { $0.applicationID == a.id }?.recoveryEvidence)
        let batches = await executor.executed
        XCTAssertEqual(batches, [["A", "B"], ["B"], ["C"]])
    }

    func testFreshCoordinatorWithoutRestoreCannotOverwritePersistedPendingIntent() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let repository = ApplicationUpdateQueueRepository(fileURL: root.appendingPathComponent("queue.json"))
        let a = formula("A"), c = formula("C")
        let session = UUID()
        var task = ApplicationUpdateTask(sessionID: session, application: a, state: .installing)
        task.recoveryEvidence = .init(applicationPath: a.path, homebrewMetadata: a.homebrewMetadata, artifacts: [])
        try await repository.save(.init(schemaVersion: ApplicationUpdateQueueRepository.currentSchemaVersion, plan: ApplicationUpdatePlanBuilder().build(applications: [a], id: session), tasks: [task], isPaused: false, updatedAt: Date()))
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: Repair3MixedExecutor())
        let alias = rescanned(a, id: "different-row")
        do { _ = try await coordinator.start(applications: [alias]); XCTFail("An interrupted install must be loaded before accepting a rescan") }
        catch ApplicationUpdateCoordinatorError.pendingInstallation {}
        _ = try await coordinator.start(applications: [c])
        try await waitUntil(coordinator) { $0.tasks.contains { $0.applicationID == c.id && $0.state == .completed } }
        let loaded = try await repository.load()
        XCTAssertEqual(loaded?.tasks.first { $0.applicationID == a.id }?.state, .needsReconciliation)
    }

    func testLateCancellationReplyWithoutStopReceiptCannotClearCoordinatorPendingIntent() async throws {
        try await lateCancellation(confirmed: false, expected: .needsReconciliation)
    }
    func testLateCancellationReplyWithTrustedStopReceiptCanClearCoordinatorPendingIntent() async throws {
        try await lateCancellation(confirmed: true, expected: .cancelled)
    }

    func testRecoveryEvidenceIsPersistedBeforeMergedInstallationBegins() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let repository = ApplicationUpdateQueueRepository(fileURL: root.appendingPathComponent("queue.json"))
        let executor = Repair3MixedExecutor(repository: repository)
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor)
        _ = try await coordinator.start(applications: [formula("C"), formula("D")])
        try await waitUntil(coordinator) { $0.tasks.allSatisfy { $0.state == .completed } }
        let persistedBeforeExecution = await executor.persistedBeforeExecution
        XCTAssertTrue(persistedBeforeExecution)
    }

    func testCaptureTrustsAdminWritableAncestorsInBothBinAndResolvedCellarButRejectsOtherWrites() throws {
        let root = try TestFileSystem.makeHome(for: self)
        let bin = root.appendingPathComponent("prefix/bin")
        let cellar = root.appendingPathComponent("Cellar/tool/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cellar, withIntermediateDirectories: true)
        let source = cellar.appendingPathComponent("brew")
        try Data("fixture only; never executed".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let link = bin.appendingPathComponent("brew")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let fixtureRoot = root.resolvingSymlinksInPath().path
        for boundary in ["admin", "other-group", "world"] {
            var visited = Set<String>()
            func attributes(_ url: URL) throws -> [FileAttributeKey: Any] {
                visited.insert(url.resolvingSymlinksInPath().path)
                var attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if url.resolvingSymlinksInPath().path.hasPrefix(fixtureRoot + "/") {
                    attributes[.ownerAccountID] = NSNumber(value: getuid())
                    attributes[.groupOwnerAccountID] = NSNumber(value: boundary == "other-group" ? 20 : 80)
                    attributes[.posixPermissions] = NSNumber(value: boundary == "world" ? 0o777 : 0o775)
                }
                return attributes
            }
            if boundary == "admin" {
                let frozen = try AppUpdateExecutableIdentity.capture(link, directoryAttributes: attributes)
                XCTAssertEqual(frozen.resolvedURL, source.resolvingSymlinksInPath())
                XCTAssertTrue(visited.contains(bin.resolvingSymlinksInPath().path))
                XCTAssertTrue(visited.contains(cellar.resolvingSymlinksInPath().path))
            } else { XCTAssertThrowsError(try AppUpdateExecutableIdentity.capture(link, directoryAttributes: attributes), boundary) }
        }
    }

    func testMasNormalExitReceiptVerifiesVersionAndReopensButCancelledForkRemainsPending() async throws {
        for cancelled in [false, true] {
            let root = try TestFileSystem.makeHome(for: self)
            let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
            let inspector = AppUpdateCountingSignatureInspector()
            let reader = ApplicationMetadataReader(signatureInspector: inspector)
            let read = await reader.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
            var app = try XCTUnwrap(read)
            app.updateProvider = .macAppStore; app.primaryUpdateProvider = .macAppStore
            app.updateStatus = .automaticallyUpdatable; app.updateCapability = .automatic
            app.canAutomaticallyUpdate = true; app.requiresUserInteraction = false; app.availableVersion = .init(marketing: "2.0")
            app.sourceResolutionState = .resolved; app.versionCheckState = .updateAvailable
            let state = Repair3PackageState(apps: [app], running: [app.path])
            let provider = Repair3StoreProvider(url: url, cancelled: cancelled)
            let executor = ProviderBackedApplicationUpdateExecutor(runtime: runtime(state), processSafety: .init(processTable: { [] }), batchAuthorization: Repair3NoAuthorization(),
                providerRegistry: .init(providers: [provider]), metadataReader: reader, heavyWorkCoordinator: HeavyWorkCoordinator(),
                runningStateProvider: { AppUpdatePerformanceTestSupport.idle }, availableDiskCapacity: { _ in Int64.max })
            let result = try await executor.execute(application: app, task: .init(sessionID: UUID(), application: app), progress: { _ in })
            XCTAssertEqual(result.state, cancelled ? .needsReconciliation : .completed)
            XCTAssertEqual(result.recoveryEvidence?.pendingReopenPaths.isEmpty, !cancelled)
            let events = await state.events
            XCTAssertEqual(events.contains("reopen:Example.app"), !cancelled)
            if cancelled {
                var intent = ApplicationUpdateTask(sessionID: UUID(), application: app, state: .needsReconciliation)
                intent.recoveryEvidence = result.recoveryEvidence
                let restored = try JSONDecoder().decode(ApplicationUpdateTask.self, from: JSONEncoder().encode(intent))
                let recovered = try await executor.reconcile(task: restored, application: nil)
                XCTAssertEqual(recovered.state, .completed)
                XCTAssertTrue(recovered.recoveryEvidence?.pendingReopenPaths.isEmpty == true)
                let finalEvents = await state.events
                XCTAssertEqual(finalEvents.filter { $0 == "reopen:Example.app" }.count, 1)
            }
        }
    }

    func testMasKnownLiveDescendantOldVersionKeepsRecoveryPending() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let reader = ApplicationMetadataReader(signatureInspector: AppUpdateCountingSignatureInspector())
        let read = await reader.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        var app = try XCTUnwrap(read)
        app.updateProvider = .macAppStore; app.primaryUpdateProvider = .macAppStore
        app.updateStatus = .automaticallyUpdatable; app.updateCapability = .automatic
        app.canAutomaticallyUpdate = true; app.requiresUserInteraction = false; app.availableVersion = .init(marketing: "2.0")
        app.sourceResolutionState = .resolved; app.versionCheckState = .updateAvailable
        let state = Repair3PackageState(apps: [app], running: [app.path])
        let provider = Repair3StoreProvider(url: url, cancelled: false, installedVersion: "1.0")
        let executor = ProviderBackedApplicationUpdateExecutor(runtime: runtime(state), processSafety: .init(processTable: { [] }), batchAuthorization: Repair3NoAuthorization(),
            providerRegistry: .init(providers: [provider]), metadataReader: reader, heavyWorkCoordinator: HeavyWorkCoordinator(),
            runningStateProvider: { AppUpdatePerformanceTestSupport.idle }, availableDiskCapacity: { _ in Int64.max })
        let result = try await executor.execute(application: app, task: .init(sessionID: UUID(), application: app), progress: { _ in })
        XCTAssertEqual(result.state, .needsReconciliation)
        XCTAssertEqual(result.recoveryEvidence?.pendingReopenPaths, [app.path])
    }

    private func lateCancellation(confirmed: Bool, expected: ApplicationUpdateTaskState) async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let executor = Repair3LateCancellationExecutor(confirmed: confirmed)
        let coordinator = ApplicationUpdateCoordinator(repository: ApplicationUpdateQueueRepository(fileURL: root.appendingPathComponent("queue.json")), executor: executor)
        let app = formula("late")
        _ = try await coordinator.start(applications: [app])
        try await waitUntil(coordinator) { $0.tasks.first?.state == .installing }
        try await coordinator.cancel()
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot?.tasks.first?.state, expected)
        if !confirmed {
            do { try await coordinator.retry(applicationID: app.id); XCTFail("Late cancelled reply must not authorize retry") }
            catch ApplicationUpdateCoordinatorError.taskCannotBeRetried {}
        }
    }

    private func waitUntil(_ coordinator: ApplicationUpdateCoordinator, _ condition: (ApplicationUpdateQueueSnapshot) -> Bool) async throws {
        for _ in 0..<400 {
            if let snapshot = await coordinator.currentSnapshot(), condition(snapshot) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Coordinator did not reach the required state")
    }
    private func suite() -> [InstalledApplication] {
        ["A", "B"].map { name in
            AppUpdateTestFixtures.application(id: name, bundleIdentifier: "com.example." + name, path: "/fixture/" + name + ".app", version: "1.0", build: "",
                availableVersion: "2.0", provider: .homebrew, status: .automaticallyUpdatable, sourceEvidence: ["homebrew-cli-json-v2"],
                homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(token: "suite", appBundlePaths: ["/fixture/A.app", "/fixture/B.app"]), canAutomaticallyUpdate: true, requiresUserInteraction: false)
        }
    }
    private func formula(_ token: String) -> InstalledApplication {
        var app = AppUpdateTestFixtures.application(id: token, path: "/fixture/" + token, version: "1.0", build: "", availableVersion: "2.0", provider: .homebrew,
            status: .automaticallyUpdatable, sourceEvidence: ["homebrew-cli-json-v2"], homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(token: token.lowercased(), kind: .formula, appBundlePaths: []),
            canAutomaticallyUpdate: true, requiresUserInteraction: false)
        app.packageKind = .commandLineTool
        return app
    }
    private func rescanned(_ application: InstalledApplication, id: String) -> InstalledApplication {
        var app = formula(id)
        app.bundleURL = application.bundleURL
        app.homebrewMetadata = application.homebrewMetadata
        return app
    }
    private func installer(_ state: Repair3PackageState, mode: Repair3CommandMode) -> HomebrewBatchInstaller {
        .init(executable: { URL(fileURLWithPath: "/fixture/bin/brew") }, command: Repair3BrewRunner(state: state, mode: mode),
            rechecker: AppUpdateFreshTestRechecker { try await state.snapshot($0) }, runtime: runtime(state), environment: { [:] }, captureExecutable: appUpdateFixtureExecutable)
    }
    private func runtime(_ state: Repair3PackageState) -> ApplicationUpdateBatchRuntime {
        .init(isRunning: { await state.running.contains($0.path) }, requestQuit: { await state.quit($0) }, reopen: { await state.reopen($0) }, wait: {}, quitTimeout: .milliseconds(50))
    }
}

private final class Repair3LiveDescendantObserver: AppUpdateCommandTreeObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [Int32]()
    private var checks = 0
    var signals: [Int32] { lock.withLock { recorded } }
    var waitChecks: Int { lock.withLock { checks } }
    func observeRunning() {}
    func confirmedStopped() -> Bool { false }
    func observedProcessesStopped() -> Bool { lock.withLock { checks += 1; return checks > 3 } }
    func signal(_ signal: Int32) { lock.withLock { recorded.append(signal) } }
}

private enum Repair3CommandMode: Sendable { case nativeFork, nativeCancelledFork, normalLiveDescendant, normalLiveOldVersion, normalOldVersion, normalChangedTeam, normalUnreadable, injectedPending }
private actor Repair3PackageState {
    let apps: [InstalledApplication]
    var running: Set<String>
    var versions: [String: String] = [:]
    var changedTeam = Set<String>()
    var changedBundle = Set<String>()
    var unreadable = false
    var events = [String]()
    var upgrades = 0
    init(apps: [InstalledApplication], running: Set<String>) { self.apps = apps; self.running = running }
    func quit(_ url: URL) -> Bool { events.append("quit:" + url.lastPathComponent); running.remove(url.path); return true }
    func reopen(_ url: URL) { events.append("reopen:" + url.lastPathComponent); running.insert(url.path) }
    func changeTeam(at path: String) { changedTeam.insert(path) }
    func changeBundle(at path: String) { changedBundle.insert(path) }
    func setVersions(_ values: [String: String]) { versions.merge(values) { _, new in new } }
    func upgraded(_ mode: Repair3CommandMode) {
        upgrades += 1; events.append("upgrade")
        if mode != .normalOldVersion && mode != .normalLiveOldVersion { for app in apps { versions[app.path] = "2.0" } }
        if mode == .normalChangedTeam { changedTeam.insert(apps.last!.path) }
        if mode == .normalUnreadable { unreadable = true }
    }
    func list() throws -> Data {
        if unreadable { throw POSIXError(.EIO) }
        return Data(("suite " + (upgrades > 0 || versions.values.contains("2.0") ? "2.0" : "1.0") + "\n").utf8)
    }
    func snapshot(_ url: URL) throws -> InstalledApplicationRecheckSnapshot? {
        if unreadable { throw POSIXError(.EIO) }
        guard var app = apps.first(where: { $0.path == url.path }) else { return nil }
        if let version = versions[app.path] { app.installedVersion = .init(marketing: version) }
        if changedTeam.contains(app.path) { app.signingTeamIdentifier = "OTHER" }
        if changedBundle.contains(app.path) { app.bundleIdentifier = "com.example.substituted" }
        return .init(application: app, signature: AppUpdatePerformanceTestSupport.signature(for: app))
    }
}
private struct Repair3BrewRunner: HomebrewCommandRunning {
    let state: Repair3PackageState
    let mode: Repair3CommandMode
    func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Data {
        if arguments.first == "list" { return try await state.list() }
        XCTAssertEqual(executableURL.path, "/fixture/bin/brew")
        XCTAssertEqual(arguments, ["upgrade", "--cask", "suite"])
        // Only our short-lived sh/sleep child is launched. Never execute the
        // supplied brew/mas/sudo/installer URL, even on failed assertions.
        if mode == .nativeFork || mode == .nativeCancelledFork {
            let cancellation = HomebrewCommandCancellation()
            if mode == .nativeCancelledFork { DispatchQueue.global().asyncAfter(deadline: .now() + 0.06) { cancellation.cancel() } }
            do {
                _ = try AppUpdateCommandRunner(stopTimeout: 0.1).runSync(executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", mode == .nativeFork ? "/bin/sleep 0.06 & wait" : "/bin/sleep 1 & wait"], environment: [:], timeout: 2, cancelled: { cancellation.isCancelled })
            } catch { await state.upgraded(mode); throw error }
        }
        await state.upgraded(mode)
        if mode == .injectedPending { throw AppUpdateCommandError.needsReconciliation }
        if mode == .normalLiveDescendant || mode == .normalLiveOldVersion { throw AppUpdateCommandError.normalExitAwaitingVerification(0, "fixture child") }
        return Data()
    }
}

private actor Repair3MixedExecutor: ApplicationUpdateBatchExecuting {
    let repository: ApplicationUpdateQueueRepository?
    var executed = [[String]]()
    var attempts = [String: Int]()
    var persistedBeforeExecution = false
    init(repository: ApplicationUpdateQueueRepository? = nil) { self.repository = repository }
    func prepareRecoveryEvidence(application: InstalledApplication, task: ApplicationUpdateTask, relatedApplications: [InstalledApplication]) -> ApplicationUpdateRecoveryEvidence? {
        .init(applicationPath: application.path, homebrewMetadata: application.homebrewMetadata, artifacts: [])
    }
    func beginBatch(applications: [InstalledApplication], sessionID: UUID) async {}
    func endBatch(sessionID: UUID) async {}
    func executeHomebrewBatch(applications: [InstalledApplication], tasks: [ApplicationUpdateTask], progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void) async -> [ApplicationUpdateInstallResult] {
        executed.append(applications.map(\.id))
        if let repository {
            let disk = try? await repository.load()
            persistedBeforeExecution = tasks.allSatisfy { task in disk?.tasks.contains { $0.id == task.id && $0.state == .installing && $0.recoveryEvidence != nil } == true }
        }
        return applications.map { app in
            attempts[app.id, default: 0] += 1
            let state: ApplicationUpdateTaskState = app.id == "A" ? .needsReconciliation : (app.id == "B" && attempts[app.id] == 1 ? .failed : .completed)
            return .init(applicationID: app.id, state: state, observedVersion: state == .completed ? .init(marketing: "2.0") : nil, detail: "injected mixed state")
        }
    }
    func execute(application: InstalledApplication, task: ApplicationUpdateTask, progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void) async throws -> ApplicationUpdateInstallResult { throw ApplicationUpdateExecutionError.unsupportedProvider(task.providerIdentifier) }
    func cancel(applicationID: String) async {}
    func reconcile(task: ApplicationUpdateTask, application: InstalledApplication?) async throws -> ApplicationUpdateInstallResult { throw POSIXError(.EIO) }
}
private actor Repair3LateCancellationExecutor: ApplicationUpdateExecuting {
    let confirmed: Bool
    private var reply: CheckedContinuation<Void, Never>?
    private var wasCancelled = false
    init(confirmed: Bool) { self.confirmed = confirmed }
    func execute(application: InstalledApplication, task: ApplicationUpdateTask, progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void) async throws -> ApplicationUpdateInstallResult {
        await progress(.init(applicationID: application.id, state: .installing, fraction: nil, detail: "injected installer running"))
        if !wasCancelled { await withCheckedContinuation { reply = $0 } }
        return .init(applicationID: application.id, state: .cancelled, observedVersion: nil, detail: "late cancellation reply", confirmedStopped: confirmed)
    }
    func cancel(applicationID: String) { wasCancelled = true; reply?.resume(); reply = nil }
    func reconcile(task: ApplicationUpdateTask, application: InstalledApplication?) async throws -> ApplicationUpdateInstallResult { throw POSIXError(.EIO) }
}
private struct Repair3NoAuthorization: AppUpdateBatchAuthorizing {
    func prepare(applications: [InstalledApplication], sessionID: UUID) async throws {}
    func homebrewEnvironment() async throws -> [String: String] { [:] }
    func upgrade(productID: UInt64) async throws { XCTFail("No real mas or sudo permitted") }
    func replace(candidate: URL, application: InstalledApplication) async throws { XCTFail("No real application replacement permitted") }
    func finish() async {}
}
private struct Repair3StoreProvider: ApplicationUpdateProvider {
    let identifier = ApplicationUpdateProviderIdentifier.macAppStore
    let url: URL
    let cancelled: Bool
    var installedVersion = "2.0"
    func canHandle(_ application: InstalledApplication) async -> Bool { true }
    func inspect(_ application: InstalledApplication) async throws -> ApplicationUpdateSourceInfo { throw ApplicationScanningError.providerUnsupported("fixture inspect unused") }
    func checkForUpdate(_ application: InstalledApplication) async throws -> ApplicationUpdateCheckResult { throw ApplicationScanningError.providerUnsupported("fixture scan unused") }
    func prepareUpdate(_ application: InstalledApplication) async throws -> PreparedApplicationUpdate {
        .init(applicationID: application.id, providerIdentifier: identifier, originalIdentity: application.identity, originalVersion: application.installedVersion, targetVersion: .init(marketing: "2.0"), providerPayload: [:])
    }
    func install(_ preparedUpdate: PreparedApplicationUpdate, progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void) async throws -> ApplicationUpdateInstallResult {
        try AppUpdatePerformanceTestSupport.writeInfo(at: url, version: installedVersion)
        throw cancelled ? AppUpdateCommandError.needsReconciliation : AppUpdateCommandError.normalExit(0, "injected mas fork", .init(trackingComplete: false, knownProcessesAlive: true, processes: [.init(.init(pid: 900_001, startTime: 1))]))
    }
}
