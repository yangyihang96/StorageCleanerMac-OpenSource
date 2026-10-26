import Foundation
import SQLite3
import XCTest
@testable import StorageCleanerMac

/// D-FP2：维护任务。只读探测、邮件索引整理（夹具数据库）、“打开方式”数据库刷新
/// 的命令构造，以及页面状态。测试从不在本机真实运行 lsregister 或整理真实的邮件索引。
final class SystemMaintenanceTests: XCTestCase {
    // MARK: Probes

    func testPurgeableSpaceIsImportantUsageMinusAvailable() {
        XCTAssertEqual(VolumeCapacityReading(availableBytes: 40, importantUsageBytes: 100).purgeableBytes, 60)
        XCTAssertEqual(VolumeCapacityReading(availableBytes: 120, importantUsageBytes: 100).purgeableBytes, 0)
        XCTAssertNil(VolumeCapacityReading(availableBytes: nil, importantUsageBytes: 100).purgeableBytes)
    }

    func testLocalSnapshotDatesAreParsedFromTmutil() throws {
        let text = """
        Snapshot dates for all disks:
        2026-10-18-093012
        2026-10-20-101500
        2026-10-19-235959
        not-a-date
        """
        let dates = LocalSnapshotDates.parse(text)
        XCTAssertEqual(dates.count, 3)
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(dates.first)), 18, "按时间排序")
        XCTAssertEqual(calendar.component(.second, from: try XCTUnwrap(dates.last)), 0)
        XCTAssertEqual(calendar.component(.minute, from: try XCTUnwrap(dates.last)), 15)
    }

    func testMailIndexIsFoundInTheNewestVersionFolder() throws {
        let fixture = try MailFixture()
        defer { fixture.remove() }
        XCTAssertEqual(MailEnvelopeIndexState.locate(home: fixture.home), .notFound, "没有 Mail 文件夹")
        try fixture.makeDatabase(version: 9, rows: 10)
        let newest = try fixture.makeDatabase(version: 10, rows: 10)
        guard case .found(let database, let bytes) = MailEnvelopeIndexState.locate(home: fixture.home) else {
            return XCTFail("应找到 V10 的索引")
        }
        XCTAssertEqual(database.path, newest.path)
        XCTAssertGreaterThan(bytes, 0)
    }

    func testUnreadableMailFolderReadsAsAccessDenied() throws {
        let fixture = try MailFixture()
        defer { fixture.remove() }
        try fixture.makeDatabase(version: 10, rows: 1)
        let mail = fixture.home.appendingPathComponent("Library/Mail")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: mail.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mail.path) }
        XCTAssertEqual(MailEnvelopeIndexState.locate(home: fixture.home), .accessDenied)
    }

    func testProbeRecommendsALargeMailIndexAndExplainsTheRest() async throws {
        let fixture = try MailFixture()
        defer { fixture.remove() }
        let database = try fixture.makeDatabase(version: 10, rows: 10)
        var probe = SystemMaintenanceProbe()
        probe.home = fixture.home
        probe.capacity = { VolumeCapacityReading(availableBytes: 10_000_000_000, importantUsageBytes: 25_000_000_000) }
        probe.mailIndex = { _ in .found(database: database, bytes: 400 * 1_024 * 1_024) }
        probe.isMailRunning = { false }
        probe.snapshotDates = { nil }
        probe.periodicScriptsExist = { false }
        probe.lastMailVacuum = { nil }
        let statuses = await probe.statuses()

        XCTAssertEqual(Set(statuses.keys), Set(SystemMaintenanceTaskID.allCases))
        XCTAssertEqual(statuses[.speedUpMail]?.mode, .runnable)
        XCTAssertEqual(statuses[.speedUpMail]?.isRecommended, true, "大于 256 MB 且没整理过")
        XCTAssertNil(statuses[.speedUpMail]?.blocker)
        XCTAssertEqual(statuses[.rebuildLaunchServices]?.mode, .runnable)
        XCTAssertEqual(statuses[.rebuildLaunchServices]?.isRecommended, false, "只在用户遇到问题时才运行")
        XCTAssertEqual(statuses[.maintenanceScripts]?.mode, .notNeeded)
        XCTAssertEqual(statuses[.flushDNS]?.mode, .administratorRequired)
        XCTAssertEqual(statuses[.freeUpMemory]?.mode, .elsewhere(.freeUpMemoryPage))
        XCTAssertEqual(statuses[.timeMachineSnapshots]?.mode, .elsewhere(.timeMachineSettings))
        XCTAssertEqual(statuses[.purgeableSpace]?.mode, .informational)
        // D178: decimal, "15 GB" (was `ByteFormat.string`, binary: "14.0 GiB").
        XCTAssertTrue(statuses[.purgeableSpace]?.lines.first?.contains(ByteFormat.storageString(15_000_000_000)) ?? false)

        probe.isMailRunning = { true }
        probe.lastMailVacuum = { Date().addingTimeInterval(-3_600) }
        let later = await probe.statuses()
        XCTAssertNotNil(later[.speedUpMail]?.blocker, "“邮件”开着时不能运行")
        XCTAssertEqual(later[.speedUpMail]?.isRecommended, false, "刚整理过就不再建议")

        probe.mailIndex = { _ in .accessDenied }
        let denied = await probe.statuses()
        XCTAssertEqual(denied[.speedUpMail]?.needsFullDiskAccess, true)
        XCTAssertEqual(SystemMaintenanceTaskID.flushDNS.administratorCommand?.hasPrefix("sudo "), true)
        XCTAssertNil(SystemMaintenanceTaskID.speedUpMail.administratorCommand)
    }

    // MARK: Speed up Mail

    func testMailIndexIsBackedUpCheckedAndCompacted() async throws {
        let fixture = try MailFixture()
        defer { fixture.remove() }
        let database = try fixture.makeDatabase(version: 10, rows: 3_000, deleteMostRows: true)
        let before = MailEnvelopeIndexState.totalBytes(of: database)
        let recorded = DateBox()

        let result = await MailEnvelopeIndexVacuum.run(environment: fixture.environment(recorded: recorded))

        XCTAssertEqual(result.outcome, .succeeded, result.message)
        let after = MailEnvelopeIndexState.totalBytes(of: database)
        XCTAssertLessThan(after, before, "删除的行留下的空位被回收")
        XCTAssertNotNil(recorded.value, "记下整理时间，用于下次是否建议")
        let backups = try FileManager.default.contentsOfDirectory(atPath: fixture.backupRoot.path)
        XCTAssertEqual(backups.count, 1)
        let backupFile = fixture.backupRoot.appendingPathComponent(backups[0]).appendingPathComponent("Envelope Index")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupFile.path), "整理前留了备份")
        XCTAssertEqual(try fixture.rowCount(at: database), 300, "内容不变")
    }

    func testMailIndexIsLeftAloneWhileMailRuns() async throws {
        let fixture = try MailFixture()
        defer { fixture.remove() }
        let database = try fixture.makeDatabase(version: 10, rows: 500, deleteMostRows: true)
        let before = MailEnvelopeIndexState.totalBytes(of: database)
        var environment = fixture.environment(recorded: DateBox())
        environment.isMailRunning = { true }

        let result = await MailEnvelopeIndexVacuum.run(environment: environment)

        XCTAssertEqual(result.outcome, .refused)
        XCTAssertEqual(MailEnvelopeIndexState.totalBytes(of: database), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backupRoot.path), "拒绝时不做备份")
    }

    func testDamagedIndexOrLowSpaceIsNotCompacted() async throws {
        let fixture = try MailFixture()
        defer { fixture.remove() }
        let database = try fixture.makeDatabase(version: 10, rows: 10)
        var lowSpace = fixture.environment(recorded: DateBox())
        lowSpace.freeBytes = { _ in 1_024 }
        let refused = await MailEnvelopeIndexVacuum.run(environment: lowSpace)
        XCTAssertEqual(refused.outcome, .refused, "空间不够备份和整理")

        try Data(repeating: 0x41, count: 8_192).write(to: database)
        let damaged = await MailEnvelopeIndexVacuum.run(environment: fixture.environment(recorded: DateBox()))
        XCTAssertEqual(damaged.outcome, .refused, damaged.message)
        XCTAssertEqual(try Data(contentsOf: database), Data(repeating: 0x41, count: 8_192), "原样保留")
    }

    func testOnlyThisAppsNewestBackupsAreKept() throws {
        let fixture = try MailFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        try manager.createDirectory(at: fixture.backupRoot, withIntermediateDirectories: true)
        for name in ["Envelope Index 2026-10-01 090000", "Envelope Index 2026-10-05 090000",
                     "Envelope Index 2026-10-09 090000", "Something Else"] {
            try manager.createDirectory(at: fixture.backupRoot.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        MailEnvelopeIndexVacuum.pruneBackups(in: fixture.backupRoot, keeping: 2)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: fixture.backupRoot.path).sorted(),
                       ["Envelope Index 2026-10-05 090000", "Envelope Index 2026-10-09 090000", "Something Else"])
    }

    // MARK: Open With database

    func testLaunchServicesRefreshRunsGarbageCollectionThenRegistration() async {
        let runner = RecordingProcessRunner(statuses: [0, 0])
        let result = await LaunchServicesRefresh.run(runner: runner, executableExists: { _ in true })
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(runner.calls.map(\.arguments), [["-gc"], ["-r", "-f", "-apps", "u,l,s"]])
        XCTAssertTrue(runner.calls.allSatisfy { $0.executable == LaunchServicesRefresh.lsregister })
        XCTAssertFalse(runner.calls.flatMap(\.arguments).contains("-kill"), "不重置默认打开方式")
        XCTAssertFalse(runner.calls.flatMap(\.arguments).contains("-delete"), "不删除数据库、不需要重启")
    }

    func testLaunchServicesRefreshStopsAtTheFirstFailure() async {
        let runner = RecordingProcessRunner(statuses: [1, 0])
        let failed = await LaunchServicesRefresh.run(runner: runner, executableExists: { _ in true })
        XCTAssertEqual(failed.outcome, .failed)
        XCTAssertEqual(runner.calls.count, 1)
        let missing = await LaunchServicesRefresh.run(runner: RecordingProcessRunner(statuses: []), executableExists: { _ in false })
        XCTAssertEqual(missing.outcome, .refused)
    }

    // MARK: Store

    @MainActor
    func testStoreTicksRecommendedTasksAndRunsThemInOrder() async throws {
        var probe = SystemMaintenanceProbe()
        probe.capacity = { VolumeCapacityReading(availableBytes: 1, importantUsageBytes: 2) }
        probe.mailIndex = { _ in .found(database: URL(fileURLWithPath: "/tmp/x"), bytes: 900 * 1_024 * 1_024) }
        probe.isMailRunning = { false }
        probe.snapshotDates = { [] }
        probe.periodicScriptsExist = { true }
        probe.lastMailVacuum = { nil }
        let order = OrderBox()
        var runners = SystemMaintenanceRunners()
        runners.speedUpMail = {
            order.append(.speedUpMail)
            return SystemMaintenanceRunResult(task: .speedUpMail, outcome: .succeeded, message: "ok", finishedAt: Date())
        }
        runners.rebuildLaunchServices = {
            order.append(.rebuildLaunchServices)
            return SystemMaintenanceRunResult(task: .rebuildLaunchServices, outcome: .succeeded, message: "ok", finishedAt: Date())
        }
        let copied = StringBox()
        let store = SystemMaintenanceStore(coordinator: HeavyWorkCoordinator(), probe: probe, runners: runners,
                                           openURL: { _ in }, copyText: { copied.value = $0 })
        store.refresh()
        try await waitUntil { store.hasStatuses && !store.isRefreshing }
        XCTAssertEqual(store.selectedTasks, [.speedUpMail], "建议的任务默认勾选")
        XCTAssertEqual(store.summary.recommendedCount, 1)
        store.toggle(.flushDNS)
        XCTAssertFalse(store.isSelected(.flushDNS), "需要管理员的任务不能勾选")
        store.toggle(.rebuildLaunchServices)
        store.copyAdministratorCommand(.flushDNS)
        XCTAssertEqual(copied.value, SystemMaintenanceTaskID.flushDNS.administratorCommand)

        store.runSelected()
        try await waitUntil { store.results.count == 2 && !store.isRunning }
        XCTAssertEqual(order.values, [.speedUpMail, .rebuildLaunchServices])
        XCTAssertEqual(store.results[.speedUpMail]?.outcome, .succeeded)
    }

    /// D168, batch 3M (2.0.1 review): Smart Care runs the tasks the user
    /// confirmed; ticking or unticking on this page meanwhile changes nothing.
    @MainActor
    func testRunningConfirmedTasksIgnoresALaterChangedSelection() async throws {
        var probe = SystemMaintenanceProbe()
        probe.capacity = { VolumeCapacityReading(availableBytes: 1, importantUsageBytes: 2) }
        probe.mailIndex = { _ in .found(database: URL(fileURLWithPath: "/tmp/x"), bytes: 900 * 1_024 * 1_024) }
        probe.isMailRunning = { false }
        probe.snapshotDates = { [] }
        probe.periodicScriptsExist = { true }
        probe.lastMailVacuum = { nil }
        let order = OrderBox()
        var runners = SystemMaintenanceRunners()
        runners.speedUpMail = {
            order.append(.speedUpMail)
            return SystemMaintenanceRunResult(task: .speedUpMail, outcome: .succeeded, message: "ok", finishedAt: Date())
        }
        runners.rebuildLaunchServices = {
            order.append(.rebuildLaunchServices)
            return SystemMaintenanceRunResult(task: .rebuildLaunchServices, outcome: .succeeded, message: "ok", finishedAt: Date())
        }
        let store = SystemMaintenanceStore(coordinator: HeavyWorkCoordinator(), probe: probe, runners: runners,
                                           openURL: { _ in }, copyText: { _ in })
        store.refresh()
        try await waitUntil { store.hasStatuses && !store.isRefreshing }
        let confirmed = store.selectedTasks
        XCTAssertEqual(confirmed, [.speedUpMail])

        store.toggle(.speedUpMail)
        store.toggle(.rebuildLaunchServices)
        XCTAssertEqual(store.selectedTasks, [.rebuildLaunchServices])
        store.run(confirmed)
        try await waitUntil { store.results[.speedUpMail] != nil && !store.isRunning }

        XCTAssertEqual(order.values, [.speedUpMail], "only the confirmed task ran")
        XCTAssertNil(store.results[.rebuildLaunchServices])
    }

    /// Report §4 item 13 (`cmm/24`): the Performance tile counts the
    /// recommended tasks as Smart Care does, and Run Tasks hands over only
    /// the recommended ones that can run, not what else is ticked on the
    /// maintenance page; while they run it waits, then says what ran.
    @MainActor
    func testPerformanceTileRunsOnlyTheRecommendedTasks() async throws {
        var probe = SystemMaintenanceProbe()
        probe.capacity = { VolumeCapacityReading(availableBytes: 1, importantUsageBytes: 2) }
        probe.mailIndex = { _ in .found(database: URL(fileURLWithPath: "/tmp/x"), bytes: 900 * 1_024 * 1_024) }
        probe.isMailRunning = { false }
        probe.snapshotDates = { [] }
        probe.periodicScriptsExist = { true }
        probe.lastMailVacuum = { nil }
        let gate = RunGate()
        let order = OrderBox()
        var runners = SystemMaintenanceRunners()
        runners.speedUpMail = {
            await gate.wait()
            order.append(.speedUpMail)
            return SystemMaintenanceRunResult(task: .speedUpMail, outcome: .succeeded, message: "ok", finishedAt: Date())
        }
        runners.rebuildLaunchServices = {
            order.append(.rebuildLaunchServices)
            return SystemMaintenanceRunResult(task: .rebuildLaunchServices, outcome: .succeeded, message: "ok", finishedAt: Date())
        }
        let store = SystemMaintenanceStore(coordinator: HeavyWorkCoordinator(), probe: probe, runners: runners,
                                           openURL: { _ in }, copyText: { _ in })
        store.refresh()
        try await waitUntil { store.hasStatuses && !store.isRefreshing }
        store.toggle(.rebuildLaunchServices)
        XCTAssertEqual(store.selectedTasks, [.speedUpMail, .rebuildLaunchServices])
        XCTAssertEqual(store.recommendedTasks, [.speedUpMail])

        var handed: [SystemMaintenanceTaskID]?
        let tile = CareStudioTileModel.maintenance(store, onReview: {}) { handed = $0 }
        XCTAssertEqual(tile.title, L10n.text("1 个维护任务推荐", "1 Maintenance Task Recommended"))
        XCTAssertEqual(tile.reviewTitle, L10n.text("查看", "Review"))
        XCTAssertEqual(tile.art, .tileMaintenance)
        XCTAssertEqual(tile.cleanTitle, L10n.text("运行任务", "Run Tasks"))
        XCTAssertTrue(tile.cleanEnabled)
        XCTAssertNil(tile.note)
        tile.onClean?()
        XCTAssertEqual(handed, [.speedUpMail], "only the recommended task is asked about")

        store.run(try XCTUnwrap(handed))
        try await waitUntil { store.isRunning }
        let running = CareStudioTileModel.maintenance(store, onReview: {}) { _ in XCTFail("nothing more runs meanwhile") }
        XCTAssertEqual(running.cleanTitle, L10n.text("正在运行…", "Running…"))
        XCTAssertFalse(running.cleanEnabled)
        running.onClean?()
        await gate.open()
        try await waitUntil { !store.isRunning && store.results[.speedUpMail] != nil }
        XCTAssertEqual(order.values, [.speedUpMail], "the ticked task that is not recommended did not run")
        let done = CareStudioTileModel.maintenance(store, onReview: {}) { _ in }
        XCTAssertEqual(done.note, L10n.text("已运行 1 项，结果在“查看”里", "1 task ran; see Review for the result"))
    }

    /// Without a recommendation the tile is Review only, as CleanMyMac's.
    @MainActor
    func testPerformanceTileWithoutRecommendationsOnlyReviews() {
        let store = SystemMaintenanceStore(coordinator: HeavyWorkCoordinator(), probe: SystemMaintenanceProbe(),
                                           runners: SystemMaintenanceRunners(), openURL: { _ in }, copyText: { _ in })
#if DEBUG
        store.installPreview(statuses: [.speedUpMail: SystemMaintenanceStatus(mode: .runnable),
                                        .rebuildLaunchServices: SystemMaintenanceStatus(mode: .runnable)],
                             selection: [.speedUpMail])
#endif
        let tile = CareStudioTileModel.maintenance(store, onReview: {}) { _ in XCTFail("nothing to run") }
        XCTAssertEqual(tile.title, L10n.text("维护任务", "Maintenance Tasks"))
        XCTAssertNil(tile.cleanTitle)
        XCTAssertTrue(store.recommendedTasks.isEmpty)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("等待超时"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

final class DateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date?
    var value: Date? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ date: Date) { lock.lock(); stored = date; lock.unlock() }
}

final class StringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Holds a fake maintenance runner until the test lets it finish.
private actor RunGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

final class OrderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SystemMaintenanceTaskID] = []
    var values: [SystemMaintenanceTaskID] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ id: SystemMaintenanceTaskID) { lock.lock(); stored.append(id); lock.unlock() }
}

final class RecordingProcessRunner: StartupItemsDomain.StartupProcessRunning, @unchecked Sendable {
    struct Call { let executable: URL; let arguments: [String] }
    private let lock = NSLock()
    private var statuses: [Int32]
    private var recorded: [Call] = []
    init(statuses: [Int32]) { self.statuses = statuses }
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }

    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws
        -> StartupItemsDomain.StartupProcessResult {
        let status = lock.withLock { () -> Int32 in
            recorded.append(Call(executable: executableURL, arguments: arguments))
            return statuses.isEmpty ? 0 : statuses.removeFirst()
        }
        return StartupItemsDomain.StartupProcessResult(standardOutput: "", standardError: status == 0 ? "" : "failed",
                                                       terminationStatus: status)
    }
}

struct MailFixture {
    let base: URL
    var home: URL { base.appendingPathComponent("home", isDirectory: true) }
    var backupRoot: URL { base.appendingPathComponent("Backups", isDirectory: true) }

    init() throws {
        base = TestFileSystem.uniqueOperationRoot("system-maintenance")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    @discardableResult
    func makeDatabase(version: Int, rows: Int, deleteMostRows: Bool = false) throws -> URL {
        let folder = home.appendingPathComponent("Library/Mail/V\(version)/MailData", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Envelope Index")
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(handle) }
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL; CREATE TABLE messages(id INTEGER PRIMARY KEY, body BLOB);", nil, nil, nil)
        sqlite3_exec(handle, "BEGIN;", nil, nil, nil)
        for index in 0..<rows {
            sqlite3_exec(handle, "INSERT INTO messages(id, body) VALUES(\(index), zeroblob(1024));", nil, nil, nil)
        }
        sqlite3_exec(handle, "COMMIT;", nil, nil, nil)
        if deleteMostRows {
            sqlite3_exec(handle, "DELETE FROM messages WHERE id >= \(rows / 10);", nil, nil, nil)
        }
        sqlite3_exec(handle, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
        return url
    }

    func rowCount(at url: URL) throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else { return -1 }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(handle, "SELECT count(*) FROM messages;", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func environment(recorded: DateBox) -> MailVacuumEnvironment {
        var environment = MailVacuumEnvironment()
        environment.home = home
        environment.backupRoot = backupRoot
        environment.isMailRunning = { false }
        environment.freeBytes = { _ in 500_000_000_000 }
        environment.recordRun = { recorded.set($0) }
        return environment
    }

    func remove() { TestFileSystem.remove(base) }
}
