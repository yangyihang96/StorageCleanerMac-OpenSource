import Foundation

/// D177: the helper's answer to `backgroundTaskInventory`. `output` is the
/// `sfltool dumpbtm` text cut down to the caller's records and the
/// system-wide ones; on failure it is nil and `failure` says why.
public struct BackgroundTaskInventoryReply: Codable, Sendable, Equatable {
    public enum Failure: String, Codable, Sendable {
        case launch, timeout, exitStatus, tooLarge, format
    }
    public let output: String?
    public let failure: Failure?
    public let exitStatus: Int32?
    public init(output: String? = nil, failure: Failure? = nil, exitStatus: Int32? = nil) {
        self.output = output; self.failure = failure; self.exitStatus = exitStatus
    }
}

public enum BackgroundTaskInventoryFilter {
    /// `dumpbtm` run as root lists every account ("Records for UID 501 : …").
    /// Keeps the system-wide records (UID -2) and the caller's own, which is
    /// what System Settings shows that user. Nil when the text has no such
    /// headings, so an unknown format never passes on other accounts' items.
    public static func records(in output: String, uid: UInt32) -> String? {
        var kept = [Substring]()
        var keeping = false
        var sawHeading = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if let owner = owner(of: line) {
                sawHeading = true
                keeping = owner == -2 || owner == Int64(uid)
            }
            if keeping { kept.append(line) }
        }
        return sawHeading ? kept.joined(separator: "\n") : nil
    }

    /// The UID a heading line names; `Int64.min` (kept by nobody) when the
    /// number cannot be read, nil for every other line.
    static func owner(of line: Substring) -> Int64? {
        let heading = "Records for UID "
        let text = line.drop { $0 == " " || $0 == "\t" }
        guard text.hasPrefix(heading) else { return nil }
        let number = text.dropFirst(heading.count).prefix { $0 == "-" || ($0.isASCII && $0.isNumber) }
        return Int64(number) ?? .min
    }
}
