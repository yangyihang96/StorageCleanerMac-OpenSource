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
    /// N18: the Operation History receipt for moving the original.
    var report: CleanReport? = nil
    /// The original's identity when it was moved, so a later look at its
    /// place can tell whether Operation History put the same file back.
    var originalIdentity: FileIdentity? = nil
    var contentVerification: MigrationContentVerification? = nil
    var publicationWarning: String? = nil
    /// Capability/fidelity notes do not invalidate a content proof.
    var information: [String] = []

    func noticeMessage(fallback message: String) -> String {
        ([publicationWarning ?? message] + information).joined(separator: "\n")
    }

    /// The move has a durable, identity-verified receipt, so Operation
    /// History can put the original back.
    var canRestoreFromHistory: Bool {
        guard let report, report.persistenceFailure == nil else { return false }
        return !report.restorableReceipts.isEmpty
    }
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
    case applicationRemovalRequiresContentVerification
    case receiptUnavailable

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
        case .applicationRemovalRequiresContentVerification:
            L10n.text("应用迁移目前仅保留副本，不自动移走原件；签名身份一致不代表副本内容完全相同。", "App migration is currently copy-only. The original is kept because matching signing identities do not prove identical contents.")
        case .receiptUnavailable:
            L10n.text("无法写入操作记录；为了能从“操作记录”恢复，原件没有移动。", "The operation record could not be written. So that the move stays restorable from Operation History, the original was not moved.")
        }
    }
}

enum ExternalDriveMigrationService {
    /// N18: receipt rule for moving a verified file's original to the Trash.
    static let originalRuleID = "migration.original.v1"

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
        trustedVolumes: [ExternalStorageVolume]? = nil,
        contentReader: GuardedFileContentReader = GuardedFileContentReader(priority: .userInitiated),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        durability: MigrationDurability = MigrationDurability(),
        creationTime: MigrationCreationTime = MigrationCreationTime(),
        // Inject only the leaf syscall; publication and failure handling remain
        // the same when a destination refuses or cannot express file flags.
        publicationFlagOperation: @Sendable (UnsafePointer<CChar>, UInt32) -> Int32 = { Darwin.lchflags($0, $1) }
    ) throws -> ExternalMigrationResult {
        try Task.checkCancellation()
        try contentReader.checkAvailability(item.sourceURL, isDirectory: item.kind == .application)
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
        let inspected = try inspectSource(item, contentReader: contentReader, homeDirectory: homeDirectory)
        let sourceIdentity = inspected.identity
        let sourceValues = inspected.values
        if item.kind == .application, isApplicationRunning(item.bundleIdentifier) {
            throw ExternalDriveMigrationError.applicationRunning
        }

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

        // Own the staging directory before the first copy can create partial data.
        // This also preserves the .app extension during bundle verification.
        let staging = try MigrationStagingDirectory(
            parentURL: destinationRoot,
            fileManager: fileManager
        )
        let stagingReceipt: MigrationStagingReceipt?
        do {
            // Injected volumes belong to isolated fixture tests; production
            // always registers staging before the first copy can write bytes.
            stagingReceipt = trustedVolumes == nil ? try MigrationStagingReceipt(url: staging.url) : nil
        } catch {
            try? staging.remove()
            throw error
        }
        let cleanup: @Sendable () -> Void = {
            if let stagingReceipt { stagingReceipt.cleanup(staging) }
            else { try? staging.remove() }
        }
        var workerOwnsCleanup = false
        var publicationCommitted = false
        defer {
            if !workerOwnsCleanup {
                if publicationCommitted { cleanup() }
                else { DispatchQueue.global(qos: .userInitiated).async(execute: cleanup) }
            }
        }
        let temporary = staging.url.appendingPathComponent(source.lastPathComponent)

        let sourceSignature = try applicationSignatureIfNeeded(item, at: source, contentReader: contentReader)
        // D61: while copyfile is in flight, its worker owns staging cleanup.
        // A cancelled/timed-out caller must not remove an active worker's tree.
        workerOwnsCleanup = true
        let copier = GuardedFileCopy(reader: contentReader, durability: durability, creationTime: creationTime)
        let capability = try copier.probeDurability(at: staging.url, onFailure: cleanup)
        workerOwnsCleanup = false
        try Task.checkCancellation()
        workerOwnsCleanup = true
        var copied = try copier.copy(source, to: temporary,
            deferRootFlags: true, onFailure: cleanup)
        copied.durabilityCapability = capability
        workerOwnsCleanup = false
        try Task.checkCancellation()
        let verification = try verifyCopy(
            item,
            source: source,
            copy: temporary,
            originalIdentity: sourceIdentity,
            originalFileSize: sourceValues.fileSize,
            originalModificationDate: sourceValues.contentModificationDate,
            sourceSignature: sourceSignature,
            contentReader: contentReader
        )
        try Task.checkCancellation()
        try contentReader.checkAvailability(source, isDirectory: item.kind == .application)
        guard try sourceIsUnchanged(source, identity: sourceIdentity,
                                fileSize: sourceValues.fileSize,
                                modificationDate: sourceValues.contentModificationDate, contentReader: contentReader) else {
            throw ExternalDriveMigrationError.sourceChanged
        }
        try Task.checkCancellation()
        var beforeMetadataRestoration: GuardedFileContentReader.Snapshot?
        if verification != nil { beforeMetadataRestoration = try contentReader.open(temporary).snapshot }
        else { beforeMetadataRestoration = nil }
        workerOwnsCleanup = true
        copied = try copier.restoreTimes(copied, at: temporary, onFailure: cleanup)
        workerOwnsCleanup = false
        let afterMetadataRestoration: GuardedFileContentReader.Snapshot?
        if verification != nil { afterMetadataRestoration = try contentReader.open(temporary).snapshot }
        else { afterMetadataRestoration = nil }
        workerOwnsCleanup = true
        var information = capability.information
        information += try copier.makeDurable(copied, at: temporary, onFailure: cleanup)
        workerOwnsCleanup = false
        if verification != nil {
            let beforePublication = try contentReader.open(temporary).snapshot
            if beforePublication != afterMetadataRestoration {
                // F_FULLFSYNC may take seconds. It cannot explain a changed
                // ctime: do not widen the metadata-rebinding exception across
                // that wait. This mismatched predecessor forces rehashing.
                beforeMetadataRestoration = beforePublication
            }
        }
        try Task.checkCancellation()
        try fileManager.moveItem(at: temporary, to: destination)
        publicationCommitted = true
        // Rename is committed. Do not turn a late cancellation or a metadata
        // restoration error into a claim that the copy was never published.
        information += copied.metadataWarnings
        var warnings: [String] = []
        // Restore permissions before immutable/append flags block chmod.
        do { try copied.restorePublishedPermissions(at: destination) }
        catch {
            warnings.append(L10n.text("副本已生成，但未能恢复原权限。原件保留，请检查副本。",
                                      "The copy was created, but its permissions could not be restored. The original was kept. Check the copy."))
        }
        do { try copied.restorePublishedFlags(at: destination, setFlags: publicationFlagOperation) }
        catch {
            warnings.append(L10n.text(
                "副本已生成，但未能恢复隐藏或锁定标志。原件保留，请检查副本。",
                "The copy was created, but its hidden or locked flags could not be restored. The original was kept. Check the copy."))
        }
        do {
            information += try copier.makeDurable(copied, at: destination, volumeRoot: volume.url,
                                   committed: true, contents: false)
        } catch {
            warnings.append(L10n.text("副本已生成，原件保留，但尚未确认副本已安全写入磁盘。请检查外接磁盘，再从列表处理原件；不要重新复制到同一位置。",
                                      "The copy exists and the original was kept, but durable storage is not confirmed. Check the external drive, then handle the original from the list. Do not copy again to the same location."))
        }
        let publicationWarning = warnings.isEmpty ? nil : Array(Set(warnings)).sorted().joined(separator: "\n")

        // Publication is the commit point. After it succeeds, return the
        // verified copy even if cancellation arrives concurrently; never label
        // an already completed filesystem write as an unfinished copy.
        return ExternalMigrationResult(
            destinationURL: destination,
            trashURL: nil,
            didMoveSourceToTrash: false,
            contentVerification: publicationWarning == nil ? verification?.afterPublication(at: destination,
                reader: contentReader, beforeMetadataRestoration: beforeMetadataRestoration) : nil,
            publicationWarning: publicationWarning,
            information: Array(Set(information)).sorted()
        )
    }

    static func moveOriginalToTrash(
        _ item: ExternalMigrationItem,
        verifiedCopyAt destinationURL: URL,
        on requestedVolume: ExternalStorageVolume,
        fileManager: FileManager = .default,
        trustedVolumes: [ExternalStorageVolume]? = nil,
        trashOperation: ((URL) throws -> URL?)? = nil,
        persist: RecordedTrashOperation.Persistence? = nil,
        journal: CleanupReportJournal? = nil,
        contentVerification: MigrationContentVerification? = nil,
        contentReader: GuardedFileContentReader = GuardedFileContentReader(priority: .userInitiated),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        durability: MigrationDurability = MigrationDurability(),
        metadata: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem()
    ) throws -> ExternalMigrationResult {
        try Task.checkCancellation()
        // Matching publisher signatures do not establish identical bundle
        // contents. Keep application migration copy-only until a bound,
        // content-verified migration receipt is implemented.
        guard item.kind != .application else {
            throw ExternalDriveMigrationError.applicationRemovalRequiresContentVerification
        }
        try contentReader.checkAvailability(item.sourceURL)
        try contentReader.checkAvailability(destinationURL)
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
        guard !PathSafety.containsSymbolicLinkComponent(in: destination.path, fileManager: fileManager) else {
            throw ExternalDriveMigrationError.unsafeSource
        }
        let inspected = try inspectSource(item, contentReader: contentReader, homeDirectory: homeDirectory)
        let sourceIdentity = inspected.identity
        let sourceValues = inspected.values
        let recordedIdentity = try contentReader.pool.read(at: source, timeout: contentReader.timeout, priority: contentReader.priority) { _ in
            try metadata.snapshot(at: source).identity
        }
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

        var verification = try MigrationContentVerification.verify(source, destination,
            reader: contentReader, reusing: contentVerification)
        let durableCopier = GuardedFileCopy(reader: contentReader, durability: durability)
        let durableFile = GuardedFileCopy.PreparedCopy(entries: [], deferredFlags: 0)
        var information = try durableCopier.makeDurable(durableFile, at: destination, volumeRoot: volume.url, bytes: item.sizeBytes)
        guard try contentReader.open(destination).snapshot == verification.destinationSnapshot else {
            throw FileContentReadError.changed
        }
        var durableSnapshot = verification.destinationSnapshot
        try Task.checkCancellation()
        guard try sourceIsUnchanged(
            source,
            identity: sourceIdentity,
            fileSize: sourceValues.fileSize,
            modificationDate: sourceValues.contentModificationDate,
            contentReader: contentReader
        ) else {
            throw ExternalDriveMigrationError.sourceChanged
        }

        // N18: the move goes through the shared receipt journal, the same
        // operation history as cleanup and uninstall, so Operation History
        // can put the original back (the verified copy stays on the drive).
        // The intent is durable before the move; without it nothing moves.
        // Production names no journal and writes the live one. Injected
        // volumes are fixture-only, and such a call must name its journal or
        // persistence: a test never writes the live journal by leaving it
        // out, and no original moves without a receipt (review P2-2).
        if trustedVolumes != nil, persist == nil, journal == nil {
            throw ExternalDriveMigrationError.receiptUnavailable
        }
        let receiptJournal = journal ?? .live
        let persistence: RecordedTrashOperation.Persistence = persist ?? { report, identities in
            try receiptJournal.checkpoint(report, expectedIdentities: identities)
        }
        var refusal: Error?
        let report = RecordedTrashOperation.run(
            items: [.init(
                path: source.path,
                bytes: item.sizeBytes,
                identity: recordedIdentity,
                allowedRestoreRoot: source.deletingLastPathComponent()
            )],
            ruleID: originalRuleID,
            validate: { _ in
                do {
                    try Task.checkCancellation()
                    try contentReader.checkAvailability(source)
                    try contentReader.checkAvailability(destination)
                    // Check both complete snapshots before and after the
                    // durable intent. Rehash only when that bound proof changed.
                    verification = try MigrationContentVerification.verify(source, destination,
                        reader: contentReader, reusing: verification)
                    if verification.destinationSnapshot != durableSnapshot {
                        information += try durableCopier.makeDurable(durableFile, at: destination, volumeRoot: volume.url, bytes: item.sizeBytes)
                        guard try contentReader.open(destination).snapshot == verification.destinationSnapshot else {
                            throw FileContentReadError.changed
                        }
                        durableSnapshot = verification.destinationSnapshot
                    }
                    guard fileManager.fileExists(atPath: destination.path) else {
                        throw ExternalDriveMigrationError.copyVerificationFailed
                    }
                    guard (try? metadata.snapshot(at: source).identity) == recordedIdentity else {
                        throw ExternalDriveMigrationError.sourceChanged
                    }
                    guard try sourceIsUnchanged(
                        source,
                        identity: sourceIdentity,
                        fileSize: sourceValues.fileSize,
                        modificationDate: sourceValues.contentModificationDate,
                        contentReader: contentReader
                    ) else {
                        throw ExternalDriveMigrationError.sourceChanged
                    }
                } catch {
                    refusal = error
                    throw error
                }
            },
            move: { url in
                // RecordedTrashOperation has crossed invokedMove; cancellation
                // must no longer invent an unknown move outcome (review P2-6).
                let target: URL?
                if let trashOperation {
                    target = try trashOperation(url)
                } else {
                    var resultingURL: NSURL?
                    try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
                    target = resultingURL as URL?
                }
                guard let target else { throw CleanupMoveError.invalidResult }
                return target
            },
            metadata: metadata,
            persist: persistence
        )

        switch report.items.first?.outcome {
        case .moved(let receipt)?:
            return ExternalMigrationResult(
                destinationURL: destination,
                trashURL: receipt.resultingItemURL,
                didMoveSourceToTrash: true,
                report: report,
                originalIdentity: recordedIdentity,
                information: Array(Set(information)).sorted()
            )
        case .notProcessed?:
            if report.outcome == .cancelled { throw CancellationError() }
            throw ExternalDriveMigrationError.receiptUnavailable
        case .failed(let failure)?:
            if let refusal { throw refusal }
            if failure.code == .moveOutcomeUnknown, !fileManager.fileExists(atPath: source.path) {
                // Gone from its place but not confirmed in the Trash: the
                // receipt says "needs verification" and the next Operation
                // History refresh looks for it in the Trash by identity.
                return ExternalMigrationResult(
                    destinationURL: destination,
                    trashURL: nil,
                    didMoveSourceToTrash: true,
                    report: report,
                    originalIdentity: recordedIdentity,
                    information: Array(Set(information)).sorted()
                )
            }
            throw ExternalDriveMigrationError.originalRemovalFailed
        case .skipped?, .deleted?, nil:
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

    private static func isAllowedSource(_ item: ExternalMigrationItem, homeDirectory: URL) -> Bool {
        switch item.kind {
        case .file:
            PathSafety.isLexicallyInsideHome(item.sourceURL.path, homeDirectory: homeDirectory)
                && PathSafety.isInsideHome(item.sourceURL.path, homeDirectory: homeDirectory)
        case .application:
            PathSafety.isInsideApplications(item.sourceURL.path)
                || PathSafety.isInsideHome(item.sourceURL.path, homeDirectory: homeDirectory)
        }
    }

    static func isApplicationRunning(_ bundleIdentifier: String) -> Bool {
        !bundleIdentifier.isEmpty
            && !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    private static func applicationSignatureIfNeeded(
        _ item: ExternalMigrationItem,
        at url: URL,
        contentReader: GuardedFileContentReader
    ) throws -> CodeSignatureVerificationResult? {
        guard item.kind == .application else { return nil }
        let timeout = applicationSignatureTimeout(sizeBytes: item.sizeBytes, readTimeout: contentReader.timeout)
        return try contentReader.pool.read(at: url, timeout: timeout, priority: contentReader.priority) { control in
            try contentReader.guardPolicy.checkTree(url, control: control)
            try control.check()
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
    }

    // Security.framework exposes no progress callback. Budget for a cold slow
    // disk at 2 MiB/s plus setup, with a finite 30 minute ceiling; pool waits
    // remain cancellable every 10 ms and isolated from other volumes.
    static func applicationSignatureTimeout(sizeBytes: Int64, readTimeout: TimeInterval) -> TimeInterval {
        min(1800, max(readTimeout, max(60, 30 + Double(max(0, sizeBytes)) / (2 * 1_048_576))))
    }

    private static func verifyCopy(
        _ item: ExternalMigrationItem,
        source: URL,
        copy: URL,
        originalIdentity: TrashItemIdentity,
        originalFileSize: Int?,
        originalModificationDate: Date?,
        sourceSignature: CodeSignatureVerificationResult?,
        contentReader: GuardedFileContentReader
    ) throws -> MigrationContentVerification? {
        guard try sourceIsUnchanged(
            source,
            identity: originalIdentity,
            fileSize: originalFileSize,
            modificationDate: originalModificationDate,
            contentReader: contentReader
        ) else {
            throw ExternalDriveMigrationError.copyVerificationFailed
        }

        switch item.kind {
        case .file:
            let sourceSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let copiedSize = try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard sourceSize == originalFileSize,
                  copiedSize == originalFileSize else {
                throw ExternalDriveMigrationError.copyVerificationFailed
            }
            return try MigrationContentVerification.verify(source, copy, reader: contentReader)
        case .application:
            guard let sourceSignature else {
                throw ExternalDriveMigrationError.copyVerificationFailed
            }
            guard let copiedSignature = try applicationSignatureIfNeeded(item, at: copy, contentReader: contentReader),
                  copiedSignature.isValid,
                  copiedSignature.codeSigningIdentifier == sourceSignature.codeSigningIdentifier,
                  copiedSignature.teamIdentifier == sourceSignature.teamIdentifier,
                  copiedSignature.designatedRequirement == sourceSignature.designatedRequirement else {
                throw ExternalDriveMigrationError.copyVerificationFailed
            }
            return nil
        }
    }

    static func filesHaveSameSHA256(
        _ first: URL, _ second: URL,
        contentReader: GuardedFileContentReader = GuardedFileContentReader(priority: .userInitiated)
    ) throws -> Bool {
        // Check both first, so a cloud-only retained copy does not needlessly
        // cause the source's contents to be read.
        try contentReader.checkAvailability(first)
        try contentReader.checkAvailability(second)
        return try contentReader.sha256(first) == contentReader.sha256(second)
    }

    private static func isURL(_ candidate: URL, inside root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private struct SourceValues: Sendable {
        let isRegularFile: Bool?
        let isDirectory: Bool?
        let fileSize: Int?
        let contentModificationDate: Date?
        init(_ values: URLResourceValues) {
            isRegularFile = values.isRegularFile
            isDirectory = values.isDirectory
            fileSize = values.fileSize
            contentModificationDate = values.contentModificationDate
        }
    }

    private static func inspectSource(
        _ item: ExternalMigrationItem, contentReader: GuardedFileContentReader, homeDirectory: URL
    ) throws -> (identity: TrashItemIdentity, values: SourceValues) {
        try contentReader.pool.read(at: item.sourceURL, timeout: contentReader.timeout, priority: contentReader.priority) { control in
            // Keep the caller's FileManager on its own thread; only Sendable
            // item/reader values cross into this read worker.
            let fileManager = FileManager.default
            let source = item.sourceURL.standardizedFileURL
            try contentReader.guardPolicy.check(source, isDirectory: item.kind == .application)
            guard fileManager.fileExists(atPath: source.path) else { throw ExternalDriveMigrationError.sourceMissing }
            guard isAllowedSource(item, homeDirectory: homeDirectory),
                  !PathSafety.containsSymbolicLinkComponent(in: source.path, fileManager: fileManager),
                  let identity = TrashItemIdentity.capture(at: source) else {
                throw ExternalDriveMigrationError.unsafeSource
            }
            try control.check()
            let values = try source.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey
            ])
            return (identity, SourceValues(values))
        }
    }

    private static func sourceIsUnchanged(
        _ source: URL,
        identity: TrashItemIdentity?,
        fileSize: Int?,
        modificationDate: Date?,
        contentReader: GuardedFileContentReader
    ) throws -> Bool {
        try contentReader.pool.read(at: source, timeout: contentReader.timeout, priority: contentReader.priority) { _ in
            guard let identity,
                  TrashItemIdentity.capture(at: source) == identity,
                  let current = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return false }
            return current.fileSize == fileSize && current.contentModificationDate == modificationDate
        }
    }
}
