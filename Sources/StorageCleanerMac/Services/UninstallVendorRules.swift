import Foundation

/// Curated paths from vendor instructions, never display-name matching (D87).
///
/// Two kinds of entries:
/// - `rules` may issue `vendorRule` ownership evidence. Each one is bound to an
///   exact bundle identifier, the vendor's Team ID, an exact relative path
///   under the user's Library, and an official vendor page. The verifier still
///   requires a valid Apple-anchored signature whose identifier equals the
///   bundle ID, a complete inventory and a single installation before the
///   evidence is issued. A wrong or unknown Team ID only makes a rule inert.
/// - `discoveryOnly` paths are shown for review and never become selectable:
///   shared group containers, shared vendor folders, data folders whose
///   ownership cannot be proved (for example a profile shared by browser
///   channels) and folders without an obtained official source.
///
/// Paths outside the existing safe related roots (Application Support,
/// Caches, Preferences, Containers, Group Containers) are intentionally not
/// listed; `AppUninstallService.isSafeRelatedPath` would reject them anyway.
enum UninstallVendorRules {
    struct Rule: Sendable, Equatable {
        let relativePath: String
        let source: String
        let revision: String
    }

    /// One documented vendor entry, also used by the maintenance tests.
    struct Entry: Sendable {
        let bundleID: String
        let teamID: String
        let source: String
        let revision: String
        /// Relative paths for an application version; empty when the version
        /// is outside what the source describes.
        let paths: @Sendable (_ version: String) -> [String]
    }

    static let microsoftTeamID = "UBF8T346G9"
    static let googleTeamID = "EQHXZ8M8AV"
    static let spotifyTeamID = "2FNC3A47ZF"
    static let dockerTeamID = "9BNSXJN65R"
    static let discordTeamID = "53Q6R32WPB"
    static let figmaTeamID = "T8RA8NE3B7"
    static let jetBrainsTeamID = "2ZEFAR8TH3"

    static let teamsSource = "https://learn.microsoft.com/en-us/troubleshoot/microsoftteams/teams-administration/clear-teams-cache"
    static let chromeSource = "https://support.google.com/chrome/answer/95319?hl=en&co=GENIE.Platform%3DDesktop"
    static let spotifySource = "https://support.spotify.com/us/article/clean-reinstall/"
    static let dockerSource = "https://docs.docker.com/desktop/uninstall/"
    static let discordSource = "https://support.discord.com/hc/en-us/articles/360022082931"
    static let figmaSource = "https://help.figma.com/hc/en-us/articles/22380853110551-Clear-the-Figma-desktop-app-cache"

    /// JetBrains IDE bundle ID -> the `<product>` part of `<product><version>`
    /// from each IDE's own uninstall page.
    static let jetBrainsProducts: [(bundleID: String, product: String, source: String)] = [
        ("com.jetbrains.intellij", "IntelliJIdea", "https://www.jetbrains.com/help/idea/uninstall.html"),
        ("com.jetbrains.pycharm", "PyCharm", "https://www.jetbrains.com/help/pycharm/uninstall.html"),
        ("com.jetbrains.WebStorm", "WebStorm", "https://www.jetbrains.com/help/webstorm/uninstall.html"),
        ("com.jetbrains.goland", "GoLand", "https://www.jetbrains.com/help/go/uninstall.html"),
        ("com.jetbrains.CLion", "CLion", "https://www.jetbrains.com/help/clion/uninstall.html"),
        ("com.jetbrains.PhpStorm", "PhpStorm", "https://www.jetbrains.com/help/phpstorm/uninstall.html"),
    ]

    static let entries: [Entry] = {
        var result: [Entry] = [
            // Existing revisions are kept verbatim: saved receipts reference them.
            Entry(bundleID: "com.microsoft.VSCode", teamID: microsoftTeamID,
                  source: UninstallOwnershipVerifier.vscodeSource, revision: "vscode-stable-1-data-v1",
                  paths: { $0.split(separator: ".").first == "1" ? ["Library/Application Support/Code"] : [] }),
            Entry(bundleID: "com.microsoft.teams2", teamID: microsoftTeamID, source: teamsSource,
                  revision: "teams-macos-container-20260914-v1",
                  paths: { _ in ["Library/Containers/com.microsoft.teams2"] }),
            Entry(bundleID: "com.microsoft.teams", teamID: microsoftTeamID, source: teamsSource,
                  revision: "teams-classic-macos-data-20260914-v1",
                  paths: { _ in ["Library/Application Support/Microsoft/Teams"] }),
            // Stable channel only: Beta/Dev/Canary use their own bundle IDs and folders.
            Entry(bundleID: "com.google.Chrome", teamID: googleTeamID, source: chromeSource,
                  revision: "chrome-stable-profile-20261012-v1",
                  paths: { _ in ["Library/Application Support/Google/Chrome"] }),
            Entry(bundleID: "com.spotify.client", teamID: spotifyTeamID, source: spotifySource,
                  revision: "spotify-clean-reinstall-20261012-v1",
                  paths: { _ in [
                      "Library/Caches/com.spotify.client",
                      "Library/Caches/com.spotify.client.helper",
                      "Library/Application Support/Spotify",
                  ] }),
            Entry(bundleID: "com.docker.docker", teamID: dockerTeamID, source: dockerSource,
                  revision: "docker-desktop-container-20261012-v1",
                  paths: { _ in ["Library/Containers/com.docker.docker"] }),
            Entry(bundleID: "com.hnc.Discord", teamID: discordTeamID, source: discordSource,
                  revision: "discord-user-support-20261012-v1",
                  paths: { _ in ["Library/Application Support/Discord"] }),
            Entry(bundleID: "com.figma.Desktop", teamID: figmaTeamID, source: figmaSource,
                  revision: "figma-desktop-support-20261012-v1",
                  paths: { _ in ["Library/Application Support/Figma"] }),
        ]
        for product in jetBrainsProducts {
            let name = product.product
            result.append(Entry(bundleID: product.bundleID, teamID: jetBrainsTeamID, source: product.source,
                revision: "jetbrains-\(name.lowercased())-versioned-20261012-v1",
                paths: { version in
                    guard let folder = jetBrainsVersionFolder(version) else { return [] }
                    return [
                        "Library/Application Support/JetBrains/" + name + folder,
                        "Library/Caches/JetBrains/" + name + folder,
                    ]
                }))
        }
        return result
    }()

    /// Discovery-only candidates (never ownership evidence). Values are
    /// relative to the home directory.
    static let discoveryOnlyPaths: [String: [String]] = [
        "com.microsoft.teams2": ["Library/Group Containers/UBF8T346G9.com.microsoft.teams"],
        // Shared app group named in Docker's uninstall page.
        "com.docker.docker": ["Library/Group Containers/group.com.docker"],
        // Profiles can be shared by several browser channels.
        "com.microsoft.edgemac": ["Library/Application Support/Microsoft Edge", "Library/Caches/Microsoft Edge"],
        "org.mozilla.firefox": ["Library/Application Support/Firefox", "Library/Caches/Firefox"],
        "com.tinyspeck.slackmacgap": ["Library/Application Support/Slack"],
        "us.zoom.xos": ["Library/Application Support/zoom.us"],
        "notion.id": ["Library/Application Support/Notion"],
        "ru.keepcoder.Telegram": ["Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram"],
        "org.telegram.desktop": ["Library/Application Support/Telegram Desktop"],
        "com.tencent.xinWeChat": ["Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat"],
        // Toolbox keeps IDE installations under this folder.
        "com.jetbrains.toolbox": ["Library/Application Support/JetBrains/Toolbox"],
        // Explicitly nothing: Adobe's shared components and Dropbox's synced
        // folder or File Provider storage are never uninstall leftovers here.
        "com.adobe.acc.AdobeCreativeCloud": [],
        "com.getdropbox.dropbox": [],
    ]

    /// High-value data that a documented rule may still prove owned. The
    /// review labels it and "Select All Verified" never includes it; the user
    /// has to tick it on its own.
    enum HighValueData: String, Sendable, CaseIterable {
        case personalProfile
        case imagesAndVolumes

        var title: String {
            switch self {
            case .personalProfile: L10n.text("含个人资料", "Contains personal profiles")
            case .imagesAndVolumes: L10n.text("含镜像与数据卷", "Contains images and data volumes")
            }
        }
    }

    static let highValueDataPaths: [String: HighValueData] = [
        // Bookmarks, passwords, history and extensions of every profile.
        "Library/Application Support/Google/Chrome": .personalProfile,
        "Library/Application Support/Microsoft Edge": .personalProfile,
        "Library/Application Support/Firefox": .personalProfile,
        // Docker's disk image with all images, containers and volumes.
        "Library/Containers/com.docker.docker": .imagesAndVolumes,
    ]

    /// Matched on the trailing `Library/...` part so it also holds for a
    /// fixture or another user's home. Erring towards a label only makes a
    /// row stricter (labelled, not bulk-selected); it never makes one selectable.
    static func highValueData(path: String) -> HighValueData? {
        let lexical = PathSafety.lexicalPath(path)
        return highValueDataPaths.first { lexical.hasSuffix("/" + $0.key) }?.value
    }

    /// Vendor-level folders shared by several products. A rule may name a
    /// product folder inside one, never the vendor folder itself.
    static let sharedVendorFolders: Set<String> = [
        "Library/Application Support/Google", "Library/Caches/Google",
        "Library/Application Support/Microsoft", "Library/Caches/Microsoft",
        "Library/Application Support/JetBrains", "Library/Caches/JetBrains",
        "Library/Application Support/Adobe", "Library/Caches/Adobe",
        "Library/Application Support/Mozilla", "Library/Application Support/Docker",
    ]

    /// Discovery-only shared App Group containers (WeChat, Telegram, Docker,
    /// Teams). They are shown by path only: walking another app's group
    /// container to measure it can raise the system "access data from other
    /// apps" prompt, and the rows can never be selected anyway.
    static func unmeasuredDiscoveryPaths(bundleID: String) -> [String] {
        discoveryOnly(bundleID: bundleID).filter { $0.hasPrefix("Library/Group Containers/") }
    }

    static func rules(bundleID: String, version: String, teamID: String) -> [Rule] {
        guard !teamID.isEmpty, UninstallCandidatePathPolicy.isSafeComponent(bundleID) else { return [] }
        return entries.filter { $0.bundleID == bundleID && $0.teamID == teamID }.flatMap { entry in
            entry.paths(version).filter(isSafeRelativePath).map {
                Rule(relativePath: $0, source: entry.source, revision: entry.revision)
            }
        }
    }

    /// Every documented path for this bundle ID and version, whatever the
    /// signer. Used only to show the rows; an unverified signer leaves them
    /// retained with the signature reason instead of hiding them.
    static func discoveryCandidates(bundleID: String, version: String) -> [String] {
        guard UninstallCandidatePathPolicy.isSafeComponent(bundleID) else { return [] }
        return entries.filter { $0.bundleID == bundleID }.flatMap { $0.paths(version) }.filter(isSafeRelativePath)
            + discoveryOnly(bundleID: bundleID)
    }

    static func discoveryOnly(bundleID: String) -> [String] {
        (discoveryOnlyPaths[bundleID] ?? []).filter(isSafeRelativePath)
    }

    /// `2026.2.1` -> `2026.2`. Anything else is outside the documented layout.
    static func jetBrainsVersionFolder(_ version: String) -> String? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].count == 4, !parts[1].isEmpty, parts[1].count <= 2,
              parts[0].allSatisfy(\.isASCIIDigitCharacter), parts[1].allSatisfy(\.isASCIIDigitCharacter),
              let year = Int(parts[0]), year >= 2020 else { return nil }
        return "\(parts[0]).\(parts[1])"
    }

    /// A relative template must stay inside the safe Library roots and must
    /// not be a whole shared root (for example all of Application Support).
    static func isSafeRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 3, components[0] == "Library",
              ["Application Support", "Caches", "Preferences", "Containers", "Group Containers"].contains(components[1]),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }),
              !sharedVendorFolders.contains(path) else { return false }
        return true
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}
