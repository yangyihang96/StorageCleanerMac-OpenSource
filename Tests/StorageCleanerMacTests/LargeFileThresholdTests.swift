import Foundation
import XCTest
@testable import StorageCleanerMac

/// D85：大文件门槛三档，默认中间一档；截断时说明“仅显示前 N 项”。D178：门槛按十进制
/// 50 MB / 200 MB / 1 GB（原来按二进制 50 MiB / 200 MiB / 1 GiB）。
final class LargeFileThresholdTests: XCTestCase {
    /// D178: renamed from testThreeBinaryThresholdsWithTheDefaultUnchanged.
    func testThreeDecimalThresholdsWithTheDefaultInTheMiddle() {
        XCTAssertEqual(LargeFileThreshold.allCases, [.mib50, .mib200, .gib1])
        // D178: decimal bytes (was 52_428_800, 209_715_200 and 1_073_741_824).
        XCTAssertEqual(LargeFileThreshold.mib50.bytes, 50_000_000)
        XCTAssertEqual(LargeFileThreshold.mib200.bytes, 200_000_000)
        XCTAssertEqual(LargeFileThreshold.gib1.bytes, 1_000_000_000)
        // D178 (was ["50 MiB", "200 MiB", "1 GiB"]).
        XCTAssertEqual(LargeFileThreshold.allCases.map(\.title), ["50 MB", "200 MB", "1 GB"])
        XCTAssertEqual(LargeFileThreshold.standard, .mib200)
        // 修复轮 1：删掉无引用的 ScanMode.largeFileMinimumBytes，默认档字节数改由 LargeFileThreshold 直接锁定。
        // D178 (was 200 * 1024 * 1024).
        XCTAssertEqual(LargeFileThreshold.standard.bytes, 200_000_000)
        XCTAssertEqual(ScanMode.standard.largeFileResultLimit, 80)
        XCTAssertEqual(LargeFileThreshold.stored(nil), .mib200)
        XCTAssertEqual(LargeFileThreshold.stored("bogus"), .mib200)
        XCTAssertEqual(LargeFileThreshold.stored("gib1"), .gib1)
        // D178 (was "1,048,576").
        XCTAssertTrue(LargeFileThreshold.unitHelp.contains("1,000,000"))
    }

    @MainActor
    func testThresholdIsKeptInTheFeaturePreferences() {
        let defaults = TestPreferenceDomain.make(for: self)
        let coordinator = HeavyWorkCoordinator()
        let store = LargeFilesStore(coordinator: coordinator,
            activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            defaults: defaults, storageMapTargets: [])
        XCTAssertEqual(store.largeFileThreshold, .mib200)
        store.largeFileThreshold = .mib50
        XCTAssertEqual(defaults.string(forKey: "large-files.threshold"), "mib50")
        let reopened = LargeFilesStore(coordinator: coordinator,
            activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            defaults: defaults, storageMapTargets: [])
        XCTAssertEqual(reopened.largeFileThreshold, .mib50)
    }

    /// 排序按大小降序（同大小按路径），超过上限只显示前 N 项并说明。
    func testListingSortsAndTruncatesAtTheResultLimit() {
        var candidates = (0..<85).map { index in
            DirectoryEntry(name: "f\(index)", path: "/Fixture/f\(String(format: "%02d", index))", sizeBytes: Int64(1_000 + index))
        }
        candidates.append(DirectoryEntry(name: "tie-b", path: "/Fixture/tie-b", sizeBytes: 5_000))
        candidates.append(DirectoryEntry(name: "tie-a", path: "/Fixture/tie-a", sizeBytes: 5_000))
        let made = LargeFileListingSummary.make(candidates: candidates, threshold: .mib50, resultLimit: 80,
            reachedTimeLimit: false, reachedFolderLimit: false, lowerBoundPaths: [])
        XCTAssertEqual(made.entries.count, 80)
        XCTAssertEqual(made.entries.prefix(3).map(\.path), ["/Fixture/tie-a", "/Fixture/tie-b", "/Fixture/f84"])
        XCTAssertEqual(made.entries.map(\.sizeBytes), made.entries.map(\.sizeBytes).sorted(by: >))
        XCTAssertEqual(made.summary.qualifyingCount, 87)
        XCTAssertEqual(made.summary.shownCount, 80)
        XCTAssertTrue(made.summary.reachedResultLimit)
        XCTAssertTrue(made.summary.isTruncated)
        XCTAssertTrue(made.summary.note.contains(L10n.text("仅显示前 80 项（共找到 87 项）",
            "Showing only the first 80 items (87 found)")), made.summary.note)
        // D178 (was "50 MiB").
        XCTAssertTrue(made.summary.note.contains("50 MB"))

        let exact = LargeFileListingSummary.make(candidates: Array(candidates.prefix(80)), threshold: .mib200, resultLimit: 80,
            reachedTimeLimit: false, reachedFolderLimit: false, lowerBoundPaths: [])
        XCTAssertFalse(exact.summary.isTruncated, "Exactly 80 results is not a truncation")
        XCTAssertFalse(exact.summary.note.contains(L10n.text("仅显示前", "Showing only")))
    }

    /// 边界：本地占用刚到门槛的文件计入，少 4 KiB 的不计入；200 MB 档两个都不计入。
    /// D178：门槛 50,000,000 字节不是 4 KiB 的整数倍，所以“刚到门槛”取门槛以上
    /// 第一个整块（50,003,968 字节）；原来门槛 50 MiB 本身就是整块，直接用它。
    func testThresholdBoundaryUsesLocalUsageInclusively() throws {
        let root = try makeRoot()
        let atThreshold = (LargeFileThreshold.mib50.bytes + 4095) / 4096 * 4096
        try Data(count: Int(atThreshold)).write(to: root.appendingPathComponent("exact.bin"))
        try Data(count: Int(atThreshold) - 4096).write(to: root.appendingPathComponent("below.bin"))
        let deadline = Date().addingTimeInterval(60)
        let fifty = DiskScanner(excludedPaths: [], largeFileRoots: [root.path], largeFileThreshold: .mib50)
            .largeFileListing(deadline: deadline)
        XCTAssertEqual(fifty.entries.map(\.name), ["exact.bin"])
        XCTAssertEqual(fifty.entries.first?.sizeBytes, atThreshold)
        XCTAssertEqual(fifty.summary.threshold, .mib50)
        XCTAssertFalse(fifty.summary.isTruncated)

        let standard = DiskScanner(excludedPaths: [], largeFileRoots: [root.path])
            .largeFileListing(deadline: deadline)
        XCTAssertTrue(standard.entries.isEmpty)
        XCTAssertEqual(standard.summary.threshold, .mib200)
    }

    /// 单个文件夹最多测 36 个子项目；超出时标为部分测量。结果上限也会截断。
    func testFolderMeasurementLimitAndResultLimitAreReported() throws {
        let root = try makeRoot()
        for index in 0..<40 {
            try Data(repeating: 1, count: 4096 * (index + 1)).write(to: root.appendingPathComponent("file-\(index).bin"))
        }
        let scanner = DiskScanner(excludedPaths: [], largeFileRoots: [root.path])
        let listing = scanner.largeFileListing(deadline: Date().addingTimeInterval(60), minimumBytes: 1, resultLimit: 5)
        XCTAssertEqual(listing.entries.count, 5)
        XCTAssertEqual(listing.summary.qualifyingCount, 36)
        XCTAssertTrue(listing.summary.reachedFolderLimit)
        XCTAssertTrue(listing.summary.reachedResultLimit)
        XCTAssertEqual(listing.entries.map(\.sizeBytes), listing.entries.map(\.sizeBytes).sorted(by: >))
        XCTAssertTrue(listing.summary.note.contains(L10n.text("仅显示前 5 项", "Showing only the first 5 items")))
        XCTAssertTrue(listing.summary.note.contains(L10n.text("部分文件夹只测了前一部分项目", "Some folders were only partly measured")))
    }

    /// 时间上限已到：不读任何位置，说明结果不完整。
    func testExpiredDeadlineReportsTheTimeLimit() throws {
        let root = try makeRoot()
        try Data(repeating: 1, count: 8192).write(to: root.appendingPathComponent("a.bin"))
        let listing = DiskScanner(excludedPaths: [], largeFileRoots: [root.path])
            .largeFileListing(deadline: Date().addingTimeInterval(-1), minimumBytes: 1)
        XCTAssertTrue(listing.entries.isEmpty)
        XCTAssertTrue(listing.summary.reachedTimeLimit)
        XCTAssertTrue(listing.summary.isTruncated)
        XCTAssertTrue(listing.summary.note.contains(L10n.text("已到扫描时间上限", "Scan time limit reached")))
        let notStarted = LargeFileListingSummary.notStarted(threshold: .gib1, resultLimit: 80)
        XCTAssertTrue(notStarted.reachedTimeLimit)
        // D178 (was "1 GiB").
        XCTAssertTrue(notStarted.note.contains("1 GB"))
    }

    /// 扫描用选中的门槛；取消时保留上次的结果与截断说明。
    @MainActor
    func testScanUsesTheChosenThresholdAndCancelKeepsThePreviousResult() async throws {
        let calls = ThresholdCalls()
        let coordinator = HeavyWorkCoordinator()
        let first = LargeFileListingSummary.make(
            candidates: [DirectoryEntry(name: "a", path: "/Fixture/a", sizeBytes: 60 * 1024 * 1024)],
            threshold: .mib50, resultLimit: 80, reachedTimeLimit: false, reachedFolderLimit: false, lowerBoundPaths: [])
        let store = LargeFilesStore(coordinator: coordinator,
            activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            defaults: TestPreferenceDomain.make(for: self),
            listingScanOperation: { threshold, _ in
                let call = calls.record(threshold)
                if call > 1 { try await Task.sleep(for: .seconds(30)) }
                return LargeFileScanOutcome(items: [], summary: first.summary)
            },
            storageMapTargets: [])
        store.largeFileThreshold = .mib50
        store.startScan()
        try await waitUntil { store.phase == .finished }
        XCTAssertEqual(calls.thresholds, [.mib50])
        XCTAssertEqual(store.listingSummary, first.summary)

        store.largeFileThreshold = .gib1
        store.startScan()
        try await waitUntil { calls.thresholds.count == 2 }
        store.cancelScan()
        try await waitUntil { store.phase == .cancelled }
        XCTAssertEqual(calls.thresholds, [.mib50, .gib1])
        XCTAssertEqual(store.listingSummary, first.summary, "A cancelled scan keeps the last result")
    }

    func testMigrationPagesShowTheThresholdControlAndTruncationNote() throws {
        let view = try source("Views/LargeFilesView.swift")
        XCTAssertTrue(view.contains("if workspace.migrationKind == .file { largeFileThresholdControl }"))
        XCTAssertTrue(view.contains("listingNote: workspace.migrationKind == .file ? workspace.listingSummary?.note : nil"))
        let page = try source("Views/FilesLightfield/FileMigrationLightfieldView.swift")
        XCTAssertTrue(page.contains("if let listingNote {"))
    }

    // MARK: - Helpers

    private final class ThresholdCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [LargeFileThreshold] = []
        func record(_ threshold: LargeFileThreshold) -> Int {
            lock.lock(); defer { lock.unlock() }
            values.append(threshold)
            return values.count
        }
        var thresholds: [LargeFileThreshold] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeRoot() throws -> URL {
        let root = TestFileSystem.uniqueRoot("LargeFileThreshold")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/" + path), encoding: .utf8)
    }
}
