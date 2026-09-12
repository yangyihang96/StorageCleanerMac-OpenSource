#if DEBUG || STORAGE_CLEANER_BETA
import AppKit
import Foundation

/// Development-only pipeline that walks every main-window page and writes a
/// PNG of the rendered window, mirroring the mini-window snapshot pipeline.
/// Captures use `cacheDisplay` on the window's content view, so no screen
/// recording or UI-automation permission is required and only this app's
/// own window is ever read.
@MainActor
enum MainWindowSnapshotPipeline {
    static let launchArgumentPrefix = "--capture-main-window-directory="
    static let goldenReferenceContentSize = NSSize(
        width: 1_280,
        height: CGFloat(1_280) * 969 / 1_624
    )

    static func runIfRequested(
        navigationState: AppNavigationState,
        browserPrivacyStore: BrowserPrivacyStore,
        store: ScanStore
    ) async {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix(launchArgumentPrefix)
        }) else { return }
        let directory = URL(
            fileURLWithPath: String(argument.dropFirst(launchArgumentPrefix.count)),
            isDirectory: true
        )
        guard directory.path.hasPrefix("/") else { return }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        installStartupItemsFixture(in: store)

        // First layout of the freshly opened window.
        try? await Task.sleep(for: .seconds(3))
        if let window = mainWindow() {
            window.setContentSize(goldenReferenceContentSize)
            window.center()
            try? await Task.sleep(for: .milliseconds(250))
        }
        for (index, filter) in ReviewFilter.allCases.enumerated() {
            if filter == .privacy, BrowserPrivacyPreviewFixture.isRequested {
                browserPrivacyStore.startScan()
                await browserPrivacyStore.waitUntilIdle()
            }
            navigationState.select(filter)
            try? await Task.sleep(for: .milliseconds(1_600))
            capture(
                named: String(format: "%02d-%@.png", index, filter.rawValue),
                in: directory
            )
        }
        capture(named: "zz-final.png", in: directory)
    }

    static func installStartupItemsFixture(in store: ScanStore) {
        store.startupDomainItems = startupItemsFixture
        store.startupCoverage = startupCoverageFixture
        store.startupScanProgress = nil
        store.isLoadingStartupItems = false
        store.hasScannedStartupItems = true
    }

    static var startupItemsFixture: [StartupItemsDomain.Item] {
        [
            startupItem(
                id: "dropbox",
                name: "Dropbox",
                kind: .openAtLogin,
                enablement: .enabled,
                process: .running(pid: 1_001),
                management: .directlyManageable,
                capability: .init(
                    canEnableDirectly: true,
                    canDisableDirectly: true,
                    canStopCurrentSession: true,
                    canOpenSystemSettings: false,
                    canRevealInFinder: true,
                    canOpenParentApp: true,
                    canRemoveOrphan: false,
                    requiresAdministrator: false,
                    isReadOnly: false,
                    isManaged: false
                )
            ),
            startupItem(
                id: "creative-cloud",
                name: "Adobe Creative Cloud",
                kind: .appBackgroundTask,
                enablement: .disabled,
                process: .stopped,
                management: .directlyManageable,
                capability: .init(
                    canEnableDirectly: true,
                    canDisableDirectly: true,
                    canStopCurrentSession: false,
                    canOpenSystemSettings: false,
                    canRevealInFinder: true,
                    canOpenParentApp: true,
                    canRemoveOrphan: false,
                    requiresAdministrator: false,
                    isReadOnly: false,
                    isManaged: false
                )
            ),
            startupItem(
                id: "docker",
                name: "Docker Desktop",
                kind: .appBackgroundTask,
                enablement: .enabled,
                process: .waiting,
                management: .manageableInSystemSettings,
                capability: .init(
                    canEnableDirectly: false,
                    canDisableDirectly: false,
                    canStopCurrentSession: false,
                    canOpenSystemSettings: true,
                    canRevealInFinder: true,
                    canOpenParentApp: true,
                    canRemoveOrphan: false,
                    requiresAdministrator: false,
                    isReadOnly: true,
                    isManaged: false
                )
            ),
            startupItem(
                id: "corporate-security",
                name: L10n.text("企业安全代理", "Corporate Security Agent"),
                kind: .managedItem,
                enablement: .enabled,
                process: .running(pid: 1_004),
                management: .managedByOrganization,
                capability: .init(
                    canEnableDirectly: false,
                    canDisableDirectly: false,
                    canStopCurrentSession: false,
                    canOpenSystemSettings: true,
                    canRevealInFinder: false,
                    canOpenParentApp: false,
                    canRemoveOrphan: false,
                    requiresAdministrator: false,
                    isReadOnly: true,
                    isManaged: true
                )
            ),
            startupItem(
                id: "protected-helper",
                name: L10n.text("受保护的系统服务", "Protected System Service"),
                kind: .privilegedHelper,
                enablement: .enabled,
                process: .running(pid: 1_005),
                management: .systemProtected,
                capability: .readOnly
            ),
        ]
    }

    private static var startupCoverageFixture: StartupCoverageReport {
        var coverage = StartupCoverageReport.empty
        coverage.groupedItemCount = startupItemsFixture.count
        coverage.openAtLoginCount = 1
        coverage.runningCount = 3
        coverage.managedItemCount = 1
        coverage.managedItemCoverageAvailable = true
        coverage.directlyManageableCount = 2
        coverage.systemSettingsOnlyCount = 1
        return coverage
    }

    private static func startupItem(
        id: String,
        name: String,
        kind: StartupItemsDomain.ItemKind,
        enablement: StartupItemsDomain.EnablementState,
        process: StartupItemsDomain.ProcessState,
        management: StartupItemsDomain.ManagementState,
        capability: StartupItemsDomain.ActionCapability
    ) -> StartupItemsDomain.Item {
        let applicationURL = URL(fileURLWithPath: "/Applications/\(name).app")
        let state = StartupItemsDomain.State(
            registration: .registered,
            authorization: management == .managedByOrganization ? .managed : .approved,
            enablement: enablement,
            load: process == .stopped ? .notLoaded : .loaded,
            process: process,
            management: management
        )
        let attribution = StartupItemsDomain.Attribution(
            applicationBundleIdentifier: "com.example.\(id)",
            applicationURL: applicationURL,
            applicationName: name,
            developerName: "Fixture",
            teamIdentifier: "FIXTURE",
            designatedRequirement: nil,
            evidence: [.init(kind: .applicationPath, value: applicationURL.path, confidence: .verified)]
        )
        let candidate = StartupItemsDomain.Candidate(
            id: id,
            source: kind == .openAtLogin ? .openAtLogin : .serviceManagement,
            kind: kind,
            scope: management == .managedByOrganization ? .managed : .currentUser,
            name: name,
            label: "com.example.\(id)",
            plistURL: nil,
            executableURL: applicationURL.appendingPathComponent("Contents/MacOS/Fixture"),
            applicationURL: applicationURL,
            configuration: nil,
            state: state,
            attribution: attribution,
            actionCapability: capability,
            diagnosticEvidence: ["anonymous-screenshot-fixture"]
        )
        return StartupItemsDomain.Item(
            id: id,
            kind: kind,
            scope: candidate.scope,
            name: name,
            components: [candidate],
            state: state,
            attribution: attribution,
            actionCapability: capability,
            warnings: []
        )
    }

    private static func capture(named name: String, in directory: URL) {
        guard let window = mainWindow(), let view = window.contentView else { return }
        window.displayIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first(where: {
            $0.isVisible && $0.contentView.map { view in
                view.bounds.width >= 700 && view.bounds.height >= 400
            } == true
        })
    }
}
#endif
