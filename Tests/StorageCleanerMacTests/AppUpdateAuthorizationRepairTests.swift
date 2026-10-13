import FileOperationShared
import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppUpdateAuthorizationRepairTests: XCTestCase {
    func testMasExecutableIsFrozenBeforePromptAndChangedBytesRejectExecution() async throws {
        let probe = AuthorizationRepairProbe()
        let identity = Repair2IdentityProbe()
        let secret = UpdatePasswordBuffer(bytes: [65])
        let auth = AppUpdateBatchAuthorization(prompt: { commands, attempt in
            XCTAssertTrue(commands.contains(where: { $0.contains("/frozen/bin/mas upgrade 123") }))
            await probe.prompt(commands, attempt: attempt); return secret
        }, makeChannel: { _ in AuthorizationFakeChannel() }, command: AuthorizationFakeCommand(probe: probe),
            mas: { URL(fileURLWithPath: "/frozen/bin/mas") }, captureExecutable: { try identity.capture($0) },
            prepareReplacement: { _, _, _ in }, replaceApplication: { _, _, _ in }, finishReplacement: {})
        var app = AppUpdateTestFixtures.application(provider: .macAppStore, requiresAdministratorAuthorization: true)
        app.appStoreProductURL = URL(string: "https://apps.apple.com/app/id123")
        try await auth.prepare(applications: [app], sessionID: UUID())
        identity.change()
        do { try await auth.upgrade(productID: 123); XCTFail("Changed executable cannot inherit batch authorization") }
        catch AppUpdateAuthorizationError.sourceChanged {}
        let calls = await probe.calls
        XCTAssertFalse(calls.contains(where: { $0.arguments.contains("upgrade") }))
        await auth.finish()
    }
    func testBrewTimestampRevocationUsesAllParentCachesAfterCallAndAtBatchEnd() async throws {
        let probe = AuthorizationRepairProbe()
        let auth = AppUpdateBatchAuthorization(prompt: { _, _ in UpdatePasswordBuffer(bytes: [65]) }, makeChannel: { _ in AuthorizationFakeChannel() },
            command: AuthorizationFakeCommand(probe: probe), brew: { URL(fileURLWithPath: "/frozen/bin/brew") }, captureExecutable: appUpdateFixtureExecutable,
            prepareReplacement: { _, _, _ in }, replaceApplication: { _, _, _ in }, finishReplacement: {})
        let app = AppUpdateTestFixtures.strictHomebrewApplication(requiresAuthorization: true)
        try await auth.prepare(applications: [app], sessionID: UUID())
        try await auth.revokeHomebrewAuthorization()
        await auth.finish()
        let calls = await probe.calls
        XCTAssertEqual(calls.map(\.arguments), [["-A", "-k", "-v"], ["-k"], ["-K"], ["-K"], ["-k"]])
        XCTAssertTrue(calls.filter { $0.arguments == ["-K"] }.allSatisfy { $0.environment["SUDO_ASKPASS"] == nil })
    }
    func testSameBuildOldDigestCapabilityStillRequiresOneLifecycleRefresh() async throws {
        let probe = CapabilityRepairProbe()
        try await AppUpdateHelperCapabilityGate.ensure(build: "200", trusted: true, probe: {
            .init(version: await probe.refreshCount == 0 ? 1 : ApplicationReplacementCapabilities.currentVersion, build: "200")
        }, refresh: { await probe.refresh() })
        let refreshed = await probe.refreshCount
        XCTAssertEqual(refreshed, 1)
    }
    func testApprovedDigestPassesThroughBatchGateAndLegacyUnboundCallIsRejected() async throws {
        let calls = AuthorizationRepairProbe()
        let digest = String(repeating: "a", count: 64)
        let secret = UpdatePasswordBuffer(bytes: [65])
        let auth = AppUpdateBatchAuthorization(prompt: { _, _ in secret }, makeChannel: { _ in AuthorizationFakeChannel() },
            command: AuthorizationFakeCommand(probe: calls), brew: { URL(fileURLWithPath: "/fake/brew") }, captureExecutable: appUpdateFixtureExecutable, prepareReplacement: { _, _, _ in },
            replaceApplication: { candidate, _, approved in XCTAssertEqual(candidate.path, "/fake/candidate.app"); XCTAssertEqual(approved, digest) }, finishReplacement: {})
        let app = AppUpdateTestFixtures.application(id: "protected", path: "/Applications/Example.app", provider: .sparkle, requiresAdministratorAuthorization: true)
        try await auth.prepare(applications: [app], sessionID: UUID())
        try await auth.replace(candidate: URL(fileURLWithPath: "/fake/candidate.app"), application: app, authenticatedSHA256: digest)
        do { try await auth.replace(candidate: URL(fileURLWithPath: "/fake/candidate.app"), application: app); XCTFail("Unbound digest is forbidden") }
        catch AppUpdateAuthorizationError.unavailable {}
        await auth.finish()
        XCTAssertTrue(secret.isCleared)
        do { try await auth.replace(candidate: URL(fileURLWithPath: "/fake/candidate.app"), application: app, authenticatedSHA256: digest); XCTFail("Finished batch cannot replace") }
        catch AppUpdateAuthorizationError.declined {}
    }
    @MainActor
    func testHelperRefreshTimeoutCancelsPendingLifecycleWork() async throws {
        let probe = RepairRefreshCancellationProbe()
        do {
            try await AppUpdateProtectedApplicationAuthorization.boundedRefresh(timeout: 0.02) {
                do { try await Task.sleep(for: .seconds(30)); XCTFail("Timed-out refresh must not continue") }
                catch { await probe.cancelled() }
            }
            XCTFail("Refresh must fail within its bound")
        } catch AuthorizedMoveError.connectionLost {}
        for _ in 0..<100 {
            if await probe.wasCancelled { break }
            await Task.yield()
        }
        let stopped = await probe.wasCancelled
        XCTAssertTrue(stopped)
    }
    func testCoordinatorRetryStartsNewBatchAndRequestsPasswordAgain() async throws {
        let probe = AuthorizationRepairProbe()
        let credentials = [UpdatePasswordBuffer(bytes: [65]), UpdatePasswordBuffer(bytes: [66])]
        let promptIndex = RepairPromptCounter()
        let auth = AppUpdateBatchAuthorization(prompt: { commands, attempt in
            await probe.prompt(commands, attempt: attempt)
            return credentials[await promptIndex.next()]
        }, makeChannel: { _ in AuthorizationFakeChannel() }, command: AuthorizationFakeCommand(probe: probe),
            brew: { URL(fileURLWithPath: "/fake/brew") }, captureExecutable: appUpdateFixtureExecutable, prepareReplacement: { _, _, _ in }, replaceApplication: { _, _, _ in }, finishReplacement: {})
        let executor = RepairRetryBatchExecutor(authorization: auth)
        let coordinator = ApplicationUpdateCoordinator(repository: RepairRetryRepository(), executor: executor)
        let app = AppUpdateTestFixtures.strictHomebrewApplication(id: "retry-auth", requiresAuthorization: true)
        let started = try await coordinator.start(applications: [app])
        for _ in 0..<200 {
            if await coordinator.currentSnapshot()?.tasks.first?.state == .failed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await coordinator.retry(applicationID: app.id)
        for _ in 0..<200 {
            if await coordinator.currentSnapshot()?.tasks.first?.state == .completed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let snapshot = await coordinator.currentSnapshot()
        let finished = try XCTUnwrap(snapshot)
        XCTAssertEqual(finished.tasks.first?.state, .completed)
        XCTAssertNotEqual(finished.plan.id, started.plan.id)
        let prompts = await probe.prompts
        let batches = await executor.batches
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(Set(batches).count, 2)
        XCTAssertTrue(credentials.allSatisfy(\.isCleared))
    }
    func testCommandErrorCannotExposeBatchPasswordOrAccountInResult() async throws {
        let probe = AuthorizationRepairProbe()
        let secret = UpdatePasswordBuffer(bytes: Array("unique-password-fixture".utf8))
        let auth = AppUpdateBatchAuthorization(prompt: { _, _ in secret }, makeChannel: { _ in AuthorizationFakeChannel() },
            command: AuthorizationFakeCommand(probe: probe), mas: { URL(fileURLWithPath: "/fake/mas") },
            brew: { URL(fileURLWithPath: "/fake/brew") }, captureExecutable: appUpdateFixtureExecutable, prepareReplacement: { _, _, _ in }, replaceApplication: { _, _, _ in }, finishReplacement: {})
        let app = AppUpdateTestFixtures.application(provider: .macAppStore, requiresAdministratorAuthorization: true)
        try await auth.prepare(applications: [app], sessionID: UUID())
        await probe.setInstallError("unique-password-fixture Not signed in: account@example.com")
        do { try await auth.upgrade(productID: 123); XCTFail("Injected command failure") }
        catch {
            XCTAssertFalse(error.localizedDescription.contains("unique-password-fixture"))
            XCTAssertFalse(error.localizedDescription.contains("account@example.com"))
            XCTAssertTrue(error.localizedDescription.contains("Not signed in"))
        }
        await probe.setInstallError(String(repeating: "x", count: 8188) + "unique-password-fixture")
        do { try await auth.upgrade(productID: 123); XCTFail("Injected boundary failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains("uniq"), "Redact before truncation so partial credentials cannot leak") }
        await auth.finish()
        XCTAssertTrue(secret.isCleared)
    }
    @MainActor
    func testHelperCancellationRequiresFinishedAcknowledgement() throws {
        let cancelled = try JSONEncoder().encode(AuthorizedUpdateReply(error: "cancelled", errorCode: Int(ECANCELED)))
        XCTAssertThrowsError(try AppUpdateProtectedApplicationAuthorization.checkReply(cancelled)) { XCTAssertEqual($0 as? AppUpdateCommandError, .cancelled) }
        let pending = try JSONEncoder().encode(AuthorizedUpdateReply(error: "cancelled", errorCode: Int(ECANCELED), finished: false))
        XCTAssertThrowsError(try AppUpdateProtectedApplicationAuthorization.checkReply(pending)) { XCTAssertEqual($0 as? AppUpdateCommandError, .needsReconciliation) }
        let recovery = try JSONEncoder().encode(AuthorizedUpdateReply(error: "/Applications/.RetainedOld.app；/Applications/.RootStaging/replacement.json", errorCode: Int(EINPROGRESS), finished: false))
        XCTAssertThrowsError(try AppUpdateProtectedApplicationAuthorization.checkReply(recovery)) {
            guard case let AppUpdateCommandError.recoveryRequired(paths) = $0 else { return XCTFail("Recovery paths must reach the task result") }
            XCTAssertTrue(paths.contains(".RetainedOld.app")); XCTAssertTrue(paths.contains("replacement.json"))
        }
    }
    func testMissingCapabilityRefreshesOnceAndProtectedPreparationFailureDoesNotBlockMas() async throws {
        let probe = CapabilityRepairProbe()
        try await AppUpdateHelperCapabilityGate.ensure(build: "200", trusted: true, probe: {
            if await probe.refreshCount == 0 { throw AuthorizedMoveError.connectionLost }
            return .init(build: "200")
        }, refresh: { await probe.refresh() })
        let count = await probe.refreshCount
        XCTAssertEqual(count, 1)
        let calls = AuthorizationRepairProbe()
        let secret = UpdatePasswordBuffer(bytes: [65])
        let auth = AppUpdateBatchAuthorization(prompt: { _, _ in secret }, makeChannel: { _ in AuthorizationFakeChannel() },
            command: AuthorizationFakeCommand(probe: calls), mas: { URL(fileURLWithPath: "/fake/mas") },
            brew: { URL(fileURLWithPath: "/fake/brew") }, captureExecutable: appUpdateFixtureExecutable, prepareReplacement: { _, _, _ in throw AuthorizedMoveError.approvalRequired }, replaceApplication: { _, _, _ in XCTFail("Unavailable helper") }, finishReplacement: {})
        let protected = AppUpdateTestFixtures.application(id: "protected", path: "/Applications/Tool.app", provider: .sparkle, requiresAdministratorAuthorization: true)
        let store = AppUpdateTestFixtures.application(id: "store", name: "Store Fixture", provider: .macAppStore, requiresAdministratorAuthorization: true)
        try await auth.prepare(applications: [protected, store], sessionID: UUID())
        try await auth.upgrade(productID: 123)
        do { try await auth.replace(candidate: URL(fileURLWithPath: "/fake/candidate.app"), application: protected); XCTFail("Skip unavailable protected replacement") }
        catch let AppUpdateAuthorizationError.helperUnavailable(reason) { XCTAssertTrue(reason.contains("Login Items") || reason.contains("登录项")) }
        await auth.finish()
        XCTAssertTrue(secret.isCleared)
        let performed = await calls.calls
        XCTAssertTrue(performed.contains(where: { $0.arguments.contains("upgrade") }))
    }
    func testOnePasswordForMasAndBrewAndNoCredentialInArgumentsEnvironmentOrOutput() async throws {
        let probe = AuthorizationRepairProbe()
        let secret = UpdatePasswordBuffer(bytes: Array("unique-password-fixture".utf8))
        let authorization = AppUpdateBatchAuthorization(prompt: { commands, attempt in
            await probe.prompt(commands, attempt: attempt); return secret
        }, makeChannel: { _ in AuthorizationFakeChannel() }, command: AuthorizationFakeCommand(probe: probe),
            mas: { URL(fileURLWithPath: "/fake/mas") }, brew: { URL(fileURLWithPath: "/fake/brew") }, captureExecutable: appUpdateFixtureExecutable, prepareReplacement: { _, _, _ in XCTFail("No replacement in this batch") },
            replaceApplication: { _, _, _ in XCTFail("Unused") }, finishReplacement: {})
        var store = AppUpdateTestFixtures.application(id: "store", name: "Store Fixture", provider: .macAppStore, requiresAdministratorAuthorization: true)
        store.appStoreProductURL = URL(string: "https://apps.apple.com/app/id123")
        var brew = AppUpdateTestFixtures.strictHomebrewApplication(id: "pkg", token: "pkg")
        brew.requiresAdministratorAuthorization = true
        let id = UUID()
        try await authorization.prepare(applications: [store, brew], sessionID: id)
        try await authorization.prepare(applications: [store, brew], sessionID: id)
        try await authorization.upgrade(productID: 123)
        let env = try await authorization.homebrewEnvironment()
        XCTAssertEqual(env["SUDO_ASKPASS"], "/sealed/fake-askpass")
        let calls = await probe.calls
        XCTAssertEqual(calls.map(\.arguments), [["-A", "-k", "-v"], ["-k"], ["-A", "-k", "/fake/mas", "upgrade", "123"]])
        for call in calls {
            XCTAssertFalse(call.arguments.joined().contains("unique-password-fixture"))
            XCTAssertFalse(call.environment.description.contains("unique-password-fixture"))
            XCTAssertEqual(call.executable.path, "/usr/bin/sudo")
        }
        let prompts = await probe.prompts
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains(where: { $0.contains("mas") && $0.contains("123") && $0.contains("Store Fixture") }))
        XCTAssertTrue(prompts[0].contains(where: { $0.contains("brew upgrade") && $0.contains("pkg") }))
        await authorization.finish()
        XCTAssertTrue(secret.isCleared)
        do { _ = try await authorization.homebrewEnvironment(); XCTFail("Finished credentials cannot be reused") }
        catch AppUpdateAuthorizationError.declined {}
    }

    func testWrongPasswordStopsAfterThreeAndErasesEveryAttempt() async throws {
        let probe = AuthorizationRepairProbe()
        await probe.rejectPasswords()
        let secrets = (0..<3).map { UpdatePasswordBuffer(bytes: Array("wrong-\($0)".utf8)) }
        let authorization = AppUpdateBatchAuthorization(prompt: { _, attempt in secrets[attempt - 1] },
            makeChannel: { _ in AuthorizationFakeChannel() }, command: AuthorizationFakeCommand(probe: probe),
            brew: { URL(fileURLWithPath: "/fake/brew") }, captureExecutable: appUpdateFixtureExecutable, prepareReplacement: { _, _, _ in XCTFail("No helper approval after a bad password") },
            replaceApplication: { _, _, _ in }, finishReplacement: {})
        let app = AppUpdateTestFixtures.strictHomebrewApplication(requiresAuthorization: true)
        do { try await authorization.prepare(applications: [app], sessionID: UUID()); XCTFail("Reject three wrong passwords") }
        catch AppUpdateAuthorizationError.incorrectPassword {}
        let calls = await probe.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(secrets.allSatisfy(\.isCleared))
    }

    func testAuthorizationCancelSkipsWithoutExecutingSudoAndFreshRetryRequestsAgain() async throws {
        let probe = AuthorizationRepairProbe()
        let cancelled = AppUpdateBatchAuthorization(prompt: { _, _ in nil }, makeChannel: { _ in XCTFail("No channel on cancel"); return AuthorizationFakeChannel() },
            command: AuthorizationFakeCommand(probe: probe), brew: { URL(fileURLWithPath: "/fake/brew") }, captureExecutable: appUpdateFixtureExecutable, prepareReplacement: { _, _, _ in }, replaceApplication: { _, _, _ in }, finishReplacement: {})
        let app = AppUpdateTestFixtures.strictHomebrewApplication(requiresAuthorization: true)
        do { try await cancelled.prepare(applications: [app], sessionID: UUID()); XCTFail("Cancel") }
        catch AppUpdateAuthorizationError.declined {}
        let empty = await probe.calls
        XCTAssertTrue(empty.isEmpty)
        let auth = AppUpdateBatchAuthorization(prompt: { commands, attempt in await probe.prompt(commands, attempt: attempt); return UpdatePasswordBuffer(bytes: [65]) },
            makeChannel: { _ in AuthorizationFakeChannel() }, command: AuthorizationFakeCommand(probe: probe),
            brew: { URL(fileURLWithPath: "/fake/brew") }, captureExecutable: appUpdateFixtureExecutable, prepareReplacement: { _, _, _ in }, replaceApplication: { _, _, _ in }, finishReplacement: {})
        try await auth.prepare(applications: [app], sessionID: UUID())
        await auth.finish()
        try await auth.prepare(applications: [app], sessionID: UUID())
        await auth.finish()
        let prompts = await probe.prompts
        XCTAssertEqual(prompts.count, 2)
    }

    func testNewClientRefreshesOldHelperAndOldClientContractRemainsAndSignerMismatchFails() async throws {
        let probe = CapabilityRepairProbe()
        try await AppUpdateHelperCapabilityGate.ensure(build: "200", trusted: true,
            probe: { await probe.capability() }, refresh: { await probe.refresh() })
        let refreshCount = await probe.refreshCount
        XCTAssertEqual(refreshCount, 1)
        do {
            try await AppUpdateHelperCapabilityGate.ensure(build: "200", trusted: false,
                probe: { XCTFail("Untrusted signature must not be probed"); return .init(build: "200") }, refresh: { XCTFail("Must not refresh an untrusted helper") })
            XCTFail("Reject signature rotation without trust")
        } catch AuthorizedMoveError.unavailable {}
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileOperationShared/FileOperationContract.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("func prepare(_ request: Data, authorization: Data"))
        XCTAssertTrue(source.contains("func commit(_ request: Data"))
        XCTAssertFalse(source.contains("upgradeAppStore"))
        XCTAssertFalse(source.contains("prepareUpdateBatch"))
    }
    func testBusyHelperCannotBeRefreshedAndAccountErrorIsRedacted() async throws {
        do {
            try await AppUpdateHelperCapabilityGate.ensure(build: "200", trusted: true,
                probe: { .init(build: "100", busy: true) }, refresh: { XCTFail("Never unregister during an operation") })
            XCTFail("Busy helper must retain the operation")
        } catch AuthorizedMoveError.unavailable {}
        let redacted = AppUpdateErrorRedaction.text("Not signed in: account@example.com https://example.com/a?token=private token=secret")
        XCTAssertTrue(redacted.contains("Not signed in"))
        XCTAssertFalse(redacted.contains("account@example.com"))
        XCTAssertFalse(redacted.contains("private"))
        XCTAssertFalse(redacted.contains("secret"))
    }
    func testArtifactPrivilegeDetectionAndBrewTokenRejectsRubyPaths() {
        let reasons = HomebrewArtifactAuthorization.reasons(artifacts: [
            ["pkg": ["installer.pkg"]], ["installer": ["script": ["executable": "install", "sudo": true]]],
            ["app": ["Tool.app", ["target": "/Applications/Tool.app"]]]], writable: { _ in false })
        XCTAssertEqual(reasons.count, 3)
        XCTAssertTrue(HomebrewArtifactAuthorization.reasons(artifacts: [["font": ["Tool.ttf"]]], writable: { _ in true }).isEmpty)
        for token in ["./x.rb", "x.rb", "/tmp/x", "x/y", "../x", "--help", "x//y/z"] { XCTAssertFalse(HomebrewPackageTokenPolicy.isValid(token), token) }
        for token in ["font-hack-nerd-font", "gemini-cli", "owner/tap/package@2"] { XCTAssertTrue(HomebrewPackageTokenPolicy.isValid(token), token) }
    }
}

private final class Repair2IdentityProbe: @unchecked Sendable {
    private let lock = NSLock(); private var changed = false
    func change() { lock.withLock { changed = true } }
    func capture(_ url: URL) throws -> AppUpdateExecutableIdentity {
        let changed = lock.withLock { changed }
        return .init(url: url, resolvedURL: url, inode: 1, device: 1, owner: getuid(), mode: 0o755,
            sha256: String(repeating: changed ? "b" : "a", count: 64))
    }
}

private struct AuthorizationFakeChannel: AppUpdateAskpassServing {
    var environment: [String: String] { ["SUDO_ASKPASS": "/sealed/fake-askpass", "STORAGE_CLEANER_ASKPASS_SOCKET": "/private/tmp/fake/p"] }
    func finish() {}
}
private actor AuthorizationRepairProbe {
    struct Call: Sendable { let executable: URL; let arguments: [String]; let environment: [String: String] }
    var calls = [Call](); var prompts = [[String]](); var reject = false
    var installError: String?
    func setInstallError(_ error: String) { installError = error }
    func prompt(_ commands: [String], attempt: Int) { prompts.append(commands) }
    func rejectPasswords() { reject = true }
    func command(_ call: Call) throws -> Data {
        calls.append(call)
        if call.arguments.contains("upgrade"), let installError { throw AppUpdateCommandError.failed(1, installError) }
        if reject { throw AppUpdateCommandError.failed(1, "incorrect password") }
        return Data()
    }
}
private struct AuthorizationFakeCommand: HomebrewCommandRunning {
    let probe: AuthorizationRepairProbe
    func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Data {
        try await probe.command(.init(executable: executableURL, arguments: arguments, environment: environment))
    }
}
private actor CapabilityRepairProbe {
    var refreshCount = 0
    func capability() -> ApplicationReplacementCapabilities { .init(version: refreshCount == 0 ? 1 : ApplicationReplacementCapabilities.currentVersion, build: refreshCount == 0 ? "100" : "200") }
    func refresh() { refreshCount += 1 }
}
private actor RepairPromptCounter {
    private var index = 0
    func next() -> Int { defer { index += 1 }; return index }
}
private actor RepairRefreshCancellationProbe {
    var wasCancelled = false
    func cancelled() { wasCancelled = true }
}
private actor RepairRetryRepository: ApplicationUpdateQueuePersisting {
    private var snapshot: ApplicationUpdateQueueSnapshot?
    func load() -> ApplicationUpdateQueueSnapshot? { snapshot }
    func save(_ snapshot: ApplicationUpdateQueueSnapshot) { self.snapshot = snapshot }
    func clear() { snapshot = nil }
}
private actor RepairRetryBatchExecutor: ApplicationUpdateBatchExecuting {
    let authorization: AppUpdateBatchAuthorization
    var batches = [UUID]()
    var attempts = 0
    init(authorization: AppUpdateBatchAuthorization) { self.authorization = authorization }
    func beginBatch(applications: [InstalledApplication], sessionID: UUID) async {
        batches.append(sessionID)
        do { try await authorization.prepare(applications: applications, sessionID: sessionID) }
        catch { XCTFail("Unexpected fake authorization: \(error)") }
    }
    func endBatch(sessionID: UUID) async { await authorization.finish() }
    func executeHomebrewBatch(applications: [InstalledApplication], tasks: [ApplicationUpdateTask],
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void) async -> [ApplicationUpdateInstallResult] {
        attempts += 1
        return applications.map { .init(applicationID: $0.id, state: attempts == 1 ? .failed : .completed,
            observedVersion: attempts == 1 ? nil : .init(marketing: "2.0"), detail: "injected retry") }
    }
    func execute(application: InstalledApplication, task: ApplicationUpdateTask,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void) async throws -> ApplicationUpdateInstallResult { throw ApplicationUpdateExecutionError.unsupportedProvider(task.providerIdentifier) }
    func cancel(applicationID: String) async {}
    func reconcile(task: ApplicationUpdateTask, application: InstalledApplication?) async throws -> ApplicationUpdateInstallResult { throw ApplicationUpdateExecutionError.unsupportedProvider(task.providerIdentifier) }
}
