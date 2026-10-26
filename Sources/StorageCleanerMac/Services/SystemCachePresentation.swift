import FileOperationShared
import Foundation

extension SystemCacheID {
    var title: String {
        switch self {
        case .coreSymbolication: L10n.text("系统符号缓存", "System Symbol Cache")
        case .iconServices: L10n.text("图标缓存", "Icon Cache")
        }
    }
    var explanation: String {
        switch self {
        case .coreSymbolication:
            L10n.text("系统会自动重建符号缓存。删除后不能撤销。", "The system rebuilds symbol caches automatically. Deletion cannot be undone.")
        case .iconServices:
            L10n.text("系统会自动重建图标缓存。删除后不能撤销；可能需要重启或重新登录，图标才恢复正常。",
                      "The system rebuilds icon caches automatically. Deletion cannot be undone; icons may need a restart or signing in again to return to normal.")
        }
    }
}

struct SystemCacheClearPlan: Identifiable, Equatable, Sendable {
    let id = UUID()
    let items: [SystemCacheInventoryItem]
    var directories: [SystemCacheDirectoryIdentity] { items.compactMap(\.identity) }
    var facts: OperationConfirmationFacts {
        let bytes = CleanupByteCount.sum(items.compactMap(\.allocatedBytes))
        return OperationConfirmationFacts(surface: .safeCleanup, actions: [.permanentDeletion],
            items: items.map { .init(id: $0.cache.rawValue, title: $0.cache.title, path: nil,
                                     bytes: $0.allocatedBytes, detail: $0.cache.explanation) },
            localBytes: bytes, bytesAreLowerBound: items.contains { $0.failure != nil },
            permanentDeletionBytes: bytes, recovery: [.notRecoverable], permission: .notRequired,
            objectWarnings: [L10n.text("需要管理员密码。只清除所选缓存文件夹里的内容，系统会自动重建。",
                                      "Requires an administrator password. Only the contents of the selected cache folders are cleared; the system rebuilds them.")])
    }
}

enum SystemCachePresentation {
    static func bytes(_ inventory: SystemCacheInventoryReply?) -> Int64 {
        CleanupByteCount.sum(inventory?.items.compactMap(\.allocatedBytes) ?? [])
    }
    static func isSelectable(_ item: SystemCacheInventoryItem) -> Bool {
        item.identity != nil && item.allocatedBytes != nil
    }
    static func result(_ reply: SystemCacheClearReply) -> String {
        let count = ByteFormat.count(reply.items.reduce(0) { $0 + $1.deletedEntries })
        let bytes = ByteFormat.storageString(CleanupByteCount.sum(reply.items.map(\.freedBytes)))
        let skipped = ByteFormat.count(reply.items.reduce(0) { $0 + $1.skippedEntries })
        let summary = L10n.text("已删除 \(count) 项系统缓存，约腾出 \(bytes)。",
                                "Deleted \(count) system cache entries, freeing approximately \(bytes).")
        let partial = reply.items.contains { $0.failure != nil || $0.skippedEntries > 0 }
            ? L10n.text("跳过 \(skipped) 项，部分缓存未清除。", "Skipped \(skipped) entries; some caches were not cleared.") : ""
        return [summary, partial, L10n.text("系统仍占用的已删除文件，要等其关闭后才释放空间。",
            "Space held by deleted files still open in the system is released when they close.")]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
