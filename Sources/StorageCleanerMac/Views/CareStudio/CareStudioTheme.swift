import AppKit
import os
import SwiftUI

/// D141 (2026-10-19): the junk-cleanup, startup and memory pages follow the
/// CleanMyMac 5.7.2 layout, colours and flow observed on this Mac
/// (`~/Claude 好玩的/清理软件逆向-2026-10-19/`). Only layout, colour values
/// and interaction order are taken from it. Pictures are our own D58 set,
/// recoloured per module; no CleanMyMac code, images, marks or strings.
enum CareStudioModule: String, CaseIterable, Sendable {
    case smartScan
    case cleanup
    case devTools
    case startup
    case memory
    /// D154: CleanMyMac's Applications module (uninstaller, leftovers,
    /// installers; updates open the updater).
    case applications
    /// D154: pages of the CleanMyMac modules we did not have.
    case cloudCleanup
    case myTools
    case myActivity
    /// D154: the remaining pages, on their module's gradient. Their landing,
    /// running and result layouts move to the studio one page at a time;
    /// until then the D67 page draws on the gradient (`MainContentHost`).
    case protection
    case clutter
    case spaceMap
    case updater
    case health
    case benchmark
    case energy
    case migration

    init?(filter: ReviewFilter) {
        switch filter {
        case .overview: self = .smartScan
        case .green: self = .cleanup
        case .devCaches: self = .devTools
        case .startup: self = .startup
        case .memory: self = .memory
        case .uninstall: self = .applications
        case .cloudCleanup: self = .cloudCleanup
        case .myTools: self = .myTools
        case .myActivity: self = .myActivity
        case .privacy: self = .protection
        case .duplicates: self = .clutter
        case .largeFiles: self = .spaceMap
        case .updater: self = .updater
        case .healthHub: self = .health
        case .performance: self = .benchmark
        case .energy: self = .energy
        case .migration: self = .migration
        // D154 batch 2: the D160–D165 tool pages take their module's look.
        case .extensions: self = .applications
        case .maintenance: self = .startup
        case .chatFiles: self = .clutter
        case .utilityHub:
            return nil
        }
    }

    /// The page a sidebar destination shows: tools in the utility hub are
    /// routed through `.utilityHub`.
    init?(route: ReviewFilter, utility: ReviewFilter) {
        self.init(filter: route == .utilityHub ? utility : route)
    }

    var filter: ReviewFilter {
        switch self {
        case .smartScan: .overview
        case .cleanup: .green
        case .devTools: .devCaches
        case .startup: .startup
        case .memory: .memory
        case .applications: .uninstall
        case .cloudCleanup: .cloudCleanup
        case .myTools: .myTools
        case .myActivity: .myActivity
        case .protection: .privacy
        case .clutter: .duplicates
        case .spaceMap: .largeFiles
        case .updater: .updater
        case .health: .healthHub
        case .benchmark: .performance
        case .energy: .energy
        case .migration: .migration
        }
    }

    /// The CleanMyMac module the page belongs to (D154): developer junk is
    /// part of Cleanup there (Xcode Junk, AI Clutter), so it takes Cleanup's
    /// green; startup items and memory are Performance's.
    var family: CareStudioFamily {
        switch self {
        case .smartScan: .smartCare
        case .cleanup, .devTools: .cleanup
        case .startup, .memory: .performance
        case .applications, .updater: .applications
        case .cloudCleanup: .cloudCleanup
        case .myTools, .health, .benchmark, .energy, .migration: .myTools
        case .myActivity: .myActivity
        case .protection: .protection
        case .clutter: .clutter
        case .spaceMap: .spaceMap
        }
    }

    var palette: CareStudioPalette { family.palette }

    var art: GeneratedArt {
        switch self {
        case .smartScan: .smartScan
        case .cleanup: .cleanup
        case .devTools: .devCaches
        // D166: a module's first page shows the module's own picture.
        case .startup: .performance
        case .memory: .memory
        case .applications: .applications
        case .cloudCleanup: .cloudCleanup
        case .myTools: .myTools
        case .myActivity: .myActivity
        // D154 batch 3R (D166④): Protection's shield and Space Map's bubbles
        // (were the globe and lock, and the document and magnifier, which the
        // classic Browser Privacy and File Analysis pages keep).
        case .protection: .protection
        case .clutter: .clutter
        case .spaceMap: .spaceMap
        case .updater: .updater
        case .health: .health
        case .benchmark: .benchmark
        case .energy: .energy
        case .migration: .migration
        }
    }

    /// Turns our D58 picture to the module colour (the pictures are one
    /// glossy hue each, so a hue rotation keeps highlights and edges).
    var artHueRotation: Angle {
        switch self {
        // D166: every picture has its measured hue (`dominantHue`), so each
        // module turns its picture by the exact difference (the angles set by
        // eye for the D58 renders are gone). Our own tools on My Tools keep
        // their picture's colour.
        case .health, .benchmark, .energy, .migration: .zero
        default: family.hueRotation(for: art)
        }
    }

    var title: String {
        switch self {
        case .smartScan: L10n.text("智能扫描", "Smart Scan")
        case .cleanup: L10n.text("垃圾清理", "Junk Cleanup")
        case .devTools: L10n.text("开发者垃圾", "Developer Junk")
        case .startup: L10n.text("登录项与后台任务", "Login & Background Items")
        case .memory: L10n.text("内存管理", "Memory")
        case .applications: L10n.text("应用管理", "Applications")
        case .cloudCleanup: L10n.text("云盘清理", "Cloud Cleanup")
        case .myTools: L10n.text("我的工具", "My Tools")
        case .myActivity: L10n.text("我的活动", "My Activity")
        case .protection: L10n.text("安全防护", "Protection")
        case .clutter: L10n.text("杂乱文件", "Clutter")
        case .spaceMap: L10n.text("空间地图", "Space Map")
        case .updater: L10n.text("应用更新", "App Updates")
        case .health: L10n.text("系统健康", "System Health")
        case .benchmark: L10n.text("性能测试", "Performance Test")
        case .energy: L10n.text("能耗", "Energy")
        case .migration: L10n.text("文件搬家", "File Migration")
        }
    }

    /// The window title shown while a module runs (CleanMyMac shows the
    /// sidebar name of the module in the title bar).
    var sidebarTitle: String { filter.sidebarTitle }

    var subtitle: String {
        switch self {
        // D168: the five Smart Care modules (was junk, files to review and
        // Mac health).
        case .smartScan:
            L10n.text("一次检查垃圾、隐私、性能、应用更新和重复文件，清理前逐项确认。",
                      "One pass over junk, privacy, performance, app updates and duplicates. Nothing is removed until you confirm.")
        case .cleanup:
            L10n.text("清掉缓存、日志和临时文件，腾出空间，让系统保持轻快。",
                      "Clear caches, logs and temporary files to free up space and keep your Mac responsive.")
        case .devTools:
            L10n.text("清理构建产物、包管理器与 AI 工具的缓存，项目源码和会话保持不动。",
                      "Clear build products and caches of package managers and AI tools. Sources and sessions stay put.")
        case .startup:
            L10n.text("查看登录后自动打开的应用和在后台运行的项目，停用用不到的，随时可以撤销。",
                      "See the apps that open at login and the items running in the background. Turn off what you don't need; undo any time.")
        case .memory:
            L10n.text("看清内存压力和占用最多的应用，退出用不到的应用来释放内存。",
                      "See memory pressure and the apps using the most memory, and quit the ones you don't need.")
        case .applications:
            L10n.text("把用不到的应用连同它留下的文件一起卸载，更新旧版本，清掉以前卸载剩下的残留。",
                      "Uninstall apps you no longer use together with what they leave behind, update old versions, and clear what earlier uninstalls left.")
        case .cloudCleanup:
            L10n.text("看看 iCloud 云盘在这台 Mac 上占了多少空间，只需放在云端的文件可以移除本机副本。",
                      "See how much iCloud Drive keeps on this Mac, and remove local copies of files that can live in the cloud.")
        case .myTools:
            L10n.text("单项任务的快捷工具，可以搜索，也可以收藏常用的。",
                      "Quick tools for single tasks. Search them and keep the ones you use as favourites.")
        case .myActivity:
            L10n.text("这台 Mac 上做过的清理和维护，以及它们腾出的空间。",
                      "The cleanups and maintenance done on this Mac, and the space they made.")
        case .protection:
            L10n.text("检查浏览记录、Cookie 和站点数据；删除前先备份，7 天内可以恢复。",
                      "Check browsing history, cookies and site data. Everything is backed up before deletion and can be restored for 7 days.")
        // D223: the clutter landing names its kinds, as CleanMyMac's lists
        // its categories (our words); “one of each stays” is said of the
        // duplicates only. D226: the Downloads folder joins them, in the
        // results page's order. D228: a line breaks only between phrases
        // (it split “聊天文件” in a 1280-point window).
        case .clutter:
            CareStudioLineBreaks.betweenPhrases(L10n.text(
                "整理重复文件、相似照片、大型和旧文件、“下载”文件夹以及聊天文件；重复文件每组至少留一份。",
                "Sort out duplicates, similar photos, large and old files, the Downloads folder and chat files. At least one copy of each duplicate group stays."))
        case .spaceMap:
            L10n.text("按文件夹看清空间被什么占用，大文件和隐藏文件都在里面，审阅后再移到废纸篓。",
                      "See what takes up space folder by folder, large and hidden files included, and move what you review to the Trash.")
        case .updater:
            L10n.text("检查可信来源的新版本，逐个或全部更新。", "Check trusted sources for new versions and update one or all.")
        case .health:
            L10n.text("检查磁盘、电池、备份和安全设置，给出健康评分。", "Check disk, battery, backups and security settings, with a health score.")
        case .benchmark:
            L10n.text("测 CPU、图形、媒体和持续性能，和自己的历史及社区成绩对比。",
                      "Measure CPU, graphics, media and sustained performance against your history and the community.")
        case .energy:
            L10n.text("看哪些应用和进程最耗电，以及芯片的功率和温度。", "See which apps and processes use the most energy, and the chip's power and temperature.")
        case .migration:
            L10n.text("把大文件或应用复制到外接硬盘并校验，确认后才把原件移到废纸篓。",
                      "Copy large files or apps to an external drive and verify them; originals go to the Trash only after you confirm.")
        }
    }

    var scanningTitle: String {
        switch self {
        case .smartScan: L10n.text("正在全面检查…", "Checking your Mac…")
        case .cleanup: L10n.text("正在查找垃圾…", "Looking for junk…")
        case .devTools: L10n.text("正在查找开发者垃圾…", "Looking for developer junk…")
        case .startup: L10n.text("正在读取启动项…", "Reading startup items…")
        case .memory: L10n.text("正在读取内存占用…", "Reading memory use…")
        case .applications: L10n.text("正在查找应用…", "Looking for applications…")
        case .cloudCleanup: L10n.text("正在读取云盘…", "Reading cloud storage…")
        case .myTools, .myActivity: title
        case .protection: L10n.text("正在检查隐私记录…", "Checking privacy records…")
        case .clutter: L10n.text("正在查找重复文件…", "Looking for duplicates…")
        case .spaceMap: L10n.text("正在绘制空间地图…", "Mapping your storage…")
        case .updater: L10n.text("正在检查更新…", "Checking for updates…")
        case .health: L10n.text("正在检查…", "Checking…")
        case .benchmark: L10n.text("正在测试…", "Testing…")
        case .energy: L10n.text("正在测量能耗…", "Measuring energy…")
        case .migration: L10n.text("正在查找可搬移的文件…", "Looking for files to move…")
        }
    }

    var scanningSubtitle: String {
        switch self {
        case .smartScan: L10n.text("正在查找垃圾、待确认文件和健康问题。", "Looking for junk, files to review and health issues.")
        case .cleanup: L10n.text("正在查找垃圾和用不到的文件。", "Looking for junk and unneeded files.")
        case .devTools: L10n.text("正在查找可以重新生成的开发者文件。", "Looking for developer files that can be regenerated.")
        case .startup: L10n.text("正在读取登录项、后台代理和系统守护进程。", "Reading login items, background agents and system daemons.")
        case .memory: L10n.text("正在读取内存压力和各应用的占用。", "Reading memory pressure and per-app usage.")
        case .applications: L10n.text("正在读取应用、可用更新和以前卸载留下的文件。", "Reading applications, available updates and files earlier uninstalls left.")
        case .cloudCleanup: L10n.text("正在找出已下载到这台 Mac 的云盘文件。", "Finding cloud files downloaded to this Mac.")
        case .myTools, .myActivity: subtitle
        case .protection: L10n.text("正在读取各浏览器的浏览、下载和表单记录。", "Reading each browser's history, downloads and forms.")
        case .clutter: L10n.text("正在比对文件的大小和内容。", "Comparing file sizes and contents.")
        case .spaceMap: L10n.text("正在测量各个文件夹的大小。", "Measuring every folder.")
        case .updater: L10n.text("正在比对各应用的版本和来源。", "Comparing each app's version and source.")
        case .health: L10n.text("正在读取磁盘、电池和系统状态。", "Reading disk, battery and system state.")
        case .benchmark: L10n.text("测试期间 Mac 会满负荷运行。", "Your Mac runs at full load during the test.")
        case .energy: L10n.text("正在分阶段采样各进程的功耗。", "Sampling each process's power in stages.")
        case .migration: L10n.text("正在找出大文件和应用。", "Finding large files and apps.")
        }
    }
}

extension CareStudioFamily {
    /// The page the sidebar row opens (D154). Pages of a module that are not
    /// its first page (developer junk, memory, app updates, the tools) are
    /// reached from the module's results or from My Tools, as in CleanMyMac.
    var primaryRoute: ReviewFilter {
        switch self {
        case .smartCare: .overview
        case .cleanup: .green
        case .protection: .privacy
        case .performance: .startup
        case .applications: .uninstall
        case .clutter: .duplicates
        case .spaceMap: .largeFiles
        case .cloudCleanup: .cloudCleanup
        case .myTools: .myTools
        case .myActivity: .myActivity
        }
    }

    /// The module a page belongs to; tools in the utility hub count as the
    /// tool on screen.
    init(route: ReviewFilter, utility: ReviewFilter = .memory) {
        switch route == .utilityHub ? utility : route {
        case .overview: self = .smartCare
        case .green, .devCaches: self = .cleanup
        case .privacy: self = .protection
        case .startup, .memory, .maintenance: self = .performance
        case .uninstall, .updater, .extensions: self = .applications
        case .duplicates, .chatFiles: self = .clutter
        case .largeFiles: self = .spaceMap
        case .cloudCleanup: self = .cloudCleanup
        case .healthHub, .performance, .energy, .migration, .myTools, .utilityHub: self = .myTools
        case .myActivity: self = .myActivity
        }
    }

    /// The module's mark in the sidebar: our D58 picture of its closest
    /// page, turned to the module colour.
    var art: GeneratedArt {
        switch self {
        case .smartCare: .smartScan
        case .cleanup: .cleanup
        // D154 batch 3R (D166④): its own shield (was the globe and lock).
        case .protection: .protection
        // D166: the modules that borrowed a page's picture have their own.
        case .performance: .performance
        case .applications: .applications
        case .clutter: .clutter
        // D154 batch 3R (D166④): its bubbles (was the document and magnifier).
        case .spaceMap: .spaceMap
        case .cloudCleanup: .cloudCleanup
        case .myTools: .myTools
        case .myActivity: .myActivity
        }
    }

    /// The hue every mark of the module is turned to (D154).
    var hue: Double {
        switch self {
        case .smartCare: 293
        case .cleanup: 124
        case .protection: 325
        case .performance: 27
        case .applications: 215
        case .clutter: 178
        case .spaceMap: 250
        case .cloudCleanup: 210
        case .myTools: 250
        case .myActivity: 255
        }
    }

    var artHueRotation: Angle { hueRotation(for: art) }

    /// Turns any of our D58 pictures to the module colour: each is one
    /// glossy hue, so rotating by the difference keeps highlights and edges.
    func hueRotation(for art: GeneratedArt) -> Angle {
        var delta = (hue - art.dominantHue).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return .degrees(delta)
    }

    /// One line on what the module covers (sidebar tooltip and VoiceOver hint).
    var summary: String {
        switch self {
        // D168 (was "junk, files to review and health").
        case .smartCare: L10n.text("一次扫描垃圾、隐私、性能、应用和重复文件", "One scan for junk, privacy, performance, apps and duplicates")
        case .cleanup: L10n.text("系统垃圾、AI 垃圾、邮件附件和废纸篓", "System junk, AI clutter, mail attachments and Trash")
        case .protection: L10n.text("浏览记录、Cookie 和站点数据", "Browsing history, cookies and site data")
        case .performance: L10n.text("登录项、后台项目和内存", "Login items, background items and memory")
        case .applications: L10n.text("卸载、更新和应用残留", "Uninstall, update and app leftovers")
        // D226 (was "duplicate files and similar photos"): every kind the landing names.
        case .clutter: L10n.text("重复文件、相似照片、大型和旧文件、下载和聊天文件",
                                 "Duplicates, similar photos, large and old files, Downloads and chat files")
        case .spaceMap: L10n.text("看清空间被什么占用，审阅后移到废纸篓", "See what takes up space; review, then move to Trash")
        case .cloudCleanup: L10n.text("iCloud 云盘的本机副本", "Local copies of iCloud Drive files")
        case .myTools: L10n.text("单项工具：性能测试、系统健康、能耗、文件搬家等", "Single tools: performance test, health, energy, file migration and more")
        case .myActivity: L10n.text("清理与维护记录", "Cleanup and maintenance history")
        }
    }
}

/// D228: Chinese may break a line between any two characters, so a narrow
/// line can split a name (“聊｜天文件”). `betweenPhrases` joins the characters
/// of each phrase with a word joiner (U+2060, which text keeps on one line
/// and does not draw), so a line breaks only after a pause mark or before
/// 以及. Latin text, which breaks at spaces, is left as it is.
enum CareStudioLineBreaks {
    static let wordJoiner: Character = "\u{2060}"
    private static let pauseMarks: Set<Character> = ["、", "，", "；", "。", "：", "！", "？"]

    static func betweenPhrases(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        for (index, character) in characters.enumerated() {
            if index > 0 {
                let previous = characters[index - 1]
                let startsYiJi = character == "以" && index + 1 < characters.count && characters[index + 1] == "及"
                if isWide(previous), isWide(character), !pauseMarks.contains(previous), !startsYiJi {
                    result.append(wordJoiner)
                }
            }
            result.append(character)
        }
        return result
    }

    /// D238: the words without the joiners, for the accessibility tree.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: String(wordJoiner), with: "")
    }

    /// Chinese characters, their punctuation and quotes: neither ASCII nor a space.
    private static func isWide(_ character: Character) -> Bool {
        !character.isWhitespace && character.unicodeScalars.allSatisfy { !$0.isASCII }
    }
}

/// CleanMyMac 5.7.2's modules, in its sidebar order (D154): eight above,
/// My Tools and My Activity at the bottom. Each is one colour family; every
/// page of a module draws its gradient and round button in that colour.
/// Names are ours (generic words), not CleanMyMac's feature names.
enum CareStudioFamily: String, CaseIterable, Identifiable, Sendable {
    case smartCare
    case cleanup
    case protection
    case performance
    case applications
    case clutter
    case spaceMap
    case cloudCleanup
    case myTools
    case myActivity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartCare: L10n.text("智能扫描", "Smart Scan")
        case .cleanup: L10n.text("垃圾清理", "Cleanup")
        case .protection: L10n.text("安全防护", "Protection")
        case .performance: L10n.text("性能优化", "Performance")
        case .applications: L10n.text("应用管理", "Applications")
        case .clutter: L10n.text("杂乱文件", "Clutter")
        case .spaceMap: L10n.text("空间地图", "Space Map")
        case .cloudCleanup: L10n.text("云盘清理", "Cloud Cleanup")
        case .myTools: L10n.text("我的工具", "My Tools")
        case .myActivity: L10n.text("我的活动", "My Activity")
        }
    }

    /// CleanMyMac keeps My Tools and My Activity apart at the sidebar's foot.
    var isFooter: Bool { self == .myTools || self == .myActivity }

    var palette: CareStudioPalette {
        switch self {
        case .smartCare: .smartCare
        case .cleanup: .cleanup
        case .protection: .protection
        case .performance: .performance
        case .applications: .applications
        case .clutter: .clutter
        case .spaceMap: .spaceMap
        case .cloudCleanup: .cloudCleanup
        case .myTools: .myTools
        case .myActivity: .myActivity
        }
    }
}

/// Colour values sampled from the CleanMyMac 5.7.2 screenshots
/// (`截图/cmm-01`, `cmm-03`, `cmm-05`, `cmm-14`): a deep corner colour, a
/// base fill and the brighter areas that drift while a module works.
struct CareStudioPalette: Equatable, Sendable {
    let deep: UInt32
    let base: UInt32
    let glows: [UInt32]
    /// The module's button colours, top and bottom: its icons, and on a
    /// lightfield page its checks, charts and links (`FeatureLightfieldPalette.accents`).
    let action: [UInt32]
    let actionGlow: UInt32
    /// Halo colours around the main button (CleanMyMac mixes a warm and a
    /// cool light behind it).
    let halo: [UInt32]
    /// D282: top and bottom of a filled button with a label, the round main
    /// button and a lightfield page's primary: `action`, or a deeper pair where
    /// the white label read under 4.5:1 on it (applications, my tools).
    let buttonFill: [UInt32]

    init(deep: UInt32, base: UInt32, glows: [UInt32], action: [UInt32], actionGlow: UInt32,
         halo: [UInt32], buttonFill: [UInt32]? = nil) {
        self.deep = deep
        self.base = base
        self.glows = glows
        self.action = action
        self.actionGlow = actionGlow
        self.halo = halo
        self.buttonFill = buttonFill ?? action
    }

    static let smartCare = Self(
        deep: 0x230B58, base: 0x4E1C88,
        glows: [0x8A2FB0, 0xB931CC, 0x6B2DAD],
        action: [0xD43BDB, 0x9A1DB6], actionGlow: 0xE45BE0,
        halo: [0xFF8A3D, 0x5B6BFF])
    static let cleanup = Self(
        deep: 0x003A0C, base: 0x0E5E1E,
        glows: [0x528A05, 0x1F8A3E, 0x2FA04C],
        action: [0x48B455, 0x1C7A2C], actionGlow: 0x8CDB6A,
        halo: [0xC8E86A, 0x2FC27A])
    static let performance = Self(
        deep: 0x7A2300, base: 0xA83C00,
        glows: [0xD95A00, 0xE57A2C, 0xC54800],
        action: [0xF39327, 0xC45C00], actionGlow: 0xFFB45E,
        halo: [0xFFD27A, 0xFF5A3D])
    /// D154: sampled from the Protection landing (`CleanMyMac全界面逆向-2026-10-20/截图/p01`).
    static let protection = Self(
        deep: 0x5A0027, base: 0x861059,
        glows: [0xB72F8C, 0x980186, 0x9C216B],
        action: [0xE04AAE, 0xA0127A], actionGlow: 0xF472C8,
        halo: [0xFF8A5B, 0x9E5BFF])
    /// D154: the next five are set from the hue of each module's 3D picture
    /// (mean, dark and light quartiles of `*_Intro.heif`), in the same
    /// deep/base/glow steps the measured modules use; refine against live
    /// screenshots.
    static let applications = Self(
        deep: 0x07185A, base: 0x123C8F,
        glows: [0x2B66D6, 0x2A86E0, 0x3048C2],
        action: [0x3F8CFF, 0x1554C8], actionGlow: 0x74B4FF,
        halo: [0x7FE3FF, 0x7A5BFF],
        // D282: `action` under black 29/255. White on the round button measured
        // 4.10:1; a lightfield primary, under its 8% top light, would read 3.8:1.
        buttonFill: [0x387CE2, 0x134AB1])
    static let clutter = Self(
        deep: 0x023A3C, base: 0x0A5A5C,
        glows: [0x169B93, 0x27B5A3, 0x0F7C84],
        action: [0x2FC4B4, 0x0D8A84], actionGlow: 0x70E6D8,
        halo: [0xB4F5CF, 0x3AA0FF])
    static let spaceMap = Self(
        deep: 0x16125A, base: 0x2E2694,
        glows: [0x5743D4, 0x7A5CF0, 0x4232B6],
        action: [0x8070FF, 0x4B38D2], actionGlow: 0xA898FF,
        halo: [0xE38CFF, 0x4E8CFF])
    static let cloudCleanup = Self(
        deep: 0x052B66, base: 0x0E52A2,
        glows: [0x2A84DE, 0x4AA4F0, 0x1C69C2],
        action: [0x48A8FF, 0x1666CE], actionGlow: 0x86C8FF,
        halo: [0xA4E9FF, 0x6E7CFF])
    static let myTools = Self(
        deep: 0x1E1B3A, base: 0x34305E,
        glows: [0x5A5296, 0x6E5FB0, 0x44407A],
        action: [0x7D72D8, 0x4F45A8], actionGlow: 0x9E94F0,
        halo: [0xF0A0FF, 0x5C9BFF],
        // D282: `action` under black 8/255. White on the lightfield primary
        // (energy, health and benchmark results) measured 4.43:1.
        buttonFill: [0x796ED1, 0x4D43A3])
    static let myActivity = Self(
        deep: 0x1A1440, base: 0x2C2366,
        glows: [0x4B3A9E, 0x5E4AB8, 0x3A2F80],
        action: [0x7A62E8, 0x4A36B0], actionGlow: 0xA08CFF,
        halo: [0x7FD8FF, 0xC77DFF])

    static func color(_ hex: UInt32, opacity: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255, opacity: opacity)
    }

    var deepColor: Color { Self.color(deep) }
    var baseColor: Color { Self.color(base) }

    /// D141 day appearance: the same hues lifted toward white, so a page
    /// keeps CleanMyMac's layout with dark type. The round button keeps its
    /// full colour, as on CleanMyMac.
    var daylight: CareStudioPalette {
        CareStudioPalette(deep: Self.mix(deep, whiteness: 0.58), base: Self.mix(base, whiteness: 0.74),
                          glows: glows.map { Self.mix($0, whiteness: 0.66) },
                          action: action, actionGlow: actionGlow, halo: halo, buttonFill: buttonFill)
    }

    func resolved(for scheme: ColorScheme) -> CareStudioPalette {
        scheme == .dark ? self : daylight
    }

    static func mix(_ hex: UInt32, whiteness: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let value = Double((hex >> shift) & 255)
            return UInt32((value + (255 - value) * whiteness).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    /// `top` at `opacity` over `bottom`.
    static func over(_ top: UInt32, opacity: Double, on bottom: UInt32) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let upper = Double((top >> shift) & 255), lower = Double((bottom >> shift) & 255)
            return UInt32((upper * opacity + lower * (1 - opacity)).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    /// WCAG 2 contrast of two sRGB colours.
    static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            func linear(_ shift: UInt32) -> Double {
                let value = Double((hex >> shift) & 255) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// D276: `hex` moved along its own line, toward black by day and toward
    /// white at night, until it reads 4.5:1 as text anywhere on this
    /// gradient. By day the deep corner binds; at night the brightest of the
    /// base, a white 0.16 tile over it and each glow at its opacity over it
    /// (`CareStudioBackdrop.glows`). White where even white falls short: the
    /// performance, clutter and cloud cleanup glows (4.1–4.2:1, as for the
    /// primary type).
    func readableText(_ hex: UInt32, night: Bool) -> UInt32 {
        let grounds = textGrounds(night: night)
        func reads(_ color: UInt32) -> Bool { grounds.allSatisfy { Self.contrast(color, $0) >= 4.5 } }
        func moved(_ amount: Double) -> UInt32 {
            night ? Self.mix(hex, whiteness: amount) : Self.over(0x000000, opacity: amount, on: hex)
        }
        guard !reads(hex) else { return hex }
        guard reads(moved(1)) else { return moved(1) }
        var low = 0.0, high = 1.0
        for _ in 0..<16 {
            let middle = (low + high) / 2
            if reads(moved(middle)) { high = middle } else { low = middle }
        }
        return moved(high)
    }

    /// The grounds text on this gradient has to read on (`readableText`).
    func textGrounds(night: Bool) -> [UInt32] {
        if night {
            return [base, deep, Self.over(0xFFFFFF, opacity: 0.16, on: base)]
                + CareStudioBackdrop.glows.map { glow in
                    Self.over(glows[min(glow.colorIndex, glows.count - 1)], opacity: glow.opacity, on: base)
                }
        }
        let day = daylight
        return [day.deep, day.base] + day.glows
    }

    /// D279: the least opacity, from `opacity` up, at which `ink` laid over
    /// each of the `textGrounds` reads 4.5:1 there; nil when even full ink
    /// falls short (white on the performance, clutter and cloud cleanup
    /// glows at night). It is judged as the colour carries it, a float, and
    /// a raised opacity is a whole 8-bit step: there the blend never falls on
    /// a half, so neither the float nor an 8-bit alpha rounds a channel the
    /// other way (a solved double on smart care's day gradient gave
    /// `Color.secondary` 4.47:1 as a float).
    func readableOpacity(_ ink: UInt32, from opacity: Double, night: Bool) -> Double? {
        let grounds = textGrounds(night: night)
        func reads(_ alpha: Double) -> Bool {
            let carried = Double(Float(alpha))
            return grounds.allSatisfy { Self.contrast(Self.over(ink, opacity: carried, on: $0), $0) >= 4.5 }
        }
        guard !reads(opacity) else { return opacity }
        guard reads(1) else { return nil }
        var low = Int((opacity * 255).rounded(.down)), high = 255
        while high - low > 1 {
            let middle = (low + high) / 2
            if reads(Double(middle) / 255) { high = middle } else { low = middle }
        }
        return Double(high) / 255
    }

    /// D281 (D276 ②): white, or the day ink (`CareStudioInk.dayHex`), for a
    /// label on a button filled top to bottom with `fill`: whichever reads
    /// better at its worst row across the label, t 0.35–0.65 of the fill. The
    /// day ink wins on the cleanup, performance, clutter and cloud cleanup
    /// fills and on the cleanup result's own orange: white reads 2.7–3.3:1
    /// there, the ink 4.4–5.6:1. Every other fill keeps white, 4.0–5.5:1,
    /// where the ink would read 2.7–3.7:1.
    static func fillLabel(_ fill: [UInt32]) -> UInt32 {
        guard let top = fill.first else { return 0xFFFFFF }
        let bottom = fill.count > 1 ? fill[1] : top
        let rows = (0...6).map { over(bottom, opacity: 0.35 + Double($0) * 0.05, on: top) }
        func worst(_ label: UInt32) -> Double { rows.map { contrast(label, $0) }.min() ?? 0 }
        return worst(CareStudioInk.dayHex) > worst(0xFFFFFF) ? CareStudioInk.dayHex : 0xFFFFFF
    }
}

/// Text and chrome on top of the module gradient. In dark appearance it is
/// CleanMyMac's white type; in light appearance the gradient is the
/// `daylight` palette and the type is dark (the separate day design the app
/// keeps for every page; `DayAppearanceTests`).
enum CareStudioInk {
    private static let night = NSColor.white
    private static let day = NSColor(srgbRed: 0.09, green: 0.07, blue: 0.13, alpha: 1)
    /// D281: the day ink in 8 bits, for judging it on a fill (`CareStudioPalette.fillLabel`).
    static let dayHex: UInt32 = 0x171221

    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let primary = adaptive(dark: night, light: day)
    /// D281 (D276 ②): the label on a filled button, the round main button and
    /// a lightfield page's primary: white, or the day ink in both appearances
    /// where that reads better on the fill (`CareStudioPalette.fillLabel`).
    /// The fill is the same by day and at night (D141), so the label is too.
    static func fillLabel(_ fill: [UInt32]) -> Color {
        CareStudioPalette.fillLabel(fill) == dayHex ? Color(nsColor: day) : .white
    }
    /// D279: the two grey levels read 4.5:1 on the page's gradient
    /// (`CareStudioText`), so on most modules they draw alike.
    static let secondary = CareStudioText(adaptive(dark: night.withAlphaComponent(0.74), light: day.withAlphaComponent(0.70)))
    static let tertiary = CareStudioText(adaptive(dark: night.withAlphaComponent(0.56), light: day.withAlphaComponent(0.50)))
    static let hairline = adaptive(dark: night.withAlphaComponent(0.16), light: day.withAlphaComponent(0.12))
    static let tileFill = adaptive(dark: night.withAlphaComponent(0.10), light: night.withAlphaComponent(0.58))
    static let tileFillHover = adaptive(dark: night.withAlphaComponent(0.14), light: night.withAlphaComponent(0.74))
    static let pillFill = adaptive(dark: night.withAlphaComponent(0.16), light: night.withAlphaComponent(0.66))
    static let pillFillPressed = adaptive(dark: night.withAlphaComponent(0.26), light: night.withAlphaComponent(0.88))
    /// Panels that group rows on the gradient.
    static let panelFill = adaptive(dark: NSColor.black.withAlphaComponent(0.18), light: night.withAlphaComponent(0.52))
    /// Type on a `primary` fill (the filled pill, a ticked box).
    static let inverse = adaptive(dark: NSColor.black.withAlphaComponent(0.86), light: night)
    /// The sidebar's veil over the gradient.
    static let sidebarVeil = adaptive(dark: NSColor.black.withAlphaComponent(0.10), light: night.withAlphaComponent(0.22))
    /// D154: CleanMyMac's current-module block in the sidebar, and hover.
    static let sidebarSelection = adaptive(dark: night.withAlphaComponent(0.16), light: night.withAlphaComponent(0.70))
    static let sidebarHover = adaptive(dark: night.withAlphaComponent(0.07), light: night.withAlphaComponent(0.36))
    /// Report §4 item 16: the glass disc of the sidebar marks, its rim, and
    /// Smart Scan's yellow dot (CleanMyMac's #EECD57, `cmm/15`; a deeper
    /// amber on the light day sidebar).
    static let badgeFill = adaptive(dark: night.withAlphaComponent(0.16), light: night.withAlphaComponent(0.72))
    static let badgeRim = adaptive(dark: night.withAlphaComponent(0.32), light: day.withAlphaComponent(0.16))
    static let badgeAttention = adaptive(dark: srgb(0xEECD57), light: srgb(0xC8941A))
    /// Report §4 item 20: CleanMyMac's magenta "New" (`cmm/09`), deep enough
    /// for its white type (4.6:1 at night, 5.7:1 by day).
    static let newTag = adaptive(dark: srgb(0xB44AAE), light: srgb(0xA23C9C))

    /// D154: links, menus and native controls on a module's gradient — the
    /// module's light colour at night and its deep colour by day, so a link
    /// never takes the gradient's own hue (a teal link on teal).
    static func tint(for family: CareStudioFamily) -> Color {
        let palette = family.palette
        return adaptive(dark: srgb(palette.actionGlow), light: srgb(palette.action[1]))
    }

    /// D276: text that acts on a module's gradient (a menu's title, a link,
    /// a borderless button) along the lines `tint` starts from, moved until
    /// it reads 4.5:1 there. By day `tint` measured 1.8–3.2:1 on the deep
    /// corner, at night 2.3–3.1:1 on the glows. `tint` stays for fills: a
    /// white tick on a near-white box would vanish.
    static func actionText(for family: CareStudioFamily) -> Color {
        actionText(for: family, light: family.palette.actionGlow, deep: family.palette.action[1])
    }

    /// The same for a page whose accent is not its module's (overview, green).
    static func actionText(for family: CareStudioFamily, light: UInt32, deep: UInt32) -> Color {
        let palette = family.palette
        return adaptive(dark: srgb(palette.readableText(light, night: true)),
                        light: srgb(palette.readableText(deep, night: false)))
    }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

/// Rows, ticks and small icon buttons on studio pages: no chrome of their
/// own, a dimmed press. With the pill, capsule and round button it is the
/// studio's button family (D141).
struct CareStudioRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.62 : 1)
    }
}

/// Geometry of the studio pages, measured on the CleanMyMac screenshots
/// (1200 × 720 pt window; values rounded to our 4 pt grid).
enum CareStudioMetrics {
    static let actionDiameter: CGFloat = 84
    static let actionRingWidth: CGFloat = 3
    static let actionRingGap: CGFloat = 5
    static let actionBottomInset: CGFloat = 26
    /// The space the round button and its halo take at the bottom.
    static let actionBand: CGFloat = actionDiameter + actionBottomInset + 18
    static let landingArtSide: CGFloat = 300
    static let runningArtSide: CGFloat = 270
    static let titleSize: CGFloat = 38
    static let runningTitleSize: CGFloat = 32
    static let subtitleSize: CGFloat = 16
    /// D204: the landing list's names (CleanMyMac: about 17 pt beside a
    /// 29 pt icon, a line every 52 pt, `cmm/01`–`05`).
    static let bulletSize: CGFloat = 17
    static let bulletIconSide: CGFloat = 28
    /// Between lines that carry a reading under the name.
    static let bulletSpacing: CGFloat = 18
    /// Between names alone.
    static let bulletNameSpacing: CGFloat = 24
    static let tileCorner: CGFloat = 14
    static let tileSpacing: CGFloat = 14
    static let tilePadding: CGFloat = 18
    static let pageInset: CGFloat = 28
    static let managerInset: CGFloat = 8
    static let managerCorner: CGFloat = 12
}

private struct CareStudioClassicResultsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Shows the tiered classic result list instead of the studio tiles
    /// (tests of the classic list and its review screenshots set it).
    var careStudioClassicResults: Bool {
        get { self[CareStudioClassicResultsKey.self] }
        set { self[CareStudioClassicResultsKey.self] = newValue }
    }

    /// True inside a studio page: shared report panels draw the studio's
    /// flat translucent fill instead of glass, as CleanMyMac's cards do.
    var careStudioSurface: Bool {
        get { self[CareStudioSurfaceKey.self] }
        set { self[CareStudioSurfaceKey.self] = newValue }
    }

    /// D276: `CareStudioInk.actionText` of the page's module; the main window
    /// sets it on studio pages, nil elsewhere.
    var careStudioActionText: Color? {
        get { self[CareStudioActionTextKey.self] }
        set { self[CareStudioActionTextKey.self] = newValue }
    }

    /// D279: the module whose gradient the text stands on. The main window
    /// sets it on studio pages and the sidebar beside them; the light
    /// manager panels and the readiness panel clear it.
    var careStudioTextGround: CareStudioFamily? {
        get { self[CareStudioTextGroundKey.self] }
        set { self[CareStudioTextGroundKey.self] = newValue }
    }
}

private struct CareStudioSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

private struct CareStudioActionTextKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

private struct CareStudioTextGroundKey: EnvironmentKey {
    static let defaultValue: CareStudioFamily? = nil
}

/// D279: grey and status type in the main window. On a module's gradient
/// (`careStudioTextGround`) it takes the least change that reads 4.5:1
/// anywhere there: a translucent ink grows more opaque, up to full ink
/// (`readableOpacity`); a solid colour moves toward black by day and toward
/// white at night (`readableText`, as D276's action colour). Elsewhere it is
/// `base`. As a fill or a line a status colour keeps its own value, as
/// D276's tint does.
struct CareStudioText: ShapeStyle, Hashable {
    let base: Color

    init(_ base: Color) { self.base = base }

    func resolve(in environment: EnvironmentValues) -> Color {
        guard let family = environment.careStudioTextGround else { return base }
        return Self.readable(base.resolve(in: environment), on: family, night: environment.colorScheme == .dark)
    }

    /// `colour` as it reads on `family`'s gradient.
    static func readable(_ colour: Color.Resolved, on family: CareStudioFamily, night: Bool) -> Color {
        func byte(_ channel: Float) -> UInt32 { UInt32((min(1, max(0, Double(channel))) * 255).rounded()) }
        let hex = byte(colour.red) << 16 | byte(colour.green) << 8 | byte(colour.blue)
        let opacity = min(1, max(0, Double(colour.opacity)))
        let key = Key(hex: hex, opacity: Int((opacity * 1000).rounded()), family: family, night: night)
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let palette = family.palette
        let readable: Color
        if opacity < 0.999, let alpha = palette.readableOpacity(hex, from: opacity, night: night) {
            readable = CareStudioPalette.color(hex, opacity: alpha)
        } else {
            readable = CareStudioPalette.color(palette.readableText(hex, night: night))
        }
        cache.withLock { $0[key] = readable }
        return readable
    }

    private struct Key: Hashable {
        let hex: UInt32
        let opacity: Int
        let family: CareStudioFamily
        let night: Bool
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [Key: Color]())
}

/// D280: SwiftUI's own grey levels in the main window. A text's
/// `.foregroundStyle(.secondary)` draws the type it inherits at 50% and
/// `.tertiary` at 25% (measured on macOS 27), whatever levels
/// `foregroundStyle(_:_:_:)` set above it; only shapes, images and
/// containers take those levels. On a module's gradient
/// (`careStudioTextGround`) the level keeps the inherited type and its hue
/// and takes the least opacity, from its own up, at which the page's type
/// reads 4.5:1 there (`readableOpacity`), up to the full type. It is judged
/// with the lightest page type by day (`AppAppearanceColors.ink`) and the
/// darkest at night (the lightfield rows' `F2F5FF`). Elsewhere it is
/// SwiftUI's own level.
struct CareStudioHierarchyText: ShapeStyle, Hashable {
    enum Level: Hashable, Sendable { case secondary, tertiary }
    let level: Level

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        let own = level == .secondary ? HierarchicalShapeStyle.secondary : .tertiary
        guard let family = environment.careStudioTextGround,
              let opacity = Self.opacity(level, on: family, night: environment.colorScheme == .dark)
        else { return AnyShapeStyle(own) }
        return AnyShapeStyle(HierarchicalShapeStyle.primary.opacity(opacity))
    }

    /// The raised opacity on `family`'s gradient, nil where SwiftUI's own
    /// level already reads.
    static func opacity(_ level: Level, on family: CareStudioFamily, night: Bool) -> Double? {
        let key = Key(level: level, family: family, night: night)
        if let cached = cache.withLock({ $0[key] }) { return cached.value }
        let own = level == .secondary ? 0.5 : 0.25
        let ink: UInt32 = night ? 0xF2F5FF : 0x242426
        let needed = family.palette.readableOpacity(ink, from: own, night: night) ?? 1
        let value = needed > own ? needed : nil
        cache.withLock { $0[key] = Cached(value: value) }
        return value
    }

    private struct Key: Hashable {
        let level: Level
        let family: CareStudioFamily
        let night: Bool
    }

    private struct Cached {
        let value: Double?
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [Key: Cached]())
}

extension ShapeStyle where Self == CareStudioHierarchyText {
    /// D280: `.secondary` that reads on the page's module gradient.
    static var readableSecondary: CareStudioHierarchyText { CareStudioHierarchyText(level: .secondary) }
    /// D280: `.tertiary` that reads on the page's module gradient.
    static var readableTertiary: CareStudioHierarchyText { CareStudioHierarchyText(level: .tertiary) }
}

/// D276: a borderless menu or button draws its title in the tint, and on a
/// studio page the tint is the module's fill colour (`CareStudioInk.tint`),
/// so its title takes the readable action colour instead. Elsewhere, and
/// before the macOS 26 controls (as D274's menu tint), it keeps the tint it
/// inherits.
private struct CareStudioActionTint: ViewModifier {
    @Environment(\.careStudioActionText) private var actionText
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if let actionText { content.tint(actionText) } else { content }
        } else {
            content
        }
    }
}

extension View {
    func careStudioActionTint() -> some View { modifier(CareStudioActionTint()) }
}

/// A shared panel: glass on the classic pages, the studio's translucent
/// card on a studio gradient.
struct CareStudioAwarePanel: ViewModifier {
    @Environment(\.careStudioSurface) private var onStudio
    let cornerRadius: CGFloat
    let tint: Color

    func body(content: Content) -> some View {
        if onStudio {
            content
                .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(CareStudioInk.tileFill))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(CareStudioInk.hairline, lineWidth: 1))
        } else {
            content.glassPanel(cornerRadius: cornerRadius, tint: tint, prominence: .quiet)
        }
    }
}

/// Motion of the studio pages: CleanMyMac fades and blurs a page out and the
/// next one in, and lets the background drift only while a module works.
enum CareStudioMotion {
    static let pageChange = 0.32
    static let blur: CGFloat = 12
    static let driftPeriod = 14.0
    static let artFloatPeriod = 3.2
    static let artFloatDistance: CGFloat = 7
    static let artTilt = 5.0
    /// D154: one turn of the light ring behind a working picture.
    static let glowRingPeriod = 6.0
    /// D154: a landing picture swinging in, and a success mark popping
    /// (the curves are the shared `AppMotion` tokens).
    static let artArrival = AppMotion.arrival
    static let successPop = AppMotion.successPop
    /// D154: result tiles come in one after another.
    static let tileArrival = AppMotion.tileArrival
    static let tileStagger = 0.05
    /// D154 batch 3P: a completion page's amount starts counting while the
    /// success mark pops.
    static let countAfterSuccess = 0.2

    /// The delay of the tile at `index`; the tenth and later share one.
    static func tileDelay(_ index: Int) -> Double { Double(min(index, 9)) * tileStagger }

    static func animation(_ duration: Double, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
    }
}

extension GeneratedArt {
    /// The hue of the picture's body. D166: every module and tile picture is
    /// a Blender render measured on its 192 px export (D58 values were 215, 28,
    /// 30, 150, 145, 335, 335, 265, 340, 260, 265, 190, 192, 190, 195); the
    /// five D58 states keep the values their success rotation assumes.
    var dominantHue: Double {
        switch self {
        case .smartScan: 213
        case .cleanup: 25
        case .devCaches: 28
        case .health: 143
        case .privacy: 138
        case .benchmark: 342
        case .startup: 342
        case .memory: 250
        case .energy: 346
        case .uninstall: 244
        case .updater: 249
        case .fileAnalysis: 191
        case .migration: 193
        case .duplicates: 191
        case .similarPhotos: 195
        case .stateSuccess, .stateAllClear: 130
        case .stateEmpty, .statePermission, .stateError: 0
        case .performance: 28
        case .maintenance: 25
        case .applications: 213
        case .extensions: 214
        case .clutter: 177
        case .chatFiles: 178
        case .cloudCleanup: 209
        case .myTools: 241
        case .myActivity: 236
        case .stateCelebration: 121
        case .tileSystemJunk, .tileDevJunk, .tileAIClutter, .tileMail, .tileTrash, .tileReview: 115
        case .tileAppUpdates, .tileUnused, .tileLeftovers, .tileInstallers, .tileLegacyApps, .tileSystemUpdate,
             .tilePickApps, .tileAppStore, .tileOtherSources, .tileVendors: 213
        case .tileCompare: 177
        case .tileMaintenance, .tileLoginItems, .tileBackground, .tileSync, .tileAttention,
             .tilePressure, .tileTopApps, .tileFreeable, .tileProcesses: 25
        case .tileHistory, .tileSensitive, .tileCookies, .tileBrowsers: 331
        case .tileDownloaded, .tileLargeCloud, .tileCloudOnly, .tileOtherClouds: 209
        case .tileCleaned, .tileMonth, .tileCount, .tileRestore: 237
        // D166②, measured the same way.
        case .onboardWelcome: 289
        case .onboardDiskAccess: 290
        case .tileNotifications: 43
        case .tileGeneral: 210
        case .tileMiniWindow: 347
        case .tileScanSafety: 185
        case .tileSystemControl: 133
        // D166③, measured the same way.
        case .tilePurgeable: 26
        case .tilePermissions: 26
        case .tileQuickLook: 209
        case .tileScreenSaver: 209
        case .tileAudio: 208
        case .tileAppExtension: 210
        // D166④, measured the same way.
        case .protection: 331
        case .spaceMap: 234
        }
    }

    /// D166: the state pictures (an empty box, the all-clear shield, the lock,
    /// the warning sign) say what happened by their colour, so a module's
    /// page shows them as drawn instead of in the module colour.
    var keepsOwnColour: Bool {
        switch self {
        case .stateEmpty, .stateAllClear, .statePermission, .stateError: true
        default: false
        }
    }
}
