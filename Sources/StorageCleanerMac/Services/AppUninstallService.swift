import Foundation
import Darwin
import os

enum AppUninstallError: LocalizedError {
    case notAllowed(String)
    case missingApp(String)
    case identityChanged(String)
    case moveNotVerified(String)

    var errorDescription: String? {
        switch self {
        case let .notAllowed(path):
            L10n.text("不能从这里卸载这个应用：\(path)", "This app cannot be uninstalled here: \(path)")
        case let .missingApp(path):
            L10n.text("应用已经不存在：\(path)", "The app no longer exists: \(path)")
        case let .identityChanged(path):
            L10n.text(
                "应用在扫描后已经发生变化，请重新扫描后再确认：\(path)",
                "The app changed after scanning. Rescan before confirming: \(path)"
            )
        case let .moveNotVerified(path):
            L10n.text(
                "无法确认应用已经移入废纸篓：\(path)",
                "The app could not be confirmed in Trash: \(path)"
            )
        }
    }
}

struct AppUninstallTrashResult: Equatable, Sendable {
    let movedAppBytes: Int64
    let movedRelatedItems: [InstalledAppRelatedItem]
    let skippedRelatedPaths: [String]
    let failedRelatedPaths: [String]

    var movedRelatedBytes: Int64 {
        movedRelatedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var movedBytes: Int64 {
        movedAppBytes + movedRelatedBytes
    }

    var movedItemCount: Int {
        (movedAppBytes > 0 ? 1 : 0) + movedRelatedItems.count
    }

    var unresolvedRelatedCount: Int {
        skippedRelatedPaths.count + failedRelatedPaths.count
    }
}

struct AppUninstallScanCoverage: Equatable, Sendable {
    let discoveredCandidateCount: Int
    let examinedCandidateCount: Int
    let didReachCandidateLimit: Bool
    let didReachTimeLimit: Bool
    let didReachResultLimit: Bool

    var isComplete: Bool {
        !didReachCandidateLimit && !didReachTimeLimit && !didReachResultLimit
    }
}

struct AppUninstallScanResult: Sendable {
    let apps: [InstalledAppItem]
    let coverage: AppUninstallScanCoverage
}

enum AppUninstallService {
    private static let defaultInventoryConcurrency = 4
    private static let spotlightDateFormatter = OSAllocatedUnfairLock(
        initialState: {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            return formatter
        }()
    )

    static func scanInstalledApps(
        limit: Int = 500,
        timeLimit: TimeInterval = 30
    ) -> [InstalledAppItem] {
        scanInstalledAppsResult(limit: limit, timeLimit: timeLimit).apps
    }

    static func scanInstalledAppsResult(
        limit: Int = 500,
        timeLimit: TimeInterval = 30
    ) -> AppUninstallScanResult {
        let folders = [
            (path: "/Applications", source: L10n.text("系统应用目录", "System Applications")),
            (path: "\(NSHomeDirectory())/Applications", source: L10n.text("用户应用目录", "User Applications"))
        ]
        let deadline = Date().addingTimeInterval(max(1, timeLimit))
        var candidates = [(url: URL, source: String)]()

        for folder in folders {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: folder.path),
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            candidates.append(contentsOf: urls.compactMap { url in
                guard url.pathExtension == "app" else { return nil }
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values?.isSymbolicLink != true else { return nil }
                return (url, folder.source)
            })
        }

        // Metadata and recursive sizes are the expensive part. A generous
        // candidate cap plus a total deadline keeps the utility responsive on
        // stalled FileProvider volumes without affecting normal app folders.
        let candidateLimit = max(limit * 2, limit)
        let orderedCandidates = Array(candidates
            .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
            .prefix(candidateLimit))
        var apps = [InstalledAppItem]()
        apps.reserveCapacity(min(limit, orderedCandidates.count))
        var examinedCandidateCount = 0
        for candidate in orderedCandidates {
            guard Date() < deadline else { break }
            apps.append(appItem(for: candidate.url, source: candidate.source, deadline: deadline))
            examinedCandidateCount += 1
        }

        let sortedApps = apps.sorted {
            if $0.sizeBytes == $1.sizeBytes {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.sizeBytes > $1.sizeBytes
        }
        return AppUninstallScanResult(
            apps: Array(sortedApps.prefix(limit)),
            coverage: AppUninstallScanCoverage(
                discoveredCandidateCount: candidates.count,
                examinedCandidateCount: examinedCandidateCount,
                didReachCandidateLimit: orderedCandidates.count < candidates.count,
                didReachTimeLimit: examinedCandidateCount < orderedCandidates.count,
                didReachResultLimit: sortedApps.count > limit
            )
        )
    }

    /// Reuses the same recursive application inventory used by Software Update.
    /// This keeps nested collections such as `/Applications/Setapp` visible
    /// without introducing a second application-directory crawler.
    static func scanInstalledAppsFromSharedInventory(
        directories: [ApplicationScanDirectory]? = nil,
        limit: Int = 500,
        timeLimit: TimeInterval = 30,
        maximumConcurrency: Int? = nil
    ) async -> AppUninstallScanResult {
        let discoveredURLs: [URL]
        do {
            discoveredURLs = try await DirectoryApplicationScanner().scan(
                directories ?? defaultInventoryDirectories()
            )
        } catch {
            return AppUninstallScanResult(
                apps: [],
                coverage: AppUninstallScanCoverage(
                    discoveredCandidateCount: 0,
                    examinedCandidateCount: 0,
                    didReachCandidateLimit: false,
                    didReachTimeLimit: true,
                    didReachResultLimit: false
                )
            )
        }

        let candidates = discoveredURLs.compactMap { url -> (url: URL, source: String)? in
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { return nil }
            return (url.standardizedFileURL, inventorySource(for: url))
        }
        return await scanInstalledAppsResult(
            candidates: candidates,
            limit: limit,
            timeLimit: timeLimit,
            maximumConcurrency: maximumConcurrency ?? defaultInventoryConcurrency
        )
    }

    private static func defaultInventoryDirectories() -> [ApplicationScanDirectory] {
        [
            ApplicationScanDirectory(
                url: URL(fileURLWithPath: "/Applications", isDirectory: true),
                maximumDepth: 4
            ),
            // Setapp marks its collection folder as a package-like directory.
            // The parent enumeration correctly skips package descendants, so
            // add the collection itself as a root for the same shared scanner.
            ApplicationScanDirectory(
                url: URL(fileURLWithPath: "/Applications/Setapp", isDirectory: true),
                maximumDepth: 2
            ),
            ApplicationScanDirectory(
                url: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications", isDirectory: true),
                maximumDepth: 4
            )
        ]
    }

    private static func inventorySource(for url: URL) -> String {
        let path = PathSafety.normalizedPath(url.path)
        let homeApplications = PathSafety.normalizedPath(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
                .path
        )
        if path.hasPrefix("/Applications/Setapp/") {
            return L10n.text("Setapp 管理目录", "Setapp Managed Collection")
        }
        if path == homeApplications || path.hasPrefix(homeApplications + "/") {
            return L10n.text("用户应用目录", "User Applications")
        }
        return L10n.text("系统应用目录", "System Applications")
    }

    private static func scanInstalledAppsResult(
        candidates: [(url: URL, source: String)],
        limit: Int,
        timeLimit: TimeInterval,
        maximumConcurrency: Int
    ) async -> AppUninstallScanResult {
        let deadline = Date().addingTimeInterval(max(1, timeLimit))
        let candidateLimit = max(limit * 2, limit)
        // Sort by app name instead of parent path so nested managed collections
        // cannot be starved when a bounded scan reaches its deadline.
        let orderedCandidates = Array(candidates
            .sorted { lhs, rhs in
                let nameOrder = lhs.url.lastPathComponent.localizedStandardCompare(
                    rhs.url.lastPathComponent
                )
                if nameOrder == .orderedSame {
                    return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
                }
                return nameOrder == .orderedAscending
            }
            .prefix(candidateLimit))
        let concurrency = max(1, min(maximumConcurrency, 8))

        var apps = [InstalledAppItem]()
        apps.reserveCapacity(min(limit, orderedCandidates.count))
        await withTaskGroup(of: InstalledAppItem?.self) { group in
            var nextCandidateIndex = 0

            while nextCandidateIndex < min(concurrency, orderedCandidates.count) {
                let candidate = orderedCandidates[nextCandidateIndex]
                group.addTask {
                    guard !Task.isCancelled, Date() < deadline else { return nil }
                    return appItem(for: candidate.url, source: candidate.source, deadline: deadline)
                }
                nextCandidateIndex += 1
            }

            while let app = await group.next() {
                if let app {
                    apps.append(app)
                }
                guard nextCandidateIndex < orderedCandidates.count,
                      Date() < deadline,
                      !Task.isCancelled else { continue }
                let candidate = orderedCandidates[nextCandidateIndex]
                group.addTask {
                    guard !Task.isCancelled, Date() < deadline else { return nil }
                    return appItem(for: candidate.url, source: candidate.source, deadline: deadline)
                }
                nextCandidateIndex += 1
            }
        }

        let sortedApps = apps.sorted {
            if $0.sizeBytes == $1.sizeBytes {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.sizeBytes > $1.sizeBytes
        }
        return AppUninstallScanResult(
            apps: Array(sortedApps.prefix(limit)),
            coverage: AppUninstallScanCoverage(
                discoveredCandidateCount: candidates.count,
                examinedCandidateCount: apps.count,
                didReachCandidateLimit: orderedCandidates.count < candidates.count,
                didReachTimeLimit: apps.count < orderedCandidates.count,
                didReachResultLimit: sortedApps.count > limit
            )
        )
    }

    static func enrichUninstallRecommendations(
        in apps: [InstalledAppItem],
        resolver: any AppStoreCatalogResolving = AppStoreCatalogResolver(),
        storefront: String = AppStoreCatalogResolver.currentStorefront
    ) async -> [InstalledAppItem] {
        var groupedApps = [AppUninstallSimilarityGroup: [InstalledAppItem]]()
        for app in apps {
            guard let group = AppUninstallSimilarityGroup.resolve(bundleIdentifier: app.bundleIdentifier) else { continue }
            groupedApps[group, default: []].append(app)
        }

        // ponytail: bound live Apple lookups; add a persistent cache before widening coverage.
        let bundleIdentifiers = Array(Set(groupedApps.values
            .filter { $0.count >= 2 }
            .flatMap { $0.map(\.bundleIdentifier) }
            .filter { !$0.trimmed.isEmpty }))
            .sorted()
            .prefix(16)

        guard !bundleIdentifiers.isEmpty else { return apps }
        var catalogEntries = [String: AppStoreCatalogEntry]()
        await withTaskGroup(of: (String, AppStoreCatalogEntry?).self) { group in
            for bundleIdentifier in bundleIdentifiers {
                group.addTask {
                    do {
                        guard case let .matched(entry) = try await resolver.resolve(
                            bundleIdentifier: bundleIdentifier,
                            storefront: storefront
                        ) else {
                            return (bundleIdentifier, nil)
                        }
                        return (bundleIdentifier, entry)
                    } catch {
                        return (bundleIdentifier, nil)
                    }
                }
            }

            for await (bundleIdentifier, entry) in group {
                if let entry {
                    catalogEntries[bundleIdentifier] = entry
                }
            }
        }

        return applyAppStoreRatings(catalogEntries, to: apps)
    }

    static func applyAppStoreRatings(
        _ catalogEntries: [String: AppStoreCatalogEntry],
        to apps: [InstalledAppItem],
        minimumRatingCount: Int = 25,
        minimumRatingGap: Double = 0.3
    ) -> [InstalledAppItem] {
        var enrichedApps = apps
        for index in enrichedApps.indices {
            guard let entry = catalogEntries[enrichedApps[index].bundleIdentifier],
                  let rating = entry.averageUserRating,
                  let ratingCount = entry.userRatingCount,
                  (0...5).contains(rating),
                  ratingCount >= 0 else { continue }
            enrichedApps[index].appStoreRating = rating
            enrichedApps[index].appStoreRatingCount = ratingCount
        }

        var groupedIndices = [AppUninstallSimilarityGroup: [Int]]()
        for index in enrichedApps.indices {
            guard let group = AppUninstallSimilarityGroup.resolve(
                bundleIdentifier: enrichedApps[index].bundleIdentifier
            ) else { continue }
            groupedIndices[group, default: []].append(index)
        }

        for (group, indices) in groupedIndices {
            let rated = indices.compactMap { index -> (index: Int, rating: Double, count: Int)? in
                guard let rating = enrichedApps[index].appStoreRating,
                      let count = enrichedApps[index].appStoreRatingCount,
                      count >= minimumRatingCount else { return nil }
                return (index, rating, count)
            }.sorted { lhs, rhs in
                if lhs.rating == rhs.rating { return lhs.count > rhs.count }
                return lhs.rating < rhs.rating
            }

            guard rated.count >= 2,
                  let lowest = rated.first,
                  let highest = rated.last,
                  highest.rating - lowest.rating >= minimumRatingGap,
                  rated[1].rating - lowest.rating >= 0.05,
                  !enrichedApps[lowest.index].isAppleApp,
                  enrichedApps[lowest.index].canMoveToTrash else { continue }

            enrichedApps[lowest.index].uninstallRatingComparison = AppUninstallRatingComparison(
                group: group,
                rating: lowest.rating,
                ratingCount: lowest.count,
                higherRatedAppName: enrichedApps[highest.index].name,
                higherRating: highest.rating,
                higherRatingCount: highest.count
            )
        }

        return enrichedApps
    }

    static func moveToTrash(_ app: InstalledAppItem) throws -> AppUninstallTrashResult {
        guard app.canMoveToTrash else {
            throw AppUninstallError.notAllowed(app.path)
        }

        guard FileManager.default.fileExists(atPath: app.path) else {
            throw AppUninstallError.missingApp(app.path)
        }

        try validateCurrentApplicationIdentity(app)

        var resultingURL: NSURL?
        try FileManager.default.trashItem(
            at: URL(fileURLWithPath: app.path),
            resultingItemURL: &resultingURL
        )
        guard !FileManager.default.fileExists(atPath: app.path) else {
            throw AppUninstallError.moveNotVerified(app.path)
        }

        return AppUninstallTrashResult(
            movedAppBytes: app.sizeBytes,
            movedRelatedItems: [],
            skippedRelatedPaths: [],
            failedRelatedPaths: []
        )
    }

    static func moveRelatedItemsToTrash(for app: InstalledAppItem) -> AppUninstallTrashResult {
        let appPath = PathSafety.normalizedPath(app.path)
        var movedRelatedItems = [InstalledAppRelatedItem]()
        var skippedRelatedPaths = [String]()
        var failedRelatedPaths = [String]()

        for item in app.relatedItems {
            let path = PathSafety.normalizedPath(item.path)
            guard path != appPath, !path.hasPrefix(appPath + "/"), isSafeRelatedPath(path) else {
                skippedRelatedPaths.append(item.path)
                continue
            }
            guard FileManager.default.fileExists(atPath: path) else {
                skippedRelatedPaths.append(item.path)
                continue
            }

            guard let currentIdentity = uninstallFileIdentity(at: path),
                  currentIdentity.entryKind != .symbolicLink,
                  item.scanIdentity.map({ $0 == currentIdentity }) ?? true else {
                failedRelatedPaths.append(item.path)
                continue
            }

            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: path),
                    resultingItemURL: &resultingURL
                )
                guard !FileManager.default.fileExists(atPath: path) else {
                    failedRelatedPaths.append(item.path)
                    continue
                }
                movedRelatedItems.append(item)
            } catch {
                failedRelatedPaths.append(item.path)
            }
        }

        return AppUninstallTrashResult(
            movedAppBytes: 0,
            movedRelatedItems: movedRelatedItems,
            skippedRelatedPaths: skippedRelatedPaths,
            failedRelatedPaths: failedRelatedPaths
        )
    }

    static func validateCurrentApplicationIdentity(_ app: InstalledAppItem) throws {
        guard let currentIdentity = uninstallFileIdentity(at: app.path),
              currentIdentity.entryKind == .directory else {
            throw AppUninstallError.identityChanged(app.path)
        }
        if let scanIdentity = app.scanIdentity, scanIdentity != currentIdentity {
            throw AppUninstallError.identityChanged(app.path)
        }

        let infoURL = URL(fileURLWithPath: app.path, isDirectory: true)
            .appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              (info["CFBundleIdentifier"] as? String ?? "") == app.bundleIdentifier,
              (info["CFBundleShortVersionString"] as? String ?? "") == app.version,
              (info["CFBundleVersion"] as? String ?? "") == app.build else {
            throw AppUninstallError.identityChanged(app.path)
        }
    }

    static func uninstallFileIdentity(at path: String) -> FileIdentity? {
        var metadata = stat()
        guard path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else { return nil }
        let kind: FileEntryKind = switch metadata.st_mode & S_IFMT {
        case S_IFREG: .regularFile
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        default: .other
        }
        return FileIdentity(
            deviceID: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            entryKind: kind,
            creationTimeNanoseconds: nil
        )
    }

    static func isSafeRelatedPath(_ path: String) -> Bool {
        let normalized = PathSafety.normalizedPath(path)
        return safeRelatedRootPaths.contains { root in
            normalized.hasPrefix(root + "/")
        }
    }

    private static var safeRelatedRootPaths: [String] {
        let library = "\(PathSafety.homePath)/Library"
        return [
            "\(library)/Application Support",
            "\(library)/Caches",
            "\(library)/Preferences",
            "\(library)/Containers",
            "\(library)/Group Containers"
        ].map(PathSafety.normalizedPath)
    }

    private static func appItem(for url: URL, source: String, deadline: Date) -> InstalledAppItem {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        var info = NSDictionary(contentsOf: infoURL) as? [String: Any] ?? [:]
        localizedInfoDictionary(for: url).forEach { key, value in
            info[key] = value
        }
        let metadata = NSMetadataItem(url: url)
        let nativeDescription = cleanedDescription(
            metadata?.value(forAttribute: NSMetadataItemDescriptionKey) as? String ?? ""
        )
        let spotlightDescription = nativeDescription.isEmpty
            ? appSpotlightDescription(url.path, deadline: deadline)
            : nativeDescription
        if !spotlightDescription.isEmpty {
            info["kMDItemDescription"] = spotlightDescription
        }
        let bundleID = info["CFBundleIdentifier"] as? String ?? ""
        let displayName = info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        let category = categoryTitle(for: info["LSApplicationCategoryType"] as? String)
        let developer = developerName(for: bundleID)
        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let lastUsedAt = metadata?.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
            ?? appLastUsedDate(url.path, deadline: deadline)
        let size = (metadata?.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)
            .map { max(0, $0.int64Value) }
            ?? appSizeBytes(url.path, deadline: deadline)
        let relatedItems = relatedItems(
            appName: displayName,
            bundleIdentifier: bundleID,
            deadline: deadline
        )
        let introduction = appIntroduction(
            displayName: displayName,
            category: category,
            bundleIdentifier: bundleID,
            developerName: developer,
            info: info
        )

        return InstalledAppItem(
            id: PathSafety.normalizedPath(url.path),
            name: displayName,
            bundleIdentifier: bundleID,
            path: url.path,
            version: version,
            build: build,
            category: category,
            appDescription: appDescription(
                displayName: displayName,
                source: source,
                category: category,
                version: AppUpdateService.versionDisplay(shortVersion: version, buildVersion: build),
                bundleIdentifier: bundleID,
                developerName: developer,
                introduction: introduction,
                info: info
            ),
            appIntroduction: introduction,
            developerName: developer,
            sizeBytes: size,
            source: source,
            modifiedAt: modifiedAt,
            scanIdentity: uninstallFileIdentity(at: url.path),
            lastUsedAt: lastUsedAt,
            relatedPaths: relatedItems.map(\.path),
            relatedItems: relatedItems,
            status: .installed
        )
    }

    static func appDescription(
        displayName: String,
        source: String,
        category: String,
        version: String,
        bundleIdentifier: String,
        developerName: String = "",
        introduction: String? = nil,
        info: [String: Any]
    ) -> String {
        var parts = [String]()
        parts.append(
            introduction?.trimmed.nonEmpty
                ?? appIntroduction(
                    displayName: displayName,
                    category: category,
                    bundleIdentifier: bundleIdentifier,
                    developerName: developerName,
                    info: info
                )
        )

        var metadata = [String]()
        if !version.trimmed.isEmpty {
            metadata.append(L10n.text("版本 \(version)", "version \(version)"))
        }
        if !developerName.trimmed.isEmpty {
            metadata.append(L10n.text("开发者 \(developerName)", "developer \(developerName)"))
        }
        if !source.trimmed.isEmpty {
            metadata.append(source)
        }
        if !bundleIdentifier.trimmed.isEmpty {
            metadata.append(bundleIdentifier)
        }

        if !metadata.isEmpty {
            parts.append(L10n.text(
                "扫描信息：\(metadata.joined(separator: " · "))。",
                "Scan info: \(metadata.joined(separator: " · "))."
            ))
        }

        return parts
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmed
    }

    static func appIntroduction(
        displayName: String,
        category: String,
        bundleIdentifier: String,
        developerName: String = "",
        info: [String: Any]
    ) -> String {
        let plistDescription = firstUsefulString(in: info, keys: [
            "NSHumanReadableDescription",
            "kMDItemDescription",
            "CFBundleGetInfoString"
        ])

        if !plistDescription.isEmpty {
            return plistDescription
        }

        if let purpose = knownAppPurpose(displayName: displayName, bundleIdentifier: bundleIdentifier) {
            return L10n.text(
                "\(displayName) 是用于\(purpose.zh)的 macOS 应用。",
                "\(displayName) is a macOS app for \(purpose.en)."
            )
        }

        if let purpose = categoryPurpose(for: category) {
            if !category.trimmed.isEmpty, !developerName.trimmed.isEmpty {
                return L10n.text(
                    "\(displayName) 是 \(developerName) 提供的\(category)类 macOS 应用，主要用于\(purpose.zh)。",
                    "\(displayName) is a \(category.lowercased()) macOS app from \(developerName), mainly used for \(purpose.en)."
                )
            }

            if !category.trimmed.isEmpty {
                return L10n.text(
                    "\(displayName) 是一款\(category)类 macOS 应用，主要用于\(purpose.zh)。",
                    "\(displayName) is a \(category.lowercased()) macOS app mainly used for \(purpose.en)."
                )
            }
        }

        if !category.trimmed.isEmpty, !developerName.trimmed.isEmpty {
            return L10n.text(
                "\(displayName) 是 \(developerName) 提供的\(category)类 macOS 应用。",
                "\(displayName) is a \(category.lowercased()) macOS app from \(developerName)."
            )
        }

        if !category.trimmed.isEmpty {
            return L10n.text(
                "\(displayName) 是一款\(category)类 macOS 应用。",
                "\(displayName) is a \(category.lowercased()) macOS app."
            )
        }

        if !developerName.trimmed.isEmpty {
            return L10n.text(
                "\(displayName) 是 \(developerName) 提供的 macOS 应用。",
                "\(displayName) is a macOS app from \(developerName)."
            )
        }

        return L10n.text(
            "\(displayName) 是安装在这台 Mac 上的应用程序。",
            "\(displayName) is an application installed on this Mac."
        )
    }

    static func developerName(for bundleIdentifier: String) -> String {
        let value = bundleIdentifier.lowercased().trimmed
        guard !value.isEmpty else { return "" }

        let knownPrefixes: [(String, String)] = [
            ("com.apple.", "Apple"),
            ("com.microsoft.", "Microsoft"),
            ("com.google.", "Google"),
            ("com.adobe.", "Adobe"),
            ("com.tencent.", "Tencent"),
            ("com.jetbrains.", "JetBrains"),
            ("com.github.", "GitHub"),
            ("com.docker.", "Docker"),
            ("com.spotify.", "Spotify"),
            ("com.valvesoftware.", "Valve"),
            ("com.epicgames.", "Epic Games"),
            ("org.videolan.", "VideoLAN"),
            ("us.zoom.", "Zoom"),
            ("me.damir.", "Damir")
        ]

        if let match = knownPrefixes.first(where: { value.hasPrefix($0.0) }) {
            return match.1
        }

        let parts = value.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return "" }
        let candidate = parts[1]
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmed
        guard candidate.count >= 2 else { return "" }
        return candidate.capitalized
    }

    static func categoryTitle(for rawValue: String?) -> String {
        guard let rawValue = rawValue?.trimmed, !rawValue.isEmpty else { return "" }

        let title: String
        switch rawValue {
        case "public.app-category.business":
            title = L10n.text("商务", "Business")
        case "public.app-category.developer-tools":
            title = L10n.text("开发工具", "Developer Tools")
        case "public.app-category.education":
            title = L10n.text("教育", "Education")
        case "public.app-category.entertainment":
            title = L10n.text("娱乐", "Entertainment")
        case "public.app-category.finance":
            title = L10n.text("财务", "Finance")
        case "public.app-category.games":
            title = L10n.text("游戏", "Games")
        case "public.app-category.graphics-design":
            title = L10n.text("图形与设计", "Graphics & Design")
        case "public.app-category.healthcare-fitness":
            title = L10n.text("健康健身", "Health & Fitness")
        case "public.app-category.lifestyle":
            title = L10n.text("生活", "Lifestyle")
        case "public.app-category.medical":
            title = L10n.text("医疗", "Medical")
        case "public.app-category.music":
            title = L10n.text("音乐", "Music")
        case "public.app-category.news":
            title = L10n.text("新闻", "News")
        case "public.app-category.photography":
            title = L10n.text("摄影", "Photography")
        case "public.app-category.productivity":
            title = L10n.text("效率", "Productivity")
        case "public.app-category.reference":
            title = L10n.text("参考", "Reference")
        case "public.app-category.social-networking":
            title = L10n.text("社交", "Social Networking")
        case "public.app-category.sports":
            title = L10n.text("体育", "Sports")
        case "public.app-category.travel":
            title = L10n.text("旅行", "Travel")
        case "public.app-category.utilities":
            title = L10n.text("工具", "Utilities")
        case "public.app-category.video":
            title = L10n.text("视频", "Video")
        case "public.app-category.weather":
            title = L10n.text("天气", "Weather")
        default:
            title = rawValue
                .replacingOccurrences(of: "public.app-category.", with: "")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }

        return title
    }

    private static func localizedInfoDictionary(for appURL: URL) -> [String: Any] {
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        for identifier in localizedInfoCandidates() {
            let stringsURL = resourcesURL
                .appendingPathComponent("\(identifier).lproj", isDirectory: true)
                .appendingPathComponent("InfoPlist.strings")
            guard let data = try? Data(contentsOf: stringsURL) else { continue }
            guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let plist = object as? [String: Any] else { continue }
            return plist
        }
        return [:]
    }

    private static func localizedInfoCandidates() -> [String] {
        var candidates = L10n.usesChinese
            ? ["zh-Hans", "zh_CN", "zh-Hant", "zh_TW", "zh"]
            : ["en", "English"]

        for language in Locale.preferredLanguages {
            let normalized = language.replacingOccurrences(of: "_", with: "-")
            candidates.append(normalized)
            candidates.append(normalized.replacingOccurrences(of: "-", with: "_"))
            if let prefix = normalized.split(separator: "-").first {
                candidates.append(String(prefix))
            }
        }

        candidates.append(contentsOf: ["Base", "en", "English"])
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func knownAppPurpose(
        displayName: String,
        bundleIdentifier: String
    ) -> (zh: String, en: String)? {
        let bundleID = bundleIdentifier.lowercased()
        let normalizedName = displayName.lowercased()

        let exact: [String: (zh: String, en: String)] = [
            "com.apple.finalcut": ("视频剪辑、调色和后期制作", "video editing, color work, and post-production"),
            "com.apple.finalcutapp": ("视频剪辑、调色和后期制作", "video editing, color work, and post-production"),
            "com.apple.compressorapp": ("视频转码、压缩和交付", "video transcoding, compression, and delivery"),
            "com.apple.garageband10": ("音乐创作、录音和音频制作", "music creation, recording, and audio production"),
            "com.apple.imovieapp": ("家庭视频剪辑和影片制作", "home video editing and movie creation"),
            "com.apple.keynote": ("演示文稿制作和现场展示", "presentation creation and live presenting"),
            "com.apple.pages": ("文稿写作、排版和文字处理", "document writing, layout, and word processing"),
            "com.apple.numbers": ("电子表格和数据表管理", "spreadsheets and tabular data"),
            "com.apple.safari": ("网页浏览和网页应用访问", "web browsing and web app access"),
            "com.apple.mail": ("邮件收发和邮箱管理", "email and mailbox management"),
            "com.apple.photos": ("照片图库管理和基础修图", "photo library management and basic editing"),
            "com.apple.dt.xcode": ("Apple 平台应用开发", "Apple platform app development"),
            "com.openai.chat": ("ChatGPT 对话、写作辅助和代码协作", "ChatGPT conversations, writing assistance, and coding collaboration"),
            "com.openai.chatgpt": ("ChatGPT 对话、写作辅助和代码协作", "ChatGPT conversations, writing assistance, and coding collaboration"),
            "com.google.chrome": ("网页浏览、扩展和 Google 账户同步", "web browsing, extensions, and Google account sync"),
            "com.google.drivefs": ("Google 云端硬盘同步和本地文件访问", "Google Drive sync and local file access"),
            "com.microsoft.word": ("文档写作、审阅和排版", "document writing, reviewing, and layout"),
            "com.microsoft.excel": ("电子表格、数据计算和表格分析", "spreadsheets, calculations, and tabular analysis"),
            "com.microsoft.powerpoint": ("演示文稿制作和放映", "presentation creation and slide delivery"),
            "com.microsoft.outlook": ("邮件、日历和联系人管理", "email, calendar, and contact management"),
            "com.microsoft.onedrive-mac": ("OneDrive 云文件同步和本地访问", "OneDrive cloud file sync and local access"),
            "com.microsoft.vscode": ("代码编辑、项目开发和扩展管理", "code editing, project development, and extension management"),
            "com.microsoft.teams2": ("团队聊天、会议和协作", "team chat, meetings, and collaboration"),
            "com.adobe.photoshop": ("图像编辑、修图和设计制作", "image editing, retouching, and design production"),
            "com.adobe.illustrator": ("矢量插画、图形设计和品牌素材制作", "vector illustration, graphic design, and brand asset creation"),
            "com.adobe.premierepro": ("视频剪辑、音频处理和后期制作", "video editing, audio handling, and post-production"),
            "com.figma.desktop": ("界面设计、原型协作和设计稿查看", "interface design, prototyping, and design collaboration"),
            "notion.id": ("笔记、知识库和项目资料管理", "notes, knowledge bases, and project documentation"),
            "com.tinyspeck.slackmacgap": ("团队聊天、频道沟通和工作通知", "team chat, channel communication, and work notifications"),
            "com.hnc.discord": ("语音聊天、社区沟通和群组协作", "voice chat, community communication, and group collaboration"),
            "com.tencent.xinwechat": ("微信聊天、文件传输和小程序使用", "WeChat messaging, file transfer, and mini programs"),
            "com.tencent.weworkmac": ("企业微信沟通和办公协作", "WeCom communication and workplace collaboration"),
            "com.tencent.qq": ("QQ 聊天、文件传输和群组沟通", "QQ messaging, file transfer, and group communication"),
            "com.tencent.qqmusicmac": ("音乐播放、歌单管理和音频内容收听", "music playback, playlist management, and audio listening"),
            "com.firecore.infuse": ("本地和网络视频播放", "local and network video playback"),
            "me.damir.dropover-mac": ("临时文件暂存、拖拽和快速整理", "temporary file shelving, drag-and-drop, and quick organization"),
            "com.docker.docker": ("容器运行、镜像管理和本地开发环境", "container runtime, image management, and local development environments"),
            "com.parallels.desktop.console": ("虚拟机运行和跨系统桌面环境", "virtual machines and cross-system desktop environments"),
            "com.colliderli.iina": ("本地视频播放和多格式媒体观看", "local video playback and multi-format media viewing"),
            "com.obsproject.obs-studio": ("屏幕录制、直播推流和音视频采集", "screen recording, live streaming, and audio/video capture"),
            "com.blackmagic-design.davinciresolve": ("视频剪辑、调色和专业后期制作", "video editing, color grading, and professional post-production"),
            "org.blenderfoundation.blender": ("三维建模、动画和渲染制作", "3D modeling, animation, and rendering"),
            "org.videolan.vlc": ("多格式视频和音频播放", "multi-format video and audio playback"),
            "ru.keepcoder.telegram": ("Telegram 消息、频道订阅和文件传输", "Telegram messaging, channel subscriptions, and file transfer"),
            "net.whatsapp.whatsapp": ("WhatsApp 消息、通话和文件沟通", "WhatsApp messaging, calls, and file communication"),
            "us.zoom.xos": ("视频会议、屏幕共享和在线沟通", "video meetings, screen sharing, and online communication")
        ]

        if let purpose = exact[bundleID] {
            return purpose
        }

        let nameContains: [(String, (zh: String, en: String))] = [
            ("final cut", ("视频剪辑、调色和后期制作", "video editing, color work, and post-production")),
            ("compressor", ("视频转码、压缩和交付", "video transcoding, compression, and delivery")),
            ("garageband", ("音乐创作、录音和音频制作", "music creation, recording, and audio production")),
            ("imovie", ("家庭视频剪辑和影片制作", "home video editing and movie creation")),
            ("keynote", ("演示文稿制作和现场展示", "presentation creation and live presenting")),
            ("chrome", ("网页浏览、扩展和账户同步", "web browsing, extensions, and account sync")),
            ("safari", ("网页浏览和网页应用访问", "web browsing and web app access")),
            ("chatgpt", ("AI 对话、写作辅助和代码协作", "AI conversations, writing assistance, and coding collaboration")),
            ("figma", ("界面设计、原型协作和设计稿查看", "interface design, prototyping, and design collaboration")),
            ("photoshop", ("图像编辑、修图和设计制作", "image editing, retouching, and design production")),
            ("illustrator", ("矢量插画、图形设计和品牌素材制作", "vector illustration, graphic design, and brand asset creation")),
            ("premiere", ("视频剪辑、音频处理和后期制作", "video editing, audio handling, and post-production")),
            ("notion", ("笔记、知识库和项目资料管理", "notes, knowledge bases, and project documentation")),
            ("slack", ("团队聊天、频道沟通和工作通知", "team chat, channel communication, and work notifications")),
            ("discord", ("语音聊天、社区沟通和群组协作", "voice chat, community communication, and group collaboration")),
            ("telegram", ("即时通讯、频道订阅和文件传输", "messaging, channel subscriptions, and file transfer")),
            ("whatsapp", ("即时通讯、通话和文件沟通", "messaging, calls, and file communication")),
            ("wechat", ("即时通讯、文件传输和移动端协同", "messaging, file transfer, and mobile sync")),
            ("qqmusic", ("音乐播放、歌单管理和音频内容收听", "music playback, playlist management, and audio listening")),
            ("dropover", ("临时文件暂存、拖拽和快速整理", "temporary file shelving, drag-and-drop, and quick organization")),
            ("infuse", ("本地和网络视频播放", "local and network video playback")),
            ("xcode", ("Apple 平台应用开发", "Apple platform app development")),
            ("visual studio code", ("代码编辑、项目开发和扩展管理", "code editing, project development, and extension management")),
            ("cursor", ("AI 辅助代码编辑、项目开发和上下文问答", "AI-assisted code editing, project development, and contextual Q&A")),
            ("docker", ("容器运行、镜像管理和本地开发环境", "container runtime, image management, and local development environments")),
            ("parallels", ("虚拟机运行和跨系统桌面环境", "virtual machines and cross-system desktop environments")),
            ("obs", ("屏幕录制、直播推流和音视频采集", "screen recording, live streaming, and audio/video capture")),
            ("davinci resolve", ("视频剪辑、调色和专业后期制作", "video editing, color grading, and professional post-production")),
            ("blender", ("三维建模、动画和渲染制作", "3D modeling, animation, and rendering")),
            ("steam", ("游戏库管理、下载和运行", "game library management, downloads, and launching")),
            ("epic games", ("游戏库管理、下载和运行", "game library management, downloads, and launching"))
        ]

        return nameContains.first { normalizedName.contains($0.0) }?.1
    }

    private static func categoryPurpose(for category: String) -> (zh: String, en: String)? {
        let value = category.lowercased().trimmed
        guard !value.isEmpty else { return nil }

        let entries: [([String], (zh: String, en: String))] = [
            (["开发工具", "developer"], ("代码编写、构建调试和开发资源管理", "coding, build/debug workflows, and developer resource management")),
            (["效率", "productivity"], ("文档处理、任务整理和日常工作提效", "document work, task organization, and daily productivity")),
            (["工具", "utilit"], ("系统辅助、文件处理或日常维护", "system assistance, file handling, or daily maintenance")),
            (["商务", "business"], ("办公协作、业务流程和团队沟通", "office collaboration, business workflows, and team communication")),
            (["图形", "design", "graphics"], ("图像设计、创意制作和视觉素材处理", "visual design, creative production, and asset handling")),
            (["摄影", "photo"], ("照片管理、修图和影像整理", "photo management, image editing, and media organization")),
            (["视频", "video"], ("视频播放、剪辑或后期制作", "video playback, editing, or post-production")),
            (["音乐", "music"], ("音频播放、音乐创作或声音制作", "audio playback, music creation, or sound production")),
            (["娱乐", "entertain"], ("媒体内容观看、播放和休闲娱乐", "media viewing, playback, and entertainment")),
            (["游戏", "game"], ("游戏运行、游戏库管理或互动娱乐", "gameplay, game library management, or interactive entertainment")),
            (["社交", "social"], ("消息沟通、社群互动和联系人协作", "messaging, community interaction, and contact collaboration")),
            (["财务", "finance"], ("账务记录、数据核算或财务管理", "bookkeeping, calculation, or finance management")),
            (["教育", "education"], ("学习、课程内容和知识训练", "learning, coursework, and knowledge practice")),
            (["参考", "reference"], ("资料查询、知识索引和内容查阅", "lookup, knowledge indexing, and reference reading")),
            (["生活", "lifestyle"], ("日常生活管理、个人内容或习惯辅助", "daily life management, personal content, or habit support")),
            (["旅行", "travel"], ("行程规划、地图位置或出行信息管理", "trip planning, location maps, or travel information")),
            (["天气", "weather"], ("天气查询、预报查看和环境信息跟踪", "weather lookup, forecasts, and environmental tracking")),
            (["医疗", "medical", "health"], ("健康记录、医疗资料或健身管理", "health records, medical information, or fitness management"))
        ]

        return entries.first { tokens, _ in
            tokens.contains { value.contains($0) }
        }?.1
    }

    private static func appSizeBytes(_ path: String, deadline: Date? = nil) -> Int64 {
        let remaining = deadline?.timeIntervalSinceNow ?? 1.5
        guard remaining > 0.05 else { return 0 }
        let timeout = min(1.5, remaining)

        if let output = try? Shell.capture("/usr/bin/du", ["-sk", path], timeout: timeout),
           let first = output.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first,
           let kb = Int64(first) {
            return kb * 1024
        }
        return 0
    }

    static func parseSpotlightDate(_ rawValue: String) -> Date? {
        let cleaned = rawValue
            .replacingOccurrences(of: "\"", with: "")
            .trimmed
        guard !cleaned.isEmpty, cleaned != "(null)", cleaned.lowercased() != "null" else {
            return nil
        }

        return spotlightDateFormatter.withLock { formatter in
            formatter.date(from: cleaned)
        }
    }

    private static func appLastUsedDate(_ path: String, deadline: Date) -> Date? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.05 else { return nil }
        guard let output = try? Shell.capture(
            "/usr/bin/mdls",
            ["-name", "kMDItemLastUsedDate", "-raw", path],
            timeout: min(0.5, remaining)
        ) else {
            return nil
        }
        return parseSpotlightDate(output)
    }

    private static func appSpotlightDescription(_ path: String, deadline: Date) -> String {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.05 else { return "" }
        guard let output = try? Shell.capture(
            "/usr/bin/mdls",
            ["-name", "kMDItemDescription", "-raw", path],
            timeout: min(0.5, remaining)
        ) else {
            return ""
        }
        return cleanedDescription(output)
    }

    private static func relatedPaths(appName: String, bundleIdentifier: String) -> [String] {
        let home = NSHomeDirectory()
        var paths = [
            "\(home)/Library/Application Support/\(appName)",
            "\(home)/Library/Caches/\(appName)",
            "\(home)/Library/Preferences/\(appName).plist"
        ]

        if !bundleIdentifier.isEmpty {
            paths.append(contentsOf: [
                "\(home)/Library/Application Support/\(bundleIdentifier)",
                "\(home)/Library/Caches/\(bundleIdentifier)",
                "\(home)/Library/Preferences/\(bundleIdentifier).plist",
                "\(home)/Library/Containers/\(bundleIdentifier)",
                "\(home)/Library/Group Containers/\(bundleIdentifier)"
            ])
        }

        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private static func relatedItems(
        appName: String,
        bundleIdentifier: String,
        deadline: Date
    ) -> [InstalledAppRelatedItem] {
        relatedPaths(appName: appName, bundleIdentifier: bundleIdentifier).compactMap { path in
            guard Date() < deadline else { return nil }
            return InstalledAppRelatedItem(
                path: path,
                sizeBytes: appSizeBytes(path, deadline: deadline),
                scanIdentity: uninstallFileIdentity(at: path)
            )
        }
    }

    private static func firstUsefulString(in info: [String: Any], keys: [String]) -> String {
        for key in keys {
            guard let value = info[key] as? String else { continue }
            let cleaned = cleanedDescription(value)
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return ""
    }

    private static func cleanedDescription(_ rawValue: String) -> String {
        let cleaned = rawValue
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmed
        guard cleaned.count >= 12,
              cleaned != "(null)",
              cleaned.lowercased() != "null" else {
            return ""
        }

        let lowered = cleaned.lowercased()
        let legalOnlyMarkers = [
            "copyright",
            "all rights reserved",
            "保留所有权利",
            "版权所有"
        ]
        if legalOnlyMarkers.contains(where: lowered.contains) {
            return ""
        }
        return cleaned
    }
}
