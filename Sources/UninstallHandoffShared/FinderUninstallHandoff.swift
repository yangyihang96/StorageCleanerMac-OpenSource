import Foundation

/// Finder -> main application handoff for "Uninstall with Storage Cleaner"
/// (D88). It only carries candidate application paths. It is not an
/// uninstall command: the main application resolves every path against its
/// own inventory and opens the existing review sheet, where identity,
/// ownership and confirmation are checked as for an in-app selection.
///
/// Transport (D88 修复轮 1): there is no public URL scheme. The extension
/// opens the selected `.app` file URLs with its own host application
/// (`NSWorkspace.open(_:withApplicationAt:configuration:)`), which arrives as
/// an open-documents event (`application(_:open:)`). A web page cannot start
/// that. Dragging an `.app` onto the Dock icon or "Open With" reaches the
/// same path and only opens the review.
public enum FinderUninstallHandoff {
    public static let maximumApplications = 32
    public static let maximumPathLength = 1024
    /// The only host the Finder entry serves: the installed Beta. Copies in
    /// build, QA, staging or `.previous` folders never show the menu.
    public static let installedBetaHostPath = "/Applications/测试版.app"

    public enum Rejection: String, Sendable, Equatable, CaseIterable {
        case notFileURL
        case notApplicationBundle
        case unnormalizedPath
        case pathTooLong
        case overLimit
    }

    public struct Rejected: Sendable, Equatable {
        public let path: String
        public let reason: Rejection
        public init(path: String, reason: Rejection) {
            self.path = path
            self.reason = reason
        }
    }

    public struct Request: Sendable, Equatable {
        /// Distinct, lexically normalized absolute `.app` paths in selection order.
        public let paths: [String]
        public let rejected: [Rejected]
        public init(paths: [String], rejected: [Rejected]) {
            self.paths = paths
            self.rejected = rejected
        }
    }

    /// Both sides. Does not touch the file system: existence, aliases,
    /// directories, signatures and running state are decided by the main
    /// application off the main thread.
    public static func request(for selection: [URL]) -> Request {
        var paths: [String] = []
        var rejected: [Rejected] = []
        for url in selection {
            guard url.isFileURL else {
                rejected.append(.init(path: String(url.absoluteString.prefix(80)), reason: .notFileURL))
                continue
            }
            classify(url.path, into: &paths, rejected: &rejected)
        }
        return Request(paths: paths, rejected: rejected)
    }

    /// Extension side: the `.app` directory URLs to open with the host;
    /// empty when nothing in the selection is a candidate (no menu item).
    public static func applicationURLs(for selection: [URL]) -> [URL] {
        request(for: selection).paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Extension side: the host application to hand requests to, only when
    /// this extension sits at `<installed Beta>/Contents/PlugIns/<name>.appex`.
    /// Any other location (a build folder, a QA copy, `.previous`, or a
    /// release-identity bundle) returns `nil`, so the menu is not shown and
    /// nothing is opened.
    public static func hostApplication(forExtensionAt extensionURL: URL) -> URL? {
        guard extensionURL.isFileURL,
              let path = normalizedApplicationPath(extensionURL.path) else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 4,
              components[components.count - 1].lowercased().hasSuffix(".appex"),
              components[components.count - 1].count > 6,
              components[components.count - 2] == "PlugIns",
              components[components.count - 3] == "Contents" else { return nil }
        let host = "/" + components.dropLast(3).joined(separator: "/")
        guard host == installedBetaHostPath else { return nil }
        return URL(fileURLWithPath: installedBetaHostPath, isDirectory: true)
    }

    /// Absolute, already-normalized `.app` path: no empty, `.` or `..`
    /// components and no NUL. A trailing slash (Finder adds one for bundles)
    /// is dropped. Symbolic links and aliases are resolved only by the main
    /// application.
    public static func normalizedApplicationPath(_ path: String) -> String? {
        var value = path
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        guard value.hasPrefix("/"), !value.contains("\0") else { return nil }
        let components = value.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return value
    }

    public static func isApplicationBundlePath(_ path: String) -> Bool {
        guard let last = path.split(separator: "/").last else { return false }
        return last.count > 4 && last.lowercased().hasSuffix(".app")
    }

    private static func classify(_ path: String, into paths: inout [String], rejected: inout [Rejected]) {
        guard path.utf8.count <= maximumPathLength else {
            rejected.append(.init(path: String(path.prefix(80)), reason: .pathTooLong))
            return
        }
        guard let normalized = normalizedApplicationPath(path) else {
            rejected.append(.init(path: path, reason: .unnormalizedPath))
            return
        }
        guard isApplicationBundlePath(normalized) else {
            rejected.append(.init(path: normalized, reason: .notApplicationBundle))
            return
        }
        guard !paths.contains(normalized) else { return }
        guard paths.count < maximumApplications else {
            rejected.append(.init(path: normalized, reason: .overLimit))
            return
        }
        paths.append(normalized)
    }
}
