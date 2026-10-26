import Foundation
import XCTest
@testable import StorageCleanerMac

/// D-FP1：扩展管理。只读列出四类文件夹扩展、内核扩展和 pluginkit 的应用扩展；
/// 只有当前用户“资源库”里的包能移到废纸篓，并在移动前逐项复核。
final class ExtensionManagerTests: XCTestCase {
    // MARK: pluginkit

    func testPluginKitOutputIsParsedIntoRecordsWithElections() {
        let output = """
             com.apple.Photos.PhotosReliveWidget(1.0)
        \t            Path = /System/Applications/Photos.app/Contents/PlugIns/PhotosReliveWidget.appex
        \t             SDK = com.apple.widgetkit-extension
        \t   Parent Bundle = /System/Applications/Photos.app
        \t    Display Name = PhotosReliveWidget
        \t     Parent Name = Photos

        +    com.example.Notes.ShareExtension(2.4)
        \t            Path = /Applications/Notes Pro.app/Contents/PlugIns/Share.appex
        \t             SDK = com.apple.share-services
        \t   Parent Bundle = /Applications/Notes Pro.app
        \t    Display Name = Share to Notes Pro
        \t     Parent Name = Notes Pro

        -    com.example.Blocker.Content((null))
        \t            Path = /Applications/Blocker.app/Contents/PlugIns/Content.appex
        \t             SDK = com.apple.Safari.content-blocker
        \t   Parent Bundle = /Applications/Blocker.app

             com.example.broken(1.0)
        \t             SDK = com.apple.widgetkit-extension
        """
        let records = PluginKitListing.parse(output)
        XCTAssertEqual(records.count, 3, "没有 Path 的记录不列出")
        XCTAssertEqual(records[0].identifier, "com.apple.Photos.PhotosReliveWidget")
        XCTAssertTrue(records[0].isApple)
        XCTAssertEqual(records[0].election, .automatic)
        XCTAssertEqual(records[1].identifier, "com.example.Notes.ShareExtension")
        XCTAssertEqual(records[1].version, "2.4")
        XCTAssertEqual(records[1].election, .enabled)
        XCTAssertEqual(records[1].displayName, "Share to Notes Pro")
        XCTAssertEqual(records[1].parentName, "Notes Pro")
        XCTAssertFalse(records[1].isApple)
        XCTAssertEqual(records[2].version, nil, "(null) 版本按没有版本处理")
        XCTAssertEqual(records[2].election, .disabled)

        let safari = ExtensionInventoryScanner.item(for: records[2])
        XCTAssertEqual(safari.kind, .safariExtension)
        XCTAssertEqual(safari.management, .safariSettings)
        XCTAssertEqual(safari.parentName, "Blocker", "没有 Parent Name 时用宿主应用的文件名")
        let share = ExtensionInventoryScanner.item(for: records[1])
        XCTAssertEqual(share.kind, .appExtension)
        XCTAssertEqual(share.management, .withParentApplication("Notes Pro"))
        XCTAssertFalse(share.management.isMovable)
    }

    func testDeveloperNameIsReadFromTheCertificateSubject() {
        XCTAssertEqual(ExtensionSigningReader.developerName(fromSubject: "Developer ID Application: Example Ltd (ABCDE12345)"),
                       "Example Ltd")
        XCTAssertEqual(ExtensionSigningReader.developerName(fromSubject: "Apple Development: Someone (XYZ)"), "Someone")
        XCTAssertEqual(ExtensionSigningReader.developerName(fromSubject: "Plain Name"), "Plain Name")
        XCTAssertNil(ExtensionSigningReader.developerName(fromSubject: "Developer ID Application:  (ABCDE12345)"))
    }

    // MARK: Folder bundles

    func testScannerListsFolderBundlesWithManagementAndObsolescence() async throws {
        let fixture = try ExtensionFixture()
        defer { fixture.remove() }
        try fixture.bundle("PreferencePanes/SignedTool.prefPane", in: fixture.userLibrary,
                           info: ["CFBundleIdentifier": "com.example.tool.pane", "NSPrefPaneIconLabel": "Tool\nSettings",
                                  "CFBundleShortVersionString": "3.1"])
        try fixture.bundle("QuickLook/Markdown.qlgenerator", in: fixture.userLibrary,
                           info: ["CFBundleIdentifier": "com.example.qlmarkdown", "CFBundleName": "QLMarkdown"])
        try fixture.bundle("Internet Plug-Ins/JavaApplet.plugin", in: fixture.localLibrary,
                           info: ["CFBundleIdentifier": "com.example.java"])
        try fixture.bundle("Spotlight/Notes.mdimporter", in: fixture.userLibrary, info: [:])
        try fixture.bundle("Extensions/Vendor.kext", in: fixture.localLibrary, info: ["CFBundleIdentifier": "com.vendor.driver"])
        try fixture.bundle("Extensions/AppleThing.kext", in: fixture.localLibrary, info: ["CFBundleIdentifier": "com.apple.thing"])
        try fixture.bundle("Audio/Plug-Ins/VST3/Synth.vst3", in: fixture.userLibrary, info: ["CFBundleName": "Synth"])
        // 不是该类扩展名的文件、隐藏文件都不列出。
        try Data("x".utf8).write(to: fixture.userLibrary.appendingPathComponent("PreferencePanes/readme.txt"))
        try Data("x".utf8).write(to: fixture.userLibrary.appendingPathComponent("PreferencePanes/.hidden.prefPane"))
        // 指向别处的链接：列出，但不可移动。
        try FileManager.default.createSymbolicLink(
            at: fixture.userLibrary.appendingPathComponent("QuickLook/Linked.qlgenerator"),
            withDestinationURL: fixture.userLibrary.appendingPathComponent("QuickLook/Markdown.qlgenerator"))

        let records = [
            PluginKitRecord(identifier: "com.example.Notes.Share", version: "1", election: .enabled,
                            path: "/Applications/Notes.app/Contents/PlugIns/Share.appex",
                            extensionPoint: "com.apple.share-services", parentPath: "/Applications/Notes.app",
                            parentName: "Notes", displayName: "Share"),
            PluginKitRecord(identifier: "com.apple.widget", version: "1", election: .automatic,
                            path: "/System/Applications/Clock.app/Contents/PlugIns/W.appex",
                            extensionPoint: "com.apple.widgetkit-extension", parentPath: nil, parentName: nil, displayName: nil),
        ]
        let inventory = await fixture.scanner(osMajor: 26, records: records).scan()

        let pane = try XCTUnwrap(inventory.items.first { $0.kind == .preferencePane })
        XCTAssertEqual(pane.name, "Tool Settings", "偏好设置面板用系统设置里显示的名字，换行合成空格")
        XCTAssertEqual(pane.version, "3.1")
        XCTAssertEqual(pane.domain, .user)
        XCTAssertEqual(pane.management, .movableToTrash)
        XCTAssertEqual(pane.signing, .developer(teamID: "ABCDE12345", name: "Example Ltd"))
        XCTAssertNotNil(pane.identity)
        XCTAssertGreaterThan(pane.bytes, 0)
        XCTAssertEqual(inventory.items(of: .preferencePane).count, 1, "txt 和隐藏文件不列出")

        let quickLook = inventory.items(of: .quickLookGenerator)
        XCTAssertEqual(quickLook.count, 2)
        XCTAssertEqual(quickLook.map(\.name), ["QLMarkdown", "QLMarkdown"], "链接按目标的名字显示")
        XCTAssertTrue(quickLook.allSatisfy { $0.obsolescence == .quickLookGeneratorsRetired })
        let link = try XCTUnwrap(quickLook.first { $0.isSymbolicLink })
        XCTAssertEqual(link.management, .symbolicLink)
        XCTAssertEqual(link.bytes, 0, "链接不按目标计大小")

        let java = try XCTUnwrap(inventory.items.first { $0.kind == .internetPlugin })
        XCTAssertEqual(java.domain, .local)
        XCTAssertEqual(java.management, .administratorLocation, "“/资源库”里的只列出")
        XCTAssertEqual(java.obsolescence, .npapiRetired)

        let kernels = inventory.items(of: .kernelExtension)
        XCTAssertEqual(kernels.map(\.bundleIdentifier), ["com.vendor.driver"], "Apple 的内核扩展只计数")
        XCTAssertEqual(kernels.first?.management, .systemSettingsApproval)
        XCTAssertEqual(inventory.items(of: .audioPlugin).first?.name, "Synth")
        XCTAssertEqual(inventory.items(of: .spotlightImporter).first?.name, "Notes", "没有名字时用文件名")

        XCTAssertEqual(inventory.items(of: .appExtension).map(\.name), ["Share"])
        XCTAssertEqual(inventory.hiddenAppleExtensionCount, 2, "Apple 的应用扩展和内核扩展各一个")
        XCTAssertTrue(inventory.pluginKitAvailable)

        let summary = inventory.summary
        XCTAssertEqual(summary.movableCount, inventory.items.filter { $0.management == .movableToTrash }.count)
        XCTAssertEqual(summary.movableCount, 4, "面板、Markdown 预览、导入器、VST3")
        XCTAssertEqual(summary.obsoleteCount, 3, "两个快速查看（含链接）和一个互联网插件")
    }

    func testQuickLookGeneratorsCountAsObsoleteOnlyFromMacOS15() async throws {
        let fixture = try ExtensionFixture()
        defer { fixture.remove() }
        try fixture.bundle("QuickLook/Old.qlgenerator", in: fixture.userLibrary, info: [:])
        let older = await fixture.scanner(osMajor: 14, records: nil).scan()
        XCTAssertNil(older.items.first?.obsolescence)
        XCTAssertFalse(older.pluginKitAvailable, "pluginkit 读不到时如实标记，不当作没有")
        let newer = await fixture.scanner(osMajor: 15, records: []).scan()
        XCTAssertEqual(newer.items.first?.obsolescence, .quickLookGeneratorsRetired)
    }

    // MARK: Removal

    func testRemovalMovesUserBundlesAndRecordsThem() async throws {
        let fixture = try ExtensionFixture()
        defer { fixture.remove() }
        try fixture.bundle("Spotlight/Notes.mdimporter", in: fixture.userLibrary, info: [:])
        try fixture.bundle("Internet Plug-Ins/Old.plugin", in: fixture.localLibrary, info: [:])
        let inventory = await fixture.scanner(osMajor: 26, records: []).scan()
        let reports = ReportBox()

        let outcome = await ExtensionRemovalService.execute(inventory.items, environment: fixture.environment(reports: reports))

        XCTAssertEqual(outcome.removed.map(\.name), ["Notes"])
        XCTAssertGreaterThan(outcome.removedBytes, 0)
        XCTAssertEqual(outcome.kept.map(\.name), ["Old"], "“/资源库”里的保留，并说明原因")
        XCTAssertEqual(outcome.kept.first?.note, ExtensionManagement.administratorLocation.note)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.userLibrary.appendingPathComponent("Spotlight/Notes.mdimporter").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.localLibrary.appendingPathComponent("Internet Plug-Ins/Old.plugin").path))
        let report = try XCTUnwrap(reports.last)
        XCTAssertEqual(report.rulesVersion, ExtensionRemovalService.ruleID)
        XCTAssertEqual(report.summary.movedItemCount, 1)
        let authorization = try XCTUnwrap(report.restoreAuthorizations?.values.first)
        XCTAssertEqual(authorization.allowedRootPath, fixture.userLibrary.appendingPathComponent("Spotlight").path,
                       "放回时只能回到原来的文件夹")
    }

    func testPreferencePaneIsKeptWhileSystemSettingsRuns() async throws {
        let fixture = try ExtensionFixture()
        defer { fixture.remove() }
        try fixture.bundle("PreferencePanes/Tool.prefPane", in: fixture.userLibrary, info: [:])
        let inventory = await fixture.scanner(osMajor: 26, records: []).scan()

        let outcome = await ExtensionRemovalService.execute(
            inventory.items,
            environment: fixture.environment(reports: ReportBox(), running: [ExtensionRemovalService.systemSettingsBundleIdentifier]))

        XCTAssertTrue(outcome.removed.isEmpty)
        XCTAssertEqual(outcome.kept.first?.note, ExtensionRemovalService.describe(.relatedAppStillRunning))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.userLibrary.appendingPathComponent("PreferencePanes/Tool.prefPane").path))
    }

    func testBundleReplacedAfterTheScanIsKept() async throws {
        let fixture = try ExtensionFixture()
        defer { fixture.remove() }
        let url = try fixture.bundle("Screen Savers/Waves.saver", in: fixture.userLibrary, info: [:])
        let inventory = await fixture.scanner(osMajor: 26, records: []).scan()
        try FileManager.default.removeItem(at: url)
        try fixture.bundle("Screen Savers/Waves.saver", in: fixture.userLibrary, info: [:])

        let outcome = await ExtensionRemovalService.execute(inventory.items, environment: fixture.environment(reports: ReportBox()))

        XCTAssertTrue(outcome.removed.isEmpty, "扫描后被替换的包不移动")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testOnlyDirectChildrenOfTheKindsOwnUserFolderAreMovable() throws {
        let fixture = try ExtensionFixture()
        defer { fixture.remove() }
        let environment = fixture.environment(reports: ReportBox())
        func item(_ path: String, kind: ExtensionKind, domain: ExtensionDomain = .user) -> ExtensionItem {
            ExtensionItem(kind: kind, path: path, name: "x", bundleIdentifier: nil, version: nil, domain: domain,
                          bytes: 1, sizeIsLowerBound: false, signing: .unsigned, parentName: nil, parentPath: nil,
                          election: nil, extensionPoint: nil, obsolescence: nil, isSymbolicLink: false,
                          identity: FileIdentity(deviceID: 1, inode: 1, entryKind: .directory, creationTimeNanoseconds: nil),
                          modified: nil, management: .movableToTrash)
        }
        let library = fixture.userLibrary.path
        XCTAssertTrue(ExtensionRemovalService.isDirectChildOfOwnFolder(
            item(library + "/PreferencePanes/A.prefPane", kind: .preferencePane), environment: environment))
        XCTAssertFalse(ExtensionRemovalService.isDirectChildOfOwnFolder(
            item(library + "/PreferencePanes/Nested/A.prefPane", kind: .preferencePane), environment: environment))
        XCTAssertFalse(ExtensionRemovalService.isDirectChildOfOwnFolder(
            item(library + "/QuickLook/A.prefPane", kind: .preferencePane), environment: environment),
            "别的类别的文件夹不行")
        XCTAssertFalse(ExtensionRemovalService.isDirectChildOfOwnFolder(
            item(library + "/PreferencePanes/../Preferences/A.prefPane", kind: .preferencePane), environment: environment))
        XCTAssertFalse(ExtensionRemovalService.isDirectChildOfOwnFolder(
            item(library + "/PreferencePanes/A.plist", kind: .preferencePane), environment: environment))
        XCTAssertFalse(ExtensionRemovalService.isDirectChildOfOwnFolder(
            item(library + "/Audio/Plug-Ins/VST3/A.vst3", kind: .audioPlugin, domain: .local), environment: environment))
        XCTAssertTrue(ExtensionRemovalService.isDirectChildOfOwnFolder(
            item(library + "/Audio/Plug-Ins/VST3/A.vst3", kind: .audioPlugin), environment: environment))
    }

    func testOperationHistoryNamesExtensionReceipts() {
        XCTAssertEqual(ToolboxOperationTitles.subject(rulesVersion: ExtensionRemovalService.ruleID,
                                                      firstSourcePath: "/Users/a/Library/PreferencePanes/Tool.prefPane"),
                       "Tool")
        let title = OperationRecordPresentation.title(rulesVersion: ExtensionRemovalService.ruleID, subject: "Tool", itemCount: 3)
        XCTAssertTrue(title.contains("Tool"))
        XCTAssertNotEqual(title, "Tool", "带上“扩展”前缀和数量")
        XCTAssertNil(ToolboxOperationTitles.subject(rulesVersion: "cleanup.v2", firstSourcePath: "/x/y.app"))
    }

    // MARK: Store

    @MainActor
    func testStoreSelectsOnlyMovableRowsAndRescansAfterRemoval() async throws {
        let fixture = try ExtensionFixture()
        defer { fixture.remove() }
        try fixture.bundle("QuickLook/Old.qlgenerator", in: fixture.userLibrary, info: [:])
        try fixture.bundle("Spotlight/Keep.mdimporter", in: fixture.userLibrary, info: [:])
        try fixture.bundle("PreferencePanes/Shared.prefPane", in: fixture.localLibrary, info: [:])
        let store = ExtensionManagerStore(coordinator: HeavyWorkCoordinator(),
                                          scanner: fixture.scanner(osMajor: 26, records: []),
                                          environment: fixture.environment(reports: ReportBox()),
                                          openURL: { _ in })
        store.scan()
        try await waitUntil { store.phase == .ready }
        let shared = try XCTUnwrap(store.inventory?.items.first { $0.domain == .local })
        store.toggle(shared)
        XCTAssertTrue(store.selection.isEmpty, "只列出的项不能选")
        store.selectObsolete()
        XCTAssertEqual(store.selectedItems.map(\.name), ["Old"])

        store.removeSelected()
        try await waitUntil { store.outcome != nil && store.phase == .ready }
        XCTAssertEqual(store.outcome?.removed.map(\.name), ["Old"])
        XCTAssertTrue(store.selection.isEmpty)
        XCTAssertNil(store.inventory?.items.first { $0.name == "Old" }, "移走后重新列出")
        XCTAssertNotNil(store.inventory?.items.first { $0.name == "Keep" })
    }

    @MainActor
    func testStoreReportsABusyLeaseInsteadOfMoving() async throws {
        let fixture = try ExtensionFixture()
        defer { fixture.remove() }
        try fixture.bundle("QuickLook/Old.qlgenerator", in: fixture.userLibrary, info: [:])
        let coordinator = HeavyWorkCoordinator()
        let lease = try await coordinator.acquire(owner: .mainScan)
        let store = ExtensionManagerStore(coordinator: coordinator, scanner: fixture.scanner(osMajor: 26, records: []),
                                          environment: fixture.environment(reports: ReportBox()), openURL: { _ in })
        store.scan()
        try await waitUntil { store.phase == .ready }
        store.selectObsolete()
        store.removeSelected()
        try await waitUntil { store.errorMessage != nil }
        XCTAssertEqual(store.errorMessage, HeavyWorkActivityStore.conflictMessage(activeOwner: .mainScan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.userLibrary.appendingPathComponent("QuickLook/Old.qlgenerator").path))
        await coordinator.release(lease)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("等待超时"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [CleanReport] = []
    func append(_ report: CleanReport) { lock.lock(); reports.append(report); lock.unlock() }
    var last: CleanReport? { lock.lock(); defer { lock.unlock() }; return reports.last }
}

struct ExtensionFixture {
    let base: URL
    var home: URL { base.appendingPathComponent("home", isDirectory: true) }
    var userLibrary: URL { home.appendingPathComponent("Library", isDirectory: true) }
    var localLibrary: URL { base.appendingPathComponent("Library", isDirectory: true) }
    var trash: URL { base.appendingPathComponent("Trash", isDirectory: true) }

    init() throws {
        // 文件操作夹具不放系统临时目录（/var 是链接，复核会拒绝）。
        base = TestFileSystem.uniqueOperationRoot("extension-manager")
        let manager = FileManager.default
        do {
            for folder in ["home/Library/PreferencePanes", "home/Library/QuickLook", "home/Library/Spotlight",
                           "home/Library/Screen Savers", "home/Library/Audio/Plug-Ins/VST3", "Library/Internet Plug-Ins",
                           "Library/PreferencePanes", "Library/Extensions", "Trash"] {
                try manager.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
        } catch {
            TestFileSystem.remove(base)
            throw error
        }
    }

    @discardableResult
    func bundle(_ relative: String, in library: URL, info: [String: Any], payloadBytes: Int = 8_192) throws -> URL {
        let url = library.appendingPathComponent(relative, isDirectory: true)
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data(repeating: 0x42, count: payloadBytes).write(to: contents.appendingPathComponent("MacOS/payload"))
        return url
    }

    func scanner(osMajor: Int, records: [PluginKitRecord]?) -> ExtensionInventoryScanner {
        var scanner = ExtensionInventoryScanner()
        scanner.roots = .init(userLibrary: userLibrary, localLibrary: localLibrary)
        scanner.homePath = home.path
        scanner.operatingSystemMajorVersion = osMajor
        scanner.signing = { url in
            url.lastPathComponent.hasPrefix("Signed") ? .developer(teamID: "ABCDE12345", name: "Example Ltd") : .unsigned
        }
        scanner.pluginKit = { records }
        return scanner
    }

    func environment(reports: ReportBox, running: Set<String> = []) -> ExtensionRemovalEnvironment {
        var environment = ExtensionRemovalEnvironment()
        environment.roots = .init(userLibrary: userLibrary, localLibrary: localLibrary)
        environment.homePath = home.path
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
