import Foundation

/// The authenticate-admin rule with reusable credentials disabled. Both ends
/// enforce these properties, so a pre-existing looser right fails closed.
public enum SystemCacheAuthorizationPolicy {
    public static func isPerOperationAdmin(_ definition: [String: Any]) -> Bool {
        definition["class"] as? String == "user" && definition["group"] as? String == "admin"
            && (definition["authenticate-user"] as? NSNumber)?.boolValue == true
            && (definition["shared"] as? NSNumber)?.boolValue == false
            && (definition["timeout"] as? NSNumber)?.doubleValue == 0
    }
}

/// D182: the only system-cache locations. XPC requests carry identifiers only.
public enum SystemCacheID: String, Codable, Sendable, CaseIterable {
    case coreSymbolication, iconServices

    public var directoryPath: String {
        switch self {
        case .coreSymbolication: "/System/Library/Caches/com.apple.coresymbolicationd"
        case .iconServices: "/Library/Caches/com.apple.iconservices.store"
        }
    }
}

public struct SystemCacheDirectoryIdentity: Codable, Sendable, Equatable {
    public let cache: SystemCacheID
    public let device: UInt64
    public let inode: UInt64
    public init(cache: SystemCacheID, device: UInt64, inode: UInt64) {
        self.cache = cache; self.device = device; self.inode = inode
    }
}

public struct SystemCacheInventoryItem: Codable, Sendable, Equatable {
    public let cache: SystemCacheID
    public let allocatedBytes: Int64?
    public let entryCount: Int?
    public let device: UInt64?
    public let inode: UInt64?
    /// Stable reason code, never a system error's text or a path.
    public let failure: String?
    public init(cache: SystemCacheID, allocatedBytes: Int64? = nil, entryCount: Int? = nil,
                device: UInt64? = nil, inode: UInt64? = nil, failure: String? = nil) {
        self.cache = cache; self.allocatedBytes = allocatedBytes; self.entryCount = entryCount
        self.device = device; self.inode = inode; self.failure = failure
    }
    public var identity: SystemCacheDirectoryIdentity? {
        guard let device, let inode else { return nil }
        return .init(cache: cache, device: device, inode: inode)
    }
}

public struct SystemCacheInventoryReply: Codable, Sendable, Equatable {
    public let items: [SystemCacheInventoryItem]
    public init(items: [SystemCacheInventoryItem]) { self.items = items }
}

public struct SystemCacheClearRequest: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let caches: [SystemCacheID]
    public let directories: [SystemCacheDirectoryIdentity]
    public let expiresAt: Date
    public init(requestID: UUID = UUID(), caches: [SystemCacheID],
                directories: [SystemCacheDirectoryIdentity], expiresAt: Date = Date().addingTimeInterval(60)) {
        self.requestID = requestID; self.caches = caches
        self.directories = directories; self.expiresAt = expiresAt
    }
    public var isValid: Bool {
        (1...2).contains(caches.count) && Set(caches).count == caches.count
            && directories.count == caches.count && Set(directories.map(\.cache)) == Set(caches)
            && directories.allSatisfy { $0.inode > 0 } && expiresAt.timeIntervalSince1970.isFinite
    }

    /// JSONDecoder normally ignores extra keys. Reject *all* unrecognised keys,
    /// including path fields at either level, before decoding a privileged request.
    public static let maximumBytes = 4_096
    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["requestID", "caches", "directories", "expiresAt"]),
              let directories = object["directories"] as? [[String: Any]],
              directories.allSatisfy({ Set($0.keys) == Set(["cache", "device", "inode"]) }) else {
            throw SystemCacheFailure.invalidRequest
        }
        let request = try JSONDecoder().decode(Self.self, from: data)
        guard request.isValid else { throw SystemCacheFailure.invalidRequest }
        return request
    }
    public func validateFreshness(receivedAt: Date) throws {
        guard isValid, receivedAt < expiresAt, expiresAt.timeIntervalSince(receivedAt) <= 65 else {
            throw SystemCacheFailure.expired
        }
    }
}

public enum SystemCacheFailure: String, Error, Sendable {
    case invalidRequest, expired, duplicateRequest, approvalRequired, authorization
    case directoryUnavailable, identityChanged, crossDevice, depthLimit, timeLimit, entryLimit, io
}

public struct SystemCacheRemovalResult: Codable, Sendable, Equatable {
    public var deletedEntries: Int = 0
    public var freedBytes: Int64 = 0
    public var skippedEntries: Int = 0
    public var failure: String?
    public init(deletedEntries: Int = 0, freedBytes: Int64 = 0, skippedEntries: Int = 0, failure: String? = nil) {
        self.deletedEntries = deletedEntries; self.freedBytes = freedBytes
        self.skippedEntries = skippedEntries; self.failure = failure
    }
}

public struct SystemCacheClearItem: Codable, Sendable, Equatable {
    public let cache: SystemCacheID
    public let deletedEntries: Int
    public let freedBytes: Int64
    public let skippedEntries: Int
    public let failure: String?
    public init(cache: SystemCacheID, result: SystemCacheRemovalResult) {
        self.cache = cache; deletedEntries = result.deletedEntries; freedBytes = result.freedBytes
        skippedEntries = result.skippedEntries; failure = result.failure
    }
}

public struct SystemCacheClearReply: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let prepared: Bool?
    public let items: [SystemCacheClearItem]
    public let failure: String?
    public init(requestID: UUID, prepared: Bool? = nil, items: [SystemCacheClearItem] = [], failure: String? = nil) {
        self.requestID = requestID; self.prepared = prepared; self.items = items; self.failure = failure
    }
}

/// One connection, one exact request, one use, fifteen seconds after SecurityAgent
/// finishes. Reserving the ID before authentication prevents replay after failure.
public struct SystemCacheCommitGate: Sendable {
    private var seen = Set<UUID>()
    private var pending: SystemCacheClearRequest?
    private var deadline = Date.distantPast
    private var received = Date.distantFuture
    public init() {}
    public var isApproved: Bool { pending != nil && Date() < deadline }
    public var approvalExpiration: Date? { pending == nil ? nil : deadline }
    public mutating func invalidate() { pending = nil; deadline = .distantPast; received = .distantFuture }
    public mutating func reserve(_ request: SystemCacheClearRequest, receivedAt: Date = Date()) throws {
        invalidate()
        try request.validateFreshness(receivedAt: receivedAt)
        guard seen.count < 128, seen.insert(request.requestID).inserted else { throw SystemCacheFailure.duplicateRequest }
        pending = request
        received = receivedAt
    }
    public mutating func approve(_ request: SystemCacheClearRequest, now: Date = Date()) throws {
        guard pending == request, now >= received else { invalidate(); throw SystemCacheFailure.approvalRequired }
        deadline = now.addingTimeInterval(15)
    }
    public mutating func consume(_ request: SystemCacheClearRequest, now: Date = Date()) throws {
        defer { invalidate() }
        guard pending == request, now < deadline, now >= deadline.addingTimeInterval(-15) else {
            throw SystemCacheFailure.approvalRequired
        }
    }
}
