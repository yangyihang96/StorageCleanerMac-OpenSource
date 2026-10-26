import Foundation

/// A cache or log folder whose exact path and owning app are known. These are
/// green and move to Trash, and are preselected while their app is closed
/// (D22, D47). Developer caches (`isRecommended == false`) keep "optional,
/// unselected" here only as a placeholder: the developer activity bands
/// replace both, and their green band (unused for over a year) is selected.
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
    var reasonKey = "cleanup.reason.knownRegenerableCache"
    var isRecommended = true
    var revision = 1
    var checkedAt = "2026-10-12"
    var impact = "应用会重新生成缓存，首次打开可能稍慢或需要联网"
    var evidenceURLs: [String] = []

    var cleanupRule: CleanupRule {
        CleanupRule(
            id: id,
            selectionPolicyVersion: isRecommended ? 2 : 1,
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
            recommendation: isRecommended ? .recommended : .optional,
            defaultSelection: isRecommended ? .selected : .unselected,
            executionEligibility: .eligible,
            measurementRequirement: .complete,
            allowsManualSelection: true,
            action: .moveToTrash,
            requiredClosedBundleIDs: requiredClosedBundleIDs,
            reasonKey: reasonKey,
            ownerDisplayName: ownerDisplayName,
            maintenance: CleanupRuleMaintenance(source: .coverageCatalog, revision: revision,
                checkedAt: checkedAt, impact: reasonKey.contains("Logs") ? "应用会重新生成日志，旧诊断记录将移入废纸篓" : impact, evidenceURLs: evidenceURLs)
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
            requiredClosedBundleIDs: [],
            isRecommended: false
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
            requiredClosedBundleIDs: [],
            isRecommended: false
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
            requiredClosedBundleIDs: [],
            isRecommended: false
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
            requiredClosedBundleIDs: [],
            isRecommended: false
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
            requiredClosedBundleIDs: [],
            isRecommended: false
        ),
    ] + developerToolCacheDefinitions

    /// D47 supplement (review P1-1a): caches that command-line developer tools
    /// keep in `~/Library/Caches` under their own exact names. They are graded
    /// by developer activity (D22): written within the threshold, red; within
    /// a year, yellow; only unchanged for over a year, green and preselected.
    /// Without these rules they were green user-cache rows whose owner could
    /// not be identified, so D47 preselected them even while in use.
    private static let developerToolCacheDefinitions: [KnownRegenerableCacheDefinition] = [
        ("developer.go-build-cache", "Go", ["go-build"]),
        ("developer.gopls-cache", "gopls", ["gopls"]),
        ("developer.golangci-lint-cache", "golangci-lint", ["golangci-lint"]),
        ("developer.playwright-browsers", "Playwright", ["ms-playwright", "ms-playwright-go"]),
        ("developer.pnpm-cache", "pnpm", ["pnpm"]),
        ("developer.yarn-cache", "Yarn", ["Yarn"]),
        ("developer.node-gyp-cache", "node-gyp", ["node-gyp"]),
        ("developer.typescript-cache", "TypeScript", ["typescript"]),
        ("developer.deno-cache", "Deno", ["deno"]),
        ("developer.electron-cache", "Electron", ["electron", "electron-builder"]),
        ("developer.cypress-cache", "Cypress", ["Cypress"]),
        ("developer.poetry-cache", "Poetry", ["pypoetry"]),
        ("developer.cocoapods-cache", "CocoaPods", ["CocoaPods"]),
        ("developer.carthage-cache", "Carthage", ["org.carthage.CarthageKit"]),
        ("developer.sccache-cache", "sccache", ["Mozilla.sccache"]),
        ("developer.flutter-cache", "Flutter", ["flutter_engine"]),
    ].map { id, owner, names in
        KnownRegenerableCacheDefinition(
            id: id,
            ownerDisplayName: owner,
            categoryID: "developer",
            categoryTitleKey: "cleanup.category.developer",
            titleKey: "cleanup.rule.developerCache.title",
            rootPath: "Library/Caches",
            candidateNames: names,
            minimumBytes: mib,
            requiredClosedBundleIDs: [],
            isRecommended: false
        )
    }

    /// D19/D22/D47: diagnostic and app logs are green and preselected while
    /// their app is closed, also when written in the last 7 days (the row
    /// says so). macOS diagnostics have no owning app.
    static let logDefinitions: [KnownRegenerableCacheDefinition] = [
        .init(
            id: "system-log.diagnostics",
            ownerDisplayName: "macOS",
            categoryID: "system",
            categoryTitleKey: "cleanup.category.system",
            titleKey: "cleanup.rule.diagnosticLogs.title",
            rootPath: "Library/Logs",
            candidateNames: ["com.apple.diagnosticextensionsd"],
            minimumBytes: mib,
            requiredClosedBundleIDs: [],
            reasonKey: "cleanup.reason.diagnosticLogs"
        ),
        .init(
            id: "application-log.codex",
            ownerDisplayName: "Codex",
            categoryID: "application-cache",
            categoryTitleKey: "cleanup.category.applicationCaches",
            titleKey: "cleanup.rule.applicationLogs.title",
            rootPath: "Library/Logs",
            candidateNames: ["com.openai.codex"],
            minimumBytes: mib,
            requiredClosedBundleIDs: ["com.openai.codex"],
            reasonKey: "cleanup.reason.applicationLogs"
        ),
    ]

    /// D19/D22: CloudKit caches can be cleaned but need judgment, so they are
    /// yellow and never preselected.
    static let cloudKitCacheRule = CleanupRule(
        id: "system-cache.cloudkit",
        selectionPolicyVersion: 2,
        categoryID: "system",
        categoryTitleKey: "cleanup.category.system",
        titleKey: "cleanup.rule.systemManagedCache.title",
        root: CleanupRuleRoot(kind: .homeRelative, path: "Library/Caches"),
        maximumDepth: 32,
        minimumAgeDays: 0,
        minimumBytes: mib,
        include: CleanupRuleMatch(
            entryKinds: [.directory],
            extensions: [],
            nameMatcher: CleanupNameMatcher(mode: .exact, values: ["CloudKit"])
        ),
        exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
        cloudPolicy: .excludeCloudRoots,
        risk: .reviewOnly,
        recommendation: .optional,
        defaultSelection: .unselected,
        executionEligibility: .eligibleAfterReview,
        measurementRequirement: .complete,
        allowsManualSelection: true,
        action: .moveToTrashAfterReview,
        requiredClosedBundleIDs: [],
        reasonKey: "cleanup.reason.systemManagedCache",
        ownerDisplayName: "macOS CloudKit",
        maintenance: CleanupRuleMaintenance(source: .coverageCatalog, revision: 1,
            checkedAt: "2026-10-12", impact: "系统会重新生成缓存，首次同步可能稍慢")
    )

    /// D24: "Mail Downloads" holds copies the system saved when attachments
    /// were opened. Yellow, selectable, never preselected; Mail must be
    /// closed. D183 lists the mail library's attachment folders separately.
    static let mailDownloadedAttachmentsRule = CleanupRule(
        id: "mail.downloaded-attachments",
        selectionPolicyVersion: 2,
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
        recommendation: .optional,
        defaultSelection: .unselected,
        executionEligibility: .eligibleAfterReview,
        measurementRequirement: .complete,
        allowsManualSelection: true,
        action: .moveToTrashAfterReview,
        requiredClosedBundleIDs: ["com.apple.mail"],
        reasonKey: "cleanup.reason.mailDownloads",
        ownerDisplayName: "Apple Mail",
        maintenance: CleanupRuleMaintenance(source: .coverageCatalog, revision: 1,
            checkedAt: "2026-10-12", impact: "已打开附件的下载副本将移入废纸篓，邮件原件不受影响")
    )

    /// D183: actual local Mail attachment folders, individually reviewable.
    static let mailLibraryAttachmentFoldersRule = CleanupRule(
        id: "mail.library-attachment-folders",
        selectionPolicyVersion: 2,
        categoryID: "mail",
        categoryTitleKey: "cleanup.category.mail",
        titleKey: "cleanup.rule.mailLibraryAttachments.title",
        root: CleanupRuleRoot(kind: .homeRelative, path: "Library/Mail"),
        candidateScope: .namedDescendantDirectories,
        maximumCandidates: 400,
        maximumDepth: 16,
        minimumAgeDays: 0,
        minimumBytes: 1_000_000,
        include: CleanupRuleMatch(
            entryKinds: [.directory],
            extensions: [],
            nameMatcher: CleanupNameMatcher(mode: .exact, values: ["Attachments"])
        ),
        exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
        cloudPolicy: .skipPlaceholder,
        risk: .reviewOnly,
        recommendation: .optional,
        defaultSelection: .unselected,
        executionEligibility: .eligibleAfterReview,
        measurementRequirement: .complete,
        allowsManualSelection: true,
        action: .moveToTrashAfterReview,
        requiredClosedBundleIDs: ["com.apple.mail"],
        reasonKey: "cleanup.reason.mailLibraryAttachments",
        ownerDisplayName: "Apple Mail",
        maintenance: CleanupRuleMaintenance(source: .coverageCatalog, revision: 1,
            checkedAt: "2026-10-23",
            impact: "附件将移入废纸篓，可放回。IMAP 等服务器邮件打开时会重新下载附件；仅存本机的邮件（如 POP 或“我的 Mac 上”邮箱）需从废纸篓放回附件后才能再查看")
    )

    /// D23: one separate item that permanently deletes the top-level entries
    /// that were in the Trash when the scan ran. Never preselected.
    static let userTrashRule = CleanupRule(
        id: "trash.user-trash",
        selectionPolicyVersion: 2,
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
        risk: .protected,
        recommendation: .notRecommended,
        defaultSelection: .unselected,
        executionEligibility: .eligibleAfterProtectedReview,
        measurementRequirement: .complete,
        allowsManualSelection: true,
        action: .emptyTrash,
        requiredClosedBundleIDs: [],
        reasonKey: "cleanup.reason.userTrash",
        maintenance: CleanupRuleMaintenance(source: .coverageCatalog, revision: 1,
            checkedAt: "2026-10-12", impact: "将永久删除扫描时已有的废纸篓项目，无法通过本应用恢复")
    )

    /// D-FP6 (竞品对比 2026-10-20): preference files macOS cannot read,
    /// listed one by one under System Junk (CleanMyMac's and Tencent Lemon's
    /// "broken preferences"). Yellow, never preselected: a few apps store
    /// other formats under the `.plist` extension. Only the files directly
    /// in `~/Library/Preferences`; `ByHost` and folders are not read.
    static let brokenPreferencesRule = CleanupRule(
        id: "system.broken-preferences",
        selectionPolicyVersion: 2,
        categoryID: "system",
        categoryTitleKey: "cleanup.category.system",
        titleKey: "cleanup.rule.brokenPreferences.title",
        root: CleanupRuleRoot(kind: .homeRelative, path: "Library/Preferences"),
        maximumDepth: 1,
        minimumAgeDays: 0,
        minimumBytes: 0,
        include: CleanupRuleMatch(
            entryKinds: [.regularFile],
            extensions: ["plist"],
            nameMatcher: CleanupNameMatcher(mode: .any, values: [])
        ),
        exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
        cloudPolicy: .excludeCloudRoots,
        risk: .reviewOnly,
        recommendation: .optional,
        defaultSelection: .unselected,
        executionEligibility: .eligibleAfterReview,
        measurementRequirement: .complete,
        allowsManualSelection: true,
        action: .moveToTrashAfterReview,
        requiredClosedBundleIDs: [],
        reasonKey: "cleanup.reason.brokenPreferences",
        ownerInference: .candidateName,
        maintenance: CleanupRuleMaintenance(source: .coverageCatalog, revision: 1,
            checkedAt: "2026-10-20", impact: "应用会恢复默认设置并按需重新生成设置文件"),
        contentRequirement: .unreadablePropertyList
    )

    /// D181: the same one-item emptying as D23, for the user's Trash folder
    /// on each other mounted volume (`/Volumes/<name>/.Trashes/<uid>`), one
    /// row per volume. Never preselected; deletes only the entries frozen at
    /// scan time, each re-verified before deletion.
    static let volumeTrashRule = CleanupRule(
        id: "trash.volume-trashes",
        selectionPolicyVersion: 2,
        categoryID: "trash",
        categoryTitleKey: "cleanup.category.trash",
        titleKey: "cleanup.rule.volumeTrash.title",
        root: CleanupRuleRoot(kind: .mountedVolumeTrashes, path: VolumeTrashLocator.volumesPath),
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
        risk: .protected,
        recommendation: .notRecommended,
        defaultSelection: .unselected,
        executionEligibility: .eligibleAfterProtectedReview,
        measurementRequirement: .complete,
        allowsManualSelection: true,
        action: .emptyTrash,
        requiredClosedBundleIDs: [],
        reasonKey: "cleanup.reason.volumeTrash",
        maintenance: CleanupRuleMaintenance(source: .coverageCatalog, revision: 1,
            checkedAt: "2026-10-23", impact: "将永久删除扫描时外接硬盘废纸篓里已有的项目，无法通过本应用恢复")
    )

    /// D192: iCloud Drive's Trash includes cloud-only entries. Metadata-only
    /// measurement and descriptor-relative unlinking must never download them.
    static let iCloudDriveTrashRule = CleanupRule(
        id: "trash.icloud-drive",
        selectionPolicyVersion: 2,
        categoryID: "trash",
        categoryTitleKey: "cleanup.category.trash",
        titleKey: "cleanup.rule.iCloudDriveTrash.title",
        root: CleanupRuleRoot(kind: .homeRelative, path: "Library/Mobile Documents/.Trash"),
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
        cloudPolicy: .metadataOnly,
        risk: .protected,
        recommendation: .notRecommended,
        defaultSelection: .unselected,
        executionEligibility: .eligibleAfterProtectedReview,
        measurementRequirement: .complete,
        allowsManualSelection: true,
        action: .emptyTrash,
        requiredClosedBundleIDs: [],
        reasonKey: "cleanup.reason.iCloudDriveTrash",
        maintenance: CleanupRuleMaintenance(source: .coverageCatalog, revision: 1,
            checkedAt: "2026-10-23", impact: "会从你所有设备上的 iCloud 云盘永久删除，不能撤销")
    )

    static var cleanupRules: [CleanupRule] {
        regenerableCacheDefinitions.map(\.cleanupRule)
            + logDefinitions.map(\.cleanupRule)
            + [
                cloudKitCacheRule,
                mailDownloadedAttachmentsRule,
                mailLibraryAttachmentFoldersRule,
                brokenPreferencesRule,
                userTrashRule,
                volumeTrashRule,
                iCloudDriveTrashRule,
            ]
    }

    static func permitsAutomaticRule(_ rule: CleanupRule) -> Bool {
        (regenerableCacheDefinitions + logDefinitions).contains { definition in
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
}
