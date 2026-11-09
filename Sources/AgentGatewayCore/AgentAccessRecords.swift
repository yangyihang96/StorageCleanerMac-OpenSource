import AgentShared
import Darwin
import Foundation

/// D268: per client, at most 20 calls a second and 600 a minute.
public struct AgentRateLimiter: Sendable {
    public let perSecond: Int
    public let perMinute: Int
    private var history: [String: [Date]] = [:]

    public init(perSecond: Int = 20, perMinute: Int = 600) {
        self.perSecond = perSecond; self.perMinute = perMinute
    }

    public mutating func admit(_ key: String, at now: Date) -> Bool {
        var times = history[key, default: []].filter { now.timeIntervalSince($0) < 60 }
        let lastSecond = times.reduce(0) { $0 + (now.timeIntervalSince($1) < 1 ? 1 : 0) }
        defer { history[key] = times }
        guard lastSecond < perSecond, times.count < perMinute else { return false }
        times.append(now)
        return true
    }
}

/// D264: one line per call. What was asked and what came back are never
/// written: only who, which tool, its level, and how it ended.
public struct AgentAccessLogEntry: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case allowed
        case refused
        case failed
    }

    public var time: Date
    public var client: String
    public var clientKey: String
    public var tool: String
    public var level: AgentOperationLevel
    public var outcome: Outcome
    public var reason: AgentRefusalReason?
    /// The AI request a proposal created (batch 2 onwards).
    public var requestID: String?

    public init(time: Date, client: String, clientKey: String, tool: String, level: AgentOperationLevel, outcome: Outcome,
                reason: AgentRefusalReason? = nil, requestID: String? = nil) {
        self.time = time; self.client = client; self.clientKey = clientKey; self.tool = tool; self.level = level
        self.outcome = outcome; self.reason = reason; self.requestID = requestID
    }
}

/// D264: JSON Lines in `<data>/Agent/`, readable only by this user, kept for
/// 30 days or 5000 entries. Shown in Settings; no tool reads it.
public final class AgentAccessLog: @unchecked Sendable {
    public static let defaultMaximumEntries = 5_000
    public static let defaultMaximumAge: TimeInterval = 30 * 86_400

    public let fileURL: URL
    private let clock: @Sendable () -> Date
    private let maximumEntries: Int
    private let maximumAge: TimeInterval
    private let trimEvery: Int
    private let lock = NSLock()
    private var appendsSinceTrim = 0

    public init(fileURL: URL, clock: @escaping @Sendable () -> Date = { Date() }, maximumEntries: Int = defaultMaximumEntries,
                maximumAge: TimeInterval = defaultMaximumAge, trimEvery: Int = 500) {
        self.fileURL = fileURL; self.clock = clock; self.maximumEntries = maximumEntries
        self.maximumAge = maximumAge; self.trimEvery = trimEvery
        lock.withLock { trim() }
    }

    public func append(_ entry: AgentAccessLogEntry) {
        lock.withLock {
            guard let line = try? Self.line(entry) else { return }
            let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return }
            _ = Self.writeAll(fd, line)
            close(fd)
            appendsSinceTrim += 1
            if appendsSinceTrim >= trimEvery { trim() }
        }
    }

    /// Oldest first; damaged lines are skipped.
    public func entries() -> [AgentAccessLogEntry] { lock.withLock { read() } }

    private func read() -> [AgentAccessLogEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(AgentAccessLogEntry.self, from: Data($0)) }
    }

    private func trim() {
        appendsSinceTrim = 0
        let all = read()
        let cutoff = clock().addingTimeInterval(-maximumAge)
        let kept = all.filter { $0.time >= cutoff }.suffix(maximumEntries)
        guard kept.count != all.count else { return }
        var data = Data()
        for entry in kept { if let line = try? Self.line(entry) { data.append(line) } }
        // Written next to the log and renamed over it, keeping 0600.
        let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(".access-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let written = Self.writeAll(fd, data)
        close(fd)
        if !written || rename(temporary.path, fileURL.path) != 0 { unlink(temporary.path) }
    }

    private static func line(_ entry: AgentAccessLogEntry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(entry)
        data.append(0x0A)
        return data
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
