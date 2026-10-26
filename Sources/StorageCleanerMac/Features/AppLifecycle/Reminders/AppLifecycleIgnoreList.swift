import Foundation

/// The reminders this feature raises. The first two raw values are
/// CleanMyMac's `issueReportKind` numbers observed in its `IssueIgnoreList.db`;
/// the D219/D220 kinds were not seen there and are numbered from 100 so they
/// never meet one of its kinds.
enum AppLifecycleIssueKind: Int, Codable, Sendable, CaseIterable {
    /// One record per trashed application; discriminator = its file URL.
    case trashedApplication = 9
    /// One global record; discriminator = "".
    case trashSize = 5
    /// D219: a Smart Scan is due; one global record.
    case scanDue = 100
    /// D220: little space left on the startup disk; one global record.
    case lowDiskSpace = 101
}

/// CleanMyMac's Ignore button and its menu (`Issue_Alert_Ignore_Option_*`).
/// The plain button ignores for a week: `604800` is the interval almost every
/// record in the observed database carries. D224: the menu's labels are this
/// app's words (they were CleanMyMac's, word for word); the button keeps the
/// plain verb the app uses for every ignore.
enum AppLifecycleIgnoreOption: String, CaseIterable, Identifiable, Sendable {
    case ignore
    case oneDay
    case threeDays
    case oneWeek
    case untilTomorrow
    case forever

    var id: String { rawValue }

    /// Options listed in the menu next to the button, in CleanMyMac's order.
    static let menuOptions: [AppLifecycleIgnoreOption] = [.oneDay, .threeDays, .oneWeek, .untilTomorrow, .forever]

    var title: String {
        switch self {
        case .ignore: L10n.text("忽略", "Ignore")
        case .oneDay: L10n.text("一天内不再提醒", "Not for a Day")
        case .threeDays: L10n.text("3 天内不再提醒", "Not for 3 Days")
        case .oneWeek: L10n.text("一周内不再提醒", "Not for a Week")
        case .untilTomorrow: L10n.text("今天不再提醒", "Not Again Today")
        case .forever: L10n.text("以后都不再提醒", "Never Remind Me")
        }
    }

    /// Seconds to stay quiet, nil for forever. "Until tomorrow" lasts until the
    /// next local midnight, as the observed records do (ignored time plus
    /// interval lands exactly on 00:00 Sydney time).
    func interval(from now: Date, calendar: Calendar = .current) -> TimeInterval? {
        switch self {
        case .ignore, .oneWeek: return 7 * 24 * 60 * 60
        case .oneDay: return 24 * 60 * 60
        case .threeDays: return 3 * 24 * 60 * 60
        case .untilTomorrow:
            let startOfToday = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(24 * 60 * 60)
            return max(1, tomorrow.timeIntervalSince(now))
        case .forever: return nil
        }
    }
}

struct AppLifecycleIgnoreRecord: Codable, Equatable, Sendable {
    let kind: AppLifecycleIssueKind
    let discriminator: String
    let ignoredAt: Date
    /// Nil means forever.
    let interval: TimeInterval?

    func isActive(at now: Date) -> Bool {
        guard let interval else { return true }
        return now < ignoredAt.addingTimeInterval(interval)
    }
}

/// CleanMyMac keeps these in SQLite (`ignore` table, unique on kind and
/// discriminator); a small JSON file in the app's data folder holds the same
/// records here. Expired records are dropped on load and save.
final class AppLifecycleIgnoreList: @unchecked Sendable {
    static let fileName = "IssueIgnoreList.json"

    private let fileURL: URL?
    private let lock = NSLock()
    private var records: [AppLifecycleIgnoreRecord] = []
    private let now: @Sendable () -> Date

    /// `directory == nil` keeps the list in memory only (tests).
    init(directory: URL?, now: @escaping @Sendable () -> Date = Date.init) {
        fileURL = directory?.appendingPathComponent(Self.fileName, isDirectory: false)
        self.now = now
        records = Self.load(fileURL).filter { $0.isActive(at: now()) }
    }

    static func live() -> AppLifecycleIgnoreList {
        AppLifecycleIgnoreList(directory: AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("AppLifecycle", isDirectory: true))
    }

    func isIgnored(_ kind: AppLifecycleIssueKind, discriminator: String) -> Bool {
        let date = now()
        return lock.withLock {
            records.contains { $0.kind == kind && $0.discriminator == discriminator && $0.isActive(at: date) }
        }
    }

    func ignore(_ kind: AppLifecycleIssueKind, discriminators: [String], option: AppLifecycleIgnoreOption) {
        let date = now()
        let interval = option.interval(from: date)
        lock.withLock {
            records.removeAll { record in
                !record.isActive(at: date)
                    || (record.kind == kind && discriminators.contains(record.discriminator))
            }
            records.append(contentsOf: discriminators.map {
                AppLifecycleIgnoreRecord(kind: kind, discriminator: $0, ignoredAt: date, interval: interval)
            })
        }
        save()
    }

    func reset(_ kind: AppLifecycleIssueKind? = nil) {
        lock.withLock { records.removeAll { kind == nil || $0.kind == kind } }
        save()
    }

    /// Records of trashed apps that are no longer in the Trash (emptied or
    /// put back) serve nothing any more.
    func pruneTrashedApplications(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        let removed: Bool = lock.withLock {
            let before = records.count
            records.removeAll { record in
                guard record.kind == .trashedApplication, let url = URL(string: record.discriminator), url.isFileURL else { return false }
                return !fileExists(url.path)
            }
            return records.count != before
        }
        if removed { save() }
    }

    func activeRecords() -> [AppLifecycleIgnoreRecord] {
        let date = now()
        return lock.withLock { records.filter { $0.isActive(at: date) } }
    }

    private func save() {
        guard let fileURL else { return }
        let snapshot = activeRecords()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            // A reminder that cannot remember being ignored shows again later;
            // that is the only consequence, so the failure is not surfaced.
        }
    }

    private static func load(_ fileURL: URL?) -> [AppLifecycleIgnoreRecord] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // D219: a record of a kind this version does not know (written by a
        // newer one) is skipped, not taken as a broken file losing the rest.
        return ((try? decoder.decode([LenientRecord].self, from: data)) ?? []).compactMap(\.record)
    }

    private struct LenientRecord: Decodable {
        let record: AppLifecycleIgnoreRecord?

        init(from decoder: Decoder) throws {
            record = try? AppLifecycleIgnoreRecord(from: decoder)
        }
    }
}
