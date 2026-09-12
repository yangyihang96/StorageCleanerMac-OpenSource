import Foundation

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(max(0, bytes))
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex <= 1 {
            return "\(Int(value)) \(units[unitIndex])"
        }

        return String(format: "%.1f %@", value, units[unitIndex])
    }

    static func storageString(
        _ bytes: Int64,
        locale: Locale = .current
    ) -> String {
        let style = ByteCountFormatStyle(
            style: .file,
            allowedUnits: .all,
            spellsOutZero: false,
            includesActualByteCount: false,
            locale: locale
        )
        return max(0, bytes).formatted(style)
    }

    static func percent(_ value: Int64, of total: Int64) -> String {
        guard total > 0 else { return "0%" }
        let percentage = Double(value) / Double(total) * 100
        return String(format: "%.0f%%", percentage)
    }
}
