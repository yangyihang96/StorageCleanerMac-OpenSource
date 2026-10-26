import Foundation
import XCTest
@testable import StorageCleanerMac

/// D-FP6（竞品对比 2026-10-20）：浏览器隐私加入 QQ 浏览器。路径取自腾讯柠檬
/// （`~/Library/Application Support/QQBrowser2`），走与其他 Chromium 系相同的已验证合同。
final class QQBrowserPrivacyProviderTests: XCTestCase {
    func testQQBrowserIsARegisteredChromiumProvider() throws {
        let provider = try XCTUnwrap(BrowserPrivacyProviderRegistry.defaultProviders.first { $0.descriptor.id == "qq-browser" })
        XCTAssertEqual(provider.descriptor.engine, .chromium)
        XCTAssertEqual(provider.descriptor.bundleIdentifiers, ["com.tencent.QQBrowser"])
        XCTAssertEqual(provider.descriptor.profileRootRelativePaths, ["Library/Application Support/QQBrowser2"])
        XCTAssertEqual(provider.historyWriteAdapter, .chromiumProduction, "只有精确匹配的 Chromium 数据库才写入")
    }

    func testQQBrowserProfilesAreDiscoveredOnlyWhenTheAppIsInstalled() throws {
        let home = TestFileSystem.uniqueRoot("qq-browser-privacy")
        defer { TestFileSystem.remove(home) }
        let profile = home.appendingPathComponent("Library/Application Support/QQBrowser2/Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: profile.appendingPathComponent("History").path, contents: Data()))

        let registry = BrowserPrivacyProviderRegistry()
        XCTAssertNil(registry.discover(homeDirectory: home, installedApplications: [])
            .first { $0.coverage.browser.id == "qq-browser" }, "没装就不列出")
        let installed = BrowserPrivacyInstalledApplication(
            bundleIdentifier: "com.tencent.QQBrowser", version: "1.0",
            url: home.appendingPathComponent("Applications/QQBrowser.app"), isDefaultBrowser: false,
            displayName: "QQ浏览器", canOpenWebURLs: true)
        let discovery = try XCTUnwrap(registry.discover(homeDirectory: home, installedApplications: [installed])
            .first { $0.coverage.browser.id == "qq-browser" })
        XCTAssertEqual(discovery.profiles.map(\.id), ["qq-browser:Default"])
    }
}
