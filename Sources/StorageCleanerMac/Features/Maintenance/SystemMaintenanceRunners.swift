import AppKit
import Foundation
import SQLite3

/// D-FP2: "Speed up Mail" as CleanMyMac does it (SQLite `VACUUM` of the
/// message index), done the careful way: Mail must be closed, the index
/// passes SQLite's own check first, and a copy is kept in this app's folder.
/// Mac Sai's other option, deleting the index so Mail rebuilds it, can make
/// Mail re-import every message for hours, so it is not offered.
struct MailVacuumEnvironment: Sendable {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var backupRoot: URL = AppDataDirectories.applicationSupportRoot
        .appendingPathComponent("Backups/Mail Index", isDirectory: true)
    var isMailRunning: @Sendable () async -> Bool = { await MailEnvelopeIndexVacuum.isMailRunningNow() }
    var freeBytes: @Sendable (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
    var now: @Sendable () -> Date = { Date() }
    var recordRun: @Sendable (Date) -> Void = { MailEnvelopeIndexVacuum.recordRun($0) }
    /// Backups this app keeps; older ones it made are removed.
    var keptBackups = 2
    var busyTimeoutMilliseconds: Int32 = 2_000
}

enum MailEnvelopeIndexVacuum {
    static let mailBundleIdentifier = "com.apple.mail"
    static let lastRunDefaultsKey = "maintenance.mailVacuum.lastRun.v1"
    static let backupPrefix = "Envelope Index "

    static func isMailRunningNow() async -> Bool {
        await MainActor.run {
            !NSRunningApplication.runningApplications(withBundleIdentifier: mailBundleIdentifier).isEmpty
        }
    }

    static func lastRunDate(defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: lastRunDefaultsKey) as? Date
    }

    static func recordRun(_ date: Date, defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastRunDefaultsKey)
    }

    static func run(environment: MailVacuumEnvironment = .init()) async -> SystemMaintenanceRunResult {
        func refused(_ message: String, _ detail: [String] = []) -> SystemMaintenanceRunResult {
            SystemMaintenanceRunResult(task: .speedUpMail, outcome: .refused, message: message, detail: detail,
                                       finishedAt: environment.now())
        }
        func failed(_ message: String, _ detail: [String] = []) -> SystemMaintenanceRunResult {
            SystemMaintenanceRunResult(task: .speedUpMail, outcome: .failed, message: message, detail: detail,
                                       finishedAt: environment.now())
        }

        if await environment.isMailRunning() {
            return refused(L10n.text("“邮件”正在运行，没有整理。请先退出“邮件”。",
                                     "Mail is open, so nothing was compacted. Quit Mail first."))
        }
        let database: URL
        let before: Int64
        switch MailEnvelopeIndexState.locate(home: environment.home) {
        case .notFound:
            return refused(L10n.text("没有找到邮件索引。", "No Mail index was found."))
        case .accessDenied:
            return refused(L10n.text("读不到邮件索引：需要在系统设置中给本应用“完全磁盘访问权限”。",
                                     "The Mail index cannot be read: this app needs Full Disk Access in System Settings."))
        case .found(let url, let bytes):
            database = url
            before = bytes
        }
        // The copy and SQLite's rebuilt file both need room.
        if let free = environment.freeBytes(environment.home), free < before * 2 + 100 * 1_024 * 1_024 {
            return refused(L10n.text("磁盘剩余空间不够备份和整理（需要约 \(ByteFormat.storageString(before * 2))）。",
                                     "Not enough free space to back up and compact (about \(ByteFormat.storageString(before * 2)) is needed)."))
        }

        let backup: URL
        do {
            backup = try makeBackup(of: database, in: environment.backupRoot, at: environment.now())
        } catch {
            return failed(L10n.text("备份邮件索引失败，没有整理。", "The Mail index could not be backed up; nothing was compacted."),
                          [error.localizedDescription])
        }

        switch compact(database, busyTimeoutMilliseconds: environment.busyTimeoutMilliseconds) {
        case .success:
            break
        case .failure(let failure):
            return failure.isCheck
                ? refused(failure.message, [L10n.text("备份在：\(backup.path)", "Backup: \(backup.path)")])
                : failed(failure.message, [L10n.text("备份在：\(backup.path)", "Backup: \(backup.path)")])
        }

        let after = MailEnvelopeIndexState.totalBytes(of: database)
        environment.recordRun(environment.now())
        pruneBackups(in: environment.backupRoot, keeping: environment.keptBackups)
        let saved = before - after
        let message = saved > 0
            ? L10n.text("邮件索引从 \(ByteFormat.storageString(before)) 整理到 \(ByteFormat.storageString(after))，少了 \(ByteFormat.storageString(saved))。",
                        "The Mail index went from \(ByteFormat.storageString(before)) to \(ByteFormat.storageString(after)), \(ByteFormat.storageString(saved)) smaller.")
            : L10n.text("邮件索引已整理，大小没有明显变化（\(ByteFormat.storageString(after))）。",
                        "The Mail index was compacted; its size barely changed (\(ByteFormat.storageString(after))).")
        return SystemMaintenanceRunResult(task: .speedUpMail, outcome: .succeeded, message: message,
                                          detail: [L10n.text("整理前的备份在：\(backup.path)", "The backup from before is at: \(backup.path)")],
                                          finishedAt: environment.now())
    }

    static func makeBackup(of database: URL, in root: URL, at date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let folder = root.appendingPathComponent(backupPrefix + formatter.string(from: date), isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for suffix in MailEnvelopeIndexState.companionSuffixes {
                let source = URL(fileURLWithPath: database.path + suffix)
                guard manager.fileExists(atPath: source.path) else { continue }
                try manager.copyItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
            }
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
        return folder
    }

    /// Removes this app's older backups, newest kept; nothing else in the
    /// folder is touched.
    static func pruneBackups(in root: URL, keeping count: Int) {
        let manager = FileManager.default
        guard let children = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let ours = children.filter { $0.lastPathComponent.hasPrefix(backupPrefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in ours.dropFirst(max(1, count)) { try? manager.removeItem(at: old) }
    }

    struct CompactFailure: Error, Equatable {
        let message: String
        /// The index failed SQLite's check, so it was left alone.
        let isCheck: Bool
    }

    static func compact(_ database: URL, busyTimeoutMilliseconds: Int32) -> Result<Void, CompactFailure> {
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil)
        guard opened == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            return .failure(.init(message: L10n.text("打不开邮件索引（\(opened)），没有整理。",
                                                     "The Mail index could not be opened (\(opened)); nothing was compacted."),
                                  isCheck: false))
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, busyTimeoutMilliseconds)

        let check = quickCheck(handle)
        if check == .busy {
            return .failure(.init(message: L10n.text("邮件索引正被使用，没有整理。请确认“邮件”已退出后再试。",
                                                     "The Mail index is in use; nothing was compacted. Make sure Mail is closed and try again."),
                                  isCheck: false))
        }
        guard check == .ok else {
            return .failure(.init(message: L10n.text("邮件索引自检没有通过，没有整理。可以让“邮件”自行重建索引。",
                                                     "The Mail index failed its check, so it was left alone. Mail can rebuild its index itself."),
                                  isCheck: true))
        }
        let vacuum = sqlite3_exec(handle, "VACUUM;", nil, nil, nil)
        guard vacuum == SQLITE_OK else {
            let busy = vacuum == SQLITE_BUSY || vacuum == SQLITE_LOCKED
            return .failure(.init(message: busy
                ? L10n.text("邮件索引正被使用，没有整理。请确认“邮件”已退出后再试。",
                            "The Mail index is in use; nothing was compacted. Make sure Mail is closed and try again.")
                : L10n.text("整理邮件索引时出错（\(vacuum)），索引保持原样。",
                            "Compacting the Mail index failed (\(vacuum)); the index was left as it was."),
                                  isCheck: false))
        }
        _ = sqlite3_exec(handle, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
        return .success(())
    }

    enum QuickCheck: Equatable { case ok, failed, busy }

    /// SQLite's own consistency check; a file that is not a database fails it.
    static func quickCheck(_ handle: OpaquePointer) -> QuickCheck {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, "PRAGMA quick_check;", -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            return prepared == SQLITE_BUSY || prepared == SQLITE_LOCKED ? .busy : .failed
        }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        if step == SQLITE_BUSY || step == SQLITE_LOCKED { return .busy }
        guard step == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return .failed }
        return String(cString: text) == "ok" ? .ok : .failed
    }
}

/// D-FP2: refreshes the LaunchServices ("Open With") database as the
/// current user. `lsregister -kill`, which Mac Sai runs and which reset
/// the default apps, is gone from this macOS, and `-delete` needs a
/// restart; garbage collection plus a forced registration of the standard
/// app folders fixes stale and duplicate entries without either.
enum LaunchServicesRefresh {
    static let lsregister = URL(fileURLWithPath:
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
    static let steps: [(arguments: [String], timeout: TimeInterval)] = [
        (["-gc"], 120),
        (["-r", "-f", "-apps", "u,l,s"], 300),
    ]

    static func run(
        runner: any StartupItemsDomain.StartupProcessRunning = StartupItemsDomain.CancellableStartupProcessRunner(),
        executableExists: @Sendable (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) },
        now: @Sendable () -> Date = { Date() }
    ) async -> SystemMaintenanceRunResult {
        guard executableExists(lsregister) else {
            return SystemMaintenanceRunResult(task: .rebuildLaunchServices, outcome: .refused,
                                              message: L10n.text("这版 macOS 找不到 lsregister，没有运行。",
                                                                 "lsregister is not on this version of macOS; nothing was run."),
                                              finishedAt: now())
        }
        let started = now()
        for step in steps {
            do {
                let result = try await runner.run(executableURL: lsregister, arguments: step.arguments, timeout: step.timeout)
                guard result.terminationStatus == 0 else {
                    return SystemMaintenanceRunResult(
                        task: .rebuildLaunchServices, outcome: .failed,
                        message: L10n.text("刷新没有完成（lsregister \(step.arguments.joined(separator: " ")) 返回 \(result.terminationStatus)）。",
                                           "The refresh did not finish (lsregister \(step.arguments.joined(separator: " ")) returned \(result.terminationStatus))."),
                        detail: [String(result.combinedOutput.prefix(400))].filter { !$0.isEmpty },
                        finishedAt: now())
                }
            } catch {
                return SystemMaintenanceRunResult(
                    task: .rebuildLaunchServices, outcome: .failed,
                    message: L10n.text("刷新没有完成：\(error.localizedDescription)",
                                       "The refresh did not finish: \(error.localizedDescription)"),
                    finishedAt: now())
            }
        }
        let seconds = Int(now().timeIntervalSince(started).rounded())
        return SystemMaintenanceRunResult(
            task: .rebuildLaunchServices, outcome: .succeeded,
            message: L10n.text("“打开方式”数据库已刷新，用时 \(seconds) 秒。", "The Open With database was refreshed in \(seconds) s."),
            detail: [L10n.text("如果“打开方式”里仍有重复项，重新登录一次即可。",
                               "If the Open With menu still shows duplicates, log out and in once.")],
            finishedAt: now())
    }
}

/// The two tasks this app runs, injectable for tests.
struct SystemMaintenanceRunners: Sendable {
    var speedUpMail: @Sendable () async -> SystemMaintenanceRunResult = { await MailEnvelopeIndexVacuum.run() }
    var rebuildLaunchServices: @Sendable () async -> SystemMaintenanceRunResult = { await LaunchServicesRefresh.run() }

    func run(_ task: SystemMaintenanceTaskID) async -> SystemMaintenanceRunResult? {
        switch task {
        case .speedUpMail: await speedUpMail()
        case .rebuildLaunchServices: await rebuildLaunchServices()
        default: nil
        }
    }
}
