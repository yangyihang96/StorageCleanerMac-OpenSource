import AppKit
import CryptoKit
import Darwin
import Foundation

struct CleanupExecutionContext: Sendable {
    let featureConfiguration: CleanupFeatureConfiguration
    let activeSessionID: ScanSessionID
    let activeRules: CleanupRuleSet
    let userHomeURL: URL
    let excludedURLs: [URL]
    let approvedPlanItemIDs: Set<UUID>?
    // Presentation evidence only: these reasons never approve an item to move.
    var preflightSkipReasons: [UUID: CleanSkipReason] = [:]
}

protocol CleanupMoving: Sendable {
    func moveToTrash(_ url: URL) async throws -> URL
    func moveToQuarantine(_ url: URL, planID: CleanPlanID, itemID: UUID) async throws -> URL
}

protocol CleanupVolumeChecking: Sendable {
    func isAvailable(volumeIdentifier: String) async -> Bool
}

protocol CleanupRunningApplicationChecking: Sendable {
    func isRunning(bundleIdentifier: String) async -> Bool
    func isRunning(applicationURL: URL) async -> Bool
}

extension CleanupRunningApplicationChecking {
    func isRunning(applicationURL _: URL) async -> Bool { false }
}

protocol CleanupCapacityReading: Sendable {
    func availableCapacity(at url: URL) async -> Int64?
}

/// D23: one frozen Trash entry to delete permanently, with the identities
/// recorded at scan time.
struct CleanupTrashEntryDeletion: Sendable {
    let trashURL: URL
    /// The Trash folder as the scan saw it.
    let trashIdentity: FileIdentity
    /// The entry's own name directly inside the Trash.
    let entryName: String
    let entryIdentity: FileIdentity
}

/// Thrown before anything is deleted.
enum CleanupTrashDeletionRefusal: Error, Equatable {
    /// The Trash folder is a link, or not the folder the scan saw.
    case trashChanged
    /// The entry is not the one frozen at scan time.
    case entryChanged
    /// The entry is on another volume than the Trash.
    case otherVolume
}

/// Thrown after part of an entry may already be gone.
enum CleanupTrashDeletionFailure: Error, Equatable {
    case system(Int32)
    /// A folder inside the entry is another volume (a mount point).
    case crossesVolume
    case tooDeep
    case changedDuringDeletion
}

/// D23: permanently removes one frozen Trash entry. A symbolic link is removed
/// itself; links inside a removed folder are unlinked, never followed.
protocol CleanupPermanentDeleting: Sendable {
    func removeTrashEntry(_ deletion: CleanupTrashEntryDeletion) async throws
}

/// P2-3: opens the Trash without following links, checks it is the folder the
/// scan saw, then deletes the entry relative to that open folder: every level
/// is opened without following links and must stay on the Trash's volume.
struct FoundationCleanupPermanentDeleter: CleanupPermanentDeleting {
    private static let maximumDepth = 128

    func removeTrashEntry(_ deletion: CleanupTrashEntryDeletion) async throws {
        try Self.remove(deletion)
    }

    static func remove(_ deletion: CleanupTrashEntryDeletion) throws {
        let name = Array(deletion.entryName.utf8CString)
        guard name.count > 1, deletion.entryName != ".", deletion.entryName != "..",
              !deletion.entryName.contains("/") else {
            throw CleanupTrashDeletionRefusal.entryChanged
        }
        let trash = deletion.trashURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard trash >= 0 else { throw CleanupTrashDeletionRefusal.trashChanged }
        defer { close(trash) }
        var trashStatus = stat()
        guard fstat(trash, &trashStatus) == 0,
              identity(of: trashStatus) == deletion.trashIdentity else {
            throw CleanupTrashDeletionRefusal.trashChanged
        }
        var entryStatus = stat()
        guard name.withUnsafeBufferPointer({
            fstatat(trash, $0.baseAddress!, &entryStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0 else {
            throw CleanupTrashDeletionRefusal.entryChanged
        }
        guard identity(of: entryStatus) == deletion.entryIdentity else {
            throw CleanupTrashDeletionRefusal.entryChanged
        }
        guard entryStatus.st_dev == trashStatus.st_dev else {
            throw CleanupTrashDeletionRefusal.otherVolume
        }
        if entryStatus.st_mode & S_IFMT == S_IFDIR {
            try removeDirectory(
                named: name,
                in: trash,
                expected: entryStatus,
                device: trashStatus.st_dev,
                depth: 0
            )
        } else {
            try unlink(name, in: trash, flags: 0)
        }
    }

    private static func removeDirectory(
        named name: [CChar],
        in parent: Int32,
        expected: stat,
        device: dev_t,
        depth: Int
    ) throws {
        guard depth < maximumDepth else { throw CleanupTrashDeletionFailure.tooDeep }
        let directory = name.withUnsafeBufferPointer {
            openat(parent, $0.baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directory >= 0 else { throw CleanupTrashDeletionFailure.system(errno) }
        defer { close(directory) }
        var status = stat()
        guard fstat(directory, &status) == 0,
              status.st_dev == expected.st_dev,
              status.st_ino == expected.st_ino else {
            throw CleanupTrashDeletionFailure.changedDuringDeletion
        }
        guard status.st_dev == device else { throw CleanupTrashDeletionFailure.crossesVolume }
        for child in try childNames(of: directory) {
            var childStatus = stat()
            let found = child.withUnsafeBufferPointer {
                fstatat(directory, $0.baseAddress!, &childStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard found == 0 else {
                if errno == ENOENT { continue }
                throw CleanupTrashDeletionFailure.system(errno)
            }
            if childStatus.st_mode & S_IFMT == S_IFDIR {
                guard childStatus.st_dev == device else {
                    throw CleanupTrashDeletionFailure.crossesVolume
                }
                try removeDirectory(
                    named: child,
                    in: directory,
                    expected: childStatus,
                    device: device,
                    depth: depth + 1
                )
            } else {
                // Files and links are unlinked; a link's target is never read.
                try unlink(child, in: directory, flags: 0)
            }
        }
        try unlink(name, in: parent, flags: AT_REMOVEDIR)
    }

    private static func unlink(_ name: [CChar], in directory: Int32, flags: Int32) throws {
        let result = name.withUnsafeBufferPointer {
            unlinkat(directory, $0.baseAddress!, flags)
        }
        guard result == 0 || errno == ENOENT else {
            throw CleanupTrashDeletionFailure.system(errno)
        }
    }

    /// Names as raw bytes, so any name the file system holds is passed back
    /// unchanged.
    private static func childNames(of directory: Int32) throws -> [[CChar]] {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw CleanupTrashDeletionFailure.system(errno) }
        guard let stream = fdopendir(duplicate) else {
            let code = errno
            close(duplicate)
            throw CleanupTrashDeletionFailure.system(code)
        }
        defer { closedir(stream) }
        var names = [[CChar]]()
        errno = 0
        while let entry = readdir(stream) {
            var raw = entry.pointee.d_name
            let length = Int(entry.pointee.d_namlen)
            let name: [CChar] = withUnsafeBytes(of: &raw) { bytes in
                bytes.prefix(length).map { CChar(bitPattern: $0) } + [0]
            }
            let isDot = length == 1 && name[0] == 0x2E
            let isDotDot = length == 2 && name[0] == 0x2E && name[1] == 0x2E
            if !isDot && !isDotDot { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw CleanupTrashDeletionFailure.system(errno) }
        return names
    }

    private static func identity(of status: stat) -> FileIdentity {
        let kind: FileEntryKind
        switch status.st_mode & S_IFMT {
        case S_IFREG: kind = .regularFile
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symbolicLink
        default: kind = .other
        }
        let birth = status.st_birthtimespec
        return FileIdentity(
            deviceID: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            entryKind: kind,
            creationTimeNanoseconds: birth.tv_sec > 0
                ? Int64(birth.tv_sec) * 1_000_000_000 + Int64(birth.tv_nsec)
                : nil
        )
    }
}

protocol CleanupContentDigestReading: Sendable {
    func sha256(at url: URL) throws -> Data
}

struct FoundationCleanupContentDigestReader: CleanupContentDigestReading {
    var reader = GuardedFileContentReader(priority: .userInitiated)

    func sha256(at url: URL) throws -> Data {
        try reader.sha256(url)
    }
}

enum CleanupMoveError: Error {
    case invalidResult
    case unsafeQuarantineRoot
    case destinationExists
    case crossVolume
}

private struct DeveloperActivityProbeError: Error {
    let reason: CleanSkipReason
}

struct FoundationCleanupMover: CleanupMoving {
    let quarantineRootURL: URL
    let userHomeURL: URL

    init(
        quarantineRootURL: URL = CleanupQuarantineLocation.defaultURL,
        userHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.quarantineRootURL = quarantineRootURL
        self.userHomeURL = userHomeURL
    }

    func moveToTrash(_ url: URL) async throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let resultingURL = resultingURL as URL?, resultingURL.isFileURL else {
            throw CleanupMoveError.invalidResult
        }
        return resultingURL.standardizedFileURL
    }

    func moveToQuarantine(
        _ url: URL,
        planID: CleanPlanID,
        itemID: UUID
    ) async throws -> URL {
        let homePath = PathSafety.lexicalPath(userHomeURL.path)
        let rootPath = PathSafety.lexicalPath(quarantineRootURL.path)
        guard rootPath != homePath,
              PathSafety.isContained(rootPath, in: homePath, resolvingSymlinks: false) else {
            throw CleanupMoveError.unsafeQuarantineRoot
        }

        try FileManager.default.createDirectory(
            at: quarantineRootURL,
            withIntermediateDirectories: true
        )
        guard !PathSafety.containsSymbolicLinkComponent(in: rootPath),
              PathSafety.isContained(rootPath, in: homePath, resolvingSymlinks: true) else {
            throw CleanupMoveError.unsafeQuarantineRoot
        }

        let planDirectory = quarantineRootURL
            .appendingPathComponent(planID.rawValue.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: planDirectory,
            withIntermediateDirectories: true
        )
        guard !PathSafety.containsSymbolicLinkComponent(in: planDirectory.path),
              PathSafety.isContained(
                planDirectory.path,
                in: rootPath,
                resolvingSymlinks: true
              ) else {
            throw CleanupMoveError.unsafeQuarantineRoot
        }

        let destinationName = itemID.uuidString
        let destinationURL = planDirectory.appendingPathComponent(destinationName)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw CleanupMoveError.destinationExists
        }

        let directoryDescriptor = open(
            planDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw CleanupMoveError.unsafeQuarantineRoot
        }
        defer { close(directoryDescriptor) }

        let result = url.withUnsafeFileSystemRepresentation { sourcePath in
            destinationName.withCString { destinationPath in
                renameat(AT_FDCWD, sourcePath, directoryDescriptor, destinationPath)
            }
        }
        guard result == 0 else {
            if errno == EXDEV {
                throw CleanupMoveError.crossVolume
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return destinationURL
    }
}

enum CleanupQuarantineLocation {
    static var defaultURL: URL {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("CleanupQuarantine", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }
}

struct FoundationCleanupVolumeChecker: CleanupVolumeChecking {
    func isAvailable(volumeIdentifier: String) async -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: []
        ) ?? []
        return volumes.contains {
            let identifier = try? $0.resourceValues(forKeys: keys).volumeIdentifier
            return identifier.map { String(describing: $0) } == volumeIdentifier
        }
    }
}

struct FoundationCleanupRunningApplicationChecker: CleanupRunningApplicationChecking {
    func isRunning(bundleIdentifier: String) async -> Bool {
        await MainActor.run {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).isEmpty
        }
    }

    func isRunning(applicationURL: URL) async -> Bool {
        let targetPath = applicationURL.standardizedFileURL.path
        return await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { application in
                application.bundleURL?.standardizedFileURL.path == targetPath
            }
        }
    }
}

struct FoundationCleanupCapacityReader: CleanupCapacityReading {
    func availableCapacity(at url: URL) async -> Int64? {
        try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
    }
}

actor SafeCleanupExecutor {
    private let metadataReader: any ReadOnlyFileSystem
    private let contentDigestReader: any CleanupContentDigestReading
    private let mover: any CleanupMoving
    private let volumeChecker: any CleanupVolumeChecking
    private let runningApplicationChecker: any CleanupRunningApplicationChecking
    private let capacityReader: any CleanupCapacityReading
    private let deleter: any CleanupPermanentDeleting
    private let coordinator: HeavyWorkCoordinator
    private let persistReport: @Sendable (CleanReport, [String: FileIdentity]) throws -> Void
    private var consumedPlanIDs = Set<CleanPlanID>()
    // ScanStore already uses this same executor for preflight and execution.
    // Retain reasons by immutable plan ID, without caching write-probe results
    // for approved items or changing the confirmation/authorization route.
    private var preflightReports: [CleanPlanID: CleanPreflightReport] = [:]

    init(
        metadataReader: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem(),
        contentDigestReader: any CleanupContentDigestReading = FoundationCleanupContentDigestReader(),
        mover: any CleanupMoving = FoundationCleanupMover(),
        volumeChecker: any CleanupVolumeChecking = FoundationCleanupVolumeChecker(),
        runningApplicationChecker: any CleanupRunningApplicationChecking =
            FoundationCleanupRunningApplicationChecker(),
        capacityReader: any CleanupCapacityReading = FoundationCleanupCapacityReader(),
        deleter: any CleanupPermanentDeleting = FoundationCleanupPermanentDeleter(),
        coordinator: HeavyWorkCoordinator,
        persistReport: @escaping @Sendable (CleanReport, [String: FileIdentity]) throws -> Void = { _, _ in }
    ) {
        self.metadataReader = metadataReader
        self.contentDigestReader = contentDigestReader
        self.mover = mover
        self.volumeChecker = volumeChecker
        self.runningApplicationChecker = runningApplicationChecker
        self.capacityReader = capacityReader
        self.deleter = deleter
        self.coordinator = coordinator
        self.persistReport = persistReport
    }

    func preflight(
        plan: CleanPlan,
        context: CleanupExecutionContext
    ) async -> CleanPreflightReport {
        preflightReports.removeValue(forKey: plan.id)
        if context.featureConfiguration.mode != .v2Full {
            return CleanPreflightReport(
                planID: plan.id,
                checkedAt: Date(),
                items: [],
                failure: CleanFailure(code: .featureDisabled, detailCode: nil)
            )
        }
        guard !consumedPlanIDs.contains(plan.id),
              plan.sessionID == context.activeSessionID,
              plan.rulesVersion == context.activeRules.rulesVersion,
              plan.rulesProvenance == context.activeRules.effectiveProvenance else {
            return CleanPreflightReport(
                planID: plan.id,
                checkedAt: Date(),
                items: [],
                failure: CleanFailure(code: .planIntegrityFailed, detailCode: nil)
            )
        }

        var results = [CleanPreflightItem]()
        for item in plan.items {
            let reason = await skipReason(for: item, context: context)
            // 取消的遍历没有完整结论，不能把已读取的部分批准为可执行。
            if Task.isCancelled {
                return CleanPreflightReport(planID: plan.id, checkedAt: Date(), items: [],
                    failure: CleanFailure(code: .unexpected, detailCode: "cancelled"))
            }
            results.append(CleanPreflightItem(
                planItemID: item.id,
                status: reason.map(CleanPreflightItemStatus.skipped) ?? .ready
            ))
        }
        let report = CleanPreflightReport(
            planID: plan.id,
            checkedAt: Date(),
            items: results,
            failure: nil
        )
        preflightReports[plan.id] = report
        return report
    }

    func execute(
        plan: CleanPlan,
        context: CleanupExecutionContext,
        progress: @escaping @Sendable (CleanupExecutionProgress) async -> Void
    ) async -> CleanReport {
        let startedAt = Date()
        guard context.featureConfiguration.mode == .v2Full else {
            return terminalFailureReport(
                plan: plan,
                startedAt: startedAt,
                code: .featureDisabled
            )
        }
        guard plan.sessionID == context.activeSessionID,
              plan.rulesVersion == context.activeRules.rulesVersion,
              plan.rulesProvenance == context.activeRules.effectiveProvenance,
              !consumedPlanIDs.contains(plan.id) else {
            return terminalFailureReport(
                plan: plan,
                startedAt: startedAt,
                code: .planIntegrityFailed
            )
        }
        let planItemIDs = Set(plan.items.map(\.id))
        guard let approvedPlanItemIDs = context.approvedPlanItemIDs,
              !approvedPlanItemIDs.isEmpty,
              approvedPlanItemIDs.isSubset(of: planItemIDs) else {
            return terminalFailureReport(
                plan: plan,
                startedAt: startedAt,
                code: .planIntegrityFailed
            )
        }

        var context = context
        if let preflight = preflightReports.removeValue(forKey: plan.id),
           preflight.failure == nil {
            for entry in preflight.items {
                if case let .skipped(reason) = entry.status {
                    context.preflightSkipReasons[entry.planItemID] = reason
                }
            }
        }
        consumedPlanIDs.insert(plan.id)
        let lease: HeavyWorkCoordinator.Lease
        do {
            lease = try await coordinator.acquire(owner: .cleanup)
        } catch {
            return terminalFailureReport(
                plan: plan,
                startedAt: startedAt,
                code: .coordinatorBusy
            )
        }
        let capacityBefore = await capacityReader.availableCapacity(at: context.userHomeURL)
        var reportItems = [CleanReportItem]()
        var cancelled = false
        var persistenceFailed = false

        let identities = Dictionary(plan.items.map {
            ($0.sourceURL.path, $0.expectedSnapshot.identity)
        }, uniquingKeysWith: { first, _ in first })
        // Register the immutable intent before any destructive operation.
        do {
            try persistReport(makeReport(plan: plan, startedAt: startedAt,
                items: plan.items.map { reportItem(for: $0, outcome: .notProcessed) },
                cancelled: false, availableSpaceDeltaBytes: nil), identities)
        } catch {
            await coordinator.release(lease)
            return terminalFailureReport(plan: plan, startedAt: startedAt, code: .persistenceFailed)
        }

        await progress(progressSnapshot(plan: plan, items: reportItems, currentRuleID: nil))
        for (index, item) in plan.items.enumerated() {
            if Task.isCancelled {
                cancelled = true
                reportItems.append(contentsOf: plan.items[index...].map {
                    reportItem(for: $0, outcome: .notProcessed)
                })
                do {
                    try persistReport(makeReport(plan: plan, startedAt: startedAt,
                        items: reportItems, cancelled: true,
                        availableSpaceDeltaBytes: nil), identities)
                } catch {
                    persistenceFailed = true
                }
                break
            }

            do {
                try await coordinator.requireValid(lease, owner: .cleanup)
            } catch {
                reportItems.append(reportItem(
                    for: item,
                    outcome: .failed(CleanFailure(
                        code: .planIntegrityFailed,
                        detailCode: "invalid-lease"
                    ))
                ))
                reportItems.append(contentsOf: plan.items.dropFirst(index + 1).map {
                    reportItem(for: $0, outcome: .notProcessed)
                })
                break
            }

            if let reason = await skipReason(for: item, context: context, rechecksWrites: false) {
                if Task.isCancelled {
                    cancelled = true
                    reportItems.append(contentsOf: plan.items[index...].map { reportItem(for: $0, outcome: .notProcessed) })
                    break
                }
                reportItems.append(reportItem(for: item, outcome: .skipped(reason)))
                await progress(progressSnapshot(
                    plan: plan,
                    items: reportItems,
                    currentRuleID: item.ruleID
                ))
                continue
            }

            // 保留身份、路径、卷和运行状态核对；写入遍历留到持久化意图之后，
            // 避免对同一目录重复走三遍。系统移动仍是基于路径的 API。
            if let reason = await skipReason(for: item, context: context, rechecksWrites: false) {
                if Task.isCancelled {
                    cancelled = true
                    reportItems.append(contentsOf: plan.items[index...].map { reportItem(for: $0, outcome: .notProcessed) })
                    break
                }
                reportItems.append(reportItem(for: item, outcome: .skipped(reason)))
                await progress(progressSnapshot(
                    plan: plan,
                    items: reportItems,
                    currentRuleID: item.ruleID
                ))
                continue
            }

            // Preflight may await app checks or expensive content verification.
            // Honour cancellation received during those checks before any move.
            if Task.isCancelled {
                cancelled = true
                reportItems.append(contentsOf: plan.items[index...].map {
                    reportItem(for: $0, outcome: .notProcessed)
                })
                break
            }

            // If a crash occurs during the system call, retain its identity and
            // explicitly mark the outcome unknown; never replay this intent.
            do {
                let interrupted = item.action.permanentlyDeletes
                    ? CleanFailure(code: .deletionOutcomeUnknown, detailCode: "interrupted-deletion-needs-verification")
                    : CleanFailure(code: .moveOutcomeUnknown, detailCode: "interrupted-move-needs-verification")
                let pending = reportItems + [reportItem(for: item, outcome: .failed(interrupted))]
                    + plan.items.dropFirst(index + 1).map { reportItem(for: $0, outcome: .notProcessed) }
                try persistReport(makeReport(plan: plan, startedAt: startedAt, items: pending,
                    cancelled: false, availableSpaceDeltaBytes: nil), identities)
            } catch {
                reportItems.append(reportItem(for: item, outcome: .failed(
                    CleanFailure(code: .persistenceFailed, detailCode: "intent-write-failed")
                )))
                reportItems.append(contentsOf: plan.items.dropFirst(index + 1).map {
                    reportItem(for: $0, outcome: .notProcessed)
                })
                break
            }
            // Durable intent creation can block on storage. Re-run the complete
            // authorization and identity preflight after it, not only before it.
            let finalReason = await skipReason(for: item, context: context)
            if Task.isCancelled {
                cancelled = true
                reportItems.append(contentsOf: plan.items[index...].map {
                    reportItem(for: $0, outcome: .notProcessed)
                })
                // No move was invoked. Replace the durable unknown intent now,
                // before the capacity read or the final receipt can fail.
                do {
                    try persistReport(makeReport(plan: plan, startedAt: startedAt,
                        items: reportItems, cancelled: true,
                        availableSpaceDeltaBytes: nil), identities)
                } catch {
                    persistenceFailed = true
                }
                break
            }
            if let reason = finalReason {
                reportItems.append(reportItem(for: item, outcome: .skipped(reason)))
                do {
                    let remaining = plan.items.dropFirst(index + 1).map {
                        reportItem(for: $0, outcome: .notProcessed)
                    }
                    try persistReport(makeReport(plan: plan, startedAt: startedAt,
                        items: reportItems + remaining, cancelled: false,
                        availableSpaceDeltaBytes: nil), identities)
                } catch {
                    persistenceFailed = true
                    reportItems.append(contentsOf: plan.items.dropFirst(index + 1).map {
                        reportItem(for: $0, outcome: .notProcessed)
                    })
                    break
                }
                await progress(progressSnapshot(plan: plan, items: reportItems, currentRuleID: item.ruleID))
                continue
            }
            var invokedMove = false
            let unknownOutcomeCode: CleanFailureCode = item.action.permanentlyDeletes
                ? .deletionOutcomeUnknown
                : .moveOutcomeUnknown
            do {
                try await coordinator.requireValid(lease, owner: .cleanup)
                try Task.checkCancellation()
                if item.action.permanentlyDeletes {
                    reportItems.append(reportItem(
                        for: item,
                        outcome: try await deleteFrozenTrashEntry(item, invoked: &invokedMove)
                    ))
                } else {
                    let resultingURL: URL
                    invokedMove = true
                    switch plan.disposition {
                    case .trash:
                        resultingURL = try await mover.moveToTrash(item.sourceURL)
                    case .quarantine:
                        resultingURL = try await mover.moveToQuarantine(
                            item.sourceURL,
                            planID: plan.id,
                            itemID: item.id
                        )
                    }

                    let movedSnapshot = try? metadataReader.snapshot(at: resultingURL)
                    let verification: CleanupMoveVerification
                    if let movedSnapshot {
                        verification = movedSnapshot.identity == item.expectedSnapshot.identity
                            ? .identityVerified
                            : .identityMismatch
                    } else {
                        verification = .destinationMetadataUnavailable
                    }
                    let receipt = CleanupMoveReceipt(
                        originalPath: item.expectedSnapshot.standardizedPath,
                        resultingItemURL: resultingURL.standardizedFileURL,
                        disposition: plan.disposition,
                        movedIdentity: movedSnapshot?.identity,
                        verification: verification,
                        movedAt: Date()
                    )
                    reportItems.append(reportItem(for: item, outcome: .moved(receipt)))
                }
            } catch is CancellationError {
                cancelled = true
                reportItems.append(reportItem(for: item, outcome: invokedMove
                    ? .failed(CleanFailure(code: unknownOutcomeCode, detailCode: "cancelled-during-move"))
                    : .notProcessed))
            } catch {
                reportItems.append(reportItem(
                    for: item,
                    outcome: .failed(invokedMove
                        ? CleanFailure(code: unknownOutcomeCode, detailCode: "move-threw-needs-verification")
                        : cleanFailure(for: error, disposition: plan.disposition))
                ))
            }
            do {
                let checkpointItems = reportItems + plan.items.dropFirst(index + 1).map {
                    reportItem(for: $0, outcome: .notProcessed)
                }
                try persistReport(makeReport(plan: plan, startedAt: startedAt, items: checkpointItems,
                    cancelled: cancelled, availableSpaceDeltaBytes: nil), identities)
            } catch {
                persistenceFailed = true
                // Preserve all real movement receipts in memory and stop. The
                // durable in-flight intent remains available after a restart.
                reportItems.append(contentsOf: plan.items.dropFirst(index + 1).map {
                    reportItem(for: $0, outcome: .notProcessed)
                })
                break
            }
            await progress(progressSnapshot(
                plan: plan,
                items: reportItems,
                currentRuleID: item.ruleID
            ))
        }

        let capacityAfter = await capacityReader.availableCapacity(at: context.userHomeURL)
        var report = makeReport(
            plan: plan,
            startedAt: startedAt,
            items: reportItems,
            cancelled: cancelled,
            availableSpaceDeltaBytes: capacityDelta(before: capacityBefore, after: capacityAfter)
        )
        // A failed final write cannot erase already persisted per-item receipts.
        let changedAnything = report.summary.movedItemCount
            + (report.summary.deletedItemCount ?? 0) > 0
        if persistenceFailed {
            report.persistenceFailure = "result-write-failed"
            report.outcome = changedAnything ? .partiallyCompleted : .failed
        }
        do { try persistReport(report, identities) }
        catch {
            report.persistenceFailure = "final-write-failed"
            report.outcome = changedAnything ? .partiallyCompleted : .failed
        }
        await coordinator.release(lease)
        return report
    }

    /// D23/P2-3: deletes one frozen entry relative to the Trash folder the
    /// scan saw. A refusal before anything is deleted is a skip; any other
    /// error after the call leaves the outcome unknown.
    private func deleteFrozenTrashEntry(
        _ item: CleanPlanItem,
        invoked: inout Bool
    ) async throws -> CleanItemOutcome {
        guard let trashIdentity = item.allowedRootIdentity else {
            return .skipped(.rulesChanged)
        }
        invoked = true
        do {
            try await deleter.removeTrashEntry(CleanupTrashEntryDeletion(
                trashURL: item.allowedRootURL,
                trashIdentity: trashIdentity,
                entryName: item.sourceURL.lastPathComponent,
                entryIdentity: item.expectedSnapshot.identity
            ))
        } catch let refusal as CleanupTrashDeletionRefusal {
            switch refusal {
            case .trashChanged: return .skipped(.pathOutsideAllowedRoot)
            case .entryChanged: return .skipped(.identityChanged)
            case .otherVolume: return .skipped(.volumeChanged)
            }
        }
        if let remaining = try? metadataReader.snapshot(at: item.sourceURL),
           remaining.identity == item.expectedSnapshot.identity {
            return .failed(CleanFailure(
                code: .deletionOutcomeUnknown,
                detailCode: "item-still-present"
            ))
        }
        return .deleted(CleanupDeletionReceipt(
            originalPath: item.expectedSnapshot.standardizedPath,
            deletedIdentity: item.expectedSnapshot.identity,
            deletedAt: Date()
        ))
    }

    private func skipReason(
        for item: CleanPlanItem,
        context: CleanupExecutionContext,
        rechecksWrites: Bool = true
    ) async -> CleanSkipReason? {
        if let approvedPlanItemIDs = context.approvedPlanItemIDs,
           !approvedPlanItemIDs.contains(item.id) {
            return context.preflightSkipReasons[item.id] ?? .preflightNotApproved
        }
        // D19: lower-bound items run; only the item's own root is moved.
        guard !item.measurementCompleteness.isFailed else {
            return .measurementIncomplete
        }
        if item.action.permanentlyDeletes {
            return await permanentDeletionSkipReason(for: item, context: context)
        }
        if let evidence = item.verifiedDuplicateEvidence {
            return verifiedDuplicateSkipReason(
                for: item,
                evidence: evidence,
                context: context
            )
        }
        guard item.action.movesToTrash,
              let rule = context.activeRules.rules.first(where: { $0.id == item.ruleID }),
              rule.measurementRequirement == .complete,
              rule.allowsManualSelection,
              rule.selectionPolicyVersion == item.ruleSelectionPolicyVersion,
              item.ruleRevision == rule.maintenance?.revision,
              rule.requiredClosedBundleIDs == item.requiredClosedBundleIDs,
              !item.reasonCodes.isEmpty,
              item.reasonCodes.contains(item.reasonCode) else {
            return .rulesChanged
        }
        let developerDecision: DeveloperCleanupAgeDecision?
        if let thresholdDays = item.developerInactivityThresholdDays,
           let referenceDate = item.developerScanReferenceDate {
            developerDecision = DeveloperCleanupAgePolicy.decision(
                for: rule,
                latestModificationTimeNanoseconds:
                    item.latestContentModificationTimeNanoseconds,
                measurementCompleteness: item.measurementCompleteness,
                referenceDate: referenceDate,
                thresholdDays: thresholdDays
            )
        } else {
            developerDecision = nil
        }
        let matchesStaticRule = developerDecision == nil
            && rule.risk == item.riskLevel
            && rule.action == item.action
            && rule.executionEligibility == item.executionEligibility
            && rule.reasonKey == item.reasonCode
        let matchesDeveloperPolicy: Bool
        if let developerDecision,
           let thresholdDays = item.developerInactivityThresholdDays {
            let requiredEvidence = DeveloperCleanupAgePolicy.evidenceCodes(
                for: developerDecision,
                latestModificationTimeNanoseconds:
                    item.latestContentModificationTimeNanoseconds,
                thresholdDays: thresholdDays
            )
            matchesDeveloperPolicy = item.riskLevel == developerDecision.risk
                && item.action == developerDecision.action
                && item.executionEligibility == developerDecision.executionEligibility
                && item.reasonCode == developerDecision.reasonCode
                && requiredEvidence.allSatisfy(item.reasonCodes.contains)
        } else {
            matchesDeveloperPolicy = false
        }
        guard matchesStaticRule || matchesDeveloperPolicy else {
            return .rulesChanged
        }
        let isSafeItem = item.riskLevel == .safe
            && item.action == .moveToTrash
            && item.executionEligibility == .eligible
            && (developerDecision?.risk == .safe || matchesStaticRule)
        let isReviewedItem = item.riskLevel == .reviewOnly
            && item.action == .moveToTrashAfterReview
            && item.executionEligibility == .eligibleAfterReview
            && (developerDecision?.risk == .reviewOnly || matchesStaticRule)
            && item.explicitUserSelection
        let isProtectedApplication = item.riskLevel == .protected
            && item.action == .moveToTrashAfterProtectedReview
            && item.executionEligibility == .eligibleAfterProtectedReview
            && rule.risk == .protected
            && isApprovedProtectedApplication(item, rule: rule)
            && item.explicitUserSelection
        let isProtectedDeveloperItem = item.riskLevel == .protected
            && item.action == .moveToTrashAfterProtectedReview
            && item.executionEligibility == .eligibleAfterProtectedReview
            && developerDecision?.risk == .protected
            && item.explicitUserSelection
        guard isSafeItem || isReviewedItem
            || isProtectedApplication || isProtectedDeveloperItem else {
            return .rulesChanged
        }

        let sourcePath = PathSafety.lexicalPath(item.sourceURL.path)
        let rootPath = PathSafety.lexicalPath(item.allowedRootURL.path)
        let homePath = PathSafety.lexicalPath(context.userHomeURL.path)
        let isApprovedApplicationsRoot = isProtectedApplication
            && rule.root.kind == .applicationsDirectory
            && rule.effectiveCandidateScope == .immediateChildren
            && rootPath == "/Applications"
            && PathSafety.lexicalPath(
                item.sourceURL.deletingLastPathComponent().path
            ) == rootPath
            && item.sourceURL.pathExtension.lowercased() == "app"
            && isApprovedProtectedApplication(item, rule: rule)
        guard item.sourceURL.isFileURL,
              item.allowedRootURL.isFileURL,
              sourcePath != rootPath,
              PathSafety.isContained(sourcePath, in: rootPath, resolvingSymlinks: false),
              isApprovedApplicationsRoot
                || PathSafety.isContained(rootPath, in: homePath, resolvingSymlinks: false) else {
            return .pathOutsideAllowedRoot
        }

        let excludedPaths = context.excludedURLs.map {
            PathSafety.lexicalPath($0.path)
        }
        if ScanExclusionService.intersectsExcludedTree(
            sourcePath,
            excludedPaths: excludedPaths
        ) {
            return .excludedByUser
        }

        let current: FileSnapshot
        do {
            current = try metadataReader.snapshot(at: item.sourceURL)
        } catch CleanupFileSystemError.permissionDenied {
            return .permissionChanged
        } catch CleanupFileSystemError.vanished {
            return await volumeChecker.isAvailable(
                volumeIdentifier: item.expectedSnapshot.volumeIdentifier
            ) ? .itemMissing : .volumeUnavailable
        } catch {
            return .permissionChanged
        }

        guard current.identity.entryKind != .symbolicLink,
              !current.hasSymbolicLinkComponent else {
            return .symbolicLinkDetected
        }
        guard PathSafety.isContained(
            current.standardizedPath,
            in: rootPath,
            resolvingSymlinks: true
        ), isApprovedApplicationsRoot || PathSafety.isContained(
            current.standardizedPath,
            in: homePath,
            resolvingSymlinks: true
        ) else {
            return .pathOutsideAllowedRoot
        }
        guard current.identity.entryKind == item.expectedSnapshot.identity.entryKind else {
            return .entryKindChanged
        }
        guard current.identity == item.expectedSnapshot.identity else {
            return .identityChanged
        }
        guard current.volumeIdentifier == item.expectedSnapshot.volumeIdentifier else {
            return .volumeChanged
        }
        guard current.isWritableVolume else {
            return .volumeReadOnly
        }
        guard !current.isCloudPlaceholder,
              current.isCloudItem == item.expectedSnapshot.isCloudItem else {
            return .cloudStateChanged
        }
        for bundleIdentifier in item.requiredClosedBundleIDs + item.inferredOwnerBundleIDs {
            if await runningApplicationChecker.isRunning(bundleIdentifier: bundleIdentifier) {
                return .relatedAppStillRunning
            }
        }
        // D92: repeat manifest/ignore/tracked/protected-tree evidence at preflight
        // and after the durable move intent, using the same bounded reader.
        if rechecksWrites, let requirement = rule.projectArtifact {
            let scanner = ProjectArtifactScanner(fileSystem: metadataReader, home: context.userHomeURL, excludedURLs: context.excludedURLs)
            let project = item.allowedRootURL
            guard item.sourceURL.standardizedFileURL == project.appendingPathComponent(requirement.relativeArtifact).standardizedFileURL,
                  (try? scanner.requirements(at: project).contains(where: {
                      $0.ecosystem == requirement.ecosystem && $0.manifest == requirement.manifest
                          && $0.lockEvidence == requirement.lockEvidence
                          && ($0.relativeArtifact == requirement.relativeArtifact
                              || (requirement.ecosystem == "Python" && ["__pycache__", ".pytest_cache", ".mypy_cache"].contains(item.sourceURL.lastPathComponent)))
                  })) == true else { return .rulesChanged }
            let assessment = scanner.assess(artifact: item.sourceURL, project: project, requirement: requirement)
            guard assessment.reason == nil, let measured = assessment.snapshot else { return .rulesChanged }
            guard measured.modificationTimeNanoseconds == item.latestContentModificationTimeNanoseconds,
                  measured.logicalSizeBytes == item.expectedSnapshot.logicalSizeBytes,
                  measured.allocatedSizeBytes == item.expectedSnapshot.allocatedSizeBytes else { return .candidateBecameActive }
        }
        // D83 (repair 1): AI tool rules, including logs that have no
        // activity probe, re-check entry names before moving. A session,
        // profile, configuration or model that appeared after the scan keeps
        // the whole row in place. Names and kinds only; contents are not read.
        if rechecksWrites,
           CleanupProtectedContentPolicy.protectsPersistentAgentState(ruleID: rule.id),
           let reason = persistentAgentStateSkipReason(
               for: item,
               maximumDepth: rule.maximumDepth,
               current: current,
               rootPath: rootPath,
               homePath: homePath,
               excludedPaths: excludedPaths
           ) {
            return reason
        }
        if rechecksWrites, developerDecision != nil,
           let reason = developerActivitySkipReason(
               for: item,
               rule: rule,
               current: current,
               rootPath: rootPath,
               homePath: homePath,
               excludedPaths: excludedPaths
           ) {
            return reason
        }
        // D47 supplement (review P1-1b): a row whose owner app could not be
        // identified gets the same write recheck as developer files.
        if rechecksWrites, item.rechecksWritesAfterScan, developerDecision == nil {
            guard let expectedLatest = item.latestContentModificationTimeNanoseconds else {
                return .candidateBecameActive
            }
            if let reason = writesAfterScanSkipReason(
                for: item,
                expectedLatest: expectedLatest,
                maximumDepth: rule.maximumDepth,
                current: current,
                rootPath: rootPath,
                homePath: homePath,
                excludedPaths: excludedPaths
            ) {
                return reason
            }
        }
        if isProtectedApplication {
            if await runningApplicationChecker.isRunning(applicationURL: item.sourceURL) {
                return .relatedAppStillRunning
            }
            if rule.effectiveRequiresDuplicateBundleIdentifier {
                guard !item.protectedRetainedCopies.isEmpty else {
                    return .duplicateEvidenceInvalid
                }
                for retained in item.protectedRetainedCopies {
                    guard let current = try? metadataReader.snapshot(at: retained.url),
                          matchesProtectedRetainedSnapshot(
                              current,
                              expected: retained.expectedSnapshot
                          ),
                          current.identity != item.expectedSnapshot.identity,
                          current.identity.entryKind == .directory,
                          retained.url.pathExtension.lowercased() == "app",
                          retained.url.deletingLastPathComponent().standardizedFileURL.path
                            == item.allowedRootURL.standardizedFileURL.path else {
                        return .duplicateRetainedCopyChanged
                    }
                }
            }
        }
        return nil
    }

    private func developerActivitySkipReason(
        for item: CleanPlanItem,
        rule: CleanupRule,
        current: FileSnapshot,
        rootPath: String,
        homePath: String,
        excludedPaths: [String]
    ) -> CleanSkipReason? {
        guard let expectedLatest = item.latestContentModificationTimeNanoseconds,
              item.developerInactivityThresholdDays != nil,
              item.developerScanReferenceDate != nil,
              DeveloperCleanupAgePolicy.applies(to: rule) else {
            return .rulesChanged
        }
        return writesAfterScanSkipReason(
            for: item,
            expectedLatest: expectedLatest,
            maximumDepth: rule.maximumDepth,
            current: current,
            rootPath: rootPath,
            homePath: homePath,
            excludedPaths: excludedPaths
        )
    }

    /// Reads the item's latest readable write again exactly as the scan did;
    /// any difference means it was written or changed after the scan.
    private func writesAfterScanSkipReason(
        for item: CleanPlanItem,
        expectedLatest: Int64,
        maximumDepth: Int,
        current: FileSnapshot,
        rootPath: String,
        homePath: String,
        excludedPaths: [String]
    ) -> CleanSkipReason? {
        var seenIdentities = Set<String>()
        var visitedEntryCount = 0
        do {
            let latest = try latestReadableModificationTime(
                at: item.sourceURL,
                snapshot: current,
                depth: 0,
                maximumDepth: maximumDepth,
                rootPath: rootPath,
                homePath: homePath,
                excludedPaths: excludedPaths,
                seenIdentities: &seenIdentities,
                visitedEntryCount: &visitedEntryCount
            )
            return latest == expectedLatest ? nil : .candidateBecameActive
        } catch is CancellationError {
            // An injected reader can throw CancellationError without cancelling
            // this task. Only real cancellation goes to the caller's cancel path.
            return Task.isCancelled ? nil : .permissionChanged
        } catch let error as DeveloperActivityProbeError {
            return error.reason
        } catch CleanupFileSystemError.permissionDenied {
            return .permissionChanged
        } catch CleanupFileSystemError.vanished {
            return .candidateBecameActive
        } catch {
            return .permissionChanged
        }
    }

    /// D83: walks the candidate the way the scan measured it (same depth, no
    /// links followed, exclusions skipped) and looks only at entry names and
    /// kinds. Unreadable children are skipped like the scan's lower bound.
    private func persistentAgentStateSkipReason(
        for item: CleanPlanItem,
        maximumDepth: Int,
        current: FileSnapshot,
        rootPath: String,
        homePath: String,
        excludedPaths: [String]
    ) -> CleanSkipReason? {
        var seenIdentities = Set<String>()
        var pending: [(url: URL, snapshot: FileSnapshot, depth: Int)] = [(item.sourceURL, current, 0)]
        var visitedEntryCount = 0
        while let next = pending.popLast() {
            guard seenIdentities.insert(next.snapshot.identity.deduplicationKey).inserted,
                  next.snapshot.identity.entryKind == .directory,
                  next.depth < maximumDepth else { continue }
            if Task.isCancelled { return .permissionChanged }
            guard let childURLs = try? metadataReader.children(of: next.url) else {
                if next.depth == 0 { return .permissionChanged }
                continue
            }
            for childURL in childURLs {
                visitedEntryCount += 1
                if visitedEntryCount.isMultiple(of: 512), Task.isCancelled { return .permissionChanged }
                guard !excludedPaths.contains(where: {
                    PathSafety.isContained(childURL.path, in: $0, resolvingSymlinks: false)
                }) else { continue }
                guard let child = try? metadataReader.aggregateSnapshot(at: childURL),
                      child.identity.entryKind != .symbolicLink,
                      !child.hasSymbolicLinkComponent else { continue }
                if CleanupProtectedContentPolicy.isProtectedAgentEntry(named: childURL.lastPathComponent)
                    || (child.identity.entryKind == .directory
                        && CleanupProtectedContentPolicy.isProtectedDataFolder(named: childURL.lastPathComponent)) {
                    return .candidateBecameActive
                }
                guard PathSafety.isContained(child.standardizedPath, in: rootPath, resolvingSymlinks: true),
                      PathSafety.isContained(child.standardizedPath, in: homePath, resolvingSymlinks: true) else {
                    continue
                }
                pending.append((childURL, child, next.depth + 1))
            }
        }
        return nil
    }

    /// 按扫描时同样的方式重读最近修改时间（D19）：不跟随符号链接，排除项和
    /// 不可读部分不计入，到深度上限只取目录本身的时间。只比较最大修改时间，
    /// 不保证发现所有内容变化。项目根本身必须仍是允许范围内的真实目录。
    private func latestReadableModificationTime(
        at url: URL,
        snapshot: FileSnapshot,
        depth: Int,
        maximumDepth: Int,
        rootPath: String,
        homePath: String,
        excludedPaths: [String],
        seenIdentities: inout Set<String>,
        visitedEntryCount: inout Int
    ) throws -> Int64? {
        if depth == 0 { try Task.checkCancellation() }
        let isContained = PathSafety.isContained(
            snapshot.standardizedPath,
            in: rootPath,
            resolvingSymlinks: true
        ) && PathSafety.isContained(
            snapshot.standardizedPath,
            in: homePath,
            resolvingSymlinks: true
        )
        if depth == 0 {
            guard snapshot.identity.entryKind != .symbolicLink,
                  !snapshot.hasSymbolicLinkComponent else {
                throw DeveloperActivityProbeError(reason: .symbolicLinkDetected)
            }
            guard isContained else {
                throw DeveloperActivityProbeError(reason: .pathOutsideAllowedRoot)
            }
        } else if !isContained {
            return snapshot.modificationTimeNanoseconds
        }
        guard seenIdentities.insert(snapshot.identity.deduplicationKey).inserted,
              snapshot.identity.entryKind == .directory,
              depth < maximumDepth else {
            return snapshot.modificationTimeNanoseconds
        }

        let childURLs: [URL]
        try Task.checkCancellation()
        do {
            childURLs = try metadataReader.children(of: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if depth == 0 { throw error }
            return snapshot.modificationTimeNanoseconds
        }
        try Task.checkCancellation()
        var latest = snapshot.modificationTimeNanoseconds
        for childURL in childURLs {
            visitedEntryCount += 1
            if visitedEntryCount.isMultiple(of: 512) { try Task.checkCancellation() }
            guard !excludedPaths.contains(where: {
                PathSafety.isContained(childURL.path, in: $0, resolvingSymlinks: false)
            }) else { continue }
            let child: FileSnapshot
            do {
                child = try metadataReader.aggregateSnapshot(at: childURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Preserve the scan's lower-bound handling of unreadable children.
                continue
            }
            guard child.identity.entryKind != .symbolicLink,
                  !child.hasSymbolicLinkComponent else {
                continue
            }
            if let childLatest = try latestReadableModificationTime(
                at: childURL,
                snapshot: child,
                depth: depth + 1,
                maximumDepth: maximumDepth,
                rootPath: rootPath,
                homePath: homePath,
                excludedPaths: excludedPaths,
                seenIdentities: &seenIdentities,
                visitedEntryCount: &visitedEntryCount
            ) {
                latest = max(latest ?? childLatest, childLatest)
            }
        }
        return latest
    }

    /// D23: each frozen Trash entry is re-read right before deletion. It must
    /// still be the same file, directly inside the user's own `~/.Trash`; a
    /// symbolic link is only removed while it points back inside the Trash.
    private func permanentDeletionSkipReason(
        for item: CleanPlanItem,
        context: CleanupExecutionContext
    ) async -> CleanSkipReason? {
        guard let rule = context.activeRules.rules.first(where: { $0.id == item.ruleID }),
              rule.action == .emptyTrash,
              rule.risk == .protected,
              rule.allowsManualSelection,
              rule.measurementRequirement == .complete,
              rule.selectionPolicyVersion == item.ruleSelectionPolicyVersion,
              rule.executionEligibility == item.executionEligibility,
              rule.reasonKey == item.reasonCode,
              item.riskLevel == .protected,
              item.requiredClosedBundleIDs.isEmpty,
              item.explicitUserSelection else {
            return .rulesChanged
        }
        let homeURL = context.userHomeURL
        let trashURL = homeURL.appendingPathComponent(rule.root.path, isDirectory: true)
        let trashPath = PathSafety.lexicalPath(trashURL.path)
        let sourcePath = PathSafety.lexicalPath(item.sourceURL.path)
        guard item.sourceURL.isFileURL,
              PathSafety.lexicalPath(item.allowedRootURL.path) == trashPath,
              PathSafety.lexicalPath(item.sourceURL.deletingLastPathComponent().path) == trashPath,
              sourcePath != trashPath,
              PathSafety.isContained(trashPath, in: PathSafety.lexicalPath(homeURL.path), resolvingSymlinks: false) else {
            return .pathOutsideAllowedRoot
        }
        if ScanExclusionService.intersectsExcludedTree(
            sourcePath,
            excludedPaths: context.excludedURLs.map { PathSafety.lexicalPath($0.path) }
        ) {
            return .excludedByUser
        }
        // P2-3: still a real folder, and the very Trash folder the scan saw.
        guard let trash = try? metadataReader.snapshot(at: trashURL),
              trash.identity.entryKind == .directory,
              !trash.hasSymbolicLinkComponent,
              let scannedTrash = item.allowedRootIdentity,
              trash.identity == scannedTrash else {
            return .pathOutsideAllowedRoot
        }

        let current: FileSnapshot
        do {
            current = try metadataReader.snapshot(at: item.sourceURL)
        } catch CleanupFileSystemError.vanished {
            return await volumeChecker.isAvailable(
                volumeIdentifier: item.expectedSnapshot.volumeIdentifier
            ) ? .itemMissing : .volumeUnavailable
        } catch {
            return .permissionChanged
        }
        guard current.identity.entryKind == item.expectedSnapshot.identity.entryKind else {
            return .entryKindChanged
        }
        guard current.identity == item.expectedSnapshot.identity else {
            return .identityChanged
        }
        guard current.volumeIdentifier == item.expectedSnapshot.volumeIdentifier else {
            return .volumeChanged
        }
        guard current.isWritableVolume else {
            return .volumeReadOnly
        }
        // P2-5: an entry that became a cloud placeholder is left alone.
        guard !current.isCloudPlaceholder,
              current.isCloudItem == item.expectedSnapshot.isCloudItem else {
            return .cloudStateChanged
        }
        if current.identity.entryKind == .symbolicLink {
            guard CleanupTrashEntryPolicy.symbolicLinkStaysInside(
                item.sourceURL,
                trashPath: trashPath,
                fileSystem: metadataReader
            ) else {
                return .symbolicLinkDetected
            }
        } else {
            guard !current.hasSymbolicLinkComponent,
                  PathSafety.isContained(current.standardizedPath, in: trashPath, resolvingSymlinks: true) else {
                return .pathOutsideAllowedRoot
            }
        }
        return nil
    }

    private func isApprovedProtectedApplication(
        _ item: CleanPlanItem,
        rule: CleanupRule
    ) -> Bool {
        if rule.effectiveRequiresDuplicateBundleIdentifier {
            return item.reasonCodes.contains("duplicate-bundle-identifier")
        }
        guard let bundleID = Bundle(url: item.sourceURL)?.bundleIdentifier else {
            return false
        }
        return rule.effectiveIncludedBundleIdentifiers.contains(bundleID)
            && item.reasonCodes.contains("application-bundle-identifier:\(bundleID)")
    }

    private func matchesProtectedRetainedSnapshot(
        _ current: FileSnapshot,
        expected: FileSnapshot
    ) -> Bool {
        current.identity == expected.identity
            && current.standardizedPath == expected.standardizedPath
            && current.volumeIdentifier == expected.volumeIdentifier
            && current.modificationTimeNanoseconds == expected.modificationTimeNanoseconds
            && current.isWritableVolume == expected.isWritableVolume
            && current.isCloudItem == expected.isCloudItem
            && current.isCloudPlaceholder == expected.isCloudPlaceholder
            && current.hasSymbolicLinkComponent == expected.hasSymbolicLinkComponent
    }


    private func boundedDuplicateSnapshot(at url: URL) throws -> FileSnapshot? {
        let metadata = metadataReader
        return try FileContentReadPool.shared.read(at: url, priority: .userInitiated) { _ in try? metadata.snapshot(at: url) }
    }

    private func verifiedDuplicateSkipReason(
        for item: CleanPlanItem, evidence: VerifiedDuplicateEvidence, context: CleanupExecutionContext
    ) -> CleanSkipReason? {
        do { return try checkedDuplicateSkipReason(for: item, evidence: evidence, context: context) }
        catch let error as FileContentReadError { return contentReadSkipReason(error) }
        catch is CancellationError { return .contentReadCancelled }
        catch { return .permissionChanged }
    }

    private func checkedDuplicateSkipReason(
        for item: CleanPlanItem,
        evidence: VerifiedDuplicateEvidence,
        context: CleanupExecutionContext
    ) throws -> CleanSkipReason? {
        let sentinelRule = context.activeRules.rules.first {
            $0.id == VerifiedDuplicateCleanPlanBuilder.ruleID
        }
        guard item.action == .moveToTrash,
              item.executionEligibility == .eligibleAfterReview,
              context.activeRules.rulesVersion == VerifiedDuplicateCleanPlanBuilder.rulesVersion,
              item.ruleID == VerifiedDuplicateCleanPlanBuilder.ruleID,
              item.ruleSelectionPolicyVersion == VerifiedDuplicateCleanPlanBuilder.selectionPolicyVersion,
              item.requiredClosedBundleIDs.isEmpty,
              sentinelRule?.selectionPolicyVersion == item.ruleSelectionPolicyVersion,
              sentinelRule?.risk == .reviewOnly,
              sentinelRule?.action == .revealOnly,
              sentinelRule?.allowsManualSelection == false,
              evidence.digest.count == VerifiedDuplicateEvidence.digestByteCount,
              evidence.contentSizeBytes == item.expectedSnapshot.logicalSizeBytes,
              !evidence.retainedCopies.isEmpty else {
            return .duplicateEvidenceInvalid
        }

        let sourcePath = PathSafety.lexicalPath(item.sourceURL.path)
        let rootPath = PathSafety.lexicalPath(item.allowedRootURL.path)
        let homePath = PathSafety.lexicalPath(context.userHomeURL.path)
        guard item.sourceURL.isFileURL,
              item.allowedRootURL.isFileURL,
              sourcePath != rootPath,
              PathSafety.isContained(sourcePath, in: rootPath, resolvingSymlinks: false),
              PathSafety.isContained(rootPath, in: homePath, resolvingSymlinks: false) else {
            return .pathOutsideAllowedRoot
        }
        let excludedPaths = context.excludedURLs.map { PathSafety.lexicalPath($0.path) }
        if ScanExclusionService.intersectsExcludedTree(sourcePath, excludedPaths: excludedPaths) {
            return .excludedByUser
        }

        guard let sourceSnapshot = try boundedDuplicateSnapshot(at: item.sourceURL) else {
            return .itemMissing
        }
        if let reason = verifiedSourceSnapshotSkipReason(
            current: sourceSnapshot,
            expected: item.expectedSnapshot,
            rootPath: rootPath,
            homePath: homePath
        ) {
            return reason
        }
        if let reason = digestSkipReason(at: item.sourceURL, expected: evidence.digest) { return reason }
        guard (try boundedDuplicateSnapshot(at: item.sourceURL)) == item.expectedSnapshot else {
            return .identityChanged
        }

        var retainedPaths = Set<String>()
        var retainedIdentities = Set<FileIdentity>()
        for retained in evidence.retainedCopies {
            let retainedPath = PathSafety.lexicalPath(retained.url.path)
            guard retained.url.isFileURL,
                  retainedPath == PathSafety.lexicalPath(retained.expectedSnapshot.standardizedPath),
                  retainedPath != sourcePath,
                  retained.expectedSnapshot.identity != item.expectedSnapshot.identity,
                  retained.expectedSnapshot.logicalSizeBytes == evidence.contentSizeBytes,
                  retainedPaths.insert(retainedPath).inserted,
                  retainedIdentities.insert(retained.expectedSnapshot.identity).inserted else {
                return .duplicateEvidenceInvalid
            }
            guard let current = try boundedDuplicateSnapshot(at: retained.url),
                  current == retained.expectedSnapshot,
                  current.identity.entryKind == .regularFile,
                  !current.hasSymbolicLinkComponent,
                  !current.isCloudPlaceholder else {
                return .duplicateRetainedCopyChanged
            }
            if let reason = digestSkipReason(at: retained.url, expected: evidence.digest) { return reason }
            guard (try boundedDuplicateSnapshot(at: retained.url)) == retained.expectedSnapshot else {
                return .duplicateRetainedCopyChanged
            }
        }
        return nil
    }

    private func digestSkipReason(at url: URL, expected: Data) -> CleanSkipReason? {
        do {
            return try contentDigestReader.sha256(at: url) == expected ? nil : .duplicateContentChanged
        } catch let error as FileContentReadError {
            return contentReadSkipReason(error)
        } catch is CancellationError {
            return .contentReadCancelled
        } catch {
            return .duplicateContentChanged
        }
    }

    private func contentReadSkipReason(_ error: FileContentReadError) -> CleanSkipReason {
        switch error {
        case .cloudOnly: .contentCloudOnly
        case .downloading: .contentDownloading
        case .timedOut, .copyTimedOut, .writingTimedOut: .contentReadTimedOut
        case .busy, .protectionUnavailable: .contentReadUnavailable
        case .changed: .duplicateContentChanged
        case .invalidPath, .unsupportedType, .tooDeep, .fileTooLarge: .contentReadUnavailable
        }
    }

    private func verifiedSourceSnapshotSkipReason(
        current: FileSnapshot,
        expected: FileSnapshot,
        rootPath: String,
        homePath: String
    ) -> CleanSkipReason? {
        guard current.identity.entryKind != .symbolicLink,
              !current.hasSymbolicLinkComponent else {
            return .symbolicLinkDetected
        }
        guard PathSafety.isContained(current.standardizedPath, in: rootPath, resolvingSymlinks: true),
              PathSafety.isContained(current.standardizedPath, in: homePath, resolvingSymlinks: true) else {
            return .pathOutsideAllowedRoot
        }
        guard current.identity.entryKind == expected.identity.entryKind else {
            return .entryKindChanged
        }
        guard current.identity == expected.identity else { return .identityChanged }
        guard current.volumeIdentifier == expected.volumeIdentifier else { return .volumeChanged }
        guard current.isWritableVolume else { return .volumeReadOnly }
        guard !current.isCloudPlaceholder,
              current.isCloudItem == expected.isCloudItem else {
            return .cloudStateChanged
        }
        guard current.logicalSizeBytes == expected.logicalSizeBytes,
              current.modificationTimeNanoseconds == expected.modificationTimeNanoseconds else {
            return .duplicateContentChanged
        }
        return nil
    }

    private func reportItem(
        for item: CleanPlanItem,
        outcome: CleanItemOutcome
    ) -> CleanReportItem {
        CleanReportItem(
            id: item.id,
            planItemID: item.id,
            ruleID: item.ruleID,
            sourcePath: item.expectedSnapshot.standardizedPath,
            estimatedBytes: item.estimatedSizeBytes,
            outcome: outcome,
            ruleRevision: item.ruleRevision
        )
    }

    private func progressSnapshot(
        plan: CleanPlan,
        items: [CleanReportItem],
        currentRuleID: String?
    ) -> CleanupExecutionProgress {
        CleanupExecutionProgress(
            planID: plan.id,
            processedItemCount: items.filter {
                if case .notProcessed = $0.outcome { return false }
                return true
            }.count,
            totalItemCount: plan.items.count,
            movedItemCount: items.filter {
                if case .moved = $0.outcome { return true }
                return false
            }.count,
            skippedItemCount: items.filter {
                if case .skipped = $0.outcome { return true }
                return false
            }.count,
            failedItemCount: items.filter {
                if case .failed = $0.outcome { return true }
                return false
            }.count,
            currentRuleID: currentRuleID,
            deletedItemCount: items.filter {
                if case .deleted = $0.outcome { return true }
                return false
            }.count
        )
    }

    private func cleanFailure(
        for error: Error,
        disposition: CleanupDisposition
    ) -> CleanFailure {
        if let moveError = error as? CleanupMoveError, case .invalidResult = moveError {
            return CleanFailure(code: .moveOutcomeUnknown, detailCode: "destination-url-unavailable")
        }
        let nsError = error as NSError
        let detailCode: String?
        switch nsError.code {
        case NSFileWriteNoPermissionError, Int(EACCES), Int(EPERM):
            detailCode = "permission-denied"
        case NSFileNoSuchFileError, Int(ENOENT):
            detailCode = "volume-or-item-unavailable"
        case Int(EXDEV):
            detailCode = "cross-volume"
        default:
            detailCode = nil
        }
        return CleanFailure(
            code: disposition == .trash ? .trashMoveFailed : .quarantineMoveFailed,
            detailCode: detailCode
        )
    }

    private func terminalFailureReport(
        plan: CleanPlan,
        startedAt: Date,
        code: CleanFailureCode
    ) -> CleanReport {
        let items = plan.items.map {
            reportItem(
                for: $0,
                outcome: .failed(CleanFailure(code: code, detailCode: nil))
            )
        }
        return makeReport(
            plan: plan,
            startedAt: startedAt,
            items: items,
            cancelled: false,
            availableSpaceDeltaBytes: nil
        )
    }

    private func makeReport(
        plan: CleanPlan,
        startedAt: Date,
        items: [CleanReportItem],
        cancelled: Bool,
        availableSpaceDeltaBytes: Int64?
    ) -> CleanReport {
        let moved = items.compactMap { item -> CleanupMoveReceipt? in
            guard case let .moved(receipt) = item.outcome else { return nil }
            return receipt
        }
        let skipped = items.filter {
            if case .skipped = $0.outcome { return true }
            return false
        }.count
        let failed = items.filter {
            if case .failed = $0.outcome { return true }
            return false
        }.count
        let notProcessed = items.filter {
            if case .notProcessed = $0.outcome { return true }
            return false
        }.count
        let deleted = items.filter {
            if case .deleted = $0.outcome { return true }
            return false
        }.count
        let movedBytes = CleanupByteCount.sum(items.compactMap {
            if case .moved = $0.outcome { return $0.estimatedBytes }
            return nil
        })
        let deletedBytes = CleanupByteCount.sum(items.compactMap {
            if case .deleted = $0.outcome { return $0.estimatedBytes }
            return nil
        })
        let movedPlanItemIDs = Set(items.compactMap { item -> UUID? in
            guard case .moved = item.outcome else { return nil }
            return item.planItemID
        })
        let hasMovedDuplicateWithUnknownPhysicalSavings = plan.items.contains {
            movedPlanItemIDs.contains($0.id) && $0.verifiedDuplicateEvidence != nil
        }
        let reclaimableAfterEmptyingTrashBytes: Int64? = plan.disposition == .trash
            ? (hasMovedDuplicateWithUnknownPhysicalSavings ? nil : movedBytes)
            : 0
        let unverified = moved.filter { !$0.isRestorable }.count
        let outcome: CleanReportOutcome
        if cancelled || notProcessed > 0 {
            outcome = .cancelled
        } else if moved.isEmpty && deleted == 0 && failed > 0 {
            outcome = .failed
        } else if skipped > 0 || failed > 0 || unverified > 0 {
            outcome = .partiallyCompleted
        } else {
            outcome = .completed
        }

        return CleanReport(
            id: plan.id.rawValue,
            planID: plan.id,
            sessionID: plan.sessionID,
            rulesVersion: plan.rulesVersion,
            disposition: plan.disposition,
            scanWasPartial: plan.scanWasPartial,
            startedAt: startedAt,
            completedAt: Date(),
            outcome: outcome,
            items: items,
            summary: CleanReportSummary(
                requestedItemCount: plan.items.count,
                movedItemCount: moved.count,
                skippedItemCount: skipped,
                failedItemCount: failed,
                notProcessedItemCount: notProcessed,
                unverifiedMoveCount: unverified,
                plannedBytes: plan.estimatedMovableBytes,
                movedToRecoverableLocationBytes: movedBytes,
                reclaimableAfterEmptyingTrashBytes: reclaimableAfterEmptyingTrashBytes,
                permanentlyFreedBytes: deletedBytes,
                availableSpaceDeltaBytes: availableSpaceDeltaBytes,
                deletedItemCount: deleted
            ),
            restoreAuthorizations: Dictionary(uniqueKeysWithValues: plan.items.map { item in
                (item.sourceURL.path, CleanupRestoreAuthorization(
                    sourcePath: item.sourceURL.path, allowedRootPath: item.allowedRootURL.path,
                    sourceIdentity: item.fileIdentity, ruleID: item.ruleID, planItemID: item.id))
            }),
            rulesProvenance: plan.rulesProvenance
        )
    }

    private func capacityDelta(before: Int64?, after: Int64?) -> Int64? {
        guard let before, let after else { return nil }
        return after - before
    }
}

actor CleanupRecoveryService {
    private let metadataReader: any ReadOnlyFileSystem

    init(metadataReader: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem()) {
        self.metadataReader = metadataReader
    }

    func restore(
        receipts: [CleanupMoveReceipt],
        userHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        trashURL: URL = CleanupService.userTrashURL(),
        quarantineRootURL: URL = CleanupQuarantineLocation.defaultURL,
        allowedApplicationPaths: Set<String> = []
    ) async -> CleanupRecoveryReport {
        var results = [CleanupRecoveryItem]()
        for receipt in receipts {
            if Task.isCancelled {
                break
            }
            results.append(await restoreOne(
                receipt,
                userHomeURL: userHomeURL,
                trashURL: trashURL,
                quarantineRootURL: quarantineRootURL,
                allowedApplicationPaths: allowedApplicationPaths
            ))
        }
        return CleanupRecoveryReport(completedAt: Date(), items: results)
    }

    func restoreOne(
        _ receipt: CleanupMoveReceipt,
        userHomeURL: URL,
        trashURL: URL,
        quarantineRootURL: URL,
        allowedApplicationPaths: Set<String>,
        beforeMove: @escaping @Sendable () async throws -> Void = {},
        onUncertainMove: @Sendable () async -> Void = {}
    ) async -> CleanupRecoveryItem {
        let fallback = CleanupRecoveryItem(
            id: UUID(),
            originalPath: receipt.originalPath,
            outcome: .failed
        )
        guard receipt.isRestorable, let movedIdentity = receipt.movedIdentity else {
            return fallback
        }

        let sourceURL = receipt.resultingItemURL.standardizedFileURL
        let destinationURL = URL(fileURLWithPath: receipt.originalPath).standardizedFileURL
        let homePath = PathSafety.lexicalPath(userHomeURL.path)
        let sourceRoot = receipt.disposition == .trash ? trashURL : quarantineRootURL
        let sourceRootPath = PathSafety.lexicalPath(sourceRoot.path)
        let restoringApplication = allowedApplicationPaths.contains(receipt.originalPath)
            && receipt.originalPath == PathSafety.lexicalPath(receipt.originalPath)
            && receipt.originalPath.hasPrefix("/Applications/")
            && destinationURL.pathExtension == "app"
            && movedIdentity.entryKind == .directory
        let destinationRoot = restoringApplication ? "/Applications" : homePath
        guard sourceURL.isFileURL,
              destinationURL.isFileURL,
              PathSafety.isContained(
                sourceURL.path,
                in: sourceRootPath,
                resolvingSymlinks: false
              ),
              PathSafety.isContained(
                destinationURL.path,
                in: destinationRoot,
                resolvingSymlinks: false
              ),
              !PathSafety.isContained(
                destinationURL.path,
                in: sourceRootPath,
                resolvingSymlinks: false
              ) else {
            return CleanupRecoveryItem(
                id: UUID(),
                originalPath: receipt.originalPath,
                outcome: .unsafePath
            )
        }

        let sourceSnapshot: FileSnapshot
        do {
            sourceSnapshot = try metadataReader.snapshot(at: sourceURL)
        } catch CleanupFileSystemError.vanished {
            return CleanupRecoveryItem(
                id: UUID(),
                originalPath: receipt.originalPath,
                outcome: .missing
            )
        } catch {
            return fallback
        }
        guard !sourceSnapshot.hasSymbolicLinkComponent,
              sourceSnapshot.identity == movedIdentity else {
            return CleanupRecoveryItem(
                id: UUID(),
                originalPath: receipt.originalPath,
                outcome: .identityChanged
            )
        }

        do {
            _ = try metadataReader.snapshot(at: destinationURL)
            return CleanupRecoveryItem(
                id: UUID(),
                originalPath: receipt.originalPath,
                outcome: .conflict
            )
        } catch CleanupFileSystemError.vanished {
            // Expected: restore never overwrites an existing destination.
        } catch {
            return fallback
        }

        let parentURL = destinationURL.deletingLastPathComponent()
        guard let parent = try? metadataReader.snapshot(at: parentURL),
              parent.identity.entryKind == .directory,
              !parent.hasSymbolicLinkComponent,
              PathSafety.isContained(
                parent.standardizedPath,
                in: destinationRoot,
                resolvingSymlinks: true
              ) else {
            return CleanupRecoveryItem(
                id: UUID(),
                originalPath: receipt.originalPath,
                outcome: .unsafePath
            )
        }

        var invoked = false
        do {
            try Task.checkCancellation()
            try await beforeMove()
            try Task.checkCancellation()
            let immediateSource = try metadataReader.snapshot(at: sourceURL)
            guard !immediateSource.hasSymbolicLinkComponent,
                  immediateSource.identity == movedIdentity else {
                return CleanupRecoveryItem(
                    id: UUID(),
                    originalPath: receipt.originalPath,
                    outcome: .identityChanged
                )
            }
            do {
                _ = try metadataReader.snapshot(at: destinationURL)
                return CleanupRecoveryItem(
                    id: UUID(),
                    originalPath: receipt.originalPath,
                    outcome: .conflict
                )
            } catch CleanupFileSystemError.vanished {
                // Expected immediately before the non-overwriting move.
            }
            do {
                try ExclusiveRecoveryMove.perform(source: sourceURL, destination: destinationURL, expectedIdentity: movedIdentity)
            } catch {
                // renameatx_np is atomic, so a thrown error means nothing moved
                // and the receipt stays retryable instead of becoming unknown.
                guard restoringApplication, UninstallErrorEvidence.isPermissionDenied(error) else { throw error }
                do { try await AuthorizedApplicationMover.shared.restore(receipt, beforeMove: beforeMove) }
                catch AuthorizedMoveError.connectionLost {
                    // Only a commit without a reply leaves the move unconfirmed.
                    invoked = true
                    await onUncertainMove()
                    throw AuthorizedMoveError.connectionLost
                }
            }
            invoked = true
            let restored = try metadataReader.snapshot(at: destinationURL)
            guard restored.identity == movedIdentity, !restored.hasSymbolicLinkComponent else {
                return CleanupRecoveryItem(
                    id: UUID(),
                    originalPath: receipt.originalPath,
                    outcome: .outcomeUnknown
                )
            }
            return CleanupRecoveryItem(
                id: UUID(),
                originalPath: receipt.originalPath,
                outcome: .restored
            )
        } catch is CancellationError {
            return CleanupRecoveryItem(id: fallback.id, originalPath: receipt.originalPath,
                                       outcome: invoked ? .outcomeUnknown : .notProcessed)
        } catch {
            return CleanupRecoveryItem(id: fallback.id, originalPath: receipt.originalPath,
                                       outcome: invoked ? .outcomeUnknown : Self.unmovedRestoreOutcome(error))
        }
    }

    /// Classify a restore that provably moved nothing, so it can be retried.
    static func unmovedRestoreOutcome(_ error: Error) -> CleanupRecoveryItemOutcome {
        if let failure = error as? CleanupReportJournal.Failure, failure == .invalidEntry { return .identityChanged }
        if case AppUninstallError.identityChanged = error { return .identityChanged }
        let existing = UninstallErrorEvidence.chain(error).contains {
            $0.domain == NSPOSIXErrorDomain && [Int(EEXIST), Int(ENOTEMPTY)].contains($0.code)
        }
        return existing ? .conflict : .failed
    }
}
