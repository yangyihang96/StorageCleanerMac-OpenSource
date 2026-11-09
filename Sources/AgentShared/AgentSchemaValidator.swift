import Foundation

public struct AgentSchemaViolation: Equatable, Sendable {
    /// `limit`, `items[0].id`; empty for the value itself.
    public let path: String
    public let problem: String

    public var description: String { path.isEmpty ? problem : "\(path) \(problem)" }
}

/// The subset of JSON Schema the catalog uses: type (one or a list), enum,
/// properties, required, additionalProperties, items, min/max items, length
/// and value. The bridge checks arguments before forwarding (MCP -32602) and
/// the App checks them again; results are checked against the output schema.
public enum AgentSchemaValidator {
    public static func violation(of value: AgentJSONValue, against schema: AgentJSONValue) -> AgentSchemaViolation? {
        check(value, schema, at: "")
    }

    private static func check(_ value: AgentJSONValue, _ schema: AgentJSONValue, at path: String) -> AgentSchemaViolation? {
        if let types = allowedTypes(schema), !types.contains(where: { matches(value, $0) }) {
            return .init(path: path, problem: "must be \(types.joined(separator: " or "))")
        }
        if let options = schema["enum"]?.arrayValue, !options.contains(value) {
            return .init(path: path, problem: "must be one of the listed values")
        }
        switch value {
        case .object(let fields):
            let properties = schema["properties"]?.objectValue ?? [:]
            for name in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where fields[name] == nil {
                return .init(path: join(path, name), problem: "is required")
            }
            for (name, field) in fields.sorted(by: { $0.key < $1.key }) {
                if let property = properties[name] {
                    if let violation = check(field, property, at: join(path, name)) { return violation }
                } else if schema["additionalProperties"] == false {
                    return .init(path: join(path, name), problem: "is not an allowed property")
                }
            }
        case .array(let items):
            if let maximum = schema["maxItems"]?.integerValue, items.count > maximum {
                return .init(path: path, problem: "must have at most \(maximum) items")
            }
            if let minimum = schema["minItems"]?.integerValue, items.count < minimum {
                return .init(path: path, problem: "must have at least \(minimum) items")
            }
            if let itemSchema = schema["items"] {
                for (index, item) in items.enumerated() {
                    if let violation = check(item, itemSchema, at: "\(path)[\(index)]") { return violation }
                }
            }
        case .string(let text):
            if let maximum = schema["maxLength"]?.integerValue, text.count > maximum {
                return .init(path: path, problem: "must be at most \(maximum) characters")
            }
            if let minimum = schema["minLength"]?.integerValue, text.count < minimum {
                return .init(path: path, problem: "must be at least \(minimum) characters")
            }
        case .integer(let number):
            if let violation = range(Double(number), schema, at: path) { return violation }
        case .number(let number):
            if let violation = range(number, schema, at: path) { return violation }
        case .null, .bool:
            break
        }
        return nil
    }

    private static func range(_ number: Double, _ schema: AgentJSONValue, at path: String) -> AgentSchemaViolation? {
        if let maximum = bound(schema["maximum"]), number > maximum.value {
            return .init(path: path, problem: "must be at most \(maximum.text)")
        }
        if let minimum = bound(schema["minimum"]), number < minimum.value {
            return .init(path: path, problem: "must be at least \(minimum.text)")
        }
        return nil
    }

    private static func bound(_ value: AgentJSONValue?) -> (value: Double, text: String)? {
        switch value {
        case .integer(let number): (Double(number), String(number))
        case .number(let number): (number, String(number))
        default: nil
        }
    }

    private static func allowedTypes(_ schema: AgentJSONValue) -> [String]? {
        switch schema["type"] {
        case .string(let type): [type]
        case .array(let types): types.compactMap(\.stringValue)
        default: nil
        }
    }

    private static func matches(_ value: AgentJSONValue, _ type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null),
             ("integer", .integer), ("number", .integer), ("number", .number):
            true
        case ("integer", .number(let number)):
            // JSON Schema counts 5.0 as an integer.
            number.rounded() == number
        default:
            false
        }
    }

    private static func join(_ path: String, _ name: String) -> String { path.isEmpty ? name : path + "." + name }
}
