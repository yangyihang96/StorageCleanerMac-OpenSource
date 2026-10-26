import Foundation
import XCTest
@testable import StorageCleanerMac

/// D225 (D207, D215): Add to Ignore List for apps outside the standard
/// folders — every copy from the app's row, one copy from its own row — by
/// path under Uninstaller, with Put Back. Removal stays bundle-only (D218).
@MainActor
final class ApplicationsManagerD225Tests: XCTestCase {
    private static let home = "/Users/d225-fixture"

    private static func item(_ path: String, identifier: String = "com.example.copy", bytes: Int64 = 100) -> InstalledAppItem {
        InstalledAppItem(id: path, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            bundleIdentifier: identifier, path: path, version: "1.0", build: "1", category: "", appDescription: "",
            sizeBytes: bytes, source: "fixture", modifiedAt: Date(timeIntervalSince1970: 1_000),
            relatedPaths: [home + "/Library/Preferences/\(identifier).plist"], relatedItems: [], status: .installed)
    }

    private func scanner(_ items: [InstalledAppItem]) -> OtherApplicationsScanner {
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })
        return OtherApplicationsScanner(homeDirectory: URL(fileURLWithPath: Self.home),
            query: { SpotlightApplicationScanResult(applicationURLs: items.map { URL(fileURLWithPath: $0.path) }, completion: .completed) },
            containsSymbolicLink: { _ in false }, readApplication: { byPath[$0.path] })
    }

    private func makeList() throws -> IgnoreListStore {
        let home = try TestFileSystem.makeHome(for: self)
        return IgnoreListStore(fileURL: home.appendingPathComponent("IgnoreList.json"), defaults: TestPreferenceDomain.make(for: self))
    }

    private func loadedModel(_ copies: [InstalledAppItem]) async -> ApplicationsManagerModel {
        let model = ApplicationsManagerModel(otherApplicationsScanner: scanner(copies))
        model.load(inventory: [Self.item("/Applications/Installed.app", identifier: "com.example.installed")],
                   readsDisk: false, ignoreList: .empty)
        model.refreshOtherApplications()
        await model.waitForOtherApplications()
        model.category = .otherLocations
        return model
    }

    private func listedPaths(_ model: ApplicationsManagerModel) -> [String] {
        model.otherApplications.groups.flatMap(\.copies).map(\.path)
    }

    func testTheAppsRowTakesEveryCopyAndPutBackReturnsThemSelected() async throws {
        let h = Self.home
        let copies = [Self.item(h + "/Developer/one/Copy.app"), Self.item(h + "/Developer/two/Copy.app"),
                      Self.item(h + "/Desktop/Other.app", identifier: "com.example.other")]
        let model = await loadedModel(copies)
        let list = try makeList()
        let feedback = IgnoreListFeedback { list }
        let group = try XCTUnwrap(model.otherApplications.groups.first { $0.copies.count == 2 })
        model.toggleOtherApplication(copies[0].path)

        model.ignoreOtherApplications(group.copies.map(\.path), feedback: feedback)
        XCTAssertEqual(listedPaths(model), [copies[2].path], "Both copies leave the list at once")
        XCTAssertEqual(model.otherApplications.ignoredCount, 2)
        XCTAssertTrue(model.otherApplicationSelection.isEmpty)
        let entries = list.snapshot().entries
        XCTAssertEqual(Set(entries.map(\.target.path)), Set(group.copies.map { PathSafety.normalizedPath($0.path) }))
        XCTAssertTrue(entries.allSatisfy { $0.category == .uninstaller && $0.target.bundleIdentifier == nil },
                      "By path, under Uninstaller")
        XCTAssertEqual(feedback.note?.text, L10n.text("已把 2 项加入忽略列表", "2 items are on the Ignore List now"))
        XCTAssertEqual(model.entries.map(\.item.path), ["/Applications/Installed.app"], "The installed apps are not touched")

        feedback.putBack()
        XCTAssertEqual(Set(listedPaths(model)), Set(copies.map(\.path)))
        XCTAssertEqual(model.otherApplications.ignoredCount, 0)
        XCTAssertEqual(model.otherApplicationSelection, [copies[0].path], "Put Back returns the copy selected as it was")
        XCTAssertTrue(list.snapshot().entries.isEmpty)
    }

    func testACopysRowTakesThatCopyAloneAndRemovalStaysBundleOnly() async throws {
        let h = Self.home
        let copies = [Self.item(h + "/Desktop/Copy.app"), Self.item(h + "/Documents/Copy.app")]
        let model = await loadedModel(copies)
        let list = try makeList()
        let feedback = IgnoreListFeedback { list }

        model.ignoreOtherApplications([copies[0].path], feedback: feedback)
        XCTAssertEqual(model.otherApplications.groups.count, 1)
        XCTAssertEqual(listedPaths(model), [copies[1].path], "The other copy stays in its row")
        XCTAssertEqual(feedback.note?.text, L10n.text("已把“Copy”加入忽略列表", "“Copy” is on the Ignore List now"))
        XCTAssertEqual(list.snapshot().entries.map(\.target.path), [PathSafety.normalizedPath(copies[0].path)])

        model.toggleOtherApplication(copies[1].path)
        let requests = model.buildRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.application?.path, copies[1].path)
        XCTAssertEqual(requests.first?.purpose, .bundleOnly)
        XCTAssertEqual(requests.first?.resources.isEmpty, true, "D218: no related files")

        // D207: the list keeps the copy out of later scans.
        model.refreshOtherApplications()
        await model.waitForOtherApplications()
        XCTAssertEqual(listedPaths(model), [copies[1].path])
        XCTAssertEqual(model.otherApplications.ignoredCount, 1)
        XCTAssertEqual(model.otherApplicationSelection, [copies[1].path])
    }

    func testCopiesTheListDoesNotHoldAreIgnoredOnlyOnce() async throws {
        let copies = [Self.item(Self.home + "/Desktop/Copy.app")]
        let model = await loadedModel(copies)
        let list = try makeList()
        let feedback = IgnoreListFeedback { list }
        model.ignoreOtherApplications([Self.home + "/Desktop/Elsewhere.app"], feedback: feedback)
        XCTAssertNil(feedback.note, "A path this list does not show adds nothing")
        XCTAssertTrue(list.snapshot().entries.isEmpty)
        model.ignoreOtherApplications([copies[0].path, copies[0].path], feedback: feedback)
        XCTAssertEqual(list.snapshot().entries.count, 1)
        XCTAssertTrue(listedPaths(model).isEmpty)
    }
}
