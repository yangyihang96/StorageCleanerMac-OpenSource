import Foundation

struct UserConfirmedOfficialSourceRecord: Codable, Hashable, Sendable {
    let applicationIdentity: ApplicationIdentity
    let developerName: String?
    let homepageURL: URL
    let updatePageURL: URL?
    let confirmedAt: Date

    var id: String {
        [
            applicationIdentity.bundleIdentifier,
            applicationIdentity.signingTeamIdentifier ?? "-",
            applicationIdentity.codeSigningIdentifier ?? "-"
        ].joined(separator: "|")
    }

    func matches(_ application: InstalledApplication) -> Bool {
        guard application.bundleIdentifier == applicationIdentity.bundleIdentifier else { return false }
        if let team = applicationIdentity.signingTeamIdentifier?.trimmed.nonEmpty {
            return application.signingTeamIdentifier == team
        }
        if let identifier = applicationIdentity.codeSigningIdentifier?.trimmed.nonEmpty {
            return application.codeSigningIdentifier == identifier
        }
        // Bundle-only user confirmations are intentionally limited to opening a
        // page. They never become automatic-download trust.
        return true
    }
}

protocol UserConfirmedSourceStoring: Sendable {
    func load() async throws -> [UserConfirmedOfficialSourceRecord]
    func save(_ records: [UserConfirmedOfficialSourceRecord]) async throws
}

actor FileUserConfirmedSourceStore: UserConfirmedSourceStoring {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> [UserConfirmedOfficialSourceRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([UserConfirmedOfficialSourceRecord].self, from: data)
    }

    func save(_ records: [UserConfirmedOfficialSourceRecord]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

actor InMemoryUserConfirmedSourceStore: UserConfirmedSourceStoring {
    private var records: [UserConfirmedOfficialSourceRecord]

    init(records: [UserConfirmedOfficialSourceRecord] = []) {
        self.records = records
    }

    func load() -> [UserConfirmedOfficialSourceRecord] { records }
    func save(_ records: [UserConfirmedOfficialSourceRecord]) { self.records = records }
}

enum OfficialSourceRegistryError: Error, Equatable, LocalizedError, Sendable {
    case invalidUserConfirmedURL
    case expiredOrUnverifiedSnapshot

    var errorDescription: String? {
        switch self {
        case .invalidUserConfirmedURL:
            return L10n.text("只能保存经过 HTTPS 域名校验的官网。", "Only an HTTPS website with a valid host can be saved.")
        case .expiredOrUnverifiedSnapshot:
            return L10n.text("来源注册表已过期或未通过签名验证。", "The source registry is expired or has not passed signature verification.")
        }
    }
}

actor OfficialSourceRegistry {
    private let builtInEntries: [OfficialSourceRegistryEntry]
    private let userStore: any UserConfirmedSourceStoring
    private var signedSnapshot: OfficialSourceRegistrySnapshot?
    private var userRecords: [UserConfirmedOfficialSourceRecord] = []
    private var didLoadUserRecords = false

    init(
        builtInEntries: [OfficialSourceRegistryEntry] = OfficialSourceRegistry.bundledEntries,
        userStore: (any UserConfirmedSourceStoring)? = nil
    ) {
        self.builtInEntries = builtInEntries
        if let userStore {
            self.userStore = userStore
        } else {
            self.userStore = FileUserConfirmedSourceStore(fileURL: Self.defaultUserRegistryURL)
        }
    }

    func installVerifiedSnapshot(_ snapshot: OfficialSourceRegistrySnapshot, now: Date = Date()) throws {
        guard !snapshot.isExpired, snapshot.payload.expiresAt > now else {
            throw OfficialSourceRegistryError.expiredOrUnverifiedSnapshot
        }
        if let current = signedSnapshot,
           snapshot.payload.sequence < current.payload.sequence {
            throw OfficialSourceRegistryError.expiredOrUnverifiedSnapshot
        }
        signedSnapshot = snapshot
    }

    func source(for application: InstalledApplication, now: Date = Date()) async -> OfficialUpdateSource? {
        await ensureUserRecordsLoaded()

        if let signedSnapshot,
           !signedSnapshot.isExpired,
           signedSnapshot.payload.expiresAt > now,
           let entry = signedSnapshot.payload.entries.first(where: {
               $0.matches(application) && Self.satisfiesDesignatedRequirement($0, application: application)
           }) {
            return entry.source(for: application)
        }
        if let entry = builtInEntries.first(where: {
            $0.matches(application) && Self.satisfiesDesignatedRequirement($0, application: application)
        }) {
            return Self.builtInSource(entry, application: application)
        }
        if let record = userRecords.first(where: { $0.matches(application) }) {
            return Self.userConfirmedSource(record, application: application)
        }
        return nil
    }

    func confirmWebsite(
        for application: InstalledApplication,
        homepageURL: URL,
        updatePageURL: URL? = nil,
        developerName: String? = nil,
        confirmedAt: Date = Date()
    ) async throws {
        let host = try Self.validatedSingleHostURL(homepageURL)
        if let updatePageURL {
            try AllowedHostValidator().validate(updatePageURL, allowedHosts: [host])
        }
        await ensureUserRecordsLoaded()
        let record = UserConfirmedOfficialSourceRecord(
            applicationIdentity: application.identity,
            developerName: developerName?.trimmed.nonEmpty,
            homepageURL: homepageURL,
            updatePageURL: updatePageURL,
            confirmedAt: confirmedAt
        )
        userRecords.removeAll { $0.id == record.id }
        userRecords.append(record)
        try await userStore.save(userRecords.sorted { $0.id < $1.id })
    }

    func revokeUserConfirmation(for application: InstalledApplication) async throws {
        await ensureUserRecordsLoaded()
        userRecords.removeAll { $0.matches(application) }
        try await userStore.save(userRecords)
    }

    func userConfirmations() async -> [UserConfirmedOfficialSourceRecord] {
        await ensureUserRecordsLoaded()
        return userRecords
    }

    func reloadUserConfirmations() async {
        userRecords = (try? await userStore.load()) ?? []
        didLoadUserRecords = true
    }

    private func ensureUserRecordsLoaded() async {
        guard !didLoadUserRecords else { return }
        didLoadUserRecords = true
        userRecords = (try? await userStore.load()) ?? []
    }

    private static func validatedSingleHostURL(_ url: URL) throws -> String {
        guard let rawHost = url.host else { throw OfficialSourceRegistryError.invalidUserConfirmedURL }
        let host = try AllowedHostValidator.normalizedHost(rawHost)
        do {
            try AllowedHostValidator().validate(url, allowedHosts: [host])
            return host
        } catch {
            throw OfficialSourceRegistryError.invalidUserConfirmedURL
        }
    }

    private static func userConfirmedSource(
        _ record: UserConfirmedOfficialSourceRecord,
        application: InstalledApplication
    ) -> OfficialUpdateSource {
        let host = record.homepageURL.host?.lowercased() ?? ""
        return OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: .officialWebsite,
            developerName: record.developerName,
            homepageURL: record.homepageURL,
            updatePageURL: record.updatePageURL,
            releaseFeedURL: nil,
            directDownloadURL: nil,
            allowedHosts: host.isEmpty ? [] : [host],
            expectedBundleIdentifier: application.bundleIdentifier,
            expectedTeamIdentifier: application.signingTeamIdentifier,
            expectedDesignatedRequirement: nil,
            verificationMethod: .userConfirmation,
            trustLevel: .userConfirmed,
            lastVerifiedAt: record.confirmedAt,
            capability: .manualWebsite,
            expectedPackageExtensions: [],
            officialGitHubRepository: nil
        )
    }

    private static func satisfiesDesignatedRequirement(
        _ entry: OfficialSourceRegistryEntry,
        application: InstalledApplication
    ) -> Bool {
        guard let expected = entry.expectedDesignatedRequirement?.trimmed.nonEmpty else {
            return true
        }
        guard let result = try? CodeSignatureVerifier().verifyCode(at: application.bundleURL) else {
            return false
        }
        return result.designatedRequirement == expected
    }

    private static func builtInSource(
        _ entry: OfficialSourceRegistryEntry,
        application: InstalledApplication
    ) -> OfficialUpdateSource {
        OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: entry.providerType,
            developerName: entry.developerName,
            homepageURL: entry.homepageURL,
            updatePageURL: entry.updatePageURL,
            releaseFeedURL: entry.releaseFeedURL,
            directDownloadURL: entry.directDownloadURL,
            allowedHosts: entry.allowedHosts,
            expectedBundleIdentifier: entry.bundleIdentifier,
            expectedTeamIdentifier: entry.signingTeamIdentifier,
            expectedDesignatedRequirement: entry.expectedDesignatedRequirement,
            verificationMethod: .vendorManifest,
            trustLevel: .verified,
            lastVerifiedAt: entry.lastVerifiedAt,
            capability: entry.capability,
            expectedPackageExtensions: entry.expectedPackageExtensions,
            officialGitHubRepository: entry.officialGitHubRepository
        )
    }

    private static var defaultUserRegistryURL: URL {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("OfficialSources", isDirectory: true)
            .appendingPathComponent("user-confirmed.json", isDirectory: false)
    }

    /// The bundled registry is deliberately small. New third-party mappings are
    /// added only with reproducible identity/domain evidence, never by app name.
    static var bundledEntries: [OfficialSourceRegistryEntry] {
        guard let storageCleanerHomepage = URL(
            string: "https://github.com/yangyihang96/StorageCleanerMacUpdates"
        ), let storageCleanerReleases = URL(
            string: "https://github.com/yangyihang96/StorageCleanerMacUpdates/releases"
        ), let drawIOHomepage = URL(
            string: "https://github.com/jgraph/drawio-desktop"
        ), let drawIOReleases = URL(
            string: "https://github.com/jgraph/drawio-desktop/releases"
        ), let ccSwitchHomepage = URL(
            string: "https://github.com/farion1231/cc-switch"
        ), let ccSwitchReleases = URL(
            string: "https://github.com/farion1231/cc-switch/releases"
        ) else {
            return []
        }
        return [
            OfficialSourceRegistryEntry(
                bundleIdentifier: "com.local.StorageCleanerMac",
                signingTeamIdentifier: "T9GZL52H8R",
                codeSigningIdentifier: "com.local.StorageCleanerMac",
                developerName: "yangyihang96",
                homepageURL: storageCleanerHomepage,
                updatePageURL: storageCleanerReleases,
                releaseFeedURL: nil,
                directDownloadURL: nil,
                allowedHosts: ["github.com"],
                expectedDesignatedRequirement: nil,
                providerType: .officialGitHubRelease,
                capability: .manualWebsite,
                expectedPackageExtensions: ["zip"],
                officialGitHubRepository: "yangyihang96/StorageCleanerMacUpdates",
                lastVerifiedAt: Date(timeIntervalSince1970: 1_768_780_800)
            ),
            OfficialSourceRegistryEntry(
                bundleIdentifier: "com.jgraph.drawio.desktop",
                signingTeamIdentifier: "UZEUFB4N53",
                codeSigningIdentifier: nil,
                developerName: "JGraph",
                homepageURL: drawIOHomepage,
                updatePageURL: drawIOReleases,
                releaseFeedURL: nil,
                directDownloadURL: nil,
                allowedHosts: OfficialGitHubRepositoryPolicy.assetDownloadHosts,
                expectedDesignatedRequirement: nil,
                providerType: .officialGitHubRelease,
                capability: .automatic,
                expectedPackageExtensions: [OfficialPackageType.diskImage.rawValue],
                officialGitHubRepository: "jgraph/drawio-desktop",
                lastVerifiedAt: Date(timeIntervalSince1970: 1_785_679_200)
            ),
            OfficialSourceRegistryEntry(
                bundleIdentifier: "com.ccswitch.desktop",
                signingTeamIdentifier: "R8UR22V2F9",
                codeSigningIdentifier: nil,
                developerName: "farion1231",
                homepageURL: ccSwitchHomepage,
                updatePageURL: ccSwitchReleases,
                releaseFeedURL: nil,
                directDownloadURL: nil,
                allowedHosts: OfficialGitHubRepositoryPolicy.assetDownloadHosts,
                expectedDesignatedRequirement: nil,
                providerType: .officialGitHubRelease,
                capability: .automatic,
                expectedPackageExtensions: [OfficialPackageType.diskImage.rawValue],
                officialGitHubRepository: "farion1231/cc-switch",
                lastVerifiedAt: Date(timeIntervalSince1970: 1_785_679_200)
            )
        ]
    }
}
