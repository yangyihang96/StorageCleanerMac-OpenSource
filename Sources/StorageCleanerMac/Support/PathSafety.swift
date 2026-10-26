import Foundation

enum PathSafety {
    static var lexicalHomePath: String {
        lexicalPath(FileManager.default.homeDirectoryForCurrentUser.path)
    }

    static var homePath: String {
        normalizedPath(FileManager.default.homeDirectoryForCurrentUser.path)
    }

    static var temporaryRootPaths: [String] {
        var seen = Set<String>()
        return ["/private/tmp", NSTemporaryDirectory()]
            .map(normalizedPath)
            .filter { $0 != "/" && seen.insert($0).inserted }
    }

    static func lexicalPath(_ path: String) -> String {
        let expanded: String
        if path == "~" {
            expanded = NSHomeDirectory()
        } else if path.hasPrefix("~/") {
            expanded = NSHomeDirectory() + String(path.dropFirst())
        } else {
            expanded = path
        }

        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .path
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: lexicalPath(path))
            .resolvingSymlinksInPath()
            .path
    }

    static func isLexicallyInsideHome(_ path: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let lexical = lexicalPath(path)
        let home = lexicalPath(homeDirectory.path)
        return lexical == home || lexical.hasPrefix(home + "/")
    }

    static func isInsideHome(_ path: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let normalized = normalizedPath(path)
        let home = normalizedPath(homeDirectory.path)
        return normalized == home || normalized.hasPrefix(home + "/")
    }

    static func isInsideApplications(_ path: String) -> Bool {
        let normalized = normalizedPath(path)
        return normalized == "/Applications" || normalized.hasPrefix("/Applications/")
    }

    static func isInsideTemporaryRoots(_ path: String) -> Bool {
        let normalized = normalizedPath(path)
        return temporaryRootPaths.contains { root in
            normalized == root || normalized.hasPrefix(root + "/")
        }
    }

    static func isContained(
        _ path: String,
        in rootPath: String,
        resolvingSymlinks: Bool
    ) -> Bool {
        let candidate = resolvingSymlinks ? normalizedPath(path) : lexicalPath(path)
        let root = resolvingSymlinks ? normalizedPath(rootPath) : lexicalPath(rootPath)
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    /// D116 (G12): a root whose written and resolved forms are worked out once,
    /// for the checks a walk repeats on every entry. While the root stays put,
    /// it answers exactly as `isContained(_:in:resolvingSymlinks:)` does. A
    /// root that is moved or relinked during the walk keeps the boundary it
    /// had when the walk began, so entries reached through the new link are
    /// still outside.
    struct ContainmentRoot: Equatable, Sendable {
        let lexical: String
        let resolved: String

        init(_ rootPath: String) {
            lexical = PathSafety.lexicalPath(rootPath)
            resolved = PathSafety.normalizedPath(rootPath)
        }

        func contains(_ path: String, resolvingSymlinks: Bool) -> Bool {
            resolvingSymlinks
                ? Self.contains(PathSafety.normalizedPath(path), in: resolved)
                : Self.contains(PathSafety.lexicalPath(path), in: lexical)
        }

        /// Both checks, as written and with links resolved, working out the
        /// path's written form once; the resolved check runs only when the
        /// written one passes.
        func containsAsWrittenAndResolved(_ path: String) -> Bool {
            let written = PathSafety.lexicalPath(path)
            guard Self.contains(written, in: lexical) else { return false }
            // The same as `normalizedPath(path)`, which starts from this written form.
            return Self.contains(URL(fileURLWithPath: written).resolvingSymlinksInPath().path, in: resolved)
        }

        private static func contains(_ candidate: String, in root: String) -> Bool {
            candidate == root || candidate.hasPrefix(root + "/")
        }
    }

    static func containsSymbolicLinkComponent(
        in path: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let components = URL(fileURLWithPath: lexicalPath(path)).pathComponents
        var current = URL(fileURLWithPath: "/", isDirectory: true)

        for component in components.dropFirst() {
            current.appendPathComponent(component)
            guard let attributes = try? fileManager.attributesOfItem(atPath: current.path),
                  let fileType = attributes[.type] as? FileAttributeType else {
                return true
            }
            if fileType == .typeSymbolicLink {
                return true
            }
        }
        return false
    }
}
