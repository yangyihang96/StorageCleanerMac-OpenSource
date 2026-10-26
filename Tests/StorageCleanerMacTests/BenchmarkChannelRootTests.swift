import FanControlShared
import Foundation
import XCTest
@testable import StorageCleanerMac

/// D106-R1: benchmark temporaries belong to the running channel. The Beta
/// (built with `-D STORAGE_CLEANER_BETA`) uses
/// `StorageCleanerMac-Beta/BenchmarkTemporary`; release keeps
/// `StorageCleanerMac/BenchmarkTemporary`. Run this class in a normal build and
/// in a build with the Beta flag: each build checks its own channel, and that
/// the other channel's folder is never listed or touched.
final class BenchmarkChannelRootTests: XCTestCase {
    private let ownFolder = StorageCleanerBuildIdentity.applicationSupportDirectoryName
    private let otherFolder = AppDataDirectories.applicationSupportDirectoryName(
        isBeta: !StorageCleanerBuildIdentity.isBeta
    )

    func testTheBuildConditionNamesTheChannelFolder() {
#if STORAGE_CLEANER_BETA
        XCTAssertTrue(StorageCleanerBuildIdentity.isBeta)
        XCTAssertEqual(ownFolder, "StorageCleanerMac-Beta")
        XCTAssertEqual(otherFolder, "StorageCleanerMac")
#else
        XCTAssertFalse(StorageCleanerBuildIdentity.isBeta)
        XCTAssertEqual(ownFolder, "StorageCleanerMac")
        XCTAssertEqual(otherFolder, "StorageCleanerMac-Beta")
#endif
        XCTAssertEqual(
            AppDataDirectories.applicationSupportDirectoryName(isBeta: StorageCleanerBuildIdentity.isBeta),
            ownFolder
        )
    }

    /// Paths only: nothing here is opened, listed or created.
    func testEveryDefaultRootIsTheChannelsOwnFolder() throws {
        let base = URL(fileURLWithPath: "/private/var/empty/benchmark-channel-fixture", isDirectory: true)
        XCTAssertEqual(
            DiskBenchmarkKernel.defaultRootDirectory(fileManager: ApplicationSupportFixture(base: base)).path,
            base.appendingPathComponent(ownFolder).appendingPathComponent("BenchmarkTemporary").path
        )

        let root = DiskBenchmarkKernel.defaultRootDirectory
        XCTAssertEqual(
            root,
            AppDataDirectories.applicationSupportRoot.appendingPathComponent("BenchmarkTemporary", isDirectory: true)
        )
        XCTAssertEqual(root, MSeriesProtocol.temporaryRoot, "the performance page and every default share one folder")
        XCTAssertEqual(root.deletingLastPathComponent().lastPathComponent, ownFolder)
        XCTAssertEqual(DiskBenchmarkKernel().rootDirectory, root.standardizedFileURL)
        XCTAssertEqual(
            SystemMacBenchmarkLifecycleCleaner().diskKernel.rootDirectory,
            root.standardizedFileURL,
            "the launch-time sweep"
        )
#if !STORAGE_CLEANER_BETA
        // Release keeps the folder it always used.
        let applicationSupport = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        XCTAssertEqual(
            root.path,
            applicationSupport.appendingPathComponent("StorageCleanerMac/BenchmarkTemporary").path
        )
#endif
    }

    /// Callers that cannot be built here without the real folders name the
    /// kernel's default instead of a folder of their own.
    func testLegacyAndV7DefaultsUseTheKernelDefault() throws {
        let sources = try SwiftSourceScanning.sources()
        func source(_ path: String) throws -> String {
            try XCTUnwrap(sources["Sources/StorageCleanerMac/" + path], path)
        }
        let compact = { (text: String) in text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

        let legacy = compact(try source("Services/Benchmark/MacBenchmarkService.swift"))
        XCTAssertTrue(legacy.contains("diskKernel: DiskBenchmarkKernel = DiskBenchmarkKernel()"))
        XCTAssertTrue(legacy.contains("var probeURL = DiskBenchmarkKernel.defaultRootDirectory.standardizedFileURL"))
        XCTAssertTrue(compact(try source("Services/Benchmark/MacBenchmarkLifecycle.swift"))
            .contains("diskKernel: DiskBenchmarkKernel = DiskBenchmarkKernel(),"))
        XCTAssertTrue(compact(try source("Stores/MacBenchmarkStore.swift"))
            .contains("lifecycleCleaner: any MacBenchmarkLifecycleCleaning = SystemMacBenchmarkLifecycleCleaner(),"))

        var targetDefaults: [String] = []
        for (path, text) in sources where path.hasPrefix("Sources/") {
            for line in text.split(separator: "\n") where line.contains("targetDirectory: URL =") {
                targetDefaults.append("\(path): \(line.trimmingCharacters(in: .whitespaces))")
                XCTAssertTrue(line.contains("targetDirectory: URL = DiskBenchmarkKernel.defaultRootDirectory"), "\(path): \(line)")
            }
        }
        XCTAssertEqual(targetDefaults.count, 5, targetDefaults.joined(separator: "\n"))

        // Only the two definitions name the folder; nothing names a channel's
        // Application Support folder by hand.
        let naming = sources.filter { $0.key.hasPrefix("Sources/") && $0.value.contains("\"BenchmarkTemporary\"") }
        XCTAssertEqual(naming.keys.sorted(), [
            "Sources/StorageCleanerMac/Services/Benchmark/DiskBenchmarkKernel.swift",
            "Sources/StorageCleanerMac/Services/Benchmark/MSeries/MSeriesProtocol.swift"
        ])
        for (path, text) in sources where path.hasPrefix("Sources/StorageCleanerMac/") {
            XCTAssertFalse(text.contains("appendingPathComponent(\"StorageCleanerMac\""), path)
        }
    }

    /// The file manager is a recorder: it lists an old orphan in both
    /// channels' folders whatever it is asked. The sweep asks only about this
    /// channel's folder and removes only the orphan inside it.
    func testTheSweepNeverListsOrRemovesTheOtherChannelsFolder() async throws {
        let base = URL(fileURLWithPath: "/private/var/empty/benchmark-channel-fixture", isDirectory: true)
        let own = DiskBenchmarkKernel.defaultRootDirectory(fileManager: ApplicationSupportFixture(base: base))
            .standardizedFileURL
        let other = base.appendingPathComponent(otherFolder, isDirectory: true)
            .appendingPathComponent("BenchmarkTemporary", isDirectory: true).standardizedFileURL
        let old = Date(timeIntervalSince1970: 1)
        let manager = RecordingDiskBenchmarkFileManager(candidates: [own, other].map {
            DiskBenchmarkOrphanCandidate(
                url: $0.appendingPathComponent("benchmark-old.tmp"),
                modificationDate: old,
                isRegularFile: true,
                isSymbolicLink: false
            )
        })

        let removed = try await DiskBenchmarkKernel(rootDirectory: own, fileManager: manager)
            .cleanupOrphans(olderThan: 24 * 60 * 60, now: Date(timeIntervalSince1970: 1_000_000))

        XCTAssertEqual(removed, 1)
        let calls = await manager.calls
        XCTAssertEqual(calls, [
            "prepare \(own.path)",
            "list \(own.path)",
            "remove \(own.appendingPathComponent("benchmark-old.tmp").path)"
        ])
        XCTAssertFalse(calls.contains { $0.contains(other.path) }, calls.joined(separator: "\n"))
    }

    /// The same with real files, both channels' folders in a private
    /// temporary fixture: only this channel's old orphan goes; the other
    /// folder keeps every entry unchanged, and the existing age, name and
    /// link checks still hold.
    func testOnlyThisChannelsOldOrphanLeavesARealFixture() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("BenchmarkChannelRootTests-\(UUID().uuidString)", isDirectory: true)
        defer { TestFileSystem.remove(base) }
        let own = DiskBenchmarkKernel.defaultRootDirectory(fileManager: ApplicationSupportFixture(base: base))
        let other = base.appendingPathComponent(otherFolder, isDirectory: true)
            .appendingPathComponent("BenchmarkTemporary", isDirectory: true)
        for root in [own, other] {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let now = Date()
        let old = now.addingTimeInterval(-48 * 60 * 60)
        func makeFile(_ url: URL, modified: Date) throws {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data([1])))
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        let ownOld = own.appendingPathComponent("benchmark-old.tmp")
        let ownYoung = own.appendingPathComponent("benchmark-young.tmp")
        let ownUnrelated = own.appendingPathComponent("notes.tmp")
        let ownLink = own.appendingPathComponent("benchmark-link.tmp")
        try makeFile(ownOld, modified: old)
        try makeFile(ownYoung, modified: now)
        try makeFile(ownUnrelated, modified: old)
        for name in ["benchmark-old.tmp", "benchmark-young.tmp", "notes.tmp"] {
            try makeFile(other.appendingPathComponent(name), modified: name == "benchmark-young.tmp" ? now : old)
        }
        try FileManager.default.createSymbolicLink(
            at: ownLink,
            withDestinationURL: other.appendingPathComponent("benchmark-old.tmp")
        )
        let otherBefore = try snapshot(other)

        let removed = try await DiskBenchmarkKernel(rootDirectory: own)
            .cleanupOrphans(olderThan: 24 * 60 * 60, now: now)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownOld.path))
        for kept in [ownYoung, ownUnrelated] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), kept.lastPathComponent)
        }
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: ownLink.path))
        XCTAssertEqual(try snapshot(other), otherBefore, "the other channel's folder is untouched")
    }

    /// Name, inode, size and modification time of every entry, and the
    /// folder's own modification time.
    private func snapshot(_ folder: URL) throws -> [String] {
        func describe(_ path: String) throws -> String {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(inode) \(size) \(modified)"
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        return try ["folder " + describe(folder.path)]
            + names.map { "\($0) " + (try describe(folder.appendingPathComponent($0).path)) }
    }
}

/// Answers only the Application Support lookup; the base is a fixture path.
private final class ApplicationSupportFixture: FileManager, @unchecked Sendable {
    private let base: URL

    init(base: URL) {
        self.base = base
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        directory == .applicationSupportDirectory ? [base] : super.urls(for: directory, in: domainMask)
    }
}

private actor RecordingDiskBenchmarkFileManager: DiskBenchmarkFileManaging {
    private let candidates: [DiskBenchmarkOrphanCandidate]
    private(set) var calls: [String] = []

    init(candidates: [DiskBenchmarkOrphanCandidate]) {
        self.candidates = candidates
    }

    func prepareDirectory(_ url: URL) async throws {
        calls.append("prepare \(url.path)")
    }

    func availableCapacity(at url: URL) async throws -> Int64 {
        calls.append("capacity \(url.path)")
        return 0
    }

    func createExclusiveFile(at url: URL) async throws -> any DiskBenchmarkFileSession {
        calls.append("create \(url.path)")
        throw BenchmarkKernelError.systemFailure
    }

    func removeFile(at url: URL) async throws {
        calls.append("remove \(url.path)")
    }

    func orphanCandidates(in directory: URL) async throws -> [DiskBenchmarkOrphanCandidate] {
        calls.append("list \(directory.path)")
        return candidates
    }
}
