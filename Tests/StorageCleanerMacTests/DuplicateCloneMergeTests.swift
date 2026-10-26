import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

/// D-FP3 / D-FP4：重复文件合并为 APFS 克隆，以及“建议保留哪份”。
/// 夹具在家目录下的隔离文件夹里（APFS，可以克隆），不碰真实文件。
final class DuplicateCloneMergeTests: XCTestCase {
    // MARK: Keeper suggestion

    func testCopyLikeNamesAreRecognised() {
        for name in ["Report copy.pdf", "Report Copy 2.pdf", "Report 副本.pdf", "Report 副本 2.pdf", "Report (1).pdf",
                     "Report-2.pdf", "Report_3.pdf", "Copy of Report.pdf"] {
            XCTAssertTrue(DuplicateKeeperSuggestion.looksLikeCopy(name), name)
        }
        for name in ["Report.pdf", "2024-10-01.pdf", "IMG_1234.jpg", "copywriting.txt", "v2.zip"] {
            XCTAssertFalse(DuplicateKeeperSuggestion.looksLikeCopy(name), name)
        }
    }

    func testKeeperPrefersOriginalNameRegularPlaceShallowPathAndOldest() {
        let home = "/Users/fixture"
        let created: [String: Date] = [
            "\(home)/Documents/Report.pdf": Date(timeIntervalSince1970: 200),
            "\(home)/Documents/Old/Report.pdf": Date(timeIntervalSince1970: 100),
            "\(home)/Documents/Report copy.pdf": Date(timeIntervalSince1970: 50),
            "\(home)/Downloads/Report.pdf": Date(timeIntervalSince1970: 10),
        ]
        let ranked = DuplicateKeeperSuggestion.rank(Array(created.keys), homePath: home, creation: { created[$0] })
        XCTAssertEqual(ranked.first?.path, "\(home)/Documents/Report.pdf")
        XCTAssertEqual(ranked.first?.reasons, [.originalName, .regularPlace, .shallowest])
        XCTAssertEqual(ranked.last?.path, "\(home)/Documents/Report copy.pdf", "像副本的名字排最后")

        let sameDepth = DuplicateKeeperSuggestion.rank(["\(home)/A/x.txt", "\(home)/B/x.txt"], homePath: home,
                                                        creation: { $0.contains("/B/") ? Date(timeIntervalSince1970: 1) : Date(timeIntervalSince1970: 2) })
        XCTAssertEqual(sameDepth.first?.path, "\(home)/B/x.txt", "其余相同时保留更早创建的")
        XCTAssertEqual(sameDepth.first?.reasons, [.oldest])
    }

    // MARK: Preview

    func testPreviewOffersOnlySafeCopies() throws {
        let fixture = try CloneFixture()
        defer { fixture.remove() }
        let keeper = try fixture.file("Documents/Photo.jpg", bytes: 300_000)
        let ready = try fixture.copy(keeper, to: "Archive/Photo.jpg")
        let executable = try fixture.copy(keeper, to: "Archive/Photo-exec.jpg", mode: 0o755)
        let linked = try fixture.copy(keeper, to: "Archive/Photo-linked.jpg")
        try FileManager.default.linkItem(atPath: linked, toPath: fixture.path("Archive/hardlink.jpg"))
        let recent = try fixture.copy(keeper, to: "Archive/Photo-recent.jpg", age: 0)
        let clone = fixture.path("Archive/Photo-clone.jpg")
        XCTAssertEqual(clonefile(keeper, clone, 0), 0)
        try fixture.age(clone)
        let group = fixture.group([keeper, ready, executable, linked, recent, clone])

        let preview = DuplicateCloneMergeService.preview(groups: [group], keepers: [group.id: keeper],
                                                         environment: fixture.environment())
        let reasons = Dictionary(uniqueKeysWithValues: preview.candidates.map { ($0.path, $0.skip) })
        XCTAssertEqual(reasons[ready], .some(nil))
        XCTAssertEqual(reasons[executable], .executable)
        XCTAssertEqual(reasons[linked], .hardLinked)
        XCTAssertEqual(reasons[recent], .recentlyModified)
        XCTAssertEqual(reasons[clone], .alreadyShared, "已经是克隆的不再合并")
        XCTAssertNil(reasons[keeper], "保留的那份不在候选里")
        XCTAssertEqual(preview.ready.map(\.path), [ready])
        XCTAssertGreaterThan(preview.reclaimableBytes, 200_000)

        let unproven = DuplicateFileGroup(id: "not-a-digest", files: group.files, contentSizeBytes: 300_000,
                                          matchKind: .logicalContentSHA256, estimatedPhysicalReclaimableBytes: nil)
        let refused = DuplicateCloneMergeService.preview(groups: [unproven], environment: fixture.environment())
        XCTAssertTrue(refused.candidates.isEmpty)
        XCTAssertEqual(refused.refusedGroups["not-a-digest"], .contentDiffers, "没有 SHA-256 证据的组不提供")

        var noClones = fixture.environment()
        noClones.volumeSupportsCloning = { _ in false }
        XCTAssertEqual(DuplicateCloneMergeService.preview(groups: [group], keepers: [group.id: keeper], environment: noClones)
            .candidates.first { $0.path == ready }?.skip, .volumeCannotClone)
    }

    // MARK: Merge

    func testMergeKeepsTheCopyLookingTheSameAndMovesOldDataToTheTrash() async throws {
        let fixture = try CloneFixture()
        defer { fixture.remove() }
        let keeper = try fixture.file("Documents/Song.m4a", bytes: 400_000)
        try fixture.setXattr(keeper, "com.example.keeper-only", "k")
        let copy = try fixture.copy(keeper, to: "Music/Song.m4a", mode: 0o640)
        try fixture.setXattr(copy, "com.example.tag", "blue")
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: copy)
        try fixture.age(copy)
        let before = try APFSCloneReplacement.capture(copy)
        let group = fixture.group([keeper, copy])
        let reports = ReportBox()
        let environment = fixture.environment(reports: reports)

        let preview = DuplicateCloneMergeService.preview(groups: [group], keepers: [group.id: keeper], environment: environment)
        let outcome = await DuplicateCloneMergeService.execute(preview, groups: [group], environment: environment)

        XCTAssertEqual(outcome.merged.map(\.path), [copy], outcome.failed.map { $0.note ?? "" }.joined())
        XCTAssertGreaterThan(outcome.reclaimableBytes, 300_000)
        let after = try APFSCloneReplacement.capture(copy)
        XCTAssertNotEqual(after.inode, before.inode, "路径上换成了克隆")
        XCTAssertEqual(after.mode & 0o7777, 0o640)
        XCTAssertEqual(after.xattrs, before.xattrs, "副本自己的扩展属性原样保留，保留那份独有的不带过来")
        XCTAssertTrue(FileMetadataCapture.equal(after.creation, before.creation))
        XCTAssertTrue(FileMetadataCapture.equal(after.modification, before.modification))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copy)), try Data(contentsOf: URL(fileURLWithPath: keeper)))
        guard case .known(let kept) = FileStorageSharing.read(at: URL(fileURLWithPath: keeper)),
              case .known(let merged) = FileStorageSharing.read(at: URL(fileURLWithPath: copy)) else {
            return XCTFail("APFS 应报告共享信息")
        }
        XCTAssertEqual(kept.cloneID, merged.cloneID, "两份现在共用同一份数据")

        let trashed = try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path)
        XCTAssertEqual(trashed.count, 1)
        XCTAssertTrue(trashed[0].contains("Song"), "换下的数据用看得懂的名字进废纸篓")
        let report = try XCTUnwrap(reports.last)
        XCTAssertEqual(report.rulesVersion, DuplicateCloneMergeService.ruleID)
        XCTAssertEqual(report.summary.movedItemCount, 1)
        XCTAssertEqual(report.restoreAuthorizations?.values.first?.allowedRootPath, fixture.path("Music"),
                       "放回时回到原来的文件夹")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.path("Music"))
        XCTAssertEqual(leftovers, ["Song.m4a"], "文件夹里不留临时文件")
    }

    func testCopyChangedAfterThePreviewIsLeftAlone() async throws {
        let fixture = try CloneFixture()
        defer { fixture.remove() }
        let keeper = try fixture.file("Documents/Data.bin", bytes: 200_000)
        let copy = try fixture.copy(keeper, to: "Backup/Data.bin")
        let group = fixture.group([keeper, copy])
        let environment = fixture.environment()
        let preview = DuplicateCloneMergeService.preview(groups: [group], keepers: [group.id: keeper], environment: environment)
        XCTAssertEqual(preview.ready.count, 1)

        // Same size, different bytes, old date: only the content check can tell.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: copy))
        try handle.seek(toOffset: 1_000)
        try handle.write(contentsOf: Data([0xFF, 0xFE, 0xFD]))
        try handle.close()
        try fixture.age(copy)
        let changed = try Data(contentsOf: URL(fileURLWithPath: copy))

        let outcome = await DuplicateCloneMergeService.execute(preview, groups: [group], environment: environment)
        XCTAssertTrue(outcome.merged.isEmpty)
        XCTAssertEqual(outcome.skipped.first?.note, CloneMergeSkipReason.contentDiffers.title)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copy)), changed, "文件保持原样")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    }

    func testCopyOpenInAnAppIsSkipped() async throws {
        let fixture = try CloneFixture()
        defer { fixture.remove() }
        let keeper = try fixture.file("Documents/Doc.pages", bytes: 100_000)
        let copy = try fixture.copy(keeper, to: "Old/Doc.pages")
        let group = fixture.group([keeper, copy])
        var environment = fixture.environment()
        environment.isOpenByAnotherProcess = { _ in true }
        let preview = DuplicateCloneMergeService.preview(groups: [group], keepers: [group.id: keeper], environment: environment)
        let outcome = await DuplicateCloneMergeService.execute(preview, groups: [group], environment: environment)
        XCTAssertTrue(outcome.merged.isEmpty)
        XCTAssertEqual(outcome.skipped.first?.note, CloneMergeSkipReason.inUse.title)
    }

    @MainActor
    func testActionPreviewsThenMergesUnderTheCleanupLease() async throws {
        let fixture = try CloneFixture()
        defer { fixture.remove() }
        let keeper = try fixture.file("Documents/Movie.mov", bytes: 500_000)
        let copy = try fixture.copy(keeper, to: "Desktop/Movie.mov")
        let group = fixture.group([keeper, copy])
        XCTAssertTrue(DuplicateCloneMergeAction.isOffered(for: group))
        let action = DuplicateCloneMergeAction(coordinator: HeavyWorkCoordinator(), environment: fixture.environment())
        action.update(groups: [group])
        action.preparePreview()
        try await waitUntil { action.phase == .ready }
        XCTAssertEqual(action.preview?.ready.first?.keeperPath, keeper, "默认保留建议的那份（不在桌面）")
        action.merge()
        try await waitUntil { action.phase == .finished }
        XCTAssertEqual(action.outcome?.merged.count, 1)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("等待超时"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

struct CloneFixture {
    let base: URL
    var home: URL { base.appendingPathComponent("home", isDirectory: true) }
    var trash: URL { base.appendingPathComponent("Trash", isDirectory: true) }

    init() throws {
        base = TestFileSystem.uniqueOperationRoot("clone-merge")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    func path(_ relative: String) -> String { home.appendingPathComponent(relative).path }

    func file(_ relative: String, bytes: Int) throws -> String {
        let path = path(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try data.write(to: URL(fileURLWithPath: path))
        try age(path)
        return path
    }

    /// An independent copy (not a clone) with its own data.
    func copy(_ source: String, to relative: String, mode: Int = 0o644, age seconds: TimeInterval = 3_600) throws -> String {
        let path = path(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(contentsOf: URL(fileURLWithPath: source)).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        if seconds > 0 { try age(path, by: seconds) }
        return path
    }

    func age(_ path: String, by seconds: TimeInterval = 3_600) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: path)
    }

    func setXattr(_ path: String, _ name: String, _ value: String) throws {
        let data = Data(value.utf8)
        let result = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        guard result == 0 else { throw POSIXError(.EIO) }
    }

    func group(_ paths: [String]) -> DuplicateFileGroup {
        let data = (try? Data(contentsOf: URL(fileURLWithPath: paths[0]))) ?? Data()
        let digest = Data(SHA256.hash(data: data)).base64EncodedString()
        return DuplicateFileGroup(
            id: digest,
            files: paths.map { DirectoryEntry(name: ($0 as NSString).lastPathComponent, path: $0, sizeBytes: Int64(data.count)) },
            contentSizeBytes: Int64(data.count), matchKind: .logicalContentSHA256, relationship: .independent,
            estimatedPhysicalReclaimableBytes: nil)
    }

    func environment(reports: ReportBox = ReportBox()) -> CloneMergeEnvironment {
        var environment = CloneMergeEnvironment()
        environment.homePath = home.path
        environment.isOpenByAnotherProcess = { _ in false }
        let trash = trash
        environment.moveToTrash = { source in
            let target = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: target)
            return target
        }
        environment.persist = { report, _ in reports.append(report) }
        return environment
    }

    func remove() { TestFileSystem.remove(base) }
}
