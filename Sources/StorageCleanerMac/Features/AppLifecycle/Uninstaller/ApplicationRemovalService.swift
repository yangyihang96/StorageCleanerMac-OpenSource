import AppKit
import Darwin
import Foundation

/// What one application (or one group of leftovers) asks to remove.
struct ApplicationRemovalRequest: Sendable, Identifiable {
    enum Purpose: String, Sendable {
        /// The bundle and its resources (CleanMyMac Uninstall).
        case uninstall
        /// D218: only this copy's bundle. Shared resources must never follow it.
        case bundleOnly
        /// Resources only, the bundle stays (CleanMyMac's reset).
        case reset
        /// Files an already removed app left behind.
        case leftovers
        /// Installer images and packages.
        case installers
        /// An app already in the Trash: its leftovers.
        case trashedApplication
    }

    let id = UUID()
    let title: String
    let bundleIdentifier: String
    let purpose: Purpose
    /// The inventory item when the bundle itself is selected.
    let application: InstalledAppItem?
    /// Selected, removable resources other than the bundle.
    let resources: [ApplicationResource]
    /// False when the person chose Ignore for this running app.
    var allowsRunningApplication = false

    init(title: String, bundleIdentifier: String, purpose: Purpose, application: InstalledAppItem?,
         resources: [ApplicationResource], allowsRunningApplication: Bool = false) {
        self.title = title
        self.bundleIdentifier = bundleIdentifier
        self.purpose = purpose
        self.application = application
        self.resources = purpose == .bundleOnly ? [] : resources
        self.allowsRunningApplication = allowsRunningApplication
    }

    var removesBundle: Bool { purpose == .uninstall || purpose == .bundleOnly }
}

/// The result shown on the completion screen and kept in the log.
struct ApplicationRemovalOutcome: Sendable, Identifiable {
    struct LogLine: Sendable, Hashable, Identifiable {
        enum Status: Sendable, Hashable { case removed, kept(String), failed(String) }
        let id = UUID()
        let path: String
        let status: Status
    }

    let id: UUID
    let title: String
    let purpose: ApplicationRemovalRequest.Purpose
    var report: CleanReport?
    var removedCount = 0
    var removedBytes: Int64 = 0
    var keptCount = 0
    var failedCount = 0
    var applicationRemoved = false
    var log: [LogLine] = []

    var succeeded: Bool { failedCount == 0 && (removedCount > 0 || keptCount == 0) }
}

/// Runs a removal the CleanMyMac way (`ConfigDependentApplicationResourceRemover`,
/// `LaunchAgentDependenciesResolver`, `ApplicationDockIconResourceRemover`)
/// with this app's guarantees: every file moves to the Trash with a receipt
/// that Operation History can restore; identities are checked again right
/// before each move; nothing is deleted; the bundle falls back to the
/// existing administrator path (`UninstallAuthorizationEnvironment`).
struct ApplicationRemovalService: Sendable {
    var moves: UninstallMoveEnvironment = .live
    var persist: @Sendable (CleanReport, [String: FileIdentity]) throws -> Void = {
        try CleanupReportJournal.live.checkpoint($0, expectedIdentities: $1)
    }
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    /// launchctl's status and standard output (`print` names the plist a
    /// loaded job came from).
    var launchctl: @Sendable (_ arguments: [String]) -> (status: Int32, output: String) = { arguments in
        guard let result = try? Shell.run("/bin/launchctl", arguments, timeout: 10) else { return (-1, "") }
        return (result.terminationStatus, result.standardOutput)
    }
    var dock: DockTileEditing = .live
    /// Moves one resource to the Trash; tests use their own Trash folder.
    var trashResource: @Sendable (URL) throws -> URL = { source in
        var target: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &target)
        guard let target = target as URL? else { throw CleanupMoveError.invalidResult }
        return target
    }

    static let ruleID = "uninstall.lifecycle.v1"

    func run(_ request: ApplicationRemovalRequest, coordinator: HeavyWorkCoordinator,
             lease: HeavyWorkCoordinator.Lease) async -> ApplicationRemovalOutcome {
        var outcome = ApplicationRemovalOutcome(id: request.id, title: request.title, purpose: request.purpose)
        let sessionID = UUID()

        // Launch items first, so a job never keeps running from a moved plist.
        var unloadRefused = Set<String>()
        for resource in request.resources {
            guard case .launchdJob(let label) = resource.kind else { continue }
            if resource.domain == .system {
                unloadRefused.insert(resource.path)
                outcome.log.append(.init(path: resource.path, status: .kept(Self.administratorNote)))
                outcome.keptCount += 1
                continue
            }
            switch unload(label: label, plist: resource.path) {
            case .notLoaded, .stopped:
                break
            case .stillRunning:
                unloadRefused.insert(resource.path)
                outcome.log.append(.init(path: resource.path, status: .failed(L10n.text(
                    "启动项 \"\(label)\" 未能停止，已保留", "Launch item \"\(label)\" could not be stopped and was kept"))))
                outcome.failedCount += 1
            case .notThisPlist, .appleLabel:
                unloadRefused.insert(resource.path)
                outcome.log.append(.init(path: resource.path, status: .kept(Self.unconfirmedLaunchItemNote)))
                outcome.keptCount += 1
            }
        }

        var items: [RecordedTrashOperation.Item] = []
        if let app = request.application, request.removesBundle {
            items.append(.init(path: app.path, bytes: app.sizeBytes, identity: app.scanIdentity,
                               allowedRestoreRoot: URL(fileURLWithPath: app.path).deletingLastPathComponent()))
        }
        var dockTiles: [String] = []
        for resource in request.resources where resource.isRemovable && !unloadRefused.contains(resource.path) {
            switch resource.kind {
            case .dockTile(let url):
                dockTiles.append(url)
            case .file, .launchdJob:
                items.append(.init(path: resource.path, bytes: resource.sizeBytes, identity: resource.identity,
                                   allowedRestoreRoot: URL(fileURLWithPath: resource.path).deletingLastPathComponent()))
            }
        }
        // A folder and something inside it never move twice.
        items.sort { $0.path.count < $1.path.count }
        var roots: [RecordedTrashOperation.Item] = []
        for item in items where !roots.contains(where: { item.path.hasPrefix($0.path + "/") || item.path == $0.path }) {
            roots.append(item)
        }

        if !roots.isEmpty {
            let applicationPath = request.application?.path
            let report = await RecordedTrashOperation.runAsync(items: roots, ruleID: Self.ruleID, validate: { item in
                try await coordinator.requireValid(lease, owner: .cleanup)
                try Task.checkCancellation()
                try await validate(item, request: request)
            }, move: { source in
                try await move(source, request: request, applicationPath: applicationPath, sessionID: sessionID,
                               coordinator: coordinator, lease: lease)
            }, persist: persist)
            outcome.report = report
            for row in report.items {
                switch row.outcome {
                case .moved:
                    outcome.removedCount += 1
                    outcome.removedBytes += row.estimatedBytes
                    if row.sourcePath == applicationPath { outcome.applicationRemoved = true }
                    outcome.log.append(.init(path: row.sourcePath, status: .removed))
                case .skipped(let reason):
                    outcome.keptCount += 1
                    outcome.log.append(.init(path: row.sourcePath, status: .kept(Self.describe(reason))))
                case .failed(let failure):
                    outcome.failedCount += 1
                    outcome.log.append(.init(path: row.sourcePath, status: .failed(Self.describe(failure, path: row.sourcePath))))
                case .notProcessed:
                    outcome.keptCount += 1
                    outcome.log.append(.init(path: row.sourcePath, status: .kept(L10n.text("未处理", "Not processed"))))
                case .deleted:
                    break
                }
            }
        }

        if !dockTiles.isEmpty {
            if let removed = await dock.removeTiles(dockTiles) {
                // Only tiles the Dock still had count as removed; one already
                // gone is noted without counting.
                outcome.removedCount += removed.count
                outcome.log.append(contentsOf: removed.map { .init(path: $0, status: .removed) })
                outcome.log.append(contentsOf: dockTiles.filter { !removed.contains($0) }.map {
                    .init(path: $0, status: .kept(L10n.text("已不在程序坞中", "No longer in the Dock")))
                })
            } else {
                outcome.failedCount += dockTiles.count
                outcome.log.append(contentsOf: dockTiles.map { .init(path: $0, status: .failed(L10n.text("未能从程序坞移除", "Could not be removed from the Dock"))) })
            }
        }
        return outcome
    }

    static let administratorNote = L10n.text("系统位置的项目需要管理员权限，本版暂不处理，已保留",
                                             "Items in system locations need an administrator; this version keeps them")
    static let unconfirmedLaunchItemNote = L10n.text("未能确认此启动项属于该应用，已保留",
                                                     "This launch item could not be confirmed as the app's own and was kept")

    // MARK: Steps

    enum UnloadResult: Equatable { case notLoaded, stopped, stillRunning, notThisPlist, appleLabel }

    /// Stops the user agent the plist defines before the plist moves. The
    /// label comes from the plist, so another loaded job may hold it (this
    /// plist then never loaded): only a job launchd says came from this very
    /// plist is booted out, and Apple's labels are never touched (D151
    /// review).
    func unload(label: String, plist: String) -> UnloadResult {
        guard UninstallCandidatePathPolicy.isSafeComponent(label) else { return .stillRunning }
        guard !label.lowercased().hasPrefix("com.apple.") else { return .appleLabel }
        let target = "gui/\(getuid())/\(label)"
        let loaded = launchctl(["print", target])
        // Not loaded: nothing to stop.
        guard loaded.status == 0 else { return .notLoaded }
        guard Self.loadedPlistPath(in: loaded.output) == PathSafety.lexicalPath(plist) else { return .notThisPlist }
        _ = launchctl(["bootout", target])
        return launchctl(["print", target]).status == 0 ? .stillRunning : .stopped
    }

    /// The `path = …` line of `launchctl print` (the plist a loaded job came
    /// from; a job submitted another way names its submitter instead).
    static func loadedPlistPath(in output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("path = ") else { continue }
            let value = String(trimmed.dropFirst("path = ".count))
            return value.hasPrefix("/") ? PathSafety.lexicalPath(value) : nil
        }
        return nil
    }

    private func validate(_ item: RecordedTrashOperation.Item, request: ApplicationRemovalRequest) async throws {
        let path = item.path
        guard path == PathSafety.lexicalPath(path), !PathSafety.containsSymbolicLinkComponent(in: path) else {
            throw AppUninstallError.identityChanged(path)
        }
        if let app = request.application, request.removesBundle || request.purpose == .reset,
           !request.allowsRunningApplication {
            let running = await MainActor.run { ApplicationTerminator.isRunning(path: app.path, bundleIdentifier: app.bundleIdentifier) }
            if running { throw RecordedTrashOperation.Skip(reason: .relatedAppStillRunning) }
        }
        if path == request.application?.path, let app = request.application {
            if request.purpose == .bundleOnly,
               !OtherApplicationsScanner.permits(path: path, homePath: homeDirectory.path) {
                throw AppUninstallError.notAllowed(path)
            }
            guard AppUninstallService.scannedApplicationStillAtPath(app, allowMissingBundleIdentifier: request.purpose == .bundleOnly) else {
                throw AppUninstallError.identityChanged(path)
            }
            return
        }
        guard !ProtectedLocations.protects(path: path, homePath: PathSafety.lexicalPath(homeDirectory.path)) else {
            throw AppUninstallError.notAllowed(path)
        }
    }

    private func move(_ source: URL, request: ApplicationRemovalRequest, applicationPath: String?, sessionID: UUID,
                      coordinator: HeavyWorkCoordinator, lease: HeavyWorkCoordinator.Lease) async throws -> URL {
        guard source.path == applicationPath, let app = request.application else {
            return try trashResource(source)
        }
        do { return try await moves.recycle(source) }
        catch {
            let nativeError = error
            guard let identity = app.scanIdentity else { throw error }
            let authorization = moves.authorization
            let decision = UninstallAuthorizationDecision.evaluate(error, applicationPath: app.path,
                isWritable: authorization.isWritable, protection: authorization.protection,
                helperVerdict: { authorization.helperVerdict(app, identity, sessionID) })
            guard decision == .offer else { throw decision.notOfferedError(wrapping: error) ?? error }
            guard AppUninstallService.scannedApplicationStillAtPath(app, allowMissingBundleIdentifier: request.purpose == .bundleOnly) else {
                throw AppUninstallError.identityChanged(app.path)
            }
            do {
                return try await authorization.move(app, identity, sessionID, {
                    try await coordinator.requireValid(lease, owner: .cleanup)
                    try Task.checkCancellation()
                    guard AppUninstallService.scannedApplicationStillAtPath(app, allowMissingBundleIdentifier: request.purpose == .bundleOnly) else {
                        throw AppUninstallError.identityChanged(app.path)
                    }
                })
            } catch AuthorizedMoveError.connectionLost {
                _ = try await coordinator.beginCleanupQuarantine(lease)
                throw AuthorizedMoveError.connectionLost
            } catch {
                throw UninstallAuthorizationFailure.wrap(error, nativeError: nativeError)
            }
        }
    }

    private static func describe(_ reason: CleanSkipReason) -> String {
        switch reason {
        case .relatedAppStillRunning: L10n.text("跳过（应用正在运行）", "Skipped (the app is running)")
        default: L10n.text("扫描后已变化，已保留", "Changed since the scan; kept")
        }
    }

    private static func describe(_ failure: CleanFailure, path: String) -> String {
        if !path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/") {
            return administratorNote
        }
        switch failure.code {
        case .trashMoveRejected: return L10n.text("系统拒绝移入废纸篓", "The system refused to move it to the Trash")
        default: return L10n.text("未能移入废纸篓", "Could not be moved to the Trash")
        }
    }
}

/// Removes tiles from the Dock's `persistent-apps` and restarts the Dock so
/// it reads them again (CleanMyMac edits the same key and relaunches the
/// Dock with `killall`; here the running Dock is asked to quit and launchd
/// starts it again).
struct DockTileEditing: Sendable {
    /// The tiles taken out of the Dock (empty when none of them is there any
    /// more), or nil when the Dock's preferences could not be changed.
    var removeTiles: @Sendable ([String]) async -> [String]?

    static let live = DockTileEditing { urls in
        await MainActor.run {
            let domain = "com.apple.dock" as CFString
            let key = "persistent-apps" as CFString
            guard let tiles = CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] else { return nil }
            func spellings(_ url: String) -> Set<String> {
                [url, url.hasSuffix("/") ? String(url.dropLast()) : url + "/"]
            }
            var removed: [String] = []
            let kept = tiles.filter { tile in
                guard let url = ((tile["tile-data"] as? [String: Any])?["file-data"] as? [String: Any])?["_CFURLString"] as? String,
                      let match = urls.first(where: { spellings($0).contains(url) }) else { return true }
                if !removed.contains(match) { removed.append(match) }
                return false
            }
            guard !removed.isEmpty else { return [] }
            CFPreferencesSetAppValue(key, kept as CFArray, domain)
            guard CFPreferencesAppSynchronize(domain) else { return nil }
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").forEach { _ = $0.terminate() }
            return removed
        }
    }
}
