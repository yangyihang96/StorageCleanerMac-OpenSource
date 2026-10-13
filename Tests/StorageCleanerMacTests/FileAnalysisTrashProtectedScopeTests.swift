import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

/// D54 (review P1-1): what File Analysis never moves to the Trash, or never
/// moves whole. The rules tables are pure path checks on a made-up home
/// folder; the review and move tests use `TrashFixture` (a hidden folder
/// under the home folder, a fixture "Trash", an isolated receipt journal).
final class FileAnalysisTrashProtectedScopeTests: XCTestCase {
    private let home = "/Users/fixture"

    private func policy(
        running: [String] = [], mounts: [String] = [],
        appDataPath: String = "/Users/fixture/.local/share/AppData"
    ) -> FileAnalysisTrashPolicy {
        FileAnalysisTrashPolicy(rootPath: home, targetKind: .homeDirectory, homePath: home,
                                appDataPath: appDataPath, excludedPaths: [],
                                runningApplicationPaths: running, mountPointPaths: mounts)
    }

    private func block(_ relative: String, directory: Bool = true, kind: String? = nil,
                       in policy: FileAnalysisTrashPolicy? = nil)
        -> FileAnalysisTrashBlock? {
        let path = home + "/" + relative
        let name = (path as NSString).lastPathComponent
        return (policy ?? self.policy()).block(path: path, name: name, kind: kind ?? (directory ? "folder" : "file"),
                                               isDirectory: directory, isEstimated: false)
    }

    // ① Kept whole, with everything inside.
    func testSystemDataAndCredentialsAreKeptWholeWithEverythingInside() {
        for name in FileAnalysisTrashPolicy.protectedLibraryFolderNames
        where name != "Mobile Documents" && name != "CloudStorage" {
            XCTAssertEqual(block("Library/" + name), .systemData, name)
            XCTAssertEqual(block("Library/" + name + "/inner/item.db", directory: false), .systemData, name)
        }
        // The cloud locations keep their own reason ("use Finder or the app").
        XCTAssertEqual(block("Library/Mobile Documents"), .cloudStorage)
        XCTAssertEqual(block("Library/CloudStorage/Dropbox"), .cloudStorage)
        XCTAssertEqual(block("Library/Keychains/login.keychain-db", directory: false), .systemData)

        for parent in ["Containers", "Group Containers", "Application Support"] {
            for name in ["com.apple.mail", "AddressBook", "CallHistoryDB", "Knowledge",
                         "FileProvider", "CloudDocs", "iCloud", "CallHistoryTransactions", "DifferentialPrivacy",
                         "Dock"] {
                XCTAssertEqual(block("Library/\(parent)/\(name)"), .systemData, "\(parent)/\(name)")
                XCTAssertEqual(block("Library/\(parent)/\(name)/Data/x.db", directory: false), .systemData)
            }
        }
        for name in ["group.com.apple.notes", "243LU875E5.groups.com.apple.podcasts",
                     "group.is.workflow.shortcuts", "group.is.workflow.my.app"] {
            XCTAssertEqual(block("Library/Group Containers/" + name), .systemData, name)
        }

        // D54 supplement: these credential stores are listed by name, so a
        // later edit cannot drop one silently.
        for relative in [".git-credentials", ".npmrc", ".pypirc", ".pgpass", ".cargo/credentials.toml",
                         ".config/op", ".password-store", ".terraform.d/credentials.tfrc.json"] {
            XCTAssertTrue(FileAnalysisTrashPolicy.credentialPaths.contains(relative), relative)
        }
        XCTAssertEqual(block(".cargo"), .containsProtectedLocation)
        XCTAssertEqual(block(".terraform.d"), .containsProtectedLocation)
        XCTAssertTrue(FileAnalysisTrashPolicy.credentialFilePaths.contains(".terraform.d/credentials.tfrc.json"))
        XCTAssertFalse(FileAnalysisTrashPolicy.credentialFilePaths.contains(".password-store"))
        for name in ["Reminders", "Shortcuts"] {
            XCTAssertTrue(FileAnalysisTrashPolicy.protectedLibraryFolderNames.contains(name))
            XCTAssertEqual(block("Library/\(name)/store.sqlite", directory: false), .systemData)
        }
        for relative in FileAnalysisTrashPolicy.credentialPaths {
            let isFile = FileAnalysisTrashPolicy.credentialFilePaths.contains(relative)
            XCTAssertEqual(block(relative, directory: !isFile), .credentials, relative)
            if !isFile { XCTAssertEqual(block(relative + "/key", directory: false), .credentials, relative) }
        }

        // Every identity's data folder (release, beta, integration test).
        for relative in ["Library/Application Support/StorageCleanerMac",
                         "Library/Application Support/StorageCleanerMac-Beta",
                         "Library/Caches/StorageCleanerIntegration-qa"] {
            XCTAssertEqual(block(relative), .appData, relative)
            XCTAssertEqual(block(relative + "/CleanupReports/r.json", directory: false), .appData, relative)
        }

        // The reviewer's E15 locations, all checkable before D54.
        for relative in ["Library/Keychains", "Library/Containers", "Library/Group Containers", "Library/Preferences",
                         "Library/Mail", "Library/Messages", "Library/Safari", "Library/Accounts",
                         "Library/Calendars", "Library/Containers/com.apple.mail",
                         "Library/Application Support/StorageCleanerMac", ".ssh"] {
            XCTAssertNotNil(block(relative), relative)
        }
    }

    // ② Not whole, but what is inside follows the rules; ⑤ what holds a
    // protected location is not moved whole either.
    func testLibraryFoldersAndAppContainersAreNotMovedWhole() {
        for name in ["Caches", "Logs", "Developer", "Application Support", "Containers", "Group Containers", "Fonts"] {
            XCTAssertEqual(block("Library/" + name), .libraryFolder, name)
        }
        XCTAssertNil(block("Library/Caches/com.example.tool"), "Inside a Library folder: by the rules")
        XCTAssertNil(block("Library/Developer/Xcode/DerivedData"))
        XCTAssertNil(block("Library/Logs/old.log", directory: false))

        XCTAssertEqual(block("Library/Containers/com.example.tool"), .appContainer)
        XCTAssertEqual(block("Library/Containers/com.example.tool/Data"), .appContainer)
        XCTAssertNil(block("Library/Containers/com.example.tool/Data/Library/Caches"))
        XCTAssertNil(block("Library/Containers/com.example.tool/Data/Documents/a.txt", directory: false))
        XCTAssertEqual(block("Library/Group Containers/UBF8T346G9.Office"), .appContainer)
        XCTAssertNil(block("Library/Group Containers/UBF8T346G9.Office/Cache"))

        XCTAssertEqual(block(".config"), .containsProtectedLocation, "Holds .config/gh and .config/gcloud")
        XCTAssertNil(block(".config/nvim"))
        XCTAssertEqual(block("Library"), .standardFolder, "The Library itself, as before")

        // iPhone backups stay checkable.
        for relative in ["Library/Application Support/MobileSync",
                         "Library/Application Support/MobileSync/Backup",
                         "Library/Application Support/MobileSync/Backup/00008110-001A2B3C4D5E6F78"] {
            XCTAssertNil(block(relative), relative)
        }
    }

    // ③ A folder holding a running app or a mount point.
    func testAFolderHoldingARunningAppOrAMountPointIsNotMovedWhole() {
        let app = home + "/Developer/Build/Products/Debug/Demo.app"
        let mount = home + "/Mounts/Disk"
        let rules = policy(running: [app], mounts: [mount])
        XCTAssertEqual(block("Developer", in: rules), .containsRunningApplication)
        XCTAssertEqual(block("Developer/Build/Products/Debug", in: rules), .containsRunningApplication)
        XCTAssertEqual(block("Developer/Build/Products/Debug/Demo.app", kind: "package", in: rules), .applicationBundle)
        XCTAssertNil(block("Developer/Other", in: rules))
        XCTAssertNil(block("Developer/Build/Products/Debug/notes.txt", directory: false, in: rules))
        XCTAssertEqual(block("Mounts", in: rules), .containsMountPoint)
        XCTAssertNil(block("Mounts/Other", in: rules))
        XCTAssertNil(block("Developer", in: policy()), "Nothing running there")

        // On an external volume too.
        let external = FileAnalysisTrashPolicy(rootPath: "/Volumes/Ext", targetKind: .externalVolume, homePath: home,
                                               appDataPath: home + "/AppData", excludedPaths: [],
                                               runningApplicationPaths: ["/Volumes/Ext/Apps/Tool.app"],
                                               mountPointPaths: ["/Volumes/Ext/Images/Mounted"])
        XCTAssertEqual(external.block(path: "/Volumes/Ext/Apps", name: "Apps", kind: "folder", isDirectory: true,
                                      isEstimated: false), .containsRunningApplication)
        XCTAssertEqual(external.block(path: "/Volumes/Ext/Images", name: "Images", kind: "folder", isDirectory: true,
                                      isEstimated: false), .containsMountPoint)
    }

    func testTheReasonsReadAsShortChinesePhrases() {
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        XCTAssertEqual(FileAnalysisTrashBlock.systemData.shortTitle, "系统数据")
        XCTAssertEqual(FileAnalysisTrashBlock.containsRunningApplication.shortTitle, "含正在运行的应用")
        XCTAssertEqual(FileAnalysisTrashBlock.containsMountPoint.shortTitle, "含挂载点")
        XCTAssertEqual(FileAnalysisTrashBlock.credentials.shortTitle, "密钥与凭据")
        XCTAssertEqual(FileAnalysisTrashBlock.libraryFolder.shortTitle, "资源库文件夹")
        XCTAssertEqual(FileAnalysisTrashBlock.appContainer.shortTitle, "应用容器")
        XCTAssertEqual(FileAnalysisTrashBlock.cloudStorage.shortTitle, "云盘位置")
        XCTAssertEqual(FileAnalysisTrashPresentation.rowNote(state: .blocked(.systemData)), "系统数据")
        for block in [FileAnalysisTrashBlock.systemData, .credentials, .libraryFolder, .appContainer,
                      .cloudStorage, .containsRunningApplication, .containsMountPoint] {
            XCTAssertTrue(FileAnalysisTrashPresentation.checkboxHelp(state: .blocked(block)).contains(block.explanation))
            XCTAssertTrue(FileAnalysisTrashPresentation.reviewBlockNote(block).contains(block.explanation))
            XCTAssertEqual(FileAnalysisTrashPresentation.rowNoteLineLimit(state: .blocked(block)), 1)
        }
        XCTAssertEqual(FileAnalysisTrashPresentation.rowNoteLineLimit(state: .includedInSelection("Old Projects")), 2)
        XCTAssertTrue(FileAnalysisTrashPresentation.checkboxHelp(state: .blocked(.containsRunningApplication))
            .contains("请先退出该应用"))
        XCTAssertEqual(FileAnalysisTrashBlock.containsRunningApplication.skipReason, .relatedAppStillRunning)
        XCTAssertEqual(FileAnalysisTrashBlock.containsMountPoint.skipReason, .containsMountPoint)
    }

    // ③ again in the review and right before the move: what is mounted and
    // what runs is read then, not taken from the analysis.
    func testTheReviewReadsMountPointsAgain() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let analysis = try fixture.analyze()
        let mounted = fixture.url("Media/Mounted").path
        let environment = fixture.environment(mountPointPaths: { [mounted] })
        var policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        policy.mountPointPaths = []  // As read when the analysis ended.
        let review = FileAnalysisTrashService.review(
            [try fixture.selection("Media", in: analysis.index), try fixture.selection("big.zip", in: analysis.index)],
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil
        )
        XCTAssertEqual(review.items.first?.status, .blocked(.containsMountPoint))
        XCTAssertEqual(review.readyItems.map(\.selection.title), ["big.zip"])
    }

    func testAnAppThatStartsInsideAFolderAfterTheReviewKeepsTheFolder() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url("Build/Demo.app/Contents"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_048).write(to: fixture.url("Build/Demo.app/Contents/Demo"))
        let analysis = try fixture.analyze()
        let running = RunningAppsStandIn()
        let environment = fixture.environment(runningApplicationPaths: { running.paths })
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let review = FileAnalysisTrashService.review(
            [try fixture.selection("Build", in: analysis.index), try fixture.selection("big.zip", in: analysis.index)],
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil
        )
        XCTAssertEqual(review.readyItems.count, 2, "Nothing runs at the review")
        running.paths = [fixture.url("Build/Demo.app").path]

        let outcome = await FileAnalysisTrashService.execute(review.items, index: analysis.index,
                                                              policy: policy, environment: environment)

        XCTAssertEqual(outcome.movedPaths, [fixture.url("big.zip").path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("Build/Demo.app/Contents/Demo").path))
        XCTAssertEqual(outcome.skipped.map(\.reason), [FileAnalysisTrashBlock.containsRunningApplication.explanation])
        let report = try XCTUnwrap(try fixture.journal.load().first)
        XCTAssertEqual(report.items.first?.outcome, .skipped(.relatedAppStillRunning))
    }

    // ④ Hard links.
    func testTheReviewSaysWhenAFileHasOtherHardLinks() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        guard link(fixture.url("Media/photo.jpg").path, fixture.base.appendingPathComponent("photo-link.jpg").path) == 0
        else { throw POSIXError(.EIO) }
        let analysis = try fixture.analyze()
        let environment = fixture.environment()
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let review = FileAnalysisTrashService.review(
            try ["Media/photo.jpg", "big.zip", "Media"].map { try fixture.selection($0, in: analysis.index) },
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil
        )
        XCTAssertEqual(review.items.map(\.hasOtherHardLinks), [true, false, false])
        XCTAssertEqual(review.readyItems.count, 3, "A note, not a block")

        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        XCTAssertEqual(FileAnalysisTrashPresentation.otherHardLinksNote, "另有硬链接，移走后空间不一定释放")
        let views = try String(contentsOf: Self.repositoryRoot
            .appendingPathComponent("Sources/StorageCleanerMac/Views/FileAnalysisTrashViews.swift"), encoding: .utf8)
        let row = try XCTUnwrap(views.components(separatedBy: "private struct FileAnalysisTrashReviewRow: View {").last)
        XCTAssertTrue(row.contains("if item.hasOtherHardLinks {"))
        XCTAssertTrue(row.contains("FileAnalysisTrashPresentation.otherHardLinksNote"))
    }

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

/// Stands in for the running apps: the test says which bundles run.
final class RunningAppsStandIn: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [String] = []

    var paths: [String] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
