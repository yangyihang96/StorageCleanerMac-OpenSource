import AgentShared
import Foundation

/// D259, D267: why a module has results or not. Results live in memory, so a
/// module with none has either not been scanned in this run or been released.
enum AgentResultStatus: String, Sendable {
    case ready
    case scanning
    case notScanned = "not_scanned"
    /// Released while only the menu-bar panel runs; a scan brings them back.
    case released
}

struct AgentModuleResults<Item: Sendable>: Sendable {
    var status: AgentResultStatus
    var updatedAt: Date?
    /// Changes when the results do; worked out from the items when nil.
    var generation: String?
    var items: [Item]

    init(status: AgentResultStatus, updatedAt: Date? = nil, generation: String? = nil, items: [Item] = []) {
        self.status = status
        self.updatedAt = updatedAt
        self.generation = generation
        self.items = items
    }
}

struct AgentAppIdentity: Equatable, Sendable {
    let name: String
    let version: String
    let build: String
    let channel: String

    static func current(bundle: Bundle = .main) -> Self {
        let info = bundle.infoDictionary ?? [:]
        let channel = switch bundle.bundleIdentifier {
        case AgentDataLocation.releaseBundleIdentifier: "release"
        case AgentDataLocation.betaBundleIdentifier: "beta"
        default: "qa"
        }
        return Self(name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? bundle.bundleURL.deletingPathExtension().lastPathComponent,
                    version: info["CFBundleShortVersionString"] as? String ?? "",
                    build: info["CFBundleVersion"] as? String ?? "",
                    channel: channel)
    }
}

struct AgentBatteryReading: Equatable, Sendable {
    var chargePercent: Int?
    var isCharging: Bool?
    var powerSource: BatteryPowerSource?
    var minutesRemaining: Int?
    var sampledAt: Date?
}

struct AgentOverviewState: Sendable {
    var isMenuBarOnly = false
    var capacity: StorageCapacitySnapshot?
    var memory: MemorySnapshot?
    var health: ComputerHealthEvaluation?
}

/// D268: the readings the App already holds, whenever they were taken.
struct AgentLiveState: Sendable {
    var snapshot: SystemMonitorSnapshot?
    var memory: MemorySnapshot?
    var capacity: StorageCapacitySnapshot?
    var battery: AgentBatteryReading?
}

struct AgentHealthState: Sendable {
    var evaluation: ComputerHealthEvaluation?
    var snapshot: ComputerHealthSnapshot?
    var storageForecast: StoragePressureForecast?
    var batteryTrend: BatteryWearTrend?
}

/// What the answers to reads are made from: values, copied off the App's
/// stores, so that everything is encoded away from the main thread.
protocol AgentReadSource: Sendable {
    func overview() async -> AgentOverviewState
    func live() async -> AgentLiveState
    func health() async -> AgentHealthState
    func junk() async -> AgentModuleResults<ScanCandidate>
    func startupItems() async -> AgentModuleResults<StartupItemsDomain.Item>
    func installedApps() async -> AgentModuleResults<InstalledAppItem>
    func appUpdates() async -> AgentModuleResults<AppUpdateItem>
    func lastCleanupScan() async -> ScanHistoryEntry?
    func scanHistory() async -> [ScanHistoryEntry]
    func operationRecords(after cursor: CleanupReportIndex.Cursor?, limit: Int) throws -> CleanupReportJournal.SummaryPage
    func operationRecord(_ id: CleanPlanID) throws -> CleanReport
    func hardwareOperations() async throws -> [HardwareOperationRecord]
    func capacityHistory() throws -> [CapacityHistoryPoint]
}
