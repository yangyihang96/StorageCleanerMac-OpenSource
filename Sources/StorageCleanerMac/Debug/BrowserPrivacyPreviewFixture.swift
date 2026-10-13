#if DEBUG
import Foundation

/// Anonymous in-memory records for layout work (`--browser-privacy-preview`).
/// Every address uses a reserved `.example` domain or a browser-internal
/// page; nothing is read from a real profile.
///
/// The set is chosen to show that every row identifies its page: titled
/// pages, several pages of one site, one page with several visits and
/// fragments, query parameters, a search, a page without a title, a
/// browser-internal address, and Safari records that can only be handled in
/// the browser.
enum BrowserPrivacyPreviewFixture {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--browser-privacy-preview")
    }

    @MainActor
    static func makeStore(outcome: BrowserPrivacyScanOutcome? = nil) -> BrowserPrivacyStore {
        BrowserPrivacyStore(scanner: Scanner(outcome: outcome ?? self.outcome),
            processor: Processor(), runningApplicationChecker: RunningApplications())
    }

    private struct Row {
        let visitID: Int64
        let pageID: Int64
        let profileID: String
        let profileName: String
        let url: String
        let title: String?
        let searchKeyword: String?
        let category: BrowserPrivacyCategory
        let minutesAgo: Double
    }

    private static let chrome = BrowserPrivacyBrowser(
        id: "chrome",
        displayName: "Google Chrome",
        engine: .chromium,
        bundleIdentifier: "com.google.Chrome",
        version: "Fixture"
    )

    private static let safari = BrowserPrivacyBrowser(
        id: "safari",
        displayName: "Safari",
        engine: .safari,
        bundleIdentifier: "com.apple.Safari",
        version: "Fixture"
    )

    private static let chromeRows: [Row] = [
        // One page, three visits, two of them to a fragment.
        Row(visitID: 101, pageID: 1, profileID: "chrome:Default", profileName: "默认",
            url: "https://news.example/world/2026/markets-rally#comments",
            title: "全球股市反弹：三大指数齐涨 - 示例新闻", searchKeyword: nil, category: .news, minutesAgo: 0),
        Row(visitID: 102, pageID: 1, profileID: "chrome:Default", profileName: "默认",
            url: "https://news.example/world/2026/markets-rally#details",
            title: "全球股市反弹：三大指数齐涨 - 示例新闻", searchKeyword: nil, category: .news, minutesAgo: 2),
        Row(visitID: 103, pageID: 1, profileID: "chrome:Default", profileName: "默认",
            url: "https://news.example/world/2026/markets-rally",
            title: "全球股市反弹：三大指数齐涨 - 示例新闻", searchKeyword: nil, category: .news, minutesAgo: 9),
        // Other pages of the same site.
        Row(visitID: 104, pageID: 2, profileID: "chrome:Default", profileName: "默认",
            url: "https://news.example/tech/ai-chips",
            title: "AI 芯片供应观察 - 示例新闻", searchKeyword: nil, category: .news, minutesAgo: 25),
        Row(visitID: 105, pageID: 3, profileID: "chrome:Default", profileName: "默认",
            url: "https://news.example/sports/final-score",
            title: "决赛比分 - 示例新闻", searchKeyword: nil, category: .news, minutesAgo: 40),
        // Query parameters, in a second profile.
        Row(visitID: 106, pageID: 4, profileID: "chrome:Profile 2", profileName: "工作",
            url: "https://bank.example/accounts/statement?month=2026-05&token=demo-token-1234",
            title: "对账单 - 示例银行", searchKeyword: nil, category: .finance, minutesAgo: 60),
        Row(visitID: 107, pageID: 4, profileID: "chrome:Profile 2", profileName: "工作",
            url: "https://bank.example/accounts/statement?month=2026-05&token=demo-token-1234",
            title: "对账单 - 示例银行", searchKeyword: nil, category: .finance, minutesAgo: 1_500),
        Row(visitID: 111, pageID: 10, profileID: "chrome:Default", profileName: "默认",
            url: "https://private.example/review/page", title: "敏感页面示例", searchKeyword: nil,
            category: .adult, minutesAgo: 10),
        Row(visitID: 112, pageID: 11, profileID: "chrome:Default", profileName: "默认",
            url: "https://account.example/login?token=demo-only", title: nil, searchKeyword: nil,
            category: .finance, minutesAgo: 20),
        // A search: the term is inside the folded query.
        Row(visitID: 108, pageID: 5, profileID: "chrome:Default", profileName: "默认",
            url: "https://search.example/results?q=%E7%BB%BF%E8%8C%B6+%E5%8A%9F%E6%95%88",
            title: "绿茶 功效 - 示例搜索", searchKeyword: "绿茶 功效", category: .search, minutesAgo: 75),
        // No recorded title and a long address.
        Row(visitID: 109, pageID: 6, profileID: "chrome:Default", profileName: "默认",
            url: "https://shop.example/cart/checkout/step-2/confirm-order-and-delivery-address/gift-wrapping-options?session=demo-session",
            title: nil, searchKeyword: nil, category: .shopping, minutesAgo: 120),
        // A browser-internal page: no site, the address is shown as recorded.
        Row(visitID: 110, pageID: 7, profileID: "chrome:Default", profileName: "默认",
            url: "chrome://settings/privacy",
            title: "设置 - 隐私和安全", searchKeyword: nil, category: .unknown, minutesAgo: 180),
    ]

    private static let safariRows: [Row] = [
        Row(visitID: 201, pageID: 8, profileID: "safari:Safari", profileName: "Safari",
            url: "https://docs.example/guide/getting-started",
            title: "入门指南 - 示例文档", searchKeyword: nil, category: .productivity, minutesAgo: 15),
        Row(visitID: 202, pageID: 9, profileID: "safari:Safari", profileName: "Safari",
            url: "https://video.example/watch?v=demo123",
            title: "示例视频：十分钟学会整理磁盘", searchKeyword: nil, category: .entertainment, minutesAgo: 300),
    ]

    static var outcome: BrowserPrivacyScanOutcome {
        let root = URL(fileURLWithPath: "/tmp/storage-cleaner-browser-preview", isDirectory: true)
        let baseDate = Date()

        func record(
            _ row: Row,
            browser: BrowserPrivacyBrowser,
            deletable: Bool
        ) -> BrowserPrivacyRecord {
            let locator = deletable
                ? BrowserPrivacyRecordLocator(
                    providerID: browser.id,
                    profileID: row.profileID,
                    engine: browser.engine,
                    visitRowID: row.visitID,
                    parentRowID: row.pageID + 1_000,
                    visitTimestampIdentity: .integer(row.visitID * 1_000),
                    rawURL: row.url,
                    databaseURL: root.appendingPathComponent("History"),
                    trustedParentURL: root,
                    identityChain: [.init(device: 1, inode: UInt64(row.visitID), kind: 0o100000)]
                )
                : nil
            let host = URLComponents(string: row.url).flatMap { components -> String? in
                guard components.scheme == "https" else { return nil }
                return components.host
            }
            return BrowserPrivacyRecord(
                id: UUID(),
                browser: browser,
                profileID: row.profileID,
                profileDisplayName: row.profileName,
                source: .history,
                url: row.url,
                domain: host,
                title: row.title,
                searchKeyword: row.searchKeyword,
                visitedAt: baseDate.addingTimeInterval(-row.minutesAgo * 60),
                visitCount: 1,
                category: row.category,
                selectionConfidence: .medium,
                sizeBytes: nil,
                locator: locator,
                directDeletionBlocker: deletable ? nil : .browserNotSupported
            )
        }

        let chromeRecords = chromeRows.map { record($0, browser: chrome, deletable: true) }
        let safariRecords = safariRows.map { record($0, browser: safari, deletable: false) }
        return BrowserPrivacyScanOutcome(
            state: .completed,
            records: chromeRecords + safariRecords,
            coverage: [
                BrowserPrivacyProviderCoverage(
                    browser: chrome,
                    availability: .available,
                    profileCount: 2,
                    recordCount: chromeRecords.count,
                    detail: "Anonymous Beta UI fixture",
                    fullyScannedProfileIDs: ["chrome:Default", "chrome:Profile 2"]
                ),
                BrowserPrivacyProviderCoverage(
                    browser: safari,
                    availability: .available,
                    profileCount: 1,
                    recordCount: safariRecords.count,
                    detail: "Anonymous Beta UI fixture",
                    fullyScannedProfileIDs: ["safari:Safari"]
                ),
            ]
        )
    }

    @MainActor static func makeResultStore(outcome: BrowserPrivacyScanOutcome? = nil) async -> BrowserPrivacyStore {
        let store = makeStore(outcome: outcome)
        store.startScan()
        await store.waitUntilIdle()
        return store
    }

    private struct Processor: BrowserPrivacyHistoryProcessing {
        func process(records: [BrowserPrivacyRecord]) async -> BrowserPrivacyProcessingReport {
            BrowserPrivacyProcessingReport(selectedRecordCount: records.count, entries: [])
        }
    }
    private struct RunningApplications: BrowserPrivacyRunningApplicationChecking {
        func runningBundleIdentifiers(matching bundleIdentifiers: Set<String>) async -> Set<String> { [] }
    }
    private struct Scanner: BrowserPrivacyScanning {
        let outcome: BrowserPrivacyScanOutcome

        func scan() async throws -> BrowserPrivacyScanOutcome { outcome }
    }
}
#endif
