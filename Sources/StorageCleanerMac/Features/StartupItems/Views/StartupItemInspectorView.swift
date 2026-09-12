import SwiftUI

/// Detail surface for an already-scanned snapshot. It deliberately delegates
/// every mutation to the existing store confirmation path.
struct StartupItemInspectorView: View {
    @Environment(\.dismiss) private var dismiss

    let item: StartupItemsDomain.Item
    let onEnable: ((StartupItemsDomain.Candidate) -> Void)?
    let onDisable: ((StartupItemsDomain.Candidate) -> Void)?
    let onStop: ((StartupItemsDomain.Candidate) -> Void)?
    let onReveal: ((StartupItemsDomain.Item) -> Void)?
    let onOpenParentApplication: ((StartupItemsDomain.Item) -> Void)?
    let onCopyText: ((String) -> Void)?
    let onOpenSystemSettings: (() -> Void)?

    private var identity: StartupInspectorIdentityPresentation {
        StartupInspectorIdentityPresentation.make(candidate: primaryCandidate)
    }

    private var primaryCandidate: StartupItemsDomain.Candidate {
        item.components.first ?? StartupItemsDomain.Candidate(
            id: item.id,
            source: .unknown,
            kind: item.kind,
            scope: item.scope,
            name: item.name,
            label: nil,
            plistURL: nil,
            executableURL: nil,
            applicationURL: nil,
            configuration: nil,
            state: item.state,
            attribution: item.attribution,
            actionCapability: item.actionCapability,
            diagnosticEvidence: item.warnings
        )
    }

    private var actionCandidate: StartupItemsDomain.Candidate? {
        startupActionCandidate(
            in: item,
            onEnable: onEnable,
            onDisable: onDisable,
            includesAdministratorRequests: true
        )
    }

    private var actionCandidates: [StartupItemsDomain.Candidate] {
        startupActionCandidates(
            in: item,
            onEnable: onEnable,
            onDisable: onDisable,
            includesAdministratorRequests: true
        )
    }

    private var administratorActionCandidate: StartupItemsDomain.Candidate? {
        guard let actionCandidate,
              actionCandidate.state.management == .requiresAdministrator,
              actionCandidate.actionCapability.requiresAdministrator else { return nil }
        return actionCandidate
    }

    private var stoppableCandidate: StartupItemsDomain.Candidate? {
        guard onStop != nil else { return nil }
        return item.components.first { $0.actionCapability.canStopCurrentSession }
    }

    private var canReveal: Bool {
        onReveal != nil && item.components.contains { $0.actionCapability.canRevealInFinder }
    }

    private var canOpenParentApplication: Bool {
        onOpenParentApplication != nil
            && item.components.contains { $0.actionCapability.canOpenParentApp }
    }

    private var canOpenSystemSettings: Bool {
        onOpenSystemSettings != nil && item.components.contains {
            $0.actionCapability.canOpenSystemSettings || $0.actionCapability.requiresAdministrator
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.large) {
                    identitySection
                    stateSection
                    componentSection
                    diagnosticSection
                }
                .padding(AppDesignTokens.Layout.pagePadding)
            }
            Divider()
            actions
        }
        .frame(minWidth: 620, minHeight: 560)
        .accessibilityLabel(L10n.text("启动项详情", "Startup Item Details"))
    }

    private var header: some View {
        HStack(spacing: AppDesignTokens.Spacing.medium) {
            CachedAppIconView(path: item.applicationIconPath ?? "", size: 42) {
                AppSymbolIcon(
                    systemImage: item.fallbackSystemImage,
                    role: .inline,
                    tint: AppDesignTokens.Palette.secondaryText,
                    isDecorative: true
                )
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(AppTypography.pageTitle)
                Text(item.displayStatus)
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(L10n.text("完成", "Done"), action: dismiss.callAsFunction)
                .keyboardShortcut(.defaultAction)
        }
        .padding(AppDesignTokens.Layout.pagePadding)
    }

    private var identitySection: some View {
        StartupInspectorSection(title: L10n.text("身份与签名", "Identity & Signature")) {
            StartupInspectorKeyValue(label: identity.applicationLabel, value: identity.applicationName)
            if let bundleIdentifier = identity.bundleIdentifier?.trimmed.nonEmpty {
                StartupInspectorKeyValue(label: L10n.text("Bundle ID", "Bundle ID"), value: bundleIdentifier)
            }
            if let teamIdentifier = identity.teamIdentifier?.trimmed.nonEmpty {
                StartupInspectorKeyValue(label: L10n.text("团队 ID", "Team ID"), value: teamIdentifier)
            }
            StartupInspectorKeyValue(
                label: L10n.text("签名状态", "Signature"),
                value: primaryCandidate.trustAssessment.title
            )
            StartupInspectorKeyValue(label: L10n.text("开发者", "Developer"), value: item.developerDisplayName)
        }
    }

    private var stateSection: some View {
        StartupInspectorSection(title: L10n.text("启动与运行状态", "Startup & Runtime")) {
            StartupInspectorKeyValue(label: L10n.text("当前状态", "Current Status"), value: item.displayStatus)
            StartupInspectorKeyValue(label: L10n.text("配置状态", "Configuration"), value: item.configurationState.title)
            StartupInspectorKeyValue(label: L10n.text("管理方式", "Management"), value: item.managementExplanation)
            StartupInspectorKeyValue(label: L10n.text("范围", "Scope"), value: item.scope.title)
            StartupInspectorKeyValue(label: L10n.text("类型", "Kind"), value: item.kind.title)
            if administratorActionCandidate != nil {
                StartupInspectorKeyValue(
                    label: L10n.text("管理员操作", "Administrator Action"),
                    value: administratorActionExplanation
                )
            }
            if let detail = item.statusDetailText {
                StartupInspectorKeyValue(label: L10n.text("运行说明", "Runtime Note"), value: detail)
            }
        }
    }

    private var componentSection: some View {
        StartupInspectorSection(title: L10n.text("扫描到的组件", "Discovered Components")) {
            ForEach(item.components) { candidate in
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                    HStack {
                        Text(candidate.label?.trimmed.nonEmpty ?? candidate.name)
                            .font(AppTypography.body.weight(.semibold))
                        Spacer(minLength: 0)
                        Text(candidate.state.conciseStatus)
                            .font(AppTypography.caption)
                            .foregroundStyle(.secondary)
                        if actionCandidates.count > 1,
                           actionCandidates.contains(where: { $0.id == candidate.id }) {
                            Button(componentActionTitle(candidate)) {
                                requestComponentAction(candidate)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    StartupInspectorKeyValue(label: L10n.text("来源", "Source"), value: candidate.source.title)
                    StartupInspectorKeyValue(label: L10n.text("范围", "Scope"), value: candidate.scope.title)
                    if let plistPath = candidate.plistURL?.path {
                        StartupInspectorKeyValue(label: L10n.text("配置文件", "Configuration File"), value: plistPath, selectable: true)
                    }
                    if let executablePath = candidate.executableURL?.path {
                        StartupInspectorKeyValue(label: L10n.text("可执行文件", "Executable"), value: executablePath, selectable: true)
                    }
                    if let configuration = candidate.configuration {
                        if let program = configuration.program?.trimmed.nonEmpty {
                            StartupInspectorKeyValue(label: "Program", value: program, selectable: true)
                        }
                        if !configuration.programArguments.isEmpty {
                            StartupInspectorKeyValue(
                                label: "ProgramArguments",
                                value: configuration.programArguments.joined(separator: " "),
                                selectable: true
                            )
                        }
                        if let runAtLoad = configuration.runAtLoad {
                            StartupInspectorKeyValue(label: "RunAtLoad", value: boolText(runAtLoad))
                        }
                        if let keepAlive = configuration.keepAlive {
                            StartupInspectorKeyValue(label: "KeepAlive", value: boolText(keepAlive))
                        }
                        let triggers = configuration.triggers.map(\.userFacingDescription)
                        if !triggers.isEmpty {
                            StartupInspectorKeyValue(label: L10n.text("触发条件", "Triggers"), value: triggers.joined(separator: " · "))
                        }
                    }
                    if case let .running(pid) = candidate.state.process {
                        StartupInspectorKeyValue(label: "PID", value: String(pid))
                    }
                }
                .padding(.vertical, AppDesignTokens.Spacing.small)

                if candidate.id != item.components.last?.id {
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private var diagnosticSection: some View {
        if !item.warnings.isEmpty || item.components.contains(where: { !$0.diagnosticEvidence.isEmpty }) {
            StartupInspectorSection(title: L10n.text("诊断信息", "Diagnostic Evidence")) {
                ForEach(diagnosticLines, id: \.self) { line in
                    Text(line)
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var diagnosticLines: [String] {
        Array(Set(item.warnings + item.components.flatMap(\.diagnosticEvidence))).sorted()
    }

    private var actions: some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            if canReveal {
                Button(L10n.text("在 Finder 中显示", "Reveal in Finder")) {
                    onReveal?(item)
                }
            }
            if canOpenParentApplication {
                Button(L10n.text("打开父应用", "Open Parent App")) {
                    onOpenParentApplication?(item)
                }
            }
            if let candidate = actionCandidate {
                let canEnable = candidate.state.enablement == .disabled || candidate.state.enablement == .temporarilyStopped
                let title = candidate.actionCapability.requiresAdministrator
                    ? (canEnable
                        ? L10n.text("请求启用（需要管理员）", "Request Enable (Administrator Required)")
                        : L10n.text("请求停用（需要管理员）", "Request Disable (Administrator Required)"))
                    : (canEnable ? L10n.text("启用", "Enable") : L10n.text("停用", "Disable"))
                Button(title) {
                    if canEnable {
                        onEnable?(candidate)
                    } else {
                        onDisable?(candidate)
                    }
                }
                .buttonStyle(.borderedProminent)
                .help(candidate.actionCapability.requiresAdministrator
                    ? administratorActionExplanation
                    : item.managementExplanation)
            }
            if let candidate = stoppableCandidate {
                Button(L10n.text("停止当前进程", "Stop Current Process")) {
                    onStop?(candidate)
                }
            }
            if canOpenSystemSettings {
                Button(L10n.text("系统设置", "System Settings")) {
                    onOpenSystemSettings?()
                }
            }
            Spacer(minLength: 0)
            if let copyValue = primaryCopyValue {
                Button(L10n.text("复制", "Copy")) {
                    onCopyText?(copyValue)
                }
            }
        }
        .padding(AppDesignTokens.Layout.pagePadding)
    }

    private var primaryCopyValue: String? {
        guard onCopyText != nil else { return nil }
        return primaryCandidate.label?.trimmed.nonEmpty
            ?? primaryCandidate.plistURL?.path
            ?? primaryCandidate.executableURL?.path
    }

    private var administratorActionExplanation: String {
        L10n.text(
            "继续前会先验证并显示影响确认。执行时系统会请求管理员授权；当前安装可能需要先注册并批准系统控制辅助程序。管理员操作目前没有应用内撤销，可通过反向操作恢复状态。",
            "The app validates the request and shows its impact before continuing. Execution requests administrator approval; this installation may first need to register and approve the system-control helper. Administrator operations currently have no in-app undo; use the inverse action to restore the state."
        )
    }

    private func boolText(_ value: Bool) -> String {
        value ? L10n.text("是", "Yes") : L10n.text("否", "No")
    }

    private func componentActionTitle(_ candidate: StartupItemsDomain.Candidate) -> String {
        switch candidate.state.enablement {
        case .disabled, .temporarilyStopped:
            L10n.text("启用此项", "Enable Item")
        case .enabled:
            L10n.text("停用此项", "Disable Item")
        case .unknown:
            L10n.text("不可操作", "Unavailable")
        }
    }

    private func requestComponentAction(_ candidate: StartupItemsDomain.Candidate) {
        switch candidate.state.enablement {
        case .disabled, .temporarilyStopped:
            onEnable?(candidate)
        case .enabled:
            onDisable?(candidate)
        case .unknown:
            break
        }
    }
}

private struct StartupInspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Text(title)
                .font(AppTypography.body.weight(.semibold))
            content
        }
    }
}

private struct StartupInspectorKeyValue: View {
    let label: String
    let value: String
    var selectable = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppDesignTokens.Spacing.medium) {
            Text(label)
                .font(AppTypography.caption)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            if selectable {
                Text(value)
                    .font(AppTypography.caption)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(AppTypography.caption)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
    }
}

extension StartupItemsDomain.ScanSource {
    var title: String {
        switch self {
        case .openAtLogin: L10n.text("登录项扫描", "Login Item Scan")
        case .serviceManagement: L10n.text("服务管理", "Service Management")
        case .backgroundTaskDiagnostic: L10n.text("后台任务诊断", "Background Task Diagnostic")
        case .launchdPlist: L10n.text("launchd 配置文件", "launchd Configuration")
        case .embeddedService: L10n.text("应用内服务", "Embedded Service")
        case .launchdRuntime: L10n.text("launchd 运行状态", "launchd Runtime")
        case .legacyServiceManagement: L10n.text("旧版服务管理", "Legacy Service Management")
        case .privilegedHelper: L10n.text("特权辅助组件", "Privileged Helper")
        case .managedConfiguration: L10n.text("受管理配置", "Managed Configuration")
        case .orphanDetection: L10n.text("残留项检测", "Orphan Detection")
        case .unknown: L10n.text("未知来源", "Unknown Source")
        }
    }
}

private extension StartupItemsDomain.ConfigurationState {
    var title: String {
        switch self {
        case .valid: L10n.text("有效", "Valid")
        case .executableMissing: L10n.text("可执行文件缺失", "Executable Missing")
        case .plistMissing: L10n.text("配置文件缺失", "Configuration File Missing")
        case .malformed: L10n.text("配置格式错误", "Malformed Configuration")
        case .signatureInvalid: L10n.text("签名异常", "Signature Invalid")
        case .orphaned: L10n.text("残留配置", "Orphaned Configuration")
        case .unknown: L10n.text("未知", "Unknown")
        }
    }
}

private extension StartupItemsDomain.TrustAssessment {
    var title: String {
        switch self {
        case .appleSystem: L10n.text("Apple 系统签名", "Apple System Signed")
        case .verifiedDeveloper: L10n.text("已验证开发者签名", "Verified Developer Signature")
        case .unsigned: L10n.text("未签名", "Unsigned")
        case .invalidSignature: L10n.text("签名无效", "Invalid Signature")
        case .missingExecutable: L10n.text("可执行文件缺失", "Executable Missing")
        case .unknown: L10n.text("签名状态未知", "Signature Unknown")
        }
    }
}
