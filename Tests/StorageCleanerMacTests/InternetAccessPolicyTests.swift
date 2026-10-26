import Foundation
import XCTest
@testable import StorageCleanerMac

/// D116: Resources/InternetAccessPolicy.plist tells Little Snitch why the app
/// connects where it does (help.obdev.at/littlesnitch5/ra-developers). These
/// tests keep it in step with the code: every file that opens a connection is
/// listed here with the policy hosts it relies on, every fixed address in those
/// files and in the build scripts is covered by a named host, every text has
/// an English and a Chinese entry, and both packaging scripts ship the files.
final class InternetAccessPolicyTests: XCTestCase {
    private static let fallback = "*"
    private static let gitHub = "github.com, *.githubusercontent.com"

    /// Each file that opens connections, with the policy entries (by `Host`)
    /// that describe them. A new file that connects must be added here and,
    /// if it reaches a new place, to the policy.
    private static let networkingFiles: [String: [String]] = [
        "Sources/StorageCleanerMac/Services/AppUpdater.swift": [gitHub],
        "Sources/StorageCleanerMac/Features/AppUpdates/OfficialSources/RemoteOfficialSourceRegistry.swift": [gitHub],
        "Sources/StorageCleanerMac/Features/AppUpdates/WebsiteUpdates/OfficialGitHubReleaseAdapter.swift":
            ["api.github.com", gitHub],
        "Sources/StorageCleanerMac/Features/AppUpdates/Providers/AppStoreCatalogResolver.swift": ["itunes.apple.com"],
        "Sources/StorageCleanerMac/Features/AppUpdates/Providers/SparkleProvider.swift": [fallback],
        "Sources/StorageCleanerMac/Features/AppUpdates/Providers/SparkleAutomaticUpdateAdapter.swift": [fallback],
        "Sources/StorageCleanerMac/Features/AppUpdates/WebsiteUpdates/OfficialApplicationUpdateInstaller.swift": [fallback],
        "Sources/StorageCleanerMac/Services/NetworkCompatibilitySpeedTestService.swift": ["speed.cloudflare.com"],
        "Sources/StorageCleanerMac/Services/PublicNetworkAddressService.swift":
            ["api.ipify.org, api6.ipify.org", "api.country.is"],
        "Sources/StorageCleanerMac/Services/Benchmark/MacBenchmarkLeaderboardService.swift":
            ["storage-cleaner-benchmark-leaderboard.yangyihang96.workers.dev"],
        "Sources/StorageCleanerMac/Services/Benchmark/BenchmarkV7LeaderboardService.swift":
            ["storage-cleaner-benchmark-leaderboard.yangyihang96.workers.dev"],
        // The shared bounded reader; its callers above name the hosts.
        "Sources/StorageCleanerMac/Services/BoundedHTTPSReader.swift": [],
    ]

    private static let networkTokens = [
        "URLSession", "URLRequest(", "BoundedHTTPSReader.data(", "SPUUpdater(", "SPUStandardUpdaterController(",
        "NWConnection", "NSURLConnection", "WKWebView", "CFReadStreamCreateForHTTPRequest", "CFHTTPMessage",
    ]

    func testThePolicyHasTheDocumentedShape() throws {
        let policy = try policy()
        XCTAssertTrue(Set(policy.keys).isSubset(of: ["ApplicationDescription", "DeveloperName", "Website", "Connections", "Services"]),
                      "\(policy.keys.sorted())")
        XCTAssertFalse(try XCTUnwrap(policy["ApplicationDescription"] as? String).isEmpty)
        let connections = try connections(policy)
        XCTAssertFalse(connections.isEmpty)
        var seenHosts = Set<String>()
        for connection in connections {
            XCTAssertTrue(Set(connection.keys).isSubset(of: [
                "IsIncoming", "Host", "NetworkProtocol", "Port", "Relevance", "Purpose", "DenyConsequences",
            ]), "\(connection.keys.sorted())")
            let host = try XCTUnwrap(connection["Host"] as? String)
            XCTAssertFalse(try XCTUnwrap(connection["Purpose"] as? String).isEmpty, host)
            XCTAssertFalse(try XCTUnwrap(connection["DenyConsequences"] as? String).isEmpty, host)
            XCTAssertNotEqual(connection["IsIncoming"] as? Bool, true, "The app listens for nothing: \(host)")
            // Every connection is HTTPS: the app declares no App Transport Security exception.
            XCTAssertEqual(connection["Port"] as? String, "443", host)
            for pattern in Self.patterns(host) {
                XCTAssertNotNil(pattern.range(of: #"^(\*|(\*\.)?[a-z0-9-]+(\.[a-z0-9-]+)+)$"#, options: .regularExpression),
                                "Not a host or domain: \(pattern)")
                XCTAssertTrue(seenHosts.insert(pattern).inserted, "Listed twice: \(pattern)")
            }
        }
        XCTAssertEqual(connections.filter { $0["Host"] as? String == Self.fallback }.count, 1,
                       "Third-party update sites are named by each app or by the signed source list")
        for script in ["script/build_and_run.sh", "script/make_release_dmg.sh"] {
            XCTAssertFalse(try text(script).contains("NSAppTransportSecurity"), script)
        }
    }

    func testEveryTextHasAnEnglishAndAChineseEntry() throws {
        let policy = try policy()
        var texts = [try XCTUnwrap(policy["ApplicationDescription"] as? String)]
        for connection in try connections(policy) {
            texts.append(try XCTUnwrap(connection["Purpose"] as? String))
            texts.append(try XCTUnwrap(connection["DenyConsequences"] as? String))
        }
        XCTAssertEqual(Set(texts).count, texts.count, "Each text is its own key")
        let english = try table("en")
        let chinese = try table("zh-Hans")
        XCTAssertEqual(Set(english.keys), Set(texts))
        XCTAssertEqual(Set(chinese.keys), Set(texts))
        for key in texts {
            XCTAssertEqual(english[key], key)
            let translated = try XCTUnwrap(chinese[key])
            XCTAssertNotEqual(translated, key)
            XCTAssertTrue(translated.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, translated)
            XCTAssertFalse(translated.contains("Sparkle"), translated)
        }
    }

    func testEveryNetworkingFileIsListedAndItsAddressesAreNamed() throws {
        let code = try SwiftSourceScanning.sourceCode()
        let connecting = Set(code.compactMap { path, text in
            Self.networkTokens.contains { text.contains($0) } ? path : nil
        })
        XCTAssertEqual(connecting, Set(Self.networkingFiles.keys),
                       "A file that opens connections must be listed here and its hosts declared in InternetAccessPolicy.plist")

        let declared = Set(try connections(policy()).compactMap { $0["Host"] as? String })
        let raw = try SwiftSourceScanning.sources()
        for (path, hosts) in Self.networkingFiles {
            for host in hosts {
                XCTAssertTrue(declared.contains(host), "\(path) relies on an undeclared entry: \(host)")
            }
            // A fixed address in a connecting file needs a named entry, not only the fallback.
            let text = try XCTUnwrap(raw[path], path)
            for address in Self.addresses(in: text) {
                XCTAssertTrue(try covers(address), "\(path): \(address)")
            }
        }
    }

    func testTheAddressesTheAppUsesAreCoveredByNamedEntries() throws {
        let registry = try XCTUnwrap(OfficialSourceRegistryRemoteConfiguration.production)
        let fixed: [String?] = [
            PublicNetworkAddressService.ipv4Endpoint.host,
            PublicNetworkAddressService.ipv6Endpoint.host,
            PublicNetworkAddressService.countryEndpoint.host,
            NetworkCompatibilitySpeedTestService.defaultDownloadEndpoint.host,
            NetworkCompatibilitySpeedTestService.defaultUploadEndpoint.host,
            NetworkCompatibilitySpeedTestService.allowedHost,
            registry.remoteURL.host,
        ]
        XCTAssertFalse(fixed.contains(nil))
        var hosts = fixed.compactMap { $0 } + registry.allowedHosts.sorted()
        // The update feeds (release and Beta) and the leaderboard come from the build scripts.
        for script in ["script/build_and_run.sh", "script/make_release_dmg.sh"] {
            let feeds = try text(script).components(separatedBy: "\n").filter { $0.contains("UPDATE_FEED_URL=\"https://") }
            XCTAssertFalse(feeds.isEmpty, script)
            hosts += feeds.flatMap { Self.addresses(in: $0) }
        }
        let leaderboard = try text("script/release_version.env").components(separatedBy: "\n")
            .filter { $0.hasPrefix("DEFAULT_LEADERBOARD_API_URL=") }
        XCTAssertEqual(leaderboard.count, 1)
        hosts += leaderboard.flatMap { Self.addresses(in: $0) }

        XCTAssertGreaterThanOrEqual(hosts.count, 11)
        for host in hosts {
            XCTAssertTrue(try covers(host), host)
        }
    }

    func testBothPackagingScriptsShipThePolicyAndItsTranslations() throws {
        let copy = #"copy_resource_file "$ROOT_DIR/Resources/InternetAccessPolicy.plist" "$APP_RESOURCES/InternetAccessPolicy.plist""#
        let languages = #"find "$ROOT_DIR/Resources" -maxdepth 1 -type d -name '*.lproj' -exec sh -c '/usr/bin/ditto --norsrc "$1" "$2/$(basename "$1")"' sh {} "$APP_RESOURCES" \;"#
        let beta = try text("script/build_and_run.sh")
        let release = try text("script/make_release_dmg.sh")
        for (name, script) in [("build_and_run.sh", beta), ("make_release_dmg.sh", release)] {
            XCTAssertEqual(SwiftSourceScanning.occurrences(of: copy, in: script), 1, name)
            XCTAssertEqual(SwiftSourceScanning.occurrences(of: languages, in: script), 1, name)
        }
        for file in ["InternetAccessPolicy.plist", "en.lproj/InternetAccessPolicy.strings", "zh-Hans.lproj/InternetAccessPolicy.strings"] {
            XCTAssertTrue(beta.contains("cmp -s \"$ROOT_DIR/Resources/\(file)\" \"$APP_RESOURCES/\(file)\""), file)
        }
        XCTAssertTrue(release.contains(
            "for policy_file in InternetAccessPolicy.plist en.lproj/InternetAccessPolicy.strings zh-Hans.lproj/InternetAccessPolicy.strings; do"
        ))
        XCTAssertTrue(release.contains(#"if ! cmp -s "$ROOT_DIR/Resources/$policy_file" "$app_path/Contents/Resources/$policy_file"; then"#))
    }

    // MARK: - Helpers

    private func policy() throws -> [String: Any] {
        let data = try Data(contentsOf: SwiftSourceScanning.projectRoot.appendingPathComponent("Resources/InternetAccessPolicy.plist"))
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func connections(_ policy: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(policy["Connections"] as? [[String: Any]])
    }

    private func table(_ language: String) throws -> [String: String] {
        try text("Resources/\(language).lproj/InternetAccessPolicy.strings").propertyListFromStringsFileFormat()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: SwiftSourceScanning.projectRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// A named (non-fallback) entry covers the host: the same host, or a domain entry `*.<domain>` above it.
    private func covers(_ host: String) throws -> Bool {
        let host = host.lowercased()
        return try connections(policy()).compactMap { $0["Host"] as? String }.flatMap(Self.patterns).contains { pattern in
            pattern != Self.fallback && (pattern == host || (pattern.hasPrefix("*.") && host.hasSuffix(String(pattern.dropFirst()))))
        }
    }

    private static func patterns(_ host: String) -> [String] {
        host.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Hosts of the `https://` addresses written in a text.
    private static func addresses(in text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"https://([A-Za-z0-9.-]+)"#)
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]).lowercased() }
        }
    }
}
