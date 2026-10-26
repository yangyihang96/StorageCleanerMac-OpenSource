import Foundation

/// D-FP2: the maintenance tasks page (CleanMyMac's Performance ›
/// Maintenance Tasks list, Mac Sai's practice of saying what each task does
/// before it runs). This app runs only the tasks a normal user can run
/// safely: speeding up Mail and refreshing the "Open With" database. Tasks
/// that need an administrator are explained, with Apple's own way to do
/// them; nothing here elevates (L1–L8, D100).
enum SystemMaintenanceTaskID: String, CaseIterable, Identifiable, Codable, Sendable {
    case freeUpMemory
    case purgeableSpace
    case flushDNS
    case speedUpMail
    case rebuildSpotlight
    case repairPermissions
    case maintenanceScripts
    case timeMachineSnapshots
    case rebuildLaunchServices

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freeUpMemory: L10n.text("释放内存", "Free Up RAM")
        case .purgeableSpace: L10n.text("可清除空间", "Purgeable Space")
        case .flushDNS: L10n.text("刷新 DNS 缓存", "Flush DNS Cache")
        case .speedUpMail: L10n.text("加速邮件", "Speed Up Mail")
        case .rebuildSpotlight: L10n.text("重建 Spotlight 索引", "Rebuild Spotlight Index")
        case .repairPermissions: L10n.text("修复磁盘权限", "Repair Disk Permissions")
        case .maintenanceScripts: L10n.text("运行维护脚本", "Run Maintenance Scripts")
        case .timeMachineSnapshots: L10n.text("Time Machine 本地快照", "Time Machine Local Snapshots")
        case .rebuildLaunchServices: L10n.text("刷新“打开方式”数据库", "Refresh the “Open With” Database")
        }
    }

    var systemImage: String {
        switch self {
        case .freeUpMemory: "memorychip"
        case .purgeableSpace: "internaldrive"
        case .flushDNS: "network"
        case .speedUpMail: "envelope"
        case .rebuildSpotlight: "magnifyingglass"
        case .repairPermissions: "lock.rotation"
        case .maintenanceScripts: "scroll"
        case .timeMachineSnapshots: "clock.arrow.circlepath"
        case .rebuildLaunchServices: "arrow.up.forward.app"
        }
    }

    /// What the task does.
    var summary: String {
        switch self {
        case .freeUpMemory:
            L10n.text("让系统收回暂时用不到的内存。在“释放内存”页运行，那里会先看内存压力，只报实测结果。",
                      "Lets macOS take back memory that is not needed right now. It runs on the Free Up RAM page, which checks memory pressure first and reports only what it measured.")
        case .purgeableSpace:
            L10n.text("可清除空间是系统需要时会自己释放的部分，比如本地快照、可以重新下载的 iCloud 文件和缓存。它已经算在可用空间里。",
                      "Purgeable space is what macOS frees on its own when it needs room, such as local snapshots, iCloud files that can be downloaded again, and caches. It already counts as available.")
        case .flushDNS:
            L10n.text("清掉记住的网站地址，网站换了地址却一直打不开时有用。切换网络时系统会自动刷新。",
                      "Clears remembered website addresses; useful when a site moved and keeps failing to open. macOS also flushes it when the network changes.")
        case .speedUpMail:
            L10n.text("整理“邮件”的邮件索引数据库，回收删除邮件后留下的空位，让搜索和打开邮箱更快。",
                      "Compacts Mail's message index database, taking back the space deleted messages left, so searching and opening mailboxes is faster.")
        case .rebuildSpotlight:
            L10n.text("Spotlight 搜不到明明存在的文件时，重建索引能修好。",
                      "When Spotlight cannot find files that are there, rebuilding its index fixes it.")
        case .repairPermissions:
            L10n.text("现在的 macOS 由系统完整性保护（SIP）管住系统文件的权限，不再需要“修复权限”。怀疑磁盘有问题时用“磁盘工具”的“急救”。",
                      "macOS now keeps system file permissions under System Integrity Protection, so repairing permissions is no longer needed. If you suspect a disk problem, use First Aid in Disk Utility.")
        case .maintenanceScripts:
            L10n.text("旧版 macOS 每天、每周、每月运行的系统清理脚本。",
                      "System clean-up scripts older macOS ran daily, weekly and monthly.")
        case .timeMachineSnapshots:
            L10n.text("Time Machine 在本机保留的快照，用来找回最近改动的文件。空间不够时系统会自动删除最旧的。",
                      "Snapshots Time Machine keeps on this Mac to recover recent changes. macOS deletes the oldest automatically when space runs low.")
        case .rebuildLaunchServices:
            L10n.text("清掉已删除应用留下的记录，并重新登记各个“应用程序”文件夹里的应用。“打开方式”菜单里出现重复或失效的应用、文件图标不对时有用。",
                      "Removes records left by deleted apps and registers the apps in the Applications folders again. Useful when the Open With menu shows duplicate or missing apps, or file icons look wrong.")
        }
    }

    /// What happens when it runs, said before it runs (Mac Sai's practice).
    var consequence: String? {
        switch self {
        case .speedUpMail:
            L10n.text("运行前需要退出“邮件”，并给本应用完全磁盘访问权限。会先把索引备份到本应用的文件夹，再整理；整理期间不要打开“邮件”。邮件本身不会改动。",
                      "Mail must be closed and this app needs Full Disk Access. The index is backed up to this app's folder before it is compacted; do not open Mail meanwhile. Messages themselves are not changed.")
        case .rebuildLaunchServices:
            L10n.text("大约需要一两分钟。期间“打开方式”菜单和文件图标可能暂时不完整，双击文件偶尔会打不开，完成后恢复。默认打开方式的设置不会改动。",
                      "Takes a minute or two. Meanwhile the Open With menu and file icons may be incomplete and a double-click may occasionally fail; it recovers when done. Your default apps are not changed.")
        default:
            nil
        }
    }

    /// A Terminal command the user can run themselves where the task needs
    /// an administrator; this app never runs it.
    var administratorCommand: String? {
        switch self {
        case .flushDNS: "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
        default: nil
        }
    }
}

/// Where a task is done.
enum SystemMaintenanceTaskMode: Equatable, Sendable {
    /// This app runs it, after a confirmation that says what will happen.
    case runnable
    /// Done on another page of this app or in a system app.
    case elsewhere(SystemMaintenanceDestination)
    /// Reading only; macOS manages it.
    case informational
    /// Needs an administrator; explained, never elevated.
    case administratorRequired
    /// This version of macOS no longer has it.
    case notNeeded

    var isRunnable: Bool { self == .runnable }
}

enum SystemMaintenanceDestination: String, Equatable, Sendable {
    case freeUpMemoryPage
    case spotlightSettings
    case diskUtility
    case timeMachineSettings

    var title: String {
        switch self {
        case .freeUpMemoryPage: L10n.text("前往“释放内存”", "Go to Free Up RAM")
        case .spotlightSettings: L10n.text("打开 Spotlight 设置", "Open Spotlight Settings")
        case .diskUtility: L10n.text("打开“磁盘工具”", "Open Disk Utility")
        case .timeMachineSettings: L10n.text("打开 Time Machine 设置", "Open Time Machine Settings")
        }
    }

    /// The system URL; nil for a page of this app.
    var url: URL? {
        switch self {
        case .freeUpMemoryPage: nil
        case .spotlightSettings: URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")
        case .diskUtility: URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app")
        case .timeMachineSettings: URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")
        }
    }
}

/// What a read-only look found for one task.
struct SystemMaintenanceStatus: Equatable, Sendable {
    var mode: SystemMaintenanceTaskMode
    /// Short lines under the title: sizes, counts, dates, why it cannot run.
    var lines: [String] = []
    /// Shown as a recommendation on the results tile.
    var isRecommended = false
    /// Why a runnable task cannot run right now (Mail open, no access).
    var blocker: String? = nil
    /// The blocker is the missing Full Disk Access (the page links to it).
    var needsFullDiskAccess = false
}

/// What a run did, said in measured terms.
struct SystemMaintenanceRunResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case succeeded, refused, failed }
    let task: SystemMaintenanceTaskID
    let outcome: Outcome
    let message: String
    var detail: [String] = []
    let finishedAt: Date
}

struct SystemMaintenanceSummary: Equatable, Sendable {
    let runnableCount: Int
    let recommendedCount: Int
}
