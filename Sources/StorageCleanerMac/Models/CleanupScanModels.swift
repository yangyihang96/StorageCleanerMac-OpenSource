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
    /// D23: permanently deletes the top-level Trash entries frozen at scan
    /// time. Never preselected and confirmed separately from Trash moves.
    case emptyTrash

    var movesToTrash: Bool {
        self == .moveToTrash
            || self == .moveToTrashAfterReview
            || self == .moveToTrashAfterProtectedReview
    }

    var permanentlyDeletes: Bool {
        self == .emptyTrash
    }

    /// Whether a plan item with this action changes the file system.
    var isExecutable: Bool {
        movesToTrash || permanentlyDeletes
    }
}

/// How a container rule (one row per child, such as `~/Library/Caches`)
/// finds the app that owns each row (D22).
enum CleanupOwnerInference: String, Codable, Sendable {
    /// The child name, or its reverse-DNS prefix, is the bundle identifier of
    /// an installed app. Rows whose owner cannot be found stay unresolved.
    case candidateName
}

/// The owner used for the running-app check before preselection (D22, D47)
/// and again before cleanup.
enum CleanupOwnerResolution: String, Codable, Hashable, Sendable {
    /// The rule names the owning apps (`requiredClosedBundleIDs`).
    case declared
    /// Found from the row name through an installed app's bundle identifier.
    case inferredFromName
    /// The row is an app bundle (a duplicate copy).
    case applicationBundle
    /// No app owns the row (system logs, command-line tools, downloads).
    case noApplication
    /// The row has an owner, but it could not be identified. D47 preselects
    /// it anyway; the row says the app is unknown.
    case unresolved
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
    case claudeDesktop
    case visualStudioCode
    case lmStudio
    case rodBrowser
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
        case .claudeDesktop: "Claude"
        case .visualStudioCode: "VS Code（含 Copilot）"
        case .lmStudio: "LM Studio"
        case .rodBrowser: "Rod 浏览器工具"
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
    /// A scoped scan retains the fingerprint of the complete loaded set.
    var fullSetProvenance: CleanupRuleSetProvenance? = nil

    var effectiveProvenance: CleanupRuleSetProvenance {
        if let fullSetProvenance, rules.allSatisfy({ rule in
            fullSetProvenance.rules.contains { reference in
                reference.ruleID == rule.id && reference.revision == rule.maintenance?.revision
                    && reference.contentHash == (try? CleanupRuleFingerprint.contentHash(for: rule))
            }
        }) { return fullSetProvenance }
        return CleanupRuleFingerprint.provenance(for: self)
    }
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
    var ownerInference: CleanupOwnerInference? = nil
    var maintenance: CleanupRuleMaintenance? = nil
    var projectArtifact: ProjectArtifactRequirement? = nil

    var effectiveCandidateScope: CleanupRuleCandidateScope {
        candidateScope ?? .immediateChildren
    }

    /// A rule that lists every child of its root as its own row, such as one
    /// row per app under `~/Library/Caches`.
    var isContainerRule: Bool {
        root.kind == .homeRelative
            && effectiveCandidateScope == .immediateChildren
            && include.nameMatcher.mode == .any
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
    /// Child names (or `name/…` paths) excluded from an immediate-children rule.
    let relativePrefixes: [String]
    let extensions: Set<String>
    /// Child names starting with one of these values are excluded.
    var namePrefixes: [String]? = nil

    func excludes(childName name: String) -> Bool {
        let normalized = name.precomposedStringWithCanonicalMapping
        return relativePrefixes.contains { value in
            let excluded = value.precomposedStringWithCanonicalMapping
            return normalized == excluded || normalized.hasPrefix(excluded + "/")
        } || (namePrefixes ?? []).contains {
            normalized.hasPrefix($0.precomposedStringWithCanonicalMapping)
        }
    }
}

enum DeveloperArtifactCleanupPolicy: Equatable, Sendable {
    /// Caches and temporary files; graded by the activity bands.
    case regenerable
    /// Tool logs; not graded by activity (D19, D22).
    case disposableLogs
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
    var revision = 1
    var checkedAt = "2026-10-12"
    var evidenceURLs: [String] = []

    var cleanupRule: CleanupRule {
        let isLog = policy == .disposableLogs
        // Logs are preselected while their app is closed (D22, D47); caches
        // and temporary files are graded by the developer activity bands.
        return CleanupRule(
            id: id,
            selectionPolicyVersion: isLog ? 2 : 1,
            categoryID: "developer",
            categoryTitleKey: "cleanup.category.developer",
            titleKey: "cleanup.rule.developerToolArtifact.title",
            root: CleanupRuleRoot(kind: .homeRelative, path: rootPath),
            maximumDepth: maximumDepth,
            minimumAgeDays: 0,
            minimumBytes: minimumBytes,
            include: CleanupRuleMatch(
                entryKinds: [.directory],
                extensions: [],
                nameMatcher: CleanupNameMatcher(mode: .exact, values: candidateNames)
            ),
            exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
            cloudPolicy: .excludeCloudRoots,
            risk: .safe,
            recommendation: isLog ? .recommended : .optional,
            defaultSelection: isLog ? .selected : .unselected,
            executionEligibility: .eligible,
            measurementRequirement: .complete,
            allowsManualSelection: true,
            action: .moveToTrash,
            requiredClosedBundleIDs: requiredClosedBundleIDs,
            reasonKey: isLog
                ? "cleanup.reason.developerToolLogs"
                : "cleanup.reason.regenerableDeveloperCache",
            developerTool: tool,
            developerArtifactKind: kind,
            maintenance: CleanupRuleMaintenance(
                source: .developerCatalog,
                revision: revision,
                checkedAt: checkedAt,
                impact: isLog ? "工具会重新生成日志，旧诊断记录将移入废纸篓" : "工具会重新生成缓存，首次使用可能稍慢或需要联网",
                evidenceURLs: evidenceURLs
            )
        )
    }
}

enum DeveloperToolArtifactCatalog {
    private static let kib: Int64 = 1_024
    private static let cursorBundleID = "com.todesktop.230313mzl4w4u92"
    private static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// Agent sessions, checkpoints, histories, project state and the Codex
    /// runtime folder `.codex/.tmp` are not junk and are not listed (D19);
    /// File Analysis still shows the space they use.
    static let definitions: [DeveloperToolArtifactDefinition] = [
        .init(id: "developer.codex-cache", rootPath: ".codex", candidateNames: ["cache"], tool: .codex, kind: .cache, policy: .regenerable, minimumBytes: 256 * kib),
        .init(id: "developer.codex-plugin-cache", rootPath: ".codex/plugins", candidateNames: ["cache"], tool: .codex, kind: .pluginCache, policy: .regenerable, minimumBytes: 256 * kib),
        .init(id: "developer.codex-temporary-files", rootPath: ".codex", candidateNames: ["tmp"], tool: .codex, kind: .temporaryFiles, policy: .regenerable, minimumBytes: 256 * kib),
        .init(id: "developer.codex-logs", rootPath: ".codex", candidateNames: ["logs"], tool: .codex, kind: .logs, policy: .disposableLogs, minimumBytes: 64 * kib),

        .init(id: "developer.claude-code-cache", rootPath: ".claude", candidateNames: ["cache"], tool: .claudeCode, kind: .cache, policy: .regenerable, minimumBytes: 256 * kib),
        .init(id: "developer.claude-code-plugin-cache", rootPath: ".claude/plugins", candidateNames: ["cache"], tool: .claudeCode, kind: .pluginCache, policy: .regenerable, minimumBytes: 256 * kib),
        .init(id: "developer.claude-code-temporary-files", rootPath: ".claude", candidateNames: ["tmp"], tool: .claudeCode, kind: .temporaryFiles, policy: .regenerable, minimumBytes: 256 * kib),
        .init(id: "developer.claude-code-app-cache", rootPath: "Library/Caches", candidateNames: ["Claude", "claude-code"], tool: .claudeCode, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib, requiredClosedBundleIDs: [claudeBundleID]),
        // D47 supplement (review P1-1a): the command-line tool's own cache,
        // graded by activity like the other developer caches.
        .init(id: "developer.claude-code-cli-cache", rootPath: "Library/Caches", candidateNames: ["claude-cli-nodejs"], tool: .claudeCode, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib),
        .init(id: "developer.claude-code-logs", rootPath: ".claude", candidateNames: ["debug", "logs"], tool: .claudeCode, kind: .logs, policy: .disposableLogs, minimumBytes: 64 * kib),

        .init(id: "developer.cursor-cache", rootPath: "Library/Application Support/Cursor", candidateNames: ["Cache", "CachedData", "Code Cache", "GPUCache"], tool: .cursor, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib, requiredClosedBundleIDs: [cursorBundleID]),
        .init(id: "developer.cursor-app-cache", rootPath: "Library/Caches", candidateNames: [cursorBundleID], tool: .cursor, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib, requiredClosedBundleIDs: [cursorBundleID]),
        .init(id: "developer.cursor-logs", rootPath: "Library/Application Support/Cursor", candidateNames: ["logs"], tool: .cursor, kind: .logs, policy: .disposableLogs, minimumBytes: 64 * kib, requiredClosedBundleIDs: [cursorBundleID]),

        .init(id: "developer.github-copilot-cache", rootPath: ".cache", candidateNames: ["github-copilot"], tool: .githubCopilot, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib),
        .init(id: "developer.github-copilot-app-cache", rootPath: "Library/Caches", candidateNames: ["GitHub Copilot"], tool: .githubCopilot, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib),
        .init(id: "developer.github-copilot-logs", rootPath: "Library/Logs", candidateNames: ["GitHub Copilot"], tool: .githubCopilot, kind: .logs, policy: .disposableLogs, minimumBytes: 64 * kib),

        .init(id: "developer.opencode-cache", rootPath: ".cache", candidateNames: ["opencode"], tool: .openCode, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib),
        .init(id: "developer.opencode-logs", rootPath: ".local/share/opencode", candidateNames: ["log", "logs"], tool: .openCode, kind: .logs, policy: .disposableLogs, minimumBytes: 64 * kib),

        .init(id: "developer.openclaw-cache", rootPath: ".openclaw", candidateNames: ["cache"], tool: .openClaw, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib),
        .init(id: "developer.openclaw-temporary-files", rootPath: ".openclaw", candidateNames: ["tmp"], tool: .openClaw, kind: .temporaryFiles, policy: .regenerable, minimumBytes: 64 * kib),
        .init(id: "developer.openclaw-app-cache", rootPath: "Library/Caches", candidateNames: ["OpenClaw"], tool: .openClaw, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib),
        .init(id: "developer.openclaw-logs", rootPath: ".openclaw", candidateNames: ["logs"], tool: .openClaw, kind: .logs, policy: .disposableLogs, minimumBytes: 64 * kib),
        .init(id: "developer.openclaw-app-logs", rootPath: "Library/Logs", candidateNames: ["OpenClaw"], tool: .openClaw, kind: .logs, policy: .disposableLogs, minimumBytes: 64 * kib),

        // `.workbuddy/audit-log` holds audit records, not disposable logs (P2-7).
        .init(id: "developer.workbuddy-logs", rootPath: ".workbuddy", candidateNames: ["logs", "traces"], tool: .workBuddy, kind: .logs, policy: .disposableLogs, minimumBytes: 1 * kib, maximumDepth: 2),

        .init(id: "developer.windsurf-logs", rootPath: "Library/Application Support/Windsurf", candidateNames: ["logs"], tool: .windsurf, kind: .logs, policy: .disposableLogs, minimumBytes: 1 * kib, maximumDepth: 2),

        .init(id: "developer.continue-index", rootPath: ".continue", candidateNames: ["index"], tool: .continueDev, kind: .contentCache, policy: .regenerable, minimumBytes: 64 * kib),

        // D83: only the runtime's generated cache directories, never its
        // userData root, Local Storage, IndexedDB, sessions or model storage.
        .init(id: "developer.claude-desktop-web-cache", rootPath: "Library/Application Support/Claude", candidateNames: ["Cache", "Code Cache", "GPUCache"], tool: .claudeDesktop, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib, requiredClosedBundleIDs: [claudeBundleID], evidenceURLs: ["https://www.electronjs.org/docs/latest/api/app#appgetpathname", "https://www.electronjs.org/docs/latest/api/session#sesclearcache"]),
        .init(id: "developer.codex-desktop-web-cache", rootPath: "Library/Application Support/Codex", candidateNames: ["Cache", "Code Cache", "GPUCache"], tool: .codex, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib, requiredClosedBundleIDs: ["com.openai.codex"], evidenceURLs: ["https://www.electronjs.org/docs/latest/api/app#appgetpathname", "https://www.electronjs.org/docs/latest/api/session#sesclearcache"]),
        .init(id: "developer.vscode-web-cache", rootPath: "Library/Application Support/Code", candidateNames: ["Cache", "Code Cache", "GPUCache"], tool: .visualStudioCode, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib, requiredClosedBundleIDs: ["com.microsoft.VSCode"], evidenceURLs: ["https://www.electronjs.org/docs/latest/api/app#appgetpathname", "https://www.electronjs.org/docs/latest/api/session#sesclearcache"]),
        .init(id: "developer.vscode-logs", rootPath: "Library/Application Support/Code", candidateNames: ["logs"], tool: .visualStudioCode, kind: .logs, policy: .disposableLogs, minimumBytes: 64 * kib, requiredClosedBundleIDs: ["com.microsoft.VSCode"], revision: 2, evidenceURLs: ["https://github.com/microsoft/vscode/blob/main/src/vs/platform/environment/common/environmentService.ts"]),
        // The observed Electron cache layout is known; a verified LM Studio
        // bundle identifier is not available in this directory-only audit.
        // Its activity and pre-execution write checks still apply (D52).
        .init(id: "developer.lmstudio-web-cache", rootPath: "Library/Application Support/LM Studio", candidateNames: ["Cache", "Code Cache", "GPUCache"], tool: .lmStudio, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib, evidenceURLs: ["https://www.electronjs.org/docs/latest/api/app#appgetpathname", "https://www.electronjs.org/docs/latest/api/session#sesclearcache"]),
        .init(id: "developer.rod-browser-downloads", rootPath: ".cache/rod", candidateNames: ["browser"], tool: .rodBrowser, kind: .cache, policy: .regenerable, minimumBytes: 64 * kib, evidenceURLs: ["https://github.com/go-rod/rod/blob/main/lib/launcher/browser.go"]),
    ]

    static var cleanupRules: [CleanupRule] {
        definitions.map(\.cleanupRule)
    }

    static func permitsAutomaticRule(_ rule: CleanupRule) -> Bool {
        definitions.contains {
            $0.id == rule.id
                && $0.rootPath == rule.root.path
                && Set($0.candidateNames) == Set(rule.include.nameMatcher.values)
                && rule.include.nameMatcher.mode == .exact
                && rule.effectiveCandidateScope == .immediateChildren
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
    case overlappingRules(ruleID: String)

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
        case let .overlappingRules(ruleID):
            L10n.text("清理规则会重复列出同一位置：\(ruleID)", "Cleanup rule would list the same location twice: \(ruleID)")
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
    /// Emptying the Trash: selectable, confirmed separately and irreversibly.
    case selectableWithPermanentDeletionReview
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
    /// Part of the folder could not be read (permission or depth limit), so
    /// its latest activity cannot be fully verified. A folder holding a user
    /// exclusion is not listed at all, because cleanup would skip it.
    case activityUnverified
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

    /// Developer caches and temporary files are graded by activity. Tool logs
    /// are not: they are preselected while their app is closed (D22, D47).
    static func applies(to rule: CleanupRule) -> Bool {
        rule.categoryID == "developer"
            && rule.root.kind == .homeRelative
            && rule.risk == .safe
            && rule.action == .moveToTrash
            && rule.executionEligibility == .eligible
            && rule.measurementRequirement == .complete
            && rule.allowsManualSelection
            && rule.developerArtifactKind != .logs
    }

    /// Skipped symbolic links are not followed and are not moved with their
    /// target, so they do not hide activity of the moved folder. Any other
    /// incomplete measurement leaves part of the folder unread.
    static func verifiesActivity(_ measurementCompleteness: MeasurementCompleteness) -> Bool {
        measurementCompleteness.isComplete
            || measurementCompleteness == .lowerBound(reason: .symbolicLinkSkipped)
    }

    static func decision(
        for rule: CleanupRule,
        latestModificationTimeNanoseconds: Int64?,
        measurementCompleteness: MeasurementCompleteness,
        referenceDate: Date,
        thresholdDays: Int
    ) -> DeveloperCleanupAgeDecision? {
        guard applies(to: rule) else { return nil }
        guard !measurementCompleteness.isFailed,
              let latestModificationTimeNanoseconds else {
            // Not listed: the scanner drops results that cannot be acted on.
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
        guard verifiesActivity(measurementCompleteness) else {
            // D19: still selectable, but only with the red two-step review.
            return DeveloperCleanupAgeDecision(
                band: .activityUnverified,
                risk: .protected,
                recommendation: .notRecommended,
                defaultSelection: .unselected,
                executionEligibility: .eligibleAfterProtectedReview,
                allowsManualSelection: true,
                action: .moveToTrashAfterProtectedReview,
                reasonCode: "cleanup.reason.developerActivityUnverified"
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
        case .activityUnverified:
            return L10n.text(
                "目录内有部分内容无法读取（权限或深度上限），最近一次可读修改距扫描约 \(days) 天，但不能确认其余部分是否仍在使用；默认不选，可逐项选择，执行前需要双重确认。清理时只把该目录本身移入废纸篓。",
                "Part of this folder could not be read (permission or depth limit). The latest readable change was about \(days) days before the scan, but the rest may still be in use. It is off by default, can be selected individually, and needs two confirmations. Cleanup moves only this folder itself to Trash."
            )
        case .unknown:
            return L10n.text(
                "无法完整确认目录内最近一次修改时间，因此按红色保护且不能加入清理计划。",
                "The latest modification time inside this folder could not be verified, so it remains protected and cannot enter a cleanup plan."
            )
        }
    }
}

/// Item 10 (D22 supplement): when a log row was last written. Since D47 it
/// no longer decides preselection; the row shows it as a hint.
enum CleanupLogWriteState: String, Sendable {
    /// Nothing written in the last 7 days.
    case quiet
    /// Written within the last 7 days, so the app may still be using it.
    case recent
    /// Part of the row could not be read, so recent writes cannot be ruled out.
    case unverified
}

/// Item 10 (D22 supplement, D40): records whether a user, diagnostic or
/// developer tool log row was written in the 7 days before the scan. D47
/// replaced the 7-day preselection rule: every green log row is preselected
/// unless its app is running, and a recent or unconfirmed write is shown on
/// the row (`CleanupCandidateRowHint`).
enum CleanupLogPreselectionPolicy {
    static let quietDays = 7
    static let evidencePrefix = "log-write-window:"

    static func applies(to rule: CleanupRule) -> Bool {
        if rule.developerArtifactKind == .logs { return true }
        guard rule.root.kind == .homeRelative else { return false }
        return rule.root.path == "Library/Logs" || rule.root.path.hasPrefix("Library/Logs/")
    }

    /// Skipped links do not hide writes to the row itself; any other part
    /// left unread might.
    static func state(
        latestWriteNanoseconds: Int64?,
        measurementCompleteness: MeasurementCompleteness,
        referenceDate: Date
    ) -> CleanupLogWriteState {
        guard let latestWriteNanoseconds,
              DeveloperCleanupAgePolicy.verifiesActivity(measurementCompleteness) else {
            return .unverified
        }
        let age = referenceDate.timeIntervalSince1970 - Double(latestWriteNanoseconds) / 1_000_000_000
        return age > Double(quietDays) * 86_400 ? .quiet : .recent
    }

    static func evidenceCode(for state: CleanupLogWriteState) -> String {
        evidencePrefix + state.rawValue
    }
}

enum CleanupSelectionPolicy {
    /// D19: a lower-bound measurement no longer blocks selection. Cleanup moves
    /// only the item's own root (internal symbolic links are never followed),
    /// so the size is shown as "at least". A failed measurement (the root
    /// itself could not be listed) stays unavailable and is not listed.
    static func eligibility(
        risk: CleanupRisk,
        isManuallySelectable: Bool,
        action: CleanupRuleAction,
        executionEligibility: CleanupExecutionEligibility,
        measurementCompleteness: MeasurementCompleteness
    ) -> SelectionEligibility {
        guard !measurementCompleteness.isFailed else { return .unavailable }
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
            if action == .emptyTrash {
                guard risk == .protected, isManuallySelectable else { return .protected }
                return .selectableWithPermanentDeletionReview
            }
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
    /// D22: the app that owns this item and whether it was running when the
    /// scan finished. `ownerBundleIdentifiers` is checked again before cleanup.
    var ownerResolution: CleanupOwnerResolution = .noApplication
    var ownerBundleIdentifiers: [String] = []
    var runningOwnerBundleIdentifiers: [String] = []
    /// D23: the top-level Trash entries frozen at scan time. Only these are
    /// deleted; anything put into the Trash later is left alone.
    var permanentDeletionEntries: [FileSnapshot]? = nil
    var ruleRevision: Int? = nil
    var rulesProvenance: CleanupRuleSetProvenance? = nil
    var ruleOwnerDisplayName: String? = nil
    var cleanupImpactText: String? = nil

    /// D82: prepared for the result-row view batch; no selection decisions here.
    var applicationOwnershipText: String {
        if let developerTool { return developerTool.displayName }
        if let ruleOwnerDisplayName { return ruleOwnerDisplayName }
        if !ownerBundleIdentifiers.isEmpty { return ownerBundleIdentifiers.joined(separator: "、") }
        return ownerResolution == .unresolved ? "未识别所属应用" : "系统或命令行工具"
    }

    /// D82 的中文记录；判断只在 `preselectionReason`（D93），界面用其本地化标题。
    var preselectionExplanationText: String {
        switch preselectionReason {
        case .ownerRunning: "所属应用正在运行，本次不预选"
        case .preselected: "绿色项目符合本次安全策略，按默认规则预选；执行前仍会复查"
        case .permanentDeletion: "永久删除需要单独确认，不预选"
        case .protected: "最近仍在使用或风险较高，需要两次确认，不预选"
        case .reviewRequired: "需要判断是否仍有用途，不预选"
        case .notReady: "测量或执行条件尚不满足，不预选"
        }
    }

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
            || selectionEligibility == .selectableWithPermanentDeletionReview
    }

    var requiresExplicitReview: Bool {
        selectionEligibility == .selectableWithReview
            || selectionEligibility == .selectableWithProtectedReview
            || selectionEligibility == .selectableWithPermanentDeletionReview
    }

    var isOwnerRunning: Bool {
        !runningOwnerBundleIdentifiers.isEmpty
    }

    /// D47 (replaces D22's unidentified-owner rule and D40's 7-day log rule):
    /// the only check that holds back a green row is a running owner app,
    /// because cleanup would skip that row anyway. A cache whose owner is
    /// unknown and a log written in the last 7 days are preselected; the row
    /// says so (`CleanupCandidateRowHint`).
    var isHeldBackFromPreselection: Bool {
        isOwnerRunning
    }

    /// D47: every green row (selectable without extra review, moved to Trash)
    /// is preselected unless its app is running. Yellow and red rows and
    /// "Empty Trash" (D23) never are, whatever their rule says.
    var isPreselectedByDefault: Bool {
        selectionEligibility == .selectable
            && defaultSelection != .forbidden
            && !isHeldBackFromPreselection
    }

    /// "Select Recommended" takes the rows whose rule recommends them, with the
    /// same owner check as preselection (D47). Every green row of the bundled
    /// rules is recommended, so in the product it matches the preselection.
    var isRecommendedForSelection: Bool {
        isSelectable
            && defaultSelection != .forbidden
            && recommendation.level == .recommended
            && !isHeldBackFromPreselection
    }

    var duplicateApplicationGroupCode: String? {
        recommendation.evidenceCodes.first { $0.hasPrefix("duplicate-bundle-group:") }
    }

    /// P2-1: the version and build of a duplicate app copy, shown on its row.
    var applicationVersionSummary: String? {
        guard duplicateApplicationGroupCode != nil else { return nil }
        let version = evidenceValue(prefix: "app-short-version:")
        let build = evidenceValue(prefix: "app-build:")
        switch (version, build) {
        case let (version?, build?):
            return L10n.text("版本 \(version)（构建 \(build)）", "Version \(version) (build \(build))")
        case let (version?, nil):
            return L10n.text("版本 \(version)", "Version \(version)")
        case let (nil, build?):
            return L10n.text("构建 \(build)", "Build \(build)")
        case (nil, nil):
            return L10n.text("未标注版本号", "No version number")
        }
    }

    /// P2-1: the copy `xcode-select` uses as the active developer directory.
    var isActiveDeveloperDirectory: Bool {
        recommendation.evidenceCodes.contains("active-developer-directory")
    }

    private func evidenceValue(prefix: String) -> String? {
        recommendation.evidenceCodes.first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Item 10 (D22 supplement): whether a log row was written recently;
    /// nil for rows that are not logs. Shown on the row (D47).
    var logWriteState: CleanupLogWriteState? {
        recommendation.evidenceCodes
            .first { $0.hasPrefix(CleanupLogPreselectionPolicy.evidencePrefix) }
            .flatMap {
                CleanupLogWriteState(rawValue: String($0.dropFirst(
                    CleanupLogPreselectionPolicy.evidencePrefix.count
                )))
            }
    }

    /// D22: records which owner apps are running in `applications`. A
    /// duplicate copy counts as running only when that exact bundle runs.
    func withRunningOwners(from applications: CleanupApplicationSnapshot) -> ScanCandidate {
        var updated = self
        switch ownerResolution {
        case .applicationBundle:
            updated.runningOwnerBundleIdentifiers = applications.runningBundlePaths
                .contains(PathSafety.lexicalPath(sourceURL.path))
                ? ownerBundleIdentifiers
                : []
        case .declared, .inferredFromName:
            updated.runningOwnerBundleIdentifiers = ownerBundleIdentifiers
                .filter(applications.runningBundleIdentifiers.contains)
        case .noApplication, .unresolved:
            updated.runningOwnerBundleIdentifiers = []
        }
        return updated
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
        guard candidate.isSelectable else { return .advisoryOnly }
        // D47: a cache whose owner could not be identified is preselected like
        // any green row, so it is no longer shown as merely optional; the row
        // says that its app is unknown instead.
        return candidate.recommendation.level
    }

    static func level(
        for candidates: [ScanCandidate],
        fallback: CleanupRecommendationLevel
    ) -> CleanupRecommendationLevel {
        candidates.contains(where: \.isSelectable) ? fallback : .advisoryOnly
    }
}

/// D47: a large cache row says that cleaning it has a cost — the app or tool
/// downloads or generates it again, which can take a while.
enum CleanupRebuildCostPolicy {
    /// One row of at least 5 GiB.
    static let largeCacheThresholdBytes: Int64 = 5 * 1_024 * 1_024 * 1_024

    static func showsHint(for candidate: ScanCandidate) -> Bool {
        isRebuildableCache(candidate)
            && candidate.estimatedSizeBytes >= largeCacheThresholdBytes
    }

    /// Caches and temporary files that apps and tools rebuild: not logs,
    /// downloads, mail attachment copies, duplicate app copies or the Trash.
    static func isRebuildableCache(_ candidate: ScanCandidate) -> Bool {
        guard candidate.action.movesToTrash,
              candidate.logWriteState == nil,
              candidate.duplicateApplicationGroupCode == nil else { return false }
        switch candidate.categoryID {
        case "browser-cache", "application-cache", "system", "developer":
            return true
        default:
            return false
        }
    }
}

/// Row hints that depend only on the candidate. D47 preselects these rows, so
/// the row says why the user might still want to clear the check.
enum CleanupCandidateRowHint {
    enum Tone: Equatable {
        case warning
        case secondary
    }

    struct Line: Equatable {
        let text: String
        let systemImage: String
        let tone: Tone
    }

    /// Item 10 (kept by D47): a log row still written in the last 7 days, or
    /// one that could not be read completely. D47: a cache row whose app could
    /// not be identified, so the running-app check cannot protect it.
    static func ownerStatus(for candidate: ScanCandidate) -> Line? {
        switch candidate.logWriteState {
        case .recent:
            return Line(
                text: L10n.text("最近 7 天内仍有写入", "Written within the last 7 days"),
                systemImage: "clock.arrow.circlepath",
                tone: .warning
            )
        case .unverified:
            return Line(
                text: L10n.text("无法确认最近 7 天内是否有写入", "Cannot confirm whether it was written in the last 7 days"),
                systemImage: "questionmark.circle",
                tone: .warning
            )
        case .quiet:
            // Logs never depended on their owner being identified (D40).
            return nil
        case nil:
            break
        }
        guard candidate.ownerResolution == .unresolved else { return nil }
        return Line(
            text: L10n.text(
                "未识别所属应用，清理前无法确认它是否在运行",
                "Its app could not be identified, so whether it is running cannot be checked"
            ),
            systemImage: "questionmark.app",
            // Review P2-8: a safety note (no running-app check can protect
            // this row), so it uses the warning colour like the log hints.
            tone: .warning
        )
    }

    /// D47: large caches cost time or downloads to rebuild.
    static func rebuildCost(for candidate: ScanCandidate) -> Line? {
        guard CleanupRebuildCostPolicy.showsHint(for: candidate) else { return nil }
        return Line(
            text: L10n.text(
                "体积较大：重建需要重新下载或生成，可能较慢",
                "Large cache: rebuilding it means downloading or generating it again, which may be slow"
            ),
            systemImage: "hourglass",
            tone: .secondary
        )
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
    /// D19: found, but it could not be selected and removed, so it is not
    /// listed. Counted under "some scopes were safely skipped".
    case candidateNotActionable
    /// Found, but it contains a path the user excluded. Cleanup would always
    /// skip it, so it is not listed; counted as not listed with this reason.
    case candidateContainsExcludedPath
    /// Found, but it holds the user's own data kept among caches, such as an
    /// IDE's local edit history. Not junk, so it is not listed; counted.
    case candidateContainsProtectedData
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
    /// Found but not listed because they could not be acted on (D19).
    let notActionableCandidateCount: Int
    /// Of those, items that contain a path the user excluded.
    let excludedPathCandidateCount: Int
    /// Of those, items that hold protected data such as IDE local history.
    let protectedDataCandidateCount: Int

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
        duration: TimeInterval,
        notActionableCandidateCount: Int = 0,
        excludedPathCandidateCount: Int = 0,
        protectedDataCandidateCount: Int = 0
    ) {
        self.notActionableCandidateCount = notActionableCandidateCount
        self.excludedPathCandidateCount = excludedPathCandidateCount
        self.protectedDataCandidateCount = protectedDataCandidateCount
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
    let smartScanScopes: Set<SmartScanScope>?
    let smartScanHealthSnapshot: ComputerHealthSnapshot?
    let smartScanHealthStatus: SmartScanHealthStatus?
    let rulesProvenance: CleanupRuleSetProvenance?

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
        includedRuleIDs: Set<String>? = nil,
        smartScanScopes: Set<SmartScanScope>? = nil,
        smartScanHealthSnapshot: ComputerHealthSnapshot? = nil,
        smartScanHealthStatus: SmartScanHealthStatus? = nil,
        rulesProvenance: CleanupRuleSetProvenance? = nil
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
        self.smartScanScopes = smartScanScopes
        self.smartScanHealthSnapshot = smartScanHealthSnapshot
        self.smartScanHealthStatus = smartScanHealthStatus
        // Existing Store wrappers rebuild sessions. Preserve scanner evidence
        // from their rows without requiring a change to ScanStore.swift.
        let rows = categories.flatMap(\.candidates)
        let first = rows.first?.rulesProvenance
        self.rulesProvenance = rulesProvenance ?? (rows.allSatisfy { $0.rulesProvenance == first } ? first : nil)
    }

    var candidates: [ScanCandidate] {
        categories.flatMap(\.candidates)
    }

    /// D68: only a Smart Scan that requested junk can update the app-wide
    /// cleanup summary. Dedicated Safe Cleanup and Developer Files results
    /// remain available on their own pages.
    var coversCleanupCandidates: Bool {
        smartScanScopes?.contains(.cleanupCandidates) == true
    }

    /// The same session with every candidate rebuilt by `transform`; a nil
    /// result removes the candidate. Identifiers, rules and counts stay
    /// consistent so a later plan from this session is still valid.
    func mappingCandidates(
        _ transform: (ScanCandidate) -> ScanCandidate?
    ) -> ScanSession {
        let mapped = categories.map { category in
            CleanupScanCategory(
                id: category.id,
                title: category.title,
                subcategories: category.subcategories.map { subcategory in
                    CleanupScanSubcategory(
                        id: subcategory.id,
                        title: subcategory.title,
                        risk: subcategory.risk,
                        recommendation: subcategory.recommendation,
                        reason: subcategory.reason,
                        candidates: subcategory.candidates.compactMap(transform)
                    )
                }
            )
        }
        let remaining = mapped.flatMap(\.candidates)
        return ScanSession(
            id: id,
            rulesVersion: rulesVersion,
            startedAt: startedAt,
            completedAt: completedAt,
            outcome: outcome,
            categories: mapped,
            issues: issues,
            permissions: permissions,
            metrics: ScanMetrics(
                visitedEntryCount: metrics.visitedEntryCount,
                visitedDirectoryCount: metrics.visitedDirectoryCount,
                candidateCount: remaining.count,
                deduplicatedIdentityCount: metrics.deduplicatedIdentityCount,
                estimatedCandidateBytes: CleanupByteCount.sum(remaining.map(\.estimatedSizeBytes)),
                completeMeasurementCandidateCount: remaining.filter { $0.measurementCompleteness.isComplete }.count,
                lowerBoundMeasurementCandidateCount: remaining.filter { $0.measurementCompleteness.isLowerBound }.count,
                failedMeasurementCandidateCount: remaining.filter { $0.measurementCompleteness.isFailed }.count,
                permissionFailureCount: metrics.permissionFailureCount,
                cloudSkippedCount: metrics.cloudSkippedCount,
                timedOutRuleCount: metrics.timedOutRuleCount,
                truncatedCandidateCount: metrics.truncatedCandidateCount,
                duration: metrics.duration,
                notActionableCandidateCount: metrics.notActionableCandidateCount,
                excludedPathCandidateCount: metrics.excludedPathCandidateCount,
                protectedDataCandidateCount: metrics.protectedDataCandidateCount
            ),
            system: system,
            developerInactivityThresholdDays: developerInactivityThresholdDays,
            includedCategoryIDs: includedCategoryIDs,
            includedRuleIDs: includedRuleIDs,
            smartScanScopes: smartScanScopes,
            smartScanHealthSnapshot: smartScanHealthSnapshot,
            smartScanHealthStatus: smartScanHealthStatus,
            rulesProvenance: rulesProvenance
        )
    }

    /// D22: refreshes which owner apps are running, for example when an app
    /// quits after the scan. Preselection and row labels follow the result.
    func updatingRunningOwners(from applications: CleanupApplicationSnapshot) -> ScanSession {
        mappingCandidates { $0.withRunningOwners(from: applications) }
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

/// The three tiers a scan's results page counts (D19, D23): the items that
/// can be selected and moved to Trash, without the separately confirmed
/// "清空废纸篓". The results page and the scan history (BOARD N20) count with
/// this one definition.
struct CleanupScanTierTotals {
    /// Every countable item, in the scan's order.
    let all: [ScanCandidate]
    let safe: [ScanCandidate]
    let review: [ScanCandidate]
    let protected: [ScanCandidate]

    init(categories: [CleanupScanCategory]) {
        let tiers = categories.flatMap(\.candidates).filter {
            !$0.action.permanentlyDeletes && $0.isSelectable
        }
        all = tiers
        safe = tiers.filter { $0.risk == .safe }
        review = tiers.filter { $0.risk == .reviewOnly }
        protected = tiers.filter { $0.risk == .protected }
    }

    var safeBytes: Int64 { CleanupByteCount.sum(safe.map(\.estimatedSizeBytes)) }
    var reviewBytes: Int64 { CleanupByteCount.sum(review.map(\.estimatedSizeBytes)) }
    var protectedBytes: Int64 { CleanupByteCount.sum(protected.map(\.estimatedSizeBytes)) }
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

    static let defaultSelection: Set<SafeCleanupScanScope> = Set(allCases)

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
        let recommendedIDs = Set(session.candidates.filter(\.isRecommendedForSelection).map(\.id))
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

    /// D47: every green row (caches, logs, developer caches unused for over a
    /// year) is checked unless its app is running. Yellow and red items and
    /// emptying the Trash (D23) never are.
    static func defaults(in session: ScanSession) -> CleanupSelection {
        guard session.outcome != .cancelled else { return CleanupSelection() }
        return CleanupSelection(selectedCandidateIDs: Set(
            session.candidates
                .filter(\.isPreselectedByDefault)
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
            // D25: the last unchecked copy of a duplicate app stays unchecked;
            // it is the copy that will be kept.
            if DuplicateApplicationRetentionPolicy.wouldSelectEveryCopy(
                adding: candidate,
                to: selectedCandidateIDs,
                in: session
            ) {
                return
            }
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
            // D25: checking a whole duplicate-app group keeps one copy.
            let keepers = DuplicateApplicationRetentionPolicy.keepers(
                forFullySelectedGroupsIn: selectedCandidateIDs,
                session: session
            )
            selectedCandidateIDs.subtract(keepers)
            explicitlySelectedCandidateIDs.subtract(keepers)
        } else {
            selectedCandidateIDs.subtract(validIDs)
            explicitlySelectedCandidateIDs.subtract(validIDs)
        }
    }

    /// Checkbox state for a group of rows. Copies of a duplicate app that are
    /// always kept do not hold the group in the mixed state.
    func groupState(
        for candidateIDs: [ScanCandidateID],
        in session: ScanSession
    ) -> TriStateSelection {
        state(for: DuplicateApplicationRetentionPolicy.selectableTargets(candidateIDs, in: session))
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

/// D25: a duplicate-app group always keeps one copy. When every copy would be
/// selected, the copy kept is, in order: a copy that was running when the scan
/// finished, the most recently modified bundle, the shorter path, then the
/// path that sorts first. The kept copy is the retained copy the executor
/// re-verifies before moving the others.
enum DuplicateApplicationRetentionPolicy {
    /// Round 3 (P2-7): a copy that is running, or that the command line tools
    /// use (`/var/db/xcode_select_link`), is always kept and cannot be
    /// selected. When both exist and differ, both are kept.
    static func isProtected(_ candidate: ScanCandidate) -> Bool {
        candidate.duplicateApplicationGroupCode != nil
            && (candidate.isOwnerRunning || candidate.isActiveDeveloperDirectory)
    }

    /// The copy kept when every copy of a group without a protected copy is
    /// checked: one directly in /Applications, then the most recently
    /// modified, then the shorter path. (Running and command-line-tools
    /// copies come first, but they are protected and never in such a group.)
    static func keeper(among members: [ScanCandidate]) -> ScanCandidate? {
        members.min { lhs, rhs in
            if lhs.isOwnerRunning != rhs.isOwnerRunning {
                return lhs.isOwnerRunning
            }
            if lhs.isActiveDeveloperDirectory != rhs.isActiveDeveloperDirectory {
                return lhs.isActiveDeveloperDirectory
            }
            let leftAtRoot = isDirectlyInAllowedRoot(lhs)
            let rightAtRoot = isDirectlyInAllowedRoot(rhs)
            if leftAtRoot != rightAtRoot {
                return leftAtRoot
            }
            let leftModified = lhs.snapshot.modificationTimeNanoseconds ?? .min
            let rightModified = rhs.snapshot.modificationTimeNanoseconds ?? .min
            if leftModified != rightModified {
                return leftModified > rightModified
            }
            let leftPath = lhs.snapshot.standardizedPath
            let rightPath = rhs.snapshot.standardizedPath
            if leftPath.count != rightPath.count {
                return leftPath.count < rightPath.count
            }
            return leftPath < rightPath
        }
    }

    private static func isDirectlyInAllowedRoot(_ candidate: ScanCandidate) -> Bool {
        PathSafety.lexicalPath(candidate.sourceURL.deletingLastPathComponent().path)
            == PathSafety.lexicalPath(candidate.allowedRootURL.path)
    }

    static func members(of groupCode: String, in session: ScanSession) -> [ScanCandidate] {
        session.candidates.filter { $0.duplicateApplicationGroupCode == groupCode }
    }

    /// Whether checking `candidate` is refused: it is protected, or it is the
    /// last unchecked copy of a group without a protected copy.
    static func wouldSelectEveryCopy(
        adding candidate: ScanCandidate,
        to selectedIDs: Set<ScanCandidateID>,
        in session: ScanSession
    ) -> Bool {
        guard let groupCode = candidate.duplicateApplicationGroupCode else { return false }
        if isProtected(candidate) { return true }
        let members = members(of: groupCode, in: session)
        guard !members.contains(where: isProtected) else { return false }
        return members.count > 1 && members.allSatisfy {
            $0.id == candidate.id || selectedIDs.contains($0.id)
        }
    }

    /// The IDs a group checkbox can actually select: checking every copy of a
    /// duplicate app keeps one, so the kept copies are left out when deciding
    /// whether the group counts as fully checked.
    static func selectableTargets(
        _ candidateIDs: [ScanCandidateID],
        in session: ScanSession
    ) -> [ScanCandidateID] {
        let keepers = keepers(forFullySelectedGroupsIn: Set(candidateIDs), session: session)
        guard !keepers.isEmpty else { return candidateIDs }
        return candidateIDs.filter { !keepers.contains($0) }
    }

    /// The copies to leave out of `selectedIDs`: every protected copy in it,
    /// and for a group without a protected copy whose copies are all in it,
    /// the keeper.
    static func keepers(
        forFullySelectedGroupsIn selectedIDs: Set<ScanCandidateID>,
        session: ScanSession
    ) -> Set<ScanCandidateID> {
        var groups = [String: [ScanCandidate]]()
        for candidate in session.candidates {
            guard let groupCode = candidate.duplicateApplicationGroupCode else { continue }
            groups[groupCode, default: []].append(candidate)
        }
        var kept = Set<ScanCandidateID>()
        for members in groups.values {
            let protected = members.filter(isProtected)
            if !protected.isEmpty {
                kept.formUnion(protected.map(\.id).filter(selectedIDs.contains))
            } else if members.count > 1,
                      members.allSatisfy({ selectedIDs.contains($0.id) }),
                      let keeper = keeper(among: members) {
                kept.insert(keeper.id)
            }
        }
        return kept
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
