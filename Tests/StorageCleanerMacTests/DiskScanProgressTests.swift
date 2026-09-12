import XCTest
@testable import StorageCleanerMac

final class DiskScanProgressTests: XCTestCase {
    func testProgressDeduplicatesDiscoveredTotalsAcrossGroups() {
        let shared = DirectoryEntry(
            name: "Shared",
            path: "/tmp/shared",
            sizeBytes: 1_024
        )
        let denied = DirectoryEntry(
            name: "Denied",
            path: "/tmp/denied",
            sizeBytes: 4_096,
            denied: true
        )
        let progress = DiskScanProgress(
            currentGroupTitle: "Logs",
            completedGroupCount: 2,
            totalGroupCount: 4,
            groups: [
                StorageGroup(id: "cache", title: "Cache", entries: [shared, denied]),
                StorageGroup(id: "logs", title: "Logs", entries: [shared])
            ]
        )

        XCTAssertEqual(progress.discoveredItemCount, 1)
        XCTAssertEqual(progress.discoveredBytes, 1_024)
        XCTAssertEqual(progress.groups.map(\.itemCount), [1, 1])
        XCTAssertEqual(progress.fractionCompleted, 0.5)
    }

    func testProgressDoesNotDoubleCountNestedScanResults() {
        let parent = DirectoryEntry(
            name: "Google",
            path: "/tmp/Library/Caches/Google",
            sizeBytes: 8_192
        )
        let child = DirectoryEntry(
            name: "Chrome",
            path: "/tmp/Library/Caches/Google/Chrome",
            sizeBytes: 6_144
        )
        let progress = DiskScanProgress(
            currentGroupTitle: "Browser Cache",
            completedGroupCount: 2,
            totalGroupCount: 2,
            groups: [
                StorageGroup(id: "browser", title: "Browser", entries: [child]),
                StorageGroup(id: "cache", title: "Cache", entries: [parent])
            ]
        )

        XCTAssertEqual(progress.discoveredItemCount, 1)
        XCTAssertEqual(progress.discoveredBytes, parent.sizeBytes)
        XCTAssertEqual(progress.groups.map(\.bytes), [child.sizeBytes, parent.sizeBytes])
    }

    func testProgressIncludesMeasuredWorkInsideTheCurrentGroup() {
        let progress = DiskScanProgress(
            currentGroupTitle: "Applications",
            completedGroupCount: 3,
            totalGroupCount: 4,
            currentGroupCompletedItemCount: 2,
            currentGroupTotalItemCount: 4,
            groups: []
        )

        XCTAssertEqual(progress.fractionCompleted, 0.875)
    }
}
