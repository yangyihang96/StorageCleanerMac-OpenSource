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

    static let session = ScanSession(
        id: sessionID,
        rulesVersion: "debug-smartscan-session-v1",
        startedAt: referenceDate.addingTimeInterval(-0.84),
        completedAt: referenceDate,
        outcome: .partial,
        categories: [
            CleanupScanCategory(
                id: "user-cache",
                title: "用户缓存",
                subcategories: [
                    CleanupScanSubcategory(
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
                    ),
                ]
            ),
            CleanupScanCategory(
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
            ),
        ],
        issues: [
            ScanIssue(
                id: UUID(uuidString: "89D17325-C940-4E2D-B707-93B6B6A9DFA2")!,
                ruleID: "debug-review-only",
                path: "/DebugFixture/Developer/build-artifacts",
                kind: .metadataUnavailable
            ),
        ],
        permissions: [
            CleanupPermissionReport(
                ruleID: "debug-user-cache",
                path: "/DebugFixture/Library/Caches",
                status: .readable
            ),
        ],
        metrics: ScanMetrics(
            visitedEntryCount: 84,
            visitedDirectoryCount: 18,
            candidateCount: 4,
            deduplicatedIdentityCount: 0,
            estimatedCandidateBytes: 3_244_000_000,
            completeMeasurementCandidateCount: 4,
            duration: 0.84
        ),
        system: SystemSnapshot(
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
        action: CleanupRuleAction
    ) -> ScanCandidate {
        let sourceURL = URL(fileURLWithPath: path)
        let executionEligibility: CleanupExecutionEligibility = switch action {
        case .moveToTrash: .eligible
        case .moveToTrashAfterReview: .eligibleAfterReview
        case .moveToTrashAfterProtectedReview: .eligibleAfterProtectedReview
        case .revealOnly: .advisoryOnly
        }
        return ScanCandidate(
            id: ScanCandidateID(rawValue: UUID(uuidString: id)!),
            sessionID: sessionID,
            ruleID: "debug-\(risk.rawValue)",
            ruleSelectionPolicyVersion: 1,
            categoryID: risk == .safe ? "user-cache" : "developer",
            categoryTitle: risk == .safe ? "用户缓存" : "开发缓存",
            subcategoryTitle: risk == .protected ? "高风险重复应用" : (risk == .safe ? "浏览器缓存" : "构建产物"),
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
                evidenceCodes: ["debug-only"]
            ),
            defaultSelection: risk == .safe && recommendation == .recommended
                ? .selected
                : .unselected,
            executionEligibility: executionEligibility,
            measurementCompleteness: .complete,
            isManuallySelectable: isManuallySelectable,
            action: action,
            requiredClosedBundleIDs: [],
            reason: risk == .safe
                ? "固定的安全候选，仅用于截图"
                : (risk == .reviewOnly
                    ? "固定的黄色候选，默认不选且需风险确认"
                    : "固定的红色高风险候选，默认不选且需双重确认")
        )
    }
}
#endif
