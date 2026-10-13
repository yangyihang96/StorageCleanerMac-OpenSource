import AppKit
import Darwin
import FileOperationShared
import Foundation
import Security

enum AppUpdateHelperCapabilityGate {
    static func ensure(build: String, trusted: Bool,
        probe: @Sendable () async throws -> ApplicationReplacementCapabilities,
        refresh: @Sendable () async throws -> Void) async throws {
        guard trusted, !build.isEmpty else { throw AuthorizedMoveError.unavailable }
        if let capability = try? await probe() {
            guard !capability.busy else { throw AuthorizedMoveError.unavailable }
            if capability.version == ApplicationReplacementCapabilities.currentVersion && capability.build == build { return }
        }
        try Task.checkCancellation()
        try await refresh()
        let capability = try await probe()
        guard !capability.busy, capability.version == ApplicationReplacementCapabilities.currentVersion, capability.build == build else { throw AuthorizedMoveError.approvalRequired }
    }
}

@MainActor final class AppUpdateProtectedApplicationAuthorization {
    static let shared = AppUpdateProtectedApplicationAuthorization()
    private var connection: NSXPCConnection?
    private var authorization: AuthorizationRef?
    private var sessionID: UUID?
    func prepare(applications: [InstalledApplication], sessionID: UUID, password: UpdatePasswordBuffer) async throws {
        await finish()
        guard applications.allSatisfy(AppUpdateProtectedReplacementPolicy.accepts),
            let helper = Bundle.main.url(forResource: "StorageCleanerFileOperationHelper", withExtension: nil),
            AppUpdateBundledCodeTrust.matchesApplication(helper, identifier: FileOperationIdentity.helper) else { throw AuthorizedMoveError.unavailable }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        try await Self.boundedRefresh { try await AuthorizedApplicationMover.shared.prepareHelper(refreshRegisteredBuild: false) }
        openConnection()
        do {
            try await AppUpdateHelperCapabilityGate.ensure(build: build, trusted: true, probe: { [self] in
                let data = try await exchange(timeout: 2) { proxy, reply in proxy.applicationReplacementCapabilities?(reply: reply) }
                return try JSONDecoder().decode(ApplicationReplacementCapabilities.self, from: data)
            }, refresh: { [self] in
                await MainActor.run { self.connection?.invalidate(); self.connection = nil }
                try await Self.boundedRefresh { try await AuthorizedApplicationMover.shared.prepareHelper(forceRefresh: true) }
                await MainActor.run { self.openConnection() }
            })
            // Commit this lifecycle cache only after the resident signed helper
            // proved its build. Later move/restore clients then keep this worker.
            UserDefaults.standard.set(build, forKey: FileOperationIdentity.helper + ".registeredBuild")
            let targets = applications.map { AuthorizedUpdateTarget(path: $0.path, bundleIdentifier: $0.bundleIdentifier,
                teamIdentifier: $0.signingTeamIdentifier ?? "", version: $0.installedVersion.marketing, build: $0.installedVersion.build) }
            let batch = AuthorizedApplicationReplacementBatch(sessionID: sessionID, targets: targets)
            guard batch.isValid else { throw AuthorizedMoveError.unavailable }
            let form = try authorizeWithoutSecondDialog(password)
            let request = try JSONEncoder().encode(batch)
            try Self.checkReply(try await exchange(timeout: 10) { proxy, reply in proxy.prepareApplicationReplacements?(request, authorization: form, reply: reply) })
            self.sessionID = sessionID
        } catch { await finish(); throw error }
    }
    func replace(candidate: URL, application: InstalledApplication, authenticatedSHA256: String) async throws {
        guard let sessionID else { throw AuthorizedMoveError.unavailable }
        let digest = authenticatedSHA256
        let request = AuthenticatedApplicationReplacement(candidatePath: candidate.path, destinationPath: application.path,
            sessionID: sessionID, candidateSHA256: digest)
        let data = try JSONEncoder().encode(request)
        do { try Self.checkReply(try await exchange(timeout: 120) { proxy, reply in proxy.replaceAuthenticatedApplication?(data, reply: reply) }) }
        catch AuthorizedMoveError.connectionLost { throw AppUpdateCommandError.needsReconciliation }
    }
    func finish() async {
        if let sessionID, connection != nil {
            // The serial helper acknowledges only after active replacement and
            // rollback complete. Invalidation alone is never a stop receipt.
            _ = try? Self.checkReply(try await exchange(timeout: 5) { proxy, reply in proxy.finishApplicationReplacements?(sessionID.uuidString, reply: reply) })
        }
        connection?.invalidate(); connection = nil; sessionID = nil
        if let authorization { AuthorizationFree(authorization, [.destroyRights]) }
        authorization = nil
    }
    private func openConnection() {
        guard let requirement = FileOperationPeerRequirement.currentSigner(peerIdentifier: FileOperationIdentity.helper) else { return }
        let connection = NSXPCConnection(machServiceName: FileOperationIdentity.helper, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: FileOperationHelperProtocol.self)
        connection.resume(); self.connection = connection
    }
    private func authorizeWithoutSecondDialog(_ password: UpdatePasswordBuffer) throws -> Data {
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else { throw AuthorizedMoveError.unavailable }
        do {
            let name = AuthorizedApplicationReplacementBatch.right
            if AuthorizationRightGet(name, nil) != errAuthorizationSuccess {
                guard AuthorizationRightSet(reference, name, kAuthorizationRuleAuthenticateAsAdmin as CFString,
                    L10n.text("替换本批已验证应用", "Replace this batch's verified applications") as CFString, nil, nil) == errAuthorizationSuccess else { throw AuthorizedMoveError.unavailable }
            }
            // AuthorizationEnvironment is an in-process credential structure,
            // never a child-process environment variable. No interaction flag:
            // failure skips these items instead of opening a second password UI.
            let status = password.withBytes { bytes -> OSStatus in
                var credential = Array(bytes) + [0]
                defer { credential.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
                return NSUserName().withCString { user in
                    credential.withUnsafeMutableBytes { buffer in
                        return kAuthorizationEnvironmentUsername.withCString { usernameKey in
                            kAuthorizationEnvironmentPassword.withCString { passwordKey in
                                var entries = [
                            AuthorizationItem(name: usernameKey, valueLength: strlen(user), value: UnsafeMutableRawPointer(mutating: user), flags: 0),
                            AuthorizationItem(name: passwordKey, valueLength: bytes.count, value: buffer.baseAddress, flags: 0)]
                        return entries.withUnsafeMutableBufferPointer { entries in
                            var environment = AuthorizationEnvironment(count: UInt32(entries.count), items: entries.baseAddress)
                            return name.withCString { name in
                                var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                                return withUnsafeMutablePointer(to: &item) { pointer in
                                    var rights = AuthorizationRights(count: 1, items: pointer)
                                    return AuthorizationCopyRights(reference, &rights, &environment, [.extendRights, .preAuthorize], nil)
                                }
                            }
                        }
                            }
                        }
                    }
                }
            }
            guard status == errAuthorizationSuccess else { throw AppUpdateAuthorizationError.declined }
            var form = AuthorizationExternalForm()
            guard AuthorizationMakeExternalForm(reference, &form) == errAuthorizationSuccess else { throw AuthorizedMoveError.unavailable }
            authorization = reference
            return withUnsafeBytes(of: form) { Data($0) }
        } catch { AuthorizationFree(reference, [.destroyRights]); throw error }
    }
    static func checkReply(_ data: Data) throws {
        let reply = try JSONDecoder().decode(AuthorizedUpdateReply.self, from: data)
        guard reply.finished else {
            if reply.errorCode == Int(EINPROGRESS), let detail = reply.error { throw AppUpdateCommandError.recoveryRequired(AppUpdateErrorRedaction.text(detail)) }
            throw AppUpdateCommandError.needsReconciliation
        }
        if reply.errorCode == Int(ECANCELED) { throw AppUpdateCommandError.cancelled }
        if let error = reply.error { throw NSError(domain: "ApplicationReplacementHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: AppUpdateErrorRedaction.text(error)]) }
    }
    private func exchange(timeout: TimeInterval, _ send: (any FileOperationHelperProtocol, @escaping (Data) -> Void) -> Void) async throws -> Data {
        guard let connection else { throw AuthorizedMoveError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = AppUpdateHelperReplyGate(continuation)
            connection.invalidationHandler = { gate.fail() }; connection.interruptionHandler = { gate.fail() }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in gate.fail() }) as? any FileOperationHelperProtocol else { gate.fail(); return }
            send(proxy) { gate.complete($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { gate.fail() }
        }
    }
    static func boundedRefresh(timeout: TimeInterval = 10, _ operation: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            let gate = AppUpdateHelperReplyGate(continuation)
            let pending = Task { @MainActor in
                do { try await operation(); gate.complete(Data()) } catch { gate.fail(error: error) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { pending.cancel(); gate.fail() }
        }
    }
}

private final class AppUpdateHelperReplyGate: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<Data, any Error>?
    init(_ continuation: CheckedContinuation<Data, any Error>) { self.continuation = continuation }
    func complete(_ data: Data) { lock.withLock { let current = continuation; continuation = nil; return current }?.resume(returning: data) }
    func fail(error: any Error = AuthorizedMoveError.connectionLost) { lock.withLock { let current = continuation; continuation = nil; return current }?.resume(throwing: error) }
}
