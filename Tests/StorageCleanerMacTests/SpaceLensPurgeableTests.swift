import XCTest
@testable import StorageCleanerMac

/// D193② (the user chose "add a row"): the Space Map lists the space macOS
/// frees by itself apart from the folders, only on the Folders list at the
/// top of a whole disk, unfiltered, and only when the scan measured some.
@MainActor
final class SpaceLensPurgeableTests: XCTestCase {
    private func result(kind: StorageMapScanTarget.Kind, purgeable: Int64) throws -> StorageMapAnalysisResult {
        let index = SpaceMapMemoryIndex.make(rootPath: "/Fixture", children: [
            .directory("Users", [.file("a", 100)]), .file("b", 200)])
        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: index.rootPath, using: index)
        return StorageMapAnalysisResult(target: .init(path: index.rootPath, title: "Fixture", kind: kind),
            volumeTotalBytes: 1_000_000_000_000, volumeAvailableBytes: 300_000_000_000, inspectedItemCount: 2,
            omittedItemCount: 0, scanSeconds: 1, index: index, rootSnapshot: snapshot,
            volumePurgeableBytes: purgeable)
    }

    /// The r35 window run found the row missing: the page asked for
    /// `navigation.isEmpty`, and the store keeps the root in its navigation
    /// at the top. The rule now takes the folder on screen. Was
    /// `bytes(result:surface:atTop:filtered:)` with `atTop: true` / `false`
    /// in each line below; `atTop: false` is now the Users folder.
    func testTheTopOfAWholeDiskListsItsPurgeableSpace() throws {
        let disk = try result(kind: .internalVolume, purgeable: 29_600_000_000)
        let top = disk.rootSnapshot
        let users = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: "/Fixture/Users", using: disk.index)
        XCTAssertEqual(SpaceLensPurgeable.bytes(result: disk, surface: 0, snapshot: top, filtered: false), 29_600_000_000)
        let external = try result(kind: .externalVolume, purgeable: 5_000_000_000)
        XCTAssertEqual(SpaceLensPurgeable.bytes(result: external, surface: 0, snapshot: external.rootSnapshot,
                                                filtered: false), 5_000_000_000)

        XCTAssertNil(SpaceLensPurgeable.bytes(result: disk, surface: 0, snapshot: users, filtered: false), "not inside a folder")
        XCTAssertNil(SpaceLensPurgeable.bytes(result: disk, surface: 1, snapshot: top, filtered: false), "not on File Types")
        XCTAssertNil(SpaceLensPurgeable.bytes(result: disk, surface: 2, snapshot: top, filtered: false), "not on Largest Files")
        XCTAssertNil(SpaceLensPurgeable.bytes(result: disk, surface: 0, snapshot: top, filtered: true), "not in a filtered list")
        let home = try result(kind: .homeDirectory, purgeable: 29_600_000_000)
        XCTAssertNil(SpaceLensPurgeable.bytes(result: home, surface: 0, snapshot: home.rootSnapshot, filtered: false),
                     "a home folder is not the disk")
        let none = try result(kind: .internalVolume, purgeable: 0)
        XCTAssertNil(SpaceLensPurgeable.bytes(result: none, surface: 0, snapshot: none.rootSnapshot, filtered: false),
                     "none measured")
    }

    /// The page's own top, as the store gives it: the root snapshot in the
    /// navigation (`LargeFilesStore.storageMapNavigation = [rootSnapshot]`
    /// after a scan), and a level below it once a folder opens.
    func testThePagesTopIsTheRootTheStoreKeeps() throws {
        let disk = try result(kind: .internalVolume, purgeable: 29_600_000_000)
        let navigation = [disk.rootSnapshot]
        let onScreen = navigation.last ?? disk.rootSnapshot
        XCTAssertNotNil(SpaceLensPurgeable.bytes(result: disk, surface: 0, snapshot: onScreen, filtered: false))
        let users = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: "/Fixture/Users", using: disk.index)
        let opened = (navigation + [users]).last ?? disk.rootSnapshot
        XCTAssertNil(SpaceLensPurgeable.bytes(result: disk, surface: 0, snapshot: opened, filtered: false))
    }

    /// The row says what the space is and that nothing is to be done.
    func testTheRowSaysMacOSManagesIt() {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            XCTAssertEqual(SpaceLensPurgeable.title, language == .zhHans ? "可清除空间" : "Purgeable Space")
            XCTAssertEqual(SpaceLensPurgeable.detail, language == .zhHans
                ? "由 macOS 管理，需要时自动腾出，不用手动清理"
                : "Managed by macOS and freed when needed; nothing to clean by hand")
        }
    }

    /// The 11th test build read the row as part of the /var row above it
    /// ("0 bytes 0.0% Purgeable Space… 126.68 GB", help "/var"): it is one
    /// accessibility element of its own, named and sized, with a fixed
    /// identifier and its own identity in the lazy list. The window test
    /// cannot check this: in the test process a ScrollView's rows are not in
    /// the accessibility tree at all (10-24 window diagnosis, D193A11Y), so
    /// the source is checked here and the installed app is read with LCU.
    func testThePurgeableRowIsOneAccessibilityElementOfItsOwn() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/CareStudio/CareStudioSpaceLens.swift"), encoding: .utf8)
        let row = try XCTUnwrap(source.components(separatedBy: "private func purgeableRow(").dropFirst().first)
        let body = try XCTUnwrap(row.components(separatedBy: "\n    }\n").first)
        for modifier in [".accessibilityElement(children: .ignore)", ".accessibilityLabel(SpaceLensPurgeable.title)",
                         ".accessibilityValue(ByteFormat.storageString(bytes))", ".accessibilityHint(SpaceLensPurgeable.detail)",
                         ".accessibilityIdentifier(\"careStudio.spaceLens.purgeable\")"] {
            XCTAssertTrue(body.contains(modifier), modifier)
        }
        XCTAssertFalse(body.contains(".accessibilityElement(children: .combine)"), "not its texts combined (11th build)")
        XCTAssertTrue(source.contains("purgeableRow(purgeable).id(\"spaceLens.purgeable\")"), "its own identity in the list")
    }

    /// The figure comes from the capacity reading the scan already makes:
    /// the important-usage free space above the plain free space.
    func testThePurgeableFigureIsTheImportantUsageMargin() {
        let capacity = StorageCapacitySnapshot(totalBytes: 1_000, availableBytes: 300, availableForImportantUsageBytes: 330)
        XCTAssertEqual(capacity.reclaimableEstimateBytes, 30)
        XCTAssertEqual(StorageCapacitySnapshot(totalBytes: 1_000, availableBytes: 300).reclaimableEstimateBytes, 0)
    }
}
