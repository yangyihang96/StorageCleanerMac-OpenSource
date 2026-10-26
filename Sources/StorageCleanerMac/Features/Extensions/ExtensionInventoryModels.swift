import Foundation

/// D-FP1: the add-ons the Extensions manager lists. Mac Sai lists preference
/// panes, Internet plug-ins and app extensions; we add the other bundle
/// folders macOS still reads (Quick Look, Spotlight, screen savers, audio
/// plug-ins) and kernel extensions. Only a bundle in the user's own Library
/// can be moved to the Trash; everything else is listed with where it is
/// managed (Mac Sai keeps Safari extensions read-only for the same reason:
/// changing them breaks the host app's signature).
enum ExtensionKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case preferencePane
    case internetPlugin
    case quickLookGenerator
    case spotlightImporter
    case screenSaver
    case audioPlugin
    case kernelExtension
    case safariExtension
    case appExtension

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preferencePane: L10n.text("偏好设置面板", "Preference Panes")
        case .internetPlugin: L10n.text("互联网插件", "Internet Plug-ins")
        case .quickLookGenerator: L10n.text("快速查看插件", "Quick Look Plug-ins")
        case .spotlightImporter: L10n.text("Spotlight 导入器", "Spotlight Importers")
        case .screenSaver: L10n.text("屏幕保护程序", "Screen Savers")
        case .audioPlugin: L10n.text("音频插件", "Audio Plug-ins")
        case .kernelExtension: L10n.text("内核扩展", "Kernel Extensions")
        case .safariExtension: L10n.text("Safari 扩展", "Safari Extensions")
        case .appExtension: L10n.text("应用扩展", "App Extensions")
        }
    }

    /// The category header's explanation: what these are and what removing
    /// one does.
    var summary: String {
        switch self {
        case .preferencePane:
            L10n.text("第三方应用装在“系统设置”底部的设置面板。对应的应用删掉后，面板常常留下来。",
                      "Settings panes third-party apps add at the bottom of System Settings. They often stay behind after the app is deleted.")
        case .internetPlugin:
            L10n.text("旧式浏览器插件（如 Java、Silverlight）。现在的 Safari、Chrome、Firefox 都不再加载它们。",
                      "Old browser plug-ins such as Java or Silverlight. Current Safari, Chrome and Firefox no longer load them.")
        case .quickLookGenerator:
            L10n.text("按空格预览文件用的旧式插件。macOS 15 起系统不再加载这类插件，新应用改用预览扩展。",
                      "Old plug-ins for previewing files with Space. macOS 15 and later no longer load them; apps now use preview extensions.")
        case .spotlightImporter:
            L10n.text("让 Spotlight 读懂某种文件内容的插件。移除后这类文件仍能按名称搜到，只是搜不到内容。",
                      "Plug-ins that let Spotlight read a kind of file. Without one, those files are still found by name but not by content.")
        case .screenSaver:
            L10n.text("自己安装的屏幕保护程序。正在使用的那个被移除后，系统会换回默认的。",
                      "Screen savers you installed. If the one in use is removed, macOS switches back to a built-in one.")
        case .audioPlugin:
            L10n.text("音频软件用的插件（AU、VST、VST3）和音频驱动。移除前请先退出正在使用它的音频软件。",
                      "Plug-ins for audio apps (AU, VST, VST3) and audio drivers. Quit the audio app using one before removing it.")
        case .kernelExtension:
            L10n.text("在内核里运行的驱动。它们在“/资源库”里，需要管理员权限，本应用只列出，不移除。",
                      "Drivers that run in the kernel. They are in /Library and need an administrator, so this app lists them only.")
        case .safariExtension:
            L10n.text("随应用安装的 Safari 扩展和内容拦截器。请在 Safari 设置的“扩展”里开关；改动应用里的扩展会破坏它的签名。",
                      "Safari extensions and content blockers that come with apps. Turn them on or off in Safari Settings › Extensions; changing them inside the app breaks its signature.")
        case .appExtension:
            L10n.text("随应用安装的小组件、共享、访达和文件提供者等扩展。删除对应的应用即可移除，也可以在系统设置里关闭。",
                      "Widgets, sharing, Finder and file provider extensions that come with apps. Deleting the app removes them; you can also turn them off in System Settings.")
        }
    }

    var systemImage: String {
        switch self {
        case .preferencePane: "gearshape.2"
        case .internetPlugin: "globe"
        case .quickLookGenerator: "eye"
        case .spotlightImporter: "magnifyingglass"
        case .screenSaver: "sparkles.tv"
        case .audioPlugin: "waveform"
        case .kernelExtension: "cpu"
        case .safariExtension: "safari"
        case .appExtension: "puzzlepiece.extension"
        }
    }

    /// Library-relative folders holding bundles of this kind, with the
    /// bundle extensions (lowercased) each one is read for.
    var libraryFolders: [(folder: String, extensions: Set<String>)] {
        switch self {
        case .preferencePane: [("PreferencePanes", ["prefpane"])]
        case .internetPlugin: [("Internet Plug-Ins", ["plugin", "webplugin"])]
        case .quickLookGenerator: [("QuickLook", ["qlgenerator"])]
        case .spotlightImporter: [("Spotlight", ["mdimporter"])]
        case .screenSaver: [("Screen Savers", ["saver"])]
        case .audioPlugin: [
            ("Audio/Plug-Ins/Components", ["component"]),
            ("Audio/Plug-Ins/VST", ["vst"]),
            ("Audio/Plug-Ins/VST3", ["vst3"]),
            ("Audio/Plug-Ins/HAL", ["driver", "plugin"]),
        ]
        case .kernelExtension: [("Extensions", ["kext"])]
        case .safariExtension, .appExtension: []
        }
    }

    /// Kinds read from bundle folders (the rest come from pluginkit).
    static let folderKinds: [ExtensionKind] = allCases.filter { !$0.libraryFolders.isEmpty }
}

/// Which Library a bundle is in. `/System/Library` is Apple's and never read.
enum ExtensionDomain: String, Codable, Sendable {
    case user
    case local
    case application

    var title: String {
        switch self {
        case .user: L10n.text("当前用户", "This User")
        case .local: L10n.text("所有用户", "All Users")
        case .application: L10n.text("应用内", "Inside an App")
        }
    }
}

/// What the code signature says, checked against Apple-issued certificates
/// (a self-made certificate cannot claim a developer).
enum ExtensionSigning: Equatable, Sendable {
    case apple
    case developer(teamID: String, name: String?)
    case unsigned
    case invalid
    case notChecked

    var title: String {
        switch self {
        case .apple: "Apple"
        case .developer(let teamID, let name):
            name.map { L10n.text("\($0)（\(teamID)）", "\($0) (\(teamID))") } ?? teamID
        case .unsigned: L10n.text("未签名", "Unsigned")
        case .invalid: L10n.text("签名无效", "Invalid Signature")
        case .notChecked: L10n.text("未核对签名", "Signature Not Checked")
        }
    }
}

/// pluginkit's election mark: "+" chosen by the user, "-" turned off, "="
/// replaced by another version, none for the extension point's default.
enum ExtensionElection: String, Codable, Sendable {
    case enabled
    case disabled
    case superseded
    case automatic

    var title: String {
        switch self {
        case .enabled: L10n.text("已开启", "On")
        case .disabled: L10n.text("已关闭", "Off")
        case .superseded: L10n.text("已被新版本取代", "Superseded")
        case .automatic: L10n.text("默认", "Default")
        }
    }
}

/// Why macOS no longer loads a bundle, so removing it changes nothing a
/// user can notice.
enum ExtensionObsolescence: String, Codable, Sendable {
    case quickLookGeneratorsRetired
    case npapiRetired

    var title: String {
        switch self {
        case .quickLookGeneratorsRetired:
            L10n.text("系统已不再加载", "No Longer Loaded")
        case .npapiRetired:
            L10n.text("浏览器已不再加载", "Browsers No Longer Load It")
        }
    }

    var explanation: String {
        switch self {
        case .quickLookGeneratorsRetired:
            L10n.text("macOS 15 起不再加载旧式快速查看插件，留着只占空间。",
                      "macOS 15 and later no longer load old Quick Look plug-ins; it only takes up space.")
        case .npapiRetired:
            L10n.text("现在的浏览器都不再加载这类插件，留着只占空间。",
                      "Current browsers no longer load this kind of plug-in; it only takes up space.")
        }
    }
}

/// How an item can be removed. Only `.movableToTrash` rows have a tick.
enum ExtensionManagement: Equatable, Sendable {
    case movableToTrash
    /// In /Library: Finder asks for an administrator; we do not elevate.
    case administratorLocation
    /// Part of an app bundle: removed with the app, turned off in System
    /// Settings.
    case withParentApplication(String)
    case safariSettings
    /// Kernel extensions are allowed and removed in System Settings.
    case systemSettingsApproval
    /// A place no flow of this app may move from (ProtectedLocations).
    case protectedLocation
    /// A link, or a path through one: moving it frees nothing and the
    /// operation history could not verify it, so Finder handles it.
    case symbolicLink
    /// Its file information could not be read, so it cannot be checked
    /// again before a move.
    case unreadable

    var isMovable: Bool { self == .movableToTrash }

    var note: String? {
        switch self {
        case .movableToTrash:
            nil
        case .administratorLocation:
            L10n.text("在“/资源库”中，需要管理员权限，本应用不移除；可以在访达中自行删除。",
                      "In /Library and needs an administrator, so this app does not remove it; you can delete it in Finder.")
        case .withParentApplication(let name):
            L10n.text("随“\(name)”安装，删除该应用即可移除。", "Comes with \(name); deleting that app removes it.")
        case .safariSettings:
            L10n.text("请在 Safari 设置的“扩展”里管理。", "Manage it in Safari Settings › Extensions.")
        case .systemSettingsApproval:
            L10n.text("内核扩展在系统设置的“隐私与安全性”里批准或移除。",
                      "Kernel extensions are allowed or removed in System Settings › Privacy & Security.")
        case .protectedLocation:
            L10n.text("位于受保护的位置，本应用不移动。", "In a protected location this app never moves from.")
        case .symbolicLink:
            L10n.text("这是指向别处的链接，移走它不释放空间；本应用不移动，可以在访达中删除。",
                      "This is a link to somewhere else; moving it frees nothing, so this app leaves it to Finder.")
        case .unreadable:
            L10n.text("读不到它的文件信息，本应用不移动。", "Its file information could not be read, so this app does not move it.")
        }
    }
}

struct ExtensionItem: Identifiable, Equatable, Sendable {
    var id: String { path }
    let kind: ExtensionKind
    let path: String
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let domain: ExtensionDomain
    /// Allocated bytes of the bundle (0 for app extensions, which stay
    /// inside their app).
    let bytes: Int64
    let sizeIsLowerBound: Bool
    let signing: ExtensionSigning
    let parentName: String?
    let parentPath: String?
    let election: ExtensionElection?
    /// The pluginkit extension point (app and Safari extensions).
    let extensionPoint: String?
    let obsolescence: ExtensionObsolescence?
    let isSymbolicLink: Bool
    let identity: FileIdentity?
    let modified: Date?
    let management: ExtensionManagement

    /// One line under the name: who made it, version and where it lives.
    var detail: String {
        var parts: [String] = []
        if let parentName, kind == .appExtension || kind == .safariExtension {
            parts.append(parentName)
            if let extensionPoint { parts.append(ExtensionPointNames.title(for: extensionPoint)) }
        } else if signing != .notChecked {
            parts.append(signing.title)
        }
        if let version, !version.isEmpty { parts.append(L10n.text("版本 \(version)", "Version \(version)")) }
        if isSymbolicLink { parts.append(L10n.text("链接", "Link")) }
        if kind != .appExtension && kind != .safariExtension { parts.append(domain.title) }
        return parts.joined(separator: " · ")
    }
}

/// What one scan found.
struct ExtensionInventory: Equatable, Sendable {
    let items: [ExtensionItem]
    /// Apple's own app extensions, counted but not listed.
    let hiddenAppleExtensionCount: Int
    /// False when pluginkit could not be read; app and Safari extensions
    /// are then missing, not absent.
    let pluginKitAvailable: Bool
    let scannedAt: Date

    func items(of kind: ExtensionKind) -> [ExtensionItem] { items.filter { $0.kind == kind } }

    var movableItems: [ExtensionItem] { items.filter(\.management.isMovable) }

    /// For a result tile: what can be removed here and how much it takes.
    var summary: ExtensionInventorySummary {
        let movable = movableItems
        return ExtensionInventorySummary(
            itemCount: items.count,
            movableCount: movable.count,
            movableBytes: movable.reduce(0) { $0 + max(0, $1.bytes) },
            obsoleteCount: items.filter { $0.obsolescence != nil }.count
        )
    }
}

struct ExtensionInventorySummary: Equatable, Sendable {
    let itemCount: Int
    let movableCount: Int
    let movableBytes: Int64
    let obsoleteCount: Int
}

/// Plain names for pluginkit extension points (`SDK = …`).
enum ExtensionPointNames {
    static let safariPoints: Set<String> = [
        "com.apple.Safari.web-extension", "com.apple.Safari.extension", "com.apple.Safari.content-blocker",
    ]

    static func title(for point: String) -> String {
        if point.hasPrefix("com.apple.networkextension") { return L10n.text("网络扩展", "Network Extension") }
        return switch point {
        case "com.apple.widgetkit-extension", "com.apple.widget-extension":
            L10n.text("小组件", "Widget")
        case "com.apple.share-services":
            L10n.text("共享", "Share")
        case "com.apple.FinderSync":
            L10n.text("访达扩展", "Finder Extension")
        case "com.apple.fileprovider-nonui", "com.apple.fileprovider-ui", "com.apple.fileprovider-actionsui":
            L10n.text("文件提供者", "File Provider")
        case "com.apple.quicklook.preview", "com.apple.quicklook.thumbnail":
            L10n.text("快速查看", "Quick Look")
        case "com.apple.spotlight.import", "com.apple.spotlight.index":
            "Spotlight"
        case "com.apple.Safari.web-extension", "com.apple.Safari.extension":
            L10n.text("Safari 扩展", "Safari Extension")
        case "com.apple.Safari.content-blocker":
            L10n.text("Safari 内容拦截器", "Safari Content Blocker")
        case "com.apple.services", "com.apple.ui-services":
            L10n.text("操作", "Action")
        case "com.apple.photo-editing", "com.apple.photo-project":
            L10n.text("照片编辑", "Photo Editing")
        case "com.apple.intents-service", "com.apple.intents-ui-service", "com.apple.appintents-extension":
            L10n.text("快捷指令", "Shortcuts")
        case "com.apple.usernotifications.service", "com.apple.usernotifications.content-extension":
            L10n.text("通知", "Notifications")
        case "com.apple.authentication-services-credential-provider-ui":
            L10n.text("密码自动填充", "Password AutoFill")
        case "com.apple.dt.Xcode.extension.source-editor":
            L10n.text("Xcode 编辑器扩展", "Xcode Source Editor")
        case "com.apple.email.extension", "com.apple.email.mailextension":
            L10n.text("邮件扩展", "Mail Extension")
        default:
            point
        }
    }
}
