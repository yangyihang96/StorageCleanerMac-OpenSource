import Foundation

/// A JSON value that keeps integers apart from doubles, so JSON-RPC IDs, byte
/// counts and record numbers survive the bridge ↔ App round trip exactly (D269).
public enum AgentJSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([AgentJSONValue])
    case object([String: AgentJSONValue])

    public subscript(key: String) -> AgentJSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public subscript(index: Int) -> AgentJSONValue? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public var integerValue: Int64? { if case .integer(let value) = self { return value }; return nil }
    public var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var arrayValue: [AgentJSONValue]? { if case .array(let value) = self { return value }; return nil }
    public var objectValue: [String: AgentJSONValue]? { if case .object(let value) = self { return value }; return nil }
}

extension AgentJSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        // JSONDecoder is strict: a Bool never decodes from a number and an
        // integer never from `true`, so the order only separates 1 from 1.5.
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int64.self) { self = .integer(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([AgentJSONValue].self) { self = .array(value); return }
        self = .object(try container.decode([String: AgentJSONValue].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension AgentJSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: AgentJSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, AgentJSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
