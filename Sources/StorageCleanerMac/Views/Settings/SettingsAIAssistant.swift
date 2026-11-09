import AgentGatewayCore
import AgentShared
import AppKit
import SwiftUI

/// D265, D273: the AI assistant page. It reads and drives the `AgentInterface`
/// it is given and nothing else, so a render or a test never reaches a real
/// gateway or real preferences. Only what works today is here: the grant and the
/// settings for proposals come with batch 2.
struct AgentSettingsPage: View {
    static let introSeenKey = "agentInterface.settingsIntroSeen.v1"
    /// D273: one grant and a refusal (was also `.propose`, D261). Proposals do nothing
    /// in this version, and a client holding that grant would need no new approval
    /// when batch 2 opens them. None skips the user's confirmation.
    static let grants: [AgentClientDecision] = [.readOnly]

    static func accessCountText(_ count: Int) -> String {
        L10n.text("\(ByteFormat.count(count)) 条", L10n.englishCount(count, "entry", "entries"))
    }

    @Environment(\.colorScheme) private var scheme
    @ObservedObject var interface: AgentInterface
    @AppStorage(Self.introSeenKey) private var introSeen = false
    @State private var showsAccessLog: Bool
    @State private var copyNotice: SettingsNotice?

    init(interface: AgentInterface, showsAccessLog: Bool = false) {
        self.interface = interface
        _showsAccessLog = State(initialValue: showsAccessLog)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if introSeen {
                connectionSection
                if !interface.pendingClients.isEmpty { pendingSection }
                clientsSection
                configurationSection
                accessSection
            } else {
                introCanSection
                introCannotSection
            }
        }
    }

    private var warningColor: Color {
        MetadataPillStatus.warning.lightfieldColor(FeatureLightfieldPalette.resolve(scheme))
    }

    // MARK: First time (D265)

    private var introCanSection: some View {
        LightfieldSettingsSection {
            SettingsRow(title: L10n.text("读取状态和结果", "Read status and results"),
                        caption: L10n.text("实时读数、健康检查，已经扫描出的垃圾、启动项、应用和应用更新，操作记录和历史。",
                                           "Live readings, the health check, existing results for junk, login items, apps and app updates, operation records and history.")) { EmptyView() }
            SettingsRow(title: L10n.text("只在这台 Mac 上连接", "Connect on this Mac only"),
                        caption: L10n.text("不开放网络端口。每个 AI 助手第一次连接都要你批准，可以随时撤销；每次访问都有记录。",
                                           "No network port is opened. Each assistant needs your approval the first time it connects, you can revoke that at any time, and every access is logged.")) { EmptyView() }
        } header: {
            Text(L10n.text("AI 助手能做什么", "What AI Assistants Can Do"))
        } footer: {
            Text(L10n.text("AI 助手读到的信息由它自己处理，可能发给它使用的模型服务。只批准你信任的 AI 助手。",
                           "An assistant handles what it reads on its own and may send it to the model service it uses. Approve only assistants you trust."))
        }
    }

    private var introCannotSection: some View {
        LightfieldSettingsSection {
            SettingsRow(title: L10n.text("改动任何东西", "Change anything"),
                        caption: L10n.text("不能清理、卸载、控制风扇、改登录项或改设置，也不能自己打开这个功能。",
                                           "It cannot clean, uninstall, control fans, change login items or change settings, and it cannot turn this feature on.")) { EmptyView() }
            SettingsRow(title: L10n.text("读取内容", "Read contents"),
                        caption: L10n.text("读不到文件内容、浏览记录、Cookie、邮件内容和进程命令行。邮件、聊天文件和隐私清理的项目只给类别、数量和大小。",
                                           "File contents, browsing history, cookies, mail contents and process command lines are out of reach. Mail, chat file and privacy items give only category, count and size.")) { EmptyView() }
            SettingsRow(title: L10n.text("自己开始扫描", "Start a scan"),
                        caption: L10n.text("这一版只能读已有的结果。", "This version can only read existing results.")) { EmptyView() }
            SettingsLinkRow(title: L10n.text("知道了", "Got It")) { introSeen = true }
        } header: {
            Text(L10n.text("AI 助手不能做什么", "What AI Assistants Cannot Do"))
        }
    }

    // MARK: Connection

    private var switchBinding: Binding<Bool> {
        Binding { interface.isEnabled } set: { interface.setEnabled($0) }
    }

    private var connectionSection: some View {
        let title = L10n.text("允许 AI 助手连接", "Allow AI Assistants to Connect")
        return LightfieldSettingsSection {
            SettingsRow(title: title, caption: interface.statusCaption,
                        captionColor: interface.status.isFailure ? warningColor : nil) {
                SettingsSwitch(title: title, isOn: switchBinding)
            }
            SettingsLinkRow(title: L10n.text("AI 助手能做什么、不能做什么", "What AI Assistants Can and Cannot Do")) { introSeen = false }
        } header: {
            Text(L10n.text("连接", "Connection"))
        } footer: {
            Text(L10n.text("这一版只能读取。关掉后立即断开所有连接。", "This version can only read. Turning this off disconnects everything at once."))
        }
    }

    // MARK: Clients (D263)

    private var pendingSection: some View {
        LightfieldSettingsSection {
            ForEach(interface.pendingClients, id: \.identity.bindingKey) { client in
                SettingsRow(title: client.identity.displayName, caption: client.identity.settingsSignature,
                            captionColor: client.identity.hasDeveloperSignature ? nil : warningColor) {
                    HStack(spacing: 16) {
                        ForEach(Self.grants, id: \.self) { grant in
                            SettingsLinkButton(title: grant.settingsGrantTitle) { interface.decide(client.identity, grant) }
                                .accessibilityLabel(client.identity.displayName + " · " + grant.settingsGrantTitle)
                        }
                        SettingsLinkButton(title: L10n.text("拒绝", "Deny"), role: .destructive) { interface.decide(client.identity, .denied) }
                            .accessibilityLabel(client.identity.displayName + " · " + L10n.text("拒绝", "Deny"))
                    }
                }
            }
        } header: {
            Text(L10n.text("等待批准", "Waiting for Approval"))
        } footer: {
            Text(L10n.text("这一版客户端只能读取信息。", "In this version a client can only read information."))
        }
    }

    private var clientsSection: some View {
        LightfieldSettingsSection {
            if interface.clients.isEmpty {
                SettingsRow(title: L10n.text("还没有客户端", "No Clients Yet"),
                            caption: L10n.text("AI 助手第一次连接时，会出现在这里等你批准。",
                                               "An AI assistant appears here for your approval the first time it connects.")) { EmptyView() }
            } else {
                ForEach(interface.clients, id: \.identity.bindingKey) { record in
                    SettingsRow(title: record.identity.displayName, caption: record.identity.settingsSignature,
                                captionColor: record.identity.hasDeveloperSignature ? nil : warningColor,
                                detail: record.settingsLastUse) {
                        HStack(spacing: 16) {
                            Text(record.decision.settingsTitle)
                                .font(.system(size: 13))
                                .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                                .fixedSize()
                            let revoke = record.decision == .denied ? L10n.text("撤销拒绝", "Undo Denial") : L10n.text("撤销", "Revoke")
                            SettingsLinkButton(title: revoke) { interface.revoke(bindingKey: record.identity.bindingKey) }
                                .accessibilityLabel(record.identity.displayName + " · " + revoke)
                        }
                    }
                }
            }
        } header: {
            Text(L10n.text("客户端", "Clients"))
        }
    }

    // MARK: Client configuration

    private var configurationSection: some View {
        let snippets = interface.configSnippets()
        return LightfieldSettingsSection {
            configurationRow("Claude Desktop",
                             caption: L10n.text("合并到 ~/Library/Application Support/Claude/claude_desktop_config.json。",
                                                "Merge into ~/Library/Application Support/Claude/claude_desktop_config.json."),
                             text: snippets.claudeDesktop)
            configurationRow("Claude Code", caption: L10n.text("在终端运行这条命令。", "Run this command in Terminal."), text: snippets.claudeCode)
            configurationRow("Codex", caption: L10n.text("加到 ~/.codex/config.toml。", "Add to ~/.codex/config.toml."), text: snippets.codex)
            if let copyNotice { SettingsNoticeView(notice: copyNotice) }
        } header: {
            Text(L10n.text("接入配置", "Client Configuration"))
        } footer: {
            Text(L10n.text("配置里只有本应用连接程序的路径，没有密码或密钥。客户端的配置由你自己修改，本应用不会改动它们。",
                           "A configuration holds only the path of this app's connection program, with no password or key. You edit a client's configuration yourself; this app never touches it."))
        }
    }

    private func configurationRow(_ client: String, caption: String, text: String) -> some View {
        SettingsRow(title: client, caption: caption) {
            SettingsLinkButton(title: L10n.text("复制", "Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copyNotice = SettingsNotice(text: L10n.text("已复制 \(client) 的接入配置。", "Copied the configuration for \(client)."),
                                            systemImage: "doc.on.doc.fill", tint: AppDesignTokens.Palette.success, severity: .success)
            }
            .accessibilityLabel(client + " · " + L10n.text("复制", "Copy"))
        }
    }

    // MARK: Access log (D264)

    private var accessSection: some View {
        let title = L10n.text("访问记录", "Access Log")
        return LightfieldSettingsSection {
            if interface.accessEntryCount == 0 {
                SettingsValueRow(title: title, value: L10n.text("还没有记录", "No Entries"))
            } else {
                SettingsExpandableRow(title: title, metadata: Self.accessCountText(interface.accessEntryCount),
                                      expanded: $showsAccessLog) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(interface.recentAccess.enumerated()), id: \.offset) { _, entry in
                            LightfieldSettingsRow {
                                SettingsValueRow(title: entry.tool, caption: entry.settingsDetail, value: entry.settingsOutcome,
                                                 valueColor: entry.isProblem ? warningColor : nil)
                            }
                        }
                    }
                }
            }
        } header: {
            Text(L10n.text("记录", "Records"))
        } footer: {
            let kept = ByteFormat.count(AgentAccessLog.defaultMaximumEntries)
            Text(L10n.text("只记时间、客户端、工具和结果，不记读取的内容。保留 30 天或 \(kept) 条，只在这里能看，AI 助手读不到。这里列出最近 \(AgentInterface.shownAccessEntries) 条。",
                           "Only the time, client, tool and outcome are logged, never what was read. Entries are kept for 30 days or \(kept) lines and only show here; AI assistants cannot read them. The latest \(AgentInterface.shownAccessEntries) are listed."))
        }
    }
}

extension AgentClientIdentity {
    /// D263: the name comes from the program's path, so this line is what says
    /// who it really is.
    var settingsSignature: String {
        switch kind {
        case .signed:
            let name = identifier ?? executablePath
            return team.map { L10n.text("已签名：\(name)（开发者 \($0)）", "Signed: \(name) (developer \($0))") }
                ?? L10n.text("已签名：\(name)", "Signed: \(name)")
        case .adHoc:
            return L10n.text("临时签名，没有开发者：\(executablePath)", "Ad-hoc signature, no developer: \(executablePath)")
        case .unsigned:
            return L10n.text("没有签名：\(executablePath)", "No signature: \(executablePath)")
        }
    }

    var hasDeveloperSignature: Bool { kind == .signed }
}

extension AgentClientRecord {
    var settingsLastUse: String? {
        guard decision != .denied else { return nil }
        return lastUsedAt.map { date in
            let text = date.appFormatted(date: .abbreviated, time: .shortened)
            return L10n.text("上次使用 \(text)", "Last used \(text)")
        } ?? L10n.text("还没有用过", "Not used yet")
    }
}

extension AgentClientDecision {
    /// What a client has now. A stored `.propose` shows as it is, though the page no
    /// longer offers it (D273).
    var settingsTitle: String {
        switch self {
        case .readOnly: L10n.text("只读", "Read Only")
        case .propose: L10n.text("可提出操作", "May Propose")
        case .denied: L10n.text("已拒绝", "Denied")
        }
    }

    /// The button that gives it, for what the page offers (`AgentSettingsPage.grants`).
    /// A refusal has its own button.
    var settingsGrantTitle: String {
        switch self {
        case .readOnly: L10n.text("允许只读", "Allow Read Only")
        case .propose, .denied: settingsTitle
        }
    }
}

extension AgentOperationLevel {
    var settingsTitle: String {
        switch self {
        case .read: L10n.text("读取", "Read")
        case .scan: L10n.text("只读扫描", "Read-only Scan")
        case .propose: L10n.text("提出操作", "Proposal")
        }
    }
}

extension AgentRefusalReason {
    var settingsText: String {
        switch self {
        case .interfaceOff: L10n.text("开关已关闭", "Switched off")
        case .appNotRunning: L10n.text("应用没有运行", "App not running")
        case .appUnverified: L10n.text("无法确认应用", "App not verified")
        case .clientUnidentified: L10n.text("无法识别客户端", "Client not identified")
        case .approvalRequired: L10n.text("等待批准", "Waiting for approval")
        case .clientDenied: L10n.text("客户端已被拒绝", "Client denied")
        case .insufficientPermission: L10n.text("权限不够", "Not permitted")
        case .rateLimited: L10n.text("请求太频繁", "Too many requests")
        case .notYetAvailable: L10n.text("这一版还没开放", "Not offered yet")
        case .unknownItem: L10n.text("找不到这一项", "Item not found")
        case .invalidArguments: L10n.text("参数不符合要求", "Invalid arguments")
        case .busy: L10n.text("应用正忙", "App busy")
        case .channelVersionMismatch: L10n.text("版本不一致", "Version mismatch")
        case .internalError: L10n.text("内部出错", "Internal error")
        }
    }
}

extension AgentAccessLogEntry {
    var settingsOutcome: String {
        switch outcome {
        case .allowed: return L10n.text("允许", "Allowed")
        case .failed: return L10n.text("出错", "Failed")
        case .refused:
            guard let reason else { return L10n.text("拒绝", "Refused") }
            return L10n.text("拒绝：\(reason.settingsText)", "Refused: \(reason.settingsText)")
        }
    }

    var isProblem: Bool { outcome != .allowed }

    var settingsDetail: String {
        [client, level.settingsTitle, time.appFormatted(date: .abbreviated, time: .standard)].joined(separator: " · ")
    }
}
