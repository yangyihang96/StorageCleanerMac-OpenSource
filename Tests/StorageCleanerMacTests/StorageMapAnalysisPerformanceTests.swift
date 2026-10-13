import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

/// N21 measurement harness, not a pass/fail gate: opt in with
/// `STORAGE_CLEANER_N21_PERF=1`. It builds a synthetic tree of many small
/// files once (reused by later runs), times `storageMapAnalysis` over it and
/// samples the process footprint while the index is held and after it is
/// released. Each run prints one `N21RESULT {json}` line.
///
/// Optional environment:
/// - `STORAGE_CLEANER_N21_ROOT`: parent folder for the tree (default: the
///   test process temporary directory). Never point it at real user data.
/// - `STORAGE_CLEANER_N21_FILES`: approximate number of files (default 200000).
/// - `STORAGE_CLEANER_N21_RUNS`: timed runs after one warm-up (default 3).
/// - `STORAGE_CLEANER_N21_THREADS`: worker threads (default: the app's).
/// - `STORAGE_CLEANER_N21_LOOKUP`: `every` asks File Provider for every item
///   (the walk before N21); default asks only where a cloud item can be.
final class StorageMapAnalysisPerformanceTests: XCTestCase {
    func testSyntheticTreeThroughputAndMemory() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["STORAGE_CLEANER_N21_PERF"] == "1",
            "Measurement harness; set STORAGE_CLEANER_N21_PERF=1 to run it."
        )
        let fileCount = Int(environment["STORAGE_CLEANER_N21_FILES"] ?? "") ?? 200_000
        let runs = max(1, Int(environment["STORAGE_CLEANER_N21_RUNS"] ?? "") ?? 3)
        let parent = environment["STORAGE_CLEANER_N21_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let tree = try SyntheticStorageTree.prepare(under: parent, approximateFileCount: fileCount)

        let target = StorageMapScanTarget(path: tree.root.path, title: "N21 Fixture", kind: .homeDirectory)
        let scanner = DiskScanner(excludedPaths: [])
        var options = DiskScanner.StorageMapAnalysisOptions.standard
        if let threads = Int(environment["STORAGE_CLEANER_N21_THREADS"] ?? "") { options.concurrency = threads }
        if environment["STORAGE_CLEANER_N21_LOOKUP"] == "every" { options.ubiquityLookup = .everyItem }
        print("N21OPTIONS concurrency=\(options.concurrency) lookup=\(options.ubiquityLookup)")
        // Memory is read around the first analysis in this process, before
        // the allocator has free pages left over from an earlier run. That run
        // also warms the vnode and attribute caches for the timed runs below.
        let start = ProcessFootprint.sample()
        let firstStarted = ProcessInfo.processInfo.systemUptime
        var first: StorageMapAnalysisResult? = try autoreleasepool {
            try scanner.storageMapAnalysis(target: target, options: options)
        }
        let firstSeconds = ProcessInfo.processInfo.systemUptime - firstStarted
        let firstHeld = ProcessFootprint.sample()
        let firstItems = first?.inspectedItemCount ?? 0
        let firstEstimate = first.map { IndexSizeEstimate($0.index) }
        let firstDigest = first.map(IndexDigest.of) ?? "-"
        first = nil
        let firstReleased = ProcessFootprint.sample()
        let memoryLine: [String: Any] = [
            "run": 0,
            "items": firstItems,
            "seconds": (firstSeconds * 1_000).rounded() / 1_000,
            "footprintStartMB": start.megabytes(\.current),
            "footprintHeldMB": firstHeld.megabytes(\.current),
            "footprintReleasedMB": firstReleased.megabytes(\.current),
            "peakMB": firstHeld.megabytes(\.peak),
            "heldBytesPerItem": firstItems > 0 ? Int((firstHeld.current - start.current) / Int64(firstItems)) : 0,
            "peakBytesPerItem": firstItems > 0 ? Int((firstHeld.peak - start.current) / Int64(firstItems)) : 0,
            "estimatedIndexMB": firstEstimate.map { (Double($0.bytes) / 1_048_576 * 10).rounded() / 10 } ?? 0,
            "estimatedIndexBytesPerItem": firstEstimate.map { firstItems > 0 ? $0.bytes / firstItems : 0 } ?? 0,
            "estimatedSlackMB": firstEstimate.map { (Double($0.slackBytes) / 1_048_576 * 10).rounded() / 10 } ?? 0,
            "entryStride": MemoryLayout<StorageMapIndexedEntry>.stride,
            "aggregateStride": MemoryLayout<StorageMapDirectoryAggregate>.stride,
        ]
        let memoryData = try JSONSerialization.data(withJSONObject: memoryLine, options: [.sortedKeys])
        print("N21RESULT " + String(decoding: memoryData, as: UTF8.self))
        print("N21DIGEST run=0 \(firstDigest)")

        for run in 1...runs {
            let before = ProcessFootprint.sample()
            let started = ProcessInfo.processInfo.systemUptime
            var result: StorageMapAnalysisResult? = try autoreleasepool {
                try scanner.storageMapAnalysis(target: target, options: options)
            }
            let seconds = ProcessInfo.processInfo.systemUptime - started
            let held = ProcessFootprint.sample()
            let items = result?.inspectedItemCount ?? 0
            let estimate = result.map { IndexSizeEstimate($0.index) }
            let digest = result.map(IndexDigest.of) ?? "-"
            result = nil
            let released = ProcessFootprint.sample()

            let line: [String: Any] = [
                "run": run,
                "items": items,
                "files": tree.fileCount,
                "directories": tree.directoryCount,
                "seconds": (seconds * 1_000).rounded() / 1_000,
                "itemsPerSecond": seconds > 0 ? Int(Double(items) / seconds) : 0,
                "footprintBeforeMB": before.megabytes(\.current),
                "footprintHeldMB": held.megabytes(\.current),
                "footprintReleasedMB": released.megabytes(\.current),
                "peakMB": held.megabytes(\.peak),
                "heldBytesPerItem": items > 0 ? Int((held.current - before.current) / Int64(items)) : 0,
                "estimatedIndexMB": estimate.map { Double($0.bytes) / 1_048_576 } ?? 0,
                "indexDirectories": estimate?.directories ?? 0,
                "indexEntries": estimate?.entries ?? 0,
            ]
            let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            print("N21RESULT " + String(decoding: data, as: UTF8.self))
            print("N21DIGEST run=\(run) \(digest)")
            XCTAssertEqual(items, tree.fileCount + tree.directoryCount + tree.otherItemCount)
        }
    }
}

/// SHA-256 over everything an analysis result holds, in a fixed order, so
/// indexes built by different code or walk modes can be compared across
/// processes (N21). Children keep their walk order.
enum IndexDigest {
    static func of(_ result: StorageMapAnalysisResult) -> String {
        var hasher = SHA256()
        func add(_ text: String) {
            hasher.update(data: Data(text.utf8))
            hasher.update(data: Data([0]))
        }
        let index = result.index
        add("R|\(index.rootPath)|\(index.rootVolumeIdentifier ?? "-")|\(result.inspectedItemCount)|\(result.omittedItemCount)")
        for path in index.directories.keys.sorted() {
            let aggregate = index.directories[path]!
            add("D|\(path)|\(aggregate.sizeBytes)|\(aggregate.immediateChildCount)|\(aggregate.descendantItemCount)|\(aggregate.isComplete)|\(String(describing: aggregate.contentProfile))")
        }
        for path in index.childrenByDirectory.keys.sorted() {
            add("C|\(path)")
            for entry in index.childrenByDirectory[path]! {
                add("E|\(entry.name)|\(entry.kind)|\(entry.sizeBytes.map(String.init) ?? "nil")|\(entry.isDirectory)|\(entry.canDescend)|\(entry.isEstimated)")
            }
        }
        for path in index.blockedDirectoryPaths.sorted() { add("B|\(path)") }
        for path in index.duplicateFilePaths.sorted() { add("H|\(path)") }
        add("S|\(result.rootSnapshot.measuredBytes)")
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A deterministic tree that resembles a home folder: mostly empty or tiny
/// files with realistic name lengths, a few hard links, app-like packages and
/// symbolic links. Empty files keep the fixture small on disk while still
/// costing one directory entry and one attribute fetch each.
struct SyntheticStorageTree {
    let root: URL
    let fileCount: Int
    let directoryCount: Int
    /// Symbolic links (enumerated, never followed).
    let otherItemCount: Int

    static let filesPerLeaf = 50
    static let leavesPerBranch = 8
    static let branchesPerTop = 10

    static func prepare(under parent: URL, approximateFileCount: Int) throws -> SyntheticStorageTree {
        let leaves = max(1, approximateFileCount / filesPerLeaf)
        let tops = max(1, Int((Double(leaves) / Double(leavesPerBranch * branchesPerTop)).rounded(.up)))
        let root = parent.appendingPathComponent("n21-synthetic-\(tops)x\(branchesPerTop)x\(leavesPerBranch)x\(filesPerLeaf)", isDirectory: true)
        let marker = root.appendingPathComponent(".n21-complete")
        var files = 0, directories = 0, links = 0
        let fileManager = FileManager.default
        let alreadyBuilt = fileManager.fileExists(atPath: marker.path)
        if !alreadyBuilt {
            try? fileManager.removeItem(at: root)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        // The counts are recomputed either way so a reused tree reports the
        // same numbers it was built with.
        var leafIndex = 0
        for top in 0..<tops {
            let topURL = root.appendingPathComponent(String(format: "Top Level Folder %03d", top), isDirectory: true)
            directories += 1
            if !alreadyBuilt { try makeDirectory(topURL) }
            for branch in 0..<branchesPerTop {
                let branchURL = topURL.appendingPathComponent(String(format: "project-workspace-%02d", branch), isDirectory: true)
                directories += 1
                if !alreadyBuilt { try makeDirectory(branchURL) }
                for leaf in 0..<leavesPerBranch where leafIndex < leaves {
                    leafIndex += 1
                    let leafURL = branchURL.appendingPathComponent(String(format: "assets-%02d", leaf), isDirectory: true)
                    directories += 1
                    if !alreadyBuilt { try makeDirectory(leafURL) }
                    for item in 0..<filesPerLeaf {
                        let name: String
                        switch item % 5 {
                        case 0: name = String(format: "IMG_2026%04d_%06d.HEIC", leaf, item)
                        case 1: name = String(format: "notes-%02d.txt", item)
                        case 2: name = String(format: "com.example.generated.cache.%05d.plist", item)
                        case 3: name = String(format: "Quarterly Report Draft %03d.pdf", item)
                        default: name = String(format: "a%02d.json", item)
                        }
                        let fileURL = leafURL.appendingPathComponent(name)
                        files += 1
                        if !alreadyBuilt {
                            try makeFile(fileURL, bytes: item % 10 == 0 ? 2_048 + item * 37 : 0)
                        }
                    }
                }
                // One app-like package per branch: counted for size, not drillable.
                let package = branchURL.appendingPathComponent("Helper Tool.app/Contents/MacOS", isDirectory: true)
                directories += 3
                files += 2
                if !alreadyBuilt {
                    try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
                    try makeFile(package.appendingPathComponent("Helper Tool"), bytes: 4_096)
                    try makeFile(package.deletingLastPathComponent().appendingPathComponent("Info.plist"), bytes: 512)
                }
                // A hard link pair and a symbolic link per branch.
                let original = branchURL.appendingPathComponent("shared-original.bin")
                let hardLink = branchURL.appendingPathComponent("shared-hardlink.bin")
                let symbolic = branchURL.appendingPathComponent("shortcut-to-assets")
                files += 2
                links += 1
                if !alreadyBuilt {
                    try makeFile(original, bytes: 8_192)
                    guard Darwin.link(original.path, hardLink.path) == 0 else { throw POSIXError(.EIO) }
                    try fileManager.createSymbolicLink(
                        at: symbolic,
                        withDestinationURL: branchURL.appendingPathComponent("assets-00")
                    )
                }
            }
        }
        if !alreadyBuilt {
            try makeFile(marker, bytes: 0)
        }
        files += 1 // the marker
        return SyntheticStorageTree(root: root, fileCount: files, directoryCount: directories, otherItemCount: links)
    }

    private static func makeDirectory(_ url: URL) throws {
        guard Darwin.mkdir(url.path, 0o755) == 0 || errno == EEXIST else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func makeFile(_ url: URL, bytes: Int) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        if bytes > 0 {
            let buffer = [UInt8](repeating: 0x5A, count: bytes)
            let written = buffer.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, bytes) }
            guard written == bytes else { throw POSIXError(.EIO) }
        }
    }
}

struct ProcessFootprint {
    let current: Int64
    let peak: Int64

    static func sample() -> ProcessFootprint {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return ProcessFootprint(current: 0, peak: 0) }
        return ProcessFootprint(
            current: Int64(info.phys_footprint),
            peak: Int64(info.ledger_phys_footprint_peak)
        )
    }

    func megabytes(_ keyPath: KeyPath<ProcessFootprint, Int64>) -> Double {
        (Double(self[keyPath: keyPath]) / 1_048_576 * 10).rounded() / 10
    }
}

/// Lower-bound estimate of the index's own heap: dictionary slots, entry
/// storage and out-of-line strings. Allocator rounding and dictionary load
/// factors come on top, so the process footprint is the authoritative number.
struct IndexSizeEstimate {
    let bytes: Int
    let directories: Int
    let entries: Int
    /// Child-entry storage reserved by array growth but unused.
    let slackBytes: Int

    init(_ index: StorageMapAnalysisIndex) {
        func stringBytes(_ value: String) -> Int {
            // Swift stores up to 15 UTF-8 bytes inline; longer strings take a
            // separate allocation with a 32-byte header.
            let count = value.utf8.count
            return count <= 15 ? 0 : 32 + count
        }
        var bytes = 0
        var entries = 0
        var slack = 0
        for (path, children) in index.childrenByDirectory {
            bytes += MemoryLayout<String>.stride + MemoryLayout<[StorageMapIndexedEntry]>.stride + stringBytes(path)
            bytes += 32 + children.capacity * MemoryLayout<StorageMapIndexedEntry>.stride
            slack += (children.capacity - children.count) * MemoryLayout<StorageMapIndexedEntry>.stride
            entries += children.count
            for child in children {
                bytes += stringBytes(child.name) + stringBytes(child.kind)
            }
        }
        for (path, _) in index.directories {
            bytes += MemoryLayout<String>.stride + MemoryLayout<StorageMapDirectoryAggregate>.stride + stringBytes(path)
        }
        for path in index.blockedDirectoryPaths.union(index.duplicateFilePaths) {
            bytes += MemoryLayout<String>.stride + stringBytes(path)
        }
        self.bytes = bytes
        self.directories = index.directories.count
        self.entries = entries
        slackBytes = slack
    }
}
