import Foundation

/// D178: sizes and counts are written as CleanMyMac and Finder write them —
/// files and disks in decimal units ("73 GB", "737 GB of 995 GB"), memory as
/// Activity Monitor does (1024 bytes a kilobyte, written KB/MB/GB), counts
/// with grouping ("51,962") — always through these entries, in the app's own
/// language (`locale`). (The binary `string`, "5.9 GiB", is gone.)
enum ByteFormat {
    /// The language the app shows, for unit words ("bytes" / "字节") and digit
    /// grouping; `L10n.locale`'s POSIX English would group no digits.
    static var locale: Locale {
        L10n.usesChinese ? Locale(identifier: "zh_Hans") : Locale(identifier: "en_US")
    }

    /// A size of files or of a disk: decimal units, as Finder and CleanMyMac
    /// write them. D178: in the app's language (was the system's).
    static func storageString(
        _ bytes: Int64,
        locale: Locale = ByteFormat.locale
    ) -> String {
        let style = ByteCountFormatStyle(
            style: .file,
            allowedUnits: .all,
            spellsOutZero: false,
            includesActualByteCount: false,
            locale: locale
        )
        return unitsAsFinderWritesThem(max(0, bytes).formatted(style))
    }

    /// D178: a size of memory, as Activity Monitor writes it — 1024 bytes a
    /// kilobyte, the units written KB, MB, GB ("16 GB" for 16 GiB of RAM).
    static func memoryString(_ bytes: Int64, locale: Locale = ByteFormat.locale) -> String {
        let style = ByteCountFormatStyle(
            style: .memory,
            allowedUnits: .all,
            spellsOutZero: false,
            includesActualByteCount: false,
            locale: locale
        )
        return unitsAsFinderWritesThem(max(0, bytes).formatted(style))
    }

    /// D178: a count with the language's digit grouping ("51,962").
    static func count(_ value: Int, locale: Locale = ByteFormat.locale) -> String {
        value.formatted(.number.locale(locale))
    }

    static func count(_ value: Int64, locale: Locale = ByteFormat.locale) -> String {
        value.formatted(.number.locale(locale))
    }

    /// The format style writes the SI "kB"; Finder and CleanMyMac write "KB".
    /// D228: in Chinese it writes "0字节" with no space; every other unit
    /// stands a space from its number ("17.8 MB"), so bytes do too ("0 字节").
    private static func unitsAsFinderWritesThem(_ text: String) -> String {
        text.replacingOccurrences(of: "kB", with: "KB")
            .replacingOccurrences(of: #"(\d)字节"#, with: "$1 字节", options: .regularExpression)
    }

    static func percent(_ value: Int64, of total: Int64) -> String {
        guard total > 0 else { return "0%" }
        let percentage = Double(value) / Double(total) * 100
        return String(format: "%.0f%%", percentage)
    }
}
