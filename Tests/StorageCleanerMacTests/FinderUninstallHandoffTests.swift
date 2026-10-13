import Foundation
import XCTest
import UninstallHandoffShared
@testable import StorageCleanerMac

/// D88: the Finder entry only carries candidate `.app` paths, opened with the
/// installed Beta (no URL scheme). Classification rejects anything that is
/// not a normalized local `.app` path.
///
/// 修复轮 1: the URL encode/parse tests were replaced by `request(for:)` /
/// `applicationURLs(for:)` tests with the same order, dedupe, traversal and
/// limit expectations, because the public scheme was removed (D88 修订).
final class FinderUninstallHandoffTests: XCTestCase {
    private func file(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testRequestKeepsOrderDeduplicatesAndSpecialCharacters() throws {
        let paths = ["/Applications/A & B=C+D #1.app", "/Applications/微信.app", "/Users/someone/Applications/x%20y.app"]
        let selection = paths.map(file) + [file("/Applications/微信.app/")]
        let request = FinderUninstallHandoff.request(for: selection)
        XCTAssertEqual(request.paths, paths)
        XCTAssertTrue(request.rejected.isEmpty)
        let urls = FinderUninstallHandoff.applicationURLs(for: selection)
        XCTAssertEqual(urls.map(\.path), paths)
        XCTAssertTrue(urls.allSatisfy { $0.isFileURL && $0.hasDirectoryPath })
    }

    func testSelectionWithoutApplicationsProducesNoCandidates() {
        XCTAssertTrue(FinderUninstallHandoff.applicationURLs(for: [file("/Users/someone/Documents/report.pdf"), file("/Applications")]).isEmpty)
        XCTAssertTrue(FinderUninstallHandoff.applicationURLs(for: [URL(string: "https://example.com/App.app")!]).isEmpty)
        let request = FinderUninstallHandoff.request(for: [file("/Applications/Tool.app"), file("/tmp/readme.txt"),
                                                           URL(string: "https://example.com/App.app")!])
        XCTAssertEqual(request.paths, ["/Applications/Tool.app"])
        XCTAssertEqual(request.rejected.map(\.reason), [.notApplicationBundle, .notFileURL])
    }

    func testOnlyTheInstalledBetaHostsTheMenu() throws {
        let installed = "/Applications/测试版.app/Contents/PlugIns/StorageCleanerFinderExtension.appex"
        XCTAssertEqual(FinderUninstallHandoff.hostApplication(forExtensionAt: URL(fileURLWithPath: installed, isDirectory: true))?.path,
                       "/Applications/测试版.app")
        for other in ["/tmp/storage-cleaner-beta-package/测试版.app/Contents/PlugIns/StorageCleanerFinderExtension.appex",
                      "/tmp/storage-cleaner-beta-dist/测试版.app/Contents/PlugIns/StorageCleanerFinderExtension.appex",
                      "/Applications/测试版.previous.app/Contents/PlugIns/StorageCleanerFinderExtension.appex",
                      "/Applications/.测试版.staging.123.app/Contents/PlugIns/StorageCleanerFinderExtension.appex",
                      "/Users/someone/Applications/测试版.app/Contents/PlugIns/StorageCleanerFinderExtension.appex",
                      "/Users/someone/Library/Caches/StorageCleanerIntegration-x/测试版.app/Contents/PlugIns/StorageCleanerFinderExtension.appex",
                      "/Applications/StorageCleanerMac.app/Contents/PlugIns/StorageCleanerFinderExtension.appex",
                      "/Applications/存储清理助手.app/Contents/PlugIns/StorageCleanerFinderExtension.appex",
                      "/Applications/测试版.app/Contents/MacOS/StorageCleanerFinderExtension.appex",
                      "/Applications/测试版.app/Contents/PlugIns/../PlugIns/StorageCleanerFinderExtension.appex",
                      "/Applications/X/../测试版.app/Contents/PlugIns/StorageCleanerFinderExtension.appex",
                      "/Applications/测试版.app/Contents/PlugIns/StorageCleanerFinderExtension"] {
            XCTAssertNil(FinderUninstallHandoff.hostApplication(forExtensionAt: URL(fileURLWithPath: other)), other)
        }
        XCTAssertNil(FinderUninstallHandoff.hostApplication(forExtensionAt: try XCTUnwrap(URL(string: "https://example.com" + installed))))
    }

    func testRequestRejectsRelativeTraversalAndNonApplicationPaths() throws {
        let selection = try ["file:///Applications/../Users/x/Evil.app", "file:///Applications/./A.app", "file:////A.app",
                             "file:///Users/x/Documents", "file:///Applications/.app", "file:///Applications/Real.app"]
            .map { try XCTUnwrap(URL(string: $0), $0) }
        let request = FinderUninstallHandoff.request(for: selection)
        XCTAssertEqual(request.paths, ["/Applications/Real.app"])
        XCTAssertEqual(request.rejected.map(\.reason),
                       [.unnormalizedPath, .unnormalizedPath, .unnormalizedPath, .notApplicationBundle, .notApplicationBundle])
        XCTAssertNil(FinderUninstallHandoff.normalizedApplicationPath("Applications/A.app"))
        XCTAssertNil(FinderUninstallHandoff.normalizedApplicationPath("/Applications/A\0.app"))
    }

    func testSelectionIsCappedAndLongPathsAreRejected() {
        let many = (0..<(FinderUninstallHandoff.maximumApplications + 3)).map { file("/Applications/App\($0).app") }
        let request = FinderUninstallHandoff.request(for: many)
        XCTAssertEqual(request.paths.count, FinderUninstallHandoff.maximumApplications)
        XCTAssertEqual(request.rejected.map(\.reason), Array(repeating: .overLimit, count: 3))
        let long = "/" + String(repeating: "a", count: FinderUninstallHandoff.maximumPathLength) + ".app"
        XCTAssertEqual(FinderUninstallHandoff.request(for: [file(long)]).rejected.map(\.reason), [.pathTooLong])
    }
}
