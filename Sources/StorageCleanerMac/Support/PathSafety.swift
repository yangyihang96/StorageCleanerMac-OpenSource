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

    static func isLexicallyInsideHome(_ path: String) -> Bool {
        let lexical = lexicalPath(path)
        let home = lexicalHomePath
        return lexical == home || lexical.hasPrefix(home + "/")
    }

    static func isInsideHome(_ path: String) -> Bool {
        let normalized = normalizedPath(path)
        let home = homePath
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

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
