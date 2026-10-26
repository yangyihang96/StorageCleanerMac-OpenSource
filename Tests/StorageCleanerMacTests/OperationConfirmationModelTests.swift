import Foundation
import XCTest
@testable import StorageCleanerMac

/// D93：确认页六个字段与完成页四组统计的共享模型。纯数据夹具，不触碰文件系统。
@MainActor
final class OperationConfirmationModelTests: XCTestCase {
    // MARK: 完成页计数与容量口径

    func testReportTallyCountsFourBucketsAndOnlyReadBackDeletionsAreFreed() {
        for language in [AppLanguage.zhHans, .english] {
            withLanguage(language) {
                let report = Self.report([
                    ("moved", 100, .moved(Self.receipt("moved"))),
                    ("unverified", 50, .moved(Self.receipt("unverified", verified: false))),
                    ("skipped", 7, .skipped(.relatedAppStillRunning)),
                    ("notRun", 8, .notProcessed),
                    ("failed", 9, .failed(CleanFailure(code: .trashMoveFailed, detailCode: nil))),
                    ("unknown", 10, .failed(CleanFailure(code: .moveOutcomeUnknown, detailCode: nil))),
                    ("deleted", 30, .deleted(CleanupDeletionReceipt(originalPath: "/Fixture/deleted",
                        deletedIdentity: Self.identity(9), deletedAt: Date()))),
                ])
                let tally = OperationCompletionTally(report: report)
                XCTAssertEqual(tally.count(.completed), 2)
                XCTAssertEqual(tally.count(.skipped), 2)
                XCTAssertEqual(tally.count(.failed), 1)
                XCTAssertEqual(tally.count(.needsVerification), 2)
                XCTAssertEqual(tally.movedToTrashBytes, 100)
                XCTAssertEqual(tally.releasedBytes, 30)
                XCTAssertEqual(tally.headline, L10n.text("完成 2 · 跳过 2 · 失败 1 · 待核实 2",
                    "Completed 2 · Skipped 2 · Failed 1 · Needs Verification 2"))
                // 每个非完成项都有原因。
                for entry in tally.entries where entry.bucket != .completed {
                    XCTAssertFalse(entry.detail.isEmpty, entry.title)
                }
                XCTAssertEqual(tally.entries(in: .skipped).first?.detail,
                               CleanSkipReasonPresentation.title(.relatedAppStillRunning))
                let lines = tally.capacityLines
                XCTAssertTrue(lines.contains { $0.contains(L10n.text("已移到废纸篓", "Moved to the Trash")) })
                XCTAssertTrue(lines.contains { $0.contains(L10n.text("清空废纸篓后才释放", "not freed until the Trash is emptied")) })
                XCTAssertTrue(lines.contains { $0.contains(L10n.text("实际释放", "Actually freed")) })
            }
        }
    }

    func testTrashOnlyCompletionNeverSaysFreed() {
        for language in [AppLanguage.zhHans, .english] {
            withLanguage(language) {
                let tally = OperationCompletionTally(report: Self.report([
                    ("a", 1_000, .moved(Self.receipt("a"))), ("b", 2_000, .moved(Self.receipt("b"))),
                ]))
                XCTAssertEqual(tally.count(.completed), 2)
                XCTAssertEqual(tally.releasedBytes, 0)
                let text = (tally.capacityLines + tally.entries.map(\.detail)).joined(separator: "\n")
                XCTAssertFalse(text.contains("已释放"), text)
                XCTAssertFalse(text.contains("实际释放"), text)
                XCTAssertFalse(text.lowercased().contains("actually freed"), text)
                XCTAssertFalse(text.lowercased().contains("space freed"), text)
                XCTAssertTrue(text.contains(L10n.text("未释放", "not freed")), text)
            }
        }
    }

    func testRestoredQuarantinedAndUnsavedReceiptsAreNotCountedAsTrash() {
        var report = Self.report([
            ("restored", 400, .moved(Self.receipt("restored"))),
            ("quarantined", 300, .moved(Self.receipt("quarantined", disposition: .quarantine))),
        ])
        report.recoveryAttempts = [CleanupRecoveryReport(completedAt: Date(), items: [
            CleanupRecoveryItem(id: UUID(), originalPath: "/Fixture/restored", outcome: .restored),
        ])]
        report.persistenceFailure = "final-write-failed"
        let tally = OperationCompletionTally(report: report)
        XCTAssertEqual(tally.movedToTrashBytes, 0)
        XCTAssertEqual(tally.movedToQuarantineBytes, 300)
        XCTAssertEqual(tally.releasedBytes, 0)
        XCTAssertTrue(tally.receiptIncomplete)
        XCTAssertTrue(tally.capacityLines.contains {
            $0 == L10n.text("回执未完整保存，请以“操作记录”为准", "The receipt was not fully saved; check Operation History")
        })
        XCTAssertEqual(tally.count(.completed), 2)
    }

    func testFileAnalysisTallyAddsReviewSkipsAndWorksWithoutReceipt() {
        let withReceipt = FileAnalysisTrashOutcome(
            report: Self.report([("movie.mov", 4_096, .moved(Self.receipt("movie.mov")))]),
            movedPaths: ["/Fixture/movie.mov"], movedBytes: 4_096,
            skipped: [.init(path: "/Fixture/locked", title: "locked", reason: "已锁定")],
            notRestorableHereCount: 0, externalVolumeNames: [], receiptUnavailable: false, cancelled: false)
        var tally = OperationCompletionTally(fileAnalysis: withReceipt)
        XCTAssertEqual(tally.count(.completed), 1)
        XCTAssertEqual(tally.count(.skipped), 1)
        XCTAssertEqual(tally.entries(in: .skipped).first?.detail, "已锁定")
        XCTAssertEqual(tally.movedToTrashBytes, 4_096)
        XCTAssertEqual(tally.releasedBytes, 0)

        var withoutReceipt = withReceipt
        withoutReceipt = FileAnalysisTrashOutcome(report: nil, movedPaths: ["/Fixture/a", "/Fixture/b"],
            movedBytes: 10, skipped: [], notRestorableHereCount: 0, externalVolumeNames: [],
            receiptUnavailable: false, cancelled: false, receiptIncomplete: true)
        tally = OperationCompletionTally(fileAnalysis: withoutReceipt)
        XCTAssertEqual(tally.count(.completed), 2)
        XCTAssertEqual(tally.movedToTrashBytes, 10)
        XCTAssertEqual(tally.releasedBytes, 0)
        XCTAssertTrue(tally.receiptIncomplete)
    }

    func testBrowserTallyMapsOutcomesAndNeverTalksAboutDiskSpace() {
        let browser = BrowserPrivacyBrowser(id: "fixture", displayName: "Fixture", engine: .chromium,
                                            bundleIdentifier: "com.storagecleaner.fixture", version: "1")
        func entry(_ profile: String, _ outcome: BrowserPrivacyProcessingOutcome, records: Int,
                   verified: Int = 0) -> BrowserPrivacyProcessingEntry {
            BrowserPrivacyProcessingEntry(browser: browser, profileID: profile, recordCount: records,
                capability: .verifiedVisitDeletion, outcome: outcome,
                verifiedDeletedRecordIDs: Set((0..<verified).map { _ in UUID() }))
        }
        // Processor writes every deleted visit into verifiedDeletedRecordIDs
        // (BrowserPrivacyHistoryProcessor); entries add up to the selection.
        let report = BrowserPrivacyProcessingReport(selectedRecordCount: 10, entries: [
            entry("A", .deleted, records: 4, verified: 4),
            entry("B", .failed, records: 2),
            entry("C", .indeterminate, records: 1),
            entry("D", .manual, records: 3),
        ])
        let tally = OperationCompletionTally(browser: report)
        XCTAssertEqual(tally.count(.completed), 4, "only read-back verified visits count as done")
        XCTAssertEqual(OperationCompletionBucket.allCases.reduce(0) { $0 + tally.count($1) }, report.selectedRecordCount)
        XCTAssertEqual(tally.count(.failed), 2)
        XCTAssertEqual(tally.count(.needsVerification), 1)
        XCTAssertEqual(tally.count(.skipped), 3)
        XCTAssertFalse(tally.affectsDiskSpace)
        XCTAssertEqual(tally.capacityLines, [L10n.text("删除浏览记录不涉及释放磁盘空间",
                                                       "Deleting browsing history does not free disk space")])
        for item in tally.entries where item.bucket != .completed { XCTAssertFalse(item.detail.isEmpty) }
        // A "deleted" entry whose read-back confirmed fewer visits counts only
        // the confirmed ones as done, never its requested record count.
        let partial = OperationCompletionTally(browser: BrowserPrivacyProcessingReport(
            selectedRecordCount: 4, entries: [entry("E", .deleted, records: 4, verified: 3)]))
        XCTAssertEqual(partial.count(.completed), 3)
    }

    // MARK: 确认页六个字段

    func testEveryPageFactoryListsAllSixFieldsInBothLanguages() throws {
        for language in [AppLanguage.zhHans, .english] {
            try withLanguage(language) {
                let all = try Self.allPageFacts()
                // Surfaces come from the production inference, not passed in by hand.
                XCTAssertEqual(all.map(\.surface).sorted { $0.rawValue < $1.rawValue },
                               OperationSurface.allCases.sorted { $0.rawValue < $1.rawValue })
                for facts in all {
                    XCTAssertEqual(facts.rows.map(\.field), OperationConfirmationFacts.Field.allCases, "\(facts.surface)")
                    for row in facts.rows {
                        XCTAssertFalse(row.value.trimmingCharacters(in: .whitespaces).isEmpty, "\(facts.surface) \(row.field)")
                        XCTAssertFalse(row.field.title.isEmpty)
                    }
                    XCTAssertEqual(facts.plainText.components(separatedBy: "\n").count, 6)
                    if language == .english {
                        let text = facts.plainText + facts.rows.map(\.field.title).joined()
                        XCTAssertNil(text.range(of: Self.cjkPattern, options: .regularExpression), "\(facts.surface): \(text)")
                    }
                }
            }
        }
    }

    /// D101 L5：菜单“清空废纸篓”的六个字段取自冻结清单，写明永久删除、不可恢复。
    func testEmptyTrashFactsComeFromTheFrozenList() {
        withLanguage(.zhHans) {
            let frozen = FrozenTrash.testFixture(names: ["a", "b", "c"])
            let facts = OperationConfirmationFacts.emptyTrash(frozen)
            XCTAssertEqual(facts.surface, .emptyTrash)
            XCTAssertEqual(facts.actions, [.permanentDeletion])
            XCTAssertEqual(facts.recovery, [.notRecoverable])
            XCTAssertEqual(facts.permission, .notRequired)
            XCTAssertEqual(facts.items.map(\.title), ["a", "b", "c"])
            XCTAssertEqual(facts.items.map(\.path), frozen.entries.map { frozen.trashURL.appendingPathComponent($0.name).path })
            XCTAssertEqual(facts.localBytes, frozen.summary.totalBytes)
            XCTAssertEqual(facts.permanentDeletionBytes, frozen.summary.totalBytes)
            XCTAssertEqual(facts.trashBytes, 0)
            XCTAssertEqual(facts.value(for: .objects), L10n.items(3))
            XCTAssertTrue(facts.value(for: .capacity).contains("永久删除"), facts.value(for: .capacity))
            XCTAssertTrue(facts.value(for: .recovery).contains("不可恢复"))
            XCTAssertEqual(facts.rows.filter(\.isWarning).map(\.field), [.action, .recovery])
        }
    }

    func testCleanupPlanFactsSplitTrashFromPermanentDeletionAndExplainSkips() {
        withLanguage(.zhHans) {
            let items = Self.planItems([("a", 1_000, .moveToTrash), ("b", 2_000, .moveToTrash), ("trash-entry", 500, .emptyTrash)])
            let skippedID = items[1].id
            let facts = OperationConfirmationFacts.cleanupPlanItems(items, disposition: .trash,
                skipped: [skippedID: .relatedAppStillRunning, UUID(): .itemMissing], surface: .safeCleanup,
                appsToQuit: ["Fixture App"], permission: .verified)
            XCTAssertEqual(facts.actions, [.moveToTrash, .permanentDeletion])
            XCTAssertEqual(facts.recovery, [.trashAndOperationHistory, .notRecoverable])
            XCTAssertEqual(facts.localBytes, 1_500)
            XCTAssertEqual(facts.trashBytes, 1_000)
            XCTAssertEqual(facts.permanentDeletionBytes, 500)
            XCTAssertEqual(facts.notRunCount, 1)
            XCTAssertTrue(facts.items.first { $0.id == skippedID.uuidString }?.detail?
                .contains(CleanSkipReasonPresentation.title(.relatedAppStillRunning)) == true)
            let capacity = facts.value(for: .capacity)
            XCTAssertTrue(capacity.contains("本地占用"), capacity)
            XCTAssertTrue(capacity.contains("清空废纸篓后才释放"), capacity)
            XCTAssertTrue(capacity.contains("回读确认"), capacity)
            XCTAssertTrue(facts.value(for: .appsToQuit).contains("Fixture App"))
            XCTAssertTrue(facts.rows.first { $0.field == .action }?.isWarning == true)
            XCTAssertEqual(facts.readyCount, 2)
            XCTAssertEqual(facts.value(for: .objects), "共 3 项：2 项将执行，1 项不会执行（原因见清单）")
            // D178: decimal (was `ByteFormat.string`, binary: "1 KiB" for 1,500 bytes).
            XCTAssertEqual(capacity, "本地占用（将执行的 2 项） \(ByteFormat.storageString(1_500))；其中 \(ByteFormat.storageString(1_000)) 移到废纸篓，清空废纸篓后才释放；其中 \(ByteFormat.storageString(500)) 永久删除，删除后回读确认才计为已释放")

            let quarantine = OperationConfirmationFacts.cleanupPlanItems(
                Self.planItems([("q", 64, .moveToTrash)]), disposition: .quarantine, skipped: [:],
                surface: .duplicateFiles, appsToQuit: [], permission: .notRequired)
            XCTAssertEqual(quarantine.actions, [.moveToQuarantine])
            XCTAssertEqual(quarantine.recovery, [.quarantine])
            XCTAssertEqual(quarantine.trashBytes, 0)
            XCTAssertTrue(quarantine.value(for: .capacity).contains("不释放空间"))
            XCTAssertEqual(quarantine.value(for: .appsToQuit), "无需退出应用")
        }
    }

    // MARK: 修复轮 2（复核轮 2 P2-11／P2-12）

    /// P2-12：标题、表头“项目／将执行”与“对象”字段同一口径——全部计划项（含清空废纸篓的条目），
    /// 有不会执行的项目时写明将执行几项。中英文一致。
    func testCleanupPlanTitleHeaderAndObjectsShareOneBasis() {
        let items = Self.planItems([("a", 1_000, .moveToTrash), ("b", 2_000, .moveToTrash), ("trash-entry", 500, .emptyTrash)])
        func facts(_ skipped: [UUID: CleanSkipReason], _ planItems: [CleanPlanItem]? = nil) -> OperationConfirmationFacts {
            OperationConfirmationFacts.cleanupPlanItems(planItems ?? items, disposition: .trash, skipped: skipped,
                surface: .safeCleanup, appsToQuit: [], permission: .verified)
        }
        let mixed = facts([items[1].id: .relatedAppStillRunning])
        XCTAssertEqual(mixed.itemCount, 3)
        XCTAssertEqual(mixed.readyCount, 2)
        withLanguage(.zhHans) {
            XCTAssertEqual(mixed.cleanupPlanTitle(planHasMoves: true, planHasPermanentDeletion: true),
                           "清理 3 个项目并清空废纸篓（将执行 2 项）？")
            XCTAssertEqual(mixed.value(for: .objects), "共 3 项：2 项将执行，1 项不会执行（原因见清单）")
            let movesOnly = facts([:], Array(items.prefix(2)))
            XCTAssertEqual(movesOnly.cleanupPlanTitle(planHasMoves: true, planHasPermanentDeletion: false), "清理 2 个项目？")
            let movesSkipped = facts([items[0].id: .itemMissing], Array(items.prefix(2)))
            XCTAssertEqual(movesSkipped.cleanupPlanTitle(planHasMoves: true, planHasPermanentDeletion: false),
                           "清理 2 个项目（将执行 1 项）？")
            let deleteOnly = facts([:], [items[2]])
            XCTAssertEqual(deleteOnly.cleanupPlanTitle(planHasMoves: false, planHasPermanentDeletion: true),
                           "清空废纸篓：1 个项目？")
        }
        withLanguage(.english) {
            XCTAssertEqual(mixed.cleanupPlanTitle(planHasMoves: true, planHasPermanentDeletion: true),
                           "Clean 3 Item(s) and Empty Trash (2 will run)?")
            XCTAssertEqual(facts([:], [items[2]]).cleanupPlanTitle(planHasMoves: false, planHasPermanentDeletion: true),
                           "Empty Trash: 1 Item(s)?")
        }
    }

    /// P2-12：移入项全部不会执行时，不再写“清空废纸篓后最多可释放 0 B”，而是写明不会移动任何项目。
    func testTrashReleaseNoteSaysNothingMovesWhenEveryMoveIsSkipped() {
        let items = Self.planItems([("a", 1_000, .moveToTrash), ("b", 2_000, .moveToTrash), ("trash-entry", 500, .emptyTrash)])
        let allMovesSkipped = OperationConfirmationFacts.cleanupPlanItems(items, disposition: .trash,
            skipped: [items[0].id: .itemMissing, items[1].id: .relatedAppStillRunning],
            surface: .safeCleanup, appsToQuit: [], permission: .verified)
        let oneReady = OperationConfirmationFacts.cleanupPlanItems(items, disposition: .trash,
            skipped: [items[1].id: .relatedAppStillRunning],
            surface: .safeCleanup, appsToQuit: [], permission: .verified)
        withLanguage(.zhHans) {
            let note = allMovesSkipped.cleanupTrashReleaseNote(planHasTrashMoves: true)
            XCTAssertEqual(note, "移到废纸篓的项目都不会执行，本次不会移动任何项目。")
            XCTAssertFalse(note?.contains("最多可释放") ?? true)
            // D178: decimal (was `ByteFormat.string`, binary).
            XCTAssertEqual(oneReady.cleanupTrashReleaseNote(planHasTrashMoves: true),
                           "清空废纸篓后最多可释放 \(ByteFormat.storageString(1_000))；当前立即释放取决于废纸篓和文件系统状态。")
            XCTAssertNil(OperationConfirmationFacts.cleanupPlanItems([items[2]], disposition: .trash, skipped: [:],
                surface: .safeCleanup, appsToQuit: [], permission: .verified)
                .cleanupTrashReleaseNote(planHasTrashMoves: false))
        }
        withLanguage(.english) {
            let note = allMovesSkipped.cleanupTrashReleaseNote(planHasTrashMoves: true) ?? ""
            XCTAssertEqual(note, "None of the items to move to the Trash will run; nothing will be moved this time.")
            XCTAssertNil(note.range(of: Self.cjkPattern, options: .regularExpression), note)
        }
    }

    /// P2-11：大型计划（几千项、几百项跳过，另有不属于本计划的跳过 ID）一次构建，计数正确；
    /// 过滤按 Set 进行（源码约束见 OperationConfirmationContractTests），不做计时断言。
    func testLargeCleanupPlanFactsCountSkipsOnceAndIgnoreForeignIDs() {
        let items = Self.planItems((0..<4_000).map { ("item-\($0)", Int64(10), CleanupRuleAction.moveToTrash) })
        var skipped: [UUID: CleanSkipReason] = [:]
        for item in items.prefix(600) { skipped[item.id] = .itemMissing }
        for _ in 0..<200 { skipped[UUID()] = .itemMissing }
        let facts = OperationConfirmationFacts.cleanupPlanItems(items, disposition: .trash, skipped: skipped,
            surface: .smartScan, appsToQuit: [], permission: .verified)
        XCTAssertEqual(facts.itemCount, 4_000)
        XCTAssertEqual(facts.notRunCount, 600)
        XCTAssertEqual(facts.readyCount, 3_400)
        XCTAssertEqual(facts.trashBytes, 34_000)
    }

    func testSurfaceInferenceKeepsDeveloperAndDuplicatePlansApart() {
        XCTAssertEqual(OperationSurface.inferred(for: Self.planItems([("x", 1, .moveToTrash)], ruleID: "developer.go-build")), .developerTools)
        XCTAssertEqual(OperationSurface.inferred(for: Self.planItems([("x", 1, .moveToTrash)], ruleID: "system.user-caches")), .safeCleanup)
        XCTAssertEqual(OperationSurface.inferred(for: Self.planItems([], ruleID: "developer.go-build")), .safeCleanup)
    }

    func testPermissionCoverageSaysWhatIsSkippedWithoutFullDiskAccess() {
        withLanguage(.zhHans) {
            let location = ScanReadinessLocation(title: "文稿", path: "/Fixture/Documents",
                                                 systemImage: "doc", isHighImpact: true)
            let blocked = ScanReadinessSummary(items: [ScanReadinessItem(location: location, status: .needsPermission)],
                                               fullDiskAccessState: .notVerified)
            let coverage = OperationPermissionCoverage.from(blocked)
            XCTAssertEqual(coverage, .missingFullDiskAccess(limitedLocations: ["文稿"]))
            XCTAssertTrue(coverage.isLimited)
            XCTAssertTrue(coverage.text.contains("文稿"))
            XCTAssertTrue(coverage.text.contains("跳过"))
            XCTAssertEqual(OperationPermissionCoverage.from(ScanReadinessSummary(items: [], fullDiskAccessState: .verified)), .verified)
            XCTAssertEqual(OperationPermissionCoverage.from(nil as ScanReadinessSummary?), .unknown)
            XCTAssertEqual(OperationPermissionCoverage.from(FullDiskAccessState.notVerified), .missingFullDiskAccess(limitedLocations: []))
            XCTAssertFalse(OperationPermissionCoverage.verified.isLimited)
            XCTAssertTrue(OperationPermissionCoverage.unknown.text.contains("跳过"))
        }
    }

    func testUninstallFactsNameTheRunningAppAndKeepUnknownSizesAsLowerBound() {
        withLanguage(.zhHans) {
            let app = Self.app()
            let related = [InstalledAppRelatedItem(path: "/Fixture/Library/Caches/com.fixture", sizeBytes: 10),
                           InstalledAppRelatedItem(path: "/Fixture/Library/Logs/fixture", sizeBytes: 0, sizeIsKnown: false)]
            let facts = OperationConfirmationFacts.uninstall(app: app, selected: related, residual: false,
                runningAppNames: ["Fixture"], permission: .verified)
            XCTAssertEqual(facts.actions, [.uninstall, .moveToTrash])
            XCTAssertEqual(facts.itemCount, 3)
            XCTAssertEqual(facts.localBytes, 1_010)
            XCTAssertTrue(facts.bytesAreLowerBound)
            XCTAssertTrue(facts.value(for: .capacity).contains("至少"))
            XCTAssertTrue(facts.value(for: .appsToQuit).contains("Fixture"))
            XCTAssertEqual(facts.recovery, [.trashAndOperationHistory])
            let residual = OperationConfirmationFacts.uninstall(app: app, selected: related, residual: true,
                runningAppNames: [], permission: .verified)
            XCTAssertEqual(residual.actions, [.moveToTrash])
            XCTAssertEqual(residual.itemCount, 2)
        }
    }

    func testFileAnalysisFactsCountBlockedItemsAndNameRunningApps() {
        withLanguage(.zhHans) {
            let review = Self.fileReview(blockedRunning: true)
            let facts = OperationConfirmationFacts.fileAnalysis(review, permission: .unknown)
            XCTAssertEqual(facts.notRunCount, 1)
            XCTAssertEqual(facts.localBytes, 2_048)
            XCTAssertEqual(facts.actions, [.moveToTrash])
            XCTAssertEqual(facts.appsToQuit, ["Editor"])
            XCTAssertTrue(facts.recovery.contains(.otherVolumeTrash))
            XCTAssertTrue(facts.items.contains { $0.detail?.hasPrefix("不会执行：") == true })
        }
    }

    func testBrowserFactsUseRecordsBackupRecoveryAndNoDiskSpace() {
        withLanguage(.zhHans) {
            let facts = OperationConfirmationFacts.browserHistory(directRecordCount: 5, manualRecordCount: 2,
                browsers: ["Chrome", "Safari"], runningBrowsers: ["Chrome"], fullDiskAccessBrowsers: ["Safari"])
            XCTAssertNil(facts.localBytes)
            XCTAssertEqual(facts.actions, [.deleteBrowserHistory, .inBrowserSteps])
            XCTAssertEqual(facts.recovery, [.browserBackup])
            XCTAssertTrue(facts.value(for: .objects).contains("7 条浏览记录"))
            XCTAssertTrue(facts.value(for: .capacity).contains("不涉及磁盘空间"))
            XCTAssertTrue(facts.value(for: .appsToQuit).contains("Chrome"))
            XCTAssertEqual(facts.permission, .missingFullDiskAccess(limitedLocations: ["Safari"]))
            let manualOnly = OperationConfirmationFacts.browserHistory(directRecordCount: 0, manualRecordCount: 2,
                browsers: ["Arc"], runningBrowsers: [], fullDiskAccessBrowsers: [])
            XCTAssertEqual(manualOnly.recovery, [.noChange])
            XCTAssertEqual(manualOnly.permission, .notRequired)
        }
    }

    // MARK: 勾选时提示需退出的应用

    func testRunningOwnerIsNamedWhenTheRowIsChecked() {
        withLanguage(.zhHans) {
            let running = Self.candidate(owner: "Slack", running: true)
            let idle = Self.candidate(owner: "Notes", running: false)
            XCTAssertNil(OperationQuitNotice.text(forSelected: [idle]))
            let notice = OperationQuitNotice.text(forSelected: [running, idle, Self.candidate(owner: "Slack", running: true)])
            XCTAssertEqual(OperationQuitNotice.appNames(forSelected: [running, idle]), ["Slack"])
            XCTAssertTrue(notice?.contains("Slack") == true, notice ?? "")
            XCTAssertTrue(notice?.contains("2 项") == true, notice ?? "")
            XCTAssertTrue(notice?.contains("跳过") == true, notice ?? "")
            let options = CleanupOwnerQuitService.Options(
                quittable: [.init(bundleIdentifier: "a", displayName: "A"), .init(bundleIdentifier: "a2", displayName: "A")],
                manual: [.init(bundleIdentifier: "b", displayName: "B")])
            XCTAssertEqual(OperationQuitNotice.appNames(options), ["A", "B"])
            XCTAssertNil(OperationQuitNotice.text(runningBrowsers: []))
            XCTAssertTrue(OperationQuitNotice.text(runningBrowsers: ["Chrome"])?.contains("Chrome") == true)
        }
    }

    // MARK: 结果行三段说明

    func testRuleExplanationUsesProvenanceAndFallsBackConservatively() {
        withLanguage(.zhHans) {
            var described = Self.candidate(owner: "Claude", running: false)
            described.cleanupImpactText = "工具会重新生成缓存，首次使用可能稍慢或需要联网"
            let explanation = described.ruleExplanation
            XCTAssertEqual(explanation.ownership, "Claude")
            XCTAssertEqual(explanation.impact, "工具会重新生成缓存，首次使用可能稍慢或需要联网")
            XCTAssertFalse(explanation.usesImpactFallback)
            XCTAssertEqual(explanation.preselection, CleanupPreselectionReason.preselected.title)
            XCTAssertEqual(explanation.lines.map(\.title), ["属于", "处理后影响", "预选"])

            var bare = Self.candidate(owner: nil, running: false)
            bare.ownerResolution = .unresolved
            bare.cleanupImpactText = "   "
            let fallback = bare.ruleExplanation
            XCTAssertEqual(fallback.ownership, "未识别所属应用")
            XCTAssertTrue(fallback.usesImpactFallback)
            XCTAssertTrue(fallback.impact.contains("移到废纸篓"))
            for line in fallback.lines { XCTAssertFalse(line.value.isEmpty, line.title) }

            let runningRow = Self.candidate(owner: "Slack", running: true)
            XCTAssertEqual(runningRow.preselectionReason, .ownerRunning)
            XCTAssertEqual(runningRow.ruleExplanation.preselection, "所属应用正在运行，本次不预选")
            XCTAssertEqual(Self.candidate(owner: nil, running: false, risk: .reviewOnly).preselectionReason, .reviewRequired)
            XCTAssertEqual(Self.candidate(owner: nil, running: false, risk: .protected).preselectionReason, .protected)
            let emptyTrash = Self.candidate(owner: nil, running: false, risk: .protected, action: .emptyTrash)
            XCTAssertEqual(emptyTrash.preselectionReason, .permanentDeletion)
            XCTAssertTrue(emptyTrash.ruleExplanation.impact.contains("永久删除"))
            // D82 的中文记录与 D93 的判断同源。
            for row in [described, runningRow, emptyTrash] {
                XCTAssertEqual(row.preselectionExplanationText, row.preselectionReason.title)
            }
        }
        withLanguage(.english) {
            var described = Self.candidate(owner: nil, running: false)
            described.cleanupImpactText = "工具会重新生成缓存"
            let explanation = described.ruleExplanation
            XCTAssertNil(explanation.impact.range(of: Self.cjkPattern, options: .regularExpression), explanation.impact)
            // A recorded note without a translation: generic English, but never "not recorded".
            XCTAssertTrue(explanation.usesImpactFallback)
            XCTAssertFalse(explanation.impact.contains("No specific impact recorded"), explanation.impact)
            XCTAssertTrue(explanation.impact.contains("only moves to the Trash"), explanation.impact)
            described.cleanupImpactText = "工具会重新生成缓存，首次使用可能稍慢或需要联网"
            XCTAssertEqual(described.ruleExplanation.impact,
                           "The tool rebuilds its cache; first use may be slower or need the internet")
            XCTAssertFalse(described.ruleExplanation.usesImpactFallback)
            XCTAssertNil(explanation.summary.range(of: Self.cjkPattern, options: .regularExpression), explanation.summary)
            for reason in CleanupPreselectionReason.allCases {
                XCTAssertNil(reason.title.range(of: Self.cjkPattern, options: .regularExpression), reason.title)
            }
        }
    }

    func testLongNameListsAreAbbreviated() {
        withLanguage(.zhHans) {
            XCTAssertEqual(OperationConfirmationFacts.abbreviatedList(["A", "B"]), "A、B")
            XCTAssertEqual(OperationConfirmationFacts.abbreviatedList(["A", "B", "C", "D"]), "A、B、C 等 4 个")
        }
        withLanguage(.english) {
            XCTAssertEqual(OperationConfirmationFacts.abbreviatedList(["A", "B", "C", "D", "E"]), "A, B, C and 2 more")
        }
    }

    // MARK: 修复轮 1（独立复核 P1／P2）

    /// P1-1 + P1-2：真实的重复文件冻结计划（VerifiedDuplicateCleanPlanBuilder）和执行前检查。
    /// “对象”拆成将执行／不会执行，与表头“检查通过”同数；APFS 克隆只写“最多”。
    func testDuplicatePlanObjectsMatchPreflightAndCapacityIsAnUpperBound() throws {
        try withLanguage(.zhHans) {
            let bundle = try Self.duplicatePlan(count: 3, disposition: .trash)
            let plan = bundle.plan
            let preflight = CleanPreflightReport(planID: plan.id, checkedAt: Date(), items: [
                CleanPreflightItem(planItemID: plan.items[0].id, status: .ready),
                CleanPreflightItem(planItemID: plan.items[1].id, status: .ready),
                CleanPreflightItem(planItemID: plan.items[2].id, status: .skipped(.duplicateContentChanged)),
            ], failure: nil)
            let facts = OperationConfirmationFacts.cleanupPlan(plan, preflight: preflight,
                surface: .inferred(for: plan, session: nil), appsToQuit: [], permission: .verified)
            XCTAssertEqual(facts.surface, .duplicateFiles)
            XCTAssertEqual(facts.readyCount, preflight.readyCount)
            XCTAssertEqual(facts.value(for: .objects), "共 3 项：2 项将执行，1 项不会执行（原因见清单）")
            XCTAssertEqual(facts.trashBytes, 2 * 4_096, "header and panel count only the items that passed")
            XCTAssertTrue(facts.physicalReleaseUnknown)
            let capacity = facts.value(for: .capacity)
            // D178: decimal (was `ByteFormat.string`, binary: "8 KiB").
            XCTAssertEqual(capacity, "本地占用（将执行的 2 项） \(ByteFormat.storageString(8_192))；其中 \(ByteFormat.storageString(8_192)) 移到废纸篓；清空废纸篓后最多释放 \(ByteFormat.storageString(8_192))，可回收量待确认（APFS 克隆或硬链接可能不释放空间）")
            XCTAssertFalse(capacity.contains("至少"), capacity)
            XCTAssertFalse(capacity.contains("清空废纸篓后才释放"), capacity)
            XCTAssertTrue(facts.rows.first { $0.field == .capacity }?.isWarning == true)

            // A preflight of another plan is ignored rather than mixed in.
            let stale = CleanPreflightReport(planID: CleanPlanID(), checkedAt: Date(), items: [
                CleanPreflightItem(planItemID: plan.items[2].id, status: .skipped(.itemMissing)),
            ], failure: nil)
            let fresh = OperationConfirmationFacts.cleanupPlan(plan, preflight: stale, surface: .duplicateFiles,
                                                               appsToQuit: [], permission: .verified)
            XCTAssertEqual(fresh.notRunCount, 0)
            XCTAssertEqual(fresh.value(for: .objects), "3 项")

            // Quarantine frees nothing anyway; no clone wording there.
            let quarantine = try Self.duplicatePlan(count: 1, disposition: .quarantine).plan
            XCTAssertFalse(OperationConfirmationFacts.cleanupPlan(quarantine, preflight: nil, surface: .duplicateFiles,
                appsToQuit: [], permission: .verified).physicalReleaseUnknown)
        }
    }

    /// P1-1 + P1-2：文件分析同样拆分；另有硬链接时写“最多”，不写“至少”。
    func testFileAnalysisFactsSplitObjectsAndHardLinksAreAnUpperBound() {
        withLanguage(.zhHans) {
            var review = Self.fileReview(blockedRunning: false)
            let facts = OperationConfirmationFacts.fileAnalysis(review, permission: .verified)
            XCTAssertEqual(facts.readyCount, review.readyItems.count)
            XCTAssertEqual(facts.value(for: .objects), "共 2 项：1 项将执行，1 项不会执行（原因见清单）")
            XCTAssertFalse(facts.physicalReleaseUnknown)
            // D178: every page writes decimal sizes (was `facts.byteStyle == .storage`,
            // the one page that did).
            XCTAssertFalse(facts.value(for: .capacity).contains("iB"), facts.value(for: .capacity))

            var items = review.items
            items[0].hasOtherHardLinks = true
            review = FileAnalysisTrashReview(items: items)
            let linked = OperationConfirmationFacts.fileAnalysis(review, permission: .verified)
            let capacity = linked.value(for: .capacity)
            XCTAssertFalse(capacity.contains("至少"), capacity)
            XCTAssertTrue(capacity.contains("最多释放 \(ByteFormat.storageString(2_048))"), capacity)
            XCTAssertTrue(capacity.contains("可回收量待确认"), capacity)
        }
    }

    /// P1-2：执行器对已核实的重复文件把可回收量记为未知（nil）；完成页写“最多”。
    /// 文件分析的硬链接同理。
    func testCompletionSaysAtMostWhenReclaimableIsUnknown() {
        withLanguage(.zhHans) {
            let clones = OperationCompletionTally(report: Self.report(
                [("copy", 4_096, .moved(Self.receipt("copy")))], movedDuplicates: true))
            XCTAssertTrue(clones.reclaimableUnknown)
            // D178: decimal (was `ByteFormat.string`, binary: "4 KiB").
            XCTAssertEqual(clones.capacityLines.first,
                "已移到废纸篓 \(ByteFormat.storageString(4_096))（未释放；清空废纸篓后最多释放 \(ByteFormat.storageString(4_096))，可回收量待确认）")
            let plain = OperationCompletionTally(report: Self.report([("cache", 4_096, .moved(Self.receipt("cache")))]))
            XCTAssertFalse(plain.reclaimableUnknown)
            // D178: decimal (was `ByteFormat.string`, binary).
            XCTAssertEqual(plain.capacityLines.first,
                           "已移到废纸篓 \(ByteFormat.storageString(4_096))（未释放，清空废纸篓后才释放）")

            var outcome = FileAnalysisTrashOutcome(
                report: Self.report([("movie.mov", 4_096, .moved(Self.receipt("movie.mov")))]),
                movedPaths: ["/Fixture/movie.mov"], movedBytes: 4_096, skipped: [], notRestorableHereCount: 0,
                externalVolumeNames: [], receiptUnavailable: false, cancelled: false)
            XCTAssertFalse(OperationCompletionTally(fileAnalysis: outcome).reclaimableUnknown)
            outcome.otherHardLinkPaths = ["/Fixture/movie.mov"]
            let linked = OperationCompletionTally(fileAnalysis: outcome)
            XCTAssertTrue(linked.reclaimableUnknown)
            XCTAssertEqual(linked.capacityLines.first,
                "已移到废纸篓 \(ByteFormat.storageString(4_096))（未释放；清空废纸篓后最多释放 \(ByteFormat.storageString(4_096))，可回收量待确认）")
        }
    }

    /// P2-1：同一页一种单位；完成页各行加起来等于“原操作移走体积”。
    func testCompletionLinesReconcileWithOriginallyMovedSizeInThePageUnit() {
        withLanguage(.zhHans) {
            var report = Self.report([
                ("trash", 1_500_000, .moved(Self.receipt("trash"))),
                ("unverified", 50_000, .moved(Self.receipt("unverified", verified: false))),
                ("restored", 400_000, .moved(Self.receipt("restored"))),
            ])
            report.recoveryAttempts = [CleanupRecoveryReport(completedAt: Date(), items: [
                CleanupRecoveryItem(id: UUID(), originalPath: "/Fixture/restored", outcome: .restored),
            ])]
            let tally = OperationCompletionTally(report: report)
            XCTAssertEqual(tally.movedToTrashBytes + tally.movedToQuarantineBytes + tally.unverifiedMovedBytes
                           + tally.restoredBytes, report.summary.movedToRecoverableLocationBytes)
            // D178: decimal, "1.5 MB" (was `ByteFormat.string`, binary: "1.4 MiB").
            XCTAssertEqual(tally.capacityLines, [
                "已移到废纸篓 \(ByteFormat.storageString(1_500_000))（未释放，清空废纸篓后才释放）",
                "另有 \(ByteFormat.storageString(50_000)) 已移动但结果待核实，未计入上面",
                "已恢复到原位置 \(ByteFormat.storageString(400_000))，不再计入",
            ])
            // D178: OperationByteStyle is gone; every page writes decimal sizes
            // (was `.binary` → `ByteFormat.string`, `.storage` → `storageString`),
            // which the lines above check.
        }
    }

    /// P2-2：恢复结果未确认、或恢复回执未保存，归入待核实，不计入已移到废纸篓。
    func testUnconfirmedRestoreNeedsVerification() {
        withLanguage(.zhHans) {
            var report = Self.report([
                ("a", 300, .moved(Self.receipt("a"))), ("b", 200, .moved(Self.receipt("b"))),
            ])
            report.recoveryAttempts = [CleanupRecoveryReport(completedAt: Date(), items: [
                CleanupRecoveryItem(id: UUID(), originalPath: "/Fixture/a", outcome: .outcomeUnknown),
            ])]
            var tally = OperationCompletionTally(report: report)
            XCTAssertEqual(tally.count(.needsVerification), 1)
            XCTAssertEqual(tally.count(.completed), 1)
            XCTAssertEqual(tally.movedToTrashBytes, 200)
            XCTAssertEqual(tally.unverifiedMovedBytes, 300)
            XCTAssertEqual(tally.entries(in: .needsVerification).first?.title, "a")
            XCTAssertEqual(OperationResultPresentation(report: report).state, .needsVerification)

            var unsaved = CleanupRecoveryReport(completedAt: Date(), items: [
                CleanupRecoveryItem(id: UUID(), originalPath: "/Fixture/b", outcome: .failed),
            ])
            unsaved.persistenceFailure = "recovery-final-write-failed"
            report.recoveryAttempts = [unsaved]
            tally = OperationCompletionTally(report: report)
            XCTAssertEqual(tally.count(.needsVerification), 1)
            XCTAssertTrue(tally.receiptIncomplete)
            XCTAssertEqual(tally.movedToTrashBytes, 300)
        }
    }

    /// P2-3：卸载时应用在运行被拒绝，完成页写“跳过（应用正在运行）”，与确认页一致。
    func testUninstallRefusedWhileRunningIsSkippedLikeTheConfirmationSays() {
        withLanguage(.zhHans) {
            let app = Self.app()
            let refused = CleanFailure(code: .trashMoveRejected,
                                       detailCode: UninstallErrorEvidence.codes(AppUninstallError.identityChanged(app.path)))
            let related = "/Fixture/Library/Caches/com.fixture.app"
            let report = Self.report([(app.path, 1_000, .failed(refused)), (related, 10, .failed(refused))])
            let running = OperationCompletionTally(uninstall: report, app: app, appIsRunning: true)
            XCTAssertEqual(running.count(.skipped), 2)
            XCTAssertEqual(running.count(.failed), 0)
            XCTAssertEqual(running.entries(in: .skipped).map(\.detail), ["跳过（应用正在运行）", "跳过（应用正在运行）"])
            XCTAssertEqual(running.entries(in: .skipped).first?.title, app.name)
            let confirmation = OperationConfirmationFacts.uninstall(app: app, selected: [], residual: false,
                runningAppNames: [app.name], permission: .verified)
            XCTAssertTrue(confirmation.value(for: .appsToQuit).contains("跳过"))

            let quit = OperationCompletionTally(uninstall: report, app: app, appIsRunning: false)
            XCTAssertEqual(quit.count(.failed), 2)
            XCTAssertEqual(quit.entries(in: .failed).first?.detail, UninstallPresentation.recordLabel(.changedSinceScan))
        }
    }

    /// P2-4：每条已加载规则登记的中文影响都有英文译文；英文界面不出现中文。
    func testEveryRecordedImpactHasAnEnglishText() throws {
        let rules = try CleanupRuleSetLoader.loadBundled()
        let impacts = Set(rules.rules.compactMap { $0.maintenance?.impact.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        XCTAssertFalse(impacts.isEmpty)
        for impact in impacts {
            let english = try XCTUnwrap(CleanupImpactText.english(for: impact), impact)
            XCTAssertNil(english.range(of: Self.cjkPattern, options: .regularExpression), english)
        }
        withLanguage(.english) {
            var candidate = Self.candidate(owner: "Fixture", running: false)
            for impact in impacts {
                candidate.cleanupImpactText = impact
                XCTAssertEqual(candidate.ruleExplanation.impact, CleanupImpactText.english(for: impact))
            }
        }
    }

    /// P2-5：只选了需在浏览器内处理的记录时，不提示退出浏览器；确认页同口径。
    func testOnlyDirectlyDeletedRecordsAskToQuitTheirBrowser() {
        withLanguage(.zhHans) {
            let chrome = BrowserPrivacyBrowser(id: "chrome", displayName: "Chrome", engine: .chromium,
                                               bundleIdentifier: "com.google.Chrome", version: "1")
            let safari = BrowserPrivacyBrowser(id: "safari", displayName: "Safari", engine: .safari,
                                               bundleIdentifier: "com.apple.Safari", version: "1")
            let direct = Self.browserRecord(chrome, direct: true)
            let manual = Self.browserRecord(safari, direct: false)
            let running: Set<String> = ["chrome", "safari"]
            XCTAssertEqual(OperationQuitNotice.runningBrowserNames(selected: [direct, manual], runningBrowserIDs: running),
                           ["Chrome"])
            XCTAssertEqual(OperationQuitNotice.runningBrowserNames(selected: [manual], runningBrowserIDs: running), [])
            XCTAssertNil(OperationQuitNotice.text(runningBrowsers:
                OperationQuitNotice.runningBrowserNames(selected: [manual], runningBrowserIDs: running)))
            let manualFacts = BrowserPrivacyConfirmationText.facts(records: [manual], runningBrowserIDs: running,
                                                                   fullDiskAccessBrowsers: [])
            XCTAssertEqual(manualFacts.appsToQuit, [])
            XCTAssertEqual(manualFacts.value(for: .appsToQuit), "无需退出应用")
            let mixed = BrowserPrivacyConfirmationText.facts(records: [direct, manual], runningBrowserIDs: running,
                                                             fullDiskAccessBrowsers: [])
            XCTAssertEqual(mixed.appsToQuit, ["Chrome"])
            XCTAssertEqual(mixed.value(for: .objects), "2 条浏览记录（Chrome、Safari）")
        }
    }

    /// P2-6：lightfield 单行详情里 D47 重建代价提示在最前，其后才是“属于 X”。
    func testLightfieldDetailKeepsRebuildCostFirst() {
        withLanguage(.zhHans) {
            XCTAssertEqual(CleanupRuleExplanation.lightfieldDetail(rebuildCost: "下次编译会变慢", ownerStatus: nil,
                                                                   ownership: "Xcode", path: "/Fixture/DerivedData"),
                           "下次编译会变慢 · 属于 Xcode · /Fixture/DerivedData")
            XCTAssertEqual(CleanupRuleExplanation.lightfieldDetail(rebuildCost: nil, ownerStatus: "未识别所属应用",
                                                                   ownership: "未识别所属应用", path: "/Fixture/x"),
                           "未识别所属应用 · 属于 未识别所属应用 · /Fixture/x")
        }
    }

    /// P2-8：智能扫描由会话判断；重复文件优先。
    func testSmartScanSurfaceComesFromTheSession() throws {
        let items = Self.planItems([("cache", 1, .moveToTrash)], ruleID: "developer.go-build")
        XCTAssertEqual(OperationSurface.inferred(for: items, fromSmartScan: true), .smartScan)
        XCTAssertEqual(OperationSurface.inferred(for: items, fromSmartScan: false), .developerTools)
        let duplicate = try Self.duplicatePlan(count: 1, disposition: .trash).plan
        XCTAssertEqual(OperationSurface.inferred(for: duplicate.items, fromSmartScan: true), .duplicateFiles)
        XCTAssertEqual(OperationSurface.inferred(for: duplicate, session: nil), .duplicateFiles)
    }

    /// P2-10（D87）：卸载勾选了含个人资料／含镜像与数据卷的项目时，“对象”字段警示。
    func testUninstallWarnsAboutHighValueRows() {
        for language in [AppLanguage.zhHans, .english] {
            withLanguage(language) {
                let app = Self.app()
                let chrome = InstalledAppRelatedItem(path: "/Users/test/Library/Application Support/Google/Chrome", sizeBytes: 10)
                let docker = InstalledAppRelatedItem(path: "/Users/test/Library/Containers/com.docker.docker", sizeBytes: 20)
                let cache = InstalledAppRelatedItem(path: "/Users/test/Library/Caches/com.fixture.app", sizeBytes: 5)
                let plain = OperationConfirmationFacts.uninstall(app: app, selected: [cache], residual: false,
                    runningAppNames: [], permission: .verified)
                XCTAssertEqual(plain.objectWarnings, [])
                XCTAssertFalse(plain.rows.first { $0.field == .objects }?.isWarning == true)
                let facts = OperationConfirmationFacts.uninstall(app: app, selected: [chrome, docker, cache],
                    residual: false, runningAppNames: [], permission: .verified)
                let objects = facts.value(for: .objects)
                XCTAssertTrue(objects.contains(UninstallVendorRules.HighValueData.personalProfile.title), objects)
                XCTAssertTrue(objects.contains(UninstallVendorRules.HighValueData.imagesAndVolumes.title), objects)
                XCTAssertTrue(facts.rows.first { $0.field == .objects }?.isWarning == true)
                if language == .zhHans {
                    XCTAssertEqual(objects, "4 项；其中 1 项含个人资料，会一并移到废纸篓，请先确认已备份；其中 1 项含镜像与数据卷，会一并移到废纸篓，请先确认已备份")
                } else {
                    XCTAssertNil(objects.range(of: Self.cjkPattern, options: .regularExpression), objects)
                }
            }
        }
    }

    // MARK: 夹具

    /// 中文字符与全角标点；不把 Common 脚本的“·”算作中文。
    static let cjkPattern = "[\\u3000-\\u303F\\u3400-\\u9FFF\\uFF00-\\uFFEF]"

    func withLanguage(_ language: AppLanguage, _ body: () throws -> Void) rethrows {
        let defaults = TestPreferenceDomain.make(for: self)
        defaults.set(language.rawValue, forKey: L10n.languageDefaultsKey)
        let preferences = TestVolatilePreferences()
        preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
        defer { preferences.restore() }
        XCTAssertEqual(L10n.usesChinese, language == .zhHans)
        try body()
    }

    static func identity(_ inode: UInt64) -> FileIdentity {
        FileIdentity(deviceID: 7, inode: inode, entryKind: .directory, creationTimeNanoseconds: 1)
    }

    static func receipt(_ name: String, verified: Bool = true,
                        disposition: CleanupDisposition = .trash) -> CleanupMoveReceipt {
        CleanupMoveReceipt(originalPath: "/Fixture/\(name)",
            resultingItemURL: URL(fileURLWithPath: "/Fixture/.Trash/\(name)"), disposition: disposition,
            movedIdentity: verified ? identity(UInt64(abs(name.hashValue % 10_000)) + 1) : nil,
            verification: verified ? .identityVerified : .destinationMetadataUnavailable, movedAt: Date())
    }

    /// The summary is filled the way `SafeCleanupExecutor` fills it: moved bytes
    /// include unverified moves; reclaimable is nil when moved items were verified
    /// duplicates (APFS clones, `testVerifiedDuplicateTrashReportKeepsPhysicalSavingsUnknown`).
    static func report(_ items: [(String, Int64, CleanItemOutcome)], disposition: CleanupDisposition = .trash,
                       movedDuplicates: Bool = false) -> CleanReport {
        let reportItems = items.map { name, bytes, outcome in
            CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: "system.user-caches",
                            sourcePath: name.hasPrefix("/") ? name : "/Fixture/\(name)", estimatedBytes: bytes, outcome: outcome)
        }
        func count(_ match: (CleanItemOutcome) -> Bool) -> Int { reportItems.filter { match($0.outcome) }.count }
        func bytes(_ match: (CleanItemOutcome) -> Bool) -> Int64 {
            reportItems.filter { match($0.outcome) }.reduce(0) { $0 + max(0, $1.estimatedBytes) }
        }
        let isMoved: (CleanItemOutcome) -> Bool = { if case .moved = $0 { return true }; return false }
        let isDeleted: (CleanItemOutcome) -> Bool = { if case .deleted = $0 { return true }; return false }
        let movedBytes = bytes(isMoved)
        var summary = CleanReportSummary(
            requestedItemCount: items.count, movedItemCount: count(isMoved),
            skippedItemCount: count { if case .skipped = $0 { return true }; return false },
            failedItemCount: count { if case .failed = $0 { return true }; return false },
            notProcessedItemCount: count { $0 == .notProcessed },
            unverifiedMoveCount: count { if case .moved(let r) = $0 { return !r.isRestorable }; return false },
            plannedBytes: items.reduce(0) { $0 + max(0, $1.1) },
            movedToRecoverableLocationBytes: movedBytes,
            reclaimableAfterEmptyingTrashBytes: disposition == .trash ? (movedDuplicates ? nil : movedBytes) : 0,
            permanentlyFreedBytes: bytes(isDeleted), availableSpaceDeltaBytes: nil)
        summary.deletedItemCount = count(isDeleted)
        return CleanReport(id: UUID(), planID: CleanPlanID(), sessionID: ScanSessionID(),
            rulesVersion: "fixture", disposition: disposition, scanWasPartial: false,
            startedAt: Date(), completedAt: Date(), outcome: .partiallyCompleted, items: reportItems,
            summary: summary)
    }

    static func snapshot(_ path: String, bytes: Int64, inode: UInt64) -> FileSnapshot {
        FileSnapshot(identity: identity(inode), standardizedPath: path, volumeIdentifier: "d93-fixture",
            logicalSizeBytes: bytes, allocatedSizeBytes: bytes, modificationTimeNanoseconds: 1,
            isWritableVolume: true, isCloudItem: false, isCloudPlaceholder: false, hasSymbolicLinkComponent: false)
    }

    static func planItems(_ entries: [(String, Int64, CleanupRuleAction)],
                          ruleID: String = "system.user-caches") -> [CleanPlanItem] {
        entries.enumerated().map { index, entry in
            let url = URL(fileURLWithPath: "/Fixture/\(entry.0)")
            return CleanPlanItem(id: UUID(), candidateID: ScanCandidateID(), ruleID: ruleID,
                ruleSelectionPolicyVersion: 1, sourceURL: url, allowedRootURL: url.deletingLastPathComponent(),
                expectedSnapshot: snapshot(url.path, bytes: entry.1, inode: UInt64(index) + 1),
                action: entry.2, riskLevel: entry.2 == .emptyTrash ? .protected : .safe,
                executionEligibility: entry.2 == .emptyTrash ? .eligibleAfterProtectedReview : .eligible,
                measurementCompleteness: .complete, requiredClosedBundleIDs: [], reasonCode: "d93",
                reasonCodes: ["d93"], explicitUserSelection: true, verifiedDuplicateEvidence: nil,
                protectedRetainedCopies: [])
        }
    }

    static func candidate(owner: String?, running: Bool, risk: CleanupRisk = .safe,
                          action: CleanupRuleAction? = nil) -> ScanCandidate {
        let action = action ?? (risk == .safe ? .moveToTrash : risk == .reviewOnly
            ? .moveToTrashAfterReview : .moveToTrashAfterProtectedReview)
        let execution: CleanupExecutionEligibility = switch action {
        case .moveToTrash: .eligible
        case .moveToTrashAfterReview: .eligibleAfterReview
        case .moveToTrashAfterProtectedReview, .emptyTrash: .eligibleAfterProtectedReview
        case .revealOnly: .advisoryOnly
        }
        let url = URL(fileURLWithPath: "/Fixture/\(owner ?? "unknown")-\(UUID().uuidString)")
        var candidate = ScanCandidate(id: ScanCandidateID(), sessionID: ScanSessionID(), ruleID: "d93.fixture",
            ruleSelectionPolicyVersion: 1, categoryID: "d93", categoryTitle: "d93", subcategoryTitle: "d93",
            sourceURL: url, allowedRootURL: url.deletingLastPathComponent(),
            snapshot: snapshot(url.path, bytes: 1_024, inode: 3), risk: risk,
            recommendation: CleanupRecommendation(level: risk == .safe ? .recommended : .notRecommended,
                                                  reasonCode: "d93", evidenceCodes: []),
            defaultSelection: risk == .safe ? .selected : .unselected, executionEligibility: execution,
            measurementCompleteness: .complete, isManuallySelectable: true, action: action,
            requiredClosedBundleIDs: [], reason: "D93 fixture")
        candidate.ruleOwnerDisplayName = owner
        if let owner, running {
            candidate.ownerBundleIdentifiers = ["com.fixture.\(owner)"]
            candidate.runningOwnerBundleIdentifiers = ["com.fixture.\(owner)"]
        }
        return candidate
    }

    static func app() -> InstalledAppItem {
        InstalledAppItem(id: "/Applications/Fixture.app", name: "Fixture", bundleIdentifier: "com.fixture.app",
            path: "/Applications/Fixture.app", version: "1", build: "1", category: "", appDescription: "",
            sizeBytes: 1_000, source: "fixture", modifiedAt: nil, relatedPaths: [], relatedItems: [],
            status: .installed)
    }

    static func fileReview(blockedRunning: Bool) -> FileAnalysisTrashReview {
        func selection(_ name: String, _ bytes: Int64) -> FileAnalysisTrashSelection {
            FileAnalysisTrashSelection(path: "/Volumes/Disk/\(name)", title: name, isDirectory: true,
                                       kind: "folder", bytes: bytes, itemCount: 1)
        }
        return FileAnalysisTrashReview(items: [
            FileAnalysisTrashReviewItem(selection: selection("ready", 2_048), status: .ready(identity(5)),
                                        externalVolumeName: "Disk"),
            FileAnalysisTrashReviewItem(selection: selection("busy", 9_999),
                status: .blocked(blockedRunning ? .containsRunningApplication : .locked), externalVolumeName: nil),
        ], unknownRunningApplicationNames: blockedRunning ? ["Editor"] : [])
    }

    /// 八个页面各一份确认字段；冻结计划的四种页面由 `OperationSurface.inferred` 判断。
    static func allPageFacts() throws -> [OperationConfirmationFacts] {
        let browser = OperationConfirmationFacts.browserHistory(directRecordCount: 3, manualRecordCount: 0,
            browsers: ["Chrome"], runningBrowsers: [], fullDiskAccessBrowsers: [])
        let duplicate = try duplicatePlan(count: 1, disposition: .trash).plan
        let plans: [([CleanPlanItem], Bool)] = [
            (planItems([("cache", 4_096, .moveToTrash)]), false),
            (planItems([("go", 4_096, .moveToTrash)], ruleID: "developer.go-build"), false),
            (planItems([("cache", 4_096, .moveToTrash)]), true),
            (duplicate.items, false),
        ]
        return plans.map { items, fromSmartScan in
            OperationConfirmationFacts.cleanupPlanItems(items, disposition: .trash, skipped: [:],
                surface: .inferred(for: items, fromSmartScan: fromSmartScan), appsToQuit: [], permission: .unknown)
        } + [
            .uninstall(app: app(), selected: [], residual: false, runningAppNames: ["Fixture"], permission: .verified),
            .fileAnalysis(fileReview(blockedRunning: false), permission: .missingFullDiskAccess(limitedLocations: ["Documents"])),
            browser,
            .emptyTrash(FrozenTrash.testFixture(names: ["Old Report.pdf"])),
        ]
    }

    /// A real frozen duplicate plan (`VerifiedDuplicateCleanPlanBuilder`), 4 KiB per copy.
    static func duplicatePlan(count: Int, disposition: CleanupDisposition) throws -> VerifiedDuplicatePlanBundle {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let root = home.appendingPathComponent("Documents", isDirectory: true)
        func duplicateSnapshot(_ url: URL, inode: UInt64) -> FileSnapshot {
            FileSnapshot(identity: FileIdentity(deviceID: 51, inode: inode, entryKind: .regularFile,
                                                creationTimeNanoseconds: Int64(inode)),
                standardizedPath: url.path, volumeIdentifier: "d93-duplicate-fixture", logicalSizeBytes: 4_096,
                allocatedSizeBytes: 4_096, modificationTimeNanoseconds: 100, isWritableVolume: true,
                isCloudItem: false, isCloudPlaceholder: false, hasSymbolicLinkComponent: false)
        }
        let retained = root.appendingPathComponent("Original/Report.pdf")
        let retainedCopy = VerifiedDuplicateRetainedCopy(url: retained, expectedSnapshot: duplicateSnapshot(retained, inode: 900))
        let requests = (0..<count).map { index -> VerifiedDuplicatePlanRequest in
            let url = root.appendingPathComponent("Copy\(index)/Report.pdf")
            return VerifiedDuplicatePlanRequest(sourceURL: url, allowedRootURL: root,
                expectedSnapshot: duplicateSnapshot(url, inode: 100 + UInt64(index)), groupID: "sha256:report",
                digest: Data(repeating: 0xA1, count: 32), retainedCopies: [retainedCopy])
        }
        let bundle = try VerifiedDuplicateCleanPlanBuilder.makePlan(requests: requests, disposition: disposition,
                                                                     userHomeURL: home)
        // Plan order follows the requests so tests can address items by index.
        precondition(bundle.plan.items.map(\.sourceURL) == requests.map(\.sourceURL))
        return bundle
    }

    static func browserRecord(_ browser: BrowserPrivacyBrowser, direct: Bool) -> BrowserPrivacyRecord {
        let url = "https://example.com/\(browser.id)"
        let root = URL(fileURLWithPath: "/tmp/d93-browser-fixture", isDirectory: true)
        return BrowserPrivacyRecord(
            id: UUID(), browser: browser, profileID: "\(browser.id):Default", source: .history,
            url: url, domain: "example.com", title: nil, searchKeyword: nil,
            visitedAt: Date(timeIntervalSince1970: 1_750_000_000), visitCount: 1, category: .other,
            selectionConfidence: .medium, sizeBytes: nil,
            locator: direct ? BrowserPrivacyRecordLocator(
                providerID: browser.id, profileID: "\(browser.id):Default", engine: browser.engine,
                visitRowID: 7, parentRowID: 1, visitTimestampIdentity: .integer(1), rawURL: url,
                databaseURL: root.appendingPathComponent("History"), trustedParentURL: root,
                identityChain: [.init(device: 1, inode: 1, kind: 0o100000)]) : nil)
    }
}
