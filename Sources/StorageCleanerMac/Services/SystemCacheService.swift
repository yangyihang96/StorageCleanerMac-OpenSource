import Darwin
import FileOperationShared
import Foundation
import Security

@MainActor
protocol SystemCacheServicing {
    func inventory() async -> SystemCacheInventoryReply?
    func clear(_ directories: [SystemCacheDirectoryIdentity]) async throws -> SystemCacheClearReply
}

enum SystemCacheServiceError: Error, LocalizedError {
    case unavailable, identityChanged, authorization, incomplete, outcomeUnknown
    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.text("系统缓存助手不可用，请稍后重试。", "The system cache helper is unavailable. Try again later.")
        case .identityChanged: L10n.text("缓存文件夹已变化，请重新扫描后再清除。", "A cache folder changed. Scan again before clearing it.")
        case .authorization: L10n.text("未完成管理员授权，系统缓存未清除。", "Administrator authorization was not completed. System caches were not cleared.")
        case .incomplete: L10n.text("助手未批准这次系统缓存清除。", "The helper did not approve this system cache clear.")
        case .outcomeUnknown: L10n.text("清除连接中断，结果待核实。重新打开应用后再扫描；在此之前暂停其他清理。",
                                       "The clear connection was lost and its result needs verification. Reopen the app and scan again; other cleanup is paused until then.")
        }
    }
}

/// D182: inventory is silent. Only clear(), called after the confirmation,
/// may register the daemon or ask SecurityAgent for administrator authorization.
@MainActor
final class SystemCacheService: SystemCacheServicing {
    private let coordinator: HeavyWorkCoordinator
    init(coordinator: HeavyWorkCoordinator) { self.coordinator = coordinator }

    /// Like D177's login-item read: a registered helper is started on demand by
    /// launchd without any dialog; an unregistered one, or another build, fails
    /// quietly. (Integration: Codex's running-PID gate hid the caches whenever
    /// the idle helper had not been started, as on the 10-23 beta.)
    func inventory() async -> SystemCacheInventoryReply? {
        guard Bundle.main.url(forResource: "StorageCleanerFileOperationHelper", withExtension: nil) != nil else { return nil }
        do {
            let data = try await FileOperationReadRetry.perform {
                let connection = try self.connect()
                defer { connection.invalidate() }
                try await self.checkBuild(connection)
                return try await Self.exchange(connection, timeout: 35) { proxy, reply in
                    proxy.systemCacheInventory?(reply: reply)
                }
            }
            let result = try JSONDecoder().decode(SystemCacheInventoryReply.self, from: data)
            guard Self.validInventory(result), result.items.contains(where: { $0.allocatedBytes != nil }) else { return nil }
            return result
        } catch { return nil }
    }

    func clear(_ directories: [SystemCacheDirectoryIdentity]) async throws -> SystemCacheClearReply {
        let validation = SystemCacheClearRequest(caches: directories.map(\.cache), directories: directories)
        guard validation.isValid else { throw SystemCacheServiceError.incomplete }
        // Reuse cleanup's exclusive process lease and quarantine behaviour.
        let lease = try await coordinator.acquire(owner: .cleanup)
        var submitted = false
        do {
            try Task.checkCancellation()
            guard let bundled = Bundle.main.url(forResource: "StorageCleanerFileOperationHelper", withExtension: nil),
                  AuthorizedApplicationMover.shared.trustedBundledHelper(bundled) else { throw SystemCacheServiceError.unavailable }
            try await AuthorizedApplicationMover.shared.prepareHelper()
            try await coordinator.requireValid(lease, owner: .cleanup)
            try Task.checkCancellation()
            let worker = Task.detached(priority: .userInitiated) { try Self.authorize() }
            let authorization = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            defer { authorization.destroy() }
            try Task.checkCancellation()
            let connection = try await verifiedConnection()
            defer { connection.invalidate() }
            let request = SystemCacheClearRequest(caches: directories.map(\.cache), directories: directories)
            let data = try JSONEncoder().encode(request)
            let preparedData = try await Self.exchange(connection, timeout: 180) { proxy, reply in
                proxy.prepareSystemCacheClear?(data, authorization: authorization.form, reply: reply)
            }
            let prepared = try JSONDecoder().decode(SystemCacheClearReply.self, from: preparedData)
            guard prepared.requestID == request.requestID, prepared.prepared == true, prepared.failure == nil,
                  prepared.items.isEmpty else { throw SystemCacheServiceError.authorization }
            try Task.checkCancellation()
            try await coordinator.requireValid(lease, owner: .cleanup)
            // On this connection the approved helper returns just freshly opened
            // directory identities, avoiding a full size scan in the commit window.
            let currentData = try await Self.exchange(connection, timeout: 5) { proxy, reply in
                proxy.systemCacheInventory?(reply: reply)
            }
            let current = try JSONDecoder().decode(SystemCacheInventoryReply.self, from: currentData)
            guard Self.validInventory(current), directories.allSatisfy({ expected in
                current.items.contains { $0.identity == expected && $0.failure == nil }
            }) else { throw SystemCacheServiceError.identityChanged }
            try Task.checkCancellation()
            try await coordinator.requireValid(lease, owner: .cleanup)
            // Once submitted, cancellation cannot release the lease ahead of the
            // root worker. An unknown outcome leaves the existing quarantine set.
            submitted = true
            let response = try await Self.exchange(connection, timeout: 260) { proxy, reply in
                proxy.commitSystemCacheClear?(data, reply: reply)
            }
            let result = try JSONDecoder().decode(SystemCacheClearReply.self, from: response)
            guard result.requestID == request.requestID, result.prepared == nil,
                  (result.failure != nil && result.items.isEmpty) || (
                    result.items.count == directories.count && Set(result.items.map(\.cache)) == Set(directories.map(\.cache))
                    && result.items.allSatisfy { $0.deletedEntries >= 0 && $0.freedBytes >= 0 && $0.skippedEntries >= 0 }
                  ) else { throw SystemCacheServiceError.outcomeUnknown }
            submitted = false
            await coordinator.release(lease)
            if result.failure != nil { throw SystemCacheServiceError.incomplete }
            return result
        } catch {
            if submitted {
                _ = try await coordinator.beginCleanupQuarantine(lease)
                await coordinator.release(lease)
                throw SystemCacheServiceError.outcomeUnknown
            }
            await coordinator.release(lease)
            if error is FileOperationReadRetry.TransportFailure { throw SystemCacheServiceError.unavailable }
            throw error
        }
    }

    private func connect() throws -> NSXPCConnection {
        guard let requirement = FileOperationPeerRequirement.currentSigner(peerIdentifier: FileOperationIdentity.helper) else {
            throw SystemCacheServiceError.unavailable
        }
        let connection = NSXPCConnection(machServiceName: FileOperationIdentity.helper, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: FileOperationHelperProtocol.self)
        connection.resume()
        return connection
    }
    /// Still read-only: before prepare, a failed capability probe can move to
    /// a fresh helper. Once prepare starts, the connection is never replayed.
    private func verifiedConnection() async throws -> NSXPCConnection {
        try await FileOperationReadRetry.perform {
            let connection = try self.connect()
            do {
                try await self.checkBuild(connection)
                return connection
            } catch {
                connection.invalidate()
                throw error
            }
        }
    }
    private func checkBuild(_ connection: NSXPCConnection) async throws {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard !build.isEmpty else { throw SystemCacheServiceError.unavailable }
        let data = try await Self.exchange(connection, timeout: 2) { proxy, reply in
            proxy.applicationReplacementCapabilities?(reply: reply)
        }
        guard (try? JSONDecoder().decode(ApplicationReplacementCapabilities.self, from: data))?.build == build else {
            throw SystemCacheServiceError.unavailable
        }
    }
    private static func validInventory(_ result: SystemCacheInventoryReply) -> Bool {
        result.items.count == 2 && Set(result.items.map(\.cache)) == Set(SystemCacheID.allCases)
            && result.items.allSatisfy { ($0.allocatedBytes ?? 0) >= 0 && ($0.entryCount ?? 0) >= 0 }
    }

    nonisolated private static func authorize() throws -> SystemCacheAuthorization {
        var reference: AuthorizationRef?
        let created = AuthorizationCreate(nil, nil, [], &reference)
        guard created == errAuthorizationSuccess, let reference else { throw SystemCacheServiceError.authorization }
        do {
            try FileOperationAuthorization.requestClientRights { flags in
                FileOperationIdentity.systemCacheRight.withCString { name in
                    var definition: CFDictionary?
                    if AuthorizationRightGet(name, &definition) != errAuthorizationSuccess {
                        var adminRule: CFDictionary?
                        guard AuthorizationRightGet(kAuthorizationRuleAuthenticateAsAdmin, &adminRule) == errAuthorizationSuccess,
                              var rule = adminRule as? [String: Any] else { return errAuthorizationDenied }
                        rule["timeout"] = 0
                        rule["shared"] = false
                        guard SystemCacheAuthorizationPolicy.isPerOperationAdmin(rule) else { return errAuthorizationDenied }
                        let status = AuthorizationRightSet(reference, name, rule as CFDictionary,
                            L10n.text("清除所选系统缓存", "Clear selected system caches") as CFString, nil, nil)
                        guard status == errAuthorizationSuccess else { return status }
                    }
                    guard AuthorizationRightGet(name, &definition) == errAuthorizationSuccess,
                          let rule = definition as? [String: Any], SystemCacheAuthorizationPolicy.isPerOperationAdmin(rule) else {
                        return errAuthorizationDenied
                    }
                    var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                    return withUnsafeMutablePointer(to: &item) { pointer in
                        var rights = AuthorizationRights(count: 1, items: pointer)
                        return AuthorizationCopyRights(reference, &rights, nil, flags, nil)
                    }
                }
            }
            try Task.checkCancellation()
            var form = AuthorizationExternalForm()
            guard AuthorizationMakeExternalForm(reference, &form) == errAuthorizationSuccess else {
                throw SystemCacheServiceError.authorization
            }
            return SystemCacheAuthorization(reference: reference, form: withUnsafeBytes(of: form) { Data($0) })
        } catch { AuthorizationFree(reference, [.destroyRights]); throw error }
    }

    private static func exchange(_ connection: NSXPCConnection, timeout: TimeInterval,
        _ send: (any FileOperationHelperProtocol, @escaping @Sendable (Data) -> Void) -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = SystemCacheReplyGate(continuation)
            // D192 hotfix (10-24, beta #10 crashed in a junk scan): XPC calls
            // these on its own queue. Without @Sendable they inherited this
            // type's main-actor isolation and the runtime check trapped
            // whenever the helper connection failed.
            connection.invalidationHandler = { @Sendable in gate.fail() }
            connection.interruptionHandler = { @Sendable in gate.fail() }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in gate.fail() }) as? any FileOperationHelperProtocol else {
                gate.fail(); return
            }
            send(proxy) { gate.complete(.success($0)) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { gate.fail() }
        }
    }
}

private final class SystemCacheAuthorization: @unchecked Sendable {
    let reference: AuthorizationRef
    let form: Data
    init(reference: AuthorizationRef, form: Data) { self.reference = reference; self.form = form }
    func destroy() { AuthorizationFree(reference, [.destroyRights]) }
}
private final class SystemCacheReplyGate: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<Data, any Error>?
    init(_ continuation: CheckedContinuation<Data, any Error>) { self.continuation = continuation }
    func fail() { complete(.failure(FileOperationReadRetry.TransportFailure.noReply)) }
    func complete(_ result: Result<Data, any Error>) {
        let target = lock.withLock { let value = continuation; continuation = nil; return value }
        target?.resume(with: result)
    }
}
