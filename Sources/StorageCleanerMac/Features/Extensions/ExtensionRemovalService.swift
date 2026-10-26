import AppKit
import Foundation

/// What moving extensions to the Trash needs from the system; tests replace
/// every part.
struct ExtensionRemovalEnvironment: Sendable {
    var roots: ExtensionInventoryScanner.Roots = .live
    var homePath: String = PathSafety.lexicalHomePath
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
}

struct ExtensionRemovalOutcome: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let path: String
        let name: String
        let note: String?
    }

    var removed: [Row] = []
    var removedBytes: Int64 = 0
    var kept: [Row] = []
    var failed: [Row] = []
    /// False when the receipt could not be written; the operation history
    /// then asks the user to check.
    var receiptWritten = true

    var title: String {
        if removed.isEmpty {
            return L10n.text("没有移动任何扩展", "No extensions were moved")
        }
        return L10n.text("已把 \(ByteFormat.count(removed.count)) 个扩展移到废纸篓", "Moved \(ByteFormat.count(removed.count)) extensions to the Trash")
    }
}

/// D-FP1: moves the chosen bundles of the user's own Library to the Trash
/// through the recorded operation every other flow uses, so each one can be
/// put back from Operation History. Each bundle is checked again right
/// before it moves: still a direct child of its folder, the same file, no
/// link on the way, and System Settings closed for a preference pane.
enum ExtensionRemovalService {
    static let ruleID = "extensions.trash.v1"
    static let systemSettingsBundleIdentifier = "com.apple.systempreferences"

    static func execute(
        _ items: [ExtensionItem],
        environment: ExtensionRemovalEnvironment = .init(),
        beforeEachMove: @escaping @Sendable () async throws -> Void = {}
    ) async -> ExtensionRemovalOutcome {
        var byPath: [String: ExtensionItem] = [:]
        for item in items where item.management.isMovable && item.identity != nil && byPath[item.path] == nil {
            byPath[item.path] = item
        }
        let ordered = items.compactMap { byPath[$0.path] }.reduce(into: [ExtensionItem]()) { list, item in
            if !list.contains(where: { $0.path == item.path }) { list.append(item) }
        }
        let selected = byPath
        let report = await RecordedTrashOperation.runAsync(
            items: ordered.map {
                RecordedTrashOperation.Item(path: $0.path, bytes: max(0, $0.bytes), identity: $0.identity,
                                            allowedRestoreRoot: URL(fileURLWithPath: $0.path).deletingLastPathComponent())
            },
            ruleID: ruleID,
            validate: { item in
                try await beforeEachMove()
                guard let selected = selected[item.path] else {
                    throw RecordedTrashOperation.Skip(reason: .preflightNotApproved)
                }
                guard isDirectChildOfOwnFolder(selected, environment: environment) else {
                    throw RecordedTrashOperation.Skip(reason: .pathOutsideAllowedRoot)
                }
                if selected.kind == .preferencePane,
                   await environment.runningBundleIdentifiers().contains(systemSettingsBundleIdentifier) {
                    throw RecordedTrashOperation.Skip(reason: .relatedAppStillRunning)
                }
            },
            move: { try environment.moveToTrash($0) },
            metadata: environment.metadata,
            persist: environment.persist
        )

        var outcome = ExtensionRemovalOutcome(receiptWritten: report.persistenceFailure == nil)
        for row in report.items {
            let name = selected[row.sourcePath]?.name ?? URL(fileURLWithPath: row.sourcePath).lastPathComponent
            switch row.outcome {
            case .moved:
                outcome.removed.append(.init(path: row.sourcePath, name: name, note: nil))
                outcome.removedBytes += max(0, row.estimatedBytes)
            case .skipped(let reason):
                outcome.kept.append(.init(path: row.sourcePath, name: name, note: describe(reason)))
            case .failed:
                outcome.failed.append(.init(path: row.sourcePath, name: name, note: L10n.text(
                    "未能移动，请在操作记录中核实", "Not moved; check it in Operation History")))
            case .notProcessed:
                outcome.kept.append(.init(path: row.sourcePath, name: name, note: L10n.text("未处理", "Not processed")))
            case .deleted:
                break
            }
        }
        // Rows that never reached the recorder (not movable here).
        for item in items where byPath[item.path] == nil && !outcome.kept.contains(where: { $0.path == item.path }) {
            outcome.kept.append(.init(path: item.path, name: item.name, note: item.management.note))
        }
        return outcome
    }

    /// The bundle must still sit directly in one of its kind's folders of the
    /// user's Library, reached without a link.
    static func isDirectChildOfOwnFolder(_ item: ExtensionItem, environment: ExtensionRemovalEnvironment) -> Bool {
        guard item.domain == .user, item.management.isMovable else { return false }
        let lexical = PathSafety.lexicalPath(item.path)
        guard lexical == item.path,
              !ProtectedLocations.protects(path: lexical, homePath: environment.homePath) else { return false }
        let parent = URL(fileURLWithPath: lexical).deletingLastPathComponent().path
        let library = PathSafety.lexicalPath(environment.roots.userLibrary.path)
        let allowed = item.kind.libraryFolders.contains { folder, extensions in
            PathSafety.lexicalPath(library + "/" + folder) == parent
                && extensions.contains(URL(fileURLWithPath: lexical).pathExtension.lowercased())
        }
        return allowed && !PathSafety.containsSymbolicLinkComponent(in: parent)
    }

    static func describe(_ reason: CleanSkipReason) -> String {
        switch reason {
        case .relatedAppStillRunning:
            L10n.text("“系统设置”正在运行，请先退出再移除偏好设置面板",
                      "System Settings is open; quit it before removing a preference pane")
        case .identityChanged, .entryKindChanged, .itemMissing, .symbolicLinkDetected:
            L10n.text("扫描后已变化或已不在，已保留", "Changed or gone since the scan; kept")
        case .pathOutsideAllowedRoot:
            L10n.text("不在可移除的位置，已保留", "Not in a location it can be removed from; kept")
        default:
            L10n.text("已保留", "Kept")
        }
    }
}
