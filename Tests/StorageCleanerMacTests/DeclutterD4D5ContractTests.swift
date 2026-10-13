import Foundation
import XCTest
@testable import StorageCleanerMac

/// D64: result surfaces keep identity, decisions and safety; static decoration stays removed.
/// These guards inspect source and presentation values, never write preferences or invoke operations.
final class DeclutterD4D5ContractTests: XCTestCase {
    private let views = "Sources/StorageCleanerMac/Views/"
    private let startup = "Sources/StorageCleanerMac/Features/StartupItems/Views/"
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ path: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
    }
    private func section(_ text: String, from start: String, to end: String) throws -> String {
        let lower = try XCTUnwrap(text.range(of: start)).lowerBound
        let upper = try XCTUnwrap(text.range(of: end, range: lower..<text.endIndex)).lowerBound
        return String(text[lower..<upper])
    }

    /// Apply only to a text-only presentation region, never to interactive controls or risk status.
    /// Covers Image, Label(..., systemImage:), and Label { ... } icon: { ... }.
    private func assertTextOnly(
        _ text: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        for pattern in [
            #"(?<![A-Za-z0-9_])(?:Image|Label)\s*(?:\(|\{)"#,
            #"\bsystemImage\s*:"#,
            #"\bicon\s*:\s*\{"#,
        ] {
            XCTAssertNil(text.range(of: pattern, options: .regularExpression),
                         "Text-only presentation regained an icon: \(pattern)", file: file, line: line)
        }
    }

    private func assertNoSymbols(
        _ symbols: [String], in text: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        for symbol in symbols {
            let pattern = #"\b(?:systemName|systemImage)\s*:\s*""#
                + NSRegularExpression.escapedPattern(for: symbol) + "\""
            XCTAssertNil(text.range(of: pattern, options: .regularExpression),
                         "Decorative symbol returned through Image or either Label form: \(symbol)",
                         file: file, line: line)
        }
    }

    func testHealthResultsRemoveDecorationButRetainEvidenceAndWarnings() throws {
        let hero = try source(views + "ComputerHealth/HealthScoreHero.swift")
        let factors = try source(views + "ComputerHealth/HealthFactorGrid.swift")
        let actions = try source(views + "ComputerHealth/HealthActionList.swift")
        let trend = try source(views + "ComputerHealth/HealthTrendChart.swift")
        XCTAssertFalse(hero.contains("磁盘、容量、稳定性、电池参与计分"))
        XCTAssertFalse(hero.contains("Disk, capacity, stability, and battery affect the score"))
        assertTextOnly(try section(hero, from: "private var scoreSummary:", to: "private var scoreAccessibilityValue:"))
        XCTAssertTrue(hero.contains("Text(HealthDashboardText.assessmentTitle)"))
        XCTAssertTrue(hero.contains(".accessibilityLabel(HealthDashboardText.assessmentTitle)"))
        // D67 permits the real status symbol and the row-end disclosure
        // control. The remaining evidence is text, without a decorative tile.
        XCTAssertTrue(factors.contains("FeatureLightfieldStatusDisclosure("))
        let template = try source(views + "DesignSystem/FeatureLightfield.swift")
        XCTAssertTrue(template.contains("Image(systemName: expanded ? \"chevron.down\" : \"chevron.right\")"))
        XCTAssertTrue(template.contains("if let expanded { FeatureLightfieldDisclosureChevron(expanded: expanded, probe: disclosureProbe) }"))
        XCTAssertFalse(factors.contains("IconTile("))
        XCTAssertFalse(factors.contains("只显示可验证的四项计分依据"))
        assertTextOnly(actions)
        XCTAssertFalse(actions.contains("最多 3 项"))
        assertTextOnly(trend)
        XCTAssertTrue(hero.contains("Label(statusTitle, systemImage: statusSystemImage)"))
        XCTAssertTrue(hero.contains("Label(errorText, systemImage: \"exclamationmark.triangle.fill\")"))
        XCTAssertTrue(hero.contains("confidence.value"))
        XCTAssertTrue(factors.contains("SMART 已验证只表示当前未报告故障"))
        XCTAssertTrue(factors.contains("SMART Verified means no current failure was reported; it does not mean 100% remaining life."))
        XCTAssertTrue(factors.contains("component?.evaluatedAt"))
        XCTAssertTrue(actions.contains("perform(action.safeAction)"))
        XCTAssertTrue(trend.contains("Complete two checks to show a trend"))
        // #10 keeps source notes inside collapsed tertiary details, in both languages.
        // D67 moves the disclosure to the row end. The evidence is the
        // disclosure content, collapsed by default and shown only when expanded.
        let evidence = try section(factors, from: "FeatureLightfieldStatusDisclosure(", to: "private func statusText(")
        XCTAssertTrue(evidence.contains("Text(detail(for: factor))"))
        XCTAssertTrue(evidence.contains("scoreText(component)"))
        let disclosure = try section(template, from: "struct FeatureLightfieldStatusDisclosure<", to: "private struct FeatureLightfieldRowEntrance")
        XCTAssertTrue(disclosure.contains("@State private var expanded = false"))
        XCTAssertTrue(disclosure.contains("if expanded {\n                content"))
        XCTAssertTrue(factors.contains("Text(detail(for: factor))"))
        XCTAssertTrue(factors.contains("同时考虑可用比例与绝对余量"))
        XCTAssertTrue(factors.contains("considers both free-space ratio and absolute headroom"))
        let scoreDetails = try section(hero, from: "DisclosureGroup(L10n.text(\"评分说明\", \"Score details\"))", to: "private var refreshButton:")
        XCTAssertTrue(scoreDetails.contains("Text(HealthDashboardText.scoreScopeNote)"))
        XCTAssertTrue(hero.contains("计分：磁盘、容量、稳定性、电池；备份、加密、当前电量与环境不计分，平均分不会掩盖单项异常。"))
        XCTAssertTrue(hero.contains("Scored: disk, capacity, stability and battery; backup, encryption, current charge and environment are excluded. The average does not mask an individual risk."))
    }

    func testEveryHealthActionReasonRetainsSeverityTextAndColor() throws {
        let expected: [HealthDashboardActionReason: HealthDashboardActionSeverity] = [
            .smartFailing: .critical, .currentCapacityPressure: .critical, .batteryService: .critical,
            .backupStaleOrUnconfigured: .warning, .recentPanicOrRestart: .warning,
            .forecastWithinThirtyDays: .warning, .lowComponentScore: .warning,
            .attentionComponentScore: .information,
        ]
        XCTAssertEqual(Set(expected.keys), Set(HealthDashboardActionReason.allCases))
        for reason in HealthDashboardActionReason.allCases {
            XCTAssertEqual(reason.severity, try XCTUnwrap(expected[reason]), "\(reason)")
        }
        let titles: [(HealthDashboardActionSeverity, String, String)] = [
            (.critical, "需处理", "Action required"),
            (.warning, "需关注", "Needs attention"),
            (.information, "留意", "Review"),
        ]
        XCTAssertEqual(HealthDashboardActionSeverity.allCases, titles.map { $0.0 })
        let actions = try source(views + "ComputerHealth/HealthActionList.swift")
        for (severity, chinese, english) in titles {
            XCTAssertEqual(severity.title, L10n.text(chinese, english))
            XCTAssertTrue(actions.contains("L10n.text(\"\(chinese)\", \"\(english)\")"))
        }
        let rows = try section(actions, from: "var body: some View", to: "private func title(")
        XCTAssertTrue(rows.contains("action.reason.severity.title"))
        XCTAssertTrue(rows.contains(".foregroundStyle(tint(action))"))
        let tint = try section(actions, from: "private func tint(", to: "\n}")
        XCTAssertTrue(tint.contains("switch action.reason.severity"))
        for mapping in [
            "case .critical: AppDesignTokens.Palette.destructive",
            "case .warning: AppDesignTokens.Palette.warning",
            "case .information: AppDesignTokens.Palette.information",
        ] {
            XCTAssertTrue(tint.contains(mapping), mapping)
        }
    }

    func testHealthDetailsKeepNetworkConsentAndRawDataWithoutExplanatoryChrome() throws {
        let health = try source(views + "ComputerHealthView.swift")
        for phrase in ["未知状态保持中性", "备份与磁盘加密很重要", "完成一次手动健康检查后", "ComputerHealthDashboardDebugView"] {
            XCTAssertFalse(health.contains(phrase), phrase)
        }
        assertNoSymbols(["function"], in: health)
        XCTAssertTrue(health.contains("speed.cloudflare.com"))
        XCTAssertTrue(health.contains("pendingSpeedTestConsent = .compatibility"))
        XCTAssertTrue(health.contains("startCompatibility(consentGranted: true)"))
        XCTAssertTrue(health.contains("snapshot.actionRequiredIssues.count"))
        XCTAssertTrue(health.contains("thermalReadinessDetail(presentation)"))
        XCTAssertTrue(health.contains("HealthDashboardText.scoreEvidenceTitle"))
        XCTAssertTrue(health.contains("不会写入 SMC"))
        for marker in ["private func evidencePanel", "private func environmentHeader"] {
            let signature = try section(health, from: marker, to: ") -> some View")
            XCTAssertFalse(signature.contains("symbol:"), marker)
        }
    }

    func testBenchmarkResultHeadingsAndEmptyStatesStayTextOnly() throws {
        let dashboard = try source(views + "ComputerHealth/BenchmarkV7DashboardView.swift")
        let results = try section(dashboard, from: "private var latestResultCard:", to: "private func metricSummary(")
        let best = try section(dashboard, from: "private var localBestPage:", to: "private func localBestCategoryCard(")
        let history = try section(dashboard, from: "private var historyPage:", to: "private func historyCard(")
        let historyHeading = try section(history, from: "private var historyPage:", to: "if let message = historyStatusMessage")
        let historyEmpty = try section(history, from: "if chronologicalHistory.isEmpty {", to: "} else {")
        for text in [results, best, historyHeading, historyEmpty] {
            assertTextOnly(text)
        }
        XCTAssertTrue(history.contains("Label(message, systemImage: \"exclamationmark.triangle\")"))
        XCTAssertTrue(history.contains("Label(historyFeedback.text, systemImage: \"exclamationmark.triangle\")"))
        XCTAssertFalse(best.contains("本机安全保存、成功完成"))
        XCTAssertFalse(history.contains("最新在前"))
        XCTAssertFalse(history.contains("FIXTURE"))
        XCTAssertTrue(history.contains("仅保存在本机"))
        XCTAssertTrue(history.contains("Stored only on this Mac"))
        XCTAssertTrue(results.contains("result.versions.planVersion"))
        XCTAssertTrue(results.contains("result.versions.workloadVersion"))
        XCTAssertTrue(best.contains("localBestResult"))
        XCTAssertTrue(dashboard.contains("isCurrentComparableOfficialResult"))
        XCTAssertTrue(dashboard.contains("删除后无法从应用内恢复"))
        XCTAssertTrue(dashboard.contains("This cannot be restored in the app; any exported JSON stays unchanged."))
    }

    func testBenchmarkFeedbackKeepsFailuresAndActionControls() throws {
        let dashboard = try source(views + "ComputerHealth/BenchmarkV7DashboardView.swift")
        XCTAssertTrue(dashboard.contains("if case .failure = historyFeedback"))
        XCTAssertTrue(dashboard.contains("Text(historyFeedback.text)"))
        XCTAssertFalse(dashboard.contains("historyFeedback.symbol"))
        XCTAssertTrue(dashboard.contains("Image(systemName: \"square.and.arrow.up\")"))
        XCTAssertTrue(dashboard.contains("Image(systemName: \"trash\")"))
        XCTAssertTrue(dashboard.contains("comparisonRecordIDs.contains(recordID)"))
        let leaderboard = try source(views + "ComputerHealth/BenchmarkV7LeaderboardSection.swift")
        let heading = try section(leaderboard, from: "private var titleAndScope:", to: "private var actions:")
        assertTextOnly(heading)
        XCTAssertFalse(heading.contains("主动参与且通过资格校验"))
        assertNoSymbols(["trophy"], in: leaderboard)
        XCTAssertTrue(leaderboard.contains("systemImage: \"wifi.exclamationmark\""))
        XCTAssertTrue(leaderboard.contains("systemImage: \"exclamationmark.triangle.fill\""))
        XCTAssertTrue(leaderboard.contains("showsPublishConfirmation = true"))
        XCTAssertTrue(leaderboard.contains("showsRemovalConfirmation = true"))
        XCTAssertTrue(leaderboard.contains("应用不会提交电脑名称、序列号"))
        let raw = try source(views + "ComputerHealth/MSeriesRawResultView.swift")
        XCTAssertTrue(raw.contains("A/B/C: sample stability, not statistical confidence"))
        XCTAssertTrue(raw.contains("awaiting reference calibration"))
        XCTAssertTrue(raw.contains("statistics.sampleCount"))
    }

    func testUnreferencedLegacyBenchmarkViewsStayDeleted() {
        for name in ["MacBenchmarkDashboardView", "MacBenchmarkResultSections", "MacBenchmarkLeaderboardSection", "MacAcceleratorBenchmarkSection", "MacSustainedBenchmarkSection"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(views + "ComputerHealth/" + name + ".swift").path), name)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(views + "ComputerHealth/MacBenchmarkPresentation.swift").path))
    }

    // D70②: domains by default; title/address and visit selection behind disclosure.
    func testBrowserRowsContinueToExposePageTitleAndAddress() throws {
        let hierarchy = try source(views + "BrowserPrivacyLightfieldResults.swift")
        let results = try source(views + "BrowserPrivacyRecordResultsView.swift")
        XCTAssertTrue(results.contains("BrowserPrivacyLightfieldResults("))
        XCTAssertTrue(hierarchy.contains("Text(pageTitle)"))
        XCTAssertTrue(hierarchy.contains("presentation.address.full ?? presentation.address.collapsed"))
        XCTAssertTrue(hierarchy.contains("BrowserPrivacyVisitPresentation.visits(of: item)"))
        XCTAssertTrue(hierarchy.contains("FeatureLightfieldCheck("))
        XCTAssertTrue(hierarchy.contains("FeatureLightfieldDisclosureChevron("))
        XCTAssertTrue(hierarchy.contains("选择页面会包含全部访问"))
    }

    func testBrowserResultsKeepBackupScopeAndManualGuidance() throws {
        let results = try source(views + "BrowserPrivacyRecordResultsView.swift")
        // D70② moves the primary action into the shared pinned skeleton.
        XCTAssertTrue(results.contains("FeatureLightfieldPage(module: .privacy"))
        XCTAssertTrue(results.contains("actionTitle: lightfieldActionTitle"))
        XCTAssertTrue(results.contains("action: beginProcessingConfirmation"))
        XCTAssertTrue(results.contains("isShowingRunningBrowserPreflight = true"))
        XCTAssertTrue(results.contains("复核删除并回读，核验前保留记录，请勿打开浏览器"))
        XCTAssertTrue(results.contains("Check, delete and verify; records stay until verified; keep browsers closed"))
        XCTAssertTrue(results.contains("点击复制才写入剪贴板"))
        XCTAssertTrue(results.contains("Selected pages stay in this memory session; copying writes to the clipboard only on click"))
        XCTAssertTrue(results.contains("BrowserPrivacyRecoveryText.retentionNotice"))
        XCTAssertFalse(results.contains("Label(group.browser.displayName"))
        XCTAssertFalse(results.contains("Label(L10n.text(\"已处理，重新扫描\""))
        XCTAssertFalse(results.contains("Image(systemName: kind == .scanning"))
        XCTAssertTrue(results.contains("Safari 使用 Command-Y"))
        XCTAssertTrue(results.contains("任何按钮都不会打开列表中的网页或自动删除内容。"))
        XCTAssertTrue(results.contains("No button opens a listed website or deletes anything automatically."))
        XCTAssertTrue(results.contains("部分扫描不能证明没有历史记录"))
        XCTAssertTrue(results.contains("Review each browser's read status above and try again; a partial scan does not prove that no history exists."))
        XCTAssertTrue(results.contains("扫描不会打开网页、上传记录"))
        XCTAssertTrue(results.contains("The scan does not open websites, upload records, or sync browser data."))
    }

    func testBrowserRecoveryFeedbackAndBulkOptionsKeepSafety() throws {
        let recent = try source(views + "BrowserPrivacyRecentDeletionsView.swift")
        XCTAssertTrue(recent.contains("if result.succeeded {"))
        XCTAssertTrue(recent.contains("Text(result.detail)"))
        XCTAssertFalse(recent.contains("result.succeeded ? \"checkmark.circle.fill\""))
        XCTAssertTrue(recent.contains("exclamationmark.triangle.fill"))
        XCTAssertTrue(recent.contains("BrowserPrivacyBackupRetention.days"))
        XCTAssertTrue(recent.contains("BrowserPrivacyBackupRetention.maximumCount"))
        XCTAssertTrue(recent.contains("已恢复和待核实的不计"))
        XCTAssertTrue(recent.contains(#"删除前备份：浏览记录为整库备份（含已删页面），Cookie 与 Chromium 表单自动填充只备份所删行，其他数据类型备份所在数据库；仅本地保存、不上传且不进入时间机器；\(BrowserPrivacyBackupRetention.days) 天后删除，浏览记录与其他数据各自最多 \(BrowserPrivacyBackupRetention.maximumCount) 份（已恢复和待核实的不计）；可提前删除"#))
        XCTAssertTrue(recent.contains(#"Backup before deletion: history as a full database backup (including deleted pages); cookies and Chromium form autofill back up only the deleted rows, other data types back up their database; local only, no upload or Time Machine; removed after \(BrowserPrivacyBackupRetention.days) days, up to \(BrowserPrivacyBackupRetention.maximumCount) copies each for history and for other data (restored and unconfirmed excluded); may be deleted earlier"#))
        XCTAssertTrue(recent.contains("Image(systemName: \"trash\")"))
        let bulk = try source(views + "BrowserPrivacyBulkSelectionView.swift")
        XCTAssertFalse(bulk.contains("按日期或网站加入选择；不会立即删除"))
        let websiteRow = try section(bulk, from: "private func websiteSelectionButton(", to: "private func dateSymbol(")
        assertTextOnly(websiteRow)
        // Undisclosed sensitive options share the same text-only row; its
        // safe title is either the visible domain or the masked aggregate.
        XCTAssertTrue(websiteRow.contains("Text(option.title)"))
        XCTAssertTrue(bulk.contains("Image(systemName: dateSymbol(for: scope))"))
        XCTAssertTrue(bulk.contains("onSelect(option.isSensitive ? .sensitive : .website(option.domain))"))
        XCTAssertTrue(bulk.contains("matchingRecordIDs("))
    }

    func testStartupResultsKeepManagementAndAdministratorSafety() throws {
        let dashboard = try source(startup + "StartupItemsDashboardView.swift")
        // D67/D70: the text-only overview is the shared B2 summary, with
        // real scanned totals and management capability counts at the adapter.
        let metric = try section(dashboard, from: "LightfieldSummary(module: .startup", to: "} rows: {")
        assertTextOnly(metric)
        XCTAssertTrue(metric.contains("presentation.summary.total"))
        XCTAssertTrue(metric.contains("isLoading && items.isEmpty ? \"—\""), "Loading without a snapshot is unknown, not zero")
        XCTAssertTrue(metric.contains("presentation.summary.manageable"))
        XCTAssertFalse(dashboard.contains("调整分类或筛选条件。"))
        XCTAssertTrue(dashboard.contains("StartupItemStatusLabel(item: item)"))
        XCTAssertFalse(dashboard.contains("switch.2"))
        let inspector = try source(startup + "StartupItemInspectorView.swift")
        XCTAssertTrue(inspector.contains("系统控制辅助程序可能需注册与批准；执行需管理员授权；无应用内撤销，可反向操作恢复"))
        XCTAssertTrue(inspector.contains("The system control helper may need registration and system approval; administrator approval required; no in-app undo, restore with the inverse action"))
        let presentation = try source(startup + "StartupItemsPresentation.swift")
        XCTAssertTrue(presentation.contains("归属或管理方式未确认 · 只读"))
        XCTAssertTrue(presentation.contains("系统或组织保护 · 只读"))
        let management = try section(presentation, from: "var managementExplanation:", to: "var isAttentionItem:")
        XCTAssertTrue(management.contains("由系统设置管理 · 本应用只打开设置页"))
        XCTAssertTrue(management.contains("Managed in System Settings · This app opens Settings only"))
    }

    func testFileReviewKeepsIdentityChecksRecoveryAndExternalVolumeLimits() throws {
        let trash = try source(views + "FileAnalysisTrashViews.swift")
        let notes = try section(trash, from: "private var notes:", to: "private func progressView(")
        let header = try section(trash, from: "private var header:", to: "private var itemList:")
        assertTextOnly(header)
        assertTextOnly(notes)
        XCTAssertTrue(notes.contains("移前逐项复核，变化则跳过；操作记录可恢复，清空废纸篓后释放空间"))
        XCTAssertTrue(notes.contains("Recheck before moving; skip changed items; restore from Operation History; empty Trash to free space"))
        XCTAssertTrue(notes.contains("otherTrashNote(volumes: review.externalVolumeNames)"))
        XCTAssertTrue(trash.contains("Image(systemName: systemImage)"))
        XCTAssertTrue(trash.contains("checkmark.square.fill"))
        XCTAssertFalse(trash.contains("static func symbol(for"))
        XCTAssertTrue(trash.contains("Text(FileAnalysisTrashPresentation.otherHardLinksNote)"))
        XCTAssertTrue(trash.contains("Text(item.selection.path)"))
        XCTAssertTrue(trash.contains("block.explanation(naming: unknownApplications)"))
        XCTAssertEqual(trash.components(separatedBy: "workspace.confirmTrash()").count - 1, 1)
        let outcome = try section(trash, from: "private func outcomeRows(", to: "private func outcomeTitle(")
        XCTAssertTrue(outcome.contains("if warns {"))
        XCTAssertTrue(outcome.contains("Label(outcomeTitle(outcome), systemImage: \"exclamationmark.triangle.fill\")"))
        let success = try section(outcome, from: "} else {", to: "Spacer(minLength:")
        assertTextOnly(success)
        XCTAssertTrue(success.contains("Text(outcomeTitle(outcome))"))
    }

    func testFileMapKeepsNavigationAndSelectionButRemovesStaticHeadingIcons() throws {
        let map = try source(views + "StorageTreemapView.swift")
        let header = try section(map, from: "private var mapHeaderIdentity:", to: "private var mapHeaderSize:")
        let empty = try section(map, from: "private func storageMapEmptyState(", to: "private var directoryCount:")
        assertTextOnly(header)
        assertTextOnly(empty)
        XCTAssertFalse(map.contains("Label(entryFilter.title"))
        XCTAssertFalse(map.contains("Label(entrySort.title"))
        XCTAssertTrue(map.contains("Image(systemName: tileIcon)"))
        XCTAssertTrue(map.contains("Image(systemName: \"chevron.right\")"))
        XCTAssertTrue(map.contains("FileAnalysisTrashCheckbox("))
        XCTAssertTrue(map.contains("AppIconButton("))
        XCTAssertTrue(header.contains("Map shows the entire folder"))
        XCTAssertTrue(map.contains("exclamationmark.triangle.fill"))
    }

    func testUninstallResidualAndConflictViewsKeepWarningsAndRealIdentity() throws {
        let uninstall = try source(views + "UninstallPreviewSheet.swift")
        assertNoSymbols(["app.dashed"], in: uninstall)
        XCTAssertFalse(uninstall.contains("Label(L10n.text(\"正在检查关联文件"))
        XCTAssertTrue(uninstall.contains("UninstallPreviewAppIcon(path: app.path)"))
        XCTAssertTrue(uninstall.contains("回执保存失败，请勿重复操作"))
        XCTAssertTrue(uninstall.contains("Receipt saving failed. Do not repeat the operation."))
        XCTAssertTrue(uninstall.contains("移入废纸篓，可恢复；清空前不释放空间"))
        XCTAssertTrue(uninstall.contains("Recoverable in Trash; space is freed only when Trash is emptied."))
        let residual = try source(views + "ResidualFileEvidenceView.swift")
        assertNoSymbols(["doc.text.magnifyingglass", "checkmark.circle"], in: residual)
        XCTAssertTrue(residual.contains("未匹配到应用不代表可以删除"))
        XCTAssertTrue(residual.contains("No app match does not mean safe to delete"))
        XCTAssertTrue(residual.contains("这不是整个磁盘或所有应用数据的证明"))
        XCTAssertTrue(residual.contains("This does not prove that the whole disk or all app data is clear."))
        XCTAssertTrue(residual.contains("systemImage: \"exclamationmark.triangle\""))
        let conflict = try source(views + "AppInstallationConflictBanner.swift")
        XCTAssertTrue(conflict.contains("Image(systemName: \"exclamationmark.triangle.fill\")"))
        XCTAssertTrue(conflict.contains("conflict.currentRuntimePath"))
        assertNoSymbols(["folder"], in: conflict)
    }

    func testCleanupAndLegacyItemViewsKeepOperationsWithoutDecorativeSymbols() throws {
        let overlay = try source(views + "CleanupOperationOverlay.swift")
        let metric = try section(overlay, from: "private func completionMetric(", to: "private var completionActions:")
        assertTextOnly(metric)
        XCTAssertTrue(overlay.contains("AppStateIconRing("))
        XCTAssertTrue(overlay.contains("清空废纸篓后才会真正释放空间"))
        XCTAssertTrue(overlay.contains("moved to Trash; space is freed only after Trash is emptied."))
        XCTAssertTrue(overlay.contains("store.requestRestoreLatestCleanup()"))
        let detail = try source(views + "ItemDetailView.swift")
        XCTAssertFalse(detail.contains("Image(systemName: item.tier.systemImage)"))
        XCTAssertTrue(detail.contains("Label(item.tier.title, systemImage: item.tier.systemImage)"))
        XCTAssertTrue(detail.contains("Image(systemName: safetyIcon)"))
        XCTAssertTrue(detail.contains("store.requestTrash(item)"))
        let list = try source(views + "ItemListView.swift")
        XCTAssertFalse(list.contains("Image(systemName: metric.systemImage)"))
        XCTAssertFalse(list.contains("Image(systemName: filter.systemImage)"))
        XCTAssertTrue(list.contains("Image(systemName: item.tier.systemImage)"))
        XCTAssertTrue(list.contains(".accessibilityValue(metric.value)"))
        let statusMetric = try section(list, from: "private struct ItemListStatusMetric", to: "private struct ItemListMetricPill")
        XCTAssertFalse(statusMetric.contains("tint"))
        let recordStrip = try section(list, from: "private var greenCleanupRecordStrip:", to: "private func cleanupRecordDetail(")
        XCTAssertTrue(recordStrip.contains("if !recordDetail.trimmed.isEmpty {"))
        XCTAssertTrue(recordStrip.contains("Text(recordDetail)"))
    }

    func testOverviewDeadPartitionsStayRemovedAndActionableTilesKeepIdentity() throws {
        let overview = try source(views + "OverviewView.swift")
        for partition in ["private var header:", "scanFreshnessSection", "systemStatusSection", "moduleSection", "diskSection", "topItemsSection", "private struct MetricCard", "private struct CompactModuleCard", "private struct TopItemRow", "private struct CardArtworkIcon", "private struct DiskSegmentBar", "private struct LegendDot"] {
            XCTAssertFalse(overview.contains(partition), partition)
        }
        let tile = try section(overview, from: "private struct SmartCareResultTaskTile:", to: "private var showsSuccessStatus:")
        XCTAssertTrue(tile.contains("if isActionable {\n                    Image(systemName: systemImage)"))
        XCTAssertFalse(tile.contains("systemImage: \"checkmark\""))
        XCTAssertTrue(tile.contains("Image(systemName: \"chevron.right\")"))
        XCTAssertTrue(tile.contains(".accessibilityLabel(title)"))
        XCTAssertTrue(overview.contains("DashboardPage("))
        XCTAssertTrue(overview.contains("systemImage: AppSymbols.Navigation.overview"))
        XCTAssertTrue(overview.contains("store.showCleanupReview(scope: .needsReview)"))
        XCTAssertTrue(overview.contains("store.showCleanupReview(scope: .careful)"))
    }
}
