import Foundation

/// D-FP5: what a busy system process is, why it is busy, whether it calms
/// down on its own and what to do (MacOptimizer has three such notes; this
/// is our own, wider set, written for the memory and energy process rows).
/// Read-only: no note offers to end a system process.
struct SystemProcessNote: Identifiable, Equatable, Sendable {
    enum Match: Equatable, Sendable {
        case exact(String)
        case prefix(String)
        case suffix(String)
        case contains(String)

        func matches(_ name: String) -> Bool {
            switch self {
            case .exact(let value): name == value
            case .prefix(let value): name.hasPrefix(value)
            case .suffix(let value): name.hasSuffix(value)
            case .contains(let value): name.contains(value)
            }
        }

        /// The full name, for truncated process names (`p_comm` keeps 16
        /// bytes, `proc_name` 32).
        var fullName: String? {
            if case .exact(let value) = self { return value }
            return nil
        }
    }

    enum Settling: Equatable, Sendable {
        case finishesOnItsOwn
        case followsYourUse
        case staysRunning

        var title: String {
            switch self {
            case .finishesOnItsOwn: L10n.text("通常会自己降下来", "Usually calms down on its own")
            case .followsYourUse: L10n.text("随你的使用变化", "Follows what you are doing")
            case .staysRunning: L10n.text("一直在运行，平时占用很低", "Always running, usually light")
            }
        }
    }

    /// Another place in this app that helps.
    enum Related: Equatable, Sendable {
        case extensions
        case maintenance
        case mobileBackups
    }

    let id: String
    let matches: [Match]
    let title: String
    let whatItIs: String
    let whyBusy: String
    let settling: Settling
    let whatToDo: String
    var related: Related? = nil

    func matches(_ name: String) -> Bool {
        if matches.contains(where: { $0.matches(name) }) { return true }
        // A name cut to 15 or more characters still names one process.
        guard name.count >= 15 else { return false }
        return matches.contains { $0.fullName.map { $0.count > name.count && $0.hasPrefix(name) } ?? false }
    }
}

enum SystemProcessNotes {
    /// The note for a process row, by its executable's file name first
    /// (never truncated), then by its shown name.
    static func note(forName name: String, path: String? = nil) -> SystemProcessNote? {
        var candidates: [String] = []
        if let path, !path.isEmpty {
            candidates.append(URL(fileURLWithPath: path).lastPathComponent)
        }
        candidates.append(name)
        for candidate in candidates where !candidate.isEmpty {
            if let note = all.first(where: { $0.matches(candidate) }) { return note }
        }
        return nil
    }

    static func note(for process: MemoryProcess) -> SystemProcessNote? {
        note(forName: process.name, path: process.path)
    }

    private static func n(_ id: String, _ matches: [SystemProcessNote.Match], title: (String, String),
                          what: (String, String), why: (String, String), _ settling: SystemProcessNote.Settling,
                          todo: (String, String), related: SystemProcessNote.Related? = nil) -> SystemProcessNote {
        SystemProcessNote(id: id, matches: matches, title: L10n.text(title.0, title.1), whatItIs: L10n.text(what.0, what.1),
                          whyBusy: L10n.text(why.0, why.1), settling: settling, whatToDo: L10n.text(todo.0, todo.1),
                          related: related)
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: (key: String, notes: [SystemProcessNote])?

    /// In the current language, built once per language: process rows ask
    /// for every row on every redraw.
    static var all: [SystemProcessNote] {
        let key = L10n.text("zh", "en")
        return cacheLock.withLock {
            if let cache, cache.key == key { return cache.notes }
            let notes = build()
            cache = (key, notes)
            return notes
        }
    }

    private static func build() -> [SystemProcessNote] {
        [
            n("kernel", [.exact("kernel_task")],
              title: ("系统内核", "The Kernel"),
              what: ("macOS 的内核，负责调度处理器、内存和各种硬件。", "The core of macOS, which schedules the processor, memory and hardware."),
              why: ("温度高时，系统会让它暂时占住处理器，迫使其他程序慢下来降温，所以看起来占用很高；大量读写磁盘或外接设备时也会升高。",
                    "When the Mac is hot, macOS has it hold the processor so other work slows down and the Mac cools, so it looks busy; heavy disk or accessory traffic also raises it."),
              .finishesOnItsOwn,
              todo: ("让 Mac 降温：关掉暂时不用的重负载应用，保证出风口通畅，高温时避免边充电边重负载。它不能也不应该被结束。",
                     "Let the Mac cool: quit heavy apps you are not using, keep the vents clear, and avoid heavy work while charging in the heat. It cannot and should not be ended.")),
            n("windowserver", [.exact("WindowServer")],
              title: ("窗口服务器", "Window Server"),
              what: ("把所有窗口、动画和光标画到屏幕上的系统进程。", "The system process that draws every window, animation and the pointer."),
              why: ("窗口和标签页很多、接着高分辨率显示器、在录屏，或透明和动画效果多时会升高。",
                    "Many windows and tabs, high-resolution displays, screen recording, or lots of transparency and animation raise it."),
              .followsYourUse,
              todo: ("关掉不用的窗口；在“辅助功能 → 显示”里打开“减少透明度”和“减少动态效果”；拔掉暂时不用的显示器。结束它会直接退出登录。",
                     "Close windows you do not need; turn on Reduce transparency and Reduce motion in Accessibility › Display; disconnect displays you are not using. Ending it logs you out.")),
            n("spotlight", [.exact("mds"), .exact("mds_stores"), .prefix("mdworker"), .exact("mdbulkimport"), .exact("mdwrite"),
                            .exact("corespotlightd"), .prefix("spotlightknowledged"), .exact("managedcorespotlightd"),
                            .suffix(".SpotlightIndexExtension")],
              title: ("Spotlight 索引", "Spotlight Indexing"),
              what: ("为 Spotlight 搜索建立文件和应用内容的索引。", "Builds the index Spotlight searches, of files and app content."),
              why: ("大量新增或改动文件、刚升级系统、接上新磁盘或从备份恢复之后，要重新读取文件内容。",
                    "After many new or changed files, a system update, a new disk or a restore, it reads the files again."),
              .finishesOnItsOwn,
              todo: ("等它完成，几分钟到几小时不等。经常变动的大文件夹（编译目录、虚拟机）可以在 Spotlight 设置的“搜索隐私”里排除。",
                     "Let it finish; it takes minutes to hours. Large folders that change all the time (build folders, virtual machines) can be excluded under Search Privacy in Spotlight settings."),
              related: .maintenance),
            n("photos", [.exact("photoanalysisd"), .exact("mediaanalysisd"), .exact("photolibraryd"), .exact("cloudphotod")],
              title: ("照片分析与同步", "Photos Analysis and Sync"),
              what: ("识别照片里的人物、场景和文字，生成回忆，并和 iCloud 照片同步。",
                     "Recognises people, scenes and text in photos, makes Memories, and syncs with iCloud Photos."),
              why: ("导入大量照片、刚升级系统或第一次打开 iCloud 照片后会集中处理。",
                    "It catches up after a big import, a system update, or turning on iCloud Photos."),
              .finishesOnItsOwn,
              todo: ("接上电源让它在空闲时做完；你开始用 Mac 时它会自动放慢。", "Keep the Mac on power and let it finish while idle; it slows down when you use the Mac.")),
            n("backup", [.exact("backupd"), .exact("backupd-helper")],
              title: ("Time Machine 备份", "Time Machine Backup"),
              what: ("Time Machine 正在备份。", "Time Machine is backing up."),
              why: ("第一次备份，或改动了很多文件之后，要备份的内容多。", "A first backup, or many changed files, means a lot to copy."),
              .finishesOnItsOwn,
              todo: ("等备份完成；经常变动又不需要备份的大文件夹，可以在 Time Machine 设置里排除。",
                     "Let the backup finish; large folders that change often and need no backup can be excluded in Time Machine settings.")),
            n("icloud", [.exact("cloudd"), .exact("bird"), .exact("fileproviderd"), .exact("com.apple.CloudDocs.iCloudDriveFileProvider"),
                         .exact("itunescloudd"), .exact("CMFSyncAgent")],
              title: ("iCloud 同步", "iCloud Sync"),
              what: ("在这台 Mac 和 iCloud 之间上传、下载文件和数据。", "Uploads and downloads files and data between this Mac and iCloud."),
              why: ("同步大量文件，或“优化 Mac 储存空间”正在下载、移除本地副本时会升高。",
                    "Syncing many files, or Optimize Mac Storage downloading or removing local copies, raises it."),
              .finishesOnItsOwn,
              todo: ("等同步完成；在访达边栏的 iCloud 云盘旁能看到进度。", "Let the sync finish; the progress shows next to iCloud Drive in the Finder sidebar.")),
            n("downloads", [.exact("nsurlsessiond")],
              title: ("后台下载", "Background Transfers"),
              what: ("替各个应用在后台下载和上传，比如 App Store、iCloud 和播客。", "Downloads and uploads in the background for apps such as the App Store, iCloud and Podcasts."),
              why: ("有应用在下载大文件或更新时。", "An app is downloading a large file or an update."),
              .finishesOnItsOwn,
              todo: ("看看是否有应用正在下载更新；下载完成后会降下来。", "Check whether an app is downloading an update; it drops when the download ends.")),
            n("updates", [.exact("softwareupdated"), .exact("mobileassetd"), .exact("installd"), .exact("system_installd"),
                          .exact("suhelperd"), .prefix("com.apple.MobileAsset"), .exact("SoftwareUpdateNotificationManager")],
              title: ("系统更新与资源下载", "System Updates and Assets"),
              what: ("下载、准备和安装系统更新，以及语音、字体、AI 模型等系统资源。",
                     "Downloads, prepares and installs system updates and system assets such as voices, fonts and AI models."),
              why: ("有更新正在下载或准备安装时。", "An update is downloading or being prepared."),
              .finishesOnItsOwn,
              todo: ("让它完成；装好待安装的更新后会恢复正常。", "Let it finish; it returns to normal once the pending update is installed.")),
            n("security", [.exact("XprotectService"), .exact("XProtectBridgeService"), .exact("xprotectd"), .exact("syspolicyd"),
                           .exact("amfid"), .exact("trustd"), .exact("com.apple.CodeSigningHelper")],
              title: ("安全检查", "Security Checks"),
              what: ("检查应用和下载文件的签名，以及有没有已知的恶意软件（Gatekeeper、XProtect）。",
                     "Checks the signatures of apps and downloads and looks for known malware (Gatekeeper, XProtect)."),
              why: ("第一次打开应用、下载大量文件，或 XProtect 刚更新特征时会集中检查。",
                    "Opening an app for the first time, many downloads, or a fresh XProtect update bring a burst of checks."),
              .finishesOnItsOwn,
              todo: ("通常很快结束。如果某个应用每次打开都引起长时间检查，它的签名可能已损坏，重新安装它。",
                     "It is usually brief. If one app causes long checks every time it opens, its signature may be damaged; reinstall it.")),
            n("audio", [.exact("coreaudiod"), .exact("audiomxd"), .exact("usbaudiod"), .prefix("Core Audio Driver ("),
                        .exact("AudioComponentRegistrar")],
              title: ("音频服务", "Audio"),
              what: ("macOS 的声音系统，负责所有播放和录音。名字带“Core Audio Driver”的是第三方音频驱动。",
                     "The macOS sound system behind all playback and recording. Names with “Core Audio Driver” are third-party audio drivers."),
              why: ("多个应用同时播放或录音、用了很多音频插件，或某个音频驱动有问题时。",
                    "Several apps playing or recording at once, many audio plug-ins, or a misbehaving audio driver."),
              .followsYourUse,
              todo: ("退出不用的音频应用；不再用的虚拟声卡和音频插件可以在“扩展”页查看。",
                     "Quit audio apps you are not using; virtual sound devices and audio plug-ins you no longer use are listed on the Extensions page."),
              related: .extensions),
            n("crash", [.exact("ReportCrash"), .exact("spindump"), .exact("spindump_agent"), .exact("tailspind"),
                        .exact("osanalyticshelper"), .exact("CrashReporterSupportHelper")],
              title: ("崩溃与卡顿报告", "Crash and Hang Reports"),
              what: ("有应用崩溃或卡住时，记下当时的情况写成报告。", "Records what happened when an app crashed or hung, as a report."),
              why: ("刚有应用崩溃或卡死；如果一直很高，说明有应用在反复崩溃。", "An app just crashed or hung; if it stays busy, an app keeps crashing."),
              .finishesOnItsOwn,
              todo: ("找到反复崩溃的应用（“控制台”的“崩溃报告”里能看到），更新或重新安装它。",
                     "Find the app that keeps crashing (Console › Crash Reports shows it) and update or reinstall it.")),
            n("logging", [.exact("logd"), .exact("logd_helper"), .exact("syslogd")],
              title: ("系统日志", "System Log"),
              what: ("收集所有应用和系统写下的日志。", "Collects what apps and macOS write to the log."),
              why: ("某个应用在大量写日志时。", "An app is writing a lot to the log."),
              .staysRunning,
              todo: ("通常是某个应用出了问题在刷日志；更新或退出最近装的应用看看。", "Usually an app with a problem is flooding the log; update or quit the app you installed most recently.")),
            n("preferences", [.exact("cfprefsd"), .exact("distnoted"), .exact("notifyd")],
              title: ("设置与通知分发", "Settings and Notifications Relay"),
              what: ("读写应用的设置，并在进程之间转发通知。", "Reads and writes apps' settings and passes notifications between processes."),
              why: ("某个应用在不停读写自己的设置时。", "An app keeps reading or writing its settings."),
              .staysRunning,
              todo: ("通常是某个应用的问题：最近装或更新的应用最可疑，退出它看是否下降。",
                     "Usually caused by an app: the most recently installed or updated one is the likeliest; quit it and watch.")),
            n("intelligence", [.exact("siriknowledged"), .exact("siriinferenced"), .exact("suggestd"), .exact("knowledge-agent"),
                               .exact("biomed"), .exact("biomesyncd"), .exact("duetexpertd"), .exact("proactived"),
                               .exact("IntelligencePlatformComputeService"), .exact("generativeexperiencesd"),
                               .exact("modelmanagerd"), .exact("modelcatalogd"), .exact("ModelCatalogAgent"),
                               .prefix("intelligence"), .exact("textunderstandingd"), .exact("naturallanguaged"),
                               .exact("mlhostd"), .exact("ANECompilerService"), .exact("aned"), .exact("assistantd")],
              title: ("Siri 与 Apple 智能", "Siri and Apple Intelligence"),
              what: ("在本机学习使用习惯、处理 Siri 和 Apple 智能的请求、准备设备上的模型。",
                     "Learns usage patterns on this Mac, handles Siri and Apple Intelligence requests and prepares on-device models."),
              why: ("刚打开 Apple 智能或系统更新后在下载、编译模型，或在空闲时整理学习数据。",
                    "It downloads or compiles models after Apple Intelligence is turned on or macOS updates, or tidies its data while idle."),
              .finishesOnItsOwn,
              todo: ("接上电源让它做完；不用这些功能可以在系统设置里关闭 Siri 或 Apple 智能。",
                     "Keep the Mac on power and let it finish; if you do not use them, Siri and Apple Intelligence can be turned off in System Settings.")),
            n("webkit", [.prefix("com.apple.WebKit.")],
              title: ("网页内容（Safari 等）", "Web Content (Safari and Others)"),
              what: ("Safari 和用网页技术做的应用，每个标签页或网页都有自己的进程。",
                     "Safari and apps built on web technology give each tab or page its own process."),
              why: ("某个网页在播放视频、动画、广告或运行脚本。", "A page is playing video, animations or ads, or running scripts."),
              .followsYourUse,
              todo: ("关掉不用的标签页；活动监视器里能看出是哪个网页。", "Close tabs you do not need; Activity Monitor shows which page it is.")),
            n("browserHelpers", [.contains("Helper (Renderer)"), .contains("Helper (GPU)"), .contains("Helper (Plugin)"),
                                 .prefix("Google Chrome Helper"), .prefix("Microsoft Edge Helper"), .prefix("Brave Browser Helper")],
              title: ("浏览器或 Electron 应用的子进程", "Browser or Electron App Helpers"),
              what: ("Chrome、Edge 和许多用 Electron 做的应用，把每个页面和插件放在单独的子进程里。",
                     "Chrome, Edge and many Electron apps run each page and extension in its own helper process."),
              why: ("某个标签页、插件或应用窗口很忙。", "A tab, an extension or an app window is busy."),
              .followsYourUse,
              todo: ("在对应应用里关掉不用的页面或插件；Chrome 可以用“窗口 → 任务管理器”看是哪个页面。",
                     "Close pages or extensions you do not need in that app; in Chrome, Window › Task Manager shows which page it is.")),
            n("video", [.exact("VTDecoderXPCService"), .exact("VTEncoderXPCService")],
              title: ("视频编解码", "Video Decoding and Encoding"),
              what: ("替应用解码播放视频，或在录屏、导出时编码视频。", "Decodes video for playback and encodes it for recording or export."),
              why: ("正在播放高分辨率视频、视频通话、录屏或导出视频。", "High-resolution playback, a video call, screen recording or an export is running."),
              .followsYourUse,
              todo: ("停止播放或导出后会降下来。", "It drops when playback or the export stops.")),
            n("thumbnails", [.exact("QuickLookSatellite"), .exact("QuickLookUIService"), .exact("com.apple.quicklook.ThumbnailsAgent"),
                             .suffix("ThumbnailExtension")],
              title: ("缩略图与快速查看", "Thumbnails and Quick Look"),
              what: ("为访达和“快速查看”生成文件缩略图和预览。", "Makes file thumbnails and previews for the Finder and Quick Look."),
              why: ("打开了文件很多的文件夹，或在预览很大的文件。", "A folder with many files is open, or a large file is being previewed."),
              .finishesOnItsOwn,
              todo: ("等缩略图生成完；文件特别多的文件夹可以改用列表视图。", "Let the thumbnails finish; use list view for folders with very many files.")),
            n("finder", [.exact("Finder")],
              title: ("访达", "Finder"),
              what: ("文件管理器。", "The file manager."),
              why: ("计算文件夹大小、复制大量文件、连接网络共享或生成预览时。",
                    "Calculating folder sizes, copying many files, browsing network shares or making previews."),
              .followsYourUse,
              todo: ("等复制或计算完成；在“显示 → 查看显示选项”里关掉“计算所有大小”。",
                     "Let the copy or calculation finish; turn off Calculate all sizes in View › Show View Options.")),
            n("devices", [.exact("AMPDeviceDiscoveryAgent"), .exact("AMPLibraryAgent"), .exact("AMPDevicesAgent"),
                          .exact("MobileDeviceUpdater"), .exact("usbmuxd")],
              title: ("iPhone、iPad 同步与备份", "iPhone and iPad Sync and Backup"),
              what: ("发现连接的 iPhone、iPad，同步内容或做备份。", "Finds connected iPhones and iPads and syncs or backs them up."),
              why: ("设备连着并在备份或同步。", "A device is connected and backing up or syncing."),
              .finishesOnItsOwn,
              todo: ("等备份完成再断开；旧的设备备份可以在“iOS 备份”里查看。", "Wait for the backup before disconnecting; old device backups are listed under iOS Backups."),
              related: .mobileBackups),
            n("continuity", [.exact("sharingd"), .exact("rapportd"), .exact("UniversalControl"), .exact("SidecarRelay"),
                             .exact("ContinuityCaptureAgent"), .exact("nearbyd")],
              title: ("接力、隔空投送与通用控制", "Handoff, AirDrop and Universal Control"),
              what: ("让 Mac 和附近的 Apple 设备互相发现、传文件、共享剪贴板。", "Lets the Mac and nearby Apple devices find each other, share files and the clipboard."),
              why: ("正在搜索附近设备或传送文件。", "It is looking for nearby devices or transferring files."),
              .followsYourUse,
              todo: ("不用时可以在控制中心关掉隔空投送，或在“通用 → 隔空投送与接力”里关闭接力。",
                     "Turn off AirDrop in Control Center, or Handoff in General › AirDrop & Handoff, when you do not use them.")),
            n("bluetooth", [.exact("bluetoothd"), .exact("bluetoothuserd"), .exact("BTLEServer"), .exact("BTLEServerAgent")],
              title: ("蓝牙", "Bluetooth"),
              what: ("管理蓝牙连接。", "Manages Bluetooth connections."),
              why: ("连着的蓝牙设备多、信号干扰，或某个设备在更新固件。", "Many connected devices, interference, or a device updating its firmware."),
              .followsYourUse,
              todo: ("断开不用的蓝牙设备。", "Disconnect Bluetooth devices you do not use.")),
            n("accounts", [.exact("accountsd"), .exact("dataaccessd"), .exact("CalendarAgent"), .exact("contactsd"),
                           .exact("remindd"), .exact("maild"), .exact("IMDPersistenceAgent"), .exact("imagent")],
              title: ("账户与信息同步", "Accounts and Messages Sync"),
              what: ("同步邮件、日历、通讯录、提醒事项和信息。", "Syncs Mail, Calendar, Contacts, Reminders and Messages."),
              why: ("刚添加账户，或有大量邮件、信息到达时。", "An account was just added, or a lot of mail or messages arrived."),
              .finishesOnItsOwn,
              todo: ("等同步完成；某个账户一直同步不成功时，在“互联网账户”里重新登录它。",
                     "Let it finish; if one account never finishes syncing, sign in to it again in Internet Accounts.")),
            n("power", [.exact("powerd"), .exact("thermalmonitord"), .exact("PerfPowerServices"), .exact("powerexperienced"),
                        .exact("peakpowermanagerd"), .exact("dasd")],
              title: ("电源、温度与后台调度", "Power, Thermal and Background Scheduling"),
              what: ("管理睡眠、电池和温度，并决定后台任务什么时候运行（比如接上电源、空闲时）。",
                     "Manages sleep, battery and temperature, and decides when background work runs (on power, while idle)."),
              why: ("通常占用很低；短暂升高是在记录能耗数据或安排一批后台任务。",
                    "Usually light; a brief rise is it recording energy data or scheduling background work."),
              .staysRunning,
              todo: ("无需处理。", "Nothing to do.")),
            n("fsevents", [.exact("fseventsd")],
              title: ("文件变动记录", "File Change Log"),
              what: ("记录磁盘上的文件变动，供 Spotlight、Time Machine 等使用。", "Records file changes on disk for Spotlight, Time Machine and others."),
              why: ("大量文件被创建或删除时，比如解压、编译或同步。", "Many files are being created or deleted, as when unpacking, building or syncing."),
              .finishesOnItsOwn,
              todo: ("等那批文件操作完成。", "Let that batch of file work finish.")),
            n("keychain", [.exact("secd"), .exact("securityd"), .exact("securityd_system"), .exact("coreauthd")],
              title: ("钥匙串", "Keychain"),
              what: ("管理钥匙串里的密码、密钥和证书。", "Manages the passwords, keys and certificates in the keychain."),
              why: ("有应用在反复查询钥匙串。", "An app keeps querying the keychain."),
              .finishesOnItsOwn,
              todo: ("通常很快恢复；一直很高时，最近装的应用可能有问题。", "It usually recovers quickly; if it stays high, a recently installed app may be at fault.")),
            n("shell", [.exact("Dock"), .exact("ControlCenter"), .exact("NotificationCenter"), .exact("SystemUIServer"),
                        .exact("WindowManager"), .prefix("WidgetRenderer")],
              title: ("程序坞、菜单栏与小组件", "Dock, Menu Bar and Widgets"),
              what: ("程序坞、菜单栏、控制中心、通知中心、小组件和台前调度。",
                     "The Dock, menu bar, Control Center, Notification Center, widgets and Stage Manager."),
              why: ("动画多、菜单栏项目多，或小组件在刷新时。", "Many animations, many menu bar items, or widgets refreshing."),
              .followsYourUse,
              todo: ("减少菜单栏项目和桌面小组件；不用台前调度可以关掉。", "Trim menu bar items and desktop widgets; turn off Stage Manager if you do not use it.")),
            n("network", [.exact("mDNSResponder"), .exact("mDNSResponderHelper"), .exact("configd"), .exact("airportd"),
                          .exact("WiFiAgent"), .exact("symptomsd")],
              title: ("网络服务", "Network Services"),
              what: ("解析网站地址、管理 Wi‑Fi 和网络设置。", "Resolves website addresses and manages Wi‑Fi and network settings."),
              why: ("切换网络或有大量网络连接时。", "Switching networks or many network connections."),
              .followsYourUse,
              todo: ("无需处理；网络异常时重新连接 Wi‑Fi 试试。", "Nothing to do; if the network misbehaves, reconnect to Wi‑Fi."),
              related: .maintenance),
            n("shaders", [.exact("MTLCompilerService")],
              title: ("图形程序编译", "Graphics Shader Compiling"),
              what: ("为游戏和图形应用编译显卡程序。", "Compiles graphics programs for games and graphics apps."),
              why: ("第一次打开游戏或图形应用，或系统更新之后。", "The first launch of a game or graphics app, or after a system update."),
              .finishesOnItsOwn,
              todo: ("等编译完成，之后再打开会快。", "Let it finish; later launches are faster.")),
            n("purge", [.exact("deleted"), .exact("deleted_helper")],
              title: ("释放可清除空间", "Freeing Purgeable Space"),
              what: ("磁盘空间不够时，系统删除可清除的内容（缓存、本地快照等）。",
                     "When the disk runs short, macOS deletes purgeable content such as caches and local snapshots."),
              why: ("磁盘快满了，它在腾空间。", "The disk is nearly full and it is making room."),
              .finishesOnItsOwn,
              todo: ("让它做完；清理大文件和垃圾能减少它工作的次数。", "Let it finish; cleaning up large files and junk means it has to work less often.")),
            n("analytics", [.exact("analyticsd"), .exact("SubmitDiagInfo"), .exact("triald"), .exact("triald_system"),
                            .exact("diagnosticservicesd")],
              title: ("诊断与改进数据", "Diagnostics and Improvement Data"),
              what: ("整理诊断数据和系统功能试验的配置。", "Prepares diagnostic data and settings for system feature trials."),
              why: ("定期整理诊断数据，并在你同意共享时上传。", "It tidies diagnostic data on schedule and uploads it if you agreed to share."),
              .finishesOnItsOwn,
              todo: ("可以在“隐私与安全性 → 分析与改进”里关闭共享。", "Sharing can be turned off in Privacy & Security › Analytics & Improvements.")),
        ]
    }
}
