import AgentGatewayCore
import AgentShared
import Darwin
import Foundation
import UserNotifications

/// D265, D267: the App's end of the AI assistant interface. Off until the user
/// turns it on, and independent of any window: it starts with the launch work
/// and ends with the process. Settings reads and drives it through here.
@MainActor
final class AgentInterface: ObservableObject {
    static let shared = AgentInterface(defaults: .standard, dataDirectory: AppDataDirectories.applicationSupportRoot,
                                       applicationURL: Bundle.main.bundleURL, launchBlocked: AcceptanceLaunch.isActive)

    @Published private(set) var status = AgentGatewayStatus.off
    @Published private(set) var clients: [AgentClientRecord] = []
    @Published private(set) var pendingClients: [AgentPendingClient] = []
    private(set) var gateway: AgentGateway?

    private let defaults: UserDefaults
    private let dataDirectory: URL
    private let applicationURL: URL
    /// D106: an acceptance session opens nothing on its own.
    private let launchBlocked: Bool
    private let announceWaitingClient: @Sendable (AgentClientIdentity) async -> Void
    private var lastChange: Task<Void, Never>?
    private var lastAnnouncement: Task<Void, Never>?

    init(defaults: UserDefaults, dataDirectory: URL, applicationURL: URL, launchBlocked: Bool,
         announceWaitingClient: @escaping @Sendable (AgentClientIdentity) async -> Void = AgentInterface.notifyUser) {
        self.defaults = defaults
        self.dataDirectory = dataDirectory
        self.applicationURL = applicationURL
        self.launchBlocked = launchBlocked
        self.announceWaitingClient = announceWaitingClient
    }

    var isEnabled: Bool { AgentPreferenceKey.interfaceEnabled(in: defaults) ?? false }
    var registry: AgentClientRegistry? { gateway?.registry }

    /// From the launch work. Everything slow happens off the main thread.
    func start(source: any AgentReadSource) {
        guard gateway == nil, !launchBlocked else { return }
        let applicationURL = applicationURL
        let identifier = AgentClientIdentifier(home: AgentDataLocation.currentUserHome()?.path ?? NSHomeDirectory())
        let gateway = AgentGateway(.init(
            dataDirectory: dataDirectory,
            peerAuthorization: {
                guard let policy = AgentGatewayPolicy.bridgePolicy(applicationURL: applicationURL) else { return nil }
                return { policy.permits($0) }
            },
            identifyClient: { identifier.identify(bridge: $0.pid) },
            clientStorage: ClientDecisionsInDefaults(defaults: defaults).storage,
            provider: AgentAppReadProvider(source: source, tokens: AgentItemTokens(), identity: .current()),
            onApprovalNeeded: { [weak self] client in
                Task { @MainActor in self?.clientAskedForApproval(client) }
            }))
        self.gateway = gateway
        clients = gateway.registry.records
        if isEnabled { apply(true) }
    }

    /// The switch itself: saved first, so it holds across a launch whatever
    /// becomes of this attempt to listen.
    func setEnabled(_ on: Bool) {
        // Applying takes a moment, or changes nothing without a gateway; the
        // switch and its caption move now.
        objectWillChange.send()
        defaults.set(on, forKey: AgentPreferenceKey.interfaceEnabled)
        apply(on)
    }

    private func apply(_ on: Bool) {
        guard let gateway else { return }
        let previous = lastChange
        lastChange = Task { @MainActor [weak self] in
            await previous?.value
            await gateway.setEnabled(on)
            let status = await gateway.status
            self?.status = status
            self?.refreshClients()
        }
    }

    /// Done once the changes asked for so far have been applied.
    func waitForStatusUpdate() async {
        await lastChange?.value
    }

    /// D267: `willTerminate`, when the process really ends. Requests are voided
    /// and the socket goes; the quit that keeps the panel never comes here.
    func terminate() {
        gateway?.terminate()
    }

    // MARK: Clients (D263)

    /// The gateway says so at most once per client every ten minutes.
    func clientAskedForApproval(_ client: AgentClientIdentity) {
        refreshClients()
        let announce = announceWaitingClient, previous = lastAnnouncement
        lastAnnouncement = Task {
            await previous?.value
            await announce(client)
        }
    }

    func waitForAnnouncements() async {
        await lastAnnouncement?.value
    }

    func decide(_ client: AgentClientIdentity, _ decision: AgentClientDecision) {
        gateway?.registry.decide(client, decision, at: Date())
        refreshClients()
    }

    func revoke(bindingKey: String) {
        gateway?.registry.revoke(bindingKey: bindingKey)
        refreshClients()
    }

    private func refreshClients() {
        clients = gateway?.registry.records ?? []
        pendingClients = gateway?.registry.pending ?? []
    }

    /// Only when the user already allowed this app's notifications: a client
    /// asking must not be what puts a system prompt on screen. The client's
    /// name comes from its signature, not from what it says about itself.
    nonisolated static func notifyUser(_ client: AgentClientIdentity) async {
        guard await ApplicationUpdateNotificationService.isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.text("有 AI 助手想连接", "An AI assistant wants to connect")
        content.body = L10n.text("\(client.displayName) 想读取存储清理助手的信息。到“设置 › AI 助手”里批准或拒绝。",
                                 "\(client.displayName) wants to read Storage Cleaner's information. Allow or deny it in Settings › AI Assistant.")
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "agent-client-\(client.bindingKey)", content: content, trigger: nil))
    }

    // MARK: What Settings shows (D264, D265)

    /// How much of the log the page lists; the log itself keeps far more.
    static let shownAccessEntries = 100
    /// Newest first.
    @Published private(set) var recentAccess: [AgentAccessLogEntry] = []
    @Published private(set) var accessEntryCount = 0
    private var lastAccessRead: Task<Void, Never>?

    /// The switch and the status differ only while a change is being applied.
    var statusCaption: String {
        guard gateway != nil else { return status.settingsText }
        switch (isEnabled, status) {
        case (true, .off): return L10n.text("正在打开…", "Turning on…")
        case (false, .listening), (false, .failed): return L10n.text("正在关闭…", "Turning off…")
        default: return status.settingsText
        }
    }

    /// Entering the page or coming back to the app. A client's calls publish
    /// nothing, so its last use and the log are read here.
    func refreshForSettings() {
        refreshClients()
        let previous = lastAccessRead
        lastAccessRead = Task { [weak self] in
            await previous?.value
            guard let entries = await self?.accessEntries() else { return }
            self?.recentAccess = Array(entries.suffix(Self.shownAccessEntries).reversed())
            self?.accessEntryCount = entries.count
        }
    }

    func waitForAccessRead() async {
        await lastAccessRead?.value
    }

    /// Readable with the switch off, too.
    func accessEntries() async -> [AgentAccessLogEntry] {
        guard let gateway else { return [] }
        let log = await gateway.accessLog
        return await Task.detached(priority: .utility) { log.entries() }.value
    }

    func configSnippets(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "") -> AgentClientConfigSnippets {
        AgentClientConfigSnippets(serverName: AgentDataLocation.serverName(bundleIdentifier: bundleIdentifier),
                                  bridgePath: applicationURL.appendingPathComponent(AgentGatewayPolicy.bridgeRelativePath, isDirectory: false).path)
    }
}

#if DEBUG
extension AgentInterface {
    /// For the settings render review: really listening takes a signed bridge,
    /// which a test does not have.
    func showStatusForReview(_ status: AgentGatewayStatus) { self.status = status }
}
#endif

extension AgentGatewayStatus {
    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }

    /// D263: Settings says why when the interface cannot start.
    var settingsText: String {
        switch self {
        case .off:
            L10n.text("已关闭", "Off")
        case .listening:
            L10n.text("已打开。没有批准的客户端读不到任何数据。", "On. Clients you have not allowed can read nothing.")
        case .failed(.location(.pathTooLong(let bytes))):
            L10n.text("无法打开：数据文件夹的路径太长（\(bytes) 字节）。", "Cannot turn on: the data folder's path is too long (\(bytes) bytes).")
        case .failed(.location):
            L10n.text("无法打开：数据文件夹里的 Agent 文件夹不是本用户的私有文件夹。", "Cannot turn on: the Agent folder in the data folder is not private to this user.")
        case .failed(.bridgeUnverifiable):
            L10n.text("无法打开：无法验证本应用的签名。", "Cannot turn on: this app's signature could not be verified.")
        case .failed(.socket(EADDRINUSE)):
            L10n.text("无法打开：另一份存储清理助手正在使用这个连接。", "Cannot turn on: another copy of Storage Cleaner is using this connection.")
        case .failed(.socket(let code)):
            L10n.text("无法打开：连接启动失败（错误 \(code)）。", "Cannot turn on: the connection failed to start (error \(code)).")
        }
    }
}

/// `UserDefaults` is thread-safe, though this SDK does not mark it `Sendable`.
private struct ClientDecisionsInDefaults: @unchecked Sendable {
    let defaults: UserDefaults

    var storage: AgentClientStorage {
        AgentClientStorage(load: { defaults.data(forKey: AgentPreferenceKey.clients) },
                           save: { defaults.set($0, forKey: AgentPreferenceKey.clients) })
    }
}
