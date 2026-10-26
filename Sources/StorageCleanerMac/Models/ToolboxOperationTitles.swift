import Foundation

/// D-FP1–D-FP4: how Operation History names the receipts of the new tool
/// pages ("Extensions · <first item> and N more"), as D46 does for File
/// Analysis. The receipt keeps the rule ID; the title is worked out when it
/// is shown, in the language of that moment.
enum ToolboxOperationTitles {
    static func prefix(for rulesVersion: String) -> String? {
        switch rulesVersion {
        case ExtensionRemovalService.ruleID:
            L10n.text("扩展", "Extensions")
        case DuplicateCloneMergeService.ruleID:
            L10n.text("重复文件合并为克隆", "Duplicates Merged into Clones")
        case ChatFilesTrashService.ruleID:
            L10n.text("聊天文件", "Chat Files")
        default:
            nil
        }
    }

    static func title(rulesVersion: String, subject: String?, itemCount: Int) -> String? {
        guard let prefix = prefix(for: rulesVersion) else { return nil }
        guard let subject else { return prefix + L10n.text(" · 移到废纸篓", " · Moved to Trash") }
        let name = prefix + " · " + subject
        return itemCount > 1 ? name + L10n.text(" 等 \(ByteFormat.count(itemCount)) 项", " and \(itemCount - 1) more") : name
    }

    /// The first item's name without its bundle extension.
    static func subject(rulesVersion: String, firstSourcePath: String?) -> String? {
        guard prefix(for: rulesVersion) != nil, let firstSourcePath else { return nil }
        return String(URL(fileURLWithPath: firstSourcePath).deletingPathExtension().lastPathComponent.prefix(160))
    }
}
