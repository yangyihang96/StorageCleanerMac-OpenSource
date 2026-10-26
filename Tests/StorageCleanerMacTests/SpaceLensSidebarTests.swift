import Foundation
import os
import XCTest
@testable import StorageCleanerMac

@MainActor
final class SpaceLensSidebarTests: XCTestCase {
    private func index() -> StorageMapAnalysisIndex {
        SpaceMapMemoryIndex.make(rootPath: "/Fixture/Home", children: [
            .directory("node_modules", [.file("dependency.js", 400_000_000)]), .file("package.json", 1),
            .directory("Library", [.directory("Caches", [.file("cache.db", 300_000_000)])]),
            .directory(".build", [.file("debug.o", 200_000_000)]), .file("Package.swift", 1),
            .directory(".codex", [.directory("worktrees", (0..<3).map { .directory("tree-\($0)", [.file("data", 40_000_000)]) })])
        ])
    }

    func testFindingsResolveToTheCanonicalParentSnapshotEntries() throws {
        let index = index()
        let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: index.rootPath))
        let findings = try XCTUnwrap(SpaceMapInsights.worthALook(index: index, purposes: purposes, limit: 6, minimumBytes: 64 << 20))
        let rows = try XCTUnwrap(SpaceLensWorthALook.rows(findings, index: index, homePath: index.rootPath))
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map(\.entry.sizeBytes), [400_000_000, 300_000_000, 200_000_000, 120_000_000])
        for row in rows {
            let parent = DiskScanner.storageMapParentPath(row.entry.path)
            let canonical = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: parent, using: index)
            XCTAssertEqual(row.entry, canonical.entries.first { $0.path == row.entry.path })
        }
    }

    func testFindingLimitAndOrderingAreProvidedByTheInsightsAlgorithm() throws {
        let index = SpaceMapMemoryIndex.make(children: (0..<12).map { .directory("project-\($0)", [
            .directory("node_modules", [.file("library", Int64(100_000_000 + $0))]), .file("package.json", 1)
        ]) })
        let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: index.rootPath))
        let findings = try XCTUnwrap(SpaceMapInsights.worthALook(index: index, purposes: purposes, limit: 6, minimumBytes: 64 << 20))
        let rows = try XCTUnwrap(SpaceLensWorthALook.rows(findings, index: index, homePath: index.rootPath))
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.map(\.entry.sizeBytes), (6..<12).reversed().map { Int64(100_000_000 + $0) })
    }

    func testSubtitlesAndRelativeLocationsInBothLanguages() throws {
        let index = index()
        let findings = [SpaceMapInsight(path: index.rootPath + "/node_modules", bytes: 400_000_000,
                                        finding: .reclaimable(.reinstallableDependencies)),
                        SpaceMapInsight(path: index.rootPath + "/.codex/worktrees", bytes: 120_000_000,
                                        finding: .worktrees(count: 3))]
        let rows = try XCTUnwrap(SpaceLensWorthALook.rows(findings, index: index, homePath: index.rootPath))
        withLanguage(.zhHans) {
            XCTAssertEqual(rows[0].subtitle, "可重装依赖 · ~")
            XCTAssertEqual(rows[1].subtitle, "AI 工作区 · 3 个工作树")
        }
        withLanguage(.english) {
            XCTAssertEqual(rows[0].subtitle, "Reinstallable Dependencies · ~")
            XCTAssertEqual(rows[1].subtitle, "AI Workspaces · 3 worktrees")
        }
        XCTAssertEqual(SpaceLensWorthALook.location(parent: index.rootPath + "/Library", root: index.rootPath, home: index.rootPath), "Library")
        XCTAssertEqual(SpaceLensWorthALook.location(parent: "/analysis", root: "/analysis", home: "/home"), ".")
        XCTAssertEqual(SpaceLensWorthALook.location(parent: "/Library", root: "/", home: "/home"), "Library")
    }

    func testWorktreeSubtitlesUsePurposeTitleAndSingularOrPluralInBothLanguages() throws {
        let index = index()
        let findings = [1, 3].map { count in
            SpaceMapInsight(path: index.rootPath + "/.codex/worktrees", bytes: 120_000_000, finding: .worktrees(count: count))
        }
        let rows = try XCTUnwrap(SpaceLensWorthALook.rows(findings, index: index, homePath: index.rootPath))
        withLanguage(.zhHans) {
            XCTAssertEqual(rows.map(\.subtitle), ["AI 工作区 · 1 个工作树", "AI 工作区 · 3 个工作树"])
        }
        withLanguage(.english) {
            XCTAssertEqual(rows.map(\.subtitle), ["AI Workspaces · 1 worktree", "AI Workspaces · 3 worktrees"])
        }
    }

    func testWorthEmptyAndFindingCopyInBothLanguages() {
        withLanguage(.zhHans) {
            XCTAssertEqual(SpaceLensWorthALook.emptyTitle, "没有发现值得一看的项目")
            XCTAssertEqual(SpaceLensWorthALook.findingTitle, "正在查找…")
            XCTAssertEqual(SpaceLensWorthALook.emptyDescription, "这里只列出 64 MB 以上、可再生或可重装的目录，以及 AI 工作区里的工作树。")
        }
        withLanguage(.english) {
            XCTAssertEqual(SpaceLensWorthALook.emptyTitle, "Nothing to Look At")
            XCTAssertEqual(SpaceLensWorthALook.findingTitle, "Finding…")
            XCTAssertEqual(SpaceLensWorthALook.emptyDescription,
                           "Only regenerable or reinstallable folders of at least 64 MB, and worktrees in AI workspaces, are listed here.")
        }
    }

    func testWorthTriggersClassificationWithoutALayoutAndCachesByVersion() async throws {
        let source = SpaceMapTreemapSource()
        let index = index()
        await source.findWorthALook(index: index, version: 1, homePath: index.rootPath)
        XCTAssertNotNil(source.classification(for: 1))
        XCTAssertEqual(source.worthRows.count, 4)
        XCTAssertEqual(source.cachedLayoutCount, 0)
        let empty = SpaceMapMemoryIndex.make(rootPath: index.rootPath, children: [])
        await source.findWorthALook(index: empty, version: 1, homePath: index.rootPath)
        XCTAssertEqual(source.worthRows.count, 4)
        await source.findWorthALook(index: empty, version: 2, homePath: index.rootPath)
        XCTAssertTrue(source.worthRows.isEmpty)
        XCTAssertEqual(source.worthVersion, 2)
        XCTAssertFalse(source.isFinding)
    }

    func testCancelledWorthDoesNotPublish() async {
        let source = SpaceMapTreemapSource()
        let index = index()
        let task = Task { await source.findWorthALook(index: index, version: 1, homePath: index.rootPath) }
        task.cancel()
        await task.value
        XCTAssertNil(source.worthVersion)
        XCTAssertTrue(source.worthRows.isEmpty)
    }

    func testOverlappingWorthRequestsPublishOnlyTheNewestVersion() async {
        let began = expectation(description: "older worth search started")
        let gate = DispatchSemaphore(value: 0)
        let full = index()
        let empty = SpaceMapMemoryIndex.make(rootPath: full.rootPath, children: [])
        let source = SpaceMapTreemapSource(computeWorth: { index, purposes, homePath in
            if !(index.childrenByDirectory[index.rootPath] ?? []).isEmpty { began.fulfill(); gate.wait() }
            return SpaceMapTreemapSource.computeWorth(index, purposes, homePath)
        })
        // Neither request is cancelled; the older one finishes last.
        let older = Task { await source.findWorthALook(index: full, version: 1, homePath: full.rootPath) }
        await fulfillment(of: [began], timeout: 2)
        await source.findWorthALook(index: empty, version: 2, homePath: full.rootPath)
        XCTAssertEqual(source.worthVersion, 2)
        gate.signal()
        await older.value
        XCTAssertEqual(source.worthVersion, 2)
        XCTAssertTrue(source.worthRows.isEmpty)
        XCTAssertFalse(source.isFinding)
    }

    private func filterIndex() -> StorageMapAnalysisIndex {
        SpaceMapMemoryIndex.make(children: [.directory("mov-folder", [.file("any.bin", 100)]),
            .directory("partial", [.file("clip.mov", 30), .file("skip.txt", 70)]), .file("skip.dat", 20)])
    }

    func testFilterTrimsWhitespaceAndBlankDoesNotCompute() async throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let source = SpaceMapTreemapSource(computeFilter: { index, key in
            reads.withLock { $0 += 1 }
            return SpaceMapTreemapSource.computeFilter(index, key)
        })
        let index = filterIndex()
        await source.filter(index: index, key: .init(version: 1, path: index.rootPath, keyword: " \n "), debounce: .zero)
        XCTAssertNil(source.filtered)
        XCTAssertEqual(reads.withLock { $0 }, 0)
        await source.filter(index: index, key: .init(version: 1, path: index.rootPath, keyword: " mov \n"), debounce: .zero)
        XCTAssertEqual(source.filtered?.result.keyword, "mov")
        XCTAssertEqual(reads.withLock { $0 }, 1)
    }

    func testFilterAndLayoutKeysIncludeVersionDirectoryAndTrimmedKeyword() {
        typealias Key = SpaceMapTreemapSource.FilterKey
        let key = Key(version: 1, path: "/analysis", keyword: " mov ")
        XCTAssertEqual(key, Key(version: 1, path: "/analysis/", keyword: "mov"))
        XCTAssertNotEqual(key, Key(version: 2, path: key.path, keyword: key.keyword))
        XCTAssertNotEqual(key, Key(version: 1, path: "/analysis/child", keyword: key.keyword))
        XCTAssertNotEqual(key, Key(version: 1, path: key.path, keyword: "txt"))
        let layout = SpaceMapTreemapSource.Key(path: key.path, size: CGSize(width: 600, height: 400), levels: 3, version: 1)
        XCTAssertNotEqual(layout, .init(path: key.path, size: layout.size, levels: 3, version: 1, keyword: "mov"))
    }

    func testListKeepsWholeAndPartialMatchesAtTheirOriginalSizes() throws {
        let index = filterIndex()
        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: index.rootPath, using: index)
        let result = try XCTUnwrap(SpaceMapTreemapFilter.filter(index: index, basePath: index.rootPath, keyword: "mov"))
        let entries = SpaceLensWorthALook.filteredEntries(snapshot.entries, filter: result)
        XCTAssertEqual(Set(entries.map(\.title)), ["mov-folder", "partial"])
        XCTAssertEqual(entries.map(\.sizeBytes), [100, 100])
        XCTAssertEqual(result.keep(forPath: "/analysis/mov-folder"), .whole)
        XCTAssertEqual(result.keep(forPath: "/analysis/partial"), .partial(bytes: 30, items: 1))
        XCTAssertEqual(SpaceLensWorthALook.filteredEntries(snapshot.entries, filter: nil), snapshot.entries)
        let tiles = SpaceMapTreemapSource.computeLayout(.init(snapshot: snapshot, index: index, filter: result),
            .init(path: index.rootPath, size: CGSize(width: 600, height: 400), levels: 3, version: 1, keyword: "mov"))
        XCTAssertFalse(tiles.isEmpty)
        for tile in tiles {
            if case let .entry(entry) = tile.kind { XCTAssertNotNil(result.keep(forPath: entry.path), entry.path) }
        }
    }

    func testFilterEmptyStateAndMatchingCountCopyInBothLanguages() throws {
        let result = try XCTUnwrap(SpaceMapTreemapFilter.filter(index: filterIndex(), basePath: "/analysis", keyword: "mov"))
        XCTAssertEqual(result.matchedItems, 3)
        XCTAssertEqual(result.matchedBytes, 130)
        withLanguage(.zhHans) {
            XCTAssertEqual(SpaceLensWorthALook.matchesTitle(result), "3 项匹配 · " + ByteFormat.storageString(130))
            XCTAssertEqual(SpaceLensWorthALook.emptyFilterTitle("mov"), "没有名称包含“mov”的项目")
        }
        withLanguage(.english) {
            XCTAssertEqual(SpaceLensWorthALook.matchesTitle(result), "3 matches · " + ByteFormat.storageString(130))
            XCTAssertEqual(SpaceLensWorthALook.emptyFilterTitle("mov"), "No items with names containing “mov”")
        }
    }

    func testFilterCacheReusesResultsAndSeparatesDirectoriesAndVersions() async {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let source = SpaceMapTreemapSource(computeFilter: { index, key in
            XCTAssertFalse(Thread.isMainThread)
            count.withLock { $0 += 1 }
            return SpaceMapTreemapSource.computeFilter(index, key)
        })
        let index = filterIndex()
        let key = SpaceMapTreemapSource.FilterKey(version: 1, path: index.rootPath, keyword: "mov")
        await source.filter(index: index, key: key, debounce: .zero)
        await source.filter(index: index, key: key, debounce: .zero)
        XCTAssertEqual(count.withLock { $0 }, 1)
        await source.filter(index: index, key: .init(version: 1, path: "/analysis/partial", keyword: "mov"), debounce: .zero)
        await source.filter(index: index, key: .init(version: 2, path: index.rootPath, keyword: "mov"), debounce: .zero)
        XCTAssertEqual(count.withLock { $0 }, 3)
        XCTAssertNil(source.activeFilter(version: 1, path: index.rootPath, keyword: "mov"))
    }

    func testThreeRapidFilterEditsOnlyComputeTheLastOne() async {
        let count = OSAllocatedUnfairLock(initialState: [String]())
        let source = SpaceMapTreemapSource(computeFilter: { index, key in
            count.withLock { $0.append(key.keyword) }
            return SpaceMapTreemapSource.computeFilter(index, key)
        })
        let index = filterIndex()
        let a = Task { await source.filter(index: index, key: .init(version: 1, path: index.rootPath, keyword: "m")) }
        await Task.yield()
        a.cancel()
        let b = Task { await source.filter(index: index, key: .init(version: 1, path: index.rootPath, keyword: "mo")) }
        await Task.yield()
        b.cancel()
        let c = Task { await source.filter(index: index, key: .init(version: 1, path: index.rootPath, keyword: "mov")) }
        await a.value; await b.value; await c.value
        XCTAssertEqual(count.withLock { $0 }, ["mov"])
        XCTAssertEqual(source.filtered?.key.keyword, "mov")
    }

    func testCancelledFilterCannotPublishOverANewerResult() async {
        let began = expectation(description: "old filter started")
        let gate = DispatchSemaphore(value: 0)
        let source = SpaceMapTreemapSource(computeFilter: { index, key in
            if key.keyword == "old" { began.fulfill(); gate.wait() }
            return SpaceMapTreemapFilter.filter(index: index, basePath: key.path, keyword: key.keyword)
        })
        let index = filterIndex()
        let old = Task { await source.filter(index: index, key: .init(version: 1, path: index.rootPath, keyword: "old"), debounce: .zero) }
        await fulfillment(of: [began], timeout: 2)
        old.cancel()
        await source.filter(index: index, key: .init(version: 1, path: index.rootPath, keyword: "mov"), debounce: .zero)
        gate.signal()
        await old.value
        XCTAssertEqual(source.filtered?.key.keyword, "mov")
    }

    func testOverlappingFilterRequestsPublishOnlyTheNewest() async {
        let began = expectation(description: "older filter started")
        let gate = DispatchSemaphore(value: 0)
        let source = SpaceMapTreemapSource(computeFilter: { index, key in
            if key.keyword == "old" { began.fulfill(); gate.wait() }
            return SpaceMapTreemapFilter.filter(index: index, basePath: key.path, keyword: key.keyword)
        })
        let index = filterIndex()
        // Neither request is cancelled; the older one finishes last.
        let older = Task { await source.filter(index: index, key: .init(version: 1, path: index.rootPath, keyword: "old"), debounce: .zero) }
        await fulfillment(of: [began], timeout: 2)
        await source.filter(index: index, key: .init(version: 1, path: index.rootPath, keyword: "mov"), debounce: .zero)
        gate.signal()
        await older.value
        XCTAssertEqual(source.filtered?.key.keyword, "mov")
    }

    func testActiveFilterKeepsOnlyTheSameVersionAndDirectory() async {
        let source = SpaceMapTreemapSource()
        let index = filterIndex()
        await source.filter(index: index, key: .init(version: 1, path: index.rootPath, keyword: "mov"), debounce: .zero)
        XCTAssertEqual(source.activeFilter(version: 1, path: index.rootPath, keyword: "mov")?.keyword, "mov")
        // The next keystroke keeps the last result while it debounces.
        XCTAssertEqual(source.activeFilter(version: 1, path: index.rootPath, keyword: "mo")?.keyword, "mov")
        XCTAssertNil(source.activeFilter(version: 1, path: index.rootPath + "/partial", keyword: "mov"))
        XCTAssertNil(source.activeFilter(version: 2, path: index.rootPath, keyword: "mov"))
        XCTAssertNil(source.activeFilter(version: 1, path: index.rootPath, keyword: " \n "))
    }

    func testEveryPurposeMapsToTheUserChosenGroup() {
        typealias Group = SpaceMapTreemapPainter.PurposeGroup
        let expected: [(SpaceMapPurpose, Group)] = [
            (.code, .development), (.toolchain, .development), (.git, .development), (.agentWorkspace, .development),
            (.cache, .caches), (.media, .personal), (.documents, .personal), (.synced, .personal), (.other, .other)
        ]
        XCTAssertEqual(Set(expected.map(\.0)), Set(SpaceMapPurpose.allCases))
        for (purpose, group) in expected {
            XCTAssertEqual(Group(purpose), group, purpose.rawValue)
            XCTAssertTrue(group.purposes.contains(purpose), purpose.rawValue)
        }
        XCTAssertEqual(Group.allCases.flatMap(\.purposes).count, 9)
    }

    func testPurposeGroupHexAndFillUseTheExactPaletteInBothAppearances() {
        typealias Group = SpaceMapTreemapPainter.PurposeGroup
        let expected: [(Group, UInt32, UInt32)] = [
            (.development, 0x3987E5, 0x2A78D6), (.caches, 0xD95926, 0xEB6834),
            (.personal, 0x199E70, 0x1BAF7A), (.other, 0x6E6B7B, 0xB6B3C2)
        ]
        for dark in [true, false] {
            for (group, darkHex, lightHex) in expected {
                let hex = dark ? darkHex : lightHex
                XCTAssertEqual(group.hex(dark: dark), hex, "\(group) dark=\(dark)")
                XCTAssertEqual(SpaceMapTreemapPainter.Fill.purpose(group).color(dark: dark), CareStudioPalette.color(hex))
            }
            XCTAssertEqual(Set(expected.map { $0.0.hex(dark: dark) }).count, 4)
        }
    }

    func testOtherPurposeStaysDistinctFromMergedAndRemainderNeutralInBothAppearances() {
        for dark in [true, false] {
            let other = SpaceMapTreemapPainter.PurposeGroup.other
            XCTAssertNotEqual(other.hex(dark: dark), 0x3A3A42)
            XCTAssertNotEqual(other.hex(dark: dark), 0xE8E8EE)
            XCTAssertNotEqual(SpaceMapTreemapPainter.Fill.purpose(other).color(dark: dark),
                              SpaceMapTreemapPainter.Fill.neutral.color(dark: dark))
            XCTAssertEqual(SpaceMapTreemapPainter.Fill.neutral.color(dark: dark),
                           CareStudioPalette.color(dark ? 0x3A3A42 : 0xE8E8EE))
        }
    }

    func testPurposeUsesDirectoryOrFileParentAndFallsBackBeforeClassification() throws {
        let index = index()
        let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: index.rootPath))
        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: index.rootPath + "/node_modules", using: index)
        let file = try XCTUnwrap(snapshot.entries.first)
        XCTAssertEqual(SpaceMapTreemapPainter.fill(for: file, mode: .purpose, purposes: purposes), .purpose(.caches))
        let root = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: index.rootPath, using: index)
        let directory = try XCTUnwrap(root.entries.first { $0.title == "node_modules" })
        XCTAssertEqual(SpaceMapTreemapPainter.fill(for: directory, mode: .purpose, purposes: purposes), .purpose(.caches))
        XCTAssertEqual(SpaceMapTreemapPainter.fill(for: file, mode: .purpose, purposes: nil), .category(.developer))
        XCTAssertEqual(SpaceMapTreemapPainter.fill(for: file, mode: .type, purposes: purposes), .category(.developer))
        let unknown = StorageTreemapEntry(id: "unknown", title: "unknown", path: "/elsewhere/file", sizeBytes: 1, kind: "file", isDirectory: false, childCount: 0)
        XCTAssertEqual(SpaceMapTreemapPainter.fill(for: unknown, mode: .purpose, purposes: purposes), .purpose(.other))
    }

    func testPurposeChangesOnlyFillAndKeepsNeutralAndDecorations() throws {
        let index = index()
        let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: index.rootPath))
        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: index.rootPath, using: index)
        let tiles = SpaceMapTreemapSource.computeLayout(.init(snapshot: snapshot, index: index),
            .init(path: index.rootPath, size: CGSize(width: 600, height: 400), levels: 3, version: 1))
        for tile in tiles {
            let type = SpaceMapTreemapPainter.decoration(for: tile, dark: true, purposes: purposes)
            let purpose = SpaceMapTreemapPainter.decoration(for: tile, dark: true, purposes: purposes, colorMode: .purpose)
            XCTAssertEqual(type.shade, purpose.shade)
            XCTAssertEqual(type.hatches, purpose.hatches)
            XCTAssertEqual(type.estimated, purpose.estimated)
        }
        let neutral = StorageTreemapEntry(id: "rest", title: "rest", path: "", sizeBytes: 10, kind: "other", isDirectory: false, childCount: 0, role: .measuredRemainder)
        XCTAssertEqual(SpaceMapTreemapPainter.fill(for: neutral, mode: .purpose, purposes: purposes), .neutral)
    }

    func testSizeFitsOnlyWhenTheWholeMeasuredWidthFits() {
        XCTAssertTrue(SpaceMapTreemapPainter.sizeFits(measuredWidth: 31.5, availableWidth: 31.5))
        XCTAssertFalse(SpaceMapTreemapPainter.sizeFits(measuredWidth: 31.5, availableWidth: 30.5))
        XCTAssertFalse(SpaceMapTreemapPainter.sizeFits(measuredWidth: 31.5, availableWidth: 0))
    }

    func testSizeCacheReusesBothDecisionsAndKeysTextFontAndAvailableWidth() {
        let cache = SpaceMapTreemapLabelCache()
        var calls = 0
        func fits(_ text: String = "11.2 GB", fontSize: CGFloat = 10, width: CGFloat = 31.5) -> Bool {
            cache.sizeFits(text, fontSize: fontSize, width: width, transitioning: false) { _ in calls += 1; return 31.5 }
        }
        XCTAssertTrue(fits())
        XCTAssertTrue(fits())
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(fits(width: 30.5))
        XCTAssertFalse(fits(width: 30.5))
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(fits("12.2 GB"))
        XCTAssertTrue(fits(fontSize: 11))
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(cache.count, 4)
    }

    func testSizeCacheReusesDuringTransitionsAndOmitsUnmeasuredSizes() {
        let cache = SpaceMapTreemapLabelCache()
        XCTAssertTrue(cache.sizeFits("11.2 GB", fontSize: 10, width: 31.5, transitioning: false) { _ in 31.5 })
        var calls = 0
        let measure: (String) -> CGFloat = { _ in calls += 1; return 31.5 }
        XCTAssertTrue(cache.sizeFits("11.2 GB", fontSize: 10, width: 31.5, transitioning: true, measure: measure))
        XCTAssertFalse(cache.sizeFits("11.2 GB", fontSize: 10, width: 30.5, transitioning: true, measure: measure))
        XCTAssertFalse(cache.sizeFits("11.2 GB", fontSize: 10, width: 0, transitioning: false, measure: measure))
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(cache.count, 1)
    }

    func testSizeAndNameCachesShareTheEntryLimit() {
        let cache = SpaceMapTreemapLabelCache(limit: 2)
        let label = SpaceMapTreemapPainter.Label(id: "name", clip: .zero,
            nameFrame: CGRect(x: 0, y: 0, width: 65, height: 15), sizeFrame: nil,
            name: "旅行剪辑-4K.mov", size: "100 B", fontSize: 12, weight: .semibold, sizeOnRight: false)
        _ = cache.name(for: label, transitioning: false) { CGFloat($0.count * 10) }
        _ = cache.sizeFits("11.2 GB", fontSize: 10, width: 40, transitioning: false) { _ in 31.5 }
        XCTAssertEqual(cache.count, 2)
        _ = cache.sizeFits("11.2 GB", fontSize: 10, width: 50, transitioning: false) { _ in 31.5 }
        XCTAssertEqual(cache.count, 1)
    }

    func testLegendsHaveStableSevenTypeAndFourPurposeItems() {
        XCTAssertEqual(SpaceMapTreemapPainter.legendItems(mode: .type).map(\.fill),
                       [.category(.application), .category(.system), .category(.developer), .category(.media), .category(.archive), .category(.document), .category(.other)])
        XCTAssertEqual(SpaceMapTreemapPainter.legendItems(mode: .purpose).map(\.fill),
                       [.purpose(.development), .purpose(.caches), .purpose(.personal), .purpose(.other)])
        XCTAssertEqual(SpaceMapTreemapPainter.legendItems(mode: .purpose).map(\.id),
                       ["purpose.development", "purpose.caches", "purpose.personal", "purpose.other"])
    }

    func testPurposeLegendTitlesAndHelpListEverySpecificPurposeInBothLanguages() {
        withLanguage(.zhHans) {
            let items = SpaceMapTreemapPainter.legendItems(mode: .purpose)
            XCTAssertEqual(items.map(\.title), ["开发", "缓存", "个人内容", "其他"])
            XCTAssertEqual(items.map(\.help), ["开发：代码、工具链、版本库、AI 工作区", "缓存：缓存", "个人内容：媒体、文档、同步盘", "其他：其他"])
        }
        withLanguage(.english) {
            let items = SpaceMapTreemapPainter.legendItems(mode: .purpose)
            XCTAssertEqual(items.map(\.title), ["Development", "Caches", "Personal", "Other"])
            XCTAssertEqual(items.map(\.help), ["Development: Code, Toolchains, Git, AI Workspaces", "Caches: Caches",
                                              "Personal: Media, Documents, Synced", "Other: Other"])
        }
        for language in [AppLanguage.zhHans, .english] {
            withLanguage(language) {
                let types = SpaceMapTreemapPainter.legendItems(mode: .type)
                XCTAssertEqual(types.map(\.help), types.map(\.title))
            }
        }
    }

    func testTypeHoverShowsSpecificPurposeAfterTypeInBothLanguages() throws {
        try assertHoverPurpose(mode: .type, chinese: "用途：AI 工作区", english: "Purpose: AI Workspaces")
    }

    func testPurposeHoverShowsSpecificPurposeAndGroupAfterTypeInBothLanguages() throws {
        try assertHoverPurpose(mode: .purpose, chinese: "用途：AI 工作区（开发）", english: "Purpose: AI Workspaces (Development)")
    }

    func testPurposeHoverAddsGroupOnlyWhenItContainsSeveralPurposesInBothLanguages() throws {
        let index = SpaceMapMemoryIndex.make(rootPath: "/Fixture/Home", children: [
            .directory(".codex", [.directory("worktrees", [.directory("tree", [.file("data", 100)])])]),
            .directory("Movies", [.file("clip.mov", 100)]),
            .directory("Library", [.directory("Caches", [.file("cache.db", 100)])]),
            .directory("Unclassified", [.file("data", 100)])
        ])
        let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: index.rootPath))
        let cases = [
            (".codex/worktrees/tree", "用途：AI 工作区（开发）", "Purpose: AI Workspaces (Development)"),
            ("Movies", "用途：媒体（个人内容）", "Purpose: Media (Personal)"),
            ("Library/Caches", "用途：缓存", "Purpose: Caches"),
            ("Unclassified", "用途：其他", "Purpose: Other")
        ]
        let scanner = DiskScanner(excludedPaths: [])
        for (relativePath, chinese, english) in cases {
            let path = index.rootPath + "/" + relativePath
            let snapshot = try scanner.storageMapSnapshot(at: DiskScanner.storageMapParentPath(path), using: index)
            let directory = try XCTUnwrap(snapshot.entries.first { $0.path == path })
            let file = try XCTUnwrap(scanner.storageMapSnapshot(at: path, using: index).entries.first)
            for entry in [directory, file] {
                let tile = SpaceMapTreemapLayout.Tile(kind: .entry(entry), frame: .zero, depth: 0, header: nil)
                for language in [AppLanguage.zhHans, .english] {
                    withLanguage(language) {
                        let card = SpaceMapTreemapPainter.hoverCard(for: tile, totalBytes: 1_000, index: index,
                            purposes: purposes, selection: .available, colorMode: .purpose)
                        let type = LightfieldFileCategory.category(entry.contentCategory).title
                        let lines = card.lines.map(\.text)
                        XCTAssertTrue(lines.contains(language == .zhHans ? chinese : english), path)
                        if let typeIndex = lines.firstIndex(of: type) {
                            XCTAssertEqual(lines[typeIndex + 1], language == .zhHans ? chinese : english, path)
                        } else {
                            XCTFail("Missing type line: \(path)")
                        }
                    }
                }
            }
        }
    }

    private func assertHoverPurpose(mode: SpaceMapColorMode, chinese: String, english: String) throws {
        let index = index()
        let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: index.rootPath))
        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: index.rootPath + "/.codex/worktrees", using: index)
        let directory = try XCTUnwrap(snapshot.entries.first)
        let file = try XCTUnwrap(DiskScanner(excludedPaths: []).storageMapSnapshot(at: directory.path, using: index).entries.first)
        for entry in [directory, file] {
            let tile = SpaceMapTreemapLayout.Tile(kind: .entry(entry), frame: .zero, depth: 0, header: nil)
            for language in [AppLanguage.zhHans, .english] {
                try withLanguage(language) {
                    let presentation = SpaceMapTreemapPainter.hoverPresentation(for: tile, highlightedID: nil,
                        snapshot: snapshot, index: index, purposes: purposes, colorMode: mode, selectionState: { _ in .available })
                    let card = try XCTUnwrap(presentation.card)
                    let type = LightfieldFileCategory.category(entry.contentCategory).title
                    let typeIndex = try XCTUnwrap(card.lines.firstIndex { $0.text == type })
                    XCTAssertEqual(card.lines[typeIndex + 1].text, language == .zhHans ? chinese : english)
                    let pending = SpaceMapTreemapPainter.hoverCard(for: tile, totalBytes: 1, index: index,
                        purposes: nil, selection: .available, colorMode: mode)
                    XCTAssertFalse(pending.lines.contains { $0.text.hasPrefix(L10n.text("用途：", "Purpose: ")) })
                }
            }
        }
    }

    func testColorModeUsesTheInjectedPreferenceDomainAndInvalidValuesFallBack() {
        let defaults = TestPreferenceDomain.make(for: self)
        func store() -> LargeFilesStore {
            let coordinator = HeavyWorkCoordinator()
            let environment = FileAnalysisTrashEnvironment(journal: .init(directory: URL(fileURLWithPath: "/Fixture/Receipts")),
                moveToTrash: { _ in throw CancellationError() }, metadata: SidebarPreferenceFileSystem(),
                homePath: "/Fixture/Home", appDataPath: "/Fixture/AppData", excludedPaths: { [] },
                isCloudFolder: { _ in false }, isReadOnlyVolume: { _ in false }, userTrashPath: "/Fixture/Trash")
            return LargeFilesStore(coordinator: coordinator, activityStore: HeavyWorkActivityStore(coordinator: coordinator),
                                   defaults: defaults, storageMapTargets: [], trashEnvironment: environment)
        }
        XCTAssertEqual(store().storageMapColorMode, .type)
        let first = store()
        first.storageMapColorMode = .purpose
        XCTAssertEqual(defaults.string(forKey: "storage-map.color-mode"), "purpose")
        XCTAssertEqual(store().storageMapColorMode, .purpose)
        defaults.set("invalid", forKey: "storage-map.color-mode")
        XCTAssertEqual(store().storageMapColorMode, .type)
    }

    func testReclaimCopyIncludesTheEstimatePendingStateAndOptionalClones() {
        let reclaim = CleanupSelectionReclaimable(items: [(100, .init(cloneSharedBytes: 80, snapshotHeldBytes: 0,
            unknownBytes: 0, wholeCloneGroupBytes: 80))])
        for language in [AppLanguage.zhHans, .english] {
            withLanguage(language) {
                let title = FileAnalysisSelectionReclaim.title(selectedBytes: 100, reclaim: reclaim, estimating: false)
                XCTAssertTrue(title.contains(ByteFormat.storageString(20)))
                XCTAssertTrue(title.contains(language == .zhHans ? "清空废纸篓后约释放" : "freed after emptying the Trash"))
                XCTAssertTrue(FileAnalysisSelectionReclaim.title(selectedBytes: 100, reclaim: reclaim, estimating: true).contains("…"))
                XCTAssertTrue(FileAnalysisSelectionReclaim.help(reclaim: reclaim).contains(ByteFormat.storageString(80)))
                XCTAssertFalse(FileAnalysisSelectionReclaim.help(reclaim: nil).contains(language == .zhHans ? "所选的完整克隆" : "selected full clones"))
            }
        }
    }

    func testCloneSentenceNeedsPossibleCloneBytesInBothLanguages() {
        let sharedOnly = CleanupSelectionReclaimable(items: [(100, .init(cloneSharedBytes: 20, snapshotHeldBytes: 0,
            unknownBytes: 0, wholeCloneGroupBytes: 0))])
        XCTAssertEqual(sharedOnly.freedBytes, 80)
        XCTAssertEqual(sharedOnly.possibleCloneBytes, 0)
        for language in [AppLanguage.zhHans, .english] {
            withLanguage(language) {
                XCTAssertEqual(FileAnalysisSelectionReclaim.help(reclaim: sharedOnly), FileAnalysisSelectionReclaim.help(reclaim: nil))
            }
        }
    }

    func testSidebarSourcesRetainReadOnlyMetadataContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = ["Features/SpaceMap/Treemap/SpaceMapTreemapViewState.swift", "Features/SpaceMap/Treemap/SpaceMapTreemapSource.swift",
                     "Views/CareStudio/SpaceMapTreemapPainter.swift", "Views/CareStudio/SpaceMapTreemapView.swift",
                     "Views/CareStudio/SpaceMapTreemapInputBridge.swift", "Views/CareStudio/SpaceLensWorthALook.swift",
                     "Features/LargeFiles/Services/FileAnalysisSelectionReclaim.swift"]
        for path in paths {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/" + path), encoding: .utf8)
            for banned in ["FileManager", "unlink", "removefile", "trashItem", "removeItem", "moveItem", "recycle", "rename(", "Process(", "NSAppleScript"] {
                XCTAssertFalse(source.contains(banned), "\(path): \(banned)")
            }
            if path.hasSuffix("FileAnalysisSelectionReclaim.swift") {
                // lstat and FileStorageSharing are permitted read-only metadata.
                XCTAssertTrue(source.contains("Darwin.lstat("))
                XCTAssertTrue(source.contains("FileStorageSharing.read(at:"))
            }
        }
    }

    private func withLanguage(_ language: AppLanguage, _ body: () throws -> Void) rethrows {
        let defaults = TestPreferenceDomain.make(for: self)
        defaults.set(language.rawValue, forKey: L10n.languageDefaultsKey)
        let preferences = TestVolatilePreferences()
        preferences.set(defaults.string(forKey: L10n.languageDefaultsKey) ?? language.rawValue, forKey: L10n.languageDefaultsKey)
        defer { preferences.restore() }
        XCTAssertEqual(L10n.usesChinese, language == .zhHans)
        try body()
    }
}

private struct SidebarPreferenceFileSystem: ReadOnlyFileSystem {
    func snapshot(at url: URL) throws -> FileSnapshot { throw CleanupFileSystemError.vanished }
    func children(of directory: URL) throws -> [URL] { [] }
    func symbolicLinkDestination(of url: URL) throws -> String { throw CleanupFileSystemError.vanished }
}
