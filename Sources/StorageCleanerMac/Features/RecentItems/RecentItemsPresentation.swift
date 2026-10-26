import Foundation

enum RecentItemsPresentation {
    static var title: String { L10n.text("最近使用项目", "Recent Items") }
    static var detail: String {
        L10n.text("清理这些列表，去掉最近打开过的文件、应用和服务器的记录",
                  "Clear these lists to remove records of recently opened files, apps and servers")
    }
    static func summary(_ snapshot: RecentItemsSnapshot) -> String {
        if snapshot.unknownListCount > 0 {
            return L10n.text("已读到 \(ByteFormat.count(snapshot.knownEntryCount)) 个最近使用项目，另有 \(ByteFormat.count(snapshot.unknownListCount)) 个列表条目数未知",
                             "Read \(ByteFormat.count(snapshot.knownEntryCount)) recent items; counts are unknown for \(ByteFormat.count(snapshot.unknownListCount)) lists")
        }
        return L10n.text("发现 \(ByteFormat.count(snapshot.knownEntryCount)) 个最近使用项目",
                         "Found \(ByteFormat.count(snapshot.knownEntryCount)) recent items")
    }
    static func title(for category: RecentItemsCategory) -> String {
        switch category {
        case .documents: L10n.text("最近的文稿", "Recent Documents")
        case .applications: L10n.text("最近的应用", "Recent Applications")
        case .servers: L10n.text("最近的服务器", "Recent Servers")
        case .applicationDocuments: L10n.text("各应用的最近文稿", "Recent Documents by App")
        }
    }
    static func count(_ value: Int?) -> String {
        value.map { L10n.text("\(ByteFormat.count($0)) 个项目", "\(ByteFormat.count($0)) items") }
            ?? L10n.text("条目数未知", "Item count unknown")
    }
    static var confirmationNotes: [String] {
        [L10n.text("只把勾选的最近使用列表移到废纸篓，可从“操作记录”放回；原文件和应用不会被移走。放回时若系统已重建同名列表，会提示冲突并保留新列表。",
                    "Only checked recent-item lists move to Trash and can be restored from Operation History. Documents and apps stay in place. If the system recreates a list, restoring reports a conflict and preserves the new list."),
         L10n.text("移完后会让系统的最近项目服务重启一下，等待两秒后检查列表。",
                    "After the move, the system's recent-items service will restart briefly. Lists are checked after two seconds."),
         L10n.text("访达边栏和收藏不受影响。建议先退出对应应用，否则它们可能马上把列表写回。",
                    "Finder's sidebar and favorites are unaffected. Quit the corresponding apps first; running apps may immediately write their lists back.")]
    }
    static func verification(_ value: RecentItemsCleanupResult.Verification) -> String {
        switch value {
        case .cleared: L10n.text("已确认列表为空或不存在", "Verified empty or absent")
        case .writtenBack: L10n.text("系统已写回，可能要注销后才清空", "The system wrote the list back; signing out may be needed to clear it")
        case .unknown: L10n.text("无法确认列表是否已清空", "Could not verify whether the list is empty")
        case .notMoved: L10n.text("未移走，请查看操作回执", "Not moved; see the operation receipt")
        }
    }
    static func restart(_ result: RecentItemsProcessController.Result?) -> String {
        switch result {
        case .terminated: L10n.text("已请求最近项目服务重启", "Recent-items service restart requested")
        case .notRunning: L10n.text("最近项目服务未在运行，已跳过重启", "Recent-items service was not running; restart skipped")
        case .failed: L10n.text("最近项目服务重启未成功，请以列表核实结果为准", "Recent-items service restart failed; check each list's verification result")
        case nil: L10n.text("没有列表移到废纸篓，未重启最近项目服务", "No lists moved to Trash; recent-items service was not restarted")
        }
    }
}
