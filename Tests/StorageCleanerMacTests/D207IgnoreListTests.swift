import AppKit
import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class D207IgnoreListStoreTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults, IgnoreListStore) {
        let root = try TestFileSystem.makeHome(for: self)
        let defaults = TestPreferenceDomain.make(for: self)
        return (root, defaults, IgnoreListStore(fileURL: root.appendingPathComponent("data/IgnoreList.json"), defaults: defaults))
    }

    func testReadWriteVersionAndAddedMetadata() throws {
        let (root, defaults, store) = try fixture()
        let path = root.appendingPathComponent("keep").path
        XCTAssertTrue(store.add(IgnoreListTarget(path: path), category: .systemJunk, displayName: "保留缓存"))
        let file = root.appendingPathComponent("data/IgnoreList.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, IgnoreListStore.schemaVersion)
        let entry = try XCTUnwrap(IgnoreListStore(fileURL: file, defaults: defaults).snapshot().entries.first)
        XCTAssertEqual(entry.displayName, "保留缓存")
        XCTAssertEqual(entry.target.path, PathSafety.normalizedPath(path))
        XCTAssertLessThan(abs(entry.addedAt.timeIntervalSinceNow), 10)
    }

    func testCorruptFileIsPreservedAndNoticeConsumedOnce() throws {
        let (root, defaults, _) = try fixture()
        let file = root.appendingPathComponent("IgnoreList.json")
        let bad = Data("broken JSON".utf8)
        try bad.write(to: file)
        let store = IgnoreListStore(fileURL: file, defaults: defaults)
        XCTAssertTrue(store.snapshot().entries.isEmpty)
        XCTAssertNotNil(store.takeNotice()); XCTAssertNil(store.takeNotice())
        XCTAssertEqual(try Data(contentsOf: file), bad)
        XCTAssertTrue(store.add(root.appendingPathComponent("keep").path, category: .other))
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("IgnoreList.json.unreadable-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), bad)
    }

    func testUnsupportedVersionFailsClosedWithoutOverwriting() throws {
        let (root, defaults, store) = try fixture()
        _ = store.snapshot()
        let file = root.appendingPathComponent("data/IgnoreList.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["version"] = 9_999
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: file)
        let future = IgnoreListStore(fileURL: file, defaults: defaults)
        XCTAssertTrue(future.snapshot().entries.isEmpty)
        XCTAssertNotNil(future.takeNotice())
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testLegacyPathsMigrateOnceWithoutChangingDefaultsOrReappearingAfterRemoval() throws {
        let (root, defaults, store) = try fixture()
        let path = root.appendingPathComponent("legacy").path
        defaults.set([path, path], forKey: ScanExclusionService.defaultsKey)
        let entry = try XCTUnwrap(store.snapshot().entries.first)
        XCTAssertEqual(entry.category, .other)
        XCTAssertEqual(store.snapshot().entries.count, 1)
        XCTAssertEqual(defaults.stringArray(forKey: ScanExclusionService.defaultsKey), [path, path])
        XCTAssertTrue(store.remove(entry))
        let reloaded = IgnoreListStore(fileURL: root.appendingPathComponent("data/IgnoreList.json"), defaults: defaults)
        XCTAssertTrue(reloaded.snapshot().entries.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: ScanExclusionService.defaultsKey), [path, path])
    }

    func testScanExclusionBridgeReadsAndRemovesCanonicalOtherEntries() throws {
        let (root, defaults, store) = try fixture()
        let path = root.appendingPathComponent("legacy").path
        defaults.set([path], forKey: ScanExclusionService.defaultsKey)
        XCTAssertEqual(ScanExclusionService.excludedPaths(defaults: defaults, store: store), [PathSafety.normalizedPath(path)])
        ScanExclusionService.remove(path, defaults: defaults, store: store)
        XCTAssertTrue(store.snapshot().entries.isEmpty)
        _ = store.add(root.appendingPathComponent("new").path, category: .other)
        XCTAssertEqual(ScanExclusionService.excludedPaths(defaults: defaults, store: store), store.snapshot().paths(for: .other))
        XCTAssertEqual(defaults.stringArray(forKey: ScanExclusionService.defaultsKey), [path])
    }

    func testLegacyVersionIsVirtualAndFutureVersionStillAppears() throws {
        let (root, defaults, store) = try fixture()
        let path = root.appendingPathComponent("App.app").path
        let app = AppUpdateTestFixtures.application(path: path, availableVersion: "2.0", status: .updateAvailable)
        AppUpdateIgnoreService.ignore(app, defaults: defaults)
        let snapshot = store.snapshot()
        let entry = try XCTUnwrap(snapshot.entries.first)
        XCTAssertEqual(entry.target.latestVersion, "2.0")
        XCTAssertTrue(entry.detail.contains("2.0"))
        XCTAssertTrue(snapshot.ignoresApplication(bundleIdentifier: app.bundleIdentifier, path: path, category: .updates, latestVersion: "2.0"))
        XCTAssertFalse(snapshot.ignoresApplication(bundleIdentifier: app.bundleIdentifier, path: path, category: .updates, latestVersion: "3.0"))
        XCTAssertTrue(AppUpdateIgnoreService.isIgnored(app, defaults: defaults))
        XCTAssertTrue(store.remove(entry))
        XCTAssertFalse(AppUpdateIgnoreService.isIgnored(app, defaults: defaults))
    }

    func testPermanentUpdateIgnoreUsesBundleAndNormalizedPath() throws {
        let (root, _, store) = try fixture()
        let path = root.appendingPathComponent("App.app").path
        XCTAssertTrue(store.add(.application(bundleIdentifier: " com.fixture.app ", path: path), category: .updates))
        let snapshot = store.snapshot()
        for version in ["2", "3", "10"] {
            XCTAssertTrue(snapshot.ignoresApplication(bundleIdentifier: "com.fixture.app", path: path, category: .updates, latestVersion: version))
        }
        XCTAssertFalse(snapshot.ignoresApplication(bundleIdentifier: "com.fixture.other", path: path, category: .updates))
        XCTAssertFalse(snapshot.ignoresApplication(bundleIdentifier: "com.fixture.app", path: path + "2", category: .updates))
    }

    func testComponentPrefixAndCategoryIsolation() throws {
        let (root, _, store) = try fixture()
        let path = root.appendingPathComponent("a/b").path
        XCTAssertTrue(store.add(path, category: .duplicates))
        let snapshot = store.snapshot()
        XCTAssertTrue(snapshot.ignores(path: path + "/file", category: .duplicates))
        XCTAssertTrue(snapshot.ignores(path: path, category: .duplicates))
        XCTAssertFalse(snapshot.ignores(path: path + "c/file", category: .duplicates))
        XCTAssertFalse(snapshot.ignores(path: path, category: .similar))
        XCTAssertFalse(snapshot.ignores(path: root.appendingPathComponent("a").path, category: .duplicates))
        XCTAssertTrue(snapshot.ignores(path: root.appendingPathComponent("a").path, category: .duplicates, includingDescendants: true))
    }

    func testSymlinkUsesPathSafetyNormalization() throws {
        let (root, _, store) = try fixture()
        let destination = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        XCTAssertTrue(store.add(link.path, category: .other))
        XCTAssertEqual(store.snapshot().entries.first?.target.path, PathSafety.normalizedPath(destination.path))
        for category in IgnoreCategory.allCases {
            XCTAssertTrue(store.snapshot().ignores(path: destination.appendingPathComponent("file").path, category: category))
        }
    }

    func testConcurrentWritesAndImmutableSnapshot() throws {
        let (root, defaults, store) = try fixture()
        let before = store.snapshot()
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            _ = store.add(root.appendingPathComponent("item-\(index)").path, category: .downloads)
            _ = store.snapshot()
        }
        XCTAssertTrue(before.entries.isEmpty)
        XCTAssertEqual(store.snapshot().entries.count, 32)
        XCTAssertEqual(IgnoreListStore(fileURL: root.appendingPathComponent("data/IgnoreList.json"), defaults: defaults).snapshot().entries.count, 32)
    }

    func testBatchUndoAndDuplicateAdd() throws {
        let (root, _, store) = try fixture()
        let first = root.appendingPathComponent("first").path
        XCTAssertTrue(store.add(first, category: .other))
        let more = ["second", "third"].map { IgnoreListTarget(path: root.appendingPathComponent($0).path) }
        XCTAssertEqual(store.add(more, category: .other), 2)
        XCTAssertFalse(store.add(first, category: .other))
        XCTAssertTrue(store.undoLastAdd())
        XCTAssertEqual(store.snapshot().entries.map(\.target.path), [PathSafety.normalizedPath(first)])
        XCTAssertFalse(store.undoLastAdd())
    }
}

@MainActor
final class SettingsIgnoreListD207Tests: XCTestCase {
    @MainActor
    func testAddRemoveUndoAndExternalRefresh() throws {
        let root = try TestFileSystem.makeHome(for: self)
        let store = IgnoreListStore(fileURL: root.appendingPathComponent("IgnoreList.json"), defaults: TestPreferenceDomain.make(for: self))
        let model = SettingsIgnoreListModel(store: store)
        model.category = .mailAttachments
        model.add([IgnoreListTarget(path: root.appendingPathComponent("attachment").path)])
        XCTAssertEqual(model.visibleEntries.count, 1)
        model.undoLastAdd()
        XCTAssertTrue(model.visibleEntries.isEmpty)
        model.add([IgnoreListTarget(path: root.appendingPathComponent("attachment").path)])
        model.remove(Set(model.visibleEntries.map(\.id)))
        XCTAssertTrue(model.visibleEntries.isEmpty)
        _ = store.add(root.appendingPathComponent("external").path, category: .mailAttachments)
        model.refresh()
        XCTAssertEqual(model.visibleEntries.count, 1)
    }

    func testBackgroundAddPublishesRefreshOnMainQueue() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let store = IgnoreListStore(fileURL: root.appendingPathComponent("IgnoreList.json"), defaults: TestPreferenceDomain.make(for: self))
        let model = SettingsIgnoreListModel(store: store)
        let refreshed = expectation(description: "忽略列表刷新")
        let observation = model.$entries.dropFirst().sink { entries in
            if entries.count == 1 { refreshed.fulfill() }
        }
        await Task.detached { _ = store.add(root.appendingPathComponent("background").path, category: .systemJunk) }.value
        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertEqual(model.entries.count, 1)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testApplicationCategoryAndAllElevenCategories() throws {
        XCTAssertEqual(IgnoreCategory.allCases.count, 11)
        let root = try TestFileSystem.makeHome(for: self)
        let store = IgnoreListStore(fileURL: root.appendingPathComponent("IgnoreList.json"), defaults: TestPreferenceDomain.make(for: self))
        let model = SettingsIgnoreListModel(store: store)
        model.category = .updates
        let path = root.appendingPathComponent("Fixture.app").path
        model.add([.application(bundleIdentifier: "com.fixture.app", path: path)], names: [path: "夹具"])
        XCTAssertEqual(model.visibleEntries.first?.displayName, "夹具")
        XCTAssertNil(model.visibleEntries.first?.target.latestVersion)
        model.undoLastAdd()
        XCTAssertTrue(model.entries.isEmpty)
    }
}

@MainActor
final class AppUpdateIgnoreD207Tests: XCTestCase {
    func testPermanentIgnoreExcludesAllThreeCountsAndBatchButKeepsIgnoredRow() throws {
        let home = try TestFileSystem.makeHome(for: self)
        let store = IgnoreListStore(fileURL: home.appendingPathComponent("IgnoreList.json"), defaults: TestPreferenceDomain.make(for: self))
        let apps = try ["keep", "update"].map { id in
            let url = home.appendingPathComponent(id + ".app")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return AppUpdateTestFixtures.strictHomebrewApplication(id: id, path: url.path)
        }
        _ = store.add(.application(bundleIdentifier: apps[0].bundleIdentifier, path: apps[0].path), category: .updates)
        let filtered = store.snapshot().applying(to: apps)
        let summary = AppScanSummary(sessionID: UUID(), applications: filtered)
        XCTAssertEqual(filtered[0].updateStatus, .ignored)
        XCTAssertFalse(filtered[0].hasConfirmedPresentableUpdate)
        XCTAssertFalse(filtered[0].canJoinAutomaticUpdateBatch)
        XCTAssertFalse(filtered[0].canJoinAutomaticUpdatePlan)
        XCTAssertFalse(filtered[0].canJoinSelectedUpdateBatch)
        XCTAssertEqual(summary.confirmedUpdateCount, 1, "D207＋旧值 2：忽略应用不计入更新数")
        XCTAssertEqual(AppUpdateCatalogSnapshot(summary: summary).confirmedUpdateCount, 1)
        XCTAssertEqual(LastAppScanSummary(summary: summary).confirmedUpdateCount, 1)
        XCTAssertEqual(AppUpdateLightfieldPresentation(summary: summary).confirmedUpdateCount, 1)
        XCTAssertEqual(summary.ignoredCount, 1)
        XCTAssertEqual(AppUpdateCatalogSnapshot(summary: summary).entries.count, 2)
        XCTAssertEqual(AppUpdateLightfieldPresentation(summary: summary).entries.count, 2)
        XCTAssertEqual(ApplicationUpdatePlanBuilder().build(applications: filtered).batchApplicationIDs, ["update"])
    }
}

@MainActor
final class D207IgnoreScannerTests: XCTestCase {
    private func fixture() throws -> (URL, IgnoreListStore) {
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        return (home, IgnoreListStore(fileURL: home.appendingPathComponent("IgnoreList.json"), defaults: TestPreferenceDomain.make(for: self)))
    }

    func testCleanupGroupsShareScopeAndCategoryIsolation() async throws {
        let (home, store) = try fixture()
        let rules = try CleanupRuleSetLoader.loadBundled().rules
        let original = try XCTUnwrap(rules.first { $0.id == "system.user-caches" })
        let cache = try CleanupRuleTestFixtures.replacing(original, fields: ["minimumBytes": 1])
        try CleanupRuleTestFixtures.seed(cache, home: home)
        let fileSystem = RuleTestReadOnlyFileSystem(root: home)
        let scanner = try ReadOnlyCleanupScanner(fileSystem: fileSystem, ruleSet: CleanupRuleTestFixtures.set([cache]))
        let baseline = try await scanner.scan(request: .init(userHomeURL: home)) { _ in }
        XCTAssertFalse(baseline.candidates.isEmpty)
        let path = try XCTUnwrap(baseline.candidates.first?.sourceURL.path)
        _ = store.add(path, category: .aiClutter)
        let unrelated = try await scanner.scan(request: .init(userHomeURL: home, ignoreList: store.snapshot())) { _ in }
        XCTAssertEqual(unrelated.candidates.count, baseline.candidates.count)
        _ = store.add(path, category: .systemJunk)
        let ignored = try await scanner.scan(request: .init(userHomeURL: home, ignoreList: store.snapshot())) { _ in }
        XCTAssertFalse(ignored.candidates.contains { $0.sourceURL.path == path })
        XCTAssertEqual(ignored.metrics.ignoredItemCount, 1)
        for rule in rules {
            let category = IgnoreCategory.cleanup(for: rule)
            switch CareJunkGroup.group(for: rule) {
            case .systemJunk, .developerJunk, .filesToReview: XCTAssertEqual(category, .systemJunk, rule.id)
            case .aiClutter: XCTAssertEqual(category, .aiClutter, rule.id)
            case .mailAttachments: XCTAssertEqual(category, .mailAttachments, rule.id)
            case .trashBins: XCTAssertEqual(category, .other, rule.id)
            }
        }
    }

    func testPartialRescanRetainsAndThenReplacesIgnoredCountsByRule() async throws {
        let (home, store) = try fixture()
        let all = try CleanupRuleSetLoader.loadBundled().rules
        let rules = try ["system.user-caches", "system.user-logs"].map { id in
            try CleanupRuleTestFixtures.replacing(XCTUnwrap(all.first { $0.id == id }), fields: ["minimumBytes": 1])
        }
        for rule in rules { try CleanupRuleTestFixtures.seed(rule, home: home) }
        let set = CleanupRuleTestFixtures.set(rules)
        let scanner = try ReadOnlyCleanupScanner(fileSystem: RuleTestReadOnlyFileSystem(root: home), ruleSet: set)
        let baseline = try await scanner.scan(request: .init(userHomeURL: home)) { _ in }
        let path = try XCTUnwrap(baseline.candidates.first { $0.ruleID == "system.user-caches" }?.sourceURL.path)
        _ = store.add(path, category: .systemJunk)
        let original = try await scanner.scan(request: .init(userHomeURL: home, ignoreList: store.snapshot())) { _ in }
        XCTAssertEqual(original.metrics.ignoredItemCount, 1)
        let logs = try ReadOnlyCleanupScanner(fileSystem: RuleTestReadOnlyFileSystem(root: home),
            ruleSet: CleanupScanOperations.scopedRuleSet(set, includedCategoryIDs: nil, includedRuleIDs: ["system.user-logs"]))
        let logsRescan = try await logs.scan(request: .init(userHomeURL: home, ignoreList: store.snapshot(), sessionID: original.id)) { _ in }
        let merged = try XCTUnwrap(original.mergingRescan(logsRescan, ofRules: ["system.user-logs"]))
        XCTAssertEqual(merged.metrics.ignoredItemCount, 1)
        XCTAssertTrue(store.undoLastAdd())
        let cache = try ReadOnlyCleanupScanner(fileSystem: RuleTestReadOnlyFileSystem(root: home),
            ruleSet: CleanupScanOperations.scopedRuleSet(set, includedCategoryIDs: nil, includedRuleIDs: ["system.user-caches"]))
        let cacheRescan = try await cache.scan(request: .init(userHomeURL: home, ignoreList: store.snapshot(), sessionID: original.id)) { _ in }
        XCTAssertEqual(try XCTUnwrap(merged.mergingRescan(cacheRescan, ofRules: ["system.user-caches"])).metrics.ignoredItemCount, 0)
    }

    func testDuplicateAndSimilarCategoriesDoNotHideEachOther() throws {
        let (home, store) = try fixture()
        for name in ["a.bin", "b.bin", "c.bin"] {
            try CleanupRuleTestFixtures.write(home.appendingPathComponent(name), bytes: 8_192)
        }
        _ = store.add(home.appendingPathComponent("a.bin").path, category: .duplicates)
        var configuration = DuplicateFileScanner.Configuration(roots: [home.path], excludedPaths: [], maxScanSeconds: 20,
            candidateRules: [], ignoreList: store.snapshot())
        let report = DuplicateFileScanner.scanReport(configuration: configuration)
        XCTAssertEqual(report.exactGroups.count, 1)
        XCTAssertEqual(report.exactGroups.first?.files.count, 2)
        XCTAssertEqual(report.coverage.ignoredCount(for: .duplicates), 1)
        XCTAssertEqual(report.coverage.ignoredCount(for: .similar), 0)
        _ = store.add(home.path, category: .other)
        configuration.ignoreList = store.snapshot()
        let allIgnored = DuplicateFileScanner.scanReport(configuration: configuration)
        XCTAssertTrue(allIgnored.exactGroups.isEmpty)
        XCTAssertEqual(allIgnored.coverage.ignoredCount(for: .duplicates), 1)
    }

    func testLegacyPathExclusionCountsWithoutCountingPolicySkips() throws {
        let (home, _) = try fixture()
        let data = home.appendingPathComponent("files")
        try CleanupRuleTestFixtures.write(data.appendingPathComponent("keep.bin"))
        let configuration = DuplicateFileScanner.Configuration(roots: [data.path], excludedPaths: [data.path], candidateRules: [])
        let report = DuplicateFileScanner.scanReport(configuration: configuration)
        XCTAssertEqual(report.coverage.ignoredCount(for: .duplicates), 1)
        let policyOnly = DuplicateFileScanCoverage(roots: [.init(rootPath: "/System", status: .skipped, skipReason: .excluded,
            scannedDirectories: 0, scannedFiles: 0, scannedBytes: 0, skippedPaths: [])],
            reachedTimeLimit: false, reachedFileLimit: false, reachedDirectoryLimit: false, reachedResultLimit: false,
            ignoredOtherItems: 0)
        XCTAssertEqual(policyOnly.ignoredCount(for: .duplicates), 0, "系统保护范围不冒充用户忽略数")
    }

    func testSimilarIgnoreFiltersImageCandidatesIndependently() throws {
        let (home, store) = try fixture()
        let images = home.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<48 {
            for x in 0..<64 { bitmap.setColor(NSColor(deviceWhite: x < 32 ? 0.2 : 0.9, alpha: 1), atX: x, y: y) }
        }
        let first = images.appendingPathComponent("first.png")
        let second = images.appendingPathComponent("second.jpg")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: first)
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])).write(to: second)
        var configuration = DuplicateFileScanner.Configuration(roots: [images.path], excludedPaths: [], maxScanSeconds: 20, candidateRules: [.similarImage])
        XCTAssertEqual(DuplicateFileScanner.scanReport(configuration: configuration).candidates.count, 1)
        _ = store.add(first.path, category: .similar)
        configuration.ignoreList = store.snapshot()
        let filtered = DuplicateFileScanner.scanReport(configuration: configuration)
        XCTAssertTrue(filtered.candidates.isEmpty)
        XCTAssertEqual(filtered.coverage.ignoredCount(for: .similar), 1)
        XCTAssertEqual(filtered.coverage.ignoredCount(for: .duplicates), 0)
    }

    func testLargeFilesSkipIgnoredAggregateAndReportCountWhileMapKeepsIt() throws {
        let (home, store) = try fixture()
        let folder = home.appendingPathComponent("files")
        try CleanupRuleTestFixtures.write(folder.appendingPathComponent("keep.bin"))
        try CleanupRuleTestFixtures.write(folder.appendingPathComponent("show.bin"))
        _ = store.add(folder.appendingPathComponent("keep.bin").path, category: .largeAndOld)
        let scanner = DiskScanner(excludedPaths: [], largeFileRoots: [folder.path], ignoreList: store.snapshot())
        let result = scanner.largeFileListing(deadline: Date().addingTimeInterval(20), minimumBytes: 1)
        XCTAssertEqual(result.entries.map(\.name), ["show.bin"])
        XCTAssertEqual(result.summary.ignoredItemCount, 1)
        let map = try scanner.storageMapAnalysis(target: .init(path: folder.path, title: "夹具", kind: .homeDirectory))
        XCTAssertEqual(map.rootSnapshot.entries.count, 2, "D207：空间地图保留忽略项")
    }

    func testLargeFileAggregateContainingIgnoredChildIsOmitted() throws {
        let (home, store) = try fixture()
        let folder = home.appendingPathComponent("files")
        let keep = folder.appendingPathComponent("aggregate/keep.bin")
        try CleanupRuleTestFixtures.write(keep)
        _ = store.add(keep.path, category: .largeAndOld)
        let result = DiskScanner(excludedPaths: [], largeFileRoots: [folder.path], ignoreList: store.snapshot())
            .largeFileListing(deadline: Date().addingTimeInterval(20), minimumBytes: 1)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.summary.ignoredItemCount, 1)
    }

    func testMalwareDoesNotReadIgnoredFilesAndCountsThem() async throws {
        let (home, store) = try fixture()
        for folder in ["Downloads", "Apps", "Support", "Launch"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let rule = home.appendingPathComponent("fixture.yara")
        try Data("rule Fixture { strings: $a = \"d207-marker\" condition: $a }".utf8).write(to: rule)
        let target = home.appendingPathComponent("Downloads/keep")
        try Data("#!/bin/sh\nd207-marker".utf8).write(to: target)
        _ = store.add(target.path, category: .malware)
        let snapshot = store.snapshot()
        var scanner = MalwareScanner(roots: .init(launchDirectories: [home.appendingPathComponent("Launch")], applicationDirectories: [home.appendingPathComponent("Apps")],
            downloads: home.appendingPathComponent("Downloads"), applicationSupport: home.appendingPathComponent("Support"), ruleFiles: [rule]),
            signature: { _ in .unsigned }, isAppleApplication: { _ in false }, ignoreList: { snapshot })
        let ignoredReads = IgnoreListScanCounter()
        scanner.reader.willRead = { url in
            if url.path == target.path { ignoredReads.record(url.path, category: .malware) }
        }
        let outcome = await scanner.scan { _ in }
        XCTAssertEqual(ignoredReads.counts[.malware] ?? 0, 0)
        XCTAssertFalse(outcome.rulesUnavailable)
        XCTAssertTrue(outcome.threats.isEmpty)
        XCTAssertEqual(outcome.checkedFiles, 0)
        XCTAssertEqual(outcome.counts.ignored, 1)
    }

    func testProjectArtifactNotListedWhenPathIgnored() throws {
        let (home, store) = try fixture()
        let project = home.appendingPathComponent("project")
        try CleanupRuleTestFixtures.write(project.appendingPathComponent("package.json"), bytes: 100)
        try CleanupRuleTestFixtures.write(project.appendingPathComponent("node_modules/generated.bin"))
        _ = store.add(project.appendingPathComponent("node_modules").path, category: .systemJunk)
        let scanner = ProjectArtifactScanner(fileSystem: RuleTestReadOnlyFileSystem(root: home), home: home, ignoreList: store.snapshot())
        let result = try scanner.scanSynchronously(roots: [project])
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.session.metrics.ignoredItemCount, 1)
    }

    func testLeftoverAppIgnoreKeepsResidualButPathIgnoreRemovesIt() throws {
        let (home, store) = try fixture()
        let residual = home.appendingPathComponent("Library/Caches/com.fixture.removed")
        try CleanupRuleTestFixtures.write(residual.appendingPathComponent("generated"))
        _ = store.add(.application(bundleIdentifier: "com.fixture.removed", path: home.appendingPathComponent("Removed.app").path), category: .uninstaller)
        var scanner = LeftoverScanner(homeDirectory: home, isRegistered: { _ in false }, hasLaunchJob: { _ in false }, measuresSizes: false, ignoreList: store.snapshot(), containsSymbolicLink: { path in
            (try? RuleTestReadOnlyFileSystem(root: home).snapshot(at: URL(fileURLWithPath: path)))?.hasSymbolicLinkComponent ?? true
        })
        XCTAssertEqual(scanner.scan().count, 1)
        XCTAssertTrue(store.add(residual.path, category: .uninstaller))
        scanner.ignoreList = store.snapshot()
        let report = scanner.scanReport()
        XCTAssertTrue(report.groups.isEmpty)
        XCTAssertEqual(report.ignoredCount, 1)
    }

    @MainActor
    func testUninstallInventoryExcludesIgnoredAppsWithoutReadingDisk() throws {
        let (home, store) = try fixture()
        let path = home.appendingPathComponent("Fixture.app").path
        let item = InstalledAppItem(id: path, name: "Fixture", bundleIdentifier: "com.fixture.app", path: path, version: "1", build: "1",
            category: "", appDescription: "", sizeBytes: 100, source: "", modifiedAt: nil, relatedPaths: [], relatedItems: [], status: .installed)
        _ = store.add(.application(bundleIdentifier: item.bundleIdentifier, path: path), category: .uninstaller)
        let model = ApplicationsManagerModel()
        model.load(inventory: [item], readsDisk: false, ignoreList: store.snapshot())
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.unusedEntries.isEmpty)
        XCTAssertEqual(model.ignoredApplicationCount, 1)
    }

    func testDownloadsAreFilteredAndSnapshotStaysStable() throws {
        let (home, store) = try fixture()
        let path = home.appendingPathComponent("Downloads/Fixture.dmg")
        try CleanupRuleTestFixtures.write(path)
        _ = store.add(path.path, category: .downloads)
        var scanner = UnusedInstallerScanner(homeDirectory: home, search: { _ in [path.path] }, ignoreList: store.snapshot(), containsSymbolicLink: { path in
            (try? RuleTestReadOnlyFileSystem(root: home).snapshot(at: URL(fileURLWithPath: path)))?.hasSymbolicLinkComponent ?? true
        })
        XCTAssertTrue(store.undoLastAdd())
        let frozen = scanner.scanReport()
        XCTAssertTrue(frozen.files.isEmpty)
        XCTAssertEqual(frozen.ignoredCount, 1)
        scanner.ignoreList = store.snapshot()
        XCTAssertEqual(scanner.scan().count, 1)
    }
}
