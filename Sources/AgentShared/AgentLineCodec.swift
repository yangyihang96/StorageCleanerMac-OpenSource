import Foundation

/// One JSON message per line, the MCP stdio framing (2026-07-28 stdio page:
/// "works unchanged over Unix domain sockets"). Used on stdio and on the
/// private socket; the socket carries this project's own messages, not MCP.
public enum AgentLineCodec {
    public enum Failure: Error, Equatable, Sendable { case embeddedNewline }

    /// Sorted keys keep the output stable for tests and logs; slashes stay
    /// readable because results carry `~/…` paths (D266).
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        // JSONEncoder escapes control characters and is not pretty-printing,
        // so a raw newline here would split one message into two.
        guard !data.contains(0x0A) else { throw Failure.embeddedNewline }
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: some DataProtocol) throws -> T {
        try JSONDecoder().decode(type, from: Data(line))
    }
}

public enum AgentLine: Equatable, Sendable {
    case line(Data)
    /// A line passed the limit; the rest of it up to the next newline is dropped.
    case overlong
}

/// Splits a byte stream into lines without ever holding more than one line
/// over the limit in memory. Blank lines are skipped; a trailing CR is removed.
public struct AgentLineBuffer: Sendable {
    public let maximumLineLength: Int
    private var pending = Data()
    private var discarding = false

    public init(maximumLineLength: Int) { self.maximumLineLength = maximumLineLength }

    public mutating func append(_ bytes: Data) -> [AgentLine] {
        var lines: [AgentLine] = []
        var start = bytes.startIndex
        while let newline = bytes[start...].firstIndex(of: 0x0A) {
            let chunk = bytes[start..<newline]
            if discarding {
                discarding = false
            } else if pending.count + chunk.count > maximumLineLength {
                lines.append(.overlong)
            } else {
                pending.append(contentsOf: chunk)
                if let line = Self.complete(pending) { lines.append(line) }
            }
            pending.removeAll(keepingCapacity: true)
            start = bytes.index(after: newline)
        }
        let rest = bytes[start...]
        guard !rest.isEmpty, !discarding else { return lines }
        if pending.count + rest.count > maximumLineLength {
            lines.append(.overlong)
            discarding = true
            pending.removeAll(keepingCapacity: false)
        } else {
            pending.append(contentsOf: rest)
        }
        return lines
    }

    /// The stream ended: an unterminated last line still counts.
    public mutating func finish() -> [AgentLine] {
        defer { pending.removeAll(); discarding = false }
        guard !discarding, let line = Self.complete(pending) else { return [] }
        return [line]
    }

    private static func complete(_ data: Data) -> AgentLine? {
        var line = data
        if line.last == 0x0D { line.removeLast() }
        guard line.contains(where: { $0 != 0x20 && $0 != 0x09 }) else { return nil }
        return .line(line)
    }
}
