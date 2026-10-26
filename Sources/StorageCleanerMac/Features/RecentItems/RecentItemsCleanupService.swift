import Foundation

struct RecentItemsCleanupEnvironment: Sendable {
    let scanner: RecentItemsScanner
    var journal: CleanupReportJournal = .live
    /// nil uses RecordedTrashOperation's existing native Trash route.
    var moveToTrash: (@Sendable (URL) throws -> URL)? = nil
    var processController = RecentItemsProcessController()
    var waitForWriteback: @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(2)) }
}

struct RecentItemsCleanupResult: Sendable {
    enum Verification: Equatable, Sendable { case cleared, writtenBack, unknown, notMoved }
    let report: CleanReport
    let restart: RecentItemsProcessController.Result?
    let verification: [String: Verification]
    let snapshot: RecentItemsSnapshot
}

enum RecentItemsCleanupService {
    static let ruleID = "privacy.recent-items.trash.v1"

    /// Even the injected services are untouched without both explicit
    /// confirmation and a nonempty selection. The review's file identities
    /// stay frozen; new or changed files are never added to the operation.
    static func clean(selected: [RecentItemsList], confirmed: Bool,
                      environment: RecentItemsCleanupEnvironment,
                      coordinator: HeavyWorkCoordinator) async throws -> RecentItemsCleanupResult? {
        guard confirmed, !selected.isEmpty else { return nil }
        let allowed = selected.filter { environment.scanner.classification(of: $0.url) != nil }
        var paths: Set<String> = []
        let lists = allowed.filter { paths.insert($0.id).inserted }
        guard !lists.isEmpty else { return nil }
        try Task.checkCancellation()
        return try await coordinator.withLease(owner: .cleanup) { _ in
            // Once confirmed, drain the moves and write their receipts even
            // if the presenting view disappears. The lease covers readback too.
            await Task.detached(priority: .userInitiated) {
                let metadata = FoundationReadOnlyFileSystem()
                let byPath = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0) })
                let items = lists.map {
                    RecordedTrashOperation.Item(path: $0.id, bytes: $0.file.logicalSizeBytes,
                        identity: $0.file.identity, allowedRestoreRoot: environment.scanner.rootURL)
                }
                let validate: (RecordedTrashOperation.Item) throws -> Void = { item in
                    let url = URL(fileURLWithPath: item.path)
                    guard environment.scanner.classification(of: url) != nil, let expected = byPath[item.path] else {
                        throw RecordedTrashOperation.Skip(reason: .preflightNotApproved)
                    }
                    let current = try metadata.snapshot(at: url)
                    guard current.identity.entryKind == .regularFile, !current.hasSymbolicLinkComponent,
                          current.identity == expected.file.identity,
                          current.logicalSizeBytes == expected.file.logicalSizeBytes,
                          current.modificationTimeNanoseconds == expected.file.modificationTimeNanoseconds else {
                        throw RecordedTrashOperation.Skip(reason: .preflightNotApproved)
                    }
                }
                let persist: RecordedTrashOperation.Persistence = {
                    try environment.journal.checkpoint($0, expectedIdentities: $1)
                }
                let report: CleanReport
                if let move = environment.moveToTrash {
                    report = RecordedTrashOperation.run(items: items, ruleID: ruleID, validate: validate,
                                                        move: move, persist: persist)
                } else {
                    report = RecordedTrashOperation.run(items: items, ruleID: ruleID, validate: validate, persist: persist)
                }
                let restart: RecentItemsProcessController.Result?
                if report.summary.movedItemCount > 0 {
                    restart = environment.processController.restart()
                    await environment.waitForWriteback()
                } else { restart = nil }
                // One readback supplies both verification and the refreshed
                // page. A missing row needs positive absence evidence below.
                let snapshot = environment.scanner.scan()
                let currentLists = Dictionary(uniqueKeysWithValues: snapshot.lists.map { ($0.id, $0) })
                var verification: [String: RecentItemsCleanupResult.Verification] = [:]
                for row in report.items {
                    guard case .moved = row.outcome else { verification[row.sourcePath] = .notMoved; continue }
                    if let list = currentLists[row.sourcePath] {
                        verification[row.sourcePath] = list.entryCount.map { $0 == 0 ? .cleared : .writtenBack } ?? .unknown
                    } else {
                        verification[row.sourcePath] = environment.scanner.isAbsentWithoutLinks(URL(fileURLWithPath: row.sourcePath)) ? .cleared : .unknown
                    }
                }
                return RecentItemsCleanupResult(report: report, restart: restart, verification: verification,
                                                snapshot: snapshot)
            }.value
        }
    }
}
