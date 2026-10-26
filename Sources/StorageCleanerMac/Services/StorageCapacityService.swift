import Foundation

enum StorageCapacityPressure: Equatable, Sendable {
    case normal
    case attention
    case critical
}

struct StorageCapacitySnapshot: Equatable, Sendable {
    let totalBytes: Int64
    let availableBytes: Int64
    let availableForImportantUsageBytes: Int64?

    init(
        totalBytes: Int64,
        availableBytes: Int64,
        availableForImportantUsageBytes: Int64? = nil
    ) {
        self.totalBytes = max(0, totalBytes)
        self.availableBytes = min(max(0, availableBytes), max(0, totalBytes))
        self.availableForImportantUsageBytes = availableForImportantUsageBytes.map {
            min(max(0, $0), max(0, totalBytes))
        }
    }

    var usedBytes: Int64 {
        max(0, totalBytes - availableBytes)
    }

    var usedRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    var availableRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(availableBytes) / Double(totalBytes)))
    }

    var availablePercent: Int {
        Int((availableRatio * 100).rounded())
    }

    /// User-visible capacity comparable to Finder's available-space figure.
    /// The important-usage value may include capacity macOS can reclaim, while
    /// `availableBytes` deliberately remains the stricter filesystem-free value.
    var userAvailableBytes: Int64 {
        min(
            totalBytes,
            max(availableBytes, availableForImportantUsageBytes ?? availableBytes)
        )
    }

    var userUsedBytes: Int64 {
        max(0, totalBytes - userAvailableBytes)
    }

    var reclaimableEstimateBytes: Int64 {
        max(0, userAvailableBytes - availableBytes)
    }

    /// D173: a reading without the important-usage figure, completed with
    /// the purgeable space measured on an earlier reading; unchanged when
    /// it carries its own figure or none was measured.
    func addingPurgeableEstimate(_ purgeableBytes: Int64?) -> StorageCapacitySnapshot {
        guard availableForImportantUsageBytes == nil, let purgeableBytes, purgeableBytes > 0 else { return self }
        let sum = availableBytes.addingReportingOverflow(purgeableBytes)
        return StorageCapacitySnapshot(
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            availableForImportantUsageBytes: sum.overflow ? totalBytes : sum.partialValue
        )
    }

    var userAvailableRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(userAvailableBytes) / Double(totalBytes)))
    }

    var userUsedRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(userUsedBytes) / Double(totalBytes)))
    }

    var userAvailablePercent: Int {
        min(100, max(0, Int((userAvailableRatio * 100).rounded())))
    }

    var userUsedPercent: Int {
        min(100, max(0, Int((userUsedRatio * 100).rounded())))
    }

    var pressure: StorageCapacityPressure {
        guard totalBytes > 0 else { return .critical }
        let pressureAvailable = availableForImportantUsageBytes ?? availableBytes
        let pressureRatio = min(1, max(0, Double(pressureAvailable) / Double(totalBytes)))
        if pressureRatio <= 0.10 {
            return .critical
        }
        if pressureRatio <= 0.20 {
            return .attention
        }
        return .normal
    }
}

enum StorageCapacityService {
    /// `includeImportantUsage` false leaves out the important-usage figure:
    /// reading it makes macOS ask CacheDelete, and every service registered
    /// with it, for its purgeable space (D173: about 170 log lines a read; iStat
    /// reads it every 5 minutes). Total and free space never need it.
    static func snapshot(path: String = "/", includeImportantUsage: Bool = true) -> StorageCapacitySnapshot? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let isInternalVolume = (try? url.resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal == true
        let keys = resourceKeys(path: path, isInternalVolume: isInternalVolume,
                                includeImportantUsage: includeImportantUsage)
        let values = try? url.resourceValues(forKeys: keys)
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path)

        let total = values?.volumeTotalCapacity.map(Int64.init)
            ?? (attributes?[.systemSize] as? NSNumber)?.int64Value
            ?? 0
        let available = values?.volumeAvailableCapacity.map(Int64.init)
            ?? (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
        let availableForImportantUsage = values?.volumeAvailableCapacityForImportantUsage

        return measuredSnapshot(total: total, available: available,
                                availableForImportantUsage: availableForImportantUsage)
    }

    static func measuredSnapshot(
        total: Int64,
        available: Int64?,
        availableForImportantUsage: Int64? = nil
    ) -> StorageCapacitySnapshot? {
        guard total > 0, let available, available >= 0 else { return nil }
        return StorageCapacitySnapshot(
            totalBytes: total,
            availableBytes: available,
            availableForImportantUsageBytes: availableForImportantUsage
        )
    }

    static func resourceKeys(
        path: String,
        isInternalVolume: Bool = false,
        includeImportantUsage: Bool = true
    ) -> Set<URLResourceKey> {
        var keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
        ]
        if includeImportantUsage, isInternalVolume || URL(fileURLWithPath: path).standardizedFileURL.path == "/" {
            keys.insert(.volumeAvailableCapacityForImportantUsageKey)
        }
        return keys
    }
}
