import AppKit
import FileOperationShared
import Foundation
import Security
import ServiceManagement

enum AuthorizedMoveError: LocalizedError {
    case approvalRequired, unavailable, connectionLost, authorizationConnectionLost
    var errorDescription: String? {
        switch self {
        case .approvalRequired: L10n.text("请在系统设置的登录项与扩展中批准文件操作辅助程序，再重试。", "Approve the file-operation helper in Login Items & Extensions, then retry.")
        case .unavailable: L10n.text("此构建的文件操作辅助程序不可用；文件保持原位。", "This build's file-operation helper is unavailable; files remain in place.")
        case .authorizationConnectionLost: L10n.text("授权连接中断，尚未提交文件移动。", "Authorization disconnected before the file move was submitted.")
        case .connectionLost: L10n.text("辅助程序连接中断，移动结果待核实；已阻止后续清理。", "The helper disconnected. The move is unconfirmed; further cleanup is blocked.")
        }
    }
}

@MainActor final class AuthorizedApplicationMover {
    static let shared = AuthorizedApplicationMover()
    private let service = SMAppService.daemon(plistName: FileOperationIdentity.helper + ".plist")

    func move(app: InstalledAppItem, identity: FileIdentity, sessionID: UUID,
              direction: AuthorizedFileMove.Direction = .trash, existingTrash: URL? = nil,
              beforeMove: @escaping @Sendable () async throws -> Void) async throws -> URL {
        guard let helper = Bundle.main.url(forResource: "StorageCleanerFileOperationHelper", withExtension: nil),
              trustedBundledHelper(helper) else { throw AuthorizedMoveError.unavailable }
        // The coordinator owns the cleanup lease before any registration. Never
        // replace a worker during an in-flight or quarantined operation.
        try Task.checkCancellation()
        try await beforeMove()
        try await prepareHelper()
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { try Self.authorize() }
        let authorization = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        defer { authorization.destroy() }
        try Task.checkCancellation()
        try await beforeMove()
        let source = direction == .trash ? URL(fileURLWithPath: app.path) : existingTrash
        guard let source else { throw CleanupMoveError.invalidResult }
        let current = try FoundationReadOnlyFileSystem().snapshot(at: source)
        guard current.identity == identity, !current.hasSymbolicLinkComponent else {
            throw AppUninstallError.identityChanged(source.path)
        }
        // Built after authorization: the request's expiry window starts now.
        let request = Self.request(for: app, identity: identity, sessionID: sessionID,
                                   direction: direction, existingTrash: existingTrash)
        let trash = URL(fileURLWithPath: request.trashPath)
        let data = try JSONEncoder().encode(request)
        guard let requirement = FileOperationPeerRequirement.currentSigner(peerIdentifier: FileOperationIdentity.helper) else {
            throw AuthorizedMoveError.unavailable
        }
        let connection = NSXPCConnection(machServiceName: FileOperationIdentity.helper, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: FileOperationHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let preparedData: Data
        do { preparedData = try await exchange(data, authorization: authorization.form, connection: connection) }
        catch { throw AuthorizedMoveError.authorizationConnectionLost }
        guard let prepared = try? JSONDecoder().decode(AuthorizedFileReply.self, from: preparedData),
              prepared.requestID == request.requestID else { throw AuthorizedMoveError.authorizationConnectionLost }
        guard prepared.prepared == true, prepared.destination == nil, prepared.errorDomain == nil else {
            throw helperError(prepared)
        }
        // The helper has authenticated, but cannot move without this second
        // message. Cancellation/lease/identity checks run AFTER the system UI.
        try Task.checkCancellation()
        try await beforeMove()
        let final = try FoundationReadOnlyFileSystem().snapshot(at: source)
        guard final.identity == identity, !final.hasSymbolicLinkComponent else {
            throw AppUninstallError.identityChanged(source.path)
        }
        try Task.checkCancellation()
        let response = try await exchange(data, authorization: nil, connection: connection)
        guard let reply = try? JSONDecoder().decode(AuthorizedFileReply.self, from: response),
              reply.requestID == request.requestID else { throw AuthorizedMoveError.connectionLost }
        if let destination = reply.destination {
            let expected = direction == .trash ? trash.path : app.path
            guard destination == expected else { throw AuthorizedMoveError.connectionLost }
            return URL(fileURLWithPath: destination)
        }
        throw helperError(reply)
    }

    /// The exact request the helper receives. One builder, so the client's
    /// eligibility check and the actual move cannot disagree on paths.
    nonisolated static func request(for app: InstalledAppItem, identity: FileIdentity, sessionID: UUID,
                                    direction: AuthorizedFileMove.Direction = .trash, existingTrash: URL? = nil,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AuthorizedFileMove {
        let trash = existingTrash ?? home.appendingPathComponent(".Trash", isDirectory: true)
            .appendingPathComponent(URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent
                + "-" + sessionID.uuidString + ".app")
        return AuthorizedFileMove(sessionID: sessionID, direction: direction,
            applicationPath: app.path, trashPath: trash.path, bundleIdentifier: app.bundleIdentifier,
            version: app.version, build: app.build, device: identity.deviceID, inode: identity.inode,
            birthNanoseconds: identity.creationTimeNanoseconds)
    }

    /// The helper's own path policy, evaluated with the helper's view of this
    /// user (uid and the account's home). The helper accepts only direct
    /// children of /Applications and ~/Applications, so a nested app such as
    /// /Applications/Utilities/X.app must never earn a password prompt.
    nonisolated static func helperAccepts(_ request: AuthorizedFileMove) -> Bool {
        let uid = getuid()
        guard let user = getpwuid(uid) else { return false }
        return FileOperationPathPolicy.permits(request, home: String(cString: user.pointee.pw_dir), uid: uid)
    }

    /// Why the helper would refuse, without restating its rules: when the same
    /// request passes with a neutral identifier, the bundle identifier (Apple,
    /// this app, or none) was the reason; otherwise the location was.
    nonisolated static func helperVerdict(_ request: AuthorizedFileMove) -> UninstallHelperVerdict {
        guard !helperAccepts(request) else { return .accepts }
        let probe = AuthorizedFileMove(sessionID: request.sessionID, direction: request.direction,
            applicationPath: request.applicationPath, trashPath: request.trashPath,
            bundleIdentifier: "org.storagecleaner.policy-probe", version: request.version, build: request.build,
            device: request.device, inode: request.inode, birthNanoseconds: request.birthNanoseconds)
        return helperAccepts(probe) ? .rejectsBundle : .rejectsLocation
    }

    private func helperError(_ reply: AuthorizedFileReply) -> NSError {
        let underlying = NSError(domain: reply.errorDomain ?? "FileOperationHelper", code: reply.errorCode ?? -1)
        return NSError(domain: "FileOperationHelper." + (reply.failureStage?.rawValue ?? "unknownStage"), code: 1,
                       userInfo: [NSUnderlyingErrorKey: underlying])
    }

    private func exchange(_ data: Data, authorization: Data?, connection: NSXPCConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let completion = FileMoveReplyGate(connection: connection, continuation: continuation)
            // D192 hotfix: XPC runs these and the replies on its own queue;
            // @Sendable keeps them off this class's main-actor isolation,
            // whose runtime check traps there (beta #10, SystemCacheService).
            connection.invalidationHandler = { @Sendable in completion.fail() }
            connection.interruptionHandler = { @Sendable in completion.fail() }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in completion.fail() }) as? FileOperationHelperProtocol else {
                completion.fail(); return
            }
            if let authorization { proxy.prepare(data, authorization: authorization) { @Sendable reply in completion.finish(reply) } }
            else { proxy.commit(data) { @Sendable reply in completion.finish(reply) } }
        }
    }

    func prepareHelper(forceRefresh: Bool = false, refreshRegisteredBuild: Bool = true) async throws {
        // D106: registering the helper and the password prompt that follows
        // are system UI on the menu-bar display; an acceptance session refuses
        // them before anything is registered.
        guard DisplayConfinementGate.shared.permitsExternal("FileOperationHelper", detail: "register and authorize") else {
            throw AuthorizedMoveError.unavailable
        }
        // Replacing the app bundle alone does not replace a running daemon.
        // Refresh only when a user-confirmed operation needs this helper, never
        // during scanning, startup, or previews. Beta/formal use separate keys.
        let key = FileOperationIdentity.helper + ".registeredBuild"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard !build.isEmpty else { throw AuthorizedMoveError.unavailable }
        do {
            var refreshed = false
            if refreshRegisteredBuild && service.status == .enabled && (forceRefresh || UserDefaults.standard.string(forKey: key) != build) {
                try await service.unregister()
                refreshed = true
                UserDefaults.standard.removeObject(forKey: key)
                try Task.checkCancellation()
            }
            if service.status == .notRegistered || service.status == .notFound {
                do { try service.register() }
                catch {
                    // BTM can briefly reject registration even after the async
                    // bootout callback. Retry once only for this observed race.
                    let failure = error as NSError
                    guard refreshed, failure.domain == "SMAppServiceErrorDomain", failure.code == 1,
                          service.status == .notRegistered || service.status == .notFound else { throw error }
                    try await Task.sleep(for: .milliseconds(500))
                    try service.register()
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw NSError(domain: "UninstallAuthorization.helper-registration", code: 1,
                          userInfo: [NSUnderlyingErrorKey: error])
        }
        guard service.status == .enabled else { throw AuthorizedMoveError.approvalRequired }
        if refreshRegisteredBuild { UserDefaults.standard.set(build, forKey: key) }
    }

    func restore(_ receipt: CleanupMoveReceipt, beforeMove: @escaping @Sendable () async throws -> Void) async throws {
        guard let identity = receipt.movedIdentity, receipt.isRestorable else { throw CleanupMoveError.invalidResult }
        let source = receipt.resultingItemURL
        guard !PathSafety.containsSymbolicLinkComponent(in: source.path),
              let info = NSDictionary(contentsOf: source.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else { throw CleanupMoveError.invalidResult }
        let app = InstalledAppItem(id: receipt.originalPath, name: source.lastPathComponent,
            bundleIdentifier: bundleID, path: receipt.originalPath,
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? "", category: "", appDescription: "",
            sizeBytes: 0, source: "recovery", modifiedAt: nil, scanIdentity: identity,
            relatedPaths: [], relatedItems: [], status: .installed)
        _ = try await move(app: app, identity: identity, sessionID: UUID(), direction: .restore,
            existingTrash: source, beforeMove: beforeMove)
    }

    // D182 reuses this verifier before cache clearing can register the helper.
    func trustedBundledHelper(_ url: URL) -> Bool {
        func certificate(_ url: URL, identifier: String) -> [SecCertificate]? {
            var code: SecStaticCode?; var info: CFDictionary?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
                  SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let values = info as? [String: Any],
                  values[kSecCodeInfoIdentifier as String] as? String == identifier,
                  let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate], !certificates.isEmpty else { return nil }
            return certificates
        }
        guard let app = certificate(Bundle.main.bundleURL, identifier: FileOperationIdentity.application),
              let helper = certificate(url, identifier: FileOperationIdentity.helper) else { return false }
        return app == helper
    }

    nonisolated private static func authorize() throws -> FileMoveAuthorization {
        var reference: AuthorizationRef?
        let created = AuthorizationCreate(nil, nil, [], &reference)
        guard created == errAuthorizationSuccess, let reference else {
            throw NSError(domain: NSOSStatusErrorDomain,
                          code: Int(created == errAuthorizationSuccess ? errAuthorizationInvalidRef : created))
        }
        do {
            try FileOperationAuthorization.requestClientRights { flags in
                FileOperationIdentity.authorizationRight.withCString { name in
                    var definition: CFDictionary?
                    if AuthorizationRightGet(name, &definition) != errAuthorizationSuccess {
                        let created = AuthorizationRightSet(reference, name, kAuthorizationRuleAuthenticateAsAdmin as CFString,
                            "Move the selected application between its original location and Trash" as CFString, nil, nil)
                        guard created == errAuthorizationSuccess else { return created }
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
            let exported = AuthorizationMakeExternalForm(reference, &form)
            guard exported == errAuthorizationSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(exported)) }
            return FileMoveAuthorization(reference: reference, form: withUnsafeBytes(of: form) { Data($0) })
        } catch { AuthorizationFree(reference, [.destroyRights]); throw error }
    }
}

private final class FileMoveAuthorization: @unchecked Sendable {
    let reference: AuthorizationRef
    let form: Data
    init(reference: AuthorizationRef, form: Data) { self.reference = reference; self.form = form }
    func destroy() { AuthorizationFree(reference, [.destroyRights]) }
}

private final class FileMoveReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private let connection: NSXPCConnection
    init(connection: NSXPCConnection, continuation: CheckedContinuation<Data, Error>) {
        self.connection = connection; self.continuation = continuation
    }
    func finish(_ data: Data) { complete(.success(data)) }
    func fail() { complete(.failure(AuthorizedMoveError.connectionLost)) }
    private func complete(_ result: Result<Data, Error>) {
        let target = lock.withLock { let value = continuation; continuation = nil; return value }
        guard let target else { return }
        connection.invalidationHandler = nil; connection.interruptionHandler = nil
        target.resume(with: result)
    }
}
