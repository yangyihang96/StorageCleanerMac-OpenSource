import AppKit
import CSQLite
import Darwin
import Foundation

/// Each browser family owns discovery plus an optional, schema-specific visit
/// row adapter. Providers without a proven adapter remain manual-only.
protocol BrowserHistoryProvider: Sendable {
    var descriptor: BrowserPrivacyProviderDescriptor { get }
    var historyWriteAdapter: BrowserPrivacySQLiteWriteAdapter? { get }

    func discoverProfiles(
        homeDirectory: URL,
        installedApplications: [BrowserPrivacyInstalledApplication]
    ) -> BrowserPrivacyProviderDiscovery
}

extension BrowserHistoryProvider {
    var historyWriteAdapter: BrowserPrivacySQLiteWriteAdapter? { nil }
}

/// The only production write surface for browser history.  Callers receive an
/// adapter from the provider registry instead of deriving a table name from
/// untrusted record data.
enum BrowserPrivacySQLiteMutationPlan: Equatable, Sendable {
    case visitRowOnly
    case chromiumV70Fixture
    /// A Chromium-family plan is enabled by the verified database contract,
    /// not by a browser brand or an application version string.
    case chromiumProduction
}

struct BrowserPrivacySQLiteWriteAdapter: Equatable, Sendable {
    private enum ChromeV70TableStorage {
        case rowID
        case autoincrementRowID
        case withoutRowID
    }

    let engine: BrowserPrivacyEngine
    let visitTable: String
    let rowIdentityQuery: String
    let schema: SQLiteSchemaAllowlist
    let mutationPlan: BrowserPrivacySQLiteMutationPlan

    static let chromiumFixtureMarkerName = ".storage-cleaner-chromium-v70-fixture"
    static let chromiumFixtureMarkerContents = "StorageCleanerMac Chromium v70 fixture\n"

    /// The adapters below are retained for bounded temporary fixtures. Product
    /// providers do not opt into database writes; these reasons explain the
    /// manual boundary shown for live profiles.
    static func manualGuidanceReason(for engine: BrowserPrivacyEngine) -> String {
        switch engine {
        case .safari:
            return L10n.text(
                "Safari 私有 History schema 的 parent counters 与 derived indexes 更新语义尚未验证；当前版本不会修改数据库，请在 Safari 内手动处理。",
                "Safari's private History schema has parent counters and derived indexes whose mutation semantics are not verified; this version will not modify the database. Process history manually in Safari."
            )
        case .chromium:
            return L10n.text(
                "此配置文件未通过当前 Chromium v70/兼容版本 16 的精确 Schema、签名、路径或 SQLite sidecar 检查；不会写入数据库，请在浏览器内手动处理。",
                "This profile did not pass the exact Chromium v70/compatible-version 16 schema, signing, path, or SQLite-sidecar checks. The database will not be written; process it manually in the browser."
            )
        case .firefox:
            return L10n.text(
                "Firefox places.sqlite 包含 visit counts、last-visit/frecency metadata 与相关 indexes；完整更新计划尚未验证。当前版本不会修改数据库，请在 Firefox 内手动处理。",
                "Firefox places.sqlite keeps visit counts, last-visit/frecency metadata, and related indexes; the complete mutation plan is not verified. This version will not modify the database. Process history manually in Firefox."
            )
        }
    }

    static func verified(for engine: BrowserPrivacyEngine) -> Self {
        switch engine {
        case .chromium:
            return Self(
                engine: engine,
                visitTable: "visits",
                rowIdentityQuery: """
                SELECT urls.id, urls.url, visits.visit_time
                FROM visits JOIN urls ON visits.url = urls.id
                WHERE visits.rowid = ?1 LIMIT 1
                """,
                schema: SQLiteSchemaAllowlist(requiredTables: [
                    SQLiteTableAllowlist(name: "urls", requiredColumns: ["id", "url"]),
                    SQLiteTableAllowlist(name: "visits", requiredColumns: ["url", "visit_time"]),
                ]),
                mutationPlan: .visitRowOnly
            )
        case .safari:
            return Self(
                engine: engine,
                visitTable: "history_visits",
                rowIdentityQuery: """
                SELECT history_items.id, history_items.url, history_visits.visit_time
                FROM history_visits
                JOIN history_items ON history_visits.history_item = history_items.id
                WHERE history_visits.rowid = ?1 LIMIT 1
                """,
                schema: SQLiteSchemaAllowlist(requiredTables: [
                    SQLiteTableAllowlist(name: "history_items", requiredColumns: ["id", "url"]),
                    SQLiteTableAllowlist(
                        name: "history_visits",
                        requiredColumns: ["history_item", "visit_time"]
                    ),
                ]),
                mutationPlan: .visitRowOnly
            )
        case .firefox:
            return Self(
                engine: engine,
                visitTable: "moz_historyvisits",
                rowIdentityQuery: """
                SELECT moz_places.id, moz_places.url, moz_historyvisits.visit_date
                FROM moz_historyvisits
                JOIN moz_places ON moz_historyvisits.place_id = moz_places.id
                WHERE moz_historyvisits.rowid = ?1 LIMIT 1
                """,
                schema: SQLiteSchemaAllowlist(requiredTables: [
                    SQLiteTableAllowlist(name: "moz_places", requiredColumns: ["id", "url"]),
                    SQLiteTableAllowlist(
                        name: "moz_historyvisits",
                        requiredColumns: ["place_id", "visit_date"]
                    ),
                ]),
                mutationPlan: .visitRowOnly
            )
        }
    }

    /// This adapter is deliberately usable only by a marked database fixture
    /// below the process temporary directory. Production providers never
    /// return it.
    static let chromiumV70Fixture = Self(
        engine: .chromium,
        visitTable: "visits",
        rowIdentityQuery: """
        SELECT urls.id, urls.url, visits.visit_time
        FROM visits JOIN urls ON visits.url = urls.id
        WHERE visits.rowid = ?1 LIMIT 1
        """,
        schema: SQLiteSchemaAllowlist(requiredTables: [
            SQLiteTableAllowlist(name: "meta", requiredColumns: ["key", "value"]),
            SQLiteTableAllowlist(
                name: "urls",
                requiredColumns: [
                    "id", "url", "visit_count", "typed_count", "last_visit_time",
                ]
            ),
            SQLiteTableAllowlist(
                name: "visits",
                requiredColumns: [
                    "id", "url", "visit_time", "from_visit", "transition", "segment_id",
                    "incremented_omnibox_typed_score", "visited_link_id",
                ]
            ),
            SQLiteTableAllowlist(name: "visit_source", requiredColumns: ["id", "source"]),
            SQLiteTableAllowlist(
                name: "context_annotations",
                requiredColumns: ["visit_id"]
            ),
            SQLiteTableAllowlist(
                name: "content_annotations",
                requiredColumns: ["visit_id"]
            ),
            SQLiteTableAllowlist(name: "segments", requiredColumns: ["id", "url_id"]),
            SQLiteTableAllowlist(
                name: "segment_usage",
                requiredColumns: ["id", "segment_id", "time_slot", "visit_count"]
            ),
        ]),
        mutationPlan: .chromiumV70Fixture
    )

    /// Historical Chromium production contract retained only as an injected
    /// temporary-fixture seam for transaction and rollback coverage. Registered
    /// product providers never return this adapter: live SQLite sidecar state
    /// cannot be held stable between inspection and a read-write open.
    static let chromiumProduction = Self(
        engine: .chromium,
        visitTable: "visits",
        rowIdentityQuery: """
        SELECT urls.id, urls.url, visits.visit_time
        FROM visits JOIN urls ON visits.url = urls.id
        WHERE visits.rowid = ?1 LIMIT 1
        """,
        schema: SQLiteSchemaAllowlist(requiredTables: [
            SQLiteTableAllowlist(name: "meta", requiredColumns: ["key", "value"]),
            SQLiteTableAllowlist(
                name: "urls",
                requiredColumns: [
                    "id", "url", "title", "visit_count", "typed_count",
                    "last_visit_time", "hidden",
                ]
            ),
            SQLiteTableAllowlist(
                name: "visits",
                requiredColumns: [
                    "id", "url", "visit_time", "from_visit", "external_referrer_url",
                    "transition", "segment_id", "visit_duration",
                    "incremented_omnibox_typed_score", "opener_visit",
                    "originator_cache_guid", "originator_visit_id",
                    "originator_from_visit", "originator_opener_visit",
                    "is_known_to_sync", "consider_for_ntp_most_visited",
                    "visited_link_id", "app_id",
                ]
            ),
            SQLiteTableAllowlist(
                name: "visit_source",
                requiredColumns: ["id", "source"]
            ),
            SQLiteTableAllowlist(
                name: "context_annotations",
                requiredColumns: [
                    "visit_id", "context_annotation_flags", "duration_since_last_visit",
                    "page_end_reason", "total_foreground_duration", "browser_type",
                    "window_id", "tab_id", "task_id", "root_task_id", "parent_task_id",
                    "response_code",
                ]
            ),
            SQLiteTableAllowlist(
                name: "content_annotations",
                requiredColumns: [
                    "visit_id", "visibility_score", "floc_protected_score", "categories",
                    "page_topics_model_version", "annotation_flags", "entities",
                    "related_searches", "search_normalized_url", "search_terms",
                    "alternative_title", "page_language", "password_state",
                    "has_url_keyed_image",
                ]
            ),
            SQLiteTableAllowlist(
                name: "segments",
                requiredColumns: ["id", "name", "url_id"]
            ),
            SQLiteTableAllowlist(
                name: "segment_usage",
                requiredColumns: ["id", "segment_id", "time_slot", "visit_count"]
            ),
            SQLiteTableAllowlist(
                name: "clusters_and_visits",
                requiredColumns: [
                    "cluster_id", "visit_id", "score", "engagement_score",
                    "url_for_deduping", "normalized_url", "url_for_display",
                    "interaction_state",
                ]
            ),
            SQLiteTableAllowlist(
                name: "cluster_visit_duplicates",
                requiredColumns: ["visit_id", "duplicate_visit_id"]
            ),
            SQLiteTableAllowlist(
                name: "visited_links",
                requiredColumns: [
                    "id", "link_url_id", "top_level_url", "frame_url", "visit_count",
                ]
            ),
            SQLiteTableAllowlist(
                name: "keyword_search_terms",
                requiredColumns: ["keyword_id", "url_id", "term", "normalized_term"]
            ),
        ]),
        mutationPlan: .chromiumProduction
    )

    /// Source compatibility for isolated fixture tests. Registered product
    /// providers do not expose this capability.
    static var chromeV70Production: Self { chromiumProduction }

    /// One production schema fact gate shared by the read-only scanner and
    /// the write processor. Column names alone do not prove that a visit
    /// rowid is the VisitID used by Chromium's dependent tables.
    func matchesChromiumProductionSchema(
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws -> Bool {
        guard self == .chromiumProduction else { return false }
        guard try Self.pragmaInteger(
            "user_version",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        ) == 0,
        try Self.pragmaInteger(
            "application_id",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        ) == 0 else {
            return false
        }
        for table in schema.requiredTables {
            guard try SQLiteRuntime.tableColumns(
                table.name,
                database: database,
                control: control,
                busyDeadlineNanoseconds: busyDeadlineNanoseconds
            ) == table.requiredColumns else {
                return false
            }
        }

        let primaryKeys: [(
            table: String,
            columns: [(name: String, type: String)],
            storage: ChromeV70TableStorage
        )] = [
            ("meta", [("key", "LONGVARCHAR")], .rowID),
            ("urls", [("id", "INTEGER")], .autoincrementRowID),
            ("visits", [("id", "INTEGER")], .autoincrementRowID),
            ("visit_source", [("id", "INTEGER")], .rowID),
            ("context_annotations", [("visit_id", "INTEGER")], .rowID),
            ("content_annotations", [("visit_id", "INTEGER")], .rowID),
            ("segments", [("id", "INTEGER")], .rowID),
            ("segment_usage", [("id", "INTEGER")], .rowID),
            (
                "clusters_and_visits",
                [("cluster_id", "INTEGER"), ("visit_id", "INTEGER")],
                .withoutRowID
            ),
            (
                "cluster_visit_duplicates",
                [("visit_id", "INTEGER"), ("duplicate_visit_id", "INTEGER")],
                .withoutRowID
            ),
            ("visited_links", [("id", "INTEGER")], .autoincrementRowID),
            ("keyword_search_terms", [], .rowID),
        ]
        for expectation in primaryKeys where !(try Self.primaryKeyMatches(
            table: expectation.table,
            expectedColumns: expectation.columns,
            storage: expectation.storage,
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )) {
            return false
        }

        for table in schema.requiredTables where try Self.hasDeclaredForeignKey(
            table: table.name,
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        ) {
            return false
        }
        for table in schema.requiredTables where try Self.hasDeclaredTrigger(
            table: table.name,
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        ) {
            return false
        }

        let versionStatement = try SQLiteRuntime.prepare(
            """
            SELECT
                (SELECT CASE
                    WHEN typeof(value) = 'integer' AND value = 70 THEN 70
                    WHEN typeof(value) = 'text' AND value = '70' THEN 70
                    ELSE NULL
                 END FROM meta WHERE key = 'version' LIMIT 1),
                (SELECT CASE
                    WHEN typeof(value) = 'integer' AND value = 16 THEN 16
                    WHEN typeof(value) = 'text' AND value = '16' THEN 16
                    ELSE NULL
                 END FROM meta WHERE key = 'last_compatible_version' LIMIT 1),
                (SELECT COUNT(*) FROM meta WHERE key = 'version'),
                (SELECT COUNT(*) FROM meta WHERE key = 'last_compatible_version')
            """,
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )
        defer { sqlite3_finalize(versionStatement) }
        guard try SQLiteRuntime.step(
            versionStatement,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        ) == SQLITE_ROW else { return false }
        return sqlite3_column_type(versionStatement, 0) == SQLITE_INTEGER
            && sqlite3_column_int64(versionStatement, 0) == 70
            && sqlite3_column_type(versionStatement, 1) == SQLITE_INTEGER
            && sqlite3_column_int64(versionStatement, 1) == 16
            && sqlite3_column_int64(versionStatement, 2) == 1
            && sqlite3_column_int64(versionStatement, 3) == 1
    }

    private static func pragmaInteger(
        _ name: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws -> Int64? {
        guard name == "user_version" || name == "application_id" else { return nil }
        let statement = try SQLiteRuntime.prepare(
            "PRAGMA \(name)",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )
        defer { sqlite3_finalize(statement) }
        guard try SQLiteRuntime.step(
            statement,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        ) == SQLITE_ROW,
        sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
            return nil
        }
        return sqlite3_column_int64(statement, 0)
    }

    /// Compatibility spelling retained for callers from the v70 fixture
    /// acceptance work.  It delegates to the capability-based gate above.
    func matchesChromeV70ProductionSchema(
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws -> Bool {
        try matchesChromiumProductionSchema(
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )
    }

    private static func primaryKeyMatches(
        table: String,
        expectedColumns: [(name: String, type: String)],
        storage: ChromeV70TableStorage,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws -> Bool {
        let info = try SQLiteRuntime.prepare(
            "PRAGMA table_info(\"\(table)\")",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )
        defer { sqlite3_finalize(info) }
        var actual: [(order: Int32, name: String, type: String)] = []
        while try SQLiteRuntime.step(
            info,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        ) == SQLITE_ROW {
            let order = sqlite3_column_int(info, 5)
            if order > 0 {
                guard let name = sqlite3_column_text(info, 1),
                      let type = sqlite3_column_text(info, 2) else {
                    return false
                }
                actual.append((
                    order: order,
                    name: String(cString: name),
                    type: String(cString: type).uppercased()
                ))
            }
        }
        actual.sort { $0.order < $1.order }
        guard actual.count == expectedColumns.count else { return false }
        for (index, expected) in expectedColumns.enumerated() {
            guard actual[index].order == Int32(index + 1),
                  actual[index].name == expected.name,
                  actual[index].type == expected.type,
                  let metadata = try columnMetadata(
                      table: table,
                      column: expected.name,
                      database: database,
                      control: control
                  ),
                  metadata.type == expected.type,
                  metadata.primaryKey else {
                return false
            }
        }

        guard let withoutRowID = try tableUsesWithoutRowID(
            table: table,
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        ) else { return false }
        switch storage {
        case .rowID:
            return !withoutRowID
        case .autoincrementRowID:
            guard !withoutRowID,
                  expectedColumns.count == 1,
                  let idMetadata = try columnMetadata(
                      table: table,
                      column: expectedColumns[0].name,
                      database: database,
                      control: control
                  ),
                  let rowIDMetadata = try columnMetadata(
                      table: table,
                      column: "rowid",
                      database: database,
                      control: control
                  ) else {
                return false
            }
            // SQLite reports the declared INTEGER PRIMARY KEY metadata when
            // rowid aliases that column. Matching AUTOINCREMENT flags prove
            // that the locator rowid is Chromium's dependent-table VisitID.
            return idMetadata.type == "INTEGER"
                && idMetadata.primaryKey
                && idMetadata.autoincrement
                && rowIDMetadata.type == "INTEGER"
                && rowIDMetadata.primaryKey
                && rowIDMetadata.autoincrement
        case .withoutRowID:
            return withoutRowID
        }
    }

    private static func columnMetadata(
        table: String,
        column: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl
    ) throws -> (type: String, primaryKey: Bool, autoincrement: Bool)? {
        try control.check()
        var declaredType: UnsafePointer<CChar>?
        var primaryKey: Int32 = 0
        var autoincrement: Int32 = 0
        let result = "main".withCString { databaseName in
            table.withCString { tableName in
                column.withCString { columnName in
                    sqlite3_table_column_metadata(
                        database,
                        databaseName,
                        tableName,
                        columnName,
                        &declaredType,
                        nil,
                        nil,
                        &primaryKey,
                        &autoincrement
                    )
                }
            }
        }
        guard result == SQLITE_OK, let declaredType else { return nil }
        return (
            String(cString: declaredType).uppercased(),
            primaryKey != 0,
            autoincrement != 0
        )
    }

    private static func tableUsesWithoutRowID(
        table: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws -> Bool? {
        let statement = try SQLiteRuntime.prepare(
            "PRAGMA main.table_list(\"\(table)\")",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )
        defer { sqlite3_finalize(statement) }
        guard try SQLiteRuntime.step(
            statement,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        ) == SQLITE_ROW,
        let type = sqlite3_column_text(statement, 2),
        String(cString: type) == "table" else {
            return nil
        }
        return sqlite3_column_int(statement, 4) != 0
    }

    private static func hasDeclaredForeignKey(
        table: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws -> Bool {
        let statement = try SQLiteRuntime.prepare(
            "PRAGMA foreign_key_list(\"\(table)\")",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )
        defer { sqlite3_finalize(statement) }
        return try SQLiteRuntime.step(
            statement,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        ) == SQLITE_ROW
    }

    private static func hasDeclaredTrigger(
        table: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws -> Bool {
        let statement = try SQLiteRuntime.prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?1 LIMIT 1",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, table, -1, transient) == SQLITE_OK else {
            throw SQLiteSnapshotFailure.malformedSchema
        }
        return try SQLiteRuntime.step(
            statement,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        ) == SQLITE_ROW
    }
}

struct BrowserPrivacyProviderDescriptor: Equatable, Sendable {
    let id: String
    let displayName: String
    let engine: BrowserPrivacyEngine
    let bundleIdentifiers: [String]
    let profileRootRelativePaths: [String]

    func productionWriteRoot(
        browser: BrowserPrivacyBrowser,
        homeDirectory: URL,
        databaseURL: URL,
        profileParentURL: URL? = nil
    ) -> URL? {
        guard engine == .chromium,
              browser.id == id,
              browser.engine == engine,
              let bundleIdentifier = browser.bundleIdentifier,
              bundleIdentifiers.contains(bundleIdentifier),
              Self.isValidInstalledBundle(
                  browser.applicationURL,
                  bundleIdentifier: bundleIdentifier,
                  signingIdentity: browser.signingIdentity
              ) else {
            return nil
        }

        let home = homeDirectory.standardizedFileURL
        let database = databaseURL.standardizedFileURL
        let profileParent = profileParentURL?.standardizedFileURL
        return profileRootRelativePaths.lazy.compactMap { relativePath -> URL? in
            guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
            let root = home.appendingPathComponent(relativePath, isDirectory: true)
                .standardizedFileURL
            guard Self.isDescendant(root, of: home),
                  Self.isDescendant(database, of: root),
                  profileParent.map({ $0 == root || Self.isDescendant($0, of: root) }) ?? true else {
                return nil
            }
            return root
        }.first
    }

    private static func isValidInstalledBundle(
        _ applicationURL: URL?,
        bundleIdentifier: String,
        signingIdentity: StartupApplicationSigningIdentity?
    ) -> Bool {
        guard let applicationURL = applicationURL?.standardizedFileURL,
              applicationURL.isFileURL,
              applicationURL.pathExtension == "app",
              let signingIdentity,
              signingIdentity.teamIdentifier?.trimmed.nonEmpty != nil,
              signingIdentity.codeSigningIdentifier == bundleIdentifier,
              signingIdentity.designatedRequirement?.trimmed.nonEmpty != nil else {
            return false
        }

        var bundleMetadata = stat()
        guard lstat(applicationURL.path, &bundleMetadata) == 0,
              bundleMetadata.st_mode & S_IFMT == S_IFDIR,
              let bundle = Bundle(url: applicationURL),
              bundle.bundleIdentifier == bundleIdentifier,
              let executableURL = bundle.executableURL?.standardizedFileURL else {
            return false
        }
        var executableMetadata = stat()
        return lstat(executableURL.path, &executableMetadata) == 0
            && executableMetadata.st_mode & S_IFMT == S_IFREG
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        return candidate.standardizedFileURL.path.hasPrefix(
            rootPath == "/" ? "/" : rootPath + "/"
        )
    }
}

struct BrowserPrivacyInstalledApplication: Equatable, Sendable {
    let bundleIdentifier: String
    let version: String?
    let url: URL
    let isDefaultBrowser: Bool
    let displayName: String?
    /// Evidence that Launch Services or the bundle itself declares HTTP(S)
    /// handling. Unknown derivatives must carry this before profile discovery.
    let canOpenWebURLs: Bool
    /// Evidence from a bounded local codesign verification. Missing or partial
    /// evidence remains unknown and cannot authorize a production locator.
    let signingIdentity: StartupApplicationSigningIdentity?

    init(
        bundleIdentifier: String,
        version: String?,
        url: URL,
        isDefaultBrowser: Bool,
        displayName: String? = nil,
        canOpenWebURLs: Bool = false,
        signingIdentity: StartupApplicationSigningIdentity? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.url = url
        self.isDefaultBrowser = isDefaultBrowser
        self.displayName = displayName
        self.canOpenWebURLs = canOpenWebURLs
        self.signingIdentity = signingIdentity
    }
}

struct BrowserPrivacyProviderDiscovery: Equatable, Sendable {
    let coverage: BrowserPrivacyProviderCoverage
    let profiles: [BrowserPrivacyProfile]
}

/// A small registry makes profile discovery an explicit, independently
/// testable concern. Adding a browser is a provider entry, not a new switch
/// scattered across a view, scanner, and deletion UI.
struct BrowserPrivacyProviderRegistry: Sendable {
    let providers: [any BrowserHistoryProvider]

    init(providers: [any BrowserHistoryProvider] = Self.defaultProviders) {
        self.providers = providers
    }

    func provider(id: String) -> (any BrowserHistoryProvider)? {
        providers.first { $0.descriptor.id == id }
    }

    func discover(
        homeDirectory: URL,
        installedApplications: [BrowserPrivacyInstalledApplication]
    ) -> [BrowserPrivacyProviderDiscovery] {
        allProviders(
            homeDirectory: homeDirectory,
            installedApplications: installedApplications
        ).filter { provider in
            guard provider is RegisteredBrowserPrivacyProvider else { return true }
            return provider.descriptor.bundleIdentifiers.contains { bundleIdentifier in
                installedApplications.contains { $0.bundleIdentifier == bundleIdentifier }
            }
        }.map {
            $0.discoverProfiles(
                homeDirectory: homeDirectory,
                installedApplications: installedApplications
            )
        }
    }

    /// Includes read-only dynamically discovered derivatives for tests and
    /// the scanner; fixed providers remain the first, stable entries.
    func allProviders(
        homeDirectory: URL,
        installedApplications: [BrowserPrivacyInstalledApplication]
    ) -> [any BrowserHistoryProvider] {
        providers + Self.discoveredProviders(
            homeDirectory: homeDirectory,
            installedApplications: installedApplications,
            knownProviders: providers
        )
    }

    private static func discoveredProviders(
        homeDirectory: URL,
        installedApplications: [BrowserPrivacyInstalledApplication],
        knownProviders: [any BrowserHistoryProvider]
    ) -> [any BrowserHistoryProvider] {
        let knownBundleIdentifiers = Set(
            knownProviders.flatMap { $0.descriptor.bundleIdentifiers }
        )
        let applicationSupport = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .standardizedFileURL
        return BrowserPrivacyDynamicDiscovery.roots(
            under: applicationSupport,
            installedApplications: installedApplications,
            excluding: knownBundleIdentifiers
        ).compactMap { candidate in
            RegisteredBrowserPrivacyProvider.discovered(
                application: candidate.application,
                engine: candidate.engine,
                profileRoot: candidate.root,
                homeDirectory: homeDirectory
            )
        }
    }

    static let defaultProviders: [any BrowserHistoryProvider] = [
        RegisteredBrowserPrivacyProvider.safari,
        RegisteredBrowserPrivacyProvider.chrome,
        RegisteredBrowserPrivacyProvider.chromiumBrowser,
        RegisteredBrowserPrivacyProvider.edge,
        RegisteredBrowserPrivacyProvider.firefox,
        RegisteredBrowserPrivacyProvider.brave,
        RegisteredBrowserPrivacyProvider.arc,
        RegisteredBrowserPrivacyProvider.opera,
        RegisteredBrowserPrivacyProvider.operaGX,
        RegisteredBrowserPrivacyProvider.vivaldi,
        RegisteredBrowserPrivacyProvider.orion,
        RegisteredBrowserPrivacyProvider.zen,
        RegisteredBrowserPrivacyProvider.libreWolf,
        RegisteredBrowserPrivacyProvider.waterfox,
    ]
}

/// App discovery is read-only and runs before profile work. Resolving a
/// default handler does not open a URL or invoke a browser.
@MainActor
enum BrowserPrivacyApplicationLocator {
    static func discover(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [BrowserPrivacyInstalledApplication] {
        let manager = FileManager.default
        let standardDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]
        var applicationURLs = Set<URL>()
        for directory in standardDirectories {
            guard let entries = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for entry in entries where entry.pathExtension == "app" {
                applicationURLs.insert(entry.standardizedFileURL)
            }
        }

        let workspace = NSWorkspace.shared
        let handlerURL: URL?
        var webHandlerURLs = Set<URL>()
        if let probeURL = URL(string: "https://browser-privacy.invalid") {
            webHandlerURLs = Set(workspace.urlsForApplications(toOpen: probeURL)
                .map(\.standardizedFileURL))
            applicationURLs.formUnion(webHandlerURLs)
            handlerURL = workspace.urlForApplication(toOpen: probeURL)?
                .standardizedFileURL
        } else {
            handlerURL = nil
        }
        if let handlerURL {
            applicationURLs.insert(handlerURL)
        }

        return applicationURLs.compactMap { url in
            guard let bundle = Bundle(url: url),
                  let bundleIdentifier = bundle.bundleIdentifier else {
                return nil
            }
            return BrowserPrivacyInstalledApplication(
                bundleIdentifier: bundleIdentifier,
                version: bundle.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String,
                url: url,
                isDefaultBrowser: url == handlerURL,
                displayName: (bundle.object(
                    forInfoDictionaryKey: "CFBundleDisplayName"
                ) as? String)?.trimmed.nonEmpty
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)?.trimmed.nonEmpty
                    ?? bundleIdentifier,
                canOpenWebURLs: webHandlerURLs.contains(url)
                    || declaresWebURLHandler(bundle: bundle)
            )
        }
        .sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }

    /// Enriches the local app inventory with bounded signing evidence. This
    /// does not open a browser, read a history database, or grant write
    /// capability; an unsigned or partially parsed bundle stays unknown.
    static func discoverWithSigningIdentity(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        identityReader: any StartupApplicationSigningIdentityReading =
            StartupApplicationSigningIdentityReader.shared
    ) async -> [BrowserPrivacyInstalledApplication] {
        let applications = discover(homeDirectory: homeDirectory)
        let knownBrowserIDs = Set(
            BrowserPrivacyProviderRegistry.defaultProviders
                .flatMap { $0.descriptor.bundleIdentifiers }
        )
        var enriched: [BrowserPrivacyInstalledApplication] = []
        enriched.reserveCapacity(applications.count)
        for application in applications {
            guard application.canOpenWebURLs
                    || knownBrowserIDs.contains(application.bundleIdentifier) else {
                enriched.append(application)
                continue
            }
            let identity = await identityReader.identity(
                at: application.url,
                executableURL: Bundle(url: application.url)?.executableURL
            )
            enriched.append(BrowserPrivacyInstalledApplication(
                bundleIdentifier: application.bundleIdentifier,
                version: application.version,
                url: application.url,
                isDefaultBrowser: application.isDefaultBrowser,
                displayName: application.displayName,
                canOpenWebURLs: application.canOpenWebURLs,
                signingIdentity: identity
            ))
        }
        return enriched.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }

    private static func declaresWebURLHandler(bundle: Bundle) -> Bool {
        guard let declarations = bundle.object(
            forInfoDictionaryKey: "CFBundleURLTypes"
        ) as? [[String: Any]] else {
            return false
        }
        let schemes = declarations.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            .map { $0.lowercased() }
        return schemes.contains("http") && schemes.contains("https")
    }
}

struct RegisteredBrowserPrivacyProvider: BrowserHistoryProvider {
    enum ProfileLayout: Equatable, Sendable {
        case safari
        case chromium
        case firefox
    }

    let descriptor: BrowserPrivacyProviderDescriptor
    private let layout: ProfileLayout
    private let allowsProductionWrite: Bool

    init(
        descriptor: BrowserPrivacyProviderDescriptor,
        layout: ProfileLayout,
        allowsProductionWrite: Bool = false
    ) {
        self.descriptor = descriptor
        self.layout = layout
        self.allowsProductionWrite = allowsProductionWrite
    }

    var historyWriteAdapter: BrowserPrivacySQLiteWriteAdapter? {
        guard allowsProductionWrite, layout == .chromium else { return nil }
        return .chromiumProduction
    }

    func discoverProfiles(
        homeDirectory: URL,
        installedApplications: [BrowserPrivacyInstalledApplication]
    ) -> BrowserPrivacyProviderDiscovery {
        let applications = installedApplications.filter {
            descriptor.bundleIdentifiers.contains($0.bundleIdentifier)
        }
        let browser = BrowserPrivacyBrowser(
            id: descriptor.id,
            displayName: descriptor.displayName,
            engine: descriptor.engine,
            bundleIdentifier: applications.first?.bundleIdentifier,
            version: applications.first?.version,
            applicationURL: applications.first?.url,
            signingIdentity: applications.first?.signingIdentity
        )

        var profiles: [BrowserPrivacyProfile] = []
        var sawPermissionDenied = false
        var sawPartial = false
        for relativePath in descriptor.profileRootRelativePaths {
            let root = homeDirectory
                .appendingPathComponent(relativePath, isDirectory: true)
                .standardizedFileURL
            switch discoverProfiles(
                in: root,
                browser: browser,
                homeDirectory: homeDirectory
            ) {
            case let .success(found, requiresFullDiskAccess):
                profiles.append(contentsOf: found)
                sawPermissionDenied = sawPermissionDenied || requiresFullDiskAccess
            case .permissionDenied:
                sawPermissionDenied = true
            case .partial:
                sawPartial = true
            case .unavailable:
                continue
            }
        }

        let uniqueProfiles = Dictionary(
            profiles.map { ($0.historyDatabaseURL.standardizedFileURL.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        .values
        .sorted { $0.id < $1.id }

        let availability: BrowserPrivacyProviderAvailability
        let detail: String?
        let requiresFullDiskAccess: Bool
        if !uniqueProfiles.isEmpty {
            availability = sawPermissionDenied || sawPartial ? .partial : .available
            detail = sawPermissionDenied
                ? L10n.text(
                    "部分配置文件需要“完全磁盘访问权限”。",
                    "Some profiles need Full Disk Access."
                )
                : (sawPartial
                    ? L10n.text(
                        "部分配置文件位置无法读取。",
                        "Some profile locations could not be read."
                    )
                    : nil)
            requiresFullDiskAccess = sawPermissionDenied
        } else if sawPermissionDenied {
            availability = .permissionDenied
            detail = L10n.text(
                "此浏览器配置文件需要“完全磁盘访问权限”。",
                "Full Disk Access is required for this browser profile."
            )
            requiresFullDiskAccess = true
        } else if !applications.isEmpty {
            availability = .noProfiles
            detail = L10n.text(
                "已安装此浏览器，但未找到可读取的本地配置文件。",
                "The browser is installed, but no readable local profile was found."
            )
            requiresFullDiskAccess = false
        } else {
            availability = .noProfiles
            detail = L10n.text(
                "未找到已安装应用或可读取的本地配置文件。",
                "No installed app or readable local profile was found."
            )
            requiresFullDiskAccess = false
        }

        return BrowserPrivacyProviderDiscovery(
            coverage: BrowserPrivacyProviderCoverage(
                browser: browser,
                availability: availability,
                profileCount: uniqueProfiles.count,
                recordCount: 0,
                detail: detail,
                requiresFullDiskAccess: requiresFullDiskAccess
            ),
            profiles: uniqueProfiles
        )
    }

    private func discoverProfiles(
        in root: URL,
        browser: BrowserPrivacyBrowser,
        homeDirectory: URL
    ) -> DiscoveryResult {
        switch BrowserPrivacyDiscoveryFileAccess.directory(at: root) {
        case .permissionDenied:
            return .permissionDenied
        case .unavailable:
            return .unavailable
        case .available:
            break
        case .noProfiles, .partial, .malformedSchema, .busy, .timedOut:
            return .unavailable
        }

        switch layout {
        case .safari:
            switch BrowserPrivacyDiscoveryFileAccess.regularFile(
                root.appendingPathComponent("History.db"),
                inside: root
            ) {
            case let .available(history):
                return .success([
                    BrowserPrivacyProfile(
                        id: "\(browser.id):Safari",
                        browser: browser,
                        displayName: "Safari",
                        historyDatabaseURL: history,
                        sourceTrustedParentURL: root
                    )
                ], requiresFullDiskAccess: false)
            case .permissionDenied:
                return .permissionDenied
            case .unavailable:
                return .partial
            }

        case .chromium:
            let children = BrowserPrivacyDiscoveryFileAccess.children(
                of: root
            )
            let metadata = Self.chromiumProfileMetadata(in: root)
            let childCandidates = children.directories.filter { directory in
                let name = directory.lastPathComponent
                guard name != "Guest Profile", name != "System Profile" else {
                    return false
                }
                if let configuredIDs = metadata?.keys {
                    return configuredIDs.contains(name)
                }
                return name == "Default" || name.hasPrefix("Profile ")
            }
            var profiles: [BrowserPrivacyProfile] = []
            var sawPermissionDenied = children.permissionDenied
            // Most Chromium browsers keep History below Default/Profile N,
            // while some derivatives keep the default profile directly at the
            // registered root. Probe both shapes instead of silently missing
            // an installed browser whose database uses the root layout.
            let candidates: [(root: URL, identifier: String, displayName: String)] = [
                (root, "Root", "Default"),
            ] + childCandidates.map {
                let identifier = $0.lastPathComponent
                return ($0, identifier, metadata?[identifier] ?? identifier)
            }
            for candidate in candidates {
                switch BrowserPrivacyDiscoveryFileAccess.regularFile(
                    candidate.root.appendingPathComponent("History"),
                    inside: candidate.root
                ) {
                case let .available(history):
                    profiles.append(BrowserPrivacyProfile(
                        id: "\(browser.id):\(candidate.identifier)",
                        browser: browser,
                        displayName: candidate.displayName,
                        historyDatabaseURL: history,
                        sourceTrustedParentURL: candidate.root
                    ))
                case .permissionDenied:
                    sawPermissionDenied = true
                case .unavailable:
                    continue
                }
            }
            if profiles.isEmpty {
                return sawPermissionDenied ? .permissionDenied : .partial
            }
            return .success(profiles, requiresFullDiskAccess: sawPermissionDenied)

        case .firefox:
            guard let configuredProfiles = Self.firefoxProfiles(
                in: root,
                homeDirectory: homeDirectory
            ) else {
                return .partial
            }
            var profiles: [BrowserPrivacyProfile] = []
            var sawPermissionDenied = false
            for configured in configuredProfiles {
                switch BrowserPrivacyDiscoveryFileAccess.regularFile(
                    configured.url.appendingPathComponent("places.sqlite"),
                    inside: configured.url
                ) {
                case let .available(history):
                    profiles.append(BrowserPrivacyProfile(
                        id: "\(browser.id):\(configured.identifier)",
                        browser: browser,
                        displayName: configured.displayName,
                        historyDatabaseURL: history,
                        sourceTrustedParentURL: configured.url
                    ))
                case .permissionDenied:
                    sawPermissionDenied = true
                case .unavailable:
                    continue
                }
            }
            if profiles.isEmpty {
                return sawPermissionDenied ? .permissionDenied : .partial
            }
            return .success(profiles, requiresFullDiskAccess: sawPermissionDenied)
        }
    }

    private static func chromiumProfileMetadata(in root: URL) -> [String: String]? {
        guard let data = BrowserPrivacyDiscoveryFileAccess.data(
            at: root.appendingPathComponent("Local State"),
            inside: root,
            maximumBytes: 4 * 1_024 * 1_024
        ),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let profile = object["profile"] as? [String: Any],
        let cache = profile["info_cache"] as? [String: Any] else {
            return nil
        }

        return cache.reduce(into: [:]) { result, entry in
            let identifier = entry.key
            guard identifier != "Guest Profile",
                  identifier != "System Profile",
                  identifier == "Default" || identifier.hasPrefix("Profile ") else {
                return
            }
            let rawName = (entry.value as? [String: Any])?["name"] as? String
            let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
            result[identifier] = name.flatMap {
                !$0.isEmpty && $0.utf8.count <= 128 ? $0 : nil
            } ?? identifier
        }
    }

    private struct FirefoxConfiguredProfile {
        let identifier: String
        let displayName: String
        let url: URL
        let isDefault: Bool
    }

    private static func firefoxProfiles(
        in root: URL,
        homeDirectory: URL
    ) -> [FirefoxConfiguredProfile]? {
        guard let data = BrowserPrivacyDiscoveryFileAccess.data(
            at: root.appendingPathComponent("profiles.ini"),
            inside: root,
            maximumBytes: 512 * 1_024
        ),
        let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let sections = parseINI(text)
        let installDefaults: Set<String> = BrowserPrivacyDiscoveryFileAccess.data(
            at: root.appendingPathComponent("installs.ini"),
            inside: root,
            maximumBytes: 512 * 1_024
        ).flatMap { String(data: $0, encoding: .utf8) }
            .map(parseINI)?
            .values
            .compactMap { $0["Default"] }
            .reduce(into: Set<String>()) { $0.insert($1) }
            ?? []
        let home = homeDirectory.standardizedFileURL
        var result: [FirefoxConfiguredProfile] = []
        for (section, values) in sections {
            guard section.hasPrefix("Profile"),
                  let rawPath = values["Path"]?.trimmingCharacters(in: .whitespaces),
                  !rawPath.isEmpty else {
                continue
            }
            let isRelative = values["IsRelative"] != "0"
            let profileURL = (isRelative
                ? root.appendingPathComponent(rawPath, isDirectory: true)
                : URL(fileURLWithPath: rawPath, isDirectory: true))
                .standardizedFileURL
            guard Self.isDescendant(profileURL, of: home),
                  !result.contains(where: { $0.url == profileURL }) else {
                continue
            }
            let name = values["Name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = name.flatMap {
                !$0.isEmpty && $0.utf8.count <= 128 ? $0 : nil
            } ?? profileURL.lastPathComponent
            result.append(FirefoxConfiguredProfile(
                identifier: profileURL.lastPathComponent,
                displayName: displayName,
                url: profileURL,
                isDefault: values["Default"] == "1"
                    || installDefaults.contains(rawPath)
            ))
        }
        return result.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.identifier < $1.identifier
        }
    }

    private static func parseINI(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var section: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else {
                continue
            }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }
            guard let section, let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[section, default: [:]][key] = value
        }
        return result
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }
}

private enum DiscoveryResult {
    case success([BrowserPrivacyProfile], requiresFullDiskAccess: Bool)
    case permissionDenied
    case partial
    case unavailable
}

private struct BrowserPrivacyDirectoryChildren {
    let directories: [URL]
    let permissionDenied: Bool
}

private enum BrowserPrivacyRegularFileResult {
    case available(URL)
    case permissionDenied
    case unavailable
}

private enum BrowserPrivacyDiscoveryFileAccess {
    static func directory(at url: URL) -> BrowserPrivacyProviderAvailability {
        do {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                return .unavailable
            }
            return .available
        } catch {
            return isPermissionDenied(error) ? .permissionDenied : .unavailable
        }
    }

    static func children(
        of rootDirectory: URL,
        maximum: Int = 128
    ) -> BrowserPrivacyDirectoryChildren {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        } catch {
            return BrowserPrivacyDirectoryChildren(
                directories: [],
                permissionDenied: isPermissionDenied(error)
            )
        }

        var directories: [URL] = []
        var permissionDenied = false
        for entry in entries.prefix(maximum) {
            switch directory(at: entry) {
            case .available:
                directories.append(entry.standardizedFileURL)
            case .permissionDenied:
                permissionDenied = true
            case .noProfiles, .partial, .malformedSchema, .busy, .timedOut, .unavailable:
                continue
            }
        }
        return BrowserPrivacyDirectoryChildren(
            directories: directories.sorted { $0.lastPathComponent < $1.lastPathComponent },
            permissionDenied: permissionDenied
        )
    }

    static func regularFile(
        _ url: URL,
        inside root: URL
    ) -> BrowserPrivacyRegularFileResult {
        let normalized = url.standardizedFileURL
        guard isInside(normalized, root: root) else { return .unavailable }
        do {
            let values = try normalized.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return .unavailable
            }
            return .available(normalized)
        } catch {
            return isPermissionDenied(error) ? .permissionDenied : .unavailable
        }
    }

    static func data(
        at url: URL,
        inside root: URL,
        maximumBytes: Int
    ) -> Data? {
        guard maximumBytes > 0,
              case let .available(file) = regularFile(url, inside: root) else {
            return nil
        }
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1),
              data.count <= maximumBytes else {
            return nil
        }
        return data
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.Code.fileReadNoPermission.rawValue {
            return true
        }

        // Full Disk Access failures can surface through Foundation as a
        // POSIX EACCES/EPERM error instead of Cocoa's fileReadNoPermission.
        // Treat both as permission evidence so a browser is not mislabeled as
        // merely having no profiles or being unavailable.
        return error.domain == NSPOSIXErrorDomain
            && (error.code == EACCES || error.code == EPERM)
    }
}

/// Best-effort discovery for installed Chromium/Firefox derivatives. The
/// result is deliberately read-only: no unknown bundle receives a write
/// adapter, even when its SQLite layout resembles Chrome or Firefox.
private enum BrowserPrivacyDynamicDiscovery {
    struct Candidate: Sendable {
        let application: BrowserPrivacyInstalledApplication
        let engine: BrowserPrivacyEngine
        let root: URL
    }

    static func roots(
        under applicationSupport: URL,
        installedApplications: [BrowserPrivacyInstalledApplication],
        excluding knownBundleIdentifiers: Set<String>,
        maximumDirectories: Int = 256,
        maximumDepth: Int = 3
    ) -> [Candidate] {
        let directories = directoryTree(
            under: applicationSupport,
            maximum: maximumDirectories,
            maximumDepth: maximumDepth
        )
        var candidates: [Candidate] = []
        var seen = Set<String>()
        for application in installedApplications where
            !knownBundleIdentifiers.contains(application.bundleIdentifier)
                && application.canOpenWebURLs {
            // A profile may only be attributed to an unknown app when the
            // bundle has a complete, self-consistent local signature. This is
            // the fail-closed boundary that prevents a similarly named app
            // from inheriting a browser's history or write capability.
            guard let identity = application.signingIdentity,
                  identity.teamIdentifier?.trimmed.nonEmpty != nil,
                  identity.codeSigningIdentifier == application.bundleIdentifier else {
                continue
            }
            let tokens = tokens(for: application)
            guard !tokens.isEmpty else { continue }
            for root in directories where tokens.contains(normalized(root.lastPathComponent)) {
                let engine: BrowserPrivacyEngine?
                if hasChromiumHistory(at: root) {
                    engine = .chromium
                } else if hasFirefoxHistory(at: root) {
                    engine = .firefox
                } else {
                    engine = nil
                }
                guard let engine else { continue }
                let key = application.bundleIdentifier + "\n" + root.path + "\n" + engine.rawValue
                guard seen.insert(key).inserted else { continue }
                candidates.append(Candidate(
                    application: application,
                    engine: engine,
                    root: root
                ))
            }
        }
        return candidates.sorted {
            if $0.application.bundleIdentifier != $1.application.bundleIdentifier {
                return $0.application.bundleIdentifier < $1.application.bundleIdentifier
            }
            return $0.root.path < $1.root.path
        }
    }

    private static func directoryTree(
        under root: URL,
        maximum: Int,
        maximumDepth: Int
    ) -> [URL] {
        guard BrowserPrivacyDiscoveryFileAccess.directory(at: root) == .available else {
            return []
        }
        var result = [root.standardizedFileURL]
        var queue: [(URL, Int)] = [(root.standardizedFileURL, 0)]
        var index = 0
        while index < queue.count, result.count < maximum {
            let (directory, depth) = queue[index]
            index += 1
            guard depth < maximumDepth else { continue }
            let children = BrowserPrivacyDiscoveryFileAccess.children(
                of: directory,
                maximum: min(64, maximum)
            ).directories
            for child in children where result.count < maximum {
                let normalized = child.standardizedFileURL
                result.append(normalized)
                queue.append((normalized, depth + 1))
            }
        }
        return result
    }

    private static func tokens(
        for application: BrowserPrivacyInstalledApplication
    ) -> Set<String> {
        let bundleLeaf = application.bundleIdentifier.split(separator: ".").last.map(String.init)
        let appLeaf = application.url.deletingPathExtension().lastPathComponent
        let raw = [application.displayName, appLeaf, bundleLeaf].compactMap { $0 }
        var values = Set(raw.map(normalized))

        values.remove("")
        return values
    }

    private static func normalized(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    private static func hasChromiumHistory(at root: URL) -> Bool {
        let profileRoots = [root] + BrowserPrivacyDiscoveryFileAccess.children(
            of: root,
            maximum: 128
        ).directories.filter {
            let name = $0.lastPathComponent
            return name == "Default"
                || name == "Guest Profile"
                || name == "System Profile"
                || name.hasPrefix("Profile ")
        }
        return profileRoots.contains {
            isSQLiteFile(at: $0.appendingPathComponent("History"), inside: $0)
        }
    }

    private static func hasFirefoxHistory(at root: URL) -> Bool {
        let profilesRoot = root.appendingPathComponent("Profiles", isDirectory: true)
        guard BrowserPrivacyDiscoveryFileAccess.directory(at: profilesRoot) == .available else {
            return false
        }
        return BrowserPrivacyDiscoveryFileAccess.children(
            of: profilesRoot,
            maximum: 128
        ).directories.contains {
            isSQLiteFile(
                at: $0.appendingPathComponent("places.sqlite"),
                inside: $0
            )
        }
    }

    private static func isSQLiteFile(at file: URL, inside root: URL) -> Bool {
        guard case let .available(normalized) = BrowserPrivacyDiscoveryFileAccess.regularFile(
            file,
            inside: root
        ), let handle = try? FileHandle(forReadingFrom: normalized) else {
            return false
        }
        defer { try? handle.close() }
        guard handle.readData(ofLength: 16) == Data("SQLite format 3\0".utf8) else {
            return false
        }
        return matchesMinimalHistorySchema(at: normalized)
    }

    private static func matchesMinimalHistorySchema(at url: URL) -> Bool {
        let deadline = MonotonicClock.now &+ 500_000_000
        let control = SQLiteExecutionControl(deadlineNanoseconds: deadline)
        do {
            return try SQLiteRuntime.withReadOnlyDatabase(
                at: url,
                control: control,
                busyDeadlineNanoseconds: deadline,
                // The file was already lstat-checked above. SQLite on older
                // macOS builds may reject SQLITE_OPEN_NOFOLLOW outright;
                // retain the read-only gate without making discovery fail for
                // a supported local database.
                forbidSymbolicLinks: false
            ) { database in
                let chromiumURLColumns = try SQLiteRuntime.tableColumns(
                    "urls",
                    database: database,
                    control: control,
                    busyDeadlineNanoseconds: deadline
                )
                let chromiumVisitColumns = try SQLiteRuntime.tableColumns(
                    "visits",
                    database: database,
                    control: control,
                    busyDeadlineNanoseconds: deadline
                )
                if Set(["id", "url"]).isSubset(of: chromiumURLColumns),
                   Set(["url", "visit_time"]).isSubset(of: chromiumVisitColumns) {
                    return true
                }

                let firefoxURLColumns = try SQLiteRuntime.tableColumns(
                    "moz_places",
                    database: database,
                    control: control,
                    busyDeadlineNanoseconds: deadline
                )
                let firefoxVisitColumns = try SQLiteRuntime.tableColumns(
                    "moz_historyvisits",
                    database: database,
                    control: control,
                    busyDeadlineNanoseconds: deadline
                )
                return Set(["id", "url"]).isSubset(of: firefoxURLColumns)
                    && Set(["place_id", "visit_date"]).isSubset(of: firefoxVisitColumns)
            }
        } catch {
            return false
        }
    }
}

private extension RegisteredBrowserPrivacyProvider {
    static let safari = Self(
        descriptor: .init(
            id: "safari",
            displayName: "Safari",
            engine: .safari,
            bundleIdentifiers: ["com.apple.Safari"],
            profileRootRelativePaths: ["Library/Safari"]
        ),
        layout: .safari
    )

    static let chrome = chromium(
        id: "chrome",
        name: "Google Chrome",
        bundleIDs: [
            "com.google.Chrome",
            "com.google.Chrome.beta",
            "com.google.Chrome.canary",
        ],
        roots: ["Library/Application Support/Google/Chrome"]
    )

    static let chromiumBrowser = chromium(
        id: "chromium",
        name: "Chromium",
        bundleIDs: ["org.chromium.Chromium"],
        roots: ["Library/Application Support/Chromium"]
    )

    static let edge = chromium(
        id: "edge",
        name: "Microsoft Edge",
        bundleIDs: ["com.microsoft.edgemac"],
        roots: ["Library/Application Support/Microsoft Edge"]
    )

    static let brave = chromium(
        id: "brave",
        name: "Brave",
        bundleIDs: ["com.brave.Browser"],
        roots: ["Library/Application Support/BraveSoftware/Brave-Browser"]
    )

    static let arc = chromium(
        id: "arc",
        name: "Arc",
        bundleIDs: ["company.thebrowser.Browser"],
        roots: ["Library/Application Support/Arc/User Data"]
    )

    static let opera = chromium(
        id: "opera",
        name: "Opera",
        bundleIDs: ["com.operasoftware.Opera"],
        roots: ["Library/Application Support/com.operasoftware.Opera"]
    )

    static let operaGX = chromium(
        id: "opera-gx",
        name: "Opera GX",
        bundleIDs: ["com.operasoftware.OperaGX"],
        roots: ["Library/Application Support/com.operasoftware.OperaGX"]
    )

    static let vivaldi = chromium(
        id: "vivaldi",
        name: "Vivaldi",
        bundleIDs: ["com.vivaldi.Vivaldi"],
        roots: ["Library/Application Support/Vivaldi"]
    )

    static let orion = Self(
        descriptor: .init(
            id: "orion",
            displayName: "Orion",
            engine: .safari,
            bundleIdentifiers: ["com.kagi.kagimacOS"],
            profileRootRelativePaths: ["Library/Application Support/Orion"]
        ),
        layout: .safari
    )

    static let firefox = firefox(
        id: "firefox",
        name: "Firefox",
        bundleIDs: [
            "org.mozilla.firefox",
            "org.mozilla.firefoxdeveloperedition",
            "org.mozilla.nightly",
        ],
        roots: ["Library/Application Support/Firefox"]
    )

    static let zen = firefox(
        id: "zen",
        name: "Zen",
        bundleIDs: ["app.zen-browser.zen"],
        roots: ["Library/Application Support/zen"]
    )

    static let libreWolf = firefox(
        id: "librewolf",
        name: "LibreWolf",
        bundleIDs: ["io.gitlab.librewolf-community"],
        roots: ["Library/Application Support/LibreWolf"]
    )

    static let waterfox = firefox(
        id: "waterfox",
        name: "Waterfox",
        bundleIDs: ["net.waterfox.waterfox"],
        roots: ["Library/Application Support/Waterfox"]
    )

    static func chromium(
        id: String,
        name: String,
        bundleIDs: [String],
        roots: [String]
    ) -> Self {
        Self(
            descriptor: .init(
                id: id,
                displayName: name,
                engine: .chromium,
                bundleIdentifiers: bundleIDs,
                profileRootRelativePaths: roots
            ),
            layout: .chromium,
            allowsProductionWrite: true
        )
    }

    static func firefox(
        id: String,
        name: String,
        bundleIDs: [String],
        roots: [String]
    ) -> Self {
        Self(
            descriptor: .init(
                id: id,
                displayName: name,
                engine: .firefox,
                bundleIdentifiers: bundleIDs,
                profileRootRelativePaths: roots
            ),
            layout: .firefox
        )
    }

    static func discovered(
        application: BrowserPrivacyInstalledApplication,
        engine: BrowserPrivacyEngine,
        profileRoot: URL,
        homeDirectory: URL
    ) -> Self? {
        let homePath = homeDirectory.standardizedFileURL.path
        let rootPath = profileRoot.standardizedFileURL.path
        guard rootPath.hasPrefix(homePath == "/" ? "/" : homePath + "/") else {
            return nil
        }
        let relativePath = String(rootPath.dropFirst(homePath.count + 1))
        guard !relativePath.isEmpty else { return nil }
        let safeID = application.bundleIdentifier
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." })
            .joined(separator: ".")
        guard !safeID.isEmpty else { return nil }
        let layout: ProfileLayout
        switch engine {
        case .chromium: layout = .chromium
        case .firefox: layout = .firefox
        case .safari: return nil
        }
        return Self(
            descriptor: .init(
                id: "discovered.\(safeID)",
                displayName: application.displayName ?? application.bundleIdentifier,
                engine: engine,
                bundleIdentifiers: [application.bundleIdentifier],
                profileRootRelativePaths: [relativePath]
            ),
            layout: layout
        )
    }
}
