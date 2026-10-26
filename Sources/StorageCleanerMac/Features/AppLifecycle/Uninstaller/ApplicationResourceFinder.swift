import Darwin
import Foundation

/// Finds what belongs to an application the way CleanMyMac 5's
/// `UninstallerScanning` does: one fetcher per kind of resource
/// (`CMApplicationContainerFetcher`, `CMSupportingFilesFetcher`,
/// `CMPreferencesFilesFetcher`, `CMCachesFetcher`, `CMLogsFetcher`,
/// `CMCrashLogsFetcher`, `CMApplicationSavedStateFetcher`, `CMCookiesFetcher`,
/// `CMLaunchDemonsFetcher`, `CMPluginsFetcher`, `CMDockIconFetcher`,
/// `CMApplicationHelpFetcher`, `CMReceiptFetcher`, `CMDownloadFilesFetcher`,
/// `CMTempFilesFetcher`), matching by identifier, embedded helpers,
/// application groups, launchd references and word-for-word names.
///
/// Read-only. Locations no flow may touch (`ProtectedLocations`) are never
/// returned, nor anything inside another installed application.
struct ApplicationResourceFinder: Sendable {
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    /// "/" in production; a fixture folder standing in for it in tests.
    var systemRoot: URL = URL(fileURLWithPath: "/", isDirectory: true)
    /// Identifiers of every installed application, for “a more specific app
    /// owns this” and shared vendor groups.
    var installedBundleIdentifiers: Set<String> = []
    /// Paths of every installed application bundle.
    var installedApplicationPaths: Set<String> = []
    /// `persistent-apps` tile URLs of the Dock.
    var dockTileURLs: @Sendable () -> [String] = { ApplicationResourceFinder.liveDockTileURLs() }
    var darwinUserCacheDirectory: URL? = ApplicationResourceFinder.confstrDirectory(_CS_DARWIN_USER_CACHE_DIR)
    var darwinUserTempDirectory: URL? = ApplicationResourceFinder.confstrDirectory(_CS_DARWIN_USER_TEMP_DIR)
    var measuresSizes = true

    static let pluginFolders = [
        "Internet Plug-Ins", "QuickLook", "Spotlight", "Services", "PreferencePanes", "Screen Savers",
        "Mail/Bundles", "Audio/Plug-Ins/Components", "Audio/Plug-Ins/VST", "Audio/Plug-Ins/VST3",
        "Audio/Plug-Ins/HAL", "ColorPickers", "Contextual Menu Items", "Input Methods", "PDF Services",
        "Address Book Plug-Ins", "Widgets",
    ]
    static let crashReportExtensions: Set<String> = ["ips", "crash", "diag", "spin", "hang", "panic"]
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg"]

    // MARK: Finding

    func resources(for profile: ApplicationProfile, includeBundle: Bool = true) -> [ApplicationResource] {
        var collector = Collector(finder: self, profile: profile)
        if includeBundle {
            collector.add(profile.path, group: .binaries, evidence: .bundle, domain: domain(of: profile.path),
                          removable: !profile.isProtectedSystemApplication,
                          note: profile.isProtectedSystemApplication ? Self.protectedApplicationNote : nil)
        }
        let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        let systemLibrary = systemRoot.appendingPathComponent("Library", isDirectory: true)
        let identifiers = [profile.bundleIdentifier] + profile.helperBundleIdentifiers

        // Containers and application scripts are named by identifier only.
        for identifier in identifiers {
            let evidence: ApplicationResourceEvidence = identifier == profile.bundleIdentifier ? .bundleIdentifier : .helperIdentifier
            collector.add(library.appendingPathComponent("Containers/\(identifier)").path, group: .container, evidence: evidence)
            collector.add(library.appendingPathComponent("Application Scripts/\(identifier)").path, group: .supportingFiles, evidence: evidence)
            collector.add(library.appendingPathComponent("HTTPStorages/\(identifier)").path, group: .supportingFiles, evidence: evidence)
            collector.add(library.appendingPathComponent("HTTPStorages/\(identifier).binarycookies").path, group: .other, evidence: evidence)
            collector.add(library.appendingPathComponent("WebKit/\(identifier)").path, group: .supportingFiles, evidence: evidence)
            collector.add(library.appendingPathComponent("Saved Application State/\(identifier).savedState").path, group: .supportingFiles, evidence: evidence)
            collector.add(library.appendingPathComponent("Cookies/\(identifier).binarycookies").path, group: .other, evidence: evidence)
        }
        for group in profile.applicationGroups {
            // A group the app cannot be shown to own alone is listed, not offered (D151 review).
            let owned = ownsApplicationGroup(group, profile: profile)
            let note = owned ? nil : Self.sharedGroupNote
            collector.add(library.appendingPathComponent("Group Containers/\(group)").path, group: .container,
                          evidence: .applicationGroup, removable: owned, note: note)
            collector.add(library.appendingPathComponent("Application Scripts/\(group)").path, group: .supportingFiles,
                          evidence: .applicationGroup, removable: owned, note: note)
        }

        // Folders where entries are named by identifier or by the app's name.
        let namedFolders: [(URL, ApplicationResourceGroup, Bool)] = [
            (library.appendingPathComponent("Application Support"), .supportingFiles, true),
            (library.appendingPathComponent("Caches"), .caches, true),
            (library.appendingPathComponent("Logs"), .logs, true),
            (library.appendingPathComponent("Preferences"), .preferences, true),
            (library.appendingPathComponent("Preferences/ByHost"), .preferences, false),
            (systemLibrary.appendingPathComponent("Application Support"), .supportingFiles, true),
            (systemLibrary.appendingPathComponent("Caches"), .caches, true),
            (systemLibrary.appendingPathComponent("Logs"), .logs, true),
            (systemLibrary.appendingPathComponent("Preferences"), .preferences, false),
        ]
        for (folder, group, matchesNames) in namedFolders {
            collector.scan(folder, group: group, matchesNames: matchesNames)
        }
        for temporary in [darwinUserCacheDirectory, darwinUserTempDirectory].compactMap({ $0 }) {
            collector.scan(temporary, group: .caches, matchesNames: false)
        }
        collector.scan(library.appendingPathComponent("Caches/com.apple.helpd/Generated"), group: .help, matchesNames: false)

        collectCrashReports(into: &collector, library: library, systemLibrary: systemLibrary)
        collectLaunchdJobs(into: &collector, library: library, systemLibrary: systemLibrary)
        for executable in profile.privilegedExecutables where UninstallCandidatePathPolicy.isSafeComponent(executable) {
            collector.add(systemLibrary.appendingPathComponent("PrivilegedHelperTools/\(executable)").path,
                          group: .loginItems, evidence: .bundleIdentifier, domain: .system)
        }
        collectPlugins(into: &collector, library: library, systemLibrary: systemLibrary)
        collectDockTile(into: &collector)
        collectInstallers(into: &collector)
        return collector.finish(measuringSizes: measuresSizes)
    }

    static let protectedApplicationNote = L10n.text(
        "这是被保护的系统应用程序文件，无法移除。但您可以移除相关文件以重置此应用程序。",
        "This is a protected system application file and it cannot be removed. However, you may remove related files to reset the application."
    )
    static let protectedPluginNote = L10n.text(
        "该插件位于受保护的系统路径中，无法在这里移除。您可以在访达中显示它，然后手动移入废纸篓。",
        "This plugin is located in a protected system path and cannot be removed here. You may reveal it in Finder and move it to Trash manually."
    )
    static let receiptNote = L10n.text(
        "安装回执记录在系统位置，需要管理员权限才能移除，这里只列出。",
        "Installation receipts live in a system location and need an administrator to remove; they are listed only."
    )

    func domain(of path: String) -> ApplicationResourceDomain {
        let home = PathSafety.lexicalPath(homeDirectory.path)
        let lexical = PathSafety.lexicalPath(path)
        if lexical.hasPrefix(home + "/") { return .user }
        for temporary in [darwinUserCacheDirectory, darwinUserTempDirectory].compactMap({ $0 }) {
            if lexical.hasPrefix(PathSafety.lexicalPath(temporary.path) + "/") { return .user }
        }
        if lexical.hasPrefix(PathSafety.lexicalPath(systemRoot.appendingPathComponent("Applications").path) + "/") {
            return .user
        }
        return .system
    }

    static let sharedGroupNote = L10n.text("可能与其他应用共用，已保留", "May be shared with other apps; kept")

    /// An application group the app declares is its own when its name carries
    /// the app's identifier, or when it is the vendor's group (prefixed with
    /// the app's Team ID, which only that team's apps can use, or naming the
    /// vendor's identifier prefix) and no other installed app from the same
    /// vendor could share it (CleanMyMac `allBundleIDsAppropriateToContainers`).
    /// D151 review: another vendor's group (group.com.other.shared) is never
    /// the app's own, whatever else is installed.
    func ownsApplicationGroup(_ group: String, profile: ApplicationProfile) -> Bool {
        let lowerGroup = group.lowercased()
        if lowerGroup.contains(profile.bundleIdentifier.lowercased()) { return true }
        let vendor = Self.vendorPrefix(of: profile.bundleIdentifier)
        guard !vendor.isEmpty, Self.isVendorGroup(lowerGroup, vendor: vendor, teamIdentifier: profile.teamIdentifier) else {
            return false
        }
        return !installedBundleIdentifiers.contains { other in
            other != profile.bundleIdentifier && Self.vendorPrefix(of: other) == vendor
        }
    }

    static func isVendorGroup(_ group: String, vendor: String, teamIdentifier: String?) -> Bool {
        if let team = teamIdentifier?.lowercased(), !team.isEmpty, group.hasPrefix(team + ".") { return true }
        let parts = group.split(separator: ".").map(String.init)
        let vendorParts = vendor.split(separator: ".").map(String.init)
        guard !vendorParts.isEmpty, parts.count >= vendorParts.count else { return false }
        return (0...(parts.count - vendorParts.count)).contains { Array(parts[$0..<($0 + vendorParts.count)]) == vendorParts }
    }

    static func vendorPrefix(of identifier: String) -> String {
        let parts = identifier.lowercased().split(separator: ".")
        return parts.count >= 2 ? parts.prefix(2).joined(separator: ".") : ""
    }

    // MARK: Fetchers

    private func collectCrashReports(into collector: inout Collector, library: URL, systemLibrary: URL) {
        guard let executable = collector.profile.executableName,
              ApplicationNameMatcher.identifyingWords(of: executable) != nil else { return }
        let lowered = executable.lowercased()
        let folders: [(URL, ApplicationResourceDomain)] = [
            (library.appendingPathComponent("Logs/DiagnosticReports"), .user),
            (library.appendingPathComponent("Logs/DiagnosticReports/Retired"), .user),
            (library.appendingPathComponent("Application Support/CrashReporter"), .user),
            (systemLibrary.appendingPathComponent("Logs/DiagnosticReports"), .system),
        ]
        for (folder, domain) in folders {
            for entry in listing(folder) {
                let name = entry.lastPathComponent.lowercased()
                let isReport = Self.crashReportExtensions.contains(entry.pathExtension.lowercased())
                    || (folder.lastPathComponent == "CrashReporter" && entry.pathExtension == "plist")
                guard isReport, name.hasPrefix(lowered + "_") || name.hasPrefix(lowered + "-") else { continue }
                collector.add(entry.path, group: .crashes, evidence: .executableName, domain: domain)
            }
        }
    }

    private func collectLaunchdJobs(into collector: inout Collector, library: URL, systemLibrary: URL) {
        let profile = collector.profile
        let owned = Set(([profile.bundleIdentifier] + profile.helperBundleIdentifiers + profile.privilegedExecutables).map { $0.lowercased() })
        let folders: [(URL, ApplicationResourceDomain)] = [
            (library.appendingPathComponent("LaunchAgents"), .user),
            (systemLibrary.appendingPathComponent("LaunchAgents"), .system),
            (systemLibrary.appendingPathComponent("LaunchDaemons"), .system),
        ]
        for (folder, domain) in folders {
            for entry in listing(folder) where entry.pathExtension == "plist" {
                guard let job = NSDictionary(contentsOf: entry) as? [String: Any],
                      let label = job["Label"] as? String else { continue }
                let program = (job["Program"] as? String) ?? ((job["ProgramArguments"] as? [String])?.first) ?? ""
                let associated: [String] = {
                    if let one = job["AssociatedBundleIdentifiers"] as? String { return [one] }
                    return job["AssociatedBundleIdentifiers"] as? [String] ?? []
                }()
                let lowerLabel = label.lowercased()
                let labelOwned = owned.contains(lowerLabel)
                    || ApplicationNameMatcher.isIdentifierOrDerived(label, identifier: profile.bundleIdentifier)
                let referencesApp = associated.contains { owned.contains($0.lowercased()) }
                    || (!program.isEmpty && PathSafety.lexicalPath(program).hasPrefix(PathSafety.lexicalPath(profile.path) + "/"))
                guard labelOwned || referencesApp, !collector.isOwnedByAnotherApplication(name: label) else { continue }
                collector.add(entry.path, group: .loginItems,
                              evidence: labelOwned ? .bundleIdentifier : .launchdReference,
                              domain: domain, kind: .launchdJob(label: label))
            }
        }
    }

    private func collectPlugins(into collector: inout Collector, library: URL, systemLibrary: URL) {
        let profile = collector.profile
        for (base, domain) in [(library, ApplicationResourceDomain.user), (systemLibrary, .system)] {
            for folder in Self.pluginFolders {
                for entry in listing(base.appendingPathComponent(folder)) {
                    let info = NSDictionary(contentsOf: entry.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
                        ?? NSDictionary(contentsOf: entry.appendingPathComponent("Info.plist")) as? [String: Any]
                    let identifier = info?["CFBundleIdentifier"] as? String ?? ""
                    let name = entry.deletingPathExtension().lastPathComponent
                    let evidence: ApplicationResourceEvidence?
                    if !identifier.isEmpty, ApplicationNameMatcher.isIdentifierOrDerived(identifier, identifier: profile.bundleIdentifier) {
                        evidence = .bundleIdentifier
                    } else if !identifier.isEmpty, profile.helperBundleIdentifiers.contains(identifier) {
                        evidence = .helperIdentifier
                    } else if ApplicationNameMatcher.matches(resourceName: name, applicationName: profile.displayName)
                                || ApplicationNameMatcher.matches(resourceName: name, applicationName: profile.bundleName) {
                        evidence = .nameMatch
                    } else {
                        evidence = nil
                    }
                    guard let evidence, !collector.isOwnedByAnotherApplication(name: identifier) else { continue }
                    let isProtected = ApplicationProfile.isSystemProtected(entry.path)
                    collector.add(entry.path, group: .plugins, evidence: evidence, domain: domain,
                                  removable: !isProtected, note: isProtected ? Self.protectedPluginNote : nil)
                }
            }
        }
    }

    private func collectDockTile(into collector: inout Collector) {
        let target = URL(fileURLWithPath: collector.profile.path, isDirectory: true).absoluteString
        guard dockTileURLs().contains(where: { $0 == target || $0 == String(target.dropLast()) }) else { return }
        collector.addDockTile(url: target)
    }

    private func collectInstallers(into collector: inout Collector) {
        let profile = collector.profile
        for folder in ["Downloads", "Desktop"] {
            for entry in listing(homeDirectory.appendingPathComponent(folder)) {
                guard Self.installerExtensions.contains(entry.pathExtension.lowercased()) else { continue }
                let name = entry.deletingPathExtension().lastPathComponent
                guard ApplicationNameMatcher.matches(resourceName: name, applicationName: profile.displayName)
                        || ApplicationNameMatcher.matches(resourceName: name, applicationName: profile.bundleName) else { continue }
                collector.add(entry.path, group: .installers, evidence: .nameMatch)
            }
        }
        let receipts = systemRoot.appendingPathComponent("private/var/db/receipts")
        for entry in listing(receipts) where ["plist", "bom"].contains(entry.pathExtension) {
            let packageIdentifier = entry.deletingPathExtension().lastPathComponent
            guard ApplicationNameMatcher.isIdentifierOrDerived(packageIdentifier, identifier: profile.bundleIdentifier) else { continue }
            collector.add(entry.path, group: .installers, evidence: .bundleIdentifier, domain: .system,
                          removable: false, note: Self.receiptNote)
        }
    }

    // MARK: Helpers

    func listing(_ folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    /// The per-user folder under `/var/folders`, with `/var` already resolved
    /// to `/private/var` so that entries inside it pass the symbolic-link check.
    static func confstrDirectory(_ name: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(name, &buffer, buffer.count) > 0 else { return nil }
        // The bytes up to the terminating NUL (the array `String(cString:)` is deprecated).
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
    }

    static func liveDockTileURLs() -> [String] {
        guard let tiles = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] else {
            return []
        }
        return tiles.compactMap { tile in
            ((tile["tile-data"] as? [String: Any])?["file-data"] as? [String: Any])?["_CFURLString"] as? String
        }
    }

    /// Accumulates candidates: drops unsafe, protected, missing and nested
    /// ones and keeps the strongest evidence for each path.
    struct Collector {
        let finder: ApplicationResourceFinder
        let profile: ApplicationProfile
        private var items: [String: ApplicationResource] = [:]
        private let homePath: String
        private let ownPrefixes: [String]

        init(finder: ApplicationResourceFinder, profile: ApplicationProfile) {
            self.finder = finder
            self.profile = profile
            homePath = PathSafety.lexicalPath(finder.homeDirectory.path)
            ownPrefixes = ProtectedLocations.appDataRelativePaths.map { PathSafety.lexicalPath(finder.homeDirectory.appendingPathComponent($0).path) }
        }

        /// Another installed app with a longer identifier claims this name
        /// (`com.vendor.App.Pro` is not part of `com.vendor.App`).
        func isOwnedByAnotherApplication(name: String) -> Bool {
            guard !name.isEmpty else { return false }
            let own = profile.bundleIdentifier.lowercased()
            return finder.installedBundleIdentifiers.contains { other in
                let lowerOther = other.lowercased()
                return lowerOther != own && lowerOther.count > own.count
                    && ApplicationNameMatcher.isIdentifierOrDerived(name, identifier: other)
            }
        }

        mutating func scan(_ folder: URL, group: ApplicationResourceGroup, matchesNames: Bool) {
            let identifiers = [profile.bundleIdentifier] + profile.helperBundleIdentifiers
            for entry in finder.listing(folder) {
                let name = entry.lastPathComponent
                let stem = ["plist", "savedState", "binarycookies"].contains(entry.pathExtension)
                    ? entry.deletingPathExtension().lastPathComponent : name
                var evidence: ApplicationResourceEvidence?
                if let identifier = identifiers.first(where: { ApplicationNameMatcher.isIdentifierOrDerived(stem, identifier: $0) }) {
                    evidence = identifier == profile.bundleIdentifier ? .bundleIdentifier : .helperIdentifier
                    if isOwnedByAnotherApplication(name: stem) { evidence = nil }
                } else if matchesNames,
                          ApplicationNameMatcher.matches(resourceName: stem, applicationName: profile.displayName)
                            || ApplicationNameMatcher.matches(resourceName: stem, applicationName: profile.bundleName) {
                    evidence = .nameMatch
                }
                guard let evidence else { continue }
                add(entry.path, group: group, evidence: evidence, domain: finder.domain(of: entry.path))
            }
        }

        mutating func add(_ path: String, group: ApplicationResourceGroup, evidence: ApplicationResourceEvidence,
                          domain: ApplicationResourceDomain? = nil, kind: ApplicationResource.Kind = .file,
                          removable: Bool = true, note: String? = nil) {
            // Never resolve links: a link anywhere on the path (the entry
            // itself included) could point at another app's or the person's
            // own folder, so such a path is left out, as the uninstaller does.
            let normalized = PathSafety.lexicalPath(path)
            var info = stat()
            guard lstat(normalized, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK,
                  !PathSafety.containsSymbolicLinkComponent(in: normalized) else { return }
            guard !ProtectedLocations.protects(path: normalized, homePath: homePath),
                  !ownPrefixes.contains(where: { normalized == $0 || normalized.hasPrefix($0 + "/") }) else { return }
            if evidence != .bundle {
                let appPath = PathSafety.lexicalPath(profile.path)
                guard normalized != appPath, !normalized.hasPrefix(appPath + "/"),
                      !finder.installedApplicationPaths.contains(where: { app in
                          let installed = PathSafety.lexicalPath(app)
                          return normalized == installed || normalized.hasPrefix(installed + "/")
                      }) else { return }
            }
            if let existing = items[normalized], existing.evidence <= evidence { return }
            items[normalized] = ApplicationResource(
                path: normalized, group: group, evidence: evidence,
                domain: domain ?? finder.domain(of: normalized), kind: kind,
                sizeBytes: 0, identity: nil, isRemovable: removable, note: note
            )
        }

        mutating func addDockTile(url: String) {
            items["dock:" + url] = ApplicationResource(
                path: profile.path, group: .dockIcon, evidence: .dockReference, domain: .user,
                kind: .dockTile(url: url), sizeBytes: 0, identity: nil, isRemovable: true, note: nil
            )
        }

        func finish(measuringSizes: Bool) -> [ApplicationResource] {
            let files = items.values.filter { if case .dockTile = $0.kind { return false }; return true }
            let filePaths = Set(files.map(\.path))
            // A folder already listed covers what is inside it.
            let kept = items.values.filter { item in
                if case .dockTile = item.kind { return true }
                var parent = (item.path as NSString).deletingLastPathComponent
                while parent.count > 1 {
                    if filePaths.contains(parent) && parent != item.path { return false }
                    parent = (parent as NSString).deletingLastPathComponent
                }
                return true
            }
            return kept.map { item in
                var resolved = item
                if case .dockTile = item.kind { return resolved }
                if measuringSizes {
                    resolved.sizeBytes = TrashSizeMeasurer.allocatedSize(of: URL(fileURLWithPath: item.path))
                }
                return ApplicationResource(
                    path: resolved.path, group: resolved.group, evidence: resolved.evidence, domain: resolved.domain,
                    kind: resolved.kind, sizeBytes: resolved.sizeBytes,
                    identity: AppUninstallService.uninstallFileIdentity(at: resolved.path),
                    isRemovable: resolved.isRemovable, note: resolved.note
                )
            }.sorted { lhs, rhs in
                let lhsIndex = ApplicationResourceGroup.allCases.firstIndex(of: lhs.group) ?? 0
                let rhsIndex = ApplicationResourceGroup.allCases.firstIndex(of: rhs.group) ?? 0
                return lhsIndex == rhsIndex ? lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending : lhsIndex < rhsIndex
            }
        }
    }
}
