import AppKit
import Foundation

/// D101 G9: an uninstaller that the app's own developer ships beside the app
/// or inside its bundle. It is found read-only and opened only when the user
/// clicks; the app does not continue any deletion of its own afterwards.
struct VendorUninstaller: Equatable, Sendable {
    let url: URL
    let teamIdentifier: String

    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Names only; the service checks the signatures.
enum VendorUninstallerLocator {
    /// How deep below `Contents` an uninstaller may sit, and how many
    /// entries of the bundle are looked at.
    static let bundleDepth = 3
    static let bundleEntryLimit = 5_000

    /// Folders that hold many unrelated apps. An uninstaller beside the app
    /// in one of them must also name the app.
    static func sharedFolders(homeDirectory: URL) -> [String] {
        ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
         homeDirectory.appendingPathComponent("Applications").path].map(PathSafety.lexicalPath)
    }

    static func isUninstallerName(_ name: String) -> Bool {
        name.range(of: "uninstall", options: .caseInsensitive) != nil || name.contains("卸载")
    }

    /// `.app` folders whose names say they uninstall, beside the app and
    /// inside its bundle. Links are not followed.
    static func candidates(for appURL: URL, sharedFolders: [String],
                           fileManager: FileManager = .default) -> [URL] {
        let app = URL(fileURLWithPath: PathSafety.lexicalPath(appURL.path), isDirectory: true)
        let appName = app.deletingPathExtension().lastPathComponent
        let parent = app.deletingLastPathComponent()
        let inSharedFolder = sharedFolders.contains(PathSafety.lexicalPath(parent.path))
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]

        var beside: [URL] = []
        let siblings = (try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: keys,
                                                             options: .skipsHiddenFiles)) ?? []
        for sibling in siblings where isPlainApplicationFolder(sibling) {
            let name = sibling.deletingPathExtension().lastPathComponent
            guard PathSafety.lexicalPath(sibling.path) != app.path, isUninstallerName(name),
                  !inSharedFolder || name.range(of: appName, options: .caseInsensitive) != nil else { continue }
            beside.append(sibling)
        }

        var inside: [URL] = []
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        if let walker = fileManager.enumerator(at: contents, includingPropertiesForKeys: keys,
                                               options: .skipsHiddenFiles) {
            var visited = 0
            for case let entry as URL in walker {
                visited += 1
                guard visited <= bundleEntryLimit else { break }
                guard entry.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                    if walker.level >= bundleDepth { walker.skipDescendants() }
                    continue
                }
                walker.skipDescendants()
                if isPlainApplicationFolder(entry), isUninstallerName(entry.deletingPathExtension().lastPathComponent) {
                    inside.append(entry)
                }
            }
        }
        return beside.sorted { $0.path < $1.path } + inside.sorted { $0.path < $1.path }
    }

    /// A real `.app` folder, not a link to one. Read afresh: a URL caches
    /// the values it has read, and the check before opening must see now.
    static func isPlainApplicationFolder(_ url: URL) -> Bool {
        let fresh = URL(fileURLWithPath: url.path)
        guard fresh.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let values = try? fresh.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}

struct VendorUninstallerService: Sendable {
    enum OpenOutcome: Equatable, Sendable {
        case opened
        /// The uninstaller moved, became a link, or its signature no longer
        /// matches the app's developer; it was not opened.
        case changed
        case failed
    }

    var signatures: any ApplicationCodeSignatureInspecting = SecurityFrameworkApplicationCodeSignatureInspector()
    /// Starts the uninstaller; called only from `open(_:)`.
    var openApplication: @Sendable (URL) async throws -> Void = { url in
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Nil means `VendorUninstallerLocator.sharedFolders(homeDirectory:)`.
    var sharedFolders: [String]?

    /// Read-only, and signatures are read only when a name matches. An
    /// uninstaller counts only when it and the app both have valid,
    /// Apple-anchored signatures with the same Team ID.
    func uninstaller(forApplicationAt appURL: URL) async -> VendorUninstaller? {
        let folders = sharedFolders ?? VendorUninstallerLocator.sharedFolders(homeDirectory: homeDirectory)
        let candidates = await Task.detached(priority: .utility) {
            VendorUninstallerLocator.candidates(for: appURL, sharedFolders: folders)
        }.value
        guard !candidates.isEmpty, let team = await trustedTeam(at: appURL) else { return nil }
        for candidate in candidates {
            if await trustedTeam(at: candidate) == team {
                return VendorUninstaller(url: candidate, teamIdentifier: team)
            }
        }
        return nil
    }

    /// Only on the user's click: the signature is read again, then the
    /// uninstaller is opened. Nothing else follows.
    func open(_ uninstaller: VendorUninstaller) async -> OpenOutcome {
        guard VendorUninstallerLocator.isPlainApplicationFolder(uninstaller.url),
              await trustedTeam(at: uninstaller.url) == uninstaller.teamIdentifier else { return .changed }
        do {
            try await openApplication(uninstaller.url)
            return .opened
        } catch {
            return .failed
        }
    }

    private func trustedTeam(at url: URL) async -> String? {
        let signature = await signatures.inspectSignature(at: url)
        guard signature.isValid else { return nil }
        return signature.signingTeamIdentifier?.trimmed.nonEmpty
    }
}

/// The uninstall page's state for G9. It never refers to the uninstall flow,
/// so opening the vendor's uninstaller cannot start a deletion here.
@MainActor
final class VendorUninstallerController: ObservableObject {
    @Published private(set) var uninstaller: VendorUninstaller?
    @Published private(set) var message: String?
    @Published private(set) var isOpening = false
    private let service: VendorUninstallerService
    private var applicationPath: String?

    init(service: VendorUninstallerService = VendorUninstallerService()) {
        self.service = service
    }

    /// Looks for the app's uninstaller; never opens anything. Nil clears it
    /// (leftover review, where the app is already in the Trash).
    func load(applicationPath path: String?) async {
        applicationPath = path
        uninstaller = nil
        message = nil
        guard let path else { return }
        let found = await service.uninstaller(forApplicationAt: URL(fileURLWithPath: path, isDirectory: true))
        guard !Task.isCancelled, applicationPath == path else { return }
        uninstaller = found
    }

    /// The Open Uninstaller button's action.
    func open() async {
        guard let uninstaller, !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        switch await service.open(uninstaller) {
        case .opened:
            message = L10n.text(
                "已打开“\(uninstaller.name)”。请按它的提示完成卸载；本应用不会接着删除任何文件。",
                "Opened “\(uninstaller.name)”. Follow its steps to uninstall; this app does not go on to delete anything."
            )
        case .changed:
            self.uninstaller = nil
            message = L10n.text("卸载程序已变化，或签名与此应用的开发者不再一致，未打开。",
                                "The uninstaller changed or no longer matches this app's developer, so it was not opened.")
        case .failed:
            message = L10n.text("无法打开卸载程序。", "The uninstaller could not be opened.")
        }
    }
}
