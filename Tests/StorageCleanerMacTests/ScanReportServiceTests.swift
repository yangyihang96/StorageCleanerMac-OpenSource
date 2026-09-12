import XCTest
@testable import StorageCleanerMac

final class ScanReportServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey)
        super.tearDown()
    }

    func testMarkdownReportIncludesSummaryRecommendationsAndTopItems() {
        let result = makeResult()

        let markdown = ScanReportService.markdown(for: result, generatedAt: Date(timeIntervalSince1970: 1_786_000_000))

        XCTAssertTrue(markdown.contains("# 存储清理助手扫描报告"))
        XCTAssertTrue(markdown.contains("## 磁盘概览"))
        XCTAssertTrue(markdown.contains("## 存储评分 v2 与可信度"))
        XCTAssertTrue(markdown.contains("扫描模式"))
        XCTAssertTrue(markdown.contains("标准"))
        XCTAssertTrue(markdown.contains("存储评分 v2"))
        XCTAssertTrue(markdown.contains("总扣分"))
        XCTAssertTrue(markdown.contains("状态扣分"))
        XCTAssertFalse(markdown.contains("风险扣分"))
        XCTAssertTrue(markdown.contains("可信度扣分"))
        XCTAssertTrue(markdown.contains("结果时效"))
        XCTAssertTrue(markdown.contains("2 小时内"))
        XCTAssertTrue(markdown.contains("权限覆盖率"))
        XCTAssertTrue(markdown.contains("85%"))
        XCTAssertTrue(markdown.contains("扫描完成状态"))
        XCTAssertTrue(markdown.contains("完整完成"))
        XCTAssertTrue(markdown.contains("评分项"))
        XCTAssertTrue(markdown.contains("权限缺口"))
        XCTAssertTrue(markdown.contains("## 建议"))
        XCTAssertTrue(markdown.contains("Example Cache"))
        XCTAssertTrue(markdown.contains("优先处理可安全清理项目"))
        XCTAssertTrue(markdown.contains("~/Library/Mail"))
    }

    func testMarkdownReportSeparatesMovedToTrashFromFreedSpace() {
        var result = makeResult()
        result.items[0].status = .movedToTrash

        let markdown = ScanReportService.markdown(for: result, generatedAt: Date(timeIntervalSince1970: 1_786_000_000))

        XCTAssertTrue(markdown.contains("仅表示已移到废纸篓，清空前仍可恢复"))
        XCTAssertTrue(markdown.contains("空间释放以清空废纸篓为准"))
        XCTAssertFalse(markdown.contains("已由本软件执行的可安全清理项目"))
    }

    func testMarkdownReportWarnsWhenScanIsStale() {
        let result = ScanResult(
            generatedAt: Date(timeIntervalSince1970: 1_785_900_000),
            scanSeconds: 0.4,
            system: makeResult().system,
            groups: [],
            items: [
                makeItem(title: "Example Cache", tier: .green, sizeBytes: 120_000)
            ],
            deniedPaths: []
        )

        let markdown = ScanReportService.markdown(for: result, generatedAt: Date(timeIntervalSince1970: 1_786_000_000))

        XCTAssertTrue(markdown.contains("超过 24 小时"))
        XCTAssertTrue(markdown.contains("请先重新扫描"))
    }

    func testExportWritesMarkdownReportToSelectedDirectory() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try ScanReportService.export(
            result: makeResult(),
            directory: directory,
            generatedAt: Date(timeIntervalSince1970: 1_786_000_000)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("存储清理助手-扫描报告-"))

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("Example Cache"))
        XCTAssertTrue(content.contains("存储评分 v2 与可信度"))
        XCTAssertTrue(content.contains("无法读取的路径"))
    }

    func testMarkdownReportExplainsTimeLimitedScanAsIncomplete() {
        let base = makeResult()
        let result = ScanResult(
            generatedAt: base.generatedAt,
            scanSeconds: ScanMode.standard.maxScanSeconds,
            scanMode: .standard,
            scanWasLimited: true,
            system: base.system,
            groups: base.groups,
            items: [],
            deniedPaths: []
        )

        let markdown = ScanReportService.markdown(
            for: result,
            generatedAt: base.generatedAt.addingTimeInterval(30 * 60)
        )

        XCTAssertTrue(markdown.contains("达到扫描预算或安全数量上限，部分位置未完成"))
        XCTAssertTrue(markdown.contains("扫描未完成"))
        XCTAssertTrue(markdown.contains("权限覆盖率 | 100%"))
        XCTAssertTrue(markdown.contains("扫描完成状态 | 部分完成"))
        XCTAssertFalse(markdown.contains("| 扫描完整度 | 100%"))
        XCTAssertTrue(markdown.contains("95/100"))
    }

    func testMarkdownReportListsCodexAndDevelopmentArtifactsOutsideTopFive() {
        var result = makeResult()
        result.items.append(
            makeItem(
                title: "Codex Runtime Screenshots",
                tier: .yellow,
                sizeBytes: 40_000,
                sourceID: "codex_runtime_records"
            )
        )

        let markdown = ScanReportService.markdown(for: result, generatedAt: result.generatedAt)

        XCTAssertTrue(markdown.contains("## 开发工具与产物"))
        XCTAssertTrue(markdown.contains("Codex Runtime Screenshots"))
        XCTAssertTrue(markdown.contains("仅定位，人工复核"))
    }

    func testMarkdownReportLabelsMovedDeveloperArtifactAsMovedToTrash() {
        var result = makeResult()
        let moved = makeItem(
            title: "Codex Runtime Temporary Area",
            tier: .green,
            sizeBytes: 40_000,
            sourceID: "codex_intermediates"
        )
        result.items.append(moved)
        result.markMovedToTrash(itemID: moved.id)

        let markdown = ScanReportService.markdown(for: result, generatedAt: result.generatedAt)

        XCTAssertTrue(markdown.contains("Codex Runtime Temporary Area"))
        XCTAssertTrue(markdown.contains("已移到废纸篓"))
    }

    private func makeResult() -> ScanResult {
        ScanResult(
            generatedAt: Date(timeIntervalSince1970: 1_785_999_000),
            scanSeconds: 0.4,
            system: SystemSnapshot(
                osName: "macOS",
                build: "test",
                arch: "arm64",
                user: "tester",
                home: PathSafety.homePath,
                filesystem: "APFS",
                purgeable: "1 GB",
                diskName: "Macintosh HD",
                diskTotalBytes: 1_000_000,
                diskUsedBytes: 650_000,
                diskFreeBytes: 350_000
            ),
            groups: [],
            items: [
                makeItem(title: "Example Cache", tier: .green, sizeBytes: 120_000),
                makeItem(title: "Example Download", tier: .yellow, sizeBytes: 80_000),
                makeItem(title: "Example App", tier: .red, sizeBytes: 60_000)
            ],
            deniedPaths: ["~/Library/Mail"]
        )
    }

    private func makeItem(
        title: String,
        tier: StorageTier,
        sizeBytes: Int64,
        sourceID: String = ""
    ) -> StorageItem {
        let path = "~/Library/Caches/\(title)"
        return StorageItem(
            id: PathSafety.normalizedPath(path),
            title: title,
            path: path,
            sourceID: sourceID,
            groupTitle: "Test",
            sizeBytes: sizeBytes,
            tier: tier,
            kind: "Test",
            reason: "Test reason",
            recommendation: "Test recommendation",
            risk: "Test risk",
            requiresClose: "None",
            trashPaths: tier == .green ? [path] : [],
            openPath: path,
            status: .available
        )
    }
}
