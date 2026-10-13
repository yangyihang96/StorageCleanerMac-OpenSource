import AppKit
import FinderSync
import UninstallHandoffShared

/// Thin Finder entry (D88): adds "Uninstall with Storage Cleaner" for selected
/// applications and hands their paths to the host application. It never
/// scans, measures, moves or deletes anything; the host application runs its
/// existing identity check and review sheet.
@objc(StorageCleanerFinderUninstallExtension)
final class FinderUninstallExtension: FIFinderSync {
    override init() {
        super.init()
        // Applications can be selected anywhere (Applications, ~/Applications,
        // Downloads, mounted images); the host decides what is manageable.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/", isDirectory: true)]
    }

    /// Only the installed Beta serves the menu; any other copy stays inert.
    private var host: URL? {
        FinderUninstallHandoff.hostApplication(forExtensionAt: Bundle.main.bundleURL)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems, host != nil,
              let selection = FIFinderSyncController.default().selectedItemURLs(),
              !FinderUninstallHandoff.applicationURLs(for: selection).isEmpty else { return nil }
        // Finder requests menus over XPC on a background queue (asserting
        // main-actor isolation there crashed the extension on every right
        // click), so build the AppKit menu on the main queue.
        nonisolated(unsafe) var menu: NSMenu?
        nonisolated(unsafe) let handler = self
        Self.onMainQueue {
            MainActor.assumeIsolated {
                let built = NSMenu(title: "")
                let item = NSMenuItem(title: Self.menuTitle, action: #selector(uninstallSelection(_:)), keyEquivalent: "")
                item.target = handler
                item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
                built.addItem(item)
                menu = built
            }
        }
        return menu
    }

    private static func onMainQueue(_ work: () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    @objc private func uninstallSelection(_ sender: Any?) {
        guard let host,
              let selection = FIFinderSyncController.default().selectedItemURLs() else { return }
        let applications = FinderUninstallHandoff.applicationURLs(for: selection)
        guard !applications.isEmpty else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Open the selected .app files with this exact host: an open-documents
        // event that a web page cannot start.
        NSWorkspace.shared.open(applications, withApplicationAt: host, configuration: configuration)
    }

    private static var menuTitle: String {
        let preferred = Locale.preferredLanguages.first ?? ""
        return preferred.hasPrefix("zh") ? "用存储清理助手卸载" : "Uninstall with Storage Cleaner"
    }
}
