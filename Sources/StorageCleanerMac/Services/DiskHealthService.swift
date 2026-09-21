import Darwin
import Foundation

struct DiskHealthCommand: Hashable, Sendable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval
}

protocol DiskHealthCommandRunning {
    func capture(_ command: DiskHealthCommand) throws -> Data
}

enum DiskHealthCommandFailure: Error, Equatable {
    case permissionDenied
    case timedOut
    case cancelled
    case unavailable
}

struct ShellDiskHealthCommandRunner: DiskHealthCommandRunning {
    private static let outputByteLimit = 1_048_576

    func capture(_ command: DiskHealthCommand) throws -> Data {
        do {
            let output = try Shell.captureCancellable(
                command.executable,
                command.arguments,
                timeout: command.timeout,
                outputByteLimit: Self.outputByteLimit,
                cancellationCheck: {
                    withUnsafeCurrentTask { $0?.isCancelled ?? false }
                }
            )
            return Data(output.utf8)
        } catch is CancellationError {
            throw DiskHealthCommandFailure.cancelled
        } catch ShellError.cancelled {
            throw DiskHealthCommandFailure.cancelled
        } catch ShellError.timedOut {
            throw DiskHealthCommandFailure.timedOut
        } catch {
            throw Self.safeFailure(for: error)
        }
    }

    private static func safeFailure(for error: Error) -> DiskHealthCommandFailure {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return .permissionDenied
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoPermission.rawValue {
            return .permissionDenied
        }
        return .unavailable
    }
}

struct MountedStorageVolumeSnapshot: Identifiable, Equatable, Sendable {
    let kind: MountedStorageVolumeKind
    let url: URL
    let name: String
    let capacity: StorageCapacitySnapshot?
    let health: DiskHealthSnapshot
    let remainingLifePercent: Int?
    let temperatureCelsius: Double?

    var id: String { url.standardizedFileURL.path }
}

enum MountedStorageVolumeKind: Equatable, Sendable {
    case external
    case network
}

struct MountedStorageVolumeInventory: Equatable, Sendable {
    let external: [MountedStorageVolumeSnapshot]
    let network: [MountedStorageVolumeSnapshot]

    static let empty = MountedStorageVolumeInventory(external: [], network: [])
}

struct MountedVolumeHealthProbe: Equatable, Sendable {
    let health: DiskHealthSnapshot
    let isDiskImage: Bool
    let remainingLifePercent: Int?
    let temperatureCelsius: Double?
}

enum MountedStorageVolumeService {
    static func snapshots() -> MountedStorageVolumeInventory {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsLocalKey,
            .volumeIsInternalKey,
            .volumeIsBrowsableKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        let healthService = DiskHealthService()

        let snapshots: [MountedStorageVolumeSnapshot] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false,
                  url.standardizedFileURL.path != "/" else {
                return nil
            }

            let fallbackName = url.lastPathComponent.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let resolvedName = values.volumeName?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let name: String
            if let resolvedName, !resolvedName.isEmpty {
                name = resolvedName
            } else if !fallbackName.isEmpty {
                name = fallbackName
            } else if values.volumeIsLocal == false {
                name = L10n.text("网络硬盘", "Network Drive")
            } else {
                name = L10n.text("外接磁盘", "External Disk")
            }

            if values.volumeIsLocal == false {
                // A mounted WebDAV share may not expose capacity. Keep its
                // identity visible without inventing a zero-sized disk.
                let capacity = networkCapacity(
                    total: values.volumeTotalCapacity,
                    available: values.volumeAvailableCapacity
                )
                return MountedStorageVolumeSnapshot(
                    kind: .network,
                    url: url.standardizedFileURL,
                    name: fallbackName.isEmpty ? name : fallbackName,
                    capacity: capacity,
                    health: networkHealthSnapshot(
                        fileSystem: values.volumeLocalizedFormatDescription,
                        capacity: capacity
                    ),
                    remainingLifePercent: nil,
                    temperatureCelsius: nil
                )
            }

            guard let capacity = StorageCapacityService.snapshot(path: url.path),
                  capacity.totalBytes > 0 else { return nil }
            let probe = healthService.mountedVolumeProbe(
                for: url,
                capacitySnapshot: capacity
            )
            let isInternal = probe.health.isInternal ?? values.volumeIsInternal
            guard classification(
                isLocal: values.volumeIsLocal,
                isInternal: isInternal,
                isDiskImage: probe.isDiskImage
            ) == .external else { return nil }

            return MountedStorageVolumeSnapshot(
                kind: .external,
                url: url.standardizedFileURL,
                name: name,
                capacity: capacity,
                health: probe.health,
                remainingLifePercent: probe.remainingLifePercent,
                temperatureCelsius: probe.temperatureCelsius
            )
        }

        return MountedStorageVolumeInventory(
            external: sorted(snapshots.filter { $0.kind == .external }),
            network: sorted(snapshots.filter { $0.kind == .network })
        )
    }

    static func networkCapacity(total: Int?, available: Int?) -> StorageCapacitySnapshot? {
        guard let total, total > 0, let available,
              available >= 0, available <= total else { return nil }
        return StorageCapacitySnapshot(totalBytes: Int64(total), availableBytes: Int64(available))
    }

    static func classification(
        isLocal: Bool?,
        isInternal: Bool?,
        isDiskImage: Bool
    ) -> MountedStorageVolumeKind? {
        if isLocal == false { return .network }
        guard isInternal != true, !isDiskImage else { return nil }
        return .external
    }

    private static func sorted(
        _ snapshots: [MountedStorageVolumeSnapshot]
    ) -> [MountedStorageVolumeSnapshot] {
        snapshots.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func networkHealthSnapshot(
        fileSystem: String?,
        capacity: StorageCapacitySnapshot?
    ) -> DiskHealthSnapshot {
        DiskHealthSnapshot(
            availability: .unavailable,
            status: .unavailable,
            smartStatus: .unsupported,
            isTRIMEnabled: nil,
            fileSystem: fileSystem,
            isInternal: false,
            totalBytes: capacity?.totalBytes,
            availableBytes: capacity?.availableBytes,
            summaryText: L10n.text(
                "网络卷不提供本机 SMART 状态。",
                "Network volumes do not expose local SMART status."
            ),
            checkedAt: Date()
        )
    }
}

struct DiskHealthService {
    static let diskInfoCommand = DiskHealthCommand(
        executable: "/usr/sbin/diskutil",
        arguments: ["info", "-plist", "/"],
        timeout: 3
    )

    static let nvmeProfilerCommand = DiskHealthCommand(
        executable: "/usr/sbin/system_profiler",
        arguments: ["-json", "-detailLevel", "mini", "-timeout", "5", "SPNVMeDataType"],
        timeout: 8
    )

    private let runner: any DiskHealthCommandRunning
    private let capacityProvider: () -> StorageCapacitySnapshot?
    private let now: () -> Date

    init(
        runner: any DiskHealthCommandRunning = ShellDiskHealthCommandRunner(),
        capacityProvider: @escaping () -> StorageCapacitySnapshot? = {
            StorageCapacityService.snapshot()
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.runner = runner
        self.capacityProvider = capacityProvider
        self.now = now
    }

    func snapshot() -> DiskHealthSnapshot {
        let diskResult = capture(Self.diskInfoCommand)
        let profilerResult = capture(Self.nvmeProfilerCommand)
        let capacity = capacityProvider()
        let checkedAt = now()
        let parsed = Self.parseDiskInfo(
            diskResult.data,
            systemProfilerData: profilerResult.data,
            capacitySnapshot: capacity,
            checkedAt: checkedAt
        )
        let failures = [diskResult.failure, profilerResult.failure].compactMap { $0 }

        if parsed.availability.hasUsableData {
            guard failures.isEmpty else {
                return Self.copy(
                    parsed,
                    availability: .partial,
                    summaryText: Self.partialSummary
                )
            }
            return parsed
        }

        guard let failure = Self.preferredFailure(in: failures) else {
            return parsed
        }
        return Self.unavailableSnapshot(
            availability: Self.availability(for: failure),
            checkedAt: checkedAt
        )
    }

    func snapshot(
        for volumeURL: URL,
        capacitySnapshot: StorageCapacitySnapshot?
    ) -> DiskHealthSnapshot {
        mountedVolumeProbe(
            for: volumeURL,
            capacitySnapshot: capacitySnapshot
        ).health
    }

    func mountedVolumeProbe(
        for volumeURL: URL,
        capacitySnapshot: StorageCapacitySnapshot?
    ) -> MountedVolumeHealthProbe {
        let result = capture(Self.diskInfoCommand(for: volumeURL))
        let checkedAt = now()
        let parsed = Self.parseDiskInfo(
            result.data,
            capacitySnapshot: capacitySnapshot,
            checkedAt: checkedAt
        )
        let diskInfo = result.data.flatMap(Self.propertyListDictionary)
        let isDiskImage = Self.isDiskImage(diskInfo)
        let health: DiskHealthSnapshot

        if parsed.availability.hasUsableData {
            if result.failure == nil {
                health = parsed
            } else {
                health = Self.copy(
                    parsed,
                    availability: .partial,
                    summaryText: Self.partialSummary
                )
            }
        } else if let failure = result.failure {
            health = Self.unavailableSnapshot(
                availability: Self.availability(for: failure),
                checkedAt: checkedAt
            )
        } else {
            health = parsed
        }

        return MountedVolumeHealthProbe(
            health: health,
            isDiskImage: isDiskImage,
            remainingLifePercent: health.remainingLifePercent,
            temperatureCelsius: health.temperatureCelsius
        )
    }

    static func diskInfoCommand(for volumeURL: URL) -> DiskHealthCommand {
        DiskHealthCommand(
            executable: "/usr/sbin/diskutil",
            arguments: [
                "info",
                "-plist",
                volumeURL.standardizedFileURL.path,
            ],
            timeout: 3
        )
    }

    static func parseDiskInfo(
        _ diskInfoData: Data?,
        systemProfilerData: Data? = nil,
        capacitySnapshot: StorageCapacitySnapshot? = nil,
        checkedAt: Date = Date()
    ) -> DiskHealthSnapshot {
        let diskInfo = diskInfoData.flatMap(propertyListDictionary)
        let targetDisk = diskInfo.flatMap {
            stringValue(in: $0, keys: ["ParentWholeDisk", "DeviceIdentifier"])
        }
        let profilerMetrics = systemProfilerData.flatMap {
            nvmeMetrics(from: $0, targetDisk: targetDisk)
        }

        let fileSystem = diskInfo.flatMap {
            safeFileSystem(stringValue(
                in: $0,
                keys: ["FilesystemType", "FilesystemName", "FileSystemPersonality", "TypeBundle"]
            ))
        }
        let totalFromDisk = diskInfo.flatMap {
            positiveInt64Value(in: $0, keys: ["TotalSize", "VolumeTotalSize", "APFSContainerSize"])
        }
        let availableDiskKeys: [String]
        if fileSystem == "APFS" {
            // The sealed startup volume can truthfully report FreeSpace = 0 even
            // while its shared APFS container still has free capacity.
            availableDiskKeys = ["APFSContainerFree", "AvailableSpace", "VolumeFreeSpace", "FreeSpace"]
        } else {
            availableDiskKeys = ["AvailableSpace", "VolumeFreeSpace", "FreeSpace", "APFSContainerFree"]
        }
        let availableFromDisk = diskInfo.flatMap {
            nonnegativeInt64Value(
                in: $0,
                keys: availableDiskKeys
            )
        }
        let mountedVolumeCapacity = capacitySnapshot.flatMap {
            validCapacity(totalBytes: $0.totalBytes, availableBytes: $0.availableBytes)
        }
        let diskInfoCapacity = validCapacity(
            totalBytes: totalFromDisk,
            availableBytes: availableFromDisk
        )
        // URL volume resource values model the mounted startup volume and are
        // also used by capacity history, so keep both health surfaces coherent.
        let capacity = mountedVolumeCapacity ?? diskInfoCapacity
        let isInternal = diskInfo.flatMap {
            boolValue(in: $0, keys: ["Internal", "DeviceInternal"])
        }
        let isSolidState = diskInfo.flatMap {
            boolValue(in: $0, keys: ["SolidState", "SolidStateMedia"])
        }
        let isFileVaultEnabled = diskInfo.flatMap {
            boolValue(in: $0, keys: ["FileVault", "FileVaultEnabled", "Encrypted"])
        }
        let diskSMART: DiskSMARTStatus? = diskInfo.flatMap {
            Self.smartStatus(from: value(in: $0, keys: ["SMARTStatus", "SMART Status"]))
        }
        let diskTRIM: Bool? = diskInfo.flatMap {
            Self.trimState(from: value(in: $0, keys: ["TRIM", "TRIMSupport", "TRIM Support"]))
        }
        let smartDetails = diskInfo.flatMap {
            value(
                in: $0,
                keys: ["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"]
            ) as? [String: Any]
        }
        let smartStatus: DiskSMARTStatus = diskSMART
            ?? profilerMetrics?.smartStatus
            ?? DiskSMARTStatus.unavailable
        let isTRIMEnabled = diskTRIM ?? profilerMetrics?.isTRIMEnabled
        let remainingLifePercent = smartDetails.flatMap(Self.remainingLifePercent)
        let temperatureCelsius = smartDetails.flatMap(Self.temperatureCelsius)

        let hasAnyData = fileSystem != nil
            || capacity != nil
            || isInternal != nil
            || isSolidState != nil
            || isFileVaultEnabled != nil
            || smartStatus != DiskSMARTStatus.unavailable
            || isTRIMEnabled != nil
        guard hasAnyData else {
            return unavailableSnapshot(availability: .unavailable, checkedAt: checkedAt)
        }

        let isComplete = fileSystem != nil
            && capacity != nil
            && isInternal != nil
            && isSolidState != nil
            && isFileVaultEnabled != nil
            && smartStatus != DiskSMARTStatus.unavailable
            && isTRIMEnabled != nil
        let availability: HealthAvailability = isComplete ? .available : .partial
        let proposedStatus = status(
            smartStatus: smartStatus,
            isTRIMEnabled: isTRIMEnabled,
            isFileVaultEnabled: isFileVaultEnabled,
            capacity: capacity
        )
        return DiskHealthSnapshot(
            availability: availability,
            status: proposedStatus,
            smartStatus: smartStatus,
            isTRIMEnabled: isTRIMEnabled,
            fileSystem: fileSystem,
            isSolidState: isSolidState,
            isInternal: isInternal,
            isFileVaultEnabled: isFileVaultEnabled,
            totalBytes: capacity?.totalBytes,
            availableBytes: capacity?.availableBytes,
            remainingLifePercent: remainingLifePercent,
            temperatureCelsius: temperatureCelsius,
            summaryText: summary(
                availability: availability,
                status: proposedStatus,
                smartStatus: smartStatus
            ),
            checkedAt: checkedAt
        )
    }

    private typealias CaptureResult = (data: Data?, failure: DiskHealthCommandFailure?)

    private func capture(_ command: DiskHealthCommand) -> CaptureResult {
        do {
            return (try runner.capture(command), nil)
        } catch let failure as DiskHealthCommandFailure {
            return (nil, failure)
        } catch is CancellationError {
            return (nil, .cancelled)
        } catch {
            return (nil, .unavailable)
        }
    }

    private static func availability(for failure: DiskHealthCommandFailure) -> HealthAvailability {
        switch failure {
        case .permissionDenied:
            .permissionDenied
        case .timedOut:
            .timedOut
        case .cancelled:
            .cancelled
        case .unavailable:
            .unavailable
        }
    }

    private static func preferredFailure(
        in failures: [DiskHealthCommandFailure]
    ) -> DiskHealthCommandFailure? {
        for candidate in [
            DiskHealthCommandFailure.permissionDenied,
            .timedOut,
            .cancelled,
            .unavailable
        ] where failures.contains(candidate) {
            return candidate
        }
        return nil
    }

    private static func copy(
        _ snapshot: DiskHealthSnapshot,
        availability: HealthAvailability,
        summaryText: String
    ) -> DiskHealthSnapshot {
        DiskHealthSnapshot(
            availability: availability,
            status: snapshot.status,
            smartStatus: snapshot.smartStatus,
            isTRIMEnabled: snapshot.isTRIMEnabled,
            fileSystem: snapshot.fileSystem,
            isSolidState: snapshot.isSolidState,
            isInternal: snapshot.isInternal,
            isFileVaultEnabled: snapshot.isFileVaultEnabled,
            totalBytes: snapshot.totalBytes,
            availableBytes: snapshot.availableBytes,
            remainingLifePercent: snapshot.remainingLifePercent,
            temperatureCelsius: snapshot.temperatureCelsius,
            summaryText: summaryText,
            checkedAt: snapshot.checkedAt
        )
    }

    private static func unavailableSnapshot(
        availability: HealthAvailability,
        checkedAt: Date
    ) -> DiskHealthSnapshot {
        DiskHealthSnapshot(
            availability: availability,
            status: .unavailable,
            smartStatus: .unavailable,
            isTRIMEnabled: nil,
            fileSystem: nil,
            isSolidState: nil,
            isInternal: nil,
            isFileVaultEnabled: nil,
            totalBytes: nil,
            availableBytes: nil,
            summaryText: unavailableSummary,
            checkedAt: checkedAt
        )
    }

    private static func propertyListDictionary(from data: Data) -> [String: Any]? {
        guard let object = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else {
            return nil
        }
        return object as? [String: Any]
    }

    private static func isDiskImage(_ diskInfo: [String: Any]?) -> Bool {
        guard let diskInfo else { return false }
        let busProtocol = stringValue(
            in: diskInfo,
            keys: ["BusProtocol", "Bus Protocol"]
        )?.lowercased()
        let registryName = stringValue(
            in: diskInfo,
            keys: ["IORegistryEntryName"]
        )?.lowercased()
        return busProtocol == "disk image"
            || registryName == "disk image"
            || boolValue(in: diskInfo, keys: ["SystemImage"]) == true
    }

    private static func remainingLifePercent(
        from smartDetails: [String: Any]
    ) -> Int? {
        guard let percentageUsed = int64Value(
            value(in: smartDetails, keys: ["PERCENTAGE_USED"])
        ), percentageUsed >= 0 else {
            return nil
        }
        return max(0, 100 - min(100, Int(percentageUsed)))
    }

    private static func temperatureCelsius(
        from smartDetails: [String: Any]
    ) -> Double? {
        guard let raw = doubleValue(
            value(in: smartDetails, keys: ["TEMPERATURE"])
        ), raw.isFinite else {
            return nil
        }
        let celsius = raw > 200 ? raw - 273.15 : raw
        guard (-20...130).contains(celsius) else { return nil }
        return celsius
    }

    private struct NVMEMetrics {
        let smartStatus: DiskSMARTStatus
        let isTRIMEnabled: Bool?
    }

    private static func nvmeMetrics(from data: Data, targetDisk: String?) -> NVMEMetrics? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        let candidates = dictionaries(in: object).filter { dictionary in
            value(in: dictionary, keys: ["spnvme_smart_status", "smart_status", "SMARTStatus"]) != nil
                || value(in: dictionary, keys: ["spnvme_trim_support", "trim_support", "TRIMSupport"]) != nil
        }
        let target = targetDisk?.lowercased()
        let exactMatch = candidates.first { dictionary in
            guard let target else { return false }
            let candidateDisk = profilerDiskIdentifier(in: dictionary)?.lowercased()
            return candidateDisk == target
        }
        let selected: [String: Any]?
        if let exactMatch {
            selected = exactMatch
        } else if candidates.count == 1 {
            let candidate = candidates[0]
            selected = target == nil || profilerDiskIdentifier(in: candidate) == nil
                ? candidate
                : nil
        } else {
            selected = nil
        }
        guard let selected else { return nil }

        let smart = smartStatus(from: value(
            in: selected,
            keys: ["spnvme_smart_status", "smart_status", "SMARTStatus"]
        )) ?? .unavailable
        let trim = trimState(from: value(
            in: selected,
            keys: ["spnvme_trim_support", "trim_support", "TRIMSupport"]
        ))
        return NVMEMetrics(smartStatus: smart, isTRIMEnabled: trim)
    }

    private static func profilerDiskIdentifier(in dictionary: [String: Any]) -> String? {
        stringValue(
            in: dictionary,
            keys: ["bsd_name", "BSD Name", "device_identifier"]
        )
    }

    private static func dictionaries(in object: Any) -> [[String: Any]] {
        if let dictionary = object as? [String: Any] {
            return [dictionary] + dictionary.values.flatMap(dictionaries)
        }
        if let array = object as? [Any] {
            return array.flatMap(dictionaries)
        }
        return []
    }

    private static func status(
        smartStatus: DiskSMARTStatus,
        isTRIMEnabled: Bool?,
        isFileVaultEnabled: Bool?,
        capacity: StorageCapacitySnapshot?
    ) -> HealthStatus {
        if smartStatus == .failing {
            return .actionRequired
        }
        if capacity?.pressure == .critical {
            return .actionRequired
        }
        if capacity?.pressure == .attention
            || smartStatus == .unsupported
            || smartStatus == .unavailable
            || isTRIMEnabled == false
            || isFileVaultEnabled == false {
            return .attention
        }
        return .healthy
    }

    private static func summary(
        availability: HealthAvailability,
        status: HealthStatus,
        smartStatus: DiskSMARTStatus
    ) -> String {
        if smartStatus == .failing {
            return L10n.text("SMART 报告需要处理", "SMART reports an issue")
        }
        if status == .actionRequired {
            return L10n.text("可用容量偏低", "Available storage is low")
        }
        if availability == .partial {
            return partialSummary
        }
        if status == .attention {
            return L10n.text("有磁盘项目值得关注", "A disk item needs attention")
        }
        return L10n.text("系统已报告磁盘状态", "Disk status reported by the system")
    }

    private static var partialSummary: String {
        L10n.text("系统仅提供部分磁盘信息", "The system provided partial disk information")
    }

    private static var unavailableSummary: String {
        L10n.text("系统未提供可靠的磁盘状态", "The system did not provide reliable disk status")
    }

    private static func value(in dictionary: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dictionary[key] {
                return value
            }
        }
        for key in keys {
            if let match = dictionary.first(where: {
                $0.key.caseInsensitiveCompare(key) == .orderedSame
            }) {
                return match.value
            }
        }
        return nil
    }

    private static func stringValue(in dictionary: [String: Any], keys: [String]) -> String? {
        guard let value = value(in: dictionary, keys: keys) else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func positiveInt64Value(in dictionary: [String: Any], keys: [String]) -> Int64? {
        guard let value = int64Value(value(in: dictionary, keys: keys)), value > 0 else { return nil }
        return value
    }

    private static func nonnegativeInt64Value(in dictionary: [String: Any], keys: [String]) -> Int64? {
        guard let value = int64Value(value(in: dictionary, keys: keys)), value >= 0 else { return nil }
        return value
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let string = value as? String {
            return Int64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func boolValue(in dictionary: [String: Any], keys: [String]) -> Bool? {
        boolValue(value(in: dictionary, keys: keys))
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.intValue != 0
        }
        guard let string = value as? String else { return nil }
        let normalized = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["yes", "true", "enabled", "on", "1"].contains(normalized) {
            return true
        }
        if ["no", "false", "disabled", "off", "0"].contains(normalized) {
            return false
        }
        return nil
    }

    private static func smartStatus(from value: Any?) -> DiskSMARTStatus? {
        guard let raw = value as? String else { return nil }
        let normalized = normalizedToken(raw)
        if normalized.contains("unsupported") || normalized.contains("notsupported") {
            return .unsupported
        }
        if normalized.contains("failing") || normalized == "failed" || normalized == "fail" {
            return .failing
        }
        if normalized.contains("verified") || normalized == "passed" || normalized == "ok" {
            return .verified
        }
        return .unavailable
    }

    private static func trimState(from value: Any?) -> Bool? {
        if let bool = boolValue(value) {
            return bool
        }
        guard let raw = value as? String else { return nil }
        let normalized = normalizedToken(raw)
        if normalized.contains("notrim")
            || normalized.contains("trimno")
            || normalized.contains("disabled")
            || normalized.contains("notsupported") {
            return false
        }
        if normalized.contains("trimyes")
            || normalized.contains("enabled")
            || normalized == "supported" {
            return true
        }
        return nil
    }

    private static func normalizedToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func safeFileSystem(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch normalizedToken(raw) {
        case "apfs", "applefilesystem":
            return "APFS"
        case "hfs", "hfsplus", "journaledhfsplus", "macosextended":
            return "HFS+"
        case "exfat":
            return "exFAT"
        case "fat", "fat32", "msdosfat32":
            return "FAT32"
        case "ntfs":
            return "NTFS"
        case "ufs":
            return "UFS"
        default:
            return nil
        }
    }

    private static func validCapacity(
        totalBytes: Int64?,
        availableBytes: Int64?
    ) -> StorageCapacitySnapshot? {
        guard let totalBytes,
              let availableBytes,
              totalBytes > 0,
              availableBytes >= 0,
              availableBytes <= totalBytes else {
            return nil
        }
        return StorageCapacitySnapshot(totalBytes: totalBytes, availableBytes: availableBytes)
    }
}
