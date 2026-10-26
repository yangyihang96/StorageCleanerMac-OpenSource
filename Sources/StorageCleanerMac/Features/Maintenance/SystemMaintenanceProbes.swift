import Foundation

/// D-FP2: read-only looks behind the maintenance list. None of them changes
/// anything; each can be replaced in tests.
struct VolumeCapacityReading: Equatable, Sendable {
    let availableBytes: Int64?
    let importantUsageBytes: Int64?

    /// What macOS counts as available only because it can purge it.
    var purgeableBytes: Int64? {
        guard let availableBytes, let importantUsageBytes else { return nil }
        return max(0, importantUsageBytes - availableBytes)
    }

    static func read(volume: URL = URL(fileURLWithPath: "/")) -> VolumeCapacityReading {
        let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityKey,
                                                          .volumeAvailableCapacityForImportantUsageKey])
        return VolumeCapacityReading(availableBytes: values?.volumeAvailableCapacity.map(Int64.init),
                                     importantUsageBytes: values?.volumeAvailableCapacityForImportantUsage)
    }
}

/// Where Mail keeps its message index: `~/Library/Mail/V<n>/MailData/
/// Envelope Index`, the newest `V<n>` that has one.
enum MailEnvelopeIndexState: Equatable, Sendable {
    case notFound
    /// ~/Library/Mail is protected: without Full Disk Access it cannot be read.
    case accessDenied
    case found(database: URL, bytes: Int64)

    static let fileName = "Envelope Index"
    static let companionSuffixes = ["", "-wal", "-shm"]

    static func locate(home: URL, fileManager: FileManager = .default) -> MailEnvelopeIndexState {
        let mail = home.appendingPathComponent("Library/Mail", isDirectory: true)
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(at: mail, includingPropertiesForKeys: nil)
        } catch {
            let code = (error as NSError).code
            let underlying = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code
            if code == NSFileReadNoPermissionError || underlying == Int(EPERM) || underlying == Int(EACCES) {
                return .accessDenied
            }
            return .notFound
        }
        let versions = children.compactMap { url -> (Int, URL)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("V"), let number = Int(name.dropFirst()) else { return nil }
            return (number, url)
        }.sorted { $0.0 > $1.0 }
        for (_, folder) in versions {
            let database = folder.appendingPathComponent("MailData/\(fileName)")
            if fileManager.fileExists(atPath: database.path) {
                if !fileManager.isReadableFile(atPath: database.path) { return .accessDenied }
                return .found(database: database, bytes: totalBytes(of: database, fileManager: fileManager))
            }
        }
        return .notFound
    }

    /// The database with its write-ahead log and shared memory files.
    static func totalBytes(of database: URL, fileManager: FileManager = .default) -> Int64 {
        companionSuffixes.reduce(Int64(0)) { total, suffix in
            let path = database.path + suffix
            let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }
}

/// `tmutil listlocalsnapshotdates /` lists one `YYYY-MM-DD-HHMMSS` per line.
enum LocalSnapshotDates {
    static let command = TimeMachineStatusService.localSnapshotsCommand

    static func parse(_ text: String, calendar: Calendar = Calendar(identifier: .gregorian)) -> [Date] {
        var calendar = calendar
        calendar.timeZone = .current
        return text.split(whereSeparator: \.isNewline).compactMap { line -> Date? in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "-")
            guard parts.count == 4, parts[0].count == 4, parts[3].count == 6,
                  let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
                  let time = Int(parts[3]) else { return nil }
            return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                      hour: time / 10_000, minute: time / 100 % 100, second: time % 100))
        }.sorted()
    }

    static func read(runner: any TimeMachineCommandRunning = ShellTimeMachineCommandRunner()) -> [Date]? {
        guard let data = try? runner.capture(command), let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }
}

/// The injectable reads behind the maintenance statuses.
struct SystemMaintenanceProbe: Sendable {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var capacity: @Sendable () -> VolumeCapacityReading = { VolumeCapacityReading.read() }
    var mailIndex: @Sendable (URL) -> MailEnvelopeIndexState = { MailEnvelopeIndexState.locate(home: $0) }
    var isMailRunning: @Sendable () async -> Bool = { await MailEnvelopeIndexVacuum.isMailRunningNow() }
    var snapshotDates: @Sendable () -> [Date]? = { LocalSnapshotDates.read() }
    var periodicScriptsExist: @Sendable () -> Bool = { FileManager.default.fileExists(atPath: "/usr/sbin/periodic") }
    var lastMailVacuum: @Sendable () -> Date? = { MailEnvelopeIndexVacuum.lastRunDate() }
    var now: @Sendable () -> Date = { Date() }
    /// An index this large is worth compacting when it was not done lately.
    var mailRecommendationBytes: Int64 = 256 * 1_024 * 1_024
    var mailRecommendationInterval: TimeInterval = 30 * 24 * 3_600

    func statuses() async -> [SystemMaintenanceTaskID: SystemMaintenanceStatus] {
        var result: [SystemMaintenanceTaskID: SystemMaintenanceStatus] = [:]
        result[.freeUpMemory] = SystemMaintenanceStatus(mode: .elsewhere(.freeUpMemoryPage))
        result[.purgeableSpace] = purgeableStatus()
        result[.flushDNS] = SystemMaintenanceStatus(mode: .administratorRequired, lines: [
            L10n.text("需要管理员权限，本应用不提权。可以自己在“终端”里运行下面的命令。",
                      "Needs an administrator and this app does not elevate. You can run the command below in Terminal yourself."),
        ])
        result[.speedUpMail] = await mailStatus()
        result[.rebuildSpotlight] = SystemMaintenanceStatus(mode: .elsewhere(.spotlightSettings), lines: [
            L10n.text("做法：在 Spotlight 设置的“搜索隐私”里加入这块磁盘，再把它移除，系统就会重建索引。",
                      "How: in Spotlight settings, add the disk under Search Privacy, then remove it; macOS rebuilds the index."),
        ])
        result[.repairPermissions] = SystemMaintenanceStatus(mode: .elsewhere(.diskUtility))
        result[.maintenanceScripts] = periodicScriptsExist()
            ? SystemMaintenanceStatus(mode: .administratorRequired, lines: [
                L10n.text("需要管理员权限；系统会按时自动运行它们。", "Needs an administrator; macOS runs them on schedule."),
            ])
            : SystemMaintenanceStatus(mode: .notNeeded, lines: [
                L10n.text("这版 macOS 已没有周期维护脚本，无需运行。", "This version of macOS no longer has periodic scripts; nothing to run."),
            ])
        result[.timeMachineSnapshots] = snapshotStatus()
        result[.rebuildLaunchServices] = SystemMaintenanceStatus(mode: .runnable)
        return result
    }

    func purgeableStatus() -> SystemMaintenanceStatus {
        let reading = capacity()
        guard let purgeable = reading.purgeableBytes, let available = reading.importantUsageBytes else {
            return SystemMaintenanceStatus(mode: .informational, lines: [
                L10n.text("暂时读不到这块磁盘的空间。", "The disk's space could not be read right now."),
            ])
        }
        return SystemMaintenanceStatus(mode: .informational, lines: [
            L10n.text("可用 \(ByteFormat.storageString(available))，其中约 \(ByteFormat.storageString(purgeable)) 是可清除空间。",
                      "\(ByteFormat.storageString(available)) available, about \(ByteFormat.storageString(purgeable)) of it purgeable."),
            L10n.text("本应用不用“临时写满磁盘”的办法强制释放：那样会让正在写文件的应用出错。",
                      "This app does not force it out by filling the disk for a moment: apps writing files at that time could fail."),
        ])
    }

    func mailStatus() async -> SystemMaintenanceStatus {
        var status = SystemMaintenanceStatus(mode: .runnable)
        switch mailIndex(home) {
        case .notFound:
            status.lines = [L10n.text("没有找到邮件索引，可能没有用过“邮件”。", "No Mail index found; Mail may not have been used.")]
            status.blocker = L10n.text("没有可整理的邮件索引", "There is no Mail index to compact")
        case .accessDenied:
            status.lines = [L10n.text("需要在系统设置中给本应用“完全磁盘访问权限”才能读取邮件索引。",
                                      "This app needs Full Disk Access in System Settings to read the Mail index.")]
            status.blocker = L10n.text("需要完全磁盘访问权限", "Needs Full Disk Access")
            status.needsFullDiskAccess = true
        case .found(_, let bytes):
            status.lines = [L10n.text("邮件索引现在 \(ByteFormat.storageString(bytes))。", "The Mail index is \(ByteFormat.storageString(bytes)) now.")]
            let last = lastMailVacuum()
            if let last {
                status.lines.append(L10n.text("上次整理：\(Self.dateText(last))", "Last compacted: \(Self.dateText(last))"))
            }
            status.isRecommended = bytes >= mailRecommendationBytes
                && (last.map { now().timeIntervalSince($0) > mailRecommendationInterval } ?? true)
            if await isMailRunning() {
                status.blocker = L10n.text("请先退出“邮件”", "Quit Mail first")
            }
        }
        return status
    }

    func snapshotStatus() -> SystemMaintenanceStatus {
        var status = SystemMaintenanceStatus(mode: .elsewhere(.timeMachineSettings))
        guard let dates = snapshotDates() else {
            status.lines = [L10n.text("暂时读不到本地快照。", "Local snapshots could not be read right now.")]
            return status
        }
        if dates.isEmpty {
            status.lines = [L10n.text("本机没有本地快照。", "There are no local snapshots on this Mac.")]
        } else {
            status.lines = [L10n.text("本机有 \(ByteFormat.count(dates.count)) 个本地快照，最早 \(Self.dateText(dates[0]))，最新 \(Self.dateText(dates[dates.count - 1]))。",
                                      "\(ByteFormat.count(dates.count)) local snapshots, the oldest from \(Self.dateText(dates[0])), the newest from \(Self.dateText(dates[dates.count - 1])).")]
        }
        status.lines.append(L10n.text("本应用不删除快照：它们是找回文件的退路，空间不够时系统会自己删最旧的。",
                                      "This app does not delete snapshots: they are a way back to your files, and macOS removes the oldest when space runs low."))
        return status
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
