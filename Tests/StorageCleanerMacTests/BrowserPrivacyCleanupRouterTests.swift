import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class BrowserPrivacyCleanupRouterTests: XCTestCase {
    func testEveryPrivacyKindUsesOnlyBrowserNativeGuidance() {
        let router = BrowserPrivacyCleanupRouter()

        for browser in BrowserKind.allCases {
            let history = router.route(for: .history, browser: browser)
            let downloads = router.route(for: .downloads, browser: browser)
            let siteData = router.route(for: .siteData, browser: browser)
            let cache = router.route(for: .cache, browser: browser)

            XCTAssertEqual(history.action, .openBrowserHistory)
            XCTAssertEqual(downloads.action, .openBrowserDownloads)
            XCTAssertEqual(siteData.action, .openBrowserWebsiteData)
            XCTAssertEqual(cache.action, .openBrowserCacheSettings)
            XCTAssertFalse(history.requiresIndependentConfirmation)
            XCTAssertFalse(downloads.requiresIndependentConfirmation)
            XCTAssertTrue(siteData.requiresIndependentConfirmation)
            XCTAssertTrue(cache.requiresIndependentConfirmation)
        }
    }

    func testNativeRoutesNeverUseNetworkURLs() {
        let router = BrowserPrivacyCleanupRouter()

        for browser in BrowserKind.allCases {
            for kind in allPrivacyKinds {
                let scheme = router.route(for: kind, browser: browser)
                    .destinationURL?.scheme?.lowercased()
                XCTAssertNotEqual(scheme, "http")
                XCTAssertNotEqual(scheme, "https")
            }
        }
    }

    func testSafariRoutesLaunchSafariWithoutPretendingToDeepLink() {
        let router = BrowserPrivacyCleanupRouter()

        for kind in allPrivacyKinds {
            XCTAssertNil(router.route(for: kind, browser: .safari).destinationURL)
        }
        XCTAssertTrue(
            router.route(for: .history, browser: .safari)
                .instruction.contains("Command-Y")
        )
    }

    func testFirefoxHistoryUsesLibraryShortcutInsteadOfInvalidAboutHistoryURL() {
        let route = BrowserPrivacyCleanupRouter().route(for: .history, browser: .firefox)

        XCTAssertNil(route.destinationURL)
        XCTAssertTrue(route.instruction.contains("Command-Shift-H"))
    }

    func testChromiumAndFirefoxDestinationsAreKnownNativeManagementPages() {
        let router = BrowserPrivacyCleanupRouter()

        XCTAssertEqual(
            router.route(for: .history, browser: .chrome).destinationURL?.absoluteString,
            "chrome://history/"
        )
        XCTAssertEqual(
            router.route(for: .cache, browser: .chrome).destinationURL?.absoluteString,
            "chrome://settings/clearBrowserData"
        )
        XCTAssertEqual(
            router.route(for: .history, browser: .edge).destinationURL?.absoluteString,
            "edge://history/all"
        )
        XCTAssertEqual(
            router.route(for: .cache, browser: .edge).destinationURL?.absoluteString,
            "edge://settings/clearBrowserData"
        )
        XCTAssertEqual(
            router.route(for: .cache, browser: .firefox).destinationURL?.absoluteString,
            "about:preferences#privacy"
        )
    }

    func testAllRoutesBindTheExplicitTargetBrowserBundle() {
        let router = BrowserPrivacyCleanupRouter()

        for browser in BrowserKind.allCases {
            for kind in allPrivacyKinds {
                XCTAssertEqual(
                    router.route(for: kind, browser: browser).browserBundleIdentifier,
                    BrowserBundleIdentifiers.primaryIdentifier(for: browser)
                )
            }
        }
    }

    func testInstructionsDoNotClaimAnOpenRequestAlreadyHappened() {
        let router = BrowserPrivacyCleanupRouter()

        for browser in BrowserKind.allCases {
            for kind in allPrivacyKinds {
                let instruction = router.route(for: kind, browser: browser).instruction
                XCTAssertFalse(instruction.contains("已请求"))
                XCTAssertFalse(instruction.localizedCaseInsensitiveContains("was asked"))
                XCTAssertFalse(instruction.localizedCaseInsensitiveContains("request was sent"))
            }
        }
    }

    func testWorkspaceRejectionIsNotReportedAsAnOpenedManagementPage() async {
        let router = BrowserPrivacyCleanupRouter()
        let route = router.route(for: .history, browser: .chrome)
        let launcher = StubBrowserWorkspaceLauncher(
            applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
            accepted: false
        )
        let opener = WorkspaceBrowserNativeManagementOpener(launcher: launcher)

        do {
            try await router.openNativeManagement(route, opener: opener)
            XCTFail("A rejected Launch Services request must not be reported as accepted")
        } catch {
            XCTAssertEqual(error as? BrowserPrivacyCleanupError, .nativeRouteUnavailable)
        }

        XCTAssertEqual(launcher.requestedBundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(launcher.launchedApplicationURL, launcher.applicationURL)
        XCTAssertEqual(launcher.launchedDestinationURL, route.destinationURL)
    }

    func testWorkspaceAcceptanceOnlyMeansTheOpenRequestWasAccepted() async throws {
        let router = BrowserPrivacyCleanupRouter()
        let route = router.route(for: .cache, browser: .edge)
        let launcher = StubBrowserWorkspaceLauncher(
            applicationURL: URL(fileURLWithPath: "/Applications/Microsoft Edge.app"),
            accepted: true
        )

        try await router.openNativeManagement(
            route,
            opener: WorkspaceBrowserNativeManagementOpener(launcher: launcher)
        )

        XCTAssertEqual(launcher.requestedBundleIdentifier, "com.microsoft.edgemac")
        XCTAssertEqual(launcher.launchedDestinationURL, route.destinationURL)
    }

    func testProductionPrivacyRoutingContainsNoDirectBrowserCacheTrashEntry() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = [
            root.appendingPathComponent("Sources/StorageCleanerMac/Services/BrowserPrivacyCleanupRouter.swift"),
            root.appendingPathComponent("Sources/StorageCleanerMac/Services/CleanupService.swift")
        ]
        let forbidden = [
            "moveCacheToTrash",
            "cacheCleanupCandidates",
            "BrowserCacheCleanupCandidate",
            "moveBrowserCacheToTrash",
            ".storage-cleaner-stage-"
        ]

        for sourceURL in sources {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(
                    source.contains(token),
                    "\(sourceURL.lastPathComponent) must not expose direct browser cache trash token \(token)"
                )
            }
        }
    }

    private var allPrivacyKinds: [BrowserPrivacyDataKind] {
        [.history, .downloads, .siteData, .cache]
    }
}

@MainActor
private final class StubBrowserWorkspaceLauncher: BrowserWorkspaceLaunching {
    let applicationURL: URL?
    private let accepted: Bool
    private(set) var requestedBundleIdentifier: String?
    private(set) var launchedApplicationURL: URL?
    private(set) var launchedDestinationURL: URL?

    init(applicationURL: URL?, accepted: Bool) {
        self.applicationURL = applicationURL
        self.accepted = accepted
    }

    func applicationURL(forBundleIdentifier identifier: String) -> URL? {
        requestedBundleIdentifier = identifier
        return applicationURL
    }

    func open(
        applicationURL: URL,
        destinationURL: URL?
    ) async -> Bool {
        launchedApplicationURL = applicationURL
        launchedDestinationURL = destinationURL
        return accepted
    }
}
