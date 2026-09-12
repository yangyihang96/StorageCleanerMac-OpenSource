#if DEBUG || STORAGE_CLEANER_BETA
import Foundation

enum BrowserPrivacyPreviewFixture {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--browser-privacy-preview")
    }

    @MainActor
    static func makeStore() -> BrowserPrivacyStore {
        BrowserPrivacyStore(scanner: Scanner(outcome: outcome))
    }

    private static var outcome: BrowserPrivacyScanOutcome {
        let browser = BrowserPrivacyBrowser(
            id: "chrome",
            displayName: "Google Chrome",
            engine: .chromium,
            bundleIdentifier: "com.google.Chrome",
            version: "Fixture"
        )
        let root = URL(fileURLWithPath: "/tmp/storage-cleaner-browser-preview", isDirectory: true)
        let baseDate = Date(timeIntervalSince1970: 1_750_000_000)
        let rows: [(Int64, String, String, Date)] = [
            (101, "https://news.example/article#comments", "news.example", baseDate),
            (102, "https://news.example/article#details", "news.example", baseDate.addingTimeInterval(-120)),
            (103, "https://bank.example/account", "bank.example", baseDate.addingTimeInterval(-3_600)),
            (104, "chrome://settings/privacy", "", baseDate.addingTimeInterval(-7_200)),
        ]
        let records = rows.map { rowID, url, domain, date in
            let profileID = rowID == 103 ? "chrome:Profile 2" : "chrome:Default"
            let locator = BrowserPrivacyRecordLocator(
                providerID: browser.id,
                profileID: profileID,
                engine: .chromium,
                visitRowID: rowID,
                parentRowID: rowID + 1_000,
                visitTimestampIdentity: .integer(rowID * 1_000),
                rawURL: url,
                databaseURL: root.appendingPathComponent("History"),
                trustedParentURL: root,
                identityChain: [.init(device: 1, inode: UInt64(rowID), kind: 0o100000)]
            )
            return BrowserPrivacyRecord(
                id: UUID(),
                browser: browser,
                profileID: profileID,
                profileDisplayName: profileID.hasSuffix("Default") ? "默认" : "工作",
                source: .history,
                url: url,
                domain: domain.isEmpty ? nil : domain,
                title: nil,
                searchKeyword: nil,
                visitedAt: date,
                visitCount: 1,
                category: domain == "bank.example" ? .finance : .news,
                selectionConfidence: .medium,
                sizeBytes: nil,
                locator: locator
            )
        }
        return BrowserPrivacyScanOutcome(
            state: .completed,
            records: records,
            coverage: [BrowserPrivacyProviderCoverage(
                browser: browser,
                availability: .available,
                profileCount: 2,
                recordCount: records.count,
                detail: "Anonymous Beta UI fixture",
                fullyScannedProfileIDs: ["chrome:Default", "chrome:Profile 2"]
            )]
        )
    }

    private struct Scanner: BrowserPrivacyScanning {
        let outcome: BrowserPrivacyScanOutcome

        func scan() async throws -> BrowserPrivacyScanOutcome { outcome }
    }
}
#endif
