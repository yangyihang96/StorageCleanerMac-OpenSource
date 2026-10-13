import CSQLite
import Foundation
import Darwin
import XCTest
@testable import StorageCleanerMac

final class BrowserPrivacyDataTests: XCTestCase {
    struct Running: BrowserPrivacyRunningApplicationChecking {
        let isRunning: Bool
        func runningBundleIdentifiers(matching ids: Set<String>) async -> Set<String> { isRunning ? ids : [] }
    }
    struct Fixture {
        let root: URL
        let profile: BrowserPrivacyProfile
        let recovery: BrowserPrivacyRecoveryBackupService
        let service: BrowserPrivacyDataService
        let file: URL
    }
    private static let chromeCookieSchema = """
    CREATE TABLE cookies(creation_utc INTEGER NOT NULL,host_key TEXT NOT NULL,top_frame_site_key TEXT NOT NULL,name TEXT NOT NULL,value TEXT NOT NULL,encrypted_value BLOB NOT NULL,path TEXT NOT NULL,expires_utc INTEGER NOT NULL,is_secure INTEGER NOT NULL,is_httponly INTEGER NOT NULL,last_access_utc INTEGER NOT NULL,has_expires INTEGER NOT NULL,is_persistent INTEGER NOT NULL,priority INTEGER NOT NULL,samesite INTEGER NOT NULL,source_scheme INTEGER NOT NULL,source_port INTEGER NOT NULL,last_update_utc INTEGER NOT NULL,source_type INTEGER NOT NULL,has_cross_site_ancestor INTEGER NOT NULL);
    CREATE UNIQUE INDEX cookies_unique_index ON cookies(host_key,top_frame_site_key,has_cross_site_ancestor,name,path,source_scheme,source_port);
    CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
    INSERT INTO meta VALUES('version','24');
    """
    private static let firefoxCookieSchema = """
    CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, originAttributes TEXT NOT NULL DEFAULT '', name TEXT, value TEXT, host TEXT, path TEXT, expiry INTEGER, lastAccessed INTEGER, creationTime INTEGER, isSecure INTEGER, isHttpOnly INTEGER, inBrowserElement INTEGER DEFAULT 0, sameSite INTEGER DEFAULT 0, schemeMap INTEGER DEFAULT 0, isPartitionedAttributeSet INTEGER DEFAULT 0, CONSTRAINT moz_uniqueid UNIQUE (name, host, path, originAttributes));
    """
    private static func chromeInsert(_ host: String, _ name: String, payload: String = "SECRET") -> String {
        "INSERT INTO cookies VALUES(0,'\(host)','','\(name)','\(payload)',X'00','/',0,0,0,0,0,0,0,0,0,0,0,0,0);"
    }
    private func fixture(_ contract: BrowserPrivacyDataContract = .chromiumCookies, running: Bool = false) throws -> Fixture {
        let root = TestFileSystem.uniqueRoot("privacy-data")
        TestFileSystem.registerCleanup(of: root, for: self)
        let profileRoot = root.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        let file = profileRoot.appendingPathComponent(contract.relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        let database = try XCTUnwrap(db)
        defer { sqlite3_close(database) }
        let sql: String
        switch contract {
        case .chromiumCookies, .chromiumNetworkCookies:
            // Chromium 131.0.6761.0 CreateV23Schema / CreateV24Schema.
            sql = Self.chromeCookieSchema + Self.chromeInsert(".example.test", "a") + Self.chromeInsert(".example.test", "b") + Self.chromeInsert("keep.test", "c")
        case .firefoxCookies:
            // Mozilla CookiePersistentStorage::CreateTableWorker, schema 16.
            sql = Self.firefoxCookieSchema + "INSERT INTO moz_cookies(host,name,path) VALUES('keep.test','c','/'),('.example.test','a','/'),('.example.test','b','/');"
        case .chromiumAutofill:
            sql = "CREATE TABLE autofill(name VARCHAR, value VARCHAR, value_lower VARCHAR, date_created INTEGER DEFAULT 0, date_last_used INTEGER DEFAULT 0, count INTEGER DEFAULT 1, PRIMARY KEY(name,value)); INSERT INTO autofill(name,value,value_lower) VALUES('email','SECRET','secret'),('email','OTHER','other'),('address','SECRET','secret'); CREATE TABLE credit_cards(secret TEXT); INSERT INTO credit_cards VALUES('KEEP'); CREATE TABLE logins(secret TEXT); INSERT INTO logins VALUES('KEEP');"
        case .firefoxAutofill:
            sql = "CREATE TABLE moz_formhistory(fieldname TEXT,secret TEXT); INSERT INTO moz_formhistory VALUES('email','SECRET'),('email','SECRET'),('address','SECRET');"
        case .chromiumDownloads:
            // Chromium c0c15e325e381f86795e51f236354b6727fef532 download_database.cc;
            // historical reroute schema: 85a072b23bde4aebb0d4e65074a6398f092e0854.
            sql = """
            CREATE TABLE downloads (id INTEGER PRIMARY KEY,guid VARCHAR NOT NULL,current_path LONGVARCHAR NOT NULL,target_path LONGVARCHAR NOT NULL,start_time INTEGER NOT NULL,received_bytes INTEGER NOT NULL,total_bytes INTEGER NOT NULL,state INTEGER NOT NULL,danger_type INTEGER NOT NULL,interrupt_reason INTEGER NOT NULL,hash BLOB NOT NULL,end_time INTEGER NOT NULL,opened INTEGER NOT NULL,last_access_time INTEGER NOT NULL,transient INTEGER NOT NULL,referrer VARCHAR NOT NULL,site_url VARCHAR NOT NULL,embedder_download_data VARCHAR NOT NULL,tab_url VARCHAR NOT NULL,tab_referrer_url VARCHAR NOT NULL,http_method VARCHAR NOT NULL,by_ext_id VARCHAR NOT NULL,by_ext_name VARCHAR NOT NULL,by_web_app_id VARCHAR NOT NULL,etag VARCHAR NOT NULL,last_modified VARCHAR NOT NULL,mime_type VARCHAR(255) NOT NULL,original_mime_type VARCHAR(255) NOT NULL);
            INSERT INTO downloads VALUES(1,'fixture','opaque','opaque',0,0,0,0,0,0,X'',0,0,0,0,'','','','','','GET','','','','','','','');
            CREATE TABLE downloads_url_chains (id INTEGER NOT NULL,chain_index INTEGER NOT NULL,url LONGVARCHAR NOT NULL,PRIMARY KEY(id,chain_index));
            INSERT INTO downloads_url_chains VALUES(1,0,'opaque');
            CREATE TABLE downloads_slices (download_id INTEGER NOT NULL,offset INTEGER NOT NULL,received_bytes INTEGER NOT NULL,finished INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(download_id,offset));
            INSERT INTO downloads_slices VALUES(1,0,0,0),(1,64,64,1);
            CREATE TABLE downloads_reroute_info (download_id INTEGER NOT NULL,reroute_info_serialized VARCHAR NOT NULL,PRIMARY KEY(download_id));
            INSERT INTO downloads_reroute_info VALUES(1,'opaque');
            CREATE TABLE urls(id INTEGER); INSERT INTO urls VALUES(77);
            """
        case .firefoxLegacyStorage:
            sql = "CREATE TABLE webappsstore2(originKey TEXT,key TEXT,secret TEXT); INSERT INTO webappsstore2 VALUES('tset.elpmaxe.:https:443','a','SECRET'),('tset.elpmaxe.:https:443','b','SECRET'),('tset.peek.:https:443','c','SECRET');"
        }
        try BrowserPrivacyDataService.exec(database, sql)
        let browser = BrowserPrivacyBrowser(id: contract.engine == .firefox ? "firefox" : "chrome", displayName: "Fixture", engine: contract.engine, bundleIdentifier: "fixture.browser", version: nil)
        let profile = BrowserPrivacyProfile(id: "fixture:Default", browser: browser, displayName: "Default", historyDatabaseURL: profileRoot.appendingPathComponent("History"), sourceTrustedParentURL: root)
        let snapshotRoot = root.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
        let snapshots = SQLiteSnapshotService(temporaryRoot: snapshotRoot)
        let recovery = BrowserPrivacyRecoveryBackupService(rootURL: root.appendingPathComponent("recovery", isDirectory: true), snapshotService: snapshots, excludeFromTimeMachine: { _ in })
        let service = BrowserPrivacyDataService(homeDirectory: root, recovery: recovery, snapshots: snapshots, running: Running(isRunning: running), fixtureRoot: root)
        return .init(root: root, profile: profile, recovery: recovery, service: service, file: file)
    }

    func testEverySQLiteAdapterGroupsDeletesReadsBackAndRestores() async throws {
        for contract in BrowserPrivacyDataContract.allCases where contract.permitsDeletion {
            let f = try fixture(contract)
            let original = try await f.service.scan(profile: f.profile, contract: contract)
            XCTAssertFalse(original.isEmpty)
            XCTAssertTrue(original.allSatisfy { !$0.isDefaultSelected })
            let row = try XCTUnwrap(original.first)
            let count = try await f.service.delete([row], keeping: [])
            XCTAssertEqual(count, row.count)
            let after = try await f.service.scan(profile: f.profile, contract: contract)
            XCTAssertFalse(after.contains { $0.key == row.key })
            let entry = try XCTUnwrap(f.recovery.entries().first)
            XCTAssertEqual(entry.dataContract, contract)
            XCTAssertFalse(FileManager.default.fileExists(atPath: entry.backup.databaseURL.deletingLastPathComponent().appendingPathComponent("Original.sqlite").path))
            XCTAssertEqual(entry.rowBackup, contract.usesRowBackup)
            let restored = await f.service.restore(entry, profiles: [f.profile])
            XCTAssertTrue(restored.succeeded, restored.detail)
            let readback = try await f.service.scan(profile: f.profile, contract: contract)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: readback.map { ($0.key, $0.count) }), Dictionary(uniqueKeysWithValues: original.map { ($0.key, $0.count) }))
            XCTAssertEqual(restored.undoBackupID == nil, contract.usesRowBackup)
            XCTAssertNotNil(f.recovery.entries().first { $0.id == entry.id }?.restoredAt)
        }
    }
    func testRunningBrowserRefusesBeforeBackupAndRestore() async throws {
        let f = try fixture(running: true)
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        do { _ = try await f.service.delete(rows, keeping: []); XCTFail("Must refuse") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .browserRunning) }
        XCTAssertTrue(f.recovery.entries().isEmpty)
    }
    func testWhitelistProtectsExactSiteAndDotVariants() async throws {
        let f = try fixture()
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        let count = try await f.service.delete(rows, keeping: [".EXAMPLE.TEST"])
        XCTAssertEqual(count, 1)
        let after = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        XCTAssertEqual(after.map(\.site), ["example.test"])
        XCTAssertEqual(after.first?.count, 2)
    }
    func testTransactionFailureRollsBackAndKeepsBackup() async throws {
        let f = try fixture()
        var failing = f.service
        failing.beforeReadback = { throw BrowserPrivacyDataFailure.readback }
        let rows = try await failing.scan(profile: f.profile, contract: .chromiumCookies)
        do { _ = try await failing.delete(rows, keeping: []); XCTFail("Must fail") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .readback) }
        let after = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        XCTAssertEqual(after.map(\.count), rows.map(\.count))
        XCTAssertEqual(f.recovery.entries().count, 1) // Sealed rows precede the deletion transaction.
    }
    func testBackupFailurePreventsDeletion() async throws {
        let f = try fixture()
        let bad = BrowserPrivacyRecoveryBackupService(rootURL: f.root.appendingPathComponent("bad"), excludeFromTimeMachine: { _ in throw BrowserPrivacyDataFailure.database })
        let service = BrowserPrivacyDataService(homeDirectory: f.root, recovery: bad, snapshots: f.service.snapshots, running: Running(isRunning: false), fixtureRoot: f.root)
        let rows = try await service.scan(profile: f.profile, contract: .chromiumCookies)
        do { _ = try await service.delete(rows, keeping: []); XCTFail("Must fail") } catch { }
        let after = try await service.scan(profile: f.profile, contract: .chromiumCookies)
        XCTAssertEqual(after.map(\.count), rows.map(\.count))
    }
    func testChangedCountsRefuseAndDoNotDelete() async throws {
        let f = try fixture()
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        try BrowserPrivacyDataService.open(f.file, writable: true) { try BrowserPrivacyDataService.exec($0, Self.chromeInsert(".example.test", "new")) }
        do { _ = try await f.service.delete(rows, keeping: []); XCTFail("Must fail") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .changed) }
        let after = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        XCTAssertEqual(after.reduce(0) { $0 + $1.count }, 4)
    }
    func testRowTransactionsPreserveSourceWALMode() async throws {
        let f = try fixture()
        var phase = "setup"
        do {
            try BrowserPrivacyDataService.open(f.file, writable: true) { try BrowserPrivacyDataService.exec($0, "PRAGMA journal_mode=WAL") }
            phase = "direct metadata"
            let direct = try BrowserPrivacyDataService.open(f.file, writable: false) { try BrowserPrivacyDataService.groups($0, .chromiumCookies) }
            XCTAssertEqual(direct.values.reduce(0, +), 3)
            phase = "scan"
            let rows = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
            phase = "delete"
            _ = try await f.service.delete(rows, keeping: [])
            let entry = try XCTUnwrap(f.recovery.entries().first)
            phase = "restore"
            let restored = await f.service.restore(entry, profiles: [f.profile])
            XCTAssertTrue(restored.succeeded, restored.detail)
            phase = "fresh count"
            XCTAssertEqual(try count(f.file, "cookies"), 3)
            phase = "read journal mode"
            try BrowserPrivacyDataService.open(f.file, writable: true) { db in
                let control = SQLiteExecutionControl(deadlineNanoseconds: MonotonicClock.now + 2_000_000_000)
                let statement = try SQLiteRuntime.prepare("PRAGMA journal_mode", database: db, control: control, busyDeadlineNanoseconds: MonotonicClock.now + 1_000_000_000)
                defer { sqlite3_finalize(statement) }
                XCTAssertEqual(try SQLiteRuntime.step(statement, control: control, busyDeadlineNanoseconds: MonotonicClock.now + 1_000_000_000), SQLITE_ROW)
                let text = try XCTUnwrap(sqlite3_column_text(statement, 0))
                XCTAssertEqual(String(cString: text), "wal")
            }
        } catch { XCTFail("WAL stage \(phase): \(error)") }
    }
    func testPendingSidecarRefusesAndEmptySidecarIsBackedUp() async throws {
        let f = try fixture()
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        let wal = URL(fileURLWithPath: f.file.path + "-wal")
        try Data([1]).write(to: wal)
        do { _ = try await f.service.delete(rows, keeping: []); XCTFail("Must refuse") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .pendingWrites) }
        XCTAssertTrue(f.recovery.entries().isEmpty)
        try Data().write(to: wal)
        _ = try await f.service.delete(rows, keeping: [])
        let backup = try XCTUnwrap(f.recovery.entries().first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.backup.databaseURL.deletingLastPathComponent().appendingPathComponent("Original.sqlite-wal").path))
        XCTAssertTrue(backup.rowBackup)
    }
    func testDownloadsLeaveFilesAndHistoryIntact() async throws {
        let f = try fixture(.chromiumDownloads)
        let downloaded = f.root.appendingPathComponent("download.pdf")
        try Data("original file".utf8).write(to: downloaded)
        try BrowserPrivacyDataService.open(f.file, writable: true) { db in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "UPDATE downloads SET target_path=?1,current_path=?1 WHERE id=1", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            XCTAssertEqual(downloaded.path.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }, SQLITE_OK)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumDownloads)
        _ = try await f.service.delete(rows, keeping: [])
        XCTAssertEqual(try Data(contentsOf: downloaded), Data("original file".utf8))
        try BrowserPrivacyDataService.open(f.file, writable: false) { db in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM urls WHERE id=77", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
        }
    }
    func testSafariAndUnknownIdentityNeverWritable() async throws {
        let f = try fixture()
        let service = BrowserPrivacyDataService(homeDirectory: f.root, recovery: f.recovery, snapshots: f.service.snapshots, running: Running(isRunning: false))
        let rows = try await service.scan(profile: f.profile, contract: .chromiumCookies)
        XCTAssertTrue(rows.allSatisfy { !$0.writable })
        do { _ = try await service.delete(rows, keeping: []); XCTFail("Must refuse") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .unsupported) }
        XCTAssertFalse(BrowserPrivacyDataContract.allCases.contains { $0.engine == .safari })
    }
    func testCookieHostVariantsAreOneSiteGroup() async throws {
        let f = try fixture()
        try BrowserPrivacyDataService.open(f.file, writable: true) { try BrowserPrivacyDataService.exec($0, Self.chromeInsert("example.test", "d")) }
        let groups = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        let site = try XCTUnwrap(groups.first { $0.site == "example.test" })
        XCTAssertEqual(site.count, 3)
        XCTAssertEqual(site.deletionCounts.count, 2)
        let deleted = try await f.service.delete([site], keeping: [])
        XCTAssertEqual(deleted, 3)
    }
    func testUnknownTriggersCannotTouchCredentialTables() async throws {
        let f = try fixture(.chromiumAutofill)
        try BrowserPrivacyDataService.open(f.file, writable: true) { try BrowserPrivacyDataService.exec($0, "CREATE TRIGGER malicious AFTER DELETE ON autofill BEGIN DELETE FROM credit_cards; END") }
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumAutofill)
        XCTAssertFalse(rows.isEmpty) // Read-only grouping does not execute triggers.
        do { _ = try await f.service.delete(rows, keeping: []); XCTFail("Must refuse trigger writes") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .unsupported) }
        XCTAssertEqual(try count(f.file, "credit_cards"), 1)
        XCTAssertTrue(f.recovery.entries().isEmpty)
    }
    func testRestoreRefusesRunningBrowserAndPreservesCurrentState() async throws {
        let f = try fixture()
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        _ = try await f.service.delete(rows, keeping: [])
        let entry = try XCTUnwrap(f.recovery.entries().first)
        let running = BrowserPrivacyDataService(homeDirectory: f.root, recovery: f.recovery, snapshots: f.service.snapshots, running: Running(isRunning: true), fixtureRoot: f.root)
        let result = await running.restore(entry, profiles: [f.profile])
        XCTAssertEqual(result.reason, .browserRunning)
        XCTAssertFalse(result.historyMayHaveChanged)
        XCTAssertEqual(f.recovery.entries().count, 1)
    }
    func testBackupExistsBeforeTransactionReadback() async throws {
        let f = try fixture()
        var service = f.service
        let root = f.root.appendingPathComponent("recovery", isDirectory: true)
        service.beforeReadback = {
            let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            guard entries.contains(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("History.backup.sqlite").path) }) else { throw BrowserPrivacyDataFailure.changed }
        }
        let rows = try await service.scan(profile: f.profile, contract: .chromiumCookies)
        let deleted = try await service.delete(rows, keeping: [])
        XCTAssertEqual(deleted, 3)
    }
    @MainActor func testKeepListAndDefaultSelectionUseIsolatedPreferences() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let store = BrowserPrivacyDataStore(defaults: defaults)
        XCTAssertTrue(store.selection.isEmpty)
        store.keep(".EXAMPLE.TEST")
        XCTAssertEqual(store.keepingSites, ["example.test"])
        let reloaded = BrowserPrivacyDataStore(defaults: defaults)
        XCTAssertEqual(reloaded.keepingSites, ["example.test"])
        reloaded.unkeep(".EXAMPLE.TEST")
        XCTAssertTrue(reloaded.keepingSites.isEmpty)
    }

    /// The fake connection records the SQL passed to the native temporary
    /// connection. It can report faulty change counts or post-commit reads.
    final class FakeConnection: @unchecked Sendable {
        private let lock = NSLock()
        private var statements: [String] = []
        func record(_ sql: String) { lock.withLock { statements.append(sql) } }
        var sql: [String] { lock.withLock { statements } }
    }
    private func count(_ file: URL, _ table: String, where predicate: String? = nil) throws -> Int {
        try BrowserPrivacyDataService.open(file, writable: false) { db in
            let control = SQLiteExecutionControl(deadlineNanoseconds: MonotonicClock.now + 2_000_000_000)
            let statement = try SQLiteRuntime.prepare("SELECT COUNT(*) FROM \(table)" + (predicate.map { " WHERE " + $0 } ?? ""), database: db, control: control, busyDeadlineNanoseconds: MonotonicClock.now + 1_000_000_000)
            defer { sqlite3_finalize(statement) }
            guard try SQLiteRuntime.step(statement, control: control, busyDeadlineNanoseconds: MonotonicClock.now + 1_000_000_000) == SQLITE_ROW else { throw BrowserPrivacyDataFailure.database }
            return Int(sqlite3_column_int(statement, 0))
        }
    }
    func testConnectionReadsMetadataOnlyAndCopiesPayloadInsideSQLite() async throws {
        let f = try fixture(.chromiumAutofill)
        let fake = FakeConnection()
        var service = f.service
        service.observeSQL = { fake.record($0) }
        let rows = try await service.scan(profile: f.profile, contract: .chromiumAutofill)
        _ = try await service.delete(rows, keeping: [])
        let entry = try XCTUnwrap(f.recovery.entries().first)
        let result = await service.restore(entry, profiles: [f.profile])
        XCTAssertTrue(result.succeeded, result.detail)
        let reads = fake.sql.filter { $0.uppercased().hasPrefix("SELECT") }
        XCTAssertFalse(reads.isEmpty)
        let dataReads = reads.filter { $0.contains("FROM autofill") }
        XCTAssertFalse(dataReads.isEmpty)
        XCTAssertTrue(dataReads.allSatisfy { $0 == "SELECT name, COUNT(*) FROM autofill GROUP BY name ORDER BY name LIMIT 10001" })
        XCTAssertFalse(reads.contains { !$0.hasPrefix("SELECT COUNT(*)") && ($0.contains("value") || $0.contains("secret") || $0.contains("*") && !$0.contains("COUNT(*)")) })
        XCTAssertTrue(fake.sql.contains { $0.hasPrefix("INSERT INTO main.autofill SELECT * FROM source.autofill WHERE name=?1") })
        XCTAssertTrue(fake.sql.contains { $0.hasPrefix("INSERT OR IGNORE INTO main.autofill (") })
        XCTAssertTrue(fake.sql.contains("PRAGMA secure_delete=ON"))
        let statements = fake.sql
        for index in statements.indices where statements[index] == "BEGIN IMMEDIATE" {
            let end = try XCTUnwrap(statements[(index + 1)...].firstIndex(of: "COMMIT"))
            XCTAssertTrue(statements[(index + 1)..<end].contains("PRAGMA secure_delete=ON"))
        }
        XCTAssertLessThan(try XCTUnwrap(statements.firstIndex { $0.hasPrefix("INSERT INTO main.autofill") }),
                          try XCTUnwrap(statements.firstIndex { $0.hasPrefix("DELETE FROM autofill") }))
        XCTAssertEqual(try count(f.file, "credit_cards"), 1)
        XCTAssertEqual(try count(f.file, "logins"), 1)
        XCTAssertNotNil(f.recovery.entries().first { $0.id == entry.id }?.restoredAt)
    }
    func testSameCountReplacementAfterArchiveRefusesDeletion() async throws {
        let f = try fixture()
        var service = f.service
        service.afterRowArchive = {
            try BrowserPrivacyDataService.open(f.file, writable: true) {
                try BrowserPrivacyDataService.exec($0, "UPDATE cookies SET value='NEW' WHERE host_key='.example.test'")
            }
        }
        let rows = try await service.scan(profile: f.profile, contract: .chromiumCookies)
        do { _ = try await service.delete(rows, keeping: []); XCTFail("Equal counts cannot authorize deletion of replaced rows") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .changed) }
        XCTAssertEqual(try count(f.file, "cookies"), 3)
        XCTAssertEqual(try count(f.file, "cookies", where: "value='NEW'"), 2)
        XCTAssertEqual(try count(try XCTUnwrap(f.recovery.entries().first).backup.databaseURL, "cookies"), 3)
    }
    func testLegacyWholeCookieBackupCannotOverwriteCurrentData() async throws {
        let f = try fixture()
        let source = SQLiteSnapshotSource(databaseURL: f.file, trustedParentURL: f.root)
        let backup = try await f.recovery.backup(source: source, schema: BrowserPrivacyDataContract.chromiumCookies.schema, browserID: "chrome", profileID: f.profile.id, deadlineNanoseconds: MonotonicClock.now + 10_000_000_000)
        try f.recovery.setDataContract(.chromiumCookies, for: backup)
        await f.recovery.annotate(backup, summary: .init(browserDisplayName: "Fixture", profileDisplayName: "Default", visitCount: 3, pageCount: nil, outcome: .deleted, dataContract: .chromiumCookies), sparing: [])
        let entry = try XCTUnwrap(f.recovery.entries().first)
        XCTAssertFalse(entry.canRestore)
        let result = await f.service.restore(entry, profiles: [f.profile])
        XCTAssertEqual(result.reason, .unsupportedDataFormat)
        XCTAssertFalse(result.historyMayHaveChanged)
        XCTAssertEqual(try count(f.file, "cookies"), 3)
        XCTAssertNil(f.recovery.entries().first?.restoredAt)
    }
    func testDeletionChangeCountMismatchRollsBack() async throws {
        let f = try fixture()
        var service = f.service
        service.reportedChanges = { $0 + 1 }
        let rows = try await service.scan(profile: f.profile, contract: .chromiumCookies)
        do { _ = try await service.delete(rows, keeping: []); XCTFail("Must reject false change count") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .readback) }
        XCTAssertEqual(try count(f.file, "cookies"), 3)
        XCTAssertEqual(f.recovery.entries().count, 1)
        XCTAssertEqual(try count(try XCTUnwrap(f.recovery.entries().first).backup.databaseURL, "cookies"), 3)
    }
    func testTransactionReadbackMismatchRollsBack() async throws {
        let f = try fixture()
        var service = f.service
        service.transactionGroups = { _ in ["unexpected": 1] }
        let rows = try await service.scan(profile: f.profile, contract: .chromiumCookies)
        do { _ = try await service.delete(rows, keeping: []); XCTFail("Transaction readback must refuse mismatched groups") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .readback) }
        XCTAssertEqual(try count(f.file, "cookies"), 3)
        XCTAssertEqual(try count(try XCTUnwrap(f.recovery.entries().first).backup.databaseURL, "cookies"), 3)
    }
    func testPostCommitReadbackMismatchKeepsRecoverableRows() async throws {
        let f = try fixture()
        var service = f.service
        service.committedGroups = { _ in ["unexpected": 1] }
        let rows = try await service.scan(profile: f.profile, contract: .chromiumCookies)
        do { _ = try await service.delete(rows, keeping: []); XCTFail("Must reject fresh read mismatch") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .readback) }
        let entry = try XCTUnwrap(f.recovery.entries().first)
        XCTAssertEqual(entry.summary?.outcome, .unverified)
        XCTAssertFalse(BrowserPrivacyRecoveryText.summary(for: entry).contains("0"), "An unconfirmed count must not be displayed as zero")
        XCTAssertEqual(try count(entry.backup.databaseURL, "cookies"), 3)
        let restored = await f.service.restore(entry, profiles: [f.profile])
        XCTAssertTrue(restored.succeeded, restored.detail)
        XCTAssertEqual(try count(f.file, "cookies"), 3)
    }
    func testDownloadForeignKeysAndUnknownAssociatedTables() async throws {
        let f = try fixture(.chromiumDownloads)
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumDownloads)
        try BrowserPrivacyDataService.open(f.file, writable: true) { try BrowserPrivacyDataService.exec($0, "CREATE TABLE downloads_future(download_id INTEGER); INSERT INTO downloads_future VALUES(1)") }
        do { _ = try await f.service.delete(rows, keeping: []); XCTFail("Unknown table must refuse") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .unknownDownloadTable) }
        XCTAssertEqual(try count(f.file, "downloads"), 1)
        XCTAssertEqual(try count(f.file, "downloads_slices"), 2)
        try BrowserPrivacyDataService.open(f.file, writable: true) { try BrowserPrivacyDataService.exec($0, "DROP TABLE downloads_future") }
        _ = try await f.service.delete(rows, keeping: [])
        for table in ["downloads", "downloads_url_chains", "downloads_slices", "downloads_reroute_info"] { XCTAssertEqual(try count(f.file, table), 0) }
    }
    func testFirefoxForeignKeyMetadataRemainsReadableButNotWritable() async throws {
        let f = try fixture(.firefoxAutofill)
        try BrowserPrivacyDataService.open(f.file, writable: true) { try BrowserPrivacyDataService.exec($0, "CREATE TABLE moz_history_to_sources(history_id INTEGER REFERENCES moz_formhistory(rowid),source_id INTEGER)") }
        let rows = try await f.service.scan(profile: f.profile, contract: .firefoxAutofill)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.count }, 3)
        XCTAssertTrue(rows.allSatisfy { !$0.writable })
        do { _ = try await f.service.delete(rows, keeping: []); XCTFail("FK adapter unavailable") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .unsupported) }
        XCTAssertEqual(try count(f.file, "moz_formhistory"), 3)
    }
    func testLegacyStorageReadOnlyDoesNotClaimCurrentStorageCleanup() async throws {
        let f = try fixture(.firefoxLegacyStorage)
        let rows = try await f.service.scan(profile: f.profile, contract: .firefoxLegacyStorage)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.count }, 3)
        XCTAssertTrue(rows.allSatisfy { !$0.writable })
        do { _ = try await f.service.delete(rows, keeping: []); XCTFail("Legacy storage must remain read only") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .unsupported) }
        XCTAssertEqual(try count(f.file, "webappsstore2"), 3)
        XCTAssertTrue(f.recovery.entries().isEmpty)
    }
    func testForeignKeyCascadeCannotWriteUnrelatedTables() async throws {
        let f = try fixture()
        try BrowserPrivacyDataService.open(f.file, writable: true) { try BrowserPrivacyDataService.exec($0, "CREATE TABLE protected(secret TEXT REFERENCES cookies(name))") }
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        do { _ = try await f.service.delete(rows, keeping: []); XCTFail("FK writes must refuse") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .unsupported) }
        XCTAssertEqual(try count(f.file, "cookies"), 3)
    }
    func testRowRestoreKeepsNewDataAndBacksUpOnlyDeletedRows() async throws {
        for contract in [BrowserPrivacyDataContract.chromiumCookies, .chromiumAutofill] {
            let f = try fixture(contract)
            let rows = try await f.service.scan(profile: f.profile, contract: contract)
            let selected = try XCTUnwrap(rows.first { contract == .chromiumAutofill ? $0.key == "email" : $0.site == "example.test" })
            _ = try await f.service.delete([selected], keeping: [])
            let entry = try XCTUnwrap(f.recovery.entries().first)
            XCTAssertEqual(try count(entry.backup.databaseURL, contract.table), selected.count)
            if contract == .chromiumCookies {
                try BrowserPrivacyDataService.open(f.file, writable: true) { try BrowserPrivacyDataService.exec($0, Self.chromeInsert(".example.test", "a", payload: "NEW") + Self.chromeInsert("later.test", "d", payload: "NEW")) }
            } else {
                try BrowserPrivacyDataService.open(f.file, writable: true) { try BrowserPrivacyDataService.exec($0, "INSERT INTO autofill(name,value,value_lower) VALUES('email','SECRET','newer'),('new','NEW','new'); INSERT INTO credit_cards VALUES('NEW CARD')") }
                XCTAssertThrowsError(try count(entry.backup.databaseURL, "credit_cards"))
            }
            let before = try count(f.file, contract.table)
            let result = await f.service.restore(entry, profiles: [f.profile])
            XCTAssertTrue(result.succeeded, result.detail)
            XCTAssertGreaterThanOrEqual(try count(f.file, contract.table), before)
            XCTAssertEqual(try count(f.file, contract.table), 4)
            if contract == .chromiumAutofill {
                XCTAssertEqual(try count(f.file, "credit_cards"), 2)
                XCTAssertEqual(try count(f.file, "autofill", where: "name='email' AND value='SECRET' AND value_lower='newer'"), 1)
            } else {
                XCTAssertEqual(try count(f.file, "cookies", where: "host_key='.example.test' AND name='a' AND value='NEW'"), 1)
            }
        }
    }
    func testWhitelistSuffixAndNormalizedUnkeep() async throws {
        let f = try fixture()
        try BrowserPrivacyDataService.open(f.file, writable: true) { try BrowserPrivacyDataService.exec($0, Self.chromeInsert("sub.example.test", "d") + Self.chromeInsert("badexample.test", "e")) }
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        let deleted = try await f.service.delete(rows, keeping: [".EXAMPLE.TEST"])
        XCTAssertEqual(deleted, 2)
        XCTAssertEqual(try count(f.file, "cookies"), 3)
    }
    @MainActor func testScanResultSelectionIsAlwaysEmpty() async throws {
        let f = try fixture()
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        let store = BrowserPrivacyDataStore(service: f.service, defaults: TestPreferenceDomain.make(for: self))
        store.selection = Set(rows.map(\.id))
        store.applyScanResults(rows)
        XCTAssertTrue(store.selection.isEmpty)
        store.keep("example.test")
        XCTAssertFalse(store.canSelect(try XCTUnwrap(rows.first { $0.site == "example.test" })))
        store.unkeep(".EXAMPLE.TEST")
        XCTAssertTrue(store.keepingSites.isEmpty)
    }
    func testProfileLocksRefuseBeforeBackup() async throws {
        for contract in [BrowserPrivacyDataContract.chromiumCookies, .firefoxCookies] {
            let f = try fixture(contract)
            let lock = f.file.deletingLastPathComponent().appendingPathComponent(contract.engine == .firefox ? ".parentlock" : "SingletonLock")
            try FileManager.default.createSymbolicLink(atPath: lock.path, withDestinationPath: "unavailable-lock-target")
            let rows = try await f.service.scan(profile: f.profile, contract: contract)
            do { _ = try await f.service.delete(rows, keeping: []); XCTFail("Profile lock must refuse") }
            catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, contract.engine == .firefox ? .lockUnverifiable : .browserRunning) }
            XCTAssertTrue(rows.allSatisfy { !$0.writable })
            XCTAssertTrue(f.recovery.entries().isEmpty)
            XCTAssertEqual(try count(f.file, contract.table), 3)
        }
    }
    func testPartialRunReportsConfirmedEarlierBatches() async throws {
        let f = try fixture()
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        let row = try XCTUnwrap(rows.first)
        let profile = BrowserPrivacyProfile(id: "zzz:later", browser: f.profile.browser, displayName: "Later", historyDatabaseURL: f.profile.historyDatabaseURL, sourceTrustedParentURL: f.root)
        let refused = BrowserPrivacyDataGroup(profile: profile, contract: row.contract, key: row.key, count: row.count, identities: row.identities, writable: false)
        do { _ = try await f.service.deleteRun(rows + [refused], keeping: []); XCTFail("Later batch must refuse") }
        catch {
            let partial = try XCTUnwrap(error as? BrowserPrivacyDataRunFailure)
            XCTAssertEqual(partial.completedCount, 3)
            XCTAssertEqual(partial.underlying as? BrowserPrivacyDataFailure, .unsupported)
        }
        XCTAssertEqual(try count(f.file, "cookies"), 0)
        XCTAssertEqual(f.recovery.entries().count, 1)
        XCTAssertEqual(try count(try XCTUnwrap(f.recovery.entries().first).backup.databaseURL, "cookies"), 3)
    }
    func testThirteenBatchesRefuseEntireRunAndHistoryHasSeparateQuota() async throws {
        let f = try fixture()
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        var batches: [BrowserPrivacyDataGroup] = []
        for i in 0..<13 {
            let profile = BrowserPrivacyProfile(id: "fixture:\(i)", browser: f.profile.browser, displayName: "\(i)", historyDatabaseURL: f.profile.historyDatabaseURL, sourceTrustedParentURL: f.root)
            let row = try XCTUnwrap(rows.first)
            batches.append(.init(profile: profile, contract: row.contract, key: row.key, count: row.count, identities: row.identities, writable: true, members: row.members))
        }
        do { _ = try await f.service.deleteRun(batches, keeping: []); XCTFail("Must preflight all 13 batches") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .capacity) }
        XCTAssertEqual(try count(f.file, "cookies"), 3)
        XCTAssertTrue(f.recovery.entries().isEmpty)
        let source = SQLiteSnapshotSource(databaseURL: f.file, trustedParentURL: f.root)
        for _ in 0..<12 {
            let backup = try await f.recovery.backup(source: source, schema: BrowserPrivacyDataContract.chromiumCookies.schema, browserID: "chrome", profileID: f.profile.id, deadlineNanoseconds: MonotonicClock.now + 10_000_000_000)
            await f.recovery.annotate(backup, summary: .init(browserDisplayName: "Fixture", profileDisplayName: "Default", visitCount: 3, pageCount: nil, outcome: .deleted), sparing: [])
        }
        // Two separate data runs: the second run's pruning sees 12 history
        // backups plus one earlier, unspared data backup (13 candidates in a
        // shared pool). Separate pools must keep every history backup.
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        _ = try await f.service.delete([rows[0]], keeping: [])
        let remaining = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        XCTAssertFalse(remaining.isEmpty)
        _ = try await f.service.delete(remaining, keeping: [])
        XCTAssertEqual(f.recovery.entries().filter { $0.dataContract == nil }.count, 12, "Data pruning must not consume the history pool")
        XCTAssertEqual(f.recovery.entries().filter { $0.dataContract != nil }.count, 2, "Data backups below their own quota are kept")
    }
    func testTwelveBatchRunProtectsEveryBackupAndRefusesNextRun() async throws {
        let f = try fixture()
        var selected: [BrowserPrivacyDataGroup] = []
        for i in 0..<12 {
            let directory = f.root.appendingPathComponent("batch-\(i)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: f.file, to: directory.appendingPathComponent("Cookies"))
            let profile = BrowserPrivacyProfile(id: "fixture:batch-\(i)", browser: f.profile.browser, displayName: "\(i)", historyDatabaseURL: directory.appendingPathComponent("History"), sourceTrustedParentURL: f.root)
            selected += try await f.service.scan(profile: profile, contract: .chromiumCookies)
        }
        var service = f.service
        service.beforeReadback = { _ = f.recovery.purgeExpired() }
        let deleted = try await service.deleteRun(selected, keeping: [])
        XCTAssertEqual(deleted, 36)
        let ids = Set(f.recovery.entries().map(\.id))
        XCTAssertEqual(ids.count, 12)
        let next = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        do { _ = try await f.service.delete(next, keeping: []); XCTFail("Full quota must refuse") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .capacity) }
        XCTAssertEqual(try count(f.file, "cookies"), 3)
        XCTAssertEqual(Set(f.recovery.entries().map(\.id)), ids)
    }
    func testHistoryAndDownloadsShareLaterBackupWarning() async throws {
        let f = try fixture(.chromiumDownloads)
        let source = SQLiteSnapshotSource(databaseURL: f.file, trustedParentURL: f.root)
        let backup = try await f.recovery.backup(source: source, schema: BrowserPrivacyDataContract.chromiumDownloads.schema, browserID: "chrome", profileID: f.profile.id, deadlineNanoseconds: MonotonicClock.now + 10_000_000_000)
        await f.recovery.annotate(backup, summary: .init(browserDisplayName: "Fixture", profileDisplayName: "Default", visitCount: 1, pageCount: nil, outcome: .deleted), sparing: [])
        let history = try XCTUnwrap(f.recovery.entries().first)
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumDownloads)
        _ = try await f.service.delete(rows, keeping: [])
        let later = BrowserPrivacyRecoveryText.laterBackups(than: history, in: f.recovery.entries())
        XCTAssertEqual(later.count, 1)
        XCTAssertEqual(later.first?.dataContract, .chromiumDownloads)
        XCTAssertNotNil(BrowserPrivacyRecoveryText.olderBackupWarning(for: history, laterBackups: later))
    }
    func testFirefoxRestoresNaturalKeysAfterIDsAreReused() async throws {
        let f = try fixture(.firefoxCookies)
        let rows = try await f.service.scan(profile: f.profile, contract: .firefoxCookies)
        _ = try await f.service.delete(rows.filter { $0.site == "example.test" }, keeping: [])
        let entry = try XCTUnwrap(f.recovery.entries().first)
        try BrowserPrivacyDataService.open(f.file, writable: true) {
            try BrowserPrivacyDataService.exec($0, "INSERT INTO moz_cookies(host,name,path) VALUES('later.test','new1','/'),('later.test','new2','/');")
        }
        // Latest deleted IDs 2/3 have been reused, but all natural keys differ.
        XCTAssertEqual(try count(f.file, "moz_cookies", where: "id IN (2,3) AND host='later.test'"), 2)
        let result = await f.service.restore(entry, profiles: [f.profile])
        XCTAssertTrue(result.succeeded, result.detail)
        XCTAssertEqual(try count(f.file, "moz_cookies"), 5)
        XCTAssertEqual(try count(f.file, "moz_cookies", where: "host='.example.test' AND id NOT IN (2,3)"), 2)
        XCTAssertEqual(try count(f.file, "moz_cookies", where: "id IN (2,3) AND host='later.test'"), 2)
        XCTAssertNotNil(f.recovery.entries().first { $0.id == entry.id }?.restoredAt)
    }
    func testRestoreExpectedMissingRowsCannotReportZeroAddedSuccess() async throws {
        let f = try fixture(.firefoxCookies)
        let rows = try await f.service.scan(profile: f.profile, contract: .firefoxCookies)
        _ = try await f.service.delete(rows, keeping: [])
        let entry = try XCTUnwrap(f.recovery.entries().first)
        var service = f.service
        service.restoredChanges = { _ in 0 }
        service.transactionGroups = { _ in [:] } // Independently faulty counts cannot hide missing natural keys.
        let result = await service.restore(entry, profiles: [f.profile])
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(try count(f.file, "moz_cookies"), 0)
        XCTAssertNil(f.recovery.entries().first { $0.id == entry.id }?.restoredAt)
    }
    func testFirefoxResidualUnlockedParentlockIsSelectableAndWritable() async throws {
        let f = try fixture(.firefoxCookies)
        let lock = f.file.deletingLastPathComponent().appendingPathComponent(".parentlock")
        try Data().write(to: lock)
        let rows = try await f.service.scan(profile: f.profile, contract: .firefoxCookies)
        XCTAssertTrue(rows.allSatisfy(\.writable))
        let deleted = try await f.service.delete(rows, keeping: [])
        XCTAssertEqual(deleted, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    }
    func testFirefoxReadOnlyScanNeverProbesWriteLocksOrChangesLockFile() async throws {
        let f = try fixture(.firefoxCookies)
        let lock = f.file.deletingLastPathComponent().appendingPathComponent(".parentlock")
        try Data().write(to: lock)
        var before = stat()
        XCTAssertEqual(lstat(lock.path, &before), 0)
        let secondFD = Darwin.open(lock.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(secondFD, 0)
        guard secondFD >= 0 else { return }
        defer { Darwin.close(secondFD) }
        let probes = FakeConnection()
        var service = f.service
        service.observeFirefoxWriteProbe = { probes.record("write probe") }
        try BrowserPrivacyDataService.requireFirefoxUnlocked(lock)
        let rows = try await service.scan(profile: f.profile, contract: .firefoxCookies)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy(\.writable))
        XCTAssertTrue(probes.sql.isEmpty, "Read-only scan must never enter the write lock probe")
        var query = Darwin.flock()
        query.l_type = Int16(F_WRLCK); query.l_whence = Int16(SEEK_SET)
        XCTAssertNotEqual(fcntl(secondFD, F_GETLK, &query), -1)
        XCTAssertEqual(query.l_type, Int16(F_UNLCK))
        var after = stat()
        XCTAssertEqual(lstat(lock.path, &after), 0)
        XCTAssertEqual(after.st_dev, before.st_dev)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec)
        XCTAssertEqual(after.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec)
        // Prove the observer is wired to real transaction boundaries.
        let deleted = try await service.delete(rows, keeping: [])
        XCTAssertEqual(deleted, 3)
        XCTAssertFalse(probes.sql.isEmpty)
    }
    func testFirefoxWriteProbeRefusesHeldFlockAndReleasesIdleLock() throws {
        let f = try fixture(.firefoxCookies)
        let lock = f.file.deletingLastPathComponent().appendingPathComponent(".parentlock")
        try Data().write(to: lock)
        let holder = Darwin.open(lock.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(holder, 0)
        guard holder >= 0 else { return }
        defer { Darwin.close(holder) }
        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try BrowserPrivacyDataService.requireFirefoxUnlockedForWrite(lock)) {
            XCTAssertEqual($0 as? BrowserPrivacyDataFailure, .browserRunning)
        }
        XCTAssertEqual(flock(holder, LOCK_UN), 0)
        try BrowserPrivacyDataService.requireFirefoxUnlockedForWrite(lock)
        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0, "Write probe must release immediately")
        XCTAssertEqual(flock(holder, LOCK_UN), 0)
    }
    func testFirefoxHeldFcntlLockIsReadOnlyAndRefusesWrites() async throws {
        let f = try fixture(.firefoxCookies)
        let lock = f.file.deletingLastPathComponent().appendingPathComponent(".parentlock")
        try Data().write(to: lock)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys,fcntl; f=open(sys.argv[1],'r+'); fcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB); sys.stdout.write('R'); sys.stdout.flush(); sys.stdin.read(1)", lock.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        try process.run()
        defer { try? input.fileHandleForWriting.close(); process.waitUntilExit() }
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 1), Data("R".utf8))
        XCTAssertThrowsError(try BrowserPrivacyDataService.requireFirefoxUnlocked(lock)) {
            XCTAssertEqual($0 as? BrowserPrivacyDataFailure, .browserRunning)
        }
        let rows = try await f.service.scan(profile: f.profile, contract: .firefoxCookies)
        XCTAssertTrue(rows.allSatisfy { !$0.writable && $0.writeFailure == .browserRunning })
        do { _ = try await f.service.delete(rows, keeping: []); XCTFail("Held record lock must refuse") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .browserRunning) }
        XCTAssertEqual(try count(f.file, "moz_cookies"), 3)
        XCTAssertTrue(f.recovery.entries().isEmpty)
    }
    struct VariantRunning: BrowserPrivacyRunningApplicationChecking {
        let bundleID: String
        func runningBundleIdentifiers(matching ids: Set<String>) async -> Set<String> { ids.contains(bundleID) ? [bundleID] : [] }
    }
    func testFirefoxVariantsShareRunningGateAndTeamIdentityRule() async throws {
        let f = try fixture(.firefoxCookies)
        for id in ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "io.gitlab.librewolf-community", "app.zen-browser.zen", "net.waterfox.waterfox"] {
            let service = BrowserPrivacyDataService(homeDirectory: f.root, recovery: f.recovery, snapshots: f.service.snapshots, running: VariantRunning(bundleID: id), fixtureRoot: f.root)
            let rows = try await service.scan(profile: f.profile, contract: .firefoxCookies)
            XCTAssertTrue(rows.allSatisfy { !$0.writable })
            do { _ = try await service.delete(rows, keeping: []); XCTFail("Running variant must refuse") }
            catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .browserRunning) }
        }
        XCTAssertTrue(BrowserPrivacyDataService.permitsDataWriteIdentity(engine: .firefox, teamIdentifier: "43AQ936H96"))
        XCTAssertFalse(BrowserPrivacyDataService.permitsDataWriteIdentity(engine: .firefox, teamIdentifier: "OTHER"))
        XCTAssertFalse(BrowserPrivacyDataService.permitsDataWriteIdentity(engine: .firefox, teamIdentifier: nil))
        XCTAssertTrue(f.recovery.entries().isEmpty)
    }
    func testRealChromeIndependentIndexCopiedAndAttachmentsReadOnly() async throws {
        let f = try fixture()
        let fake = FakeConnection()
        var service = f.service
        service.observeSQL = { fake.record($0) }
        service.attachmentReadOnly = { alias, readOnly in fake.record("attachment:\(alias):\(readOnly)") }
        let rows = try await service.scan(profile: f.profile, contract: .chromiumCookies)
        _ = try await service.delete(rows, keeping: [])
        let entry = try XCTUnwrap(f.recovery.entries().first)
        XCTAssertEqual(try count(entry.backup.databaseURL, "sqlite_master", where: "type='index' AND sql LIKE 'CREATE UNIQUE INDEX%'"), 1)
        XCTAssertThrowsError(try count(entry.backup.databaseURL, "meta"))
        let result = await service.restore(entry, profiles: [f.profile])
        XCTAssertTrue(result.succeeded, result.detail)
        XCTAssertTrue(fake.sql.contains("attachment:source:true"))
        XCTAssertEqual(fake.sql.filter { $0 == "attachment:saved:true" }.count, 3)
        XCTAssertFalse(fake.sql.contains { $0.hasPrefix("attachment:") && $0.hasSuffix(":false") })
        XCTAssertTrue(fake.sql.contains { $0.hasPrefix("CREATE UNIQUE INDEX main.row_unique_") })
        let payloadReads = fake.sql.filter { $0.hasPrefix("SELECT") && !$0.hasPrefix("SELECT COUNT(*)") && $0.contains("FROM cookies") }
        XCTAssertEqual(Set(payloadReads), ["SELECT host_key, COUNT(*) FROM cookies GROUP BY host_key ORDER BY host_key LIMIT 10001"])
    }
    func testUntrustedSchemaRejectsMultipleStatementsBeforeExecution() async throws {
        let f = try fixture()
        try BrowserPrivacyDataService.open(f.file, writable: true) { db in
            XCTAssertThrowsError(try BrowserPrivacyDataService.executeSchemaStatement(db, "CREATE TABLE sneaky(id); DELETE FROM cookies;"))
            XCTAssertEqual(sqlite3_get_autocommit(db), 1)
            XCTAssertThrowsError(try BrowserPrivacyDataService.executeSchemaStatement(db, "DELETE FROM cookies"))
            try BrowserPrivacyDataService.executeSchemaStatement(db, "CREATE TABLE accepted(id INTEGER);  \n")
        }
        XCTAssertEqual(try count(f.file, "cookies"), 3)
        XCTAssertThrowsError(try count(f.file, "sneaky"))
        XCTAssertEqual(try count(f.file, "accepted"), 0)
    }
    func testRestoreSchemaAndCommittedReadbackMustMatch() async throws {
        for mode in 0..<3 {
            let f = try fixture()
            let rows = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
            _ = try await f.service.delete(rows, keeping: [])
            let entry = try XCTUnwrap(f.recovery.entries().first)
            var service = f.service
            if mode == 0 {
                try BrowserPrivacyDataService.open(f.file, writable: true) { try BrowserPrivacyDataService.exec($0, "DROP INDEX cookies_unique_index; CREATE UNIQUE INDEX changed ON cookies(host_key,name);") }
            } else if mode == 1 { service.committedGroups = { _ in ["wrong": 1] } }
            else { service.transactionGroups = { _ in ["wrong": 1] } }
            let result = await service.restore(entry, profiles: [f.profile])
            XCTAssertFalse(result.succeeded)
            XCTAssertNil(f.recovery.entries().first { $0.id == entry.id }?.restoredAt)
            XCTAssertEqual(try count(f.file, "cookies"), mode == 1 ? 3 : 0)
        }
    }
    @MainActor func testKeptChildProtectsParentDomainCookiesAtUIAndWriteBoundary() async throws {
        let f = try fixture()
        try BrowserPrivacyDataService.open(f.file, writable: true) {
            try BrowserPrivacyDataService.exec($0, Self.chromeInsert(".google.com", "login") + Self.chromeInsert("google.com", "hostOnly") + Self.chromeInsert("badgoogle.com", "unrelated"))
        }
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        let parent = try XCTUnwrap(rows.first { $0.site == "google.com" })
        let store = BrowserPrivacyDataStore(service: f.service, defaults: TestPreferenceDomain.make(for: self))
        store.applyScanResults(rows); store.selection = [parent.id]; store.keep("mail.google.com")
        XCTAssertFalse(store.canSelect(parent)); XCTAssertFalse(store.selection.contains(parent.id))
        let deleted = try await f.service.delete(rows, keeping: ["mail.google.com"])
        XCTAssertEqual(deleted, 4)
        XCTAssertEqual(try count(f.file, "cookies"), 2)
        XCTAssertEqual(try count(f.file, "cookies", where: "host_key='.google.com'"), 1)
    }
    func testConfirmationUsesActualTypesAndBoundsSiteList() async throws {
        let f = try fixture(.firefoxCookies)
        let rows = try await f.service.scan(profile: f.profile, contract: .firefoxCookies)
        let message = BrowserPrivacyDataConfirmation.message(Array(repeating: try XCTUnwrap(rows.first), count: 100))
        XCTAssertFalse(message.contains(BrowserPrivacyDataType.siteStorage.title))
        XCTAssertTrue(message.contains("100")); XCTAssertTrue(message.contains("8"))
        XCTAssertLessThanOrEqual(message.split(separator: "\n").count, 13)
        XCTAssertTrue(message.contains("Firefox"))
        let downloads = try fixture(.chromiumDownloads)
        let downloadRows = try await downloads.service.scan(profile: downloads.profile, contract: .chromiumDownloads)
        let text = BrowserPrivacyDataConfirmation.message(downloadRows)
        XCTAssertTrue(text.hasPrefix(L10n.text("将备份并删除：", "Back up and delete: ") + BrowserPrivacyDataType.downloads.title))
        XCTAssertFalse(text.contains("Firefox"))
    }
    func testConfirmationNamesTheProfileOfEachRow() async throws {
        let f = try fixture(.chromiumDownloads)
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumDownloads)
        let row = try XCTUnwrap(rows.first)
        let line = row.profile.browser.displayName + " · " + row.profile.displayName + " · " + row.contract.type.title
        XCTAssertTrue(BrowserPrivacyDataConfirmation.message([row]).contains(line))
    }
    func testTypeLimitationsDoNotBorrowOtherTypesText() {
        XCTAssertTrue(BrowserPrivacyDataType.cookies.limitation.contains("Safari"))
        for type in [BrowserPrivacyDataType.downloads, .autofill] {
            XCTAssertFalse(type.limitation.contains("Safari"), "\(type)")
            XCTAssertFalse(type.limitation.contains("Cookie"), "\(type)")
        }
    }
    func testDataViewKeepsActionsOutsideALazyFilterableList() throws {
        let source = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/BrowserPrivacyDataView.swift")
        let scroll = try XCTUnwrap(source.range(of: "ScrollView {"))
        let delete = try XCTUnwrap(source.range(of: "\"删除所选\""))
        XCTAssertLessThan(delete.lowerBound, scroll.lowerBound)
        XCTAssertTrue(source.contains("LazyVStack"))
        XCTAssertTrue(source.contains("ForEach(visibleGroups(type))"))
        let store = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Features/BrowserPrivacy/Store/BrowserPrivacyDataStore.swift")
        XCTAssertFalse(store.contains("type == .siteStorage { reason = type.limitation }"))
    }
    func testConcurrentDeletionHasDistinctReason() async throws {
        let f = try fixture()
        let lease = try f.recovery.beginDataRun(batchCount: 1)
        defer { withExtendedLifetime(lease) {} }
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumCookies)
        do { _ = try await f.service.delete(rows, keeping: []); XCTFail("Concurrent delete must refuse") }
        catch { XCTAssertEqual(error as? BrowserPrivacyDataFailure, .concurrentOperation) }
        XCTAssertNotEqual(BrowserPrivacyDataFailure.concurrentOperation.text, BrowserPrivacyDataFailure.capacity.text)
        XCTAssertTrue(f.recovery.entries().isEmpty)
    }
    func testDownloadRestoreFailureDoesNotPruneOtherBackupsAndReleasesLeases() async throws {
        let f = try fixture(.chromiumDownloads)
        let rows = try await f.service.scan(profile: f.profile, contract: .chromiumDownloads)
        _ = try await f.service.delete(rows, keeping: [])
        let entry = try XCTUnwrap(f.recovery.entries().first)
        let source = SQLiteSnapshotSource(databaseURL: f.file, trustedParentURL: f.root)
        for _ in 0..<10 {
            let backup = try await f.recovery.backup(source: source, schema: BrowserPrivacyDataContract.chromiumDownloads.schema, browserID: "chrome", profileID: f.profile.id, deadlineNanoseconds: MonotonicClock.now + 10_000_000_000)
            try f.recovery.setDataContract(.chromiumDownloads, for: backup)
            f.recovery.annotateDataRun(backup, summary: .init(browserDisplayName: "Fixture", profileDisplayName: "Default", visitCount: nil, pageCount: nil, outcome: .deleted, dataContract: .chromiumDownloads))
            backup.writingLease?.release()
        }
        let previous = Set(f.recovery.entries().map(\.id))
        XCTAssertEqual(previous.count, 11)
        var service = f.service
        service.beforeRestoreReadback = { throw BrowserPrivacyDataFailure.readback }
        let result = await service.restore(entry, profiles: [f.profile])
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.historyMayHaveChanged)
        XCTAssertNotNil(result.undoBackupID)
        XCTAssertEqual(try count(f.file, "downloads"), 1)
        XCTAssertEqual(f.recovery.entries().count, 12)
        XCTAssertTrue(previous.isSubset(of: Set(f.recovery.entries().map(\.id))))
        let undo = try XCTUnwrap(f.recovery.entries().first { !previous.contains($0.id) })
        let undoLease = try f.recovery.beginRestoring(undo.backup)
        withExtendedLifetime(undoLease) {}
        do {
            let run = try f.recovery.beginDataRun(batchCount: 0)
            withExtendedLifetime(run) {}
        }
        let atCapacity = Set(f.recovery.entries().map(\.id))
        let refused = await f.service.restore(entry, profiles: [f.profile])
        XCTAssertFalse(refused.succeeded)
        XCTAssertEqual(refused.reason, .currentStateNotSaved)
        XCTAssertEqual(Set(f.recovery.entries().map(\.id)), atCapacity)
    }

}
