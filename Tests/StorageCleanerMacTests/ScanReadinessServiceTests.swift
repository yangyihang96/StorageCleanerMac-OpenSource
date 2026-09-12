import XCTest
@testable import StorageCleanerMac

final class ScanReadinessServiceTests: XCTestCase {
    func testSummaryMarksReadableLocationsReady() {
        let locations = [
            ScanReadinessLocation(title: "Downloads", path: "~/Downloads", systemImage: "arrow.down.circle.fill"),
            ScanReadinessLocation(title: "Documents", path: "~/Documents", systemImage: "doc.text.fill")
        ]
        var didRestoreSavedAccess = false

        let summary = ScanReadinessService.summary(
            locations: locations,
            fileExists: { _ in true },
            canReadDirectory: { _ in true },
            restoreSavedAccess: {
                didRestoreSavedAccess = true
            },
            detectFullDiskAccess: {
                .notVerified
            }
        )

        XCTAssertEqual(summary.level, .ready)
        XCTAssertEqual(summary.readableCount, 2)
        XCTAssertEqual(summary.blockedCount, 0)
        XCTAssertEqual(summary.estimatedCoveragePercent, 100)
        XCTAssertTrue(didRestoreSavedAccess)
    }

    func testSummaryMarksExistingUnreadableLocationsAsPermissionGaps() {
        let locations = [
            ScanReadinessLocation(title: "Downloads", path: "~/Downloads", systemImage: "arrow.down.circle.fill"),
            ScanReadinessLocation(title: "Desktop", path: "~/Desktop", systemImage: "menubar.rectangle")
        ]

        let summary = ScanReadinessService.summary(
            locations: locations,
            fileExists: { _ in true },
            canReadDirectory: { path in !path.hasSuffix("/Downloads") },
            detectFullDiskAccess: {
                .notVerified
            }
        )

        XCTAssertEqual(summary.level, .needsPermission)
        XCTAssertEqual(summary.readableCount, 1)
        XCTAssertEqual(summary.blockedCount, 1)
        XCTAssertEqual(summary.highImpactBlockedCount, 1)
        XCTAssertEqual(summary.estimatedCoveragePercent, 85)
        XCTAssertEqual(summary.blockedItems.map(\.location.title), ["Downloads"])
    }

    func testSummarySkipsMissingLocationsWithoutCreatingPermissionGaps() {
        let locations = [
            ScanReadinessLocation(title: "Pictures", path: "~/Pictures", systemImage: "photo.fill"),
            ScanReadinessLocation(title: "iCloud Drive", path: "~/Library/Mobile Documents/com~apple~CloudDocs", systemImage: "icloud.fill")
        ]

        let summary = ScanReadinessService.summary(
            locations: locations,
            fileExists: { path in path.hasSuffix("/Pictures") },
            canReadDirectory: { _ in true },
            detectFullDiskAccess: {
                .notVerified
            }
        )

        XCTAssertEqual(summary.level, .ready)
        XCTAssertEqual(summary.readableCount, 1)
        XCTAssertEqual(summary.missingCount, 1)
        XCTAssertEqual(summary.blockedCount, 0)
        XCTAssertEqual(summary.estimatedCoveragePercent, 100)
    }

    func testDefaultReadinessLocationsAvoidMediaLibraryAndTrashRoots() {
        let paths = ScanReadinessService.defaultLocations(homePath: "/Users/tester").map(\.path)

        XCTAssertTrue(paths.contains("/Users/tester/Downloads"))
        XCTAssertTrue(paths.contains("/Users/tester/Desktop"))
        XCTAssertTrue(paths.contains("/Users/tester/Documents"))
        XCTAssertFalse(paths.contains("/Users/tester/.Trash"))
        XCTAssertFalse(paths.contains("/Users/tester/Pictures"))
        XCTAssertFalse(paths.contains("/Users/tester/Movies"))
        XCTAssertFalse(paths.contains("/Users/tester/Music"))
    }

    func testSummaryFromScanDeniedPathsMarksCurrentGapsWithoutReadingDirectories() {
        let locations = [
            ScanReadinessLocation(title: "Downloads", path: "/Users/tester/Downloads", systemImage: "arrow.down.circle.fill"),
            ScanReadinessLocation(title: "Documents", path: "/Users/tester/Documents", systemImage: "doc.text.fill"),
            ScanReadinessLocation(title: "Trash", path: "/Users/tester/.Trash", systemImage: "trash.fill")
        ]

        let summary = ScanReadinessService.summary(
            fromScanDeniedPaths: ["/Users/tester/Documents/Client"],
            locations: locations
        )

        XCTAssertEqual(summary.level, .needsPermission)
        XCTAssertEqual(summary.readableCount, 2)
        XCTAssertEqual(summary.blockedCount, 1)
        XCTAssertEqual(summary.blockedItems.map(\.location.title), ["Documents"])
    }

    func testSummaryFromCleanScanTreatsPlannedLocationsAsCurrentlyVerified() {
        let locations = [
            ScanReadinessLocation(title: "Downloads", path: "/Users/tester/Downloads", systemImage: "arrow.down.circle.fill"),
            ScanReadinessLocation(title: "Documents", path: "/Users/tester/Documents", systemImage: "doc.text.fill")
        ]

        let summary = ScanReadinessService.summary(fromScanDeniedPaths: [], locations: locations)

        XCTAssertEqual(summary.level, .ready)
        XCTAssertEqual(summary.readableCount, 2)
        XCTAssertEqual(summary.blockedCount, 0)
    }

    func testDisplayTextSeparatesCurrentCheckFromLastScanAccessGaps() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let unchecked = ScanReadinessService.displayText(
            summary: nil,
            lastDeniedCount: 1,
            isChecking: false
        )

        XCTAssertEqual(unchecked.title, "当前权限未检查")
        XCTAssertTrue(unchecked.detail.contains("上次扫描 1 处受限"))
        XCTAssertEqual(unchecked.actionTitle, "检查当前")

        let limited = ScanReadinessService.summary(
            locations: [
                ScanReadinessLocation(title: "Downloads", path: "~/Downloads", systemImage: "arrow.down.circle.fill")
            ],
            fileExists: { _ in true },
            canReadDirectory: { _ in false },
            detectFullDiskAccess: {
                .notVerified
            }
        )
        let limitedText = ScanReadinessService.displayText(
            summary: limited,
            lastDeniedCount: 1,
            isChecking: false
        )

        XCTAssertEqual(limitedText.title, "当前权限受限")
        XCTAssertTrue(limitedText.detail.contains("当前 1 处未读取"))
        XCTAssertTrue(limitedText.detail.contains("重启本应用后检查"))
        XCTAssertEqual(limitedText.actionTitle, "检查当前")
    }

    func testFullDiskAccessVerifiedAvoidsDuplicateFolderAuthorization() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let summary = ScanReadinessService.summary(
            locations: [
                ScanReadinessLocation(title: "文稿", path: "/Users/tester/Documents", systemImage: "doc.text.fill")
            ],
            fileExists: { _ in true },
            canReadDirectory: { _ in false },
            detectFullDiskAccess: {
                .verified
            }
        )

        XCTAssertEqual(summary.level, .needsPermission)
        XCTAssertTrue(summary.isFullDiskAccessVerified)
        XCTAssertEqual(summary.blockedCount, 1)
        XCTAssertEqual(summary.folderAuthorizationRequiredCount, 0)
        XCTAssertEqual(summary.estimatedCoveragePercent, 97)

        let displayText = ScanReadinessService.displayText(
            summary: summary,
            lastDeniedCount: 1,
            isChecking: false
        )

        XCTAssertEqual(displayText.title, "完整磁盘访问已生效")
        XCTAssertTrue(displayText.detail.contains("不需要重复授权文件夹"))
        XCTAssertEqual(displayText.actionTitle, "检查当前")
    }

    func testFullDiskAccessProbeUsesExistingProtectedLocations() {
        let state = ScanReadinessService.fullDiskAccessState(
            probePaths: [
                "/Users/tester/Library/Safari",
                "/Users/tester/Library/Mail"
            ],
            fileExists: { path in path.hasSuffix("/Safari") || path.hasSuffix("/Mail") },
            canReadDirectory: { path in path.hasSuffix("/Mail") }
        )

        XCTAssertEqual(state, .verified)
    }

    func testFolderAccessGrantPromptShowsOnlyBeforeSavedAccessOrSkip() throws {
        let suiteName = "FolderAccessGrantPromptTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        FolderAccessGrantService.reset(defaults: defaults)
        XCTAssertTrue(FolderAccessGrantService.shouldShowInitialPrompt(defaults: defaults))

        FolderAccessGrantService.markInitialPromptShown(defaults: defaults)
        XCTAssertFalse(FolderAccessGrantService.shouldShowInitialPrompt(defaults: defaults))

        FolderAccessGrantService.reset(defaults: defaults)
        defaults.set(
            ["/Users/tester/Documents": "stored-bookmark"],
            forKey: FolderAccessGrantService.bookmarksDefaultsKey
        )

        XCTAssertFalse(FolderAccessGrantService.shouldShowInitialPrompt(defaults: defaults))
        XCTAssertTrue(FolderAccessGrantService.hasSavedAccess(for: "/Users/tester/Documents/Work", defaults: defaults))
    }
}
