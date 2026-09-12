import AppKit
import CryptoKit
import DiskArbitration
import Foundation

struct ExternalStorageVolume: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let availableBytes: Int64
    let totalBytes: Int64
    let fileSystem: String
    let supportsApplications: Bool

    var id: String { url.standardizedFileURL.path }
}

struct ExternalMigrationItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case file
        case application
    }

    static let minimumApplicationSize: Int64 = 1_000_000_000

    let id: String
    let title: String
    let sourceURL: URL
    let sizeBytes: Int64
    let kind: Kind
    let bundleIdentifier: String

    static func largeFile(_ item: StorageItem) -> Self? {
        guard item.status == .available,
              !item.isDirectory,
              PathSafety.isLexicallyInsideHome(item.path),
              PathSafety.isInsideHome(item.path) else { return nil }
        return Self(
            id: "file:\(item.id)",
            title: item.title,
            sourceURL: URL(fileURLWithPath: item.path),
            sizeBytes: item.sizeBytes,
            kind: .file,
            bundleIdentifier: ""
        )
    }

    static func application(_ app: InstalledAppItem) -> Self? {
        guard app.status == .installed,
              app.canMoveToTrash,
              !app.isAppleApp,
              app.sizeBytes >= minimumApplicationSize,
              !app.bundleIdentifier.isEmpty,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              !ExternalDriveMigrationService.isApplicationRunning(app.bundleIdentifier) else { return nil }
        return Self(
            id: "app:\(app.id)",
            title: app.name,
            sourceURL: URL(fileURLWithPath: app.path),
            sizeBytes: app.sizeBytes,
            kind: .application,
            bundleIdentifier: app.bundleIdentifier
        )
    }
}

struct ExternalMigrationResult: Sendable {
    let destinationURL: URL
    let trashURL: URL?
    let didMoveSourceToTrash: Bool
}

enum ExternalDriveMigrationError: LocalizedError, Equatable {
    case volumeUnavailable
    case unsupportedApplicationVolume
    case insufficientSpace
    case unsafeSource
    case sourceMissing
    case sourceChanged
    case applicationRunning
    case destinationExists
    case copyVerificationFailed
    case originalRemovalFailed

    var errorDescription: String? {
        switch self {
        case .volumeUnavailable:
            L10n.text("所选外接硬盘已断开、只读或不再可用。", "The selected external drive is disconnected, read-only, or unavailable.")
        case .unsupportedApplicationVolume:
            L10n.text("这个硬盘格式不适合运行 macOS App；请使用 APFS 或 Mac OS 扩展格式。", "This drive format cannot safely run macOS apps. Use APFS or Mac OS Extended.")
        case .insufficientSpace:
            L10n.text("外接硬盘的可用空间不足。", "The external drive does not have enough available space.")
        case .unsafeSource:
            L10n.text("来源路径不在允许的迁移范围内，或路径包含符号链接。", "The source is outside the allowed migration locations or contains a symbolic link.")
        case .sourceMissing:
            L10n.text("来源文件已不存在，请重新扫描。", "The source no longer exists. Rescan and try again.")
        case .sourceChanged:
            L10n.text("来源文件在扫描后已发生变化，请重新扫描后再搬移。", "The source changed after scanning. Rescan before moving it.")
        case .applicationRunning:
            L10n.text("应用仍在运行，请先完全退出后再迁移。", "The app is still running. Quit it completely before migrating.")
        case .destinationExists:
            L10n.text("目标文件夹中已有同名项目；为避免覆盖，迁移已停止。", "An item with the same name already exists at the destination. Migration stopped without overwriting it.")
        case .copyVerificationFailed:
            L10n.text("复制后的项目未通过完整性检查，原件保持不变。", "The copied item did not pass verification. The original was left unchanged.")
        case .originalRemovalFailed:
            L10n.text("无法把原件移到废纸篓；已验证的副本和原件均保持不变。", "The original could not be moved to Trash. The verified copy and original were both left unchanged.")
        }
    }
}

enum ExternalDriveMigrationService {
    static func availableVolumes() -> [ExternalStorageVolume] {
        DirectoryApplicationScanner()
            .externalVolumeDirectories(maximumDepth: 1)
            .compactMap { volume(at: $0.url) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func migrate(
        _ item: ExternalMigrationItem,
        to requestedVolume: ExternalStorageVolume,
        fileManager: FileManager = .default,
        trustedVolumes: [ExternalStorageVolume]? = nil
    ) throws -> ExternalMigrationResult {
        try Task.checkCancellation()
        let volumes = trustedVolumes ?? availableVolumes()
        guard let volume = volumes.first(where: { $0.id == requestedVolume.id }),
              fileManager.fileExists(atPath: volume.url.path) else {
            throw ExternalDriveMigrationError.volumeUnavailable
        }
        if item.kind == .application, !volume.supportsApplications {
            throw ExternalDriveMigrationError.unsupportedApplicationVolume
        }
        guard volume.availableBytes >= item.sizeBytes else {
            throw ExternalDriveMigrationError.insufficientSpace
        }

        let source = item.sourceURL.standardizedFileURL
        guard fileManager.fileExists(atPath: source.path) else {
            throw ExternalDriveMigrationError.sourceMissing
        }
        guard isAllowedSource(item),
              !PathSafety.containsSymbolicLinkComponent(in: source.path, fileManager: fileManager) else {
            throw ExternalDriveMigrationError.unsafeSource
        }
        guard let sourceIdentity = TrashItemIdentity.capture(at: source) else {
            throw ExternalDriveMigrationError.unsafeSource
        }
        if item.kind == .application, isApplicationRunning(item.bundleIdentifier) {
            throw ExternalDriveMigrationError.applicationRunning
        }

        let sourceValues = try source.resourceValues(forKeys: [
            .isRegularFileKey,
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        switch item.kind {
        case .file:
            guard sourceValues.isRegularFile == true else {
                throw ExternalDriveMigrationError.unsafeSource
            }
            guard let sourceSize = sourceValues.fileSize,
                  Int64(sourceSize) == item.sizeBytes else {
                throw ExternalDriveMigrationError.sourceChanged
            }
        case .application:
            guard sourceValues.isDirectory == true,
                  source.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                throw ExternalDriveMigrationError.unsafeSource
            }
        }

        let migrationRoot = volume.url
            .appendingPathComponent("StorageCleaner Migration", isDirectory: true)
        guard item.sizeBytes > 0,
              isURL(migrationRoot, inside: volume.url),
              !PathSafety.containsSymbolicLinkComponent(in: volume.url.path, fileManager: fileManager),
              (!fileManager.fileExists(atPath: migrationRoot.path)
                || !PathSafety.containsSymbolicLinkComponent(in: migrationRoot.path, fileManager: fileManager)) else {
            throw ExternalDriveMigrationError.volumeUnavailable
        }
        try fileManager.createDirectory(at: migrationRoot, withIntermediateDirectories: true)

        let folderName = item.kind == .application ? "Applications" : "Large Files"
        let destinationRoot = migrationRoot.appendingPathComponent(folderName, isDirectory: true)
        guard !PathSafety.containsSymbolicLinkComponent(in: migrationRoot.path, fileManager: fileManager),
              (!fileManager.fileExists(atPath: destinationRoot.path)
                || !PathSafety.containsSymbolicLinkComponent(in: destinationRoot.path, fileManager: fileManager)) else {
            throw ExternalDriveMigrationError.volumeUnavailable
        }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        guard isURL(destinationRoot, inside: volume.url),
              !PathSafety.containsSymbolicLinkComponent(in: destinationRoot.path, fileManager: fileManager) else {
            throw ExternalDriveMigrationError.volumeUnavailable
        }

        let destination = destinationRoot.appendingPathComponent(source.lastPathComponent)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ExternalDriveMigrationError.destinationExists
        }

        let temporary = destinationRoot.appendingPathComponent(".storagecleaner-\(UUID().uuidString).partial")
        var temporaryExists = false
        defer {
            if temporaryExists {
                try? fileManager.removeItem(at: temporary)
            }
        }

        let sourceSignature = try applicationSignatureIfNeeded(item, at: source)
        try fileManager.copyItem(at: source, to: temporary)
        temporaryExists = true
        try Task.checkCancellation()
        try verifyCopy(
            item,
            source: source,
            copy: temporary,
            originalIdentity: sourceIdentity,
            originalFileSize: sourceValues.fileSize,
            originalModificationDate: sourceValues.contentModificationDate,
            sourceSignature: sourceSignature
        )
        try Task.checkCancellation()
        try fileManager.moveItem(at: temporary, to: destination)
        temporaryExists = false

        guard sourceIsUnchanged(
            source,
            identity: sourceIdentity,
            fileSize: sourceValues.fileSize,
            modificationDate: sourceValues.contentModificationDate
        ) else {
            throw ExternalDriveMigrationError.sourceChanged
        }

        return ExternalMigrationResult(
            destinationURL: destination,
            trashURL: nil,
            didMoveSourceToTrash: false
        )
    }

    static func moveOriginalToTrash(
        _ item: ExternalMigrationItem,
        verifiedCopyAt destinationURL: URL,
        on requestedVolume: ExternalStorageVolume,
        fileManager: FileManager = .default,
        trustedVolumes: [ExternalStorageVolume]? = nil,
        trashOperation: ((URL) throws -> URL?)? = nil
    ) throws -> ExternalMigrationResult {
        try Task.checkCancellation()
        let volumes = trustedVolumes ?? availableVolumes()
        guard let volume = volumes.first(where: { $0.id == requestedVolume.id }),
              fileManager.fileExists(atPath: volume.url.path) else {
            throw ExternalDriveMigrationError.volumeUnavailable
        }
        if item.kind == .application, !volume.supportsApplications {
            throw ExternalDriveMigrationError.unsupportedApplicationVolume
        }

        let source = item.sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        let folderName = item.kind == .application ? "Applications" : "Large Files"
        let expectedDestination = volume.url
            .appendingPathComponent("StorageCleaner Migration", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)
            .standardizedFileURL
        guard destination == expectedDestination,
              isURL(destination, inside: volume.url),
              fileManager.fileExists(atPath: destination.path) else {
            throw ExternalDriveMigrationError.copyVerificationFailed
        }
        guard fileManager.fileExists(atPath: source.path) else {
            throw ExternalDriveMigrationError.sourceMissing
        }
        guard isAllowedSource(item),
              !PathSafety.containsSymbolicLinkComponent(in: source.path, fileManager: fileManager),
              !PathSafety.containsSymbolicLinkComponent(in: destination.path, fileManager: fileManager) else {
            throw ExternalDriveMigrationError.unsafeSource
        }
        if item.kind == .application, isApplicationRunning(item.bundleIdentifier) {
            throw ExternalDriveMigrationError.applicationRunning
        }

        guard let sourceIdentity = TrashItemIdentity.capture(at: source) else {
            throw ExternalDriveMigrationError.unsafeSource
        }
        let sourceValues = try source.resourceValues(forKeys: [
            .isRegularFileKey,
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        switch item.kind {
        case .file:
            guard sourceValues.isRegularFile == true,
                  let sourceSize = sourceValues.fileSize,
                  Int64(sourceSize) == item.sizeBytes else {
                throw ExternalDriveMigrationError.sourceChanged
            }
        case .application:
            guard sourceValues.isDirectory == true,
                  source.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                throw ExternalDriveMigrationError.unsafeSource
            }
        }

        let sourceSignature = try applicationSignatureIfNeeded(item, at: source)
        try verifyCopy(
            item,
            source: source,
            copy: destination,
            originalIdentity: sourceIdentity,
            originalFileSize: sourceValues.fileSize,
            originalModificationDate: sourceValues.contentModificationDate,
            sourceSignature: sourceSignature
        )
        try Task.checkCancellation()
        guard sourceIsUnchanged(
            source,
            identity: sourceIdentity,
            fileSize: sourceValues.fileSize,
            modificationDate: sourceValues.contentModificationDate
        ) else {
            throw ExternalDriveMigrationError.sourceChanged
        }

        do {
            let trashURL: URL?
            if let trashOperation {
                trashURL = try trashOperation(source)
            } else {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: source, resultingItemURL: &resultingURL)
                trashURL = resultingURL as URL?
            }
            guard !fileManager.fileExists(atPath: source.path) else {
                throw ExternalDriveMigrationError.originalRemovalFailed
            }
            return ExternalMigrationResult(
                destinationURL: destination,
                trashURL: trashURL,
                didMoveSourceToTrash: true
            )
        } catch let error as ExternalDriveMigrationError {
            throw error
        } catch {
            throw ExternalDriveMigrationError.originalRemovalFailed
        }
    }

    @MainActor
    static func reveal(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func volume(at url: URL) -> ExternalStorageVolume? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.volumeIsLocal != false,
              values.volumeIsReadOnly != true,
              let capacity = StorageCapacityService.snapshot(path: url.path),
              let hardware = diskDescription(for: url),
              hardware.isInternal != true,
              hardware.isWritable != false,
              !hardware.isVirtual else { return nil }

        let kind = hardware.fileSystem.lowercased()
        return ExternalStorageVolume(
            url: url.standardizedFileURL,
            name: values.volumeName ?? url.lastPathComponent,
            availableBytes: capacity.availableBytes,
            totalBytes: capacity.totalBytes,
            fileSystem: hardware.fileSystem.uppercased(),
            supportsApplications: ["apfs", "hfs", "hfs+", "hfsx"].contains(kind)
        )
    }

    private static func diskDescription(for url: URL) -> (
        isInternal: Bool?,
        isWritable: Bool?,
        isVirtual: Bool,
        fileSystem: String
    )? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return nil }

        let protocolName = (description[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? "").lowercased()
        let model = (description[kDADiskDescriptionDeviceModelKey as String] as? String ?? "").lowercased()
        return (
            description[kDADiskDescriptionDeviceInternalKey as String] as? Bool,
            description[kDADiskDescriptionMediaWritableKey as String] as? Bool,
            protocolName.contains("disk image") || model.contains("disk image") || protocolName.contains("virtual"),
            description[kDADiskDescriptionVolumeKindKey as String] as? String ?? "unknown"
        )
    }

    private static func isAllowedSource(_ item: ExternalMigrationItem) -> Bool {
        switch item.kind {
        case .file:
            PathSafety.isLexicallyInsideHome(item.sourceURL.path)
                && PathSafety.isInsideHome(item.sourceURL.path)
        case .application:
            PathSafety.isInsideApplications(item.sourceURL.path)
                || PathSafety.isInsideHome(item.sourceURL.path)
        }
    }

    static func isApplicationRunning(_ bundleIdentifier: String) -> Bool {
        !bundleIdentifier.isEmpty
            && !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    private static func applicationSignatureIfNeeded(
        _ item: ExternalMigrationItem,
        at url: URL
    ) throws -> CodeSignatureVerificationResult? {
        guard item.kind == .application else { return nil }
        let bundle = Bundle(url: url)
        guard bundle?.bundleIdentifier == item.bundleIdentifier else {
            throw ExternalDriveMigrationError.copyVerificationFailed
        }
        let signature = try CodeSignatureVerifier().verifyCode(at: url)
        guard signature.isValid else {
            throw ExternalDriveMigrationError.copyVerificationFailed
        }
        return signature
    }

    private static func verifyCopy(
        _ item: ExternalMigrationItem,
        source: URL,
        copy: URL,
        originalIdentity: TrashItemIdentity,
        originalFileSize: Int?,
        originalModificationDate: Date?,
        sourceSignature: CodeSignatureVerificationResult?
    ) throws {
        guard sourceIsUnchanged(
            source,
            identity: originalIdentity,
            fileSize: originalFileSize,
            modificationDate: originalModificationDate
        ) else {
            throw ExternalDriveMigrationError.copyVerificationFailed
        }

        switch item.kind {
        case .file:
            let sourceSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let copiedSize = try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard sourceSize == originalFileSize,
                  copiedSize == originalFileSize,
                  try filesHaveSameSHA256(source, copy) else {
                throw ExternalDriveMigrationError.copyVerificationFailed
            }
        case .application:
            guard Bundle(url: copy)?.bundleIdentifier == item.bundleIdentifier,
                  let sourceSignature else {
                throw ExternalDriveMigrationError.copyVerificationFailed
            }
            let copiedSignature = try CodeSignatureVerifier().verifyCode(at: copy)
            guard copiedSignature.isValid,
                  copiedSignature.codeSigningIdentifier == sourceSignature.codeSigningIdentifier,
                  copiedSignature.teamIdentifier == sourceSignature.teamIdentifier,
                  copiedSignature.designatedRequirement == sourceSignature.designatedRequirement else {
                throw ExternalDriveMigrationError.copyVerificationFailed
            }
        }
    }

    static func filesHaveSameSHA256(_ first: URL, _ second: URL) throws -> Bool {
        try sha256(of: first) == sha256(of: second)
    }

    private static func sha256(of url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize()
    }

    private static func isURL(_ candidate: URL, inside root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private static func sourceIsUnchanged(
        _ source: URL,
        identity: TrashItemIdentity?,
        fileSize: Int?,
        modificationDate: Date?
    ) -> Bool {
        guard let identity,
              TrashItemIdentity.capture(at: source) == identity,
              let current = try? source.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
              ]) else { return false }
        return current.fileSize == fileSize
            && current.contentModificationDate == modificationDate
    }
}
