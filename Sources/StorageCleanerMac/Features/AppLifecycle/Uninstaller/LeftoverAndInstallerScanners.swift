import CoreServices
import Darwin
import Foundation

/// Files an already removed application left behind, grouped by that app
/// (CleanMyMac `LeftoversFetcher`, `LeftoverCandidate`,
/// `LeftoverUninstallerApplication`): entries in the user's Library named by a
/// bundle identifier that no installed or registered application has.
struct LeftoverGroup: Identifiable, Hashable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    var resources: [ApplicationResource]
    var id: String { bundleIdentifier }
    var totalBytes: Int64 { resources.reduce(0) { $0 + $1.sizeBytes } }
}

struct LeftoverScanner: Sendable {
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var installedBundleIdentifiers: Set<String> = []
    /// LaunchServices knows an application with this identifier somewhere.
    var isRegistered: @Sendable (String) -> Bool = { identifier in
        LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil)?.takeRetainedValue() != nil
    }
    /// D191: a launch agent or daemon with this label is still installed.
    var hasLaunchJob: @Sendable (String) -> Bool = { label in
        ["\(NSHomeDirectory())/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"].contains { folder in
            var info = stat()
            return lstat("\(folder)/\(label).plist", &info) == 0
        }
    }
    var measuresSizes = true
    var ignoreList: IgnoreListSnapshot = .empty
    var containsSymbolicLink: @Sendable (String) -> Bool = { PathSafety.containsSymbolicLinkComponent(in: $0) }

    /// Folders named by identifier, and the resource group each one fills.
    static let folders: [(String, ApplicationResourceGroup, Set<String>)] = [
        ("Library/Application Support", .supportingFiles, []),
        ("Library/Caches", .caches, []),
        ("Library/Preferences", .preferences, ["plist"]),
        ("Library/Containers", .container, []),
        ("Library/Logs", .logs, []),
        ("Library/Saved Application State", .supportingFiles, ["savedState"]),
        ("Library/HTTPStorages", .supportingFiles, ["binarycookies"]),
        ("Library/WebKit", .supportingFiles, []),
        ("Library/Application Scripts", .supportingFiles, []),
        ("Library/Cookies", .other, ["binarycookies"]),
    ]

    /// Identifiers never treated as leftovers: the system's own, this app's,
    /// and the shared stores of system services.
    static let excludedPrefixes = [
        "com.apple.", "group.com.apple.", "com.local.storagecleanermac", "systemgroup.", "com.google.keystone",
        "com.microsoft.autoupdate", "org.sparkle-project.", "com.crashlytics.", "io.sentry",
    ]

    /// D191: stores named by a library or toolchain that many apps use, never
    /// one removed app (10-23: SDWebImage, Kingfisher and Firebase caches and
    /// SwiftPM's cache were listed as removed apps).
    static let libraryPrefixes = ["com.hackemist.", "com.onevcat.", "com.firebase.", "com.google.firebase.", "org.swift."]

    /// D191: second-level domains shared by unrelated developers, where the
    /// developer is the third label.
    static let sharedVendorDomains: Set<String> = ["com.github", "io.github", "com.gitlab", "io.gitlab", "com.local"]

    /// D191: the developer's domain (`com.microsoft.office` → `com.microsoft`),
    /// without an app group's `group.` prefix.
    static func vendorDomain(of identifier: String) -> String? {
        let lower = identifier.lowercased()
        let parts = (lower.hasPrefix("group.") ? String(lower.dropFirst(6)) : lower).split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let domain = parts.prefix(2).joined(separator: ".")
        guard sharedVendorDomains.contains(domain) else { return domain }
        return parts.count >= 3 ? parts.prefix(3).joined(separator: ".") : nil
    }

    /// D191: the identifier and each shorter prefix of three or more labels
    /// (`com.vendor.App.widget` → `com.vendor.App`), also without `group.`.
    /// An app's extensions and helpers belong to it wherever it is installed
    /// (10-23: WeType's FinderSync, with WeType in /Library/Input Methods).
    static func ownerCandidates(for identifier: String) -> [String] {
        var bases = [identifier]
        if identifier.lowercased().hasPrefix("group.") { bases.append(String(identifier.dropFirst(6))) }
        return bases.flatMap { base -> [String] in
            var parts = base.split(separator: ".").map(String.init)
            var candidates: [String] = []
            while parts.count >= 3 {
                candidates.append(parts.joined(separator: "."))
                parts.removeLast()
            }
            return candidates
        }
    }

    static func looksLikeBundleIdentifier(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }), name.count <= 155 else { return false }
        guard UninstallCandidatePathPolicy.isSafeComponent(name) else { return false }
        // The first label is a top-level domain, never a number.
        return parts[0].allSatisfy(\.isLetter)
    }

    func scan() -> [LeftoverGroup] { scanReport().groups }

    func scanReport() -> (groups: [LeftoverGroup], ignoredCount: Int) {
        var ignored = Set<String>()
        let home = PathSafety.lexicalPath(homeDirectory.path)
        let installed = installedBundleIdentifiers.map { $0.lowercased() }
        // D191: a developer with an app still installed keeps its shared
        // stores (10-23: `com.microsoft.office` with Office installed,
        // `com.setapp.defaults` with Setapp, `com.raycast.shared` with Raycast).
        let installedVendors = Set(installed.compactMap(Self.vendorDomain(of:)))
        var groups: [String: [ApplicationResource]] = [:]
        var names: [String: String] = [:]
        for (relative, group, extensions) in Self.folders {
            let folder = homeDirectory.appendingPathComponent(relative, isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                let stem = extensions.contains(entry.pathExtension) ? entry.deletingPathExtension().lastPathComponent : entry.lastPathComponent
                guard Self.looksLikeBundleIdentifier(stem) else { continue }
                let lower = stem.lowercased()
                guard !Self.excludedPrefixes.contains(where: { lower.hasPrefix($0) }),
                      !Self.libraryPrefixes.contains(where: { lower.hasPrefix($0) }),
                      !installed.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }),
                      !(Self.vendorDomain(of: lower).map(installedVendors.contains) ?? false),
                      !Self.ownerCandidates(for: stem).contains(where: { isRegistered($0) || hasLaunchJob($0) }) else { continue }
                let path = PathSafety.lexicalPath(entry.path)
                // An app ignore never suppresses residual resources: paths only.
                if ignoreList.ignores(path: path, category: .uninstaller, includingDescendants: true) {
                    ignored.insert(path); continue
                }
                var info = stat()
                guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK,
                      !containsSymbolicLink(path),
                      !ProtectedLocations.protects(path: path, homePath: home) else { continue }
                let owner = Self.ownerIdentifier(for: stem)
                if group == .container, let name = Self.containerDisplayName(entry) { names[owner] = name }
                groups[owner, default: []].append(ApplicationResource(
                    path: path, group: group, evidence: .bundleIdentifier, domain: .user, kind: .file,
                    sizeBytes: measuresSizes ? TrashSizeMeasurer.allocatedSize(of: entry) : 0,
                    identity: AppUninstallService.uninstallFileIdentity(at: path), isRemovable: true, note: nil
                ))
            }
        }
        let result = groups.map { identifier, resources in
            LeftoverGroup(bundleIdentifier: identifier,
                          displayName: names[identifier] ?? Self.displayName(for: identifier),
                          resources: resources.sorted { $0.path < $1.path })
        }.sorted { $0.totalBytes > $1.totalBytes }
        return (result, ignored.count)
    }

    /// Helpers group under their app (`com.vendor.App.helper` → `com.vendor.App`
    /// when the shorter identifier also left files; otherwise itself).
    static func ownerIdentifier(for identifier: String) -> String {
        let parts = identifier.split(separator: ".")
        guard parts.count > 3 else { return identifier }
        let suffix = parts.last?.lowercased() ?? ""
        let helperWords: Set<String> = ["helper", "agent", "launcher", "updater", "shipit", "crashpad", "extension", "service"]
        return helperWords.contains(suffix) ? parts.dropLast().joined(separator: ".") : identifier
    }

    static func displayName(for identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    /// Containers record the bundle they belong to; the name is its last
    /// identifier label when nothing better is known.
    static func containerDisplayName(_ container: URL) -> String? {
        let metadata = container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let values = NSDictionary(contentsOf: metadata) as? [String: Any],
              let identifier = values["MCMMetadataIdentifier"] as? String else { return nil }
        return displayName(for: identifier)
    }
}

/// Installer images and packages that are no longer needed (CleanMyMac
/// `UnusedDiskImagesScanning`: a Spotlight search by type, physical size,
/// `/Applications` skipped, each item “autoselected” or not). Here an item is
/// preselected when its name matches an installed application, so that app
/// is already installed and the installer has done its job.
struct InstallerFile: Identifiable, Hashable, Sendable {
    let resource: ApplicationResource
    let matchedApplication: String?
    /// D209: only an installer in Downloads or on the Desktop is preselected.
    /// One elsewhere is listed but not selected (10-25: a project's reference
    /// DMG in Documents was preselected because its app was installed).
    var inPreselectableFolder = true
    var id: String { resource.id }
    var preselected: Bool { matchedApplication != nil && inPreselectableFolder }
}

struct UnusedInstallerScanner: Sendable {
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var installedApplicationNames: [String] = []
    /// Spotlight paths of disk images and installer packages; injectable.
    var search: @Sendable (URL) -> [String] = { UnusedInstallerScanner.spotlightPaths(in: $0) }
    var mountedImagePaths: @Sendable () -> Set<String> = { [] }
    var ignoreList: IgnoreListSnapshot = .empty
    var containsSymbolicLink: @Sendable (String) -> Bool = { PathSafety.containsSymbolicLinkComponent(in: $0) }

    /// D226: the one list My Clutter's Downloads and Large & Old Files leave out.
    static let extensions = InstallerFileTypes.extensions

    /// D209: the folders whose installers may be preselected, under the home folder.
    static let preselectableFolders = ["Downloads", "Desktop"]

    func scan() -> [InstallerFile] { scanReport().files }

    func scanReport() -> (files: [InstallerFile], ignoredCount: Int) {
        var ignored = Set<String>()
        let home = PathSafety.lexicalPath(homeDirectory.path)
        let mounted = mountedImagePaths()
        var seen = Set<String>()
        var files: [InstallerFile] = []
        for raw in search(homeDirectory) {
            let path = PathSafety.lexicalPath(raw)
            guard seen.insert(path).inserted, path.hasPrefix(home + "/"),
                  !path.hasPrefix(home + "/Library/"), !path.contains("/Applications/"),
                  Self.extensions.contains((path as NSString).pathExtension.lowercased()),
                  !mounted.contains(path), !containsSymbolicLink(path),
                  !ProtectedLocations.protects(path: path, homePath: home) else { continue }
            if ignoreList.ignores(path: path, category: .downloads, includingDescendants: true) {
                ignored.insert(path); continue
            }
            let url = URL(fileURLWithPath: path)
            let stem = url.deletingPathExtension().lastPathComponent
            let match = installedApplicationNames.first { ApplicationNameMatcher.matches(resourceName: stem, applicationName: $0) }
            files.append(InstallerFile(resource: ApplicationResource(
                path: path, group: .installers, evidence: .nameMatch, domain: .user, kind: .file,
                sizeBytes: TrashSizeMeasurer.allocatedSize(of: url),
                identity: AppUninstallService.uninstallFileIdentity(at: path), isRemovable: true, note: nil
            ), matchedApplication: match,
               inPreselectableFolder: Self.preselectableFolders.contains { path.hasPrefix(home + "/" + $0 + "/") }))
        }
        return (files.sorted { $0.resource.sizeBytes > $1.resource.sizeBytes }, ignored.count)
    }

    /// D226: disk images and installer packages by type, and every type of
    /// the shared list by name (a XIP archive is neither type).
    static var spotlightQuery: String {
        let types = ["com.apple.disk-image", "com.apple.installer-package-archive"].map { "kMDItemContentTypeTree == \"\($0)\"cd" }
        let names = extensions.sorted().map { "kMDItemFSName == \"*.\($0)\"cd" }
        return "(" + (types + names).joined(separator: " || ") + ")"
    }

    /// `MDQuery` over the home folder for disk images and installer packages.
    static func spotlightPaths(in home: URL) -> [String] {
        guard let mdQuery = MDQueryCreate(kCFAllocatorDefault, spotlightQuery as CFString, nil, nil) else { return [] }
        MDQuerySetSearchScope(mdQuery, [home.path] as CFArray, 0)
        MDQuerySetMaxCount(mdQuery, 2_000)
        guard MDQueryExecute(mdQuery, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var paths: [String] = []
        for index in 0..<MDQueryGetResultCount(mdQuery) {
            guard let raw = MDQueryGetResultAtIndex(mdQuery, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String { paths.append(path) }
        }
        return paths
    }
}

/// Third-party audio plug-ins (CleanMyMac `AudioPluginLoader`,
/// `UninstallerAudioPlugin`): Audio Units, VST, VST3 and AAX bundles. User
/// copies move to the Trash; copies in `/Library` need an administrator and
/// are listed only.
struct AudioPluginScanner: Sendable {
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var systemRoot: URL = URL(fileURLWithPath: "/", isDirectory: true)
    var ignoreList: IgnoreListSnapshot = .empty
    var containsSymbolicLink: @Sendable (String) -> Bool = { PathSafety.containsSymbolicLinkComponent(in: $0) }

    static let folders = ["Library/Audio/Plug-Ins/Components", "Library/Audio/Plug-Ins/VST", "Library/Audio/Plug-Ins/VST3",
                          "Library/Application Support/Avid/Audio/Plug-Ins"]
    static let extensions: Set<String> = ["component", "vst", "vst3", "aaxplugin"]

    func scan() -> [InstallerFile] { scanReport().files }

    func scanReport() -> (files: [InstallerFile], ignoredCount: Int) {
        var ignored = Set<String>()
        var files: [InstallerFile] = []
        for (base, domain) in [(homeDirectory, ApplicationResourceDomain.user), (systemRoot, .system)] {
            for folder in Self.folders {
                let directory = base.appendingPathComponent(folder, isDirectory: true)
                guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
                for entry in entries where Self.extensions.contains(entry.pathExtension.lowercased()) {
                    let path = PathSafety.lexicalPath(entry.path)
                    if ignoreList.ignores(path: path, category: .uninstaller, includingDescendants: true) {
                        ignored.insert(path); continue
                    }
                    guard !containsSymbolicLink(path) else { continue }
                    let info = NSDictionary(contentsOf: entry.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
                    let vendor = (info?["CFBundleIdentifier"] as? String).map { ApplicationResourceFinder.vendorPrefix(of: $0) }
                    let isProtected = ApplicationProfile.isSystemProtected(path)
                    files.append(InstallerFile(resource: ApplicationResource(
                        path: path, group: .plugins, evidence: .bundle, domain: domain, kind: .file,
                        sizeBytes: TrashSizeMeasurer.allocatedSize(of: entry),
                        identity: AppUninstallService.uninstallFileIdentity(at: path),
                        isRemovable: domain == .user && !isProtected,
                        note: domain == .system ? ApplicationRemovalService.administratorNote : nil
                    ), matchedApplication: vendor))
                }
            }
        }
        return (files.sorted { $0.resource.displayName.localizedStandardCompare($1.resource.displayName) == .orderedAscending }, ignored.count)
    }
}
