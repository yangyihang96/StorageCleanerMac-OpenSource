import Foundation

struct DirectoryApplicationScanner: Sendable {
    private let fileManagerFactory: @Sendable () -> FileManager

    init(fileManagerFactory: @escaping @Sendable () -> FileManager = { FileManager() }) {
        self.fileManagerFactory = fileManagerFactory
    }

    func scan(_ directories: [ApplicationScanDirectory]) async throws -> [URL] {
        let fileManagerFactory = self.fileManagerFactory
        return try await Task.detached(priority: .utility) {
            let fileManager = fileManagerFactory()
            var discovered = [String: URL]()

            for directory in Self.nonRedundantDirectories(directories) {
                try Task.checkCancellation()
                guard fileManager.fileExists(atPath: directory.url.path) else { continue }

                let didStartSecurityScope: Bool
                if directory.requiresSecurityScopedAccess {
                    didStartSecurityScope = directory.url.startAccessingSecurityScopedResource()
                    guard didStartSecurityScope else {
                        throw ApplicationScanningError.securityScopedAccessDenied(directory.url.path)
                    }
                } else {
                    didStartSecurityScope = false
                }
                defer {
                    if didStartSecurityScope {
                        directory.url.stopAccessingSecurityScopedResource()
                    }
                }

                try Self.enumerate(
                    directory,
                    fileManager: fileManager,
                    discovered: &discovered
                )
            }

            return discovered.values.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        }.value
    }

    func externalVolumeDirectories(maximumDepth: Int) -> [ApplicationScanDirectory] {
        let fileManager = fileManagerFactory()
        let keys: [URLResourceKey] = [
            .volumeIsInternalKey,
            .volumeIsReadOnlyKey,
            .volumeIsBrowsableKey,
            .volumeNameKey,
        ]
        let volumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return volumes.compactMap { volumeURL in
            guard let values = try? volumeURL.resourceValues(forKeys: Set(keys)),
                  values.volumeIsInternal == false,
                  values.volumeIsReadOnly != true,
                  values.volumeIsBrowsable != false,
                  !Self.isExcludedExternalVolume(url: volumeURL, name: values.volumeName)
            else {
                return nil
            }
            return ApplicationScanDirectory(
                url: volumeURL,
                maximumDepth: max(1, maximumDepth)
            )
        }
    }

    private static func enumerate(
        _ directory: ApplicationScanDirectory,
        fileManager: FileManager,
        discovered: inout [String: URL]
    ) throws {
        let root = directory.url.standardizedFileURL
        let rootDepth = root.pathComponents.count
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .isReadableKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return
        }

        while let candidate = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let depth = candidate.pathComponents.count - rootDepth
            if let maximumDepth = directory.maximumDepth, depth > maximumDepth {
                enumerator.skipDescendants()
                continue
            }

            guard candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                continue
            }
            enumerator.skipDescendants()
            let key = ApplicationPathNormalizer.comparisonKey(for: candidate)
            discovered[key] = candidate.standardizedFileURL
        }

        if root.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            discovered[ApplicationPathNormalizer.comparisonKey(for: root)] = root
        }
    }

    private static func nonRedundantDirectories(
        _ directories: [ApplicationScanDirectory]
    ) -> [ApplicationScanDirectory] {
        var seen = Set<String>()
        return directories.filter { directory in
            seen.insert(ApplicationPathNormalizer.comparisonKey(for: directory.url)).inserted
        }
    }

    private static func isExcludedExternalVolume(url: URL, name: String?) -> Bool {
        let normalizedName = (name ?? url.lastPathComponent).lowercased()
        let excludedNames = [
            "recovery",
            "preboot",
            "vm",
            "update",
            "time machine backups",
            "backups.backupdb",
            "com.apple.timemachine",
        ]
        return excludedNames.contains { normalizedName == $0 || normalizedName.contains($0) }
    }
}
