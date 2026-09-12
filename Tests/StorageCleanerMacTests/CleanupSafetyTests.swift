import XCTest
@testable import StorageCleanerMac

final class CleanupSafetyTests: XCTestCase {
    func testOnlyAvailableGreenItemsCanMoveToTrash() {
        let green = makeItem(tier: .green, trashPaths: ["~/Library/Caches/example"])
        XCTAssertTrue(green.canMoveToTrash)

        let yellow = makeItem(tier: .yellow, trashPaths: ["~/Downloads"])
        XCTAssertFalse(yellow.canMoveToTrash)

        let red = makeItem(tier: .red, trashPaths: ["/Applications/Xcode.app"])
        XCTAssertFalse(red.canMoveToTrash)

        let alreadyMoved = makeItem(tier: .green, trashPaths: ["~/Library/Caches/example"], status: .movedToTrash)
        XCTAssertFalse(alreadyMoved.canMoveToTrash)
    }

    func testAllowedTrashPathsOnlyIncludesGreenItems() {
        let greenPath = "~/Library/Caches/example"
        let yellowPath = "~/Downloads"
        let result = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0.25,
            system: makeSnapshot(),
            groups: [],
            items: [
                makeItem(tier: .green, trashPaths: [greenPath]),
                makeItem(tier: .yellow, trashPaths: [yellowPath])
            ],
            deniedPaths: []
        )

        XCTAssertTrue(result.allowedTrashPaths.contains(PathSafety.lexicalPath(greenPath)))
        XCTAssertFalse(result.allowedTrashPaths.contains(PathSafety.lexicalPath(yellowPath)))
    }

    func testClassifierKeepsLogsInstallersAndArchivesOutOfSafeCleanup() {
        let groups = [
            StorageGroup(
                id: "logs",
                title: "Logs",
                entries: [DirectoryEntry(name: "app.log", path: "~/Library/Logs/app.log", sizeBytes: 1_000)]
            ),
            StorageGroup(
                id: "downloads",
                title: "Downloads",
                entries: [DirectoryEntry(name: "installer.dmg", path: "~/Downloads/installer.dmg", sizeBytes: 2_000)]
            ),
            StorageGroup(
                id: "large_files",
                title: "Large Files",
                entries: [DirectoryEntry(name: "archive.zip", path: "~/Downloads/archive.zip", sizeBytes: 3_000)]
            ),
            StorageGroup(
                id: "caches",
                title: "Caches",
                entries: [DirectoryEntry(name: "Cache", path: "~/Library/Caches/example", sizeBytes: 4_000, isDirectory: true)]
            )
        ]

        let itemsBySource = Dictionary(uniqueKeysWithValues: StorageClassifier.classify(groups: groups).map { ($0.sourceID, $0) })

        XCTAssertEqual(itemsBySource["logs"]?.tier, .yellow)
        XCTAssertEqual(itemsBySource["downloads"]?.tier, .yellow)
        XCTAssertEqual(itemsBySource["large_files"]?.tier, .yellow)
        XCTAssertEqual(itemsBySource["caches"]?.tier, .green)
        XCTAssertEqual(itemsBySource["logs"]?.trashPaths, [])
        XCTAssertEqual(itemsBySource["downloads"]?.trashPaths, [])
        XCTAssertEqual(itemsBySource["large_files"]?.trashPaths, [])
        XCTAssertFalse(itemsBySource["caches"]?.trashPaths.isEmpty ?? true)
    }

    func testClassifierKeepsSpecificHigherPriorityPathWhenCandidatesOverlap() {
        let broadCache = DirectoryEntry(
            name: "Google",
            path: "~/Library/Caches/Google",
            sizeBytes: 8_000,
            isDirectory: true
        )
        let chromeCache = DirectoryEntry(
            name: "Chrome",
            path: "~/Library/Caches/Google/Chrome",
            sizeBytes: 6_000,
            isDirectory: true
        )

        let items = StorageClassifier.classify(groups: [
            StorageGroup(id: "caches", title: "Caches", entries: [broadCache]),
            StorageGroup(id: "browser_caches", title: "Browser Cache", entries: [chromeCache])
        ])

        XCTAssertEqual(items.map(\.path), [chromeCache.path])
        XCTAssertEqual(items.first?.sourceID, "browser_caches")
        XCTAssertEqual(items.first?.trashPaths, [chromeCache.path])
    }

    func testCleanupRejectsRedItemsBeforeTouchingFileSystem() {
        let item = makeItem(tier: .red, path: "/Applications/Xcode.app", trashPaths: ["/Applications/Xcode.app"])

        XCTAssertThrowsError(try CleanupService.moveToTrash(item, allowedPaths: [PathSafety.normalizedPath(item.path)])) { error in
            guard case CleanupServiceError.notAllowed = error else {
                return XCTFail("Expected notAllowed, got \(error)")
            }
        }
    }

    func testCleanupRejectsGreenPathOutsideHomeEvenIfAllowlisted() {
        let item = makeItem(tier: .green, path: "/Applications/Fake.app", trashPaths: ["/Applications/Fake.app"])

        XCTAssertThrowsError(try CleanupService.moveToTrash(item, allowedPaths: [PathSafety.normalizedPath(item.path)])) { error in
            guard case CleanupServiceError.outsideAllowedRoots = error else {
                return XCTFail("Expected outsideAllowedRoots, got \(error)")
            }
        }
    }

    func testPathNormalizationExpandsHome() {
        let normalized = PathSafety.normalizedPath("~/Library/Caches")
        XCTAssertTrue(normalized.hasPrefix(PathSafety.homePath + "/"))
        XCTAssertTrue(PathSafety.isInsideHome(normalized))
    }

    func testCleanupRejectsNewExcludedDescendantFromOlderScanResult() {
        let parent = "~/Library/Caches/Codex/.tmp"
        let excludedChild = "~/Library/Caches/Codex/.tmp/keep/session.jsonl"
        let item = makeItem(tier: .green, path: parent, trashPaths: [parent])

        XCTAssertThrowsError(
            try CleanupService.moveToTrash(
                item,
                allowedPaths: [PathSafety.lexicalPath(parent)],
                excludedPaths: [excludedChild]
            )
        ) { error in
            guard case CleanupServiceError.notAllowed = error else {
                return XCTFail("Expected notAllowed, got \(error)")
            }
        }
    }

    func testCleanupRejectsCandidateReplacedBySymbolicLinkAfterScan() throws {
        let testRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/StorageCleanerSymlinkTests-\(UUID().uuidString)", isDirectory: true)
        let target = testRoot.appendingPathComponent("user-data", isDirectory: true)
        let candidate = testRoot.appendingPathComponent("codex-temp", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("keep.txt"))
        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: target)

        let item = makeItem(tier: .green, path: candidate.path, trashPaths: [candidate.path])
        XCTAssertThrowsError(
            try CleanupService.moveToTrash(
                item,
                allowedPaths: [PathSafety.lexicalPath(candidate.path)],
                excludedPaths: []
            )
        ) { error in
            guard case CleanupServiceError.notAllowed = error else {
                return XCTFail("Expected notAllowed, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("keep.txt").path))
    }

    func testMoveToTrashReturnsExactSystemResultingURL() throws {
        let testRoot = try makeRestoreHome()
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let candidateURL = testRoot.appendingPathComponent("cache.bin")
        try Data("cache".utf8).write(to: candidateURL)
        let trashURL = testRoot.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let expectedTrashURL = trashURL.appendingPathComponent("cache 2.bin")
        let item = makeItem(
            tier: .green,
            path: candidateURL.path,
            trashPaths: [candidateURL.path]
        )
        var observedOriginalURL: URL?

        let records = try CleanupService.moveToTrash(
            item,
            allowedPaths: [PathSafety.lexicalPath(candidateURL.path)],
            excludedPaths: [],
            trashItemOperation: { originalURL in
                observedOriginalURL = originalURL
                try FileManager.default.moveItem(at: originalURL, to: expectedTrashURL)
                return expectedTrashURL
            }
        )

        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(observedOriginalURL?.standardizedFileURL, candidateURL.standardizedFileURL)
        XCTAssertEqual(record.originalPath, candidateURL.standardizedFileURL.path)
        XCTAssertEqual(record.resultingItemURL, expectedTrashURL.standardizedFileURL)
        XCTAssertNotNil(record.itemIdentity)
    }

    func testRestoreFromTrashRejectsAReplacementAtTheRecordedTrashPath() throws {
        let homeURL = try makeRestoreHome()
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let trashURL = CleanupService.userTrashURL(homeDirectory: homeURL)
        let originalParent = homeURL.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalParent, withIntermediateDirectories: true)

        let sourceURL = trashURL.appendingPathComponent("reused-name.bin")
        let destinationURL = originalParent.appendingPathComponent("cache.bin")
        try Data("original".utf8).write(to: sourceURL)
        let record = TrashMoveRecord(
            originalPath: destinationURL.path,
            resultingItemURL: sourceURL
        )
        let recordedIdentity = try XCTUnwrap(record.itemIdentity)

        try FileManager.default.removeItem(at: sourceURL)
        let replacementURL = trashURL.appendingPathComponent("replacement.bin")
        let replacementData = Data("unrelated replacement".utf8)
        try replacementData.write(to: replacementURL)
        try FileManager.default.moveItem(at: replacementURL, to: sourceURL)
        XCTAssertNotEqual(TrashItemIdentity.capture(at: sourceURL), recordedIdentity)

        let summary = CleanupService.restoreFromTrash(
            [record],
            homeDirectory: homeURL,
            trashURL: trashURL
        )

        XCTAssertTrue(summary.restored.isEmpty)
        XCTAssertEqual(summary.failed.map(\.record), [record])
        XCTAssertEqual(try Data(contentsOf: sourceURL), replacementData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testRestoreFromTrashRestoresExactOriginalPath() throws {
        let homeURL = try makeRestoreHome()
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let trashURL = CleanupService.userTrashURL(homeDirectory: homeURL)
        let originalParent = homeURL.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalParent, withIntermediateDirectories: true)

        let sourceURL = trashURL.appendingPathComponent("restorable-cache.bin")
        let destinationURL = originalParent.appendingPathComponent("cache.bin")
        let expectedData = Data("restore-me".utf8)
        try expectedData.write(to: sourceURL)
        let record = TrashMoveRecord(
            originalPath: destinationURL.path,
            resultingItemURL: sourceURL
        )

        let summary = CleanupService.restoreFromTrash(
            [record],
            homeDirectory: homeURL,
            trashURL: trashURL
        )

        XCTAssertEqual(summary.restored, [record])
        XCTAssertEqual(summary.restoredCount, 1)
        XCTAssertTrue(summary.conflicts.isEmpty)
        XCTAssertTrue(summary.missing.isEmpty)
        XCTAssertTrue(summary.failed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destinationURL), expectedData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testRestoreFromTrashDoesNotOverwriteExistingDestination() throws {
        let homeURL = try makeRestoreHome()
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let trashURL = CleanupService.userTrashURL(homeDirectory: homeURL)
        let originalParent = homeURL.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalParent, withIntermediateDirectories: true)

        let sourceURL = trashURL.appendingPathComponent("conflicting-cache.bin")
        let destinationURL = originalParent.appendingPathComponent("cache.bin")
        let existingData = Data("keep-existing".utf8)
        try Data("do-not-overwrite".utf8).write(to: sourceURL)
        try existingData.write(to: destinationURL)
        let record = TrashMoveRecord(
            originalPath: destinationURL.path,
            resultingItemURL: sourceURL
        )

        let summary = CleanupService.restoreFromTrash(
            [record],
            homeDirectory: homeURL,
            trashURL: trashURL
        )

        XCTAssertEqual(summary.conflicts, [record])
        XCTAssertEqual(summary.conflictCount, 1)
        XCTAssertTrue(summary.restored.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destinationURL), existingData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testRestoreFromTrashReportsMissingAndInvalidRecordsSeparately() throws {
        let homeURL = try makeRestoreHome()
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let trashURL = CleanupService.userTrashURL(homeDirectory: homeURL)
        let originalParent = homeURL.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalParent, withIntermediateDirectories: true)

        let missingRecord = TrashMoveRecord(
            originalPath: originalParent.appendingPathComponent("missing.bin").path,
            resultingItemURL: trashURL.appendingPathComponent("missing.bin")
        )
        let outsideSourceURL = homeURL.appendingPathComponent("not-in-trash.bin")
        try Data("keep".utf8).write(to: outsideSourceURL)
        let invalidRecord = TrashMoveRecord(
            originalPath: originalParent.appendingPathComponent("invalid.bin").path,
            resultingItemURL: outsideSourceURL
        )

        let summary = CleanupService.restoreFromTrash(
            [missingRecord, invalidRecord],
            homeDirectory: homeURL,
            trashURL: trashURL
        )

        XCTAssertEqual(summary.missing, [missingRecord])
        XCTAssertEqual(summary.missingCount, 1)
        XCTAssertEqual(summary.failed.map(\.record), [invalidRecord])
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertFalse(summary.failed[0].reason.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideSourceURL.path))
    }

    func testRestoreFromTrashRejectsUnsafeOriginalPath() throws {
        let homeURL = try makeRestoreHome()
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let trashURL = CleanupService.userTrashURL(homeDirectory: homeURL)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let sourceURL = trashURL.appendingPathComponent("unsafe.bin")
        try Data("keep".utf8).write(to: sourceURL)
        let outsideDestination = homeURL.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).bin")
        let record = TrashMoveRecord(
            originalPath: outsideDestination.path,
            resultingItemURL: sourceURL
        )

        let summary = CleanupService.restoreFromTrash(
            [record],
            homeDirectory: homeURL,
            trashURL: trashURL
        )

        XCTAssertTrue(summary.restored.isEmpty)
        XCTAssertEqual(summary.failed.map(\.record), [record])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideDestination.path))
    }

    func testRestoreFromTrashRejectsSymbolicLinkDestinationParent() throws {
        let homeURL = try makeRestoreHome()
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let trashURL = CleanupService.userTrashURL(homeDirectory: homeURL)
        let realParent = homeURL.appendingPathComponent("real-parent", isDirectory: true)
        let linkedParent = homeURL.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)

        let sourceURL = trashURL.appendingPathComponent("linked-parent.bin")
        let destinationURL = linkedParent.appendingPathComponent("cache.bin")
        try Data("keep".utf8).write(to: sourceURL)
        let record = TrashMoveRecord(
            originalPath: destinationURL.path,
            resultingItemURL: sourceURL
        )

        let summary = CleanupService.restoreFromTrash(
            [record],
            homeDirectory: homeURL,
            trashURL: trashURL
        )

        XCTAssertTrue(summary.restored.isEmpty)
        XCTAssertEqual(summary.failed.map(\.record), [record])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: realParent.appendingPathComponent("cache.bin").path))
    }

    func testRevealAllowsKnownTemporaryRootsWithoutExpandingTrashPermissions() throws {
        let privateTemporaryArtifact = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("storage-cleaner-reveal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: privateTemporaryArtifact, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: privateTemporaryArtifact) }
        let userTemporaryArtifact = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-screenshot.png")
            .path

        XCTAssertTrue(CleanupService.isAllowedRevealPath(privateTemporaryArtifact.path))
        XCTAssertTrue(CleanupService.isAllowedRevealPath(userTemporaryArtifact))
        XCTAssertFalse(CleanupService.isAllowedRevealPath("/System/Library/CoreServices/Finder.app"))
        XCTAssertFalse(PathSafety.isLexicallyInsideHome(privateTemporaryArtifact.path))
    }

    func testTrashSummaryCountsDirectTrashItemsAndNestedBytes() throws {
        let homeURL = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let trashURL = CleanupService.userTrashURL(homeDirectory: homeURL)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)

        try Data(repeating: 1, count: 2048).write(to: trashURL.appendingPathComponent(".hidden-cache"))

        let folderURL = trashURL.appendingPathComponent("Old Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 4096).write(to: folderURL.appendingPathComponent("nested.bin"))

        let summary = try CleanupService.trashSummary(at: trashURL)

        XCTAssertEqual(summary.itemCount, 2)
        XCTAssertGreaterThan(summary.totalBytes, 0)
    }

    func testEmptyUserTrashRemovesOnlyTrashContents() throws {
        let homeURL = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let trashURL = CleanupService.userTrashURL(homeDirectory: homeURL)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)

        let outsideURL = homeURL.appendingPathComponent("keep.txt")
        let trashFileURL = trashURL.appendingPathComponent("delete.txt")
        try Data("keep".utf8).write(to: outsideURL)
        try Data("delete".utf8).write(to: trashFileURL)

        let summary = try CleanupService.emptyUserTrash(at: trashURL)

        XCTAssertEqual(summary.itemCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideURL.path))
    }

    func testEmptyUserTrashRejectsNonTrashLocation() throws {
        let homeURL = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: homeURL) }

        XCTAssertThrowsError(try CleanupService.emptyUserTrash(at: homeURL)) { error in
            guard case CleanupServiceError.invalidTrashLocation = error else {
                return XCTFail("Expected invalidTrashLocation, got \(error)")
            }
        }
    }

    @MainActor
    func testBulkCleanupPreviewOnlyIncludesAvailableGreenItemsAndCanBeEdited() {
        let cleanable = makeItem(tier: .green, path: "~/Library/Caches/cleanable", trashPaths: ["~/Library/Caches/cleanable"])
        let moved = makeItem(tier: .green, path: "~/Library/Caches/moved", trashPaths: ["~/Library/Caches/moved"], status: .movedToTrash)
        let review = makeItem(tier: .yellow, path: "~/Downloads/review", trashPaths: ["~/Downloads/review"])

        let store = ScanStore(cleanupFeatureConfiguration: .legacy)
        store.result = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0.25,
            system: makeSnapshot(),
            groups: [],
            items: [cleanable, moved, review],
            deniedPaths: []
        )

        store.requestTrashAllGreen()
        XCTAssertEqual(store.pendingBulkTrashItems.map(\.id), [cleanable.id])

        store.removePendingBulkTrashItem(cleanable)
        XCTAssertEqual(store.pendingBulkTrashItems, [])

        store.requestTrashAllGreen()
        store.cancelTrashAllGreenPreview()
        XCTAssertEqual(store.pendingBulkTrashItems, [])

        store.isCheckingScanReadiness = true
        XCTAssertFalse(store.canRequestGreenTrash)
        store.requestTrashAllGreen()
        XCTAssertEqual(store.pendingBulkTrashItems, [])

        store.isCheckingScanReadiness = false
        store.isScanning = true
        XCTAssertFalse(store.canRequestGreenTrash)
        store.requestTrashAllGreen()
        XCTAssertEqual(store.pendingBulkTrashItems, [])

        store.isScanning = false
        store.isEmptyingTrash = true
        XCTAssertFalse(store.canRequestGreenTrash)
        store.requestTrashAllGreen()
        XCTAssertEqual(store.pendingBulkTrashItems, [])

        store.isEmptyingTrash = false
        XCTAssertTrue(store.canRequestGreenTrash)
        store.requestTrashAllGreen()
        XCTAssertEqual(store.pendingBulkTrashItems.map(\.id), [cleanable.id])
    }

    private func makeTemporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRestoreHome() throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/StorageCleanerRestoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeItem(
        tier: StorageTier,
        path: String = "~/Library/Caches/example",
        trashPaths: [String],
        status: ItemStatus = .available
    ) -> StorageItem {
        StorageItem(
            id: PathSafety.normalizedPath(path),
            title: "Example",
            path: path,
            groupTitle: "Test",
            sizeBytes: 1024,
            tier: tier,
            kind: "Test",
            reason: "Test",
            recommendation: "Test",
            risk: "Test",
            requiresClose: "None",
            trashPaths: trashPaths,
            openPath: path,
            status: status
        )
    }

    private func makeSnapshot() -> SystemSnapshot {
        SystemSnapshot(
            osName: "macOS",
            build: "test",
            arch: "arm64",
            user: "tester",
            home: PathSafety.homePath,
            filesystem: "APFS",
            purgeable: "",
            diskName: "Macintosh HD",
            diskTotalBytes: 1000,
            diskUsedBytes: 500,
            diskFreeBytes: 500
        )
    }
}
