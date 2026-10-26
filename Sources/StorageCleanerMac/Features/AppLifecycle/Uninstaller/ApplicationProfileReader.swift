import Foundation
import Security

/// Reads what the resource finder needs from an application bundle: its
/// identifiers, the helpers it embeds (CleanMyMac `appsInsideBundleAtPath:`),
/// its application groups (`securityApplicationGroupIdentifiers`) and its
/// privileged helpers (`SMPrivilegedExecutables`). Read-only.
enum ApplicationProfileReader {
    /// Folders inside a bundle that hold helpers with their own identifier.
    static let helperFolders = [
        "Contents/Library/LoginItems", "Contents/PlugIns", "Contents/XPCServices",
        "Contents/Library/LaunchServices", "Contents/Helpers", "Contents/Library/SystemExtensions",
        "Contents/Library/QuickLook", "Contents/Library/Spotlight",
    ]

    static func profile(at url: URL, fileManager: FileManager = .default) -> ApplicationProfile? {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              let identifier = (info["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespaces),
              !identifier.isEmpty else { return nil }
        let bundleName = (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let displayName = (info["CFBundleDisplayName"] as? String) ?? bundleName
        let signing = signingInformation(at: url)
        let privileged = (info["SMPrivilegedExecutables"] as? [String: Any]).map { Array($0.keys).sorted() } ?? []
        return ApplicationProfile(
            bundleURL: url,
            bundleIdentifier: identifier,
            displayName: displayName,
            bundleName: bundleName,
            executableName: info["CFBundleExecutable"] as? String,
            version: (info["CFBundleShortVersionString"] as? String) ?? "",
            teamIdentifier: signing.teamIdentifier,
            applicationGroups: signing.applicationGroups,
            helperBundleIdentifiers: helperIdentifiers(in: url, excluding: identifier, fileManager: fileManager),
            privilegedExecutables: privileged
        )
    }

    static func helperIdentifiers(in bundle: URL, excluding own: String, fileManager: FileManager) -> [String] {
        var identifiers = Set<String>()
        for folder in helperFolders {
            let directory = bundle.appendingPathComponent(folder, isDirectory: true)
            guard let children = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for child in children.prefix(200) {
                let plist = child.appendingPathComponent("Contents/Info.plist")
                guard let info = NSDictionary(contentsOf: plist) as? [String: Any],
                      let identifier = info["CFBundleIdentifier"] as? String,
                      UninstallCandidatePathPolicy.isSafeComponent(identifier), identifier != own else { continue }
                identifiers.insert(identifier)
            }
        }
        return identifiers.sorted()
    }

    struct Signing: Sendable {
        var teamIdentifier: String?
        var applicationGroups: [String]
    }

    static func signingInformation(at url: URL) -> Signing {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return Signing(teamIdentifier: nil, applicationGroups: [])
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let values = information as? [String: Any] else {
            return Signing(teamIdentifier: nil, applicationGroups: [])
        }
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let groups = (entitlements["com.apple.security.application-groups"] as? [String] ?? [])
            .filter(UninstallCandidatePathPolicy.isSafeComponent)
        return Signing(teamIdentifier: values[kSecCodeInfoTeamIdentifier as String] as? String,
                       applicationGroups: groups.sorted())
    }
}

/// CleanMyMac's word matching of a resource name against an application name
/// (`isValidApplicationResourceName:matchedByWordsForApplicationName:separators:`,
/// `isValidVersionPattern:forApplicationName:`): both names are split into
/// words at spaces, hyphens, underscores and dots; the resource matches when
/// its words equal the application's, ignoring case and a trailing version.
enum ApplicationNameMatcher {
    static let separators = CharacterSet(charactersIn: " -_.")

    /// Words that never identify an application on their own (CleanMyMac's
    /// list plus folder words every app uses).
    static let genericWords: Set<String> = [
        "maccatalyst", "updater", "service", "launcher", "preferences", "preference", "accounts", "settings",
        "calendars", "contacts", "keychains", "extension", "fileprovider", "findersync",
        "app", "application", "applications", "helper", "helpers", "agent", "daemon", "setup", "installer",
        "install", "uninstall", "uninstaller", "update", "support", "data", "cache", "caches", "logs", "log",
        "library", "plugins", "plugin", "mac", "macos", "osx", "default", "user", "shared", "common", "temp",
        "tmp", "backup", "backups", "files", "documents", "downloads", "desktop", "pictures", "music", "movies",
        "apple", "google", "microsoft", "adobe", "notes", "mail", "photos", "calendar", "reminders", "messages",
    ]

    static func words(_ name: String) -> [String] {
        name.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
    }

    static func isVersionWord(_ word: String) -> Bool {
        let trimmed = word.hasPrefix("v") ? String(word.dropFirst()) : word
        return !trimmed.isEmpty && trimmed.allSatisfy { $0.isNumber }
    }

    /// The application's words, or nil when they are too generic to claim a
    /// folder by name alone (a single generic word or one shorter than three).
    static func identifyingWords(of applicationName: String) -> [String]? {
        var appWords = words(applicationName)
        while let last = appWords.last, isVersionWord(last), appWords.count > 1 { appWords.removeLast() }
        guard !appWords.isEmpty else { return nil }
        if appWords.count == 1 {
            let word = appWords[0]
            guard word.count >= 3, !genericWords.contains(word), !isVersionWord(word) else { return nil }
        }
        return appWords
    }

    static func matches(resourceName: String, applicationName: String) -> Bool {
        guard let appWords = identifyingWords(of: applicationName) else { return false }
        var resourceWords = words(resourceName)
        while let last = resourceWords.last, isVersionWord(last), resourceWords.count > appWords.count {
            resourceWords.removeLast()
        }
        return resourceWords == appWords
    }

    /// `name` is the identifier itself or a name derived from it
    /// (`com.vendor.App.helper`, `com.vendor.App.plist`).
    static func isIdentifierOrDerived(_ name: String, identifier: String) -> Bool {
        let lowerName = name.lowercased()
        let lowerIdentifier = identifier.lowercased()
        return lowerName == lowerIdentifier || lowerName.hasPrefix(lowerIdentifier + ".")
    }
}
