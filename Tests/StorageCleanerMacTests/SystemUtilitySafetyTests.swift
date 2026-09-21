import Foundation
import Combine
import Darwin
import XCTest
@testable import StorageCleanerMac

final class SystemUtilitySafetyTests: XCTestCase {
    @MainActor
    func testScanBusyGuardDoesNotMislabelOtherWorkAsCleanupPreparation() {
        let store = ScanStore()
        XCTAssertNil(store.activeScanStatusText)
        store.isScanningDuplicates = true
        XCTAssertTrue(store.isPreparingScan)
        XCTAssertFalse(store.isPreparingMainScan)
        XCTAssertEqual(store.activeScanStatusText, L10n.text("正在扫描重复文件", "Scanning duplicate files"))
        store.isScanningDuplicates = false
        store.isCheckingScanReadiness = true
        XCTAssertTrue(store.isPreparingMainScan)
        XCTAssertEqual(store.activeScanStatusText, L10n.text("正在检查扫描权限", "Checking scan access"))
        store.isCheckingScanReadiness = false
        XCTAssertFalse(store.isPreparingScan)
        XCTAssertNil(store.activeScanStatusText)
    }

    func testFirstLaunchAccessGuideOnlyAppearsOnceInTheApplicationHost() {
        XCTAssertTrue(FirstLaunchOnboardingPolicy.shouldPresent(isCompleted: false, isApplicationHost: true))
        XCTAssertFalse(FirstLaunchOnboardingPolicy.shouldPresent(isCompleted: true, isApplicationHost: true))
        XCTAssertFalse(FirstLaunchOnboardingPolicy.shouldPresent(isCompleted: false, isApplicationHost: false))
    }

#if DEBUG
    func testLayoutFramePreferenceKeyMergesDistinctProbesAndKeepsNewestFrame() {
        let original = CGRect(x: 10, y: 20, width: 30, height: 40)
        let replacement = CGRect(x: 11, y: 21, width: 31, height: 41)
        let second = CGRect(x: 50, y: 60, width: 70, height: 80)
        var value = ["workspace": original]

        LayoutFramePreferenceKey.reduce(value: &value) {
            ["workspace": replacement, "privacy": second]
        }

        XCTAssertEqual(value["workspace"], replacement)
        XCTAssertEqual(value["privacy"], second)
    }
#endif

    func testLaunchAgentManagementUsesStructuredLaunchctlWithoutEditingThirdPartyPlists() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/StartupItems/Management/UserLaunchAgentManager.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("[\"bootout\", serviceTarget]"))
        XCTAssertTrue(source.contains("[\"disable\", serviceTarget]"))
        XCTAssertTrue(source.contains("[\"enable\", serviceTarget]"))
        XCTAssertTrue(source.contains("[\"bootstrap\", domain, plistURL.path]"))
        XCTAssertFalse(source.contains("plist[\"Disabled\"]"))
        XCTAssertFalse(source.contains("/bin/sh"))
    }

    func testInstalledAppCanMoveToTrashOnlyForAppBundlesInAllowedRoots() {
        let app = InstalledAppItem(
            id: "/Applications/Test.app",
            name: "Test",
            bundleIdentifier: "com.example.test",
            path: "/Applications/Test.app",
            version: "1.0",
            build: "100",
            category: "工具",
            appDescription: "Test 是一款工具类 macOS 应用。",
            sizeBytes: 1,
            source: "Applications",
            modifiedAt: nil,
            relatedPaths: [],
            relatedItems: [],
            status: .installed
        )
        let supportFile = InstalledAppItem(
            id: "\(NSHomeDirectory())/Library/Application Support/Test",
            name: "Test Support",
            bundleIdentifier: "com.example.test",
            path: "\(NSHomeDirectory())/Library/Application Support/Test",
            version: "1.0",
            build: "100",
            category: "工具",
            appDescription: "Test Support 是一款工具类 macOS 应用。",
            sizeBytes: 1,
            source: "Support",
            modifiedAt: nil,
            relatedPaths: [],
            relatedItems: [],
            status: .installed
        )

        XCTAssertTrue(app.canMoveToTrash)
        XCTAssertFalse(supportFile.canMoveToTrash)
    }

    func testSetappManagedApplicationCanBeMovedToTrashInApp() {
        let app = InstalledAppItem(
            id: "/Applications/Setapp/AlDente Pro.app",
            name: "AlDente Pro",
            bundleIdentifier: "com.apphousekitchen.aldente-pro",
            path: "/Applications/Setapp/AlDente Pro.app",
            version: "1.0",
            build: "100",
            category: "工具",
            appDescription: "Setapp 管理的测试应用。",
            sizeBytes: 1,
            source: "Setapp",
            modifiedAt: nil,
            relatedPaths: [],
            relatedItems: [],
            status: .installed
        )

        XCTAssertEqual(app.externalManagementProviderName, "Setapp")
        XCTAssertTrue(app.canMoveToTrash)
        XCTAssertEqual(app.uninstallRecommendation, .keep)
        XCTAssertTrue(app.uninstallRecommendationReasons.contains { $0.contains("Setapp") })
        XCTAssertTrue(app.uninstallRecommendationReasons.contains {
            $0.contains("废纸篓") || $0.contains("Trash")
        })
    }

    func testSharedUninstallInventoryDiscoversNestedApplicationCollections() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root
            .appendingPathComponent("Setapp", isDirectory: true)
            .appendingPathComponent("Nested Tool.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.nested-tool",
            "CFBundleName": "Nested Tool",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let result = await AppUninstallService.scanInstalledAppsFromSharedInventory(
            directories: [ApplicationScanDirectory(url: root, maximumDepth: 3)],
            timeLimit: 5,
            maximumConcurrency: 2
        )

        XCTAssertEqual(result.coverage.discoveredCandidateCount, 1)
        XCTAssertEqual(result.apps.map(\.bundleIdentifier), ["com.example.nested-tool"])
    }

    func testAppUninstallRejectsAPathReplacedAfterScanning() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/StorageCleanerFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root
            .appendingPathComponent("Setapp", isDirectory: true)
            .appendingPathComponent("Replaceable.app", isDirectory: true)

        try writeTestApplication(
            at: appURL,
            bundleIdentifier: "com.example.replaceable",
            version: "1.0",
            build: "1"
        )
        let result = await AppUninstallService.scanInstalledAppsFromSharedInventory(
            directories: [ApplicationScanDirectory(url: root, maximumDepth: 3)],
            timeLimit: 5,
            maximumConcurrency: 1
        )
        let scanned = try XCTUnwrap(result.apps.first)
        XCTAssertNotNil(scanned.scanIdentity)
        XCTAssertTrue(UninstallCandidatePathPolicy.isSafeComponent(scanned.bundleIdentifier))
        XCTAssertEqual(scanned.scanIdentity, AppUninstallService.uninstallFileIdentity(at: scanned.path))
        XCTAssertNoThrow(try AppUninstallService.validateCurrentApplicationIdentity(scanned))

        try FileManager.default.removeItem(at: appURL)
        try writeTestApplication(
            at: appURL,
            bundleIdentifier: "com.example.replaceable",
            version: "1.0",
            build: "1"
        )

        XCTAssertThrowsError(try AppUninstallService.validateCurrentApplicationIdentity(scanned)) { error in
            guard case AppUninstallError.identityChanged = error else {
                return XCTFail("Expected identityChanged, got \(error)")
            }
        }
    }

    func testSharedUninstallInventoryKeepsExplicitManagedCollectionRoot() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Services/AppUninstallService.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("/Applications/Setapp"))
        XCTAssertTrue(source.contains("DirectoryApplicationScanner().scan"))
        XCTAssertFalse(source.contains("enumerator(atPath: \"/Applications/Setapp\")"))
    }

    func testLiveSetappUninstallInventoryWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["STORAGE_CLEANER_RUN_LIVE_SETAPP_SCAN"] == "1" else {
            throw XCTSkip("Set STORAGE_CLEANER_RUN_LIVE_SETAPP_SCAN=1 for the read-only Setapp inventory audit")
        }
        let setappURL = URL(fileURLWithPath: "/Applications/Setapp", isDirectory: true)
        guard FileManager.default.fileExists(atPath: setappURL.path) else {
            throw XCTSkip("Setapp collection is not installed")
        }

        let result = await AppUninstallService.scanInstalledAppsFromSharedInventory(
            directories: [ApplicationScanDirectory(url: setappURL, maximumDepth: 2)],
            timeLimit: 30,
            maximumConcurrency: 4
        )

        XCTAssertTrue(
            result.apps.contains { $0.bundleIdentifier == "com.apphousekitchen.aldente-pro-setapp" },
            "Setapp apps found: \(result.apps.map { $0.bundleIdentifier }.sorted())"
        )

        let fullResult = await AppUninstallService.scanInstalledAppsFromSharedInventory(
            timeLimit: 30,
            maximumConcurrency: 4
        )
        XCTAssertTrue(
            fullResult.apps.contains { $0.bundleIdentifier == "com.apphousekitchen.aldente-pro-setapp" },
            "Full inventory coverage: \(fullResult.coverage); found \(fullResult.apps.count) apps"
        )
    }

    func testInstalledAppTotalFootprintAddsRelatedItemsWithoutChangingTrashEligibility() {
        let app = InstalledAppItem(
            id: "/Applications/Test.app",
            name: "Test",
            bundleIdentifier: "com.example.test",
            path: "/Applications/Test.app",
            version: "1.0",
            build: "100",
            category: "工具",
            appDescription: "Test 是一款工具类 macOS 应用。",
            sizeBytes: 100,
            source: "Applications",
            modifiedAt: nil,
            relatedPaths: ["/tmp/TestCache", "/tmp/TestPrefs.plist"],
            relatedItems: [
                InstalledAppRelatedItem(path: "/tmp/TestCache", sizeBytes: 40),
                InstalledAppRelatedItem(path: "/tmp/TestPrefs.plist", sizeBytes: 5)
            ],
            status: .installed
        )

        XCTAssertEqual(app.relatedBytes, 45)
        XCTAssertEqual(app.totalFootprintBytes, 145)
        XCTAssertTrue(app.canMoveToTrash)
    }

    func testAppUninstallRelatedCleanupOnlyAllowsCommonUserLibraryRoots() {
        let home = NSHomeDirectory()

        XCTAssertTrue(AppUninstallService.isSafeRelatedPath("\(home)/Library/Application Support/com.example.Tool"))
        XCTAssertTrue(AppUninstallService.isSafeRelatedPath("\(home)/Library/Caches/com.example.Tool"))
        XCTAssertTrue(AppUninstallService.isSafeRelatedPath("\(home)/Library/Preferences/com.example.Tool.plist"))
        XCTAssertTrue(AppUninstallService.isSafeRelatedPath("\(home)/Library/Containers/com.example.Tool"))
        XCTAssertTrue(AppUninstallService.isSafeRelatedPath("\(home)/Library/Group Containers/com.example.Tool"))

        XCTAssertFalse(AppUninstallService.isSafeRelatedPath("\(home)/Downloads/com.example.Tool"))
        XCTAssertFalse(AppUninstallService.isSafeRelatedPath("/Applications/Tool.app"))
        XCTAssertFalse(AppUninstallService.isSafeRelatedPath("/tmp/com.example.Tool"))
    }

    func testInstalledAppDisplayDescriptionDetailRemovesRepeatedIntroduction() {
        let app = makeInstalledApp(
            name: "Dropover",
            appIntroduction: "Dropover 是用于临时文件暂存和拖拽整理的 macOS 应用。",
            appDescription: "Dropover 是用于临时文件暂存和拖拽整理的 macOS 应用。扫描信息：版本 1.0 · 开发者 Damir · me.damir.dropover-mac。"
        )

        XCTAssertEqual(
            app.displayDescriptionDetail,
            "扫描信息：版本 1.0 · 开发者 Damir · me.damir.dropover-mac。"
        )
    }

    func testInstalledAppDisplayDescriptionDetailHidesDuplicateDescription() {
        let app = makeInstalledApp(
            name: "Dropover",
            appIntroduction: "Dropover 是用于临时文件暂存和拖拽整理的 macOS 应用。",
            appDescription: "Dropover 是用于临时文件暂存和拖拽整理的 macOS 应用。"
        )

        XCTAssertNil(app.displayDescriptionDetail)
    }

    func testAppUninstallDescriptionUsesCategoryAndScanMetadata() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let description = AppUninstallService.appDescription(
            displayName: "Example App",
            source: "Applications",
            category: "开发工具",
            version: "1.2.3 (456)",
            bundleIdentifier: "com.example.app",
            info: [:]
        )

        XCTAssertTrue(description.contains("Example App"))
        XCTAssertTrue(description.contains("开发工具"))
        XCTAssertTrue(description.contains("1.2.3"))
        XCTAssertTrue(description.contains("com.example.app"))
    }

    func testAppUninstallDescriptionPrefersBundleDescription() {
        let description = AppUninstallService.appDescription(
            displayName: "Example App",
            source: "Applications",
            category: "工具",
            version: "",
            bundleIdentifier: "",
            info: [
                "CFBundleGetInfoString": "Example App helps organize project files and local documents."
            ]
        )

        XCTAssertTrue(description.hasPrefix("Example App helps organize project files"))
    }

    func testAppUninstallIntroductionUsesKnownBundlePurpose() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let introduction = AppUninstallService.appIntroduction(
            displayName: "Final Cut Pro",
            category: "视频",
            bundleIdentifier: "com.apple.FinalCutApp",
            developerName: "Apple",
            info: [:]
        )

        XCTAssertTrue(introduction.contains("视频剪辑"))
        XCTAssertTrue(introduction.contains("Final Cut Pro"))
    }

    func testAppUninstallIntroductionUsesKnownThirdPartyPurpose() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let introduction = AppUninstallService.appIntroduction(
            displayName: "Docker Desktop",
            category: "开发工具",
            bundleIdentifier: "com.docker.docker",
            developerName: "Docker",
            info: [:]
        )

        XCTAssertTrue(introduction.contains("容器运行"))
        XCTAssertTrue(introduction.contains("Docker Desktop"))
    }

    func testAppUninstallIntroductionUsesCategoryPurposeFallback() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let introduction = AppUninstallService.appIntroduction(
            displayName: "Unknown Studio",
            category: "效率",
            bundleIdentifier: "io.example.unknownstudio",
            developerName: "Example",
            info: [:]
        )

        XCTAssertTrue(introduction.contains("Unknown Studio"))
        XCTAssertTrue(introduction.contains("Example"))
        XCTAssertTrue(introduction.contains("任务整理"))
    }

    func testAppUninstallIntroductionPrefersSpotlightDescriptionOverLegalInfo() {
        let introduction = AppUninstallService.appIntroduction(
            displayName: "Example App",
            category: "工具",
            bundleIdentifier: "com.example.app",
            developerName: "Example",
            info: [
                "kMDItemDescription": "Example App helps review local projects and organize related files.",
                "CFBundleGetInfoString": "Copyright 2026 Example. All rights reserved."
            ]
        )

        XCTAssertEqual(introduction, "Example App helps review local projects and organize related files.")
    }

    func testAppUninstallDeveloperNameUsesKnownPrefixAndReverseDNSFallback() {
        XCTAssertEqual(AppUninstallService.developerName(for: "com.microsoft.VSCode"), "Microsoft")
        XCTAssertEqual(AppUninstallService.developerName(for: "me.damir.dropover-mac"), "Damir")
        XCTAssertEqual(AppUninstallService.developerName(for: "io.example.Tool"), "Example")
    }

    func testAppUninstallParsesSpotlightLastUsedDate() {
        XCTAssertNotNil(AppUninstallService.parseSpotlightDate("2026-06-22 14:05:31 +0000"))
        XCTAssertNil(AppUninstallService.parseSpotlightDate("(null)"))
        XCTAssertNil(AppUninstallService.parseSpotlightDate("null"))
    }

    func testAppUninstallListPresenterFiltersByOwnershipLeftoversAndSearchText() {
        let apple = makeInstalledApp(
            name: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            developerName: "Apple",
            appIntroduction: "Apple 平台应用开发",
            relatedBytes: 512
        )
        let thirdParty = makeInstalledApp(
            name: "Dropover",
            bundleIdentifier: "me.damir.dropover-mac",
            developerName: "Damir",
            appIntroduction: "临时文件暂存和拖拽整理",
            appDescription: "扫描描述：Dropover 可用于临时文件暂存、拖拽整理和桌面素材管理。",
            relatedBytes: 0
        )

        XCTAssertEqual(
            AppUninstallListPresenter.visibleApps(from: [apple, thirdParty], query: "", filter: .apple, sortMode: .name).map(\.name),
            ["Xcode"]
        )
        XCTAssertEqual(
            AppUninstallListPresenter.visibleApps(from: [apple, thirdParty], query: "", filter: .thirdParty, sortMode: .name).map(\.name),
            ["Dropover"]
        )
        XCTAssertEqual(
            AppUninstallListPresenter.visibleApps(from: [apple, thirdParty], query: "", filter: .withLeftovers, sortMode: .name).map(\.name),
            ["Xcode"]
        )
        XCTAssertEqual(
            AppUninstallListPresenter.visibleApps(from: [apple, thirdParty], query: "拖拽", filter: .all, sortMode: .name).map(\.name),
            ["Dropover"]
        )
        XCTAssertEqual(
            AppUninstallListPresenter.visibleApps(from: [apple, thirdParty], query: "素材管理", filter: .all, sortMode: .name).map(\.name),
            ["Dropover"]
        )
    }

    func testAppUninstallListPresenterSortsByLeftoversAndName() {
        let alpha = makeInstalledApp(name: "Alpha", relatedBytes: 100)
        let beta = makeInstalledApp(name: "Beta", relatedBytes: 400)
        let gamma = makeInstalledApp(name: "Gamma", relatedBytes: 400)

        XCTAssertEqual(
            AppUninstallListPresenter.visibleApps(from: [alpha, gamma, beta], query: "", filter: .all, sortMode: .leftovers).map(\.name),
            ["Beta", "Gamma", "Alpha"]
        )
        XCTAssertEqual(
            AppUninstallListPresenter.visibleApps(from: [gamma, beta, alpha], query: "", filter: .all, sortMode: .name).map(\.name),
            ["Alpha", "Beta", "Gamma"]
        )
    }

    func testAppUninstallListPresenterFiltersLongUnusedAndSortsUnknownLast() {
        let old = makeInstalledApp(name: "Old", lastUsedAt: Date(timeIntervalSinceNow: -160 * 24 * 60 * 60))
        let recent = makeInstalledApp(name: "Recent", lastUsedAt: Date(timeIntervalSinceNow: -4 * 24 * 60 * 60))
        let unknown = makeInstalledApp(name: "Unknown", lastUsedAt: nil)

        XCTAssertTrue(old.isLongUnused())
        XCTAssertFalse(recent.isLongUnused())
        XCTAssertFalse(unknown.isLongUnused())

        XCTAssertEqual(
            AppUninstallListPresenter.visibleApps(from: [recent, unknown, old], query: "", filter: .longUnused, sortMode: .name).map(\.name),
            ["Old"]
        )
        XCTAssertEqual(
            AppUninstallListPresenter.visibleApps(from: [unknown, recent, old], query: "", filter: .all, sortMode: .lastUsed).map(\.name),
            ["Old", "Recent", "Unknown"]
        )
    }

    func testAppUninstallRecommendationProtectsAppleApps() {
        let app = makeInstalledApp(
            name: "Final Cut Pro",
            bundleIdentifier: "com.apple.FinalCutApp",
            developerName: "Apple",
            sizeBytes: 8_000_000_000,
            relatedBytes: 2_000_000_000,
            lastUsedAt: Date(timeIntervalSinceNow: -160 * 24 * 60 * 60)
        )

        XCTAssertEqual(app.uninstallRecommendation, .protected)
        XCTAssertLessThan(app.uninstallReviewScore, 45)
        XCTAssertTrue(app.uninstallRecommendationReasons.contains { $0.contains("Apple") })
    }

    func testAppUninstallRecommendationPromotesLongUnusedLargeThirdPartyApps() {
        let app = makeInstalledApp(
            name: "Old Studio",
            bundleIdentifier: "com.example.oldstudio",
            developerName: "Example",
            sizeBytes: 6_000_000_000,
            relatedBytes: 1_500_000_000,
            lastUsedAt: Date(timeIntervalSinceNow: -180 * 24 * 60 * 60)
        )

        XCTAssertEqual(app.uninstallRecommendation, .candidate)
        XCTAssertGreaterThanOrEqual(app.uninstallReviewScore, 70)
        XCTAssertTrue(app.uninstallRecommendationReasons.contains { $0.contains("60") })
    }

    func testAppUninstallSuggestionStartsAtSixtyDaysWithoutSizeRequirement() {
        let referenceDate = Date()
        let app = makeInstalledApp(
            name: "Quiet Tool",
            sizeBytes: 1_000,
            lastUsedAt: referenceDate.addingTimeInterval(-60 * 24 * 60 * 60)
        )

        XCTAssertTrue(app.isLongUnused(referenceDate: referenceDate))
        XCTAssertEqual(app.uninstallRecommendation, .candidate)
        XCTAssertNotNil(app.uninstallSuggestionReason)
    }

    func testAppStoreRatingsRemainReferenceAndDoNotDriveUninstall() throws {
        let chrome = makeInstalledApp(
            name: "Chrome",
            bundleIdentifier: "com.google.Chrome",
            lastUsedAt: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
        )
        let firefox = makeInstalledApp(
            name: "Firefox",
            bundleIdentifier: "org.mozilla.firefox",
            lastUsedAt: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
        )
        let brave = makeInstalledApp(
            name: "Brave",
            bundleIdentifier: "com.brave.Browser",
            lastUsedAt: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
        )
        let entries = [
            chrome.bundleIdentifier: AppStoreCatalogEntry(
                bundleIdentifier: chrome.bundleIdentifier,
                version: ApplicationVersion(marketing: "1"),
                productURL: try XCTUnwrap(URL(string: "https://apps.apple.com/app/chrome/id1")),
                sellerName: nil,
                releaseDate: nil,
                releaseNotes: nil,
                downloadSize: nil,
                averageUserRating: 3.7,
                userRatingCount: 240
            ),
            firefox.bundleIdentifier: AppStoreCatalogEntry(
                bundleIdentifier: firefox.bundleIdentifier,
                version: ApplicationVersion(marketing: "1"),
                productURL: try XCTUnwrap(URL(string: "https://apps.apple.com/app/firefox/id2")),
                sellerName: nil,
                releaseDate: nil,
                releaseNotes: nil,
                downloadSize: nil,
                averageUserRating: 4.6,
                userRatingCount: 900
            ),
            brave.bundleIdentifier: AppStoreCatalogEntry(
                bundleIdentifier: brave.bundleIdentifier,
                version: ApplicationVersion(marketing: "1"),
                productURL: try XCTUnwrap(URL(string: "https://apps.apple.com/app/brave/id3")),
                sellerName: nil,
                releaseDate: nil,
                releaseNotes: nil,
                downloadSize: nil,
                averageUserRating: 1.0,
                userRatingCount: 4
            ),
        ]

        let enriched = AppUninstallService.applyAppStoreRatings(entries, to: [firefox, chrome, brave])
        let enrichedChrome = try XCTUnwrap(enriched.first { $0.name == "Chrome" })
        let enrichedFirefox = try XCTUnwrap(enriched.first { $0.name == "Firefox" })
        let enrichedBrave = try XCTUnwrap(enriched.first { $0.name == "Brave" })

        XCTAssertEqual(enrichedChrome.uninstallRecommendation, .keep)
        XCTAssertNotNil(enrichedChrome.uninstallRatingComparison)
        XCTAssertNil(enrichedChrome.uninstallSuggestionReason)
        XCTAssertNil(enrichedFirefox.uninstallRatingComparison)
        XCTAssertEqual(enrichedFirefox.uninstallRecommendation, .keep)
        XCTAssertNil(enrichedBrave.uninstallRatingComparison)
        XCTAssertEqual(enrichedBrave.uninstallRecommendation, .keep)
        XCTAssertNil(AppUninstallSimilarityGroup.resolve(bundleIdentifier: "com.example.productivity"))
        XCTAssertNil(AppUninstallSimilarityGroup.resolve(bundleIdentifier: "com.google.ChromeRemoteDesktop"))
    }

    func testAppUninstallRecommendationKeepsRecentlyUsedApps() {
        let app = makeInstalledApp(
            name: "Daily Tool",
            bundleIdentifier: "com.example.daily",
            developerName: "Example",
            sizeBytes: 300_000_000,
            relatedBytes: 0,
            lastUsedAt: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
        )

        XCTAssertEqual(app.uninstallRecommendation, .keep)
        XCTAssertLessThan(app.uninstallReviewScore, 45)
    }

    func testAppUninstallPresenterFiltersAndSortsByRecommendation() {
        let keep = makeInstalledApp(
            name: "Daily",
            sizeBytes: 300_000_000,
            lastUsedAt: Date(timeIntervalSinceNow: -1 * 24 * 60 * 60)
        )
        let review = makeInstalledApp(
            name: "Medium",
            sizeBytes: 2_000_000_000,
            relatedBytes: 600_000_000,
            lastUsedAt: Date(timeIntervalSinceNow: -70 * 24 * 60 * 60)
        )
        let candidate = makeInstalledApp(
            name: "Archive",
            sizeBytes: 8_000_000_000,
            relatedBytes: 2_000_000_000,
            lastUsedAt: Date(timeIntervalSinceNow: -200 * 24 * 60 * 60)
        )

        XCTAssertEqual(
            AppUninstallListPresenter.visibleApps(from: [keep, review, candidate], query: "", filter: .reviewRecommended, sortMode: .name).map(\.name),
            ["Archive", "Medium"]
        )
        XCTAssertEqual(
            AppUninstallListPresenter.visibleApps(from: [review, keep, candidate], query: "", filter: .all, sortMode: .recommendation).map(\.name),
            ["Archive", "Medium", "Daily"]
        )
    }

    func testInstalledAppInsightCardsSummarizePurposeUsageAndLeftovers() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let app = makeInstalledApp(
            name: "Archive Studio",
            appIntroduction: "Archive Studio 用于整理旧项目素材。",
            appDescription: "Archive Studio 用于整理旧项目素材。扫描信息：版本 1.0 · 开发者 Example · com.example.archivestudio。",
            sizeBytes: 6_000_000_000,
            relatedBytes: 1_200_000_000,
            lastUsedAt: Date(timeIntervalSinceNow: -150 * 24 * 60 * 60)
        )

        let cards = app.uninstallInsightCards

        XCTAssertEqual(cards.map(\.kind), [.introduction, .description, .scan, .usage, .leftovers])
        XCTAssertTrue(cards.contains { $0.kind == .introduction && $0.detail.contains("旧项目素材") })
        XCTAssertTrue(cards.contains { $0.kind == .description && $0.detail.contains("扫描信息") })
        XCTAssertTrue(cards.contains { $0.kind == .scan && $0.detail.contains("卸载确认时可一并移到废纸篓") })
        XCTAssertTrue(cards.contains { $0.kind == .usage && $0.detail.contains("超过 60 天") })
        XCTAssertTrue(cards.contains { $0.kind == .leftovers && $0.detail.contains("卸载确认时可一并移到废纸篓") })
    }

    func testInstalledAppInsightCardsUseGreenLeftoverToneWhenNoCommonLeftovers() {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let app = makeInstalledApp(name: "Daily Tool", relatedBytes: 0)

        let leftoverCard = app.uninstallInsightCards.first { $0.kind == .leftovers }

        XCTAssertEqual(leftoverCard?.tone, .green)
        XCTAssertTrue(leftoverCard?.detail.localizedCaseInsensitiveContains("No common associated files") == true)
    }

    func testAppUninstallCategoryTitleMapsKnownCategory() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        XCTAssertEqual(
            AppUninstallService.categoryTitle(for: "public.app-category.developer-tools"),
            "开发工具"
        )
    }

    func testUtilityListExportMarkdownIncludesUninstallBoundaryAndLeftovers() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let app = makeInstalledApp(
            name: "Old Tool",
            developerName: "Example",
            sizeBytes: 1_000,
            relatedBytes: 2_000
        )

        let markdown = UtilityListExportService.installedAppsMarkdown(
            for: [app],
            generatedAt: Date(timeIntervalSince1970: 1_786_000_000)
        )

        XCTAssertTrue(markdown.contains("# 应用卸载清单"))
        XCTAssertTrue(markdown.contains("应用文件和关联文件一起移到废纸篓"))
        XCTAssertTrue(markdown.contains("复制或导出只会生成复核清单"))
        XCTAssertTrue(markdown.contains("不会卸载应用、移动关联文件或清空废纸篓"))
        XCTAssertTrue(markdown.contains(ByteFormat.string(app.totalFootprintBytes)))
        XCTAssertTrue(markdown.contains("Old Tool"))
        XCTAssertTrue(markdown.contains("/tmp/Old Tool-cache"))
    }

    func testUninstallPreviewDefersAssociatedFilesUntilAfterAppRemoval() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let utilitySource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"),
            encoding: .utf8
        )
        let contentSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/ContentView.swift"),
            encoding: .utf8
        )
        let storeSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift"),
            encoding: .utf8
        )
        let serviceSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/AppUninstallService.swift"),
            encoding: .utf8
        )
        let previewStart = try XCTUnwrap(utilitySource.range(of: "struct UninstallPreviewSheet: View"))
        let previewEnd = try XCTUnwrap(
            utilitySource.range(of: "private struct UninstallPreviewAppIcon: View", range: previewStart.upperBound..<utilitySource.endIndex)
        )
        let previewSource = String(utilitySource[previewStart.lowerBound..<previewEnd.lowerBound])

        XCTAssertTrue(previewSource.contains("应用会先移到废纸篓"))
        XCTAssertFalse(previewSource.contains("relatedItems"))
        XCTAssertFalse(previewSource.contains("关联文件"))
        XCTAssertTrue(contentSource.contains("是否清除关联文件？"))
        XCTAssertTrue(contentSource.contains("store.confirmRelatedAppCleanup()"))
        XCTAssertTrue(storeSource.contains("try AppUninstallService.moveToTrash(app)"))
        XCTAssertTrue(storeSource.contains("pendingRelatedCleanupApp = app"))
        XCTAssertTrue(serviceSource.contains("static func moveRelatedItemsToTrash(for app:"))
    }

    func testUninstallRowKeepsDirectButtonAndShowsOnlySuggestionReason() throws {
        let viewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let source = try String(contentsOf: viewURL, encoding: .utf8)
        let rowStart = try XCTUnwrap(source.range(of: "private struct InstalledAppRow: View"))
        let rowEnd = try XCTUnwrap(
            source.range(of: "private struct InstalledAppIcon", range: rowStart.upperBound..<source.endIndex)
        )
        let rowSource = String(source[rowStart.lowerBound..<rowEnd.lowerBound])

        XCTAssertEqual(rowSource.components(separatedBy: "store.requestUninstall(app)").count - 1, 1)
        XCTAssertTrue(rowSource.contains(".contextMenu {"))
        let contextActions = try XCTUnwrap(rowSource.components(separatedBy: ".contextMenu {").last)
        XCTAssertTrue(contextActions.contains("store.copyPath(app.path)"))
        XCTAssertTrue(contextActions.contains("store.reveal(app.path)"))
        XCTAssertFalse(contextActions.contains("requestUninstall"))
        XCTAssertTrue(rowSource.contains("查看卸载计划"))
        XCTAssertTrue(rowSource.contains("uninstallSuggestionReason"))
        XCTAssertTrue(rowSource.contains("建议卸载"))
        XCTAssertTrue(rowSource.contains("来源：\\(provider)"))
        XCTAssertFalse(rowSource.contains("openExternalAppManager"))
        XCTAssertFalse(rowSource.contains("related"))
    }

    func testUninstallPageUsesOneInAppTrashEligibilityFilter() throws {
        let viewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let source = try String(contentsOf: viewURL, encoding: .utf8)
        let viewStart = try XCTUnwrap(source.range(of: "struct AppUninstallerView: View"))
        let viewEnd = try XCTUnwrap(
            source.range(of: "private struct InstalledAppRow: View", range: viewStart.upperBound..<source.endIndex)
        )
        let viewSource = String(source[viewStart.lowerBound..<viewEnd.lowerBound])

        XCTAssertTrue(viewSource.contains("store.installedApps.filter(\\.canMoveToTrash)"))
        XCTAssertTrue(viewSource.contains("apps: manageableApps"))
        XCTAssertFalse(viewSource.contains("openExternalAppManager"))
    }

    func testActionMessagesSeparateTrashMoveFromFreedSpace() throws {
        let storeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift")
        let source = try String(contentsOf: storeURL, encoding: .utf8)

        XCTAssertTrue(source.contains("已移到废纸篓，清空前可恢复"))
        XCTAssertTrue(source.contains("\\(movedCount) 个可安全清理项目已移到废纸篓，清空后才释放空间"))
        XCTAssertTrue(source.contains("已将 \\(app.name) 移到废纸篓，清空前可恢复"))
        XCTAssertTrue(source.contains("清空后才释放空间"))
        XCTAssertTrue(source.contains("space is freed after Trash is emptied"))
        XCTAssertFalse(source.contains("已清理 \\(movedCount) 项绿色缓存"))
        XCTAssertFalse(source.contains("Cleaned \\(L10n.items(movedCount)) marked green"))
    }

    func testMemoryByteAggregationClampsOverflowInsteadOfWrapping() {
        let result = MemoryByteMath.sum([Int64.max - 10, 100])

        XCTAssertEqual(result.value, Int64.max)
        XCTAssertTrue(result.clamped)
        XCTAssertEqual(MemoryByteMath.signedDifference(Int64.max, -1), Int64.max)
        XCTAssertEqual(MemoryByteMath.signedDifference(Int64.min, 1), Int64.min)
    }

    func testMemoryProcessExplainsQuitBoundaryForAppsAndSystemProcesses() {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let appProcess = MemoryProcess(
            id: 100,
            name: "Example App",
            path: "/Applications/Example.app/Contents/MacOS/Example",
            iconPath: "/Applications/Example.app",
            bundlePath: "/Applications/Example.app",
            residentBytes: 512_000_000,
            percent: 3.2,
            canQuit: true
        )
        let systemProcess = MemoryProcess(
            id: 101,
            name: "kernel_task",
            path: "/usr/bin/kernel_task",
            iconPath: "/usr/bin/kernel_task",
            bundlePath: nil,
            residentBytes: 1_024_000_000,
            percent: 6.4,
            canQuit: false
        )
        let bundledSystemProcess = MemoryProcess(
            id: 102,
            name: "chronod",
            path: "/System/Library/PrivateFrameworks/ChronoCore.framework/Support/chronod",
            iconPath: "/System/Library/PrivateFrameworks/ChronoCore.framework",
            bundlePath: "/System/Library/PrivateFrameworks/ChronoCore.framework",
            residentBytes: 1_024_000_000,
            percent: 6.4,
            canQuit: false
        )

        XCTAssertEqual(appProcess.processKindTitle, "Application")
        XCTAssertTrue(appProcess.isUserApplication)
        XCTAssertTrue(appProcess.quitHint.localizedCaseInsensitiveContains("normal quit"))
        XCTAssertEqual(appProcess.memoryShareTitle, "3.2%")
        XCTAssertTrue(appProcess.isRecommendedQuitCandidate)
        XCTAssertEqual(appProcess.quitImpactTitle, "Low impact")
        XCTAssertEqual(systemProcess.processKindTitle, "System Process")
        XCTAssertFalse(systemProcess.isUserApplication)
        XCTAssertTrue(systemProcess.quitHint.localizedCaseInsensitiveContains("cannot be quit"))
        XCTAssertFalse(systemProcess.isRecommendedQuitCandidate)
        XCTAssertEqual(systemProcess.quitImpactTitle, "Read-only")
        XCTAssertEqual(bundledSystemProcess.processKindTitle, "System Process")
        XCTAssertFalse(bundledSystemProcess.isUserApplication)
    }

    func testMemoryOptimizationResultTracksObservedAvailabilityDelta() {
        let before = makeMemorySnapshot(reclaimableBytes: 1_500_000_000)
        let after = makeMemorySnapshot(reclaimableBytes: 900_000_000)
        let result = MemoryOptimizationResult(
            beforeSnapshot: before,
            snapshot: after,
            status: .completed,
            detail: "",
            durationSeconds: 0.4
        )

        XCTAssertEqual(result.freeDeltaBytes, after.freeBytes - before.freeBytes)
        XCTAssertEqual(result.absoluteFreeDeltaBytes, abs(after.freeBytes - before.freeBytes))
        XCTAssertEqual(result.availableDeltaBytes, after.availableBytes - before.availableBytes)
        XCTAssertEqual(result.absoluteAvailableDeltaBytes, abs(after.availableBytes - before.availableBytes))
        XCTAssertEqual(result.releasedBytes, max(0, after.availableBytes - before.availableBytes))
    }

    func testMemorySnapshotBuildsActionableAdviceFromQuitCandidates() {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let smallApp = MemoryProcess(
            id: 200,
            name: "Small App",
            path: "/Applications/Small.app/Contents/MacOS/Small",
            iconPath: "/Applications/Small.app",
            bundlePath: "/Applications/Small.app",
            residentBytes: 128 * 1024 * 1024,
            percent: 0.8,
            canQuit: true
        )
        let heavyApp = MemoryProcess(
            id: 201,
            name: "Heavy App",
            path: "/Applications/Heavy.app/Contents/MacOS/Heavy",
            iconPath: "/Applications/Heavy.app",
            bundlePath: "/Applications/Heavy.app",
            residentBytes: 2_000 * 1024 * 1024,
            percent: 12.5,
            canQuit: true
        )
        let systemProcess = MemoryProcess(
            id: 202,
            name: "kernel_task",
            path: "/usr/bin/kernel_task",
            iconPath: "/usr/bin/kernel_task",
            bundlePath: nil,
            residentBytes: 4_000 * 1024 * 1024,
            percent: 25,
            canQuit: false
        )
        let snapshot = MemorySnapshot(
            generatedAt: Date(),
            physicalBytes: 16_000 * 1024 * 1024,
            freeBytes: 4_000 * 1024 * 1024,
            inactiveBytes: 1_000 * 1024 * 1024,
            speculativeBytes: 500 * 1024 * 1024,
            fileBackedBytes: 1_200 * 1024 * 1024,
            purgeableBytes: 300 * 1024 * 1024,
            wiredBytes: 2_000 * 1024 * 1024,
            compressedBytes: 1_000 * 1024 * 1024,
            swapUsedBytes: 0,
            pressureFreePercentage: 80,
            pressureSummary: "Free 25%",
            topProcesses: [systemProcess, smallApp, heavyApp]
        )

        XCTAssertEqual(snapshot.quitCandidates.map(\.name), ["Heavy App"])
        XCTAssertEqual(snapshot.quitCandidateBytes, heavyApp.residentBytes)
        XCTAssertEqual(heavyApp.quitImpactTitle, "High impact")
        XCTAssertTrue(snapshot.memoryAdviceTitle.localizedCaseInsensitiveContains("quit"))
        XCTAssertEqual(snapshot.cleanupPlan.primaryAction, .quitHighUsageApps)
    }

    func testMemoryQuitSuggestionsProtectCommunicationAndSyncApps() {
        let weChat = MemoryProcess(
            id: 210,
            name: "WeChat",
            path: "/Applications/WeChat.app/Contents/MacOS/WeChat",
            iconPath: "/Applications/WeChat.app",
            bundlePath: "/Applications/WeChat.app",
            residentBytes: 2_000 * 1024 * 1024,
            percent: 12.5,
            canQuit: true
        )
        let editor = MemoryProcess(
            id: 211,
            name: "Video Editor",
            path: "/Applications/Video Editor.app/Contents/MacOS/Video Editor",
            iconPath: "/Applications/Video Editor.app",
            bundlePath: "/Applications/Video Editor.app",
            residentBytes: 2_000 * 1024 * 1024,
            percent: 12.5,
            canQuit: true
        )
        let mail = MemoryProcess(
            id: 212,
            name: "Mail",
            path: "/System/Applications/Mail.app/Contents/MacOS/Mail",
            iconPath: "/System/Applications/Mail.app",
            bundlePath: "/System/Applications/Mail.app",
            residentBytes: 2_000 * 1024 * 1024,
            percent: 12.5,
            canQuit: true
        )
        let dropbox = MemoryProcess(
            id: 213,
            name: "Dropbox",
            path: "/Applications/Dropbox.app/Contents/MacOS/Dropbox",
            iconPath: "/Applications/Dropbox.app",
            bundlePath: "/Applications/Dropbox.app",
            residentBytes: 2_000 * 1024 * 1024,
            percent: 12.5,
            canQuit: true
        )
        let snapshot = MemorySnapshot(
            generatedAt: Date(),
            physicalBytes: 16_000 * 1024 * 1024,
            freeBytes: 1_000 * 1024 * 1024,
            inactiveBytes: 500 * 1024 * 1024,
            speculativeBytes: 0,
            fileBackedBytes: 0,
            purgeableBytes: 0,
            wiredBytes: 2_000 * 1024 * 1024,
            compressedBytes: 2_000 * 1024 * 1024,
            swapUsedBytes: 0,
            pressureFreePercentage: 12,
            pressureSummary: "Free 12%",
            topProcesses: [weChat, mail, dropbox, editor]
        )

        XCTAssertEqual(snapshot.quitCandidateApps.map(\.name), ["Video Editor"])
        XCTAssertEqual(snapshot.recommendedQuitApps.map(\.name), ["Video Editor"])

        let emptyResult = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0,
            system: makeSnapshot(),
            groups: [],
            items: [],
            deniedPaths: []
        )
        let mixedTasks = SmartMaintenanceService.tasks(
            result: emptyResult,
            appUpdateCount: 0,
            hasScannedAppUpdates: true,
            startupItemCount: 0,
            hasScannedStartupItems: true,
            memorySnapshot: snapshot,
            hasScannedDuplicates: true,
            duplicateCount: 0
        )
        XCTAssertEqual(mixedTasks.filter { $0.id == "review-memory-apps" }.count, 1)

        let protectedOnlySnapshot = MemorySnapshot(
            generatedAt: Date(),
            physicalBytes: 16_000 * 1024 * 1024,
            freeBytes: 1_000 * 1024 * 1024,
            inactiveBytes: 500 * 1024 * 1024,
            speculativeBytes: 0,
            fileBackedBytes: 0,
            purgeableBytes: 0,
            wiredBytes: 2_000 * 1024 * 1024,
            compressedBytes: 2_000 * 1024 * 1024,
            swapUsedBytes: 0,
            pressureFreePercentage: 12,
            pressureSummary: "Free 12%",
            topProcesses: [weChat, mail, dropbox]
        )
        let protectedOnlyTasks = SmartMaintenanceService.tasks(
            result: emptyResult,
            appUpdateCount: 0,
            hasScannedAppUpdates: true,
            startupItemCount: 0,
            hasScannedStartupItems: true,
            memorySnapshot: protectedOnlySnapshot,
            hasScannedDuplicates: true,
            duplicateCount: 0
        )
        XCTAssertFalse(protectedOnlyTasks.contains { $0.id == "review-memory-apps" })
    }

    func testMemorySnapshotBuildsSelectableQuitListByResidentUsage() {
        let smallApp = MemoryProcess(
            id: 300,
            name: "Small App",
            path: "/Applications/Small.app/Contents/MacOS/Small",
            iconPath: "/Applications/Small.app",
            bundlePath: "/Applications/Small.app",
            residentBytes: 128 * 1024 * 1024,
            percent: 0.8,
            canQuit: true
        )
        let mediumApp = MemoryProcess(
            id: 301,
            name: "Medium App",
            path: "/Applications/Medium.app/Contents/MacOS/Medium",
            iconPath: "/Applications/Medium.app",
            bundlePath: "/Applications/Medium.app",
            residentBytes: 800 * 1024 * 1024,
            percent: 5,
            canQuit: true
        )
        let largeApp = MemoryProcess(
            id: 302,
            name: "Large App",
            path: "/Applications/Large.app/Contents/MacOS/Large",
            iconPath: "/Applications/Large.app",
            bundlePath: "/Applications/Large.app",
            residentBytes: 2_000 * 1024 * 1024,
            percent: 12.5,
            canQuit: true
        )
        let systemProcess = MemoryProcess(
            id: 303,
            name: "kernel_task",
            path: "/usr/bin/kernel_task",
            iconPath: "/usr/bin/kernel_task",
            bundlePath: nil,
            residentBytes: 4_000 * 1024 * 1024,
            percent: 25,
            canQuit: false
        )
        let snapshot = MemorySnapshot(
            generatedAt: Date(),
            physicalBytes: 16_000 * 1024 * 1024,
            freeBytes: 4_000 * 1024 * 1024,
            inactiveBytes: 1_000 * 1024 * 1024,
            speculativeBytes: 500 * 1024 * 1024,
            fileBackedBytes: 1_200 * 1024 * 1024,
            purgeableBytes: 300 * 1024 * 1024,
            wiredBytes: 2_000 * 1024 * 1024,
            compressedBytes: 1_000 * 1024 * 1024,
            swapUsedBytes: 0,
            pressureFreePercentage: 80,
            pressureSummary: "Free 25%",
            topProcesses: [mediumApp, systemProcess, smallApp, largeApp]
        )

        XCTAssertEqual(snapshot.processesByResidentUsage.map(\.name), ["kernel_task", "Large App", "Medium App", "Small App"])
        XCTAssertEqual(snapshot.selectableQuitProcesses.map(\.name), ["Large App", "Medium App", "Small App"])
        XCTAssertEqual(snapshot.selectableQuitBytes, largeApp.residentBytes + mediumApp.residentBytes + smallApp.residentBytes)
        XCTAssertEqual(snapshot.appsByResidentUsage.first?.name, "kernel_task")
    }

    func testMemorySnapshotTreatsFileCacheAsAvailableMemory() {
        let snapshot = MemorySnapshot(
            generatedAt: Date(),
            physicalBytes: 16_000 * 1024 * 1024,
            freeBytes: 1_000 * 1024 * 1024,
            inactiveBytes: 4_000 * 1024 * 1024,
            speculativeBytes: 500 * 1024 * 1024,
            fileBackedBytes: 3_000 * 1024 * 1024,
            purgeableBytes: 1_000 * 1024 * 1024,
            wiredBytes: 2_000 * 1024 * 1024,
            compressedBytes: 1_000 * 1024 * 1024,
            swapUsedBytes: 0,
            pressureFreePercentage: 80,
            pressureSummary: "Free 25%",
            topProcesses: []
        )

        XCTAssertEqual(snapshot.cachedEstimateBytes, 3_000 * 1024 * 1024)
        XCTAssertEqual(snapshot.availableBytes, 4_000 * 1024 * 1024)
        XCTAssertEqual(snapshot.usedBytes, 12_000 * 1024 * 1024)
        XCTAssertEqual(snapshot.pressureLevel, .normal)
    }

    func testMemoryPressureSummaryUsesReadableFreePercentage() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let output = """
        The system has 51539607552 (3145728 pages with a page size of 16384).
        System-wide memory free percentage: 72%
        """

        let reading = MemoryOptimizerService.pressureSummary(from: output)
        XCTAssertEqual(reading.summary, "压力余量 72%")
        XCTAssertEqual(reading.freePercentage, 72)
        let emptyReading = MemoryOptimizerService.pressureSummary(from: "")
        XCTAssertEqual(emptyReading.summary, "压力数据不可用")
        XCTAssertNil(emptyReading.freePercentage)
    }

    func testMemoryPressureKeepsSystemStateSeparateFromHeadroomEstimate() {
        let snapshot = makeMemorySnapshot(
            reclaimableBytes: 4_000_000_000,
            pressureFreePercentage: 45
        )
        let newerSnapshot = makeMemorySnapshot(
            reclaimableBytes: 4_000_000_000,
            pressureFreePercentage: 77
        )
        let invalidSnapshot = makeMemorySnapshot(
            reclaimableBytes: 4_000_000_000,
            pressureFreePercentage: 101
        )
        let headroomUnavailableMeasurements = MemoryMeasurements(
            pressure: .available(.normal),
            physicalBytes: .available(16_000_000_000),
            availableBytes: .available(9_000_000_000),
            appBytes: .available(0),
            wiredBytes: .available(1_000_000_000),
            compressedBytes: .available(1_000_000_000),
            cachedBytes: .available(8_000_000_000),
            swapUsedBytes: .available(0),
            swapInRate: .unavailable(.temporarilyInvalid, reason: "Not needed"),
            swapOutRate: .unavailable(.temporarilyInvalid, reason: "Not needed")
        )
        let headroomUnavailableSnapshot = makeMemorySnapshot(
            reclaimableBytes: 8_000_000_000,
            pressureFreePercentage: nil,
            measurements: headroomUnavailableMeasurements
        )
        let fullyUnavailableSnapshot = makeMemorySnapshot(
            reclaimableBytes: 8_000_000_000,
            pressureFreePercentage: nil
        )

        XCTAssertEqual(snapshot.pressureLevel, .normal)
        XCTAssertEqual(snapshot.pressureHeadroomPercent, 45)
        XCTAssertEqual(snapshot.pressureEstimatePercent, 55)
        XCTAssertEqual(snapshot.reportablePressureLevel, .normal)
        XCTAssertEqual(newerSnapshot.pressureHeadroomPercent, 77)
        XCTAssertEqual(newerSnapshot.pressureEstimatePercent, 23)
        XCTAssertNil(invalidSnapshot.pressureHeadroomPercent)
        XCTAssertNil(invalidSnapshot.pressureEstimatePercent)
        XCTAssertNil(invalidSnapshot.reportablePressureLevel)
        XCTAssertEqual(headroomUnavailableSnapshot.pressureLevel, .normal)
        XCTAssertNil(headroomUnavailableSnapshot.pressureHeadroomPercent)
        XCTAssertEqual(headroomUnavailableSnapshot.reportablePressureLevel, .normal)
        XCTAssertNil(fullyUnavailableSnapshot.reportablePressureLevel)
    }

    func testUnavailableSwapMeasurementIsNotRepresentedAsARealZero() {
        let metric = MemoryMeasurement<UInt64>.unavailable(
            .permissionDenied,
            reason: "Permission revoked"
        )

        XCTAssertNil(metric.value)
        XCTAssertEqual(metric.availability, .permissionDenied)
        XCTAssertEqual(metric.reason, "Permission revoked")
    }

    func testMemorySnapshotDoesNotOfferCacheReclaimAtAnyPressure() {
        let normal = makeMemorySnapshot(reclaimableBytes: 4_000_000_000)
        let elevated = makeMemorySnapshot(
            reclaimableBytes: 4_000_000_000,
            pressureFreePercentage: 10,
            compressedBytes: 4_000_000_000
        )

        XCTAssertEqual(normal.pressureLevel, .normal)
        XCTAssertEqual(normal.cleanupPlan.primaryAction, .observe)
        XCTAssertEqual(elevated.pressureLevel, .elevated)
        XCTAssertEqual(elevated.cleanupPlan.primaryAction, .observe)
        XCTAssertEqual(elevated.cleanupPlan.estimatedRecoverableBytes, 0)
    }

    func testMemoryPressureDoesNotTreatHistoricalSwapAsCurrentPressureWhenAvailableMemoryIsHealthy() {
        let snapshot = makeMemorySnapshot(
            reclaimableBytes: 7_000_000_000,
            pressureFreePercentage: 80,
            compressedBytes: 5_000_000_000,
            swapUsedBytes: 5_000_000_000
        )

        XCTAssertEqual(snapshot.availableRatio, 0.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.pressureLevel, .normal)
        XCTAssertEqual(snapshot.cleanupPlan.primaryAction, .observe)
    }

    func testMemoryCleanupPlanPrefersQuitAppsWhenCacheReclaimIsTooSmall() {
        let heavyApp = MemoryProcess(
            id: 4_001,
            name: "Heavy App",
            path: "/Applications/Heavy.app/Contents/MacOS/Heavy",
            iconPath: "/Applications/Heavy.app",
            bundlePath: "/Applications/Heavy.app",
            residentBytes: 2_000_000_000,
            percent: 12.5,
            canQuit: true
        )
        let snapshot = MemorySnapshot(
            generatedAt: Date(),
            physicalBytes: 16_000_000_000,
            freeBytes: 900_000_000,
            inactiveBytes: 0,
            speculativeBytes: 0,
            fileBackedBytes: 128_000_000,
            purgeableBytes: 0,
            wiredBytes: 2_000_000_000,
            compressedBytes: 4_000_000_000,
            swapUsedBytes: 256_000_000,
            pressureFreePercentage: 8,
            pressureSummary: "Pressure",
            topProcesses: [heavyApp]
        )

        XCTAssertEqual(snapshot.pressureLevel, .elevated)
        XCTAssertEqual(snapshot.cleanupPlan.primaryAction, .quitHighUsageApps)
    }

    func testMemorySnapshotGroupsProcessesByApplicationBundle() {
        let helper = MemoryProcess(
            id: 5_001,
            name: "Example",
            path: "/Applications/Example.app/Contents/MacOS/helper",
            iconPath: "/Applications/Example.app",
            bundlePath: "/Applications/Example.app",
            residentBytes: 300_000_000,
            percent: 1.8,
            canQuit: true
        )
        let renderer = MemoryProcess(
            id: 5_002,
            name: "Example",
            path: "/Applications/Example.app/Contents/MacOS/renderer",
            iconPath: "/Applications/Example.app",
            bundlePath: "/Applications/Example.app",
            residentBytes: 500_000_000,
            percent: 3.1,
            canQuit: true
        )
        let snapshot = MemorySnapshot(
            generatedAt: Date(),
            physicalBytes: 16_000_000_000,
            freeBytes: 4_000_000_000,
            inactiveBytes: 0,
            speculativeBytes: 0,
            fileBackedBytes: 1_000_000_000,
            purgeableBytes: 0,
            wiredBytes: 1_000_000_000,
            compressedBytes: 0,
            swapUsedBytes: 0,
            pressureFreePercentage: 80,
            pressureSummary: "Normal",
            topProcesses: [helper, renderer]
        )

        XCTAssertEqual(snapshot.appsByResidentUsage.count, 1)
        XCTAssertEqual(snapshot.appsByResidentUsage.first?.bytes, 800_000_000)
        XCTAssertEqual(snapshot.appsByResidentUsage.first?.processCount, 2)
        XCTAssertEqual(Set(snapshot.appsByResidentUsage.first?.selectableProcessIDs ?? []), Set<Int32>([5_001, 5_002]))
        XCTAssertEqual(snapshot.quitCandidateApps.map(\.name), ["Example"])
        XCTAssertEqual(snapshot.recommendedQuitApps.map(\.name), ["Example"])
        XCTAssertEqual(snapshot.recommendedQuitProcessIDs, Set<Int32>([5_001, 5_002]))

        var activeRenderer = renderer
        activeRenderer.isActive = true
        let activeSnapshot = MemorySnapshot(
            generatedAt: snapshot.generatedAt,
            physicalBytes: snapshot.physicalBytes,
            freeBytes: snapshot.freeBytes,
            inactiveBytes: snapshot.inactiveBytes,
            speculativeBytes: snapshot.speculativeBytes,
            fileBackedBytes: snapshot.fileBackedBytes,
            purgeableBytes: snapshot.purgeableBytes,
            wiredBytes: snapshot.wiredBytes,
            compressedBytes: snapshot.compressedBytes,
            swapUsedBytes: snapshot.swapUsedBytes,
            pressureFreePercentage: snapshot.pressureFreePercentage,
            pressureSummary: snapshot.pressureSummary,
            topProcesses: [helper, activeRenderer]
        )
        XCTAssertTrue(activeSnapshot.appsByResidentUsage.first?.isActive == true)
        XCTAssertTrue(activeSnapshot.recommendedQuitApps.isEmpty)
    }

    func testMemorySnapshotDoesNotMarkCandidatesSuggestedWhenNoActionIsNeeded() {
        let chrome = MemoryProcess(
            id: 6_001,
            name: "Chrome",
            path: "/Applications/Chrome.app/Contents/MacOS/Chrome",
            iconPath: "/Applications/Chrome.app",
            bundlePath: "/Applications/Chrome.app",
            residentBytes: 980_000_000,
            percent: 2,
            canQuit: true
        )
        let secondApp = MemoryProcess(
            id: 6_002,
            name: "Second",
            path: "/Applications/Second.app/Contents/MacOS/Second",
            iconPath: "/Applications/Second.app",
            bundlePath: "/Applications/Second.app",
            residentBytes: 920_000_000,
            percent: 1.9,
            canQuit: true
        )
        let snapshot = MemorySnapshot(
            generatedAt: Date(),
            physicalBytes: 48_000_000_000,
            freeBytes: 10_000_000_000,
            inactiveBytes: 0,
            speculativeBytes: 0,
            fileBackedBytes: 12_000_000_000,
            purgeableBytes: 0,
            wiredBytes: 4_000_000_000,
            compressedBytes: 1_000_000_000,
            swapUsedBytes: 0,
            pressureFreePercentage: 50,
            pressureSummary: "Normal",
            topProcesses: [chrome, secondApp]
        )

        XCTAssertEqual(snapshot.quitCandidateApps.count, 2)
        XCTAssertEqual(snapshot.cleanupPlan.primaryAction, .observe)
        XCTAssertTrue(snapshot.recommendedQuitApps.isEmpty)
        XCTAssertTrue(snapshot.recommendedQuitProcessIDs.isEmpty)
    }

    func testShellCaptureTimesOutSlowCommand() {
        let started = Date()

        XCTAssertThrowsError(try Shell.capture("/bin/sleep", ["2"], timeout: 0.1)) { error in
            guard case ShellError.timedOut = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testShellRunReturnsSeparateOutputAndNonzeroStatus() throws {
        let result = try Shell.run(
            "/bin/sh",
            ["-c", "printf standard; printf failure >&2; exit 7"],
            timeout: 1
        )

        XCTAssertEqual(result.terminationStatus, 7)
        XCTAssertEqual(result.standardOutput, "standard")
        XCTAssertEqual(result.standardError, "failure")
        XCTAssertEqual(result.combinedOutput, "standardfailure")
    }

    func testShellTimeoutDoesNotWaitForInheritedOutputDescriptor() {
        let started = Date()

        XCTAssertThrowsError(
            try Shell.capture(
                "/bin/sh",
                ["-c", "trap '' TERM; (sleep 5) & wait"],
                timeout: 0.05
            )
        ) { error in
            guard case ShellError.timedOut = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testShellTimeoutTerminatesDescendantProcesses() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerMac-shell-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        XCTAssertThrowsError(
            try Shell.capture(
                "/bin/sh",
                [
                    "-c",
                    "sleep 5 & child=$!; printf '%s' \"$child\" > \"$1\"; trap '' TERM; wait",
                    "StorageCleanerMacShellTest",
                    pidFile.path
                ],
                timeout: 0.1
            )
        ) { error in
            guard case ShellError.timedOut = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
        }

        let childPID = try XCTUnwrap(
            Int32(String(contentsOf: pidFile, encoding: .utf8).trimmed)
        )
        var childIsAlive = true
        for _ in 0..<20 {
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pidinfo(childPID, PROC_PIDTBSDINFO, 0, pointer, infoSize)
            }
            if result <= 0 || info.pbi_status == UInt32(SZOMB) {
                childIsAlive = false
                break
            }
            usleep(50_000)
        }

        XCTAssertFalse(childIsAlive, "Timed-out commands must not leave descendant processes running")
    }

    @MainActor
    func testScanReadinessTimeoutRestoresControls() async throws {
        let store = ScanStore(
            scanReadinessTimeout: .milliseconds(25),
            loadScanReadinessSummary: {
                Thread.sleep(forTimeInterval: 0.2)
                return ScanReadinessSummary(items: [])
            }
        )

        store.refreshScanReadiness(showCompletionMessage: true)
        XCTAssertTrue(store.isCheckingScanReadiness)

        try await Task.sleep(for: .milliseconds(80))

        XCTAssertFalse(store.isCheckingScanReadiness)
        XCTAssertNotNil(store.actionMessage)
        XCTAssertNil(store.scanReadinessSummary)
    }

    @MainActor
    func testRepeatedReadinessChecksReuseOnePhysicalOperationAfterUITimeout() async throws {
        let counter = ThreadSafeInvocationCounter()
        let completionGate = DispatchSemaphore(value: 0)
        defer { completionGate.signal() }
        let store = ScanStore(
            scanReadinessTimeout: .milliseconds(20),
            loadScanReadinessSummary: {
                counter.increment()
                completionGate.wait()
                return ScanReadinessSummary(items: [])
            }
        )

        store.refreshScanReadiness()
        for _ in 0..<200 where counter.value == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(counter.value, 1)
        for _ in 0..<200 where store.isCheckingScanReadiness {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.isCheckingScanReadiness)

        store.refreshScanReadiness()
        for _ in 0..<200 where store.isCheckingScanReadiness {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(counter.value, 1)
        XCTAssertFalse(store.isCheckingScanReadiness)
    }

    @MainActor
    func testFolderAccessRestoreTimeoutDoesNotBlockScanningForever() async throws {
        UserDefaults.standard.set(true, forKey: ScanStore.initialPermissionCheckDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: ScanStore.initialPermissionCheckDefaultsKey) }

        let store = ScanStore(
            folderAccessRestoreTimeout: .milliseconds(25),
            restoreSavedAccessOperation: {
                Thread.sleep(forTimeInterval: 0.2)
            }
        )

        store.prepareInitialPermissionCheckOnLaunch()
        XCTAssertTrue(store.isCheckingScanReadiness)

        try await Task.sleep(for: .milliseconds(80))

        XCTAssertFalse(store.isCheckingScanReadiness)
        XCTAssertFalse(store.isPreparingScan)
    }

    func testAppUninstallCoverageDistinguishesCompleteAndLimitedResults() {
        let complete = AppUninstallScanCoverage(
            discoveredCandidateCount: 40,
            examinedCandidateCount: 40,
            didReachCandidateLimit: false,
            didReachTimeLimit: false,
            didReachResultLimit: false
        )
        let limited = AppUninstallScanCoverage(
            discoveredCandidateCount: 400,
            examinedCandidateCount: 120,
            didReachCandidateLimit: true,
            didReachTimeLimit: true,
            didReachResultLimit: false
        )

        XCTAssertTrue(complete.isComplete)
        XCTAssertFalse(limited.isComplete)
    }

    func testRuntimeRecoveryAndBuildCleanupGuardsRemainPresent() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let monitorSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/SystemMonitorService.swift"),
            encoding: .utf8
        )
        let temperatureSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/AppleSiliconTemperatureService.swift"),
            encoding: .utf8
        )
        let folderAccessSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/FolderAccessGrantService.swift"),
            encoding: .utf8
        )
        let storeSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift"),
            encoding: .utf8
        )
        let buildScript = try String(
            contentsOf: projectRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )
        let releaseScript = try String(
            contentsOf: projectRoot.appendingPathComponent("script/make_release_dmg.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(monitorSource.contains("gpuSampleTimeout"))
        XCTAssertTrue(monitorSource.contains("thermalSampleTimeout"))
        XCTAssertTrue(monitorSource.contains("guard generation == gpuSampleGeneration"))
        XCTAssertTrue(monitorSource.contains("guard generation == thermalSampleGeneration"))
        XCTAssertTrue(temperatureSource.contains("TemperatureClientStore"))
        XCTAssertTrue(temperatureSource.contains("retryInterval: TimeInterval = 30"))
        XCTAssertTrue(monitorSource.contains("Keep a physical single-flight"))
        XCTAssertTrue(folderAccessSource.contains("guard restoreActivityLock.try() else { return [] }"))
        XCTAssertTrue(folderAccessSource.contains("currentBookmarks[removal.path] == removal.originalValue"))
        XCTAssertTrue(folderAccessSource.contains("currentBookmarks[replacement.originalPath] == replacement.originalValue"))
        XCTAssertTrue(storeSource.contains("scanReadinessPhysicalTask"))
        XCTAssertTrue(storeSource.contains("Exactly one completion watcher belongs to each physical task"))
        XCTAssertTrue(buildScript.contains("prepare_swift_build_dir \"$SWIFT_BUILD_DIR\""))
        XCTAssertTrue(buildScript.contains("\"$parent\" != \"/tmp\""))
        XCTAssertTrue(releaseScript.contains("safe_remove_generated_build_path \"$SWIFT_BUILD_DIR\""))
        XCTAssertTrue(releaseScript.contains("safe_remove_generated_build_path \"$BUILD_ROOT\""))
        XCTAssertTrue(releaseScript.contains("direct storage-cleaner-* child of /tmp"))
    }

    func testPotentiallyBlockingUtilitiesHaveDeadlinesAndRunOffMainActor() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let uninstallSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/AppUninstallService.swift"),
            encoding: .utf8
        )
        let startupScanSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/StartupItems/Scanning/StartupScanning.swift"
            ),
            encoding: .utf8
        )
        let startupManagementSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/StartupItems/Management/StartupProcessRunner.swift"
            ),
            encoding: .utf8
        )
        let storeSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift"),
            encoding: .utf8
        )
        let memorySource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/MemoryOptimizerService.swift"),
            encoding: .utf8
        )
        let memoryProbeSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Features/Memory/Infrastructure/SystemMemoryProbe.swift"),
            encoding: .utf8
        )
        let updateSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/AppUpdateService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(uninstallSource.contains("timeLimit: TimeInterval = 30"))
        XCTAssertTrue(uninstallSource.contains("deadline.timeIntervalSinceNow"))
        XCTAssertTrue(uninstallSource.contains("timeout: min(0.5, remaining)"))
        XCTAssertTrue(uninstallSource.contains("guard Date() < deadline else { break }"))
        XCTAssertTrue(startupScanSource.contains("commandTimeout: TimeInterval = 4"))
        XCTAssertTrue(startupScanSource.contains("cleanupWaitTimeout: 1"))
        XCTAssertTrue(startupManagementSource.contains("timeout: timeout"))
        XCTAssertTrue(startupManagementSource.contains("withTaskCancellationHandler"))
        XCTAssertTrue(storeSource.contains("try await Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(storeSource.contains("FolderAccessGrantService.restoreSavedAccess()"))
        XCTAssertTrue(storeSource.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(memoryProbeSource.contains("timeout: 2"))
        XCTAssertFalse(memorySource.contains("/usr/sbin/purge"))
        XCTAssertFalse(memorySource.contains("Process()"))
        XCTAssertTrue(updateSource.contains("Shell.run(executable, arguments, timeout: timeoutSeconds)"))
        XCTAssertFalse(updateSource.contains("let process = Process()"))
    }

    func testAppUpdaterDetectsAppStoreBeforeSparkle() {
        let method = AppUpdateService.updateMethod(
            for: ["SUFeedURL": "https://example.com/appcast.xml"],
            hasAppStoreReceipt: true
        )

        XCTAssertEqual(method, .appStore)
    }

    func testAppUpdaterDetectsHomebrewBeforeSparkle() {
        let method = AppUpdateService.updateMethod(
            for: ["SUFeedURL": "https://example.com/appcast.xml"],
            hasAppStoreReceipt: false,
            homebrewToken: "example-cask"
        )

        XCTAssertEqual(method, .homebrew)
    }

    func testAppUpdaterKeepsAppStoreBeforeHomebrew() {
        let method = AppUpdateService.updateMethod(
            for: [:],
            hasAppStoreReceipt: true,
            homebrewToken: "example-cask"
        )

        XCTAssertEqual(method, .appStore)
    }

    func testAppUpdaterFormatsShortVersionAndBuild() {
        XCTAssertEqual(
            AppUpdateService.versionDisplay(shortVersion: "1.2.3", buildVersion: "456"),
            "1.2.3 (456)"
        )
        XCTAssertEqual(
            AppUpdateService.versionDisplay(shortVersion: "1.2.3", buildVersion: "1.2.3"),
            "1.2.3"
        )
    }

    func testAppUpdaterParsesAppStoreOutdatedVersions() throws {
        let output = """
        {"bundleID":"com.example.one","version":"1.0","newVersion":"1.2"}
        {"bundleID":"com.example.two","version":"4.5","newVersion":"4.6"}
        """

        let entries = AppUpdateService.appStoreOutdatedByBundleIdentifier(from: output)

        XCTAssertEqual(entries["com.example.one"], AppStoreOutdatedInfo(currentVersion: "1.0", latestVersion: "1.2"))
        XCTAssertEqual(entries["com.example.two"], AppStoreOutdatedInfo(currentVersion: "4.5", latestVersion: "4.6"))
    }

    func testAppUpdaterMergesLocalAppStoreUpdatesWithoutMakingThemAutomatic() throws {
        let app = makeAppUpdateItem(
            name: "Store App",
            method: .appStore,
            latestVersion: ""
        )
        let updates = [
            app.bundleIdentifier: AppStoreOutdatedInfo(
                currentVersion: "1.0",
                latestVersion: "1.2"
            ),
        ]

        let merged = try XCTUnwrap(
            AppUpdateService.mergingAppStoreOutdated(updates, into: [app]).first
        )

        XCTAssertEqual(merged.availableVersion, ApplicationVersion(marketing: "1.2"))
        XCTAssertEqual(merged.effectiveVersionCheckState, .updateAvailable)
        XCTAssertEqual(merged.effectiveUpdateCapability, .appStoreManaged)
        XCTAssertFalse(merged.canAutomaticallyUpdate)
        XCTAssertTrue(merged.requiresUserInteraction)
        XCTAssertTrue(merged.sourceEvidence.contains("mas-outdated"))
    }

    func testAppUpdaterParsesHomebrewOutdatedVersions() throws {
        let output = """
        {
          "formulae": [],
          "casks": [
            {
              "name": "example-app",
              "installed_versions": ["1.0"],
              "current_version": "1.3",
              "pinned": false
            }
          ]
        }
        """

        let entries = AppUpdateService.homebrewOutdatedByToken(from: output)

        XCTAssertEqual(entries["example-app"], HomebrewOutdatedInfo(installedVersion: "1.0", latestVersion: "1.3"))
    }

    func testAppUpdaterRequiresLatestVersionForScanCandidate() {
        let missingLatest = makeAppUpdateItem(name: "Store", method: .appStore, latestVersion: "")
        let hasLatest = makeAppUpdateItem(name: "Store", method: .appStore, latestVersion: "1.1")

        XCTAssertFalse(AppUpdateService.isConfirmedUpdate(missingLatest))
        XCTAssertTrue(AppUpdateService.isConfirmedUpdate(hasLatest))
    }

    func testAppUpdaterHidesAlreadyCurrentVersionAfterRescan() {
        let alreadyCurrent = makeAppUpdateItem(name: "Store", method: .appStore, latestVersion: "1.0")
        let newer = makeAppUpdateItem(name: "Store", method: .appStore, latestVersion: "1.0.1")

        XCTAssertFalse(AppUpdateService.isConfirmedUpdate(alreadyCurrent))
        XCTAssertTrue(AppUpdateService.isConfirmedUpdate(newer))
    }

    func testAppUpdateItemSeparatesOneClickReadyFromReviewOnlySources() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let appStore = makeAppUpdateItem(name: "Store", method: .appStore)
        let homebrew = makeAppUpdateItem(name: "Brew", method: .homebrew, caskToken: "brew-app")
        let homebrewMissingToken = makeAppUpdateItem(name: "Brew Missing", method: .homebrew, caskToken: nil)
        let sparkle = makeAppUpdateItem(name: "Sparkle", method: .sparkle)
        let manual = makeAppUpdateItem(name: "Manual", method: .manual)

        XCTAssertFalse(appStore.canRunInOneClickUpdate)
        XCTAssertTrue(homebrew.canRunInOneClickUpdate)
        XCTAssertFalse(homebrewMissingToken.canRunInOneClickUpdate)
        XCTAssertFalse(sparkle.canRunInOneClickUpdate)
        XCTAssertFalse(manual.canRunInOneClickUpdate)
        XCTAssertTrue(appStore.updateHandlingDetail.contains("App Store"))
        XCTAssertFalse(appStore.updateHandlingDetail.contains("mas"))
        XCTAssertTrue(homebrew.updateHandlingDetail.contains("受控更新队列"))
        XCTAssertTrue(sparkle.updateHandlingDetail.contains("内置更新器"))
    }

    func testAppUpdateIgnoreOnlyHidesTheSameLatestVersion() throws {
        let suiteName = "StorageCleanerMacTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let current = makeAppUpdateItem(name: "Store", method: .appStore, latestVersion: "1.1")
        let newer = makeAppUpdateItem(name: "Store", method: .appStore, latestVersion: "1.2")

        XCTAssertFalse(AppUpdateIgnoreService.isIgnored(current, defaults: defaults))
        AppUpdateIgnoreService.ignore(current, defaults: defaults)

        XCTAssertTrue(AppUpdateIgnoreService.isIgnored(current, defaults: defaults))
        XCTAssertFalse(AppUpdateIgnoreService.isIgnored(newer, defaults: defaults))

        AppUpdateIgnoreService.clear(defaults: defaults)
        XCTAssertFalse(AppUpdateIgnoreService.isIgnored(current, defaults: defaults))
    }

    func testAppUpdateSourcePreferencesRoundTrip() throws {
        let suiteName = "StorageCleanerMacTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(AppUpdateSourcePreferences.configuration(defaults: defaults), .all)

        AppUpdateSourcePreferences.set(.appStore, isEnabled: false, defaults: defaults)
        AppUpdateSourcePreferences.set(.sparkle, isEnabled: false, defaults: defaults)

        let configuration = AppUpdateSourcePreferences.configuration(defaults: defaults)
        XCTAssertFalse(configuration.includes(.appStore))
        XCTAssertTrue(configuration.includes(.homebrew))
        XCTAssertFalse(configuration.includes(.sparkle))
        XCTAssertTrue(configuration.includes(.manual))

        AppUpdateSourcePreferences.reset(defaults: defaults)
        XCTAssertEqual(AppUpdateSourcePreferences.configuration(defaults: defaults), .all)
    }

    func testSettingsUpdateSourceEmptyNoticeSeparatesDisabledSourcesFromPermissions() throws {
        let settingsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Views/SettingsView.swift")
        let source = try String(contentsOf: settingsURL, encoding: .utf8)

        XCTAssertTrue(source.contains("关闭更新来源只停止对应远程检查"))
        XCTAssertTrue(source.contains("不影响存储清理助手自身的 Sparkle 更新"))
        XCTAssertTrue(source.contains("Disabling an update source only stops its remote checks"))
        XCTAssertTrue(source.contains("it does not affect Storage Cleaner's own Sparkle updates"))
    }

    func testSettingsLaunchAtLoginUsesServiceManagementAndExplainsSessionRestore() throws {
        let settingsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Views/SettingsView.swift")
        let source = try String(contentsOf: settingsURL, encoding: .utf8)

        XCTAssertTrue(source.contains("SMAppService.mainApp.register()") || source.contains("try service.register()"))
        XCTAssertTrue(source.contains("try service.unregister()"))
        XCTAssertTrue(source.contains("登录后自动打开存储清理助手"))
        XCTAssertTrue(source.contains("应用不会加入 macOS 的登录会话恢复列表"))
    }

    func testAppUpdateCandidateFilteringHonorsSourceConfiguration() {
        let appStore = makeAppUpdateItem(name: "Store", method: .appStore)
        let homebrew = makeAppUpdateItem(name: "Brew", method: .homebrew, caskToken: "brew-app")
        let sparkle = makeAppUpdateItem(name: "Sparkle", method: .sparkle)
        let manual = makeAppUpdateItem(name: "Manual", method: .manual)
        let configuration = AppUpdateSourceConfiguration(enabledMethods: [.homebrew, .manual])

        let candidates = AppUpdateService.confirmedUpdateCandidates(
            [manual, sparkle, homebrew, appStore],
            configuration: configuration
        )

        XCTAssertEqual(candidates.map(\.name), ["Brew", "Manual"])
    }

    func testUtilityListExportMarkdownIncludesAppUpdateVersionsAndBoundary() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let homebrew = makeAppUpdateItem(
            name: "Brew Tool",
            method: .homebrew,
            caskToken: "brew-tool",
            latestVersion: "2.0"
        )
        let manual = makeAppUpdateItem(name: "Manual Tool", method: .manual)

        let markdown = UtilityListExportService.appUpdatesMarkdown(
            for: [homebrew, manual],
            generatedAt: Date(timeIntervalSince1970: 1_786_000_000)
        )

        XCTAssertTrue(markdown.contains("# 应用更新清单"))
        XCTAssertTrue(markdown.contains("不代表已经完成更新"))
        XCTAssertTrue(markdown.contains("复制或导出只会生成复核清单"))
        XCTAssertTrue(markdown.contains("不会打开更新器、运行命令或确认版本变化"))
        XCTAssertTrue(markdown.contains("当前版本"))
        XCTAssertTrue(markdown.contains("最新版本"))
        XCTAssertTrue(markdown.contains("Brew Tool"))
        XCTAssertTrue(markdown.contains("brew upgrade --cask brew-tool"))
        XCTAssertTrue(markdown.contains("2.0"))
        XCTAssertTrue(markdown.contains("Manual Tool"))
    }

    func testOneClickPlanGroupsUpdateSources() {
        let appStore = makeAppUpdateItem(name: "Store", method: .appStore)
        let homebrew = makeAppUpdateItem(name: "Brew", method: .homebrew, caskToken: "brew-app")
        let sparkle = makeAppUpdateItem(name: "Sparkle", method: .sparkle)
        let manual = makeAppUpdateItem(name: "Manual", method: .manual)

        let plan = AppUpdateService.oneClickPlan(for: [manual, sparkle, homebrew, appStore])

        XCTAssertEqual(plan.appStoreApps.map(\.name), ["Store"])
        XCTAssertEqual(plan.automaticApps.map(\.name), ["Brew"])
        XCTAssertEqual(plan.sparkleApps.map(\.name), ["Sparkle"])
        XCTAssertEqual(plan.manualApps.map(\.name), ["Manual"])
        XCTAssertEqual(plan.totalCount, 4)
        XCTAssertEqual(plan.automaticCount, 1)
        XCTAssertEqual(plan.manualReviewCount, 2)
        XCTAssertTrue(plan.hasAutomaticUpdates)
    }

    func testOneClickHomebrewCommandDeduplicatesAndSortsTokens() {
        let zed = makeAppUpdateItem(name: "Zed", method: .homebrew, caskToken: "zed")
        let duplicate = makeAppUpdateItem(name: "Zed Copy", method: .homebrew, caskToken: "zed")
        let alpha = makeAppUpdateItem(name: "Alpha", method: .homebrew, caskToken: "alpha")

        XCTAssertEqual(
            AppUpdateService.homebrewUpgradeArguments(for: [zed, duplicate, alpha]),
            ["upgrade", "--cask", "alpha", "zed"]
        )
        XCTAssertEqual(
            AppUpdateService.homebrewUpgradeCommand(for: [zed, duplicate, alpha]),
            "brew upgrade --cask alpha zed"
        )
    }

    func testOneClickManualReviewListIncludesOnlyManualConfirmationApps() {
        let sparkle = makeAppUpdateItem(name: "Sparkle", method: .sparkle)
        let manual = makeAppUpdateItem(name: "Manual", method: .manual)
        let homebrew = makeAppUpdateItem(name: "Brew", method: .homebrew, caskToken: "brew-app")
        let plan = AppUpdateService.oneClickPlan(for: [sparkle, manual, homebrew])

        let list = AppUpdateService.manualReviewList(for: plan)

        XCTAssertTrue(list.contains("Sparkle"))
        XCTAssertTrue(list.contains("Manual"))
        XCTAssertFalse(list.contains("Brew"))
    }

    func testAppStoreUpdateServiceDoesNotExposeMasWriteCommands() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Services/AppUpdateService.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("runAppStoreUpgrade"))
        XCTAssertFalse(source.contains("appStoreUpgradeCommand"))
        XCTAssertFalse(source.contains("mas update"))
        XCTAssertTrue(source.contains("macappstore://showUpdatesPage"))
    }

    func testOneClickHomebrewRunReportsUnavailableForMissingExecutable() {
        let app = makeAppUpdateItem(name: "Brew", method: .homebrew, caskToken: "brew-app")
        let result = AppUpdateService.runHomebrewUpgrade(
            for: [app],
            brewPath: "/tmp/storage-cleaner-missing-brew",
            timeoutSeconds: 0.1
        )

        XCTAssertEqual(result.status, .unavailable)
    }

    func testOneClickHomebrewRunDetectsTerminalAuthorizationRequirement() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let brew = root.appendingPathComponent("brew")
        let script = """
        #!/bin/sh
        echo "sudo: a terminal is required to read the password" >&2
        echo "sudo: a password is required" >&2
        exit 1
        """
        try Data(script.utf8).write(to: brew)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)

        let app = makeAppUpdateItem(name: "Brew", method: .homebrew, caskToken: "brew-app")
        let result = AppUpdateService.runHomebrewUpgrade(
            for: [app],
            brewPath: brew.path,
            timeoutSeconds: 10
        )

        XCTAssertEqual(result.status, .needsTerminal)
        XCTAssertTrue(AppUpdateService.shouldContinueHomebrewInTerminal(result))
        XCTAssertTrue(AppUpdateService.needsInteractiveTerminal("sudo: a terminal is required to read the password"))
        XCTAssertTrue(result.detail.contains("终端") || result.detail.localizedCaseInsensitiveContains("terminal"))
    }

    func testOneClickHomebrewSuccessAsksForRescanBeforeClaimingVersions() throws {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let brew = root.appendingPathComponent("brew")
        let script = """
        #!/bin/sh
        exit 0
        """
        try Data(script.utf8).write(to: brew)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)

        let app = makeAppUpdateItem(name: "Brew", method: .homebrew, caskToken: "brew-app")
        let result = AppUpdateService.runHomebrewUpgrade(
            for: [app],
            brewPath: brew.path,
            timeoutSeconds: 10
        )

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertTrue(result.detail.contains("重新检查更新列表确认版本"))
        XCTAssertEqual(AppUpdateExecutionStatus.succeeded.title, "命令完成")
    }

    func testOneClickSummarySeparatesCommandCompletionFromVersionConfirmation() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let result = AppUpdateOneClickResult(
            launched: AppUpdateOneClickLaunchResult(openedAppStore: false, copiedManualReviewList: false),
            appStore: AppUpdateAppStoreRunResult(status: .skipped, command: nil, detail: "跳过"),
            automatic: AppUpdateAutomaticRunResult(status: .succeeded, command: "brew upgrade --cask brew-app", detail: "完成"),
            generatedAt: Date()
        )

        let summary = AppUpdateService.oneClickSummary(result: result)

        XCTAssertTrue(summary.contains("重新检查确认版本"))
        XCTAssertFalse(summary.contains("更新已完成"))
    }

    func testOneClickAppStoreResultDoesNotReportOpenedWhenLaunchFails() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let app = makeAppUpdateItem(name: "Store App", method: .appStore)
        let plan = AppUpdateService.oneClickPlan(for: [app])
        let launch = AppUpdateOneClickLaunchResult(openedAppStore: false, copiedManualReviewList: false)

        let appStore = AppUpdateService.appStoreRunResult(for: plan, launched: launch)
        let result = AppUpdateOneClickResult(
            launched: launch,
            appStore: appStore,
            automatic: AppUpdateAutomaticRunResult(status: .skipped, command: nil, detail: "跳过"),
            generatedAt: Date()
        )

        XCTAssertEqual(appStore.status, .failed)
        XCTAssertTrue(appStore.detail.contains("未能打开"))
        XCTAssertFalse(appStore.detail.contains("已打开"))
        XCTAssertTrue(AppUpdateService.oneClickSummary(result: result).contains("步骤失败"))
        XCTAssertFalse(AppUpdateService.oneClickSummary(result: result).contains("已打开"))
    }

    func testOneClickAppStoreResultReportsOpenedOnlyAfterSuccessfulLaunch() {
        let app = makeAppUpdateItem(name: "Store App", method: .appStore)
        let plan = AppUpdateService.oneClickPlan(for: [app])
        let launch = AppUpdateOneClickLaunchResult(openedAppStore: true, copiedManualReviewList: false)

        let result = AppUpdateService.appStoreRunResult(for: plan, launched: launch)

        XCTAssertEqual(result.status, .opened)
    }

    func testUpdateEntryMessagesDoNotClaimUpdatesCompleted() throws {
        let serviceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Services/AppUpdateService.swift")
        let source = try String(contentsOf: serviceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("需要授权时由系统窗口确认"))
        XCTAssertTrue(source.contains("复制不代表已执行"))
        XCTAssertTrue(source.contains("仍需在应用内或官网确认"))
        XCTAssertTrue(source.contains("尚未确认版本已更新"))
        XCTAssertTrue(source.contains("仍需按终端提示完成后重新检查"))
        XCTAssertTrue(source.contains("复制不代表已更新"))
    }

    func testStatusCopyDoesNotOverstateFreshnessActionsOrMemoryHealth() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contentSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/ContentView.swift"),
            encoding: .utf8
        )
        let workspaceSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MainWorkspaceViews.swift"),
            encoding: .utf8
        )
        let utilitiesSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"),
            encoding: .utf8
        )
        let storeSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift"),
            encoding: .utf8
        )
        let appUpdatesSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(contentSource.contains("HeroScanPage("))
        XCTAssertTrue(workspaceSource.contains("只读扫描 · 清理前逐项确认"))
        XCTAssertFalse(contentSource.contains("上次扫描结果已就绪"))
        XCTAssertFalse(contentSource.contains("当前存储状态良好"))
        XCTAssertTrue(appUpdatesSource.contains("actionTitle: L10n.text(\"检查更新\", \"Check for Updates\")"))
        XCTAssertFalse(appUpdatesSource.contains("自动更新仅包含通过来源、版本与签名校验的项目"))
        XCTAssertTrue(appUpdatesSource.contains("guard let lastSummary else { return .idle(L10n.text(\"尚未检查更新\", \"Updates not checked\")) }"))
        XCTAssertFalse(appUpdatesSource.contains("更新来源已关闭"))
        XCTAssertTrue(utilitiesSource.contains("cleanupPlan.title"))
        XCTAssertFalse(utilitiesSource.contains("Memory Pressure Is Normal"))
        XCTAssertTrue(appSource.contains("预览安全清理项目"))
        XCTAssertFalse(appSource.contains("一键清理绿灯项"))
        XCTAssertTrue(storeSource.contains("未清空系统缓存，内存状态已刷新"))
        XCTAssertFalse(storeSource.contains("内存压力正常，已跳过缓存回收"))
    }

    func testOneClickSummaryTreatsTerminalLaunchAsStillNeedsConfirmation() {
        // A Terminal launch only starts the batch update; it must never be
        // summarized as a completed or successful update.
        let launchedResult = AppUpdateOneClickResult(
            launched: AppUpdateOneClickLaunchResult(
                openedAppStore: false,
                copiedManualReviewList: false
            ),
            appStore: AppUpdateCommandRunResult(
                status: .skipped,
                command: nil,
                detail: ""
            ),
            automatic: AppUpdateCommandRunResult(
                status: .launched,
                command: "brew upgrade",
                detail: ""
            ),
            generatedAt: Date(timeIntervalSince1970: 100)
        )

        let summary = AppUpdateService.oneClickSummary(result: launchedResult)

        XCTAssertTrue(summary.contains(
            L10n.text("仍需按终端提示完成后重新检查", "finish the Terminal prompts and check again")
        ))
        XCTAssertFalse(summary.contains(L10n.text("已完成", "completed")))
    }

    func testSystemSettingsDestinationsUseSystemPreferencesURLs() throws {
        let destinations: [CleanupService.SystemSettingsDestination] = [
            .storage,
            .loginItems,
            .fullDiskAccess,
            .filesAndFolders
        ]

        for destination in destinations {
            let url = try XCTUnwrap(CleanupService.systemSettingsURL(for: destination))
            XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        }

        XCTAssertTrue(
            try XCTUnwrap(CleanupService.systemSettingsURL(for: .fullDiskAccess)?.absoluteString)
                .contains("Privacy_AllFiles")
        )
        XCTAssertTrue(
            try XCTUnwrap(CleanupService.systemSettingsURL(for: .filesAndFolders)?.absoluteString)
                .contains("Privacy_FilesAndFolders")
        )
    }

    func testAppRuntimeLocationClassifiesInstallAndDevelopmentBundles() {
        XCTAssertEqual(
            AppRuntimeLocationService.kind(for: "/Applications/存储清理助手.app"),
            .applications
        )
        XCTAssertEqual(
            AppRuntimeLocationService.kind(for: "/Users/example/Documents/StorageCleanerMac/dist/StorageCleanerMac.app"),
            .developmentDist
        )
        XCTAssertEqual(
            AppRuntimeLocationService.kind(for: "/Users/example/Documents/StorageCleanerMac/.build/debug/StorageCleanerMac"),
            .buildProduct
        )
    }

    func testAppRuntimeInfoFormatsVersionAndIdentifier() {
        let info = AppRuntimeLocationService.info(
            bundlePath: "/Applications/存储清理助手.app",
            bundleIdentifier: "com.local.StorageCleanerMac",
            infoDictionary: [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "456"
            ]
        )

        XCTAssertEqual(info.kind, .applications)
        XCTAssertEqual(info.bundleIdentifier, "com.local.StorageCleanerMac")
        XCTAssertEqual(info.versionDisplay, "1.2.3 (456)")
    }

    func testAppRuntimeLocationTitlesExplainInstalledAndDevelopmentState() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        XCTAssertEqual(AppRuntimeLocationKind.applications.title, "已安装")
        XCTAssertEqual(AppRuntimeLocationKind.applications.detail, "正在从 /Applications 运行")
        XCTAssertEqual(AppRuntimeLocationKind.developmentDist.title, "开发版本")
        XCTAssertEqual(AppRuntimeLocationKind.buildProduct.title, "构建版本")
        XCTAssertEqual(AppRuntimeLocationKind.other.title, "非标准位置")
    }

    func testAppRuntimeDiagnosticsMarkdownIncludesVersionBundleAndPath() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let info = AppRuntimeLocationService.info(
            bundlePath: "/Applications/存储清理助手.app",
            bundleIdentifier: "com.local.StorageCleanerMac",
            infoDictionary: [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "456"
            ]
        )

        let markdown = info.diagnosticsMarkdown

        XCTAssertTrue(markdown.contains("1.2.3 (456)"))
        XCTAssertTrue(markdown.contains("Build: 456"))
        XCTAssertTrue(markdown.contains("Bundle ID: com.local.StorageCleanerMac"))
        XCTAssertTrue(markdown.contains("/Applications/存储清理助手.app"))
        XCTAssertTrue(markdown.contains("分发状态"))
        XCTAssertTrue(markdown.contains("Developer ID"))
        XCTAssertTrue(markdown.contains("Apple 公证"))
        XCTAssertTrue(markdown.contains("授权稳定性"))
        XCTAssertTrue(markdown.contains("Bundle ID 保持不变"))
        XCTAssertTrue(markdown.contains("减少重复授权"))
        XCTAssertTrue(markdown.contains("固定从 /Applications/存储清理助手.app 打开"))
        XCTAssertTrue(markdown.contains("关闭窗口与授权"))
        XCTAssertTrue(markdown.contains("关闭窗口只会隐藏主界面"))
        XCTAssertTrue(markdown.contains("不需要重新授权"))
    }

    func testAppRuntimeAccessStabilityExplainsWhyDevelopmentBuildsMayPromptAgain() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let installed = AppRuntimeLocationService.info(
            bundlePath: "/Applications/存储清理助手.app",
            bundleIdentifier: "com.local.StorageCleanerMac",
            infoDictionary: [:]
        )
        let development = AppRuntimeLocationService.info(
            bundlePath: "/Users/example/Documents/StorageCleanerMac/dist/StorageCleanerMac.app",
            bundleIdentifier: "com.local.StorageCleanerMac",
            infoDictionary: [:]
        )

        XCTAssertTrue(installed.authorizationStabilityStatus.contains("复用已授予的文件访问权限"))
        XCTAssertTrue(installed.authorizationStabilityAction.contains("不要从 DMG、下载目录或临时构建目录"))
        XCTAssertTrue(installed.authorizationWindowLifecycleNote.contains("不会撤销 macOS 文件访问授权"))
        XCTAssertTrue(installed.authorizationWindowLifecycleNote.contains("不需要重新授权"))
        XCTAssertTrue(development.authorizationStabilityStatus.contains("需要重新确认权限"))
        XCTAssertTrue(development.authorizationStabilityAction.contains("/Applications/存储清理助手.app"))
        XCTAssertTrue(development.authorizationWindowLifecycleNote.contains("关闭窗口本身不会撤销授权"))
        XCTAssertTrue(development.authorizationWindowLifecycleNote.contains("macOS 仍可能把它当作新 App"))
    }

    func testSettingsDiagnosticsCopyExplainsItDoesNotChangeAuthorization() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Views/SettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("授权复用建议"))
        XCTAssertTrue(source.contains("authorizationStabilityAction"))
        XCTAssertTrue(source.contains("窗口关闭说明"))
        XCTAssertTrue(source.contains("authorizationWindowLifecycleNote"))
        XCTAssertTrue(source.contains("诊断信息已复制"))
    }

    func testRecordAndVisibilityClearMessagesDoNotImplyFileDeletionOrInstall() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let store = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("仅移除本机记录，不会删除任何文件"))
        XCTAssertTrue(store.contains("仅移除记录，不会清空废纸篓或删除文件"))
        XCTAssertTrue(store.contains("仅影响更新列表，不会安装软件"))
        XCTAssertTrue(settings.contains("扫描排除项清单已复制"))
        XCTAssertTrue(settings.contains("已从扫描排除项移除"))
        XCTAssertTrue(settings.contains("已清空扫描排除项"))
    }

    func testStartupAndMemoryActionMessagesKeepDisableAndQuitBoundariesClear() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let store = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift"),
            encoding: .utf8
        )
        let coordinator = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Features/Memory/Application/MemoryCoordinator.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("仅阻止自动载入，不会卸载所属应用"))
        XCTAssertTrue(coordinator.contains("不会自动升级为强制退出"))
        XCTAssertTrue(store.contains("实际内存变化已单独重测"))
        XCTAssertTrue(coordinator.contains("never escalates to force quit automatically"))
        XCTAssertTrue(store.contains("Actual memory change was remeasured separately"))
        XCTAssertTrue(store.contains("does not uninstall its application"))
    }

    func testStartupDashboardShowsAllScannedRowsAndGatesActionsByCapability() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dashboardSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/StartupItems/Views/StartupItemsDashboardView.swift"
            ),
            encoding: .utf8
        )
        let managementSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/StartupItems/Management/StartupManagementCapability.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(dashboardSource.contains("DisclosureGroup"))
        XCTAssertTrue(dashboardSource.contains("CachedAppIconView"))
        XCTAssertTrue(dashboardSource.contains("candidate.state.management == .directlyManageable"))
        XCTAssertTrue(dashboardSource.contains("candidate.actionCapability.canEnableDirectly"))
        XCTAssertTrue(dashboardSource.contains("candidate.actionCapability.canDisableDirectly"))
        XCTAssertFalse(dashboardSource.contains("items.filter(\\.isDirectlyManageable)"))
        XCTAssertTrue(dashboardSource.contains("items: items"))
        XCTAssertTrue(dashboardSource.contains("item.isSystemSettingsOnly"))
        XCTAssertTrue(dashboardSource.contains("if item.requiresAdministrator"))
        XCTAssertTrue(dashboardSource.contains("StartupItemsCategory"))
        XCTAssertTrue(dashboardSource.contains("GlassSegmentedControl("))
        XCTAssertTrue(dashboardSource.contains(".toggleStyle(.switch)"))
        XCTAssertTrue(dashboardSource.contains("else if directCandidate != nil"))
        XCTAssertFalse(dashboardSource.contains("filter: .actionable"))
        XCTAssertTrue(dashboardSource.contains("L10n.text(\"在系统设置中管理\", \"Manage in System Settings\")"))
        XCTAssertTrue(managementSource.contains("attribution?.confidence ?? .unknown >= .high"))
        XCTAssertTrue(managementSource.contains("hasPrivilegedHelper: false"))
    }

    func testUtilityListsPreferActionableApplications() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("StartupItemsDashboardView("))
        XCTAssertTrue(source.contains("items: store.startupDomainItems"))
        XCTAssertTrue(source.contains("onEnable: { store.requestStartupOperation(.enable"))
        XCTAssertTrue(source.contains("onDisable: { store.requestStartupOperation(.disable"))
        XCTAssertTrue(source.contains("onOpenSystemSettings: { SMAppService.openSystemSettingsLoginItems() }"))
        XCTAssertTrue(source.contains("EnergyImpactListPresenter.presentation("))
        XCTAssertTrue(source.contains("store.installedApps.filter(\\.canMoveToTrash)"))
        XCTAssertFalse(source.contains("openExternalAppManager"))
        XCTAssertFalse(source.contains("没有可在此关闭的登录项"))
        XCTAssertFalse(source.contains("按应用查看累计能耗与当前功率"))
        XCTAssertFalse(source.contains("系统只读\", \"Read-only"))
    }

    func testReleaseFirstOpenReadmeExplainsGatekeeperAndNotarizationBoundary() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/make_release_dmg.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("当前不是 Apple 公证的公开分发版"))
        XCTAssertTrue(script.contains("Gatekeeper 拦截未公证 App"))
        XCTAssertTrue(script.contains("不代表 DMG 或 ZIP 真坏"))
        XCTAssertTrue(script.contains("Control 点击"))
        XCTAssertTrue(script.contains("Apple Developer ID 证书签名"))
        XCTAssertTrue(script.contains("Apple notarization 公证"))
        XCTAssertTrue(script.contains("减少重复授权提示"))
        XCTAssertTrue(script.contains("继续从 /Applications/存储清理助手.app 打开"))
        XCTAssertTrue(script.contains("系统可能会再次要求确认"))
        XCTAssertTrue(script.contains("关闭窗口不会撤销 macOS 文件访问授权"))
        XCTAssertTrue(script.contains("不需要每次重新授权"))
    }

    func testReleaseScriptVerifiesDmgFirstOpenReadmeContent() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/make_release_dmg.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("verify_first_open_readme"))
        XCTAssertTrue(script.contains("does not explain repeated access prompts"))
        XCTAssertTrue(script.contains("does not name the stable install path"))
        XCTAssertTrue(script.contains("mounted image does not contain $NOTICE_NAME"))
        XCTAssertTrue(script.contains("mounted image does not contain $expected_app_name.app"))
        XCTAssertFalse(script.contains("find \"$mount_point\" -maxdepth 2 -type d -name '*.app'"))
        XCTAssertTrue(script.contains("Stats SMC helper"))
        XCTAssertTrue(script.contains("verify_dmg_archive \"$DMG_PATH\" \"$DISPLAY_NAME\" \"zh-dmg\" \"首次打开说明.txt\""))
        XCTAssertTrue(script.contains("verify_dmg_archive \"$ASCII_DMG_PATH\" \"$DISPLAY_NAME\" \"ascii-dmg\" \"README-FIRST.txt\""))
    }

    func testReleaseScriptVerifiesZipFirstOpenReadmeContent() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/make_release_dmg.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("verify_first_open_readme \"$verify_dir/$expected_readme_name\" \"$zip_path\" \"$expected_readme_name\""))
        XCTAssertTrue(script.contains("archive does not contain $NOTICE_NAME"))
        XCTAssertTrue(script.contains("archive does not contain $expected_app_name.app"))
        XCTAssertFalse(script.contains("find \"$verify_dir\" -maxdepth 2 -type d -name '*.app'"))
        XCTAssertTrue(script.contains("Stats SMC helper"))
        XCTAssertTrue(script.contains("verify_zip_archive \"$ZIP_PATH\" \"$DISPLAY_NAME\" \"zh-zip\" \"首次打开说明.txt\""))
        XCTAssertTrue(script.contains("verify_zip_archive \"$ASCII_ZIP_PATH\" \"$DISPLAY_NAME\" \"ascii-zip\" \"README-FIRST.txt\""))
    }

    func testReleaseScriptsShareCanonicalVersionDefaults() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let versionFile = try String(
            contentsOf: root.appendingPathComponent("script/release_version.env"),
            encoding: .utf8
        )

        XCTAssertEqual(
            versionFile.components(separatedBy: "DEFAULT_APP_VERSION=").count - 1,
            1
        )
        XCTAssertEqual(
            versionFile.components(separatedBy: "DEFAULT_APP_BUILD=").count - 1,
            1
        )
        XCTAssertTrue(versionFile.contains("DEFAULT_APP_VERSION=1.10.1"))
        XCTAssertNotNil(
            versionFile.range(
                of: #"(?m)^DEFAULT_APP_BUILD=\d{12}$"#,
                options: .regularExpression
            )
        )

        for name in ["build_and_run.sh", "make_release_dmg.sh", "notarize_release.sh"] {
            let script = try String(
                contentsOf: root.appendingPathComponent("script/\(name)"),
                encoding: .utf8
            )
            XCTAssertTrue(
                script.contains("source \"$ROOT_DIR/script/release_version.env\""),
                name
            )
            XCTAssertTrue(
                script.contains("APP_VERSION=\"${APP_VERSION:-$DEFAULT_APP_VERSION}\""),
                name
            )
        }
    }

    func testRepositoryVerificationUsesToolsAvailableOnGitHubMacRunners() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bootstrap = try String(
            contentsOf: root.appendingPathComponent("script/bootstrap.sh"),
            encoding: .utf8
        )
        let verify = try String(
            contentsOf: root.appendingPathComponent("script/verify.sh"),
            encoding: .utf8
        )
        let continuousIntegration = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(bootstrap.contains("git swift xcrun codesign grep"))
        XCTAssertFalse(bootstrap.contains("git swift xcrun codesign rg"))
        XCTAssertTrue(verify.contains("grep -R -n -E"))
        XCTAssertTrue(verify.contains("| grep -q '/System/Library/PrivateFrameworks'"))
        XCTAssertFalse(verify.contains("rg -n"))
        XCTAssertTrue(continuousIntegration.contains("developer_dir: /Applications/Xcode_16.2.app/Contents/Developer"))
        XCTAssertTrue(continuousIntegration.contains("DEVELOPER_DIR: ${{ matrix.developer_dir }}"))

        for path in [
            "Sources/FanControlHelper/main.swift",
            "Sources/StorageCleanerMac/Services/SMCFanSpeedService.swift",
            "Sources/StorageCleanerMac/Services/SystemMonitorService.swift"
        ] {
            let source = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("@preconcurrency import Darwin"), path)
        }

        let artwork = try String(
            contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Support/AppArtwork.swift"),
            encoding: .utf8
        )
        let applicationUpdateCoordinator = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/AppUpdates/Coordination/ApplicationUpdateCoordinator.swift"
            ),
            encoding: .utf8
        )
        let fanControl = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Services/FanControlCoordinator.swift"
            ),
            encoding: .utf8
        )
        let panelSession = try String(
            contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Support/MenuBarPanelSession.swift"),
            encoding: .utf8
        )
        let rayTracing = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Services/Benchmark/MetalRayTracingBenchmarkKernel.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(artwork.contains("@preconcurrency import CoreImage"))
        XCTAssertFalse(applicationUpdateCoordinator.contains(
            "Continuation.BufferingPolicy = .bufferingNewest"
        ))
        XCTAssertTrue(fanControl.contains("@preconcurrency import ServiceManagement"))
        XCTAssertTrue(panelSession.contains("#if compiler(>=6.2)"))
        XCTAssertTrue(rayTracing.contains("#if compiler(>=6.2)"))
    }

    func testReleaseRunbookAlwaysUsesDedicatedSparkleKeychainAccount() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runbook = try String(
            contentsOf: root.appendingPathComponent(
                "docs/superpowers/plans/2026-07-15-v1.4.0-release-validation.md"
            ),
            encoding: .utf8
        )
        let signingInvocations = runbook
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                line.contains("\"$SPARKLE_SIGN\"")
                    && line.contains(".zip")
            }

        XCTAssertFalse(signingInvocations.isEmpty)
        XCTAssertTrue(runbook.contains("SPARKLE_KEYCHAIN_ACCOUNT=\"com.local.StorageCleanerMac\""))
        XCTAssertTrue(signingInvocations.allSatisfy {
            $0.contains("--account \"$SPARKLE_KEYCHAIN_ACCOUNT\"")
        })
        XCTAssertFalse(runbook.contains("\"$SPARKLE_SIGN\" release/"))
    }

    func testReleaseReportVerifiesChecksumFileAgainstCurrentArtifacts() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/make_release_dmg.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("echo \"checksums:\""))
        XCTAssertTrue(script.contains("CHECKSUM_STAGING=\"$BUILD_ROOT/checksum-staging\""))
        XCTAssertTrue(script.contains("DMG_PATH=\"$RELEASE_DIR/$DISPLAY_NAME-$APP_VERSION.dmg\""))
        XCTAssertTrue(script.contains("ZIP_PATH=\"$RELEASE_DIR/$DISPLAY_NAME-$APP_VERSION.zip\""))
        XCTAssertTrue(script.contains("CHECKSUM_PATH=\"$RELEASE_DIR/CHECKSUMS-SHA256-$APP_VERSION.txt\""))
        XCTAssertTrue(script.contains("ASCII_DMG_ASSET_NAME=\"StorageCleanerMac-$APP_VERSION.dmg\""))
        XCTAssertTrue(script.contains("ASCII_ZIP_ASSET_NAME=\"StorageCleanerMac-$APP_VERSION.zip\""))
        XCTAssertTrue(script.contains("ZH_DMG_ASSET_NAME=\"StorageCleanerMac-zhHans-$APP_VERSION.dmg\""))
        XCTAssertTrue(script.contains("ZH_ZIP_ASSET_NAME=\"StorageCleanerMac-zhHans-$APP_VERSION.zip\""))
        XCTAssertTrue(script.contains("ZH_DMG_ASSET_PATH=\"$RELEASE_DIR/$ZH_DMG_ASSET_NAME\""))
        XCTAssertTrue(script.contains("ZH_ZIP_ASSET_PATH=\"$RELEASE_DIR/$ZH_ZIP_ASSET_NAME\""))
        XCTAssertTrue(script.contains("$ASCII_STAGING/$DISPLAY_NAME.app"))
        XCTAssertTrue(script.contains("$ASCII_ZIP_STAGING/$DISPLAY_NAME.app"))
        XCTAssertFalse(script.contains("$ASCII_STAGING/StorageCleanerMac.app"))
        XCTAssertFalse(script.contains("$ASCII_ZIP_STAGING/StorageCleanerMac.app"))
        XCTAssertTrue(script.contains("/usr/bin/ditto --norsrc \"$DMG_PATH\" \"$ZH_DMG_ASSET_PATH\""))
        XCTAssertTrue(script.contains("/usr/bin/ditto --norsrc \"$ZIP_PATH\" \"$ZH_ZIP_ASSET_PATH\""))
        XCTAssertTrue(script.contains("ln -s \"$ASCII_DMG_PATH\" \"$CHECKSUM_STAGING/$ASCII_DMG_ASSET_NAME\""))
        XCTAssertTrue(script.contains("ln -s \"$ASCII_ZIP_PATH\" \"$CHECKSUM_STAGING/$ASCII_ZIP_ASSET_NAME\""))
        XCTAssertTrue(script.contains("ln -s \"$ZH_DMG_ASSET_PATH\" \"$CHECKSUM_STAGING/$ZH_DMG_ASSET_NAME\""))
        XCTAssertTrue(script.contains("ln -s \"$ZH_ZIP_ASSET_PATH\" \"$CHECKSUM_STAGING/$ZH_ZIP_ASSET_NAME\""))
        XCTAssertTrue(script.contains("cd \"$CHECKSUM_STAGING\""))
        XCTAssertTrue(script.contains("shasum -a 256 -c \"$CHECKSUM_PATH\""))
        XCTAssertFalse(
            script.contains(
                "shasum -a 256 \"$ASCII_DMG_PATH\" \"$ASCII_ZIP_PATH\" \"$DMG_PATH\" \"$ZIP_PATH\""
            )
        )
    }

    func testDistributionSetupRequiresDeveloperIDForPublicReleaseBuild() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: projectRoot.appendingPathComponent("script/configure_distribution.sh"),
            encoding: .utf8
        )
        let releaseScript = try String(
            contentsOf: projectRoot.appendingPathComponent("script/make_release_dmg.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("SIGN_IDENTITY=\"$DEVELOPER_ID\""))
        XCTAssertTrue(script.contains("REQUIRE_DEVELOPER_ID=1"))
        XCTAssertTrue(script.contains("script/notarize_release.sh"))
        XCTAssertTrue(script.contains("isFreeProvisioningTeam = 1"))
        XCTAssertTrue(script.contains("Apple does not issue Developer ID certificates to free Personal Teams"))
        XCTAssertTrue(script.contains("NOTARY_KEY_ID"))
        XCTAssertTrue(script.contains("shasum -a 256 -c"))
        XCTAssertTrue(script.contains("RELEASE_VERSION=\"$(/usr/libexec/PlistBuddy"))
        XCTAssertTrue(script.contains("APP_VERSION=\"$RELEASE_VERSION\" EXPECTED_VERSION=\"$RELEASE_VERSION\""))
        XCTAssertTrue(script.contains("EXPECTED_BUILD=\"$EXPECTED_RELEASE_BUILD\""))
        XCTAssertTrue(script.contains("DEFAULT_APP_BUILD"))
        XCTAssertTrue(script.contains("CHECKSUMS-SHA256-$RELEASE_VERSION.txt"))
        XCTAssertTrue(script.contains("DIST_DIR=\"${DIST_DIR:-/tmp/storage-cleaner-release-dist}\""))
        XCTAssertTrue(script.contains("DIST_DIR=\"$DIST_DIR\" SIGN_IDENTITY=\"$DEVELOPER_ID\""))
        XCTAssertTrue(script.contains("$DIST_DIR/StorageCleanerMac.app/Contents/Info.plist"))
        XCTAssertTrue(releaseScript.contains("sign_args+=(--timestamp)"))
        XCTAssertTrue(releaseScript.contains("--options runtime"))
        XCTAssertTrue(releaseScript.contains("RELEASE_DIR=\"${RELEASE_DIR:-$ROOT_DIR/release}\""))
        XCTAssertTrue(releaseScript.contains("DIST_DIR=\"${DIST_DIR:-/tmp/storage-cleaner-release-dist}\""))
        XCTAssertTrue(releaseScript.contains("FinderInfo to nested Sparkle bundles"))
    }

    func testNotarizationPipelineRebuildsFinalArchivesAroundStapledApp() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/notarize_release.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("DIST_DIR=\"${DIST_DIR:-/tmp/storage-cleaner-release-dist}\""))
        let appSubmission = try XCTUnwrap(script.range(of: "submit_notary \"$APP_SUBMISSION\" \"app\""))
        let appStaple = try XCTUnwrap(script.range(of: "xcrun stapler staple \"$STAPLED_APP\""))
        let staging = try XCTUnwrap(script.range(of: "\nprepare_staging_directories\n"))
        let finalChecksums = try XCTUnwrap(script.range(of: "\nwrite_and_verify_checksums\n"))

        XCTAssertLessThan(appSubmission.lowerBound, appStaple.lowerBound)
        XCTAssertLessThan(appStaple.lowerBound, staging.lowerBound)
        XCTAssertLessThan(staging.lowerBound, finalChecksums.lowerBound)
        XCTAssertTrue(script.contains("Authority=Developer ID Application:"))
        XCTAssertTrue(script.contains("flags=.*runtime"))
        XCTAssertTrue(script.contains("Timestamp="))
        XCTAssertTrue(script.contains("com.apple.security.get-task-allow"))
        XCTAssertTrue(script.contains("xcrun stapler validate \"$app_path\""))
        XCTAssertTrue(script.contains("syspolicy_check distribution \"$app_path\""))
        XCTAssertTrue(script.contains("codesign --force --timestamp --sign \"$DEVELOPER_ID\" \"$dmg_path\""))
        XCTAssertTrue(script.contains("context:primary-signature"))
        XCTAssertTrue(script.contains("verify_zip \"$ZIP_PATH\""))
        XCTAssertTrue(script.contains("verify_dmg \"$DMG_PATH\""))
        XCTAssertTrue(script.contains("verify_zip \"$ASCII_ZIP_PATH\" \"$DISPLAY_NAME\""))
        XCTAssertTrue(script.contains("verify_dmg \"$ASCII_DMG_PATH\" \"$DISPLAY_NAME\""))
        XCTAssertTrue(script.contains("MODE=\"${1:-notarize}\""))
        XCTAssertTrue(script.contains("--verify-only"))
        XCTAssertTrue(script.contains("verify_quarantined_copy \"$DIST_APP\""))
        XCTAssertTrue(script.contains("verify_quarantined_copy \"$VERIFY_ROOT/ascii-zip/$DISPLAY_NAME.app\""))
        XCTAssertTrue(script.contains("version-probe"))
        XCTAssertTrue(script.contains("com.apple.quarantine"))
        XCTAssertTrue(script.contains("trap cleanup_mounted_dmg EXIT"))
        XCTAssertTrue(script.contains("EXPECTED_BUNDLE_ID"))
        XCTAssertTrue(script.contains("EXPECTED_VERSION"))
        XCTAssertTrue(script.contains("EXPECTED_BUILD"))
        XCTAssertTrue(script.contains("CFBundleVersion"))
        XCTAssertTrue(script.contains("CFBundleDisplayName"))
        XCTAssertTrue(script.contains("CFBundleDevelopmentRegion"))
        XCTAssertTrue(script.contains("SUFeedURL"))
        XCTAssertTrue(script.contains("SUPublicEDKey"))
        XCTAssertTrue(script.contains("EXPECTED_FEED_URL"))
        XCTAssertTrue(script.contains("EXPECTED_SPARKLE_PUBLIC_KEY"))
        XCTAssertTrue(script.contains("已通过 Apple notarization"))
        XCTAssertTrue(script.contains("无需 Control-点击"))
        XCTAssertTrue(script.contains("does not require Control-click"))
        XCTAssertTrue(script.contains("Drag 存储清理助手.app to Applications"))
        XCTAssertTrue(script.contains("StorageCleanerMac-$APP_VERSION.dmg"))
        XCTAssertTrue(script.contains("StorageCleanerMac-zhHans-$APP_VERSION.dmg"))
        XCTAssertTrue(script.contains("CHECKSUMS-SHA256-$APP_VERSION.txt"))
        XCTAssertTrue(script.contains("refresh_localized_release_assets"))
        XCTAssertTrue(script.contains("Checksums: regenerated after all staple and archive rebuild operations"))
        XCTAssertTrue(script.contains("shasum -a 256 -c \"$CHECKSUM_PATH\""))
    }

    func testProjectTestScriptUsesStableScratchPathAndDisablesCopyfileMetadata() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/test.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("$HOME/.storage-cleaner-swiftpm-test"))
        XCTAssertTrue(script.contains("xattr -cr \"$SWIFT_TEST_DIR\""))
        XCTAssertTrue(script.contains("COPYFILE_DISABLE=1 swift test"))
        XCTAssertTrue(script.contains("\"$@\""))
    }

    func testPackagingScriptsDisableCopyfileMetadata() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildAndRunScript = try String(
            contentsOf: projectRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )
        let releaseScript = try String(
            contentsOf: projectRoot.appendingPathComponent("script/make_release_dmg.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(buildAndRunScript.contains("export COPYFILE_DISABLE=1"))
        XCTAssertTrue(releaseScript.contains("export COPYFILE_DISABLE=1"))
        XCTAssertTrue(releaseScript.contains("BUILD_CONFIGURATION=\"${BUILD_CONFIGURATION:-release}\""))
        XCTAssertTrue(releaseScript.contains("SWIFT_BUILD_JOBS=\"${SWIFT_BUILD_JOBS:-2}\""))
        XCTAssertTrue(releaseScript.contains("build -c \"$BUILD_CONFIGURATION\" --scratch-path \"$SWIFT_BUILD_DIR\" --jobs \"$SWIFT_BUILD_JOBS\""))
        XCTAssertTrue(releaseScript.contains("test -c release"))
        XCTAssertTrue(releaseScript.contains("--jobs \"$SWIFT_BUILD_JOBS\""))
        XCTAssertTrue(releaseScript.contains("codesign --verify --deep --strict --verbose=4 \"$DIST_APP\""))
        XCTAssertTrue(releaseScript.contains("strict validation failed after metadata cleanup"))
        XCTAssertEqual(
            releaseScript.components(separatedBy: "clean_attrs \"$DIST_APP\"").count - 1,
            2
        )
    }

    func testPackagingScriptsRequireMacOS26SDKAndValidateBinaryCompatibility() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scripts = try ["script/build_and_run.sh", "script/make_release_dmg.sh"].map { path in
            try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
        }

        for script in scripts {
            XCTAssertTrue(script.contains("REQUIRED_LINK_SDK_MAJOR=\"${REQUIRED_LINK_SDK_MAJOR:-26}\""))
            XCTAssertTrue(script.contains("LSMinimumSystemVersion"))
            XCTAssertTrue(script.contains("xcrun vtool -show-build"))
            XCTAssertTrue(script.contains("verify_executable_compatibility"))
            XCTAssertTrue(script.contains("linked macOS SDK must be"))
            XCTAssertTrue(script.contains("REQUIRED_ARCHITECTURE=\"${REQUIRED_ARCHITECTURE:-arm64}\""))
            XCTAssertTrue(script.contains("/Applications/Xcode.app/Contents/Developer"))
            XCTAssertTrue(script.contains("SWIFT_TOOL=\"/usr/bin/swift\""))
        }
    }

    func testBuildVerificationClosesWindowsByAccessibilityRole() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/build_and_run.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("subrole is \"AXCloseButton\""))
        XCTAssertTrue(script.contains("perform action \"AXClose\" of targetWindow"))
        XCTAssertFalse(script.contains("click button 1 of window 1"))
    }

    func testPackagingScriptsDoNotBundleArtworkSourceImages() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildAndRunScript = try String(
            contentsOf: projectRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )
        let releaseScript = try String(
            contentsOf: projectRoot.appendingPathComponent("script/make_release_dmg.sh"),
            encoding: .utf8
        )

        for script in [buildAndRunScript, releaseScript] {
            XCTAssertTrue(script.contains("! -name 'AppIconSource.png'"))
            XCTAssertTrue(script.contains("! -name 'AppIconGenerated*.png'"))
            XCTAssertFalse(script.contains("-name 'SidebarIcon*.png'"))
        }
    }

    func testToolsMenuKeepsOnlyGlobalUtilityCommands() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"),
            encoding: .utf8
        )
        let utilitiesSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"),
            encoding: .utf8
        )
        let appUpdatesSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains("CommandMenu(L10n.text(\"工具\", \"Tools\"))"))
        XCTAssertTrue(appSource.contains("checkCurrentPermissionsFromMenu()"))
        XCTAssertTrue(appSource.contains("updater.checkForUpdates()"))
        XCTAssertFalse(appSource.contains("检测开机程序"))
        XCTAssertFalse(appSource.contains("打开登录项设置"))
        XCTAssertFalse(appSource.contains("优化内存"))
        XCTAssertFalse(appSource.contains("扫描可卸载应用"))
        XCTAssertFalse(appSource.contains("扫描程序升级"))
        XCTAssertFalse(appSource.contains("扫描重复文件"))
        XCTAssertFalse(utilitiesSource.contains("store.openLoginItemsSettings()"))
        XCTAssertTrue(utilitiesSource.contains(
            "store.refreshStartupItems(includeBackgroundTaskDiagnostic: true)"
        ))
        XCTAssertTrue(utilitiesSource.contains("store.performRecommendedMemoryAction()"))
        XCTAssertTrue(utilitiesSource.contains("store.refreshInstalledApps()"))
        XCTAssertTrue(appUpdatesSource.contains("onScan: store.refreshAppUpdates"))
        XCTAssertTrue(utilitiesSource.contains("store.scanDuplicateFiles()"))
    }

    func testSelfUpdaterUsesSignedPublicSparkleFeed() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let updaterSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/AppUpdater.swift"),
            encoding: .utf8
        )
        let scripts = try ["script/build_and_run.sh", "script/make_release_dmg.sh"].map { path in
            try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
        }
        let applicationSourceRoot = projectRoot.appendingPathComponent("Sources/StorageCleanerMac")
        let sourceEnumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: applicationSourceRoot,
                includingPropertiesForKeys: nil
            )
        )
        let applicationSource = try sourceEnumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertTrue(packageSource.contains("exact: \"2.9.4\""))
        XCTAssertTrue(updaterSource.contains("SPUStandardUpdaterController"))
        XCTAssertTrue(updaterSource.contains("checkForUpdates(nil)"))
        XCTAssertFalse(applicationSource.contains("api.github.com/repos/yangyihang96/StorageCleanerMac/releases/latest"))
        XCTAssertFalse(applicationSource.contains("gh api repos/yangyihang96/StorageCleanerMac/releases/latest"))
        XCTAssertFalse(applicationSource.contains("GitHub 更新仓库为私有仓库"))
        for script in scripts {
            XCTAssertTrue(script.contains("StorageCleanerMacUpdates/main/appcast.xml"))
            XCTAssertTrue(script.contains("APP_FRAMEWORKS=\"$APP_CONTENTS/Frameworks\""))
            XCTAssertTrue(script.contains("SUEnableAutomaticChecks"))
            XCTAssertTrue(script.contains("SUAutomaticallyUpdate"))
            XCTAssertTrue(script.contains("SUVerifyUpdateBeforeExtraction"))
            XCTAssertTrue(script.contains("SUPublicEDKey"))
        }
    }

    func testInstalledAppUpdatesStayDistinctFromStorageCleanerSelfUpdates() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelsSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Models/StorageModels.swift"),
            encoding: .utf8
        )
        let updaterSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift"
            ),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SettingsView.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(modelsSource.contains("case .updater: L10n.text(\"应用更新\", \"App Updates\")"))
        XCTAssertTrue(updaterSource.contains("title: ReviewFilter.updater.title"))
        XCTAssertTrue(settingsSource.contains("L10n.text(\"应用更新\", \"App Updates\")"))
        XCTAssertTrue(settingsSource.contains("不影响存储清理助手自身的 Sparkle 更新"))
        XCTAssertTrue(settingsSource.contains("does not affect Storage Cleaner's own Sparkle updates"))
        XCTAssertTrue(appSource.contains("L10n.text(\"检查存储清理助手更新\", \"Check Storage Cleaner Updates\")"))
        XCTAssertFalse(updaterSource.contains("检查存储清理助手更新"))
    }

    func testAppUpdatesDashboardShowsVerifiedUpdatesAndKeepsAutomaticBatchSeparate() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("switch store.appUpdatePresentationState"))
        for phase in [
            "idle", "scanning", "scanSummary", "managing", "preparingUpdate",
            "updating", "finalizing", "completed", "cancelled", "failed",
        ] {
            XCTAssertTrue(source.contains("case let .\(phase)"), phase)
        }
        XCTAssertTrue(source.contains("HeroScanPage("))
        XCTAssertTrue(source.contains("AppUpdateScanSummaryPage("))
        XCTAssertTrue(source.contains("AppUpdateManagerPage("))
        XCTAssertTrue(source.contains("AppUpdateProgressPage("))
        XCTAssertTrue(source.contains("AppUpdateReportPage("))
        XCTAssertTrue(source.contains("AppUpdateSessionLogPage("))
        XCTAssertTrue(source.contains("if shouldShowOrchestratorStatusBanner"))
        XCTAssertTrue(source.contains("private var shouldShowOrchestratorStatusBanner: Bool"))
        XCTAssertTrue(source.contains("case .idle, .scanning, .completed"))
        XCTAssertTrue(source.contains("LazyVStack(spacing: 0)"))
        XCTAssertFalse(source.contains(".frame(maxWidth: 720)"))
        XCTAssertFalse(source.contains("shouldUseHeroPresentation"))
        XCTAssertFalse(source.contains("primaryFilters"))
        XCTAssertFalse(source.contains("secondaryFilters"))
        XCTAssertFalse(source.contains("更多筛选"))
        XCTAssertFalse(source.contains("第三方应用"))
        XCTAssertTrue(source.contains("placeholder: L10n.text(\"搜索应用、版本或来源\""))
        XCTAssertTrue(source.contains("store.requestSelectedAppUpdates("))
        XCTAssertTrue(source.contains("store.requestAppUpdate(app)"))
        XCTAssertTrue(source.contains("一键更新全部 · \\("))
        XCTAssertFalse(source.contains("安全更新 · \\("))
        XCTAssertTrue(source.contains("store.openUpdateEntry(app)"))
        XCTAssertTrue(source.contains("store.requestAppStoreUpdate(app)"))
        XCTAssertTrue(source.contains("L10n.text(\"在 App Store 中更新\""))
        XCTAssertTrue(source.contains("L10n.text(\"打开应用内更新\""))
    }

    func testNavigationMenuKeepsOnlyPrimaryReviewDestinations() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains("CommandMenu(L10n.text(\"导航\", \"Navigate\"))"))
        XCTAssertTrue(appSource.contains("ReviewFilter.overview.title"))
        XCTAssertTrue(appSource.contains("ReviewFilter.healthHub.title"))
        XCTAssertTrue(appSource.contains("ReviewFilter.performance.title"))
        XCTAssertTrue(appSource.contains("ReviewFilter.green.title"))
        XCTAssertTrue(appSource.contains("ReviewFilter.privacy.title"))
        XCTAssertTrue(appSource.contains("ReviewFilter.devCaches.title"))
        XCTAssertTrue(appSource.contains("ReviewFilter.largeFiles.title"))
        XCTAssertTrue(appSource.contains("ReviewFilter.migration.title"))
        XCTAssertTrue(appSource.contains("ReviewFilter.duplicates.title"))
        XCTAssertFalse(appSource.contains("ReviewFilter.scanHistory.title"))
        XCTAssertFalse(appSource.contains("keyboardShortcut(\"7\""))
    }

    func testSidebarMergesRelatedFunctionsAndKeepsToolboxExpanded() throws {
        XCTAssertEqual(ReviewFilter.sidebarCleanupCases, [.green, .devCaches, .privacy, .largeFiles])
        XCTAssertEqual(ReviewFilter.cleanupWorkspaceCases, [.green, .devCaches])
        XCTAssertEqual(ReviewFilter.fileWorkspaceCases, [.largeFiles, .migration, .duplicates])
        XCTAssertEqual(ReviewFilter.devCaches.sidebarGroupAnchor, .devCaches)
        XCTAssertEqual(ReviewFilter.sidebarItems(in: .cleanup), [.green, .devCaches])
        XCTAssertEqual(ReviewFilter.privacy.sidebarGroupAnchor, .privacy)
        XCTAssertEqual(ReviewFilter.duplicates.sidebarGroupAnchor, .duplicates)
        XCTAssertEqual(ReviewFilter.migration.sidebarGroupAnchor, .migration)
        XCTAssertEqual(ReviewFilter.utilityCases, [.utilityHub])
        XCTAssertEqual(ReviewFilter.utilityToolCases, [.startup, .memory, .energy, .uninstall, .updater])
        XCTAssertEqual(ReviewFilter.startup.sidebarDestination, .utilityHub)
        XCTAssertEqual(ReviewFilter.memory.sidebarDestination, .utilityHub)
        XCTAssertEqual(ReviewFilter.energy.sidebarDestination, .utilityHub)
        XCTAssertEqual(ReviewFilter.uninstall.sidebarDestination, .utilityHub)
        XCTAssertEqual(ReviewFilter.updater.sidebarDestination, .utilityHub)

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebarSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SidebarView.swift"),
            encoding: .utf8
        )
        let utilitySource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"),
            encoding: .utf8
        )
        let metadataPillSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/MetadataPill.swift"),
            encoding: .utf8
        )
        let contentSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/ContentView.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"),
            encoding: .utf8
        )
        let glassSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/GlassStyle.swift"),
            encoding: .utf8
        )
        let smartCareSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SmartCareComponents.swift"),
            encoding: .utf8
        )
        let smartScanSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SmartScanProgressView.swift"),
            encoding: .utf8
        )
        let modulePresentationSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/ModulePresentation.swift"
            ),
            encoding: .utf8
        )
        let moduleThemeSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Support/ModuleTheme.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(sidebarSource.contains("@Binding var isCompact: Bool"))
        XCTAssertFalse(sidebarSource.contains("SidebarBrandHeader"))
        XCTAssertTrue(sidebarSource.contains("ScrollView(.vertical)"))
        XCTAssertTrue(sidebarSource.contains("ForEach(SidebarGroup.allCases)"))
        XCTAssertTrue(sidebarSource.contains("ReviewFilter.sidebarItems(in: group)"))
        XCTAssertTrue(sidebarSource.contains("struct SidebarSectionView<Content: View>: View"))
        XCTAssertTrue(sidebarSource.contains("@AppStorage private var isExpanded: Bool"))
        XCTAssertTrue(sidebarSource.contains("struct SidebarFooter: View"))
        XCTAssertTrue(sidebarSource.contains("SettingsLink"))
        XCTAssertTrue(sidebarSource.contains("SidebarFooter()"))
        XCTAssertFalse(sidebarSource.contains(".overlay(alignment: .bottom)"))
        XCTAssertFalse(sidebarSource.contains("AppDesignTokens.Layout.sidebarFooterHeight"))
        XCTAssertFalse(sidebarSource.contains(".scrollIndicators(.hidden)"))
        XCTAssertTrue(sidebarSource.contains("sidebarTrafficLightClearance"))
        XCTAssertTrue(sidebarSource.contains("Text(filter.sidebarTitle)"))
        XCTAssertTrue(sidebarSource.contains("Image(systemName: filter.systemImage)"))
        XCTAssertTrue(sidebarSource.contains("filter.moduleTheme.sidebarIconColor"))
        XCTAssertTrue(sidebarSource.contains("AppMotionTokens.hover"))
        XCTAssertTrue(sidebarSource.contains("accessibilityAddTraits(isSelected ? .isSelected : [])"))
        XCTAssertFalse(sidebarSource.contains("sidebarSystemImage"))
        XCTAssertFalse(sidebarSource.contains("SidebarNavigationGlyph"))
        XCTAssertFalse(sidebarSource.contains("ArtworkIconTile("))
        XCTAssertFalse(sidebarSource.contains("filter.accentColor"))
        XCTAssertTrue(sidebarSource.contains("Button(action: action)"))
        XCTAssertTrue(sidebarSource.contains(".buttonStyle(ResponsivePlainButtonStyle())"))
        XCTAssertFalse(sidebarSource.contains("sidebar.left"))
        XCTAssertTrue(sidebarSource.contains("if isExpanded"))
        XCTAssertTrue(moduleThemeSource.contains("enum SidebarGroup"))
        XCTAssertTrue(moduleThemeSource.contains("var expansionDefaultsKey"))
        XCTAssertTrue(utilitySource.contains("struct SystemUtilitiesHubView"))
        XCTAssertFalse(utilitySource.contains("Picker(\"\", selection: selectedTool)"))
        XCTAssertTrue(utilitySource.contains("ReviewFilter.utilityToolCases"))
        XCTAssertTrue(utilitySource.contains("switch selectedTool.wrappedValue"))
        XCTAssertTrue(utilitySource.contains("AppMotionTokens.pageTransition(reduceMotion: reduceMotion)"))
        XCTAssertFalse(utilitySource.contains("struct MetadataPill"))
        XCTAssertTrue(metadataPillSource.contains("struct MetadataPill"))
        XCTAssertTrue(metadataPillSource.contains(".glassCapsule(tint: tint)"))
        XCTAssertFalse(metadataPillSource.contains(".background(tint.opacity(0.1), in: Capsule"))
        XCTAssertTrue(contentSource.contains("SystemUtilitiesHubView(store: store)"))
        XCTAssertTrue(contentSource.contains("ReviewWorkspaceShell("))
        XCTAssertTrue(contentSource.contains("ReviewWorkspaceShell(\n                    filter: filter"))
        XCTAssertFalse(contentSource.contains("options: ReviewFilter.cleanupWorkspaceCases"))
        XCTAssertTrue(contentSource.contains("session.includedCategoryIDs == nil"))
        XCTAssertTrue(contentSource.contains("LargeFilesScanLandingView"))
        XCTAssertTrue(contentSource.contains("mode: .migration"))
        XCTAssertFalse(contentSource.contains("options: ReviewFilter.fileWorkspaceCases"))
        XCTAssertFalse(contentSource.contains("GlassSegmentedControl("))
        XCTAssertTrue(contentSource.contains("showsIntegratedTitlebar: false"))
        XCTAssertTrue(contentSource.contains("MainWindowChromeConfigurator()"))
        XCTAssertFalse(contentSource.contains("SidebarFooter()"))
        XCTAssertFalse(contentSource.contains("SettingsLink"))
        XCTAssertFalse(contentSource.contains("sidebar.compact.v1"))
        XCTAssertTrue(contentSource.contains(".toolbar(removing: .sidebarToggle)"))
        XCTAssertTrue(contentSource.contains("ideal: metrics.sidebarIdealWidth"))
        XCTAssertTrue(contentSource.contains(".focusedSceneValue("))
        XCTAssertTrue(contentSource.contains("#selector(NSSplitViewController.toggleSidebar(_:))"))
        XCTAssertTrue(appSource.contains("MainWindowSidebarCommands()"))
        XCTAssertTrue(appSource.contains("CommandGroup(replacing: .sidebar)"))
        XCTAssertTrue(appSource.contains("显示或隐藏边栏"))
        XCTAssertTrue(appSource.contains(".disabled(sidebarAction == nil)"))
        XCTAssertFalse(appSource.contains("#selector(NSSplitViewController.toggleSidebar(_:))"))
        XCTAssertFalse(glassSource.contains("window.toolbar = nil"))
        XCTAssertFalse(contentSource.contains("GlassAppBackdrop()"))
        XCTAssertTrue(modulePresentationSource.contains("struct MainWindowChromeConfigurator: NSViewRepresentable"))
        XCTAssertTrue(modulePresentationSource.contains("window.titlebarAppearsTransparent = true"))
        XCTAssertTrue(modulePresentationSource.contains("window.styleMask.insert(.fullSizeContentView)"))
        XCTAssertFalse(modulePresentationSource.contains("window.toolbar = nil"))
        XCTAssertTrue(modulePresentationSource.contains(
            "window.setFrame(targetFrame, display: true, animate: false)"
        ))
        XCTAssertTrue(modulePresentationSource.contains("struct HeroScanPage<Accessory: View>: View"))
        XCTAssertTrue(modulePresentationSource.contains("struct ManagementListPage<"))
        XCTAssertTrue(modulePresentationSource.contains("struct DashboardPage<"))
        XCTAssertFalse(contentSource.contains("SmartCareHeroVisual(mode: .ready)"))
        XCTAssertTrue(smartScanSource.contains("AppButton("))
        XCTAssertTrue(smartScanSource.contains("kind: .primary"))
        XCTAssertTrue(contentSource.contains("HeroScanPage("))
        XCTAssertFalse(contentSource.contains("SmartCareStartMetric("))
        XCTAssertFalse(contentSource.contains("lastScanStrip"))
        XCTAssertFalse(contentSource.contains(".brandStagePanel"))
        XCTAssertFalse(smartCareSource.contains("AppIconArtwork"))
        XCTAssertFalse(smartCareSource.contains("SmartCareInstrumentCore"))
        XCTAssertFalse(smartCareSource.contains("ForEach(0..<18"))
        XCTAssertTrue(smartCareSource.contains(".progressViewStyle(.linear)"))
        XCTAssertTrue(contentSource.contains("store.startScanRespectingAccessGuide()"))
        XCTAssertFalse(contentSource.contains("private var utilityView"))
        XCTAssertFalse(contentSource.contains("nativePanel"))
        XCTAssertFalse(contentSource.contains("NativePanelModifier"))
        XCTAssertFalse(contentSource.contains("ToolbarIconButtonLabel"))
        XCTAssertFalse(contentSource.contains("toolbarCountBadge"))
        XCTAssertFalse(contentSource.contains("HomeCleanupDisc"))
        XCTAssertFalse(contentSource.contains("LastScanSummaryPanel"))
        XCTAssertFalse(contentSource.contains("LastScanMetricPill"))
        XCTAssertFalse(contentSource.contains("statusMetaLine"))
        XCTAssertFalse(contentSource.contains("cleanupCard"))
        XCTAssertFalse(contentSource.contains("statusActions"))
        XCTAssertFalse(contentSource.contains("performStatusPrimaryAction"))
    }

    func testTaskPagesHideInactiveControlsUntilTheyHaveResults() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let duplicateSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"),
            encoding: .utf8
        )
        let largeFilesSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/LargeFilesView.swift"),
            encoding: .utf8
        )
        let itemListSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/ItemListView.swift"),
            encoding: .utf8
        )
        let overviewSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/OverviewView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(duplicateSource.contains("if !workspace.hasScanned"))
        XCTAssertTrue(duplicateSource.contains("duplicateScanHero"))
        XCTAssertTrue(duplicateSource.contains("if allItems.isEmpty"))
        XCTAssertTrue(duplicateSource.contains("duplicateSummaryPanel"))
        XCTAssertTrue(duplicateSource.contains("private var duplicateEmptyState: some View"))
        XCTAssertTrue(duplicateSource.contains("AppEmptyState("))
        XCTAssertFalse(duplicateSource.contains("noDuplicateResultPanel"))
        XCTAssertTrue(largeFilesSource.contains("workspace.storageMapTargets"))
        XCTAssertFalse(largeFilesSource.contains("LargeFileMetricCard"))
        XCTAssertTrue(itemListSource.contains("ItemListPresenter.availableScopes"))
        XCTAssertFalse(itemListSource.contains("ItemScopeFilterChip"))
        XCTAssertFalse(overviewSource.contains("scanReliabilityBand"))
        XCTAssertFalse(overviewSource.contains("scanCoverageSection"))
        XCTAssertFalse(overviewSource.contains("ReliabilityStatusTile"))
        XCTAssertFalse(overviewSource.contains("ScanCoverageMeter"))
    }

    @MainActor
    func testUtilityDeepLinksOpenToolboxWithRequestedInternalTab() {
        let store = ScanStore()

        store.showFilter(.updater)

        XCTAssertEqual(store.selectedFilter, .utilityHub)
        XCTAssertEqual(store.requestedFilter, .utilityHub)
        XCTAssertEqual(store.selectedUtilityFilter, .updater)

        store.showFilter(.memory)

        XCTAssertEqual(store.selectedFilter, .utilityHub)
        XCTAssertEqual(store.selectedUtilityFilter, .memory)

        store.showFilter(.energy)

        XCTAssertEqual(store.selectedFilter, .utilityHub)
        XCTAssertEqual(store.selectedUtilityFilter, .energy)
    }

    @MainActor
    func testNavigationStatePublishesOnlyActualRouteChanges() {
        let navigationState = AppNavigationState()
        var updateCount = 0
        let cancellable = navigationState.objectWillChange.sink {
            updateCount += 1
        }

        XCTAssertFalse(navigationState.select(.overview))
        XCTAssertEqual(updateCount, 0)

        XCTAssertTrue(navigationState.select(.memory))
        XCTAssertEqual(
            navigationState.route,
            AppNavigationRoute(filter: .utilityHub, utilityTool: .memory)
        )
        XCTAssertEqual(updateCount, 1)

        XCTAssertFalse(navigationState.select(.memory))
        XCTAssertEqual(updateCount, 1)

        XCTAssertTrue(navigationState.select(.energy))
        XCTAssertEqual(
            navigationState.route,
            AppNavigationRoute(filter: .utilityHub, utilityTool: .energy)
        )
        XCTAssertEqual(updateCount, 2)

        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testNavigationChangesDoNotInvalidateTheScanningStore() {
        let store = ScanStore()
        var storeUpdateCount = 0
        let cancellable = store.objectWillChange.sink {
            storeUpdateCount += 1
        }

        store.navigationState.select(.memory)
        store.navigationState.select(.energy)
        store.navigationState.select(.uninstall)

        XCTAssertEqual(store.selectedFilter, .utilityHub)
        XCTAssertEqual(store.selectedUtilityFilter, .uninstall)
        XCTAssertEqual(storeUpdateCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testSidebarNavigationDefersObservableStateChangesUntilAfterViewUpdates() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebarSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SidebarView.swift"),
            encoding: .utf8
        )
        let contentSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(sidebarSource.contains("Task { @MainActor in\n            selection = filter"))
        XCTAssertTrue(contentSource.contains(".onChange(of: navigationState.route) { _, newRoute in\n            Task { @MainActor in"))
    }

    func testNavigationStressPathUsesCachedAnalysisAndExplicitUninstallScan() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelsSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Models/SystemModels.swift"),
            encoding: .utf8
        )
        let storeSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift"),
            encoding: .utf8
        )
        let utilitySource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"),
            encoding: .utf8
        )
        let contentSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(modelsSource.contains("private let processAnalysis: MemoryProcessAnalysis"))
        XCTAssertTrue(modelsSource.contains("processAnalysis = MemoryProcessAnalysis("))
        XCTAssertTrue(modelsSource.contains("processAnalysis.appsByResidentUsage"))
        XCTAssertTrue(storeSource.contains("let navigationState = AppNavigationState()"))
        XCTAssertFalse(storeSource.contains("@Published var selectedFilter"))
        XCTAssertFalse(storeSource.contains("@Published var selectedUtilityFilter"))
        XCTAssertTrue(storeSource.contains("@Published var hasScannedInstalledApps = false"))
        XCTAssertFalse(utilitySource.contains("Task.sleep(for: .milliseconds(300))"))
        XCTAssertTrue(utilitySource.contains("AppUninstallScanLandingView(store: store)"))
        XCTAssertTrue(utilitySource.contains("!store.hasScannedInstalledApps"))
        XCTAssertFalse(utilitySource.contains("!store.hasScannedInstalledApps || store.isLoadingInstalledApps"))
        XCTAssertTrue(utilitySource.contains("List(selection: $selectedApplicationID)"))
        XCTAssertTrue(utilitySource.contains("!store.hasScannedStartupItems"))
        XCTAssertTrue(utilitySource.contains("ForEach(apps)"))
        XCTAssertFalse(utilitySource.contains(".id(selectedTool.wrappedValue)"))
        XCTAssertFalse(contentSource.contains(".id(routeIdentity)"))

        let routerStart = try XCTUnwrap(contentSource.range(of: "private struct DetailRouterView: View {"))
        let routerEnd = try XCTUnwrap(contentSource.range(of: "private struct SmartScanFlowHost: View {"))
        let routerSource = String(contentSource[routerStart.lowerBound..<routerEnd.lowerBound])
        XCTAssertTrue(routerSource.contains("@ObservedObject var largeFilesWorkspace: LargeFilesStore"))
        XCTAssertFalse(routerSource.contains("store.largeFilesWorkspace"))
        let routerCalls = contentSource.components(separatedBy: "DetailRouterView(").dropFirst()
        XCTAssertEqual(routerCalls.count, 2, "Both debug and release callers must pass the observed workspace")
        for call in routerCalls {
            let arguments = try XCTUnwrap(call.components(separatedBy: ")").first)
            XCTAssertTrue(arguments.contains("largeFilesWorkspace: store.largeFilesWorkspace,"))
        }

        let buttonStart = try XCTUnwrap(routerSource.range(of: "private var fileAnalysisScanButton: some View {"))
        let buttonEnd = try XCTUnwrap(routerSource.range(of: "private var fileScanActionTitle: String {"))
        let buttonSource = String(routerSource[buttonStart.lowerBound..<buttonEnd.lowerBound])
        let appBranchStart = try XCTUnwrap(buttonSource.range(of: "if filter == .migration, largeFilesWorkspace.migrationKind == .application {"))
        let fileBranchStart = try XCTUnwrap(buttonSource.range(of: "} else if filter == .migration {"))
        let appBranch = String(buttonSource[appBranchStart.upperBound..<fileBranchStart.lowerBound])
        XCTAssertTrue(appBranch.contains("store.refreshInstalledApps()"))
        XCTAssertFalse(appBranch.contains("startScan()"))
        XCTAssertFalse(appBranch.contains("cancelScan()"))
        XCTAssertTrue(buttonSource.contains("? !store.canRefreshInstalledApps"))
        XCTAssertTrue(routerSource.contains("重新读取可搬移 App"))
        XCTAssertTrue(routerSource.contains("if store.isLoadingInstalledApps"))
    }

    @MainActor
    func testAutoCleanReviewPageCarriesAllCleanupDecisionTiers() {
        let cache = makeStorageItem(sourceID: "caches", title: "Build Cache", tier: .green, sizeBytes: 1_000)
        let review = makeStorageItem(sourceID: "downloads", title: "Archive", tier: .yellow, sizeBytes: 5_000)
        let careful = makeStorageItem(sourceID: "applications", title: "Xcode", tier: .red, sizeBytes: 3_000)
        let store = ScanStore()
        store.result = ScanResult(
            generatedAt: Date(timeIntervalSince1970: 100),
            scanSeconds: 1,
            system: makeSnapshot(),
            groups: [],
            items: [review, careful, cache],
            deniedPaths: []
        )

        XCTAssertEqual(store.items(for: .green).map(\.title), ["Build Cache", "Archive", "Xcode"])

        store.showCleanupReview(scope: .needsReview, selectedItemID: review.id)

        XCTAssertEqual(store.selectedFilter, .green)
        XCTAssertEqual(store.requestedFilter, .green)
        XCTAssertEqual(store.preferredItemScopeFilter, .needsReview)
        XCTAssertEqual(store.selectedItemID, review.id)
    }

    func testOverviewRoutesReviewAndCarefulItemsIntoAutoCleanReviewPage() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let overviewSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/OverviewView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(overviewSource.contains("store.showCleanupReview(scope: .cleanable)"))
        XCTAssertTrue(overviewSource.contains("store.showCleanupReview(scope: .needsReview)"))
        XCTAssertTrue(overviewSource.contains("store.showCleanupReview(scope: .careful)"))
        XCTAssertFalse(overviewSource.contains("selection = .all"))
    }

    func testUnusedCommonToolsGridIsRemoved() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("struct QuickActionBar"))
        XCTAssertFalse(source.contains("private struct QuickActionButton"))
        XCTAssertFalse(source.contains("常用工具"))
        XCTAssertFalse(source.contains("Common Tools"))
    }

    func testOverviewHidesDuplicateFullDiskAccessShortcutWhilePermissionPanelIsVisible() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot
                .appendingPathComponent("Sources/StorageCleanerMac/Views/OverviewView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("scanCoverageSummary.level != .complete,"))
        XCTAssertTrue(source.contains("!store.shouldShowPermissionPanelInMainInterface"))
    }

    func testSmartCareUsesSingleStartActionAndActionableResultTiles() throws {
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
        let smartCareSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SmartCareComponents.swift"),
            encoding: .utf8
        )
        let smartScanSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SmartScanProgressView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(contentSource.contains("SmartCareHeroVisual(mode: .ready)"))
        XCTAssertTrue(smartScanSource.contains("AppButton("))
        XCTAssertTrue(smartScanSource.contains("kind: .primary"))
        XCTAssertTrue(contentSource.contains("HeroScanPage("))
        XCTAssertFalse(contentSource.contains("SmartCareStartMetric("))
        XCTAssertFalse(contentSource.contains("lastScanStrip"))
        XCTAssertFalse(contentSource.contains("HomeInsightCard"))
        XCTAssertFalse(contentSource.contains("homeInsightGrid"))

        XCTAssertTrue(overviewSource.contains("SmartCareResultTaskTile("))
        XCTAssertTrue(overviewSource.contains("store.showCleanupReview(scope: .cleanable)"))
        XCTAssertTrue(overviewSource.contains("selection = .green"))
        XCTAssertTrue(overviewSource.contains("selection = .devCaches"))
        XCTAssertTrue(overviewSource.contains("selection = .largeFiles"))
        XCTAssertTrue(overviewSource.contains("selection = .duplicates"))
        XCTAssertTrue(overviewSource.contains("performResultPrimaryAction()"))
        XCTAssertTrue(overviewSource.contains("isActionable: cleanupProjection.hasCleanableItems"))
        XCTAssertTrue(overviewSource.contains(".buttonStyle(ResponsivePlainButtonStyle"))
        XCTAssertTrue(overviewSource.contains("if isActionable"))
        XCTAssertFalse(overviewSource.contains(".brandStagePanel"))
        XCTAssertFalse(smartCareSource.contains("SmartCarePrecisionOrbit"))
        XCTAssertFalse(smartCareSource.contains("SmartCareInstrumentCore"))
        XCTAssertFalse(smartCareSource.contains("TimelineView(.animation("))
        XCTAssertTrue(smartCareSource.contains("} else if isActive {\n                ProgressView()"))
        XCTAssertTrue(smartCareSource.contains("width: progress == nil ? 32 : size"))
        XCTAssertTrue(smartCareSource.contains("ProgressView()"))
        XCTAssertTrue(smartCareSource.contains("ProgressView(value: Double(renderedProgress), total: 1)"))
        XCTAssertTrue(smartCareSource.contains(".progressViewStyle(.linear)"))
        XCTAssertTrue(smartCareSource.contains("AppMotionPolicy.shouldAnimate"))
        XCTAssertFalse(smartCareSource.contains("SmartCarePressButtonStyle"))
        XCTAssertTrue(smartCareSource.contains("accessibilityReduceMotion"))
        XCTAssertFalse(smartCareSource.contains("repeatForever"))
        XCTAssertTrue(contentSource.contains("store.scanPresentationState.showsProgressPage"))
        XCTAssertTrue(contentSource.contains("ScanProgressView(store: store, module: presentationFilter)"))
        XCTAssertTrue(contentSource.contains("await Task.yield()"))
        XCTAssertTrue(smartScanSource.contains("withAnimation(.easeOut(duration: 0.14))"))
        XCTAssertFalse(contentSource.contains(".smooth("))
        XCTAssertFalse(contentSource.contains("scanRouteTransition"))
        XCTAssertFalse(contentSource.contains("ProgressView()\n                .controlSize(.small)\n                .frame(width: 220)"))
    }

    func testMotionPolicyOnlyAnimatesActiveNonReducedMotionStates() {
        XCTAssertTrue(AppMotionPolicy.shouldAnimate(reduceMotion: false))
        XCTAssertTrue(AppMotionPolicy.shouldAnimate(reduceMotion: false, isActive: true))
        XCTAssertFalse(AppMotionPolicy.shouldAnimate(reduceMotion: false, isActive: false))
        XCTAssertFalse(AppMotionPolicy.shouldAnimate(reduceMotion: true, isActive: true))
    }

    func testResidentSurfacesDoNotUseContinuousMotion() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let residentPaths = [
            "Sources/StorageCleanerMac/Views/MenuBarStatusView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift",
            "Sources/StorageCleanerMac/Views/SettingsView.swift",
            "Sources/StorageCleanerMac/Support/MenuBarStatusRenderer.swift"
        ]

        for path in residentPaths {
            let source = try String(
                contentsOf: projectRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            XCTAssertFalse(source.contains("repeatForever"), "Unexpected continuous animation in \(path)")
            XCTAssertFalse(source.contains("TimelineView"), "Unexpected resident TimelineView in \(path)")
        }
    }

    func testBrowserPrivacyUsesStandaloneStorageWorkspace() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contentSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/ContentView.swift"),
            encoding: .utf8
        )
        let privacyViewURL = projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/PrivacyTracesView.swift")
        let workspaceURL = projectRoot.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/BrowserPrivacyWorkspaceView.swift"
        )

        XCTAssertEqual(ReviewFilter(rawValue: "privacy"), .privacy)
        XCTAssertEqual(ReviewFilter.resolvedDestination(rawValue: "privacy"), .privacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: privacyViewURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.path))
        XCTAssertFalse(contentSource.contains("PrivacyTracesView"))
        XCTAssertTrue(contentSource.contains("filter == .privacy"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("Resources/SidebarIconPrivacy.png").path))
    }

    func testAppearancePreferenceSynchronizesMainWindowAndMenuBarPanel() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let localizationSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/L10n.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(localizationSource.contains("func applyAppKitPreference()"))
        XCTAssertTrue(localizationSource.contains("NSApplication.shared.appearance = nil"))
        XCTAssertTrue(localizationSource.contains("NSAppearance(named: .aqua)"))
        XCTAssertTrue(localizationSource.contains("NSAppearance(named: .darkAqua)"))
        XCTAssertTrue(appSource.contains(".applyAppKitPreference()"))
        XCTAssertTrue(settingsSource.contains("newValue.applyAppKitPreference()"))
    }

    func testStandaloneCleanupHistoryPageIsRemovedAfterRecordIntegration() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contentSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/ContentView.swift"),
            encoding: .utf8
        )
        let itemListSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/ItemListView.swift"),
            encoding: .utf8
        )
        let storeSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift"),
            encoding: .utf8
        )
        let heavyWorkServiceSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/ScanHeavyWorkService.swift"),
            encoding: .utf8
        )
        let cleanupViewURL = projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/CleanupHistoryView.swift")

        XCTAssertNil(ReviewFilter(rawValue: "cleanupHistory"))
        XCTAssertEqual(ReviewFilter.resolvedDestination(rawValue: "cleanupHistory"), .green)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanupViewURL.path))
        XCTAssertFalse(contentSource.contains("CleanupHistoryView"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("Resources/SidebarIconHistory.png").path))
        XCTAssertTrue(itemListSource.contains("greenCleanupRecordStrip"))
        XCTAssertTrue(itemListSource.contains("清理记录"))
        XCTAssertTrue(itemListSource.contains("store.copyCleanupHistoryEntry(latest)"))
        XCTAssertTrue(itemListSource.contains("store.requestRestoreLatestCleanup()"))
        XCTAssertTrue(itemListSource.contains("arrow.uturn.backward"))
        XCTAssertFalse(itemListSource.contains("arrow.uturn.backward.circle"))
        XCTAssertTrue(itemListSource.contains(".appButtonChrome(.secondary)"))
        XCTAssertTrue(contentSource.contains("撤销最近清理？"))
        XCTAssertTrue(contentSource.contains("不会覆盖或自动改名"))
        XCTAssertFalse(storeSource.contains("CleanupService.restoreFromTrash(records)"))
        XCTAssertTrue(heavyWorkServiceSource.contains("CleanupService.restoreFromTrash(records)"))
        XCTAssertTrue(heavyWorkServiceSource.contains("Task.detached(priority: .userInitiated)"))
    }

    func testToolboxCopyDoesNotReferToOldSeparatePages() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let menuBarChromeSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift"),
            encoding: .utf8
        )
        let maintenanceSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/SmartMaintenanceService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(menuBarChromeSource.contains("打开主窗口"))
        XCTAssertFalse(menuBarChromeSource.contains("打开存储清理助手"))
        XCTAssertFalse(menuBarChromeSource.contains("打开工具箱内存"))
        XCTAssertFalse(menuBarChromeSource.contains("打开内存页"))
        XCTAssertTrue(maintenanceSource.contains("系统工具的应用更新页"))
        XCTAssertFalse(maintenanceSource.contains("工具箱的升级标签"))
        XCTAssertFalse(maintenanceSource.contains("升级页批量处理"))
        XCTAssertFalse(maintenanceSource.contains("updater page"))
    }

    func testRuntimeAppArtworkIsDownsampledBeforeCaching() throws {
        let image = try XCTUnwrap(AppArtwork.iconImage())

        XCTAssertLessThanOrEqual(image.size.width, 512)
        XCTAssertLessThanOrEqual(image.size.height, 512)
    }

    func testDockIconTransitionUsesSmoothstepProgress() {
        XCTAssertEqual(AppArtwork.transitionProgress(step: 0, totalSteps: 18), 0)
        XCTAssertEqual(AppArtwork.transitionProgress(step: 9, totalSteps: 18), 0.5)
        XCTAssertEqual(AppArtwork.transitionProgress(step: 18, totalSteps: 18), 1)
        XCTAssertEqual(AppArtwork.transitionProgress(step: -1, totalSteps: 18), 0)
        XCTAssertEqual(AppArtwork.transitionProgress(step: 19, totalSteps: 18), 1)
    }

    @MainActor
    func testDockIconBlendUsesExactEndpointImages() throws {
        let light = try XCTUnwrap(AppArtwork.iconImage(for: .light))
        let dark = try XCTUnwrap(AppArtwork.iconImage(for: .dark))

        XCTAssertTrue(AppArtwork.blendedIcon(from: light, to: dark, progress: 0) === light)
        XCTAssertTrue(AppArtwork.blendedIcon(from: light, to: dark, progress: 1) === dark)
        let midpoint = AppArtwork.blendedIcon(from: light, to: dark, progress: 0.5)
        XCTAssertEqual(midpoint.size, dark.size)
        assertRuntimeIconRepresentations(midpoint)
    }

    func testRuntimeIconsCarryOpticallySizedLightAndDarkRepresentations() throws {
        assertRuntimeIconRepresentations(
            try XCTUnwrap(AppArtwork.iconImage(for: .light))
        )
        assertRuntimeIconRepresentations(
            try XCTUnwrap(AppArtwork.iconImage(for: .dark))
        )
    }

    private func assertRuntimeIconRepresentations(
        _ image: NSImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (logicalSize, pixelSize) in [(16, 32), (32, 64), (64, 128)] {
            XCTAssertTrue(
                image.representations.contains { representation in
                    representation.size == NSSize(width: logicalSize, height: logicalSize)
                        && representation.pixelsWide == pixelSize
                        && representation.pixelsHigh == pixelSize
                },
                "Missing \(logicalSize)pt @2x runtime icon representation",
                file: file,
                line: line
            )
        }
    }

    func testArtworkGeneratorPreservesApprovedSourceIcons() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptSource = try String(
            contentsOf: projectRoot.appendingPathComponent("script/generate_artwork.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(scriptSource.contains("generatedAppIconImage(dark: dark, size: size)"))
        XCTAssertTrue(scriptSource.contains("try writeICNS(from: iconset"))
        XCTAssertFalse(scriptSource.contains("to: resources.appendingPathComponent(\"AppIconGeneratedLight.png\")"))
        XCTAssertFalse(scriptSource.contains("to: resources.appendingPathComponent(\"AppIconGeneratedDark.png\")"))
    }

    func testArtworkGeneratorRemovesTheBakedAppIconPerimeter() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptSource = try String(
            contentsOf: projectRoot.appendingPathComponent("script/generate_artwork.swift"),
            encoding: .utf8
        )
        let compactStart = try XCTUnwrap(
            scriptSource.range(of: "func drawCompactBroomAppIcon")
        )
        let compactEnd = try XCTUnwrap(
            scriptSource.range(of: "func drawSimpleCleanAppIcon", range: compactStart.upperBound..<scriptSource.endIndex)
        )
        let compactIcon = scriptSource[compactStart.lowerBound..<compactEnd.lowerBound]

        XCTAssertFalse(compactIcon.contains("let rim = NSBezierPath"))
        XCTAssertTrue(scriptSource.contains("source.size.width * 0.015"))
        XCTAssertTrue(scriptSource.contains("source.size.height * 0.015"))
        XCTAssertTrue(scriptSource.contains("from: sourceRect"))
    }

    func testAppIconICNSContainsEveryPNGCompatibleMacRepresentation() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: projectRoot.appendingPathComponent("Resources/AppIcon.icns"))

        func bigEndianUInt32(at offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].reduce(UInt32(0)) { value, byte in
                (value << 8) | UInt32(byte)
            }
        }

        XCTAssertGreaterThan(data.count, 8)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "icns")
        XCTAssertEqual(Int(bigEndianUInt32(at: 4)), data.count)

        var types: [String] = []
        var offset = 8
        while offset + 8 <= data.count {
            let chunkLength = Int(bigEndianUInt32(at: offset + 4))
            XCTAssertGreaterThanOrEqual(chunkLength, 8)
            XCTAssertLessThanOrEqual(offset + chunkLength, data.count)
            guard chunkLength >= 8, offset + chunkLength <= data.count else { break }

            types.append(String(data: data[offset..<(offset + 4)], encoding: .ascii) ?? "")
            offset += chunkLength
        }

        XCTAssertEqual(offset, data.count)
        XCTAssertEqual(types, ["ic11", "ic12", "ic07", "ic13", "ic08", "ic14", "ic09", "ic10"])
    }

    func testArtworkGeneratorAndPackagingExcludeRetiredSidebarPNGs() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptSource = try String(
            contentsOf: projectRoot.appendingPathComponent("script/generate_artwork.swift"),
            encoding: .utf8
        )
        let buildScriptSource = try String(
            contentsOf: projectRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )
        let releaseScriptSource = try String(
            contentsOf: projectRoot.appendingPathComponent("script/make_release_dmg.sh"),
            encoding: .utf8
        )
        let removedIconNames = [
            "SidebarIconOverview",
            "SidebarIconReady",
            "SidebarIconLargeFiles",
            "SidebarIconDuplicates",
            "SidebarIconAll",
            "SidebarIconStartup",
            "SidebarIconMemory",
            "SidebarIconUninstall",
            "SidebarIconUpdater",
            "SidebarIconScanHistory",
            "SidebarIconHistory",
            "SidebarIconPrivacy",
            "SidebarIconTrashBins",
            "SidebarIconReview",
            "SidebarIconCareful"
        ]

        for iconName in removedIconNames {
            XCTAssertFalse(scriptSource.contains(iconName))
        }
        XCTAssertFalse(buildScriptSource.contains("-name 'SidebarIcon*.png'"))
        XCTAssertFalse(releaseScriptSource.contains("-name 'SidebarIcon*.png'"))
    }

    func testExportAndCopyMessagesStayReviewOnly() throws {
        let storeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift")
        let store = try String(contentsOf: storeURL, encoding: .utf8)

        XCTAssertTrue(store.contains("仅供复核，不代表已执行更新"))
        XCTAssertTrue(store.contains("仅供复核，不会卸载应用"))
        XCTAssertTrue(store.contains("仅记录已移到废纸篓的项目"))
        XCTAssertTrue(store.contains("报告仅记录当前结果"))
        XCTAssertTrue(store.contains("导出不会执行清理"))
        XCTAssertTrue(store.contains("仅用于定位复核"))
        XCTAssertTrue(store.contains("已在访达中显示，仅打开位置，不会移动或删除文件"))
        XCTAssertTrue(store.contains("已打开废纸篓供复核，尚未清空或删除任何文件"))
        XCTAssertTrue(store.contains("已打开系统存储设置，仅用于查看系统建议，不会执行清理"))
        XCTAssertTrue(store.contains("已打开登录项设置；仍需在系统设置里手动确认更改"))
    }

    func testSettingsPermissionButtonsExplainSystemConfirmationBoundary() throws {
        let viewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Views/SettingsView.swift")
        let source = try String(contentsOf: viewURL, encoding: .utf8)

        XCTAssertTrue(source.contains("openFullDiskAccessSettings()"))
        XCTAssertTrue(source.contains("已打开完整磁盘访问设置，授权后请重新扫描"))
        XCTAssertTrue(source.contains("openFilesAndFoldersSettings()"))
        XCTAssertTrue(source.contains("已打开文件与文件夹设置，授权在系统设置中完成"))
    }

    func testOverviewPermissionPanelListsRequiredAccessAndSettingsLinks() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let overviewSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/OverviewView.swift"),
            encoding: .utf8
        )
        let homeSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/ContentView.swift"),
            encoding: .utf8
        )

        for source in [overviewSource, homeSource] {
            XCTAssertTrue(source.contains("打开权限列表"))
            XCTAssertTrue(source.contains("授权文件夹"))
            XCTAssertTrue(source.contains("requestRequiredFolderAccess()"))
            XCTAssertTrue(source.contains("isFullDiskAccessVerified"))
            XCTAssertTrue(source.contains("无需重复授权"))
            XCTAssertTrue(source.contains("完整磁盘访问"))
            XCTAssertTrue(source.contains("文件与文件夹"))
            XCTAssertTrue(source.contains("openFullDiskAccessSettings()"))
            XCTAssertTrue(source.contains("openFilesAndFoldersSettings()"))
            XCTAssertTrue(source.contains("private var statusBadge: some View"))
            XCTAssertFalse(source.contains("permissionActionTitle"))
            XCTAssertFalse(source.contains("openPermissionSettings(for item"))
            XCTAssertFalse(source.contains("Label(actionTitle, systemImage: \"arrow.up.forward.app\")"))
        }
        XCTAssertTrue(overviewSource.contains("scanReadinessCheckedAt"))
        XCTAssertTrue(overviewSource.contains("shouldShowPermissionPanelInMainInterface"))
        XCTAssertTrue(homeSource.contains("授权文件夹"))
        XCTAssertTrue(homeSource.contains("prepareInitialPermissionCheckOnLaunch()"))
        XCTAssertTrue(homeSource.contains("shouldShowPermissionPanelInMainInterface"))
        XCTAssertTrue(homeSource.contains("ScanReadinessPanel(store: store"))
    }

    @MainActor
    func testInitialPermissionCheckCompletionHidesMainPermissionPanel() {
        let defaults = UserDefaults.standard
        let key = ScanStore.initialPermissionCheckDefaultsKey
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        let firstLaunchStore = ScanStore()
        XCTAssertFalse(firstLaunchStore.didCompleteInitialPermissionCheck)
        XCTAssertTrue(firstLaunchStore.shouldShowPermissionPanelInMainInterface)

        defaults.set(true, forKey: key)
        let laterLaunchStore = ScanStore()
        XCTAssertTrue(laterLaunchStore.didCompleteInitialPermissionCheck)
        XCTAssertFalse(laterLaunchStore.shouldShowPermissionPanelInMainInterface)
    }

    func testAccessRepairGuideKeepsPermissionFlowInOrder() {
        let steps = AccessRepairGuideService.steps()

        XCTAssertEqual(steps.map(\.id), [.openSettings, .grantAccess, .rescan])
        XCTAssertEqual(steps.map(\.systemImage), ["folder", "checkmark.shield.fill", "arrow.clockwise"])
    }

    func testAccessRepairGuidePromptsOnlyWhenCurrentReadinessConfirmsPermissionGaps() {
        let permissionLimited = makeLastScanStatus(deniedCount: 1)
        let currentBlocked = ScanReadinessSummary(
            items: [
                ScanReadinessItem(
                    location: ScanReadinessLocation(title: "Downloads", path: "~/Downloads", systemImage: "arrow.down.circle.fill"),
                    status: .needsPermission
                )
            ]
        )
        let currentReady = ScanReadinessSummary(
            items: [
                ScanReadinessItem(
                    location: ScanReadinessLocation(title: "Downloads", path: "~/Downloads", systemImage: "arrow.down.circle.fill"),
                    status: .readable
                )
            ]
        )
        XCTAssertEqual(permissionLimited.recommendedAction, .repairAccess)
        XCTAssertTrue(
            AccessRepairGuideService.shouldPromptBeforeScan(
                latestStatus: permissionLimited,
                currentReadiness: currentBlocked
            )
        )
        XCTAssertFalse(
            AccessRepairGuideService.shouldPromptBeforeScan(
                latestStatus: permissionLimited,
                currentReadiness: nil
            )
        )
        XCTAssertFalse(
            AccessRepairGuideService.shouldPromptBeforeScan(
                latestStatus: permissionLimited,
                currentReadiness: currentReady
            )
        )

        let current = makeLastScanStatus(deniedCount: 0)
        XCTAssertEqual(current.recommendedAction, .reviewResult)
        XCTAssertFalse(
            AccessRepairGuideService.shouldPromptBeforeScan(
                latestStatus: current,
                currentReadiness: currentBlocked
            )
        )

        let stale = makeLastScanStatus(deniedCount: 0, referenceOffset: 3 * 60 * 60)
        XCTAssertEqual(stale.recommendedAction, .rescan)
        XCTAssertFalse(
            AccessRepairGuideService.shouldPromptBeforeScan(
                latestStatus: stale,
                currentReadiness: currentBlocked
            )
        )
        XCTAssertFalse(
            AccessRepairGuideService.shouldPromptBeforeScan(
                latestStatus: nil,
                currentReadiness: currentBlocked
            )
        )
    }

    func testAccessRepairGuideRefreshesCurrentReadinessOnlyForRepairableScans() {
        let permissionLimited = makeLastScanStatus(deniedCount: 1)
        let current = makeLastScanStatus(deniedCount: 0)
        let stale = makeLastScanStatus(deniedCount: 0, referenceOffset: 3 * 60 * 60)

        XCTAssertTrue(
            AccessRepairGuideService.shouldRefreshCurrentReadinessBeforeScan(
                latestStatus: permissionLimited
            )
        )
        XCTAssertFalse(
            AccessRepairGuideService.shouldRefreshCurrentReadinessBeforeScan(
                latestStatus: current
            )
        )
        XCTAssertFalse(
            AccessRepairGuideService.shouldRefreshCurrentReadinessBeforeScan(
                latestStatus: stale
            )
        )
        XCTAssertFalse(
            AccessRepairGuideService.shouldRefreshCurrentReadinessBeforeScan(
                latestStatus: nil
            )
        )
    }

    @MainActor
    func testScanStoreTreatsAccessCheckAsPreparingScan() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let store = ScanStore()

        XCTAssertFalse(store.isPreparingScan)
        XCTAssertEqual(store.scanActionSystemImage, "arrow.clockwise")
        XCTAssertEqual(store.scanActionTitle(normalTitle: "重新扫描"), "重新扫描")
        XCTAssertEqual(store.scanActionSystemImage(normalSystemImage: "play.fill"), "play.fill")

        store.isCheckingScanReadiness = true

        XCTAssertTrue(store.isPreparingScan)
        XCTAssertEqual(store.scanActionSystemImage, "lock.open")
        XCTAssertEqual(store.scanActionTitle(normalTitle: "重新扫描"), "检查权限")
        XCTAssertEqual(store.scanActionSystemImage(normalSystemImage: "play.fill"), "lock.open")

        store.isCheckingScanReadiness = false
        store.isScanning = true

        XCTAssertTrue(store.isPreparingScan)
        XCTAssertEqual(store.scanActionSystemImage, "waveform.path.ecg")
        XCTAssertEqual(store.scanActionTitle(normalTitle: "重新扫描"), "重新扫描")
        XCTAssertEqual(store.scanActionSystemImage(normalSystemImage: "play.fill"), "waveform.path.ecg")
    }

    @MainActor
    func testScanStoreBlocksDuplicateScanDuringMainScanPreparation() {
        let store = ScanStore()

        XCTAssertTrue(store.canScanDuplicates)

        store.isCheckingScanReadiness = true
        XCTAssertFalse(store.canScanDuplicates)
        store.scanDuplicateFiles()
        XCTAssertFalse(store.isScanningDuplicates)

        store.isCheckingScanReadiness = false
        store.isScanning = true
        XCTAssertFalse(store.canScanDuplicates)
        store.scanDuplicateFiles()
        XCTAssertFalse(store.isScanningDuplicates)

        store.isScanning = false
        store.isScanningDuplicates = true
        XCTAssertFalse(store.canScanDuplicates)
    }

    @MainActor
    func testScanStoreBlocksMainScanDuringDuplicateScan() {
        let store = ScanStore()
        store.isScanningDuplicates = true

        XCTAssertTrue(store.isPreparingScan)

        store.startScan()
        XCTAssertFalse(store.isScanning)

        store.startScanRespectingAccessGuide()
        XCTAssertFalse(store.isCheckingScanReadiness)
        XCTAssertFalse(store.isScanning)
    }

    @MainActor
    func testScanStoreBlocksTrashActionsDuringMainScanPreparation() {
        let store = ScanStore(cleanupFeatureConfiguration: .legacy)
        let cache = makeStorageItem(sourceID: "caches", title: "Build Cache", tier: .green)
        store.result = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: [cache],
            deniedPaths: []
        )

        XCTAssertTrue(store.canRequestTrash(cache))
        XCTAssertTrue(store.canRequestGreenTrash)
        XCTAssertTrue(store.canRequestEmptyTrash)

        store.isCheckingTrashSummary = true

        XCTAssertFalse(store.canRequestTrash(cache))
        XCTAssertFalse(store.canRequestGreenTrash)
        XCTAssertFalse(store.canRequestEmptyTrash)

        store.requestTrash(cache)
        XCTAssertNil(store.pendingTrashItem)

        store.pendingBulkTrashItems = [cache]
        store.confirmTrashAllGreen()
        XCTAssertEqual(store.pendingBulkTrashItems.map(\.id), [cache.id])

        store.pendingEmptyTrashSummary = TrashSummary(itemCount: 1, totalBytes: 42)
        store.confirmEmptyTrash()
        XCTAssertEqual(store.pendingEmptyTrashSummary, TrashSummary(itemCount: 1, totalBytes: 42))
        XCTAssertFalse(store.isEmptyingTrash)

        store.pendingTrashItem = nil
        store.pendingBulkTrashItems = []
        store.pendingEmptyTrashSummary = nil
        store.isCheckingTrashSummary = false
        store.isCheckingScanReadiness = true

        XCTAssertFalse(store.canRequestTrash(cache))
        XCTAssertFalse(store.canRequestGreenTrash)
        XCTAssertFalse(store.canRequestEmptyTrash)

        store.requestTrash(cache)
        XCTAssertNil(store.pendingTrashItem)

        store.pendingTrashItem = cache
        store.confirmTrash()
        XCTAssertEqual(store.pendingTrashItem?.id, cache.id)

        store.pendingBulkTrashItems = [cache]
        store.confirmTrashAllGreen()
        XCTAssertEqual(store.pendingBulkTrashItems.map(\.id), [cache.id])

        store.pendingEmptyTrashSummary = TrashSummary(itemCount: 1, totalBytes: 42)
        store.confirmEmptyTrash()
        XCTAssertEqual(store.pendingEmptyTrashSummary, TrashSummary(itemCount: 1, totalBytes: 42))
        XCTAssertFalse(store.isEmptyingTrash)
    }

    @MainActor
    func testScanStoreBlocksMemoryActionsDuringMemoryRefreshOrOptimization() {
        let store = ScanStore()
        let app = MemoryProcess(
            id: 9_991,
            name: "Example App",
            path: "/Applications/Example.app/Contents/MacOS/Example",
            iconPath: "/Applications/Example.app",
            bundlePath: "/Applications/Example.app",
            residentBytes: 512_000_000,
            percent: 3.2,
            canQuit: true
        )
        let systemProcess = MemoryProcess(
            id: 9_992,
            name: "kernel_task",
            path: "/usr/bin/kernel_task",
            iconPath: "/usr/bin/kernel_task",
            bundlePath: nil,
            residentBytes: 1_024_000_000,
            percent: 6.4,
            canQuit: false
        )
        store.memorySnapshot = MemorySnapshot(
            generatedAt: Date(),
            physicalBytes: 16_000_000_000,
            freeBytes: 1_000_000_000,
            inactiveBytes: 0,
            speculativeBytes: 0,
            fileBackedBytes: 1_000_000_000,
            purgeableBytes: 0,
            wiredBytes: 1_000_000_000,
            compressedBytes: 1_000_000_000,
            swapUsedBytes: 0,
            pressureFreePercentage: 80,
            pressureSummary: "Normal",
            topProcesses: [app, systemProcess]
        )

        XCTAssertTrue(store.canOptimizeMemory)
        XCTAssertTrue(store.canRefreshMemory)
        XCTAssertTrue(store.canRequestMemoryQuit(app))
        XCTAssertFalse(store.canRequestMemoryQuit(systemProcess))

        store.isLoadingMemory = true

        XCTAssertFalse(store.canOptimizeMemory)
        XCTAssertFalse(store.canRefreshMemory)
        XCTAssertFalse(store.canRequestMemoryQuitActions)
        XCTAssertFalse(store.canRequestMemoryQuit(app))

        store.optimizeMemory()
        XCTAssertFalse(store.isOptimizingMemory)

        store.requestQuitProcess(app)
        XCTAssertNil(store.pendingMemoryProcess)

        store.setMemoryProcessSelection(app, isSelected: true)
        XCTAssertFalse(store.isMemoryProcessSelected(app))

        store.selectAllMemoryProcessesForQuit()
        XCTAssertTrue(store.selectedMemoryProcessIDs.isEmpty)

        store.pendingMemoryProcess = app
        store.confirmQuitProcess()
        XCTAssertEqual(store.pendingMemoryProcess?.id, app.id)

        store.pendingMemoryProcessesToQuit = [app]
        store.confirmQuitSelectedMemoryProcesses()
        XCTAssertEqual(store.pendingMemoryProcessesToQuit.map(\.id), [app.id])

        store.isLoadingMemory = false
        store.isOptimizingMemory = true

        XCTAssertFalse(store.canOptimizeMemory)
        XCTAssertFalse(store.canRefreshMemory)
        XCTAssertFalse(store.canRequestMemoryQuitActions)
    }

    @MainActor
    func testScanStoreBlocksStartupAndUninstallActionsDuringRefresh() {
        let store = ScanStore()
        let highAttribution = StartupItemsDomain.Attribution(
            applicationBundleIdentifier: "com.example.app",
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            applicationName: "Example",
            developerName: "Example Developer",
            teamIdentifier: "TEAMID",
            designatedRequirement: nil,
            evidence: [
                StartupItemsDomain.AttributionEvidence(
                    kind: .associatedBundleIdentifier,
                    value: "com.example.app",
                    confidence: .high
                ),
            ]
        )
        let directlyManageable = StartupItemsDomain.ActionCapability(
            canEnableDirectly: true,
            canDisableDirectly: true,
            canStopCurrentSession: true,
            canOpenSystemSettings: true,
            canRevealInFinder: true,
            canOpenParentApp: true,
            canRemoveOrphan: false,
            requiresAdministrator: false,
            isReadOnly: false,
            isManaged: false
        )
        let startupItem = StartupItemsDomain.Candidate(
            id: "user-agent",
            source: .launchdPlist,
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Example Agent",
            label: "com.example.agent",
            plistURL: URL(fileURLWithPath: "\(NSHomeDirectory())/Library/LaunchAgents/example.plist"),
            executableURL: URL(fileURLWithPath: "/Applications/Example.app/Contents/MacOS/Example"),
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            configuration: nil,
            state: StartupItemsDomain.State(
                registration: .registered,
                authorization: .approved,
                enablement: .enabled,
                load: .loaded,
                process: .running(pid: 123),
                management: .directlyManageable
            ),
            attribution: highAttribution,
            actionCapability: directlyManageable,
            diagnosticEvidence: []
        )
        let systemStartupItem = StartupItemsDomain.Candidate(
            id: "system-agent",
            source: .launchdPlist,
            kind: .systemLaunchDaemon,
            scope: .system,
            name: "System Agent",
            label: "com.apple.example",
            plistURL: URL(fileURLWithPath: "/System/Library/LaunchDaemons/example.plist"),
            executableURL: URL(fileURLWithPath: "/usr/libexec/example"),
            applicationURL: nil,
            configuration: nil,
            state: StartupItemsDomain.State(
                registration: .registered,
                authorization: .notApplicable,
                enablement: .enabled,
                load: .loaded,
                process: .waiting,
                management: .systemProtected
            ),
            attribution: nil,
            actionCapability: .readOnly,
            diagnosticEvidence: ["apple-system-location"]
        )
        let app = makeInstalledApp(name: "Example")

        XCTAssertTrue(store.canRequestStartupOperation(startupItem, operation: .disable))
        XCTAssertTrue(store.canRefreshStartupItems)
        XCTAssertFalse(store.canRequestStartupOperation(systemStartupItem, operation: .disable))
        XCTAssertTrue(store.canRequestUninstall(app))
        XCTAssertTrue(store.canRefreshInstalledApps)

        store.isLoadingStartupItems = true

        XCTAssertFalse(store.canRequestStartupOperation(startupItem, operation: .disable))
        XCTAssertFalse(store.canRefreshStartupItems)
        store.requestStartupOperation(.disable, candidate: startupItem)
        XCTAssertNil(store.pendingStartupOperationPlan)

        store.isLoadingInstalledApps = true

        XCTAssertFalse(store.canRequestUninstall(app))
        XCTAssertFalse(store.canRefreshInstalledApps)
        store.requestUninstall(app)
        XCTAssertNil(store.pendingUninstallApp)

        store.pendingUninstallApp = app
        store.confirmUninstall()
        XCTAssertEqual(store.pendingUninstallApp?.id, app.id)

        store.isLoadingInstalledApps = false
        store.isUninstallingApp = true
        XCTAssertFalse(store.canRequestUninstall(app))
        XCTAssertFalse(store.canRefreshInstalledApps)

        store.isUninstallingApp = false
        store.isCleaningRelatedAppFiles = true
        XCTAssertFalse(store.canRequestUninstall(app))
        XCTAssertFalse(store.canRefreshInstalledApps)

        store.isCleaningRelatedAppFiles = false
        store.pendingRelatedCleanupApp = app
        XCTAssertFalse(store.canRequestUninstall(app))
        XCTAssertFalse(store.canRefreshInstalledApps)
    }

    @MainActor
    func testMemoryRefreshDismissesStaleQuitConfirmationAndSelection() {
        let store = ScanStore()
        let app = MemoryProcess(
            id: 9_991,
            name: "Example App",
            path: "/Applications/Example.app/Contents/MacOS/Example",
            iconPath: "/Applications/Example.app",
            bundlePath: "/Applications/Example.app",
            residentBytes: 512_000_000,
            percent: 3.2,
            canQuit: true
        )

        store.pendingMemoryProcess = app
        store.pendingMemoryProcessesToQuit = [app]
        store.selectedMemoryProcessIDs = [app.id]

        store.refreshMemory()

        XCTAssertNil(store.pendingMemoryProcess)
        XCTAssertTrue(store.pendingMemoryProcessesToQuit.isEmpty)
        XCTAssertTrue(store.selectedMemoryProcessIDs.isEmpty)
        XCTAssertFalse(store.canRefreshMemory)
    }

    @MainActor
    func testScanStoreExportsOnlyWhenCurrentResultIsStable() {
        let store = ScanStore()

        XCTAssertFalse(store.canExportCurrentScanArtifacts)

        store.result = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: [],
            deniedPaths: []
        )
        XCTAssertTrue(store.canExportCurrentScanArtifacts)

        store.isCheckingScanReadiness = true
        XCTAssertFalse(store.canExportCurrentScanArtifacts)

        store.isCheckingScanReadiness = false
        store.isScanning = true
        XCTAssertFalse(store.canExportCurrentScanArtifacts)

        store.isScanning = false
        store.isScanningDuplicates = true
        XCTAssertFalse(store.canExportCurrentScanArtifacts)
    }

    @MainActor
    func testOneClickUserRequestKeepsAutomaticQueueBehindConfirmation() {
        let store = ScanStore()
        store.appUpdates = [makeAppUpdateItem(name: "Brew", method: .homebrew, caskToken: "brew-app")]

        store.requestOneClickAppUpdates()

        XCTAssertNotNil(store.pendingOneClickUpdatePlan)
        XCTAssertFalse(store.isRunningOneClickUpdate)
    }

    @MainActor
    func testDirectAppUpdateRejectsStaleAutomaticEligibility() {
        let store = ScanStore()
        let stale = makeAppUpdateItem(name: "Brew", method: .homebrew, caskToken: "brew-app")
        var current = stale
        current.canAutomaticallyUpdate = false
        current.requiresUserInteraction = true
        store.appUpdates = [current]

        store.requestAppUpdate(stale)

        XCTAssertFalse(store.isRunningOneClickUpdate)
        XCTAssertNil(store.pendingOneClickUpdatePlan)
        XCTAssertNil(store.appUpdateQueueSnapshot)
    }

    func testAppUpdaterBatchButtonsCreateVerifiedAutomaticRequests() throws {
        let viewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift")
        let source = try String(contentsOf: viewURL, encoding: .utf8)
        let summaryStart = try XCTUnwrap(source.range(of: "case let .scanSummary(summary):"))
        let summaryEnd = try XCTUnwrap(
            source.range(of: "case let .managing(snapshot):", range: summaryStart.upperBound..<source.endIndex)
        )
        let summarySource = String(source[summaryStart.lowerBound..<summaryEnd.lowerBound])
        let managerEnd = try XCTUnwrap(
            source.range(of: "case let .preparingUpdate(plan):", range: summaryEnd.upperBound..<source.endIndex)
        )
        let managerSource = String(source[summaryEnd.lowerBound..<managerEnd.lowerBound])

        XCTAssertTrue(summarySource.contains("summary.batchEligibleApps.map(\\.id)"))
        XCTAssertEqual(
            summarySource.components(separatedBy: "store.requestSelectedAppUpdates(").count - 1,
            1
        )
        XCTAssertEqual(
            managerSource.components(separatedBy: "store.requestSelectedAppUpdates(applicationIDs: ids)").count - 1,
            1
        )
        XCTAssertFalse(summarySource.contains("store.requestOneClickAppUpdates()"))
        XCTAssertFalse(managerSource.contains("store.previewOneClickAppUpdates()"))
    }

    func testPrimaryViewsDoNotExposeEquivalentDuplicateControls() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let utilitySource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"),
            encoding: .utf8
        )
        let appUpdatesSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift"),
            encoding: .utf8
        )
        let contentSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/ContentView.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"),
            encoding: .utf8
        )

        let installedRowStart = try XCTUnwrap(utilitySource.range(of: "private struct InstalledAppRow: View"))
        let installedRowEnd = try XCTUnwrap(
            utilitySource.range(of: "private struct InstalledAppIcon", range: installedRowStart.upperBound..<utilitySource.endIndex)
        )
        let installedRowSource = String(utilitySource[installedRowStart.lowerBound..<installedRowEnd.lowerBound])
        XCTAssertEqual(
            installedRowSource.components(separatedBy: "store.requestUninstall(app)").count - 1,
            1
        )
        XCTAssertFalse(installedRowSource.contains(".onTapGesture"))
        XCTAssertTrue(installedRowSource.contains(".contextMenu {"))
        let contextActions = try XCTUnwrap(installedRowSource.components(separatedBy: ".contextMenu {").last)
        XCTAssertFalse(contextActions.contains("requestUninstall"))
        XCTAssertFalse(installedRowSource.contains("inspectInstalledApp"))

        let updateRowStart = try XCTUnwrap(appUpdatesSource.range(of: "private struct AppUpdateCatalogRow: View"))
        let updateRowEnd = try XCTUnwrap(
            appUpdatesSource.range(
                of: "private struct AppUpdateCatalogDetail: View",
                range: updateRowStart.upperBound..<appUpdatesSource.endIndex
            )
        )
        let updateRowSource = String(
            appUpdatesSource[updateRowStart.lowerBound..<updateRowEnd.lowerBound]
        )
        XCTAssertEqual(
            updateRowSource.components(separatedBy: "Toggle(").count - 1,
            1
        )
        XCTAssertFalse(updateRowSource.contains("store."))
        XCTAssertFalse(updateRowSource.contains(".onTapGesture"))
        XCTAssertFalse(updateRowSource.contains(".contextMenu"))
        XCTAssertFalse(updateRowSource.contains("Menu"))

        XCTAssertFalse(contentSource.contains(".keyboardShortcut(\"r\", modifiers: [.command])"))
        XCTAssertEqual(
            appSource.components(separatedBy: ".keyboardShortcut(\"r\", modifiers: [.command])").count - 1,
            1
        )
    }

    func testComputerHealthCommandsRunOnlyAfterExplicitActions() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/ComputerHealthView.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(viewSource.contains(".task {"))
        XCTAssertFalse(viewSource.contains(".onAppear"))
        XCTAssertTrue(viewSource.contains("Task { await healthStore.refresh"))
        XCTAssertTrue(viewSource.contains("networkStore.start(consentGranted: true)"))
        XCTAssertFalse(appSource.contains("computerHealthStore.refresh"))
        XCTAssertFalse(appSource.contains("networkSpeedTestStore.start"))
        XCTAssertEqual(
            appSource.components(separatedBy: "@StateObject private var computerHealthStore").count - 1,
            1
        )
        XCTAssertEqual(
            appSource.components(separatedBy: "@StateObject private var networkSpeedTestStore").count - 1,
            1
        )
    }

    func testOverviewResultActionKeepsItsMeaningWhileTrashWorkIsBusy() {
        let readyCleanup = OverviewResultActionPolicy(
            hasCleanableItems: true,
            canRequestGreenTrash: true,
            canRequestTrashActions: true
        )
        XCTAssertEqual(readyCleanup.action, .reviewAndClean)
        XCTAssertTrue(readyCleanup.isEnabled)

        let busyCleanup = OverviewResultActionPolicy(
            hasCleanableItems: true,
            canRequestGreenTrash: false,
            canRequestTrashActions: false
        )
        XCTAssertEqual(busyCleanup.action, .reviewAndClean)
        XCTAssertFalse(busyCleanup.isEnabled)

        let readyRescan = OverviewResultActionPolicy(
            hasCleanableItems: false,
            canRequestGreenTrash: false,
            canRequestTrashActions: true
        )
        XCTAssertEqual(readyRescan.action, .scanAgain)
        XCTAssertTrue(readyRescan.isEnabled)

        let busyRescan = OverviewResultActionPolicy(
            hasCleanableItems: false,
            canRequestGreenTrash: false,
            canRequestTrashActions: false
        )
        XCTAssertEqual(busyRescan.action, .scanAgain)
        XCTAssertFalse(busyRescan.isEnabled)
    }

    @MainActor
    func testScanStoreBlocksOneClickUpdatesWhileScanningUpdates() {
        let store = ScanStore()
        store.appUpdates = [makeAppUpdateItem(name: "Brew", method: .homebrew, caskToken: "brew-app")]

        XCTAssertTrue(store.canRequestOneClickAppUpdates)
        XCTAssertTrue(store.canRefreshAppUpdates)
        XCTAssertTrue(store.canRunAutomaticAppUpdateRecheck)

        store.isLoadingAppUpdates = true
        XCTAssertFalse(store.canRequestOneClickAppUpdates)
        XCTAssertFalse(store.canRefreshAppUpdates)
        XCTAssertFalse(store.canRunAutomaticAppUpdateRecheck)
        store.previewOneClickAppUpdates()
        XCTAssertNil(store.pendingOneClickUpdatePlan)
        store.requestOneClickAppUpdates()
        XCTAssertFalse(store.isRunningOneClickUpdate)

        store.isLoadingAppUpdates = false
        store.pendingOneClickUpdatePlan = AppUpdateService.oneClickPlan(for: store.appUpdates)
        store.isRunningOneClickUpdate = true
        XCTAssertFalse(store.canRequestOneClickAppUpdates)
        XCTAssertFalse(store.canRefreshAppUpdates)
        XCTAssertFalse(store.canRunAutomaticAppUpdateRecheck)
        store.refreshAppUpdates()
        XCTAssertFalse(store.isLoadingAppUpdates)
        store.confirmOneClickAppUpdates()
        XCTAssertNotNil(store.pendingOneClickUpdatePlan)
    }

    @MainActor
    func testScanStoreDefersAutomaticAppUpdateRecheckDuringPendingBatch() {
        let store = ScanStore()
        let app = makeAppUpdateItem(name: "Manual Review", method: .manual, latestVersion: "2.0")
        store.appUpdates = [app]

        XCTAssertTrue(store.canRunAutomaticAppUpdateRecheck)

        store.pendingOneClickUpdatePlan = AppUpdateService.oneClickPlan(for: [app])
        XCTAssertFalse(store.canRunAutomaticAppUpdateRecheck)

        store.pendingOneClickUpdatePlan = nil
        XCTAssertTrue(store.canRunAutomaticAppUpdateRecheck)
    }

    @MainActor
    func testScanStoreBlocksAppUpdateListChangesDuringScanOrOneClickUpdate() {
        AppUpdateIgnoreService.clear()
        defer { AppUpdateIgnoreService.clear() }

        let store = ScanStore()
        let app = makeAppUpdateItem(name: "Blocked Update", method: .manual, latestVersion: "9.9.9")
        store.appUpdates = [app]
        store.ignoredAppUpdateCount = 1

        XCTAssertTrue(store.canModifyAppUpdateList)
        XCTAssertTrue(store.canIgnoreAppUpdate(app))
        XCTAssertTrue(store.canClearIgnoredAppUpdates)

        store.isLoadingAppUpdates = true

        XCTAssertFalse(store.canModifyAppUpdateList)
        XCTAssertFalse(store.canIgnoreAppUpdate(app))
        XCTAssertFalse(store.canClearIgnoredAppUpdates)

        store.ignoreAppUpdate(app)
        XCTAssertEqual(store.appUpdates.map(\.id), [app.id])
        XCTAssertFalse(AppUpdateIgnoreService.isIgnored(app))

        store.clearIgnoredAppUpdates()
        XCTAssertEqual(store.ignoredAppUpdateCount, 1)

        store.isLoadingAppUpdates = false
        store.isRunningOneClickUpdate = true

        XCTAssertFalse(store.canModifyAppUpdateList)
        XCTAssertFalse(store.canIgnoreAppUpdate(app))
        XCTAssertFalse(store.canClearIgnoredAppUpdates)
    }

    @MainActor
    func testScanStoreBlocksHistoryClearingDuringActiveWork() {
        let store = ScanStore()
        let scanEntry = ScanHistoryEntry(
            date: Date(),
            scanSeconds: 1,
            score: 90,
            diskUsedBytes: 1_000,
            diskFreeBytes: 500,
            greenBytes: 100,
            yellowBytes: 200,
            redBytes: 300,
            itemCount: 3,
            greenCount: 1,
            yellowCount: 1,
            redCount: 1,
            deniedCount: 0
        )
        let cleanupEntry = CleanupHistoryEntry(
            title: "Cleaned Cache",
            itemCount: 1,
            totalBytes: 100,
            paths: ["/tmp/cache"]
        )
        store.scanHistorySummary = ScanHistorySummary(entries: [scanEntry])
        store.cleanupHistorySummary = CleanupHistorySummary(entries: [cleanupEntry])

        XCTAssertTrue(store.canClearScanHistory)
        XCTAssertTrue(store.canClearCleanupHistory)

        store.isScanning = true

        XCTAssertFalse(store.canClearScanHistory)
        store.clearScanHistory()
        XCTAssertEqual(store.scanHistorySummary.entries, [scanEntry])

        store.isScanning = false
        store.isEmptyingTrash = true

        XCTAssertFalse(store.canClearCleanupHistory)
        store.clearCleanupHistory()
        XCTAssertEqual(store.cleanupHistorySummary.entries, [cleanupEntry])
    }

    @MainActor
    func testHeavyWorkConfirmationSurfacesDoNotAcquireLease() async throws {
        let coordinator = HeavyWorkCoordinator()
        let store = ScanStore(
            heavyWorkCoordinator: coordinator,
            cleanupFeatureConfiguration: .legacy
        )
        let cache = makeStorageItem(
            sourceID: "caches",
            title: "Build Cache",
            tier: .green
        )
        store.result = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: [cache],
            deniedPaths: []
        )
        store.appUpdates = [
            makeAppUpdateItem(
                name: "Brew",
                method: .homebrew,
                caskToken: "brew-app"
            )
        ]

        store.requestTrash(cache)
        store.requestTrashAllGreen()
        store.pendingEmptyTrashSummary = TrashSummary(itemCount: 1, totalBytes: 42)
        store.previewOneClickAppUpdates()

        let activeOwner = await coordinator.activeOwner
        XCTAssertNil(activeOwner)
        XCTAssertNotNil(store.pendingTrashItem)
        XCTAssertFalse(store.pendingBulkTrashItems.isEmpty)
        XCTAssertNotNil(store.pendingEmptyTrashSummary)
        XCTAssertNotNil(store.pendingOneClickUpdatePlan)
    }

    @MainActor
    func testHeavyWorkCoordinatorBlocksStoreOperationOwnedByBenchmark() async throws {
        let coordinator = HeavyWorkCoordinator()
        let benchmarkLease = try await coordinator.acquire(owner: .benchmark)
        let store = ScanStore(heavyWorkCoordinator: coordinator)

        store.scanDuplicateFiles()
        for _ in 0..<2_000 where store.isScanningDuplicates {
            await Task.yield()
        }

        let activeOwner = await coordinator.activeOwner
        XCTAssertEqual(activeOwner, .benchmark)
        XCTAssertFalse(store.isScanningDuplicates)
        XCTAssertEqual(store.heavyWorkActivityStore.activeOwner, .benchmark)
        XCTAssertNotNil(store.heavyWorkActivityStore.conflictMessage)
        XCTAssertNotNil(store.actionMessage)

        await coordinator.release(benchmarkLease)
    }

    @MainActor
    func testRepeatedActionMessageKeepsTheLatestVisibilityWindow() async throws {
        let store = ScanStore()

        store.copyInstalledAppList([])
        let message = try XCTUnwrap(store.actionMessage)
        try await Task.sleep(for: .milliseconds(2_100))

        store.copyInstalledAppList([])
        XCTAssertEqual(store.actionMessage, message)
        try await Task.sleep(for: .milliseconds(550))

        XCTAssertEqual(
            store.actionMessage,
            message,
            "A previous dismissal task must not clear a newly repeated message."
        )
    }

    func testScanExclusionsNormalizeDedupeAndMatchChildren() throws {
        let defaults = try makeTemporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        ScanExclusionService.add("~/Downloads", defaults: defaults)
        ScanExclusionService.add("\(NSHomeDirectory())/Downloads", defaults: defaults)

        let paths = ScanExclusionService.excludedPaths(defaults: defaults)
        XCTAssertEqual(paths, [PathSafety.normalizedPath("~/Downloads")])
        XCTAssertTrue(ScanExclusionService.isExcluded("~/Downloads/example.dmg", excludedPaths: paths))
        XCTAssertFalse(ScanExclusionService.isExcluded("~/Desktop/example.dmg", excludedPaths: paths))
    }

    func testScanExclusionsRejectSystemRoot() throws {
        let defaults = try makeTemporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        ScanExclusionService.add("/", defaults: defaults)

        XCTAssertEqual(ScanExclusionService.excludedPaths(defaults: defaults), [])
    }

    func testScanExclusionsReportAddOutcomeAndDisplayName() throws {
        let defaults = try makeTemporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        XCTAssertTrue(ScanExclusionService.add("~/Downloads", defaults: defaults))
        XCTAssertFalse(ScanExclusionService.add("\(NSHomeDirectory())/Downloads", defaults: defaults))
        XCTAssertFalse(ScanExclusionService.add("/", defaults: defaults))

        XCTAssertTrue(ScanExclusionService.canExclude("~/Desktop"))
        XCTAssertTrue(ScanExclusionService.canExclude("/Applications/Example.app"))
        XCTAssertFalse(ScanExclusionService.canExclude("/System"))
        XCTAssertEqual(ScanExclusionService.displayName(for: "/Applications/Example.app"), "Example.app")
    }

    func testScanExclusionsRemoveAndClearPersistedPaths() throws {
        let defaults = try makeTemporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        ScanExclusionService.add("~/Downloads", defaults: defaults)
        ScanExclusionService.add("~/Desktop", defaults: defaults)
        ScanExclusionService.remove("~/Downloads", defaults: defaults)

        XCTAssertEqual(ScanExclusionService.excludedPaths(defaults: defaults), [PathSafety.normalizedPath("~/Desktop")])

        ScanExclusionService.clear(defaults: defaults)

        XCTAssertEqual(ScanExclusionService.excludedPaths(defaults: defaults), [])
    }

    func testScanExclusionMarkdownIncludesBoundaryAndAllowedPaths() {
        let downloads = PathSafety.normalizedPath("~/Downloads")
        let markdown = ScanExclusionService.markdown(
            for: [
                "~/Downloads",
                downloads,
                "/Applications/Example.app",
                "/System"
            ],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(markdown.contains("安全边界") || markdown.contains("Safety boundary"))
        XCTAssertTrue(markdown.contains(downloads))
        XCTAssertTrue(markdown.contains("/Applications/Example.app"))
        XCTAssertFalse(markdown.contains("/System"))
        XCTAssertEqual(markdown.components(separatedBy: downloads).count - 1, 1)
    }

    func testScanCoverageSummaryClassifiesPermissionState() {
        let complete = ScanCoverageService.summary(deniedPaths: [])
        XCTAssertEqual(complete.level, .complete)
        XCTAssertEqual(complete.estimatedCoveragePercent, 100)

        let partial = ScanCoverageService.summary(deniedPaths: ["~/Downloads"])
        XCTAssertEqual(partial.level, .partial)
        XCTAssertEqual(partial.deniedCount, 1)
        XCTAssertEqual(partial.highImpactDeniedCount, 1)
        XCTAssertEqual(partial.estimatedCoveragePercent, 85)
        XCTAssertEqual(partial.scorePenalty, 6)

        let limited = ScanCoverageService.summary(
            deniedPaths: ["~/Downloads", "~/Desktop", "~/Documents"],
            previewLimit: 2
        )
        XCTAssertEqual(limited.level, .limited)
        XCTAssertEqual(limited.previewPaths, ["~/Desktop", "~/Documents"])
        XCTAssertEqual(limited.hiddenDeniedCount, 1)
        XCTAssertEqual(limited.highImpactDeniedCount, 3)
        XCTAssertEqual(limited.estimatedCoveragePercent, 55)
        XCTAssertEqual(limited.scorePenalty, 8)
    }

    func testScanCoverageDeduplicatesNormalizedPathsBeforeScoring() {
        let summary = ScanCoverageService.summary(
            deniedPaths: [
                "~/Downloads",
                "~/downloads",
                PathSafety.normalizedPath("~/Downloads")
            ]
        )

        XCTAssertEqual(summary.deniedCount, 1)
        XCTAssertEqual(summary.highImpactDeniedCount, 1)
        XCTAssertEqual(summary.level, .partial)
        XCTAssertEqual(summary.scorePenalty, 6)
    }

    func testScanCoverageCapsLowImpactAndHighImpactPermissionPenalties() {
        XCTAssertEqual(ScanCoverageService.scorePenalty(deniedCount: 0), 0)
        XCTAssertEqual(ScanCoverageService.scorePenalty(deniedCount: 1), 2)
        XCTAssertEqual(ScanCoverageService.scorePenalty(deniedCount: 2), 3)
        XCTAssertEqual(ScanCoverageService.scorePenalty(deniedCount: 3), 4)
        XCTAssertEqual(ScanCoverageService.scorePenalty(deniedCount: 30), 4)

        let manyHighImpact = ScanCoverageService.summary(
            deniedPaths: [
                "~/Downloads",
                "~/Desktop",
                "~/Documents",
                "~/Pictures",
                "~/Library/Mail",
                "~/Library/Mobile Documents"
            ]
        )
        XCTAssertEqual(manyHighImpact.scorePenalty, 10)
    }

    func testDuplicateFileScannerFindsSameNameAndSizeCandidates() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstFolder = root.appendingPathComponent("first", isDirectory: true)
        let secondFolder = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)

        try Data("same payload".utf8).write(to: firstFolder.appendingPathComponent("export.mov"))
        try Data("same payload".utf8).write(to: secondFolder.appendingPathComponent("export.mov"))
        try Data("different".utf8).write(to: root.appendingPathComponent("unique.mov"))

        let entries = DuplicateFileScanner.scan(
            configuration: DuplicateFileScanner.Configuration(
                roots: [root.path],
                excludedPaths: [],
                minimumBytes: 1,
                maxFilesScanned: 100,
                maxResults: 10
            )
        )

        XCTAssertEqual(entries.map(\.name), ["export.mov", "export.mov"])
        XCTAssertTrue(entries.allSatisfy { $0.sizeBytes == Int64("same payload".utf8.count) })
    }

    func testDuplicateFileScannerHonorsImmediateTimeLimit() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("same payload".utf8).write(to: root.appendingPathComponent("export.mov"))

        let entries = DuplicateFileScanner.scan(
            configuration: DuplicateFileScanner.Configuration(
                roots: [root.path],
                excludedPaths: [],
                minimumBytes: 1,
                maxFilesScanned: 100,
                maxResults: 10,
                maxScanSeconds: 0
            )
        )

        XCTAssertEqual(entries, [])
    }

    func testDuplicateUserFilesDefaultCoversCommonFoldersWithoutPhotoLibraryRoot() {
        let configuration = DuplicateFileScanner.Configuration.userFiles(excludedPaths: [])

        XCTAssertEqual(Set(configuration.roots), [
            "~/Downloads",
            "~/Desktop",
            "~/Documents",
            "~/Movies",
            "~/Music",
            "~/Pictures",
        ])
        XCTAssertFalse(configuration.roots.contains("~/Pictures/Photos Library.photoslibrary"))
    }

    func testLargeFileScanAvoidsMediaLibraryRootsInStandardMode() {
        let roots = DiskScanner.plannedLargeFileRoots(for: .standard, homePath: "/Users/tester")

        XCTAssertEqual(roots, [
            "/Users/tester/Downloads",
            "/Users/tester/Desktop",
            "/Users/tester/Documents"
        ])
        XCTAssertFalse(roots.contains("/Users/tester/Movies"))
        XCTAssertFalse(roots.contains("/Users/tester/Pictures"))
        XCTAssertFalse(roots.contains("/Users/tester/Music"))
    }

    func testDuplicateEntriesClassifyAsReviewOnlyItems() {
        let entries = [
            DirectoryEntry(name: "export.mov", path: "\(NSHomeDirectory())/Downloads/export.mov", sizeBytes: 1024)
        ]

        let items = DiskScanner.itemsForDuplicateEntries(entries)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.sourceID, "duplicate_files")
        XCTAssertEqual(items.first?.tier, .yellow)
        XCTAssertEqual(items.first?.canMoveToTrash, false)
    }

    func testDuplicateFilterShowsOnlyDuplicateSourceItems() {
        let duplicate = makeStorageItem(sourceID: "duplicate_files", title: "export.mov")
        let largeFile = makeStorageItem(sourceID: "large_files", title: "movie.mov")
        let devCache = makeStorageItem(sourceID: "dev_caches", title: ".build")
        let result = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: [largeFile, duplicate, devCache],
            deniedPaths: []
        )

        XCTAssertEqual(result.items(for: .duplicates), [duplicate])
        XCTAssertEqual(result.items(for: .devCaches), [devCache])
    }

    func testPrivacyTraceClassifierDetectsBrowserAndTraceKind() {
        let safari = makeStorageItem(
            sourceID: "privacy_traces",
            title: "Safari 浏览历史",
            tier: .yellow
        )
        let chromeCache = makeStorageItem(
            sourceID: "browser_caches",
            title: "Chrome Cache",
            tier: .green
        )

        XCTAssertEqual(PrivacyTraceClassifier.surface(for: safari), .safari)
        XCTAssertEqual(PrivacyTraceClassifier.kind(for: safari), .history)
        XCTAssertEqual(PrivacyTraceClassifier.surface(for: chromeCache), .chrome)
        XCTAssertEqual(PrivacyTraceClassifier.kind(for: chromeCache), .cache)
    }

    func testPrivacyTraceSummaryIncludesTracesAndBrowserCaches() {
        let history = makeStorageItem(
            sourceID: "privacy_traces",
            title: "Chrome History",
            tier: .yellow
        )
        let cache = makeStorageItem(
            sourceID: "browser_caches",
            title: "Chrome Cache",
            tier: .green
        )
        let unrelated = makeStorageItem(
            sourceID: "large_files",
            title: "movie.mov",
            tier: .yellow
        )
        let result = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: [history, cache, unrelated],
            deniedPaths: []
        )

        let visibleItems = PrivacyTraceClassifier.visibleItems(in: result)
        let summaries = PrivacyTraceClassifier.summaries(for: visibleItems)

        XCTAssertEqual(visibleItems.map(\.title).sorted(), ["Chrome Cache", "Chrome History"])
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.surface, .chrome)
        XCTAssertEqual(summaries.first?.traceCount, 1)
        XCTAssertEqual(summaries.first?.cacheCount, 1)
    }

    func testDeveloperCacheScanIncludesCodexCachesButSkipsCodexHistory() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/DiskScanner.swift"),
            encoding: .utf8
        )

        let catalogPaths = Set(DeveloperToolArtifactCatalog.definitions.flatMap { definition in
            definition.candidateNames.map { "~/\(definition.rootPath)/\($0)" }
        })
        XCTAssertTrue(catalogPaths.contains("~/.codex/cache"))
        XCTAssertTrue(catalogPaths.contains("~/.codex/plugins/cache"))
        XCTAssertTrue(catalogPaths.contains("~/.codex/tmp"))
        XCTAssertTrue(catalogPaths.contains("~/.codex/logs"))
        let artifactSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/CodexArtifactScanner.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(artifactSource.contains(".codex/.tmp"))
        XCTAssertTrue(artifactSource.contains(".codex/generated_images"))
        XCTAssertTrue(artifactSource.contains(".playwright-mcp"))
        XCTAssertTrue(artifactSource.contains("function-check"))
        XCTAssertTrue(artifactSource.contains("codexTemporaryDirectories"))
        XCTAssertTrue(source.contains("scanDevelopmentIntermediates(deadline: deadline)"))
        XCTAssertTrue(source.contains("\".build\""))
        XCTAssertTrue(source.contains("\".codebase-memory\""))
        XCTAssertTrue(source.contains("\".next\""))
        XCTAssertTrue(source.contains("Gemini CLI、OpenCode、WorkBuddy、Windsurf、Continue、Cline、Roo Code"))
        XCTAssertTrue(catalogPaths.contains("~/.codex/sessions"))
        XCTAssertEqual(
            DeveloperToolArtifactCatalog.definitions.first {
                $0.id == "developer.codex-agent-data"
            }?.policy,
            .referenceOnly
        )
        XCTAssertFalse(catalogPaths.contains("~/.codex/memories"))
        XCTAssertFalse(artifactSource.contains(".codex/sessions"))
        XCTAssertFalse(artifactSource.contains(".codex/memories"))
    }

    func testSmartMaintenancePrioritizesPermissionsAndSafeCleanup() {
        let green = makeStorageItem(sourceID: "caches", title: "Cache", tier: .green)
        let red = makeStorageItem(sourceID: "applications", title: "Xcode", tier: .red)
        let result = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: [green, red],
            deniedPaths: ["\(NSHomeDirectory())/Documents"]
        )

        let tasks = SmartMaintenanceService.tasks(
            result: result,
            appUpdateCount: 2,
            hasScannedAppUpdates: true,
            startupItemCount: 0,
            hasScannedStartupItems: true,
            memorySnapshot: makeMemorySnapshot(reclaimableBytes: 0),
            hasScannedDuplicates: true,
            duplicateCount: 0,
            limit: 3
        )

        XCTAssertEqual(tasks.map(\.id), ["permissions", "clean-green", "review-careful"])
        XCTAssertEqual(tasks.first?.action, .openPermissions)
    }

    func testSmartMaintenanceSuggestsRoutineModuleScans() {
        let result = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: [],
            deniedPaths: []
        )

        let tasks = SmartMaintenanceService.tasks(
            result: result,
            appUpdateCount: 0,
            hasScannedAppUpdates: false,
            startupItemCount: 0,
            hasScannedStartupItems: false,
            memorySnapshot: nil,
            hasScannedDuplicates: false,
            duplicateCount: 0,
            limit: 5
        )

        XCTAssertTrue(tasks.map(\.id).contains("scan-app-updates"))
        XCTAssertTrue(tasks.map(\.id).contains("scan-duplicates"))
        XCTAssertTrue(tasks.map(\.id).contains("refresh-memory"))
        XCTAssertTrue(tasks.map(\.id).contains("scan-startup"))
    }

    func testSmartMaintenanceDefaultDoesNotOmitLowerPriorityTasks() {
        let green = makeStorageItem(sourceID: "caches", title: "Cache", tier: .green)
        let red = makeStorageItem(sourceID: "applications", title: "Xcode", tier: .red)
        let result = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: [green, red],
            deniedPaths: ["\(NSHomeDirectory())/Documents"]
        )

        let tasks = SmartMaintenanceService.tasks(
            result: result,
            appUpdateCount: 2,
            hasScannedAppUpdates: true,
            startupItemCount: 3,
            hasScannedStartupItems: true,
            memorySnapshot: makeMemorySnapshot(reclaimableBytes: 2_000_000_000, pressureFreePercentage: 10),
            hasScannedDuplicates: true,
            duplicateCount: 2
        )

        XCTAssertEqual(tasks.count, 6)
        XCTAssertEqual(
            tasks.map(\.id),
            [
                "permissions",
                "clean-green",
                "review-careful",
                "app-updates",
                "review-duplicates",
                "startup-items"
            ]
        )
    }

    func testSmartMaintenancePlanSeparatesOverviewStartsFromManualReview() {
        let green = makeStorageItem(sourceID: "caches", title: "Cache", tier: .green, sizeBytes: 2_000_000_000)
        let red = makeStorageItem(sourceID: "applications", title: "Xcode", tier: .red, sizeBytes: 3_000_000_000)
        let result = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: [green, red],
            deniedPaths: ["\(NSHomeDirectory())/Documents"]
        )

        let plan = SmartMaintenanceService.plan(
            result: result,
            appUpdateCount: 1,
            hasScannedAppUpdates: true,
            startupItemCount: 2,
            hasScannedStartupItems: true,
            memorySnapshot: makeMemorySnapshot(reclaimableBytes: 1_500_000_000, pressureFreePercentage: 10),
            hasScannedDuplicates: true,
            duplicateCount: 0
        )

        XCTAssertEqual(plan.primaryTask?.id, "permissions")
        XCTAssertEqual(plan.quickStartTasks.map(\.id), ["clean-green"])
        XCTAssertEqual(plan.reviewTasks.map(\.id), ["permissions", "review-careful", "app-updates", "startup-items"])
        XCTAssertEqual(plan.safeCleanupBytes, 2_000_000_000)
        XCTAssertEqual(plan.opportunityBytes, 2_000_000_000)
        XCTAssertEqual(plan.statusPriority, .urgent)
    }

    func testMaintenanceChecklistMarkdownIncludesPlanAndSafetyBoundaries() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let green = makeStorageItem(sourceID: "caches", title: "Build Cache", tier: .green, sizeBytes: 2_000_000_000)
        let red = makeStorageItem(sourceID: "applications", title: "Xcode", tier: .red, sizeBytes: 3_000_000_000)
        let result = ScanResult(
            generatedAt: Date(timeIntervalSince1970: 1_786_000_000),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: [green, red],
            deniedPaths: ["\(NSHomeDirectory())/Documents"]
        )
        let plan = SmartMaintenanceService.plan(
            result: result,
            appUpdateCount: 1,
            hasScannedAppUpdates: true,
            startupItemCount: 2,
            hasScannedStartupItems: true,
            memorySnapshot: makeMemorySnapshot(reclaimableBytes: 1_500_000_000, pressureFreePercentage: 10),
            hasScannedDuplicates: true,
            duplicateCount: 0
        )

        let markdown = MaintenanceChecklistService.markdown(
            for: plan,
            result: result,
            generatedAt: Date(timeIntervalSince1970: 1_786_000_100)
        )

        XCTAssertTrue(markdown.contains("# 存储清理助手今日维护清单"))
        XCTAssertTrue(markdown.contains("## 执行顺序"))
        XCTAssertTrue(markdown.contains("补齐磁盘访问权限"))
        XCTAssertTrue(markdown.contains("预览可安全清理项"))
        XCTAssertTrue(markdown.contains("需要人工确认"))
        XCTAssertTrue(markdown.contains("这份清单只记录建议，不会自动删除任何文件"))
        XCTAssertTrue(markdown.contains("Build Cache"))
    }

    func testMaintenanceChecklistMarkdownExplainsEmptyPlan() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }

        let result = ScanResult(
            generatedAt: Date(timeIntervalSince1970: 1_786_000_000),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: [],
            deniedPaths: []
        )
        let plan = SmartMaintenancePlan(
            tasks: [],
            quickStartTasks: [],
            reviewTasks: [],
            safeCleanupBytes: 0
        )

        let markdown = MaintenanceChecklistService.markdown(
            for: plan,
            result: result,
            generatedAt: Date(timeIntervalSince1970: 1_786_000_100)
        )

        XCTAssertTrue(markdown.contains("| - | 暂无待处理项目 | - | 无需操作 | 当前扫描没有发现需要立即处理的维护项。 |"))
        XCTAssertTrue(markdown.contains("没有可从总览直接启动的维护项"))
        XCTAssertTrue(markdown.contains("没有需要人工确认的维护项"))
    }

    func testMaintenanceChecklistExportWritesMarkdownFile() throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let result = ScanResult(
            generatedAt: Date(timeIntervalSince1970: 1_786_000_000),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: [],
            deniedPaths: []
        )
        let plan = SmartMaintenanceService.plan(
            result: result,
            appUpdateCount: 0,
            hasScannedAppUpdates: false,
            startupItemCount: 0,
            hasScannedStartupItems: false,
            memorySnapshot: nil,
            hasScannedDuplicates: false,
            duplicateCount: 0
        )

        let url = try MaintenanceChecklistService.export(
            plan: plan,
            result: result,
            directory: tempDirectory,
            generatedAt: Date(timeIntervalSince1970: 1_786_000_000)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.lastPathComponent.contains("维护清单") || url.lastPathComponent.contains("Maintenance"))
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("Storage Cleaner Maintenance Checklist") || content.contains("存储清理助手今日维护清单"))
    }

    func testScanResultReplacesDuplicateSourceItems() {
        let oldDuplicate = makeStorageItem(sourceID: "duplicate_files", title: "old.mov")
        let largeFile = makeStorageItem(sourceID: "large_files", title: "movie.mov")
        let devCache = makeStorageItem(sourceID: "dev_caches", title: ".build")
        let newDuplicate = makeStorageItem(sourceID: "duplicate_files", title: "new.mov")
        var result = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: [largeFile, devCache, oldDuplicate],
            deniedPaths: []
        )

        result.replaceItems(sourceID: "duplicate_files", with: [newDuplicate])

        XCTAssertEqual(result.items(for: .duplicates), [newDuplicate])
        XCTAssertEqual(result.items(for: .largeFiles), [largeFile])
        XCTAssertEqual(result.items(for: .devCaches), [devCache])
    }

    func testLargeFileClassifierDetectsCommonFileKinds() {
        XCTAssertEqual(LargeFileKind.classify(makeStorageItem(sourceID: "large_files", title: "movie.mov")), .video)
        XCTAssertEqual(LargeFileKind.classify(makeStorageItem(sourceID: "large_files", title: "installer.dmg")), .installer)
        XCTAssertEqual(LargeFileKind.classify(makeStorageItem(sourceID: "large_files", title: "archive.zip")), .archive)
        XCTAssertEqual(LargeFileKind.classify(makeStorageItem(sourceID: "large_files", title: "contract.pdf")), .document)
        XCTAssertEqual(LargeFileKind.classify(makeStorageItem(sourceID: "large_files", title: "Client Project", isDirectory: true)), .folder)
        XCTAssertEqual(LargeFileKind.classify(makeStorageItem(sourceID: "large_files", title: "node_modules", isDirectory: true)), .developer)
        XCTAssertEqual(LargeFileKind.classify(makeStorageItem(sourceID: "mail_attachments", title: "attachment.pdf")), .mailAttachment)
    }

    func testLargeFilePresenterFiltersSearchesAndSorts() {
        let movie = makeStorageItem(sourceID: "large_files", title: "movie.mov", sizeBytes: 3_000)
        let installer = makeStorageItem(sourceID: "downloads", title: "installer.dmg", sizeBytes: 5_000)
        let archive = makeStorageItem(sourceID: "large_files", title: "backup.zip", sizeBytes: 2_000)
        let document = makeStorageItem(sourceID: "large_files", title: "contract.pdf", sizeBytes: 4_000)

        XCTAssertEqual(
            LargeFilePresenter.visibleItems(
                from: [movie, installer, archive, document],
                query: "",
                filter: .installer,
                sortMode: .size
            )
            .map(\.title),
            ["installer.dmg"]
        )

        XCTAssertEqual(
            LargeFilePresenter.visibleItems(
                from: [movie, installer, archive, document],
                query: "contract",
                filter: .all,
                sortMode: .size
            )
            .map(\.title),
            ["contract.pdf"]
        )

        XCTAssertEqual(
            LargeFilePresenter.visibleItems(
                from: [movie, installer, archive, document],
                query: "",
                filter: .all,
                sortMode: .size
            )
            .map(\.title),
            ["installer.dmg", "contract.pdf", "movie.mov", "backup.zip"]
        )
    }

    func testLargeFilePresenterBuildsKindSummaries() {
        let movie = makeStorageItem(sourceID: "large_files", title: "movie.mov", sizeBytes: 3_000)
        let clip = makeStorageItem(sourceID: "large_files", title: "clip.mp4", sizeBytes: 2_000)
        let installer = makeStorageItem(sourceID: "downloads", title: "installer.dmg", sizeBytes: 4_000)

        let summaries = LargeFilePresenter.summaries(for: [movie, clip, installer])

        XCTAssertEqual(summaries.first?.kind, .video)
        XCTAssertEqual(summaries.first?.count, 2)
        XCTAssertEqual(summaries.first?.bytes, 5_000)
        XCTAssertEqual(summaries.last?.kind, .installer)
    }

    func testLargeFilePresenterOnlyOffersFiltersBackedByResults() {
        let movie = makeStorageItem(sourceID: "large_files", title: "movie.mov")
        let installer = makeStorageItem(sourceID: "downloads", title: "installer.dmg")

        XCTAssertEqual(
            LargeFilePresenter.availableFilters(for: [movie, installer]),
            [.all, .video, .installer]
        )
        XCTAssertEqual(LargeFilePresenter.availableFilters(for: []), [.all])
    }

    func testExternalDriveMigrationSeparatesVerifiedCopyFromOriginalRemovalAndNeverOverwrites() throws {
        #if DEBUG || STORAGE_CLEANER_BETA
        XCTAssertEqual(
            DebugExternalMigrationPresentationFixture.scenario(arguments: [
                "StorageCleanerMac", "--debug-migration-confirmation", "copy",
            ]),
            .copy
        )
        XCTAssertNil(DebugExternalMigrationPresentationFixture.scenario(arguments: [
            "StorageCleanerMac", "--debug-migration-confirmation", "unknown",
        ]))
        #endif

        let fileManager = FileManager.default
        let testRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".storage-cleaner-migration-test-\(UUID().uuidString)")
        let sourceDirectory = testRoot.appendingPathComponent("Source", isDirectory: true)
        let volumeURL = testRoot.appendingPathComponent("External", isDirectory: true)
        let trashDirectory = testRoot.appendingPathComponent("Trash", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: volumeURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let sourceURL = sourceDirectory.appendingPathComponent("movie.mov")
        let contents = Data("verified migration".utf8)
        try contents.write(to: sourceURL)
        let item = ExternalMigrationItem(
            id: "file:test",
            title: "movie.mov",
            sourceURL: sourceURL,
            sizeBytes: Int64(contents.count),
            kind: .file,
            bundleIdentifier: ""
        )
        let volume = ExternalStorageVolume(
            url: volumeURL,
            name: "External",
            availableBytes: 1_000_000,
            totalBytes: 2_000_000,
            fileSystem: "APFS",
            supportsApplications: true
        )

        let result = try ExternalDriveMigrationService.migrate(
            item,
            to: volume,
            fileManager: fileManager,
            trustedVolumes: [volume]
        )

        let destination = volumeURL
            .appendingPathComponent("StorageCleaner Migration/Large Files/movie.mov")
        XCTAssertEqual(result.destinationURL, destination)
        XCTAssertFalse(result.didMoveSourceToTrash)
        XCTAssertEqual(try Data(contentsOf: destination), contents)
        XCTAssertTrue(fileManager.fileExists(atPath: sourceURL.path))

        let removal = try ExternalDriveMigrationService.moveOriginalToTrash(
            item,
            verifiedCopyAt: destination,
            on: volume,
            fileManager: fileManager,
            trustedVolumes: [volume]
        ) { source in
            try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            let trashed = trashDirectory.appendingPathComponent(source.lastPathComponent)
            try fileManager.moveItem(at: source, to: trashed)
            return trashed
        }

        XCTAssertEqual(removal.destinationURL, destination)
        XCTAssertTrue(removal.didMoveSourceToTrash)
        XCTAssertEqual(try Data(contentsOf: destination), contents)
        XCTAssertFalse(fileManager.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: trashDirectory.appendingPathComponent("movie.mov").path))

        try Data("do not overwrite!!".utf8).write(to: sourceURL)
        XCTAssertThrowsError(
            try ExternalDriveMigrationService.migrate(
                item,
                to: volume,
                fileManager: fileManager,
                trustedVolumes: [volume]
            )
        ) { error in
            XCTAssertEqual(error as? ExternalDriveMigrationError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), contents)

        let changedSourceURL = sourceDirectory.appendingPathComponent("changed-after-scan.mov")
        try Data("changed contents".utf8).write(to: changedSourceURL)
        let staleItem = ExternalMigrationItem(
            id: "file:stale",
            title: changedSourceURL.lastPathComponent,
            sourceURL: changedSourceURL,
            sizeBytes: 4,
            kind: .file,
            bundleIdentifier: ""
        )
        XCTAssertThrowsError(
            try ExternalDriveMigrationService.migrate(
                staleItem,
                to: volume,
                fileManager: fileManager,
                trustedVolumes: [volume]
            )
        ) { error in
            XCTAssertEqual(error as? ExternalDriveMigrationError, .sourceChanged)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: changedSourceURL.path))
        XCTAssertFalse(fileManager.fileExists(
            atPath: volumeURL
                .appendingPathComponent("StorageCleaner Migration/Large Files/changed-after-scan.mov")
                .path
        ))

        let retainedSourceURL = sourceDirectory.appendingPathComponent("archive.zip")
        let retainedContents = Data("verified copy with retained source".utf8)
        try retainedContents.write(to: retainedSourceURL)
        let retainedItem = ExternalMigrationItem(
            id: "file:retained",
            title: "archive.zip",
            sourceURL: retainedSourceURL,
            sizeBytes: Int64(retainedContents.count),
            kind: .file,
            bundleIdentifier: ""
        )
        let retainedResult = try ExternalDriveMigrationService.migrate(
            retainedItem,
            to: volume,
            fileManager: fileManager,
            trustedVolumes: [volume]
        )
        let retainedDestination = volumeURL
            .appendingPathComponent("StorageCleaner Migration/Large Files/archive.zip")
        XCTAssertFalse(retainedResult.didMoveSourceToTrash)
        XCTAssertTrue(fileManager.fileExists(atPath: retainedSourceURL.path))
        XCTAssertEqual(try Data(contentsOf: retainedDestination), retainedContents)

        XCTAssertThrowsError(
            try ExternalDriveMigrationService.moveOriginalToTrash(
                retainedItem,
                verifiedCopyAt: retainedDestination,
                on: volume,
                fileManager: fileManager,
                trustedVolumes: [volume],
                trashOperation: { _ in throw CocoaError(.fileWriteNoPermission) }
            )
        ) { error in
            XCTAssertEqual(error as? ExternalDriveMigrationError, .originalRemovalFailed)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: retainedSourceURL.path))
        XCTAssertEqual(try Data(contentsOf: retainedDestination), retainedContents)

        try Data(repeating: 0x58, count: retainedContents.count).write(to: retainedDestination)
        XCTAssertThrowsError(
            try ExternalDriveMigrationService.moveOriginalToTrash(
                retainedItem,
                verifiedCopyAt: retainedDestination,
                on: volume,
                fileManager: fileManager,
                trustedVolumes: [volume],
                trashOperation: { _ in nil }
            )
        ) { error in
            XCTAssertEqual(error as? ExternalDriveMigrationError, .copyVerificationFailed)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: retainedSourceURL.path))

        let sameSizeDifferentBytes = sourceDirectory.appendingPathComponent("same-size.bin")
        try Data("verified migratioN".utf8).write(to: sameSizeDifferentBytes)
        XCTAssertFalse(
            try ExternalDriveMigrationService.filesHaveSameSHA256(
                destination,
                sameSizeDifferentBytes
            )
        )
        XCTAssertTrue(
            try ExternalDriveMigrationService.filesHaveSameSHA256(
                destination,
                destination
            )
        )
    }

    func testItemListPresenterFiltersSearchesAndSortsResultItems() {
        let cache = makeStorageItem(sourceID: "caches", title: "Build Cache", tier: .green, sizeBytes: 1_000, kind: "缓存")
        let review = makeStorageItem(sourceID: "mail_attachments", title: "Mail Attachment", tier: .yellow, sizeBytes: 5_000, kind: "邮件附件")
        let careful = makeStorageItem(sourceID: "applications", title: "Xcode", tier: .red, sizeBytes: 3_000, kind: "应用")

        XCTAssertEqual(
            ItemListPresenter.visibleItems(
                from: [review, careful, cache],
                query: "",
                scopeFilter: .cleanable,
                sortMode: .sizeDescending
            )
            .map(\.title),
            ["Build Cache"]
        )

        XCTAssertEqual(
            ItemListPresenter.visibleItems(
                from: [review, careful, cache],
                query: "邮件",
                scopeFilter: .all,
                sortMode: .sizeDescending
            )
            .map(\.title),
            ["Mail Attachment"]
        )

        XCTAssertEqual(
            ItemListPresenter.visibleItems(
                from: [review, careful, cache],
                query: "",
                scopeFilter: .all,
                sortMode: .safety
            )
            .map(\.title),
            ["Build Cache", "Mail Attachment", "Xcode"]
        )
    }

    func testItemListPresenterMetricsUseRawAndVisibleItemsSeparately() {
        let cache = makeStorageItem(sourceID: "caches", title: "Build Cache", tier: .green, sizeBytes: 1_000)
        let review = makeStorageItem(sourceID: "downloads", title: "Archive", tier: .yellow, sizeBytes: 5_000)
        let careful = makeStorageItem(sourceID: "applications", title: "Xcode", tier: .red, sizeBytes: 3_000)
        let visibleItems = [cache, review]

        let metrics = ItemListPresenter.metrics(rawItems: [cache, review, careful], visibleItems: visibleItems)

        XCTAssertEqual(metrics.rawCount, 3)
        XCTAssertEqual(metrics.visibleCount, 2)
        XCTAssertEqual(metrics.visibleBytes, 6_000)
        XCTAssertEqual(metrics.cleanableCount, 1)
        XCTAssertEqual(metrics.reviewCount, 1)
        XCTAssertEqual(metrics.carefulCount, 1)
    }

    func testItemListPresenterOnlyOffersScopesBackedByResults() {
        let cache = makeStorageItem(sourceID: "caches", title: "Build Cache", tier: .green)
        let review = makeStorageItem(sourceID: "downloads", title: "Archive", tier: .yellow)
        let careful = makeStorageItem(sourceID: "applications", title: "Xcode", tier: .red)

        XCTAssertEqual(
            ItemListPresenter.availableScopes(for: [cache, review, careful]),
            [.all, .cleanable, .needsReview, .careful]
        )
        XCTAssertEqual(ItemListPresenter.availableScopes(for: []), [.all])
    }

    private var defaultsSuiteName: String {
        "StorageCleanerMacTests.ScanExclusions"
    }

    private func makeTemporaryDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeTestApplication(
        at appURL: URL,
        bundleIdentifier: String,
        version: String,
        build: String
    ) throws {
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": appURL.deletingPathExtension().lastPathComponent,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    }

    private func makeStorageItem(
        sourceID: String,
        title: String,
        tier: StorageTier? = nil,
        path: String? = nil,
        sizeBytes: Int64 = 1024,
        kind: String = "Test",
        isDirectory: Bool = false
    ) -> StorageItem {
        let path = path ?? "\(NSHomeDirectory())/Downloads/\(title)"
        let resolvedTier = tier ?? (sourceID == "duplicate_files" ? .yellow : .green)
        return StorageItem(
            id: "\(sourceID)-\(title)",
            title: title,
            path: path,
            sourceID: sourceID,
            groupTitle: "Test",
            sizeBytes: sizeBytes,
            tier: resolvedTier,
            kind: kind,
            reason: "Test",
            recommendation: "Test",
            risk: "Test",
            requiresClose: "None",
            trashPaths: resolvedTier == .green ? [path] : [],
            openPath: path,
            isDirectory: isDirectory,
            status: .available
        )
    }

    private func makeInstalledApp(
        name: String,
        bundleIdentifier: String? = nil,
        developerName: String = "",
        appIntroduction: String? = nil,
        appDescription: String? = nil,
        sizeBytes: Int64 = 1_000,
        relatedBytes: Int64 = 0,
        modifiedAt: Date? = nil,
        lastUsedAt: Date? = nil
    ) -> InstalledAppItem {
        let bundleID = bundleIdentifier ?? "com.example.\(name.lowercased())"
        let relatedItems = relatedBytes > 0
            ? [InstalledAppRelatedItem(path: "/tmp/\(name)-cache", sizeBytes: relatedBytes)]
            : []

        return InstalledAppItem(
            id: "/Applications/\(name).app",
            name: name,
            bundleIdentifier: bundleID,
            path: "/Applications/\(name).app",
            version: "1.0",
            build: "1",
            category: "工具",
            appDescription: appDescription ?? "\(name) 是一款测试应用。",
            appIntroduction: appIntroduction ?? "\(name) 是一款测试应用。",
            developerName: developerName,
            sizeBytes: sizeBytes,
            source: "Applications",
            modifiedAt: modifiedAt,
            lastUsedAt: lastUsedAt,
            relatedPaths: relatedItems.map(\.path),
            relatedItems: relatedItems,
            status: .installed
        )
    }

    private func makeAppUpdateItem(
        name: String,
        method: AppUpdateMethod,
        caskToken: String? = nil,
        latestVersion: String = "1.1"
    ) -> AppUpdateItem {
        let appName = name.replacingOccurrences(of: " ", with: "-").lowercased()
        var item = AppUpdateItem(
            id: "/Applications/\(name).app",
            name: name,
            bundleIdentifier: "com.example.\(appName)",
            path: "/Applications/\(name).app",
            version: "1.0",
            build: "1",
            source: "Test",
            method: method,
            feedURL: method == .sparkle ? "https://example.com/appcast.xml" : nil,
            caskToken: caskToken,
            currentVersion: "1.0",
            latestVersion: latestVersion,
            modifiedAt: nil
        )
        if method == .homebrew, let caskToken {
            item.signingTeamIdentifier = "TESTTEAM"
            item.codeSigningIdentifier = item.bundleIdentifier
            item.sourceEvidence = [
                "homebrew-match:exact-artifact-path",
                "valid-code-signature",
            ]
            item.homebrewMetadata = HomebrewPackageMetadata(
                token: caskToken,
                kind: .cask,
                homepageURL: URL(string: "https://example.com/\(appName)"),
                installedVersions: ["1.0"],
                currentVersion: latestVersion,
                isOutdated: true,
                outdatedProvenance: .plain,
                isPinned: false,
                isDisabled: false,
                isDeprecated: false,
                autoUpdates: false,
                requiresManualInstaller: false,
                appBundlePaths: [item.path]
            )
            item.updateStatus = .automaticallyUpdatable
            item.canAutomaticallyUpdate = true
        }
        return item
    }

    private func makeSnapshot() -> SystemSnapshot {
        SystemSnapshot(
            osName: "macOS",
            build: "test",
            arch: "arm64",
            user: "tester",
            home: PathSafety.homePath,
            filesystem: "APFS",
            purgeable: "",
            diskName: "Macintosh HD",
            diskTotalBytes: 1000,
            diskUsedBytes: 500,
            diskFreeBytes: 500
        )
    }

    private func makeMemorySnapshot(
        reclaimableBytes: Int64,
        pressureFreePercentage: Int? = 80,
        compressedBytes: Int64 = 1_000_000_000,
        swapUsedBytes: Int64 = 0,
        measurements: MemoryMeasurements? = nil
    ) -> MemorySnapshot {
        MemorySnapshot(
            generatedAt: Date(),
            physicalBytes: 16_000_000_000,
            freeBytes: 1_000_000_000,
            inactiveBytes: 0,
            speculativeBytes: 0,
            fileBackedBytes: reclaimableBytes,
            purgeableBytes: 0,
            wiredBytes: 1_000_000_000,
            compressedBytes: compressedBytes,
            swapUsedBytes: swapUsedBytes,
            pressureFreePercentage: pressureFreePercentage,
            pressureSummary: "Normal",
            topProcesses: [],
            measurements: measurements
        )
    }

    private func makeLastScanStatus(
        deniedCount: Int,
        referenceOffset: TimeInterval = 60
    ) -> LastScanStatusSummary {
        let date = Date(timeIntervalSince1970: 100)
        let entry = ScanHistoryEntry(
            date: date,
            scanSeconds: 1,
            score: deniedCount == 0 ? 100 : 94,
            diskUsedBytes: 500,
            diskFreeBytes: 500,
            greenBytes: 0,
            yellowBytes: 0,
            redBytes: 0,
            itemCount: 0,
            greenCount: 0,
            yellowCount: 0,
            redCount: 0,
            deniedCount: deniedCount,
            scanMode: .standard,
            permissionPenalty: deniedCount == 0 ? 0 : 6,
            scoreModelVersion: ScanHistoryService.currentScoreModelVersion,
            actionableGreenBytes: 0,
            actionableGreenCount: 0,
            scanWasLimited: false
        )
        return LastScanStatusSummary(
            entry: entry,
            freshness: ScanFreshnessService.summary(
                generatedAt: date,
                referenceDate: date.addingTimeInterval(referenceOffset)
            )
        )
    }
}

private final class ThreadSafeInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }
}
