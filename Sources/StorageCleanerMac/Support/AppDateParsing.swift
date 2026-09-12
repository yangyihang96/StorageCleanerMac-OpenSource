import Foundation

enum AppISO8601DateCodec {
    private static let fractionalStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )
    private static let standardStyle = Date.ISO8601FormatStyle()

    static func string(from date: Date) -> String {
        date.formatted(fractionalStyle)
    }

    static func date(from value: String) -> Date? {
        (try? Date(value, strategy: fractionalStyle))
            ?? (try? Date(value, strategy: standardStyle))
    }
}
