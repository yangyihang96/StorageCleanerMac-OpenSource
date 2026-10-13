import CryptoKit
import Darwin
import FileOperationShared
import Foundation
import XCTest
@testable import StorageCleanerMac

/// Every command source in injected-executor tests is also an injected identity.
func appUpdateFixtureExecutable(_ url: URL) throws -> AppUpdateExecutableIdentity {
    .init(url: url, resolvedURL: url, inode: 1, device: 1, owner: getuid(), mode: 0o755, sha256: String(repeating: "a", count: 64))
}

final class AppUpdateRepair2Tests: XCTestCase {
    func testAskpassPolicyBindsExactCodePathFrozenHashSudoParentAndProcessIdentity() {
        let app = UpdateAskpassCodeIdentity(identifier: "app", team: "TEAM", cdhash: Data([1]))
        let approved = UpdateAskpassCodeIdentity(identifier: "askpass", team: "TEAM", cdhash: Data([2]))
        let policy = UpdateAskpassPeerPolicy(executable: "/signed/askpass", application: app, bundledAskpass: approved)
        let peer = UpdateAskpassKernelPeer(pid: 101, uid: getuid(), auditToken: Data(repeating: 0, count: 32))
        for boundary in ["valid", "path", "signer", "hash", "parent", "reused"] {
            let counter = Repair2PolicyLookupProbe()
            let allowed = policy.permits(peer, process: { pid in
                if pid == peer.pid {
                    let count = counter.next()
                    return self.process(pid, parent: 100, group: 1, start: boundary == "reused" && count > 0 ? 99 : 10,
                        executable: boundary == "path" ? "/other/askpass" : policy.executable)
                }
                return pid == 100 ? self.process(pid, parent: 1, group: 1, executable: boundary == "parent" ? "/usr/bin/ruby" : "/usr/bin/sudo") : nil
            }, signature: { _ in
                .init(identifier: "askpass", team: boundary == "signer" ? "OTHER" : "TEAM", cdhash: boundary == "hash" ? Data([9]) : approved.cdhash)
            })
            XCTAssertEqual(allowed, boundary == "valid", boundary)
        }
    }
    func testRealSocketPeerRejectsWrongExecutableSignerAndNonSudoParent() throws {
        let appCode = UpdateAskpassCodeIdentity(identifier: "app", team: "TEAM", cdhash: Data([1]))
        let askCode = UpdateAskpassCodeIdentity(identifier: "askpass", team: "TEAM", cdhash: Data([2]))
        let policy = UpdateAskpassPeerPolicy(executable: "/signed/App.app/Contents/Helpers/askpass", application: appCode, bundledAskpass: askCode)
        for boundary in ["path", "signer", "parent", "hash"] {
            let observed = Repair2PeerProbe()
            let secret = UpdatePasswordBuffer(bytes: Array("fixture-secret".utf8))
            let channel = try UpdateAskpassChannel(password: secret, maximumResponses: 1, authorizePeer: { peer in
                observed.record(peer)
                let caller = UpdateProcessSnapshot(pid: peer.pid, startTime: 10, parentPID: 777, groupPID: 1, uid: peer.uid,
                    executable: boundary == "path" ? "/other/askpass" : policy.executable)
                let parent = UpdateProcessSnapshot(pid: 777, startTime: 5, parentPID: 1, groupPID: 1, uid: 0,
                    executable: boundary == "parent" ? "/usr/bin/ruby" : "/usr/bin/sudo")
                let code = UpdateAskpassCodeIdentity(identifier: "askpass", team: boundary == "signer" ? "OTHER" : "TEAM",
                    cdhash: boundary == "hash" ? Data([9]) : askCode.cdhash)
                return policy.permits(peer, process: { $0 == peer.pid ? caller : ($0 == 777 ? parent : nil) }, signature: { _ in code })
            }, authorizeRequest: { _, _ in XCTFail("Untrusted peer must never consume an allowance"); return true })
            defer { channel.finish() }
            XCTAssertTrue(try repair2SocketRead(channel.socketPath).isEmpty, boundary)
            XCTAssertEqual(observed.peer?.pid, getpid(), "Peer PID is supplied by the kernel, never a client message")
            XCTAssertEqual(observed.peer?.uid, getuid())
            XCTAssertEqual(observed.peer?.auditToken.count, MemoryLayout<audit_token_t>.size)
        }
    }
    func testRealSocketChallengeIsOneUseAndFinishErasesCredential() throws {
        let secret = UpdatePasswordBuffer(bytes: Array("fixture-secret".utf8))
        let observed = Repair2PeerProbe()
        let channel = try UpdateAskpassChannel(password: secret, maximumResponses: 1, authorizePeer: { peer in
            observed.record(peer); return peer.pid == getpid() && peer.uid == getuid()
        }, authorizeRequest: { _, _ in true })
        XCTAssertEqual(try repair2SocketRead(channel.socketPath), Data("fixture-secret\n".utf8))
        XCTAssertTrue(try repair2SocketRead(channel.socketPath).isEmpty, "The same caller/sudo request cannot consume a second credential")
        channel.finish()
        XCTAssertTrue(secret.isCleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: channel.socketPath))
    }
    func testWrongOneUseChallengeNeverReleasesPassword() throws {
        let secret = UpdatePasswordBuffer(bytes: Array("fixture-secret".utf8))
        let channel = try UpdateAskpassChannel(password: secret, maximumResponses: 1, authorizePeer: { _ in true }, authorizeRequest: { _, _ in true })
        defer { channel.finish() }
        XCTAssertTrue(try repair2SocketRead(channel.socketPath, corruptChallenge: true).isEmpty)
    }
    func testAskpassItselfRequiresSudoParentAndPipeStdout() {
        XCTAssertTrue(UpdateAskpassInvocation.permits(parentExecutable: "/usr/bin/sudo", stdoutMode: S_IFIFO | 0o600))
        XCTAssertFalse(UpdateAskpassInvocation.permits(parentExecutable: "/usr/bin/ruby", stdoutMode: S_IFIFO))
        XCTAssertFalse(UpdateAskpassInvocation.permits(parentExecutable: "/usr/bin/sudo", stdoutMode: S_IFREG))
        XCTAssertFalse(UpdateAskpassInvocation.permits(parentExecutable: "/usr/bin/sudo", stdoutMode: S_IFCHR))
    }
    func testResponseBudgetIsActualSudoInvocationsWithinLiveApprovedCommand() {
        let registry = UpdateAskpassInvocationRegistry()
        let root = process(100, parent: 1, group: 100, executable: "/frozen/brew")
        let ruby = process(101, parent: 100, group: 900, executable: "/usr/bin/ruby")
        let sudo = process(102, parent: 101, group: 901, executable: "/usr/bin/sudo")
        let laterSudo = process(103, parent: 101, group: 902, executable: "/usr/bin/sudo")
        let unrelated = process(104, parent: 1, group: 104, executable: "/usr/bin/sudo")
        let table = [root, ruby, sudo, laterSudo, unrelated]
        registry.begin(socket: "fixture", root: root.identity)
        func lookup(_ pid: pid_t) -> UpdateProcessSnapshot? { table.first { $0.identity.pid == pid } }
        XCTAssertFalse(registry.claim(socket: "fixture", sudo: ruby.identity, lookup: lookup))
        XCTAssertFalse(registry.claim(socket: "fixture", sudo: unrelated.identity, lookup: lookup))
        XCTAssertTrue(registry.claim(socket: "fixture", sudo: sudo.identity, lookup: lookup))
        XCTAssertFalse(registry.claim(socket: "fixture", sudo: sudo.identity, lookup: lookup))
        XCTAssertTrue(registry.claim(socket: "fixture", sudo: laterSudo.identity, lookup: lookup))
        registry.end(socket: "fixture", root: root.identity)
        XCTAssertFalse(registry.claim(socket: "fixture", sudo: laterSudo.identity, lookup: lookup))
    }
    func testCommandTreeTracksAllGroupsRetainsReparentedChildrenAndNeverSignalsReusedPID() {
        let root = process(100, parent: 1, group: 100)
        let child = process(101, parent: 100, group: 777)
        let grandchild = process(102, parent: 101, group: 888)
        var tree = AppUpdateCommandProcessTree(root: root.identity)
        tree.observe([grandchild, child, root])
        XCTAssertEqual(tree.identities, Set([root.identity, child.identity, grandchild.identity]))
        let reparented = process(102, parent: 1, group: 888)
        XCTAssertEqual(tree.signalTargets(current: [reparented]), [grandchild.identity])
        XCTAssertFalse(tree.confirmedStopped(current: [reparented]))
        let reused = process(102, parent: 1, group: 888, start: 999)
        XCTAssertTrue(tree.signalTargets(current: [reused]).isEmpty)
        XCTAssertTrue(tree.confirmedStopped(current: [reused]))
        XCTAssertFalse(tree.confirmedStopped(current: [], readable: false))
        tree.lostTracking()
        XCTAssertFalse(tree.confirmedStopped(current: []), "A missing descendant cannot be silently declared stopped")
    }
    func testNativeProducerOutputLimitStopsOwnShortLivedChild() throws {
        let runner = AppUpdateCommandRunner(outputLimit: 16, stopTimeout: 0.2)
        XCTAssertThrowsError(try runner.runSync(executableURL: URL(fileURLWithPath: "/usr/bin/printf"), arguments: [String(repeating: "x", count: 128)],
            environment: ["PATH": "/usr/bin:/bin"], timeout: 2, cancelled: { false })) {
                XCTAssertEqual($0 as? AppUpdateCommandError, .outputLimit)
            }
    }
    func testNativeTimeoutAndCancellationAcknowledgeOwnChildStop() throws {
        let runner = AppUpdateCommandRunner(stopTimeout: 0.2)
        XCTAssertThrowsError(try runner.runSync(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"], environment: [:], timeout: 0.03, cancelled: { false })) {
            XCTAssertEqual($0 as? AppUpdateCommandError, .timedOut)
        }
        let cancel = HomebrewCommandCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { cancel.cancel() }
        XCTAssertThrowsError(try runner.runSync(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"], environment: [:], timeout: 2, cancelled: { cancel.isCancelled })) {
            XCTAssertEqual($0 as? AppUpdateCommandError, .cancelled)
        }
    }
    func testPasswordRedactionUsesByteBufferAcrossRepeatedAndTruncationBoundaryMatches() {
        let secret = UpdatePasswordBuffer(bytes: Array("fixture-secret".utf8))
        let redactor = AppUpdateCredentialRedactor()
        redactor.set(secret)
        let raw = Data(("fixture-secret " + String(repeating: "x", count: 8190) + "fixture-secret fixture-secret").utf8)
        let redacted = redactor.redact(bytes: raw)
        XCTAssertFalse(redacted.contains("fixture"))
        XCTAssertTrue(redacted.hasPrefix("[已隐去]"))
        secret.clear(); redactor.set(nil)
    }
    func testFrozenExecutableDetectsSameInodeByteChangesAndGroupWritableSource() throws {
        let root = try TestFileSystem.makeHome(for: self)
        let executable = root.appendingPathComponent("brew-fixture")
        try Data("unused test executable bytes".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let frozen = try AppUpdateExecutableIdentity.capture(executable)
        try frozen.validate()
        try Data("changed test executable bytes".utf8).write(to: executable)
        XCTAssertThrowsError(try frozen.validate())
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: executable.path)
        XCTAssertThrowsError(try AppUpdateExecutableIdentity.capture(executable))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: root.path)
        XCTAssertThrowsError(try AppUpdateExecutableIdentity.capture(executable), "The containing source directory cannot be group writable")
    }
    /// Standard Homebrew keeps bin/ as user:admin 0775 (verified on the user's Mac 2026-10-12).
    func testStandardHomebrewAdminGroupBinIsTrustedButOtherGroupWriteIsNot() {
        let user: UInt32 = 501
        XCTAssertTrue(AppUpdateSourcePermissions.isTrusted(owner: user, group: 80, mode: 0o775, user: user))
        XCTAssertTrue(AppUpdateSourcePermissions.isTrusted(owner: 0, group: 0, mode: 0o755, user: user))
        XCTAssertFalse(AppUpdateSourcePermissions.isTrusted(owner: user, group: 20, mode: 0o775, user: user))
        XCTAssertFalse(AppUpdateSourcePermissions.isTrusted(owner: user, group: 80, mode: 0o777, user: user))
        XCTAssertFalse(AppUpdateSourcePermissions.isTrusted(owner: 502, group: 80, mode: 0o755, user: user))
    }
    func testPrivilegedPATHContainsOnlySystemAndFrozenPrefixBin() {
        let env = HomebrewCommandEnvironment.allowlist(executableURL: URL(fileURLWithPath: "/frozen/prefix/bin/brew"),
            environment: ["PATH": "/attacker/bin:/usr/local/bin", "SUDO_ASKPASS": "/attacker/askpass"])
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin:/frozen/prefix/bin")
        XCTAssertNil(env["SUDO_ASKPASS"])
    }
    func testCaskSavedConfigurationPrecedenceAndEveryArtifactDirectory() throws {
        let home = URL(fileURLWithPath: "/Users/fixture")
        let config = HomebrewCaskConfiguration.resolve(saved: ["default": ["appdir": "/default"], "env": ["appdir": "/saved-env"],
            "explicit": ["appdir": "~/Custom Apps", "mdimporterdir": "/protected/Spotlight"]],
            environment: ["HOMEBREW_CASK_OPTS": "--appdir=/ignored-current"], home: home)
        XCTAssertTrue(config.understood)
        XCTAssertEqual(config.directories["app"], "/Users/fixture/Custom Apps")
        XCTAssertEqual(config.directories["suite"], "/Users/fixture/Custom Apps")
        XCTAssertEqual(config.directories["keyboard_layout"], "/Library/Keyboard Layouts")
        XCTAssertEqual(config.directories["mdimporter"], "/protected/Spotlight")
        for artifact in ["font", "binary", "manpage", "colorpicker", "prefpane", "qlplugin", "dictionary", "service", "input_method",
            "internet_plugin", "audio_unit_plugin", "vst_plugin", "vst3_plugin", "screen_saver", "appimage", "bash_completion", "zsh_completion", "fish_completion", "pwsh_completion"] {
            XCTAssertNotNil(config.directories[artifact], artifact)
        }
        let envOnly = HomebrewCaskConfiguration.resolve(environment: ["HOMEBREW_CASK_OPTS": "--appdir='~/Quoted Apps' --keyboard-layoutdir=/custom/layouts"], home: home)
        XCTAssertEqual(envOnly.directories["app"], "/Users/fixture/Quoted Apps")
        XCTAssertEqual(envOnly.directories["keyboard_layout"], "/custom/layouts")
    }
    func testCustomAppdirFeedsExactPathsAndProtectedKeyboardLayoutAndImporterNeedAuthorization() throws {
        let config = HomebrewCaskConfiguration.resolve(saved: ["explicit": ["appdir": "/protected/Apps", "mdimporterdir": "/protected/Spotlight"]])
        let artifacts: [[String: Any]] = [["app": ["Tool.app"]], ["keyboard_layout": ["Fixture.keylayout"]], ["mdimporter": ["Fixture.mdimporter"]]]
        let reasons = HomebrewArtifactAuthorization.reasons(artifacts: artifacts, configuration: config, exists: { _ in true }, writable: { $0.hasPrefix("/protected") == false && !$0.hasPrefix("/Library") })
        XCTAssertTrue(reasons.contains(where: { $0.contains("/protected/Apps/Tool.app") }))
        XCTAssertTrue(reasons.contains(where: { $0.contains("keyboard_layout") }))
        XCTAssertTrue(reasons.contains(where: { $0.contains("mdimporter") }))
        let data = try JSONSerialization.data(withJSONObject: ["formulae": [], "casks": [["token": "tool", "version": "2.0", "installed": "1.0", "artifacts": artifacts]]])
        let packages = try HomebrewInventoryParser.parse(installedData: data, outdatedData: nil, prefixURL: URL(fileURLWithPath: "/opt/homebrew"), caskConfigurations: ["tool": config])
        XCTAssertEqual(packages.first?.metadata.appBundlePaths, ["/protected/Apps/Tool.app"])
        XCTAssertTrue(packages.first?.metadata.needsAdministrator == true)
    }
    func testUnknownOrUnparseableTargetConfigurationConservativelyNeedsAuthorization() {
        let unknown = HomebrewCaskConfiguration.resolve(environment: ["HOMEBREW_CASK_OPTS": "--appdir='unclosed"])
        XCTAssertFalse(unknown.understood)
        XCTAssertFalse(HomebrewArtifactAuthorization.reasons(artifacts: [["font": ["Font.ttf"]]], configuration: unknown, writable: { _ in true }).isEmpty)
        XCTAssertFalse(HomebrewArtifactAuthorization.reasons(artifacts: [["new_unknown_type": ["Thing"]]], writable: { _ in true }).isEmpty)
    }
    func testSuiteArtifactCollectsEveryExistingApplicationUnderEffectiveAppdir() throws {
        let root = try TestFileSystem.makeHome(for: self)
        for name in ["A.app", "Nested/B.app"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Suite/" + name), withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: ["formulae": [], "casks": [["token": "suite", "version": "2.0", "installed": "1.0", "artifacts": [["suite": ["Suite"]]]]]])
        let config = HomebrewCaskConfiguration.resolve(saved: ["explicit": ["appdir": root.path]])
        let packages = try HomebrewInventoryParser.parse(installedData: data, outdatedData: nil, prefixURL: root, caskConfigurations: ["suite": config])
        let observed = packages.first?.metadata.appBundlePaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(observed, [root.appendingPathComponent("Suite/A.app").resolvingSymlinksInPath().path, root.appendingPathComponent("Suite/Nested/B.app").resolvingSymlinksInPath().path])
    }
    func testCoordinatorKeepsFailedOldAndBelowTargetReadbackPendingAndRejectsRetry() async throws {
        for mode in ["throw", "failed", "old", "below", "unknown-cancel"] {
            let executor = Repair2PendingExecutor(mode: mode)
            let coordinator = ApplicationUpdateCoordinator(repository: Repair2QueueRepository(), executor: executor)
            let app = AppUpdateTestFixtures.strictHomebrewApplication(id: "pending")
            _ = try await coordinator.start(applications: [app])
            for _ in 0..<200 {
                if await coordinator.currentSnapshot()?.tasks.first?.state == .needsReconciliation { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            await coordinator.reconcilePendingTasks()
            let state = await coordinator.currentSnapshot()?.tasks.first?.state
            XCTAssertEqual(state, .needsReconciliation, mode)
            do { try await coordinator.retry(applicationID: app.id); XCTFail("Unproven completion cannot enter a retry batch: \(mode)") }
            catch ApplicationUpdateCoordinatorError.taskCannotBeRetried {}
            let attempts = await executor.attempts
            XCTAssertEqual(attempts, 1)
        }
    }
    func testCoordinatorAcceptsTrustedCompletedTargetReadback() async throws {
        let coordinator = ApplicationUpdateCoordinator(repository: Repair2QueueRepository(), executor: Repair2PendingExecutor(mode: "trusted"))
        let app = AppUpdateTestFixtures.strictHomebrewApplication(id: "pending")
        _ = try await coordinator.start(applications: [app])
        for _ in 0..<200 {
            if await coordinator.currentSnapshot()?.tasks.first?.state == .needsReconciliation { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await coordinator.reconcilePendingTasks()
        let state = await coordinator.currentSnapshot()?.tasks.first?.state
        XCTAssertEqual(state, .completed)
    }
    func testCoordinatorOnlyAcceptsCancellationWithConfirmedNativeStopReceipt() async throws {
        let coordinator = ApplicationUpdateCoordinator(repository: Repair2QueueRepository(), executor: Repair2PendingExecutor(mode: "stopped"))
        let app = AppUpdateTestFixtures.strictHomebrewApplication(id: "pending")
        _ = try await coordinator.start(applications: [app])
        for _ in 0..<200 {
            if await coordinator.currentSnapshot()?.tasks.first?.state == .needsReconciliation { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await coordinator.reconcilePendingTasks()
        let state = await coordinator.currentSnapshot()?.tasks.first?.state
        XCTAssertEqual(state, .cancelled)
    }
    func testLateFailureProgressCannotReleasePendingInstallationIntoRetry() async throws {
        let executor = Repair2PendingExecutor(mode: "throw")
        let coordinator = ApplicationUpdateCoordinator(repository: Repair2QueueRepository(), executor: executor)
        let app = AppUpdateTestFixtures.strictHomebrewApplication(id: "pending")
        _ = try await coordinator.start(applications: [app])
        for _ in 0..<200 {
            if await coordinator.currentSnapshot()?.tasks.first?.state == .needsReconciliation { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await executor.emitLateFailure()
        let state = await coordinator.currentSnapshot()?.tasks.first?.state
        XCTAssertEqual(state, .needsReconciliation)
        let cancellations = await executor.cancellations
        XCTAssertEqual(cancellations, 0, "A late progress event must not trigger another native cancellation")
        do { try await coordinator.retry(applicationID: app.id); XCTFail("Late progress is not stop evidence") }
        catch ApplicationUpdateCoordinatorError.taskCannotBeRetried {}
    }
    private func process(_ pid: pid_t, parent: pid_t, group: pid_t, start: UInt64 = 10, executable: String = "/fixture") -> UpdateProcessSnapshot {
        .init(pid: pid, startTime: start, parentPID: parent, groupPID: group, uid: getuid(), executable: executable)
    }
    func testSymbolicLatestUsesOneNormalization() {
        for value in ["latest", ":latest", "LATEST", ":LaTeSt", " latest "] { XCTAssertTrue(HomebrewSymbolicVersion.isLatest(value)) }
        for value in ["1.0", "latest1", "foo:latest", ""] { XCTAssertFalse(HomebrewSymbolicVersion.isLatest(value)) }
    }
}

private actor Repair2QueueRepository: ApplicationUpdateQueuePersisting {
    var value: ApplicationUpdateQueueSnapshot?
    func load() -> ApplicationUpdateQueueSnapshot? { value }
    func save(_ snapshot: ApplicationUpdateQueueSnapshot) { value = snapshot }
    func clear() { value = nil }
}
private actor Repair2PendingExecutor: ApplicationUpdateBatchExecuting {
    let mode: String; var attempts = 0
    var cancellations = 0
    var callback: (@Sendable (ApplicationUpdateProgressEvent) async -> Void)?
    init(mode: String) { self.mode = mode }
    func beginBatch(applications: [InstalledApplication], sessionID: UUID) async {}
    func endBatch(sessionID: UUID) async {}
    func executeHomebrewBatch(applications: [InstalledApplication], tasks: [ApplicationUpdateTask], progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void) async -> [ApplicationUpdateInstallResult] {
        attempts += 1
        callback = progress
        return applications.map { .init(applicationID: $0.id, state: .needsReconciliation, observedVersion: nil, detail: "Unconfirmed stop") }
    }
    func execute(application: InstalledApplication, task: ApplicationUpdateTask, progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void) async throws -> ApplicationUpdateInstallResult {
        throw ApplicationUpdateExecutionError.unsupportedProvider(task.providerIdentifier)
    }
    func cancel(applicationID: String) async { cancellations += 1 }
    func emitLateFailure() async { await callback?(.init(applicationID: "pending", state: .failed, fraction: nil, detail: "Late failure without stop proof")) }
    func reconcile(task: ApplicationUpdateTask, application: InstalledApplication?) async throws -> ApplicationUpdateInstallResult {
        if mode == "throw" { throw ProviderBackedUpdateExecutorError.applicationMissing }
        return .init(applicationID: task.applicationID, state: ["stopped", "unknown-cancel"].contains(mode) ? .cancelled : (mode == "failed" ? .failed : .completed),
            observedVersion: mode == "trusted" ? task.targetVersion : (mode == "below" ? .init(marketing: "1.5") : task.originalVersion),
            detail: "Injected readback", confirmedStopped: mode == "stopped")
    }
}
private final class Repair2PolicyLookupProbe {
    private var count = 0
    func next() -> Int { defer { count += 1 }; return count }
}

private final class Repair2PeerProbe: @unchecked Sendable {
    private let lock = NSLock(); private var value: UpdateAskpassKernelPeer?
    var peer: UpdateAskpassKernelPeer? { lock.withLock { value } }
    func record(_ value: UpdateAskpassKernelPeer) { lock.withLock { self.value = value } }
}
private func repair2SocketRead(_ path: String, corruptChallenge: Bool = false) throws -> Data {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    // A closed server must surface as EPIPE, never kill the test process.
    var noSignal: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = try UpdateAskpassPeer.address(path)
    let status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard status == 0 else { throw POSIXError(.ECONNREFUSED) }
    var token = [UInt8](repeating: 0, count: 32); var offset = 0
    while offset < token.count {
        let count = token.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
        if count <= 0 { return Data() }; offset += count
    }
    if corruptChallenge { token[0] ^= 1 }
    _ = token.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    var bytes = [UInt8](repeating: 0, count: 4096); var result = Data()
    while true { let count = Darwin.read(fd, &bytes, bytes.count); if count <= 0 { break }; result.append(contentsOf: bytes.prefix(count)) }
    return result
}
