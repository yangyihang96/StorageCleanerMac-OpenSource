import Darwin
import Foundation

/// Finds review leads in a few volatile Library locations. A missing installed
/// bundle identifier is never proof of ownership or permission to remove data.
struct ResidualFileEvidenceScanner {
    struct Candidate: Identifiable, Hashable, Sendable {
        let path: String
        let bundleIdentifier: String
        let location: String
        let modifiedAt: Date?

        var id: String { path }
    }

    struct Result: Sendable {
        let candidates: [Candidate]
        let inspectedEntryCount: Int
        let unreadableRootCount: Int
        let reachedLimit: Bool
        let cancelled: Bool
    }

    private static let relativeRoots: [(path: String, title: String)] = [
        ("Library/Caches", "Caches"),
        ("Library/Logs", "Logs"),
        ("Library/Saved Application State", "Saved Application State"),
        ("Library/HTTPStorages", "HTTPStorages")
    ]

    static func scan(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        installedBundleIdentifiers: Set<String>,
        maximumEntries: Int = 4_000,
        maximumSeconds: TimeInterval = 5
    ) -> Result {
        let home = homeDirectory.standardizedFileURL
        let knownIDs = Set(installedBundleIdentifiers.map { $0.lowercased() })
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.1, maximumSeconds)
        var candidates: [Candidate] = []
        var inspected = 0
        var unreadableRoots = 0
        var reachedLimit = false
        var cancelled = false

        for root in relativeRoots {
            if Task<Never, Never>.isCancelled {
                cancelled = true
                break
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                reachedLimit = true
                break
            }
            let rootURL = home.appendingPathComponent(root.path, isDirectory: true)
            if !FileManager.default.fileExists(atPath: rootURL.path) {
                continue
            }
            guard isSafeDirectoryChain(from: home, relativePath: root.path) else {
                unreadableRoots += 1
                continue
            }
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: rootURL,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                unreadableRoots += 1
                continue
            }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if Task<Never, Never>.isCancelled {
                    cancelled = true
                    break
                }
                if inspected >= maximumEntries || ProcessInfo.processInfo.systemUptime >= deadline {
                    reachedLimit = true
                    break
                }
                inspected += 1
                guard isRegularItemWithoutSymlink(entry),
                      let bundleID = candidateBundleIdentifier(from: entry.lastPathComponent),
                      !isCoveredByInstalledApp(bundleID, knownIDs: knownIDs) else {
                    continue
                }
                let modifiedAt = try? entry.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
                candidates.append(Candidate(
                    path: entry.path,
                    bundleIdentifier: bundleID,
                    location: root.title,
                    modifiedAt: modifiedAt
                ))
            }
            if cancelled || reachedLimit { break }
        }

        return Result(
            candidates: candidates,
            inspectedEntryCount: inspected,
            unreadableRootCount: unreadableRoots,
            reachedLimit: reachedLimit,
            cancelled: cancelled
        )
    }

    private static func candidateBundleIdentifier(from name: String) -> String? {
        var value = name.lowercased()
        for suffix in [".savedstate", ".plist", ".log"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
            break
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              parts[0] != "apple",
              !value.hasPrefix("com.apple."),
              parts.allSatisfy({ component in
                  !component.isEmpty && component.utf8.allSatisfy { byte in
                      (byte >= 97 && byte <= 122)
                          || (byte >= 48 && byte <= 57)
                          || byte == 45
                  }
              }) else {
            return nil
        }
        return value
    }

    private static func isCoveredByInstalledApp(
        _ candidate: String,
        knownIDs: Set<String>
    ) -> Bool {
        knownIDs.contains { installed in
            candidate == installed
                || candidate.hasPrefix(installed + ".")
                || installed.hasPrefix(candidate + ".")
        }
    }

    private static func isSafeDirectoryChain(from home: URL, relativePath: String) -> Bool {
        guard isDirectoryWithoutSymlink(home) else { return false }
        var current = home
        for part in relativePath.split(separator: "/") {
            current.appendPathComponent(String(part), isDirectory: true)
            guard isDirectoryWithoutSymlink(current) else { return false }
        }
        return true
    }

    private static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isRegularItemWithoutSymlink(_ url: URL) -> Bool {
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return false }
        let kind = info.st_mode & S_IFMT
        return kind == S_IFREG || kind == S_IFDIR
    }
}
