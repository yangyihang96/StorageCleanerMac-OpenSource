import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

final class FileAnalysisApplicationBundleCandidateTests: XCTestCase {
    @MainActor
    func testRootExecutableIsBlockedByProbeSelectionAndReview() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let bundle = try makeBundle("Example.app", in: fixture, infoDirectory: "Contents")
        // 复核最小反例：有 Contents/Info.plist，但 Tool 只在包根。
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: bundle.appendingPathComponent("Tool"))
        XCTAssertTrue(FileAnalysisApplicationBundleProbe.isApplication(atPath: bundle.path))

        let analysis = try fixture.analyze()
        let environment = fixture.environment(runningApplicationPaths: { [] })
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let entry = try XCTUnwrap(analysis.index.indexedEntry(at: bundle.path))
        XCTAssertFalse(policy.nonApplicationBundlePaths.contains(bundle.path))
        XCTAssertEqual(FileAnalysisTrashService.block(for: bundle.path, entry: entry,
            index: analysis.index, policy: policy), .applicationBundle)
        let review = FileAnalysisTrashService.review(
            [try fixture.selection("Example.app", in: analysis.index), try fixture.selection("big.zip", in: analysis.index)],
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil)
        XCTAssertEqual(review.items.first?.status, .blocked(.applicationBundle))
        XCTAssertEqual(review.readyItems.map(\.selection.title), ["big.zip"])

        let coordinator = HeavyWorkCoordinator()
        let store = LargeFilesStore(coordinator: coordinator, activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            defaults: TestPreferenceDomain.make(for: self), storageMapTargets: [], trashEnvironment: environment)
        store.replaceStorageAnalysisForTesting(analysis)
        let deadline = Date().addingTimeInterval(15)
        while store.trashPolicy?.isRefined != true {
            guard Date() < deadline else { XCTFail("等待规则超时"); throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(10))
        }
        let row = try XCTUnwrap(store.currentStorageMapSnapshot?.entries.first { $0.path == bundle.path })
        XCTAssertEqual(row.contentCategory, .application)
        XCTAssertEqual(store.trashSelectionState(for: row), .blocked(.applicationBundle))
        store.toggleTrashSelection(row)
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
        XCTAssertEqual(store.trashReview?.items.map(\.selection.title), ["big.zip"], "应用不能进入用户审阅列表")
        XCTAssertEqual(store.trashReview?.readyItems.count, 1)
        store.cancelTrashReview()
    }

    func testEveryModernExecutableLocationIsAnApplication() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let candidates = ["Contents/MacOS", "Contents/Mac OS X", "Contents/MacOSClassic",
                          "Contents/Mac OS 8", "Contents", ""]
        for (index, directory) in candidates.enumerated() {
            let bundle = try makeBundle("Modern\(index).app", in: fixture, infoDirectory: "Contents")
            XCTAssertFalse(FileAnalysisApplicationBundleProbe.isApplication(atPath: bundle.path), "尚无可执行文件")
            try writeExecutable(in: bundle, directory: directory)
            XCTAssertTrue(FileAnalysisApplicationBundleProbe.isApplication(atPath: bundle.path), directory)
        }
    }

    func testLegacyAndFlatExecutableLocationsAreApplications() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let layouts: [(String, [String])] = [
            ("Resources", [""]),
            ("Support Files", ["Support Files/Executables/MacOS", "Support Files/Executables/Mac OS X",
                               "Support Files/Executables/MacOSClassic", "Support Files/Executables/Mac OS 8",
                               "Support Files/Executables", ""]),
            ("", ["MacOS", "Mac OS X", "MacOSClassic", "Mac OS 8", ""]),
        ]
        for (layoutIndex, layout) in layouts.enumerated() {
            for (index, directory) in layout.1.enumerated() {
                let bundle = try makeBundle("Legacy\(layoutIndex)-\(index).app", in: fixture, infoDirectory: layout.0)
                XCTAssertFalse(FileAnalysisApplicationBundleProbe.isApplication(atPath: bundle.path))
                try writeExecutable(in: bundle, directory: directory)
                XCTAssertTrue(FileAnalysisApplicationBundleProbe.isApplication(atPath: bundle.path), "\(layout.0): \(directory)")
            }
        }
        // 没有 plist 的平面包仍用包名；Contents 为普通文件也不是退出查找的理由。
        let flat = fixture.url("NoInfo.app")
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        try Data([1]).write(to: flat.appendingPathComponent("Contents"))
        try Data([1]).write(to: flat.appendingPathComponent("NoInfo"))
        XCTAssertTrue(FileAnalysisApplicationBundleProbe.isApplication(atPath: flat.path))
    }

    func testOnlyTheApplicableLayoutSuppliesTheExecutableNameAndDirectories() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let modern = try makeBundle("Mixed.app", in: fixture, infoDirectory: "Contents")
        // Contents 布局不会把旧式 Support Files 中的普通数据误当可执行文件。
        try writeExecutable(in: modern, directory: "Support Files/Executables/MacOS")
        XCTAssertFalse(FileAnalysisApplicationBundleProbe.isApplication(atPath: modern.path))
        try writeExecutable(in: modern, directory: "")
        XCTAssertTrue(FileAnalysisApplicationBundleProbe.isApplication(atPath: modern.path))
        let old = try makeBundle("Resources.app", in: fixture, infoDirectory: "Resources")
        try writeExecutable(in: old, directory: "MacOS")
        XCTAssertFalse(FileAnalysisApplicationBundleProbe.isApplication(atPath: old.path), "Resources 布局只检查包根")
    }

    func testCandidateLookupContinuesAfterDirectoriesAndSpecialFiles() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let bundle = try makeBundle("NonFiles.app", in: fixture, infoDirectory: "Contents")
        let manager = FileManager.default
        try manager.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS/Tool"), withIntermediateDirectories: true)
        try manager.createDirectory(at: bundle.appendingPathComponent("Contents/Mac OS X"), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(bundle.appendingPathComponent("Contents/Mac OS X/Tool").path, 0o600), 0)
        try writeExecutable(in: bundle, directory: "")
        XCTAssertTrue(FileAnalysisApplicationBundleProbe.isApplication(atPath: bundle.path))
        try manager.removeItem(at: bundle.appendingPathComponent("Tool"))
        XCTAssertFalse(FileAnalysisApplicationBundleProbe.isApplication(atPath: bundle.path), "所有候选都没有普通文件才按文件夹处理")
    }

    func testFallbackCandidatesKeepSubpathsInsideTheBundleAndDoNotFollowLinks() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        for (index, directory) in ["Contents/Mac OS X", "Contents", ""].enumerated() {
            let bundle = try makeBundle("Linked\(index).app", in: fixture, infoDirectory: "Contents", executable: "bin/Tool")
            let parent = directory.isEmpty ? bundle : bundle.appendingPathComponent(directory)
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: parent.appendingPathComponent("bin"),
                                           withDestinationURL: fixture.url("missing-target"))
            XCTAssertTrue(FileAnalysisApplicationBundleProbe.isApplication(atPath: bundle.path), directory)
            try manager.removeItem(at: parent.appendingPathComponent("bin"))
            try manager.createDirectory(at: parent.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: parent.appendingPathComponent("bin/Tool"),
                                           withDestinationURL: fixture.url("missing-target"))
            XCTAssertTrue(FileAnalysisApplicationBundleProbe.isApplication(atPath: bundle.path), "可执行位置链接也不跟随")
            try manager.removeItem(at: parent.appendingPathComponent("bin/Tool"))
            try Data([1]).write(to: parent.appendingPathComponent("bin/Tool"))
            XCTAssertTrue(FileAnalysisApplicationBundleProbe.isApplication(atPath: bundle.path), "候选目录中的包内子路径")
        }
        try Data([1]).write(to: fixture.url("outside"))
        let escaping = try makeBundle("Escape.app", in: fixture, infoDirectory: "Contents", executable: "../../../outside")
        XCTAssertFalse(FileAnalysisApplicationBundleProbe.isApplication(atPath: escaping.path), "不能从任一候选越过包根")
        let root = try makeBundle("RootRelative.app", in: fixture, infoDirectory: "Contents", executable: "../../Tool")
        try writeExecutable(in: root, directory: "")
        XCTAssertTrue(FileAnalysisApplicationBundleProbe.isApplication(atPath: root.path), "从常规目录解析到包根仍在包内")
    }

    private func makeBundle(_ name: String, in fixture: TrashFixture, infoDirectory: String,
                            executable: String = "Tool") throws -> URL {
        let bundle = fixture.url(name)
        let directory = infoDirectory.isEmpty ? bundle : bundle.appendingPathComponent(infoDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundlePackageType": "APPL", "CFBundleExecutable": executable],
                                            format: .xml, options: 0).write(to: directory.appendingPathComponent("Info.plist"))
        return bundle
    }

    private func writeExecutable(in bundle: URL, directory: String) throws {
        let parent = directory.isEmpty ? bundle : bundle.appendingPathComponent(directory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: parent.appendingPathComponent("Tool"))
    }
}
