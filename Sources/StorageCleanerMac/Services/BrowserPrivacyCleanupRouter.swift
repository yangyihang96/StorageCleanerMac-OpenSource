import AppKit
import Foundation

enum BrowserPrivacyDataKind: Equatable, Sendable {
    case history
    case downloads
    case siteData
    case cache
}

enum BrowserPrivacyCleanupAction: Equatable, Sendable {
    case openBrowserHistory
    case openBrowserDownloads
    case openBrowserWebsiteData
    case openBrowserCacheSettings
}

struct BrowserPrivacyCleanupRoute: Equatable, Sendable {
    let browser: BrowserKind
    let action: BrowserPrivacyCleanupAction
    let destinationURL: URL?
    let browserBundleIdentifier: String
    let instruction: String
    let requiresIndependentConfirmation: Bool
}

enum BrowserPrivacyCleanupError: LocalizedError, Equatable {
    case nativeRouteUnavailable

    var errorDescription: String? {
        switch self {
        case .nativeRouteUnavailable:
            L10n.text(
                "无法向浏览器发送打开请求，请按下方说明手动操作。",
                "The open request could not be sent to the browser. Follow the instructions below manually."
            )
        }
    }
}

enum BrowserBundleIdentifiers {
    static func primaryIdentifier(for browser: BrowserKind) -> String {
        switch browser {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .edge: "com.microsoft.edgemac"
        case .firefox: "org.mozilla.firefox"
        }
    }
}

@MainActor
protocol BrowserNativeManagementOpening: AnyObject {
    /// `true` only means Launch Services accepted the open request. It does not
    /// prove that a browser page finished rendering or that anything was deleted.
    @discardableResult
    func open(_ route: BrowserPrivacyCleanupRoute) async -> Bool
}

@MainActor
protocol BrowserWorkspaceLaunching: AnyObject {
    func applicationURL(forBundleIdentifier identifier: String) -> URL?

    /// `true` only means Launch Services accepted the request.
    func open(applicationURL: URL, destinationURL: URL?) async -> Bool
}

@MainActor
final class NSWorkspaceBrowserLauncher: BrowserWorkspaceLaunching {
    func applicationURL(forBundleIdentifier identifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }

    @discardableResult
    func open(applicationURL: URL, destinationURL: URL?) async -> Bool {
        await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            if let destinationURL {
                NSWorkspace.shared.open(
                    [destinationURL],
                    withApplicationAt: applicationURL,
                    configuration: configuration
                ) { runningApplication, error in
                    continuation.resume(returning: runningApplication != nil && error == nil)
                }
            } else {
                NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: configuration
                ) { runningApplication, error in
                    continuation.resume(returning: runningApplication != nil && error == nil)
                }
            }
        }
    }
}

@MainActor
final class WorkspaceBrowserNativeManagementOpener: BrowserNativeManagementOpening {
    private let launcher: any BrowserWorkspaceLaunching

    init(launcher: any BrowserWorkspaceLaunching = NSWorkspaceBrowserLauncher()) {
        self.launcher = launcher
    }

    @discardableResult
    func open(_ route: BrowserPrivacyCleanupRoute) async -> Bool {
        guard let applicationURL = launcher.applicationURL(
            forBundleIdentifier: route.browserBundleIdentifier
        ) else {
            return false
        }
        return await launcher.open(
            applicationURL: applicationURL,
            destinationURL: route.destinationURL
        )
    }
}

/// Safe-guidance-only privacy routing. The router never deletes browser data,
/// force-quits a browser, or constructs a direct cache-to-Trash operation.
struct BrowserPrivacyCleanupRouter: Sendable {
    func route(
        for kind: BrowserPrivacyDataKind,
        browser: BrowserKind
    ) -> BrowserPrivacyCleanupRoute {
        let action: BrowserPrivacyCleanupAction
        let requiresIndependentConfirmation: Bool

        switch kind {
        case .history:
            action = .openBrowserHistory
            requiresIndependentConfirmation = false
        case .downloads:
            action = .openBrowserDownloads
            requiresIndependentConfirmation = false
        case .siteData:
            action = .openBrowserWebsiteData
            requiresIndependentConfirmation = true
        case .cache:
            action = .openBrowserCacheSettings
            requiresIndependentConfirmation = true
        }

        return BrowserPrivacyCleanupRoute(
            browser: browser,
            action: action,
            destinationURL: managementURL(for: browser, kind: kind),
            browserBundleIdentifier: BrowserBundleIdentifiers.primaryIdentifier(for: browser),
            instruction: instruction(for: browser, kind: kind),
            requiresIndependentConfirmation: requiresIndependentConfirmation
        )
    }

    @MainActor
    func openNativeManagement(
        _ route: BrowserPrivacyCleanupRoute,
        opener: any BrowserNativeManagementOpening = WorkspaceBrowserNativeManagementOpener()
    ) async throws {
        guard await opener.open(route) else {
            throw BrowserPrivacyCleanupError.nativeRouteUnavailable
        }
    }

    private func managementURL(
        for browser: BrowserKind,
        kind: BrowserPrivacyDataKind
    ) -> URL? {
        switch (browser, kind) {
        case (.safari, _):
            // Safari has no stable public deep links for these management
            // surfaces. Launch Safari itself, then show an exact manual guide.
            return nil
        case (.chrome, .history):
            return URL(string: "chrome://history/")
        case (.chrome, .downloads):
            return URL(string: "chrome://downloads/")
        case (.chrome, .siteData):
            return URL(string: "chrome://settings/content/all")
        case (.chrome, .cache):
            return URL(string: "chrome://settings/clearBrowserData")
        case (.edge, .history):
            return URL(string: "edge://history/all")
        case (.edge, .downloads):
            return URL(string: "edge://downloads/all")
        case (.edge, .siteData):
            return URL(string: "edge://settings/content/all")
        case (.edge, .cache):
            return URL(string: "edge://settings/clearBrowserData")
        case (.firefox, .history):
            // `about:history` is not a supported Firefox management URL.
            return nil
        case (.firefox, .downloads):
            return URL(string: "about:downloads")
        case (.firefox, .siteData), (.firefox, .cache):
            return URL(string: "about:preferences#privacy")
        }
    }

    private func instruction(
        for browser: BrowserKind,
        kind: BrowserPrivacyDataKind
    ) -> String {
        switch (browser, kind) {
        case (.safari, .history):
            return L10n.text(
                "请打开 Safari，再按 Command-Y 打开历史记录，核对后手动删除。",
                "Open Safari, press Command-Y, review History, then delete manually."
            )
        case (.safari, .downloads):
            return L10n.text(
                "请打开 Safari，再按 Option-Command-L 打开下载列表并逐项确认。",
                "Open Safari, press Option-Command-L, and review Downloads item by item."
            )
        case (.safari, .siteData):
            return L10n.text(
                "请打开 Safari，前往 Safari > 设置 > 隐私 > 管理网站数据；移除后可能退出登录。",
                "Open Safari and go to Safari > Settings > Privacy > Manage Website Data; removal may sign you out."
            )
        case (.safari, .cache):
            return L10n.text(
                "请打开 Safari，在设置中启用网页开发者功能，再从开发菜单选择清空缓存；本应用不会直接移动缓存。",
                "Open Safari, enable web-developer features in Settings, then choose Empty Caches from Develop; this app does not move caches directly."
            )
        case (.firefox, .history):
            return L10n.text(
                "请打开 Firefox，再按 Command-Shift-H 打开历史记录资料库，核对后手动删除。",
                "Open Firefox, press Command-Shift-H, review the History Library, then delete manually."
            )
        case (_, .history):
            return L10n.text(
                "请打开浏览器的历史记录页面，核对域名后再手动删除。",
                "Open the browser's History page and review the domain before deleting manually."
            )
        case (_, .downloads):
            return L10n.text(
                "请打开浏览器的下载记录并逐项确认。",
                "Open the browser's Downloads page and review each entry."
            )
        case (_, .siteData):
            return L10n.text(
                "请打开浏览器的网站数据设置；移除 Cookie 可能退出登录并影响同步，请独立确认。",
                "Open the browser's site-data settings. Removing cookies may sign you out and affect sync; confirm separately."
            )
        case (_, .cache):
            return L10n.text(
                "请打开浏览器的清除浏览数据设置，只勾选缓存并核对时间范围；本应用不会直接移动缓存。",
                "Open the browser's clear-browsing-data settings, select only cached data, and review the time range; this app does not move caches directly."
            )
        }
    }
}
