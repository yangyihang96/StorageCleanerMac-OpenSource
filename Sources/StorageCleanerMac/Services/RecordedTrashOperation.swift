import Foundation
import Darwin

/// Both paths use the existing operation history. Async cancellation drains the
/// native callback before the lease owner can return; no semaphore or timeout
/// can abandon a move whose outcome has not been recorded.
enum RecordedTrashOperation {
    struct Item: Sendable {
        let path: String
        let bytes: Int64
        let identity: FileIdentity?
        var allowedRestoreRoot: URL? = nil
    }
    typealias Persistence = (CleanReport, [String: FileIdentity]) throws -> Void

    /// Thrown by `validate` before the move: the item is recorded as
    /// skipped with this reason (kept in place), not as a refused move.
    struct Skip: Error, Equatable, Sendable {
        let reason: CleanSkipReason
    }

    static func run(items: [Item], ruleID: String, validate: (Item) throws -> Void,
                    move: (URL) throws -> URL = { source in
                        var target: NSURL?
                        try FileManager.default.trashItem(at: source, resultingItemURL: &target)
                        guard let target = target as URL? else { throw CleanupMoveError.invalidResult }
                        return target
                    }, metadata: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem(),
                    persist: Persistence = { try CleanupReportJournal.live.checkpoint($0, expectedIdentities: $1) }) -> CleanReport {
        let state = Recording(items: items, ruleID: ruleID, metadata: metadata)
        guard state.checkpoint(persist, failure: "intent-write-failed") else { return state.report() }
        for (index, item) in items.enumerated() {
            if Task.isCancelled { state.cancelled = true; break }
            var invokedMove = false
            do {
                try validate(item); try state.validate(item)
                state.markInFlight(index)
                guard state.checkpoint(persist, failure: "intent-write-failed") else {
                    state.outcomes[index] = .notProcessed; break
                }
                try Task.checkCancellation()
                try validate(item); try state.validate(item)
                invokedMove = true
                try state.recordTarget(try move(URL(fileURLWithPath: item.path)), item: item, index: index)
            } catch { state.recordError(error, item: item, index: index, invokedMove: invokedMove) }
            guard state.checkpoint(persist, failure: "result-write-failed") else { break }
        }
        _ = state.checkpoint(persist, failure: "final-write-failed")
        return state.report()
    }

    static func runAsync(items: [Item], ruleID: String,
                         validate: (Item) async throws -> Void,
                         move: (URL) async throws -> URL,
                         requiresFirstSuccess: Bool = false,
                         metadata: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem(),
                         persist: Persistence = { try CleanupReportJournal.live.checkpoint($0, expectedIdentities: $1) },
                         progress: (CleanReport) async -> Void = { _ in },
                         prepare: ((Item) async throws -> Void)? = nil) async -> CleanReport {
        let state = Recording(items: items, ruleID: ruleID, metadata: metadata)
        guard state.checkpoint(persist, failure: "intent-write-failed") else { return state.report() }
        for (index, item) in items.enumerated() {
            if Task.isCancelled { state.cancelled = true; break }
            if requiresFirstSuccess && index > 0 {
                guard case .moved(let receipt) = state.outcomes[0], receipt.isRestorable else { break }
            }
            var invokedMove = false
            do {
                // D184: a bundle swap must have a durable in-flight intent before it happens.
                // Existing callers omit this hook and retain their original validation order.
                if let prepare {
                    state.markInFlight(index)
                    guard state.checkpoint(persist, failure: "intent-write-failed") else { break }
                    try Task.checkCancellation()
                    try await prepare(item)
                }
                try await validate(item); try state.validate(item)
                state.markInFlight(index)
                guard state.checkpoint(persist, failure: "intent-write-failed") else {
                    state.outcomes[index] = .notProcessed; break
                }
                await progress(state.report())
                // Awaited lease/authorization checks precede the final identity check.
                try await validate(item)
                try Task.checkCancellation(); try state.validate(item)
                invokedMove = true
                let target = try await move(URL(fileURLWithPath: item.path))
                // Do not throw for cancellation here: an actual move still needs its receipt.
                try state.recordTarget(target, item: item, index: index)
            } catch { state.recordError(error, item: item, index: index, invokedMove: invokedMove) }
            guard state.checkpoint(persist, failure: "result-write-failed") else { break }
            await progress(state.report())
        }
        if Task.isCancelled { state.cancelled = true }
        _ = state.checkpoint(persist, failure: "final-write-failed")
        await progress(state.report())
        return state.report()
    }

    private final class Recording {
        let items: [Item]
        let ruleID: String
        let metadata: any ReadOnlyFileSystem
        init(items: [Item], ruleID: String, metadata: any ReadOnlyFileSystem) {
            self.items = items; self.ruleID = ruleID; self.metadata = metadata
            itemIDs = items.map { _ in UUID() }
            identities = Dictionary(items.compactMap { item in item.identity.map { (item.path, $0) } }, uniquingKeysWith: { a, _ in a })
            outcomes = Array(repeating: .notProcessed, count: items.count)
        }
        let planID = CleanPlanID()
        let sessionID = ScanSessionID()
        let reportID = UUID()
        let startedAt = Date()
        let itemIDs: [UUID]
        let identities: [String: FileIdentity]
        var outcomes: [CleanItemOutcome]
        var cancelled = false
        var persistenceFailure: String?
        func report() -> CleanReport {
            let rows = zip(items.indices, items).map { index, item in
                CleanReportItem(id: itemIDs[index], planItemID: itemIDs[index], ruleID: ruleID,
                    sourcePath: item.path, estimatedBytes: item.bytes, outcome: outcomes[index])
            }
            var moved = 0, failed = 0, skipped = 0, pending = 0, unverified = 0
            var bytes: Int64 = 0
            for row in rows {
                switch row.outcome {
                case .moved(let receipt):
                    moved += 1
                    bytes += max(0, row.estimatedBytes)
                    if !receipt.isRestorable { unverified += 1 }
                case .failed: failed += 1
                case .skipped: skipped += 1
                case .notProcessed: pending += 1
                // This path only moves to Trash; deletions never occur here.
                case .deleted: break
                }
            }
            let outcome: CleanReportOutcome = cancelled ? .cancelled :
                (failed + pending + unverified == 0 && persistenceFailure == nil ? .completed :
                    (moved > 0 ? .partiallyCompleted : .failed))
            return CleanReport(id: reportID, planID: planID, sessionID: sessionID,
                rulesVersion: ruleID, disposition: .trash, scanWasPartial: false,
                startedAt: startedAt, completedAt: Date(), outcome: outcome, items: rows,
                summary: CleanReportSummary(requestedItemCount: items.count, movedItemCount: moved,
                    skippedItemCount: skipped, failedItemCount: failed, notProcessedItemCount: pending,
                    unverifiedMoveCount: unverified, plannedBytes: items.reduce(0) { $0 + max(0, $1.bytes) },
                    movedToRecoverableLocationBytes: bytes, reclaimableAfterEmptyingTrashBytes: bytes,
                    permanentlyFreedBytes: 0, availableSpaceDeltaBytes: nil),
                persistenceFailure: persistenceFailure,
                restoreAuthorizations: Dictionary(uniqueKeysWithValues: items.indices.compactMap { index in
                    let item = items[index]
                    guard let root = item.allowedRestoreRoot, let identity = item.identity else { return nil }
                    return (item.path, CleanupRestoreAuthorization(sourcePath: item.path,
                        allowedRootPath: root.path, sourceIdentity: identity, ruleID: ruleID,
                        planItemID: itemIDs[index]))
                }))
        }

        func checkpoint(_ persist: Persistence, failure: String) -> Bool {
            do { try persist(report(), identities); return true }
            catch { if persistenceFailure == nil { persistenceFailure = failure }; return false }
        }
        func validate(_ item: Item) throws {
            guard let identity = item.identity else { throw AppUninstallError.identityChanged(item.path) }
            let current = try metadata.snapshot(at: URL(fileURLWithPath: item.path))
            guard current.identity == identity, !current.hasSymbolicLinkComponent else {
                throw AppUninstallError.identityChanged(item.path)
            }
        }
        func markInFlight(_ index: Int) {
            outcomes[index] = .failed(CleanFailure(code: .moveOutcomeUnknown, detailCode: "move-in-flight"))
        }
        func recordTarget(_ target: URL, item: Item, index: Int) throws {
            do {
                _ = try metadata.snapshot(at: URL(fileURLWithPath: item.path))
                // A replacement is a conflict too, not proof of removal.
                throw CleanupMoveError.invalidResult
            } catch CleanupFileSystemError.vanished {
                // Only positive absence evidence permits a moved result.
            }
            let moved = try? metadata.snapshot(at: target)
            let verification: CleanupMoveVerification = moved.map {
                $0.identity == item.identity && !$0.hasSymbolicLinkComponent ? .identityVerified : .identityMismatch
            } ?? .destinationMetadataUnavailable
            outcomes[index] = .moved(CleanupMoveReceipt(originalPath: item.path,
                resultingItemURL: target, disposition: .trash, movedIdentity: moved?.identity,
                verification: verification, movedAt: Date()))
        }
        func recordError(_ error: Error, item: Item, index: Int, invokedMove: Bool) {
            if !invokedMove, let skip = error as? Skip {
                outcomes[index] = .skipped(skip.reason)
                return
            }
            if error is CancellationError {
                cancelled = true
                outcomes[index] = invokedMove ? .failed(CleanFailure(code: .moveOutcomeUnknown,
                    detailCode: "cancelled-during-move")) : .notProcessed
                return
            }
            let unchanged = (try? metadata.snapshot(at: URL(fileURLWithPath: item.path)))
                .map { $0.identity == item.identity && !$0.hasSymbolicLinkComponent } ?? false
            outcomes[index] = .failed(CleanFailure(
                code: invokedMove && !(UninstallErrorEvidence.isPermissionDenied(error) && unchanged)
                    ? .moveOutcomeUnknown : .trashMoveRejected,
                detailCode: UninstallErrorEvidence.codes(error)))
        }
    }
}

enum UninstallErrorEvidence {
    static func chain(_ error: Error) -> [NSError] {
        var result: [NSError] = []; var current: NSError? = error as NSError
        while let item = current, result.count < 8,
              !result.contains(where: { $0 === item }) {
            result.append(item); current = item.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }
    static func codes(_ error: Error) -> String {
        // Preserve diagnostic codes, not paths or untrusted localized descriptions.
        chain(error).map { "\($0.domain):\($0.code)" }.joined(separator: " > ")
    }
    /// The system refused the move for a permission reason (Cocoa 513 or POSIX
    /// EACCES/EPERM). With the original unchanged this records "not moved"
    /// rather than an unknown outcome. It is not by itself a reason to ask
    /// for an administrator password: see `UninstallAuthorizationDecision`.
    static func isPermissionDenied(_ error: Error) -> Bool {
        chain(error).contains {
            ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteNoPermissionError)
            || ($0.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains($0.code))
        }
    }

    /// POSIX EACCES/EPERM in the chain.
    static func hasPOSIXPermissionDenial(_ error: Error) -> Bool {
        chain(error).contains { $0.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains($0.code) }
    }

    /// Cocoa 513 with nothing beneath it. A field receipt for an installer-owned
    /// /Applications app showed exactly this (docs/2.0.0/UNINSTALL-513-20260925.md);
    /// App Management (TCC) can report it too, so it never decides on its own.
    static func isLoneWriteRefusal(_ error: Error) -> Bool {
        let errors = chain(error)
        return !errors.isEmpty && errors.allSatisfy { $0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteNoPermissionError }
    }
}
