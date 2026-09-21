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
        store: ScanStore,
        healthStore: ComputerHealthStore? = nil
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
        if ProcessInfo.processInfo.arguments.contains("--capture-feature-runtime-audit") {
            await captureFeatureRuntimeAudit(navigationState: navigationState,
                browserPrivacyStore: browserPrivacyStore, store: store,
                healthStore: healthStore, in: directory)
            if ProcessInfo.processInfo.arguments.contains("--capture-main-window-responsive") {
                await captureResponsiveWindows(navigationState: navigationState, in: directory)
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--capture-runtime-ui") {
            await captureLiveRuntime(navigationState: navigationState, store: store, in: directory)
            if ProcessInfo.processInfo.arguments.contains("--capture-main-window-responsive") {
                await captureResponsiveWindows(navigationState: navigationState, in: directory)
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--capture-main-window-responsive") {
            await captureResponsiveWindows(navigationState: navigationState, in: directory)
            return
        }
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

    /// Explicit audit flag only. Calls existing read-only feature entry points;
    /// never applies cleanup, installs updates, exits processes or writes hardware.
    private static func captureFeatureRuntimeAudit(
        navigationState: AppNavigationState, browserPrivacyStore: BrowserPrivacyStore,
        store: ScanStore, healthStore: ComputerHealthStore?, in directory: URL
    ) async {
        try? await Task.sleep(for: .seconds(3))
        guard let window = mainWindow() else { return }
        let originalFrame = window.frame
        let originalRoute = navigationState.route
        defer {
            window.setFrame(originalFrame, display: true)
            navigationState.select(originalRoute.filter)
        }
        window.setContentSize(goldenReferenceContentSize)
        var records: [[String: Any]] = []
        func audit(_ filter: ReviewFilter, start: () -> Void, busy: () -> Bool,
                   cancel: (() -> Void)? = nil, seconds: TimeInterval = 20) async {
            navigationState.select(filter)
            try? await Task.sleep(for: .milliseconds(200))
            start()
            var count = 0
            let deadline = Date().addingTimeInterval(seconds)
            repeat {
                try? await Task.sleep(for: .milliseconds(count == 0 ? 60 : 500))
                let active = busy()
                if count < 3 || !active {
                    let file = "live-\(filter.rawValue)-\(count)-\(active ? "active" : "settled").png"
                    capture(named: file, in: directory)
                    records.append(["file": file, "filter": filter.rawValue,
                        "active": active, "fixture": false, "capturedAt": ISO8601DateFormatter().string(from: Date())])
                }
                count += 1
                if !active { break }
            } while Date() < deadline
            if busy(), let cancel {
                cancel()
                for _ in 0..<20 where busy() { try? await Task.sleep(for: .milliseconds(250)) }
                let file = "live-\(filter.rawValue)-after-cancel-request.png"
                capture(named: file, in: directory)
                records.append(["file": file, "filter": filter.rawValue,
                    "active": busy(), "fixture": false, "cancelRequested": true])
            }
        }
        await audit(.memory, start: { store.refreshMemory() }, busy: { store.isLoadingMemory })
        await audit(.energy, start: { store.scanEnergyImpact() }, busy: { store.isEnergyImpactPageScanActive }, seconds: 60)
        await audit(.startup, start: { store.refreshStartupItems() }, busy: { store.isLoadingStartupItems }, cancel: { store.cancelStartupScan() })
        await audit(.uninstall, start: { store.refreshInstalledApps() }, busy: { store.isLoadingInstalledApps }, seconds: 45)
        if let healthStore {
            await audit(.healthHub, start: { Task { await healthStore.refresh(force: true) } }, busy: { healthStore.isRefreshing })
        }
        await audit(.largeFiles, start: { store.largeFilesWorkspace.startStorageAnalysis() },
            busy: { store.largeFilesWorkspace.isAnalyzingStorage }, cancel: { store.largeFilesWorkspace.cancelStorageAnalysis() })
        await audit(.duplicates, start: { store.scanDuplicateFiles() },
            busy: { store.duplicateFilesWorkspace.isScanning }, cancel: { store.cancelDuplicateFileScan() })
        // Stop after the active view is captured: browser history remains local
        // and no final browsing records are exported into the evidence folder.
        navigationState.select(.privacy)
        browserPrivacyStore.startScan()
        try? await Task.sleep(for: .milliseconds(40))
        if browserPrivacyStore.state == .scanning {
            capture(named: "live-privacy-active.png", in: directory)
        }
        browserPrivacyStore.cancel()
        await browserPrivacyStore.waitUntilIdle()
        await captureLiveRuntime(navigationState: navigationState, store: store, in: directory)
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("live-feature-audit.json"), options: .atomic)
        }
    }

    /// Explicit local audit only: run the normal read-only scan and capture
    /// published states. No fixtures, cleanup requests or hardware writes.
    private static func captureLiveRuntime(
        navigationState: AppNavigationState, store: ScanStore, in directory: URL
    ) async {
        try? await Task.sleep(for: .seconds(3))
        guard let window = mainWindow() else { return }
        let originalFrame = window.frame
        let originalMinimum = window.contentMinSize
        defer {
            window.contentMinSize = originalMinimum
            window.setFrame(originalFrame, display: true)
        }
        let originalRoute = navigationState.route
        defer { navigationState.select(originalRoute.filter) }
        var records: [[String: Any]] = []
        for module in [ReviewFilter.overview, .green, .devCaches] {
            window.setContentSize(goldenReferenceContentSize)
            navigationState.select(module)
            try? await Task.sleep(for: .milliseconds(300))
            capture(named: "\(module.rawValue)-before-scan.png", in: directory)
            store.startScan()
            var previousCheckpoint = ""
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                let state = String(describing: store.scanPresentationState)
                let fraction = store.mainScanProgress?.fractionCompleted ?? 0
                let checkpoint = "\(state)-\(Int(fraction * 10))"
                if checkpoint != previousCheckpoint {
                    let file = "\(module.rawValue)-\(checkpoint).png"
                    capture(named: file, in: directory)
                    records.append(["file": file, "filter": module.rawValue, "state": state,
                        "fraction": fraction, "fixture": false,
                        "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"])
                    previousCheckpoint = checkpoint
                }
                if !store.scanPresentationState.showsProgressPage { break }
            }
            if store.canCancelMainScan {
                store.cancelMainScan()
                for _ in 0..<40 where store.scanPresentationState.showsProgressPage {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            window.contentMinSize = NSSize(width: 300, height: 250)
            for size in [NSSize(width: 1280, height: 740), NSSize(width: 820, height: 520), NSSize(width: 677, height: 390)] {
                window.setContentSize(size)
                try? await Task.sleep(for: .milliseconds(600))
                let file = "\(module.rawValue)-result-\(Int(size.width))x\(Int(size.height)).png"
                capture(named: file, in: directory)
                records.append(["file": file, "filter": module.rawValue,
                    "state": String(describing: store.scanPresentationState),
                    "actualWidth": window.contentView?.bounds.width ?? 0,
                    "actualHeight": window.contentView?.bounds.height ?? 0, "fixture": false])
            }
            // Do not begin a second workflow if the previous cancellation is still pending.
            if store.scanPresentationState.showsProgressPage { break }
        }
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("runtime-captures.json"), options: .atomic)
        }
    }

    /// Exercise the installed layout with live state, including native tiling
    /// sizes that can be smaller than contentMinSize. Never install fixtures or
    /// start scans in this mode, and restore the original window and selection.
    private static func captureResponsiveWindows(
        navigationState: AppNavigationState,
        in directory: URL
    ) async {
        try? await Task.sleep(for: .seconds(3))
        guard let window = mainWindow() else { return }
        let originalFrame = window.frame
        let originalMinimum = window.contentMinSize
        let originalRoute = navigationState.route
        defer {
            window.contentMinSize = originalMinimum
            window.setFrame(originalFrame, display: true)
            navigationState.select(originalRoute.filter)
            navigationState.selectUtilityTool(originalRoute.utilityTool)
        }

        window.contentMinSize = NSSize(width: 300, height: 250)
        let sizes: [NSSize] = [
            goldenReferenceContentSize,
            NSSize(width: 820, height: 520),
            NSSize(width: 677, height: 390),
            NSSize(width: 1280, height: 390),
            NSSize(width: 677, height: 764)
        ]
        var records: [[String: Any]] = []
        for size in sizes {
            window.setContentSize(size)
            window.center()
            for filter in ReviewFilter.allCases where filter != .utilityHub {
                navigationState.select(filter)
                try? await Task.sleep(for: .milliseconds(800))
                let name = "\(Int(size.width))x\(Int(size.height))-\(filter.rawValue).png"
                capture(named: name, in: directory)
                records.append([
                    "file": name,
                    "requestedWidth": size.width,
                    "requestedHeight": size.height,
                    "actualWidth": window.contentView?.bounds.width ?? 0,
                    "actualHeight": window.contentView?.bounds.height ?? 0,
                    "fixture": false
                ])
            }
        }
        window.setContentSize(goldenReferenceContentSize)
        navigationState.select(.overview)
        try? await Task.sleep(for: .milliseconds(800))
        capture(named: "zz-restored-wide-overview.png", in: directory)
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("capture-sizes.json"), options: .atomic)
        }
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
        NSApp.windows.filter {
            $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled)
                && $0.contentView.map { $0.bounds.width >= 300 && $0.bounds.height >= 250 } == true
        }.max { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }
    }
}
#endif
