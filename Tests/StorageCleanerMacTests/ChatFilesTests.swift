import Foundation
import XCTest
@testable import StorageCleanerMac

/// D-FP3（竞品对比 2026-10-20，腾讯柠檬的聊天文件清理与搬家）：微信 4、旧版微信、QQ NT、
/// 企业微信四种目录布局；只读统计、按月份和 90 天划分；移到废纸篓前聊天软件须已退出；
/// 复制到外置盘逐个文件核对，原件不动。夹具在家目录下的隔离文件夹里。
final class ChatFilesTests: XCTestCase {
    private static let now = ISO8601DateFormatter().date(from: "2026-10-20T10:00:00Z")!

    func testScannerListsMonthsPerAppAccountAndKind() throws {
        let fixture = try ChatFixture()
        defer { fixture.remove() }
        try fixture.seedAllLayouts()

        let inventory = fixture.scanner().scan()
        XCTAssertEqual(Set(inventory.appsFound), [.wechat, .wechatLegacy, .qq, .wecom])
        let byID = Dictionary(uniqueKeysWithValues: inventory.rows.map { ($0.id, $0) })

        let attach = try XCTUnwrap(byID["wechat|wxid_abc123_def4|images|2024-01"])
        XCTAssertEqual(attach.folders.count, 2, "两个聊天的同一月份合成一行")
        XCTAssertEqual(attach.fileCount, 2)
        XCTAssertTrue(attach.isOlderThanCutoff)
        let recent = try XCTUnwrap(byID["wechat|wxid_abc123_def4|files|2026-10"])
        XCTAssertFalse(recent.isOlderThanCutoff, "90 天内")
        XCTAssertNotNil(byID["wechat|wxid_abc123_def4|videos|2025-12"])
        XCTAssertNil(inventory.rows.first { $0.account == "all_users" }, "不是账号的文件夹不列")

        let unsorted = try XCTUnwrap(byID["qq|nt_qq_123|files|-"], "QQ 没按月份放的文件单独一行")
        XCTAssertTrue(unsorted.isOlderThanCutoff, "没有月份时按最新改动时间判断")
        XCTAssertNotNil(byID["qq|nt_qq_123|images|2024-03"])
        XCTAssertNotNil(byID["wecom|P1|files|2024-02"])
        let legacy = try XCTUnwrap(inventory.rows.first { $0.app == .wechatLegacy && $0.kind == .images })
        XCTAssertNil(legacy.month)
        XCTAssertEqual(legacy.account, "2.0b4.0.9/hash1")

        XCTAssertGreaterThan(inventory.summary.olderBytes, 0)
        XCTAssertLessThan(inventory.summary.olderBytes, inventory.summary.totalBytes)
    }

    func testNothingIsReadWithoutFullDiskAccess() {
        var scanner = ChatFilesScanner()
        scanner.fullDiskAccess = { .notVerified }
        XCTAssertEqual(scanner.access(), .needsFullDiskAccess)
        scanner.fullDiskAccess = { .verified }
        XCTAssertEqual(scanner.access(), .granted)
    }

    func testMonthsAreRecognisedStrictly() {
        XCTAssertTrue(ChatFilesScanner.isMonth("2024-01"))
        XCTAssertTrue(ChatFilesScanner.isMonth("2026-12"))
        XCTAssertFalse(ChatFilesScanner.isMonth("2024-13"))
        XCTAssertFalse(ChatFilesScanner.isMonth("2024-1"))
        XCTAssertFalse(ChatFilesScanner.isMonth("Img"))
    }

    // MARK: Trash

    func testRowsMoveToTheTrashOnlyWhileTheChatAppIsClosed() async throws {
        let fixture = try ChatFixture()
        defer { fixture.remove() }
        try fixture.seedAllLayouts()
        let inventory = fixture.scanner().scan()
        let attach = try XCTUnwrap(inventory.rows.first { $0.id == "wechat|wxid_abc123_def4|images|2024-01" })

        let reports = ReportBox()
        let refused = await ChatFilesTrashService.execute([attach], environment: fixture.environment(reports: reports,
                                                                                                       running: ["com.tencent.xinWeChat"]))
        XCTAssertTrue(refused.movedRowIDs.isEmpty)
        XCTAssertTrue(refused.keptNotes.contains { $0.contains(ChatApp.wechat.title) })
        XCTAssertTrue(attach.folders.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        let moved = await ChatFilesTrashService.execute([attach], environment: fixture.environment(reports: reports))
        XCTAssertEqual(moved.movedRowIDs, [attach.id])
        XCTAssertTrue(attach.folders.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let report = try XCTUnwrap(reports.last)
        XCTAssertEqual(report.rulesVersion, ChatFilesTrashService.ruleID)
        XCTAssertEqual(report.summary.movedItemCount, 2)
        XCTAssertEqual(OperationRecordPresentation.title(rulesVersion: report.rulesVersion, subject: "2024-01", itemCount: 2)
            .contains(L10n.text("聊天文件", "Chat Files")), true)
    }

    func testAFolderOutsideTheAppsContainerIsKept() async throws {
        let fixture = try ChatFixture()
        defer { fixture.remove() }
        let outside = fixture.home.appendingPathComponent("Documents/2024-01", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside.appendingPathComponent("a.txt"))
        let identity = try FoundationReadOnlyFileSystem().snapshot(at: outside).identity
        let forged = ChatFilesRow(id: "wechat|x|files|2024-01", app: .wechat, account: "x", kind: .files, month: "2024-01",
                                  folders: [.init(path: PathSafety.lexicalPath(outside.path), identity: identity)],
                                  bytes: 1, fileCount: 1, newestModification: nil, isOlderThanCutoff: true, sizeIsLowerBound: false)
        let outcome = await ChatFilesTrashService.execute([forged], environment: fixture.environment(reports: ReportBox()))
        XCTAssertTrue(outcome.movedRowIDs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "不在聊天软件容器里的不动")
    }

    // MARK: Copy

    func testVideosAndFilesAreCopiedAndCheckedButPicturesAreNot() throws {
        let fixture = try ChatFixture()
        defer { fixture.remove() }
        try fixture.seedAllLayouts()
        let inventory = fixture.scanner().scan()
        let rows = inventory.rows.filter { $0.app == .wechat && $0.account == "wxid_abc123_def4" }
        let volume = fixture.base.appendingPathComponent("Volume", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)

        let outcome = ChatFilesCopyService.execute(rows, to: volume, availableBytes: 10_000_000_000,
                                                   environment: fixture.environment(reports: ReportBox()))
        let files = try XCTUnwrap(rows.first { $0.id.hasSuffix("files|2024-01") })
        let copied = try XCTUnwrap(outcome.verified[files.id])
        let original = URL(fileURLWithPath: files.folders[0].path).appendingPathComponent("a.pdf")
        let copy = URL(fileURLWithPath: copied).appendingPathComponent("2024-01/a.pdf")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: original), "逐字节一致")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "原件不动")
        let pictures = try XCTUnwrap(rows.first { $0.kind == .images })
        XCTAssertNil(outcome.verified[pictures.id])
        XCTAssertNotNil(outcome.failed[pictures.id], "图片不复制，并说明原因")

        let full = ChatFilesCopyService.execute([files], to: volume, availableBytes: 10,
                                                environment: fixture.environment(reports: ReportBox()))
        XCTAssertNotNil(full.failed[files.id], "空间不够时不开始")
    }

    @MainActor
    func testStoreAsksForFullDiskAccessInsteadOfScanning() {
        var scanner = ChatFilesScanner()
        scanner.fullDiskAccess = { .notVerified }
        let store = ChatFilesStore(coordinator: HeavyWorkCoordinator(), scanner: scanner, loadVolumes: { [] }, openURL: { _ in })
        store.scan()
        XCTAssertEqual(store.phase, .needsFullDiskAccess)
        XCTAssertNil(store.inventory)
    }

    @MainActor
    func testStoreFiltersByKindAndAge() async throws {
        let fixture = try ChatFixture()
        defer { fixture.remove() }
        try fixture.seedAllLayouts()
        let store = ChatFilesStore(coordinator: HeavyWorkCoordinator(), scanner: fixture.scanner(),
                                   environment: fixture.environment(reports: ReportBox()), loadVolumes: { [] }, openURL: { _ in })
        store.scan()
        let deadline = Date().addingTimeInterval(10)
        while store.phase != .ready, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(store.apps, [.wechat, .wechatLegacy, .qq, .wecom])
        store.kindFilter = .files
        store.ageFilter = .recent
        XCTAssertEqual(store.rows(for: .wechat).map(\.month), ["2026-10"])
        store.ageFilter = .older
        store.setSelected(store.rows(for: .wechat), selected: true)
        XCTAssertTrue(store.selectedRows.allSatisfy { $0.isOlderThanCutoff && $0.kind == .files })
    }
}

struct ChatFixture {
    let base: URL
    var home: URL { base.appendingPathComponent("home", isDirectory: true) }
    var trash: URL { base.appendingPathComponent("Trash", isDirectory: true) }

    init() throws {
        base = TestFileSystem.uniqueOperationRoot("chat-files")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    func write(_ relative: String, bytes: Int = 50_000, daysOld: Double = 400) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)],
                                              ofItemAtPath: url.path)
    }

    func seedAllLayouts() throws {
        let wechat = ChatApp.wechat.accountsRoot + "/wxid_abc123_def4/msg"
        try write(wechat + "/file/2024-01/a.pdf")
        try write(wechat + "/file/2026-10/b.pdf", daysOld: 2)
        try write(wechat + "/video/2025-12/v.mp4")
        try write(wechat + "/attach/chatA/2024-01/Img/x.dat")
        try write(wechat + "/attach/chatB/2024-01/Img/y.dat")
        try write(ChatApp.wechat.accountsRoot + "/all_users/config/global.dat")
        try write(ChatApp.wechatLegacy.accountsRoot + "/2.0b4.0.9/hash1/Message/MessageTemp/chat1/Image/i.jpg")
        let qq = ChatApp.qq.accountsRoot + "/nt_qq_123/nt_data"
        try write(qq + "/Pic/2024-03/Ori/p.jpg")
        try write(qq + "/File/report.docx")
        try write(ChatApp.wecom.accountsRoot + "/P1/Caches/Files/2024-02/c.xlsx")
    }

    func scanner() -> ChatFilesScanner {
        var scanner = ChatFilesScanner()
        scanner.home = home
        scanner.now = { ISO8601DateFormatter().date(from: "2026-10-20T10:00:00Z")! }
        scanner.fullDiskAccess = { .verified }
        return scanner
    }

    func environment(reports: ReportBox, running: Set<String> = []) -> ChatFilesEnvironment {
        var environment = ChatFilesEnvironment()
        environment.home = home
        environment.runningBundleIdentifiers = { running }
        let trash = trash
        environment.moveToTrash = { source in
            let target = trash.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: target)
            return target
        }
        environment.persist = { report, _ in reports.append(report) }
        return environment
    }

    func remove() { TestFileSystem.remove(base) }
}
