import Darwin
import FileOperationShared
import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppUpdateRepair4Tests: XCTestCase {
    func testGlobalReleaseDetectsBrewShellAndRubyWrappersAndRejectsUnreadableArguments() {
        for arguments in [["/bin/bash", "/opt/homebrew/bin/brew", "upgrade", "a"],
                          ["/usr/bin/ruby", "/usr/local/Homebrew/Library/Homebrew/brew.rb", "upgrade", "a"]] {
            let executable = AppUpdateInstallationProcessSafety.releaseExecutable(arguments[0], arguments: arguments)
            XCTAssertNotNil(executable)
            let process = child(path: executable ?? "/fixture/unrelated", pid: 900_003)
            XCTAssertEqual(AppUpdateInstallationProcessSafety(processTable: { [process] }).releaseStatus(nil), .running)
        }
        XCTAssertNil(AppUpdateInstallationProcessSafety.releaseExecutable("/bin/bash", arguments: nil))
        XCTAssertEqual(AppUpdateInstallationProcessSafety.releaseExecutable("/bin/bash", arguments: ["bash", "/fixture/unrelated.sh"]), "/bin/bash")
    }
    func testNativeForkReceiptKeepsLostTrackingAfterObservedChildrenExit() throws {
        do {
            _ = try AppUpdateCommandRunner(stopTimeout: 0.1).runSync(executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "/bin/sleep 0.02 & wait"], environment: [:], timeout: 2,
                captureCompletionEvidence: true, cancelled: { false })
            XCTFail("The native normal exit must carry its receipt")
        } catch let AppUpdateCommandError.normalExit(code, _, evidence) {
            XCTAssertEqual(code, 0)
            XCTAssertFalse(evidence.trackingComplete, "NOTE_FORK's missing child identities cannot become a complete tracking receipt")
            XCTAssertFalse(evidence.knownProcessesAlive)
            XCTAssertFalse(evidence.permitsRetry)
        }
    }
    func testNormalReceiptRetainsIncompleteTrackingWithNoKnownLiveChildren() throws {
        let observer = Repair4IncompleteObserver()
        let runner = AppUpdateCommandRunner(stopTimeout: 0.01, processTree: { pid in observer.rootPID = pid; return observer })
        do {
            // Only our own short-lived shell/child, never the supplied brew URL.
            _ = try runner.runSync(executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "(/bin/sh -c '/bin/sleep 0.01' &); exit 1"], environment: [:], timeout: 2,
                captureCompletionEvidence: true, cancelled: { false })
            XCTFail("Normal update exit must carry its tracking evidence")
        } catch let AppUpdateCommandError.normalExit(code, _, evidence) {
            XCTAssertEqual(code, 1)
            XCTAssertFalse(evidence.trackingComplete)
            XCTAssertFalse(evidence.knownProcessesAlive)
            XCTAssertFalse(evidence.permitsRetry)
            XCTAssertFalse(evidence.processes.isEmpty)
            XCTAssertTrue(observer.signals.isEmpty)
        }
    }

    func testIncompleteTrackingOldReadbackNeverRetriesAnyMergedToken() async throws {
        let apps = [formula("a"), formula("b")]
        let state = Repair4PackageState(apps: apps, mode: .incompleteOld)
        let results = await installer(state).install(applications: apps) { _ in }
        XCTAssertEqual(results.map(\.state), [.needsReconciliation, .needsReconciliation])
        XCTAssertTrue(results.allSatisfy { $0.recoveryEvidence?.commandCompletion?.trackingComplete == false })
        let calls = await state.upgradeCalls
        XCTAssertEqual(calls, [["upgrade", "--formula", "a", "b"]], "An empty observed set cannot authorize a token retry after lost tracking")
    }

    func testIncompleteTrackingTargetAndNoLiveChildCompletesAndReopens() async throws {
        let apps = suite()
        let state = Repair4PackageState(apps: apps, mode: .incompleteTarget, running: Set(apps.map(\.path)))
        let result = await installer(state).install(applications: [apps[0]]) { _ in }
        XCTAssertEqual(result.first?.state, .completed)
        XCTAssertEqual(result.first?.installationIsolated, false)
        let reopened = await state.reopened
        XCTAssertEqual(reopened, apps.map(\.path), "Merely observing a fork must not suppress a verified normal completion")
    }

    func testLiveChildExitRequiresSecondWholePackageReadbackAndReopens() async throws {
        let apps = suite()
        let state = Repair4PackageState(apps: apps, mode: .liveTarget, running: Set(apps.map(\.path)))
        let table = Repair4ProcessTable(sequence: [[child()], []])
        let results = await installer(state, table: table).install(applications: [apps[0]]) { _ in }
        XCTAssertEqual(results.first?.state, .completed)
        XCTAssertEqual(results.first?.installationIsolated, false)
        let reads = await state.postUpgradeReads, reopened = await state.reopened
        XCTAssertEqual(reads, 2, "The target must still hold after the last known child exits")
        XCTAssertEqual(reopened, apps.map(\.path))
        XCTAssertGreaterThanOrEqual(table.reads, 2)
    }

    func testLiveChildRollbackAfterFirstTargetSnapshotDoesNotComplete() async throws {
        let apps = suite()
        let state = Repair4PackageState(apps: apps, mode: .liveRollback, running: Set(apps.map(\.path)))
        let table = Repair4ProcessTable(sequence: [[child()], []])
        let results = await installer(state, table: table).install(applications: [apps[0]]) { _ in }
        XCTAssertEqual(results.first?.state, .needsReconciliation)
        let reads = await state.postUpgradeReads, reopened = await state.reopened, calls = await state.upgradeCalls
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(reopened.isEmpty)
        XCTAssertEqual(calls.count, 1)
    }

    func testLiveChildTimeoutCompletesWithoutReopeningAndRetainsDurableIsolation() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let repository = ApplicationUpdateQueueRepository(fileURL: root.appendingPathComponent("queue.json"))
        let apps = suite()
        let state = Repair4PackageState(apps: apps, mode: .liveTarget, running: Set(apps.map(\.path)))
        let table = Repair4ProcessTable(sequence: [[child()]])
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor(state, table: table, timeout: 0))
        _ = try await coordinator.start(applications: [apps[0]])
        try await waitUntil(coordinator) { $0.tasks.first?.state == .completed }
        let saved = try await repository.load()
        let task = try XCTUnwrap(saved?.tasks.first)
        XCTAssertTrue(task.requiresInstallationReconciliation)
        XCTAssertEqual(task.recoveryEvidence?.pendingReopenPaths, apps.map(\.path))
        XCTAssertTrue(task.detail?.contains(L10n.text("安装程序仍在收尾", "the installer is still finishing")) == true)
        let reopened = await state.reopened
        XCTAssertTrue(reopened.isEmpty)
        let restarted = ApplicationUpdateCoordinator(repository: ApplicationUpdateQueueRepository(fileURL: root.appendingPathComponent("queue.json")), executor: Repair4CountingExecutor())
        _ = try await restarted.restore(applications: apps, autoResume: false)
        var alias = AppUpdateTestFixtures.application(id: "new-row-B", bundleIdentifier: apps[1].bundleIdentifier, path: apps[1].path,
            version: "1.0", build: "", availableVersion: "2.0", provider: .homebrew, status: .automaticallyUpdatable,
            sourceEvidence: ["homebrew-cli-json-v2"], homebrewMetadata: apps[1].homebrewMetadata, canAutomaticallyUpdate: true, requiresUserInteraction: false)
        alias.sourceResolutionState = apps[1].sourceResolutionState
        do { _ = try await restarted.start(applications: [alias]); XCTFail("Completed-but-finishing must remain isolated across restart") }
        catch { XCTAssertTrue(error is ApplicationUpdateCoordinatorError) }
        do { try await restarted.clearFinishedSession(); XCTFail("Clearing must not erase the finishing intent") }
        catch { XCTAssertTrue(error is ApplicationUpdateCoordinatorError) }
    }

    func testCompletedFinishingIntentSurvivesRetryOfAnotherItem() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let a = formula("a"), b = formula("b")
        var taskA = ApplicationUpdateTask(sessionID: UUID(), application: a, state: .completed)
        taskA.installationIsolated = true
        taskA.recoveryEvidence = .init(applicationPath: a.path, homebrewMetadata: a.homebrewMetadata, artifacts: [],
            commandCompletion: .init(trackingComplete: false, knownProcessesAlive: true, processes: [.init(child().identity)]))
        var taskB = ApplicationUpdateTask(sessionID: taskA.sessionID, application: b, state: .failed)
        taskB.detail = "injected failed B"
        let repository = ApplicationUpdateQueueRepository(fileURL: root.appendingPathComponent("queue.json"))
        try await save([taskA, taskB], apps: [a, b], to: repository)
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: Repair4CountingExecutor())
        _ = try await coordinator.restore(applications: [a, b], autoResume: false)
        try await coordinator.retry(applicationID: b.id)
        try await waitUntil(coordinator) { $0.tasks.first(where: { $0.applicationID == b.id })?.state == .completed }
        let after = await coordinator.currentSnapshot()
        XCTAssertTrue(after?.tasks.first(where: { $0.applicationID == a.id })?.requiresInstallationReconciliation == true)
        XCTAssertEqual(after?.plan.batchApplicationIDs, [b.id])
    }

    func testLegacyHomebrewIntentQuarantinesDifferentBundleAndFormulaButNotMas() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let a = suite()[0], b = suite()[1], tool = formula("unrelated-tool")
        let task = ApplicationUpdateTask(sessionID: UUID(), application: a, state: .needsReconciliation)
        let repository = ApplicationUpdateQueueRepository(fileURL: root.appendingPathComponent("queue.json"))
        try await save([task], apps: [a], to: repository)
        let fake = Repair4CountingExecutor()
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: fake)
        _ = try await coordinator.restore(applications: [a, b, tool], autoResume: false)
        for app in [b, tool] {
            XCTAssertNotEqual(app.identity, a.identity)
            do { _ = try await coordinator.start(applications: [app]); XCTFail("Legacy missing package scope quarantines every Homebrew item") }
            catch { XCTAssertTrue(error is ApplicationUpdateCoordinatorError) }
        }
        let mas = storeApp()
        let next = try await coordinator.start(applications: [mas])
        XCTAssertEqual(next.plan.batchApplicationIDs, [mas.id])
        try await waitUntil(coordinator) { $0.tasks.first(where: { $0.applicationID == mas.id })?.state == .completed }
        let calls = await fake.executed
        XCTAssertEqual(calls, [mas.id])
        let current = await coordinator.currentSnapshot()
        XCTAssertTrue(current?.tasks.contains(where: { $0.applicationID == a.id && $0.requiresInstallationReconciliation }) == true)
    }

    func testStoppedUnchangedInstallationExplicitlyReleasesThenRetryStartsNewBatch() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let app = formula("a")
        let state = Repair4PackageState(apps: [app], mode: .incompleteOld)
        let repository = ApplicationUpdateQueueRepository(fileURL: root.appendingPathComponent("queue.json"))
        var task = ApplicationUpdateTask(sessionID: UUID(), application: app, state: .needsReconciliation)
        task.recoveryEvidence = .init(applicationPath: app.path, homebrewMetadata: app.homebrewMetadata, artifacts: [],
            commandCompletion: .init(trackingComplete: false, knownProcessesAlive: true, processes: [.init(child().identity)]))
        try await save([task], apps: [app], to: repository)
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor(state))
        _ = try await coordinator.restore(applications: [app], autoResume: false)
        await coordinator.reconcilePendingTasks()
        let before = await coordinator.currentSnapshot()
        XCTAssertEqual(before?.tasks.first?.state, .needsReconciliation, "Automatic negative readback cannot release the old intent")
        try await coordinator.verifyAndRelease(applicationID: app.id, applications: [app])
        let released = await coordinator.currentSnapshot()
        XCTAssertEqual(released?.tasks.first?.state, .failed)
        XCTAssertFalse(released?.tasks.first?.requiresInstallationReconciliation ?? true)
        XCTAssertTrue(released?.tasks.first?.detail?.contains(L10n.text("已解除隔离", "quarantine released")) == true)
        let callsBeforeRetry = await state.upgradeCalls
        XCTAssertTrue(callsBeforeRetry.isEmpty, "Verify and Recover must not run an upgrade command")
        try await coordinator.retry(applicationID: app.id)
        try await waitUntil(coordinator) { $0.tasks.first?.state == .needsReconciliation }
        let retried = await coordinator.currentSnapshot(), calls = await state.upgradeCalls
        XCTAssertNotEqual(retried?.plan.id, task.sessionID)
        XCTAssertEqual(calls.count, 1)
    }

    func testLegacyFormulaUsesFrozenOriginalVersionDespiteFreshScan() async throws {
        let app = formula("a")
        let state = Repair4PackageState(apps: [app], mode: .incompleteOld, version: "2.0")
        let task = ApplicationUpdateTask(sessionID: UUID(), application: app, state: .needsReconciliation)
        var rescan = app
        rescan.installedVersion = .init(marketing: "2.0")
        rescan.homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(token: "a", kind: .formula, installedVersions: ["2.0"], appBundlePaths: [])
        let result = try await executor(state).verifyAndRelease(task: task, application: rescan)
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.observedVersion, .init(marketing: "2.0"))
        XCTAssertEqual(result.recoveryEvidence?.packageVersionsBefore, "1.0")
        let calls = await state.upgradeCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testKnownIdentityAndGlobalInstallersPreventExplicitRelease() async throws {
        let app = formula("a")
        let state = Repair4PackageState(apps: [app], mode: .incompleteOld)
        var task = ApplicationUpdateTask(sessionID: UUID(), application: app, state: .needsReconciliation)
        task.recoveryEvidence = .init(applicationPath: app.path, homebrewMetadata: app.homebrewMetadata, artifacts: [],
            commandCompletion: .init(trackingComplete: false, knownProcessesAlive: true, processes: [.init(child().identity)]))
        for path in ["/fixture/child", "/opt/homebrew/bin/brew", "/opt/homebrew/bin/mas", "/usr/sbin/installer", "/usr/sbin/softwareupdate", "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/bin/ruby"] {
            let process = path == "/fixture/child" ? child() : child(path: path, pid: 900_003)
            let result = try await executor(state, table: .init(sequence: [[process]])).verifyAndRelease(task: task, application: app)
            XCTAssertEqual(result.state, .needsReconciliation, path)
            XCTAssertFalse(result.confirmedStopped, path)
        }
        let unreadable = try await executor(state, table: .init(sequence: [nil])).verifyAndRelease(task: task, application: app)
        XCTAssertEqual(unreadable.state, .needsReconciliation)
        let reads = await state.listCalls, calls = await state.upgradeCalls
        XCTAssertEqual(reads, 0, "A live installer gate must run before readback or reopening")
        XCTAssertTrue(calls.isEmpty)
    }

    func testPIDReuseAndZombieDoNotBlockReadOnlyRelease() async throws {
        let app = formula("a")
        let state = Repair4PackageState(apps: [app], mode: .incompleteOld)
        var task = ApplicationUpdateTask(sessionID: UUID(), application: app, state: .needsReconciliation)
        task.recoveryEvidence = .init(applicationPath: app.path, homebrewMetadata: app.homebrewMetadata, artifacts: [],
            commandCompletion: .init(trackingComplete: false, knownProcessesAlive: true, processes: [.init(child().identity)]))
        let replacement = UpdateProcessSnapshot(pid: child().identity.pid, startTime: 999, parentPID: 1, groupPID: 1, uid: 501, executable: "/fixture/unrelated")
        let zombie = UpdateProcessSnapshot(pid: 900_004, startTime: 10, parentPID: 1, groupPID: 1, uid: 501, executable: "/usr/sbin/installer", zombie: true)
        let result = try await executor(state, table: .init(sequence: [[replacement, zombie]])).verifyAndRelease(task: task, application: app)
        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.confirmedStopped)
    }

    func testLegacyGUIWithoutEvidenceCanBeSafelyReleasedAfterStop() async throws {
        let app = suite()[0]
        let state = Repair4PackageState(apps: suite(), mode: .incompleteOld)
        let task = ApplicationUpdateTask(sessionID: UUID(), application: app, state: .needsReconciliation)
        let result = try await executor(state).verifyAndRelease(task: task, application: app)
        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.confirmedStopped)
        let calls = await state.upgradeCalls, reopened = await state.reopened
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(reopened.isEmpty)
    }

    func testCorruptQueueIsArchivedUnchangedAndRequiresConfirmationAcrossRestart() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = root.appendingPathComponent("queue.json")
        let original = Data([0x7b, 0x00, 0xff, 0x22, 0x42])
        try original.write(to: url)
        let fake = Repair4CountingExecutor()
        let first = ApplicationUpdateCoordinator(repository: ApplicationUpdateQueueRepository(fileURL: url), executor: fake)
        let status = await first.recoveryStatus()
        let issue = try XCTUnwrap(status.queueIssue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: issue.archivedPath))
        XCTAssertEqual(URL(fileURLWithPath: issue.archivedPath).deletingLastPathComponent(), url.deletingLastPathComponent())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: issue.archivedPath)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let restarted = ApplicationUpdateCoordinator(repository: ApplicationUpdateQueueRepository(fileURL: url), executor: fake)
        do { _ = try await restarted.start(applications: [formula("a")]); XCTFail("An archived unknown intent still blocks Homebrew before confirmation") }
        catch {
            guard case .queueRecoveryConfirmationRequired? = error as? ApplicationUpdateCoordinatorError else { return XCTFail("Expected the damaged-queue confirmation gate: \(error)") }
        }
        let callsBefore = await fake.executed
        XCTAssertTrue(callsBefore.isEmpty)
        try await restarted.acknowledgeDamagedQueue()
        let afterConfirmation = await restarted.recoveryStatus()
        XCTAssertNil(afterConfirmation.queueIssue)
        _ = try await restarted.start(applications: [formula("a")])
        try await waitUntil(restarted) { $0.tasks.first?.state == .completed }
        XCTAssertTrue(FileManager.default.fileExists(atPath: issue.archivedPath))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: issue.archivedPath)), original, "Confirmation must never remove or rewrite the archive")
    }

    func testUnsupportedSchemaArchiveDoesNotPreventMasAndConfirmationRetainsValidIntents() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = root.appendingPathComponent("queue.json")
        let app = formula("a"), mas = storeApp()
        let task = ApplicationUpdateTask(sessionID: UUID(), application: app, state: .queued)
        let invalid = ApplicationUpdateQueueSnapshot(schemaVersion: 999, plan: ApplicationUpdatePlanBuilder().build(applications: [app], id: task.sessionID), tasks: [task], isPaused: false, updatedAt: Date())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let original = try encoder.encode(invalid); try original.write(to: url)
        let repository = ApplicationUpdateQueueRepository(fileURL: url)
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: Repair4CountingExecutor())
        _ = try await coordinator.start(applications: [mas])
        try await waitUntil(coordinator) { $0.tasks.first?.state == .completed }
        let status = await coordinator.recoveryStatus(), issue = try XCTUnwrap(status.queueIssue)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: issue.archivedPath)), original)
        try await coordinator.acknowledgeDamagedQueue()
        let valid = try await repository.load()
        XCTAssertEqual(valid?.tasks.first?.applicationID, mas.id)
        XCTAssertEqual(valid?.tasks.first?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: issue.archivedPath)), original)
    }

    func testInstallerAppearingDuringReadbackPreventsReleaseAndReopen() async throws {
        let apps = suite()
        let state = Repair4PackageState(apps: apps, mode: .incompleteTarget, version: "2.0", running: [])
        var task = ApplicationUpdateTask(sessionID: UUID(), application: apps[0], state: .needsReconciliation)
        task.recoveryEvidence = .init(applicationPath: apps[0].path, homebrewMetadata: apps[0].homebrewMetadata,
            artifacts: apps.map { .init(path: $0.path, originalIdentity: $0.identity, originalVersion: $0.installedVersion, wasRunning: true) })
        let table = Repair4ProcessTable(sequence: [[], [], [child(path: "/usr/sbin/installer")]])
        let result = try await executor(state, table: table).verifyAndRelease(task: task, application: apps[0])
        XCTAssertEqual(result.state, .needsReconciliation)
        XCTAssertFalse(result.confirmedStopped)
        let reopened = await state.reopened
        XCTAssertTrue(reopened.isEmpty)
    }

    func testMasLiveChildTargetSnapshotDefersReopenAndRemainsIsolated() async throws {
        let (app, url, reader) = try await masFixture()
        let state = Repair4PackageState(apps: [app], mode: .liveTarget, running: [app.path])
        let table = Repair4ProcessTable(sequence: [[child()]])
        let safety = AppUpdateInstallationProcessSafety(processTable: { table.read() }, completionWaitTimeout: 0)
        let provider = Repair4MasProvider(url: url)
        let executor = ProviderBackedApplicationUpdateExecutor(runtime: runtime(state), processSafety: safety, batchAuthorization: Repair4NoAuthorization(),
            providerRegistry: .init(providers: [provider]), metadataReader: reader, heavyWorkCoordinator: HeavyWorkCoordinator(),
            runningStateProvider: { AppUpdatePerformanceTestSupport.idle }, availableDiskCapacity: { _ in Int64.max })
        let result = try await executor.execute(application: app, task: .init(sessionID: UUID(), application: app), progress: { _ in })
        XCTAssertEqual(result.state, .completed)
        XCTAssertTrue(result.installationIsolated)
        XCTAssertEqual(result.recoveryEvidence?.pendingReopenPaths, [app.path])
        let reopened = await state.reopened
        XCTAssertTrue(reopened.isEmpty)
        var task = ApplicationUpdateTask(sessionID: UUID(), application: app, state: .completed)
        task.installationIsolated = true; task.recoveryEvidence = result.recoveryEvidence
        let stillRunning = try await executor.verifyAndRelease(task: task, application: app)
        XCTAssertEqual(stillRunning.state, .needsReconciliation)
        XCTAssertFalse(stillRunning.confirmedStopped)
    }

    func testMasRollbackAfterKnownChildExitFailsSecondReadbackWithoutReopen() async throws {
        let (app, url, reader) = try await masFixture()
        let state = Repair4PackageState(apps: [app], mode: .liveRollback, running: [app.path])
        let table = Repair4ProcessTable(sequence: [[child()], []])
        let safety = AppUpdateInstallationProcessSafety(processTable: {
            let processes = table.read()
            if processes?.isEmpty == true {
                do { try AppUpdatePerformanceTestSupport.writeInfo(at: url, version: "1.0") }
                catch { XCTFail("The private rollback fixture could not be written: \(error)") }
            }
            return processes
        }, completionWaitTimeout: 0.05, pollInterval: 0.001)
        let provider = Repair4MasProvider(url: url)
        let executor = ProviderBackedApplicationUpdateExecutor(runtime: runtime(state), processSafety: safety, batchAuthorization: Repair4NoAuthorization(),
            providerRegistry: .init(providers: [provider]), metadataReader: reader, heavyWorkCoordinator: HeavyWorkCoordinator(),
            runningStateProvider: { AppUpdatePerformanceTestSupport.idle }, availableDiskCapacity: { _ in Int64.max })
        let result = try await executor.execute(application: app, task: .init(sessionID: UUID(), application: app), progress: { _ in })
        XCTAssertEqual(result.state, .needsReconciliation)
        XCTAssertTrue(result.detail.contains(ProviderBackedUpdateExecutorError.versionDidNotChange.localizedDescription))
        let reopened = await state.reopened
        XCTAssertTrue(reopened.isEmpty)
    }

    private func masFixture() async throws -> (InstalledApplication, URL, ApplicationMetadataReader) {
        let root = try TestFileSystem.makeHome(for: self)
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let reader = ApplicationMetadataReader(signatureInspector: AppUpdateCountingSignatureInspector())
        let disk = await reader.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        var app = try XCTUnwrap(disk)
        app.updateProvider = .macAppStore; app.primaryUpdateProvider = .macAppStore
        app.updateStatus = .automaticallyUpdatable; app.updateCapability = .automatic
        app.canAutomaticallyUpdate = true; app.requiresUserInteraction = false; app.availableVersion = .init(marketing: "2.0")
        app.sourceResolutionState = .resolved; app.versionCheckState = .updateAvailable
        return (app, url, reader)
    }

    private func suite() -> [InstalledApplication] {
        ["A", "B"].map { name in
            AppUpdateTestFixtures.application(id: name, bundleIdentifier: "com.example." + name, path: "/fixture/" + name + ".app", version: "1.0", build: "", availableVersion: "2.0",
                provider: .homebrew, status: .automaticallyUpdatable, sourceEvidence: ["homebrew-cli-json-v2"],
                homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(token: "suite", appBundlePaths: ["/fixture/A.app", "/fixture/B.app"]),
                canAutomaticallyUpdate: true, requiresUserInteraction: false)
        }
    }
    private func formula(_ token: String) -> InstalledApplication {
        var app = AppUpdateTestFixtures.application(id: token, bundleIdentifier: "tool." + token, path: "/fixture/" + token, version: "1.0", build: "", availableVersion: "2.0",
            provider: .homebrew, status: .automaticallyUpdatable, sourceEvidence: ["homebrew-cli-json-v2"],
            homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(token: token, kind: .formula, appBundlePaths: []), canAutomaticallyUpdate: true, requiresUserInteraction: false)
        app.packageKind = .commandLineTool
        return app
    }
    private func storeApp() -> InstalledApplication {
        var app = AppUpdateTestFixtures.application(id: "mas-item", path: "/fixture/Store.app", version: "1.0", build: "", availableVersion: "2.0", provider: .macAppStore,
            status: .automaticallyUpdatable, sourceEvidence: ["valid-code-signature"], canAutomaticallyUpdate: true, requiresUserInteraction: false)
        app.sourceResolutionState = .resolved; app.versionCheckState = .updateAvailable; app.updateCapability = .automatic
        return app
    }
    private func child(path: String = "/fixture/child", pid: Int32 = 900_001) -> UpdateProcessSnapshot {
        .init(pid: pid, startTime: 1, parentPID: 900_002, groupPID: pid, uid: 501, executable: path)
    }
    private func installer(_ state: Repair4PackageState, table: Repair4ProcessTable = .init(sequence: [[]]), timeout: TimeInterval = 0.05) -> HomebrewBatchInstaller {
        .init(executable: { URL(fileURLWithPath: "/fixture/bin/brew") }, command: state,
            rechecker: AppUpdateFreshTestRechecker { try await state.snapshot($0) }, runtime: runtime(state),
            processSafety: .init(processTable: { table.read() }, completionWaitTimeout: timeout, pollInterval: 0.001),
            environment: { [:] }, captureExecutable: appUpdateFixtureExecutable)
    }
    private func runtime(_ state: Repair4PackageState) -> ApplicationUpdateBatchRuntime {
        .init(isRunning: { await state.running.contains($0.path) }, requestQuit: { await state.quit($0) }, reopen: { await state.reopen($0) }, wait: {}, quitTimeout: .milliseconds(10))
    }
    private func executor(_ state: Repair4PackageState, table: Repair4ProcessTable = .init(sequence: [[]]), timeout: TimeInterval = 0.05) -> ProviderBackedApplicationUpdateExecutor {
        .init(runtime: runtime(state), processSafety: .init(processTable: { table.read() }, completionWaitTimeout: timeout, pollInterval: 0.001),
            batchAuthorization: Repair4NoAuthorization(), brewBatchInstaller: installer(state, table: table, timeout: timeout),
            heavyWorkCoordinator: HeavyWorkCoordinator(), availableDiskCapacity: { _ in Int64.max })
    }
    private func save(_ tasks: [ApplicationUpdateTask], apps: [InstalledApplication], to repository: ApplicationUpdateQueueRepository) async throws {
        let id = try XCTUnwrap(tasks.first?.sessionID)
        try await repository.save(.init(schemaVersion: 2, plan: ApplicationUpdatePlanBuilder().build(applications: apps, id: id), tasks: tasks, isPaused: true, updatedAt: Date()))
    }
    private func waitUntil(_ coordinator: ApplicationUpdateCoordinator, _ predicate: (ApplicationUpdateQueueSnapshot) -> Bool) async throws {
        for _ in 0..<400 {
            if let snapshot = await coordinator.currentSnapshot(), predicate(snapshot) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The injected coordinator did not reach its required state")
    }
}

private final class Repair4IncompleteObserver: AppUpdateCommandTreeObserving, @unchecked Sendable {
    var rootPID: Int32 = 0
    var signals: [Int32] = []
    func observeRunning() {}
    func confirmedStopped() -> Bool { false }
    func observedProcessesStopped() -> Bool { true }
    func signal(_ signal: Int32) { signals.append(signal) }
    func completionEvidence() -> AppUpdateCommandCompletionEvidence {
        .init(trackingComplete: false, knownProcessesAlive: false, processes: [.init(.init(pid: rootPID, startTime: 1))])
    }
}
private final class Repair4ProcessTable: @unchecked Sendable {
    private let lock = NSLock()
    private let sequence: [[UpdateProcessSnapshot]?]
    private var count = 0
    init(sequence: [[UpdateProcessSnapshot]?]) { self.sequence = sequence }
    var reads: Int { lock.withLock { count } }
    func read() -> [UpdateProcessSnapshot]? {
        lock.withLock { let result = sequence[min(count, sequence.count - 1)]; count += 1; return result }
    }
}
private enum Repair4CommandMode: Sendable { case incompleteOld, incompleteTarget, liveTarget, liveRollback }
private actor Repair4PackageState: HomebrewCommandRunning {
    let apps: [InstalledApplication]
    let mode: Repair4CommandMode
    var version: String
    var running: Set<String>
    var reopened: [String] = []
    var upgradeCalls: [[String]] = []
    var postUpgradeReads = 0
    var listCalls = 0
    init(apps: [InstalledApplication], mode: Repair4CommandMode, version: String = "1.0", running: Set<String> = []) {
        self.apps = apps; self.mode = mode; self.version = version; self.running = running
    }
    func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Data {
        XCTAssertEqual(executableURL.path, "/fixture/bin/brew")
        if arguments.first == "list" {
            listCalls += 1
            if !upgradeCalls.isEmpty { postUpgradeReads += 1 }
            if mode == .liveRollback && postUpgradeReads >= 2 { version = "1.0" }
            return Data((arguments.last! + " " + version + "\n").utf8)
        }
        XCTAssertEqual(arguments.first, "upgrade")
        upgradeCalls.append(arguments)
        if mode != .incompleteOld { version = "2.0" }
        let live = mode == .liveTarget || mode == .liveRollback
        throw AppUpdateCommandError.normalExit(mode == .incompleteOld ? 1 : 0, "injected update command", .init(trackingComplete: false,
            knownProcessesAlive: live, processes: [.init(.init(pid: 900_001, startTime: 1))]))
    }
    func snapshot(_ url: URL) throws -> InstalledApplicationRecheckSnapshot? {
        guard var app = apps.first(where: { $0.path == url.path }) else { return nil }
        app.installedVersion = .init(marketing: version)
        return .init(application: app, signature: AppUpdatePerformanceTestSupport.signature(for: app))
    }
    func quit(_ url: URL) -> Bool { running.remove(url.path); return true }
    func reopen(_ url: URL) { reopened.append(url.path); running.insert(url.path) }
}
private actor Repair4CountingExecutor: ApplicationUpdateExecuting {
    var executed: [String] = []
    func execute(application: InstalledApplication, task: ApplicationUpdateTask, progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void) async throws -> ApplicationUpdateInstallResult {
        executed.append(application.id)
        return .init(applicationID: application.id, state: .completed, observedVersion: .init(marketing: "2.0"), detail: "injected completed")
    }
    func cancel(applicationID: String) async {}
    func reconcile(task: ApplicationUpdateTask, application: InstalledApplication?) async throws -> ApplicationUpdateInstallResult { throw POSIXError(.EIO) }
}
private struct Repair4NoAuthorization: AppUpdateBatchAuthorizing {
    func prepare(applications: [InstalledApplication], sessionID: UUID) async throws {}
    func upgrade(productID: UInt64) async throws { XCTFail("No real mas or sudo is permitted") }
    func replace(candidate: URL, application: InstalledApplication) async throws { XCTFail("No real application replacement is permitted") }
    func finish() async {}
}

private struct Repair4MasProvider: ApplicationUpdateProvider {
    let identifier = ApplicationUpdateProviderIdentifier.macAppStore
    let url: URL
    func canHandle(_ application: InstalledApplication) async -> Bool { true }
    func inspect(_ application: InstalledApplication) async throws -> ApplicationUpdateSourceInfo { throw ApplicationScanningError.providerUnsupported("unused injected scan") }
    func checkForUpdate(_ application: InstalledApplication) async throws -> ApplicationUpdateCheckResult { throw ApplicationScanningError.providerUnsupported("unused injected scan") }
    func prepareUpdate(_ application: InstalledApplication) async throws -> PreparedApplicationUpdate {
        .init(applicationID: application.id, providerIdentifier: identifier, originalIdentity: application.identity, originalVersion: application.installedVersion,
            targetVersion: .init(marketing: "2.0"), providerPayload: [:])
    }
    func install(_ prepared: PreparedApplicationUpdate, progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void) async throws -> ApplicationUpdateInstallResult {
        try AppUpdatePerformanceTestSupport.writeInfo(at: url, version: "2.0")
        throw AppUpdateCommandError.normalExit(0, "injected mas receipt", .init(trackingComplete: false, knownProcessesAlive: true, processes: [.init(.init(pid: 900_001, startTime: 1))]))
    }
}
