import XCTest
@testable import StorageCleanerMac

@MainActor
final class StartupReadD195Tests: XCTestCase {
    func testMissingSystemItemsShowUnknownAndTheDiagnosticInBothLanguages() {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            var coverage = StartupCoverageReport.empty
            coverage.sources = [.init(source: .backgroundTaskDiagnostic, identifier: "fixture", discoveredCount: 0,
                                      errorDescription: "Fixture helper unavailable")]
            let reading = StartupReadPresentation(coverage: coverage)
            XCTAssertFalse(reading.isAvailable)
            XCTAssertEqual(reading.loginTitle(count: 0), language == .zhHans ? "没读到登录项" : "Login Items Not Read")
            XCTAssertFalse(reading.loginTitle(count: 0).contains("你有 0 个登录项"))
            XCTAssertEqual(reading.loginDetail, "Fixture helper unavailable")
            // D217＋旧值：发现至少 2 个后台项目 / At Least 2 Background Items Found。
            XCTAssertEqual(reading.backgroundTitle(count: 2), language == .zhHans
                ? "发现 2 个后台项目" : "2 Background Items Found")
            // D217＋旧值：当前只含用户级项目；系统后台项目尚未读到。
            XCTAssertEqual(reading.backgroundDetail, language == .zhHans
                ? "按用户与共享启动项目录中的文件逐个计数。其他后台组件可在完整清单中查看。"
                : "Counts each file in the user and shared startup directories. Other background components are available in the full list.")
            XCTAssertEqual(StartupReadPresentation(coverage: .empty).unreadReason, language == .zhHans
                ? "需要后台助手或完整扫描才能读到"
                : "The background helper or a full scan is needed to read these items.")
        }
    }

    func testSuccessfulSystemReadKeepsExistingTileCopyIncludingRealZero() {
        var coverage = StartupCoverageReport.empty
        coverage.managedItemCoverageAvailable = true
        let reading = StartupReadPresentation(coverage: coverage)
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            for count in [0, 1, 2] {
                XCTAssertEqual(reading.loginTitle(count: count), language == .zhHans ? "你有 \(count) 个登录项"
                    : count == 1 ? "You Have 1 Login Item" : "You Have \(count) Login Items")
                XCTAssertEqual(reading.backgroundTitle(count: count), language == .zhHans ? "发现 \(count) 个后台项目"
                    : count == 1 ? "1 Background Item Found" : "\(count) Background Items Found")
            }
            XCTAssertEqual(reading.loginDetail, language == .zhHans
                ? "登录 Mac 时会自动打开这些应用。用不到的可以停用，随时能撤销。"
                : "These apps open automatically when you log in. Turn off what you don't need; undo any time.")
            // D217＋旧值：允许在后台运行的代理、帮助程序和服务。都需要吗？
            XCTAssertEqual(reading.backgroundDetail, language == .zhHans
                ? "按用户与共享启动项目录中的文件逐个计数。其他后台组件可在完整清单中查看。"
                : "Counts each file in the user and shared startup directories. Other background components are available in the full list.")
        }
    }

    func testSmartScanMissingLoginReadCannotClaimGoodPerformance() throws {
        let store = try MyActivityD187Fixtures.readOnlyStore(for: self)
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            store.startupCoverage = .empty
            let unknown = SmartCareSummaries.summary(for: .performance, state: .done, store: store, privacy: nil)
            XCTAssertEqual(unknown.headline, language == .zhHans ? "没读到登录项" : "Login Items Not Read")
            XCTAssertFalse(unknown.line.contains("性能良好"))
            XCTAssertTrue(unknown.reviews)
            store.startupCoverage.managedItemCoverageAvailable = true
            let read = SmartCareSummaries.summary(for: .performance, state: .done, store: store, privacy: nil)
            XCTAssertEqual(read.headline, language == .zhHans ? "没有维护任务" : "No tasks")
            XCTAssertEqual(read.subtitle, language == .zhHans ? "不用运行" : "to run")
            XCTAssertFalse(read.reviews)
        }
    }

    func testRecommendationsRequireASuccessfulLoginReadEvenForStaleCounts() {
        var state = MyActivityD187Fixtures.noRecommendations()
        for count in [0, 5, 100] {
            state.loginItemCount = count
            state.managedItemCoverageAvailable = false
            XCTAssertFalse(MyActivityRecommendations.make(state, now: MyActivityD187Fixtures.now)
                .contains { $0.kind == .loginItems })
            state.managedItemCoverageAvailable = true
            XCTAssertEqual(MyActivityRecommendations.make(state, now: MyActivityD187Fixtures.now)
                .contains { $0.kind == .loginItems }, count >= 5)
        }
    }

    func testProductionViewsPassCoverageAndKeepTheReviewAction() throws {
        let root = SwiftSourceScanning.projectRoot.appendingPathComponent("Sources/StorageCleanerMac")
        let utilities = try String(contentsOf: root.appendingPathComponent("Views/SystemUtilitiesView.swift"), encoding: .utf8)
        XCTAssertTrue(utilities.contains("coverage: store.startupCoverage"))
        let startup = try String(contentsOf: root.appendingPathComponent("Views/CareStudio/CareStudioStartup.swift"), encoding: .utf8)
        XCTAssertTrue(startup.contains("StartupReadPresentation(coverage: coverage)"))
        XCTAssertTrue(startup.contains("reviewTitle: L10n.text(\"查看\", \"Review\"), onReview: open(.loginItems)"))
        let activity = try String(contentsOf: root.appendingPathComponent("Views/CareStudio/CareStudioMyActivity.swift"), encoding: .utf8)
        XCTAssertTrue(activity.contains("value.managedItemCoverageAvailable = store.startupCoverage.managedItemCoverageAvailable"))
    }
}
