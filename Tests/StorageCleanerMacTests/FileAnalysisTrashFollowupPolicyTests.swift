import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

final class FileAnalysisTrashFollowupPolicyTests: XCTestCase {
    func testD54NamesIgnoreCaseAndCanonicalUnicodeSpelling() {
        let home = "/Users/Fixturé"
        let policy = FileAnalysisTrashPolicy(rootPath: "/", targetKind: .internalVolume, homePath: home,
                                             appDataPath: home + "/AppData", excludedPaths: [])
        func block(_ relative: String, directory: Bool = false) -> FileAnalysisTrashBlock? {
            let path = home.decomposedStringWithCanonicalMapping + "/" + relative
            return policy.block(path: path, name: (path as NSString).lastPathComponent,
                                kind: directory ? "folder" : "file", isDirectory: directory, isEstimated: false)
        }
        for relative in ["library/keychains/key", "LIBRARY/MAIL/mail.db", "Library/reminders/store.sqlite",
                         "library/shortcuts/store.sqlite", "library/application support/FILEPROVIDER/state.db",
                         "library/group containers/GROUP.IS.WORKFLOW.SHORTCUTS/Shortcuts.sqlite",
                         "library/containers/COM.APPLE.MAIL/Data/x", "library/preferences/tool.plist"] {
            XCTAssertEqual(block(relative), .systemData, relative)
        }
        for relative in [".SSH/key", ".PASSWORD-STORE/key", ".TERRAFORM.D/CREDENTIALS.TFRC.JSON"] {
            XCTAssertEqual(block(relative), .credentials, relative)
        }
        XCTAssertEqual(block("library/containers/com.example.tool/DATA", directory: true), .appContainer)
        XCTAssertEqual(block(".CONFIG", directory: true), .containsProtectedLocation)
        XCTAssertNil(block("library/application support/MobileSync/Backup/one", directory: true))
        XCTAssertNil(block("library/keychains-old/key"), "按路径分量比较，不能匹配同名前缀")
        XCTAssertEqual(policy.block(path: "/Users/FIXTURÉ/Downloads/item.zip", name: "item.zip", kind: "file",
                                    isDirectory: false, isEstimated: false), .outsideHome,
                       "保护名称的大小写折叠不能扩大个人目录的可处理范围")
        XCTAssertEqual(FileAnalysisTrashPolicy.protectedName("CAFÉ"),
                       FileAnalysisTrashPolicy.protectedName("Cafe\u{301}"))
        XCTAssertNotEqual(FileAnalysisTrashPolicy.protectedName("Cafe"),
                          FileAnalysisTrashPolicy.protectedName("Café"), "不去掉重音")
    }

    func testProtectedSymbolicLinkTargetsAndTheirParentsStayProtectedOnAnExternalVolume() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let home = fixture.base.appendingPathComponent("Home")
        try manager.createDirectory(at: home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try manager.createDirectory(at: fixture.url("Stores/Mail"), withIntermediateDirectories: true)
        try Data("fixture mail".utf8).write(to: fixture.url("Stores/Mail/messages.db"))
        try manager.createSymbolicLink(at: home.appendingPathComponent("Library/mAiL"),
                                       withDestinationURL: fixture.url("Stores/Mail"))
        try manager.createDirectory(at: fixture.url("Keys"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: home.appendingPathComponent(".SSH"), withDestinationURL: fixture.url("Keys"))
        try manager.createDirectory(at: fixture.url("Caches/com.example"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: home.appendingPathComponent("Library/Caches"),
                                       withDestinationURL: fixture.url("Caches"))
        let analysis = try DiskScanner(excludedPaths: []).storageMapAnalysis(target:
            StorageMapScanTarget(path: fixture.root.path, title: "External fixture", kind: .externalVolume))
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: fixture.environment(homePath: home.path))
        func block(_ relative: String, directory: Bool = true) -> FileAnalysisTrashBlock? {
            let path = fixture.url(relative).path
            return policy.block(path: path, name: (path as NSString).lastPathComponent, kind: "folder",
                                isDirectory: directory, isEstimated: false)
        }
        XCTAssertEqual(block("Stores/Mail"), .systemData)
        XCTAssertEqual(block("Stores/Mail/messages.db", directory: false), .systemData)
        XCTAssertEqual(block("Stores"), .containsProtectedLocation)
        XCTAssertEqual(block("Keys"), .credentials)
        XCTAssertEqual(block("Keys/key", directory: false), .credentials)
        XCTAssertEqual(block("Caches"), .libraryFolder)
        XCTAssertNil(block("Caches/com.example"), "第一层资源库目录的链接目标内部仍按其他规则处理")
        XCTAssertNil(block("Media"))
        let review = FileAnalysisTrashService.review([try fixture.selection("Stores", in: analysis.index)],
            index: analysis.index, policy: policy, environment: fixture.environment(homePath: home.path),
            externalVolumeName: "External fixture")
        XCTAssertEqual(review.items.first?.status, .blocked(.containsProtectedLocation))
    }

    func testALinkedLibraryProtectsSystemStoresWithoutBlockingMobileSyncBackups() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let home = fixture.base.appendingPathComponent("Home")
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        for relative in ["Library/Mail", "Library/Group Containers/com.apple.notes",
                         "Library/Containers/com.example.tool/Data", "Library/Application Support/MobileSync/Backup/one"] {
            try manager.createDirectory(at: fixture.url(relative), withIntermediateDirectories: true)
        }
        try manager.createSymbolicLink(at: home.appendingPathComponent("Library"),
                                       withDestinationURL: fixture.url("Library"))
        let locations = FileAnalysisProtectedLinkResolver.locations(homePath: home.path,
                                                                     appDataPath: home.appendingPathComponent("AppData").path)
        let policy = FileAnalysisTrashPolicy(rootPath: fixture.root.path, targetKind: .externalVolume,
            homePath: home.path, appDataPath: home.appendingPathComponent("AppData").path,
            excludedPaths: [], protectedLinkTargets: locations)
        func block(_ relative: String) -> FileAnalysisTrashBlock? {
            policy.block(path: fixture.url(relative).path, name: (relative as NSString).lastPathComponent,
                         kind: "folder", isDirectory: true, isEstimated: false)
        }
        XCTAssertEqual(block("Library/Mail"), .systemData)
        XCTAssertEqual(block("Library/Group Containers/com.apple.notes"), .systemData)
        XCTAssertEqual(block("Library/Containers/com.example.tool"), .appContainer)
        XCTAssertEqual(block("Library/Containers/com.example.tool/Data"), .appContainer)
        XCTAssertNil(block("Library/Containers/com.example.tool/Data/Documents"))
        XCTAssertNil(block("Library/Application Support/MobileSync/Backup/one"))
    }

    /// `.app` 只是包形状；第 4 轮按可执行文件判定。行、规则和审阅使用
    /// 扫描器实际给出的项目；没有可执行文件的数据目录仍可勾选。
    func testAFolderNamedLikeAnAppIsSelectableUnlessItHasAnExecutable() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        func folder(_ relative: String, packageType: String?, plist: Bool = true, executable: String? = nil) throws {
            let contents = fixture.url(relative).appendingPathComponent("Contents")
            try manager.createDirectory(at: contents, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 2_048).write(to: contents.appendingPathComponent("payload.bin"))
            if let executable {
                try manager.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
                try Data(repeating: 0xCF, count: 4_096).write(to: contents.appendingPathComponent("MacOS/" + executable))
            }
            guard plist else { return }
            var info: [String: Any] = ["CFBundleIdentifier": "com.example." + (relative as NSString).lastPathComponent]
            if let packageType { info["CFBundlePackageType"] = packageType }
            if let executable { info["CFBundleExecutable"] = executable }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        let storage = fixture.url("Library/HTTPStorages/com.example.app")
        try manager.createDirectory(at: storage, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: storage.appendingPathComponent("httpstorage.sqlite"))
        try folder("Downloads/Plugin.app", packageType: "BNDL", executable: "Plugin")
        try folder("Downloads/Untyped.app", packageType: nil)
        try folder("Downloads/Empty.app", packageType: nil, plist: false)
        try folder("Build/Real.app", packageType: "APPL", executable: "Real")
        // Main-session ruling: an older app without a package type is still
        // an app when its executable is there.
        try folder("Build/Legacy.app", packageType: nil, executable: "Legacy")

        let analysis = try fixture.analyze()
        // The analyzed folder stands in for the home folder, so this is `~/Library/HTTPStorages`.
        let environment = fixture.environment(homePath: fixture.root.path)
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        func block(_ relative: String) throws -> FileAnalysisTrashBlock? {
            let path = fixture.url(relative).path
            let entry = try XCTUnwrap(analysis.index.indexedEntry(at: path), relative)
            XCTAssertEqual(entry.kind, "package", "\(relative): what the scanner gives a folder named ….app")
            return FileAnalysisTrashService.block(for: path, entry: entry, index: analysis.index, policy: policy)
        }
        XCTAssertNil(try block("Library/HTTPStorages/com.example.app"))
        XCTAssertEqual(try block("Downloads/Plugin.app"), .applicationBundle, "BNDL 带可执行文件也挡为应用")
        XCTAssertNil(try block("Downloads/Untyped.app"))
        XCTAssertNil(try block("Downloads/Empty.app"))
        XCTAssertEqual(try block("Build/Real.app"), .applicationBundle)
        XCTAssertEqual(try block("Build/Legacy.app"), .applicationBundle, "No package type, but its executable is there")
        XCTAssertEqual(try block("Tool.app"), .applicationBundle)

        // The row's category follows the same rule: a folder named like an
        // app that is not one is labelled by what it holds, like a folder.
        func category(_ relative: String) throws -> StorageMapContentCategory {
            let url = fixture.url(relative)
            let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(
                at: url.deletingLastPathComponent().path, using: analysis.index)
            return try XCTUnwrap(snapshot.entries.first { $0.path == url.path }, relative).contentCategory
        }
        XCTAssertEqual(try category("Library/HTTPStorages/com.example.app"), .data)
        for relative in ["Downloads/Untyped.app", "Downloads/Empty.app"] {
            XCTAssertNotEqual(try category(relative), .application, relative)
        }
        for relative in ["Downloads/Plugin.app", "Build/Real.app", "Build/Legacy.app", "Tool.app"] {
            XCTAssertEqual(try category(relative), .application, relative)
        }

        let review = FileAnalysisTrashService.review(
            try ["Library/HTTPStorages/com.example.app", "Build/Real.app", "Downloads/Plugin.app"]
                .map { try fixture.selection($0, in: analysis.index) },
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil)
        XCTAssertTrue(review.items[0].isReady, "\(review.items[0].status)")
        XCTAssertEqual(review.items[1].status, .blocked(.applicationBundle))
        XCTAssertEqual(review.items[2].status, .blocked(.applicationBundle))
        XCTAssertEqual(review.readyItems.map(\.selection.path), [storage.path])

        // Rules made without the file system stay on the safe side.
        let pure = FileAnalysisTrashPolicy(rootPath: "/Users/fixture", targetKind: .homeDirectory,
                                           homePath: "/Users/fixture", appDataPath: "/Users/fixture/AppData",
                                           excludedPaths: [])
        XCTAssertEqual(pure.block(path: "/Users/fixture/Downloads/Plugin.app", name: "Plugin.app", kind: "package",
                                  isDirectory: true, isEstimated: false), .applicationBundle)
        XCTAssertNil(pure.block(path: "/Users/fixture/Downloads/report.app", name: "report.app", kind: "file",
                                isDirectory: false, isEstimated: false))
        XCTAssertFalse(FileAnalysisTrashPolicy.isApplicationBundle(name: "report.pages", kind: "package"))
        XCTAssertTrue(FileAnalysisTrashPolicy.isApplicationBundle(name: "Tool.APP", kind: "package"))
    }

    /// 第 4 轮：忽略包类型，支持包名后备名和包内子路径；链接仍不跟随。
    func testTheAppProbeUsesCFBundleExecutableNamesWithoutRequiringAPPL() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let probe = fixture.url("Probe")
        func bundle(_ name: String, info: [String: Any], executable: String? = nil) throws {
            let contents = probe.appendingPathComponent(name).appendingPathComponent("Contents")
            try manager.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            if let executable {
                try manager.createDirectory(at: contents.appendingPathComponent("MacOS/" + executable)
                    .deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0xCF, count: 4_096).write(to: contents.appendingPathComponent("MacOS/" + executable))
            }
        }
        func isApplication(_ name: String) -> Bool {
            FileAnalysisApplicationBundleProbe.isApplication(atPath: probe.appendingPathComponent(name).path)
        }
        try bundle("Legacy.app", info: ["CFBundleExecutable": "Legacy"], executable: "Legacy")
        try bundle("NoExecutable.app", info: ["CFBundleExecutable": "Gone"])
        try bundle("Unnamed.app", info: ["CFBundleIdentifier": "com.example.unnamed"], executable: "Unnamed")
        try bundle("Plugin.app", info: ["CFBundlePackageType": "BNDL", "CFBundleExecutable": "Plugin"], executable: "Plugin")
        // 此路径仍在包内，按 CFBundle 的解析方式可以找到文件。
        try bundle("Escape.app", info: ["CFBundleExecutable": "../MacOS/Escape"], executable: "Escape")
        XCTAssertTrue(isApplication("Legacy.app"), "No type, its executable is there: an app")
        XCTAssertFalse(isApplication("NoExecutable.app"), "No type, the named executable is missing: a folder")
        XCTAssertTrue(isApplication("Unnamed.app"), "没有可执行文件名时按包名找")
        XCTAssertTrue(isApplication("Plugin.app"), "BNDL 带可执行文件：应用")
        XCTAssertTrue(isApplication("Escape.app"), "包内的相对路径仍能找到可执行文件")
        try bundle("Subpath.app", info: ["CFBundleExecutable": "bin/Tool"], executable: "bin/Tool")
        XCTAssertTrue(isApplication("Subpath.app"))
        try bundle("APPLWithoutExecutable.app", info: ["CFBundlePackageType": "APPL"])
        XCTAssertFalse(isApplication("APPLWithoutExecutable.app"), "APPL 不能代替存在的可执行文件")
        try bundle("EmptyName.app", info: ["CFBundleExecutable": ""], executable: "EmptyName")
        XCTAssertTrue(isApplication("EmptyName.app"))
        try bundle("Malformed.app", info: [:], executable: "Malformed")
        try Data("not a property list".utf8).write(to: probe.appendingPathComponent("Malformed.app/Contents/Info.plist"))
        XCTAssertTrue(isApplication("Malformed.app"), "解析不了 plist 时按包名找")
        try bundle("MissingPlist.app", info: [:], executable: "MissingPlist")
        try manager.removeItem(at: probe.appendingPathComponent("MissingPlist.app/Contents/Info.plist"))
        XCTAssertTrue(isApplication("MissingPlist.app"))
        try bundle("Outside.app", info: ["CFBundleExecutable": "../../../outside"])
        try Data([1]).write(to: probe.appendingPathComponent("outside"))
        XCTAssertFalse(isApplication("Outside.app"), "不能查到包外的文件")
        try bundle("Absolute.app", info: ["CFBundleExecutable": probe.appendingPathComponent("outside").path])
        XCTAssertFalse(isApplication("Absolute.app"))
        try bundle("Nul.app", info: [:], executable: "Tool")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Tool\0hidden"], format: .binary, options: 0)
            .write(to: probe.appendingPathComponent("Nul.app/Contents/Info.plist"))
        XCTAssertFalse(isApplication("Nul.app"))

        try bundle("FolderExecutable.app", info: ["CFBundleExecutable": "Tool"])
        try manager.createDirectory(at: probe.appendingPathComponent("FolderExecutable.app/Contents/MacOS/Tool"),
                                    withIntermediateDirectories: true)
        XCTAssertFalse(isApplication("FolderExecutable.app"), "A folder where the executable should be")
        // Links are not followed: followed, these would read as folders.
        try bundle("LinkedExecutable.app", info: ["CFBundleExecutable": "Tool"])
        try manager.createSymbolicLink(at: probe.appendingPathComponent("LinkedExecutable.app/Contents/MacOS/Tool"),
                                       withDestinationURL: fixture.url("no-such-file"))
        XCTAssertTrue(isApplication("LinkedExecutable.app"), "A linked executable is not followed: stays an app")
        try manager.createDirectory(at: fixture.url("EmptyMacOS"), withIntermediateDirectories: true)
        try bundle("LinkedMacOS.app", info: ["CFBundleExecutable": "Legacy"])
        try manager.removeItem(at: probe.appendingPathComponent("LinkedMacOS.app/Contents/MacOS"))
        try manager.createSymbolicLink(at: probe.appendingPathComponent("LinkedMacOS.app/Contents/MacOS"),
                                       withDestinationURL: fixture.url("EmptyMacOS"))
        XCTAssertTrue(isApplication("LinkedMacOS.app"), "A linked MacOS folder is not followed: stays an app")
        try bundle("LinkedSubpath.app", info: ["CFBundleExecutable": "bin/Tool"])
        try manager.createSymbolicLink(at: probe.appendingPathComponent("LinkedSubpath.app/Contents/MacOS/bin"),
                                       withDestinationURL: fixture.url("no-such-folder"))
        XCTAssertTrue(isApplication("LinkedSubpath.app"), "子路径中的链接也不跟随")
    }

    /// 读不到、不敢读的 plist 仍挡住；可读但无可执行文件的夹具是文件夹。
    func testTheAppProbeStaysBlockedWhenItCannotRead() throws {
        let fixture = try TrashFixture()
        let manager = FileManager.default
        let probe = fixture.url("Probe")
        func contents(_ name: String) throws -> URL {
            let url = probe.appendingPathComponent(name).appendingPathComponent("Contents")
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func write(_ info: [String: Any], to url: URL) throws {
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: url)
        }
        let locked = try contents("Locked.app").appendingPathComponent("Info.plist")
        defer {
            _ = chmod(locked.path, 0o644)
            fixture.remove()
        }
        func isApplication(_ name: String) -> Bool {
            FileAnalysisApplicationBundleProbe.isApplication(atPath: probe.appendingPathComponent(name).path)
        }
        try write(["CFBundlePackageType": "APPL"], to: try contents("App.app").appendingPathComponent("Info.plist"))
        try manager.createDirectory(at: probe.appendingPathComponent("App.app/Contents/MacOS"), withIntermediateDirectories: true)
        try Data([1]).write(to: probe.appendingPathComponent("App.app/Contents/MacOS/App"))
        try write(["CFBundlePackageType": "BNDL", "CFBundleExecutable": "Plugin"],
                  to: try contents("Plugin.app").appendingPathComponent("Info.plist"))
        try Data("not a property list".utf8).write(to: try contents("Garbage.app").appendingPathComponent("Info.plist"))
        try manager.createDirectory(at: probe.appendingPathComponent("Plain.app"), withIntermediateDirectories: true)
        XCTAssertTrue(isApplication("App.app"))
        XCTAssertFalse(isApplication("Plugin.app"))
        XCTAssertFalse(isApplication("Garbage.app"))
        XCTAssertFalse(isApplication("Plain.app"), "No Contents")
        XCTAssertFalse(isApplication("Missing.app"))

        // Links are not followed; a file it may not read is not guessed.
        let elsewhere = fixture.url("elsewhere.plist")
        try write(["CFBundlePackageType": "BNDL"], to: elsewhere)
        try manager.createSymbolicLink(at: try contents("LinkedPlist.app").appendingPathComponent("Info.plist"),
                                       withDestinationURL: elsewhere)
        try manager.createDirectory(at: probe.appendingPathComponent("LinkedContents.app"),
                                    withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: probe.appendingPathComponent("LinkedContents.app/Contents"),
                                       withDestinationURL: probe.appendingPathComponent("Plugin.app/Contents"))
        try write(["CFBundlePackageType": "BNDL"], to: locked)
        XCTAssertEqual(chmod(locked.path, 0), 0)
        XCTAssertTrue(isApplication("LinkedPlist.app"))
        XCTAssertTrue(isApplication("LinkedContents.app"))
        try manager.createSymbolicLink(at: probe.appendingPathComponent("LinkedBundle.app"),
                                       withDestinationURL: probe.appendingPathComponent("Plain.app"))
        XCTAssertTrue(isApplication("LinkedBundle.app"), "包自身是链接也不跟随")
        XCTAssertTrue(isApplication("Locked.app"))
        let oversized = try contents("Oversized.app").appendingPathComponent("Info.plist")
        try Data(repeating: 0, count: FileAnalysisApplicationBundleProbe.maximumInfoPlistBytes + 1).write(to: oversized)
        XCTAssertTrue(isApplication("Oversized.app"))
        let fifo = try contents("FIFO.app").appendingPathComponent("Info.plist")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertFalse(isApplication("FIFO.app"), "初始就是 FIFO：不打开，不阻塞")
    }

    func testAnInfoPlistReplacedWithAFIFOBetweenStatAndOpenDoesNotBlock() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let contents = fixture.url("Raced.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = contents.appendingPathComponent("Info.plist").path
        try Data("not a property list".utf8).write(to: URL(fileURLWithPath: plist))
        let release = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        var replacementSucceeded = false
        var writerStarted = false
        defer {
            release.signal()
            if writerStarted { writerFinished.wait() }
        }
        let start = ContinuousClock.now
        let isApplication = FileAnalysisApplicationBundleProbe.isApplication(atPath: fixture.url("Raced.app").path,
            beforeOpeningInfoPlist: {
                replacementSucceeded = unlink(plist) == 0 && mkfifo(plist, 0o600) == 0
                guard replacementSucceeded else { return }
                writerStarted = true
                // 仅反证去掉 O_NONBLOCK 时，2 秒后开写端解除阻塞；绿态取消。
                DispatchQueue.global(qos: .utility).async {
                    if release.wait(timeout: .now() + 2) == .timedOut {
                        let writer = open(plist, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
                        if writer >= 0 { close(writer) }
                    }
                    writerFinished.signal()
                }
            })
        XCTAssertTrue(replacementSucceeded)
        XCTAssertTrue(isApplication, "检查后类型被替换：保守挡为应用")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1), "不能等待 FIFO 的写端")
    }
}
