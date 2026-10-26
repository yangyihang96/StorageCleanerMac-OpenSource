import Foundation

/// D101 G4-2, layer 1: locations no flow may move or delete — File Analysis,
/// the cleanup rules and uninstall alike — with everything inside them.
/// Paths are relative to the home folder and matched without case.
///
/// What only one flow protects stays with that flow. File Analysis also keeps
/// standard folders, Preferences, Cookies, LaunchAgents, Apple's own entries,
/// app containers and the Trash whole, because uninstall removes an app's own
/// preferences and containers (Apple's App Store apps included) and cleanup
/// rules read Mail's and Safari's containers. The roots automatic rules may
/// not touch stay in `CleanupRuleValidator` (layer 2); the file flags that
/// block a move are `FileProtectionFlags` (layer 3).
enum ProtectedLocations {
    enum Kind: Equatable, Sendable {
        case credentials
        case cloudStorage
        case systemData
        case appData
    }

    /// Keys and credentials.
    static let credentialPaths: [String] = [
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".config/gh", ".config/gcloud", ".netrc",
        // D54 supplement (second review P2-1).
        ".git-credentials", ".npmrc", ".pypirc", ".pgpass", ".cargo/credentials", ".cargo/credentials.toml",
        ".config/op", ".password-store", ".terraform.d/credentials.tfrc.json",
    ]
    /// The credential paths above that are single files.
    static let credentialFilePaths: Set<String> = [
        ".netrc", ".git-credentials", ".npmrc", ".pypirc", ".pgpass", ".cargo/credentials",
        ".cargo/credentials.toml", ".terraform.d/credentials.tfrc.json",
    ]
    /// iCloud Drive and File Provider storage in `~/Library`.
    static let cloudLibraryFolderNames: Set<String> = ["Mobile Documents", "CloudStorage"]
    /// `~/Library` folders of system and personal data.
    static let libraryFolderNames: Set<String> = [
        "Keychains", "Mail", "Messages", "Safari", "Accounts", "Calendars", "HomeKit", "Passes",
        "Autosave Information", "Biome", "IdentityServices", "Sharing", "Suggestions", "Metadata",
        "Daemon Containers", "Reminders", "Shortcuts",
    ]
    /// `~/Library` folders where apps and the system keep entries side by side.
    static let sharedLibraryFolderNames: Set<String> = ["Containers", "Group Containers", "Application Support"]
    /// System stores in those folders whose names do not carry `com.apple`:
    /// contacts, call history, Screen Time, the File Provider and iCloud
    /// Drive databases, and the Shortcuts group containers (D54 ①, second
    /// review P2-1).
    static let sharedEntryNames: Set<String> = [
        "AddressBook", "CallHistoryDB", "Knowledge",
        "FileProvider", "CloudDocs", "iCloud", "CallHistoryTransactions", "DifferentialPrivacy", "Dock",
        "group.is.workflow.shortcuts", "group.is.workflow.my.app",
    ]
    /// This app's data folder for every identity (release, beta).
    static var appDataRelativePaths: [String] {
        [false, true].map { "Library/Application Support/" + AppDataDirectories.applicationSupportDirectoryName(isBeta: $0) }
    }
    /// The integration identity keeps its data in folders starting with this.
    static let integrationDataPrefix = "Library/Caches/StorageCleanerIntegration-"

    static let foldedCredentialPaths: [String] = credentialPaths.map(folded)
    static let foldedAppDataRelativePaths: [String] = appDataRelativePaths.map(folded)
    static let foldedIntegrationDataPrefix = folded(integrationDataPrefix)
    private static let foldedCloudLibraryFolderNames = Set(cloudLibraryFolderNames.map(folded))
    private static let foldedLibraryFolderNames = Set(libraryFolderNames.map(folded))
    private static let foldedSharedLibraryFolderNames = Set(sharedLibraryFolderNames.map(folded))
    private static let foldedSharedEntryNames = Set(sharedEntryNames.map(folded))
    /// Every location above as one folded path, for "holds one".
    private static let foldedLocationPaths: [String] = foldedCredentialPaths + foldedAppDataRelativePaths
        + (cloudLibraryFolderNames.union(libraryFolderNames)).map { folded("Library/" + $0) }
        + sharedLibraryFolderNames.flatMap { shared in sharedEntryNames.map { folded("Library/\(shared)/\($0)") } }
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    /// Case folded and in NFC; accents are kept.
    static func folded(_ name: String) -> String {
        name.folding(options: [.caseInsensitive], locale: foldingLocale)
            .precomposedStringWithCanonicalMapping
    }

    /// The location `parts` (folded components of a home-relative path) is
    /// or lies inside, if any.
    static func kind(ofFoldedParts parts: [String]) -> Kind? {
        let relative = parts.joined(separator: "/")
        if foldedAppDataRelativePaths.contains(where: { contains(relative, in: $0) })
            || relative.hasPrefix(foldedIntegrationDataPrefix) {
            return .appData
        }
        if parts.count >= 2, parts[0] == "library" {
            if foldedCloudLibraryFolderNames.contains(parts[1]) { return .cloudStorage }
            if foldedLibraryFolderNames.contains(parts[1]) { return .systemData }
            if parts.count >= 3, foldedSharedLibraryFolderNames.contains(parts[1]),
               foldedSharedEntryNames.contains(parts[2]) {
                return .systemData
            }
        }
        if foldedCredentialPaths.contains(where: { contains(relative, in: $0) }) { return .credentials }
        return nil
    }

    /// `kind(ofFoldedParts:)` for a home-relative path as written.
    static func kind(ofHomeRelative path: String) -> Kind? {
        kind(ofFoldedParts: folded(path).split(separator: "/").map(String.init))
    }

    /// Whether a folder at `parts` holds a location (the home folder holds them all).
    static func holdsLocation(foldedParts parts: [String]) -> Bool {
        let relative = parts.joined(separator: "/")
        let prefix = relative.isEmpty ? "" : relative + "/"
        return foldedLocationPaths.contains { $0.hasPrefix(prefix) }
            || foldedIntegrationDataPrefix.hasPrefix(prefix)
    }

    /// Uninstall and cleanup: whether `path` is, lies inside or holds a
    /// location. Both paths are spelled the same way (lexical or resolved);
    /// a path outside `homePath` is left to the flow's own roots.
    static func protects(path: String, homePath: String) -> Bool {
        let foldedPath = folded(path)
        let foldedHome = folded(homePath)
        let relative: Substring
        if foldedPath == foldedHome {
            relative = ""
        } else if foldedPath.hasPrefix(foldedHome + "/") {
            relative = foldedPath.dropFirst(foldedHome.count + 1)
        } else {
            return false
        }
        let parts = relative.split(separator: "/").map(String.init)
        return kind(ofFoldedParts: parts) != nil || holdsLocation(foldedParts: parts)
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        !root.isEmpty && (path == root || path.hasPrefix(root + "/"))
    }
}
