import Foundation
import XCTest
@testable import StorageCleanerMac

final class PrivacyCleanupPresentationTests: XCTestCase {
    func testBrowserPrivacyManualWorkflowNormalizesDomainsForClipboard() {
        XCTAssertEqual(
            BrowserPrivacyManualWorkflow.normalizedDomains([
                " Beta.Example ",
                "alpha.example",
                "beta.example",
                nil,
                "\n",
            ]),
            ["alpha.example", "beta.example"]
        )
        XCTAssertEqual(
            BrowserPrivacyManualWorkflow.clipboardText(
                domains: [" Beta.Example ", "alpha.example", "beta.example"]
            ),
            "alpha.example\nbeta.example"
        )
    }

    func testBrowserPrivacyManualWorkflowUsesAuditedRoutesForFourCanonicalBrowsers() {
        let safari = browser(id: "safari", name: "Safari", engine: .safari)
        let chrome = BrowserPrivacyBrowser(
            id: "chrome",
            displayName: "Chrome",
            engine: .chromium,
            bundleIdentifier: "com.google.Chrome",
            version: nil
        )
        let edge = browser(id: "edge", name: "Edge", engine: .chromium)
        let firefox = browser(id: "firefox", name: "Firefox", engine: .firefox)

        XCTAssertNil(BrowserPrivacyManualWorkflow.historyRoute(for: safari)?.destinationURL)
        XCTAssertTrue(BrowserPrivacyManualWorkflow.historyInstruction(for: safari).contains("Command-Y"))
        XCTAssertEqual(
            BrowserPrivacyManualWorkflow.historyRoute(for: chrome)?.destinationURL?.absoluteString,
            "chrome://history/"
        )
        XCTAssertEqual(
            BrowserPrivacyManualWorkflow.historyRoute(for: edge)?.destinationURL?.absoluteString,
            "edge://history/all"
        )
        XCTAssertNil(BrowserPrivacyManualWorkflow.historyRoute(for: firefox)?.destinationURL)
        XCTAssertTrue(BrowserPrivacyManualWorkflow.historyInstruction(for: firefox).contains("Command-Shift-H"))
    }

    func testBrowserPrivacyDerivativeFallsBackToLaunchOnlyGuidance() {
        let brave = browser(id: "brave", name: "Brave", engine: .chromium)

        XCTAssertNil(BrowserPrivacyManualWorkflow.historyRoute(for: brave))
        XCTAssertTrue(
            BrowserPrivacyManualWorkflow.historyInstruction(for: brave)
                .localizedCaseInsensitiveContains("Brave")
        )
    }

    // MARK: - D20: every row identifies the site and the page

    func testRowShowsTitleSiteAndPathAndFoldsTheQuery() {
        let url = "https://private-bank.example/account/overview?token=secret-token&q=hidden+phrase#section"
        let record = privacyRecord(
            browser: browser(id: "chrome", name: "Chrome", engine: .chromium),
            url: url,
            domain: "private-bank.example",
            title: "Private Bank Account Overview",
            keyword: "hidden phrase"
        )

        let presentation = BrowserPrivacyRecordPresentation(record: record)

        XCTAssertEqual(presentation.title, "Private Bank Account Overview")
        XCTAssertTrue(presentation.hasRecordedTitle)
        XCTAssertEqual(presentation.address.collapsed, "private-bank.example/account/overview?…")
        XCTAssertEqual(presentation.address.full, url, "the complete address is one step away")
        XCTAssertTrue(presentation.address.hasFoldedDetail)
        XCTAssertTrue(presentation.accessibilityLabel.contains("Chrome"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("private-bank.example/account/overview"))

        // Query parameters may carry tokens: nothing the row prints by
        // default contains them.
        let printedByDefault = [
            presentation.title,
            presentation.address.collapsed,
            presentation.summary,
            presentation.accessibilityLabel,
        ].joined(separator: " ")
        for secret in ["secret-token", "hidden phrase", "hidden+phrase", "#section"] {
            XCTAssertFalse(printedByDefault.contains(secret), secret)
        }
    }

    func testRowWithoutATitleUsesTheAddressInsteadOfAPlaceholder() {
        let presentation = BrowserPrivacyRecordPresentation(record: privacyRecord(
            browser: browser(id: "chrome", name: "Chrome", engine: .chromium),
            url: "https://private-bank.example/account/overview?token=secret-token",
            domain: "private-bank.example",
            title: nil
        ))

        XCTAssertFalse(presentation.hasRecordedTitle)
        XCTAssertEqual(presentation.title, "private-bank.example/account/overview?…")
        XCTAssertEqual(presentation.address.collapsed, presentation.title)
        for placeholder in ["未记录页面标题", "Page title unavailable", "未知网站", "Unknown site"] {
            XCTAssertFalse(presentation.title.contains(placeholder))
            XCTAssertFalse(presentation.accessibilityLabel.contains(placeholder))
        }

        let blankTitle = BrowserPrivacyRecordPresentation(record: privacyRecord(
            browser: browser(id: "chrome", name: "Chrome", engine: .chromium),
            url: "https://news.example/story",
            domain: "news.example",
            title: "  \n "
        ))
        XCTAssertEqual(blankTitle.title, "news.example/story", "a whitespace-only title is no title")
    }

    func testAddressesOtherThanWebPagesAreShownAsRecorded() {
        func address(_ url: String) -> BrowserPrivacyAddressPresentation {
            BrowserPrivacyAddressPresentation(url: url, domain: nil)
        }

        for original in [
            "chrome://settings/privacy",
            "file:///Users/demo/Documents/report.pdf",
            "about:blank",
            "edge://history/all",
        ] {
            XCTAssertEqual(address(original).collapsed, original)
            XCTAssertEqual(address(original).full, original)
            XCTAssertTrue(address(original).isAvailable)
            XCTAssertFalse(address(original).hasFoldedDetail)
        }
        XCTAssertEqual(
            address("chrome-extension://abcdef/options.html?tab=2").collapsed,
            "chrome-extension://abcdef/options.html?…"
        )
        let internalPage = BrowserPrivacyRecordPresentation(record: privacyRecord(
            browser: browser(id: "chrome", name: "Chrome", engine: .chromium),
            url: "chrome://settings/privacy",
            domain: nil,
            title: nil
        ))
        XCTAssertEqual(internalPage.title, "chrome://settings/privacy")
        XCTAssertFalse(internalPage.accessibilityLabel.contains("未知网站"))
        XCTAssertFalse(internalPage.accessibilityLabel.contains("Unknown site"))
    }

    func testAddressPresentationHandlesHostPortEncodingAndMissingValues() {
        func collapsed(_ url: String) -> String {
            BrowserPrivacyAddressPresentation(url: url, domain: nil).collapsed
        }

        XCTAssertEqual(collapsed("https://example.com/"), "example.com")
        XCTAssertEqual(collapsed("https://example.com"), "example.com")
        XCTAssertEqual(collapsed("http://Example.COM:8080/a/b"), "example.com:8080/a/b")
        XCTAssertEqual(collapsed("https://example.com/path#anchor"), "example.com/path")
        XCTAssertEqual(
            collapsed("https://zh.example/wiki/%E7%BB%BF%E8%8C%B6"),
            "zh.example/wiki/绿茶",
            "an encoded path is shown readable"
        )
        XCTAssertEqual(
            collapsed("https://user:password@example.com/private"),
            "example.com/private",
            "credentials in an address are not part of the row"
        )

        // Invisible direction overrides and line breaks never reach a view.
        let hostile = BrowserPrivacyAddressPresentation(
            url: "https://example.com/a\u{202E}fdp.exe\nsecond",
            domain: nil
        )
        for text in [hostile.collapsed, hostile.full ?? ""] {
            XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x0A })
        }

        let long = BrowserPrivacyAddressPresentation(
            url: "https://example.com/" + String(repeating: "a", count: 6_000),
            domain: nil
        )
        XCTAssertLessThanOrEqual(long.full?.count ?? .max, 2_048)

        let siteOnly = BrowserPrivacyAddressPresentation(url: nil, domain: "Only-Site.Example")
        XCTAssertEqual(siteOnly.collapsed, "only-site.example")
        XCTAssertNil(siteOnly.full)
        XCTAssertFalse(siteOnly.hasFoldedDetail)
        XCTAssertTrue(siteOnly.isAvailable)

        let nothing = BrowserPrivacyAddressPresentation(url: nil, domain: nil)
        XCTAssertFalse(nothing.isAvailable)
        XCTAssertNil(nothing.full)
    }

    func testListedPageCarriesNewestRecordedTitleAndAddress() throws {
        let chrome = browser(id: "chrome", name: "Chrome", engine: .chromium)
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let newestUntitled = privacyRecord(
            browser: chrome,
            url: "https://docs.example/guide#install",
            domain: "docs.example",
            title: nil,
            visitedAt: base
        )
        let olderTitled = privacyRecord(
            browser: chrome,
            url: "https://docs.example/guide#intro",
            domain: "docs.example",
            title: "Guide",
            visitedAt: base.addingTimeInterval(-600)
        )

        let item = try XCTUnwrap(
            BrowserPrivacyDisplayItem.aggregate([olderTitled, newestUntitled]).first
        )

        XCTAssertEqual(item.visitCount, 2, "fragments of one page are one row")
        XCTAssertEqual(item.title, "Guide", "the newest recorded title wins over a missing one")
        XCTAssertEqual(item.address, "https://docs.example/guide#install")
        XCTAssertEqual(item.latestVisitedAt, base)
        XCTAssertEqual(item.records.map(\.id), [newestUntitled.id, olderTitled.id])
        let presentation = BrowserPrivacyRecordPresentation(item: item)
        XCTAssertEqual(presentation.title, "Guide")
        XCTAssertEqual(presentation.address.collapsed, "docs.example/guide")
        XCTAssertEqual(presentation.visitCount, 2)
    }

    func testExpandedRowListsEveryVisitWithWhatDistinguishesIt() throws {
        let chrome = browser(id: "chrome", name: "Chrome", engine: .chromium)
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let comments = privacyRecord(
            browser: chrome, url: "https://news.example/article#comments",
            domain: "news.example", title: "Article", visitedAt: base
        )
        let details = privacyRecord(
            browser: chrome, url: "https://news.example/article#details",
            domain: "news.example", title: "Article (draft)", visitedAt: base.addingTimeInterval(-120)
        )
        let plain = privacyRecord(
            browser: chrome, url: "https://news.example/article",
            domain: "news.example", title: "Article", visitedAt: base.addingTimeInterval(-240)
        )
        let item = try XCTUnwrap(
            BrowserPrivacyDisplayItem.aggregate([plain, details, comments]).first
        )

        let visits = BrowserPrivacyVisitPresentation.visits(of: item)

        XCTAssertEqual(visits.map(\.id), [comments.id, details.id, plain.id], "newest first")
        XCTAssertEqual(visits.map(\.detail), ["#comments", "#details · Article (draft)", nil])
        XCTAssertEqual(Set(visits.map(\.time)).count, 3, "each visit shows its own time")

        let many = (0 ..< 120).map { index in
            privacyRecord(
                browser: chrome, url: "https://busy.example/page",
                domain: "busy.example", title: "Busy",
                visitedAt: base.addingTimeInterval(Double(-index * 60))
            )
        }
        let busy = try XCTUnwrap(BrowserPrivacyDisplayItem.aggregate(many).first)
        XCTAssertEqual(busy.visitCount, 120)
        XCTAssertEqual(
            BrowserPrivacyVisitPresentation.visits(of: busy).count,
            BrowserPrivacyVisitPresentation.displayLimit
        )
    }

    func testSearchHintExplainsMatchesTheRowDoesNotPrint() throws {
        let chrome = browser(id: "chrome", name: "Chrome", engine: .chromium)
        let item = try XCTUnwrap(BrowserPrivacyDisplayItem.aggregate([
            privacyRecord(
                browser: chrome,
                url: "https://find.example/results?q=green+tea&session=abc123",
                domain: "find.example",
                title: "Results",
                keyword: "green tea",
                category: .search
            ),
        ]).first)
        func hint(_ query: String, keyword: String = "") -> String? {
            BrowserPrivacyRecordPresentation.searchHint(
                for: item,
                query: query,
                keywordFilter: keyword
            )
        }

        XCTAssertNil(hint(""))
        XCTAssertNil(hint("results"), "the title already shows why")
        XCTAssertNil(hint("find.example"), "the address already shows why")
        XCTAssertNil(hint("Search"), "a printed category already shows why")
        XCTAssertTrue(try XCTUnwrap(hint("GREEN")).contains("green tea"), "the hidden search term is named")
        XCTAssertTrue(try XCTUnwrap(hint("", keyword: "tea")).contains("green tea"))
        let parameterHint = try XCTUnwrap(hint("abc123"))
        XCTAssertFalse(parameterHint.contains("green tea"))
        XCTAssertTrue(parameterHint.contains("参数") || parameterHint.contains("parameters"))

        // "Other" is not printed on the row, so a match on it is explained.
        let other = try XCTUnwrap(BrowserPrivacyDisplayItem.aggregate([
            privacyRecord(
                browser: chrome, url: "https://misc.example/x",
                domain: "misc.example", title: "Misc", category: .other
            ),
        ]).first)
        XCTAssertNil(BrowserPrivacyRecordPresentation(item: other).category)
        let categoryHint = try XCTUnwrap(
            BrowserPrivacyRecordPresentation.searchHint(for: other, query: "其他")
        )
        XCTAssertTrue(categoryHint.contains(BrowserPrivacyCategory.other.title))
    }

    func testCountsAlwaysNamePagesAndVisits() {
        withAppLanguage(.zhHans) {
            XCTAssertEqual(
                BrowserPrivacyCountText.listHeader(pages: 3, visits: 7, selectedVisits: 2),
                "3 个页面 · 7 次访问 · 已选 2 次访问"
            )
            XCTAssertEqual(BrowserPrivacyCountText.pagesAndVisits(pages: 1, visits: 1), "1 个页面 · 1 次访问")
        }
        withAppLanguage(.english) {
            XCTAssertEqual(
                BrowserPrivacyCountText.listHeader(pages: 3, visits: 7, selectedVisits: 1),
                "3 pages · 7 visits · 1 visit selected"
            )
            XCTAssertEqual(BrowserPrivacyCountText.pagesAndVisits(pages: 1, visits: 1), "1 page · 1 visit")
        }
    }

    func testConfirmationNamesTheFirstPagesAndCountsTheRest() {
        let chrome = browser(id: "chrome", name: "Chrome", engine: .chromium)
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let records = (0 ..< 9).map { index in
            privacyRecord(
                browser: chrome,
                url: "https://shop.example/item/\(index)?ref=mail",
                domain: "shop.example",
                title: index == 0 ? nil : "Item \(index)",
                visitedAt: base.addingTimeInterval(Double(-index * 60))
            )
        }
        let items = BrowserPrivacyDisplayItem.aggregate(records)
        XCTAssertEqual(items.count, 9)

        withAppLanguage(.zhHans) {
            let lines = BrowserPrivacyPageListText.lines(for: items, limit: 6)
            XCTAssertEqual(lines.count, 7)
            XCTAssertEqual(lines[0], "• shop.example/item/0?…", "an untitled page is named by its address")
            XCTAssertEqual(lines[1], "• Item 1 — shop.example/item/1?…")
            XCTAssertEqual(lines[6], "等 3 个页面")
            XCTAssertEqual(BrowserPrivacyPageListText.lines(for: Array(items.prefix(2))).count, 2)
            XCTAssertFalse(lines.joined().contains("ref=mail"), "query parameters stay folded here too")
        }
    }

    func testManualGuidanceShowsRealSitesAndPagesGroupedByBrowser() {
        let chrome = browser(id: "chrome", name: "Chrome", engine: .chromium)
        let safari = browser(id: "safari", name: "Safari", engine: .safari)
        let groups = BrowserPrivacyManualWorkflow.groups(from: [
            privacyRecord(browser: chrome, url: "https://bank.example/statements", domain: "bank.example", title: "Statements"),
            privacyRecord(browser: chrome, url: "https://bank.example/statements", domain: "bank.example", title: "Statements"),
            privacyRecord(browser: chrome, url: "https://search.example/", domain: "search.example"),
            privacyRecord(browser: chrome, url: "chrome://settings/privacy", domain: nil),
            privacyRecord(browser: safari, url: "https://social.example/feed", domain: "social.example"),
        ])

        XCTAssertEqual(groups.map(\.browser.id), ["chrome", "safari"])
        XCTAssertEqual(groups[0].domains, ["bank.example", "search.example"])
        XCTAssertEqual(groups[0].recordCount, 4)
        XCTAssertEqual(groups[0].pages.count, 3, "two visits of one page are one page")
        XCTAssertEqual(groups[1].domains, ["social.example"])

        // D20: the page shows the real sites, not masked ones.
        withAppLanguage(.english) {
            XCTAssertEqual(
                BrowserPrivacyPageListText.siteSummary(groups[0].domains),
                "bank.example, search.example"
            )
            XCTAssertEqual(
                BrowserPrivacyPageListText.siteSummary(["a.example", "b.example", "c.example"], limit: 2),
                "a.example, b.example and 1 more sites"
            )
        }
        let pageLines = BrowserPrivacyPageListText.lines(for: groups[0].pages).joined(separator: "\n")
        XCTAssertTrue(pageLines.contains("Statements — bank.example/statements"))
        XCTAssertTrue(pageLines.contains("chrome://settings/privacy"), "pages without a domain are still listed")
        XCTAssertEqual(
            BrowserPrivacyManualWorkflow.clipboardText(domains: groups[0].domains),
            "bank.example\nsearch.example"
        )
    }

    // MARK: - Second review round

    func testCopiedAddressesAreMarkedConcealedAndTransient() {
        // A private named pasteboard: the user's clipboard is not touched.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("StorageCleanerTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        XCTAssertTrue(BrowserPrivacyClipboard.write("https://example.com/a?token=1", to: pasteboard))

        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(.string))
        XCTAssertTrue(types.contains(BrowserPrivacyClipboard.concealedType), "clipboard managers must not record it")
        XCTAssertTrue(types.contains(BrowserPrivacyClipboard.transientType))
        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/a?token=1")
    }

    func testHoverShowsTheAddressWithoutItsQuery() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = try [
            "Sources/StorageCleanerMac/Views/BrowserPrivacyRecordPresentation.swift",
            "Sources/StorageCleanerMac/Views/BrowserPrivacyRecordResultsView.swift",
        ].map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }
        // D20: query parameters stay folded until the row is expanded, so a
        // tooltip never carries the complete address.
        let fullAddressInTooltip = try NSRegularExpression(pattern: #"\.help\([^\n]*address\.full"#)
        for source in sources {
            XCTAssertEqual(
                fullAddressInTooltip.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)),
                0
            )
        }
        XCTAssertTrue(sources[0].contains(".help(presentation.address.collapsed)"))
    }

    func testDeletionConfirmationStatesTheBackupAndIncompleteReads() {
        let chrome = browser(id: "chrome", name: "Google Chrome", engine: .chromium)
        let edge = browser(id: "edge", name: "Microsoft Edge", engine: .chromium)
        let safari = browser(id: "safari", name: "Safari", engine: .safari)
        let records = [
            directRecord(browser: chrome, url: "https://running.example/a", title: "Chrome Page"),
            directRecord(browser: edge, url: "https://quiet.example/b", title: "Edge Page"),
            privacyRecord(browser: safari, url: "https://manual.example/c", domain: "manual.example", title: "Safari Page"),
        ]

        withAppLanguage(.zhHans) {
            let complete = BrowserPrivacyConfirmationText.deletionMessage(
                records: records,
                includesIncompletelyReadProfiles: false
            )
            XCTAssertTrue(complete.contains("将删除 2 次访问"), complete)
            XCTAssertTrue(complete.contains("另有 1 次访问只能在浏览器内处理"), complete)
            XCTAssertTrue(complete.contains(BrowserPrivacyRecoveryText.retentionNotice), complete)
            XCTAssertTrue(complete.contains("被删除的页面仍保存在删除前的备份里"), complete)
            XCTAssertFalse(complete.contains("只会删除已读取到的访问"))
            let sections = complete.components(separatedBy: "\n\n")
            let deleted = sections.first { $0.hasPrefix("将删除") } ?? ""
            XCTAssertTrue(deleted.contains("Chrome Page") && deleted.contains("Edge Page"))
            XCTAssertFalse(deleted.contains("Safari Page"), "pages handled in the browser are listed apart")

            let incomplete = BrowserPrivacyConfirmationText.deletionMessage(
                records: records,
                includesIncompletelyReadProfiles: true
            )
            XCTAssertTrue(incomplete.contains("只会删除已读取到的访问"), incomplete)
        }
        withAppLanguage(.english) {
            let message = BrowserPrivacyConfirmationText.deletionMessage(
                records: records,
                includesIncompletelyReadProfiles: true
            )
            XCTAssertTrue(message.contains("still contains the deleted pages"), message)
            XCTAssertTrue(message.contains("Only the visits that were read are deleted"), message)
        }
    }

    func testRunningBrowserConfirmationListsSkippedPagesSeparately() {
        let chrome = browser(id: "chrome", name: "Google Chrome", engine: .chromium)
        let edge = browser(id: "edge", name: "Microsoft Edge", engine: .chromium)
        let records = [
            directRecord(browser: chrome, url: "https://running.example/a", title: "Chrome Page"),
            directRecord(browser: edge, url: "https://quiet.example/b", title: "Edge Page"),
        ]

        withAppLanguage(.zhHans) {
            let message = BrowserPrivacyConfirmationText.preflightMessage(
                records: records,
                runningBrowserIDs: ["chrome"],
                includesIncompletelyReadProfiles: false
            )
            let sections = message.components(separatedBy: "\n\n")
            let skippable = sections.first { $0.contains("跳过") && $0.contains("Chrome Page") }
            XCTAssertNotNil(skippable, message)
            XCTAssertFalse(skippable?.contains("Edge Page") ?? true)
            let always = sections.first { $0.contains("两种选择都会删除") }
            XCTAssertTrue(always?.contains("Edge Page") == true, message)
            XCTAssertFalse(always?.contains("Chrome Page") ?? true, "a skipped browser's pages are not listed as deleted")
            XCTAssertTrue(message.contains(BrowserPrivacyRecoveryText.retentionNotice))
        }
    }

    func testReportOffersToRemoveTheBackupAndStatesItsRetention() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let results = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/BrowserPrivacyRecordResultsView.swift"
            ),
            encoding: .utf8
        )
        // The production report is independently hostable for native AX
        // regression; the retention/removal assertions remain unchanged.
        let reportStart = try XCTUnwrap(results.range(of: "struct BrowserPrivacyProcessingReportView"))
        let report = results[reportStart.lowerBound...]
        XCTAssertTrue(report.contains("BrowserPrivacyRecoveryText.retentionNotice"))
        XCTAssertTrue(report.contains("删除这份备份"))
        XCTAssertTrue(report.contains("BrowserPrivacyRecoveryText.removalWarning"))
        withAppLanguage(.zhHans) {
            let warning = BrowserPrivacyRecoveryText.removalWarning(
                createdAt: Date(timeIntervalSince1970: 1_750_000_000)
            )
            XCTAssertTrue(warning.contains("无法再撤销"), warning)
            XCTAssertTrue(warning.contains("不会移到废纸篓"), warning)
        }
    }

    func testDeletingABackupIsNamedTheSameInTheReportAndInRecentDeletions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func read(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let results = try read("Sources/StorageCleanerMac/Views/BrowserPrivacyRecordResultsView.swift")
        let recent = try read("Sources/StorageCleanerMac/Views/BrowserPrivacyRecentDeletionsView.swift")
        // One action, one name in each language. The retention notice tells
        // people to "delete" the backup in Recent Deletions.
        XCTAssertTrue(results.contains("L10n.text(\"删除这份备份\", \"Delete This Backup\")"))
        XCTAssertTrue(recent.contains("L10n.text(\"删除这份备份\", \"Delete This Backup\")"))
        XCTAssertTrue(recent.contains("L10n.text(\"删除备份\", \"Delete Backup\")"))
        for source in [results, recent] {
            XCTAssertFalse(source.contains("Remove This Backup"))
            XCTAssertFalse(source.contains("\"Remove Backup\""))
        }
    }

    func testCompleteAddressesAndPageListsCannotBeSelectedAsText() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func read(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let results = try read("Sources/StorageCleanerMac/Views/BrowserPrivacyRecordResultsView.swift")
        // ⌘C on selected text would put titles and complete addresses, query
        // included, on the clipboard without the concealed/transient markers.
        XCTAssertEqual(
            results.components(separatedBy: ".textSelection(.enabled)").count - 1,
            1,
            "only the list of sites on the manual page stays selectable"
        )
        let sites = try XCTUnwrap(results.range(of: "Text(BrowserPrivacyPageListText.siteSummary(group.domains))"))
        XCTAssertTrue(results[sites.upperBound...].prefix(240).contains(".textSelection(.enabled)"))
        for path in [
            "Sources/StorageCleanerMac/Views/BrowserPrivacyRecordPresentation.swift",
            "Sources/StorageCleanerMac/Views/BrowserPrivacyRecentDeletionsView.swift",
            "Sources/StorageCleanerMac/Views/BrowserPrivacyWorkspaceView.swift",
            "Sources/StorageCleanerMac/Views/BrowserPrivacyLightfieldResults.swift",
        ] {
            XCTAssertFalse(try read(path).contains(".textSelection(.enabled)"), path)
        }

        let privacy = try read("PRIVACY.md")
        XCTAssertTrue(privacy.contains("cannot be selected as text"))
        XCTAssertTrue(privacy.contains("不能作为文字选中"))
    }

    func testFragmentsOfOtherAddressesAreFoldedLikeQueries() {
        func address(_ url: String) -> BrowserPrivacyAddressPresentation {
            BrowserPrivacyAddressPresentation(url: url, domain: nil)
        }
        // A fragment can carry a token as well (for example an OAuth
        // implicit-flow access_token), so it is folded until the row is
        // expanded, exactly like a query.
        XCTAssertEqual(address("chrome://settings/privacy#section").collapsed, "chrome://settings/privacy#…")
        XCTAssertEqual(
            address("file:///Users/demo/report.html#access_token=abc").collapsed,
            "file:///Users/demo/report.html#…"
        )
        XCTAssertEqual(
            address("chrome-extension://abcdef/options.html?tab=2#frag").collapsed,
            "chrome-extension://abcdef/options.html?…"
        )
        let folded = address("chrome://settings/privacy#section")
        XCTAssertTrue(folded.hasFoldedDetail)
        XCTAssertEqual(folded.full, "chrome://settings/privacy#section", "the expanded row still shows it")
    }

    func testDocumentsDescribeTheBackupAndTheDifferencesFromChromium() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func read(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let days = BrowserPrivacyBackupRetention.days
        let matrix = try read("docs/CleanAnalysiser/Browser Privacy Parity Matrix.md")
        XCTAssertFalse(matrix.contains("不持久化"), "the backup keeps the deleted pages on disk for a while")
        XCTAssertTrue(matrix.contains("\(days) 天后自动删除"))
        let pageDeletion = try XCTUnwrap(
            matrix.components(separatedBy: "\n").first { $0.hasPrefix("| 39 |") }
        )
        for difference in ["书签", "重定向", "Favicons"] {
            XCTAssertTrue(pageDeletion.contains(difference), "row 39 must name the difference: \(difference)")
        }

        let state = try read("docs/PROJECT_STATE.md")
        XCTAssertFalse(state.contains("网址和标题不持久化"))
        XCTAssertTrue(state.contains("\(days) 天后自动删除"))

        let validation = try read("docs/1.9.9-browser-privacy-validation.md")
        let correction = try XCTUnwrap(validation.components(separatedBy: "## 1.").first)
        XCTAssertFalse(correction.contains("不持久化"))
        XCTAssertFalse(correction.contains("官方删除流程一致"))
        XCTAssertTrue(correction.contains("\(days) 天后自动删除"))

        let privacy = try read("PRIVACY.md")
        XCTAssertTrue(privacy.contains("## Browser privacy"))
        XCTAssertTrue(privacy.contains("deleted automatically after \(days) days"))
        XCTAssertTrue(privacy.contains("Recent Deletions"))
        XCTAssertTrue(privacy.contains("最近的删除"))
    }

    func testProfileFilterListsProfilesByBrowserAndDisplayName() {
        let chrome = browser(id: "chrome", name: "Chrome", engine: .chromium)
        let safari = browser(id: "safari", name: "Safari", engine: .safari)
        let records = [
            privacyRecord(browser: chrome, domain: "a.example", profileID: "chrome:Profile 2", profileName: "工作"),
            privacyRecord(browser: chrome, domain: "b.example", profileID: "chrome:Profile 2", profileName: "工作"),
            privacyRecord(browser: chrome, domain: "c.example", profileID: "chrome:Default", profileName: nil),
            privacyRecord(browser: safari, domain: "d.example", profileID: "safari:Safari", profileName: "Safari"),
        ]

        XCTAssertEqual(
            BrowserPrivacyRecordResultsView.profileOptions(from: records, browserID: nil),
            [
                BrowserPrivacyProfileOption(id: "chrome:Default", title: "Chrome · Default"),
                BrowserPrivacyProfileOption(id: "chrome:Profile 2", title: "Chrome · 工作"),
                BrowserPrivacyProfileOption(id: "safari:Safari", title: "Safari · Safari"),
            ],
            "the menu shows names; the raw identifier is only the stored filter value"
        )
        XCTAssertEqual(
            BrowserPrivacyRecordResultsView.profileOptions(from: records, browserID: "safari").map(\.id),
            ["safari:Safari"]
        )
    }

    func testBrowserPrivacyCopyMatchesManualOnlyProductionBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/BrowserPrivacyWorkspaceView.swift"
            ),
            encoding: .utf8
        )
        let results = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/BrowserPrivacyRecordResultsView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(workspace.contains("不读取 Cookie、密码、书签、自动填充或网页内容"))
        XCTAssertFalse(workspace.contains("真实域名仅在明确复制时进入剪贴板"))
        // D64 compresses the notice; memory-only retention and explicit clipboard writes remain visible.
        let workflowStart = try XCTUnwrap(results.range(of: "private var manualWorkflow:")).lowerBound
        let workflowEnd = try XCTUnwrap(results.range(of: "private func manualStep(", range: workflowStart..<results.endIndex)).lowerBound
        let workflow = String(results[workflowStart..<workflowEnd])
        XCTAssertTrue(workflow.contains("所选页面仅在本次内存会话保留；点击复制才写入剪贴板"))
        XCTAssertTrue(workflow.contains("Selected pages stay in this memory session; copying writes to the clipboard only on click"))
        XCTAssertTrue(workflow.contains("Button {\n                                copyDomains(for: group)\n                            } label:"))
        XCTAssertTrue(workflow.contains(".disabled(group.domains.isEmpty)"))
        XCTAssertTrue(results.contains("处理完成后正常退出浏览器"))
        XCTAssertTrue(results.contains("按浏览器复制所选域名"))
        XCTAssertTrue(results.contains("打开浏览器历史页并手动处理"))
        XCTAssertTrue(results.contains("已处理，重新扫描"))
        XCTAssertTrue(results.contains("chrome://history/"))
        XCTAssertTrue(results.contains("NSPasteboard.general"))
        XCTAssertTrue(results.contains("store.prepareManualGuidance()"))
        XCTAssertTrue(results.contains("store.processSelectedRecords()"))
    }

    func testBrowserPrivacyManualModeNeverClaimsOrStartsDatabaseDeletion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/BrowserPrivacyRecordResultsView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("store.prepareManualGuidance()"))
        XCTAssertTrue(source.contains("数据库结构不受支持的配置文件不会被修改"))
        XCTAssertTrue(source.contains("profiles with an unsupported database schema are not modified"))
        XCTAssertTrue(source.contains("创建恢复备份并清理"))
        XCTAssertTrue(source.contains("浏览器内手动处理说明"))
        XCTAssertFalse(source.contains("支持的配置文件只删除已选择的访问行"))

        // Only a verified deletion candidate can reach database processing. The manual branch is guidance only.
        let decisionStart = try XCTUnwrap(source.range(of: "if store.selectedRecordsContainVerifiedDeletionCandidate {")).lowerBound
        let decisionEnd = try XCTUnwrap(source.range(of: "Button(L10n.text(\"取消\"", range: decisionStart..<source.endIndex)).lowerBound
        let decision = String(source[decisionStart..<decisionEnd])
        let manualStart = try XCTUnwrap(decision.range(of: "} else {")).upperBound
        let manualBranch = String(decision[manualStart...])
        XCTAssertTrue(decision.contains("store.processSelectedRecords()"))
        XCTAssertTrue(manualBranch.contains("store.prepareManualGuidance()"))
        XCTAssertFalse(manualBranch.contains("store.processSelectedRecords()"))
        XCTAssertTrue(source.contains("任何按钮都不会打开列表中的网页或自动删除内容"))
        XCTAssertTrue(source.contains("No button opens a listed website or deletes anything automatically"))

        let workflowStart = try XCTUnwrap(source.range(of: "private var manualWorkflow")?.lowerBound)
        let workflow = source[workflowStart...]
        let review = try XCTUnwrap(workflow.range(of: "按浏览器复制所选域名")?.lowerBound)
        let process = try XCTUnwrap(workflow.range(of: "打开浏览器历史页并手动处理")?.lowerBound)
        let quit = try XCTUnwrap(workflow.range(of: "处理完成后正常退出浏览器")?.lowerBound)
        let rescan = try XCTUnwrap(workflow.range(of: "处理后重新扫描")?.lowerBound)
        XCTAssertLessThan(review, process)
        XCTAssertLessThan(process, quit)
        XCTAssertLessThan(quit, rescan)
    }

    func testResultRowsPrintOnlySanitizedPresentationText() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resultsSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/BrowserPrivacyRecordResultsView.swift"
            ),
            encoding: .utf8
        )
        let presentationSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/BrowserPrivacyRecordPresentation.swift"
            ),
            encoding: .utf8
        )
        let lightfieldSource = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/BrowserPrivacyLightfieldResults.swift"), encoding: .utf8)
        let source = resultsSource + presentationSource + lightfieldSource

        // Raw history fields are never handed to a view directly: the
        // presentation types strip control characters and bound the length.
        for forbidden in [
            "Text(record.title",
            "Text(record.url",
            "Text(record.domain",
            "Text(record.searchKeyword",
            "Text(item.title",
            "Text(item.address",
            "Text(item.domain",
            ".accessibilityLabel(record.title",
            ".accessibilityLabel(record.domain",
            ".help(record.url",
            ".help(item.address",
        ] {
            XCTAssertFalse(source.contains(forbidden), "raw history text reached a view: \(forbidden)")
        }
        // D70② shows the identity after explicit domain expansion.
        XCTAssertTrue(resultsSource.contains("BrowserPrivacyLightfieldResults("))
        XCTAssertTrue(lightfieldSource.contains("Text(pageTitle)"))
        XCTAssertTrue(presentationSource.contains("Text(presentation.title)"))
        XCTAssertTrue(presentationSource.contains("Text(presentation.address.collapsed)"))
        XCTAssertTrue(presentationSource.contains(".truncationMode(.middle)"))
        XCTAssertTrue(presentationSource.contains(".help(presentation.address.collapsed)"))
        XCTAssertTrue(presentationSource.contains("@Environment(\\.moduleTheme) private var theme"))
        XCTAssertTrue(presentationSource.contains(".foregroundStyle(theme.primaryText)"))
        XCTAssertTrue(presentationSource.contains(".foregroundStyle(theme.secondaryText)"))

        // D20 replaced the masked row and the masked manual page.
        for retired in ["maskedDomain", "未记录页面标题", "未知网站", "遮罩域名", "仅显示域名，路径和查询参数未展示"] {
            XCTAssertFalse(source.contains(retired), retired)
        }

        // Expansion, the per-visit list and the explicit copy action.
        XCTAssertTrue(lightfieldSource.contains("if expanded {"))
        XCTAssertTrue(lightfieldSource.contains("BrowserPrivacyVisitPresentation.visits(of: item)"))
        XCTAssertTrue(lightfieldSource.contains("visit(record)"))
        XCTAssertTrue(lightfieldSource.contains("复制网址"))
        XCTAssertTrue(resultsSource.contains("所选页面仅在本次内存会话保留；点击复制才写入剪贴板"))
        XCTAssertTrue(resultsSource.contains("Selected pages stay in this memory session; copying writes to the clipboard only on click"))
        XCTAssertEqual(
            (resultsSource + lightfieldSource).components(separatedBy: "BrowserPrivacyClipboard.write(").count - 1,
            2,
            "the clipboard is written in exactly two places: copy address and copy domains"
        )
        XCTAssertEqual(
            resultsSource.components(separatedBy: "setString(").count - 1,
            1,
            "only BrowserPrivacyClipboard writes, so every copy carries its privacy markers"
        )
        XCTAssertFalse(presentationSource.contains("NSPasteboard"))
    }

    func testBrowserPrivacySourcesKeepHistoryInMemoryOnly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = root.appendingPathComponent("Sources/StorageCleanerMac")
        var files = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourceRoot.appendingPathComponent("Features/BrowserPrivacy"),
                includingPropertiesForKeys: nil
            )?.allObjects as? [URL]
        ).filter { $0.pathExtension == "swift" }
        files += try FileManager.default.contentsOfDirectory(
            at: sourceRoot.appendingPathComponent("Views"),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("BrowserPrivacy") && $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 12)

        // Addresses and titles are shown, never stored, logged, exported or
        // sent anywhere. The only file written is the recovery backup with
        // its metadata, and the clipboard is written by the results view only.
        let forbiddenEverywhere = [
            "UserDefaults", "@AppStorage", "@SceneStorage", "NSUbiquitousKeyValueStore",
            "Logger(", "os_log", "NSLog(",
            "URLSession", "URLRequest", "NSSharingService", "NSSavePanel",
            "DiagnosticsExport", "CleanReportStore",
        ]
        // Free functions, so `Fingerprint(` and the like do not match.
        let consoleOutput = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_.])(print|debugPrint|dump)\("#
        )
        let fileWriters = [".write(to:", "FileHandle(forWritingTo", "createFile(atPath"]
        for file in files {
            // Comments describe the rule itself; only code is checked.
            let source = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for token in forbiddenEverywhere {
                // D91 permits only the site keep-list preference. History,
                // cookie values and scan groups remain nonpersistent.
                if token == "UserDefaults", file.lastPathComponent == "BrowserPrivacyDataStore.swift" {
                    XCTAssertTrue(source.contains("browser-privacy.kept-sites.v1"))
                    XCTAssertEqual(source.components(separatedBy: "defaults.set(").count - 1, 2)
                    XCTAssertEqual(source.components(separatedBy: "defaults.set(keepingSites.sorted(), forKey: Self.preferenceKey)").count - 1, 2)
                } else {
                    XCTAssertFalse(source.contains(token), "\(file.lastPathComponent): \(token)")
                }
            }
            XCTAssertEqual(
                consoleOutput.numberOfMatches(
                    in: source,
                    range: NSRange(source.startIndex..., in: source)
                ),
                0,
                "\(file.lastPathComponent) writes to the console"
            )
            if file.lastPathComponent != "BrowserPrivacyRecoveryBackupService.swift" {
                for token in fileWriters {
                    XCTAssertFalse(source.contains(token), "\(file.lastPathComponent): \(token)")
                }
            }
            if file.lastPathComponent != "BrowserPrivacyRecordResultsView.swift" {
                XCTAssertFalse(source.contains("NSPasteboard"), file.lastPathComponent)
            }
        }
    }

    func testWebsiteGroupingPreservesEveryRecordAndProfile() {
        let chrome = browser(id: "chrome", name: "Chrome", engine: .chromium)
        let safari = browser(id: "safari", name: "Safari", engine: .safari)
        let records = [
            privacyRecord(browser: chrome, domain: "example.com"),
            privacyRecord(browser: safari, domain: "example.com"),
            privacyRecord(browser: chrome, domain: "second.example"),
            privacyRecord(browser: chrome, domain: nil),
        ]
        let items = BrowserPrivacyDisplayItem.aggregate(records)
        let groups = BrowserPrivacyRecordResultsView.websiteGroups(items)
        XCTAssertEqual(groups.map(\.domain), ["", "example.com", "second.example"])
        XCTAssertEqual(groups[1].items.count, 2)
        XCTAssertEqual(Set(groups.flatMap(\.items).flatMap(\.records).map(\.id)), Set(records.map(\.id)))
    }

    private func browser(
        id: String,
        name: String,
        engine: BrowserPrivacyEngine
    ) -> BrowserPrivacyBrowser {
        BrowserPrivacyBrowser(
            id: id,
            displayName: name,
            engine: engine,
            bundleIdentifier: "test.\(id)",
            version: nil
        )
    }

    private func privacyRecord(
        browser: BrowserPrivacyBrowser,
        url: String? = nil,
        domain: String?,
        title: String? = nil,
        keyword: String? = nil,
        // Ordinary disclosed-page format fixtures. Sensitive disclosure has
        // separate category-explicit regression coverage.
        category: BrowserPrivacyCategory = .shopping,
        visitedAt: Date = Date(timeIntervalSince1970: 1_750_000_000),
        profileID: String? = nil,
        profileName: String? = nil
    ) -> BrowserPrivacyRecord {
        BrowserPrivacyRecord(
            id: UUID(),
            browser: browser,
            profileID: profileID ?? "\(browser.id):Default",
            profileDisplayName: profileName,
            source: .history,
            url: url ?? domain.map { "https://\($0)/" },
            domain: domain,
            title: title,
            searchKeyword: keyword,
            visitedAt: visitedAt,
            visitCount: 1,
            category: category,
            selectionConfidence: .medium,
            sizeBytes: nil
        )
    }

    /// A record that can be deleted directly (it carries a locator).
    private func directRecord(
        browser: BrowserPrivacyBrowser,
        url: String,
        title: String?
    ) -> BrowserPrivacyRecord {
        let root = URL(fileURLWithPath: "/tmp/browser-privacy-presentation-fixture", isDirectory: true)
        let domain = URLComponents(string: url)?.host
        return BrowserPrivacyRecord(
            id: UUID(),
            browser: browser,
            profileID: "\(browser.id):Default",
            source: .history,
            url: url,
            domain: domain,
            title: title,
            searchKeyword: nil,
            visitedAt: Date(timeIntervalSince1970: 1_750_000_000),
            visitCount: 1,
            category: .other,
            selectionConfidence: .medium,
            sizeBytes: nil,
            locator: BrowserPrivacyRecordLocator(
                providerID: browser.id,
                profileID: "\(browser.id):Default",
                engine: browser.engine,
                visitRowID: Int64.random(in: 1 ... 1_000_000),
                parentRowID: 1,
                visitTimestampIdentity: .integer(1),
                rawURL: url,
                databaseURL: root.appendingPathComponent("History"),
                trustedParentURL: root,
                identityChain: [.init(device: 1, inode: 1, kind: 0o100000)]
            )
        )
    }

    /// Runs `body` with the app language forced, then restores the setting.
    private func withAppLanguage(_ language: AppLanguage, _ body: () -> Void) {
        let defaults = TestVolatilePreferences()
        defaults.set(language.rawValue, forKey: L10n.languageDefaultsKey)
        defer { defaults.restore() }
        body()
    }

    func testBrowserFilterOptionsDeduplicateRecordsFromTheSameBrowser() {
        let chrome = browser(id: "chrome", name: "Chrome", engine: .chromium)
        let safari = browser(id: "safari", name: "Safari", engine: .safari)

        let browsers = BrowserPrivacyRecordResultsView.uniqueBrowsers(from: [
            privacyRecord(browser: chrome, domain: "first.example"),
            privacyRecord(browser: chrome, domain: "second.example"),
            privacyRecord(browser: safari, domain: "third.example"),
        ])

        XCTAssertEqual(browsers.map(\.id), ["chrome", "safari"])
    }

    func testBrowserCoverageSeparatesPartialReadsAndPermissionGuidance() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/BrowserPrivacyRecordResultsView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private var fullyReadBrowserCount"))
        XCTAssertTrue(source.contains("private var partialBrowserCount"))
        XCTAssertTrue(source.contains("requiresFullDiskAccess"))
        XCTAssertTrue(source.contains("PrivacySystemSettingsOpener.openFullDiskAccess()"))
        XCTAssertTrue(source.contains("Check System Settings access"))
        XCTAssertFalse(source.contains(
            "coverage.availability == .available || coverage.availability == .partial"
        ))

        // Coverage lives in a vertical popover reached from the result toolbar;
        // the old horizontally scrolling card strip stays deleted so narrow
        // windows can never truncate per-browser coverage again.
        XCTAssertTrue(source.contains("private var coverageDetails"))
        XCTAssertTrue(source.contains("BrowserPrivacyCoverageRow"))
        XCTAssertFalse(source.contains("BrowserPrivacyCoverageCard"))
        XCTAssertFalse(source.contains("ScrollView(.horizontal)"))
    }

    func testBrowserPrivacyLegacySummaryMetricsStayDeleted() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/BrowserPrivacyRecordResultsView.swift"
            ),
            encoding: .utf8
        )

        // The unmounted summary/metric surface was removed in 1.9.11. It must
        // not come back as dead code, and the historical "other = total minus
        // adult" miscount must never be reintroduced with it.
        XCTAssertFalse(source.contains("store.records.count - categoryCount(.adult)"))
        XCTAssertFalse(source.contains("BrowserPrivacySummaryMetric"))
        XCTAssertFalse(source.contains("private var summary: some View"))
        XCTAssertFalse(source.contains("private var summaryMetrics"))
    }

    func testBrowserPrivacyRefreshKeepsCachedResultsAndEmptyStatesStayTruthful() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspaceSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/BrowserPrivacyWorkspaceView.swift"
            ),
            encoding: .utf8
        )
        let resultsSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/BrowserPrivacyRecordResultsView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(workspaceSource.contains("!browserPrivacyStore.hasCachedResults"))
        XCTAssertTrue(workspaceSource.contains("onCancel: browserPrivacyStore.cancel"))
        // D70② uses the shared running page's cancel action.
        XCTAssertTrue(workspaceSource.contains("BrowserPrivacyRunningPage(onCancel: browserPrivacyStore.cancel)"))
        XCTAssertTrue(resultsSource.contains("正在刷新，继续显示上次结果"))
        XCTAssertTrue(resultsSource.contains("刷新失败，仍显示上次结果"))
        XCTAssertTrue(resultsSource.contains("部分扫描不能证明没有历史记录"))
        // Preserve processing/scan locks, and lock stale selection while the
        // asynchronously filtered projection is pending.
        XCTAssertTrue(resultsSource.contains("disabled: store.isFiltering || store.isProcessing || store.state == .scanning"))
        let hierarchySource = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/BrowserPrivacyLightfieldResults.swift"), encoding: .utf8)
        XCTAssertTrue(hierarchySource.contains(".disabled(disabled)"))
        XCTAssertTrue(hierarchySource.contains(".disabled(disabled || ids.isEmpty)"))
        XCTAssertFalse(resultsSource.contains("手动处理步骤已生成"))
    }

    func testBrowserPrivacyZeroRecordEmptyStatePrefersCoverageTruthOverFilters() {
        XCTAssertEqual(
            BrowserPrivacyRecordsEmptyStateKind.resolve(
                scanState: .permissionDenied,
                hasFilters: true,
                hasRecords: false,
                requiresFullDiskAccess: true
            ),
            .permissionRequired
        )
        XCTAssertEqual(
            BrowserPrivacyRecordsEmptyStateKind.resolve(
                scanState: .partial,
                hasFilters: true,
                hasRecords: false,
                requiresFullDiskAccess: false
            ),
            .partial
        )
        XCTAssertEqual(
            BrowserPrivacyRecordsEmptyStateKind.resolve(
                scanState: .completed,
                hasFilters: true,
                hasRecords: false,
                requiresFullDiskAccess: false
            ),
            .completed
        )
        XCTAssertEqual(
            BrowserPrivacyRecordsEmptyStateKind.resolve(
                scanState: .completed,
                hasFilters: true,
                hasRecords: true,
                requiresFullDiskAccess: false
            ),
            .filtered
        )
        XCTAssertEqual(
            BrowserPrivacyRecordsEmptyStateKind.resolve(
                scanState: .partial,
                hasFilters: true,
                hasRecords: true,
                requiresFullDiskAccess: false
            ),
            .partial
        )
        XCTAssertEqual(
            BrowserPrivacyRecordsEmptyStateKind.resolve(
                scanState: .completed,
                hasFilters: true,
                hasRecords: true,
                requiresFullDiskAccess: true
            ),
            .permissionRequired
        )
    }

    // D70② supersedes the V1 compact header with the shared lightfield shell.
    func testBrowserPrivacyResultsUseCompactHeaderSingleSearchAndLazyRows() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/BrowserPrivacyRecordResultsView.swift"), encoding: .utf8)
        let hierarchy = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/BrowserPrivacyLightfieldResults.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("FeatureLightfieldPage(module: .privacy"))
        XCTAssertTrue(source.contains("BrowserPrivacyLightfieldResults("))
        XCTAssertTrue(source.contains(".task(id: searchQuery)"))
        let filtering = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Features/BrowserPrivacy/Store/BrowserPrivacyStore.swift"), encoding: .utf8)
        XCTAssertTrue(filtering.contains("milliseconds(200)"))
        XCTAssertTrue(filtering.contains("Task.detached"))
        XCTAssertEqual(hierarchy.components(separatedBy: "TextField(").count - 1, 1)
        XCTAssertTrue(hierarchy.contains("LazyVStack"))
        XCTAssertTrue(hierarchy.contains("LightfieldSummary("))
        XCTAssertTrue(hierarchy.contains("store.setSelection("))
        XCTAssertFalse(source.contains("privacySidecar"))
        XCTAssertFalse(source.contains("compactSelectionHeader"))
    }

    func testBrowserPrivacyPrimarySurfacesOmitRedundantExplanatoryCopy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/BrowserPrivacyWorkspaceView.swift"
            ),
            encoding: .utf8
        )
        let results = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/BrowserPrivacyRecordResultsView.swift"
            ),
            encoding: .utf8
        )
        let landing = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/FileToolLandingPage.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(results.contains("store.filters.query = searchQuery"))
        // D70②: time is now the three approved options in the B2 option rows.
        XCTAssertTrue(workspace.contains("BrowserPrivacyLightfieldPresentation.datePresets"))
        XCTAssertTrue(workspace.contains("LightfieldOptionRow("))
        XCTAssertTrue(workspace.contains("只读扫描 · 删除前确认"))
        XCTAssertFalse(workspace.contains("检查隐私足迹"))
        XCTAssertFalse(workspace.contains("扫描只读读取已发现配置文件"))
        XCTAssertFalse(results.contains("历史记录属于需确认数据；仅精确匹配受支持 Schema"))
        XCTAssertFalse(results.contains("标题、完整网址、查询参数和真实域名仍保持隐藏"))
        XCTAssertTrue(landing.contains("if !actionDetail.isEmpty"))

        XCTAssertTrue(results.contains("浏览器仍在运行"))
        XCTAssertTrue(results.contains("直接清理前浏览器必须正常退出"))
        XCTAssertTrue(results.contains("PrivacySystemSettingsOpener.openFullDiskAccess()"))
    }

    func testBrowserPrivacyCleanAnalysiserParityMatrixDocumentsSafetyBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let matrix = try String(
            contentsOf: root.appendingPathComponent(
                "docs/CleanAnalysiser/Browser Privacy Parity Matrix.md"
            ),
            encoding: .utf8
        )

        XCTAssertGreaterThanOrEqual(
            matrix.components(separatedBy: "\n| ").count - 1,
            30
        )
        XCTAssertTrue(matrix.contains("不均摊数据库大小"))
        XCTAssertTrue(matrix.contains("不得复制目录扫描或建立第二条删除链"))

        // The write boundary the matrix states is the one the registry has.
        let writableProviders = BrowserPrivacyProviderRegistry.defaultProviders
            .filter { $0.historyWriteAdapter != nil }
        XCTAssertTrue(writableProviders.allSatisfy { $0.descriptor.engine == .chromium })
        XCTAssertTrue(matrix.contains("Chromium 系 \(writableProviders.count) 个注册 Provider"))
        XCTAssertTrue(matrix.contains("Schema 版本 70／兼容版本 16"))
        XCTAssertTrue(matrix.contains("没有写入 Adapter，只生成浏览器内处理步骤"))
        XCTAssertTrue(matrix.contains("每条记录都能看出是哪个网站的哪个页面（D20）"))
        XCTAssertTrue(matrix.contains("不把网址和标题写入设置、日志或诊断导出，也不上传"))
    }

    func testSidebarAndDocumentsDescribeTheCurrentBrowserPrivacyBehaviour() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebar = try String(
            contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/SidebarView.swift"),
            encoding: .utf8
        )
        // The scan reads all history; it never filtered to "possibly sensitive" sites.
        XCTAssertFalse(sidebar.contains("只扫描可能敏感的网站记录"))
        XCTAssertFalse(sidebar.contains("Scan only possibly sensitive-site history"))
        XCTAssertTrue(sidebar.contains("读取本机全部浏览记录，逐页列出网站和页面；删除前确认"))

        let matrix = try String(
            contentsOf: root.appendingPathComponent(
                "docs/CleanAnalysiser/Browser Privacy Parity Matrix.md"
            ),
            encoding: .utf8
        )
        // Chromium-family providers have exposed a production write adapter since 1.9.10.
        XCTAssertFalse(matrix.contains("生产 Provider 不授予历史数据库写入 Adapter"))
        XCTAssertFalse(matrix.contains("注册 Provider 始终返回 nil"))
        XCTAssertFalse(matrix.contains("标题、完整 URL、查询和真实域名隐藏"))

        let state = try String(
            contentsOf: root.appendingPathComponent("docs/PROJECT_STATE.md"),
            encoding: .utf8
        )
        XCTAssertFalse(state.contains("完整 URL 路径、查询参数、解析出的搜索词及密码、Cookie、书签、自动填充和网页正文仍不展示"))

        let validation = try String(
            contentsOf: root.appendingPathComponent("docs/1.9.9-browser-privacy-validation.md"),
            encoding: .utf8
        )
        XCTAssertTrue(validation.contains("2026-10-04 更正"))
        XCTAssertFalse(validation.contains("> 当前状态："), "the 1.9.9 status line must not read as current")
    }

}
