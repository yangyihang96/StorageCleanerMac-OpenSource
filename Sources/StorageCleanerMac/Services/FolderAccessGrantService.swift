import Foundation

enum FolderAccessGrantService {
    static let bookmarksDefaultsKey = "folderAccess.securityScopedBookmarks.v1"
    static let initialPromptDefaultsKey = "folderAccess.initialPromptShown.v1"
    private static let restoreActivityLock = NSLock()
    private static let bookmarkStoreLock = NSLock()

    @discardableResult
    static func saveAccess(for urls: [URL], defaults: UserDefaults = .standard) -> Int {
        var newBookmarks = [String: String]()
        var savedCount = 0

        for url in urls {
            let standardizedURL = url.standardizedFileURL
            let path = PathSafety.normalizedPath(standardizedURL.path)
            guard isAllowedGrantPath(path) else { continue }

            do {
                let data = try standardizedURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                newBookmarks[path] = data.base64EncodedString()
                savedCount += 1
            } catch {
                continue
            }
        }

        if !newBookmarks.isEmpty {
            withBookmarkStoreLock {
                var bookmarks = rawSavedBookmarkStrings(defaults: defaults)
                bookmarks.merge(newBookmarks) { _, new in new }
                defaults.set(bookmarks, forKey: bookmarksDefaultsKey)
            }
        }
        return savedCount
    }

    @discardableResult
    static func restoreSavedAccess(defaults: UserDefaults = .standard) -> [String] {
        // Bookmark resolution is synchronous and can block on a disconnected
        // FileProvider. Never queue more blocking workers behind an existing
        // restore; a later readiness pass can retry after this one finishes.
        guard restoreActivityLock.try() else { return [] }
        defer { restoreActivityLock.unlock() }

        let bookmarks = savedBookmarkStrings(defaults: defaults)
        guard !bookmarks.isEmpty else { return [] }

        var restored = [String]()
        var removals = [(path: String, originalValue: String)]()
        var replacements = [(
            originalPath: String,
            originalValue: String,
            refreshedPath: String,
            refreshedValue: String
        )]()

        for (path, encodedBookmark) in bookmarks {
            guard let data = Data(base64Encoded: encodedBookmark) else {
                removals.append((path, encodedBookmark))
                continue
            }

            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                guard url.startAccessingSecurityScopedResource() else { continue }

                let normalizedPath = PathSafety.normalizedPath(url.standardizedFileURL.path)
                restored.append(normalizedPath)

                if isStale {
                    let refreshedData = try url.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    replacements.append((
                        originalPath: path,
                        originalValue: encodedBookmark,
                        refreshedPath: normalizedPath,
                        refreshedValue: refreshedData.base64EncodedString()
                    ))
                }
            } catch {
                removals.append((path, encodedBookmark))
            }
        }

        if !removals.isEmpty || !replacements.isEmpty {
            withBookmarkStoreLock {
                var currentBookmarks = rawSavedBookmarkStrings(defaults: defaults)

                for removal in removals
                    where currentBookmarks[removal.path] == removal.originalValue {
                    currentBookmarks.removeValue(forKey: removal.path)
                }

                for replacement in replacements
                    where currentBookmarks[replacement.originalPath] == replacement.originalValue {
                    currentBookmarks.removeValue(forKey: replacement.originalPath)
                    if replacement.refreshedPath == replacement.originalPath
                        || currentBookmarks[replacement.refreshedPath] == nil {
                        currentBookmarks[replacement.refreshedPath] = replacement.refreshedValue
                    }
                }

                defaults.set(currentBookmarks, forKey: bookmarksDefaultsKey)
            }
        }

        return restored.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func savedAccessPaths(defaults: UserDefaults = .standard) -> [String] {
        savedBookmarkStrings(defaults: defaults)
            .keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Returns the original sandbox-extension payloads so a scoped operation
    /// can resolve, start and stop access around its own I/O. Reconstructing a
    /// plain file URL from the saved path loses that authorization context.
    static func savedAccessBookmarkData(defaults: UserDefaults = .standard) -> [Data] {
        savedBookmarkStrings(defaults: defaults)
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .compactMap { Data(base64Encoded: $0.value) }
    }

    static func hasSavedAccess(
        for path: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let normalizedPath = PathSafety.normalizedPath(path)
        return savedAccessPaths(defaults: defaults).contains { savedPath in
            normalizedPath == savedPath || normalizedPath.hasPrefix(savedPath + "/")
        }
    }

    static func shouldShowInitialPrompt(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: initialPromptDefaultsKey) && savedAccessPaths(defaults: defaults).isEmpty
    }

    static func markInitialPromptShown(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: initialPromptDefaultsKey)
    }

    static func reset(defaults: UserDefaults = .standard) {
        withBookmarkStoreLock {
            defaults.removeObject(forKey: bookmarksDefaultsKey)
            defaults.removeObject(forKey: initialPromptDefaultsKey)
        }
    }

    private static func savedBookmarkStrings(defaults: UserDefaults) -> [String: String] {
        withBookmarkStoreLock {
            rawSavedBookmarkStrings(defaults: defaults)
        }
    }

    private static func rawSavedBookmarkStrings(defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: bookmarksDefaultsKey) as? [String: String] ?? [:]
    }

    private static func withBookmarkStoreLock<T>(_ operation: () -> T) -> T {
        bookmarkStoreLock.lock()
        defer { bookmarkStoreLock.unlock() }
        return operation()
    }

    private static func isAllowedGrantPath(_ path: String) -> Bool {
        path != "/" && PathSafety.isInsideHome(path)
    }
}
