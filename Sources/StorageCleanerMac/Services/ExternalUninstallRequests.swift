import AppKit
import SwiftUI
import UninstallHandoffShared

/// Why a path from the Finder entry did not reach the uninstall review (D88).
enum ExternalUninstallRejection: Equatable, Sendable {
    case handoff(FinderUninstallHandoff.Rejection)
    case missing
    case notApplicationBundle
    case systemApplication
    case notInInventory
    case notManageable

    var title: String {
        switch self {
        case .handoff(.notFileURL), .handoff(.unnormalizedPath):
            L10n.text("不是本机应用路径", "Not a local application path")
        case .handoff(.notApplicationBundle), .notApplicationBundle:
            L10n.text("不是应用程序", "Not an application")
        case .handoff(.pathTooLong):
            L10n.text("路径过长", "Path is too long")
        case .handoff(.overLimit):
            L10n.text("一次最多处理 \(FinderUninstallHandoff.maximumApplications) 个应用", "At most \(FinderUninstallHandoff.maximumApplications) apps at a time")
        case .missing:
            L10n.text("已不存在或替身已失效", "No longer exists, or the alias is broken")
        case .systemApplication:
            L10n.text("系统应用，不能卸载", "System app; cannot be uninstalled")
        case .notInInventory:
            L10n.text("不在已扫描的应用清单中", "Not in the scanned application list")
        case .notManageable:
            L10n.text("当前位置或状态不能移到废纸篓", "Cannot be moved to Trash from this location or state")
        }
    }
}

enum ExternalUninstallMatch: Equatable, Sendable {
    case application(InstalledAppItem)
    case rejected(ExternalUninstallRejection)
}

/// Maps a handed-off path to an inventory entry.
///
/// `literalMatch` is pure and runs on the main actor: a lexically equal
/// inventory path is the common Finder case and needs no file-system call.
/// Everything else goes through `resolve`, which follows an alias or symbolic
/// link once, requires a directory and compares real locations; the request
/// center runs it off the main thread. Running state, signature, other copies
/// and ownership are left to the existing review and execution checks.
enum ExternalUninstallResolver {
    /// `nil` when only the file system can decide.
    static func literalMatch(_ path: String, inventory: [InstalledAppItem]) -> ExternalUninstallMatch? {
        guard let normalized = FinderUninstallHandoff.normalizedApplicationPath(path) else {
            return .rejected(.handoff(.unnormalizedPath))
        }
        guard FinderUninstallHandoff.isApplicationBundlePath(normalized) else { return .rejected(.notApplicationBundle) }
        if normalized.hasPrefix("/System/") { return .rejected(.systemApplication) }
        if let app = inventory.first(where: {
            FinderUninstallHandoff.normalizedApplicationPath(PathSafety.lexicalPath($0.path)) == normalized
        }) {
            return .application(app)
        }
        return nil
    }

    static func resolve(_ path: String, inventory: [InstalledAppItem]) -> ExternalUninstallMatch {
        guard let normalized = FinderUninstallHandoff.normalizedApplicationPath(path) else {
            return .rejected(.handoff(.unnormalizedPath))
        }
        let url = URL(fileURLWithPath: normalized)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: normalized) else {
            return .rejected(.missing)
        }
        var target = normalized
        let isLink = attributes[.type] as? FileAttributeType == .typeSymbolicLink
        let isAlias = (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true
        if isLink || isAlias {
            guard let resolved = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]),
                  resolved.isFileURL,
                  let resolvedPath = FinderUninstallHandoff.normalizedApplicationPath(PathSafety.lexicalPath(resolved.path)),
                  FileManager.default.fileExists(atPath: resolvedPath) else {
                return .rejected(.missing)
            }
            target = resolvedPath
        }
        // Only an `.app` directory is an application; a file named `X.app`
        // opened with this app is not.
        var isDirectory: ObjCBool = false
        guard FinderUninstallHandoff.isApplicationBundlePath(target),
              FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory),
              isDirectory.boolValue else { return .rejected(.notApplicationBundle) }
        // Compare real locations so `/var` vs `/private/var` style firmlinks or
        // a symlinked parent cannot hide (or fake) an inventory match.
        let real = PathSafety.normalizedPath(target)
        if real.hasPrefix("/System/") { return .rejected(.systemApplication) }
        guard let app = inventory.first(where: { PathSafety.normalizedPath($0.path) == real }) else {
            return .rejected(.notInInventory)
        }
        return .application(app)
    }
}

/// The part of `ScanStore` the Finder handoff drives; a protocol so the queue
/// can be tested without scanning real applications.
@MainActor
protocol ExternalUninstallHost: AnyObject {
    var installedApps: [InstalledAppItem] { get }
    var hasScannedInstalledApps: Bool { get }
    var isLoadingInstalledApps: Bool { get }
    var isUninstallingApp: Bool { get }
    var isPreparingUninstall: Bool { get }
    var isRestoringRecordedOperation: Bool { get }
    var pendingUninstallApp: InstalledAppItem? { get }
    var pendingRelatedCleanupApp: InstalledAppItem? { get }
    var isCleaningRelatedAppFiles: Bool { get }
    var canRefreshInstalledApps: Bool { get }
    func canRequestUninstall(_ app: InstalledAppItem) -> Bool
    func requestUninstall(_ app: InstalledAppItem)
    func refreshInstalledApps(priority: TaskPriority)
    func showFilter(_ filter: ReviewFilter)
}

extension ScanStore: ExternalUninstallHost {}

/// The dedicated summary shown when some handed-off items did not reach the
/// review. Not an "operation failed" error: nothing was attempted.
struct ExternalUninstallRejectionSummary: Equatable, Sendable {
    static let maximumListedItems = 8
    static let maximumNameLength = 60

    let message: String

    static var title: String {
        L10n.text("部分项目未进入卸载审阅", "Some Items Were Not Opened for Review")
    }

    init(entries: [(path: String, reason: ExternalUninstallRejection)], droppedCount: Int) {
        let separator = L10n.text("：", ": ")
        let lines = entries.prefix(Self.maximumListedItems).map { entry in
            "• " + Self.displayName(entry.path) + separator + entry.reason.title
        }
        let more = entries.count + droppedCount - min(entries.count, Self.maximumListedItems)
        let tail = more > 0 ? ["• " + L10n.text("另有 \(more) 项", "\(more) more")] : []
        message = ([L10n.text("以下项目没有打开卸载审阅：", "These items were not opened for uninstall review:")] + lines + tail)
            .joined(separator: "\n")
    }

    /// The last path component without control or format characters (for
    /// example newlines or right-to-left overrides), truncated.
    static func displayName(_ path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let clean = String(scalars)
        guard clean.count > maximumNameLength else { return clean.isEmpty ? "?" : clean }
        return String(clean.prefix(maximumNameLength - 1)) + "…"
    }
}

/// Queues Finder handoffs and feeds them, one at a time, into the existing
/// `requestUninstall` review. It never selects related files, confirms or
/// executes; the review sheet stays the only place an uninstall can start.
///
/// Requests that arrive while one batch is still being handled join that
/// batch: the inventory is refreshed once and the page is switched once.
/// The queue and the rejection list are bounded.
@MainActor
final class ExternalUninstallRequestCenter: ObservableObject {
    static let shared = ExternalUninstallRequestCenter()
    static let maximumQueuedApplications = FinderUninstallHandoff.maximumApplications
    static let maximumRejections = 64

    private(set) var queue: [String] = []
    private(set) var rejections: [(path: String, reason: ExternalUninstallRejection)] = []
    private(set) var droppedRejectionCount = 0
    private(set) var isBatchActive = false
    /// Running file-system resolution, exposed so tests can await it.
    private(set) var resolutionTask: Task<Void, Never>?
    @Published var rejectionSummary: ExternalUninstallRejectionSummary?

    private var resolvedApplication: InstalledAppItem?
    private var inFlightPath: String?
    private var needsInventoryRefresh = false
    private var hasRefreshedThisBatch = false
    private var needsNavigation = false
    private var needsWindowPresentation = false
    private weak var host: (any ExternalUninstallHost)?

    /// SwiftUI routes the open-documents event to the existing main window,
    /// or creates one for it when none is open, so only bring the app
    /// forward. Requesting the "primary" main window here opened a second
    /// window on a cold launch, whose window SwiftUI created for the event
    /// (2026-10-13 real-device check).
    var showMainWindow: @MainActor () -> Void = {
        NSApp.activate(ignoringOtherApps: true)
    }
    /// The attaching window already exists; only bring the app forward.
    var activateAttachedWindow: @MainActor () -> Void = {
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Runs off the main actor; injectable for tests.
    var resolveOnFileSystem: @Sendable (String, [InstalledAppItem]) async -> ExternalUninstallMatch = { path, inventory in
        await Task.detached(priority: .userInitiated) {
            ExternalUninstallResolver.resolve(path, inventory: inventory)
        }.value
    }

    init() {}

    /// Open-documents entry (`application(_:open:)`). Returns `false` when
    /// none of the URLs is a file URL, so nothing is shown.
    @discardableResult
    func receive(openedURLs urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        receive(FinderUninstallHandoff.request(for: files))
        return true
    }

    func receive(_ request: FinderUninstallHandoff.Request) {
        let startsBatch = !isBatchActive
        isBatchActive = true
        for path in request.paths where !queue.contains(path) && inFlightPath != path {
            if queue.count < Self.maximumQueuedApplications {
                queue.append(path)
            } else {
                addRejection(path, .handoff(.overLimit))
            }
        }
        for rejected in request.rejected { addRejection(rejected.path, .handoff(rejected.reason)) }
        // A Finder selection may be newer than the last inventory (for example
        // an app installed since). Refresh once per batch before matching.
        if !request.paths.isEmpty && !hasRefreshedThisBatch { needsInventoryRefresh = true }
        if startsBatch {
            needsNavigation = true
            presentMainWindow()
        }
        if let host { advance(host) }
    }

    /// Called when the main window appears. On a cold launch the request can
    /// arrive before any window exists; it waits here and the app is brought
    /// forward once the window is ready, without opening another window.
    func attach(_ host: any ExternalUninstallHost) {
        self.host = host
        if needsWindowPresentation {
            needsWindowPresentation = false
            activateAttachedWindow()
        }
        advance(host)
    }

    func advance(_ host: any ExternalUninstallHost) {
        guard isBatchActive else { return }
        if needsNavigation {
            needsNavigation = false
            host.showFilter(.uninstall)
        }
        guard resolutionTask == nil, Self.isIdle(host) else { return }
        if let app = resolvedApplication {
            resolvedApplication = nil
            if offer(app, host: host) { return }
        }
        if !queue.isEmpty && (needsInventoryRefresh || !host.hasScannedInstalledApps) {
            guard host.canRefreshInstalledApps else { return }
            needsInventoryRefresh = false
            hasRefreshedThisBatch = true
            host.refreshInstalledApps(priority: .userInitiated)
            return
        }
        while !queue.isEmpty {
            let path = queue.removeFirst()
            switch ExternalUninstallResolver.literalMatch(path, inventory: host.installedApps) {
            case .application(let app)?:
                if offer(app, host: host) { return }
            case .rejected(let reason)?:
                addRejection(path, reason)
            case nil:
                resolveOffMain(path, inventory: host.installedApps)
                return
            }
        }
        finishBatch()
    }

    /// Waits for the whole uninstall flow, including a related-files cleanup
    /// that follows an uninstall, before refreshing or opening a review.
    private static func isIdle(_ host: any ExternalUninstallHost) -> Bool {
        !host.isLoadingInstalledApps && !host.isUninstallingApp && !host.isPreparingUninstall
            && !host.isRestoringRecordedOperation && host.pendingUninstallApp == nil
            && host.pendingRelatedCleanupApp == nil && !host.isCleaningRelatedAppFiles
    }

    private func offer(_ app: InstalledAppItem, host: any ExternalUninstallHost) -> Bool {
        guard host.canRequestUninstall(app) else {
            addRejection(app.path, .notManageable)
            return false
        }
        host.requestUninstall(app)
        return true
    }

    private func resolveOffMain(_ path: String, inventory: [InstalledAppItem]) {
        inFlightPath = path
        let resolver = resolveOnFileSystem
        resolutionTask = Task { [weak self] in
            let match = await resolver(path, inventory)
            guard let self else { return }
            self.inFlightPath = nil
            self.resolutionTask = nil
            switch match {
            case .application(let app): self.resolvedApplication = app
            case .rejected(let reason): self.addRejection(path, reason)
            }
            if let host = self.host { self.advance(host) }
        }
    }

    private func presentMainWindow() {
        if host == nil {
            needsWindowPresentation = true
        } else {
            showMainWindow()
        }
    }

    private func addRejection(_ path: String, _ reason: ExternalUninstallRejection) {
        if rejections.count < Self.maximumRejections {
            rejections.append((path, reason))
        } else {
            droppedRejectionCount += 1
        }
    }

    private func finishBatch() {
        if !rejections.isEmpty || droppedRejectionCount > 0 {
            rejectionSummary = ExternalUninstallRejectionSummary(entries: rejections, droppedCount: droppedRejectionCount)
        }
        rejections.removeAll()
        droppedRejectionCount = 0
        isBatchActive = false
        hasRefreshedThisBatch = false
        needsInventoryRefresh = false
    }
}

/// Re-evaluates the queue whenever the uninstall flow becomes idle again, and
/// shows the rejection summary with its own title.
struct ExternalUninstallRequestBridge: ViewModifier {
    @ObservedObject var store: ScanStore
    @ObservedObject var center: ExternalUninstallRequestCenter

    func body(content: Content) -> some View {
        content
            // An open-documents event is handled by the existing main window
            // instead of creating another one.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onAppear { center.attach(store) }
            .onChange(of: store.isLoadingInstalledApps) { _, _ in center.advance(store) }
            .onChange(of: store.isPreparingUninstall) { _, _ in center.advance(store) }
            .onChange(of: store.isUninstallingApp) { _, _ in center.advance(store) }
            .onChange(of: store.isRestoringRecordedOperation) { _, _ in center.advance(store) }
            .onChange(of: store.pendingUninstallApp?.id) { _, _ in center.advance(store) }
            .onChange(of: store.pendingRelatedCleanupApp?.id) { _, _ in center.advance(store) }
            .onChange(of: store.isCleaningRelatedAppFiles) { _, _ in center.advance(store) }
            .alert(ExternalUninstallRejectionSummary.title, isPresented: summaryBinding) {
                Button(L10n.text("好", "OK")) { center.rejectionSummary = nil }
            } message: {
                Text(center.rejectionSummary?.message ?? "")
            }
    }

    /// Waits for any existing error alert so two alerts never compete.
    private var summaryBinding: Binding<Bool> {
        Binding {
            center.rejectionSummary != nil && store.errorMessage == nil
        } set: { isPresented in
            if !isPresented { center.rejectionSummary = nil }
        }
    }
}
