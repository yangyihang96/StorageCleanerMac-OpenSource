import Foundation

/// One hardware reading under DECISIONS D57's no-value rule (M1–M5).
///
/// - `unsupported`: the SMC key, IOReport channel or registry property does
///   not exist on this Mac. The row is hidden; a third-level detail that
///   lists the item says "本机不支持".
/// - `invalid`: it exists, but the value cannot be decoded or is outside its
///   plausible range. The row shows "—"; the third level says "读数无效".
/// - `value`: a measured value. Zero is a legal value and is shown as zero.
enum HardwareReading<Value: Equatable & Sendable>: Equatable, Sendable {
    case unsupported
    case invalid
    case value(Value)

    var value: Value? {
        if case let .value(value) = self { return value }
        return nil
    }

    var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }

    func map<T: Equatable & Sendable>(_ transform: (Value) -> T) -> HardwareReading<T> {
        switch self {
        case .unsupported: .unsupported
        case .invalid: .invalid
        case let .value(value): .value(transform(value))
        }
    }
}

/// The words D57 uses for a reading without a value. One exit so the second
/// and third levels never drift apart.
enum HardwareReadingText {
    /// The second-level value of an invalid reading.
    static let invalidValue = "—"

    static var unsupported: String { L10n.text("本机不支持", "Not supported on this Mac") }
    static var invalid: String { L10n.text("读数无效", "Invalid reading") }
    static var updating: String { L10n.text("更新中", "Updating") }

    /// A third-level value: the formatted value, "本机不支持" or "读数无效".
    static func detail<Value>(_ reading: HardwareReading<Value>, format: (Value) -> String) -> String {
        switch reading {
        case .unsupported: unsupported
        case .invalid: invalid
        case let .value(value): format(value)
        }
    }

    static func watts(_ value: Double) -> String {
        String(format: "%.2f W", value)
    }

    static func megahertz(_ value: Double) -> String {
        String(format: "%.0f MHz", value)
    }

    /// "+28.00 W", "-2.60 W"; a zero has no sign.
    static func signedWatts(_ value: Double) -> String {
        signed(value, decimals: 2, unit: "W")
    }

    /// "-0.84 A"; a zero has no sign.
    static func signedAmps(_ value: Double) -> String {
        signed(value, decimals: 2, unit: "A")
    }

    /// A signed value with `decimals` places. A value that rounds to zero
    /// has no sign ("0.000 A", never "+0.000 A" or "-0.000 A").
    static func signed(_ value: Double, decimals: Int, unit: String) -> String {
        let places = max(0, min(decimals, 6))
        let number = abs(value) < 0.5 * pow(10, -Double(places))
            ? String(format: "%.\(places)f", 0.0)
            : String(format: "%+.\(places)f", value)
        return "\(number) \(unit)"
    }

    static func volts(_ value: Double) -> String {
        String(format: "%.2f V", value)
    }

    static func amps(_ value: Double) -> String {
        String(format: "%.2f A", value)
    }

    static func celsius(_ value: Double) -> String {
        String(format: "%.1f°C", value)
    }
}
