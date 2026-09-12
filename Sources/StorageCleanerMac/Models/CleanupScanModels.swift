import CryptoKit
import Foundation

enum CleanupByteCount {
    static func adding(_ value: Int64, to total: Int64) -> Int64 {
        let (sum, overflow) = total.addingReportingOverflow(max(0, value))
        return overflow ? .max : sum
    }

    static func sum<S: Sequence>(_ values: S) -> Int64 where S.Element == Int64 {
        values.reduce(0) { adding($1, to: $0) }
    }
}

enum CleanupArchitectureMode: String, Codable, Sendable {
    case legacy
    case v2ScanOnly
    case v2Full
}

struct CleanupFeatureConfiguration: Sendable {
    let mode: CleanupArchitectureMode

    static let productDefault = CleanupFeatureConfiguration(mode: .v2Full)
    static let legacy = CleanupFeatureConfiguration(mode: .legacy)

    var diagnosticValue: String {
        "cleanup-architecture=\(mode.rawValue)"
    }
}

enum CleanupRuleAction: String, Codable, Sendable {
    case moveToTrash
    case moveToTrashAfterReview
    case moveToTrashAfterProtectedReview
    case revealOnly

    var movesToTrash: Bool {
        self == .moveToTrash
            || self == .moveToTrashAfterReview
            || self == .moveToTrashAfterProtectedReview
    }
}

enum CleanupCloudPolicy: String, Codable, Sendable {
    case metadataOnly
    case skipPlaceholder
    case excludeCloudRoots
}

enum CleanupRuleRootKind: String, Codable, Sendable {
    case homeRelative
    case applicationsDirectory
}

enum CleanupRuleCandidateScope: String, Codable, Sendable {
    case immediateChildren
    case root
    case descendantAggregate
}

enum FileEntryKind: String, Codable, Hashable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

enum CleanupRisk: String, Codable, Sendable {
    case safe
    case reviewOnly
    case protected
    case informational
}

enum CleanupRecommendationLevel: String, Codable, Sendable {
    case recommended
    case optional
    case notRecommended
    case advisoryOnly
}

enum CleanupDefaultSelection: String, Codable, Sendable {
    case selected
    case unselected
    case forbidden
}

enum CleanupExecutionEligibility: String, Codable, Sendable {
    case eligible
    case eligibleAfterReview
    case eligibleAfterProtectedReview
    case advisoryOnly
}

enum CleanupMeasurementRequirement: String, Codable, Sendable {
    case complete
    case bestEffort
}

enum DeveloperTool: String, Codable, CaseIterable, Hashable, Sendable {
    case npm
    case codex
    case claudeCode
    case cursor
    case githubCopilot
    case openCode
    case openClaw
    case geminiCLI
    case workBuddy
    case windsurf
    case continueDev
    case cline
    case rooCode

    var displayName: String {
        switch self {
        case .npm: "npm"
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        case .githubCopilot: "GitHub Copilot"
        case .openCode: "OpenCode"
        case .openClaw: "OpenClaw"
        case .geminiCLI: "Gemini CLI"
        case .workBuddy: "WorkBuddy"
        case .windsurf: "Windsurf"
        case .continueDev: "Continue"
        case .cline: "Cline"
        case .rooCode: "Roo Code"
        }
    }
}

enum DeveloperArtifactKind: String, Codable, Sendable {
    case cache
    case pluginCache
    case temporaryFiles
    case temporaryExecutionCache
    case contentCache
    case logs
    case agentData

    var displayName: String {
        switch self {
        case .cache: L10n.text("缓存", "Cache")
        case .pluginCache: L10n.text("插件缓存", "Plugin Cache")
        case .temporaryFiles: L10n.text("临时文件", "Temporary Files")
        case .temporaryExecutionCache: L10n.text("临时执行缓存", "Temporary Execution Cache")
        case .contentCache: L10n.text("内容缓存", "Content Cache")
        case .logs: L10n.text("日志", "Logs")
        case .agentData: L10n.text("Agent 会话与产物", "Agent Sessions & Artifacts")
        }
    }
}

struct CleanupRuleSet: Codable, Sendable {
    let schemaVersion: Int
    let rulesVersion: String
    let rules: [CleanupRule]
}

struct CleanupRule: Codable, Identifiable, Sendable {
    let id: String
    let selectionPolicyVersion: Int
    let categoryID: String
    let categoryTitleKey: String
    let titleKey: String
    let root: CleanupRuleRoot
    var candidateScope: CleanupRuleCandidateScope? = nil
    let maximumDepth: Int
    let minimumAgeDays: Int
    let minimumBytes: Int64
    let include: CleanupRuleMatch
    let exclude: CleanupRuleExclusion
    let cloudPolicy: CleanupCloudPolicy
    let risk: CleanupRisk
    let recommendation: CleanupRecommendationLevel
    let defaultSelection: CleanupDefaultSelection
    let executionEligibility: CleanupExecutionEligibility
    let measurementRequirement: CleanupMeasurementRequirement
    let allowsManualSelection: Bool
    let action: CleanupRuleAction
    let requiredClosedBundleIDs: [String]
    let reasonKey: String
    var ownerDisplayName: String? = nil
    var developerTool: DeveloperTool? = nil
    var developerArtifactKind: DeveloperArtifactKind? = nil
    var includedBundleIdentifiers: Set<String>? = nil
    var requiresDuplicateBundleIdentifier: Bool? = nil

    var effectiveCandidateScope: CleanupRuleCandidateScope {
        candidateScope ?? .immediateChildren
    }

    var effectiveIncludedBundleIdentifiers: Set<String> {
        includedBundleIdentifiers ?? []
    }

    var effectiveRequiresDuplicateBundleIdentifier: Bool {
        requiresDuplicateBundleIdentifier
            ?? (root.kind == .applicationsDirectory
                && risk == .protected
                && effectiveIncludedBundleIdentifiers.isEmpty)
    }
}

struct CleanupRuleRoot: Codable, Sendable {
    let kind: CleanupRuleRootKind
    let path: String
}

struct CleanupRuleMatch: Codable, Sendable {
    let entryKinds: Set<FileEntryKind>
    let extensions: Set<String>
    let nameMatcher: CleanupNameMatcher
}

enum CleanupNameMatchMode: String, Codable, Sendable {
    case any
    case exact
    case prefix
}

struct CleanupNameMatcher: Codable, Sendable {
    let mode: CleanupNameMatchMode
    let values: [String]
}

struct CleanupRuleExclusion: Codable, Sendable {
    let relativePrefixes: [String]
    let extensions: Set<String>
}

enum DeveloperArtifactCleanupPolicy: Equatable, Sendable {
    case regenerable
    case reviewOnly
    case referenceOnly
}

struct DeveloperToolArtifactDefinition: Sendable {
    let id: String
    let rootPath: String
    let candidateNames: [String]
    let tool: DeveloperTool
    let kind: DeveloperArtifactKind
    let policy: DeveloperArtifactCleanupPolicy
    let minimumBytes: Int64
    var maximumDepth = 32
    var requiredClosedBundleIDs: [String] = []

    var cleanupRule: CleanupRule {
        let isRegenerable = policy == .regenerable
        let isReferenceOnly = policy == .referenceOnly
        let reasonKey: String
        switch policy {
        case .regenerable: reasonKey = "cleanup.reason.regenerableDeveloperCache"
        case .reviewOnly: reasonKey = "cleanup.reason.developerToolLogs"
        case .referenceOnly: reasonKey = "cleanup.reason.developerToolState"
        }
        return CleanupRule(
            id: id,
            selectionPolicyVersion: 1,
            categoryID: "developer",
            categoryTitleKey: "cleanup.category.developer",
            titleKey: "cleanup.rule.developerToolArtifact.title",
            root: CleanupRuleRoot(kind: .homeRelative, path: rootPath),
            maximumDepth: isReferenceOnly ? 0 : maximumDepth,
            minimumAgeDays: 0,
            minimumBytes: isReferenceOnly ? 0 : minimumBytes,
            include: CleanupRuleMatch(
                entryKinds: [.directory],
                extensions: [],
                nameMatcher: CleanupNameMatcher(mode: .exact, values: candidateNames)
            ),
            exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
            cloudPolicy: .excludeCloudRoots,
            risk: isRegenerable ? .safe : .reviewOnly,
            recommendation: isRegenerable ? .optional : .advisoryOnly,
            defaultSelection: isRegenerable ? .unselected : .forbidden,
            executionEligibility: isRegenerable ? .eligible : .advisoryOnly,
            measurementRequirement: isRegenerable ? .complete : .bestEffort,
            allowsManualSelection: isRegenerable,
            action: isRegenerable ? .moveToTrash : .revealOnly,
            requiredClosedBundleIDs: requiredClosedBundleIDs,
            reasonKey: reasonKey,
            developerTool: tool,
            developerArtifactKind: kind
        )
    }
}

enum DeveloperToolArtifactCatalog {
    private static let kib: Int64 = 1_024
    private static let cursorBundleID = "com.todesktop.230313mzl4w4u92"
    private static let claudeBundleID = "com.anthropic.claudefordesktop"

    static let definitions: [DeveloperToolArtifactDefinition] = [
        .init(id: "developer.codex-cache", rootPath: ".codex", candidateNames: ["cache"], tool: .codex, kind: .cache, policy: .regenerable, minimumBytes: 256 * kib),
        .init(id: "developer.codex-plugin-cache", rootPath: ".codex/plugins", candidateNames: ["cache"], tool: .codex, kind: .pluginCache, policy: .regenerable, minimumBytes: 256 * kib),
        .init(id: "developer.codex-temporary-files", rootPath: ".codex", candidateNames: ["tmp"], tool: .codex, kind: .temporaryFiles, policy: .regenerable, minimumBytes: 256 * kib),
        .init(id: "developer.codex-logs", rootPath: ".codex", candidateNames: ["logs"], tool: .codex, kind: .logs, policy: .reviewOnly, minimumBytes: 64 * kib),
        .init(id: "developer.codex-runtime-temporary-files", rootPath: ".codex", candidateNames: [".tmp"], tool: .codex, kind: .temporaryFiles, policy: .referenceOnly, minimumBytes: 0),
        .init(id: "developer.codex-agent-data", rootPath: ".codex", candidateNames: ["sessions", "archived_sessions", "generated_images", "visualizations"], tool: .codex, kind: .agentData, policy: .referenceOnly, minimumBytes: 0),

        .init(id: "developer.claude-code-cache", rootPath: ".claude", candidateNames: ["cache"], tool: .claudeCode, kind: .cache, policy: .regenerable, minimumBytes: 256 * kib),
        .init(id: "developer.claude-code-plugin-cache", rootPath: ".claude/plugins", candidateNames: ["cache"], tool: .claudeCode, kind: .pluginCache, policy: .regenerable, minimumBytes: 256 * kib),
        .init(id: "developer.claude-code-temporary-files", rootPath: ".claude", candidateNames: ["tmp"], tool: .claudeCode, kind: .temporaryFiles, policy: .regenerable, minimumBytes: 256 * kib),
        .init(id: "developer.claude-code-app-cache", rootPath: "Library/Caches", candidateNames: ["Claude", "claude-code"], tool: .claudeCode, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib, requiredClosedBundleIDs: [claudeBundleID]),
        .init(id: "developer.claude-code-logs", rootPath: ".claude", candidateNames: ["debug", "logs"], tool: .claudeCode, kind: .logs, policy: .reviewOnly, minimumBytes: 64 * kib),
        .init(id: "developer.claude-code-agent-data", rootPath: ".claude", candidateNames: ["projects", "sessions", "file-history", "plans"], tool: .claudeCode, kind: .agentData, policy: .referenceOnly, minimumBytes: 0),

        .init(id: "developer.cursor-cache", rootPath: "Library/Application Support/Cursor", candidateNames: ["Cache", "CachedData", "Code Cache", "GPUCache"], tool: .cursor, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib, requiredClosedBundleIDs: [cursorBundleID]),
        .init(id: "developer.cursor-app-cache", rootPath: "Library/Caches", candidateNames: [cursorBundleID], tool: .cursor, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib, requiredClosedBundleIDs: [cursorBundleID]),
        .init(id: "developer.cursor-logs", rootPath: "Library/Application Support/Cursor", candidateNames: ["logs"], tool: .cursor, kind: .logs, policy: .reviewOnly, minimumBytes: 64 * kib),
        .init(id: "developer.cursor-agent-data", rootPath: "Library/Application Support/Cursor", candidateNames: ["snapshots"], tool: .cursor, kind: .agentData, policy: .referenceOnly, minimumBytes: 0),

        .init(id: "developer.github-copilot-cache", rootPath: ".cache", candidateNames: ["github-copilot"], tool: .githubCopilot, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib),
        .init(id: "developer.github-copilot-app-cache", rootPath: "Library/Caches", candidateNames: ["GitHub Copilot"], tool: .githubCopilot, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib),
        .init(id: "developer.github-copilot-logs", rootPath: "Library/Logs", candidateNames: ["GitHub Copilot"], tool: .githubCopilot, kind: .logs, policy: .reviewOnly, minimumBytes: 64 * kib),

        .init(id: "developer.opencode-cache", rootPath: ".cache", candidateNames: ["opencode"], tool: .openCode, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib),
        .init(id: "developer.opencode-logs", rootPath: ".local/share/opencode", candidateNames: ["log", "logs"], tool: .openCode, kind: .logs, policy: .reviewOnly, minimumBytes: 64 * kib),
        .init(id: "developer.opencode-agent-data", rootPath: ".local/share/opencode", candidateNames: ["project", "storage", "session", "repos"], tool: .openCode, kind: .agentData, policy: .referenceOnly, minimumBytes: 0),

        .init(id: "developer.openclaw-cache", rootPath: ".openclaw", candidateNames: ["cache"], tool: .openClaw, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib),
        .init(id: "developer.openclaw-temporary-files", rootPath: ".openclaw", candidateNames: ["tmp"], tool: .openClaw, kind: .temporaryFiles, policy: .regenerable, minimumBytes: 64 * kib),
        .init(id: "developer.openclaw-app-cache", rootPath: "Library/Caches", candidateNames: ["OpenClaw"], tool: .openClaw, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib),
        .init(id: "developer.openclaw-logs", rootPath: ".openclaw", candidateNames: ["logs"], tool: .openClaw, kind: .logs, policy: .reviewOnly, minimumBytes: 64 * kib),
        .init(id: "developer.openclaw-app-logs", rootPath: "Library/Logs", candidateNames: ["OpenClaw"], tool: .openClaw, kind: .logs, policy: .reviewOnly, minimumBytes: 64 * kib),

        .init(id: "developer.gemini-cli-data", rootPath: ".gemini", candidateNames: ["tmp", "history"], tool: .geminiCLI, kind: .agentData, policy: .referenceOnly, minimumBytes: 0),

        .init(id: "developer.workbuddy-logs", rootPath: ".workbuddy", candidateNames: ["logs", "traces", "audit-log"], tool: .workBuddy, kind: .logs, policy: .reviewOnly, minimumBytes: 1 * kib, maximumDepth: 2),
        .init(id: "developer.workbuddy-agent-data", rootPath: ".workbuddy", candidateNames: ["tasks", "sessions", "artifact-index", "file-history", "projects", "workspace"], tool: .workBuddy, kind: .agentData, policy: .referenceOnly, minimumBytes: 0),

        .init(id: "developer.windsurf-agent-data", rootPath: ".codeium/windsurf", candidateNames: ["cascade"], tool: .windsurf, kind: .agentData, policy: .referenceOnly, minimumBytes: 0),
        .init(id: "developer.windsurf-logs", rootPath: "Library/Application Support/Windsurf", candidateNames: ["logs"], tool: .windsurf, kind: .logs, policy: .reviewOnly, minimumBytes: 1 * kib, maximumDepth: 2),

        .init(id: "developer.continue-index", rootPath: ".continue", candidateNames: ["index"], tool: .continueDev, kind: .contentCache, policy: .regenerable, minimumBytes: 64 * kib),

        .init(id: "developer.cline-sdk-data", rootPath: ".cline/data", candidateNames: ["sessions"], tool: .cline, kind: .agentData, policy: .referenceOnly, minimumBytes: 0),
        .init(id: "developer.cline-vscode-data", rootPath: "Library/Application Support/Code/User/globalStorage", candidateNames: ["saoudrizwan.claude-dev"], tool: .cline, kind: .agentData, policy: .referenceOnly, minimumBytes: 0),
        .init(id: "developer.cline-cursor-data", rootPath: "Library/Application Support/Cursor/User/globalStorage", candidateNames: ["saoudrizwan.claude-dev"], tool: .cline, kind: .agentData, policy: .referenceOnly, minimumBytes: 0),
        .init(id: "developer.cline-windsurf-data", rootPath: "Library/Application Support/Windsurf/User/globalStorage", candidateNames: ["saoudrizwan.claude-dev"], tool: .cline, kind: .agentData, policy: .referenceOnly, minimumBytes: 0),

        .init(id: "developer.roo-code-vscode-data", rootPath: "Library/Application Support/Code/User/globalStorage", candidateNames: ["rooveterinaryinc.roo-cline"], tool: .rooCode, kind: .agentData, policy: .referenceOnly, minimumBytes: 0),
        .init(id: "developer.roo-code-cursor-data", rootPath: "Library/Application Support/Cursor/User/globalStorage", candidateNames: ["rooveterinaryinc.roo-cline"], tool: .rooCode, kind: .agentData, policy: .referenceOnly, minimumBytes: 0),
        .init(id: "developer.roo-code-windsurf-data", rootPath: "Library/Application Support/Windsurf/User/globalStorage", candidateNames: ["rooveterinaryinc.roo-cline"], tool: .rooCode, kind: .agentData, policy: .referenceOnly, minimumBytes: 0),
    ]

    static var cleanupRules: [CleanupRule] {
        definitions.map(\.cleanupRule)
    }

    static func permitsAutomaticRule(_ rule: CleanupRule) -> Bool {
        definitions.contains {
            $0.policy == .regenerable
                && $0.id == rule.id
                && $0.rootPath == rule.root.path
                && Set($0.candidateNames) == Set(rule.include.nameMatcher.values)
                && rule.include.nameMatcher.mode == .exact
        }
    }
}

enum CleanupRuleValidationError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case invalidRulesVersion
    case duplicateRuleID(String)
    case invalidRelativePath(ruleID: String)
    case forbiddenRoot(ruleID: String)
    case unsafeActionRiskCombination(ruleID: String)
    case invalidLimit(ruleID: String)
    case invalidBundleIdentifier(ruleID: String)
    case invalidNameMatcher(ruleID: String)
    case invalidDeveloperArtifactMetadata(ruleID: String)
    case invalidAttributionMetadata(ruleID: String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            L10n.text("不支持清理规则版本 \(version)", "Unsupported cleanup rule schema \(version)")
        case .invalidRulesVersion:
            L10n.text("清理规则版本为空", "Cleanup rules version is empty")
        case let .duplicateRuleID(ruleID):
            L10n.text("清理规则重复：\(ruleID)", "Duplicate cleanup rule: \(ruleID)")
        case let .invalidRelativePath(ruleID):
            L10n.text("清理规则路径无效：\(ruleID)", "Invalid cleanup rule path: \(ruleID)")
        case let .forbiddenRoot(ruleID):
            L10n.text("清理规则范围过大：\(ruleID)", "Cleanup rule scope is too broad: \(ruleID)")
        case let .unsafeActionRiskCombination(ruleID):
            L10n.text("清理规则风险与动作不匹配：\(ruleID)", "Cleanup rule risk/action mismatch: \(ruleID)")
        case let .invalidLimit(ruleID):
            L10n.text("清理规则限制无效：\(ruleID)", "Invalid cleanup rule limits: \(ruleID)")
        case let .invalidBundleIdentifier(ruleID):
            L10n.text("清理规则的应用标识无效：\(ruleID)", "Invalid app identifier in cleanup rule: \(ruleID)")
        case let .invalidNameMatcher(ruleID):
            L10n.text("清理规则的名称匹配无效：\(ruleID)", "Invalid name matcher in cleanup rule: \(ruleID)")
        case let .invalidDeveloperArtifactMetadata(ruleID):
            L10n.text("开发工具残留标识不完整：\(ruleID)", "Incomplete developer artifact metadata: \(ruleID)")
        case let .invalidAttributionMetadata(ruleID):
            L10n.text("清理规则归属无效：\(ruleID)", "Invalid cleanup rule attribution: \(ruleID)")
        }
    }
}

struct ScanSessionID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct ScanCandidateID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    /// Produces the same identifier for the same scanner rule and file
    /// identity without relying on list order or a per-scan random UUID.
    init(stableKey: String) {
        var bytes = Array(SHA256.hash(data: Data(stableKey.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        rawValue = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

struct FileIdentity: Hashable, Codable, Sendable {
    let deviceID: UInt64
    let inode: UInt64
    let entryKind: FileEntryKind
    let creationTimeNanoseconds: Int64?

    var deduplicationKey: String {
        "\(deviceID):\(inode):\(entryKind.rawValue)"
    }
}

struct FileSnapshot: Hashable, Codable, Sendable {
    let identity: FileIdentity
    let standardizedPath: String
    let volumeIdentifier: String
    let logicalSizeBytes: Int64
    let allocatedSizeBytes: Int64?
    let modificationTimeNanoseconds: Int64?
    let isWritableVolume: Bool
    let isCloudItem: Bool
    let isCloudPlaceholder: Bool
    let hasSymbolicLinkComponent: Bool
}

struct CleanupRecommendation: Codable, Sendable {
    let level: CleanupRecommendationLevel
    let reasonCode: String
    let evidenceCodes: [String]
}

enum SelectionEligibility: String, Codable, Sendable {
    case selectable
    case selectableWithReview
    case selectableWithProtectedReview
    case reviewRequired
    case protected
    case readOnly
    case unavailable
}

enum CleanupMeasurementIssue: String, Codable, Hashable, Sendable {
    case unreadableDescendant
    case permissionDenied
    case symbolicLinkSkipped
    case excludedDescendant
    case depthLimitReached
    case unknown
}

enum MeasurementCompleteness: Codable, Hashable, Sendable {
    case complete
    case lowerBound(reason: CleanupMeasurementIssue)
    case failed(reason: CleanupMeasurementIssue)

    var isComplete: Bool {
        self == .complete
    }

    var isLowerBound: Bool {
        if case .lowerBound = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum DeveloperCleanupAgeBand: String, Codable, Sendable {
    case inactiveYear
    case inactiveReview
    case recent
    case unknown
}

struct DeveloperCleanupAgeDecision: Equatable, Sendable {
    let band: DeveloperCleanupAgeBand
    let risk: CleanupRisk
    let recommendation: CleanupRecommendationLevel
    let defaultSelection: CleanupDefaultSelection
    let executionEligibility: CleanupExecutionEligibility
    let allowsManualSelection: Bool
    let action: CleanupRuleAction
    let reasonCode: String
}

enum DeveloperCleanupAgePolicy {
    static let defaultThresholdDays = 30
    static let minimumThresholdDays = 30
    static let maximumThresholdDays = 364
    static let inactiveYearDays = 365

    static func normalizedThresholdDays(_ days: Int) -> Int {
        min(max(days, minimumThresholdDays), maximumThresholdDays)
    }

    static func applies(to rule: CleanupRule) -> Bool {
        rule.categoryID == "developer"
            && rule.root.kind == .homeRelative
            && rule.risk == .safe
            && rule.action == .moveToTrash
            && rule.executionEligibility == .eligible
            && rule.measurementRequirement == .complete
            && rule.allowsManualSelection
    }

    static func decision(
        for rule: CleanupRule,
        latestModificationTimeNanoseconds: Int64?,
        measurementCompleteness: MeasurementCompleteness,
        referenceDate: Date,
        thresholdDays: Int
    ) -> DeveloperCleanupAgeDecision? {
        guard applies(to: rule) else { return nil }
        guard measurementCompleteness.isComplete,
              let latestModificationTimeNanoseconds else {
            return DeveloperCleanupAgeDecision(
                band: .unknown,
                risk: .protected,
                recommendation: .notRecommended,
                defaultSelection: .forbidden,
                executionEligibility: .advisoryOnly,
                allowsManualSelection: false,
                action: .revealOnly,
                reasonCode: "cleanup.reason.developerActivityUnknown"
            )
        }

        let age = referenceDate.timeIntervalSince1970
            - Double(latestModificationTimeNanoseconds) / 1_000_000_000
        if age > Double(inactiveYearDays) * 86_400 {
            return DeveloperCleanupAgeDecision(
                band: .inactiveYear,
                risk: .safe,
                recommendation: .recommended,
                defaultSelection: .selected,
                executionEligibility: .eligible,
                allowsManualSelection: true,
                action: .moveToTrash,
                reasonCode: "cleanup.reason.developerInactiveYear"
            )
        }
        if age > Double(normalizedThresholdDays(thresholdDays)) * 86_400 {
            return DeveloperCleanupAgeDecision(
                band: .inactiveReview,
                risk: .reviewOnly,
                recommendation: .optional,
                defaultSelection: .unselected,
                executionEligibility: .eligibleAfterReview,
                allowsManualSelection: true,
                action: .moveToTrashAfterReview,
                reasonCode: "cleanup.reason.developerInactiveReview"
            )
        }
        return DeveloperCleanupAgeDecision(
            band: .recent,
            risk: .protected,
            recommendation: .notRecommended,
            defaultSelection: .unselected,
            executionEligibility: .eligibleAfterProtectedReview,
            allowsManualSelection: true,
            action: .moveToTrashAfterProtectedReview,
            reasonCode: "cleanup.reason.developerRecent"
        )
    }

    static func inactivityDays(
        latestModificationTimeNanoseconds: Int64,
        referenceDate: Date
    ) -> Int {
        max(0, Int((referenceDate.timeIntervalSince1970
            - Double(latestModificationTimeNanoseconds) / 1_000_000_000) / 86_400))
    }

    static func evidenceCodes(
        for decision: DeveloperCleanupAgeDecision,
        latestModificationTimeNanoseconds: Int64?,
        thresholdDays: Int
    ) -> [String] {
        [
            "developer-age-band:\(decision.band.rawValue)",
            "developer-inactivity-threshold-days:\(normalizedThresholdDays(thresholdDays))",
            "developer-latest-modification-ns:\(latestModificationTimeNanoseconds ?? 0)",
        ]
    }

    static func reason(
        for decision: DeveloperCleanupAgeDecision,
        latestModificationTimeNanoseconds: Int64?,
        referenceDate: Date,
        thresholdDays: Int
    ) -> String {
        guard let latestModificationTimeNanoseconds else {
            return L10n.text(
                "无法完整确认目录内最近一次修改时间，因此按红色保护且不能加入清理计划。",
                "The latest modification time inside this folder could not be verified, so it remains protected and cannot enter a cleanup plan."
            )
        }
        let days = inactivityDays(
            latestModificationTimeNanoseconds: latestModificationTimeNanoseconds,
            referenceDate: referenceDate
        )
        switch decision.band {
        case .inactiveYear:
            return L10n.text(
                "目录内最近一次可读修改距扫描约 \(days) 天，已超过一年；这是可重新生成的开发缓存，因此默认选中。判断基于文件系统修改时间，不代表完整版本历史。",
                "The latest readable modification inside this folder was about \(days) days before the scan, over one year ago. This regenerable developer cache is selected by default. The decision uses filesystem modification times, not complete version history."
            )
        case .inactiveReview:
            return L10n.text(
                "目录内最近一次可读修改距扫描约 \(days) 天，超过设置的 \(normalizedThresholdDays(thresholdDays)) 天但未超过一年；建议核对用途后再手动选择。判断基于文件系统修改时间。",
                "The latest readable modification inside this folder was about \(days) days before the scan, beyond the \(normalizedThresholdDays(thresholdDays))-day setting but within one year. Review its purpose before selecting it manually. The decision uses filesystem modification times."
            )
        case .recent:
            return L10n.text(
                "目录内最近一次可读修改距扫描约 \(days) 天，仍在设置的 \(normalizedThresholdDays(thresholdDays)) 天以内，可能正在使用；默认不选。确认用途和备份后可逐项选择，执行前需要双重确认。",
                "The latest readable modification inside this folder was about \(days) days before the scan, within the \(normalizedThresholdDays(thresholdDays))-day setting, so it may still be active. It is off by default and requires individual selection plus two confirmations."
            )
        case .unknown:
            return L10n.text(
                "无法完整确认目录内最近一次修改时间，因此按红色保护且不能加入清理计划。",
                "The latest modification time inside this folder could not be verified, so it remains protected and cannot enter a cleanup plan."
            )
        }
    }
}

enum CleanupSelectionPolicy {
    static func eligibility(
        risk: CleanupRisk,
        isManuallySelectable: Bool,
        action: CleanupRuleAction,
        executionEligibility: CleanupExecutionEligibility,
        measurementCompleteness: MeasurementCompleteness
    ) -> SelectionEligibility {
        guard measurementCompleteness.isComplete else { return .unavailable }
        switch executionEligibility {
        case .eligible:
            guard risk == .safe,
                  isManuallySelectable,
                  action == .moveToTrash else { return .unavailable }
            return .selectable
        case .eligibleAfterReview:
            guard risk == .reviewOnly,
                  isManuallySelectable,
                  action == .moveToTrashAfterReview else { return .reviewRequired }
            return .selectableWithReview
        case .eligibleAfterProtectedReview:
            guard risk == .protected,
                  isManuallySelectable,
                  action == .moveToTrashAfterProtectedReview else { return .protected }
            return .selectableWithProtectedReview
        case .advisoryOnly:
            switch risk {
            case .protected: return .protected
            case .reviewOnly: return .reviewRequired
            case .safe: return .unavailable
            case .informational: return .readOnly
            }
        }
    }
}

struct ScanCandidate: Identifiable, Sendable {
    let id: ScanCandidateID
    let sessionID: ScanSessionID
    let ruleID: String
    let ruleSelectionPolicyVersion: Int
    let categoryID: String
    let categoryTitle: String
    let subcategoryTitle: String
    let sourceURL: URL
    let allowedRootURL: URL
    let snapshot: FileSnapshot
    let risk: CleanupRisk
    let recommendation: CleanupRecommendation
    let defaultSelection: CleanupDefaultSelection
    let executionEligibility: CleanupExecutionEligibility
    let measurementCompleteness: MeasurementCompleteness
    let isManuallySelectable: Bool
    let action: CleanupRuleAction
    let requiredClosedBundleIDs: [String]
    let reason: String
    var latestContentModificationTimeNanoseconds: Int64? = nil
    var developerTool: DeveloperTool? = nil
    var developerArtifactKind: DeveloperArtifactKind? = nil

    var developerArtifactSummary: String? {
        guard let developerTool, let developerArtifactKind else { return nil }
        return "\(developerTool.displayName) · \(developerArtifactKind.displayName)"
    }

    var selectionEligibility: SelectionEligibility {
        CleanupSelectionPolicy.eligibility(
            risk: risk,
            isManuallySelectable: isManuallySelectable,
            action: action,
            executionEligibility: executionEligibility,
            measurementCompleteness: measurementCompleteness
        )
    }

    var isSelectable: Bool {
        selectionEligibility == .selectable
            || selectionEligibility == .selectableWithReview
            || selectionEligibility == .selectableWithProtectedReview
    }

    var requiresExplicitReview: Bool {
        selectionEligibility == .selectableWithReview
            || selectionEligibility == .selectableWithProtectedReview
    }

    /// `du -sk`, used by storage-analyzer, reports disk blocks. Prefer the
    /// scanner's allocated-size estimate and retain logical size as fallback.
    var estimatedSizeBytes: Int64 {
        max(0, snapshot.allocatedSizeBytes ?? snapshot.logicalSizeBytes)
    }

    var latestContentModificationDate: Date? {
        latestContentModificationTimeNanoseconds.map {
            Date(timeIntervalSince1970: Double($0) / 1_000_000_000)
        }
    }
}

enum CleanupRecommendationDisplayPolicy {
    static func level(for candidate: ScanCandidate) -> CleanupRecommendationLevel {
        candidate.isSelectable ? candidate.recommendation.level : .advisoryOnly
    }

    static func level(
        for candidates: [ScanCandidate],
        fallback: CleanupRecommendationLevel
    ) -> CleanupRecommendationLevel {
        candidates.contains(where: \.isSelectable) ? fallback : .advisoryOnly
    }
}

enum ScanOutcome: String, Codable, Sendable {
    case complete
    case partial
    case cancelled
}

enum ScanIssueKind: String, Codable, Sendable {
    case permissionDenied
    case vanished
    case unreadable
    case metadataUnavailable
    case symbolicLinkSkipped
    case hardLinkDeduplicated
    case cloudPlaceholderSkipped
    case volumeUnavailable
    case outsideAllowedRoot
    case timedOut
}

struct ScanIssue: Identifiable, Sendable {
    let id: UUID
    let ruleID: String?
    let path: String?
    let kind: ScanIssueKind

    init(id: UUID = UUID(), ruleID: String?, path: String?, kind: ScanIssueKind) {
        self.id = id
        self.ruleID = ruleID
        self.path = path
        self.kind = kind
    }
}

enum CleanupPermissionStatus: String, Codable, Sendable {
    case readable
    case permissionDenied
    case missing
    case unreadable
}

struct CleanupPermissionReport: Identifiable, Sendable {
    var id: String { ruleID }
    let ruleID: String
    let path: String
    let status: CleanupPermissionStatus
}

struct ScanMetrics: Sendable {
    let visitedEntryCount: Int
    let visitedDirectoryCount: Int
    let candidateCount: Int
    let deduplicatedIdentityCount: Int
    let estimatedCandidateBytes: Int64
    let completeMeasurementCandidateCount: Int
    let lowerBoundMeasurementCandidateCount: Int
    let failedMeasurementCandidateCount: Int
    let permissionFailureCount: Int
    let cloudSkippedCount: Int
    let timedOutRuleCount: Int
    let truncatedCandidateCount: Int
    let duration: TimeInterval

    init(
        visitedEntryCount: Int,
        visitedDirectoryCount: Int = 0,
        candidateCount: Int,
        deduplicatedIdentityCount: Int,
        estimatedCandidateBytes: Int64,
        completeMeasurementCandidateCount: Int = 0,
        lowerBoundMeasurementCandidateCount: Int = 0,
        failedMeasurementCandidateCount: Int = 0,
        permissionFailureCount: Int = 0,
        cloudSkippedCount: Int = 0,
        timedOutRuleCount: Int = 0,
        truncatedCandidateCount: Int = 0,
        duration: TimeInterval
    ) {
        self.visitedEntryCount = visitedEntryCount
        self.visitedDirectoryCount = visitedDirectoryCount
        self.candidateCount = candidateCount
        self.deduplicatedIdentityCount = deduplicatedIdentityCount
        self.estimatedCandidateBytes = estimatedCandidateBytes
        self.completeMeasurementCandidateCount = completeMeasurementCandidateCount
        self.lowerBoundMeasurementCandidateCount = lowerBoundMeasurementCandidateCount
        self.failedMeasurementCandidateCount = failedMeasurementCandidateCount
        self.permissionFailureCount = permissionFailureCount
        self.cloudSkippedCount = cloudSkippedCount
        self.timedOutRuleCount = timedOutRuleCount
        self.truncatedCandidateCount = truncatedCandidateCount
        self.duration = duration
    }
}

struct CleanupScanSubcategory: Identifiable, Sendable {
    let id: String
    let title: String
    let risk: CleanupRisk
    let recommendation: CleanupRecommendationLevel
    let reason: String
    let candidates: [ScanCandidate]

    var discoveredBytes: Int64 {
        CleanupByteCount.sum(candidates.map(\.estimatedSizeBytes))
    }

    var selectableCandidateIDs: [ScanCandidateID] {
        candidates.filter(\.isSelectable).map(\.id)
    }
}

struct CleanupScanCategory: Identifiable, Sendable {
    let id: String
    let title: String
    let subcategories: [CleanupScanSubcategory]

    var candidates: [ScanCandidate] {
        subcategories.flatMap(\.candidates)
    }

    var discoveredBytes: Int64 {
        CleanupByteCount.sum(subcategories.map(\.discoveredBytes))
    }

    var selectableCandidateIDs: [ScanCandidateID] {
        subcategories.flatMap(\.selectableCandidateIDs)
    }
}

struct ScanSession: Identifiable, Sendable {
    let id: ScanSessionID
    let rulesVersion: String
    let startedAt: Date
    let completedAt: Date
    let outcome: ScanOutcome
    let categories: [CleanupScanCategory]
    let issues: [ScanIssue]
    let permissions: [CleanupPermissionReport]
    let metrics: ScanMetrics
    let system: SystemSnapshot?
    let developerInactivityThresholdDays: Int
    let includedCategoryIDs: Set<String>?
    let includedRuleIDs: Set<String>?

    init(
        id: ScanSessionID,
        rulesVersion: String,
        startedAt: Date,
        completedAt: Date,
        outcome: ScanOutcome,
        categories: [CleanupScanCategory],
        issues: [ScanIssue],
        permissions: [CleanupPermissionReport],
        metrics: ScanMetrics,
        system: SystemSnapshot? = nil,
        developerInactivityThresholdDays: Int = DeveloperCleanupAgePolicy.defaultThresholdDays,
        includedCategoryIDs: Set<String>? = nil,
        includedRuleIDs: Set<String>? = nil
    ) {
        self.id = id
        self.rulesVersion = rulesVersion
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.outcome = outcome
        self.categories = categories
        self.issues = issues
        self.permissions = permissions
        self.metrics = metrics
        self.system = system
        self.developerInactivityThresholdDays = DeveloperCleanupAgePolicy.normalizedThresholdDays(
            developerInactivityThresholdDays
        )
        self.includedCategoryIDs = includedCategoryIDs
        self.includedRuleIDs = includedRuleIDs
    }

    var candidates: [ScanCandidate] {
        categories.flatMap(\.candidates)
    }

    func candidates(with risk: CleanupRisk) -> [ScanCandidate] {
        candidates.filter { $0.risk == risk }
    }

    func discoveredBytes(for risk: CleanupRisk) -> Int64 {
        CleanupByteCount.sum(candidates(with: risk).map(\.estimatedSizeBytes))
    }

    var topStorageCandidates: [ScanCandidate] {
        candidates.sorted {
            if $0.estimatedSizeBytes == $1.estimatedSizeBytes {
                return $0.snapshot.standardizedPath.localizedStandardCompare(
                    $1.snapshot.standardizedPath
                ) == .orderedAscending
            }
            return $0.estimatedSizeBytes > $1.estimatedSizeBytes
        }
        .prefix(5)
        .map { $0 }
    }
}

enum CleanupScanPhase: String, Sendable {
    case preparing
    case enumerating
    case finalizing
}

enum CleanupScanRuleState: String, Codable, Equatable, Sendable {
    case pending
    case scanning
    case clean
    case found
    case skipped
    case failed
}

struct CleanupScanProgress: Sendable {
    struct GroupSummary: Identifiable, Sendable {
        let id: String
        let title: String
        let itemCount: Int
        let bytes: Int64
        let risk: CleanupRisk
        let state: CleanupScanRuleState
        let currentPath: String?

        init(
            id: String,
            title: String,
            itemCount: Int,
            bytes: Int64,
            risk: CleanupRisk = .informational,
            state: CleanupScanRuleState = .pending,
            currentPath: String? = nil
        ) {
            self.id = id
            self.title = title
            self.itemCount = itemCount
            self.bytes = bytes
            self.risk = risk
            self.state = state
            self.currentPath = currentPath
        }
    }

    let phase: CleanupScanPhase
    var currentRuleID: String? = nil
    let currentRuleTitle: String
    /// 正在扫描的具体位置（可选），用于像柠檬清理那样提示用户当前在扫哪里。
    var currentPath: String? = nil
    var currentRuleCompletedItemCount: Int = 0
    var currentRuleTotalItemCount: Int = 0
    let completedRuleCount: Int
    let totalRuleCount: Int
    let discoveredItemCount: Int
    let discoveredBytes: Int64
    let groups: [GroupSummary]
}

enum CleanupScanMode: String, Codable, Sendable {
    case standard
}

struct CleanupScanRequest: Sendable {
    static let standardMaximumDuration: TimeInterval = 300

    let mode: CleanupScanMode
    let userHomeURL: URL
    let excludedURLs: [URL]
    let maximumDuration: TimeInterval
    let developerInactivityThresholdDays: Int
    let includedCategoryIDs: Set<String>?
    let includedRuleIDs: Set<String>?

    init(
        mode: CleanupScanMode = .standard,
        userHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        excludedURLs: [URL] = [],
        maximumDuration: TimeInterval = CleanupScanRequest.standardMaximumDuration,
        developerInactivityThresholdDays: Int = DeveloperCleanupAgePolicy.defaultThresholdDays,
        includedCategoryIDs: Set<String>? = nil,
        includedRuleIDs: Set<String>? = nil
    ) {
        self.mode = mode
        self.userHomeURL = userHomeURL
        self.excludedURLs = excludedURLs
        self.maximumDuration = maximumDuration.isFinite
            ? max(0, maximumDuration)
            : Self.standardMaximumDuration
        self.developerInactivityThresholdDays = DeveloperCleanupAgePolicy.normalizedThresholdDays(
            developerInactivityThresholdDays
        )
        self.includedCategoryIDs = includedCategoryIDs.flatMap { $0.isEmpty ? nil : $0 }
        self.includedRuleIDs = includedRuleIDs
    }
}

enum SafeCleanupScanScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case caches
    case logs
    case temporaryFiles
    case downloadResidue

    var id: String { rawValue }

    func includes(_ rule: CleanupRule) -> Bool {
        let isLog = rule.developerArtifactKind == .logs
            || rule.id.localizedCaseInsensitiveContains("log")
        switch self {
        case .caches:
            return !isLog && (
                rule.categoryID == "browser-cache"
                    || rule.categoryID == "application-cache"
                    || rule.id == "system.user-caches"
                    || rule.id.hasPrefix("system-cache.")
                    || (rule.categoryID != "developer"
                        && rule.id.localizedCaseInsensitiveContains("cache"))
            )
        case .logs:
            return isLog
        case .temporaryFiles:
            return rule.developerArtifactKind == .temporaryFiles
        case .downloadResidue:
            return rule.categoryID == "downloads"
        }
    }
}

enum TriStateSelection: String, Sendable {
    case unchecked
    case checked
    case mixed
}

struct CleanupSelection: Sendable {
    private(set) var selectedCandidateIDs: Set<ScanCandidateID>
    private(set) var explicitlySelectedCandidateIDs: Set<ScanCandidateID>

    init(
        selectedCandidateIDs: Set<ScanCandidateID> = [],
        explicitlySelectedCandidateIDs: Set<ScanCandidateID> = []
    ) {
        self.selectedCandidateIDs = selectedCandidateIDs
        self.explicitlySelectedCandidateIDs = explicitlySelectedCandidateIDs
            .intersection(selectedCandidateIDs)
    }

    static func recommended(
        in session: ScanSession,
        preservingExplicitReviewFrom current: CleanupSelection = CleanupSelection()
    ) -> CleanupSelection {
        guard session.outcome != .cancelled else { return CleanupSelection() }
        let recommendedIDs = Set(session.candidates.filter {
            $0.isSelectable
                && $0.defaultSelection != .forbidden
                && $0.recommendation.level == .recommended
        }.map(\.id))
        let explicitReviewIDs = Set(session.candidates.filter {
            $0.requiresExplicitReview
                && $0.isSelectable
                && (recommendedIDs.contains($0.id)
                    || current.isExplicitlySelected($0.id))
        }.map(\.id))
        return CleanupSelection(
            selectedCandidateIDs: recommendedIDs.union(explicitReviewIDs),
            explicitlySelectedCandidateIDs: explicitReviewIDs
        )
    }

    static func defaults(in session: ScanSession) -> CleanupSelection {
        guard session.outcome != .cancelled else { return CleanupSelection() }
        return CleanupSelection(selectedCandidateIDs: Set(
            session.candidates
                .filter { $0.isSelectable && $0.defaultSelection == .selected }
                .map(\.id)
        ))
    }

    mutating func setCandidate(
        _ candidateID: ScanCandidateID,
        selected: Bool,
        in session: ScanSession
    ) {
        guard let candidate = session.candidates.first(where: { $0.id == candidateID }),
              candidate.sessionID == session.id,
              candidate.isSelectable,
              session.outcome != .cancelled else {
            selectedCandidateIDs.remove(candidateID)
            explicitlySelectedCandidateIDs.remove(candidateID)
            return
        }
        if selected {
            selectedCandidateIDs.insert(candidateID)
            explicitlySelectedCandidateIDs.insert(candidateID)
        } else {
            selectedCandidateIDs.remove(candidateID)
            explicitlySelectedCandidateIDs.remove(candidateID)
        }
    }

    mutating func setCandidates(
        _ candidateIDs: [ScanCandidateID],
        selected: Bool,
        in session: ScanSession
    ) {
        let requestedIDs = Set(candidateIDs)
        guard !requestedIDs.isEmpty else { return }

        guard session.outcome != .cancelled else {
            selectedCandidateIDs.subtract(requestedIDs)
            explicitlySelectedCandidateIDs.subtract(requestedIDs)
            return
        }

        // Resolve the whole batch in one pass. Calling setCandidate for every
        // row searched session.candidates from the beginning each time, which
        // made large category toggles quadratic and visibly stalled the UI.
        let validIDs = Set(session.candidates.lazy.compactMap { candidate in
            requestedIDs.contains(candidate.id)
                && candidate.sessionID == session.id
                && candidate.isSelectable
                ? candidate.id
                : nil
        })
        let invalidIDs = requestedIDs.subtracting(validIDs)
        selectedCandidateIDs.subtract(invalidIDs)
        explicitlySelectedCandidateIDs.subtract(invalidIDs)

        if selected {
            selectedCandidateIDs.formUnion(validIDs)
            explicitlySelectedCandidateIDs.formUnion(validIDs)
        } else {
            selectedCandidateIDs.subtract(validIDs)
            explicitlySelectedCandidateIDs.subtract(validIDs)
        }
    }

    func state(for candidateIDs: [ScanCandidateID]) -> TriStateSelection {
        guard !candidateIDs.isEmpty else { return .unchecked }
        let selectedCount = candidateIDs.reduce(0) {
            $0 + (selectedCandidateIDs.contains($1) ? 1 : 0)
        }
        if selectedCount == 0 { return .unchecked }
        if selectedCount == candidateIDs.count { return .checked }
        return .mixed
    }

    func selectedCandidates(in session: ScanSession) -> [ScanCandidate] {
        session.candidates.filter {
            $0.sessionID == session.id
                && $0.isSelectable
                && selectedCandidateIDs.contains($0.id)
        }
    }

    func isExplicitlySelected(_ candidateID: ScanCandidateID) -> Bool {
        selectedCandidateIDs.contains(candidateID)
            && explicitlySelectedCandidateIDs.contains(candidateID)
    }

    func limited(to candidateIDs: Set<ScanCandidateID>) -> CleanupSelection {
        CleanupSelection(
            selectedCandidateIDs: selectedCandidateIDs.intersection(candidateIDs),
            explicitlySelectedCandidateIDs: explicitlySelectedCandidateIDs.intersection(candidateIDs)
        )
    }

    func selectedBytes(in session: ScanSession) -> Int64 {
        CleanupByteCount.sum(
            selectedCandidates(in: session).map(\.estimatedSizeBytes)
        )
    }
}

struct CleanupDryRunSummary: Sendable {
    let sessionID: ScanSessionID
    let createdAt: Date
    let selectedCount: Int
    let selectedBytes: Int64
    let paths: [String]

    static func make(
        session: ScanSession,
        selection: CleanupSelection,
        limitingTo candidateIDs: Set<ScanCandidateID>? = nil
    ) -> CleanupDryRunSummary {
        let candidates = selection.selectedCandidates(in: session).filter {
            candidateIDs?.contains($0.id) ?? true
        }
        return CleanupDryRunSummary(
            sessionID: session.id,
            createdAt: Date(),
            selectedCount: candidates.count,
            selectedBytes: CleanupByteCount.sum(candidates.map(\.estimatedSizeBytes)),
            paths: candidates.map(\.snapshot.standardizedPath).sorted()
        )
    }
}
