import XCTest
@testable import StorageCleanerMac

final class CleanupHistoryServiceTests: XCTestCase {
    private let gib: Int64 = 1_073_741_824
    private let testTrashIdentity = TrashItemIdentity(
        deviceID: 7,
        fileID: 42,
        objectType: 0x8000,
        birthTimeSeconds: 100,
        birthTimeNanoseconds: 200
    )
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "CleanupHistoryServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRecordMovedItemsStoresSummary() throws {
        let item = makeItem(title: "Example Cache", path: "~/Library/Caches/example", sizeBytes: 2048)

        CleanupHistoryService.recordMovedItems([item], date: Date(timeIntervalSince1970: 100), defaults: defaults)

        let summary = CleanupHistoryService.summary(defaults: defaults)
        XCTAssertEqual(summary.totalCount, 1)
        XCTAssertEqual(summary.totalBytes, 2048)
        XCTAssertEqual(summary.latest?.title, "Example Cache")
        XCTAssertEqual(summary.latest?.paths, ["~/Library/Caches/example"])
        XCTAssertEqual(summary.latest?.moveRecords, [])
    }

    func testRecordMovedItemsStoresMatchingMoveRecords() throws {
        let item = makeItem(title: "Example Cache", path: "~/Library/Caches/example", sizeBytes: 2048)
        let record = TrashMoveRecord(
            originalPath: PathSafety.lexicalPath(item.path),
            resultingItemURL: CleanupService.userTrashURL().appendingPathComponent("example"),
            itemIdentity: testTrashIdentity
        )

        CleanupHistoryService.recordMovedItems(
            [item],
            moveRecords: [record],
            date: Date(timeIntervalSince1970: 100),
            defaults: defaults
        )

        let latest = try XCTUnwrap(CleanupHistoryService.summary(defaults: defaults).latest)
        XCTAssertEqual(latest.moveRecords, [record])
    }

    func testRecordMovedItemsRejectsUnrelatedMoveRecords() throws {
        let item = makeItem(title: "Example Cache", path: "~/Library/Caches/example", sizeBytes: 2048)
        let unrelatedRecord = TrashMoveRecord(
            originalPath: PathSafety.lexicalPath("~/Library/Caches/other"),
            resultingItemURL: CleanupService.userTrashURL().appendingPathComponent("other"),
            itemIdentity: testTrashIdentity
        )

        CleanupHistoryService.recordMovedItems(
            [item],
            moveRecords: [unrelatedRecord],
            defaults: defaults
        )

        let latest = try XCTUnwrap(CleanupHistoryService.summary(defaults: defaults).latest)
        XCTAssertTrue(latest.moveRecords.isEmpty)
    }

    func testCleanupHistoryDecodesLegacyEntryWithoutMoveRecords() throws {
        struct LegacyCleanupHistoryEntry: Codable {
            let id: UUID
            let date: Date
            let title: String
            let itemCount: Int
            let totalBytes: Int64
            let paths: [String]
        }

        let legacyEntry = LegacyCleanupHistoryEntry(
            id: UUID(),
            date: Date(timeIntervalSince1970: 100),
            title: "Legacy cleanup",
            itemCount: 1,
            totalBytes: 2048,
            paths: ["~/Library/Caches/legacy"]
        )
        defaults.set(
            try JSONEncoder().encode([legacyEntry]),
            forKey: CleanupHistoryService.defaultsKey
        )

        let latest = try XCTUnwrap(CleanupHistoryService.load(defaults: defaults).first)
        XCTAssertEqual(latest.id, legacyEntry.id)
        XCTAssertEqual(latest.paths, legacyEntry.paths)
        XCTAssertTrue(latest.moveRecords.isEmpty)
    }

    func testCleanupHistoryRoundTripsMoveRecords() throws {
        let record = TrashMoveRecord(
            id: UUID(),
            originalPath: PathSafety.lexicalPath("~/Library/Caches/example"),
            resultingItemURL: CleanupService.userTrashURL().appendingPathComponent("example"),
            itemIdentity: testTrashIdentity,
            movedAt: Date(timeIntervalSince1970: 90)
        )
        let entry = CleanupHistoryEntry(
            id: UUID(),
            date: Date(timeIntervalSince1970: 100),
            title: "Example Cache",
            itemCount: 1,
            totalBytes: 2048,
            paths: ["~/Library/Caches/example"],
            moveRecords: [record]
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(CleanupHistoryEntry.self, from: data)

        XCTAssertEqual(decoded, entry)
    }

    func testLatestRestorableSkipsNewerLegacyRecord() throws {
        let restorableItem = makeItem(title: "Restorable", path: "~/Library/Caches/restorable", sizeBytes: 100)
        let record = TrashMoveRecord(
            originalPath: PathSafety.lexicalPath(restorableItem.path),
            resultingItemURL: CleanupService.userTrashURL().appendingPathComponent("restorable"),
            itemIdentity: testTrashIdentity
        )
        CleanupHistoryService.recordMovedItems(
            [restorableItem],
            moveRecords: [record],
            date: Date(timeIntervalSince1970: 100),
            defaults: defaults
        )
        CleanupHistoryService.recordMovedItems(
            [makeItem(title: "Legacy", path: "~/Library/Caches/legacy", sizeBytes: 100)],
            date: Date(timeIntervalSince1970: 200),
            defaults: defaults
        )

        let summary = CleanupHistoryService.summary(defaults: defaults)
        XCTAssertEqual(summary.latest?.title, "Legacy")
        XCTAssertEqual(summary.latestRestorable?.title, "Restorable")
        XCTAssertEqual(summary.latestRestorable?.moveRecords, [record])
    }

    func testRemoveMoveRecordsConsumesOnlyCompletedRestoreRecords() throws {
        let item = makeItem(title: "Batch", path: "~/Library/Caches/batch", sizeBytes: 100)
        let first = TrashMoveRecord(
            originalPath: PathSafety.lexicalPath(item.path),
            resultingItemURL: CleanupService.userTrashURL().appendingPathComponent("batch-a"),
            itemIdentity: testTrashIdentity
        )
        let second = TrashMoveRecord(
            originalPath: PathSafety.lexicalPath(item.path),
            resultingItemURL: CleanupService.userTrashURL().appendingPathComponent("batch-b"),
            itemIdentity: testTrashIdentity
        )
        CleanupHistoryService.recordMovedItems(
            [item],
            moveRecords: [first, second],
            defaults: defaults
        )
        let entry = try XCTUnwrap(CleanupHistoryService.summary(defaults: defaults).latestRestorable)

        CleanupHistoryService.removeMoveRecords(
            entryID: entry.id,
            recordIDs: [first.id],
            defaults: defaults
        )

        XCTAssertEqual(CleanupHistoryService.summary(defaults: defaults).latestRestorable?.moveRecords, [second])
    }

    func testLegacyMoveRecordWithoutIdentityIsNotOfferedForRestore() throws {
        struct LegacyMoveRecord: Codable {
            let id: UUID
            let originalPath: String
            let resultingItemURL: URL
            let movedAt: Date
        }

        let legacy = LegacyMoveRecord(
            id: UUID(),
            originalPath: PathSafety.lexicalPath("~/Library/Caches/legacy"),
            resultingItemURL: CleanupService.userTrashURL().appendingPathComponent("legacy"),
            movedAt: Date(timeIntervalSince1970: 90)
        )
        let decoded = try JSONDecoder().decode(
            TrashMoveRecord.self,
            from: JSONEncoder().encode(legacy)
        )
        XCTAssertNil(decoded.itemIdentity)

        let entry = CleanupHistoryEntry(
            date: Date(timeIntervalSince1970: 100),
            title: "Legacy beta cleanup",
            itemCount: 1,
            totalBytes: 100,
            paths: [decoded.originalPath],
            moveRecords: [decoded]
        )
        XCTAssertNil(CleanupHistorySummary(entries: [entry]).latestRestorable)
    }

    func testScanResultMarksMovedItemAvailableOnlyAfterEveryPathIsRestored() throws {
        let firstPath = "~/Library/Caches/example-a"
        let secondPath = "~/Library/Caches/example-b"
        let item = StorageItem(
            id: "multi-path",
            title: "Multi Path",
            path: firstPath,
            groupTitle: "Test",
            sizeBytes: 100,
            tier: .green,
            kind: "Cache",
            reason: "Test",
            recommendation: "Test",
            risk: "Test",
            requiresClose: "None",
            trashPaths: [firstPath, secondPath],
            openPath: firstPath,
            status: .movedToTrash
        )
        var result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 500,
            freeBytes: 500,
            items: [item]
        )

        result.markRestoredFromTrash(paths: [firstPath])
        XCTAssertEqual(result.items.first?.status, .movedToTrash)

        result.markRestoredFromTrash(paths: [firstPath, secondPath])
        XCTAssertEqual(result.items.first?.status, .available)
    }

    func testRecordMultipleItemsCreatesBatchEntry() {
        let items = [
            makeItem(title: "One", path: "~/Library/Caches/one", sizeBytes: 1024),
            makeItem(title: "Two", path: "~/Library/Caches/two", sizeBytes: 2048)
        ]

        CleanupHistoryService.recordMovedItems(items, defaults: defaults)

        let summary = CleanupHistoryService.summary(defaults: defaults)
        XCTAssertEqual(summary.totalCount, 2)
        XCTAssertEqual(summary.totalBytes, 3072)
        XCTAssertEqual(summary.latest?.itemCount, 2)
    }

    func testCleanupHistoryMarkdownIncludesSafetyBoundaryAndAllPaths() {
        let entry = CleanupHistoryEntry(
            date: Date(timeIntervalSince1970: 100),
            title: "Green cache cleanup",
            itemCount: 4,
            totalBytes: 4096,
            paths: [
                "~/Library/Caches/one",
                "~/Library/Caches/two",
                "~/Library/Caches/three",
                "~/Library/Caches/four"
            ]
        )

        let markdown = CleanupHistoryService.markdown(for: entry)

        XCTAssertTrue(markdown.contains("Green cache cleanup"))
        XCTAssertTrue(markdown.contains("4 KiB"))
        XCTAssertTrue(markdown.contains("废纸篓") || markdown.contains("Trash"))
        XCTAssertTrue(markdown.contains("~/Library/Caches/one"))
        XCTAssertTrue(markdown.contains("~/Library/Caches/two"))
        XCTAssertTrue(markdown.contains("~/Library/Caches/three"))
        XCTAssertTrue(markdown.contains("~/Library/Caches/four"))
    }

    func testClearRemovesHistory() {
        CleanupHistoryService.recordMovedItems([makeItem(title: "Example", path: "~/Library/Caches/example", sizeBytes: 1)], defaults: defaults)

        CleanupHistoryService.clear(defaults: defaults)

        XCTAssertTrue(CleanupHistoryService.load(defaults: defaults).isEmpty)
    }

    func testCleanupHistoryIsIntegratedIntoAutoCleanNavigation() {
        XCTAssertFalse(ReviewFilter.cleanupCases.map(\.rawValue).contains("cleanupHistory"))
        XCTAssertNil(ReviewFilter(rawValue: "cleanupHistory"))
        XCTAssertEqual(ReviewFilter.resolvedDestination(rawValue: "cleanupHistory"), .green)
    }

    func testScanHistoryRecordsScanSummary() {
        let result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 700,
            freeBytes: 300,
            items: [
                makeItem(title: "Cache", path: "~/Library/Caches/example", sizeBytes: 100, tier: .green),
                makeItem(title: "Downloads", path: "~/Downloads/archive.zip", sizeBytes: 200, tier: .yellow),
                makeItem(title: "App", path: "/Applications/App.app", sizeBytes: 300, tier: .red)
            ],
            deniedPaths: ["~/Documents"]
        )

        ScanHistoryService.record(result, defaults: defaults)

        let summary = ScanHistoryService.summary(defaults: defaults)
        XCTAssertEqual(summary.entries.count, 1)
        XCTAssertEqual(summary.latest?.diskUsedBytes, 700)
        XCTAssertEqual(summary.latest?.diskFreeBytes, 300)
        XCTAssertEqual(summary.latest?.greenBytes, 100)
        XCTAssertEqual(summary.latest?.yellowBytes, 200)
        XCTAssertEqual(summary.latest?.redBytes, 300)
        XCTAssertEqual(summary.latest?.deniedCount, 1)
        XCTAssertEqual(summary.latest?.itemCount, 3)
        XCTAssertEqual(summary.latest?.scanMode, .standard)
        XCTAssertEqual(summary.latest?.permissionPenalty, 6)
        XCTAssertEqual(summary.latest?.scoreModelVersion, ScanHistoryService.currentScoreModelVersion)
        XCTAssertEqual(summary.latest?.actionableGreenBytes, 100)
        XCTAssertEqual(summary.latest?.actionableGreenCount, 1)
        XCTAssertEqual(summary.latest?.scanWasLimited, false)
        XCTAssertEqual(summary.latest?.score, ScanHistoryService.scoreBreakdown(for: result).score)
    }

    func testScanHistoryToleratesLegacyQuickScanModeWhenReloaded() throws {
        struct LegacyEntry: Codable {
            let id: UUID
            let date: Date
            let scanSeconds: TimeInterval
            let score: Int
            let diskUsedBytes: Int64
            let diskFreeBytes: Int64
            let greenBytes: Int64
            let yellowBytes: Int64
            let redBytes: Int64
            let itemCount: Int
            let greenCount: Int
            let yellowCount: Int
            let redCount: Int
            let deniedCount: Int
            let scanMode: String
            let permissionPenalty: Int?
        }

        let legacyEntry = LegacyEntry(
            id: UUID(),
            date: Date(timeIntervalSince1970: 100),
            scanSeconds: 1.2,
            score: 90,
            diskUsedBytes: 500,
            diskFreeBytes: 500,
            greenBytes: 0,
            yellowBytes: 0,
            redBytes: 0,
            itemCount: 0,
            greenCount: 0,
            yellowCount: 0,
            redCount: 0,
            deniedCount: 0,
            scanMode: "quick",
            permissionPenalty: nil
        )
        let data = try JSONEncoder().encode([legacyEntry])
        defaults.set(data, forKey: ScanHistoryService.defaultsKey)

        let latest = ScanHistoryService.summary(defaults: defaults).latest
        XCTAssertNil(latest?.scanMode)
        XCTAssertNil(latest?.scoreModelVersion)
        XCTAssertFalse(latest?.usesCurrentScoreModel == true)
        XCTAssertEqual(latest?.score, 90)
    }

    func testScanHistoryPreservesHighImpactPermissionPenaltyWhenReloaded() {
        let result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 500,
            freeBytes: 500,
            deniedPaths: ["~/Downloads"]
        )
        let breakdown = ScanHistoryService.scoreBreakdown(for: result)

        ScanHistoryService.record(result, defaults: defaults)

        let latest = ScanHistoryService.summary(defaults: defaults).latest
        XCTAssertEqual(breakdown.permissionPenalty, 6)
        XCTAssertEqual(latest?.permissionPenalty, 6)
        XCTAssertEqual(latest?.score, breakdown.score)
    }

    func testScanHistoryTracksLatestDelta() {
        let first = makeScanResult(date: Date(timeIntervalSince1970: 100), usedBytes: 800, freeBytes: 200)
        let second = makeScanResult(date: Date(timeIntervalSince1970: 200), usedBytes: 650, freeBytes: 350)

        ScanHistoryService.record(first, defaults: defaults)
        ScanHistoryService.record(second, defaults: defaults)

        let summary = ScanHistoryService.summary(defaults: defaults)
        XCTAssertEqual(summary.latest?.diskUsedBytes, 650)
        XCTAssertEqual(summary.previous?.diskUsedBytes, 800)
        XCTAssertEqual(summary.usedDeltaBytes, -150)
    }

    func testScanHistoryBuildsTrendAcrossScoreSpaceReviewAndPermissions() throws {
        let first = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 900,
            freeBytes: 100,
            items: [
                makeItem(title: "Old Review", path: "~/Downloads/old.zip", sizeBytes: 120, tier: .yellow),
                makeItem(title: "Old App", path: "/Applications/Old.app", sizeBytes: 80, tier: .red)
            ],
            deniedPaths: ["~/Downloads", "~/Documents"]
        )
        let second = makeScanResult(
            date: Date(timeIntervalSince1970: 200),
            usedBytes: 650,
            freeBytes: 350,
            items: [
                makeItem(title: "Fresh Cache", path: "~/Library/Caches/fresh", sizeBytes: 30, tier: .green),
                makeItem(title: "Small Review", path: "~/Downloads/small.zip", sizeBytes: 20, tier: .yellow)
            ]
        )

        ScanHistoryService.record(first, defaults: defaults)
        ScanHistoryService.record(second, defaults: defaults)

        let trend = try XCTUnwrap(ScanHistoryService.summary(defaults: defaults).trend)
        XCTAssertGreaterThan(trend.scoreDelta, 0)
        XCTAssertEqual(trend.usedDeltaBytes, -250)
        XCTAssertEqual(trend.greenDeltaBytes, 30)
        XCTAssertEqual(trend.reviewDeltaBytes, -180)
        XCTAssertEqual(trend.deniedDelta, -2)
    }

    func testLatestScanStatusMarksFreshCompleteScanCurrent() throws {
        let date = Date(timeIntervalSince1970: 100)
        let result = makeScanResult(date: date, usedBytes: 650, freeBytes: 350)

        ScanHistoryService.record(result, defaults: defaults)

        let status = try XCTUnwrap(
            ScanHistoryService.summary(defaults: defaults)
                .latestStatus(referenceDate: date.addingTimeInterval(30 * 60))
        )

        XCTAssertEqual(status.attentionLevel, .current)
        XCTAssertFalse(status.shouldRescan)
        XCTAssertEqual(status.recommendedAction, .reviewResult)
        XCTAssertEqual(status.reviewBytes, 0)
    }

    func testLatestScanStatusPrioritizesPermissionGapsOverFreshness() throws {
        let date = Date(timeIntervalSince1970: 100)
        let result = makeScanResult(
            date: date,
            usedBytes: 650,
            freeBytes: 350,
            deniedPaths: ["~/Downloads"]
        )

        ScanHistoryService.record(result, defaults: defaults)

        let status = try XCTUnwrap(
            ScanHistoryService.summary(defaults: defaults)
                .latestStatus(referenceDate: date.addingTimeInterval(20 * 60))
        )

        XCTAssertEqual(status.attentionLevel, .permissionLimited)
        XCTAssertTrue(status.shouldRescan)
        XCTAssertEqual(status.recommendedAction, .repairAccess)
    }

    func testLatestScanStatusRecommendsRescanForOldCompleteScan() throws {
        let date = Date(timeIntervalSince1970: 100)
        let result = makeScanResult(date: date, usedBytes: 650, freeBytes: 350)

        ScanHistoryService.record(result, defaults: defaults)

        let status = try XCTUnwrap(
            ScanHistoryService.summary(defaults: defaults)
                .latestStatus(referenceDate: date.addingTimeInterval(3 * 60 * 60))
        )

        XCTAssertEqual(status.attentionLevel, .rescanRecommended)
        XCTAssertTrue(status.shouldRescan)
        XCTAssertEqual(status.recommendedAction, .rescan)
    }

    func testLatestScanStatusRecommendsRescanForFreshTimeLimitedScan() throws {
        let date = Date(timeIntervalSince1970: 100)
        let result = makeScanResult(
            date: date,
            scanSeconds: ScanMode.standard.maxScanSeconds,
            scanWasLimited: true,
            usedBytes: 650,
            freeBytes: 350
        )

        ScanHistoryService.record(result, defaults: defaults)

        let status = try XCTUnwrap(
            ScanHistoryService.summary(defaults: defaults)
                .latestStatus(referenceDate: date.addingTimeInterval(20 * 60))
        )

        XCTAssertEqual(status.attentionLevel, .rescanRecommended)
        XCTAssertTrue(status.shouldRescan)
        XCTAssertEqual(status.recommendedAction, .rescan)
    }

    func testScanHistoryDataIsIntegratedWithoutStandaloneNavigation() throws {
        XCTAssertNil(ReviewFilter(rawValue: "scanHistory"))

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contentSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/ContentView.swift"),
            encoding: .utf8
        )
        let overviewSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/OverviewView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/ScanHistoryView.swift").path))
        XCTAssertFalse(contentSource.contains("ScanHistoryView"))
        XCTAssertFalse(contentSource.contains("selection = .scanHistory"))
        XCTAssertFalse(overviewSource.contains("selection = .scanHistory"))
        XCTAssertTrue(contentSource.contains("scanHistorySummary.latestStatus()"))
    }

    func testLegacyCleanupAndReviewPagesAreIntegratedIntoAutoCleanNavigation() {
        let visibleSidebarFilters = ReviewFilter.careCases + ReviewFilter.cleanupCases + ReviewFilter.utilityCases
        XCTAssertEqual(visibleSidebarFilters, [.overview, .healthHub, .performance, .green, .privacy, .devCaches, .largeFiles, .duplicates, .utilityHub])
        XCTAssertFalse(visibleSidebarFilters.map(\.rawValue).contains("yellow"))
        XCTAssertFalse(visibleSidebarFilters.map(\.rawValue).contains("red"))
        XCTAssertTrue(visibleSidebarFilters.map(\.rawValue).contains("privacy"))
        XCTAssertFalse(visibleSidebarFilters.map(\.rawValue).contains("trashBins"))
        XCTAssertFalse(visibleSidebarFilters.map(\.rawValue).contains("all"))
        XCTAssertFalse(visibleSidebarFilters.contains(.startup))
        XCTAssertFalse(visibleSidebarFilters.contains(.memory))
        XCTAssertFalse(visibleSidebarFilters.contains(.energy))
        XCTAssertFalse(visibleSidebarFilters.contains(.uninstall))
        XCTAssertFalse(visibleSidebarFilters.contains(.updater))
        XCTAssertNil(ReviewFilter(rawValue: "yellow"))
        XCTAssertNil(ReviewFilter(rawValue: "red"))
        XCTAssertNil(ReviewFilter(rawValue: "all"))
        XCTAssertEqual(ReviewFilter(rawValue: "privacy"), .privacy)
        XCTAssertNil(ReviewFilter(rawValue: "trashBins"))
        XCTAssertEqual(ReviewFilter.resolvedDestination(rawValue: "yellow"), .green)
        XCTAssertEqual(ReviewFilter.resolvedDestination(rawValue: "red"), .green)
        XCTAssertEqual(ReviewFilter.resolvedDestination(rawValue: "all"), .green)
        XCTAssertEqual(ReviewFilter.resolvedDestination(rawValue: "privacy"), .privacy)
        XCTAssertEqual(ReviewFilter.resolvedDestination(rawValue: "trashBins"), .green)
        XCTAssertEqual(ReviewFilter.startup.sidebarDestination, .utilityHub)
        XCTAssertEqual(ReviewFilter.memory.sidebarDestination, .utilityHub)
        XCTAssertEqual(ReviewFilter.energy.sidebarDestination, .utilityHub)
        XCTAssertEqual(ReviewFilter.uninstall.sidebarDestination, .utilityHub)
        XCTAssertEqual(ReviewFilter.updater.sidebarDestination, .utilityHub)

        let result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 700,
            freeBytes: 300,
            items: [
                makeItem(title: "Download", path: "~/Downloads/archive.zip", sizeBytes: 200, tier: .yellow),
                makeItem(title: "Xcode", path: "/Applications/Xcode.app", sizeBytes: 300, tier: .red)
            ]
        )

        XCTAssertEqual(result.items(forTier: .yellow).map(\.title), ["Download"])
        XCTAssertEqual(result.items(forTier: .red).map(\.title), ["Xcode"])
    }

    func testHealthyStorageWithSmallCacheAndLargeReviewItemsCanReachPerfectScore() {
        let items = [
            makeItem(title: "Small Cache", path: "~/Library/Caches/example", sizeBytes: 2 * gib, tier: .green),
            makeItem(title: "Large Download", path: "~/Downloads/archive.zip", sizeBytes: 180 * gib, tier: .yellow),
            makeItem(title: "Large App", path: "/Applications/Studio.app", sizeBytes: 120 * gib, tier: .red)
        ]
        let result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 700 * gib,
            freeBytes: 300 * gib,
            items: items
        )

        let breakdown = ScanHistoryService.scoreBreakdown(for: result)

        XCTAssertEqual(breakdown.actionableGreenBytes, 2 * gib)
        XCTAssertEqual(breakdown.cleanupBacklogPenalty, 0)
        XCTAssertEqual(breakdown.healthPenalty, 0)
        XCTAssertEqual(breakdown.totalPenalty, 0)
        XCTAssertEqual(breakdown.score, 100)
        XCTAssertEqual(breakdown.band, .excellent)
    }

    func testSmartScoreCanReachPerfectWhenThereAreNoPenalties() {
        let result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 0,
            freeBytes: 1000,
            items: []
        )

        let breakdown = ScanHistoryService.scoreBreakdown(for: result)

        XCTAssertEqual(breakdown.totalPenalty, 0)
        XCTAssertEqual(breakdown.score, 100)
    }

    func testSmartScoreDoesNotPenalizeHealthyStorageHeadroom() {
        let result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 850 * gib,
            freeBytes: 150 * gib,
            items: []
        )

        let breakdown = ScanHistoryService.scoreBreakdown(for: result)

        XCTAssertEqual(breakdown.diskPressurePenalty, 0)
        XCTAssertEqual(breakdown.totalPenalty, 0)
        XCTAssertEqual(breakdown.score, 100)
    }

    func testYellowAndRedReviewContentDoesNotChangeStorageScore() {
        let baseline = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 700 * gib,
            freeBytes: 300 * gib,
            items: []
        )
        let withReviewContent = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 700 * gib,
            freeBytes: 300 * gib,
            items: [
                makeItem(title: "Archive", path: "~/Downloads/archive.zip", sizeBytes: 200 * gib, tier: .yellow),
                makeItem(title: "Studio", path: "/Applications/Studio.app", sizeBytes: 100 * gib, tier: .red)
            ]
        )

        let baselineBreakdown = ScanHistoryService.scoreBreakdown(for: baseline)
        let reviewBreakdown = ScanHistoryService.scoreBreakdown(for: withReviewContent)

        XCTAssertEqual(reviewBreakdown.yellowBytes, 200 * gib)
        XCTAssertEqual(reviewBreakdown.redBytes, 100 * gib)
        XCTAssertEqual(reviewBreakdown.healthPenalty, baselineBreakdown.healthPenalty)
        XCTAssertEqual(reviewBreakdown.totalPenalty, baselineBreakdown.totalPenalty)
        XCTAssertEqual(reviewBreakdown.score, baselineBreakdown.score)
    }

    func testActionableCleanupBacklogCreatesUsefulScoreSeparation() {
        func result(actionableBytes: Int64) -> ScanResult {
            makeScanResult(
                date: Date(timeIntervalSince1970: 100),
                usedBytes: 700 * gib,
                freeBytes: 300 * gib,
                items: [
                    makeItem(
                        title: "Cache",
                        path: "~/Library/Caches/example",
                        sizeBytes: actionableBytes,
                        tier: .green
                    )
                ]
            )
        }

        let small = ScanHistoryService.scoreBreakdown(for: result(actionableBytes: 2 * gib))
        let medium = ScanHistoryService.scoreBreakdown(for: result(actionableBytes: 8 * gib))
        let large = ScanHistoryService.scoreBreakdown(for: result(actionableBytes: 30 * gib))

        XCTAssertEqual(small.cleanupBacklogPenalty, 0)
        XCTAssertEqual(medium.cleanupBacklogPenalty, 4)
        XCTAssertEqual(large.cleanupBacklogPenalty, 20)
        XCTAssertEqual([small.score, medium.score, large.score], [100, 96, 80])
        XCTAssertGreaterThan(small.score - large.score, 15)
    }

    func testDiskHeadroomUsesDistinctPressureGrades() {
        func penalty(usedGiB: Int64, freeGiB: Int64) -> Int {
            let result = makeScanResult(
                date: Date(timeIntervalSince1970: 100),
                usedBytes: usedGiB * gib,
                freeBytes: freeGiB * gib,
                items: []
            )
            return ScanHistoryService.scoreBreakdown(for: result).diskPressurePenalty
        }

        XCTAssertEqual(penalty(usedGiB: 850, freeGiB: 150), 0)
        XCTAssertEqual(penalty(usedGiB: 936, freeGiB: 64), 0)
        XCTAssertEqual(penalty(usedGiB: 950, freeGiB: 50), 7)
        XCTAssertEqual(penalty(usedGiB: 980, freeGiB: 20), 32)
        XCTAssertEqual(penalty(usedGiB: 996, freeGiB: 4), 54)
    }

    func testCleanupProjectionOnlyCountsMoveableAvailableGreenItems() {
        let result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 820 * gib,
            freeBytes: 180 * gib,
            items: [
                makeItem(title: "Moveable Cache", path: "~/Library/Caches/moveable", sizeBytes: 12 * gib, tier: .green),
                makeItem(title: "Already Cleaned", path: "~/Library/Caches/old", sizeBytes: 7 * gib, tier: .green, status: .movedToTrash),
                makeItem(title: "Review File", path: "~/Downloads/review.zip", sizeBytes: 120 * gib, tier: .yellow)
            ]
        )

        let projection = ScanHistoryService.cleanupProjection(for: result)

        XCTAssertEqual(projection.cleanableCount, 1)
        XCTAssertEqual(projection.cleanableBytes, 12 * gib)
        XCTAssertEqual(projection.current.greenBytes, 12 * gib)
        XCTAssertEqual(projection.projected.greenBytes, 0)
        XCTAssertEqual(projection.current.diskUsedBytes, projection.projected.diskUsedBytes)
        XCTAssertGreaterThan(projection.scoreDelta, 0)
        XCTAssertEqual(projection.cleanupPenaltyDelta, projection.current.cleanupBacklogPenalty)
    }

    func testScanResultSeparatesMovedTrashFromRemainingCleanableBacklog() {
        let result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 820,
            freeBytes: 180,
            items: [
                makeItem(title: "Remaining Cache", path: "~/Library/Caches/remaining", sizeBytes: 100, tier: .green),
                makeItem(title: "Moved Cache", path: "~/Library/Caches/moved", sizeBytes: 70, tier: .green, status: .movedToTrash),
                makeItem(title: "Review File", path: "~/Downloads/review.zip", sizeBytes: 120, tier: .yellow)
            ]
        )

        XCTAssertEqual(result.greenBytes, 100)
        XCTAssertEqual(result.movedToTrashItems.map(\.title), ["Moved Cache"])
        XCTAssertEqual(result.movedToTrashBytes, 70)
    }

    func testCleanupFollowUpPrioritizesTrashReviewAfterMovingItems() {
        let result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 820,
            freeBytes: 180,
            items: [
                makeItem(title: "Remaining Cache", path: "~/Library/Caches/remaining", sizeBytes: 100, tier: .green),
                makeItem(title: "Moved Cache", path: "~/Library/Caches/moved", sizeBytes: 70, tier: .green, status: .movedToTrash)
            ]
        )

        let summary = ScanHistoryService.cleanupFollowUp(for: result)

        XCTAssertEqual(summary.stage, .needsTrashReview)
        XCTAssertEqual(summary.primaryCount, 1)
        XCTAssertEqual(summary.primaryBytes, 70)
    }

    func testCleanupFollowUpShowsReadyToCleanBeforeMovingItems() {
        let result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 820,
            freeBytes: 180,
            items: [
                makeItem(title: "Remaining Cache", path: "~/Library/Caches/remaining", sizeBytes: 100, tier: .green)
            ]
        )

        let summary = ScanHistoryService.cleanupFollowUp(for: result)

        XCTAssertEqual(summary.stage, .readyToClean)
        XCTAssertEqual(summary.primaryCount, 1)
        XCTAssertEqual(summary.primaryBytes, 100)
    }

    func testCleanupFollowUpShowsNoCleanableItemsWhenGreenBacklogIsGone() {
        let result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 820,
            freeBytes: 180,
            items: [
                makeItem(title: "Review File", path: "~/Downloads/review.zip", sizeBytes: 120, tier: .yellow)
            ]
        )

        let summary = ScanHistoryService.cleanupFollowUp(for: result)

        XCTAssertEqual(summary.stage, .noCleanableItems)
        XCTAssertEqual(summary.primaryCount, 0)
        XCTAssertEqual(summary.primaryBytes, 0)
    }

    func testSmartScoreBreakdownExplainsScoreWithSameFormula() {
        let items = [
            makeItem(title: "Cache", path: "~/Library/Caches/example", sizeBytes: 12 * gib, tier: .green)
        ]
        + (0..<19).map { index in
            makeItem(title: "Review \(index)", path: "~/Downloads/review-\(index)", sizeBytes: 2 * gib, tier: .yellow)
        }
        + (0..<9).map { index in
            makeItem(title: "Careful \(index)", path: "/Applications/Careful-\(index).app", sizeBytes: 4 * gib, tier: .red)
        }
        let result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 570 * gib,
            freeBytes: 430 * gib,
            items: items,
            deniedPaths: ["~/Documents"]
        )

        let breakdown = ScanHistoryService.scoreBreakdown(for: result)

        XCTAssertEqual(breakdown.score, ScanHistoryService.smartScore(for: result))
        XCTAssertEqual(breakdown.totalPenalty, 13)
        XCTAssertEqual(breakdown.diskPressurePenalty, 0)
        XCTAssertEqual(breakdown.cleanupBacklogPenalty, 7)
        XCTAssertEqual(breakdown.permissionPenalty, 6)
        XCTAssertEqual(breakdown.scanScopePenalty, 0)
        XCTAssertEqual(breakdown.freshnessPenalty, 0)
        XCTAssertEqual(breakdown.healthPenalty, 7)
        XCTAssertEqual(breakdown.confidencePenalty, 6)
        XCTAssertTrue(["权限缺口", "access gaps"].contains(breakdown.confidenceDetail))
        XCTAssertEqual(
            breakdown.factors.map(\.id),
            [.diskPressure, .cleanupBacklog, .permissions, .scanCompleteness]
        )
    }

    func testSmartScoreDoesNotPenalizeScanScopeWhenThereIsOnlyStandardMode() {
        let result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 500,
            freeBytes: 500,
            items: []
        )

        let breakdown = ScanHistoryService.scoreBreakdown(for: result)

        XCTAssertEqual(breakdown.scanScopePenalty, 0)
        XCTAssertEqual(breakdown.totalPenalty, 0)
        XCTAssertEqual(breakdown.score, 100)
    }

    func testTimeLimitedScanCannotReceivePerfectScore() {
        let result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            scanSeconds: ScanMode.standard.maxScanSeconds,
            scanWasLimited: true,
            usedBytes: 500 * gib,
            freeBytes: 500 * gib,
            items: []
        )

        let breakdown = ScanHistoryService.scoreBreakdown(for: result)

        XCTAssertTrue(breakdown.scanWasLimited)
        XCTAssertEqual(breakdown.scanScopePenalty, 5)
        XCTAssertEqual(breakdown.totalPenalty, 5)
        XCTAssertEqual(breakdown.score, 95)
        XCTAssertEqual(breakdown.factors.first { $0.id == .scanCompleteness }?.severity, .warning)
    }

    func testPerfectScoreRequiresEveryPenaltyToBeZero() {
        let perfect = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 700 * gib,
            freeBytes: 300 * gib,
            items: []
        )
        let nonPerfectResults = [
            makeScanResult(
                date: Date(timeIntervalSince1970: 100),
                usedBytes: 950 * gib,
                freeBytes: 50 * gib,
                items: []
            ),
            makeScanResult(
                date: Date(timeIntervalSince1970: 100),
                usedBytes: 700 * gib,
                freeBytes: 300 * gib,
                items: [makeItem(title: "Cache", path: "~/Library/Caches/example", sizeBytes: 8 * gib)]
            ),
            makeScanResult(
                date: Date(timeIntervalSince1970: 100),
                usedBytes: 700 * gib,
                freeBytes: 300 * gib,
                items: [],
                deniedPaths: ["~/Documents"]
            ),
            makeScanResult(
                date: Date(timeIntervalSince1970: 100),
                scanWasLimited: true,
                usedBytes: 700 * gib,
                freeBytes: 300 * gib,
                items: []
            )
        ]

        let perfectBreakdown = ScanHistoryService.scoreBreakdown(for: perfect)
        XCTAssertEqual(perfectBreakdown.score, 100)
        XCTAssertEqual(perfectBreakdown.totalPenalty, 0)

        for result in nonPerfectResults {
            let breakdown = ScanHistoryService.scoreBreakdown(for: result)
            XCTAssertGreaterThan(breakdown.totalPenalty, 0)
            XCTAssertEqual(breakdown.score, 100 - breakdown.totalPenalty)
            XCTAssertLessThan(breakdown.score, 100)
        }
    }

    func testSmartScoreBandBoundaries() {
        XCTAssertEqual(SmartScoreBand(score: 100), .excellent)
        XCTAssertEqual(SmartScoreBand(score: 96), .excellent)
        XCTAssertEqual(SmartScoreBand(score: 95), .good)
        XCTAssertEqual(SmartScoreBand(score: 88), .good)
        XCTAssertEqual(SmartScoreBand(score: 87), .fair)
        XCTAssertEqual(SmartScoreBand(score: 75), .fair)
        XCTAssertEqual(SmartScoreBand(score: 74), .attention)
        XCTAssertEqual(SmartScoreBand(score: 60), .attention)
        XCTAssertEqual(SmartScoreBand(score: 59), .critical)
        XCTAssertEqual(SmartScoreBand(score: 0), .critical)
    }

    func testSmartScorePenalizesStaleCurrentResult() {
        let generatedAt = Date(timeIntervalSince1970: 100)
        let result = makeScanResult(
            date: generatedAt,
            usedBytes: 500,
            freeBytes: 500,
            items: []
        )

        let breakdown = ScanHistoryService.scoreBreakdown(
            for: result,
            referenceDate: generatedAt.addingTimeInterval(24 * 60 * 60)
        )

        XCTAssertEqual(breakdown.freshnessPenalty, 5)
        XCTAssertEqual(breakdown.totalPenalty, 5)
        XCTAssertEqual(breakdown.healthPenalty, 0)
        XCTAssertEqual(breakdown.confidencePenalty, 5)
        XCTAssertTrue(["结果时效", "freshness"].contains(breakdown.confidenceDetail))
        XCTAssertEqual(breakdown.score, 95)
        XCTAssertTrue(breakdown.factors.map(\.id).contains(.freshness))
    }

    func testSmartScoreUsesSmallerPenaltyForAgingResult() {
        let generatedAt = Date(timeIntervalSince1970: 100)
        let result = makeScanResult(
            date: generatedAt,
            usedBytes: 500 * gib,
            freeBytes: 500 * gib,
            items: []
        )

        let breakdown = ScanHistoryService.scoreBreakdown(
            for: result,
            referenceDate: generatedAt.addingTimeInterval(3 * 60 * 60)
        )

        XCTAssertEqual(breakdown.freshnessPenalty, 2)
        XCTAssertEqual(breakdown.score, 98)
        XCTAssertEqual(breakdown.band, .excellent)
    }

    func testSmartScoreWeightsHighImpactPermissionGapsMoreHeavily() {
        let lowImpact = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 500,
            freeBytes: 500,
            deniedPaths: ["~/Library/Containers/com.example.cache"]
        )
        let highImpact = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 500,
            freeBytes: 500,
            deniedPaths: ["~/Downloads"]
        )

        let lowBreakdown = ScanHistoryService.scoreBreakdown(for: lowImpact)
        let highBreakdown = ScanHistoryService.scoreBreakdown(for: highImpact)

        XCTAssertEqual(lowBreakdown.permissionPenalty, 2)
        XCTAssertEqual(highBreakdown.permissionPenalty, 6)
        XCTAssertGreaterThan(highBreakdown.totalPenalty, lowBreakdown.totalPenalty)
    }

    func testSmartScorePenalizesHighDiskPressure() {
        let result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 980 * gib,
            freeBytes: 20 * gib,
            items: []
        )

        XCTAssertLessThan(ScanHistoryService.smartScore(for: result), 70)
    }

    func testSmartScoreBreakdownMarksHighDiskPressureAsCritical() {
        let result = makeScanResult(
            date: Date(timeIntervalSince1970: 100),
            usedBytes: 996 * gib,
            freeBytes: 4 * gib,
            items: []
        )

        let breakdown = ScanHistoryService.scoreBreakdown(for: result)
        let diskFactor = breakdown.factors.first { $0.id == .diskPressure }

        XCTAssertEqual(diskFactor?.penalty, breakdown.diskPressurePenalty)
        XCTAssertEqual(diskFactor?.severity, .critical)
    }

    private func makeItem(
        title: String,
        path: String,
        sizeBytes: Int64,
        tier: StorageTier = .green,
        status: ItemStatus = .available
    ) -> StorageItem {
        StorageItem(
            id: PathSafety.normalizedPath(path),
            title: title,
            path: path,
            groupTitle: "Test",
            sizeBytes: sizeBytes,
            tier: tier,
            kind: "Cache",
            reason: "Test",
            recommendation: "Test",
            risk: "Test",
            requiresClose: "None",
            trashPaths: [path],
            openPath: path,
            status: status
        )
    }

    private func makeScanResult(
        date: Date,
        scanMode: ScanMode = .standard,
        scanSeconds: TimeInterval = 1.2,
        scanWasLimited: Bool = false,
        usedBytes: Int64,
        freeBytes: Int64,
        items: [StorageItem]? = nil,
        deniedPaths: [String] = []
    ) -> ScanResult {
        let scanItems = items ?? [
            makeItem(title: "Cache", path: "~/Library/Caches/example", sizeBytes: 100)
        ]

        return ScanResult(
            generatedAt: date,
            scanSeconds: scanSeconds,
            scanMode: scanMode,
            scanWasLimited: scanWasLimited,
            system: SystemSnapshot(
                osName: "macOS",
                build: "Test",
                arch: "arm64",
                user: "yyh",
                home: NSHomeDirectory(),
                filesystem: "apfs",
                purgeable: "",
                diskName: "Macintosh HD",
                diskTotalBytes: usedBytes + freeBytes,
                diskUsedBytes: usedBytes,
                diskFreeBytes: freeBytes
            ),
            groups: [],
            items: scanItems,
            deniedPaths: deniedPaths
        )
    }
}
