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

    func testActiveRecordPresentationShowsTitleAndDomainWithoutURLDetails() {
        let record = privacyRecord(
            browser: browser(id: "chrome", name: "Chrome", engine: .chromium),
            url: "https://private-bank.example/account?token=secret-token&q=hidden+phrase",
            domain: "private-bank.example",
            title: "Private Bank Account Overview",
            keyword: "hidden phrase"
        )

        let presentation = BrowserPrivacySafeRecordPresentation(record: record)
        let rendered = [
            presentation.title,
            presentation.location,
            presentation.domain,
            presentation.keyword,
            presentation.accessibilityLabel,
        ].joined(separator: " ")

        XCTAssertEqual(presentation.title, "Private Bank Account Overview")
        XCTAssertEqual(presentation.domain, "private-bank.example")
        XCTAssertTrue(presentation.location.contains("private-bank.example"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("Chrome"))

        for secret in ["secret-token", "hidden phrase", "/account"] {
            XCTAssertFalse(rendered.localizedCaseInsensitiveContains(secret))
        }
        XCTAssertTrue(presentation.keyword.localizedCaseInsensitiveContains("未展示")
            || presentation.keyword.localizedCaseInsensitiveContains("not shown"))
    }

    func testManualGuidanceGroupsDomainsByBrowserAndOnlyClipboardPayloadIsUnmasked() {
        let chrome = browser(id: "chrome", name: "Chrome", engine: .chromium)
        let safari = browser(id: "safari", name: "Safari", engine: .safari)
        let groups = BrowserPrivacyManualWorkflow.groups(from: [
            privacyRecord(browser: chrome, domain: "bank.example"),
            privacyRecord(browser: chrome, domain: "search.example"),
            privacyRecord(browser: safari, domain: "social.example"),
        ])

        XCTAssertEqual(groups.map(\.browser.id), ["chrome", "safari"])
        XCTAssertEqual(groups[0].domains, ["bank.example", "search.example"])
        XCTAssertEqual(groups[1].domains, ["social.example"])
        XCTAssertFalse(
            groups[0].domains
                .map(BrowserPrivacySafeRecordPresentation.maskedDomain)
                .joined(separator: " ")
                .contains("bank.example")
        )
        XCTAssertEqual(
            BrowserPrivacyManualWorkflow.clipboardText(domains: groups[0].domains),
            "bank.example\nsearch.example"
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
        XCTAssertTrue(results.contains("只有点击对应浏览器的复制按钮后才写入剪贴板"))
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
        XCTAssertTrue(source.contains("不支持的 Schema 不会写入"))
        XCTAssertTrue(source.contains("unsupported schemas are not written"))
        XCTAssertTrue(source.contains("创建恢复备份并清理"))
        XCTAssertTrue(source.contains("浏览器内手动处理说明"))
        XCTAssertFalse(source.contains("支持的配置文件只删除已选择的访问行"))

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

    func testActiveResultSourceUsesSafeTitleAndDomainPresentation() throws {
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
        let source = resultsSource + presentationSource

        for forbidden in [
            "Text(record.title",
            "Text(record.url",
            "Text(record.domain",
            "Text(record.searchKeyword",
            ".accessibilityLabel(record.title",
            ".accessibilityLabel(record.domain",
            "查看所选域名（",
        ] {
            XCTAssertFalse(source.contains(forbidden), "active result source leaked: \(forbidden)")
        }
        XCTAssertTrue(resultsSource.contains("BrowserPrivacyRecordIdentityView(item: item)"))
        XCTAssertTrue(presentationSource.contains("Text(presentation?.title"))
        XCTAssertTrue(presentationSource.contains("presentation?.domain"))
        XCTAssertTrue(presentationSource.contains("@Environment(\\.moduleTheme) private var theme"))
        XCTAssertTrue(presentationSource.contains(".foregroundStyle(theme.primaryText)"))
        XCTAssertTrue(presentationSource.contains(".foregroundStyle(theme.secondaryText)"))
        XCTAssertTrue(resultsSource.contains("只有点击对应浏览器的复制按钮后才写入剪贴板"))
        XCTAssertTrue(resultsSource.contains("NSPasteboard.general"))
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
        keyword: String? = nil
    ) -> BrowserPrivacyRecord {
        BrowserPrivacyRecord(
            id: UUID(),
            browser: browser,
            profileID: "\(browser.id):Default",
            source: .history,
            url: url ?? domain.map { "https://\($0)/" },
            domain: domain,
            title: title,
            searchKeyword: keyword,
            visitedAt: Date(timeIntervalSince1970: 1_750_000_000),
            visitCount: 1,
            category: .finance,
            selectionConfidence: .medium,
            sizeBytes: nil
        )
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
        XCTAssertTrue(workspaceSource.contains("browserPrivacyStore.cancel()"))
        XCTAssertTrue(workspaceSource.contains("取消扫描"))
        XCTAssertTrue(resultsSource.contains("正在刷新，继续显示上次结果"))
        XCTAssertTrue(resultsSource.contains("刷新失败，仍显示上次结果"))
        XCTAssertTrue(resultsSource.contains("部分扫描不能证明没有历史记录"))
        XCTAssertTrue(resultsSource.contains("isDisabled: store.state == .scanning || store.isProcessing"))
        XCTAssertTrue(resultsSource.contains(".disabled(isDisabled || !item.selectionEligibility.canSelect)"))
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

    func testBrowserPrivacyResultsUseCompactHeaderSingleSearchAndLazyRows() throws {
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

        let bodyStart = try XCTUnwrap(source.range(of: "    var body: some View {")?.lowerBound)
        let headerStart = try XCTUnwrap(
            source.range(of: "    private var compactSelectionHeader")?.lowerBound
        )
        let activeBody = source[bodyStart ..< headerStart]
        XCTAssertTrue(activeBody.contains("compactSelectionHeader"))
        XCTAssertTrue(activeBody.contains("resultSurface"))
        XCTAssertFalse(source.contains("FileToolLandingArtwork"))
        XCTAssertFalse(source.contains("privacySidecar"))
        XCTAssertLessThan(
            try XCTUnwrap(activeBody.range(of: "resultSurface")?.lowerBound),
            try XCTUnwrap(activeBody.range(of: "compactSelectionHeader")?.lowerBound)
        )
        XCTAssertFalse(activeBody.contains("summaryMetrics"))
        XCTAssertFalse(activeBody.contains("coverage"))

        let searchStart = try XCTUnwrap(
            source.range(of: "    private var compactSearchField")?.lowerBound
        )
        let sortStart = try XCTUnwrap(source.range(of: "    private var sortMenu")?.lowerBound)
        let search = source[searchStart ..< sortStart]
        XCTAssertEqual(search.components(separatedBy: "TextField(").count - 1, 1)
        XCTAssertTrue(source.contains(".task(id: searchQuery)"))
        XCTAssertTrue(source.contains("milliseconds(200)"))
        XCTAssertTrue(source.contains("LazyVStack(spacing: 0)"))
        XCTAssertTrue(source.contains("filteredSelectionState"))
        XCTAssertTrue(source.contains("\"运行中\", \"Running\""))
        XCTAssertTrue(source.contains("大小不可用"))
        XCTAssertFalse(source.contains("\"已选择 (store.selectedRecordIDs.count)"))
        XCTAssertFalse(source.contains("\"(store.selectedRecordIDs.count) selected"))
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

        XCTAssertTrue(workspace.contains("$store.filters.query"))
        XCTAssertTrue(workspace.contains("BrowserPrivacyDateControls(store: browserPrivacyStore, showsSearch: true)"))
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
        XCTAssertTrue(matrix.contains("生产 Provider 不授予历史数据库写入 Adapter"))
        XCTAssertTrue(matrix.contains("不均摊数据库大小"))
        XCTAssertTrue(matrix.contains("不得复制目录扫描或建立第二条删除链"))
    }

}
