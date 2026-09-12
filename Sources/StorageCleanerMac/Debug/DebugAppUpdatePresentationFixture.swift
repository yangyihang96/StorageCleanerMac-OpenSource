import Foundation

#if DEBUG
/// Deterministic, inert data for visual acceptance of the production app-update UI.
/// Every value is synthetic and the Store blocks scanners, providers and executors while active.
enum DebugAppUpdatePresentationFixture {
    static let launchArgument = "--debug-app-updates"

    enum Scenario: String, CaseIterable, Hashable, Sendable {
        case idle
        case scanning
        case summary
        case managing
        case updating
        case partial
        case failed
    }

    static let referenceDate = Date(timeIntervalSinceReferenceDate: 800_100_000)
    static let sessionID = UUID(uuidString: "24DDF1F3-0A8E-4F33-8D19-22CF9C174E90")!

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

    static let applications: [InstalledApplication] = [
        application(
            id: "aurora-studio",
            name: "Aurora Studio",
            currentVersion: "4.8.1",
            latestVersion: "4.9.0",
            provider: .homebrew,
            installationSource: .homebrewCask,
            status: .automaticallyUpdatable,
            capability: .automatic,
            source: "Homebrew Cask",
            automaticCaskToken: "aurora-studio",
            downloadSize: 86_200_000
        ),
        application(
            id: "lumen-capture",
            name: "Lumen Capture",
            currentVersion: "2.3.0",
            latestVersion: "2.4.2",
            provider: .homebrew,
            installationSource: .homebrewCask,
            status: .automaticallyUpdatable,
            capability: .automatic,
            source: "Homebrew Cask",
            automaticCaskToken: "lumen-capture",
            downloadSize: 42_600_000
        ),
        application(
            id: "dayline",
            name: "Dayline",
            currentVersion: "8.1",
            latestVersion: "8.3",
            provider: .macAppStore,
            installationSource: .appStore,
            status: .updateAvailable,
            capability: .appStoreManaged,
            source: "App Store",
            sourceEvidence: ["verified-app-store-receipt"],
            downloadSize: 118_000_000
        ),
        application(
            id: "note-harbor",
            name: "Note Harbor",
            currentVersion: "6.5.2",
            latestVersion: "6.6.0",
            provider: .sparkle,
            installationSource: .sparkle,
            status: .applicationUpdateRequired,
            capability: .inApplication,
            source: "应用内更新",
            downloadSize: 31_400_000
        ),
        application(
            id: "pixel-forge",
            name: "Pixel Forge",
            currentVersion: "3.2",
            latestVersion: "3.4",
            provider: .officialWebsite,
            installationSource: .officialWebsite,
            status: .websiteUpdateRequired,
            capability: .websiteGuided,
            source: "已确认的开发者网站",
            downloadSize: 205_000_000
        ),
        application(
            id: "calm-reader",
            name: "Calm Reader",
            currentVersion: "5.0.1",
            latestVersion: nil,
            provider: .sparkle,
            installationSource: .sparkle,
            status: .upToDate,
            capability: .inApplication,
            source: "应用内更新"
        ),
        application(
            id: "archive-lens",
            name: "Archive Lens",
            currentVersion: "1.7",
            latestVersion: nil,
            provider: .manual,
            installationSource: .standardDirectory,
            status: .latestVersionUnknown,
            capability: .unavailable,
            source: "来源未确认"
        ),
    ]

    static func presentationState(for scenario: Scenario) -> AppUpdatePresentationState {
        switch scenario {
        case .idle:
            return .idle(nil)
        case .scanning:
            return .scanning(
                AppScanProgressSnapshot(
                    sessionID: sessionID,
                    generatedAt: referenceDate,
                    stage: .checkingVersions,
                    completedUnitCount: 9,
                    totalUnitCount: 14,
                    currentApplicationID: applications[3].id,
                    currentApplicationName: applications[3].displayName
                )
            )
        case .summary:
            return .scanSummary(summary)
        case .managing:
            return .managing(AppUpdateCatalogSnapshot(summary: summary))
        case .updating:
            return .updating(
                AppUpdateSessionSnapshot(
                    queue: makeQueueSnapshot(for: .updating),
                    applications: applications
                )
            )
        case .partial:
            return .completed(report(for: .partial))
        case .failed:
            return .failed(report(for: .failed))
        }
    }

    static func queueSnapshot(for scenario: Scenario) -> ApplicationUpdateQueueSnapshot? {
        switch scenario {
        case .updating, .partial, .failed:
            return makeQueueSnapshot(for: scenario)
        case .idle, .scanning, .summary, .managing:
            return nil
        }
    }

    static func lastScannedAt(for scenario: Scenario) -> Date? {
        switch scenario {
        case .idle, .scanning: nil
        case .summary, .managing, .updating, .partial, .failed: referenceDate
        }
    }

    static func warnings(for scenario: Scenario) -> [String] {
        scenario == .failed
            ? ["界面演示数据：示例 Provider 未能完成验证。"]
            : []
    }

    private static let summary = AppScanSummary(
        sessionID: sessionID,
        generatedAt: referenceDate,
        applications: applications
    )

    private static var automaticApplications: [InstalledApplication] {
        Array(applications.prefix(2))
    }

    private static func report(for scenario: Scenario) -> AppUpdateReport {
        AppUpdateReport(
            snapshot: AppUpdateSessionSnapshot(
                queue: makeQueueSnapshot(for: scenario),
                applications: applications
            ),
            sessionError: scenario == .failed
                ? "界面演示数据：所有自动更新均未完成。"
                : nil
        )
    }

    private static func makeQueueSnapshot(
        for scenario: Scenario
    ) -> ApplicationUpdateQueueSnapshot {
        let states: [(ApplicationUpdateTaskState, Double?, String, String?)]
        switch scenario {
        case .updating:
            states = [
                (.completed, 1, "界面演示：已完成磁盘版本复核", nil),
                (.installing, 0.63, "界面演示：正在准备安装", nil),
            ]
        case .partial:
            states = [
                (.completed, 1, "界面演示：更新及复核已完成", nil),
                (.failed, nil, "界面演示：未改动原应用", "示例签名验证失败"),
            ]
        case .failed:
            states = [
                (.failed, nil, "界面演示：未改动原应用", "示例下载来源不可用"),
                (.failed, nil, "界面演示：未改动原应用", "示例签名验证失败"),
            ]
        case .idle, .scanning, .summary, .managing:
            states = [(.queued, nil, "界面演示：等待处理", nil)]
        }

        let tasks = zip(automaticApplications, states).enumerated().map { index, pair in
            var task = ApplicationUpdateTask(
                id: taskIDs[index],
                sessionID: sessionID,
                application: pair.0,
                state: pair.1.0,
                createdAt: referenceDate.addingTimeInterval(-36)
            )
            task.progressFraction = pair.1.1
            task.detail = pair.1.2
            task.errorDescription = pair.1.3
            task.updatedAt = referenceDate
            task.attemptCount = 1
            return task
        }

        return ApplicationUpdateQueueSnapshot(
            schemaVersion: ApplicationUpdateQueueRepository.currentSchemaVersion,
            plan: ApplicationUpdatePlan(
                id: sessionID,
                createdAt: referenceDate.addingTimeInterval(-36),
                automaticApplicationIDs: automaticApplications.map(\.id),
                requiresQuitApplicationIDs: [],
                requiresAuthorizationApplicationIDs: [],
                appStoreApplicationIDs: [],
                websiteApplicationIDs: [],
                manualApplicationIDs: [],
                skippedApplicationIDs: []
            ),
            tasks: tasks,
            isPaused: false,
            updatedAt: referenceDate
        )
    }

    private static let taskIDs = [
        UUID(uuidString: "8E72C742-E7E5-494C-8F1E-4E427640B1A2")!,
        UUID(uuidString: "9EA40562-1D52-4E26-820D-E2A771D71D18")!,
    ]

    private static func application(
        id: String,
        name: String,
        currentVersion: String,
        latestVersion: String?,
        provider: ApplicationUpdateProviderIdentifier,
        installationSource: ApplicationInstallationSource,
        status: ApplicationUpdateStatus,
        capability: UpdateCapability,
        source: String,
        automaticCaskToken: String? = nil,
        sourceEvidence: [String] = [],
        downloadSize: Int64? = nil
    ) -> InstalledApplication {
        let bundleIdentifier = "com.storagecleaner.debug.appupdates.\(id)"
        let bundleURL = URL(fileURLWithPath: "/DebugAppUpdates/Applications/\(name).app")
        let latest = latestVersion.map { ApplicationVersion(marketing: $0) }
        let isAutomatic = automaticCaskToken != nil
        let evidence = isAutomatic
            ? sourceEvidence + ["homebrew-match:exact-artifact-path", "valid-code-signature"]
            : sourceEvidence
        let metadata = automaticCaskToken.map { token in
            HomebrewPackageMetadata(
                token: token,
                kind: .cask,
                homepageURL: nil,
                installedVersions: [currentVersion],
                currentVersion: latestVersion,
                isOutdated: true,
                outdatedProvenance: .plain,
                isPinned: false,
                isDisabled: false,
                isDeprecated: false,
                autoUpdates: false,
                requiresManualInstaller: false,
                appBundlePaths: [bundleURL.path]
            )
        }

        return InstalledApplication(
            id: id,
            displayName: name,
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL,
            executableURL: nil,
            installedVersion: ApplicationVersion(marketing: currentVersion),
            buildNumber: currentVersion,
            signingTeamIdentifier: isAutomatic ? "DEBUGTEAM1" : nil,
            codeSigningIdentifier: isAutomatic ? bundleIdentifier : nil,
            installationSource: installationSource,
            updateProvider: provider,
            architectures: ["arm64"],
            minimumSystemVersion: "14.0",
            isSystemApplication: false,
            isRunning: false,
            isOnExternalVolume: false,
            isReadOnly: false,
            lastScanDate: referenceDate,
            availableVersion: latest,
            releaseDate: latest == nil ? nil : referenceDate.addingTimeInterval(-86_400),
            releaseNotes: latest == nil ? nil : "界面演示数据，不代表真实发布说明。",
            downloadSize: downloadSize,
            appStoreProductURL: provider == .macAppStore
                ? URL(string: "https://apps.apple.com/")
                : nil,
            updateStatus: status,
            sourceResolutionState: status == .latestVersionUnknown ? .unresolved : .resolved,
            versionCheckState: latest == nil
                ? (status == .upToDate ? .upToDate : .unavailable)
                : .updateAvailable,
            updateCapability: capability,
            updateError: status == .latestVersionUnknown
                ? "界面演示数据：没有可验证的最新版本。"
                : nil,
            requiresUserInteraction: !isAutomatic,
            requiresApplicationQuit: false,
            requiresAdministratorAuthorization: false,
            canAutomaticallyUpdate: isAutomatic,
            sourceDisplayName: source,
            sourceEvidence: evidence,
            homebrewMetadata: metadata,
            caskToken: automaticCaskToken,
            reportedCurrentVersion: currentVersion,
            modifiedAt: referenceDate.addingTimeInterval(-86_400 * 7)
        )
    }
}
#endif
