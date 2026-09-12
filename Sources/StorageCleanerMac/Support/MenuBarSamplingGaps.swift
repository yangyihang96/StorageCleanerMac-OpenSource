import Foundation

/// Known pauses are metadata, never synthetic telemetry. The existing energy
/// lifecycle observer and menu-bar pause action supply these boundaries.
final class MenuBarSamplingGaps: @unchecked Sendable {
    enum Reason: String { case sleep, paused }
    static let shared = MenuBarSamplingGaps(defaults: .standard)
    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let key = "menuBar.history.unrecordedIntervals.v1"
    private var recorded: [DateInterval]
    private var pending: [Reason: Date] = [:]

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        recorded = defaults?.data(forKey: key).flatMap {
            try? JSONDecoder().decode([DateInterval].self, from: $0)
        } ?? []
    }

    func begin(_ reason: Reason, at date: Date = Date()) {
        lock.withLock { pending[reason] = pending[reason] ?? date }
    }

    func end(_ reason: Reason, at date: Date = Date()) {
        lock.withLock {
            guard let start = pending.removeValue(forKey: reason), date > start else { return }
            recorded.append(DateInterval(start: start, end: date))
            let cutoff = date.addingTimeInterval(-MenuBarHistoryRetention.duration)
            recorded = Array(recorded.filter { $0.end >= cutoff }.suffix(512))
            if let data = try? JSONEncoder().encode(recorded) { defaults?.set(data, forKey: key) }
        }
    }

    func intervals(at date: Date = Date()) -> [DateInterval] {
        lock.withLock {
            recorded + pending.values.compactMap { start in
                date > start ? DateInterval(start: start, end: date) : nil
            }
        }
    }

    static func crosses(_ intervals: [DateInterval], from start: Date, to end: Date) -> Bool {
        intervals.contains { $0.start < end && $0.end > start }
    }
}
