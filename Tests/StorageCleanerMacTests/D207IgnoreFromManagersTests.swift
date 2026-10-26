#if DEBUG
import Foundation
import XCTest
@testable import StorageCleanerMac

/// D207, the managers' half (CleanMyMac's Add to Ignore List and the note
/// with Put Back; our wording): each manager adds its rows to the ignore list
/// under the category the scan files them in, hides them as a scan leaves out
/// what the list covers, counts them among the ignored, and Put Back returns
/// them where they were; Put Back removes exactly what that addition added.
/// Every list here is a file in a test folder.
@MainActor
final class D207IgnoreFromManagersTests: XCTestCase {
    private func makeList() throws -> IgnoreListStore {
        let home = try TestFileSystem.makeHome(for: self)
        return IgnoreListStore(fileURL: home.appendingPathComponent("IgnoreList.json"), defaults: TestPreferenceDomain.make(for: self))
    }

    func testPutBackRemovesExactlyThisAdditionAndTheNoteSaysWhatHappened() throws {
        let list = try makeList()
        let feedback = IgnoreListFeedback { list }
        let item = IgnoreListFeedback.Item(target: IgnoreListTarget(path: "/fixture/a"), category: .systemJunk, name: "a")
        XCTAssertNotNil(feedback.add([item]))
        XCTAssertEqual(feedback.note?.canPutBack, true)
        XCTAssertEqual(feedback.note?.place, .window)
        XCTAssertEqual(feedback.note?.text, L10n.text("已把“a”加入忽略列表", "“a” is on the Ignore List now"))

        // Something else goes on the list afterwards (Settings): Put Back leaves it.
        XCTAssertTrue(list.add("/fixture/b", category: .other))
        var restoredWith: IgnoreListSnapshot?
        feedback.onPutBack { restoredWith = $0 }
        feedback.putBack()
        XCTAssertNil(feedback.note)
        XCTAssertEqual(list.snapshot().entries.map(\.target.path), [PathSafety.normalizedPath("/fixture/b")])
        XCTAssertEqual(restoredWith?.entries.count, 1, "the rows come back against the list as it is after Put Back")

        // Adding what the list already has says so, without Put Back.
        let listed = IgnoreListFeedback.Item(target: IgnoreListTarget(path: "/fixture/b"), category: .other, name: "b")
        XCTAssertNotNil(feedback.add([listed]))
        XCTAssertEqual(feedback.note?.canPutBack, false)
        XCTAssertEqual(feedback.note?.text, L10n.text("已在忽略列表里", "Already on the Ignore List"))
        feedback.putBack()
        XCTAssertEqual(list.snapshot().entries.count, 1, "nothing to put back")

        // Several rows at once, in two categories, are one addition.
        let rows = [IgnoreListFeedback.Item(target: IgnoreListTarget(path: "/fixture/c"), category: .systemJunk, name: "c"),
                    IgnoreListFeedback.Item(target: IgnoreListTarget(path: "/fixture/d"), category: .aiClutter, name: "d")]
        XCTAssertNotNil(feedback.add(rows))
        XCTAssertEqual(feedback.note?.text, L10n.text("已把 2 项加入忽略列表", "2 items are on the Ignore List now"))
        feedback.putBack()
        XCTAssertEqual(list.snapshot().entries.map(\.target.path), [PathSafety.normalizedPath("/fixture/b")])

        XCTAssertNil(IgnoreListFeedback { nil }.add([item]), "without a list nothing is added or hidden")
        XCTAssertEqual(IgnoreListMenu.title(count: 1), L10n.text("加入忽略列表", "Add to Ignore List"))
        XCTAssertEqual(IgnoreListMenu.title(count: 3), L10n.text("忽略 3 项", "Add 3 Items to Ignore List"))
    }

    func testTheCleanupManagerHoldsBackWhatItIgnoresAndPutBackReturnsIt() throws {
        let store = try ScanStore.makeForTests(for: self)
        store.ignoreListStore = try makeList()
        store.installDebugSmartScanSessionFixture(.results, page: .green)
        let session = try XCTUnwrap(store.cleanupScanSession)
        var found: (CleanupScanCategory, CleanupScanSubcategory, Int, ScanCandidate)?
        search: for category in session.categories {
            for subcategory in category.subcategories {
                if let index = subcategory.candidates.firstIndex(where: \.isSelectable) {
                    found = (category, subcategory, index, subcategory.candidates[index])
                    break search
                }
            }
        }
        let (category, subcategory, index, candidate) = try XCTUnwrap(found)
        store.setCleanupCandidate(candidate.id, selected: true)
        XCTAssertTrue(store.cleanupSelection.selectedCandidateIDs.contains(candidate.id))
        let path = candidate.snapshot.standardizedPath

        store.ignoreCleanupCandidates([candidate.id])
        let held = try XCTUnwrap(store.cleanupScanSession)
        XCTAssertEqual(held.id, session.id, "the same result, without the row")
        XCTAssertFalse(held.candidates.contains { $0.id == candidate.id })
        XCTAssertEqual(held.metrics.candidateCount, session.metrics.candidateCount - 1)
        XCTAssertEqual(held.metrics.ignoredItemCount, session.metrics.ignoredItemCount + 1, "counted as the scan counts")
        XCTAssertEqual(held.metrics.ignoredPathsByRule[candidate.ruleID]?.contains(path), true)
        XCTAssertFalse(store.cleanupSelection.selectedCandidateIDs.contains(candidate.id), "it leaves the selection")
        let entry = try XCTUnwrap(store.ignoreListStore?.snapshot().entries.first)
        XCTAssertEqual(entry.category, IgnoreCategory.cleanup(for: CareJunkGroup.group(categoryID: category.id, candidates: [candidate])))
        XCTAssertEqual(entry.target.path, PathSafety.normalizedPath(path))
        XCTAssertEqual(store.ignoreFeedback.note?.canPutBack, true)

        store.ignoreFeedback.putBack()
        let back = try XCTUnwrap(store.cleanupScanSession)
        let returned = try XCTUnwrap(back.categories.first { $0.id == category.id }?.subcategories.first { $0.id == subcategory.id })
        XCTAssertEqual(returned.candidates.firstIndex { $0.id == candidate.id }, index, "where it was")
        XCTAssertEqual(back.metrics.candidateCount, session.metrics.candidateCount)
        XCTAssertEqual(back.metrics.ignoredItemCount, session.metrics.ignoredItemCount)
        XCTAssertNotEqual(back.metrics.ignoredPathsByRule[candidate.ruleID]?.contains(path), true)
        XCTAssertTrue(store.cleanupSelection.selectedCandidateIDs.contains(candidate.id), "selected as it was")
        XCTAssertEqual(store.ignoreListStore?.snapshot().entries.isEmpty, true)
    }

    func testAnUpdateRowGoesOnTheListForGoodAndPutBackGivesItsStateBack() throws {
        let store = try ScanStore.makeForTests(for: self)
        store.ignoreListStore = try makeList()
        let home = try TestFileSystem.makeHome(for: self)
        let apps = try ["keep", "update"].map { id in
            let url = home.appendingPathComponent(id + ".app")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return AppUpdateTestFixtures.strictHomebrewApplication(id: id, path: url.path)
        }
        store.appUpdates = apps
        XCTAssertTrue(store.canAddAppUpdateToIgnoreList(apps[1]))

        store.ignoreAppUpdates([apps[1]])
        XCTAssertEqual(store.appUpdates[1].updateStatus, .ignored, "the row says it is ignored, as a check marks it")
        XCTAssertFalse(store.appUpdates[1].canJoinAutomaticUpdateBatch)
        XCTAssertEqual(store.ignoredAppUpdateCount, 1)
        XCTAssertEqual(store.appUpdates[0].updateStatus, apps[0].updateStatus)
        let entry = try XCTUnwrap(store.ignoreListStore?.snapshot().entries.first)
        XCTAssertEqual(entry.category, .updates)
        XCTAssertEqual(entry.target.bundleIdentifier, apps[1].bundleIdentifier)
        XCTAssertNil(entry.target.latestVersion, "every later update too")
        XCTAssertFalse(store.canAddAppUpdateToIgnoreList(store.appUpdates[1]))

        store.ignoreFeedback.putBack()
        XCTAssertEqual(store.appUpdates[1].updateStatus, apps[1].updateStatus)
        XCTAssertEqual(store.appUpdates[1].canAutomaticallyUpdate, apps[1].canAutomaticallyUpdate)
        XCTAssertEqual(store.appUpdates[1].requiresUserInteraction, apps[1].requiresUserInteraction)
        XCTAssertEqual(store.ignoredAppUpdateCount, 0)
    }

    func testAMalwareRowLeavesTheResultAmongTheIgnoredAndComesBack() async throws {
        let list = try makeList()
        let feedback = IgnoreListFeedback { list }
        let threats = ["/fixture/Downloads/a", "/fixture/Downloads/b"].map {
            MalwareThreat(ruleName: "XProtect_MACOS_SYNTHETIC_A", path: $0, size: 1, signature: .unsigned, launchPlists: [])
        }
        let malware = MalwareScanStore(scanner: D207FixedMalwareScanner(outcome: MalwareScanOutcome(checkedFiles: 2, threats: threats)))
        malware.startScan()
        await malware.waitUntilIdle()
        XCTAssertEqual(malware.rows.map(\.path), ["/fixture/Downloads/a", "/fixture/Downloads/b"])
        malware.setSelected("/fixture/Downloads/a", selected: true)

        malware.ignore(["/fixture/Downloads/a"], feedback: feedback)
        XCTAssertEqual(malware.rows.map(\.path), ["/fixture/Downloads/b"])
        XCTAssertEqual(malware.outcome?.counts.ignored, 1)
        XCTAssertTrue(malware.selectedPaths.isEmpty)
        XCTAssertEqual(feedback.note?.place, .malwareList, "the note shows in the list's sheet")
        XCTAssertEqual(list.snapshot().entries.first?.category, .malware)

        feedback.putBack()
        XCTAssertEqual(malware.rows.map(\.path), ["/fixture/Downloads/a", "/fixture/Downloads/b"])
        XCTAssertEqual(malware.outcome?.counts.ignored, 0)
        XCTAssertEqual(malware.selectedPaths, ["/fixture/Downloads/a"])
    }

    func testAnAppAndALeftoverGroupLeaveTheirListsAndComeBack() throws {
        let list = try makeList()
        let feedback = IgnoreListFeedback { list }
        let model = ApplicationsManagerModel()
        let photon = Self.entry(id: "com.example.photon", name: "Photon")
        let lumen = Self.entry(id: "com.example.lumen", name: "Lumen")
        model.replaceEntries([photon, lumen])
        model.toggle(photon)
        let selected = try XCTUnwrap(model.selection[photon.id])

        model.ignoreApplications([photon.id], feedback: feedback)
        XCTAssertEqual(model.entries.map(\.id), [lumen.id])
        XCTAssertEqual(model.ignoredApplicationCount, 1)
        XCTAssertNil(model.selection[photon.id])
        let entry = try XCTUnwrap(list.snapshot().entries.first)
        XCTAssertEqual(entry.category, .uninstaller)
        XCTAssertEqual(entry.target.bundleIdentifier, "com.example.photon")
        feedback.putBack()
        XCTAssertEqual(model.entries.map(\.id), [photon.id, lumen.id], "where it was")
        XCTAssertEqual(model.ignoredApplicationCount, 0)
        XCTAssertEqual(model.selection[photon.id], selected)

        let resources = ["Library/Caches/com.example.gone", "Library/Preferences/com.example.gone.plist"].map {
            ApplicationResource(path: "/Users/fixture/" + $0, group: .caches, evidence: .bundleIdentifier, domain: .user, kind: .file,
                                sizeBytes: 10, identity: nil, isRemovable: true, note: nil)
        }
        let gone = LeftoverGroup(bundleIdentifier: "com.example.gone", displayName: "Gone", resources: resources)
        let other = LeftoverGroup(bundleIdentifier: "com.example.other", displayName: "Other", resources: [
            ApplicationResource(path: "/Users/fixture/Library/Caches/com.example.other", group: .caches, evidence: .bundleIdentifier,
                                domain: .user, kind: .file, sizeBytes: 10, identity: nil, isRemovable: true, note: nil)])
        model.replaceLeftovers([gone, other])
        model.ignoreLeftovers(Set(gone.resources.map(\.id)), feedback: feedback)
        XCTAssertEqual(model.leftovers.map(\.id), [other.id], "a group left empty goes")
        XCTAssertEqual(model.ignoredLeftoverCount, 2)
        XCTAssertEqual(model.leftoverSelection, Set(other.resources.map(\.id)))
        XCTAssertEqual(Set(list.snapshot().entries.filter { $0.target.bundleIdentifier == nil }.map(\.category)), [.uninstaller],
                       "leftovers by path, as the leftover scan reads them")
        feedback.putBack()
        XCTAssertEqual(model.leftovers.map(\.id), [gone.id, other.id])
        XCTAssertEqual(model.leftovers.first?.resources.map(\.id), gone.resources.map(\.id))
        XCTAssertEqual(model.ignoredLeftoverCount, 0)
        XCTAssertEqual(model.leftoverSelection, Set((gone.resources + other.resources).map(\.id)))
    }

    /// D215: one leftover file at a time, by its path under Uninstaller, from
    /// its own row. The rest of its group stays; a group whose last file goes
    /// leaves with it. Put Back returns the file to its place, selected as it was.
    func testASingleLeftoverFileLeavesAloneOrTakesItsGroupWithIt() throws {
        let list = try makeList()
        let feedback = IgnoreListFeedback { list }
        let model = ApplicationsManagerModel()
        func resource(_ path: String) -> ApplicationResource {
            ApplicationResource(path: "/Users/fixture/" + path, group: .caches, evidence: .bundleIdentifier, domain: .user,
                                kind: .file, sizeBytes: 10, identity: nil, isRemovable: true, note: nil)
        }
        let gone = LeftoverGroup(bundleIdentifier: "com.example.gone", displayName: "Gone", resources: [
            resource("Library/Caches/com.example.gone"), resource("Library/Preferences/com.example.gone.plist")])
        let other = LeftoverGroup(bundleIdentifier: "com.example.other", displayName: "Other", resources: [
            resource("Library/Caches/com.example.other")])
        model.replaceLeftovers([gone, other])
        let (first, second) = (gone.resources[0], gone.resources[1])
        model.leftoverSelection.remove(first.id)

        model.ignoreLeftovers([second.id], feedback: feedback)
        XCTAssertEqual(model.leftovers.map(\.id), [gone.id, other.id], "the group stays")
        XCTAssertEqual(model.leftovers.first?.resources.map(\.id), [first.id])
        XCTAssertEqual(model.ignoredLeftoverCount, 1)
        XCTAssertFalse(model.leftoverSelection.contains(second.id))
        let entry = try XCTUnwrap(list.snapshot().entries.first)
        XCTAssertEqual(list.snapshot().entries.count, 1)
        XCTAssertEqual(entry.category, .uninstaller)
        XCTAssertEqual(entry.target.path, PathSafety.normalizedPath(second.path))
        XCTAssertNil(entry.target.bundleIdentifier, "by path, as the leftover scan reads it")
        XCTAssertEqual(entry.displayName, "Gone · com.example.gone.plist")
        feedback.putBack()
        XCTAssertEqual(model.leftovers.first?.resources.map(\.id), [first.id, second.id], "where it was")
        XCTAssertTrue(model.leftoverSelection.contains(second.id), "selected as it was")
        XCTAssertFalse(model.leftoverSelection.contains(first.id), "the unticked file stays unticked")
        XCTAssertEqual(model.ignoredLeftoverCount, 0)
        XCTAssertTrue(list.snapshot().entries.isEmpty)

        model.ignoreLeftovers([other.resources[0].id], feedback: feedback)
        XCTAssertEqual(model.leftovers.map(\.id), [gone.id], "its last file takes the group")
        feedback.putBack()
        XCTAssertEqual(model.leftovers.map(\.id), [gone.id, other.id], "the group comes back to its place")

        // Each leftover file's own row offers it; the installed apps' file rows do not.
        let view = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/StorageCleanerMac/Views/ApplicationsManager/ApplicationsManagerView.swift"),
            encoding: .utf8)
        XCTAssertTrue(view.contains("model.ignoreLeftovers([resource.id], feedback: feedback)"))
        XCTAssertTrue(view.contains("Button(IgnoreListMenu.title(count: 1), action: ignore)"))
        XCTAssertEqual(view.components(separatedBy: "ignore: ignoreListFeedback.flatMap").count - 1, 1, "leftovers only")
    }

    func testADuplicateLeavesWithTheCopyLeftAloneAndComesBackWithIt() throws {
        let store = try ScanStore.makeForTests(for: self)
        store.ignoreListStore = try makeList()
        let groups = FeatureLightfieldFileResultFixture.duplicateGroups(similar: false)
        let items = groups.flatMap(\.items)
        let workspace = store.duplicateFilesWorkspace
        workspace.replaceItemsForTesting(items, coverage: DuplicateFileScanCoverage(
            roots: [], reachedTimeLimit: false, reachedFileLimit: false, reachedDirectoryLimit: false, reachedResultLimit: false))
        let pair = try XCTUnwrap(groups.first { $0.items.count == 2 })
        let trio = try XCTUnwrap(groups.first { $0.items.count == 3 })

        workspace.ignore([pair.items[0]], feedback: store.ignoreFeedback)
        XCTAssertFalse(workspace.items.contains { $0.id == pair.items[0].id })
        XCTAssertFalse(workspace.items.contains { $0.id == pair.items[1].id }, "its copy no longer has a duplicate")
        XCTAssertEqual(workspace.scanCoverage?.ignoredCount(for: .duplicates), 1, "only the ignored file counts")
        XCTAssertEqual(store.ignoreListStore?.snapshot().entries.first?.category, .duplicates)
        store.ignoreFeedback.putBack()
        XCTAssertEqual(workspace.items.map(\.id), items.map(\.id), "both return where they were")
        XCTAssertEqual(workspace.scanCoverage?.ignoredCount(for: .duplicates), 0)

        workspace.ignore([trio.items[0]], feedback: store.ignoreFeedback)
        XCTAssertEqual(workspace.items.filter { $0.duplicateGroupID == trio.id }.count, 2, "two copies are still a group")

        store.ignoreFeedback.putBack()

        // Main session, 10-25: when the ignored file was the one copy its group
        // kept, another copy stays unselected (a plan would refuse
        // noRetainedCopy otherwise); Put Back gives the selection back. The
        // copies sit in the store's home, where they may be selected.
        let home = try TestFileSystem.makeHome(for: self)
        let coordinator = HeavyWorkCoordinator()
        let copies = DuplicateFilesStore(defaults: TestPreferenceDomain.make(for: self), coordinator: coordinator,
                                         activityStore: HeavyWorkActivityStore(coordinator: coordinator), userHomeURL: home)
        let three = (0..<3).map { index in
            StorageItem(id: "copy-\(index)", title: "clip.mov", path: home.appendingPathComponent("copy-\(index)/clip.mov").path,
                        groupTitle: "clip.mov", sizeBytes: 10, tier: .yellow, kind: "file", reason: "", recommendation: "", risk: "",
                        requiresClose: "", trashPaths: [], openPath: "", isDirectory: false, duplicateGroupID: "group-clip",
                        duplicateMatchKind: DuplicateFileGroup.MatchKind.logicalContentSHA256.rawValue, status: .available)
        }
        copies.replaceItemsForTesting(three)
        copies.setSelected(true, item: three[1], allItems: copies.items)
        copies.setSelected(true, item: three[2], allItems: copies.items)
        XCTAssertEqual(copies.selectedItemIDs, [three[1].id, three[2].id], "copy-0 is the copy kept")
        copies.ignore([three[0]], feedback: store.ignoreFeedback)
        XCTAssertEqual(copies.items.map(\.id), [three[1].id, three[2].id])
        XCTAssertEqual(copies.selectedItemIDs.count, 1, "one copy stays")
        XCTAssertNil(copies.selectionMessage, "said by the checkbox, not a Cannot Select alert")
        store.ignoreFeedback.putBack()
        XCTAssertEqual(copies.items.map(\.id), three.map(\.id))
        XCTAssertEqual(copies.selectedItemIDs, [three[1].id, three[2].id], "selected as they were")

        let similar = FeatureLightfieldFileResultFixture.duplicateGroups(similar: true).flatMap(\.items)
        XCTAssertEqual(DuplicateFilesStore.ignoreCategory(of: similar[0]), .similar)
        XCTAssertEqual(DuplicateFilesStore.ignoreCategory(of: pair.items[0]), .duplicates)
    }

    private static func entry(id: String, name: String) -> ApplicationEntry {
        let path = "/Applications/\(name).app"
        let item = InstalledAppItem(id: path, name: name, bundleIdentifier: id, path: path, version: "1", build: "1",
                                    category: "", appDescription: "", sizeBytes: 1_000, source: "", modifiedAt: nil,
                                    relatedPaths: [], relatedItems: [], status: .installed)
        let resources = [
            ApplicationResource(path: path, group: .binaries, evidence: .bundle, domain: .user, kind: .file,
                                sizeBytes: 100, identity: nil, isRemovable: true, note: nil),
            ApplicationResource(path: "/Users/me/Library/Caches/\(id)", group: .caches, evidence: .bundleIdentifier, domain: .user,
                                kind: .file, sizeBytes: 100, identity: nil, isRemovable: true, note: nil),
        ]
        return ApplicationEntry(item: item, profile: nil,
            classification: ApplicationClassification(store: .other, vendor: .other, isUnused: false,
                                                      isThirtyTwoBitOnly: false, suspiciousReason: nil),
            resources: resources, isThisApplication: false)
    }
}

private struct D207FixedMalwareScanner: MalwareScanning {
    let outcome: MalwareScanOutcome
    func scan(progress: @escaping @Sendable (MalwareScanProgress) -> Void) async -> MalwareScanOutcome { outcome }
}
#endif
