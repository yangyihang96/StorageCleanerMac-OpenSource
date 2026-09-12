import Foundation

/// Normalized startup-item domain shared by scanning, management and UI.
enum StartupItemsDomain {
    enum ItemKind: String, CaseIterable, Codable, Hashable, Sendable {
        case openAtLogin
        case loginItem
        case userLaunchAgent
        case globalLaunchAgent
        case systemLaunchAgent
        case launchDaemon
        case systemLaunchDaemon
        case appBackgroundTask
        case embeddedHelper
        case privilegedHelper
        case managedItem
        case orphanedItem
        case unknown
    }

    enum Scope: String, Codable, Hashable, Sendable {
        case currentUser
        case allUsers
        case system
        case applicationBundle
        case managed
        case unknown
    }

    enum ScanSource: String, Codable, Hashable, Sendable {
        case openAtLogin
        case serviceManagement
        case backgroundTaskDiagnostic
        case launchdPlist
        case embeddedService
        case launchdRuntime
        case legacyServiceManagement
        case privilegedHelper
        case managedConfiguration
        case orphanDetection
        case unknown
    }

    enum RegistrationState: String, Codable, Hashable, Sendable {
        case registered
        case notRegistered
        case legacyRegistered
        case discoveredFromFile
        case unknown
    }

    enum AuthorizationState: String, Codable, Hashable, Sendable {
        case approved
        case requiresApproval
        case denied
        case managed
        case notApplicable
        case unknown
    }

    enum EnablementState: String, Codable, Hashable, Sendable {
        case enabled
        case disabled
        case temporarilyStopped
        case unknown
    }

    enum LoadState: String, Codable, Hashable, Sendable {
        case loaded
        case notLoaded
        case onDemand
        case unavailable
        case unknown
    }

    enum ProcessState: Hashable, Sendable {
        case running(pid: Int32)
        case stopped
        case waiting
        case failed(exitCode: Int32)
        case unknown
    }

    enum ManagementState: String, Codable, Hashable, Sendable {
        case directlyManageable
        case manageableInSystemSettings
        case requiresAdministrator
        case managedByOrganization
        case systemProtected
        case unsupported
        case readOnly
    }

    /// A file/configuration result intentionally kept separate from launchd
    /// enablement and runtime state. A disabled agent can still have a valid
    /// plist, and a running process can still point at a missing executable.
    enum ConfigurationState: String, Codable, Hashable, Sendable {
        case valid
        case executableMissing
        case plistMissing
        case malformed
        case signatureInvalid
        case orphaned
        case unknown
    }

    struct State: Hashable, Sendable {
        var registration: RegistrationState
        var authorization: AuthorizationState
        var enablement: EnablementState
        var load: LoadState
        var process: ProcessState
        var management: ManagementState

        static let unknown = State(
            registration: .unknown,
            authorization: .unknown,
            enablement: .unknown,
            load: .unknown,
            process: .unknown,
            management: .unsupported
        )
    }

    struct ActionCapability: Codable, Hashable, Sendable {
        var canEnableDirectly: Bool
        var canDisableDirectly: Bool
        var canStopCurrentSession: Bool
        var canOpenSystemSettings: Bool
        var canRevealInFinder: Bool
        var canOpenParentApp: Bool
        var canRemoveOrphan: Bool
        var requiresAdministrator: Bool
        var isReadOnly: Bool
        var isManaged: Bool

        static let readOnly = ActionCapability(
            canEnableDirectly: false,
            canDisableDirectly: false,
            canStopCurrentSession: false,
            canOpenSystemSettings: false,
            canRevealInFinder: true,
            canOpenParentApp: false,
            canRemoveOrphan: false,
            requiresAdministrator: false,
            isReadOnly: true,
            isManaged: false
        )
    }

    enum AttributionConfidence: Int, Codable, Comparable, Hashable, Sendable {
        case unknown = 0
        case low = 1
        case medium = 2
        case high = 3
        case verified = 4

        static func < (lhs: AttributionConfidence, rhs: AttributionConfidence) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    enum AttributionEvidenceKind: String, Codable, Hashable, Sendable {
        case backgroundTaskManagement
        case associatedBundleIdentifier
        case embeddedInApplication
        case executableBundleIdentifier
        case signingTeamIdentifier
        case designatedRequirement
        case applicationPath
        case packageReceipt
        case installedApplicationIndex
        case labelHint
    }

    struct AttributionEvidence: Codable, Hashable, Sendable {
        let kind: AttributionEvidenceKind
        let value: String
        let confidence: AttributionConfidence
    }

    struct Attribution: Codable, Hashable, Sendable {
        var applicationBundleIdentifier: String?
        var applicationURL: URL?
        var applicationName: String?
        var developerName: String?
        var teamIdentifier: String?
        var designatedRequirement: String?
        var evidence: [AttributionEvidence]

        var confidence: AttributionConfidence {
            evidence.map(\.confidence).max() ?? .unknown
        }
    }

    struct CalendarSchedule: Codable, Hashable, Sendable {
        var minute: Int?
        var hour: Int?
        var day: Int?
        var weekday: Int?
        var month: Int?
    }

    enum LaunchTrigger: Hashable, Sendable {
        case login
        case systemBoot
        case runAtLoad
        case keepAlive
        case interval(seconds: Int)
        case calendar([CalendarSchedule])
        case watchPaths([String])
        case queueDirectories([String])
        case machServices([String])
        case sockets([String])
        case onDemand
        case unknown

        var userFacingDescription: String {
            switch self {
            case .login:
                L10n.text("登录时启动", "Starts at login")
            case .systemBoot:
                L10n.text("系统启动时加载", "Loads at system startup")
            case .runAtLoad:
                L10n.text("载入时启动", "Runs when loaded")
            case .keepAlive:
                L10n.text("始终保持运行", "Kept running")
            case let .interval(seconds):
                L10n.text("每 \(Self.intervalText(seconds))运行", "Runs every \(Self.intervalText(seconds))")
            case let .calendar(schedules):
                schedules.first.map(Self.calendarText) ?? L10n.text("按计划运行", "Runs on a schedule")
            case .watchPaths:
                L10n.text("文件发生变化时运行", "Runs when files change")
            case .queueDirectories:
                L10n.text("目录包含待处理内容时运行", "Runs when a watched directory has work")
            case .machServices, .sockets:
                L10n.text("收到请求时按需启动", "Starts on demand when requested")
            case .onDemand:
                L10n.text("按需启动", "Starts on demand")
            case .unknown:
                L10n.text("当前触发条件未知", "Trigger conditions are unknown")
            }
        }

        private static func intervalText(_ seconds: Int) -> String {
            if seconds.isMultiple(of: 3_600) {
                return L10n.text("\(seconds / 3_600) 小时", "\(seconds / 3_600) hours")
            }
            if seconds.isMultiple(of: 60) {
                return L10n.text("\(seconds / 60) 分钟", "\(seconds / 60) minutes")
            }
            return L10n.text("\(seconds) 秒", "\(seconds) seconds")
        }

        private static func calendarText(_ schedule: CalendarSchedule) -> String {
            let time = String(format: "%02d:%02d", schedule.hour ?? 0, schedule.minute ?? 0)
            if let month = schedule.month, let day = schedule.day {
                return L10n.text(
                    "每年 \(month) 月 \(day) 日 \(time) 运行",
                    "Runs yearly on month \(month), day \(day) at \(time)"
                )
            }
            if let day = schedule.day {
                return L10n.text(
                    "每月 \(day) 日 \(time) 运行",
                    "Runs monthly on day \(day) at \(time)"
                )
            }
            if let weekday = schedule.weekday {
                let names = L10n.text(
                    "周日,周一,周二,周三,周四,周五,周六",
                    "Sunday,Monday,Tuesday,Wednesday,Thursday,Friday,Saturday"
                ).split(separator: ",").map(String.init)
                let name = names.indices.contains(weekday) ? names[weekday] : String(weekday)
                return L10n.text(
                    "每\(name) \(time) 运行",
                    "Runs every \(name) at \(time)"
                )
            }
            if schedule.hour != nil || schedule.minute != nil {
                return L10n.text("每天 \(time) 运行", "Runs daily at \(time)")
            }
            return L10n.text("按计划运行", "Runs on a schedule")
        }
    }

    enum ParseIssue: Codable, Hashable, Sendable {
        case missingLabel
        case missingExecutable
        case invalidValue(key: String)
        case unresolvedBundleProgram(String)
        case unsupportedValue(key: String)
    }

    struct LaunchdConfiguration: Hashable, Sendable {
        var label: String?
        var program: String?
        var programArguments: [String]
        var bundleProgram: String?
        var resolvedExecutableURL: URL?
        var runAtLoad: Bool?
        var keepAlive: Bool?
        var keepAliveDictionary: [String: String]
        var startInterval: Int?
        var startCalendarIntervals: [CalendarSchedule]
        var watchPaths: [String]
        var queueDirectories: [String]
        var sockets: [String]
        var machServices: [String]
        var disabled: Bool?
        var processType: String?
        var limitLoadToSessionTypes: [String]
        var associatedBundleIdentifiers: [String]
        var workingDirectory: String?
        var userName: String?
        var groupName: String?
        var standardOutPath: String?
        var standardErrorPath: String?
        var triggers: [LaunchTrigger]
        var rawValues: [String: PropertyListValue]
        var issues: [ParseIssue]
    }

    indirect enum PropertyListValue: Hashable, Sendable {
        case string(String)
        case integer(Int)
        case real(Double)
        case bool(Bool)
        case date(Date)
        case data(Data)
        case array([PropertyListValue])
        case dictionary([String: PropertyListValue])
    }

    struct Candidate: Identifiable, Hashable, Sendable {
        let id: String
        var source: ScanSource
        var kind: ItemKind
        var scope: Scope
        var name: String
        var label: String?
        var plistURL: URL?
        var executableURL: URL?
        var applicationURL: URL?
        var configuration: LaunchdConfiguration?
        var state: State
        var attribution: Attribution?
        var actionCapability: ActionCapability
        var diagnosticEvidence: [String]
    }

    struct Item: Identifiable, Hashable, Sendable {
        let id: String
        var kind: ItemKind
        var scope: Scope
        var name: String
        var components: [Candidate]
        var state: State
        var attribution: Attribution?
        var actionCapability: ActionCapability
        var warnings: [String]
    }

    typealias StartupItemKind = ItemKind
    typealias StartupScope = Scope
    typealias StartupScanSource = ScanSource
    typealias StartupItemState = State
    typealias StartupActionCapability = ActionCapability
    typealias StartupItemCandidate = Candidate
    typealias StartupItem = Item
}
