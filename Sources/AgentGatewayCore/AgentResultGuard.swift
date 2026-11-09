import AgentShared
import Foundation

public struct AgentResultViolation: Error, Equatable, Sendable {
    public let path: String
    public let problem: String
}

/// D266: the last check before a result leaves the App. Builders follow the
/// rules themselves; this rewrites the home folder wherever it still appears
/// and refuses a result that carries an identifying or content field at all,
/// so a builder's mistake becomes an error rather than a leak.
public struct AgentResultGuard: Sendable {
    /// Compared lowercased, without `_` and `-`, so every spelling counts.
    static let bannedFields: Set<String> = [
        "serial", "serialnumber", "hardwareuuid", "platformuuid", "udid", "computername", "hostname", "localhostname",
        "username", "fullname", "ip", "ipaddress", "ipv4", "ipv6", "macaddress", "ssid", "bssid", "wifiname",
        "commandline", "cmdline", "argv", "arguments", "environment",
        "content", "contents", "filecontent", "filecontents",
        "cookie", "cookies", "password", "passcode", "token", "secret", "apikey", "credential", "credentials"
    ]

    private let home: String

    public init(home: String) { self.home = home }

    public static func forCurrentUser() -> Self { .init(home: AgentDataLocation.currentUserHome()?.path ?? NSHomeDirectory()) }

    public func cleaned(_ result: AgentJSONValue) throws(AgentResultViolation) -> AgentJSONValue {
        guard case .object = result else { throw AgentResultViolation(path: "", problem: "must be an object") }
        if let items = result["items"]?.arrayValue, items.count > Int(AgentToolCatalog.pageLimit) {
            throw AgentResultViolation(path: "items", problem: "holds more than \(AgentToolCatalog.pageLimit) items")
        }
        return try clean(result, at: "")
    }

    private func clean(_ value: AgentJSONValue, at path: String) throws(AgentResultViolation) -> AgentJSONValue {
        switch value {
        case .string(let text):
            return .string(tilde(text))
        case .array(let items):
            var cleaned: [AgentJSONValue] = []
            cleaned.reserveCapacity(items.count)
            for (index, item) in items.enumerated() { cleaned.append(try clean(item, at: "\(path)[\(index)]")) }
            return .array(cleaned)
        case .object(let fields):
            var cleaned: [String: AgentJSONValue] = [:]
            for (name, field) in fields {
                let location = path.isEmpty ? name : path + "." + name
                let normalized = name.lowercased().filter { $0 != "_" && $0 != "-" }
                guard !Self.bannedFields.contains(normalized) else {
                    throw AgentResultViolation(path: location, problem: "is a field D266 never lets out")
                }
                // The App's own IDs can be paths; an AI gets tokens (AgentItemTokens).
                if normalized.hasSuffix("id"), field.stringValue?.contains("/") == true {
                    throw AgentResultViolation(path: location, problem: "is an ID that holds a path")
                }
                cleaned[name] = try clean(field, at: location)
            }
            return .object(cleaned)
        case .null, .bool, .integer, .number:
            return value
        }
    }

    /// Only the whole folder name: home `/Users/ann` does not cover `/Users/annie`.
    private func tilde(_ text: String) -> String {
        guard !home.isEmpty, text.contains(home) else { return text }
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: home) {
            result += rest[..<range.lowerBound]
            let after = rest[range.upperBound...]
            if let next = after.first, next.isLetter || next.isNumber || next == "_" || next == "-" || next == "." {
                result += rest[range]
            } else {
                result += "~"
            }
            rest = after
        }
        return result + rest
    }
}

/// D266 paging for every list tool. A cursor names the result set it came
/// from, so a new scan makes old cursors fail instead of silently skipping
/// or repeating items.
public struct AgentPage: Equatable, Sendable {
    public static let defaultLimit = 50

    public let items: [AgentJSONValue]
    public let nextCursor: String?
    public let totalCount: Int

    /// Which items a page holds, so a caller can build only those.
    public struct Window: Equatable, Sendable {
        public let range: Range<Int>
        public let nextCursor: String?
    }

    /// `arguments` holds the tool's optional `cursor` and `limit`; `generation`
    /// is whatever changes when the results do (a scan's end time, say).
    public static func window(count: Int, arguments: [String: AgentJSONValue], generation: String) throws(AgentRefusal) -> Window {
        var start = 0
        if let cursor = arguments["cursor"]?.stringValue {
            guard let colon = cursor.lastIndex(of: ":"), cursor[..<colon] == generation,
                  let offset = Int(cursor[cursor.index(after: colon)...]), offset >= 0, offset < count else {
                throw AgentRefusal(.invalidArguments, "这个游标已经失效，结果可能更新过了。请从第一页重新读取。")
            }
            start = offset
        }
        let limit = max(1, min(arguments["limit"]?.integerValue.map(Int.init) ?? defaultLimit, Int(AgentToolCatalog.pageLimit)))
        let end = min(start + limit, count)
        return Window(range: start..<end, nextCursor: end < count ? "\(generation):\(end)" : nil)
    }

    public init(_ all: [AgentJSONValue], arguments: [String: AgentJSONValue], generation: String) throws(AgentRefusal) {
        let window = try Self.window(count: all.count, arguments: arguments, generation: generation)
        items = Array(all[window.range])
        nextCursor = window.nextCursor
        totalCount = all.count
    }

    /// The fields the list tools' output schemas share.
    public var fields: [String: AgentJSONValue] {
        ["items": .array(items), "next_cursor": nextCursor.map(AgentJSONValue.string) ?? .null, "total_count": .integer(Int64(totalCount))]
    }
}
