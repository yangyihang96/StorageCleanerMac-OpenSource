import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class FileAnalysisTrashRunningApplicationTests: XCTestCase {
    /// 第 4 轮 P1-1：复核中的四种真实包写法均不可选、不可进入审阅。
    /// 强制旧的非应用判定后也要挡住，用来独立锁定包自身的运行中规则。
    func testRunningBundlesStayBlockedRegardlessOfPackageTypeOrProbeResult() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let examples: [(String, String?)] = [("Browser", "FNDR"), ("Client", "AAPL"),
                                             ("Plugin", "BNDL"), ("Viewer", nil)]
        let paths = examples.map { fixture.url("Tools/\($0.0).app").path }
        for (name, type) in examples {
            let contents = fixture.url("Tools/\(name).app/Contents")
            try manager.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": "com.example." + name]
            if let type {
                info["CFBundlePackageType"] = type
                info["CFBundleExecutable"] = name
            }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: contents.appendingPathComponent("MacOS/" + name))
            XCTAssertTrue(FileAnalysisApplicationBundleProbe.isApplication(atPath: fixture.url("Tools/\(name).app").path),
                          "未设置运行中状态时，\(type ?? "无类型") 也须按可执行文件判为应用")
        }
        let analysis = try fixture.analyze()
        let environment = fixture.environment(runningApplicationPaths: { paths })
        var policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        policy.runningApplicationPaths = paths
        policy.nonApplicationBundlePaths.formUnion(paths)
        let selections = try examples.map { try fixture.selection("Tools/\($0.0).app", in: analysis.index) }
        for selection in selections {
            XCTAssertEqual(policy.block(path: selection.path, name: selection.title, kind: "package",
                                         isDirectory: true, isEstimated: false), .applicationBundle, selection.title)
        }
        XCTAssertEqual(policy.block(path: fixture.url("Tools").path, name: "Tools", kind: "folder",
                                     isDirectory: true, isEstimated: false), .containsRunningApplication)
        let review = FileAnalysisTrashService.review(selections, index: analysis.index, policy: policy,
                                                     environment: environment, externalVolumeName: nil)
        XCTAssertTrue(review.readyItems.isEmpty)
        for item in review.items { XCTAssertEqual(item.status, .blocked(.applicationBundle), item.selection.title) }

        let coordinator = HeavyWorkCoordinator()
        let store = LargeFilesStore(coordinator: coordinator, activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            defaults: TestPreferenceDomain.make(for: self), storageMapTargets: [], trashEnvironment: environment)
        store.replaceStorageAnalysisForTesting(analysis)
        let deadline = Date().addingTimeInterval(15)
        while store.trashPolicy?.isRefined != true {
            guard Date() < deadline else { XCTFail("等待规则超时"); throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: fixture.url("Tools").path, using: analysis.index)
        for path in paths {
            let row = try XCTUnwrap(snapshot.entries.first { $0.path == path })
            XCTAssertEqual(row.contentCategory, .application, row.title)
            XCTAssertEqual(store.trashSelectionState(for: row), .blocked(.applicationBundle), row.title)
            store.toggleTrashSelection(row)
        }
        XCTAssertTrue(store.trashSelections.isEmpty)
        XCTAssertFalse(store.canReviewTrash)
        let zip = try XCTUnwrap(store.currentStorageMapSnapshot?.entries.first { $0.title == "big.zip" })
        store.toggleTrashSelection(zip)
        store.requestTrashReview()
        let reviewDeadline = Date().addingTimeInterval(15)
        while store.trashPhase != .reviewing {
            guard Date() < reviewDeadline else { XCTFail("等待审阅超时"); throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.trashReview?.readyItems.map(\.selection.title), ["big.zip"])
        XCTAssertEqual(store.trashReview?.items.count, 1, "运行中的应用不出现在用户审阅列表")
        store.cancelTrashReview()
    }

    func testTranslocatedAppsProtectTheirOriginalFoldersAndKeepTheirRuntimePaths() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let runtime = "/private/var/folders/fixture/AppTranslocation/id/d/Demo.app"
        let original = fixture.url("Build/Demo.app").path
        var environment = fixture.environment(runningApplicationPaths: { [runtime] })
        environment.originalRunningApplicationURL = { url in
            url.path == runtime ? URL(fileURLWithPath: original) : nil
        }
        let running = environment.runningApplicationState()
        XCTAssertTrue(running.isKnown)
        XCTAssertEqual(Set(running.paths), Set([runtime, original]))
        let policy = FileAnalysisTrashPolicy(rootPath: fixture.root.path, targetKind: .homeDirectory,
            homePath: fixture.root.path, appDataPath: fixture.base.appendingPathComponent("AppData").path,
            excludedPaths: [], runningApplicationPaths: running.paths)
        XCTAssertEqual(policy.block(path: fixture.url("Build").path, name: "Build", kind: "folder",
                                    isDirectory: true, isEstimated: false), .containsRunningApplication)
        XCTAssertNil(policy.block(path: fixture.url("Docs").path, name: "Docs", kind: "folder",
                                  isDirectory: true, isEstimated: false))
    }

    func testFailedOriginalPathResolutionFailsClosedForFoldersButLeavesFilesAvailable() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let runtime = "/private/var/folders/fixture/AppTranslocation/id/d/Demo.app"
        var environment = fixture.environment(runningApplicationPaths: { [runtime] })
        environment.originalRunningApplicationURL = { _ in nil }
        let running = environment.runningApplicationState()
        XCTAssertFalse(running.isKnown)
        XCTAssertEqual(running.unknownApplicationNames, ["Demo"])
        XCTAssertEqual(running.paths, [runtime], "失败不能丢掉已知运行路径")
        var policy = FileAnalysisTrashPolicy(rootPath: fixture.root.path, targetKind: .homeDirectory,
            homePath: fixture.root.path, appDataPath: fixture.base.appendingPathComponent("AppData").path,
            excludedPaths: [], runningApplicationPaths: running.paths)
        policy.unknownRunningApplicationNames = running.unknownApplicationNames
        XCTAssertEqual(policy.block(path: fixture.url("Docs").path, name: "Docs", kind: "folder",
                                    isDirectory: true, isEstimated: false), .runningApplicationStateUnknown)
        XCTAssertNil(policy.block(path: fixture.url("big.zip").path, name: "big.zip", kind: "file",
                                  isDirectory: false, isEstimated: false))
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        XCTAssertTrue(FileAnalysisTrashBlock.runningApplicationStateUnknown.explanation.contains("原始位置"))
        let named = FileAnalysisTrashBlock.runningApplicationStateUnknown.explanation(naming: running.unknownApplicationNames)
        XCTAssertTrue(named.contains("无法确认“Demo”的原始位置"), named)
        XCTAssertTrue(named.contains("请退出“Demo”后重试"), named)
        XCTAssertEqual(FileAnalysisTrashBlock.containsMountPoint.explanation(naming: ["Demo"]),
                       FileAnalysisTrashBlock.containsMountPoint.explanation, "Only this reason names apps")
    }

    func testTheStoreUsesOriginalPathsAndPrunesASelectionWhenATranslocatedAppStarts() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url("Build"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: fixture.url("Build/file.bin"))
        let runtime = "/private/var/folders/fixture/AppTranslocation/id/d/Demo.app"
        let original = fixture.url("Build/Demo.app").path
        let apps = RunningAppsStandIn()
        var environment = fixture.environment(runningApplicationPaths: { apps.paths })
        environment.originalRunningApplicationURL = { _ in URL(fileURLWithPath: original) }
        let coordinator = HeavyWorkCoordinator()
        let store = LargeFilesStore(coordinator: coordinator, activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            defaults: try temporaryDefaults(),
            storageMapTargets: [], trashEnvironment: environment)
        store.replaceStorageAnalysisForTesting(try fixture.analyze())
        // P1-1: the rules are complete once the links are found off the main thread.
        for _ in 0..<1_500 where store.trashPolicy?.isRefined != true { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.trashPolicy?.isRefined, true)
        let build = try XCTUnwrap(store.currentStorageMapSnapshot?.entries.first { $0.title == "Build" })
        let zip = try XCTUnwrap(store.currentStorageMapSnapshot?.entries.first { $0.title == "big.zip" })
        store.toggleTrashSelection(build)
        XCTAssertEqual(store.trashSelections.map(\.title), ["Build"])
        apps.paths = [runtime]
        store.toggleTrashSelection(zip)
        XCTAssertEqual(store.trashSelectionState(for: build), .blocked(.containsRunningApplication))
        XCTAssertEqual(store.trashSelections.map(\.title), ["big.zip"])
    }

    func testAnAppTranslocatedAfterReviewIsCaughtBeforeMoveAndRecordedAsRunning() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url("Build/Demo.app/Contents"),
                                                withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: fixture.url("Build/Demo.app/Contents/Info.plist"))
        let apps = RunningAppsStandIn()
        let runtime = "/private/var/folders/fixture/AppTranslocation/id/d/Demo.app"
        let original = fixture.url("Build/Demo.app").path
        var environment = fixture.environment(runningApplicationPaths: { apps.paths })
        environment.originalRunningApplicationURL = { url in
            url.path == runtime ? URL(fileURLWithPath: original) : nil
        }
        let analysis = try fixture.analyze()
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let review = FileAnalysisTrashService.review(
            [try fixture.selection("Build", in: analysis.index), try fixture.selection("big.zip", in: analysis.index)],
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil)
        XCTAssertEqual(review.readyItems.count, 2)
        apps.paths = [runtime]
        let outcome = await FileAnalysisTrashService.execute(review.items, index: analysis.index,
                                                              policy: policy, environment: environment)
        XCTAssertEqual(outcome.movedPaths, [fixture.url("big.zip").path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original))
        let report = try XCTUnwrap(try fixture.journal.load().first)
        XCTAssertEqual(report.items.first?.outcome, .skipped(.relatedAppStillRunning))
    }

    func testUntranslocatedAppsKeepTheirPathsAndAnEmptyListDoesNotNeedTheResolver() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let original = fixture.url("Build/Demo.app").path
        let environment = fixture.environment(runningApplicationPaths: { [original] })
        XCTAssertEqual(environment.runningApplicationState(), FileAnalysisRunningApplicationState(paths: [original]))
        var empty = fixture.environment()
        empty.originalRunningApplicationURL = { _ in nil }
        XCTAssertEqual(empty.runningApplicationState(), FileAnalysisRunningApplicationState(paths: []))
        XCTAssertTrue(empty.runningApplicationState().isKnown)
    }

    /// r2-fa-followups P2-2: an app still running after its bundle was moved
    /// or deleted is not translocated: its own path is its original path, and
    /// nothing becomes unknown. Uses the real Security lookup (read-only, on
    /// a path that does not exist; no app is started).
    func testARunningAppWhoseBundleIsGoneIsMatchedByItsOwnPath() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url("Build"), withIntermediateDirectories: true)
        let gone = fixture.url("Build/Gone.app").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone))
        XCTAssertEqual(FileAnalysisRunningApplicationResolver.originalURL(for: URL(fileURLWithPath: gone))?.path, gone)

        var environment = fixture.environment(runningApplicationPaths: { [gone] })
        environment.originalRunningApplicationURL = { FileAnalysisRunningApplicationResolver.originalURL(for: $0) }
        let running = environment.runningApplicationState()
        XCTAssertTrue(running.isKnown)
        XCTAssertEqual(running.paths, [gone])
        // Even a lookup that fails outright leaves an app outside a
        // translocation mount known by its own path.
        environment.originalRunningApplicationURL = { _ in nil }
        XCTAssertEqual(environment.runningApplicationState().paths, [gone])
        XCTAssertTrue(environment.runningApplicationState().isKnown)

        let policy = FileAnalysisTrashPolicy(rootPath: fixture.root.path, targetKind: .homeDirectory,
            homePath: fixture.base.path, appDataPath: fixture.base.appendingPathComponent("AppData").path,
            excludedPaths: [], runningApplicationPaths: running.paths)
        XCTAssertEqual(policy.block(path: fixture.url("Build").path, name: "Build", kind: "folder",
                                    isDirectory: true, isEstimated: false), .containsRunningApplication)
        XCTAssertNil(policy.block(path: fixture.url("Docs").path, name: "Docs", kind: "folder",
                                  isDirectory: true, isEstimated: false), "Other folders stay checkable")
    }

    /// P2-2: the real lookup leaves an app on a translocation mount unknown
    /// when it cannot restore its original path (read-only; the path does
    /// not exist and nothing is started), and keeps an ordinary app's path.
    func testTheRealLookupLeavesOnlyAnUnrestorableTranslocatedAppUnknown() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let ghost = fixture.base.appendingPathComponent("AppTranslocation/\(UUID().uuidString)/d/Ghost.app").path
        XCTAssertTrue(FileAnalysisRunningApplicationResolver.isInTranslocationMount(ghost))
        XCTAssertNil(FileAnalysisRunningApplicationResolver.originalURL(for: URL(fileURLWithPath: ghost)))
        XCTAssertEqual(FileAnalysisRunningApplicationResolver.applicationName(forBundlePath: ghost), "Ghost")
        let ordinary = fixture.url("Tool.app").path
        XCTAssertEqual(FileAnalysisRunningApplicationResolver.originalURL(for: URL(fileURLWithPath: ordinary))?.path,
                       ordinary)
        for path in ["/Applications/AppTranslocation.app", "/Users/fixture/AppTranslocation/Tool.app", ordinary] {
            XCTAssertFalse(FileAnalysisRunningApplicationResolver.isInTranslocationMount(path), path)
        }
    }

    /// P2-2: while a translocated app's original location is unknown, the
    /// hint names it: on hover, on a click, in the review and in what the
    /// move kept. Files are not affected.
    func testTheReasonNamesTheAppWhoseOriginalLocationIsUnknown() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let runtime = "/private/var/folders/zz/fixture/T/AppTranslocation/0F1E2D3C/d/Demo.app"
        let apps = RunningAppsStandIn()
        var environment = fixture.environment(runningApplicationPaths: { apps.paths })
        environment.originalRunningApplicationURL = { _ in nil }
        let coordinator = HeavyWorkCoordinator()
        let store = LargeFilesStore(coordinator: coordinator, activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            defaults: try temporaryDefaults(), storageMapTargets: [], trashEnvironment: environment)
        let analysis = try fixture.analyze()
        store.replaceStorageAnalysisForTesting(analysis)
        for _ in 0..<1_500 where store.trashPolicy?.isRefined != true { try await Task.sleep(for: .milliseconds(10)) }
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        let docs = try XCTUnwrap(store.currentStorageMapSnapshot?.entries.first { $0.title == "Docs" })
        let zip = try XCTUnwrap(store.currentStorageMapSnapshot?.entries.first { $0.title == "big.zip" })
        XCTAssertEqual(store.trashSelectionState(for: docs), .available)

        apps.paths = [runtime]
        store.toggleTrashSelection(zip)
        XCTAssertEqual(store.trashSelectionState(for: zip), .selected, "Files are not affected")
        let state = store.trashSelectionState(for: docs)
        XCTAssertEqual(state, .blocked(.runningApplicationStateUnknown, applications: ["Demo"]))
        XCTAssertTrue(FileAnalysisTrashPresentation.checkboxHelp(state: state).contains("请退出“Demo”后重试"))
        store.toggleTrashSelection(docs)
        XCTAssertEqual(store.trashNotice?.contains("无法确认“Demo”的原始位置"), true, store.trashNotice ?? "")

        var policy = try XCTUnwrap(store.trashPolicy)
        let review = FileAnalysisTrashService.review(
            [try fixture.selection("Docs", in: analysis.index), try fixture.selection("big.zip", in: analysis.index)],
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil)
        XCTAssertEqual(review.items.first?.status, .blocked(.runningApplicationStateUnknown))
        XCTAssertEqual(review.unknownRunningApplicationNames, ["Demo"])
        XCTAssertTrue(FileAnalysisTrashPresentation.reviewBlockNote(
            .runningApplicationStateUnknown, applications: review.unknownRunningApplicationNames).contains("“Demo”"))

        // Reviewed while nothing was unknown, then the app starts: the folder
        // is kept, and what the page says names the app.
        apps.paths = []
        policy.unknownRunningApplicationNames = []
        let ready = FileAnalysisTrashService.review(
            [try fixture.selection("Media", in: analysis.index), try fixture.selection("big.zip", in: analysis.index)],
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil)
        XCTAssertEqual(ready.readyItems.count, 2)
        apps.paths = [runtime]
        let outcome = await FileAnalysisTrashService.execute(ready.items, index: analysis.index,
                                                              policy: policy, environment: environment)
        XCTAssertEqual(outcome.movedPaths, [fixture.url("big.zip").path])
        XCTAssertEqual(outcome.skipped.map(\.reason),
                       [FileAnalysisTrashBlock.runningApplicationStateUnknown.explanation(naming: ["Demo"])])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("Media/photo.jpg").path))
    }

    /// D48: a temporary absolute-path domain, removed with its folder after the test.
    private func temporaryDefaults() throws -> UserDefaults {
        TestPreferenceDomain.make(for: self)
    }
}
