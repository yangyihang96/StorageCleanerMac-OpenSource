import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

/// N21: the file-analysis speed-ups must not change the index. These tests
/// pin what the analysis builds for a tree with the cases that matter
/// (hard links, a package, a symbolic link, an excluded folder, an unreadable
/// folder, hidden and empty files) and compare the parallel walk with the
/// one-thread walk on the same trees.
final class StorageMapAnalysisEquivalenceTests: XCTestCase {
    func testMixedTreeIndexIsPinned() throws {
        let tree = try MixedStorageTree()
        defer { tree.remove() }

        let result = try DiskScanner(excludedPaths: [tree.excluded.path])
            .storageMapAnalysis(target: tree.target)
        let index = result.index
        let root = index.rootPath

        XCTAssertEqual(result.inspectedItemCount, 20)
        XCTAssertEqual(result.omittedItemCount, 2)
        XCTAssertEqual(
            Set(index.directories.keys),
            Set([root] + ["Documents", "Documents/Nested", "Documents/Nested/Deep", "Media", "Tool.app",
                          "Tool.app/Contents", "Tool.app/Contents/MacOS", "Empty", "Excluded", "Locked"]
                .map { root + "/" + $0 })
        )
        XCTAssertEqual(index.blockedDirectoryPaths, Set(["Tool.app", "Excluded", "Locked"].map { root + "/" + $0 }))
        XCTAssertEqual(index.duplicateFilePaths, [root + "/Media/photo.jpg"])

        let rootChildren = try XCTUnwrap(index.childrenByDirectory[root])
        XCTAssertEqual(
            Set(rootChildren.map(\.name)),
            [".hidden", "Documents", "Media", "Tool.app", "link-to-docs", "Empty", "Excluded", "Locked", "zero.dat"]
        )
        let link = try XCTUnwrap(rootChildren.first { $0.name == "link-to-docs" })
        XCTAssertEqual(link.kind, "alias")
        XCTAssertFalse(link.isDirectory)
        let package = try XCTUnwrap(rootChildren.first { $0.name == "Tool.app" })
        XCTAssertEqual(package.kind, "package")
        XCTAssertFalse(package.canDescend)
        let excluded = try XCTUnwrap(rootChildren.first { $0.name == "Excluded" })
        XCTAssertEqual(excluded.kind, "folder")
        XCTAssertTrue(excluded.isEstimated)
        XCTAssertEqual(rootChildren.first { $0.name == "zero.dat" }?.sizeBytes, 0)

        let media = try XCTUnwrap(index.directories[root + "/Media"])
        let photoBytes = try tree.allocatedBytes("Media/linked-photo.jpg")
        XCTAssertEqual(media.sizeBytes, photoBytes, "Hard-linked bytes count once")
        XCTAssertEqual(media.immediateChildCount, 2)
        XCTAssertTrue(media.isComplete)
        let documents = try XCTUnwrap(index.directories[root + "/Documents"])
        XCTAssertEqual(
            documents.sizeBytes,
            try tree.allocatedBytes("Documents/report.pdf")
                + tree.allocatedBytes("Documents/notes.txt")
                + tree.allocatedBytes("Documents/Nested/Deep/file.bin")
        )
        XCTAssertEqual(documents.descendantItemCount, 5)
        XCTAssertEqual(index.directories[root + "/Locked"]?.isComplete, false)
        XCTAssertEqual(index.directories[root + "/Excluded"]?.isComplete, false)
        let rootAggregate = try XCTUnwrap(index.directories[root])
        XCTAssertFalse(rootAggregate.isComplete)
        XCTAssertEqual(rootAggregate.immediateChildCount, 9)
        XCTAssertEqual(rootAggregate.descendantItemCount, 20)
    }

    func testEveryWalkModeBuildsTheSameIndexAsTheOriginalWalk() throws {
        let mixed = try MixedStorageTree()
        defer { mixed.remove() }
        let nested = try NestedStorageTree()
        defer { nested.remove() }

        for (name, target, excluded) in [
            ("mixed", mixed.target, [mixed.excluded.path]),
            ("nested", nested.target, [String]()),
        ] {
            let scanner = DiskScanner(excludedPaths: excluded)
            let reference = try scanner.storageMapAnalysis(target: target, options: .reference)
            for options in [
                DiskScanner.StorageMapAnalysisOptions(concurrency: 1, ubiquityLookup: .whereNeeded),
                DiskScanner.StorageMapAnalysisOptions(concurrency: 4, ubiquityLookup: .everyItem),
                DiskScanner.StorageMapAnalysisOptions(concurrency: 4, ubiquityLookup: .whereNeeded),
                DiskScanner.StorageMapAnalysisOptions(concurrency: 8, ubiquityLookup: .whereNeeded),
                .standard,
            ] {
                let walked = try scanner.storageMapAnalysis(target: target, options: options)
                let label = "\(name) concurrency \(options.concurrency) \(options.ubiquityLookup)"
                XCTAssertEqual(walked.index, reference.index, label)
                XCTAssertEqual(walked.rootSnapshot, reference.rootSnapshot, label)
                XCTAssertEqual(walked.inspectedItemCount, reference.inspectedItemCount, label)
                XCTAssertEqual(walked.omittedItemCount, reference.omittedItemCount, label)
            }
        }
        // The nested tree is large enough for workers to hand out deeper
        // folders, and its hard links span sub-folders.
        XCTAssertGreaterThan(
            try DiskScanner(excludedPaths: []).storageMapAnalysis(target: nested.target, options: .reference)
                .index.duplicateFilePaths.count,
            10
        )
    }

    func testParallelWalkStopsWhenItsTaskIsCancelled() async throws {
        let nested = try NestedStorageTree(topLevelFolders: 12, subfolders: 12, filesPerFolder: 120)
        defer { nested.remove() }
        let target = nested.target
        let walking = ProgressReports()
        let task = Task.detached(priority: .utility) {
            try DiskScanner(excludedPaths: []).storageMapAnalysis(
                target: target,
                options: DiskScanner.StorageMapAnalysisOptions(concurrency: 4, ubiquityLookup: .whereNeeded),
                progressHandler: { walking.append($0) }
            )
        }
        // Cancel once workers are walking.
        while walking.all.count < 2 { try await Task.sleep(for: .milliseconds(1)) }
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("The walk finished although it was cancelled")
        } catch is CancellationError {
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelledAt, 2, "Workers stop promptly")
        }
    }

    func testCloudStateIsAskedForWhereverACloudItemCanBe() {
        let home = "/Users/fixture"
        func needs(_ path: String, directory: Bool = false, link: Bool = false,
                   ubiquitousParent: Bool = false, dataless: Bool = false) -> Bool {
            DiskScanner.storageMapNeedsCloudState(
                isDirectory: directory, isSymbolicLink: link, parentIsUbiquitous: ubiquitousParent,
                isDataless: dataless, path: path, homePath: home
            )
        }
        XCTAssertTrue(needs("/Users/fixture/Library/Caches/folder", directory: true))
        XCTAssertFalse(needs("/Users/fixture/Library/Mobile Documents/x", link: true))
        XCTAssertTrue(needs("/Users/fixture/Developer/file.swift", ubiquitousParent: true))
        XCTAssertTrue(needs("/Users/fixture/Downloads/clip.mov", dataless: true))
        XCTAssertTrue(needs("/Users/fixture/Library/Mobile Documents/com~apple~CloudDocs/a.txt"))
        XCTAssertTrue(needs("/Users/other/Library/CloudStorage/GoogleDrive-x/b.txt"))
        XCTAssertTrue(needs("/Users/fixture/Desktop/c.txt"))
        XCTAssertTrue(needs("/Users/fixture/Documents/Reports/d.pdf"))
        XCTAssertFalse(needs("/Users/fixture/Downloads/clip.mov"))
        XCTAssertFalse(needs("/Users/fixture/Library/Caches/com.example/e.db"))
        XCTAssertFalse(needs("/Users/fixture/DesktopArchive/f.txt"))
        XCTAssertFalse(needs("/Applications/Tool.app/Contents/MacOS/tool"))

        // The byte search behind the location checks finds whatever a
        // character search finds, also in non-ASCII paths, and only ever more.
        let contains = DiskScanner.storageMapPathContains
        for path in [
            "/Users/杨/Library/Mobile Documents/com~apple~CloudDocs/文件.txt",
            "/Volumes/Data/Users/x/Library/CloudStorage/OneDrive/a",
            "/Users/x/Library/Mobile Documents/",
            "/Users/x/Library/Caches/a",
            "/Users/x/Library/Cloud",
            "",
        ] {
            XCTAssertEqual(contains(path, "/Library/Mobile Documents/"), path.contains("/Library/Mobile Documents/"), path)
            XCTAssertEqual(contains(path, "/Library/CloudStorage/"), path.contains("/Library/CloudStorage/"), path)
        }
        // A combining mark after the slash makes a different character, so a
        // character search misses this path; the byte search still asks.
        XCTAssertTrue(contains("/Users/x/Library/Mobile Documents/\u{301}a.txt", "/Library/Mobile Documents/"))
    }

    func testWalkOrderPutsAFolderBeforeItsContentsAndSiblingsInOrder() {
        let precedes = DiskScanner.storageMapWalkOrderPrecedes
        XCTAssertTrue(precedes([3], [3, 1]))
        XCTAssertTrue(precedes([3, 9], [4]))
        XCTAssertTrue(precedes([3, 1, 7], [3, 2]))
        XCTAssertFalse(precedes([4], [3, 9]))
        XCTAssertFalse(precedes([3, 1], [3, 1]))
        XCTAssertEqual([[4], [3, 2], [3], [3, 1, 5], [1]].sorted(by: precedes), [[1], [3], [3, 1, 5], [3, 2], [4]])
    }

    func testProgressFromAllWorkersAddsUpInOneSequence() throws {
        let nested = try NestedStorageTree()
        defer { nested.remove() }
        let reports = ProgressReports()
        let result = try DiskScanner(excludedPaths: []).storageMapAnalysis(
            target: nested.target,
            options: DiskScanner.StorageMapAnalysisOptions(concurrency: 4, ubiquityLookup: .whereNeeded),
            progressHandler: { reports.recordSlowly($0) }
        )
        let counts = reports.all.map(\.inspectedItemCount)
        XCTAssertFalse(counts.isEmpty)
        XCTAssertEqual(counts.last, result.inspectedItemCount)
        XCTAssertEqual(counts, counts.sorted(), "Counts never go back")
        XCTAssertEqual(reports.overlappingCalls, 0, "As with one walker, the handler never runs twice at once")

        // The running byte total before the final report matches one walk,
        // so a file hard-linked from two sub-folder walks is counted once.
        let oneWalk = ProgressReports()
        _ = try DiskScanner(excludedPaths: []).storageMapAnalysis(
            target: nested.target,
            options: .reference,
            progressHandler: { oneWalk.append($0) }
        )
        XCTAssertEqual(
            reports.all.dropLast().last?.measuredBytes,
            oneWalk.all.dropLast().last?.measuredBytes
        )
    }

    // MARK: - Review P2-1: a cloud folder's state reaches its files

    /// Files outside the known cloud locations are asked about their cloud
    /// state only because their folder is a cloud item. A stand-in File
    /// Provider makes two folders cloud folders: one at the top level, which
    /// a worker walks when there are workers, and one nested inside another
    /// top-level folder. Their files are placeholders, so they must come out
    /// estimated, and every walk must equal the every-item reference.
    func testACloudFolderPassesItsStateToItsFilesOnTheSameThreadAndInAWorkerSubtree() throws {
        let tree = try CloudFolderTree()
        defer { tree.remove() }
        let scanner = DiskScanner(excludedPaths: [])
        let cloud = DiskScanner.StorageMapAnalysisOptions.CloudStateSource.custom(CloudFolderTree.fakeFileProvider)
        let reference = try scanner.storageMapAnalysis(
            target: tree.target,
            options: DiskScanner.StorageMapAnalysisOptions(concurrency: 1, ubiquityLookup: .everyItem, cloudState: cloud)
        )
        for concurrency in [1, 4] {
            let walked = try scanner.storageMapAnalysis(
                target: tree.target,
                options: DiskScanner.StorageMapAnalysisOptions(concurrency: concurrency, ubiquityLookup: .whereNeeded, cloudState: cloud)
            )
            let label = "concurrency \(concurrency)"
            for file in CloudFolderTree.cloudFiles {
                XCTAssertEqual(tree.entry(file, in: walked.index)?.isEstimated, true, "\(label): \(file)")
            }
            XCTAssertEqual(tree.entry("local.bin", in: walked.index)?.isEstimated, false, label)
            XCTAssertEqual(tree.entry("Plain/plain.bin", in: walked.index)?.isEstimated, false, label)
            XCTAssertEqual(walked.index, reference.index, label)
        }
    }

    // MARK: - Review P2-8: the merge does not depend on workers starting

    /// Nothing guarantees that a worker thread ever runs. With every worker
    /// held back, the calling thread walks the sub-folders itself, the index
    /// equals the reference, and workers that start after the walk returned
    /// walk nothing.
    func testAWalkWhoseWorkersNeverStartStillFinishes() throws {
        let nested = try NestedStorageTree()
        defer { nested.remove() }
        let target = nested.target
        let reference = try DiskScanner(excludedPaths: []).storageMapAnalysis(target: target, options: .reference)
        let held = HeldWorkers()
        let lookups = CloudLookups()
        let options = DiskScanner.StorageMapAnalysisOptions(
            concurrency: 4,
            ubiquityLookup: .whereNeeded,
            cloudState: .custom { lookups.notInTheCloud($0) },
            startWorker: { held.hold($0) }
        )

        let walked = try runOnAnotherThread(givingUpAfter: 10) {
            try DiskScanner(excludedPaths: []).storageMapAnalysis(target: target, options: options)
        }
        XCTAssertEqual(walked?.index, reference.index)
        XCTAssertEqual(held.count, 4)

        let lookupsAfterWalk = lookups.count
        held.startAll()
        XCTAssertEqual(lookups.count, lookupsAfterWalk, "A worker that starts after the walk walks nothing")
    }

    /// Cancelling ends the walk within 2 s although no worker ever starts,
    /// here while the calling thread is inside a sub-folder walk of its own.
    func testCancellingAWalkWhoseWorkersNeverStartEndsWithinTwoSeconds() throws {
        let nested = try NestedStorageTree()
        defer { nested.remove() }
        let target = nested.target
        let gate = SubfolderGate(root: nested.root, topLevelFolders: 3)
        let options = DiskScanner.StorageMapAnalysisOptions(
            concurrency: 4,
            ubiquityLookup: .whereNeeded,
            cloudState: .custom { gate.cloudState(of: $0) },
            startWorker: { _ in }
        )
        let thrown = Locked<Error?>(nil)
        let ended = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .utility) {
            do {
                _ = try DiskScanner(excludedPaths: []).storageMapAnalysis(target: target, options: options)
            } catch {
                thrown.value = error
            }
            ended.signal()
        }

        XCTAssertTrue(gate.waitForRootLevel(seconds: 10), "The root level is walked")
        XCTAssertTrue(gate.waitForSubfolderWalk(seconds: 5), "The calling thread walks a sub-folder itself")
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        task.cancel()
        gate.open()
        XCTAssertEqual(ended.wait(timeout: .now() + 2), .success, "The walk ends within 2 s of cancelling")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelledAt, 2)
        XCTAssertTrue(thrown.value is CancellationError, String(describing: thrown.value))
    }

    /// Review P2-8 follow-up (the reviewer's experiment, adapted): after a
    /// cancelled walk has returned, a worker thread that only starts now must
    /// not open any sub-folder. The queue is closed when the walk throws, so
    /// a late worker returns at once (`enterWorker`), and one that got in
    /// takes nothing (`take`). The sub-folders are emptied after the walk
    /// returned: a late walk of one would then finish normally and report
    /// progress instead of stopping at its first item, so any progress report
    /// or cloud lookup after the return is a late walk.
    func testWorkersThatStartAfterACancelledWalkReturnedOpenNoFolder() throws {
        let fileManager = FileManager.default
        let root = TestFileSystem.uniqueOperationRoot("LateWorker")
        TestFileSystem.registerCleanup(of: root, for: self)
        let folderCount = 6
        for index in 0..<folderCount {
            let folder = root.appendingPathComponent("Top \(index)", isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in 0..<3 {
                try Data(repeating: UInt8(file), count: 512).write(to: folder.appendingPathComponent("f\(file).bin"))
            }
        }
        defer { TestFileSystem.remove(root) }
        let target = StorageMapScanTarget(path: root.path, title: "Late Worker", kind: .homeDirectory)

        let held = HeldWorkers()
        let gate = RootLevelGate(root: root, blockAtFolder: 3)
        let progress = LateProgress()
        let options = DiskScanner.StorageMapAnalysisOptions(
            concurrency: 4,
            ubiquityLookup: .whereNeeded,
            cloudState: .custom { gate.cloudState(of: $0) },
            startWorker: { held.hold($0) }
        )
        let ended = DispatchSemaphore(value: 0)
        let thrown = Locked<Error?>(nil)
        let task = Task.detached(priority: .utility) {
            do {
                _ = try DiskScanner(excludedPaths: []).storageMapAnalysis(
                    target: target,
                    options: options,
                    progressHandler: { progress.record($0) }
                )
            } catch {
                thrown.value = error
            }
            ended.signal()
        }

        XCTAssertTrue(gate.waitUntilBlocked(seconds: 10), "The root walk reached the third top-level folder")
        task.cancel()
        gate.release()
        XCTAssertEqual(ended.wait(timeout: .now() + 5), .success, "The cancelled walk returned")
        XCTAssertTrue(thrown.value is CancellationError, String(describing: thrown.value))
        XCTAssertEqual(held.count, 4, "Every worker was held back")
        XCTAssertGreaterThanOrEqual(gate.handedOutAtLeast, 2, "Sub-folder walks were waiting when the walk returned")

        for index in 0..<folderCount {
            let folder = root.appendingPathComponent("Top \(index)", isDirectory: true)
            for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] {
                try fileManager.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        progress.markReturned()
        let lookupsBeforeLateStart = gate.lookups

        held.startAll()

        XCTAssertEqual(progress.reportsAfterReturn, [], "A worker that started after the walk returned walked a folder")
        XCTAssertEqual(gate.lookups, lookupsBeforeLateStart, "A worker that started late looked something up")
    }

    // MARK: - Helpers

    /// Runs `body` on its own thread and gives up waiting after `seconds`,
    /// so a walk that never ends fails the test instead of hanging the run.
    private func runOnAnotherThread<T: Sendable>(
        givingUpAfter seconds: TimeInterval,
        _ body: @escaping @Sendable () throws -> T
    ) throws -> T? {
        let outcome = Locked<Result<T, Error>?>(nil)
        let ended = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            outcome.value = Result { try body() }
            ended.signal()
        }
        guard ended.wait(timeout: .now() + seconds) == .success else {
            XCTFail("Still running after \(seconds) s")
            return nil
        }
        return try outcome.value?.get()
    }

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// Stands in for the global queue: keeps each worker without running it
    /// until told.
    private final class HeldWorkers: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [@Sendable () -> Void] = []
        var count: Int { lock.withLock { held.count } }
        func hold(_ work: @escaping @Sendable () -> Void) { lock.withLock { held.append(work) } }
        /// Runs every held worker, each on its own thread, and waits for them.
        func startAll() {
            let workers = lock.withLock { held }
            DispatchQueue.concurrentPerform(iterations: workers.count) { workers[$0]() }
        }
    }

    /// Cloud-state stand-in that counts lookups and reports nothing in the
    /// cloud, as File Provider does for /private/tmp.
    private final class CloudLookups: @unchecked Sendable {
        private let lock = NSLock()
        private var lookups = 0
        var count: Int { lock.withLock { lookups } }
        func notInTheCloud(_ url: URL) -> DiskScanner.StorageMapCloudState {
            lock.withLock { lookups += 1 }
            return DiskScanner.StorageMapCloudState(isUbiquitous: false, isCurrent: true)
        }
    }

    /// Cloud-state stand-in that reports nothing in the cloud, tells when the
    /// root level has been walked, and holds every lookup inside a top-level
    /// folder (that is, during a sub-folder walk) until it is opened.
    private final class SubfolderGate: @unchecked Sendable {
        private let condition = NSCondition()
        private let rootName: String
        private let topLevelFolders: Int
        private var topLevelLookups = 0
        private var subfolderLookups = 0
        private var isOpen = false

        init(root: URL, topLevelFolders: Int) {
            rootName = root.lastPathComponent
            self.topLevelFolders = topLevelFolders
        }

        func cloudState(of url: URL) -> DiskScanner.StorageMapCloudState {
            let components = url.pathComponents
            let depth = components.firstIndex(of: rootName).map { components.count - $0 - 1 } ?? 0
            condition.lock()
            if depth == 1 { topLevelLookups += 1 }
            if depth >= 2 { subfolderLookups += 1 }
            condition.broadcast()
            if depth >= 2 {
                let deadline = Date().addingTimeInterval(10)
                while !isOpen && condition.wait(until: deadline) {}
            }
            condition.unlock()
            return DiskScanner.StorageMapCloudState(isUbiquitous: false, isCurrent: true)
        }

        func waitForRootLevel(seconds: TimeInterval) -> Bool {
            wait(seconds) { topLevelLookups >= topLevelFolders }
        }

        func waitForSubfolderWalk(seconds: TimeInterval) -> Bool {
            wait(seconds) { subfolderLookups > 0 }
        }

        func open() {
            condition.lock()
            isOpen = true
            condition.broadcast()
            condition.unlock()
        }

        private func wait(_ seconds: TimeInterval, until holds: () -> Bool) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(seconds)
            while !holds() {
                if !condition.wait(until: deadline) { return holds() }
            }
            return true
        }
    }

    /// Progress reports that arrive after the walk is known to have returned.
    private final class LateProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var returned = false
        private var lateReports: [String] = []
        func record(_ report: StorageMapScanProgress) {
            lock.withLock { if returned { lateReports.append(report.currentPath) } }
        }
        func markReturned() { lock.withLock { returned = true } }
        var reportsAfterReturn: [String] { lock.withLock { lateReports } }
    }

    /// Cloud-state stand-in that reports nothing in the cloud, counts
    /// lookups, and holds the lookup of the N-th top-level folder until it is
    /// released, so the root level stops with earlier folders handed out.
    private final class RootLevelGate: @unchecked Sendable {
        private let condition = NSCondition()
        private let rootName: String
        private let blockAtFolder: Int
        private var topLevelLookups = 0
        private var allLookups = 0
        private var blocked = false
        private var released = false

        init(root: URL, blockAtFolder: Int) {
            rootName = root.lastPathComponent
            self.blockAtFolder = blockAtFolder
        }

        var lookups: Int {
            condition.lock(); defer { condition.unlock() }
            return allLookups
        }

        /// Top-level folders looked up before the held one were handed out
        /// as sub-folder walks.
        var handedOutAtLeast: Int {
            condition.lock(); defer { condition.unlock() }
            return topLevelLookups - 1
        }

        func cloudState(of url: URL) -> DiskScanner.StorageMapCloudState {
            let components = url.pathComponents
            let depth = components.firstIndex(of: rootName).map { components.count - $0 - 1 } ?? 0
            condition.lock()
            allLookups += 1
            if depth == 1 {
                topLevelLookups += 1
                if topLevelLookups == blockAtFolder {
                    blocked = true
                    condition.broadcast()
                    let deadline = Date().addingTimeInterval(10)
                    while !released && condition.wait(until: deadline) {}
                }
            }
            condition.unlock()
            return DiskScanner.StorageMapCloudState(isUbiquitous: false, isCurrent: true)
        }

        func waitUntilBlocked(seconds: TimeInterval) -> Bool {
            condition.lock(); defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(seconds)
            while !blocked {
                if !condition.wait(until: deadline) { return blocked }
            }
            return true
        }

        func release() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private final class ProgressReports: @unchecked Sendable {
        private let lock = NSLock()
        private var reports: [StorageMapScanProgress] = []
        private var callsInside = 0
        private var overlaps = 0
        func append(_ report: StorageMapScanProgress) { lock.withLock { reports.append(report) } }
        var all: [StorageMapScanProgress] { lock.withLock { reports } }
        var overlappingCalls: Int { lock.withLock { overlaps } }

        /// Stays in the handler for a moment, so a second call made while one
        /// is running is caught.
        func recordSlowly(_ report: StorageMapScanProgress) {
            lock.withLock {
                if callsInside > 0 { overlaps += 1 }
                callsInside += 1
            }
            Thread.sleep(forTimeInterval: 0.002)
            lock.withLock {
                callsInside -= 1
                reports.append(report)
            }
        }
    }

    /// Folders several levels deep with hard links inside and across
    /// top-level folders, a package and a link per top-level folder.
    private struct NestedStorageTree {
        let root: URL

        var target: StorageMapScanTarget {
            StorageMapScanTarget(path: root.path, title: "Nested Fixture", kind: .homeDirectory)
        }

        init(topLevelFolders: Int = 3, subfolders: Int = 6, filesPerFolder: Int = 8) throws {
            let fileManager = FileManager.default
            root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("storage-map-nested-\(UUID().uuidString)", isDirectory: true)
            do {
                var firstFiles: [URL] = []
                for top in 0..<topLevelFolders {
                    let topURL = root.appendingPathComponent("Top \(top)", isDirectory: true)
                    for sub in 0..<subfolders {
                        let folder = topURL.appendingPathComponent("sub-\(sub)/deeper/deepest", isDirectory: true)
                        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                        for file in 0..<filesPerFolder {
                            let url = (file.isMultiple(of: 2) ? folder : folder.deletingLastPathComponent())
                                .appendingPathComponent("file-\(file).dat")
                            try Data(repeating: UInt8(file % 251), count: 512 * (file % 5)).write(to: url)
                            if file == 0 { firstFiles.append(url) }
                        }
                    }
                    let package = topURL.appendingPathComponent("Bundle.app/Contents", isDirectory: true)
                    try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
                    try Data(repeating: 1, count: 2_048).write(to: package.appendingPathComponent("Info.plist"))
                    try fileManager.createSymbolicLink(
                        at: topURL.appendingPathComponent("shortcut"),
                        withDestinationURL: topURL.appendingPathComponent("sub-0")
                    )
                }
                // Hard links within a top-level folder and across them.
                for (index, file) in firstFiles.enumerated() where index > 0 {
                    try fileManager.linkItem(at: firstFiles[0], to: file.deletingLastPathComponent()
                        .appendingPathComponent("linked-\(index).dat"))
                }
                try Data(repeating: 9, count: 4_096).write(to: root.appendingPathComponent("root-file.dat"))
                try fileManager.linkItem(
                    at: root.appendingPathComponent("root-file.dat"),
                    to: root.appendingPathComponent("Top 0/root-file-link.dat")
                )
            } catch {
                TestFileSystem.remove(root)
                throw error
            }
        }

        func remove() {
            TestFileSystem.remove(root)
        }
    }

    /// Two stand-in cloud folders under /private/tmp, away from every known
    /// cloud location: "CloudTop" at the top level and "CloudDeep" inside
    /// "Plain/Nested".
    private struct CloudFolderTree {
        static let cloudFiles = [
            "CloudTop/top-a.bin",
            "CloudTop/top-b.bin",
            "CloudTop/Inner/inner.bin",
            "Plain/Nested/CloudDeep/deep-a.bin",
            "Plain/Nested/CloudDeep/deep-b.bin",
        ]

        /// Anything inside the two folders is a cloud item; folders are up to
        /// date (walked into), files are not (placeholders).
        static let fakeFileProvider: @Sendable (URL) throws -> DiskScanner.StorageMapCloudState = { url in
            let path = url.path
            let inCloudFolder = path.contains("/CloudTop") || path.contains("/CloudDeep")
            let isDirectory = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
            return DiskScanner.StorageMapCloudState(
                isUbiquitous: inCloudFolder,
                isCurrent: !inCloudFolder || isDirectory
            )
        }

        let root: URL

        var target: StorageMapScanTarget {
            StorageMapScanTarget(path: root.path, title: "Cloud Fixture", kind: .homeDirectory)
        }

        init() throws {
            root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("storage-map-cloud-\(UUID().uuidString)", isDirectory: true)
            do {
                for file in Self.cloudFiles + ["local.bin", "Plain/plain.bin"] {
                    let url = root.appendingPathComponent(file)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(repeating: 3, count: 1_024).write(to: url)
                }
            } catch {
                TestFileSystem.remove(root)
                throw error
            }
        }

        func entry(_ relativePath: String, in index: StorageMapAnalysisIndex) -> StorageMapIndexedEntry? {
            let path = (index.rootPath + "/" + relativePath) as NSString
            return index.childrenByDirectory[path.deletingLastPathComponent]?
                .first { $0.name == path.lastPathComponent }
        }

        func remove() {
            TestFileSystem.remove(root)
        }
    }

    /// /private/tmp keeps the root free of symbolic-link components, which
    /// the analysis refuses.
    private struct MixedStorageTree {
        let root: URL
        let excluded: URL

        var target: StorageMapScanTarget {
            StorageMapScanTarget(path: root.path, title: "Mixed Fixture", kind: .homeDirectory)
        }

        init() throws {
            let fileManager = FileManager.default
            root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("storage-map-equivalence-\(UUID().uuidString)", isDirectory: true)
            excluded = root.appendingPathComponent("Excluded", isDirectory: true)
            do {
                for folder in ["Documents/Nested/Deep", "Media", "Tool.app/Contents/MacOS", "Empty", "Excluded", "Locked"] {
                    try fileManager.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
                }
                let files: [(String, Int)] = [
                    ("Documents/report.pdf", 8_192),
                    ("Documents/notes.txt", 100),
                    ("Documents/Nested/Deep/file.bin", 16_384),
                    ("Media/photo.jpg", 65_536),
                    ("Tool.app/Contents/MacOS/tool", 4_096),
                    ("Tool.app/Contents/Info.plist", 1_024),
                    (".hidden", 1_024),
                    ("Excluded/skipped.bin", 2_048),
                    ("Locked/secret.bin", 2_048),
                    ("zero.dat", 0),
                ]
                for (path, bytes) in files {
                    try Data(repeating: 0x42, count: bytes).write(to: root.appendingPathComponent(path))
                }
                try fileManager.linkItem(
                    at: root.appendingPathComponent("Media/photo.jpg"),
                    to: root.appendingPathComponent("Media/linked-photo.jpg")
                )
                try fileManager.createSymbolicLink(
                    at: root.appendingPathComponent("link-to-docs"),
                    withDestinationURL: root.appendingPathComponent("Documents")
                )
                guard chmod(root.appendingPathComponent("Locked").path, 0) == 0 else { throw POSIXError(.EPERM) }
            } catch {
                _ = chmod(root.appendingPathComponent("Locked").path, 0o755)
                TestFileSystem.remove(root)
                throw error
            }
        }

        func allocatedBytes(_ relativePath: String) throws -> Int64 {
            let values = try root.appendingPathComponent(relativePath)
                .resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        func remove() {
            _ = chmod(root.appendingPathComponent("Locked").path, 0o755)
            TestFileSystem.remove(root)
        }
    }
}
