import Foundation

struct KnownRegenerableCacheDefinition: Sendable {
    let id: String
    let ownerDisplayName: String
    let categoryID: String
    let categoryTitleKey: String
    let titleKey: String
    let rootPath: String
    let candidateNames: [String]
    let minimumBytes: Int64
    let requiredClosedBundleIDs: [String]

    var cleanupRule: CleanupRule {
        CleanupRule(
            id: id,
            selectionPolicyVersion: 1,
            categoryID: categoryID,
            categoryTitleKey: categoryTitleKey,
            titleKey: titleKey,
            root: CleanupRuleRoot(kind: .homeRelative, path: rootPath),
            maximumDepth: 32,
            minimumAgeDays: 0,
            minimumBytes: minimumBytes,
            include: CleanupRuleMatch(
                entryKinds: [.directory],
                extensions: [],
                nameMatcher: CleanupNameMatcher(
                    mode: .exact,
                    values: candidateNames
                )
            ),
            exclude: CleanupRuleExclusion(
                relativePrefixes: [],
                extensions: []
            ),
            cloudPolicy: .excludeCloudRoots,
            risk: .safe,
            recommendation: .optional,
            defaultSelection: .unselected,
            executionEligibility: .eligible,
            measurementRequirement: .complete,
            allowsManualSelection: true,
            action: .moveToTrash,
            requiredClosedBundleIDs: requiredClosedBundleIDs,
            reasonKey: "cleanup.reason.knownRegenerableCache",
            ownerDisplayName: ownerDisplayName
        )
    }
}

struct KnownReadOnlyCoverageDefinition: Sendable {
    let id: String
    let ownerDisplayName: String
    let categoryID: String
    let categoryTitleKey: String
    let titleKey: String
    let reasonKey: String
    let rootPath: String
    let candidateNames: [String]
    let minimumBytes: Int64
    let requiredClosedBundleIDs: [String]

    var cleanupRule: CleanupRule {
        CleanupRule(
            id: id,
            selectionPolicyVersion: 1,
            categoryID: categoryID,
            categoryTitleKey: categoryTitleKey,
            titleKey: titleKey,
            root: CleanupRuleRoot(kind: .homeRelative, path: rootPath),
            maximumDepth: 32,
            minimumAgeDays: 0,
            minimumBytes: minimumBytes,
            include: CleanupRuleMatch(
                entryKinds: [.directory],
                extensions: [],
                nameMatcher: CleanupNameMatcher(
                    mode: .exact,
                    values: candidateNames
                )
            ),
            exclude: CleanupRuleExclusion(
                relativePrefixes: [],
                extensions: []
            ),
            cloudPolicy: .skipPlaceholder,
            risk: .reviewOnly,
            recommendation: .advisoryOnly,
            defaultSelection: .forbidden,
            executionEligibility: .advisoryOnly,
            measurementRequirement: .bestEffort,
            allowsManualSelection: false,
            action: .revealOnly,
            requiredClosedBundleIDs: requiredClosedBundleIDs,
            reasonKey: reasonKey,
            ownerDisplayName: ownerDisplayName
        )
    }
}

enum CleanupCoverageCatalog {
    private static let kib: Int64 = 1_024
    private static let mib = kib * kib

    static let regenerableCacheDefinitions: [KnownRegenerableCacheDefinition] = [
        .init(
            id: "browser-cache.google-chrome",
            ownerDisplayName: "Google Chrome",
            categoryID: "browser-cache",
            categoryTitleKey: "cleanup.category.browserCaches",
            titleKey: "cleanup.rule.browserCache.title",
            rootPath: "Library/Caches/Google",
            candidateNames: ["Chrome"],
            minimumBytes: mib,
            requiredClosedBundleIDs: ["com.google.Chrome"]
        ),
        .init(
            id: "browser-cache.safari",
            ownerDisplayName: "Safari",
            categoryID: "browser-cache",
            categoryTitleKey: "cleanup.category.browserCaches",
            titleKey: "cleanup.rule.browserCache.title",
            rootPath: "Library/Containers/com.apple.Safari/Data/Library",
            candidateNames: ["Caches"],
            minimumBytes: mib,
            requiredClosedBundleIDs: ["com.apple.Safari"]
        ),
        .init(
            id: "browser-cache.microsoft-edge",
            ownerDisplayName: "Microsoft Edge",
            categoryID: "browser-cache",
            categoryTitleKey: "cleanup.category.browserCaches",
            titleKey: "cleanup.rule.browserCache.title",
            rootPath: "Library/Caches",
            candidateNames: ["Microsoft Edge"],
            minimumBytes: mib,
            requiredClosedBundleIDs: ["com.microsoft.edgemac"]
        ),
        .init(
            id: "browser-cache.brave",
            ownerDisplayName: "Brave",
            categoryID: "browser-cache",
            categoryTitleKey: "cleanup.category.browserCaches",
            titleKey: "cleanup.rule.browserCache.title",
            rootPath: "Library/Caches/BraveSoftware",
            candidateNames: ["Brave-Browser"],
            minimumBytes: mib,
            requiredClosedBundleIDs: ["com.brave.Browser"]
        ),
        .init(
            id: "browser-cache.firefox",
            ownerDisplayName: "Firefox",
            categoryID: "browser-cache",
            categoryTitleKey: "cleanup.category.browserCaches",
            titleKey: "cleanup.rule.browserCache.title",
            rootPath: "Library/Caches",
            candidateNames: ["Firefox"],
            minimumBytes: mib,
            requiredClosedBundleIDs: ["org.mozilla.firefox"]
        ),
        .init(
            id: "browser-cache.arc",
            ownerDisplayName: "Arc",
            categoryID: "browser-cache",
            categoryTitleKey: "cleanup.category.browserCaches",
            titleKey: "cleanup.rule.browserCache.title",
            rootPath: "Library/Caches",
            candidateNames: ["company.thebrowser.Browser"],
            minimumBytes: mib,
            requiredClosedBundleIDs: ["company.thebrowser.Browser"]
        ),
        .init(
            id: "application-cache.whatsapp",
            ownerDisplayName: "WhatsApp",
            categoryID: "application-cache",
            categoryTitleKey: "cleanup.category.applicationCaches",
            titleKey: "cleanup.rule.applicationCache.title",
            rootPath: "Library/Caches",
            candidateNames: ["net.whatsapp.WhatsApp"],
            minimumBytes: mib,
            requiredClosedBundleIDs: ["net.whatsapp.WhatsApp"]
        ),
        .init(
            id: "application-cache.codex",
            ownerDisplayName: "Codex",
            categoryID: "application-cache",
            categoryTitleKey: "cleanup.category.applicationCaches",
            titleKey: "cleanup.rule.applicationCache.title",
            rootPath: "Library/Caches",
            candidateNames: ["Codex", "com.openai.codex"],
            minimumBytes: mib,
            requiredClosedBundleIDs: ["com.openai.codex"]
        ),
        .init(
            id: "application-cache.ego-lite",
            ownerDisplayName: "ego lite",
            categoryID: "application-cache",
            categoryTitleKey: "cleanup.category.applicationCaches",
            titleKey: "cleanup.rule.applicationCache.title",
            rootPath: "Library/Caches/Citro Labs",
            candidateNames: ["ego lite"],
            minimumBytes: mib,
            requiredClosedBundleIDs: ["com.citrolabs.ego.lite"]
        ),
        .init(
            id: "application-cache.typeless-updater",
            ownerDisplayName: "Typeless",
            categoryID: "application-cache",
            categoryTitleKey: "cleanup.category.applicationCaches",
            titleKey: "cleanup.rule.applicationCache.title",
            rootPath: "Library/Caches",
            candidateNames: ["typeless-updater"],
            minimumBytes: mib,
            requiredClosedBundleIDs: ["now.typeless.desktop"]
        ),
        .init(
            id: "application-cache.zoom",
            ownerDisplayName: "Zoom",
            categoryID: "application-cache",
            categoryTitleKey: "cleanup.category.applicationCaches",
            titleKey: "cleanup.rule.applicationCache.title",
            rootPath: "Library/Caches",
            candidateNames: ["us.zoom.xos"],
            minimumBytes: mib,
            requiredClosedBundleIDs: ["us.zoom.xos"]
        ),
        .init(
            id: "developer.playwright-mcp-cache",
            ownerDisplayName: "Playwright MCP",
            categoryID: "developer",
            categoryTitleKey: "cleanup.category.developer",
            titleKey: "cleanup.rule.developerCache.title",
            rootPath: "Library/Caches",
            candidateNames: ["ms-playwright-mcp"],
            minimumBytes: mib,
            requiredClosedBundleIDs: []
        ),
        .init(
            id: "developer.pip-cache",
            ownerDisplayName: "pip",
            categoryID: "developer",
            categoryTitleKey: "cleanup.category.developer",
            titleKey: "cleanup.rule.developerCache.title",
            rootPath: "Library/Caches",
            candidateNames: ["pip"],
            minimumBytes: mib,
            requiredClosedBundleIDs: []
        ),
        .init(
            id: "developer.swiftpm-cache",
            ownerDisplayName: "SwiftPM",
            categoryID: "developer",
            categoryTitleKey: "cleanup.category.developer",
            titleKey: "cleanup.rule.developerCache.title",
            rootPath: "Library/Caches",
            candidateNames: ["org.swift.swiftpm"],
            minimumBytes: mib,
            requiredClosedBundleIDs: []
        ),
        .init(
            id: "developer.clang-cache",
            ownerDisplayName: "Clang",
            categoryID: "developer",
            categoryTitleKey: "cleanup.category.developer",
            titleKey: "cleanup.rule.developerCache.title",
            rootPath: "Library/Caches",
            candidateNames: ["clang"],
            minimumBytes: mib,
            requiredClosedBundleIDs: []
        ),
        .init(
            id: "developer.bun-cache",
            ownerDisplayName: "Bun",
            categoryID: "developer",
            categoryTitleKey: "cleanup.category.developer",
            titleKey: "cleanup.rule.developerCache.title",
            rootPath: "Library/Caches",
            candidateNames: ["bun"],
            minimumBytes: mib,
            requiredClosedBundleIDs: []
        ),
    ]

    static let readOnlyDefinitions: [KnownReadOnlyCoverageDefinition] = [
        .init(
            id: "system-cache.cloudkit",
            ownerDisplayName: "macOS CloudKit",
            categoryID: "system",
            categoryTitleKey: "cleanup.category.system",
            titleKey: "cleanup.rule.systemManagedCache.title",
            reasonKey: "cleanup.reason.systemManagedCache",
            rootPath: "Library/Caches",
            candidateNames: ["CloudKit"],
            minimumBytes: mib,
            requiredClosedBundleIDs: []
        ),
        .init(
            id: "system-log.diagnostics",
            ownerDisplayName: "macOS",
            categoryID: "system",
            categoryTitleKey: "cleanup.category.system",
            titleKey: "cleanup.rule.diagnosticLogs.title",
            reasonKey: "cleanup.reason.diagnosticLogs",
            rootPath: "Library/Logs",
            candidateNames: ["com.apple.diagnosticextensionsd"],
            minimumBytes: mib,
            requiredClosedBundleIDs: []
        ),
        .init(
            id: "application-log.codex",
            ownerDisplayName: "Codex",
            categoryID: "application-cache",
            categoryTitleKey: "cleanup.category.applicationCaches",
            titleKey: "cleanup.rule.applicationLogs.title",
            reasonKey: "cleanup.reason.applicationLogs",
            rootPath: "Library/Logs",
            candidateNames: ["com.openai.codex"],
            minimumBytes: mib,
            requiredClosedBundleIDs: ["com.openai.codex"]
        ),
    ]

    static let mailDownloadedAttachmentsRule = CleanupRule(
        id: "mail.downloaded-attachments",
        selectionPolicyVersion: 1,
        categoryID: "mail",
        categoryTitleKey: "cleanup.category.mail",
        titleKey: "cleanup.rule.mailDownloads.title",
        root: CleanupRuleRoot(
            kind: .homeRelative,
            path: "Library/Containers/com.apple.mail/Data/Library"
        ),
        maximumDepth: 32,
        minimumAgeDays: 0,
        minimumBytes: 1,
        include: CleanupRuleMatch(
            entryKinds: [.directory],
            extensions: [],
            nameMatcher: CleanupNameMatcher(
                mode: .exact,
                values: ["Mail Downloads"]
            )
        ),
        exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
        cloudPolicy: .skipPlaceholder,
        risk: .reviewOnly,
        recommendation: .advisoryOnly,
        defaultSelection: .forbidden,
        executionEligibility: .advisoryOnly,
        measurementRequirement: .bestEffort,
        allowsManualSelection: false,
        action: .revealOnly,
        requiredClosedBundleIDs: ["com.apple.mail"],
        reasonKey: "cleanup.reason.mailAttachments",
        ownerDisplayName: "Apple Mail"
    )

    static let mailLibraryAttachmentsRule = CleanupRule(
        id: "mail.library-attachments",
        selectionPolicyVersion: 1,
        categoryID: "mail",
        categoryTitleKey: "cleanup.category.mail",
        titleKey: "cleanup.rule.mailLibraryAttachments.title",
        root: CleanupRuleRoot(kind: .homeRelative, path: "Library/Mail"),
        candidateScope: .descendantAggregate,
        maximumDepth: 32,
        minimumAgeDays: 0,
        minimumBytes: 1,
        include: CleanupRuleMatch(
            entryKinds: [.directory],
            extensions: [],
            nameMatcher: CleanupNameMatcher(
                mode: .exact,
                values: ["Attachments"]
            )
        ),
        exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
        cloudPolicy: .skipPlaceholder,
        risk: .reviewOnly,
        recommendation: .advisoryOnly,
        defaultSelection: .forbidden,
        executionEligibility: .advisoryOnly,
        measurementRequirement: .bestEffort,
        allowsManualSelection: false,
        action: .revealOnly,
        requiredClosedBundleIDs: ["com.apple.mail"],
        reasonKey: "cleanup.reason.mailAttachments",
        ownerDisplayName: "Apple Mail"
    )

    static let userTrashRule = CleanupRule(
        id: "trash.user-trash",
        selectionPolicyVersion: 1,
        categoryID: "trash",
        categoryTitleKey: "cleanup.category.trash",
        titleKey: "cleanup.rule.userTrash.title",
        root: CleanupRuleRoot(kind: .homeRelative, path: ".Trash"),
        candidateScope: .root,
        maximumDepth: 32,
        minimumAgeDays: 0,
        minimumBytes: 1,
        include: CleanupRuleMatch(
            entryKinds: [.directory],
            extensions: [],
            nameMatcher: CleanupNameMatcher(mode: .any, values: [])
        ),
        exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
        cloudPolicy: .skipPlaceholder,
        risk: .reviewOnly,
        recommendation: .advisoryOnly,
        defaultSelection: .forbidden,
        executionEligibility: .advisoryOnly,
        measurementRequirement: .bestEffort,
        allowsManualSelection: false,
        action: .revealOnly,
        requiredClosedBundleIDs: [],
        reasonKey: "cleanup.reason.userTrash"
    )

    static var cleanupRules: [CleanupRule] {
        regenerableCacheDefinitions.map(\.cleanupRule)
            + readOnlyDefinitions.map(\.cleanupRule)
            + [
                mailDownloadedAttachmentsRule,
                mailLibraryAttachmentsRule,
                userTrashRule,
            ]
    }

    static func permitsAutomaticRule(_ rule: CleanupRule) -> Bool {
        regenerableCacheDefinitions.contains { definition in
            definition.id == rule.id
                && definition.ownerDisplayName == rule.ownerDisplayName
                && definition.categoryID == rule.categoryID
                && definition.categoryTitleKey == rule.categoryTitleKey
                && definition.titleKey == rule.titleKey
                && definition.rootPath == rule.root.path
                && definition.minimumBytes == rule.minimumBytes
                && Set(definition.candidateNames)
                    == Set(rule.include.nameMatcher.values)
                && Set(definition.requiredClosedBundleIDs)
                    == Set(rule.requiredClosedBundleIDs)
                && rule.effectiveCandidateScope == .immediateChildren
                && rule.include.nameMatcher.mode == .exact
        }
    }

    static func permitsDescendantAggregateRule(_ rule: CleanupRule) -> Bool {
        rule.id == mailLibraryAttachmentsRule.id
            && rule.root.path == mailLibraryAttachmentsRule.root.path
            && rule.ownerDisplayName == mailLibraryAttachmentsRule.ownerDisplayName
            && rule.include.nameMatcher.mode == .exact
            && Set(rule.include.nameMatcher.values) == Set(["Attachments"])
    }
}
