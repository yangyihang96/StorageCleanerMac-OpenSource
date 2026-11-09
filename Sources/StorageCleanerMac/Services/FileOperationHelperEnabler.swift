import AppKit
import FileOperationShared
import Foundation
import ServiceManagement
import SwiftUI

/// D229: where the file-operation helper's registration stands. The formal
/// 2.0.1 install on the review Mac had never registered it, so Performance
/// and Smart Scan could not read login items and only said so.
enum FileOperationHelperStatus: Equatable, Sendable {
    case enabled
    /// Registered; macOS waits for the switch in Login Items & Extensions.
    case requiresApproval
    case notRegistered
    /// This build carries no helper (a bare `swift run`).
    case unavailable

    init(service: SMAppService.Status, bundled: Bool) {
        guard bundled else { self = .unavailable; return }
        switch service {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        // `.notFound` too: `prepareHelper` registers it the same way.
        case .notRegistered, .notFound: self = .notRegistered
        @unknown default: self = .notRegistered
        }
    }

    var title: String {
        switch self {
        case .enabled: L10n.text("已启用", "Enabled")
        case .requiresApproval: L10n.text("等待系统批准", "Awaiting System Approval")
        case .notRegistered: L10n.text("尚未启用", "Not Enabled")
        case .unavailable: L10n.text("此版本不含后台助手", "Not in This Build")
        }
    }

    /// What the user can do about unread login items; nil when the helper is
    /// enabled, where the read error itself says what went wrong.
    var unreadLoginReason: String? {
        switch self {
        case .enabled: nil
        case .notRegistered:
            L10n.text("后台助手还没有启用，所以没读到登录项。启用后台助手就能直接读取；也可以在启动项管理里做一次需要管理员确认的完整读取。",
                      "The background helper is not enabled, so login items were not read. Enable it to read them directly, or run a full read in the Startup Manager, which asks for administrator approval.")
        case .requiresApproval:
            L10n.text("后台助手正在等待你在系统设置的“登录项与扩展”中批准；批准后回到这里会重新读取。",
                      "The background helper is waiting for your approval in System Settings › Login Items & Extensions; the list is read again when you come back.")
        case .unavailable:
            L10n.text("这个版本没有带后台助手；可以在启动项管理里做一次需要管理员确认的完整读取。",
                      "This build has no background helper; run a full read in the Startup Manager, which asks for administrator approval.")
        }
    }

    /// The button that moves this status on; nil when there is nothing to do.
    var actionTitle: String? {
        switch self {
        case .notRegistered: L10n.text("启用后台助手", "Enable Helper")
        case .requiresApproval: L10n.text("打开登录项", "Open Login Items")
        case .enabled, .unavailable: nil
        }
    }
}

/// D229 (A batch, review P1-1): the user's explicit "Enable Background
/// Helper". D177 stands: scans never register the helper. Only this button,
/// after its confirmation, and the confirmed operations that need the helper
/// (protected uninstall, D182 system caches) call `prepareHelper`.
@MainActor
final class FileOperationHelperEnabler: ObservableObject {
    enum Outcome: Equatable {
        case enabled
        case awaitingApproval
        case failed(String)
    }

    struct Dependencies: Sendable {
        /// Read off the main thread: `SMAppService.status` is a synchronous
        /// XPC query (see `SettingsGeneral.refreshLaunchAtLoginStatus`).
        var readStatus: @Sendable () -> FileOperationHelperStatus
        /// The bundled helper is there and signed like this app (D182's check).
        var bundledHelperIsTrusted: @Sendable () async -> Bool
        var register: @MainActor @Sendable () async throws -> Void
        var openApprovalSettings: @MainActor @Sendable () -> Void

        static let live = Dependencies(
            readStatus: {
                FileOperationHelperStatus(
                    service: SMAppService.daemon(plistName: FileOperationIdentity.helper + ".plist").status,
                    bundled: Bundle.main.url(forResource: "StorageCleanerFileOperationHelper", withExtension: nil) != nil)
            },
            bundledHelperIsTrusted: {
                guard let url = Bundle.main.url(forResource: "StorageCleanerFileOperationHelper", withExtension: nil) else {
                    return false
                }
                return await AuthorizedApplicationMover.trustedBundledHelper(url)
            },
            register: { try await AuthorizedApplicationMover.shared.prepareHelper(refreshRegisteredBuild: true) },
            openApprovalSettings: { SMAppService.openSystemSettingsLoginItems() })
    }

    static let shared = FileOperationHelperEnabler(.live)

    /// nil until the first read finishes; the views show no button meanwhile.
    @Published private(set) var status: FileOperationHelperStatus?
    @Published private(set) var isEnabling = false
    @Published private(set) var outcome: Outcome?
    private let dependencies: Dependencies
    private var refreshTask: Task<Void, Never>?
    /// Set while macOS waits for the user's approval; called once the
    /// helper reads as enabled (the startup list is read again then).
    private var onApproved: (@MainActor @Sendable () -> Void)?
    private var activationObserver: NSObjectProtocol?

    init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Reads the registration again; also finishes a pending approval once
    /// the helper reads as enabled.
    func refresh() async {
        let read = dependencies.readStatus
        let value = await Task.detached(priority: .utility) { read() }.value
        status = value
        if value == .enabled, let approved = onApproved {
            stopAwaitingApproval()
            outcome = .enabled
            approved()
        }
    }

    /// For views: a read that does not block them.
    func refreshSoon() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh() }
    }

    /// The confirmed action. `onEnabled` reads the startup list again once
    /// the helper can answer: now, or after the user approves it. Returns
    /// what happened (nil when another request was running or it was cancelled).
    @discardableResult
    func enable(onEnabled: @escaping @MainActor @Sendable () -> Void) async -> Outcome? {
        guard !isEnabling else { return nil }
        isEnabling = true
        defer { isEnabling = false }
        // A new request replaces a pending approval's callback.
        stopAwaitingApproval()
        outcome = nil
        await refresh()
        switch status {
        case .enabled?:
            outcome = .enabled
            onEnabled()
            return outcome
        case .requiresApproval?:
            // Already registered: only the user's switch is missing.
            awaitApproval(onEnabled)
            dependencies.openApprovalSettings()
            return outcome
        case .unavailable?:
            outcome = .failed(Self.unavailableMessage)
            return outcome
        case .notRegistered?, nil:
            break
        }
        guard await dependencies.bundledHelperIsTrusted() else {
            outcome = .failed(Self.unavailableMessage)
            return outcome
        }
        do {
            try await dependencies.register()
            await refresh()
            outcome = .enabled
            onEnabled()
        } catch AuthorizedMoveError.approvalRequired {
            await refresh()
            awaitApproval(onEnabled)
            dependencies.openApprovalSettings()
        } catch is CancellationError {
            await refresh()
            return nil
        } catch {
            await refresh()
            outcome = .failed(Self.message(for: error))
        }
        return outcome
    }

    /// The approval switch is the user's; this only opens the place.
    func openApprovalSettings() {
        dependencies.openApprovalSettings()
    }

    private func awaitApproval(_ onEnabled: @escaping @MainActor @Sendable () -> Void) {
        outcome = .awaitingApproval
        onApproved = onEnabled
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    private func stopAwaitingApproval() {
        onApproved = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    static var unavailableMessage: String {
        L10n.text("这个版本的后台助手缺失或签名不符，不能启用。",
                  "This build's background helper is missing or not signed like the app, so it cannot be enabled.")
    }

    static func message(for error: Error) -> String {
        if (error as? AuthorizedMoveError) == .unavailable { return unavailableMessage }
        let underlying = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError) ?? error as NSError
        return L10n.text("macOS 没有接受后台助手的注册（\(underlying.domain) \(underlying.code)），可以稍后重试。",
                         "macOS did not accept the background helper's registration (\(underlying.domain) \(underlying.code)); try again later.")
    }
}

/// D229: the one confirmation in front of every "Enable Background Helper";
/// `perform` runs only after the user chose Enable.
extension View {
    func fileOperationHelperEnableConfirmation(isPresented: Binding<Bool>,
                                               perform: @escaping @MainActor () -> Void) -> some View {
        confirmationDialog(L10n.text("启用后台助手？", "Enable the Background Helper?"), isPresented: isPresented,
                           titleVisibility: .visible) {
            Button(L10n.text("启用", "Enable"), action: perform)
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(FileOperationHelperEnabler.confirmationMessage)
        }
    }
}

extension FileOperationHelperEnabler {
    static var confirmationMessage: String {
        L10n.text("后台助手是本应用自带、以管理员身份运行的系统组件。系统只在读取登录项、卸载受保护的应用或清除系统缓存时按需启动它，空闲 15 秒后自动退出。启用后 macOS 会在“登录项与扩展”里列出它，可能需要你在那里打开开关。扫描本身从不启用它。",
                  "The background helper is a system component bundled with this app that runs as administrator. macOS starts it only when needed — to read login items, remove protected apps or clear system caches — and it quits after 15 idle seconds. Once enabled, macOS lists it in Login Items & Extensions, where you may need to turn it on. Scans never enable it.")
    }
}
