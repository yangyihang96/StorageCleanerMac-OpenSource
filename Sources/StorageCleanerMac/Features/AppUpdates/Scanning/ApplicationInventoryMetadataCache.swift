import CryptoKit
import Foundation

protocol ApplicationMetadataReading: Sendable {
    func read(
        applicationURL: URL,
        runningState: ApplicationRunningStateSnapshot,
        scanDate: Date
    ) async -> InstalledApplication?
}

/// Only the inventory scanner owns this cache. Execution uses the uncached
/// ApplicationMetadataReader/VerifiedInstalledApplicationRechecker instead.
actor ApplicationInventoryMetadataCache {
    static let schemaVersion = 1
    static let defaultMaximumBytes = 8 * 1_024 * 1_024
    static let defaultMaximumEntries = 2_048

    static var defaultFileURL: URL {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("AppUpdates", isDirectory: true)
            .appendingPathComponent("inventory-metadata-v1.json", isDirectory: false)
    }

    private struct Entry: Codable, Sendable {
        let fingerprint: ApplicationBundleFingerprint
        let application: InstalledApplication
        var lastUsed: Date
    }
    private struct Envelope: Codable {
        let version: Int
        let checksum: String
        let payload: Data
    }
    private let fileURL: URL
    private let maximumBytes: Int
    private let maximumEntries: Int
    private var entries = [String: Entry]()
    private var loaded = false
    private var dirty = false

    init(
        fileURL: URL = ApplicationInventoryMetadataCache.defaultFileURL,
        maximumBytes: Int = ApplicationInventoryMetadataCache.defaultMaximumBytes,
        maximumEntries: Int = ApplicationInventoryMetadataCache.defaultMaximumEntries
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.maximumBytes = max(1, maximumBytes)
        self.maximumEntries = max(1, maximumEntries)
    }

    func cached(at url: URL, fingerprint: ApplicationBundleFingerprint) -> InstalledApplication? {
        loadIfNeeded()
        let key = url.standardizedFileURL.path
        guard var entry = entries[key], entry.fingerprint == fingerprint else {
            if entries.removeValue(forKey: key) != nil { dirty = true }
            return nil
        }
        entry.lastUsed = Date()
        entries[key] = entry
        return entry.application
    }

    func store(_ application: InstalledApplication, fingerprint: ApplicationBundleFingerprint) {
        loadIfNeeded()
        // isValid=false conflates invalid code with temporarily unavailable
        // Security/permissions. Never persist that state across scans.
        guard application.sourceEvidence.contains("valid-code-signature") else {
            invalidate(at: application.bundleURL)
            return
        }
        entries[application.bundleURL.standardizedFileURL.path] = Entry(
            fingerprint: fingerprint, application: application, lastUsed: Date()
        )
        while entries.count > maximumEntries { evictOldest() }
        dirty = true
    }

    func invalidate(at url: URL) {
        loadIfNeeded()
        if entries.removeValue(forKey: url.standardizedFileURL.path) != nil { dirty = true }
    }

    /// Once per scan, not once per bundle; hits never rewrite the cache file.
    func flush() throws {
        guard dirty else { return }
        var data = try encodedEnvelope()
        while data.count > maximumBytes, !entries.isEmpty {
            evictOldest()
            data = try encodedEnvelope()
        }
        guard data.count <= maximumBytes else {
            try discardFile()
            dirty = false
            return
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
        dirty = false
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= maximumBytes else {
                throw ApplicationBundleFingerprintError.unreadable
            }
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else { throw ApplicationBundleFingerprintError.unreadable }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == Self.schemaVersion,
                  envelope.checksum == Self.checksum(envelope.payload) else {
                throw ApplicationBundleFingerprintError.unreadable
            }
            let decoded = try JSONDecoder().decode([String: Entry].self, from: envelope.payload)
            guard decoded.count <= maximumEntries,
                  decoded.allSatisfy({ key, entry in
                      entry.application.bundleURL.isFileURL
                          && entry.application.sourceEvidence.contains("valid-code-signature")
                          && entry.application.bundleURL.standardizedFileURL.path == key
                          && entry.fingerprint.descendantDigest.count == 64
                          && entry.fingerprint.descendantCount >= 0
                  }) else { throw ApplicationBundleFingerprintError.unreadable }
            entries = decoded
        } catch {
            // Never partially recover identities from an invalid envelope.
            entries.removeAll()
            dirty = true
            // Deletion failure does not turn the old data into a cache hit;
            // flush retries replacement and the scan reports write failures.
            try? discardFile()
        }
    }

    private func encodedEnvelope() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(entries)
        return try encoder.encode(Envelope(version: Self.schemaVersion, checksum: Self.checksum(payload), payload: payload))
    }

    private static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func evictOldest() {
        guard let key = entries.min(by: {
            if $0.value.lastUsed != $1.value.lastUsed { return $0.value.lastUsed < $1.value.lastUsed }
            return $0.key < $1.key
        })?.key else { return }
        entries.removeValue(forKey: key)
    }

    private func discardFile() throws {
        do { try FileManager.default.removeItem(at: fileURL) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return }
    }
}

struct ApplicationInventoryMetadataReader: Sendable {
    let reader: any ApplicationMetadataReading
    let cache: ApplicationInventoryMetadataCache
    let fingerprintReader: any ApplicationBundleFingerprintReading

    init(
        reader: any ApplicationMetadataReading = ApplicationMetadataReader(),
        cache: ApplicationInventoryMetadataCache = ApplicationInventoryMetadataCache(),
        fingerprintReader: any ApplicationBundleFingerprintReading = FileSystemApplicationBundleFingerprintReader()
    ) {
        self.reader = reader
        self.cache = cache
        self.fingerprintReader = fingerprintReader
    }

    func read(
        applicationURL: URL,
        runningState: ApplicationRunningStateSnapshot,
        scanDate: Date = Date()
    ) async -> InstalledApplication? {
        guard !Task.isCancelled else { return nil }
        let fingerprint = try? await fingerprintReader.fingerprint(at: applicationURL)
        if let fingerprint, var application = await cache.cached(at: applicationURL, fingerprint: fingerprint) {
            application.isRunning = runningState.contains(bundleIdentifier: application.bundleIdentifier, bundleURL: applicationURL)
            application.lastScanDate = scanDate
            application.sourceDisplayName = ApplicationMetadataReader.sourceDisplayName(for: application.installationSource)
            return application
        }
        await cache.invalidate(at: applicationURL)
        guard !Task.isCancelled else { return nil }
        let application = await reader.read(applicationURL: applicationURL, runningState: runningState, scanDate: scanDate)
        if let application, application.sourceEvidence.contains("valid-code-signature"),
           let fingerprint, !Task.isCancelled,
           let after = try? await fingerprintReader.fingerprint(at: applicationURL), after == fingerprint {
            await cache.store(application, fingerprint: fingerprint)
        }
        return application
    }
}
