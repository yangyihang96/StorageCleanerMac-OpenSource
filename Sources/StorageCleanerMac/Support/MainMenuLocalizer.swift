import AppKit
import FanControlShared

enum MainMenuLocalizer {
    @MainActor
    static func scheduleApply(language: AppLanguage = L10n.appLanguage) {
        apply(language: language)

        Task { @MainActor in
            apply(language: language)
            try? await Task.sleep(for: .milliseconds(200))
            apply(language: language)
            try? await Task.sleep(for: .seconds(1))
            apply(language: language)
        }
    }

    @MainActor
    static func apply(language: AppLanguage = L10n.appLanguage, menu: NSMenu? = nil) {
        guard let menu = menu ?? NSApp.mainMenu else { return }
        let usesChinese = L10n.usesChinese(for: language)
        localize(menu: menu, usesChinese: usesChinese)
    }

    static func localizedTitle(_ title: String, usesChinese: Bool) -> String {
        if usesChinese {
            return chineseTitle(for: title)
        }
        return englishTitle(for: title)
    }

    private static func localize(menu: NSMenu, usesChinese: Bool) {
        for item in menu.items {
            if !item.title.isEmpty {
                item.title = localizedTitle(item.title, usesChinese: usesChinese)
            }
            if let submenu = item.submenu {
                localize(menu: submenu, usesChinese: usesChinese)
            }
        }
    }

    private static func chineseTitle(for title: String) -> String {
        if let fixed = chineseFixedTitles[title] {
            return fixed
        }

        let appName = appName(usesChinese: true)
        if title.hasPrefix("About ") {
            return "关于\(appName)"
        }
        if title.hasPrefix("Hide ") {
            return "隐藏\(appName)"
        }
        if title.hasPrefix("Quit ") {
            return "退出\(appName)"
        }
        if title.hasPrefix("Services") {
            return "服务"
        }
        return title
    }

    private static func englishTitle(for title: String) -> String {
        if let fixed = englishFixedTitles[title] {
            return fixed
        }

        let appName = appName(usesChinese: false)
        if title.hasPrefix("关于") {
            return "About \(appName)"
        }
        if title.hasPrefix("隐藏") && title != "隐藏其他" {
            return "Hide \(appName)"
        }
        if title.hasPrefix("退出") {
            return "Quit \(appName)"
        }
        return title
    }

    private static func appName(usesChinese: Bool) -> String {
        if StorageCleanerBuildIdentity.isBeta {
            return usesChinese ? "测试版" : "Beta"
        }
        return usesChinese ? "存储清理助手" : "Storage Cleaner"
    }

    private static let chineseFixedTitles: [String: String] = [
        "File": "文件",
        "Edit": "编辑",
        "View": "显示",
        "Window": "窗口",
        "Help": "帮助",
        "Close": "关闭",
        "Close Window": "关闭窗口",
        "Minimize": "最小化",
        "Zoom": "缩放",
        "Bring All to Front": "全部置于顶层",
        "Undo": "撤销",
        "Redo": "重做",
        "Cut": "剪切",
        "Copy": "拷贝",
        "Paste": "粘贴",
        "Paste and Match Style": "粘贴并匹配样式",
        "Delete": "删除",
        "Select All": "全选",
        "Find": "查找",
        "Find...": "查找...",
        "Find…": "查找...",
        "Find and Replace...": "查找并替换...",
        "Find and Replace…": "查找并替换...",
        "Find Next": "查找下一个",
        "Find Previous": "查找上一个",
        "Use Selection for Find": "使用所选内容查找",
        "Show Spelling and Grammar": "显示拼写和语法",
        "Check Document Now": "立即检查文稿",
        "Check Spelling While Typing": "键入时检查拼写",
        "Check Grammar With Spelling": "随拼写检查语法",
        "Correct Spelling Automatically": "自动纠正拼写",
        "Substitutions": "替换",
        "Show Substitutions": "显示替换",
        "Smart Copy/Paste": "智能拷贝/粘贴",
        "Smart Quotes": "智能引号",
        "Smart Dashes": "智能破折号",
        "Smart Links": "智能链接",
        "Data Detectors": "数据检测器",
        "Text Replacement": "文本替换",
        "Transformations": "转换",
        "Make Upper Case": "转为大写",
        "Make Lower Case": "转为小写",
        "Capitalize": "首字母大写",
        "Speech": "语音",
        "Start Speaking": "开始朗读",
        "Stop Speaking": "停止朗读",
        "Start Dictation...": "开始听写...",
        "Start Dictation…": "开始听写...",
        "Emoji & Symbols": "表情与符号",
        "Settings...": "设置...",
        "Settings…": "设置...",
        "Hide Others": "隐藏其他",
        "Show All": "全部显示",
        "Enter Full Screen": "进入全屏幕",
        "Exit Full Screen": "退出全屏幕"
    ]

    private static let englishFixedTitles: [String: String] = [
        "文件": "File",
        "编辑": "Edit",
        "显示": "View",
        "窗口": "Window",
        "帮助": "Help",
        "关闭": "Close",
        "关闭窗口": "Close Window",
        "最小化": "Minimize",
        "缩放": "Zoom",
        "全部置于顶层": "Bring All to Front",
        "撤销": "Undo",
        "重做": "Redo",
        "剪切": "Cut",
        "拷贝": "Copy",
        "粘贴": "Paste",
        "粘贴并匹配样式": "Paste and Match Style",
        "删除": "Delete",
        "全选": "Select All",
        "查找": "Find",
        "查找...": "Find...",
        "查找并替换...": "Find and Replace...",
        "查找下一个": "Find Next",
        "查找上一个": "Find Previous",
        "使用所选内容查找": "Use Selection for Find",
        "显示拼写和语法": "Show Spelling and Grammar",
        "立即检查文稿": "Check Document Now",
        "键入时检查拼写": "Check Spelling While Typing",
        "随拼写检查语法": "Check Grammar With Spelling",
        "自动纠正拼写": "Correct Spelling Automatically",
        "替换": "Substitutions",
        "显示替换": "Show Substitutions",
        "智能拷贝/粘贴": "Smart Copy/Paste",
        "智能引号": "Smart Quotes",
        "智能破折号": "Smart Dashes",
        "智能链接": "Smart Links",
        "数据检测器": "Data Detectors",
        "文本替换": "Text Replacement",
        "转换": "Transformations",
        "转为大写": "Make Upper Case",
        "转为小写": "Make Lower Case",
        "首字母大写": "Capitalize",
        "语音": "Speech",
        "开始朗读": "Start Speaking",
        "停止朗读": "Stop Speaking",
        "开始听写...": "Start Dictation...",
        "表情与符号": "Emoji & Symbols",
        "设置...": "Settings...",
        "隐藏其他": "Hide Others",
        "全部显示": "Show All",
        "进入全屏幕": "Enter Full Screen",
        "退出全屏幕": "Exit Full Screen"
    ]
}
