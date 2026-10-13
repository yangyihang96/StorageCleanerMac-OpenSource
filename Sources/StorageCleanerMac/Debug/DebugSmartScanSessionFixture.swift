import Foundation

#if DEBUG
/// A deterministic, inert Smart Scan session used only to capture the real
/// results surface. It deliberately contains no live paths or executor state.
enum DebugSmartScanSessionFixture {
    static let launchArgument = "--debug-smartscan-session"

    enum Scenario: String, Hashable, Sendable {
        case results
    }

    static let referenceDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let presentationID = UUID(uuidString: "A4CCB60D-5EAB-4B69-8A67-7F559F55391E")!
    static let sessionID = ScanSessionID(
        rawValue: UUID(uuidString: "9150A4F6-0DA5-432B-9AC3-1BAF2C0724FE")!
    )

    static func scenario(arguments: [String]) -> Scenario? {
        guard let index = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return Scenario(rawValue: arguments[index + 1].lowercased())
    }

    static var launchScenario: Scenario? {
        scenario(arguments: ProcessInfo.processInfo.arguments)
    }

    /// Review P2-2: adds the D47 example rows for results-page screenshots.
    static let d47RowsArgument = "--debug-smartscan-d47-rows"
    /// Review P2-2: opens the results page's green tier and its groups, so a
    /// screenshot shows the rows, badges and hints without a click.
    static let expandGreenTierArgument = "--debug-smartscan-expand-green"

    static var expandsGreenTier: Bool {
        ProcessInfo.processInfo.arguments.contains(expandGreenTierArgument)
    }

    static let session = makeSession(
        includesD47Rows: ProcessInfo.processInfo.arguments.contains(d47RowsArgument)
    )

    /// The default fixture has two green, one yellow and one red row. With
    /// `includesD47Rows` the user-cache group starts with the D47 examples
    /// (review P2-2): a cache whose app is unknown, one whose app is running,
    /// a cache over the 5 GiB rebuild-cost limit and a recently written log.
    static func makeSession(includesD47Rows: Bool) -> ScanSession {
        let d47Rows = includesD47Rows ? d47Subcategories : []
        let rowCount = 4 + d47Rows.reduce(0) { $0 + $1.candidates.count }
        let d47Bytes = d47Rows.flatMap(\.candidates).reduce(Int64(0)) { $0 + $1.estimatedSizeBytes }
        return ScanSession(
            id: sessionID,
            rulesVersion: "debug-smartscan-session-v1",
            startedAt: referenceDate.addingTimeInterval(-0.84),
            completedAt: referenceDate,
            outcome: .partial,
            categories: [
                CleanupScanCategory(
                    id: "user-cache",
                    title: "用户缓存",
                    subcategories: d47Rows + [browserCacheSubcategory]
                ),
                developerCategory,
            ],
            issues: issues,
            permissions: permissions,
            metrics: ScanMetrics(
                visitedEntryCount: 84,
                visitedDirectoryCount: 18,
                candidateCount: rowCount,
                deduplicatedIdentityCount: 0,
                estimatedCandidateBytes: 3_244_000_000 + d47Bytes,
                completeMeasurementCandidateCount: rowCount,
                duration: 0.84
            ),
            system: system,
            smartScanScopes: [.cleanupCandidates, .filesToReview]
        )
    }

    /// Tests of the §3.3 bulk rule (review 2): a session whose green tier
    /// has one group per entry of `rowCounts`, each with that many inert
    /// rows under /DebugFixture. Row identities depend only on the group and
    /// row number, so a session with more groups keeps the earlier ones.
    static func makeBulkSession(rowCounts: [Int]) -> ScanSession {
        var inode: UInt64 = 20_000
        let subcategories = rowCounts.enumerated().map { group, count in
            CleanupScanSubcategory(
                id: "bulk-\(group)",
                title: "批量组 \(group)",
                risk: .safe,
                recommendation: .recommended,
                reason: "固定的批量测试组",
                candidates: (0..<count).map { row in
                    inode += 1
                    return candidate(
                        id: String(format: "B0000000-0000-4000-8000-%04d%08d", group, row),
                        inode: inode,
                        path: "/DebugFixture/Library/Caches/bulk-\(group)/item-\(row)",
                        bytes: 1_000_000,
                        risk: .safe,
                        recommendation: .recommended,
                        isManuallySelectable: true,
                        action: .moveToTrash,
                        categoryID: "bulk",
                        subcategoryTitle: "批量组 \(group)"
                    )
                }
            )
        }
        let rowCount = rowCounts.reduce(0, +)
        return ScanSession(
            id: sessionID,
            rulesVersion: "debug-smartscan-bulk-v1",
            startedAt: referenceDate.addingTimeInterval(-0.84),
            completedAt: referenceDate,
            outcome: .complete,
            categories: [CleanupScanCategory(id: "bulk", title: "批量", subcategories: subcategories)],
            issues: [],
            permissions: permissions,
            metrics: ScanMetrics(
                visitedEntryCount: rowCount,
                visitedDirectoryCount: rowCounts.count,
                candidateCount: rowCount,
                deduplicatedIdentityCount: 0,
                estimatedCandidateBytes: Int64(rowCount) * 1_000_000,
                completeMeasurementCandidateCount: rowCount,
                duration: 0.84
            ),
            system: system
        )
    }

    private static let browserCacheSubcategory = CleanupScanSubcategory(
        id: "browser-cache",
        title: "浏览器缓存",
        risk: .safe,
        recommendation: .recommended,
        reason: "已核对为可安全移至废纸篓的缓存",
        candidates: [
            candidate(
                id: "CBB9B9B9-9B12-4A02-A3F6-97017AEB0BE9",
                inode: 101,
                path: "/DebugFixture/Library/Caches/com.example.browser/cache.db",
                bytes: 1_842_000_000,
                risk: .safe,
                recommendation: .recommended,
                isManuallySelectable: true,
                action: .moveToTrash
            ),
            candidate(
                id: "93E6CC12-0BA4-4617-AB72-4E17A5D497F8",
                inode: 102,
                path: "/DebugFixture/Library/Caches/com.example.browser/image-cache",
                bytes: 322_000_000,
                risk: .safe,
                recommendation: .optional,
                isManuallySelectable: true,
                action: .moveToTrash
            ),
        ]
    )

    /// Review P2-2: the D47 examples. Paths stay under /DebugFixture and the
    /// "running" app is a made-up bundle identifier; nothing here refers to
    /// a real app, file or process.
    private static let d47Subcategories = [
        CleanupScanSubcategory(
            id: "application-cache",
            title: "应用缓存",
            risk: .safe,
            recommendation: .recommended,
            reason: "固定的应用缓存示例，仅用于截图",
            candidates: [
                candidate(
                    id: "ECC94A5B-C1F0-4FBD-B31D-23FFE9347986",
                    inode: 105,
                    path: "/DebugFixture/Library/Caches/com.example.unknown-helper",
                    bytes: 640_000_000,
                    risk: .safe,
                    recommendation: .recommended,
                    isManuallySelectable: true,
                    action: .moveToTrash,
                    categoryID: "application-cache",
                    subcategoryTitle: "应用缓存",
                    ownerResolution: .unresolved,
                    reason: "固定示例：所属应用无法识别的缓存"
                ),
                candidate(
                    id: "680E9097-6151-4B0A-808E-F7D5BFC827D2",
                    inode: 106,
                    path: "/DebugFixture/Library/Caches/com.example.editor",
                    bytes: 410_000_000,
                    risk: .safe,
                    recommendation: .recommended,
                    isManuallySelectable: true,
                    action: .moveToTrash,
                    categoryID: "application-cache",
                    subcategoryTitle: "应用缓存",
                    ownerResolution: .inferredFromName,
                    ownerBundleIdentifiers: ["com.example.editor"],
                    runningOwnerBundleIdentifiers: ["com.example.editor"],
                    reason: "固定示例：所属应用正在运行的缓存"
                ),
                candidate(
                    id: "6DD5FFC3-5E6A-4325-9E14-4D3FA5211E32",
                    inode: 107,
                    path: "/DebugFixture/Library/Caches/com.example.video-renders",
                    bytes: 6_400_000_000,
                    risk: .safe,
                    recommendation: .recommended,
                    isManuallySelectable: true,
                    action: .moveToTrash,
                    categoryID: "application-cache",
                    subcategoryTitle: "应用缓存",
                    ownerResolution: .inferredFromName,
                    ownerBundleIdentifiers: ["com.example.video"],
                    reason: "固定示例：体积较大的可重建缓存"
                ),
            ]
        ),
        CleanupScanSubcategory(
            id: "application-logs",
            title: "应用日志",
            risk: .safe,
            recommendation: .recommended,
            reason: "固定的日志示例，仅用于截图",
            candidates: [
                candidate(
                    id: "5C4C8CE1-F263-4580-A63F-343CDD3AD9BA",
                    inode: 108,
                    path: "/DebugFixture/Library/Logs/com.example.sync",
                    bytes: 96_000_000,
                    risk: .safe,
                    recommendation: .recommended,
                    isManuallySelectable: true,
                    action: .moveToTrash,
                    categoryID: "logs",
                    subcategoryTitle: "应用日志",
                    evidenceCodes: [
                        "debug-only",
                        CleanupLogPreselectionPolicy.evidencePrefix + CleanupLogWriteState.recent.rawValue,
                    ],
                    reason: "固定示例：最近 7 天内仍有写入的日志"
                ),
            ]
        ),
    ]

    private static let developerCategory = CleanupScanCategory(
        id: "developer",
        title: "开发缓存",
        subcategories: [
            CleanupScanSubcategory(
                id: "build-artifacts",
                title: "构建产物",
                risk: .reviewOnly,
                recommendation: .notRecommended,
                reason: "需要人工确认项目归属",
                candidates: [
                    candidate(
                        id: "B6B57C3D-CB42-4BC7-B615-2566E9CEFA02",
                        inode: 103,
                        path: "/DebugFixture/Developer/build-artifacts",
                        bytes: 820_000_000,
                        risk: .reviewOnly,
                        recommendation: .notRecommended,
                        isManuallySelectable: true,
                        action: .moveToTrashAfterReview
                    ),
                ]
            ),
            CleanupScanSubcategory(
                id: "protected-data",
                title: "高风险重复应用",
                risk: .protected,
                recommendation: .notRecommended,
                reason: "默认不选，手动选择后需要双重确认",
                candidates: [
                    candidate(
                        id: "D2E409C4-A7A2-4875-8CD4-13FE2FDCA4D6",
                        inode: 104,
                        path: "/Applications/Example Beta.app",
                        bytes: 260_000_000,
                        risk: .protected,
                        recommendation: .notRecommended,
                        isManuallySelectable: true,
                        action: .moveToTrashAfterProtectedReview
                    ),
                ]
            ),
        ]
    )

    private static let issues = [
        ScanIssue(
            id: UUID(uuidString: "89D17325-C940-4E2D-B707-93B6B6A9DFA2")!,
            ruleID: "debug-review-only",
            path: "/DebugFixture/Developer/build-artifacts",
            kind: .metadataUnavailable
        ),
    ]

    private static let permissions = [
        CleanupPermissionReport(
            ruleID: "debug-user-cache",
            path: "/DebugFixture/Library/Caches",
            status: .readable
        ),
    ]

    private static let system = SystemSnapshot(
        osName: "macOS 15.6",
        build: "debug",
        arch: "arm64",
        user: "Debug",
        home: "/DebugFixture",
        filesystem: "APFS",
        purgeable: "",
        diskName: "Debug Macintosh HD",
        diskTotalBytes: 512_000_000_000,
        diskUsedBytes: 398_000_000_000,
        diskFreeBytes: 114_000_000_000
    )

    static let selection = CleanupSelection.defaults(in: session)

    private static func candidate(
        id: String,
        inode: UInt64,
        path: String,
        bytes: Int64,
        risk: CleanupRisk,
        recommendation: CleanupRecommendationLevel,
        isManuallySelectable: Bool,
        action: CleanupRuleAction,
        categoryID: String? = nil,
        subcategoryTitle: String? = nil,
        evidenceCodes: [String] = ["debug-only"],
        ownerResolution: CleanupOwnerResolution = .noApplication,
        ownerBundleIdentifiers: [String] = [],
        runningOwnerBundleIdentifiers: [String] = [],
        reason: String? = nil
    ) -> ScanCandidate {
        let sourceURL = URL(fileURLWithPath: path)
        let executionEligibility: CleanupExecutionEligibility = switch action {
        case .moveToTrash: .eligible
        case .moveToTrashAfterReview: .eligibleAfterReview
        case .moveToTrashAfterProtectedReview, .emptyTrash: .eligibleAfterProtectedReview
        case .revealOnly: .advisoryOnly
        }
        var candidate = ScanCandidate(
            id: ScanCandidateID(rawValue: UUID(uuidString: id)!),
            sessionID: sessionID,
            ruleID: "debug-\(risk.rawValue)",
            ruleSelectionPolicyVersion: 1,
            categoryID: categoryID ?? (risk == .safe ? "user-cache" : "developer"),
            categoryTitle: risk == .safe ? "用户缓存" : "开发缓存",
            subcategoryTitle: subcategoryTitle
                ?? (risk == .protected ? "高风险重复应用" : (risk == .safe ? "浏览器缓存" : "构建产物")),
            sourceURL: sourceURL,
            allowedRootURL: risk == .protected
                ? URL(fileURLWithPath: "/Applications")
                : URL(fileURLWithPath: "/DebugFixture"),
            snapshot: FileSnapshot(
                identity: FileIdentity(
                    deviceID: 42,
                    inode: inode,
                    entryKind: .regularFile,
                    creationTimeNanoseconds: 800_000_000_000_000_000
                ),
                standardizedPath: path,
                volumeIdentifier: "debug-fixture-volume",
                logicalSizeBytes: bytes,
                allocatedSizeBytes: bytes,
                modificationTimeNanoseconds: 800_000_000_000_000_000,
                isWritableVolume: true,
                isCloudItem: false,
                isCloudPlaceholder: false,
                hasSymbolicLinkComponent: false
            ),
            risk: risk,
            recommendation: CleanupRecommendation(
                level: recommendation,
                reasonCode: "debug-fixture",
                evidenceCodes: evidenceCodes
            ),
            defaultSelection: risk == .safe && recommendation == .recommended
                ? .selected
                : .unselected,
            executionEligibility: executionEligibility,
            measurementCompleteness: .complete,
            isManuallySelectable: isManuallySelectable,
            action: action,
            requiredClosedBundleIDs: [],
            reason: reason ?? (risk == .safe
                ? "固定的安全候选，仅用于截图"
                : (risk == .reviewOnly
                    ? "固定的黄色候选，默认不选且需风险确认"
                    : "固定的红色高风险候选，默认不选且需双重确认"))
        )
        candidate.ownerResolution = ownerResolution
        candidate.ownerBundleIdentifiers = ownerBundleIdentifiers
        candidate.runningOwnerBundleIdentifiers = runningOwnerBundleIdentifiers
        return candidate
    }
}
#endif
