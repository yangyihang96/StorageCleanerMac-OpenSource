#if DEBUG || STORAGE_CLEANER_BETA
import AppKit
import Foundation
import SwiftUI

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
        healthStore: ComputerHealthStore? = nil,
        openSettings: (@MainActor () -> Void)? = nil
    ) async {
        await WindowMotionDemo.runIfRequested(navigationState: navigationState, store: store)
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
#if DEBUG
        if LightfieldComponentGallery.isRequested {
            await captureLightfieldGallery(in: directory)
            return
        }
        if FeaturePresentationDemo.isEnabled {
            await captureFeatureTemplates(navigationState: navigationState, in: directory)
            return
        }
#endif
        if let fixture = fileAnalysisTrashFixture {
            await captureFileAnalysisTrash(fixture: fixture, navigationState: navigationState, store: store, in: directory)
            return
        }
        if let fixture = fixtureFolder(argumentPrefix: fileAnalysisProtectedArgumentPrefix) {
            await captureFileAnalysisProtectedScope(fixture: fixture, navigationState: navigationState,
                                                    store: store, in: directory)
            return
        }
        if let fixture = fixtureFolder(argumentPrefix: fileAnalysisFollowupsArgumentPrefix) {
            await captureFileAnalysisFollowups(fixture: fixture, navigationState: navigationState,
                                               store: store, in: directory)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--capture-settings-window"), let openSettings {
            await captureSettingsWindow(open: openSettings, in: directory)
            return
        }
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
            place(window, contentSize: goldenReferenceContentSize)
            try? await Task.sleep(for: .milliseconds(250))
        }
        for (index, filter) in ReviewFilter.allCases.enumerated() {
#if DEBUG
            if filter == .privacy, BrowserPrivacyPreviewFixture.isRequested {
                browserPrivacyStore.startScan()
                await browserPrivacyStore.waitUntilIdle()
            }
#endif
            navigationState.select(filter)
            if index == 0, let window = mainWindow() { activate(window) }
            try? await Task.sleep(for: .milliseconds(1_600))
            capture(
                named: String(format: "%02d-%@.png", index, filter.rawValue),
                in: directory
            )
        }
        capture(named: "zz-final.png", in: directory)
    }

#if DEBUG
    private static func captureLightfieldGallery(in directory: URL) async {
        try? await Task.sleep(for: .seconds(3))
        guard let window = mainWindow() else { return }
        let originalFrame = window.frame
        defer { window.setFrame(originalFrame, display: true) }
        place(window, contentSize: NSSize(width: 1280, height: 763))
        for component in LightfieldComponentGallery.components {
            LightfieldComponentGallerySession.shared.component = component
            try? await Task.sleep(for: .milliseconds(300))
            capture(named: "gallery-\(component).png", in: directory)
        }
    }

    /// 14 × start/run × the requested sizes, all from inert UI fixtures.
    /// Themes remain the existing launch options; no user preference is changed.
    private static func captureFeatureTemplates(navigationState: AppNavigationState, in directory: URL) async {
        try? await Task.sleep(for: .seconds(3))
        guard let window = mainWindow() else { return }
        let originalFrame = window.frame
        let originalMinimum = window.contentMinSize
        let originalMaximum = window.contentMaxSize
        let originalRoute = navigationState.route
        let originalPhase = FeaturePresentationDemo.shared.phase
        let originalMousePolicy = window.ignoresMouseEvents
        defer {
            FeaturePresentationDemo.shared.phase = originalPhase
            navigationState.select(originalRoute.filter)
            navigationState.selectUtilityTool(originalRoute.utilityTool)
            window.contentMinSize = originalMinimum
            window.contentMaxSize = originalMaximum
            window.ignoresMouseEvents = originalMousePolicy
            restoreContentViewSize(window)
            window.setFrame(originalFrame, display: true)
        }
        window.contentMinSize = NSSize(width: 300, height: 250)
        window.contentMaxSize = AppWindowLayoutPolicy.unboundedContentSize
        window.ignoresMouseEvents = true
        activate(window)
        let arguments = ProcessInfo.processInfo.arguments
        let sizes = requestedSizes(arguments: arguments) ?? [
            NSSize(width: 820, height: 560), NSSize(width: 1000, height: 700),
            NSSize(width: 1280, height: 763), NSSize(width: 1680, height: 1050), NSSize(width: 2400, height: 1350),
            NSSize(width: 677, height: 390), NSSize(width: 1280, height: 390)]
        let modules = FeaturePresentationDemo.modules.filter { module in
            if FeaturePresentationDemo.shared.phase == .result && !FeatureLightfield.owns(module) { return false }
            if let selected = FeaturePresentationDemo.launchConfiguration?.module { return selected == module }
            return requestedFilters(arguments: arguments).map { $0.contains(module.rawValue) } ?? true
        }
        let phases = arguments.contains("--capture-feature-templates")
            ? FeaturePresentationDemo.Phase.allCases : [FeaturePresentationDemo.shared.phase]
        var records: [[String: Any]] = []
        for size in sizes {
            for module in modules {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                _ = withTransaction(transaction) { navigationState.select(module) }
                for phase in phases where phase != .result || FeatureLightfield.owns(module) {
                    withTransaction(transaction) { FeaturePresentationDemo.shared.phase = phase }
                    place(window, contentSize: size)
                    try? await Task.sleep(for: .milliseconds(captureSettleMilliseconds))
                    var attempts = 0
                    while !contentView(of: window, matches: size), attempts < 3 {
                        attempts += 1
                        place(window, contentSize: size)
                        try? await Task.sleep(for: .milliseconds(captureSettleMilliseconds))
                    }
                    let settled = await waitForSettledFeature(module,
                        expectedPhase: FeatureLightfieldPhase(rawValue: phase.rawValue) ?? .landing)
                    let name = "\(Int(size.width))x\(Int(size.height))-\(module.rawValue)-\(phase.rawValue)\(settled ? "" : "-unsettled").png"
                    capture(named: name, in: directory)
                    records.append(["file": name, "module": module.rawValue, "phase": phase.rawValue,
                        "requestedWidth": size.width, "requestedHeight": size.height,
                        "actualWidth": window.contentView?.bounds.width ?? 0,
                        "actualHeight": window.contentView?.bounds.height ?? 0, "fixture": true,
                        "productionRunningView": true, "layoutAnimations": false,
                        "settled": settled, "settleEvidence": FeatureLightfieldResultAudit.capture,
                        "renderedGeometry": FeatureVisualProbeStore.capture,
                        "duplicateFilter": FeaturePresentationDemo.duplicateFilter(arguments: arguments).rawValue,
                        "benchmarkV11Variant": PerformanceBenchmarkV11DemoPage.argument("variant", fallback: "standard"),
                        "benchmarkV11Section": PerformanceBenchmarkV11DemoPage.argument("section", fallback: "0"),
                        "benchmarkV11Stage": PerformanceBenchmarkV11DemoPage.argument("stage", fallback: "core"),
                        "analysisView": FeaturePresentationDemo.analysisView(arguments: arguments)])

                }
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("capture-feature-templates.json"), options: .atomic)
        }
    }
#endif

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
                    let settled = active ? false : await waitForSettledFeature(filter, busy: busy)
                    let suffix = active ? "active" : settled ? "settled" : "unsettled"
                    let file = "live-\(filter.rawValue)-\(count)-\(suffix).png"
                    capture(named: file, in: directory)
                    records.append(["file": file, "filter": filter.rawValue,
                        "active": busy(), "fixture": false, "settled": settled,
                        "settleEvidence": settleEvidence,
                        "capturedAt": ISO8601DateFormatter().string(from: Date())])
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

    /// Wait beyond the longest bounded entrance, then require a single state
    /// and stable observed geometry for multiple run-loop turns. Timeouts are
    /// explicitly named `unsettled`, never promoted to acceptance evidence.
    static func waitForSettledFeature(_ module: ReviewFilter, expectedPhase: FeatureLightfieldPhase = .result,
                                      busy: () -> Bool = { false }, timeout: TimeInterval = 5) async -> Bool {
#if DEBUG
        guard FeatureLightfield.owns(module) else { return false }
        if let art = GeneratedArt.module(for: module) {
            _ = await GeneratedArtLibrary.shared.image(named: art.resourceName(expectedPhase == .result ? .header : .landing))
        }
        var gate = FeatureLightfieldSettleGate()
        let start = Date()
        let minimum = max(FeatureLightfieldSettleGate.animationBudget, Double(captureSettleMilliseconds) / 1000)
        while Date().timeIntervalSince(start) < timeout && !Task.isCancelled {
            mainWindow()?.contentView?.layoutSubtreeIfNeeded()
            mainWindow()?.displayIfNeeded()
            let frames = FeatureLightfieldResultAudit.frames
            let canvasOrigin = frames["lightfield.canvas"]?.origin ?? .zero
            let correctResultGeometry = expectedPhase != .result || !FeatureLightfield.usesResultSpace(module)
                || (abs((frames["lightfield.content"]?.minY ?? -1) - canvasOrigin.y - FeatureLightfield.resultHeaderHeight) < 0.5
                    && (frames["lightfield.artwork"]?.height ?? .infinity) <= 48
                    && frames["lightfield.status"]?.contains(frames["lightfield.primary"] ?? .null) == true)
            if gate.observe(elapsed: Date().timeIntervalSince(start), busy: busy(),
                matchesPage: FeatureLightfieldResultAudit.module == module && FeatureLightfieldResultAudit.phase == expectedPhase
                    && correctResultGeometry,
                layers: FeatureLightfieldResultAudit.layers, expectedPhase: expectedPhase,
                frames: frames, minimumDelay: minimum) { return true }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return false
#else
        // Beta builds compile no Lightfield render probes, so settling cannot
        // be verified: wait the bounded entrance and report it as unsettled.
        try? await Task.sleep(for: .milliseconds(captureSettleMilliseconds))
        return false
#endif
    }

    private static var settleEvidence: [String: Any] {
#if DEBUG
        FeatureLightfieldResultAudit.capture
#else
        ["verified": false, "reason": "Beta builds compile no Lightfield render probes."]
#endif
    }

    private static func observesResultPhase(of module: ReviewFilter) -> Bool {
#if DEBUG
        FeatureLightfieldResultAudit.module == module && FeatureLightfieldResultAudit.phase == .result
#else
        false
#endif
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
                let settled = await waitForSettledFeature(module, busy: { store.scanPresentationState.showsProgressPage })
                let file = "\(module.rawValue)-result-\(Int(size.width))x\(Int(size.height))\(settled ? "" : "-unsettled").png"
                capture(named: file, in: directory)
                records.append(["file": file, "filter": module.rawValue,
                    "state": String(describing: store.scanPresentationState),
                    "actualWidth": window.contentView?.bounds.width ?? 0,
                    "actualHeight": window.contentView?.bounds.height ?? 0, "fixture": false,
                    "settled": settled, "settleEvidence": settleEvidence])
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
        // D53 review: 1680×1050 and 2400×1350 exceed the screen's visible
        // area; lift the maximum for this capture session only.
        let originalMaximum = window.contentMaxSize
        window.contentMaxSize = AppWindowLayoutPolicy.unboundedContentSize
        defer {
            window.contentMaxSize = originalMaximum
            restoreContentViewSize(window)
        }
        // Activate once for the whole session; the captures themselves never
        // take focus again (the custom styles do not depend on it).
        activate(window)
        // The pointer of whoever is using the Mac may rest over the window;
        // keep hover highlights out of the screenshots.
        window.ignoresMouseEvents = true
        defer { window.ignoresMouseEvents = false }
        let arguments = ProcessInfo.processInfo.arguments
        let sizes = requestedSizes(arguments: arguments) ?? [
            goldenReferenceContentSize,
            NSSize(width: 820, height: 520),
            // Middle widths, where landing pages drop the illustration before
            // they would narrow the action column (BOARD 3b).
            NSSize(width: 1000, height: 700),
            NSSize(width: 900, height: 640),
            NSSize(width: 677, height: 390),
            NSSize(width: 1280, height: 390),
            NSSize(width: 677, height: 764)
        ]
        let filters = requestedFilters(arguments: arguments)
        var records: [[String: Any]] = []
        for size in sizes {
            place(window, contentSize: size)
            for filter in ReviewFilter.allCases where filter != .utilityHub
                && filters.map({ $0.contains(filter.rawValue) }) != false {
                navigationState.select(filter)
                try? await Task.sleep(for: .milliseconds(captureSettleMilliseconds))
                // A size taller than the screen lives only in the content
                // view; AppKit can lay that view back out to the window's
                // screen-limited size while a page settles (seen as 1304×713
                // shots of 1680×1050). Put the size back and settle again.
                var attempts = 0
                while !contentView(of: window, matches: size), attempts < 3 {
                    attempts += 1
                    place(window, contentSize: size)
                    try? await Task.sleep(for: .milliseconds(captureSettleMilliseconds))
                }
                let isResult = FeatureLightfield.owns(filter) && observesResultPhase(of: filter)
                let settled = isResult ? await waitForSettledFeature(filter) : false
                let name = "\(Int(size.width))x\(Int(size.height))-\(filter.rawValue)\(isResult && !settled ? "-unsettled" : "").png"
                capture(named: name, in: directory)
                records.append([
                    "file": name,
                    "resultSettleRequested": isResult, "settled": settled,
                    "settleEvidence": settleEvidence,
                    "requestedWidth": size.width,
                    "requestedHeight": size.height,
                    "actualWidth": window.contentView?.bounds.width ?? 0,
                    "actualHeight": window.contentView?.bounds.height ?? 0,
                    "isKeyWindow": window.isKeyWindow,
                    "appIsActive": NSApp.isActive,
                    "fixture": false
                ])
            }
        }
        place(window, contentSize: goldenReferenceContentSize)
        navigationState.select(.overview)
        try? await Task.sleep(for: .milliseconds(800))
        capture(named: "zz-restored-wide-overview.png", in: directory)
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("capture-sizes.json"), options: .atomic)
        }
    }

    /// The window gets exactly the requested content size and stays on its
    /// current screen (D53 review: never move it to another display). A size
    /// larger than the visible area keeps its top-left corner on screen and
    /// extends past the edge; `cacheDisplay` still renders the whole window.
    static func place(_ window: NSWindow, contentSize: NSSize) {
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        guard let screen = window.screen ?? NSScreen.main else {
            window.setContentSize(contentSize)
            return
        }
        let visible = screen.visibleFrame
        let x = frame.width <= visible.width
            ? (visible.midX - frame.width / 2).rounded()
            : visible.minX
        let y = frame.height <= visible.height
            ? (visible.midY - frame.height / 2).rounded()
            : visible.maxY - frame.height
        window.setFrame(NSRect(x: x, y: y, width: frame.width, height: frame.height), display: true)
        // AppKit keeps a titled window within its screen's height. For sizes
        // taller than the screen (1680×1050, 2400×1350 on a 878 pt display)
        // lay the content view out at the requested size instead; the
        // window itself stays where it is and `cacheDisplay` renders the
        // whole view. The next `place` or the session end restores it.
        guard let content = window.contentView else { return }
        if abs(content.bounds.width - contentSize.width) > 0.5
            || abs(content.bounds.height - contentSize.height) > 0.5 {
            content.setFrameSize(contentSize)
            content.layoutSubtreeIfNeeded()
        }
    }

    static func contentView(of window: NSWindow, matches size: NSSize) -> Bool {
        guard let bounds = window.contentView?.bounds else { return false }
        return abs(bounds.width - size.width) <= 0.5 && abs(bounds.height - size.height) <= 0.5
    }

    /// Returns the content view to the window's own size.
    static func restoreContentViewSize(_ window: NSWindow) {
        guard let content = window.contentView else { return }
        let size = window.contentRect(forFrameRect: window.frame).size
        if abs(content.bounds.width - size.width) > 0.5 || abs(content.bounds.height - size.height) > 0.5 {
            content.setFrameSize(size)
        }
    }

    /// Called once per capture session (D53 review: the pipeline used to
    /// re-activate the app before every shot and steal focus repeatedly).
    private static func activate(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Waits long enough for the page transition and entrance animations.
    static var captureSettleMilliseconds: Int {
        let prefix = "--capture-settle-ms="
        let value = ProcessInfo.processInfo.arguments.last(where: { $0.hasPrefix(prefix) })
            .flatMap { Int($0.dropFirst(prefix.count)) }
        return min(5_000, max(300, value ?? 1_400))
    }

    /// `--capture-main-window-sizes=1280x763.74,900x640` limits the responsive
    /// captures to these content sizes.
    static func requestedSizes(arguments: [String]) -> [NSSize]? {
        let prefix = "--capture-main-window-sizes="
        guard let value = arguments.last(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count) else {
            return nil
        }
        let sizes = value.split(separator: ",").compactMap { item -> NSSize? in
            let parts = item.split(separator: "x")
            guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
                  width.isFinite, height.isFinite, width >= 300, height >= 250 else { return nil }
            return NSSize(width: width, height: height)
        }
        return sizes.isEmpty ? nil : sizes
    }

    /// `--capture-main-window-filters=performance,overview` limits the
    /// responsive captures to these pages.
    static func requestedFilters(arguments: [String]) -> Set<String>? {
        let prefix = "--capture-main-window-filters="
        guard let value = arguments.last(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count) else {
            return nil
        }
        let filters = Set(value.split(separator: ",").map(String.init))
        return filters.isEmpty ? nil : filters
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

    // MARK: - D45 evidence for D46 (File Analysis moves to the Trash)

    static let fileAnalysisTrashArgumentPrefix = "--capture-file-analysis-trash="

    /// A fixture folder the capture script made: hidden, directly in the
    /// home folder, named `.storage-cleaner-…`. Never real data.
    static var fileAnalysisTrashFixture: URL? {
        fixtureFolder(argumentPrefix: fileAnalysisTrashArgumentPrefix)
    }

    /// Review fixes for D46 (D54 and P2): the protected scope and the new
    /// states, on a fixture folder that stands in for a home folder.
    static let fileAnalysisProtectedArgumentPrefix = "--capture-file-analysis-protected="

    /// The fixture folder named by `argumentPrefix`: hidden, directly in the
    /// home folder, named `.storage-cleaner-…`. Never real data.
    static func fixtureFolder(argumentPrefix: String) -> URL? {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix(argumentPrefix)
        }) else { return nil }
        let url = URL(fileURLWithPath: String(argument.dropFirst(argumentPrefix.count)),
                      isDirectory: true).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard url.deletingLastPathComponent().path == home.path,
              url.lastPathComponent.hasPrefix(".storage-cleaner-") else { return nil }
        return url
    }

    /// Analyzes the fixture folder and captures the File Analysis page: the
    /// checkboxes and the reasons rows give, checked items with the bar (and
    /// the note a blocked click leaves), the columns, a level inside a
    /// checked folder, and the review sheet. Nothing moves: the review is
    /// cancelled. The display mode is put back afterwards.
    private static func captureFileAnalysisTrash(
        fixture: URL, navigationState: AppNavigationState, store: ScanStore, in directory: URL
    ) async {
        try? await Task.sleep(for: .seconds(3))
        guard let window = mainWindow() else { return }
        window.setContentSize(goldenReferenceContentSize)
        window.center()
        let modeKey = "storage-analysis.display-mode"
        let originalMode = UserDefaults.standard.string(forKey: modeKey)
        defer {
            if let originalMode { UserDefaults.standard.set(originalMode, forKey: modeKey) }
            else { UserDefaults.standard.removeObject(forKey: modeKey) }
        }
        UserDefaults.standard.set(StorageAnalysisDisplayMode.visualMap.rawValue, forKey: modeKey)
        let target = StorageMapScanTarget(path: fixture.path, title: L10n.text("夹具文件夹", "Fixture Folder"),
                                          kind: .homeDirectory)
        guard let result = try? await Task.detached(priority: .userInitiated, operation: {
            try DiskScanner(excludedPaths: []).storageMapAnalysis(target: target)
        }).value else { return }
        let workspace = store.largeFilesWorkspace
        workspace.replaceStorageAnalysisForTesting(result)
        navigationState.select(.largeFiles)
        try? await Task.sleep(for: .milliseconds(1_500))
        capture(named: "fa-1-checkboxes.png", in: directory)

        let entries = result.rootSnapshot.entries
        for name in ["Old Projects", "Installers.dmg", "Archive 2023.zip", "Tool.app"] {
            if let entry = entries.first(where: { $0.title == name }) { workspace.toggleTrashSelection(entry) }
        }
        try? await Task.sleep(for: .milliseconds(1_200))
        capture(named: "fa-2-selected-bar.png", in: directory)

        UserDefaults.standard.set(StorageAnalysisDisplayMode.columnBrowser.rawValue, forKey: modeKey)
        try? await Task.sleep(for: .milliseconds(1_200))
        capture(named: "fa-3-columns.png", in: directory)
        UserDefaults.standard.set(StorageAnalysisDisplayMode.visualMap.rawValue, forKey: modeKey)

        if let folder = entries.first(where: { $0.title == "Old Projects" }) {
            workspace.openStorageMapDirectory(folder)
            for _ in 0..<50 where workspace.storageMapNavigation.count < 2 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(1_000))
            capture(named: "fa-4-inside-checked-folder.png", in: directory)
            workspace.showStorageMapRoot()
        }

        // One checked file changes before the review, so the review shows
        // an item it will not move, and why (fixture file only).
        if let handle = try? FileHandle(forWritingTo: fixture.appendingPathComponent("Archive 2023.zip")) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data([0x2A]))
            try? handle.close()
        }
        workspace.requestTrashReview()
        for _ in 0..<100 where workspace.trashPhase != .reviewing {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(1_200))
        if let sheet = window.attachedSheet {
            capture(window: sheet, named: "fa-5-review-sheet.png", in: directory)
        }
        capture(named: "fa-5-review-main.png", in: directory)
        workspace.cancelTrashReview()
        try? await Task.sleep(for: .milliseconds(800))

        let originalMinimum = window.contentMinSize
        window.contentMinSize = NSSize(width: 300, height: 250)
        window.setContentSize(NSSize(width: 820, height: 560))
        try? await Task.sleep(for: .milliseconds(1_200))
        capture(named: "fa-6-narrow-selected.png", in: directory)
        window.contentMinSize = originalMinimum
        window.setContentSize(goldenReferenceContentSize)
        workspace.clearTrashSelection()
    }

    /// The fixture's `Home` stands in for a home folder (with its own
    /// Library, `.ssh`, `.config`, Desktop and Documents); its `Receipts` and
    /// `Trash` are the receipt journal and the "Trash". Captures: the reasons
    /// at the top, in the Library and in Containers (D54), Desktop while
    /// iCloud is being checked (P2-12), a level inside a checked folder at
    /// 1280 points (P2-11), the review with a hard-linked file (D54 ④), a
    /// move that could not start and the bar after cancelling (P2-10), and a
    /// receipt that fails midway (P2-2). The only move is of two fixture
    /// files into the fixture "Trash". Nothing is written to preferences:
    /// the display mode comes in as a launch argument.
    private static func captureFileAnalysisProtectedScope(
        fixture: URL, navigationState: AppNavigationState, store: ScanStore, in directory: URL
    ) async {
        try? await Task.sleep(for: .seconds(3))
        guard let window = mainWindow() else { return }
        window.setContentSize(goldenReferenceContentSize)
        window.center()
        let home = fixture.appendingPathComponent("Home", isDirectory: true)
        let receipts = fixture.appendingPathComponent("Receipts", isDirectory: true)
        let trash = fixture.appendingPathComponent("Trash", isDirectory: true)
        let gate = CaptureRefinementGate()
        let receiptBreaker = CaptureReceiptBreaker(directory: receipts)
        defer {
            gate.open()
            receiptBreaker.repair()
        }
        try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let documents = home.appendingPathComponent("Documents").path
        var environment = FileAnalysisTrashEnvironment(
            journal: CleanupReportJournal(directory: receipts),
            moveToTrash: { source in
                // The fixture "Trash" only, and only from the fixture home.
                guard source.standardizedFileURL.path.hasPrefix(home.path + "/") else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                let target = trash.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: target)
                receiptBreaker.breakAfterFirstMove()
                return target
            },
            metadata: FoundationReadOnlyFileSystem(),
            homePath: home.path,
            appDataPath: fixture.appendingPathComponent("AppData").path,
            excludedPaths: { [] },
            isCloudFolder: { url in
                gate.wait()
                return url.path == documents
            },
            isReadOnlyVolume: { _ in false },
            userTrashPath: trash.path
        )
        environment.runningApplicationPaths = { [home.appendingPathComponent("Build/Products/Debug/Demo.app").path] }
        environment.mountPointPaths = { [home.appendingPathComponent("Mounts/Disk").path] }
        let workspace = store.largeFilesWorkspace
        workspace.useTrashEnvironmentForCapture(environment)

        let target = StorageMapScanTarget(path: home.path, title: L10n.text("夹具个人目录", "Fixture Home"),
                                          kind: .homeDirectory)
        guard let result = try? await Task.detached(priority: .userInitiated, operation: {
            try DiskScanner(excludedPaths: []).storageMapAnalysis(target: target)
        }).value else { return }
        workspace.replaceStorageAnalysisForTesting(result)
        navigationState.select(.largeFiles)
        try? await Task.sleep(for: .milliseconds(1_500))
        capture(named: "fb-1-home-reasons.png", in: directory)

        func open(_ name: String) async {
            guard let entry = workspace.currentStorageMapSnapshot?.entries.first(where: { $0.title == name }) else { return }
            let depth = workspace.storageMapNavigation.count
            workspace.openStorageMapDirectory(entry)
            for _ in 0..<50 where workspace.storageMapNavigation.count <= depth {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(1_000))
        }
        func check(_ name: String) {
            if let entry = workspace.currentStorageMapSnapshot?.entries.first(where: { $0.title == name }) {
                workspace.toggleTrashSelection(entry)
            }
        }

        // While iCloud is still being checked.
        await open("Desktop")
        capture(named: "fb-2-desktop-checking.png", in: directory)
        workspace.showStorageMapRoot()
        gate.open()
        for _ in 0..<50 where workspace.trashPolicy?.isRefined != true {
            try? await Task.sleep(for: .milliseconds(100))
        }

        await open("Library")
        capture(named: "fb-3-library-reasons.png", in: directory)
        await open("Containers")
        capture(named: "fb-4-containers-reasons.png", in: directory)
        workspace.showStorageMapRoot()
        try? await Task.sleep(for: .milliseconds(800))

        check("Old Projects")
        await open("Old Projects")
        capture(named: "fb-5-inside-checked-folder.png", in: directory)
        workspace.clearTrashSelection()
        workspace.showStorageMapRoot()
        try? await Task.sleep(for: .milliseconds(800))

        await open("Media")
        check("photo.jpg")
        check("clip.mov")
        workspace.requestTrashReview()
        for _ in 0..<100 where workspace.trashPhase != .reviewing {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(1_200))
        if let sheet = window.attachedSheet {
            capture(window: sheet, named: "fb-6-review-hard-link.png", in: directory)
        }
        workspace.showTrashMoveFailureForCapture(HeavyWorkCoordinator.Error.invalidLease(expectedOwner: .cleanup))
        try? await Task.sleep(for: .milliseconds(1_000))
        if let sheet = window.attachedSheet {
            capture(window: sheet, named: "fb-7-move-did-not-start.png", in: directory)
        }
        workspace.cancelTrashReview()
        try? await Task.sleep(for: .milliseconds(1_000))
        capture(named: "fb-8-after-cancel.png", in: directory)

        // The receipt stops being writable after the first move.
        workspace.requestTrashReview()
        for _ in 0..<100 where workspace.trashPhase != .reviewing {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(800))
        workspace.confirmTrash()
        for _ in 0..<100 where workspace.trashOutcome == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(1_200))
        capture(named: "fb-9-receipt-incomplete.png", in: directory)
        receiptBreaker.repair()
        workspace.dismissTrashOutcome()
    }

    /// r2-fa-followups evidence, the same steps before and after the batch.
    static let fileAnalysisFollowupsArgumentPrefix = "--capture-file-analysis-followups="

    /// The fixture's `Home` stands in for a home folder and `Volume` for an
    /// external volume. Captures: folders named like apps (P2-1); iCloud and
    /// an external volume not answered within the 10 s budget, also in a
    /// narrow window (P2-3); a translocated app whose original place is
    /// unknown, after a click on a folder (P2-2, P2-3); an app still running
    /// after its bundle was deleted (P2-2); and, on builds that have it, the
    /// rows waiting while the links are found (P1-1). The "Trash" refuses
    /// every move, so nothing moves; preferences are untouched.
    private static func captureFileAnalysisFollowups(
        fixture: URL, navigationState: AppNavigationState, store: ScanStore, in directory: URL
    ) async {
        try? await Task.sleep(for: .seconds(3))
        guard let window = mainWindow() else { return }
        window.setContentSize(goldenReferenceContentSize)
        window.center()
        let home = fixture.appendingPathComponent("Home", isDirectory: true)
        let workspace = store.largeFilesWorkspace
        let held = CaptureRefinementGate()
        defer { held.open() }
        navigationState.select(.largeFiles)

        func environment(
            isCloudFolder: @escaping @Sendable (URL) -> Bool = { _ in false },
            isReadOnlyVolume: @escaping @Sendable (URL) -> Bool = { _ in false },
            running: [String] = [],
            original: @escaping @Sendable (URL) -> URL? = { $0 }
        ) -> FileAnalysisTrashEnvironment {
            var environment = FileAnalysisTrashEnvironment(
                journal: CleanupReportJournal(directory: fixture.appendingPathComponent("Receipts", isDirectory: true)),
                moveToTrash: { _ in throw CocoaError(.fileWriteNoPermission) },
                metadata: FoundationReadOnlyFileSystem(),
                homePath: home.path,
                appDataPath: fixture.appendingPathComponent("AppData").path,
                excludedPaths: { [] },
                isCloudFolder: isCloudFolder,
                isReadOnlyVolume: isReadOnlyVolume,
                userTrashPath: fixture.appendingPathComponent("Trash").path
            )
            environment.runningApplicationPaths = { running }
            environment.originalRunningApplicationURL = original
            return environment
        }
        func analyze(_ root: URL, title: String, kind: StorageMapScanTarget.Kind,
                     with environment: FileAnalysisTrashEnvironment) async -> Bool {
            workspace.useTrashEnvironmentForCapture(environment)
            let target = StorageMapScanTarget(path: root.path, title: title, kind: kind)
            guard let result = try? await Task.detached(priority: .userInitiated, operation: {
                try DiskScanner(excludedPaths: []).storageMapAnalysis(target: target)
            }).value else { return false }
            workspace.replaceStorageAnalysisForTesting(result)
            try? await Task.sleep(for: .milliseconds(1_500))
            return true
        }
        func open(_ name: String) async {
            guard let entry = workspace.currentStorageMapSnapshot?.entries.first(where: { $0.title == name }) else { return }
            let depth = workspace.storageMapNavigation.count
            workspace.openStorageMapDirectory(entry)
            for _ in 0..<50 where workspace.storageMapNavigation.count <= depth {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(1_000))
        }
        func click(_ name: String) async {
            if let entry = workspace.currentStorageMapSnapshot?.entries.first(where: { $0.title == name }) {
                workspace.toggleTrashSelection(entry)
            }
            try? await Task.sleep(for: .milliseconds(800))
        }
        func narrow(_ name: String) async {
            let minimum = window.contentMinSize
            window.contentMinSize = NSSize(width: 300, height: 250)
            window.setContentSize(NSSize(width: 820, height: 560))
            try? await Task.sleep(for: .milliseconds(1_200))
            capture(named: name, in: directory)
            window.contentMinSize = minimum
            window.setContentSize(goldenReferenceContentSize)
            try? await Task.sleep(for: .milliseconds(800))
        }
        let homeTitle = L10n.text("夹具个人目录", "Fixture Home")

        // P1-1 (after only): while the links are found off the main thread,
        // the rows wait.
        var linked = environment()
        let links = CaptureRefinementGate()
        defer { links.open() }
        linked.protectedLinkTargets = { homePath, appDataPath in
            links.wait()
            return FileAnalysisProtectedLinkResolver.locations(homePath: homePath, appDataPath: appDataPath)
        }
        guard await analyze(home, title: homeTitle, kind: .homeDirectory, with: linked) else { return }
        await click("Old Projects")
        capture(named: "fc-0-links-checking.png", in: directory)
        links.open()
        workspace.dismissTrashOutcome()
        // End of the after-only step.

        // P2-1: folders named like apps.
        guard await analyze(home, title: homeTitle, kind: .homeDirectory, with: environment()) else { return }
        await open("Library")
        await open("HTTPStorages")
        capture(named: "fc-1-library-httpstorages.png", in: directory)
        workspace.showStorageMapRoot()
        await open("Downloads")
        capture(named: "fc-2-downloads-bundles.png", in: directory)
        workspace.showStorageMapRoot()

        // P2-3: iCloud not answered within the budget.
        _ = await analyze(home, title: homeTitle, kind: .homeDirectory, with: environment(isCloudFolder: { _ in
            held.wait()
            return false
        }))
        try? await Task.sleep(for: .seconds(11))
        await open("Desktop")
        capture(named: "fc-3-icloud-timeout.png", in: directory)
        await narrow("fc-3n-icloud-timeout-narrow.png")
        workspace.showStorageMapRoot()

        // P2-2, P2-3: a translocated app whose original place is unknown.
        let translocated = "/private/var/folders/zz/fixture/T/AppTranslocation/0F1E2D3C/d/Demo.app"
        _ = await analyze(home, title: homeTitle, kind: .homeDirectory,
                          with: environment(running: [translocated], original: { _ in nil }))
        await click("Old Projects")
        capture(named: "fc-4-running-app-unknown.png", in: directory)
        await narrow("fc-4n-running-app-unknown-narrow.png")
        workspace.dismissTrashOutcome()

        // P2-2: an app still running after its bundle was deleted.
        let gone = home.appendingPathComponent("Build/Gone.app").path
        _ = await analyze(home, title: homeTitle, kind: .homeDirectory, with: environment(running: [gone], original: {
            FileAnalysisRunningApplicationResolver.originalURL(for: $0)
        }))
        capture(named: "fc-5-gone-bundle.png", in: directory)

        // P2-3: an external volume's read-only state, then its timeout.
        let volume = fixture.appendingPathComponent("Volume", isDirectory: true)
        _ = await analyze(volume, title: L10n.text("夹具外接卷", "Fixture Volume"), kind: .externalVolume,
                          with: environment(isReadOnlyVolume: { _ in
                              held.wait()
                              return false
                          }))
        await click("Movies")
        capture(named: "fc-6-volume-checking.png", in: directory)
        workspace.dismissTrashOutcome()
        try? await Task.sleep(for: .seconds(11))
        capture(named: "fc-7-volume-timeout.png", in: directory)
        await narrow("fc-7n-volume-timeout-narrow.png")
    }

    /// Opens Settings and captures every category, read-only: the category is
    /// switched through its stored selection, nothing is applied or changed.
    private static func captureSettingsWindow(open: @MainActor () -> Void, in directory: URL) async {
        try? await Task.sleep(for: .seconds(2))
        // Without the main window there is nothing to tell Settings apart from.
        guard let main = mainWindow() else { return }
        let key = "settings.selected-category.v1"
        let original = UserDefaults.standard.string(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        open()
        try? await Task.sleep(for: .milliseconds(1_500))
        for (index, category) in SettingsCaptureCategories.all.enumerated() {
            UserDefaults.standard.set(category, forKey: key)
            try? await Task.sleep(for: .milliseconds(800))
            guard let window = NSApp.windows.first(where: {
                $0.isVisible && $0 !== main && !($0 is NSPanel) && $0.styleMask.contains(.titled)
            }) else { return }
            capture(window: window, named: String(format: "settings-%02d-%@.png", index, category), in: directory)
        }
    }

    private static func capture(named name: String, in directory: URL) {
        guard let window = mainWindow() else { return }
        capture(window: window, named: name, in: directory)
    }

    private static func capture(window: NSWindow, named name: String, in directory: URL) {
        guard let view = window.contentView else { return }
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

    static func mainWindow() -> NSWindow? {
        NSApp.windows.filter {
            $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled)
                && $0.contentView.map { $0.bounds.width >= 300 && $0.bounds.height >= 250 } == true
        }.max { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }
    }
}

/// Debug-only scripted window motion for screen recordings (D53 V0). Never
/// starts scans, cleanup or hardware writes; it only resizes this app's own
/// window and switches pages, then leaves the window where it ended.
///
/// - `--debug-window-content-size=WxH` sets the starting content size;
/// - `--debug-window-resize-demo` steps the width from the start down to
///   820 pt with `setFrame(_:display:animate:)`;
/// - `--debug-sidebar-tour=a,b,c` selects these pages one after another;
/// - `--debug-window-frame-file=/abs/path.json` fits the start size to the
///   window's screen, writes the window rectangle for `screencapture -R`
///   and waits 2.5 s before the scripted motion starts;
/// - with `--debug-mini-window-demo-data` only (fixture processes, every quit
///   request stays disabled): `--debug-memory-quittable` opens the memory
///   page on its quittable-apps list, `--debug-memory-select-suggested`
///   drafts the suggested selection, and `--debug-memory-demo` refreshes the
///   fixture, switches lists, drafts and clears the selection.
@MainActor
enum WindowMotionDemo {
    static func runIfRequested(navigationState: AppNavigationState, store: ScanStore) async {
        let arguments = ProcessInfo.processInfo.arguments
        let sizePrefix = "--debug-window-content-size="
        let tourPrefix = "--debug-sidebar-tour="
        let wantsResize = arguments.contains("--debug-window-resize-demo")
        let wantsMemoryDemo = arguments.contains("--debug-memory-demo") && MiniWindowDemoData.isEnabled
        prepareMemoryFixture(store: store, arguments: arguments)
        let tour = arguments.last(where: { $0.hasPrefix(tourPrefix) })
            .map { $0.dropFirst(tourPrefix.count).split(separator: ",").compactMap { ReviewFilter(rawValue: String($0)) } }
        let startSize = arguments.last(where: { $0.hasPrefix(sizePrefix) })
            .flatMap { MainWindowSnapshotPipeline.requestedSizes(arguments: ["--capture-main-window-sizes=" + $0.dropFirst(sizePrefix.count)])?.first }
        let frameFile = arguments.last(where: { $0.hasPrefix(frameFilePrefix) })
            .map { String($0.dropFirst(frameFilePrefix.count)) }
        guard wantsResize || wantsMemoryDemo || tour != nil || startSize != nil || frameFile != nil else { return }
        // The main window can take a few seconds to appear on a cold start.
        var found: NSWindow?
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(200))
            if let window = MainWindowSnapshotPipeline.mainWindow() { found = window; break }
        }
        guard let window = found else { return }
        try? await Task.sleep(for: .milliseconds(500))
        window.contentMaxSize = AppWindowLayoutPolicy.unboundedContentSize
        if let startSize {
            // A recording must show the whole window: the start size is
            // limited to the visible area of the window's own screen.
            MainWindowSnapshotPipeline.place(window, contentSize: fittingRecordingSize(startSize, for: window))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // A recording is scripted: a pointer resting over the window must
        // neither hover nor click anything in it.
        window.ignoresMouseEvents = true
        defer { window.ignoresMouseEvents = false }
        let originalLevel = window.level
        defer { window.level = originalLevel }
        if let frameFile, frameFile.hasPrefix("/") {
            // While recording, other apps' windows must not cover the
            // recorded rectangle; the recorder reads the rectangle here
            // (screencapture -R) and starts before any scripted motion.
            window.level = .floating
            writeRecordingFrame(of: window, to: frameFile)
            try? await Task.sleep(for: .seconds(2.5))
        }
        try? await Task.sleep(for: .seconds(2))
        if let tour {
            for filter in tour {
                navigationState.select(filter)
                try? await Task.sleep(for: .seconds(1.6))
            }
        }
        if wantsMemoryDemo {
            await runMemoryDemo(navigationState: navigationState, store: store)
        }
#if DEBUG
        // DebugSmartScanFlowDemo exists only in Debug; this file also builds for Beta.
        if DebugSmartScanFlowDemo.isRequested {
            // The flow demo runs on its own clock; keep the window floating
            // and ignoring the pointer until it is done.
            try? await Task.sleep(for: .seconds(22))
        }
#endif
        if wantsResize {
            // Down to the 820×560 minimum in steps, then back up, with the
            // top-left corner fixed (the full sidebar returns at 960 pt).
            let start = window.contentRect(forFrameRect: window.frame).size
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            var steps: [NSSize] = []
            var content = start
            while content.width > 820.5 {
                content.width = max(820, content.width - 110)
                content.height = max(560, content.height - 60)
                steps.append(content)
            }
            for size in steps + steps.reversed().dropFirst() + [start] {
                var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
                frame.origin = NSPoint(x: topLeft.x, y: topLeft.y - frame.height)
                window.setFrame(frame, display: true, animate: true)
                try? await Task.sleep(for: .milliseconds(650))
            }
        }
    }

    static let frameFilePrefix = "--debug-window-frame-file="

    static var recordsWindowFrame: Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix(frameFilePrefix) }
    }

    private static func fittingRecordingSize(_ size: NSSize, for window: NSWindow) -> NSSize {
        guard recordsWindowFrame, let screen = window.screen ?? NSScreen.main else { return size }
        let chrome = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8).size
        return NSSize(
            width: min(size.width, size.width - (chrome.width - visible.width)),
            height: min(size.height, size.height - (chrome.height - visible.height))
        )
    }

    /// Writes the window frame in screencapture coordinates: points, origin
    /// at the top-left corner of the primary display.
    private static func writeRecordingFrame(of window: NSWindow, to path: String) {
        guard let primary = NSScreen.screens.first else { return }
        let frame = window.frame
        // `window` lets a window-only recorder (ScreenCaptureKit) follow this
        // window alone, so nothing else on the screen is ever recorded.
        let rect: [String: Int] = [
            "x": Int(frame.minX.rounded(.down)),
            "y": Int((primary.frame.maxY - frame.maxY).rounded(.down)),
            "width": Int(frame.width.rounded(.up)),
            "height": Int(frame.height.rounded(.up)),
            "window": window.windowNumber
        ]
        if let data = try? JSONSerialization.data(withJSONObject: rect, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// Fixture only: the memory store reads the demo snapshot on refresh and
    /// refuses every quit request while demo data is on.
    private static func prepareMemoryFixture(store: ScanStore, arguments: [String]) {
        guard MiniWindowDemoData.isEnabled else { return }
        if arguments.contains("--debug-memory-quittable") {
            store.memoryShowsAllProcesses = false
        }
        if arguments.contains("--debug-memory-select-suggested") {
            store.refreshMemory()
            _ = store.selectRecommendedMemoryApps()
        }
    }

    private static func runMemoryDemo(navigationState: AppNavigationState, store: ScanStore) async {
        navigationState.select(.memory)
        try? await Task.sleep(for: .seconds(2.6))
        store.refreshMemory()
        try? await Task.sleep(for: .seconds(1.2))
        store.memoryShowsAllProcesses = false
        try? await Task.sleep(for: .seconds(1.6))
        _ = store.selectRecommendedMemoryApps()
        try? await Task.sleep(for: .seconds(2.2))
        store.clearMemoryProcessSelection()
        try? await Task.sleep(for: .seconds(1.4))
        store.memoryShowsAllProcesses = true
        try? await Task.sleep(for: .seconds(1.4))
    }
}

/// Holds a policy refinement's iCloud question until opened (capture only).
private final class CaptureRefinementGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    func wait() {
        condition.lock()
        let deadline = Date().addingTimeInterval(60)
        while !isOpen && condition.wait(until: deadline) {}
        condition.unlock()
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Makes the fixture's receipt files read-only after the first move, so the
/// next receipt write fails (capture only); `repair` undoes it.
private final class CaptureReceiptBreaker: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var broken = false

    init(directory: URL) { self.directory = directory }

    func breakAfterFirstMove() {
        let first: Bool = lock.withLock {
            defer { broken = true }
            return !broken
        }
        if first { setMode(0o400) }
    }

    func repair() { setMode(0o600) }

    private func setMode(_ mode: mode_t) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            _ = chmod(directory.appendingPathComponent(name).path, mode)
        }
    }
}
#endif
