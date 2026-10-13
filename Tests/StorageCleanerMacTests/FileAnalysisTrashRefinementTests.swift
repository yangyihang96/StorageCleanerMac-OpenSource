import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class FileAnalysisTrashRefinementTests: XCTestCase {
    func testTimeoutOnlyBlocksUnansweredLocationsAndKeepsOtherSelectionsReviewable() async throws {
        let fixture = try TrashFixture()
        let provider = RefinementGate()
        let timeout = TrashRefinementTimeoutGate()
        defer { provider.open(); Task { await timeout.open() }; fixture.remove() }
        for folder in ["Desktop", "Documents"] {
            try FileManager.default.createDirectory(at: fixture.url(folder), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: fixture.url(folder + "/item.txt"))
        }
        let desktop = fixture.url("Desktop").path
        var environment = fixture.environment(homePath: fixture.root.path, isCloudFolder: { url in
            if url.path == desktop { provider.wait() }
            return false
        })
        environment.waitForRefinementTimeout = { await timeout.wait() }
        let store = try makeStore(fixture, environment: environment)
        let analysis = try fixture.analyze()
        store.replaceStorageAnalysisForTesting(analysis)
        let scanner = DiskScanner(excludedPaths: [])
        let shot = try XCTUnwrap(try scanner.storageMapSnapshot(at: desktop, using: analysis.index).entries.first)
        let document = try XCTUnwrap(try scanner.storageMapSnapshot(at: fixture.url("Documents").path,
                                                                   using: analysis.index).entries.first)
        let zip = try XCTUnwrap(store.currentStorageMapSnapshot?.entries.first { $0.title == "big.zip" })
        try await waitUntil {
            store.trashPolicy?.pendingRefinementPaths == Set([desktop])
                && store.trashPolicy?.awaitsProtectedLinkTargets == false
        }
        XCTAssertEqual(store.trashSelectionState(for: shot), .checking(.iCloud))
        XCTAssertEqual(store.trashSelectionState(for: document), .available)
        store.toggleTrashSelection(document)
        store.toggleTrashSelection(zip)
        XCTAssertTrue(store.canReviewTrash)
        await timeout.open()
        try await waitUntil { store.trashPolicy?.failedRefinementPaths == Set([desktop]) }
        XCTAssertEqual(store.trashSelectionState(for: shot), .blocked(.cloudStateUnknown))
        XCTAssertEqual(store.trashSelectionState(for: document), .selected)
        XCTAssertEqual(store.trashSelections.map(\.title), ["item.txt", "big.zip"])
        XCTAssertNil(store.trashRefinementNotice)
        store.requestTrashReview()
        try await waitUntil { store.trashPhase == .reviewing }
        XCTAssertEqual(store.trashReview?.readyItems.count, 2)
        store.cancelTrashReview()
        provider.open()
        try await waitUntil { provider.waitFinished }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.trashSelectionState(for: shot), .blocked(.cloudStateUnknown))
    }

    func testALateAnswerFromAnOldAnalysisCannotOverwriteTheNewPolicy() async throws {
        let fixture = try TrashFixture()
        let provider = RefinementGate()
        defer { provider.open(); fixture.remove() }
        let environment = fixture.environment(homePath: fixture.root.path, isCloudFolder: { _ in
            provider.wait(); return true
        })
        let store = try makeStore(fixture, environment: environment)
        store.replaceStorageAnalysisForTesting(try fixture.analyze())
        let new = try DiskScanner(excludedPaths: []).storageMapAnalysis(target:
            StorageMapScanTarget(path: fixture.root.path, title: "New fixture", kind: .externalVolume))
        store.replaceStorageAnalysisForTesting(new)
        try await waitUntil { store.trashPolicy?.isRefined == true }
        let latest = try XCTUnwrap(store.trashPolicy)
        provider.open()
        // 等旧判定工作线程返回，再观察主 actor；generation 守卫必须仍有效。
        try await waitUntil { provider.waitFinished }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.trashPolicy, latest)
        XCTAssertEqual(store.trashPolicy?.targetKind, .externalVolume)
        XCTAssertEqual(store.trashPolicy?.cloudSyncedFolders, [])
    }

    func testTimeoutPolicyPreservesAnswersAndTheReviewRefusesUnknownItems() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url("Desktop"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: fixture.url("Desktop/item.txt"))
        let analysis = try fixture.analyze()
        let environment = fixture.environment(homePath: fixture.root.path)
        let basic = FileAnalysisTrashService.basicPolicy(for: analysis, environment: environment)
        let answered = FileAnalysisTrashService.applyingRefinementAnswer(true,
            for: fixture.url("Documents").path, to: basic)
        let failed = FileAnalysisTrashService.refinementTimedOut(answered)
        XCTAssertEqual(failed.cloudSyncedFolders, [fixture.url("Documents").path])
        XCTAssertEqual(failed.failedRefinementPaths, Set([fixture.url("Desktop").path]))
        let selections = try ["Desktop/item.txt", "big.zip"].map { try fixture.selection($0, in: analysis.index) }
        XCTAssertEqual(FileAnalysisTrashService.selectionBlocks(selections, index: analysis.index, policy: failed),
                       [fixture.url("Desktop/item.txt").path: .cloudStateUnknown],
                       "超时只取消依赖未知位置的勾选；其他勾选不受影响")
        XCTAssertEqual(FileAnalysisTrashService.applyingRefinementAnswer(false,
            for: fixture.url("Desktop").path, to: failed), failed)
        let review = FileAnalysisTrashService.review(
            [try fixture.selection("Desktop/item.txt", in: analysis.index), try fixture.selection("big.zip", in: analysis.index)],
            index: analysis.index, policy: failed, environment: environment, externalVolumeName: nil)
        XCTAssertEqual(review.items.first?.status, .blocked(.cloudStateUnknown))
        XCTAssertEqual(review.readyItems.map(\.selection.title), ["big.zip"])
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        // P2-3: a short phrase on the row; iCloud's sentence on hover and in the review.
        XCTAssertEqual(FileAnalysisTrashBlock.cloudStateUnknown.shortTitle, "云端状态未知")
        XCTAssertTrue(FileAnalysisTrashBlock.cloudStateUnknown.explanation.hasPrefix("无法确认云端状态，暂不可选"))
        XCTAssertTrue(FileAnalysisTrashBlock.cloudStateUnknown.explanation.contains("已超时"))
    }

    func testAnExternalVolumeTimeoutStaysUnavailable() {
        let policy = FileAnalysisTrashPolicy(rootPath: "/Volumes/Fixture", targetKind: .externalVolume,
            homePath: "/Users/fixture", appDataPath: "/Users/fixture/AppData", excludedPaths: [], isRefined: false)
        XCTAssertTrue(policy.awaitsRefinement(of: "/Volumes/Fixture/file.zip"))
        let failed = FileAnalysisTrashService.refinementTimedOut(policy)
        XCTAssertFalse(failed.awaitsRefinement(of: "/Volumes/Fixture/file.zip"))
        // P2-3: it was the volume's read-only state, not iCloud.
        XCTAssertEqual(failed.block(path: "/Volumes/Fixture/file.zip", name: "file.zip", kind: "file",
                                    isDirectory: false, isEstimated: false), .volumeStateUnknown)
    }

    /// r2-fa-followups P2-3: on an external volume what is checked is whether
    /// the volume is read-only, and the bar, a click, the hover and the
    /// timeout say so, not iCloud.
    func testAnExternalVolumeSaysItIsCheckingTheVolumeNotICloud() async throws {
        let fixture = try TrashFixture()
        let volume = RefinementGate()
        let timeout = TrashRefinementTimeoutGate()
        defer { volume.open(); Task { await timeout.open() }; fixture.remove() }
        var environment = fixture.environment(isReadOnlyVolume: { _ in
            volume.wait()
            return false
        })
        environment.waitForRefinementTimeout = { await timeout.wait() }
        let store = try makeStore(fixture, environment: environment)
        store.replaceStorageAnalysisForTesting(try DiskScanner(excludedPaths: []).storageMapAnalysis(target:
            StorageMapScanTarget(path: fixture.root.path, title: "External fixture", kind: .externalVolume)))
        try await waitUntil { store.trashPolicy?.awaitsProtectedLinkTargets == false }
        let zip = try XCTUnwrap(store.currentStorageMapSnapshot?.entries.first { $0.title == "big.zip" })
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        XCTAssertEqual(store.trashSelectionState(for: zip), .checking(.volume))
        XCTAssertEqual(store.trashRefinementNotice, "正在确认卷状态…")
        let hover = FileAnalysisTrashPresentation.checkboxHelp(state: store.trashSelectionState(for: zip))
        XCTAssertTrue(hover.contains("只读"), hover)
        XCTAssertFalse(hover.contains("iCloud"), hover)
        store.toggleTrashSelection(zip)
        XCTAssertEqual(store.trashNotice, "正在确认“big.zip”所在的卷是否只读，请稍候再勾选。")

        await timeout.open()
        try await waitUntil { store.trashPolicy?.failedRefinementPaths.isEmpty == false }
        XCTAssertEqual(store.trashSelectionState(for: zip), .blocked(.volumeStateUnknown))
        XCTAssertEqual(FileAnalysisTrashPresentation.rowNote(state: .blocked(.volumeStateUnknown)), "卷状态未知")
        let reason = FileAnalysisTrashBlock.volumeStateUnknown.explanation
        XCTAssertTrue(reason.hasPrefix("无法确认卷状态，暂不可选"), reason)
        XCTAssertFalse(reason.contains("iCloud"), reason)
        XCTAssertNil(store.trashRefinementNotice)
    }

    /// r2-fa-followups P1-1: when finding the links runs out of the same
    /// time, nothing becomes checkable on a guess: every item no other rule
    /// blocks says the protected locations are unknown, and a late result
    /// is not taken.
    func testFindingTheLinksOutOfTimeBlocksEveryItemAndALateResultIsIgnored() async throws {
        let fixture = try TrashFixture()
        let resolver = RefinementGate()
        let resolved = ProtectionResolverCompletion()
        let timeout = TrashRefinementTimeoutGate()
        defer { resolver.open(); Task { await timeout.open() }; fixture.remove() }
        var environment = fixture.environment()
        let resolve = environment.protectedLinkTargets
        environment.protectedLinkTargets = { home, appData in
            resolver.wait()
            let result = resolve(home, appData)
            resolved.finish()
            return result
        }
        environment.waitForRefinementTimeout = { await timeout.wait() }
        let store = try makeStore(fixture, environment: environment)
        store.replaceStorageAnalysisForTesting(try fixture.analyze())
        let protectionTask = try XCTUnwrap(store.trashProtectionCompletionForTesting())
        let root = try XCTUnwrap(store.currentStorageMapSnapshot)
        let zip = try XCTUnwrap(root.entries.first { $0.title == "big.zip" })
        let tool = try XCTUnwrap(root.entries.first { $0.title == "Tool.app" })
        // iCloud is answered at once here; only the links are still out.
        try await waitUntil { store.trashPolicy?.pendingRefinementPaths.isEmpty == true }
        XCTAssertEqual(store.trashSelectionState(for: zip), .checking(.protectedLocations))
        XCTAssertEqual(store.trashSelectionState(for: tool), .blocked(.applicationBundle))

        await timeout.open()
        try await waitUntil { store.trashPolicy?.protectedLinkTargetsUnknown == true }
        XCTAssertEqual(store.trashSelectionState(for: zip), .blocked(.protectedLocationsUnknown))
        // As with iCloud's timeout, the unknown comes before the item's own
        // rules (an app read "App" while it waited).
        XCTAssertEqual(store.trashSelectionState(for: tool), .blocked(.protectedLocationsUnknown))
        XCTAssertEqual(store.trashPolicy?.isRefined, true)
        XCTAssertNil(store.trashRefinementNotice)
        resolver.open()
        // 解析闭包完成后才发信号；还要等主 actor 真正处理或拒收该结果。
        try await waitUntil { resolved.isFinished }
        await protectionTask.value
        XCTAssertEqual(store.trashSelectionState(for: zip), .blocked(.protectedLocationsUnknown), "Not taken late")
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        XCTAssertEqual(FileAnalysisTrashBlock.protectedLocationsUnknown.shortTitle, "保护范围未知")
        XCTAssertTrue(FileAnalysisTrashBlock.protectedLocationsUnknown.explanation.contains("已超时"))
    }

    /// D48: the store's preferences go to a temporary absolute-path domain,
    /// removed with its folder after the test.
    private func makeStore(_ fixture: TrashFixture, environment: FileAnalysisTrashEnvironment) throws -> LargeFilesStore {
        let coordinator = HeavyWorkCoordinator()
        return LargeFilesStore(coordinator: coordinator, activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            defaults: TestPreferenceDomain.make(for: self),
            storageMapTargets: [], trashEnvironment: environment)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else { XCTFail("等待夹具状态超时"); throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class ProtectionResolverCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var isFinished: Bool { lock.withLock { finished } }
    func finish() { lock.withLock { finished = true } }
}

/// 只用于夹具的超时信号；先 open 后 wait 也能返回。
private actor TrashRefinementTimeoutGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
