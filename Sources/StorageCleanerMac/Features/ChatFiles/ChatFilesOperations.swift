import AppKit
import Darwin
import Foundation

struct ChatFilesEnvironment: Sendable {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var runningBundleIdentifiers: @Sendable () async -> Set<String> = {
        await MainActor.run { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
    }
    var moveToTrash: @Sendable (URL) throws -> URL = { source in
        var target: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &target)
        guard let target = target as URL? else { throw CleanupMoveError.invalidResult }
        return target
    }
    var metadata: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem()
    var persist: @Sendable (CleanReport, [String: FileIdentity]) throws -> Void = {
        try CleanupReportJournal.live.checkpoint($0, expectedIdentities: $1)
    }
    var digest: @Sendable (URL) throws -> Data = { try GuardedFileContentReader(priority: .userInitiated).sha256($0) }
}

struct ChatFilesTrashOutcome: Equatable, Sendable {
    var movedRowIDs: [String] = []
    var movedBytes: Int64 = 0
    var keptNotes: [String] = []
    var receiptWritten = true
}

/// D-FP3: moves chosen months of chat files to the Trash through the
/// recorded operation, so each folder can be put back. Never preselected;
/// the chat app must be closed, and each folder must still be the one the
/// scan saw, inside that app's own container.
enum ChatFilesTrashService {
    static let ruleID = "chat-files.trash.v1"

    static func execute(_ rows: [ChatFilesRow], environment: ChatFilesEnvironment = .init(),
                        beforeEachMove: @escaping @Sendable () async throws -> Void = {}) async -> ChatFilesTrashOutcome {
        var outcome = ChatFilesTrashOutcome()
        var owners: [String: ChatFilesRow] = [:]
        var items: [RecordedTrashOperation.Item] = []
        for row in rows {
            for folder in row.folders where owners[folder.path] == nil {
                guard let identity = folder.identity else {
                    outcome.keptNotes.append(L10n.text("\(row.title)：扫描时没能确认文件，已保留", "\(row.title): could not be confirmed during the scan; kept"))
                    continue
                }
                owners[folder.path] = row
                items.append(.init(path: folder.path, bytes: 0, identity: identity,
                                   allowedRestoreRoot: URL(fileURLWithPath: folder.path).deletingLastPathComponent()))
            }
        }
        // Each folder's share of its row's bytes, for the receipt.
        let shares = Dictionary(grouping: items, by: { owners[$0.path]?.id ?? "" }).mapValues { $0.count }
        items = items.map { item in
            let row = owners[item.path]
            let share = row.map { $0.bytes / Int64(max(1, shares[$0.id] ?? 1)) } ?? 0
            return .init(path: item.path, bytes: share, identity: item.identity, allowedRestoreRoot: item.allowedRestoreRoot)
        }
        let selected = owners
        let report = await RecordedTrashOperation.runAsync(
            items: items, ruleID: ruleID,
            validate: { item in
                try await beforeEachMove()
                guard let row = selected[item.path] else { throw RecordedTrashOperation.Skip(reason: .preflightNotApproved) }
                let container = environment.home.appendingPathComponent(row.app.containerRoot).path
                guard PathSafety.isContained(item.path, in: container, resolvingSymlinks: false),
                      item.path != PathSafety.lexicalPath(container),
                      !ProtectedLocations.protects(path: item.path, homePath: PathSafety.lexicalPath(environment.home.path)) else {
                    throw RecordedTrashOperation.Skip(reason: .pathOutsideAllowedRoot)
                }
                if await environment.runningBundleIdentifiers().contains(row.app.bundleIdentifier) {
                    throw RecordedTrashOperation.Skip(reason: .relatedAppStillRunning)
                }
            },
            move: { try environment.moveToTrash($0) },
            metadata: environment.metadata,
            persist: environment.persist
        )
        outcome.receiptWritten = report.persistenceFailure == nil
        var movedRows = Set<String>()
        var keptRows = Set<String>()
        for row in report.items {
            guard let owner = selected[row.sourcePath] else { continue }
            switch row.outcome {
            case .moved:
                movedRows.insert(owner.id)
                outcome.movedBytes += max(0, row.estimatedBytes)
            case .skipped(.relatedAppStillRunning):
                keptRows.insert(owner.id)
                outcome.keptNotes.append(L10n.text("\(owner.app.title)正在运行，请先退出", "\(owner.app.title) is open; quit it first"))
            default:
                keptRows.insert(owner.id)
            }
        }
        outcome.movedRowIDs = rows.map(\.id).filter { movedRows.contains($0) && !keptRows.contains($0) }
        if !keptRows.isEmpty, outcome.keptNotes.isEmpty {
            outcome.keptNotes.append(L10n.text("有些文件夹扫描后有变化，已保留", "Some folders changed since the scan and were kept"))
        }
        var seen = Set<String>()
        outcome.keptNotes = outcome.keptNotes.filter { seen.insert($0).inserted }
        return outcome
    }
}
