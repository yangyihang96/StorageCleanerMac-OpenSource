import AppKit
import FileOperationShared
import Foundation
import Security

/// Selection is frozen once, before a lease or system prompt can suspend the UI.
struct UninstallPlan: Sendable {
    let id = UUID()
    let app: InstalledAppItem
    let relatedItems: [InstalledAppRelatedItem]
    let homeDirectory: URL

    init(app: InstalledAppItem, selectedPaths: Set<String>,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard app.canMoveToTrash(homeDirectory: homeDirectory), app.scanIdentity != nil else {
            throw AppUninstallError.identityChanged(app.path)
        }
        let allowed = AppUninstallService.reviewableRelatedItems(for: app, homeDirectory: homeDirectory).filter { $0.ownershipEvidence != nil }
        guard selectedPaths.isSubset(of: Set(allowed.map(\.path))) else {
            throw AppUninstallError.notAllowed(app.path)
        }
        self.app = app
        self.homeDirectory = homeDirectory
        // Collapse nested selections so a directory and its child cannot move twice.
        let selected = allowed.filter { selectedPaths.contains($0.path) }.sorted { $0.path.count < $1.path.count }
        var roots = [InstalledAppRelatedItem]()
        for item in selected where !roots.contains(where: { item.path.hasPrefix($0.path + "/") }) {
            roots.append(item)
        }
        relatedItems = roots
    }
}

enum NativeApplicationRecycler {
    /// Resumes only when macOS finishes. Cancellation never abandons the callback.
    @MainActor static func recycle(_ source: URL) async throws -> URL {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.recycle([source]) { destinations, error in
                if let destination = destinations[source] {
                    continuation.resume(returning: destination)
                } else {
                    continuation.resume(throwing: error ?? CleanupMoveError.invalidResult)
                }
            }
        }
    }
}

extension AppUninstallService {
    static func execute(_ plan: UninstallPlan, coordinator: HeavyWorkCoordinator,
                        lease: HeavyWorkCoordinator.Lease, retrying previous: CleanReport? = nil,
                        completedApplication: CleanupMoveReceipt? = nil,
                        recycle: @escaping @Sendable (URL) async throws -> URL = { try await NativeApplicationRecycler.recycle($0) },
                        authorization: UninstallAuthorizationEnvironment = .live,
                        persist: RecordedTrashOperation.Persistence = {
                            try CleanupReportJournal.live.checkpoint($0, expectedIdentities: $1)
                        }, progress: (CleanReport) async -> Void = { _ in }) async -> AppUninstallTrashResult {
        let app = plan.app
        let ownership = Dictionary(uniqueKeysWithValues: plan.relatedItems.compactMap { item in
            item.ownershipEvidence.map { (item.path, $0) }
        })
        func attachingEvidence(_ report: CleanReport) -> CleanReport {
            var copy = report
            copy.uninstallOwnership = ownership
            return copy
        }
        var items = [RecordedTrashOperation.Item(path: app.path, bytes: app.sizeBytes,
            identity: app.scanIdentity, allowedRestoreRoot: URL(fileURLWithPath: app.path).deletingLastPathComponent())]
            + plan.relatedItems.map { .init(path: $0.path, bytes: $0.sizeBytes, identity: $0.scanIdentity,
                allowedRestoreRoot: URL(fileURLWithPath: $0.path).deletingLastPathComponent()) }
        if completedApplication != nil { items.removeAll { $0.path == app.path } }
        if let previous {
            let permitted = Set(previous.items.filter { isRetryable($0.outcome) }.map(\.sourcePath))
            items = items.filter { permitted.contains($0.path) }
        }
        let containsApplication = items.contains { $0.path == app.path }
        let report = await RecordedTrashOperation.runAsync(items: items, ruleID: "uninstall.selection.v1",
            validate: { item in
                try await coordinator.requireValid(lease, owner: .cleanup)
                try Task.checkCancellation()
                if item.path == app.path {
                    try validateCurrentApplicationIdentity(app)
                    if !ownership.isEmpty {
                        let signature = try CodeSignatureVerifier().verifyCode(at: URL(fileURLWithPath: app.path))
                        guard signature.codeSigningIdentifier == app.bundleIdentifier,
                              ownership.values.allSatisfy({ $0.teamID == signature.teamIdentifier && $0.applicationIdentity == app.scanIdentity }) else {
                            throw AppUninstallError.identityChanged(app.path)
                        }
                    }
                } else {
                    if !containsApplication {
                        guard let receipt = completedApplication ?? previous?.restorableReceipts.first(where: { $0.originalPath == app.path }),
                              receipt.originalPath == app.path, receipt.isRestorable,
                              let identity = receipt.movedIdentity,
                              try FoundationReadOnlyFileSystem().snapshot(at: receipt.resultingItemURL).identity == identity else {
                            throw AppUninstallError.moveNotVerified(app.path)
                        }
                        do {
                            _ = try FoundationReadOnlyFileSystem().snapshot(at: URL(fileURLWithPath: app.path))
                            throw AppUninstallError.identityChanged(app.path)
                        } catch CleanupFileSystemError.vanished { }
                    }
                    guard NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty,
                          reviewableRelatedItems(for: app, homeDirectory: plan.homeDirectory).contains(where: { $0.path == item.path }) else {
                        throw AppUninstallError.identityChanged(item.path)
                    }
                }
            }, move: { source in
                do { return try await recycle(source) }
                catch {
                    let nativeError = error
                    guard source.path == app.path, let identity = app.scanIdentity else { throw error }
                    let decision = UninstallAuthorizationDecision.evaluate(error, applicationPath: app.path,
                        isWritable: authorization.isWritable, protection: authorization.protection,
                        helperVerdict: { authorization.helperVerdict(app, identity, plan.id) })
                    guard decision == .offer else {
                        // Not offered: the refusal codes stay in the chain, so the
                        // unchanged app is still recorded as "not moved".
                        throw decision.notOfferedError(wrapping: error) ?? error
                    }
                    // Native denial is not enough: prove the original still exists before offering authorization.
                    try validateCurrentApplicationIdentity(app)
                    do {
                        return try await authorization.move(app, identity, plan.id, {
                            try await coordinator.requireValid(lease, owner: .cleanup)
                            try Task.checkCancellation()
                            try validateCurrentApplicationIdentity(app)
                        })
                    } catch AuthorizedMoveError.connectionLost {
                        // Disconnection cannot establish worker completion. Retain quarantine
                        // even after this lease exits; require reconciliation before further cleanup.
                        _ = try await coordinator.beginCleanupQuarantine(lease)
                        throw AuthorizedMoveError.connectionLost
                    } catch {
                        // Preserve the original permission chain along with the authorization
                        // result, so a confirmed unchanged app is not labelled as removed.
                        throw UninstallAuthorizationFailure.wrap(error, nativeError: nativeError)
                    }
                }
            }, requiresFirstSuccess: containsApplication,
            persist: { report, identities in try persist(attachingEvidence(report), identities) },
            progress: { await progress(attachingEvidence($0)) })
        let moved = Set(report.items.compactMap { row -> String? in
            guard case .moved = row.outcome else { return nil }; return row.sourcePath
        })
        return AppUninstallTrashResult(movedAppBytes: moved.contains(app.path) ? app.sizeBytes : 0,
            movedRelatedItems: plan.relatedItems.filter { moved.contains($0.path) }, skippedRelatedPaths: [],
            failedRelatedPaths: plan.relatedItems.filter { !moved.contains($0.path) }.map(\.path), report: attachingEvidence(report))
    }
}


extension AppUninstallService {
    /// A row that provably moved nothing: never started, or refused while
    /// the original stayed in place. Unknown outcomes are never retried.
    static func isRetryable(_ outcome: CleanItemOutcome) -> Bool {
        switch outcome {
        case .notProcessed: true
        case .failed(let failure): failure.code == .trashMoveRejected
        case .moved, .skipped, .deleted: false
        }
    }

    /// Provably unmoved and not bound to fail the same way again (a path the
    /// helper never accepts, a change that needs a rescan, a vanished item).
    static func isWorthRetrying(_ outcome: CleanItemOutcome) -> Bool {
        guard isRetryable(outcome) else { return false }
        guard case .failed(let failure) = outcome else { return true }
        return UninstallFailureReason(failure)?.retryMayHelp ?? true
    }

    /// "Retry unfinished" only once the application itself is gone (moved and
    /// still restorable, or moved by an earlier receipt), or when the
    /// application was refused in place for a reason a retry can overcome.
    /// An unknown or unrun application move, a restore, a receipt that failed
    /// to save, or nothing left worth retrying ends it.
    static func canRetryUninstall(_ result: CleanReport, applicationPath: String,
                                  applicationAlreadyMoved: Bool) -> Bool {
        guard result.persistenceFailure == nil,
              result.items.contains(where: { isWorthRetrying($0.outcome) }) else { return false }
        guard let row = result.items.first(where: { $0.sourcePath == applicationPath }) else {
            return applicationAlreadyMoved
        }
        switch row.outcome {
        case .moved: return result.restorableReceipts.contains { $0.originalPath == applicationPath }
        case .failed: return isWorthRetrying(row.outcome)
        case .notProcessed, .skipped, .deleted: return false
        }
    }

    static func canInspectResiduals(_ report: CleanReport) -> Bool {
        report.rulesVersion == "uninstall.selection.v1" && report.persistenceFailure == nil
            && report.restorableReceipts.contains { $0.originalPath.hasSuffix(".app") }
    }

    static func residualReview(_ report: CleanReport, inventory: [InstalledAppItem], complete: Bool,
                               homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> (InstalledAppItem, CleanupMoveReceipt) {
        guard canInspectResiduals(report),
              let receipt = report.restorableReceipts.first(where: { $0.originalPath.hasSuffix(".app") }),
              let identity = receipt.movedIdentity,
              try FoundationReadOnlyFileSystem().snapshot(at: receipt.resultingItemURL).identity == identity,
              !PathSafety.containsSymbolicLinkComponent(in: receipt.resultingItemURL.path),
              let info = NSDictionary(contentsOf: receipt.resultingItemURL.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String,
              UninstallOwnershipVerifier.canResumeResiduals(bundleID: bundleID, inventory: inventory, complete: complete) else {
            throw AppUninstallError.identityChanged("uninstall-receipt")
        }
        do {
            _ = try FoundationReadOnlyFileSystem().snapshot(at: URL(fileURLWithPath: receipt.originalPath))
            throw AppUninstallError.identityChanged(receipt.originalPath)
        } catch CleanupFileSystemError.vanished { }
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
            ?? URL(fileURLWithPath: receipt.originalPath).deletingPathExtension().lastPathComponent
        // Verify the actual, identity-bound app in Trash. An old receipt or a
        // bundle ID alone never promotes newly discovered data into a delete plan.
        let archived = InstalledAppItem(id: receipt.originalPath, name: name, bundleIdentifier: bundleID,
            path: receipt.resultingItemURL.path, version: version, build: build, category: "", appDescription: "",
            sizeBytes: 0, source: "receipt", modifiedAt: nil, scanIdentity: identity,
            relatedPaths: [], relatedItems: [], status: .installed)
        let prepared = UninstallOwnershipVerifier.prepare(archived, inventory: inventory + [archived], complete: complete, homeDirectory: homeDirectory)
        let app = InstalledAppItem(id: receipt.originalPath, name: name, bundleIdentifier: bundleID,
            path: receipt.originalPath, version: version, build: build, category: "", appDescription: "",
            sizeBytes: 0, source: "receipt", modifiedAt: nil, scanIdentity: identity,
            relatedPaths: prepared.relatedPaths, relatedItems: prepared.relatedItems, status: .installed)
        return (app, receipt)
    }
}

/// One uninstall review: the saved receipts (the original run, then each
/// retry) and a by-path display of them. The display is not a receipt: it
/// has its own identity and rules marker, and is never saved, restored or
/// used for a leftover check; those use `receipts`.
struct UninstallReviewResult: Equatable, Sendable {
    static let displayRulesVersion = "uninstall.review.display.v1"
    /// Saved receipts, oldest first. Restore and leftover checks use these.
    let receipts: [CleanReport]
    /// One row per path, the latest run's row winning; includes a running retry.
    let display: CleanReport

    init?(receipts: [CleanReport], inFlight: CleanReport? = nil) {
        let runs = receipts + (inFlight.map { [$0] } ?? [])
        guard let first = runs.first, let last = runs.last else { return nil }
        self.receipts = receipts
        var order: [String] = []
        var latest: [String: CleanReportItem] = [:]
        for item in runs.flatMap(\.items) {
            if latest.updateValue(item, forKey: item.sourcePath) == nil { order.append(item.sourcePath) }
        }
        let items = order.compactMap { latest[$0] }
        var moved = 0, skipped = 0, failed = 0, pending = 0, unverified = 0
        var movedBytes: Int64 = 0
        for item in items {
            switch item.outcome {
            case .moved(let receipt):
                moved += 1
                movedBytes += max(0, item.estimatedBytes)
                if !receipt.isRestorable { unverified += 1 }
            case .skipped: skipped += 1
            case .failed: failed += 1
            case .notProcessed: pending += 1
            // Uninstall only moves to Trash; a deletion row never occurs here.
            case .deleted: break
            }
        }
        let persistenceFailure = runs.lazy.compactMap(\.persistenceFailure).first
        let outcome: CleanReportOutcome = last.outcome == .cancelled ? .cancelled
            : failed + pending + unverified == 0 && persistenceFailure == nil ? .completed
            : moved > 0 ? .partiallyCompleted : .failed
        let attempts = runs.flatMap { $0.recoveryAttempts ?? [] }.sorted { $0.completedAt < $1.completedAt }
        display = CleanReport(id: UUID(), planID: CleanPlanID(), sessionID: ScanSessionID(),
            rulesVersion: Self.displayRulesVersion, disposition: first.disposition,
            scanWasPartial: runs.contains(where: \.scanWasPartial), startedAt: first.startedAt,
            completedAt: last.completedAt, outcome: outcome, items: items,
            summary: CleanReportSummary(requestedItemCount: items.count, movedItemCount: moved,
                skippedItemCount: skipped, failedItemCount: failed, notProcessedItemCount: pending,
                unverifiedMoveCount: unverified, plannedBytes: items.reduce(0) { $0 + max(0, $1.estimatedBytes) },
                movedToRecoverableLocationBytes: movedBytes, reclaimableAfterEmptyingTrashBytes: movedBytes,
                permanentlyFreedBytes: 0, availableSpaceDeltaBytes: nil),
            persistenceFailure: persistenceFailure,
            recoveryAttempts: attempts.isEmpty ? nil : attempts,
            restoreAuthorizations: runs.reduce(into: [String: CleanupRestoreAuthorization]()) {
                $0.merge($1.restoreAuthorizations ?? [:]) { _, newer in newer }
            },
            uninstallOwnership: runs.reduce(into: [String: UninstallOwnershipEvidence]()) {
                $0.merge($1.uninstallOwnership ?? [:]) { _, newer in newer }
            })
    }

    /// Whether any saved receipt still has something to restore.
    var canRestore: Bool { receipts.contains { !$0.restorableReceipts.isEmpty } }
    /// The saved receipt that moved the application, for a leftover check.
    var residualReceipt: CleanReport? { receipts.last(where: AppUninstallService.canInspectResiduals) }
}

/// Why an uninstall row did not move, read from the diagnostic codes its
/// receipt recorded (RecordedTrashOperation records every pre-move check
/// failure as trashMoveRejected). The receipt is unchanged; this only picks
/// the wording and whether "Retry unfinished" can help.
enum UninstallFailureReason: Equatable, Sendable {
    /// No password was requested (see `UninstallAuthorizationDecision`).
    case systemRefused, unsupportedLocation, protectedApp, locked
    /// The administrator authorization did not finish (approval, cancel, denial, helper error).
    case authorizationIncomplete
    /// This build's helper is missing or untrusted.
    case helperUnavailable
    /// Changed since the scan (identity, version) or the app was running.
    case changedSinceScan
    /// Related files wait for a confirmed move of the application.
    case applicationNotConfirmed
    case missing
    /// The task's lease ended before the move.
    case interrupted
    /// macOS refused the move and no authorization decision applied.
    case refused
    case other

    init?(_ failure: CleanFailure) {
        guard failure.code == .trashMoveRejected else { return nil }
        let detail = failure.detailCode ?? ""
        let outer = detail.components(separatedBy: " > ").first ?? detail
        func code(_ error: Error) -> String { let value = error as NSError; return "\(value.domain):\(value.code)" }
        let notOffered = UninstallAuthorizationDecision.notOfferedDomainPrefix
        if outer.hasPrefix(notOffered) {
            switch outer.dropFirst(notOffered.count).prefix(while: { $0 != ":" }) {
            case "system-refused": self = .systemRefused
            case "location": self = .unsupportedLocation
            case "protected-app": self = .protectedApp
            case "locked": self = .locked
            default: self = .other
            }
        } else if outer.hasPrefix("UninstallAuthorization.") {
            self = detail.contains("helper-unavailable") ? .helperUnavailable : .authorizationIncomplete
        } else if outer == code(AppUninstallError.identityChanged("")) {
            self = .changedSinceScan
        } else if outer == code(AppUninstallError.moveNotVerified("")) {
            self = .applicationNotConfirmed
        } else if outer == code(AppUninstallError.missingApp("")) || outer == code(CleanupFileSystemError.vanished) {
            self = .missing
        } else if outer.hasPrefix((HeavyWorkCoordinator.Error.invalidLease(expectedOwner: .cleanup) as NSError).domain + ":") {
            self = .interrupted
        } else if [code(CocoaError(.fileWriteNoPermission)), code(POSIXError(.EACCES)), code(POSIXError(.EPERM))].contains(outer) {
            self = .refused
        } else {
            self = .other
        }
    }

    /// False when a retry cannot change the outcome: the helper never accepts
    /// it, it needs a rescan, the application move is unconfirmed or the item
    /// is gone. Hides "Retry unfinished"; the receipt is not changed.
    var retryMayHelp: Bool {
        switch self {
        case .unsupportedLocation, .protectedApp, .helperUnavailable,
             .changedSinceScan, .applicationNotConfirmed, .missing: false
        case .systemRefused, .locked, .authorizationIncomplete, .interrupted, .refused, .other: true
        }
    }
}

/// Whether a native refusal to move the application is worth an
/// administrator password. The privileged helper only overrides Unix file
/// permissions, for paths and bundles its own policy accepts; it refuses
/// locked or system-protected bundles, and App Management (TCC) refuses it
/// the same way as this app. Asking in those cases only wastes a password.
enum UninstallAuthorizationDecision: Equatable, Sendable {
    /// All of: POSIX EACCES/EPERM or a lone Cocoa 513; the bundle or its folder
    /// is really not writable for this user; the helper's policy accepts the
    /// request; and the bundle carries no lock or system-protection flag.
    case offer
    /// Not a permission refusal; the original error is kept as is.
    case notRefused
    /// The bundle and its folder are writable (or the refusal is not a
    /// permission code): a system policy refused the move. App Management is
    /// one possible cause, so the guidance names it without asserting it.
    case systemRefused
    /// The helper accepts only direct children of /Applications and ~/Applications.
    case unsupportedLocation
    /// The helper never moves Apple's apps, this app, or bundles without an
    /// identifier, nor bundles with a system-protection flag.
    case protectedApp
    /// The bundle is locked (uchg); unlocking it in Finder's Get Info helps.
    case locked

    static func evaluate(_ error: Error, applicationPath: String,
                         isWritable: (String) -> Bool,
                         protection: (String) -> UninstallBundleProtection,
                         helperVerdict: () -> UninstallHelperVerdict) -> Self {
        guard UninstallErrorEvidence.isPermissionDenied(error) else { return .notRefused }
        // 1. A POSIX permission code, or the lone Cocoa 513 a field receipt
        //    showed for an installer-owned app. Other codes (read-only volume…)
        //    are not something administrator rights can fix.
        guard UninstallErrorEvidence.hasPOSIXPermissionDenial(error)
                || UninstallErrorEvidence.isLoneWriteRefusal(error) else { return .systemRefused }
        // 2. Moving a bundle to another folder writes its parent folder and the
        //    bundle itself (its ".." entry); one of them must really be
        //    read-only for this user, or file permissions are not the obstacle.
        let parent = URL(fileURLWithPath: applicationPath).deletingLastPathComponent().path
        guard !isWritable(parent) || !isWritable(applicationPath) else { return .systemRefused }
        // 3. The helper's own path and bundle policy.
        switch helperVerdict() {
        case .accepts: break
        case .rejectsBundle: return .protectedApp
        case .rejectsLocation: return .unsupportedLocation
        }
        // 4. The helper refuses locked and system-protected bundles.
        switch protection(applicationPath) {
        case .none: return .offer
        case .userLocked: return .locked
        case .systemProtected: return .protectedApp
        }
    }

    /// Diagnostic recorded with the native codes, so the result can explain
    /// why no password was requested. The refusal codes stay in the chain.
    func notOfferedError(wrapping nativeError: Error) -> NSError? {
        let reason: String
        switch self {
        case .offer, .notRefused: return nil
        case .systemRefused: reason = "system-refused"
        case .unsupportedLocation: reason = "location"
        case .protectedApp: reason = "protected-app"
        case .locked: reason = "locked"
        }
        return NSError(domain: Self.notOfferedDomainPrefix + reason, code: 1,
                       userInfo: [NSUnderlyingErrorKey: nativeError as NSError])
    }

    static let notOfferedDomainPrefix = "UninstallAuthorization.not-offered."
}

/// The lock flags the helper checks before it moves a bundle; D101 G4-2:
/// both read them with `FileProtectionFlags`.
enum UninstallBundleProtection: Equatable, Sendable {
    case none
    /// An owner flag: "Locked" in Finder's Get Info (UF_IMMUTABLE) or
    /// append-only (UF_APPEND).
    case userLocked
    /// A system flag (SF_IMMUTABLE, SF_APPEND, SF_RESTRICTED, SF_NOUNLINK):
    /// only the system can lift them.
    case systemProtected

    /// lstat, like the helper: the bundle itself, never a link target.
    static func of(_ path: String) -> Self {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .none }
        switch FileProtectionFlags.lock(info.st_flags) {
        case .none: return .none
        case .owner: return .userLocked
        case .system: return .systemProtected
        }
    }
}

/// The helper's own policy (`FileOperationPathPolicy`) applied to the exact request.
enum UninstallHelperVerdict: Equatable, Sendable {
    case accepts, rejectsBundle, rejectsLocation
}

/// How an uninstall moves files: the native recycler, then (only when the
/// decision allows it) the privileged helper. Injectable so store tests use
/// an isolated Trash and never reach the helper.
struct UninstallMoveEnvironment: Sendable {
    var recycle: @Sendable (URL) async throws -> URL
    var authorization: UninstallAuthorizationEnvironment

    static let live = UninstallMoveEnvironment(recycle: { try await NativeApplicationRecycler.recycle($0) },
                                               authorization: .live)
}

/// Inputs of the authorization path, injectable so fixtures never depend on
/// real folder permissions or flags, or reach the privileged helper.
struct UninstallAuthorizationEnvironment: Sendable {
    var helperVerdict: @Sendable (InstalledAppItem, FileIdentity, UUID) -> UninstallHelperVerdict
    var isWritable: @Sendable (String) -> Bool
    var protection: @Sendable (String) -> UninstallBundleProtection
    var move: @Sendable (InstalledAppItem, FileIdentity, UUID,
                         @escaping @Sendable () async throws -> Void) async throws -> URL

    static let live = UninstallAuthorizationEnvironment(
        helperVerdict: { app, identity, sessionID in
            AuthorizedApplicationMover.helperVerdict(
                AuthorizedApplicationMover.request(for: app, identity: identity, sessionID: sessionID))
        },
        isWritable: { access($0, W_OK) == 0 },
        protection: { UninstallBundleProtection.of($0) },
        move: { app, identity, sessionID, beforeMove in
            try await AuthorizedApplicationMover.shared.move(app: app, identity: identity,
                                                              sessionID: sessionID, beforeMove: beforeMove)
        })
}

/// Keep the worker's stage and OSStatus; an EACCES during rename is not a
/// rejected authorization prompt. Append (rather than overwrite) native evidence.
enum UninstallAuthorizationFailure {
    static func wrap(_ error: Error, nativeError: Error) -> NSError {
        let value = error as NSError
        let reason: String
        switch error {
        case AuthorizedMoveError.approvalRequired: reason = "approval-required"
        case AuthorizedMoveError.unavailable: reason = "helper-unavailable"
        case is CancellationError: reason = "authorization-cancelled"
        default:
            if value.domain.hasPrefix("FileOperationHelper.") { reason = "helper-failed" }
            else if value.domain == NSOSStatusErrorDomain && value.code == Int(errAuthorizationCanceled) { reason = "authorization-cancelled" }
            else if value.domain == NSOSStatusErrorDomain && value.code == Int(errAuthorizationDenied) { reason = "authorization-denied" }
            else { reason = "authorization-failed" }
        }
        func append(_ current: NSError, depth: Int) -> NSError {
            var info = current.userInfo
            if let child = info[NSUnderlyingErrorKey] as? NSError, depth < 6 {
                info[NSUnderlyingErrorKey] = append(child, depth: depth + 1)
            } else if info[NSUnderlyingErrorKey] == nil { info[NSUnderlyingErrorKey] = nativeError }
            return NSError(domain: current.domain, code: current.code, userInfo: info)
        }
        return NSError(domain: "UninstallAuthorization." + reason, code: 1,
                       userInfo: [NSUnderlyingErrorKey: append(value, depth: 0)])
    }
}
