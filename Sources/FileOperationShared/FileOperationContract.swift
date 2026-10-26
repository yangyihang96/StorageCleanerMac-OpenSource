import Foundation

public enum FileOperationIdentity {
#if STORAGE_CLEANER_BETA
    public static let application = "com.local.StorageCleanerMac.beta"
#else
    public static let application = "com.local.StorageCleanerMac"
#endif
    public static var helper: String { application + ".FileOperationHelper" }
    public static var authorizationRight: String { helper + ".move-to-trash" }
    public static var systemCacheRight: String { helper + ".clear-system-cache" }
}

public struct AuthorizedFileMove: Codable, Sendable, Equatable {
    public enum Direction: String, Codable, Sendable { case trash, restore }
    public let sessionID: UUID
    public let requestID: UUID
    public let direction: Direction
    public let applicationPath: String
    public let trashPath: String
    public let bundleIdentifier: String
    public let version: String
    public let build: String
    public let device: UInt64
    public let inode: UInt64
    public let birthNanoseconds: Int64?
    public let expiresAt: Date
    public init(sessionID: UUID, direction: Direction, applicationPath: String, trashPath: String,
                bundleIdentifier: String, version: String, build: String, device: UInt64,
                inode: UInt64, birthNanoseconds: Int64?) {
        self.sessionID = sessionID; requestID = UUID(); self.direction = direction
        self.applicationPath = applicationPath; self.trashPath = trashPath
        self.bundleIdentifier = bundleIdentifier; self.version = version; self.build = build
        self.device = device; self.inode = inode; self.birthNanoseconds = birthNanoseconds
        expiresAt = Date().addingTimeInterval(60)
    }
}

public enum AuthorizedFileFailureStage: String, Codable, Sendable {
    case request, importAuthorization, checkAuthorization, commit, fileMove
}

public struct AuthorizedFileReply: Codable, Sendable {
    public let requestID: UUID
    public let destination: String?
    public let errorDomain: String?
    public let errorCode: Int?
    public let failureStage: AuthorizedFileFailureStage?
    public let prepared: Bool?
    public init(requestID: UUID, destination: String? = nil, errorDomain: String? = nil, errorCode: Int? = nil, failureStage: AuthorizedFileFailureStage? = nil, prepared: Bool? = nil) {
        self.requestID = requestID; self.destination = destination
        self.errorDomain = errorDomain; self.errorCode = errorCode; self.failureStage = failureStage; self.prepared = prepared
    }
}

@objc public protocol FileOperationHelperProtocol {
    func prepare(_ request: Data, authorization: Data, reply: @escaping (Data) -> Void)
    func commit(_ request: Data, reply: @escaping (Data) -> Void)
    @objc optional func applicationReplacementCapabilities(reply: @escaping (Data) -> Void)
    @objc optional func prepareApplicationReplacements(_ request: Data, authorization: Data, reply: @escaping (Data) -> Void)
    @objc optional func replaceAuthenticatedApplication(_ request: Data, reply: @escaping (Data) -> Void)
    @objc optional func finishApplicationReplacements(_ sessionID: String, reply: @escaping (Data) -> Void)
    /// D177: the macOS login-item and background-task list, which
    /// `sfltool dumpbtm` shows only after an administrator password. The
    /// helper runs that one fixed command as root and replies with a
    /// `BackgroundTaskInventoryReply`; nothing from the client reaches it.
    @objc optional func backgroundTaskInventory(reply: @escaping (Data) -> Void)
    @objc optional func systemCacheInventory(reply: @escaping (Data) -> Void)
    @objc optional func prepareSystemCacheClear(_ request: Data, authorization: Data, reply: @escaping (Data) -> Void)
    @objc optional func commitSystemCacheClear(_ request: Data, reply: @escaping (Data) -> Void)
}

// NSXPC enforces this requirement for every message (public API, macOS 13+),
// avoiding PID lookups and private audit-token properties.
import CryptoKit
import Security
public enum FileOperationPeerRequirement {
    public static func currentSigner(peerIdentifier: String) -> String? {
        guard [FileOperationIdentity.application, FileOperationIdentity.helper].contains(peerIdentifier) else { return nil }
        var code: SecCode?; var staticCode: SecStaticCode?; var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return expression(identifier: peerIdentifier, leafCertificate: SecCertificateCopyData(leaf) as Data,
                          teamIdentifier: values[kSecCodeInfoTeamIdentifier as String] as? String ?? "")
    }

    /// The requirement text: the peer's identifier, the leaf certificate pin
    /// and (D102 L2) the signer's Team ID. Without a Team ID (Apple's own
    /// system code) that clause is left out. Nil when the identifier or Team ID
    /// holds anything but the characters they are made of, so a quote can
    /// never end a string early, or when Security cannot parse the result.
    /// FanControlPeerRequirement builds the same text for the fan channel.
    public static func expression(identifier: String, leafCertificate: Data, teamIdentifier: String) -> String? {
        guard !identifier.isEmpty,
              identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              teamIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let fingerprint = Insecure.SHA1.hash(data: leafCertificate).map { String(format: "%02x", $0) }.joined()
        var expression = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf = H\"\(fingerprint)\""
        if !teamIdentifier.isEmpty {
            expression += " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess else { return nil }
        return expression
    }
}

public enum FileOperationPathPolicy {
    /// Pure validation shared by the client contract tests and the privileged
    /// worker. The worker obtains home and uid from the authenticated connection.
    public static func permits(_ request: AuthorizedFileMove, home: String, uid: UInt32) -> Bool {
        func lexical(_ value: String) -> Bool {
            value.hasPrefix("/") && value.utf8.count < 1024 && !value.utf8.contains(0)
                && value == URL(fileURLWithPath: value).standardizedFileURL.path
                && !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        }
        let app = URL(fileURLWithPath: request.applicationPath)
        let trash = URL(fileURLWithPath: request.trashPath)
        let bundle = request.bundleIdentifier.lowercased()
        return uid >= 501 && lexical(home) && home != "/"
            && lexical(request.applicationPath) && lexical(request.trashPath)
            && app.pathExtension.lowercased() == "app" && trash.pathExtension.lowercased() == "app"
            && ["/Applications", home + "/Applications"].contains(app.deletingLastPathComponent().path)
            && trash.deletingLastPathComponent().path == home + "/.Trash"
            && !bundle.isEmpty && !bundle.hasPrefix("com.apple.")
            && !bundle.hasPrefix("com.local.storagecleanermac")
            && request.applicationPath != request.trashPath
    }
}

/// Preflight is not proof of actual authorization. A timeout-zero rule cannot
/// be preauthorized. The worker completes authentication through SecurityAgent
/// in the imported reference's user session, never by collecting credentials.
public enum FileOperationAuthorization {
    public static func requestClientRights(using copyRights: (AuthorizationFlags) -> OSStatus) throws {
        try requireSuccess(copyRights([.interactionAllowed, .extendRights, .preAuthorize]))
    }

    public static func checkImportedRights(using copyRights: (AuthorizationFlags) -> OSStatus) throws {
        try requireSuccess(copyRights([.extendRights, .interactionAllowed]))
    }

    private static func requireSuccess(_ status: OSStatus) throws {
        guard status == errAuthorizationSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

/// A one-use approval for this exact operation, not a cache of administrator
/// credentials. Owned by one authenticated XPC connection and cleared on use.
public struct AuthorizedFileCommitGate: Sendable {
    private var pending: AuthorizedFileMove?
    private var deadline = Date.distantPast
    public init() {}
    public var approvalExpiration: Date? { pending == nil ? nil : deadline }
    public mutating func invalidate() { pending = nil }
    public mutating func approve(_ request: AuthorizedFileMove, receivedAt: Date? = nil, now: Date = Date()) throws {
        invalidate()
        // Validate freshness at receipt, before SecurityAgent interaction. Time
        // spent entering credentials must not consume the commit window.
        let received = receivedAt ?? now
        guard received < request.expiresAt, request.expiresAt.timeIntervalSince(received) <= 65,
              now >= received else {
            throw POSIXError(.ESTALE)
        }
        pending = request
        deadline = now.addingTimeInterval(15)
    }
    @discardableResult
    public mutating func consume(_ request: AuthorizedFileMove, now: Date = Date()) throws -> Date {
        defer { invalidate() }
        guard pending == request, now < deadline else { throw POSIXError(.EPERM) }
        return deadline
    }
}
