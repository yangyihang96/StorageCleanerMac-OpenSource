import Foundation

enum StartupItemsListFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case actionable
    case directlyManageable
    case openAtLogin
    case background
    case userAgents
    case globalAgents
    case daemons
    case orphaned
    case managed
    case appleSystem
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.text("全部", "All")
        case .actionable: L10n.text("可操作", "Actionable")
        case .directlyManageable: L10n.text("可直接管理", "Directly Manageable")
        case .openAtLogin: L10n.text("登录时打开", "Open at Login")
        case .background: L10n.text("后台项目", "Background Items")
        case .userAgents: L10n.text("用户代理", "User Agents")
        case .globalAgents: L10n.text("系统代理", "Global Agents")
        case .daemons: L10n.text("守护进程", "Daemons")
        case .orphaned: L10n.text("残留项", "Orphaned")
        case .managed: L10n.text("受管理", "Managed")
        case .appleSystem: L10n.text("Apple 系统", "Apple System")
        case .disabled: L10n.text("已停用", "Disabled")
        }
    }
}

/// Default categories answer user-facing questions. Raw launchd kinds remain
/// available in the inspector instead of driving the main navigation.
enum StartupItemsCategory: String, CaseIterable, Identifiable, Sendable {
    case all
    case loginItems
    case background
    case updatesAndSync
    case attention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.text("全部", "All")
        case .loginItems: L10n.text("登录时打开", "Open at Login")
        case .background: L10n.text("后台运行", "Background")
        case .updatesAndSync: L10n.text("更新与同步", "Updates & Sync")
        case .attention: L10n.text("需要关注", "Needs Attention")
        }
    }
}

enum StartupItemsStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case enabled
    case disabled
    case running
    case requiresApproval
    case requiresAdministrator
    case invalidConfiguration
    case readOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.text("全部状态", "All Statuses")
        case .enabled: L10n.text("已启用", "Enabled")
        case .disabled: L10n.text("已禁用", "Disabled")
        case .running: L10n.text("正在运行", "Running")
        case .requiresApproval: L10n.text("等待用户批准", "Approval Required")
        case .requiresAdministrator: L10n.text("需要管理员权限", "Administrator Required")
        case .invalidConfiguration: L10n.text("配置失效", "Configuration Issue")
        case .readOnly: L10n.text("只读系统项目", "Read-only System Items")
        }
    }
}

enum StartupItemsSourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case currentUser
    case allUsers
    case system
    case applicationBundle
    case managed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.text("全部来源", "All Sources")
        case .currentUser: L10n.text("当前用户", "Current User")
        case .allUsers: L10n.text("所有用户", "All Users")
        case .system: L10n.text("系统", "System")
        case .applicationBundle: L10n.text("应用内", "In App")
        case .managed: L10n.text("组织管理", "Managed")
        }
    }
}

enum StartupItemsSortOrder: String, CaseIterable, Identifiable, Sendable {
    case recommended
    case name
    case kind
    case status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommended: L10n.text("建议顺序", "Recommended")
        case .name: L10n.text("名称", "Name")
        case .kind: L10n.text("类型", "Kind")
        case .status: L10n.text("状态", "Status")
        }
    }
}

/// The five user-facing management states required by the startup console.
/// Raw scanner states remain available in the technical inspector.
enum StartupItemManageability: String, Equatable, Sendable {
    case directlyManageable
    case manageableThroughSystemSettings
    case informationOnly
    case protectedSystemItem
    case unknown
}

struct StartupItemsSummary: Equatable, Sendable {
    let total: Int
    let openAtLogin: Int
    let background: Int
    let manageable: Int
    let unidentified: Int
    let orphaned: Int
    let requiresAdministrator: Int
    let systemSettingsOnly: Int
}

struct StartupItemsPresentation: Sendable {
    let allItems: [StartupItemsDomain.Item]
    let visibleItems: [StartupItemsDomain.Item]
    let summary: StartupItemsSummary
    let categoryCounts: [StartupItemsCategory: Int]
    /// The attention category is an explicit review surface. Even if malformed
    /// scan data advertises a direct capability, this projection never exposes
    /// a mutation action.
    let allowsStartupMutationActions: Bool

    func count(for category: StartupItemsCategory) -> Int {
        categoryCounts[category, default: 0]
    }

    /// Compatibility entry point used by the existing presentation tests and
    /// any surface that needs the older, intentionally narrow filter set.
    static func make(
        items: [StartupItemsDomain.Item],
        query: String,
        filter: StartupItemsListFilter
    ) -> StartupItemsPresentation {
        build(
            items: items.filter { filter.matches($0) },
            query: query,
            category: .all,
            status: .all,
            source: .all,
            includeAppleSystem: true,
            sort: .recommended,
            searchTechnicalDetails: true
        )
    }

    static func make(
        items: [StartupItemsDomain.Item],
        query: String,
        category: StartupItemsCategory,
        status: StartupItemsStatusFilter,
        source: StartupItemsSourceFilter,
        includeAppleSystem: Bool,
        sort: StartupItemsSortOrder,
        includeTechnicalDetails: Bool = true
    ) -> StartupItemsPresentation {
        build(
            items: items,
            query: query,
            category: category,
            status: status,
            source: source,
            includeAppleSystem: includeAppleSystem,
            sort: sort,
            includeTechnicalDetails: includeTechnicalDetails,
            searchTechnicalDetails: false
        )
    }

    private static func build(
        items: [StartupItemsDomain.Item],
        query: String,
        category: StartupItemsCategory,
        status: StartupItemsStatusFilter,
        source: StartupItemsSourceFilter,
        includeAppleSystem: Bool,
        sort: StartupItemsSortOrder,
        includeTechnicalDetails: Bool = true,
        searchTechnicalDetails: Bool = false
    ) -> StartupItemsPresentation {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseItems = includeAppleSystem ? items : items.filter { !$0.isAppleSystem }
        // "All" means every non-Apple result. Previously low-confidence,
        // administrator-required and information-only rows were silently
        // moved out of the main list, which made a complete scan look
        // incomplete compared with the underlying evidence.
        let primaryItems = baseItems.filter { !$0.isAppleSystem }
        let primaryAttentionItems = baseItems.filter(\.isPrimaryAttentionReviewItem)
        let usesPrimaryAttentionProjection = !includeTechnicalDetails && category == .attention
        let visibleUniverse = includeTechnicalDetails
            ? baseItems
            : (usesPrimaryAttentionProjection ? primaryAttentionItems : primaryItems)
        let summaryItems = includeTechnicalDetails ? baseItems : primaryItems
        let visible = visibleUniverse
            .filter { usesPrimaryAttentionProjection || category.matches($0) }
            .filter { status.matches($0) }
            .filter { source.matches($0) }
            .filter {
                normalizedQuery.isEmpty
                    || $0.searchText(includeTechnicalDetails: searchTechnicalDetails)
                        .localizedCaseInsensitiveContains(normalizedQuery)
            }
            .sorted(by: sort.comparator)

        return StartupItemsPresentation(
            allItems: baseItems,
            visibleItems: visible,
            summary: StartupItemsSummary(
                total: summaryItems.count,
                openAtLogin: summaryItems.filter { item in
                    item.components.contains { component in
                        component.kind == .openAtLogin || component.kind == .loginItem
                    }
                }.count,
                background: summaryItems.filter(\.hasBackgroundComponent).count,
                manageable: summaryItems.filter(\.isDirectlyManageable).count,
                unidentified: summaryItems.filter {
                    ($0.attribution?.confidence ?? .unknown) < .high
                }.count,
                orphaned: summaryItems.filter(\.isOrphaned).count,
                requiresAdministrator: summaryItems.filter(\.requiresAdministrator).count,
                systemSettingsOnly: summaryItems.filter(\.isSystemSettingsOnly).count
            ),
            categoryCounts: Dictionary(uniqueKeysWithValues: StartupItemsCategory.allCases.map { category in
                let count: Int
                switch category {
                case .all:
                    count = summaryItems.count
                case .attention where !includeTechnicalDetails:
                    count = primaryAttentionItems.count
                default:
                    count = summaryItems.filter(category.matches).count
                }
                return (category, count)
            }),
            allowsStartupMutationActions: category != .attention
        )
    }
}

private extension StartupItemsListFilter {
    func matches(_ item: StartupItemsDomain.Item) -> Bool {
        if self != .appleSystem, item.isAppleSystem { return false }
        switch self {
        case .all:
            return true
        case .actionable:
            return item.isActionable
        case .directlyManageable:
            return item.isDirectlyManageable
        case .openAtLogin:
            return item.components.contains { $0.kind == .openAtLogin || $0.kind == .loginItem }
        case .background:
            return item.hasBackgroundComponent
        case .userAgents:
            return item.components.contains { $0.kind == .userLaunchAgent }
        case .globalAgents:
            return item.components.contains { $0.kind == .globalLaunchAgent || $0.kind == .systemLaunchAgent }
        case .daemons:
            return item.components.contains { $0.kind == .launchDaemon || $0.kind == .systemLaunchDaemon }
        case .orphaned:
            return item.isOrphaned
        case .managed:
            return item.state.management == .managedByOrganization
                || item.components.contains { $0.kind == .managedItem }
        case .appleSystem:
            return item.isAppleSystem
        case .disabled:
            return item.components.contains { $0.state.enablement == .disabled }
        }
    }
}

private extension StartupItemsCategory {
    func matches(_ item: StartupItemsDomain.Item) -> Bool {
        switch self {
        case .all:
            true
        case .loginItems:
            item.components.contains {
                $0.kind == .openAtLogin || $0.kind == .loginItem
            }
        case .background:
            item.hasBackgroundComponent
        default:
            item.consoleCategory == self
        }
    }
}

private extension StartupItemsStatusFilter {
    func matches(_ item: StartupItemsDomain.Item) -> Bool {
        switch self {
        case .all:
            true
        case .enabled:
            item.components.contains { $0.state.enablement == .enabled }
        case .disabled:
            item.components.contains { $0.state.enablement == .disabled }
        case .running:
            item.components.contains {
                if case .running = $0.state.process { return true }
                return false
            }
        case .requiresApproval:
            item.components.contains { $0.state.authorization == .requiresApproval }
        case .requiresAdministrator:
            item.requiresAdministrator
        case .invalidConfiguration:
            item.hasConfigurationIssue
        case .readOnly:
            item.isReadOnly
        }
    }
}

private extension StartupItemsSourceFilter {
    func matches(_ item: StartupItemsDomain.Item) -> Bool {
        switch self {
        case .all:
            true
        case .currentUser:
            item.components.contains { $0.scope == .currentUser }
        case .allUsers:
            item.components.contains { $0.scope == .allUsers }
        case .system:
            item.components.contains { $0.scope == .system }
        case .applicationBundle:
            item.components.contains { $0.scope == .applicationBundle }
        case .managed:
            item.components.contains { $0.scope == .managed }
        }
    }
}

private extension StartupItemsSortOrder {
    var comparator: (StartupItemsDomain.Item, StartupItemsDomain.Item) -> Bool {
        switch self {
        case .recommended:
            StartupItemsDomain.Item.presentationOrder
        case .name:
            { lhs, rhs in
                lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        case .kind:
            { lhs, rhs in
                let comparison = lhs.kind.title.localizedStandardCompare(rhs.kind.title)
                return comparison == .orderedSame
                    ? lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                    : comparison == .orderedAscending
            }
        case .status:
            { lhs, rhs in
                let comparison = lhs.displayStatus.localizedStandardCompare(rhs.displayStatus)
                return comparison == .orderedSame
                    ? lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                    : comparison == .orderedAscending
            }
        }
    }
}

extension StartupItemsDomain.ItemKind {
    var title: String {
        switch self {
        case .openAtLogin: L10n.text("登录时打开", "Open at Login")
        case .loginItem: L10n.text("登录项", "Login Item")
        case .userLaunchAgent: L10n.text("用户 LaunchAgent", "User LaunchAgent")
        case .globalLaunchAgent: L10n.text("全局 LaunchAgent", "Global LaunchAgent")
        case .systemLaunchAgent: L10n.text("系统 LaunchAgent", "System LaunchAgent")
        case .launchDaemon: L10n.text("LaunchDaemon", "LaunchDaemon")
        case .systemLaunchDaemon: L10n.text("系统 LaunchDaemon", "System LaunchDaemon")
        case .appBackgroundTask: L10n.text("后台任务", "Background Task")
        case .embeddedHelper: L10n.text("应用内辅助组件", "Embedded Helper")
        case .privilegedHelper: L10n.text("特权辅助组件", "Privileged Helper")
        case .managedItem: L10n.text("组织管理项目", "Managed Item")
        case .orphanedItem: L10n.text("残留启动项", "Orphaned Item")
        case .unknown: L10n.text("未知项目", "Unknown Item")
        }
    }

    var systemImage: String {
        switch self {
        case .openAtLogin: AppSymbols.Startup.openAtLogin
        case .loginItem: AppSymbols.Startup.loginItem
        case .userLaunchAgent: AppSymbols.Startup.userAgent
        case .globalLaunchAgent, .systemLaunchAgent: AppSymbols.Startup.globalAgent
        case .launchDaemon, .systemLaunchDaemon: AppSymbols.Startup.daemon
        case .appBackgroundTask: AppSymbols.Startup.backgroundTask
        case .embeddedHelper: AppSymbols.Startup.embeddedHelper
        case .privilegedHelper: AppSymbols.Startup.privilegedHelper
        case .managedItem: AppSymbols.Startup.managed
        case .orphanedItem: AppSymbols.Startup.orphaned
        case .unknown: AppSymbols.Startup.unknown
        }
    }

    var isBackgroundKind: Bool {
        switch self {
        case .userLaunchAgent, .globalLaunchAgent, .systemLaunchAgent,
             .launchDaemon, .systemLaunchDaemon, .appBackgroundTask,
             .embeddedHelper, .privilegedHelper:
            true
        case .openAtLogin, .loginItem, .managedItem, .orphanedItem, .unknown:
            false
        }
    }
}

extension StartupItemsDomain.Scope {
    var title: String {
        switch self {
        case .currentUser: L10n.text("用户级", "User")
        case .allUsers: L10n.text("所有用户", "All Users")
        case .system: L10n.text("系统级", "System")
        case .applicationBundle: L10n.text("应用内", "In App")
        case .managed: L10n.text("组织管理", "Managed")
        case .unknown: L10n.text("范围未知", "Scope Unknown")
        }
    }
}

extension StartupItemsDomain.Candidate {
    /// Derived only from the immutable scan evidence; the presentation layer
    /// never touches the file system to manufacture a status.
    var configurationState: StartupItemsDomain.ConfigurationState {
        if kind == .orphanedItem
            || diagnosticEvidence.contains(where: { $0.hasPrefix("orphan-evidence:") }) {
            return .orphaned
        }
        if diagnosticEvidence.contains(where: { $0.hasPrefix("malformed-plist:") }) {
            return .malformed
        }
        if plistURL == nil, source == .launchdPlist {
            return .plistMissing
        }
        if diagnosticEvidence.contains("missing-executable")
            || diagnosticEvidence.contains("target-missing") {
            return .executableMissing
        }
        if diagnosticEvidence.contains("signature-invalid")
            || diagnosticEvidence.contains("team-identifier-mismatch") {
            return .signatureInvalid
        }
        return .valid
    }
}

extension StartupItemsDomain.Item {
    var consoleCategory: StartupItemsCategory {
        if isAttentionItem {
            return .attention
        }
        if components.contains(where: {
            $0.kind == .openAtLogin || $0.kind == .loginItem
        }) {
            return .loginItems
        }
        let purpose = resolvedPurpose.value.lowercased()
        if ["更新", "同步", "update", "sync", "cloud"].contains(where: purpose.contains) {
            return .updatesAndSync
        }
        return .background
    }

    var manageability: StartupItemManageability {
        if isDirectlyManageable {
            return .directlyManageable
        }
        if components.contains(where: {
            $0.state.management == .manageableInSystemSettings
                && $0.actionCapability.canOpenSystemSettings
                && !$0.actionCapability.requiresAdministrator
        }) {
            return .manageableThroughSystemSettings
        }
        if isAppleSystem || components.contains(where: {
            $0.state.management == .systemProtected
                || $0.state.management == .readOnly
                || $0.state.management == .managedByOrganization
                || $0.actionCapability.isManaged
        }) {
            return .protectedSystemItem
        }
        if attribution?.confidence ?? .unknown < .high {
            return .unknown
        }
        return .informationOnly
    }

    var configurationState: StartupItemsDomain.ConfigurationState {
        let states = components.map(\.configurationState)
        for state in [
            StartupItemsDomain.ConfigurationState.orphaned,
            .malformed,
            .plistMissing,
            .executableMissing,
            .signatureInvalid,
            .unknown,
        ] where states.contains(state) {
            return state
        }
        return .valid
    }

    var hasConfigurationIssue: Bool {
        switch configurationState {
        case .valid, .unknown:
            false
        case .executableMissing, .plistMissing, .malformed, .signatureInvalid, .orphaned:
            true
        }
    }

    var requiresAdministrator: Bool {
        components.contains { candidate in
            candidate.actionCapability.requiresAdministrator
                || candidate.state.management == .requiresAdministrator
        }
    }

    var isSystemSettingsOnly: Bool {
        !isDirectlyManageable && manageability == .manageableThroughSystemSettings
    }

    var isReadOnly: Bool {
        guard !isDirectlyManageable else { return false }
        return components.contains { candidate in
            candidate.actionCapability.isReadOnly
                || candidate.state.management == .systemProtected
                || candidate.state.management == .readOnly
                || candidate.state.management == .managedByOrganization
                || candidate.state.management == .unsupported
        }
    }

    private var backgroundComponents: [StartupItemsDomain.Candidate] {
        components.filter { $0.kind.isBackgroundKind }
    }

    var hasBackgroundComponent: Bool {
        !backgroundComponents.isEmpty
    }

    var displayName: String {
        if isAppleSystem {
            if let label = components
                .compactMap(\.label)
                .compactMap({ $0.trimmed.nonEmpty })
                .sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
                .first {
                return label
            }
            let source = components.first?.source.title
                ?? L10n.text("系统扫描", "System Scan")
            return L10n.text("Apple 系统项目 · \(source)", "Apple System Item · \(source)")
        }
        guard attribution?.confidence ?? .unknown >= .high else {
            return components
                .compactMap(\.label)
                .compactMap { $0.trimmed.nonEmpty }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .first ?? name
        }
        return attribution?.applicationName?.trimmed.nonEmpty ?? name
    }

    var identitySummaryText: String {
        let developer = developerDisplayName
        guard attribution?.confidence ?? .unknown < .high,
              displayName == L10n.text("未知后台项目", "Unknown Background Item"),
              let label = components.compactMap(\.label).first?.trimmed.nonEmpty else {
            return developer
        }
        return "\(label) · \(developer)"
    }

    var developerDisplayName: String {
        if isAppleSystem { return "Apple" }
        guard attribution?.confidence ?? .unknown >= .high else {
            return L10n.text("开发者未知", "Unknown Developer")
        }
        return attribution?.developerName?.trimmed.nonEmpty
            ?? attribution?.teamIdentifier?.trimmed.nonEmpty
            ?? L10n.text("开发者未知", "Unknown Developer")
    }

    var displayStatus: String {
        if isAppleSystem {
            return L10n.text("由 macOS 管理", "Managed by macOS")
        }
        if isPartiallyDisabled {
            return L10n.text("部分停用", "Partially Disabled")
        }
        return state.conciseStatus
    }

    var statusDetailText: String? {
        guard state.load == .onDemand || components.contains(where: { $0.state.load == .onDemand }) else {
            return nil
        }
        return L10n.text(
            "由 macOS 在应用或系统事件需要时启动",
            "macOS starts it only when an app or system event needs it"
        )
    }

    var isPartiallyDisabled: Bool {
        let enablements = components.map(\.state.enablement)
        return enablements.contains(.disabled)
            && enablements.contains { $0 == .enabled || $0 == .temporarilyStopped }
    }

    var applicationIconPath: String? {
        components.compactMap(\.reliableApplicationIconPath).first
    }

    var fallbackSystemImage: String {
        isAppleSystem ? "apple.logo" : kind.systemImage
    }

    var runningComponentCount: Int {
        backgroundComponents.filter { component in
            if case .running = component.state.process { return true }
            return false
        }.count
    }

    var runningSummaryText: String {
        if backgroundComponents.isEmpty {
            return L10n.text("无后台组件", "No background components")
        }
        if runningComponentCount > 0 {
            return L10n.text(
                "\(runningComponentCount) 个正在运行",
                "\(runningComponentCount) running"
            )
        }
        let hasUnknownProcessState = backgroundComponents.contains { component in
            if case .unknown = component.state.process { return true }
            return false
        }
        if hasUnknownProcessState {
            return L10n.text("运行状态待确认", "Runtime state pending")
        }
        return L10n.text("0 个正在运行", "0 running")
    }

    var isAppleSystem: Bool {
        !components.isEmpty && components.allSatisfy(\.isVerifiedAppleSystem)
    }

    var isOrphaned: Bool {
        kind == .orphanedItem
            || components.contains { $0.kind == .orphanedItem || $0.diagnosticEvidence.contains("target-missing") }
    }

    var isDirectlyManageable: Bool {
        components.contains { candidate in
            guard candidate.state.management == .directlyManageable else {
                return false
            }
            switch candidate.state.enablement {
            case .disabled, .temporarilyStopped:
                return candidate.actionCapability.canEnableDirectly
            case .enabled:
                return candidate.actionCapability.canDisableDirectly
            case .unknown:
                return false
            }
        }
    }

    var isActionable: Bool {
        isDirectlyManageable || components.contains { candidate in
            !candidate.actionCapability.isManaged
                && (candidate.actionCapability.canOpenSystemSettings
                    || candidate.actionCapability.requiresAdministrator)
        }
    }

    var isPrimaryManagementItem: Bool {
        guard !isAppleSystem,
              attribution?.confidence ?? .unknown >= .high else { return false }
        return manageability == .directlyManageable
            || manageability == .manageableThroughSystemSettings
    }

    /// The attention category remains a focused review projection even though
    /// these rows also stay visible in the complete non-Apple list.
    var isPrimaryAttentionReviewItem: Bool {
        guard !isAppleSystem,
              !components.contains(where: {
                  $0.state.management == .systemProtected
                      || $0.state.management == .managedByOrganization
                      || $0.actionCapability.isManaged
              }) else { return false }
        if needsAttention { return true }
        if manageability == .directlyManageable
            || manageability == .manageableThroughSystemSettings {
            return attribution?.confidence ?? .unknown < .high
        }
        return manageability == .unknown
    }

    var managementExplanation: String {
        if requiresAdministrator {
            return L10n.text(
                "此项目需要管理员权限；本应用不会在未经确认和验证时更改它。",
                "This item requires administrator permission; the app will not change it without confirmation and verification."
            )
        }
        switch manageability {
        case .directlyManageable:
            return L10n.text(
                "可由本应用管理；操作完成后会重新读取系统状态。",
                "Manageable in this app; system state is read back after each operation."
            )
        case .manageableThroughSystemSettings:
            return L10n.text(
                "由 macOS 系统设置管理，本应用只会打开对应设置页。",
                "Managed by macOS System Settings; this app only opens the relevant settings page."
            )
        case .protectedSystemItem:
            return L10n.text(
                "这是受系统或组织保护的只读项目，本应用不会修改它。",
                "This is a read-only system- or organization-protected item; the app will not modify it."
            )
        case .informationOnly:
            return L10n.text(
                "当前没有经过验证的安全管理方式，仅显示扫描信息。",
                "No verified safe management path is available; scan information is shown only."
            )
        case .unknown:
            return L10n.text(
                "所属应用或管理方式尚未可靠确认，仅显示扫描信息。",
                "The owning app or management path is not reliably identified; scan information is shown only."
            )
        }
    }

    var isAttentionItem: Bool {
        needsAttention || manageability == .unknown
    }

    var needsAttention: Bool {
        hasConfigurationIssue || components.contains { component in
            component.diagnosticEvidence.contains("group-writable")
                || component.diagnosticEvidence.contains("world-writable")
                || component.diagnosticEvidence.contains("unresolved-symbolic-link")
        }
    }

    fileprivate static func presentationOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.needsAttention != rhs.needsAttention { return lhs.needsAttention }
        if lhs.isDirectlyManageable != rhs.isDirectlyManageable {
            return lhs.isDirectlyManageable
        }
        let lhsIsIdentified = lhs.attribution?.confidence ?? .unknown >= .high
        let rhsIsIdentified = rhs.attribution?.confidence ?? .unknown >= .high
        if lhsIsIdentified != rhsIsIdentified { return lhsIsIdentified }
        if lhs.isAppleSystem != rhs.isAppleSystem { return !lhs.isAppleSystem }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    fileprivate func searchText(includeTechnicalDetails: Bool) -> String {
        let primary = [
            displayName,
            developerDisplayName,
            resolvedPurpose.value,
        ]
        guard includeTechnicalDetails else { return primary.joined(separator: "\n") }
        let componentText = components.flatMap { component in
            [
                component.name,
                component.label,
                component.plistURL?.path,
                component.executableURL?.path,
            ].compactMap { $0 }
        }
        return (primary + [
            attribution?.applicationBundleIdentifier,
            attribution?.teamIdentifier,
        ].compactMap { $0 } + componentText).joined(separator: "\n")
    }

    var loginItemStatusText: String? {
        activationStatusText(
            title: L10n.text("登录时打开", "Open at Login"),
            components: components.filter { $0.kind == .openAtLogin || $0.kind == .loginItem }
        )
    }

    var backgroundItemStatusText: String? {
        activationStatusText(
            title: L10n.text("后台运行", "Background"),
            components: backgroundComponents
        )
    }

    private func activationStatusText(
        title: String,
        components: [StartupItemsDomain.Candidate]
    ) -> String? {
        guard !components.isEmpty else { return nil }
        let states = Set(components.map(\.state.enablement))
        let status: String
        if states == [.disabled] || states == [.temporarilyStopped]
            || states == [.disabled, .temporarilyStopped] {
            status = L10n.text("关闭", "Off")
        } else if states == [.enabled] {
            status = L10n.text("开启", "On")
        } else if states.contains(.enabled) {
            status = L10n.text("部分开启", "Partially On")
        } else {
            status = L10n.text("状态未知", "Unknown")
        }
        return L10n.text("\(title)：\(status)", "\(title): \(status)")
    }

}

extension StartupItemsDomain.State {
    var conciseStatus: String {
        if enablement == .disabled {
            if case .running = process {
                return L10n.text(
                    "已禁用 · 本次会话仍在运行",
                    "Disabled · Still Running This Session"
                )
            }
            return L10n.text("已禁用 · 未运行", "Disabled · Not Running")
        }
        switch process {
        case .running: return L10n.text("正在运行", "Running")
        case .waiting: return L10n.text("等待触发", "Waiting")
        case .failed: return L10n.text("上次运行失败", "Last Run Failed")
        case .stopped:
            if load == .onDemand {
                return L10n.text("已启用 · 当前未运行", "Enabled · Not Running")
            }
            return L10n.text("未运行", "Not Running")
        case .unknown:
            if load == .loaded { return L10n.text("已载入", "Loaded") }
            if load == .onDemand {
                return L10n.text("已启用 · 当前未运行", "Enabled · Not Running")
            }
            return L10n.text("状态未知", "Unknown State")
        }
    }
}
