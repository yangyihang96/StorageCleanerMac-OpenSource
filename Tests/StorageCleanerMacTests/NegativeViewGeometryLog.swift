import AppKit
import OSLog

/// D242 (review P2-2): AppKit's “Invalid view geometry: width/height is
/// negative” reports in this process's own log (no window needed to read it).
enum NegativeViewGeometryLog {
    static func reports(since start: Date) throws -> [String] {
        let from = start.addingTimeInterval(-0.01)
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: from),
                                           matching: NSPredicate(format: "composedMessage CONTAINS %@", "Invalid view geometry"))
        return entries.compactMap { $0.date >= from ? $0.composedMessage : nil }
    }

    /// Gives a throwaway view a negative size and reads the report back
    /// (the log can lag a moment); true when the report was found.
    @MainActor
    static func provokedReportIsReadable() throws -> Bool {
        let start = Date()
        let probe = NSView(frame: .zero)
        probe.setFrameSize(NSSize(width: -1, height: -1))
        for _ in 0..<10 {
            if !(try reports(since: start).isEmpty) { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }
}
