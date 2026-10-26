import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

/// D116 G11：iPhone、iPad 备份只读盘点。夹具都在系统临时目录的假家目录里，
/// 不读取真实的 ~/Library/Application Support/MobileSync。
final class MobileDeviceBackupInventoryTests: XCTestCase {
    private let firstDate = Date(timeIntervalSince1970: 1_790_000_000)
    private let manifestDate = Date(timeIntervalSince1970: 1_789_000_000)
    private let tabletDate = Date(timeIntervalSince1970: 1_780_000_000)

    func testBackupsListNameDateVersionEncryptionAndSizeOnly() throws {
        let home = try makeHome()
        let phone = try backupFolder("PHONE-FOLDER", in: home)
        try writePlist(["Date": firstDate, "SnapshotState": "finished", "IsFullBackup": false],
                       to: phone.appendingPathComponent("Status.plist"))
        try writePlist([
            "IsEncrypted": true, "Date": manifestDate,
            "Lockdown": ["DeviceName": "  Test\u{0007} iPhone\n", "ProductVersion": "18.1",
                         "SerialNumber": "SECRET-SERIAL", "UniqueDeviceID": "SECRET-UDID"],
        ], to: phone.appendingPathComponent("Manifest.plist"))
        try writePlist(["Phone Number": "SECRET-PHONE", "IMEI": "SECRET-IMEI", "Device Name": "Other Name"],
                       to: phone.appendingPathComponent("Info.plist"))
        try writeData(64 * 1024, to: phone.appendingPathComponent("00/0011aa"))
        try writeData(16 * 1024, to: phone.appendingPathComponent("ab/ab22bb"))

        let tablet = try backupFolder("TABLET-FOLDER", in: home)
        try writePlist(["Device Name": "Test iPad", "Product Version": "17.6.1", "Last Backup Date": tabletDate,
                        "Serial Number": "SECRET-SERIAL-2"], to: tablet.appendingPathComponent("Info.plist"))
        try writePlist(["SnapshotState": "uploading"], to: tablet.appendingPathComponent("Status.plist"))
        try writeData(8 * 1024, to: tablet.appendingPathComponent("cd/cd33dd"))
        // Not backups: a hidden folder and a stray file at the top.
        try writeData(4 * 1024, to: backupRoot(in: home).appendingPathComponent(".hidden/file"))
        try writeData(4 * 1024, to: backupRoot(in: home).appendingPathComponent("stray.txt"))

        let inventory = MobileDeviceBackupInventoryScanner(homePath: home.path).scan()

        XCTAssertEqual(inventory.rootState, .readable)
        XCTAssertEqual(inventory.backups.map(\.id), ["PHONE-FOLDER", "TABLET-FOLDER"], "Larger first")
        let first = try XCTUnwrap(inventory.backups.first)
        XCTAssertEqual(first.deviceName, "Test iPhone", "Control characters and edge spaces removed")
        XCTAssertEqual(first.systemVersion, "18.1")
        XCTAssertEqual(first.backupDate, firstDate, "Status.plist's date comes first")
        XCTAssertEqual(first.isEncrypted, true)
        XCTAssertFalse(first.isUnfinished)
        XCTAssertEqual(first.fileCount, 5)
        XCTAssertEqual(first.bytes, allocatedTree(phone))
        XCTAssertEqual(first.sharedBytes, 0)
        XCTAssertFalse(first.isIncomplete)
        XCTAssertEqual(first.location, phone.path)

        let second = try XCTUnwrap(inventory.backups.last)
        XCTAssertEqual(second.deviceName, "Test iPad", "Info.plist fills what the others lack")
        XCTAssertEqual(second.systemVersion, "17.6.1")
        XCTAssertEqual(second.backupDate, tabletDate)
        XCTAssertNil(second.isEncrypted)
        XCTAssertTrue(second.isUnfinished)
        XCTAssertEqual(second.bytes, allocatedTree(tablet))

        XCTAssertEqual(inventory.totalBytes, first.bytes + second.bytes)
        XCTAssertFalse(inventory.isIncomplete)
        XCTAssertEqual(inventory.skippedSymbolicLinkCount, 0)
        // Only the shown fields are kept: nothing else from the property lists.
        XCTAssertFalse(String(describing: inventory).contains("SECRET"))

        let date: (Date) -> String = { _ in "DATE" }
        let firstDetail = MobileDeviceBackupPresentation.detail(first, formatDate: date)
        XCTAssertTrue(firstDetail.contains("DATE"))
        XCTAssertTrue(firstDetail.contains("18.1"))
        XCTAssertTrue(firstDetail.contains(L10n.text("已加密", "Encrypted")))
        let secondDetail = MobileDeviceBackupPresentation.detail(second, formatDate: date)
        XCTAssertTrue(secondDetail.contains(L10n.text("上次备份没有完成", "The last backup did not finish")))
        XCTAssertFalse(secondDetail.contains(L10n.text("已加密", "Encrypted")))
        XCTAssertTrue(MobileDeviceBackupPresentation.summary(inventory).contains("2"))
        XCTAssertNil(MobileDeviceBackupPresentation.stateDetail(inventory))
        XCTAssertNil(MobileDeviceBackupPresentation.sharing(first))
        XCTAssertTrue(MobileDeviceBackupPresentation.notices(inventory).isEmpty)
    }

    func testMissingLinkedAndUnreadableFoldersAreReportedWithoutFollowing() throws {
        let empty = try makeHome()
        let none = MobileDeviceBackupInventoryScanner(homePath: empty.path).scan()
        XCTAssertEqual(none.rootState, .absent)
        XCTAssertTrue(none.backups.isEmpty)
        XCTAssertEqual(MobileDeviceBackupPresentation.summary(none),
                       L10n.text("这台 Mac 的默认位置没有 iPhone 或 iPad 备份",
                                 "No iPhone or iPad backups in the default location on this Mac"))

        // The backup folder itself links to another place (for example an external drive): not followed.
        let outside = try makeOutside()
        let linkedHome = try makeHome()
        let mobileSync = linkedHome.appendingPathComponent("Library/Application Support/MobileSync")
        try FileManager.default.createDirectory(at: mobileSync, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: mobileSync.appendingPathComponent("Backup"), withDestinationURL: outside)
        let linked = MobileDeviceBackupInventoryScanner(homePath: linkedHome.path).scan()
        XCTAssertEqual(linked.rootState, .symbolicLink(destination: outside.path))
        XCTAssertTrue(linked.backups.isEmpty)
        XCTAssertEqual(linked.totalBytes, 0)
        XCTAssertTrue(try XCTUnwrap(MobileDeviceBackupPresentation.stateDetail(linked)).hasSuffix(" → " + outside.path))

        // A parent (MobileSync) is the link.
        let ancestorHome = try makeHome()
        let support = ancestorHome.appendingPathComponent("Library/Application Support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("MobileSync"), withDestinationURL: outside)
        let ancestor = MobileDeviceBackupInventoryScanner(homePath: ancestorHome.path).scan()
        guard case let .linkedAncestor(path, _) = ancestor.rootState else {
            return XCTFail("\(ancestor.rootState)")
        }
        XCTAssertEqual(path, support.appendingPathComponent("MobileSync").path)
        XCTAssertTrue(ancestor.backups.isEmpty)

        // A folder that cannot be listed reads as missing access, with the way to grant it.
        let lockedHome = try makeHome()
        let locked = backupRoot(in: lockedHome)
        try writeData(4 * 1024, to: locked.appendingPathComponent("ONE/00/file"))
        XCTAssertEqual(chmod(locked.path, 0o000), 0)
        defer { _ = chmod(locked.path, 0o755) }
        let unreadable = MobileDeviceBackupInventoryScanner(homePath: lockedHome.path).scan()
        XCTAssertEqual(unreadable.rootState, .unreadable)
        XCTAssertTrue(unreadable.backups.isEmpty)
        let detail = try XCTUnwrap(MobileDeviceBackupPresentation.stateDetail(unreadable))
        XCTAssertTrue(detail.contains(L10n.text("完全磁盘访问权限", "Full Disk Access")))
        XCTAssertTrue(MobileDeviceBackupPresentation.notices(unreadable).isEmpty)
    }

    func testHardLinksLinksDeepFoldersAndUnreadableMetadataAreSafe() throws {
        let home = try makeHome()
        let first = try backupFolder("A", in: home)
        let second = try backupFolder("B", in: home)
        let shared = first.appendingPathComponent("00/shared")
        try writeData(32 * 1024, to: shared)
        try FileManager.default.createDirectory(at: second.appendingPathComponent("00"), withIntermediateDirectories: true)
        XCTAssertEqual(link(shared.path, second.appendingPathComponent("00/shared").path), 0)
        // The same file twice inside one backup counts once there.
        try FileManager.default.createDirectory(at: first.appendingPathComponent("ff"), withIntermediateDirectories: true)
        XCTAssertEqual(link(shared.path, first.appendingPathComponent("ff/again").path), 0)
        try writeData(8 * 1024, to: first.appendingPathComponent("01/own"))
        try writeData(4 * 1024, to: second.appendingPathComponent("02/own"))
        // A link inside a backup and a linked backup folder: neither is followed or counted.
        let outside = try makeOutside()
        try FileManager.default.createSymbolicLink(at: first.appendingPathComponent("01/link"),
                                                   withDestinationURL: outside.appendingPathComponent("big"))
        try FileManager.default.createSymbolicLink(at: backupRoot(in: home).appendingPathComponent("LINKED"),
                                                   withDestinationURL: outside)
        // Too deep for the limit used here: only that subtree is skipped.
        try writeData(4 * 1024, to: second.appendingPathComponent("x/y/z/deep"))
        // Metadata that must not be read: a linked Status.plist and an oversized Info.plist.
        try FileManager.default.createSymbolicLink(at: first.appendingPathComponent("Status.plist"),
                                                   withDestinationURL: outside.appendingPathComponent("Status.plist"))
        try writePlist(["Device Name": "Big", "Padding": String(repeating: "x", count: 4096)],
                       to: second.appendingPathComponent("Info.plist"))

        var scanner = MobileDeviceBackupInventoryScanner(homePath: home.path)
        scanner.maximumDepth = 3
        scanner.infoPlistByteLimit = 1024
        let inventory = scanner.scan()

        XCTAssertEqual(Set(inventory.backups.map(\.id)), ["A", "B"])
        let a = try XCTUnwrap(inventory.backups.first { $0.id == "A" })
        let b = try XCTUnwrap(inventory.backups.first { $0.id == "B" })
        let sharedBytes = allocated(shared)
        XCTAssertEqual(a.bytes, sharedBytes + allocated(first.appendingPathComponent("01/own")))
        XCTAssertEqual(a.fileCount, 2)
        XCTAssertEqual(a.sharedBytes, sharedBytes)
        XCTAssertNil(a.backupDate, "A linked Status.plist is not followed")
        XCTAssertFalse(a.isIncomplete)
        XCTAssertEqual(b.sharedBytes, sharedBytes)
        XCTAssertNil(b.deviceName, "An oversized Info.plist is not parsed")
        XCTAssertTrue(b.isIncomplete, "The deep folder was skipped")
        XCTAssertEqual(b.bytes, sharedBytes + allocated(second.appendingPathComponent("02/own"))
                       + allocated(second.appendingPathComponent("Info.plist")))
        XCTAssertEqual(inventory.totalBytes, a.bytes + b.bytes - sharedBytes, "Shared once")
        XCTAssertEqual(inventory.skippedSymbolicLinkCount, 3)
        XCTAssertEqual(inventory.skippedDeepFolderCount, 1)
        XCTAssertTrue(inventory.isIncomplete)
        XCTAssertEqual(MobileDeviceBackupPresentation.title(b),
                       L10n.text("没有读到设备名的备份", "Backup without a device name"))
        XCTAssertNotNil(MobileDeviceBackupPresentation.sharing(a))
        XCTAssertTrue(MobileDeviceBackupPresentation.detail(b, formatDate: { _ in "" })
            .contains(L10n.text("大小不完整", "Size incomplete")))
        XCTAssertEqual(MobileDeviceBackupPresentation.notices(inventory).count, 2)
    }

    func testEntryLimitAndCancellationStopEarly() throws {
        let home = try makeHome()
        for index in 0..<4 {
            try writeData(4 * 1024, to: try backupFolder("D\(index)", in: home).appendingPathComponent("00/file"))
        }
        XCTAssertEqual(MobileDeviceBackupInventoryScanner(homePath: home.path).scan().backups.count, 4)

        var limited = MobileDeviceBackupInventoryScanner(homePath: home.path)
        limited.entryLimit = 5
        let partial = limited.scan()
        XCTAssertTrue(partial.stoppedEarly)
        XCTAssertTrue(partial.isIncomplete)
        XCTAssertLessThan(partial.backups.count, 4)
        XCTAssertTrue(MobileDeviceBackupPresentation.notices(partial)
            .contains(L10n.text("条目过多或已停止，结果不完整", "Too many entries or stopped; results are incomplete")))

        var cancelled = MobileDeviceBackupInventoryScanner(homePath: home.path)
        cancelled.isCancelled = { true }
        let stopped = cancelled.scan()
        XCTAssertTrue(stopped.stoppedEarly)
        XCTAssertTrue(stopped.backups.isEmpty)
    }

    func testNamesAndVersionsAreCleanedOrDropped() {
        XCTAssertEqual(MobileDeviceBackupInventoryScanner.displayName(" \u{0000}My\u{001B} Phone\t"), "My Phone")
        XCTAssertNil(MobileDeviceBackupInventoryScanner.displayName("  \n "))
        XCTAssertNil(MobileDeviceBackupInventoryScanner.displayName(42))
        XCTAssertEqual(MobileDeviceBackupInventoryScanner.displayName(String(repeating: "名", count: 100)),
                       String(repeating: "名", count: 80) + "…")
        for valid in ["18", "18.1", "17.6.1", "16.7.10.2"] {
            XCTAssertEqual(MobileDeviceBackupInventoryScanner.systemVersion(valid), valid)
        }
        for invalid in ["", "18..1", ".18", "18.1a", "18.1.", "\u{FF11}\u{FF18}.1", "1.2.3.4.5",
                        String(repeating: "1", count: 17)] {
            XCTAssertNil(MobileDeviceBackupInventoryScanner.systemVersion(invalid), invalid)
        }
        XCTAssertNil(MobileDeviceBackupInventoryScanner.systemVersion(18.1))
        XCTAssertTrue(MobileDeviceBackupPresentation.readOnlyNote.contains(L10n.text("不提供删除", "nothing can be deleted")))
        XCTAssertTrue(MobileDeviceBackupPresentation.readOnlyNote.contains(L10n.text("管理备份", "Manage Backups")))
    }

    /// 只读：盘点与界面里没有任何删除、移动或写入的调用；入口在文件分析里。
    func testInventoryOffersNoDeletionAndIsReachableFromFileAnalysis() throws {
        for path in ["Services/MobileDeviceBackupInventory.swift", "Views/FilesLightfield/MobileDeviceBackupInventoryView.swift"] {
            let text = try source(path)
            for token in ["removeItem", "trashItem", "moveItem", "unlink(", "rmdir(", "createFile", "write(to:",
                          "requestTrash", "moveToTrash", "Process(", "copyItem"] {
                XCTAssertFalse(text.contains(token), "\(path) \(token)")
            }
        }
        let page = try source("Views/FilesLightfield/FileAnalysisLightfieldView.swift")
        XCTAssertTrue(page.contains("MobileDeviceBackupInventorySheet(onClose:"))
        XCTAssertTrue(page.contains("lightfield.analysis.deviceBackups"))
    }

    // MARK: - Helpers

    private func makeHome() throws -> URL {
        let root = TestFileSystem.uniqueRoot("DeviceBackups")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeOutside() throws -> URL {
        let root = TestFileSystem.uniqueRoot("DeviceBackupsOutside")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("FOLDER"), withIntermediateDirectories: true)
        try Data(repeating: 9, count: 64 * 1024).write(to: root.appendingPathComponent("big"))
        try writePlist(["Date": firstDate], to: root.appendingPathComponent("Status.plist"))
        return root
    }

    private func backupRoot(in home: URL) -> URL {
        home.appendingPathComponent(MobileDeviceBackupInventoryScanner.relativeRootPath)
    }

    private func backupFolder(_ name: String, in home: URL) throws -> URL {
        let folder = backupRoot(in: home).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writePlist(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0).write(to: url)
    }

    private func writeData(_ count: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: count).write(to: url)
    }

    private func allocated(_ url: URL) -> Int64 {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return -1 }
        return Int64(status.st_blocks) * 512
    }

    /// Allocated bytes of every regular file under a folder (no links in these trees).
    private func allocatedTree(_ folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return -1 }
        var total: Int64 = 0
        for case let relative as String in walker {
            let url = folder.appendingPathComponent(relative)
            var status = stat()
            guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { continue }
            total += Int64(status.st_blocks) * 512
        }
        return total
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/" + path), encoding: .utf8)
    }
}
