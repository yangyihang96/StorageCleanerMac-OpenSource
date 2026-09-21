import Foundation
import XCTest

final class CompetitiveParityContractTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testSmartScanCopyDoesNotClaimPrivacyOrPerformanceWorkItDoesNotRun() throws {
        let themeSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Support/ModuleTheme.swift"
            ),
            encoding: .utf8
        )
        let progressSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/SmartScanProgressView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(themeSource.contains("检查系统垃圾、隐私风险与性能状态"))
        XCTAssertFalse(progressSource.contains("Checking cleanup, privacy, and performance status"))
        XCTAssertTrue(themeSource.contains("检查可清理垃圾与需要人工判断的文件"))
        XCTAssertTrue(progressSource.contains("subtitle: module.pageSubtitle"))
        XCTAssertTrue(themeSource.contains("Check cleanup candidates and files that need review"))
    }

    func testStorageMapUsesOneReusableIndexAndKeepsFinderAsExplicitAction() throws {
        let largeFilesSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/LargeFilesView.swift"
            ),
            encoding: .utf8
        )
        let mapSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/StorageTreemapView.swift"
            ),
            encoding: .utf8
        )
        let storeSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/LargeFiles/Stores/LargeFilesStore.swift"
            ),
            encoding: .utf8
        )
        let scannerSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Services/DiskScanner.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(largeFilesSource.contains("LargeFileStorageMap("))
        XCTAssertTrue(largeFilesSource.contains("case visualMap"))
        XCTAssertTrue(largeFilesSource.contains("case columnBrowser"))
        XCTAssertTrue(largeFilesSource.contains(".pickerStyle(.segmented)"))
        XCTAssertFalse(largeFilesSource.contains("private var summaryPanel"))
        XCTAssertFalse(largeFilesSource.contains("private struct LargeFileCategoryBar"))
        XCTAssertTrue(mapSource.contains("StorageMapColumn("))
        XCTAssertTrue(mapSource.contains("workspace.openStorageMapDirectory(entry, fromLevel:"))
        XCTAssertTrue(mapSource.contains("workspace.showNextStorageMapLevel()"))
        XCTAssertTrue(mapSource.contains("workspace.storageMapNavigation.enumerated()"))
        XCTAssertTrue(mapSource.contains("ScrollViewReader { proxy in"))
        XCTAssertTrue(mapSource.contains("scrollBreadcrumbToCurrent(using: proxy)"))
        XCTAssertTrue(mapSource.contains("scrollColumnBrowserToCurrent(using: proxy)"))
        XCTAssertTrue(mapSource.contains(".id(snapshot.path)"))
        XCTAssertTrue(mapSource.contains("currentLocationIdentity"))
        XCTAssertTrue(mapSource.contains("accessibilityAddTraits(isSelected ? .isSelected : [])"))
        XCTAssertTrue(mapSource.contains(".accessibilityElement(children: .contain)"))
        XCTAssertTrue(mapSource.contains(".accessibilityValue(mapSelectionAccessibilityValue)"))
        XCTAssertTrue(mapSource.contains(".accessibilityAction(named: Text(L10n.text(\"打开\", \"Open\")), onActivate)"))
        XCTAssertTrue(mapSource.contains(".accessibilityHint(entry.role != .content"))
        XCTAssertTrue(mapSource.contains("if !entry.isDirectory, !entry.path.isEmpty"))
        XCTAssertTrue(mapSource.contains("StorageTreemapTile("))
        XCTAssertFalse(largeFilesSource.contains("case sunburstMap"))
        XCTAssertTrue(mapSource.contains("rectangularMapCanvas"))
        XCTAssertTrue(mapSource.contains("measuredShare:"))
        XCTAssertTrue(mapSource.contains("StorageTreemapPresentation.mapLayoutEntries"))
        XCTAssertTrue(mapSource.contains("referenceBytes: currentSnapshot.referenceBytes"))
        XCTAssertTrue(mapSource.contains("case .unmeasuredRemainder"))
        XCTAssertTrue(mapSource.contains("StorageMapCategoryLegendItem"))
        XCTAssertTrue(mapSource.contains("entry.contentCategory"))
        XCTAssertTrue(mapSource.contains("ByteFormat.storageString"))
        XCTAssertFalse(mapSource.contains("index %"))
        XCTAssertFalse(mapSource.contains("currentEntryList\n                    .frame(height: 230)"))
        XCTAssertTrue(mapSource.contains("The adjacent Columns mode remains available"))
        XCTAssertTrue(mapSource.contains("切换层级只读取当前一层"))
        XCTAssertTrue(mapSource.contains("在访达中显示"))
        XCTAssertFalse(mapSource.contains("DiskScanner"))
        XCTAssertFalse(mapSource.contains("Timer"))
        XCTAssertFalse(mapSource.contains("Task.detached"))
        XCTAssertTrue(storeSource.contains("storageMapAnalysis("))
        XCTAssertTrue(storeSource.contains("guard let index else"))
        XCTAssertTrue(storeSource.contains("using: index"))
        XCTAssertTrue(storeSource.contains("storageAnalysisOperation"))
        XCTAssertTrue(storeSource.contains("withTaskCancellationHandler"))
        XCTAssertTrue(storeSource.contains("worker.cancel()"))
        XCTAssertTrue(scannerSource.contains("childrenByDirectory"))
        XCTAssertTrue(scannerSource.contains("autoreleasepool(invoking:"))
        XCTAssertTrue(scannerSource.contains("for directoryID in directories.indices.reversed()"))
        XCTAssertTrue(scannerSource.contains("metadata.st_nlink > 1"))
        XCTAssertTrue(scannerSource.contains("shouldSkipLogicalDataMirror"))
        XCTAssertTrue(scannerSource.contains("storageMapPath("))
        XCTAssertTrue(scannerSource.contains("storageMapEnumeratedPath("))
        XCTAssertTrue(scannerSource.contains("storageMapLogicalPath("))
        XCTAssertTrue(scannerSource.contains("storageMapParentPath("))
        XCTAssertTrue(scannerSource.contains("storageMapPreferredSize("))
        XCTAssertTrue(scannerSource.contains("capacity?.userAvailableBytes"))
        XCTAssertTrue(scannerSource.contains("values.fileSize"))
        XCTAssertFalse(scannerSource.contains(".totalFileSizeKey"))
        XCTAssertTrue(scannerSource.contains("No file-system read"))
        XCTAssertTrue(mapSource.contains("activateFileViewerSelecting"))

        let tileSource = try XCTUnwrap(
            mapSource.components(separatedBy: "private struct StorageTreemapTile").last?
                .components(separatedBy: "private struct StorageMapEntryRow").first
        )
        XCTAssertFalse(tileSource.contains("NSWorkspace"))
        XCTAssertFalse(tileSource.contains("activateFileViewerSelecting"))
    }
}
