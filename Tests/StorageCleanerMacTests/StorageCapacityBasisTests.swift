import Darwin
import XCTest
@testable import StorageCleanerMac

/// D84：容量口径说明。只加说明不改算法；夹具都在系统临时目录（只读分析）。
final class StorageCapacityBasisTests: XCTestCase {
    /// D193（用户 10-23 选“改成实际占用”）：名字沿用 D84 时的写法；应用包
    /// 内容也按本地占用。旧值：应用包内容的口径是 `.logical`，
    /// `storageMapPreferredSize(10, 4096, /Applications/Tool.app/Contents/Info.plist)` 是 10。
    func testApplicationBundleContentUsesLogicalSizeAndEverythingElseLocalUsage() {
        XCTAssertEqual(DiskScanner.storageMapSizeBasis(path: "/Applications/Tool.app/Contents/MacOS/Tool"), .allocated)
        XCTAssertEqual(DiskScanner.storageMapSizeBasis(path: "/Users/tester/Downloads/movie.mov"), .allocated)
        XCTAssertEqual(DiskScanner.storageMapSizeBasis(path: "/Applications/readme.txt"), .allocated)
        // 本地占用优先，缺值时用逻辑大小。
        XCTAssertEqual(DiskScanner.storageMapPreferredSize(logicalSize: 10, allocatedSize: 4096,
            path: "/Applications/Tool.app/Contents/Info.plist"), 4096)
        XCTAssertEqual(DiskScanner.storageMapPreferredSize(logicalSize: 10, allocatedSize: 4096, path: "/Users/t/a.txt"), 4096)
        XCTAssertEqual(DiskScanner.storageMapPreferredSize(logicalSize: 10, allocatedSize: nil, path: "/Users/t/a.txt"), 10)
        XCTAssertEqual(DiskScanner.storageMapPreferredSize(logicalSize: nil, allocatedSize: 8, path: "/Applications/T.app/x"), 8)
        XCTAssertEqual(DiskScanner.storageMapPreferredSize(logicalSize: 10, allocatedSize: nil,
            path: "/Applications/Tool.app/Contents/Info.plist"), 10)
        XCTAssertEqual(StorageCapacityPresentation.basis(forMeasuredPath: "/Applications/Tool.app", isDirectory: true), .allocated)
        XCTAssertEqual(StorageCapacityPresentation.basis(forMeasuredPath: "/Users/t/Tool.app", isDirectory: true), .allocated)
    }

    /// D193：不再有“逻辑大小”和“应用包按逻辑大小”两种口径，说明由 9 段
    /// 变 7 段。旧值：`notes.count == 9`，并含这两段的标题。
    func testBasisTitlesNameTheFourMeasures() {
        XCTAssertEqual(StorageCapacityBasis.allocated.title, L10n.text("本地占用（分配大小）", "Local Usage (Allocated Size)"))
        XCTAssertEqual(StorageCapacityBasis.measuredLowerBound.title, L10n.text("本轮量到的下限", "Lower Bound Measured This Run"))
        XCTAssertEqual(StorageCapacityBasis.cloudPlaceholder.title,
                       L10n.text("云端占位（未下载，不占本地）", "Cloud Placeholder (Not Downloaded, No Local Usage)"))
        XCTAssertEqual(StorageCapacityBasis.allCases, [.allocated, .measuredLowerBound, .cloudPlaceholder])
        let notes = StorageCapacityPresentation.notes.map(\.title)
        XCTAssertEqual(notes.count, 7)
        XCTAssertFalse(notes.contains(L10n.text("逻辑大小", "Logical Size")))
        XCTAssertFalse(notes.contains(L10n.text("本地占用（应用包按逻辑大小）", "Local Usage (App Bundles by Logical Size)")))
        for title in [L10n.text("硬链接", "Hard Links"), L10n.text("APFS 克隆", "APFS Clones"),
                      L10n.text("稀疏文件", "Sparse Files"), L10n.text("废纸篓", "Trash")] {
            XCTAssertTrue(notes.contains(title), title)
        }
    }

    /// 修复轮 1（P1-1）时范围为 / 或 /Applications 写混合口径；D193 起这些
    /// 范围和应用包本身都按本地占用，名字沿用。旧值：/、/Applications、
    /// /Applications/Utilities 的口径为 `.mixedWithAppBundles`，标签
    /// “已分析 · 本地占用（应用包按逻辑大小）”，说明“按本地占用（应用包按
    /// 逻辑大小）”；/Applications/Tool.app 的标签“已分析 · 逻辑大小”；
    /// 完整时 / 与 /Users/tester 的标签不同。
    func testScopesContainingAppBundlesAreLabelledAsMixed() throws {
        let localLabel = L10n.text("已分析 · 本地占用", "Analyzed · Local Usage")
        let localNote = L10n.text("按本地占用（分配大小）", "By local usage (allocated size)")
        for path in ["/", "/Applications", "/Applications/", "/Applications/Utilities", "/Applications/Tool.app"] {
            XCTAssertEqual(StorageCapacityPresentation.summaryBasis(isComplete: true, path: path), .allocated, path)
            XCTAssertEqual(StorageCapacityPresentation.summaryLabel(isComplete: true, path: path), localLabel, path)
            XCTAssertEqual(StorageCapacityPresentation.snapshotNote(isComplete: true, path: path), localNote, path)
        }
        XCTAssertEqual(StorageCapacityPresentation.summaryLabel(isComplete: true, path: "/Users/tester"),
                       L10n.text("已分析 · 本地占用", "Analyzed · Local Usage"))
        XCTAssertEqual(StorageCapacityPresentation.snapshotNote(isComplete: true, path: "/Users/tester"),
                       L10n.text("按本地占用（分配大小）", "By local usage (allocated size)"))
        XCTAssertEqual(StorageCapacityPresentation.summaryLabel(isComplete: false, path: "/"),
                       L10n.text("本轮量到的下限", "Lower Bound This Run"))
        XCTAssertEqual(StorageCapacityPresentation.summaryLabel(isComplete: true, path: "/"),
                       StorageCapacityPresentation.summaryLabel(isComplete: true, path: "/Users/tester"))

        // 行悬停：D193 起都写本地占用（旧值：/Applications 与其中文件夹写混合，
        // 应用包与其内容写逻辑大小）。
        func folder(_ path: String) -> StorageTreemapEntry {
            StorageTreemapEntry(id: path, title: (path as NSString).lastPathComponent, path: path, sizeBytes: 1, kind: "folder",
                                isDirectory: true, canDescend: true, isEstimated: false, isCloudOnly: false)
        }
        XCTAssertEqual(StorageCapacityPresentation.basis(for: folder("/Applications")), .allocated)
        XCTAssertEqual(StorageCapacityPresentation.basis(for: folder("/Applications/Utilities")), .allocated)
        XCTAssertEqual(StorageCapacityPresentation.basis(for: folder("/Applications/Tool.app")), .allocated)
        XCTAssertEqual(StorageCapacityPresentation.basis(for: folder("/Applications/Tool.app/Contents")), .allocated)
        XCTAssertEqual(StorageCapacityPresentation.basis(for: folder("/Users")), .allocated)
        XCTAssertEqual(StorageCapacityPresentation.basis(forMeasuredPath: "/Applications/readme.txt", isDirectory: false), .allocated)
        XCTAssertTrue(StorageCapacityPresentation.rowHelp(folder("/Applications"))
            .contains(StorageCapacityBasis.allocated.title))

        // 界面按当前范围 / 当前层级的路径取标签。
        let view = try source("Views/FilesLightfield/FileAnalysisLightfieldView.swift")
        XCTAssertTrue(view.contains("StorageCapacityPresentation.summaryLabel(isComplete: result.rootSnapshot.isComplete, path: result.rootSnapshot.path)"))
        XCTAssertTrue(view.contains("StorageCapacityPresentation.snapshotNote(isComplete: snapshot.isComplete, path: snapshot.path)"))
    }

    /// 修复轮 1（P2-7、P2-8）：说明文字随语言切换（不在第一次读取时定死），
    /// 英文计数区分单复数。
    @MainActor
    func testNotesFollowTheCurrentLanguageAndEnglishCountsArePluralised() {
        let model = LocalModelEntry(id: "m", source: .lmStudio, name: "p/m", format: "GGUF", bytes: 1, exclusiveBytes: 1,
                                    sharedBytes: 0, sharedWith: [], fileCount: 1, missingFileCount: 1, location: "/m")
        withLanguage(.english) {
            XCTAssertTrue(StorageCapacityPresentation.hardLinkNote.hasPrefix("Hard links"))
            XCTAssertTrue(StorageCapacityPresentation.trashNote.hasPrefix("Moving to the Trash"))
            XCTAssertTrue(LargeFileThreshold.unitHelp.hasPrefix("Compared by local usage"))
            XCTAssertTrue(LocalModelInventoryPresentation.readOnlyNote.hasPrefix("Read-only inventory"))
            let detail = LocalModelInventoryPresentation.detail(model)
            XCTAssertTrue(detail.contains("1 file ·") && detail.hasSuffix("1 file missing"), detail)
            XCTAssertFalse(detail.contains("1 files"), detail)
            let note = LargeFileListingSummary(threshold: .mib200, resultLimit: 80, qualifyingCount: 1, shownCount: 1,
                reachedTimeLimit: true, reachedFolderLimit: false, lowerBoundPaths: ["/x"]).note
            XCTAssertTrue(note.contains("Showing the 1 item found") && note.contains("1 item timed out"), note)
        }
        withLanguage(.zhHans) {
            XCTAssertTrue(StorageCapacityPresentation.hardLinkNote.hasPrefix("硬链接"))
            XCTAssertTrue(StorageCapacityPresentation.trashNote.hasPrefix("移入废纸篓"))
            XCTAssertTrue(LargeFileThreshold.unitHelp.hasPrefix("按本地占用"))
            XCTAssertTrue(LocalModelInventoryPresentation.readOnlyNote.hasPrefix("只读盘点"))
        }
    }

    /// 稀疏文件：逻辑 300 MiB，本地只占几个块。空间分析按本地占用记，
    /// 200 MiB 门槛的大文件清单也不收它。
    func testSparseFileIsMeasuredByLocalUsage() throws {
        let root = try makeRoot()
        let sparse = root.appendingPathComponent("disk.img")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.seek(toOffset: 300 * 1024 * 1024)
        try handle.write(contentsOf: Data([1]))
        try handle.close()
        let logical = try XCTUnwrap(try sparse.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let allocated = allocatedBytes(sparse.path)
        XCTAssertGreaterThan(Int64(logical), 300 * 1024 * 1024)
        XCTAssertLessThan(allocated, 16 * 1024 * 1024, "APFS keeps the hole unallocated")

        let analysis = try DiskScanner(excludedPaths: []).storageMapAnalysis(target: target(root))
        let entry = try XCTUnwrap(analysis.rootSnapshot.entries.first { $0.title == "disk.img" })
        XCTAssertEqual(entry.sizeBytes, allocated)
        XCTAssertEqual(StorageCapacityPresentation.basis(for: entry), .allocated)
        XCTAssertTrue(analysis.rootSnapshot.isComplete)
        XCTAssertEqual(StorageCapacityPresentation.summaryLabel(isComplete: true, path: analysis.rootSnapshot.path),
                       L10n.text("已分析 · 本地占用", "Analyzed · Local Usage"))

        let listing = DiskScanner(excludedPaths: [], largeFileRoots: [root.path])
            .largeFileListing(deadline: Date().addingTimeInterval(30))
        XCTAssertTrue(listing.entries.isEmpty, "Sparse 300 MiB file takes far less than 200 MiB locally")
        XCTAssertEqual(listing.summary.qualifyingCount, 0)
    }

    /// 硬链接：空间分析只计一次。
    func testHardLinkedFileCountsOnceInSpaceAnalysis() throws {
        let root = try makeRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("B"), withIntermediateDirectories: true)
        let original = root.appendingPathComponent("A/data.bin")
        try Data(repeating: 7, count: 256 * 1024).write(to: original)
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("B/data-link.bin"))
        let allocated = allocatedBytes(original.path)

        let analysis = try DiskScanner(excludedPaths: []).storageMapAnalysis(target: target(root))
        XCTAssertEqual(analysis.rootSnapshot.measuredBytes, allocated, "Two links, one copy of the data")
        XCTAssertTrue(StorageCapacityPresentation.hardLinkNote.contains(L10n.text("只计一次", "once")))
    }

    /// APFS 克隆：各自报告完整的分配大小，合计可能大于实际占用（说明里写明）。
    func testAPFSCloneReportsFullAllocationForEachCopy() throws {
        let root = try makeRoot()
        let original = root.appendingPathComponent("original.bin")
        try Data(repeating: 9, count: 512 * 1024).write(to: original)
        let clone = root.appendingPathComponent("clone.bin")
        XCTAssertEqual(clonefile(original.path, clone.path, 0), 0, "temporary directory is on APFS")
        let allocated = allocatedBytes(original.path)
        XCTAssertEqual(allocatedBytes(clone.path), allocated)

        let analysis = try DiskScanner(excludedPaths: []).storageMapAnalysis(target: target(root))
        XCTAssertEqual(analysis.rootSnapshot.measuredBytes, 2 * allocated)
        XCTAssertTrue(StorageCapacityPresentation.cloneNote.contains(L10n.text("合计可能大于实际占用", "totals can exceed real usage")))
    }

    /// 云端占位：未下载的文件按“云端占位（未下载，不占本地）”说明。
    func testCloudPlaceholderReadsAsCloudPlaceholder() throws {
        let root = try makeRoot()
        let placeholder = root.appendingPathComponent("cloud.zip")
        try Data(repeating: 1, count: 4096).write(to: placeholder)
        try Data(repeating: 2, count: 4096).write(to: root.appendingPathComponent("local.txt"))
        // 枚举出的路径可能是 /private/var 拼法，按文件名判断。
        let options = DiskScanner.StorageMapAnalysisOptions(
            concurrency: 1, ubiquityLookup: .everyItem,
            cloudState: .custom { url in
                let isPlaceholder = url.lastPathComponent == "cloud.zip"
                return DiskScanner.StorageMapCloudState(isUbiquitous: isPlaceholder, isCurrent: !isPlaceholder)
            }
        )
        let analysis = try DiskScanner(excludedPaths: []).storageMapAnalysis(target: target(root), options: options)
        let cloud = try XCTUnwrap(analysis.rootSnapshot.entries.first { $0.title == "cloud.zip" })
        let local = try XCTUnwrap(analysis.rootSnapshot.entries.first { $0.title == "local.txt" })
        XCTAssertEqual(StorageCapacityPresentation.basis(for: cloud), .cloudPlaceholder)
        XCTAssertEqual(StorageCapacityPresentation.basis(for: local), .allocated)
        XCTAssertTrue(StorageCapacityPresentation.rowHelp(cloud).contains(StorageCapacityBasis.cloudPlaceholder.title))
        // 未读入的文件夹不猜测为云端占位。
        let folder = StorageTreemapEntry(id: "/f", title: "f", path: "/f", sizeBytes: 0, kind: "folder",
                                         isDirectory: true, canDescend: false, isEstimated: true, isCloudOnly: true)
        XCTAssertEqual(StorageCapacityPresentation.basis(for: folder), .measuredLowerBound)
    }

    /// 部分扫描（被排除、权限不足）：汇总与行都标为本轮量到的下限。
    func testPartialScanIsALowerBound() throws {
        let root = try makeRoot()
        let excluded = root.appendingPathComponent("Excluded")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 64 * 1024).write(to: excluded.appendingPathComponent("hidden.bin"))
        try Data(repeating: 4, count: 64 * 1024).write(to: root.appendingPathComponent("seen.bin"))

        let analysis = try DiskScanner(excludedPaths: [excluded.path]).storageMapAnalysis(target: target(root))
        XCTAssertFalse(analysis.rootSnapshot.isComplete)
        XCTAssertEqual(StorageCapacityPresentation.summaryBasis(isComplete: analysis.rootSnapshot.isComplete,
                                                                path: analysis.rootSnapshot.path), .measuredLowerBound)
        XCTAssertEqual(StorageCapacityPresentation.summaryLabel(isComplete: false, path: analysis.rootSnapshot.path),
                       L10n.text("本轮量到的下限", "Lower Bound This Run"))
        XCTAssertEqual(StorageCapacityPresentation.snapshotNote(isComplete: false, path: analysis.rootSnapshot.path),
                       L10n.text("部分索引 · 本轮量到的下限", "Partial index · Lower bound this run"))
        let row = try XCTUnwrap(analysis.rootSnapshot.entries.first { $0.title == "Excluded" })
        XCTAssertEqual(StorageCapacityPresentation.basis(for: row), .measuredLowerBound)
    }

    /// 读不出的子文件夹：大文件清单里的文件夹大小只是下限。
    func testUnreadableSubfolderMakesTreeMeasurementALowerBound() throws {
        let root = try makeRoot()
        let folder = root.appendingPathComponent("Project")
        let locked = folder.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 5, count: 64 * 1024).write(to: folder.appendingPathComponent("a.bin"))
        try Data(repeating: 6, count: 64 * 1024).write(to: locked.appendingPathComponent("b.bin"))
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { _ = chmod(locked.path, 0o700) }

        let scanner = DiskScanner(excludedPaths: [], largeFileRoots: [root.path])
        let measurement = try XCTUnwrap(scanner.treeSizeMeasurement(folder.path))
        XCTAssertFalse(measurement.isComplete)
        let complete = try XCTUnwrap(scanner.treeSizeMeasurement(folder.appendingPathComponent("a.bin").path))
        XCTAssertTrue(complete.isComplete)

        let listing = scanner.largeFileListing(deadline: Date().addingTimeInterval(30), minimumBytes: 1)
        XCTAssertTrue(listing.summary.lowerBoundPaths.contains(PathSafety.normalizedPath(folder.path)))
        XCTAssertTrue(listing.summary.note.contains(L10n.text("本轮量到的下限", "lower bounds")))
    }

    /// 移入废纸篓的完成摘要不写成“已释放磁盘空间”。
    func testMovedToTrashSummaryNeverClaimsFreedSpace() throws {
        let summary = StorageCapacityPresentation.movedToTrashSummary(count: 3, bytes: 3_000_000)
        XCTAssertTrue(summary.contains(L10n.text("已移到废纸篓", "to the Trash")))
        XCTAssertTrue(summary.contains(L10n.text("清空废纸篓后才释放", "freed when the Trash is emptied")))
        XCTAssertFalse(summary.contains("已释放"))
        let analysis = try source("Views/FilesLightfield/FileAnalysisLightfieldView.swift")
        XCTAssertTrue(analysis.contains("StorageCapacityPresentation.movedToTrashSummary(count: outcome.movedPaths.count, bytes: outcome.movedBytes)"))
        XCTAssertFalse(analysis.contains("已移走"))
        for path in ["Views/FilesLightfield/FileAnalysisLightfieldView.swift", "Views/FilesLightfield/FileMigrationLightfieldView.swift",
                     "Views/LargeFilesView.swift", "Views/FileAnalysisTrashViews.swift"] {
            XCTAssertFalse(try source(path).contains("已释放"), path)
        }
    }

    // MARK: - Helpers

    private func makeRoot() throws -> URL {
        let root = TestFileSystem.uniqueRoot("CapacityBasis")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func target(_ root: URL) -> StorageMapScanTarget {
        StorageMapScanTarget(path: root.path, title: "Capacity Fixture", kind: .homeDirectory)
    }

    private func allocatedBytes(_ path: String) -> Int64 {
        var status = stat()
        guard lstat(path, &status) == 0 else { return -1 }
        return Int64(status.st_blocks) * 512
    }

    @MainActor
    private func withLanguage(_ language: AppLanguage, _ body: () throws -> Void) rethrows {
        let defaults = TestPreferenceDomain.make(for: self)
        defaults.set(language.rawValue, forKey: L10n.languageDefaultsKey)
        let preferences = TestVolatilePreferences()
        preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
        defer { preferences.restore() }
        XCTAssertEqual(L10n.usesChinese, language == .zhHans)
        try body()
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/" + path), encoding: .utf8)
    }
}
