import Foundation
import XCTest
@testable import StorageCleanerMac

final class ApplicationInventoryMetadataCacheTests: XCTestCase {
    func testScannerBatchesUsePersistentDisplayCacheAcrossRestart() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let urls = try (0..<2).map { try AppUpdatePerformanceTestSupport.bundle(in: root, name: "Batch\($0)") }
        let inspector = AppUpdateCountingSignatureInspector()
        let cacheURL = root.appendingPathComponent("scanner-cache.json")
        let cache = ApplicationInventoryMetadataCache(fileURL: cacheURL)
        let first = ApplicationInventoryScanner(metadataReader: ApplicationMetadataReader(signatureInspector: inspector), metadataCache: cache)
        let cold = try await first.readMetadata(urls: urls, runningState: AppUpdatePerformanceTestSupport.idle, onProgress: { _ in }, onApplications: { _ in })
        XCTAssertEqual(cold.count, 2)
        try await cache.flush()
        let second = ApplicationInventoryScanner(metadataReader: ApplicationMetadataReader(signatureInspector: inspector), metadataCache: ApplicationInventoryMetadataCache(fileURL: cacheURL))
        let warm = try await second.readMetadata(urls: urls, runningState: AppUpdatePerformanceTestSupport.idle, onProgress: { _ in }, onApplications: { _ in })
        XCTAssertEqual(warm.count, 2)
        let paths = await inspector.paths
        XCTAssertEqual(paths.count, 2, "Two cold inspections, zero additional inspections after scanner restart")
    }

    func testUnchangedBundlesHitAcrossRestartWithoutMetadataOrSignatureReads() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let urls = try (0..<3).map { try AppUpdatePerformanceTestSupport.bundle(in: root, name: "App\($0)") }
        let file = root.appendingPathComponent("display-cache.json")
        let firstInspector = AppUpdateCountingSignatureInspector()
        let first = AppUpdateCountingMetadataReader(inspector: firstInspector)
        let cold = ApplicationInventoryMetadataReader(reader: first, cache: ApplicationInventoryMetadataCache(fileURL: file), fingerprintReader: AppUpdatePerformanceTestSupport.fingerprints())
        for url in urls { _ = await cold.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle) }
        try await cold.cache.flush()
        let coldCount = await first.count
        let coldSignatureCount = await firstInspector.paths.count
        XCTAssertEqual(coldCount, 3)
        XCTAssertEqual(coldSignatureCount, 3)
        let originalCacheBytes = try Data(contentsOf: file)

        // New reader/cache instances model process restart. Dynamic facts must
        // still come from this scan, despite reusing the static metadata.
        let secondInspector = AppUpdateCountingSignatureInspector()
        let second = AppUpdateCountingMetadataReader(inspector: secondInspector)
        let warm = ApplicationInventoryMetadataReader(reader: second, cache: ApplicationInventoryMetadataCache(fileURL: file), fingerprintReader: AppUpdatePerformanceTestSupport.fingerprints())
        let scanDate = Date(timeIntervalSince1970: 123_456)
        let running = ApplicationRunningStateSnapshot(bundleIdentifiers: ["com.example.example"], normalizedBundlePaths: [])
        for url in urls {
            let result = await warm.read(applicationURL: url, runningState: running, scanDate: scanDate)
            XCTAssertTrue(try XCTUnwrap(result).isRunning)
            XCTAssertEqual(result?.lastScanDate, scanDate)
        }
        try await warm.cache.flush()
        let warmCount = await second.count
        let warmSignatureCount = await secondInspector.paths.count
        XCTAssertEqual(warmCount, 0, "Three unchanged bundles avoid three full metadata reads")
        XCTAssertEqual(warmSignatureCount, 0, "Three unchanged bundles avoid three Security inspections")
        XCTAssertEqual(try Data(contentsOf: file), originalCacheBytes, "Hits must not rewrite the persistent cache")
    }

    func testNewOrReplacedSamePathSameVersionBundleIsReadAgain() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let inspector = AppUpdateCountingSignatureInspector()
        let raw = AppUpdateCountingMetadataReader(inspector: inspector)
        let display = reader(root: root, raw: raw)
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let before = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        _ = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("previous.app"))
        _ = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let after = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        XCTAssertEqual(before?.installedVersion, after?.installedVersion)
        let count = await raw.count
        let signatures = await inspector.paths.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(signatures, 2, "A same-path/same-version replacement must miss")
        let added = try AppUpdatePerformanceTestSupport.bundle(in: root, name: "New")
        _ = await display.read(applicationURL: added, runningState: AppUpdatePerformanceTestSupport.idle)
        let afterAdding = await raw.count
        XCTAssertEqual(afterAdding, 3, "Only the new bundle adds a full read")
    }

    func testInfoExecutableAndCodeSignatureChangesMissWithUnchangedRootMtime() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let fingerprints = AppUpdatePerformanceTestSupport.fingerprints()
        let inspector = AppUpdateCountingSignatureInspector()
        let raw = AppUpdateCountingMetadataReader(inspector: inspector)
        let display = reader(root: root, raw: raw)
        _ = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        for (index, relative) in ["Contents/Info.plist", "Contents/MacOS/Example", "Contents/_CodeSignature/CodeResources"].enumerated() {
            let before = try await fingerprints.fingerprint(at: url)
            if relative.hasSuffix("Info.plist") {
                try AppUpdatePerformanceTestSupport.writeInfo(at: url, extra: "b")
            } else {
                try Data("changed-content-\(index)".utf8).write(to: url.appendingPathComponent(relative))
            }
            let after = try await fingerprints.fingerprint(at: url)
            XCTAssertEqual(before.root, after.root, "This mutation does not touch the root directory")
            XCTAssertNotEqual(before.descendantDigest, after.descendantDigest)
            let application = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
            XCTAssertEqual(application?.installedVersion.marketing, "1.0")
            let count = await raw.count
            XCTAssertEqual(count, index + 2)
        }
    }

    func testChildResourceModificationInvalidatesCachedValidSignatureWithoutRootChange() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let fingerprints = AppUpdatePerformanceTestSupport.fingerprints()
        let inspector = AppUpdateCountingSignatureInspector()
        let raw = AppUpdateCountingMetadataReader(inspector: inspector)
        let display = reader(root: root, raw: raw)
        let original = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        XCTAssertTrue(try XCTUnwrap(original).sourceEvidence.contains("valid-code-signature"))
        let before = try await fingerprints.fingerprint(at: url)
        let resource = url.appendingPathComponent("Contents/Resources/payload")
        let originalMtime = try resource.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try Data("resource-b".utf8).write(to: resource)
        // Restoring mtime and keeping file size/inode still cannot restore ctime.
        if let originalMtime { try FileManager.default.setAttributes([.modificationDate: originalMtime], ofItemAtPath: resource.path) }
        await inspector.setValid(false)
        let after = try await fingerprints.fingerprint(at: url)
        XCTAssertEqual(before.root, after.root)
        XCTAssertNotEqual(before.descendantDigest, after.descendantDigest)
        let changed = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        XCTAssertFalse(try XCTUnwrap(changed).sourceEvidence.contains("valid-code-signature"))
        let count = await raw.count
        let signatures = await inspector.paths.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(signatures, 2)
    }

    func testExternalRemountIdentityMissesEvenWhenEveryFileStatIsIdentical() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let file = root.appendingPathComponent("cache.json")
        let inspector = AppUpdateCountingSignatureInspector()
        let raw = AppUpdateCountingMetadataReader(inspector: inspector)
        let first = ApplicationInventoryMetadataReader(reader: raw, cache: ApplicationInventoryMetadataCache(fileURL: file), fingerprintReader: AppUpdatePerformanceTestSupport.fingerprints(mount: "external|session-1|mount-1"))
        _ = await first.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        try await first.cache.flush()
        let mount2 = AppUpdatePerformanceTestSupport.fingerprints(mount: "external|session-1|mount-2")
        let before = try await AppUpdatePerformanceTestSupport.fingerprints(mount: "external|session-1|mount-1").fingerprint(at: url)
        let after = try await mount2.fingerprint(at: url)
        XCTAssertEqual(before.root, after.root)
        XCTAssertEqual(before.descendantDigest, after.descendantDigest)
        let second = ApplicationInventoryMetadataReader(reader: raw, cache: ApplicationInventoryMetadataCache(fileURL: file), fingerprintReader: mount2)
        _ = await second.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        _ = await second.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        let count = await raw.count
        XCTAssertEqual(count, 2, "Remount misses once; unchanged bundles in the new mount hit")
    }

    func testCorruptOversizeOrUnknownVersionFileIsDiscardedAndRebuilt() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let file = root.appendingPathComponent("cache.json")
        let inspector = AppUpdateCountingSignatureInspector()
        let raw = AppUpdateCountingMetadataReader(inspector: inspector)
        let initial = reader(root: root, raw: raw)
        _ = await initial.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        try await initial.cache.flush()
        let valid = try Data(contentsOf: file)
        var versioned = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        versioned["version"] = 999
        var wrongChecksum = versioned
        wrongChecksum["version"] = ApplicationInventoryMetadataCache.schemaVersion
        wrongChecksum["checksum"] = "bad"
        let invalidFiles = [Data([0xff]), try JSONSerialization.data(withJSONObject: versioned), try JSONSerialization.data(withJSONObject: wrongChecksum), Data(repeating: 0, count: 16_385)]
        for (index, invalid) in invalidFiles.enumerated() {
            try invalid.write(to: file)
            let display = reader(root: root, raw: raw, maximumBytes: 16_384)
            _ = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
            try await display.cache.flush()
            let count = await raw.count
            XCTAssertEqual(count, index + 2)
            XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 16_384)
            let reread = reader(root: root, raw: raw, maximumBytes: 16_384)
            _ = await reread.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
            let afterRebuild = await raw.count
            XCTAssertEqual(afterRebuild, index + 2, "A rebuilt file must be reusable")
        }
    }

    func testEntryAndByteLimitsEvictRatherThanReuseOversizedCache() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let inspector = AppUpdateCountingSignatureInspector()
        let raw = AppUpdateCountingMetadataReader(inspector: inspector)
        let firstURL = try AppUpdatePerformanceTestSupport.bundle(in: root, name: "First")
        let secondURL = try AppUpdatePerformanceTestSupport.bundle(in: root, name: "Second")
        let display = reader(root: root, raw: raw, maximumEntries: 1)
        _ = await display.read(applicationURL: firstURL, runningState: AppUpdatePerformanceTestSupport.idle)
        _ = await display.read(applicationURL: secondURL, runningState: AppUpdatePerformanceTestSupport.idle)
        try await display.cache.flush()
        let restarted = reader(root: root, raw: raw, maximumEntries: 1)
        _ = await restarted.read(applicationURL: secondURL, runningState: AppUpdatePerformanceTestSupport.idle)
        _ = await restarted.read(applicationURL: firstURL, runningState: AppUpdatePerformanceTestSupport.idle)
        let count = await raw.count
        XCTAssertEqual(count, 3, "One retained entry hits, one evicted entry misses")

        let tiny = reader(root: root, raw: raw, maximumBytes: 512)
        _ = await tiny.read(applicationURL: secondURL, runningState: AppUpdatePerformanceTestSupport.idle)
        try await tiny.cache.flush()
        XCTAssertLessThanOrEqual(try Data(contentsOf: root.appendingPathComponent("cache.json")).count, 512)
        let tinyRestarted = reader(root: root, raw: raw, maximumBytes: 512)
        _ = await tinyRestarted.read(applicationURL: secondURL, runningState: AppUpdatePerformanceTestSupport.idle)
        let finalCount = await raw.count
        XCTAssertEqual(finalCount, 5, "An entry too large for the byte limit cannot persist")
    }

    func testUnreadableFingerprintNeverReusesCachedMetadata() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let raw = AppUpdateCountingMetadataReader(inspector: AppUpdateCountingSignatureInspector())
        let display = reader(root: root, raw: raw)
        _ = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        // An external symlink makes fingerprinting fail closed, while the raw
        // metadata reader can still describe this ordinary bundle.
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("Contents/Resources/external"), withDestinationURL: root)
        _ = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        _ = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        let count = await raw.count
        XCTAssertEqual(count, 3)
    }

    func testDefaultCacheLocationUsesIsolatedAppDataRoot() {
        XCTAssertEqual(ApplicationInventoryMetadataCache.defaultFileURL, AppDataDirectories.applicationSupportRoot.appendingPathComponent("AppUpdates/inventory-metadata-v1.json"))
    }

    func testTemporarySignatureUnreadabilityRecoversWithoutAnyFileStatChange() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = try AppUpdatePerformanceTestSupport.bundle(in: root)
        let inspector = AppUpdateCountingSignatureInspector()
        let raw = AppUpdateCountingMetadataReader(inspector: inspector)
        let display = reader(root: root, raw: raw)
        let before = try await AppUpdatePerformanceTestSupport.fingerprints().fingerprint(at: url)
        await inspector.setValid(false)
        let unreadable = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        XCTAssertFalse(try XCTUnwrap(unreadable).sourceEvidence.contains("valid-code-signature"))
        try await display.cache.flush()
        await inspector.setValid(true)
        let recovered = await display.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        XCTAssertTrue(try XCTUnwrap(recovered).sourceEvidence.contains("valid-code-signature"))
        try await display.cache.flush()
        let after = try await AppUpdatePerformanceTestSupport.fingerprints().fingerprint(at: url)
        XCTAssertEqual(before, after, "Recovery did not require any filesystem identity change")
        let restarted = reader(root: root, raw: raw)
        _ = await restarted.read(applicationURL: url, runningState: AppUpdatePerformanceTestSupport.idle)
        let reads = await raw.count
        let signatures = await inspector.paths.count
        XCTAssertEqual(reads, 2, "Unreadable state retries; only the recovered valid result is cached")
        XCTAssertEqual(signatures, 2)
    }

    private func reader(root: URL, raw: AppUpdateCountingMetadataReader, maximumBytes: Int = 8 * 1_024 * 1_024, maximumEntries: Int = 2_048) -> ApplicationInventoryMetadataReader {
        ApplicationInventoryMetadataReader(
            reader: raw,
            cache: ApplicationInventoryMetadataCache(fileURL: root.appendingPathComponent("cache.json"), maximumBytes: maximumBytes, maximumEntries: maximumEntries),
            fingerprintReader: AppUpdatePerformanceTestSupport.fingerprints()
        )
    }
}
