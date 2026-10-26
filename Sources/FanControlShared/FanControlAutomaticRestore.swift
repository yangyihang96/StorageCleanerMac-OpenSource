import Foundation

/// D105 (review C-R1, C-R2): the helper returned the fans to system control
/// on its own account (a lease that ran out, thermal protection, a curve that
/// stopped, a fan state it could not verify, the app gone, the helper stopping,
/// or a helper started after one that left the fans under its control), and
/// whether that return completed. The reason alone never says it did. Nothing
/// that names the computer is kept.
public struct FanControlAutomaticRestore: Codable, Equatable, Identifiable, Sendable {
    public enum Reason: String, Codable, CaseIterable, Sendable {
        case fanLeaseExpired
        case curveLeaseExpired
        case thermalProtectionActivated
        case curveFailed
        case fanVerificationFailed
        case appDisconnected
        case helperStopping
        case startupRecovery
        /// A reason a newer helper gave that this build does not know.
        case other

        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
        }
    }

    public let id: UUID
    public let occurredAt: Date
    public let reason: Reason
    /// The helper's request to return every fan to system control completed.
    public let restored: Bool

    public init(id: UUID = UUID(), occurredAt: Date, reason: Reason, restored: Bool) {
        self.id = id
        self.occurredAt = occurredAt
        self.reason = reason
        self.restored = restored
    }

    /// The helper's own return: `restore` hands every fan back to system
    /// control first, and only then is its actual result kept, when there was
    /// control to give back. Keeping it never delays or replaces the return.
    @discardableResult
    public static func perform(
        _ reason: Reason,
        hadControl: Bool,
        restore: () -> Bool,
        keep: (Reason, Bool) -> Void
    ) -> Bool {
        let restored = restore()
        if hadControl { keep(reason, restored) }
        return restored
    }
}

/// The helper's own list of those returns, oldest first and at most
/// `retainedLimit`. A return the helper keeps retrying for the same reason
/// stays one failed entry until a return completes. The root helper keeps the list under /var/run,
/// never in a user's folders, and puts it on its replies; the app records
/// each return once, by its ID.
public struct FanControlAutomaticRestoreLog: Codable, Equatable, Sendable {
    public static let retainedLimit = 16
    public static let maximumEncodedBytes = 8_192

    public private(set) var restores: [FanControlAutomaticRestore]

    public init(restores: [FanControlAutomaticRestore] = []) {
        self.restores = Array(restores.suffix(Self.retainedLimit))
    }

    /// Keeps the result of a return the helper has just made.
    @discardableResult
    public mutating func record(
        _ reason: FanControlAutomaticRestore.Reason,
        restored: Bool,
        at date: Date = Date(),
        id: UUID = UUID()
    ) -> FanControlAutomaticRestore {
        if !restored, let last = restores.last, !last.restored, last.reason == reason { return last }
        let restore = FanControlAutomaticRestore(id: id, occurredAt: date, reason: reason, restored: restored)
        restores.append(restore)
        if restores.count > Self.retainedLimit {
            restores.removeFirst(restores.count - Self.retainedLimit)
        }
        return restore
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Nil for anything the helper would not have written: over the size
    /// limit, not decodable, more than `retainedLimit` entries, or a time that
    /// is not finite.
    public static func decoded(_ data: Data) -> FanControlAutomaticRestoreLog? {
        guard data.count <= maximumEncodedBytes,
              let log = try? JSONDecoder().decode(Self.self, from: data),
              log.restores.count <= retainedLimit,
              log.restores.allSatisfy({ $0.occurredAt.timeIntervalSinceReferenceDate.isFinite }) else {
            return nil
        }
        return log
    }
}

/// The helper's copy of that list in one root-owned file (the helper keeps it
/// under /var/run, beside its crash-recovery marker; never in a user's
/// folders), so a helper started again still reports what an earlier one did.
/// Reading refuses anything but a regular file within the size limit; a write
/// that fails is logged and the list is still reported from memory.
public final class FanControlAutomaticRestoreJournal: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var log: FanControlAutomaticRestoreLog

    public init(url: URL) {
        self.url = url
        log = Self.load(url) ?? FanControlAutomaticRestoreLog()
    }

    public var restores: [FanControlAutomaticRestore] { lock.withLock { log.restores } }

    public func record(_ reason: FanControlAutomaticRestore.Reason, restored: Bool, at date: Date = Date()) {
        lock.withLock {
            log.record(reason, restored: restored, at: date)
            do {
                try log.encoded().write(to: url, options: [.atomic])
            } catch {
                NSLog("Could not keep the automatic fan restore: %@", error.localizedDescription)
            }
        }
    }

    private static func load(_ url: URL) -> FanControlAutomaticRestoreLog? {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size <= off_t(FanControlAutomaticRestoreLog.maximumEncodedBytes),
              let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return FanControlAutomaticRestoreLog.decoded(data)
    }
}
