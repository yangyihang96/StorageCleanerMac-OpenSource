import Darwin
import FileOperationShared
import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppUpdateRepair5Tests: XCTestCase {
    func testCompleteKernelArgvPreservesArgumentsAfterEightAndStopsBeforeEnvironment() throws {
        let arguments = ["ruby"] + (0..<12).map { "option\($0)" } + ["/opt/homebrew/Library/Homebrew/brew.rb", "upgrade", "a"]
        let bytes = kernelArguments(arguments, environment: ["SECRET=not-an-argument"])
        XCTAssertEqual(AppUpdateInstallationProcessSafety.parseCommandArguments(bytes, byteCount: bytes.count), arguments)
        let withEmpty = kernelArguments(["bash", "", "-c", "echo okay"])
        XCTAssertEqual(AppUpdateInstallationProcessSafety.parseCommandArguments(withEmpty, byteCount: withEmpty.count), ["bash", "", "-c", "echo okay"])
    }

    func testTruncatedArgvIsUnavailableAndCannotReleaseQuarantine() {
        let complete = kernelArguments(["ruby"] + (0..<12).map { "option\($0)" } + ["/opt/homebrew/Library/Homebrew/brew.rb"])
        let truncated = Array(complete.dropLast(12))
        XCTAssertNil(AppUpdateInstallationProcessSafety.parseCommandArguments(truncated, byteCount: truncated.count))
        XCTAssertNil(AppUpdateInstallationProcessSafety.parseCommandArguments(complete, byteCount: complete.count + 1))
        let safety = AppUpdateInstallationProcessSafety(processTable: {
            let arguments = AppUpdateInstallationProcessSafety.parseCommandArguments(truncated, byteCount: truncated.count)
            guard let executable = AppUpdateInstallationProcessSafety.releaseExecutable("/usr/bin/ruby", arguments: arguments) else { return nil }
            return [Self.process(1, path: executable)]
        })
        XCTAssertEqual(safety.releaseStatus(nil), .unavailable)
    }

    func testLongRubyArgvFindsBrewAfterNinthArgument() throws {
        let argv = ["/usr/bin/ruby"] + (0..<12).map { "option\($0)" } + ["/usr/local/Homebrew/Library/Homebrew/brew.rb", "upgrade", "a"]
        let bytes = kernelArguments(argv)
        let arguments = try XCTUnwrap(AppUpdateInstallationProcessSafety.parseCommandArguments(bytes, byteCount: bytes.count))
        let executable = try XCTUnwrap(AppUpdateInstallationProcessSafety.releaseExecutable("/usr/bin/ruby", arguments: arguments))
        XCTAssertEqual(AppUpdateInstallationProcessSafety(processTable: { [Self.process(1, path: executable)] }).releaseStatus(nil), .running)
    }

    func testShellCommandTextAndBrewScriptsInAnyArgumentRemainInstalling() throws {
        for shell in ["/bin/bash", "/bin/sh", "/bin/zsh", "/usr/bin/ruby"] {
            for text in ["echo ready; '/opt/homebrew/bin/brew' postinstall tool", "source /fixture/brew.sh; finish", "load '/fixture/brew.rb'"] {
                let executable = try XCTUnwrap(AppUpdateInstallationProcessSafety.releaseExecutable(shell,
                    arguments: [shell] + Array(repeating: "option", count: 12) + ["-c", text]))
                XCTAssertEqual(AppUpdateInstallationProcessSafety(processTable: { [Self.process(1, path: executable)] }).releaseStatus(nil), .running)
            }
            XCTAssertNil(AppUpdateInstallationProcessSafety.releaseExecutable(shell, arguments: nil))
        }
    }

    func testHomebrewOwnExecutablesBlockReleaseButFormulaKegsDoNot() {
        for prefix in AppUpdateInstallationProcessSafety.defaultHomebrewPrefixes {
            for executable in [prefix + "/bin/brew", prefix + "/Library/Homebrew/vendor/portable-ruby/current/bin/ruby"] {
                XCTAssertEqual(AppUpdateInstallationProcessSafety(processTable: { [Self.process(1, path: executable)] }).releaseStatus(nil), .running, executable)
            }
            // Formula kegs are user programs; they block only as installer descendants.
            let keg = prefix + "/Cellar/node/22.0.0/bin/node"
            XCTAssertEqual(AppUpdateInstallationProcessSafety(processTable: { [Self.process(1, path: keg)] }).releaseStatus(nil), .stopped, keg)
        }
        for intel in ["/usr/local/Homebrew/bin/brew", "/usr/local/Homebrew/Library/Homebrew/vendor/portable-ruby/3.4.5/bin/ruby"] {
            XCTAssertEqual(AppUpdateInstallationProcessSafety(processTable: { [Self.process(1, path: intel)] }).releaseStatus(nil), .running, intel)
        }
        // Binary casks run from Caskroom; cask scripts are covered as brew descendants.
        for cask in ["/opt/homebrew/Caskroom/claude-code/2.1.0/claude", "/opt/homebrew/Caskroom/miniforge/base/bin/python3.12"] {
            XCTAssertEqual(AppUpdateInstallationProcessSafety(processTable: { [Self.process(1, path: cask)] }).releaseStatus(nil), .stopped, cask)
        }
        XCTAssertEqual(AppUpdateInstallationProcessSafety(processTable: { [Self.process(1, path: "/opt/homebrewx/vendor/worker")] }).releaseStatus(nil), .stopped)
    }

    /// Review 6 P1: long-running Homebrew-installed programs (node CLIs, MCP
    /// servers, services) must not keep a finished update quarantined forever.
    func testResidentHomebrewInstalledProgramsDoNotBlockRelease() throws {
        let npx = try XCTUnwrap(AppUpdateInstallationProcessSafety.releaseExecutable("/bin/bash",
            arguments: ["bash", "-c", "exec /opt/homebrew/bin/npx -y some-mcp-server"]))
        let rails = try XCTUnwrap(AppUpdateInstallationProcessSafety.releaseExecutable("/opt/homebrew/Cellar/ruby/3.4.1/bin/ruby",
            arguments: ["ruby", "/Users/fixture/app/bin/rails", "server"]))
        let script = try XCTUnwrap(AppUpdateInstallationProcessSafety.releaseExecutable("/bin/zsh",
            arguments: ["zsh", "/Users/fixture/bin/homebrew.sh"]))
        let table = [Self.process(1, path: "/opt/homebrew/Cellar/node/22.0.0/bin/node"),
                     Self.process(2, parent: 1, path: "/opt/homebrew/Cellar/node/22.0.0/bin/node"),
                     Self.process(3, path: "/opt/homebrew/opt/postgresql@17/bin/postgres"),
                     Self.process(4, path: npx), Self.process(5, path: rails), Self.process(6, path: script)]
        XCTAssertEqual(AppUpdateInstallationProcessSafety(processTable: { table }).releaseStatus(nil), .stopped)
        // The same keg program still counts while it descends from brew.
        let underBrew = [Self.process(7, path: "/opt/homebrew/bin/brew"),
                         Self.process(8, parent: 7, path: "/opt/homebrew/Cellar/node/22.0.0/bin/node")]
        var evidence = AppUpdateCommandCompletionEvidence.stopped
        XCTAssertEqual(AppUpdateInstallationProcessSafety(processTable: { table + underBrew }).releaseStatus(&evidence), .running)
        XCTAssertTrue(evidence.processes.contains { $0.pid == 8 })
    }

    func testCustomBrewPrefixIsFrozenWithFormulaAndCaskAndUsedDuringRecovery() async throws {
        let installed = Data(#"{"formulae":[{"name":"a","installed":[{"version":"1.0"}],"versions":{"stable":"2.0"}}],"casks":[{"token":"fonts","installed":["1.0"],"version":"2.0","artifacts":[]}]}"#.utf8)
        let outdated = Data(#"{"formulae":[{"name":"a"}],"casks":[{"name":"fonts"}]}"#.utf8)
        let packages = try HomebrewInventoryParser.parse(installedData: installed, outdatedData: outdated,
            prefixURL: URL(fileURLWithPath: "/fixture/custom-brew"))
        XCTAssertEqual(packages.map(\.metadata.prefixPath), ["/fixture/custom-brew", "/fixture/custom-brew"])
        var app = AppUpdateTestFixtures.application(id: "a", path: "/fixture/a", version: "1.0", build: "", availableVersion: "2.0",
            provider: .homebrew, status: .automaticallyUpdatable, sourceEvidence: ["homebrew-cli-json-v2"], homebrewMetadata: packages[0].metadata,
            canAutomaticallyUpdate: true, requiresUserInteraction: false)
        app.packageKind = .commandLineTool
        var task = ApplicationUpdateTask(sessionID: UUID(), application: app, state: .needsReconciliation)
        task.recoveryEvidence = .init(applicationPath: app.path, homebrewMetadata: app.homebrewMetadata, artifacts: [], packageVersionsBefore: "1.0")
        let restored = try JSONDecoder().decode(ApplicationUpdateTask.self, from: JSONEncoder().encode(task))
        let executable = "/fixture/custom-brew/Library/Homebrew/vendor/bin/worker"
        let state = Repair5PackageState(apps: [app])
        let executor = executor(state, table: .init([[Self.process(1, path: executable)]]))
        let result = try await executor.verifyAndRelease(task: restored, application: app)
        XCTAssertEqual(result.state, .needsReconciliation)
        XCTAssertFalse(result.confirmedStopped)
        XCTAssertEqual(state.listCalls, 0)
        let prefix = try XCTUnwrap(restored.recoveryEvidence?.homebrewMetadata?.prefixPath)
        let interpreted = AppUpdateInstallationProcessSafety.releaseExecutable("/bin/bash", arguments: ["bash", "-c", executable], homebrewPrefixes: [prefix])
        XCTAssertEqual(interpreted, "brew")
    }

    func testGlobalInstallerDescendantsStayTrackedAfterClientExitAcrossGroups() {
        let p = Self.process(1, path: "/usr/sbin/installer"), q = Self.process(2, parent: 1), r = Self.process(3, parent: 2)
        let table = Repair5ProcessTable([[p, q, r], [q, r], [r], []])
        let safety = AppUpdateInstallationProcessSafety(processTable: { table.read() })
        var evidence = AppUpdateCommandCompletionEvidence.stopped
        XCTAssertEqual(safety.releaseStatus(&evidence), .running)
        XCTAssertEqual(Set(evidence.processes.map(\.pid)), [1, 2, 3])
        XCTAssertEqual(safety.releaseStatus(&evidence), .running)
        XCTAssertEqual(safety.releaseStatus(&evidence), .running)
        XCTAssertEqual(safety.releaseStatus(&evidence), .stopped)
    }

    func testResidentSystemInstallServicesDoNotPermanentlyBlockRelease() {
        let services = ["installd", "system_installd", "softwareupdated", "appinstalld"].enumerated().map {
            Self.process(Int32($0.offset + 1), path: "/usr/libexec/" + $0.element)
        }
        XCTAssertEqual(AppUpdateInstallationProcessSafety(processTable: { services }).releaseStatus(nil), .stopped)
    }

    func testWaitingExpandsPThenQAndCannotStopUntilQExits() async throws {
        let p = Self.process(900_001), q = Self.process(900_003, parent: p.identity.pid)
        let table = Repair5ProcessTable([[p], [p, q], [q], []])
        let safety = AppUpdateInstallationProcessSafety(processTable: { table.read() }, completionWaitTimeout: 0.2, pollInterval: 0.001)
        var evidence = Self.receipt
        let stopped = try await safety.waitForKnownProcesses(&evidence)
        XCTAssertTrue(stopped)
        XCTAssertEqual(table.reads, 4, "Q, observed while P was alive, still belongs to the command after P exits")
        XCTAssertEqual(Set(evidence.processes.map(\.identity)), [p.identity, q.identity])
        XCTAssertFalse(evidence.knownProcessesAlive)
    }

    func testReusedParentPIDCannotAdoptUnrelatedNewChild() async throws {
        let reused = Self.process(900_001, start: 99), unrelated = Self.process(900_003, parent: reused.identity.pid, start: 100)
        let safety = AppUpdateInstallationProcessSafety(processTable: { [reused, unrelated] }, completionWaitTimeout: 0.01)
        var evidence = Self.receipt
        let stopped = try await safety.waitForKnownProcesses(&evidence)
        XCTAssertTrue(stopped)
        XCTAssertEqual(evidence.processes, Self.receipt.processes)
    }

    func testVisibleZombieParentStillOwnsItsChildUntilPIDIdentityDisappears() async throws {
        // A zombie still has its original PID/start identity and cannot have
        // been reused. Its visible live child must survive the parent's exit.
        let p = UpdateProcessSnapshot(pid: 900_001, startTime: 1, parentPID: 0, groupPID: 900_001,
            uid: 501, executable: "/fixture/worker", zombie: true)
        let q = Self.process(900_003, parent: p.identity.pid)
        let safety = AppUpdateInstallationProcessSafety(processTable: { [p, q] }, completionWaitTimeout: 0)
        var evidence = Self.receipt
        let stopped = try await safety.waitForKnownProcesses(&evidence)
        XCTAssertFalse(stopped)
        XCTAssertEqual(Set(evidence.processes.map(\.identity)), [p.identity, q.identity])
        XCTAssertTrue(evidence.knownProcessesAlive)
    }

    func testHomebrewWaitsForNewQThenRereadsAllArtifactsBeforeReopening() async throws {
        let apps = suite(), state = Repair5PackageState(apps: suite())
        let table = descendantSequence()
        let results = await installer(state, table: table).install(applications: [apps[0]]) { _ in }
        XCTAssertEqual(results.first?.state, .completed)
        XCTAssertEqual(results.first?.installationIsolated, false)
        XCTAssertEqual(table.reads, 4)
        XCTAssertEqual(state.postUpgradeReads, 2)
        XCTAssertEqual(state.reopened, apps.map(\.path))
        XCTAssertEqual(Set(results.first?.recoveryEvidence?.commandCompletion?.processes.map(\.pid) ?? []), [900_001, 900_003])
    }

    func testHomebrewTargetRollbackWhileQIsStillAliveDoesNotCompleteOrReopen() async throws {
        try await assertHomebrewRollback(beforeExit: true)
    }
    func testHomebrewTargetRollbackAfterQExitsDoesNotCompleteOrReopen() async throws {
        try await assertHomebrewRollback(beforeExit: false)
    }

    func testTimeoutPersistsNewDescendantAcrossCoordinatorRestartAndRecovery() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let repository = ApplicationUpdateQueueRepository(fileURL: root.appendingPathComponent("queue.json"))
        let apps = suite(), state = Repair5PackageState(apps: suite())
        let p = Self.process(900_001), q = Self.process(900_003, parent: p.identity.pid)
        let table = Repair5ProcessTable([[p], [p, q], [q]])
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor(state, table: table, timeout: 0.02))
        _ = try await coordinator.start(applications: [apps[0]])
        for _ in 0..<200 {
            if await coordinator.currentSnapshot()?.tasks.first?.state == .completed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let saved = try await repository.load()
        let task = try XCTUnwrap(saved?.tasks.first)
        XCTAssertTrue(task.requiresInstallationReconciliation)
        XCTAssertEqual(Set(task.recoveryEvidence?.commandCompletion?.processes.map(\.pid) ?? []), [900_001, 900_003])
        XCTAssertEqual(task.recoveryEvidence?.pendingReopenPaths, apps.map(\.path))
        XCTAssertTrue(state.reopened.isEmpty)
        let restarted = ApplicationUpdateCoordinator(repository: repository, executor: executor(state, table: table))
        _ = try await restarted.restore(applications: apps, autoResume: false)
        await restarted.reconcilePendingTasks()
        let restored = await restarted.currentSnapshot()
        XCTAssertEqual(restored?.tasks.first?.state, .needsReconciliation)
        XCTAssertTrue(state.reopened.isEmpty, "Q must remain isolated after P and the old app session have exited")
        table.replace([[]])
        try await restarted.verifyAndRelease(applicationID: apps[0].id, applications: apps)
        let released = try await repository.load()
        XCTAssertEqual(released?.tasks.first?.state, .completed)
        XCTAssertFalse(released?.tasks.first?.requiresInstallationReconciliation ?? true)
        XCTAssertEqual(state.reopened, apps.map(\.path))
    }

    func testAutomaticRecoveryPersistsNewGlobalDescendantsEvenWhileStillPending() async throws {
        let root = try TestFileSystem.makeHome(for: self), app = suite()[0]
        var task = ApplicationUpdateTask(sessionID: UUID(), application: app, state: .needsReconciliation)
        task.recoveryEvidence = .init(applicationPath: app.path, homebrewMetadata: app.homebrewMetadata, artifacts: [], commandCompletion: Self.receipt)
        let repository = ApplicationUpdateQueueRepository(fileURL: root.appendingPathComponent("queue.json"))
        try await repository.save(.init(schemaVersion: 2, plan: ApplicationUpdatePlanBuilder().build(applications: [app], id: task.sessionID),
            tasks: [task], isPaused: true, updatedAt: Date()))
        let p = Self.process(900_001), q = Self.process(900_003, parent: p.identity.pid)
        let table = Repair5ProcessTable([[p, q]])
        let state = Repair5PackageState(apps: [app])
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor(state, table: table))
        _ = try await coordinator.restore(applications: [app], autoResume: false)
        await coordinator.reconcilePendingTasks()
        let pending = try await repository.load()
        XCTAssertEqual(pending?.tasks.first?.state, .needsReconciliation)
        XCTAssertEqual(Set(pending?.tasks.first?.recoveryEvidence?.commandCompletion?.processes.map(\.pid) ?? []), [900_001, 900_003])
        XCTAssertEqual(state.listCalls, 0)
    }

    func testLegacyIntentWithoutEvidencePersistsGlobalChildAcrossRestart() async throws {
        let root = try TestFileSystem.makeHome(for: self), app = suite()[0]
        let task = ApplicationUpdateTask(sessionID: UUID(), application: app, state: .needsReconciliation)
        let repository = ApplicationUpdateQueueRepository(fileURL: root.appendingPathComponent("queue.json"))
        try await repository.save(.init(schemaVersion: 2, plan: ApplicationUpdatePlanBuilder().build(applications: [app], id: task.sessionID),
            tasks: [task], isPaused: true, updatedAt: Date()))
        let p = Self.process(900_001, path: "/opt/homebrew/bin/brew"), q = Self.process(900_003, parent: p.identity.pid)
        let table = Repair5ProcessTable([[p, q]]), state = Repair5PackageState(apps: suite())
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor(state, table: table))
        _ = try await coordinator.restore(applications: [app], autoResume: false)
        await coordinator.reconcilePendingTasks()
        let saved = try await repository.load()
        let frozen = try XCTUnwrap(saved?.tasks.first?.recoveryEvidence)
        XCTAssertEqual(Set(frozen.commandCompletion?.processes.map(\.pid) ?? []), [900_001, 900_003])
        XCTAssertNil(frozen.homebrewMetadata, "Process evidence must not invent the legacy package scope")
        XCTAssertTrue(frozen.artifacts.isEmpty)
        var storeApplication = app
        storeApplication.updateProvider = .macAppStore
        var legacyStoreTask = ApplicationUpdateTask(sessionID: UUID(), application: storeApplication, state: .needsReconciliation)
        legacyStoreTask.recoveryEvidence = frozen
        let alias = AppUpdateTestFixtures.application(id: "legacy-alias", bundleIdentifier: app.bundleIdentifier, path: "/fixture/A-copy.app",
            signingTeamIdentifier: app.signingTeamIdentifier, codeSigningIdentifier: app.codeSigningIdentifier, provider: .macAppStore)
        XCTAssertTrue(legacyStoreTask.isolates(alias), "Process-only evidence cannot remove a legacy identity quarantine")
        table.replace([[q]])
        let restarted = ApplicationUpdateCoordinator(repository: repository, executor: executor(state, table: table))
        _ = try await restarted.restore(applications: [app], autoResume: false)
        try await restarted.verifyAndRelease(applicationID: app.id, applications: [app])
        let pending = try await repository.load()
        XCTAssertEqual(pending?.tasks.first?.state, .needsReconciliation)
        XCTAssertTrue(pending?.tasks.first?.isolates(suite()[1]) == true)
        XCTAssertEqual(state.listCalls, 0)
        XCTAssertTrue(state.upgradeCalls.isEmpty)
        XCTAssertTrue(state.reopened.isEmpty)
        table.replace([[]])
        try await restarted.verifyAndRelease(applicationID: app.id, applications: [app])
        let released = try await repository.load()
        XCTAssertEqual(released?.tasks.first?.state, .failed, "Stopped legacy GUI records still cannot prove their original whole-package target")
        XCTAssertFalse(released?.tasks.first?.requiresInstallationReconciliation ?? true)
    }

    func testMasWaitsForNewQThenCompletesAndReopens() async throws {
        let (app, url, reader) = try await masFixture()
        let state = Repair5PackageState(apps: [app]), table = descendantSequence()
        let executor = masExecutor(appURL: url, reader: reader, state: state, table: table)
        let result = try await executor.execute(application: app, task: .init(sessionID: UUID(), application: app), progress: { _ in })
        XCTAssertEqual(result.state, .completed)
        XCTAssertFalse(result.installationIsolated)
        XCTAssertEqual(table.reads, 4)
        XCTAssertEqual(state.reopened, [app.path])
        XCTAssertEqual(Set(result.recoveryEvidence?.commandCompletion?.processes.map(\.pid) ?? []), [900_001, 900_003])
    }

    func testMasTimeoutPersistsNewQWithoutReopening() async throws {
        let (app, url, reader) = try await masFixture()
        let state = Repair5PackageState(apps: [app])
        let p = Self.process(900_001), q = Self.process(900_003, parent: p.identity.pid)
        let table = Repair5ProcessTable([[p], [p, q], [q]])
        let result = try await masExecutor(appURL: url, reader: reader, state: state, table: table, timeout: 0.02)
            .execute(application: app, task: .init(sessionID: UUID(), application: app), progress: { _ in })
        XCTAssertEqual(result.state, .completed)
        XCTAssertTrue(result.installationIsolated)
        XCTAssertTrue(state.reopened.isEmpty)
        XCTAssertEqual(Set(result.recoveryEvidence?.commandCompletion?.processes.map(\.pid) ?? []), [900_001, 900_003])
        XCTAssertEqual(result.recoveryEvidence?.pendingReopenPaths, [app.path])
    }

    /// Review 6 P2: process-only evidence (empty path) saved for a legacy intent
    /// must not turn a verified MAS upgrade into a path-identity failure.
    func testLegacyMasIntentWithProcessOnlyEvidenceCompletesAfterVerifiedUpgrade() async throws {
        let (app, url, reader) = try await masFixture()
        var task = ApplicationUpdateTask(sessionID: UUID(), application: app, state: .needsReconciliation)
        task.recoveryEvidence = .init(applicationPath: "", homebrewMetadata: nil, artifacts: [],
            commandCompletion: .init(trackingComplete: false, knownProcessesAlive: false, processes: [.init(.init(pid: 900_001, startTime: 1))]))
        try AppUpdatePerformanceTestSupport.writeInfo(at: url, version: "2.0")
        let state = Repair5PackageState(apps: [app]), table = Repair5ProcessTable([[]])
        let result = try await masExecutor(appURL: url, reader: reader, state: state, table: table)
            .verifyAndRelease(task: task, application: app)
        XCTAssertEqual(result.state, .completed, result.detail)
    }

    func testMasRollbackBeforeOrAfterNewQExitNeverCompletes() async throws {
        for beforeExit in [true, false] {
            let (app, url, reader) = try await masFixture()
            let state = Repair5PackageState(apps: [app]), table = descendantSequence()
            table.onRead = { processes in
                if beforeExit ? processes?.count == 1 && processes?.first?.identity.pid == 900_003 : processes?.isEmpty == true {
                    do { try AppUpdatePerformanceTestSupport.writeInfo(at: url, version: "1.0") }
                    catch { XCTFail("Private rollback fixture: \(error)") }
                }
            }
            let result = try await masExecutor(appURL: url, reader: reader, state: state, table: table)
                .execute(application: app, task: .init(sessionID: UUID(), application: app), progress: { _ in })
            XCTAssertEqual(result.state, .needsReconciliation)
            XCTAssertTrue(result.detail.contains(ProviderBackedUpdateExecutorError.versionDidNotChange.localizedDescription))
            XCTAssertEqual(table.reads, 4)
            XCTAssertTrue(state.reopened.isEmpty)
        }
    }

    private func assertHomebrewRollback(beforeExit: Bool) async throws {
        let state = Repair5PackageState(apps: suite()), table = descendantSequence()
        table.onRead = { processes in
            if beforeExit ? processes?.count == 1 && processes?.first?.identity.pid == 900_003 : processes?.isEmpty == true { state.setVersion("1.0") }
        }
        let result = await installer(state, table: table).install(applications: [suite()[0]]) { _ in }
        XCTAssertEqual(result.first?.state, .needsReconciliation)
        XCTAssertEqual(table.reads, 4)
        XCTAssertEqual(state.postUpgradeReads, 2)
        XCTAssertEqual(state.upgradeCalls.count, 1)
        XCTAssertTrue(state.reopened.isEmpty)
    }
    private func kernelArguments(_ arguments: [String], environment: [String] = []) -> [UInt8] {
        var argc = Int32(arguments.count)
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/usr/bin/interpreter".utf8) + [0, 0, 0]
        for string in arguments + environment { bytes += Array(string.utf8) + [0] }
        return bytes
    }
    fileprivate static let receipt = AppUpdateCommandCompletionEvidence(trackingComplete: false, knownProcessesAlive: true,
        processes: [.init(.init(pid: 900_001, startTime: 1))])
    private static func process(_ pid: Int32, parent: Int32 = 0, start: UInt64 = 1, path: String = "/fixture/worker") -> UpdateProcessSnapshot {
        .init(pid: pid, startTime: start, parentPID: parent, groupPID: pid, uid: 501, executable: path)
    }
    private func descendantSequence() -> Repair5ProcessTable {
        let p = Self.process(900_001), q = Self.process(900_003, parent: p.identity.pid)
        return .init([[p], [p, q], [q], []])
    }
    private func suite() -> [InstalledApplication] {
        ["A", "B"].map { name in
            AppUpdateTestFixtures.application(id: name, bundleIdentifier: "com.example." + name, path: "/fixture/" + name + ".app", version: "1.0", build: "", availableVersion: "2.0",
                provider: .homebrew, status: .automaticallyUpdatable, sourceEvidence: ["homebrew-cli-json-v2"],
                homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(token: "suite", appBundlePaths: ["/fixture/A.app", "/fixture/B.app"]),
                canAutomaticallyUpdate: true, requiresUserInteraction: false)
        }
    }
    private func runtime(_ state: Repair5PackageState) -> ApplicationUpdateBatchRuntime {
        .init(isRunning: { state.isRunning($0) }, requestQuit: { state.quit($0) }, reopen: { state.reopen($0) }, wait: {}, quitTimeout: .milliseconds(10))
    }
    private func installer(_ state: Repair5PackageState, table: Repair5ProcessTable, timeout: TimeInterval = 0.2) -> HomebrewBatchInstaller {
        .init(executable: { URL(fileURLWithPath: "/fixture/bin/brew") }, command: state, rechecker: AppUpdateFreshTestRechecker { state.snapshot($0) }, runtime: runtime(state),
            processSafety: .init(processTable: { table.read() }, completionWaitTimeout: timeout, pollInterval: 0.001),
            environment: { [:] }, captureExecutable: appUpdateFixtureExecutable)
    }
    private func executor(_ state: Repair5PackageState, table: Repair5ProcessTable, timeout: TimeInterval = 0.2) -> ProviderBackedApplicationUpdateExecutor {
        .init(runtime: runtime(state), processSafety: .init(processTable: { table.read() }, completionWaitTimeout: timeout, pollInterval: 0.001),
            batchAuthorization: Repair5NoAuthorization(), brewBatchInstaller: installer(state, table: table, timeout: timeout),
            heavyWorkCoordinator: HeavyWorkCoordinator(), availableDiskCapacity: { _ in Int64.max })
    }
    private func masFixture() async throws -> (InstalledApplication, URL, ApplicationMetadataReader) {
        let root = try TestFileSystem.makeHome(for: self), url = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let reader = ApplicationMetadataReader(signatureInspector: AppUpdateCountingSignatureInspector())
        let disk = await reader.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        var app = try XCTUnwrap(disk)
        app.updateProvider = .macAppStore; app.primaryUpdateProvider = .macAppStore
        app.updateStatus = .automaticallyUpdatable; app.updateCapability = .automatic
        app.canAutomaticallyUpdate = true; app.requiresUserInteraction = false; app.availableVersion = .init(marketing: "2.0")
        app.sourceResolutionState = .resolved; app.versionCheckState = .updateAvailable
        return (app, url, reader)
    }
    private func masExecutor(appURL: URL, reader: ApplicationMetadataReader, state: Repair5PackageState, table: Repair5ProcessTable,
        timeout: TimeInterval = 0.2) -> ProviderBackedApplicationUpdateExecutor {
        .init(runtime: runtime(state), processSafety: .init(processTable: { table.read() }, completionWaitTimeout: timeout, pollInterval: 0.001),
            batchAuthorization: Repair5NoAuthorization(), providerRegistry: .init(providers: [Repair5MasProvider(url: appURL)]), metadataReader: reader,
            heavyWorkCoordinator: HeavyWorkCoordinator(), runningStateProvider: { AppUpdatePerformanceTestSupport.idle }, availableDiskCapacity: { _ in Int64.max })
    }
}

private final class Repair5ProcessTable: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: [[UpdateProcessSnapshot]?]
    private var count = 0
    var onRead: @Sendable ([UpdateProcessSnapshot]?) -> Void = { _ in }
    init(_ sequence: [[UpdateProcessSnapshot]?]) { self.sequence = sequence }
    var reads: Int { lock.withLock { count } }
    func replace(_ sequence: [[UpdateProcessSnapshot]?]) { lock.withLock { self.sequence = sequence; count = 0 } }
    func read() -> [UpdateProcessSnapshot]? {
        let value = lock.withLock { let value = sequence[min(count, sequence.count - 1)]; count += 1; return value }
        onRead(value)
        return value
    }
}

private final class Repair5PackageState: HomebrewCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let apps: [InstalledApplication]
    private var version = "1.0"
    private var running: Set<String>
    private var opens = [String]()
    private var upgrades = [[String]]()
    private var postReads = 0
    private var lists = 0
    init(apps: [InstalledApplication]) { self.apps = apps; running = Set(apps.map(\.path)) }
    var reopened: [String] { lock.withLock { opens } }
    var postUpgradeReads: Int { lock.withLock { postReads } }
    var listCalls: Int { lock.withLock { lists } }
    var upgradeCalls: [[String]] { lock.withLock { upgrades } }
    func setVersion(_ version: String) { lock.withLock { self.version = version } }
    func isRunning(_ url: URL) -> Bool { lock.withLock { running.contains(url.path) } }
    func quit(_ url: URL) -> Bool { lock.withLock { _ = running.remove(url.path) }; return true }
    func reopen(_ url: URL) { lock.withLock { opens.append(url.path); running.insert(url.path) } }
    func snapshot(_ url: URL) -> InstalledApplicationRecheckSnapshot? {
        lock.withLock {
            guard var app = apps.first(where: { $0.path == url.path }) else { return nil }
            app.installedVersion = .init(marketing: version)
            return .init(application: app, signature: AppUpdatePerformanceTestSupport.signature(for: app))
        }
    }
    func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Data {
        XCTAssertEqual(executableURL.path, "/fixture/bin/brew")
        if arguments.first == "list" {
            return lock.withLock {
                lists += 1
                if !upgrades.isEmpty { postReads += 1 }
                return Data((arguments.last! + " " + version + "\n").utf8)
            }
        }
        XCTAssertEqual(arguments.first, "upgrade")
        lock.withLock { upgrades.append(arguments); version = "2.0" }
        throw AppUpdateCommandError.normalExit(0, "injected brew receipt", AppUpdateRepair5Tests.receipt)
    }
}

private struct Repair5NoAuthorization: AppUpdateBatchAuthorizing {
    func prepare(applications: [InstalledApplication], sessionID: UUID) async throws {}
    func upgrade(productID: UInt64) async throws { XCTFail("No real mas or sudo") }
    func replace(candidate: URL, application: InstalledApplication) async throws { XCTFail("No real replacement") }
    func finish() async {}
}
private struct Repair5MasProvider: ApplicationUpdateProvider {
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
        throw AppUpdateCommandError.normalExit(0, "injected mas receipt", AppUpdateRepair5Tests.receipt)
    }
}
