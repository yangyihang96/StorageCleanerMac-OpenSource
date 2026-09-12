import Foundation

struct OfficialReleaseDescriptor: Codable, Hashable, Sendable {
    let version: ApplicationVersion
    let releaseDate: Date?
    let releaseNotes: String?
    let downloadURL: URL?
    let downloadSize: Int64?
    let checksumSHA256: String?

    init(
        version: ApplicationVersion,
        releaseDate: Date? = nil,
        releaseNotes: String? = nil,
        downloadURL: URL? = nil,
        downloadSize: Int64? = nil,
        checksumSHA256: String? = nil
    ) {
        self.version = version
        self.releaseDate = releaseDate
        self.releaseNotes = releaseNotes?.trimmed.nonEmpty
        self.downloadURL = downloadURL
        self.downloadSize = downloadSize
        self.checksumSHA256 = checksumSHA256?.trimmed.lowercased().nonEmpty
    }
}

enum OfficialReleaseCheckOutcome: Hashable, Sendable {
    case updateAvailable(OfficialReleaseDescriptor)
    case upToDate
    case latestVersionUnknown(String?)
}

enum OfficialReleaseCheckerError: Error, Equatable, LocalizedError, Sendable {
    case missingSource
    case sourceNotTrusted
    case noVerifiedAdapter
    case invalidVersion
    case invalidDownloadURL
    case invalidDownloadSize

    var errorDescription: String? {
        switch self {
        case .missingSource:
            return L10n.text("应用没有可用的官方更新来源。", "No official update source is available for this application.")
        case .sourceNotTrusted:
            return L10n.text("更新来源尚未通过项目注册表或 Provider 验证。", "The update source has not been verified by the registry or provider.")
        case .noVerifiedAdapter:
            return L10n.text("没有适用于该官方发布源的已验证适配器。", "No verified adapter supports this official release source.")
        case .invalidVersion:
            return L10n.text("官方发布源返回了无效版本。", "The official release source returned an invalid version.")
        case .invalidDownloadURL:
            return L10n.text("官方发布源返回了未授权的下载地址。", "The official release source returned an unauthorized download URL.")
        case .invalidDownloadSize:
            return L10n.text("官方发布源返回了无效的下载大小。", "The official release source returned an invalid download size.")
        }
    }
}

/// A site/feed adapter is deliberately explicit. Implementations must be tied
/// to a reviewed vendor manifest, API, feed, or repository; this protocol is
/// not a general-purpose HTML scraper.
protocol OfficialReleaseCheckingAdapter: Sendable {
    var identifier: String { get }
    func supports(_ source: OfficialUpdateSource) -> Bool
    func latestRelease(for source: OfficialUpdateSource) async throws -> OfficialReleaseDescriptor?
}

struct OfficialReleaseChecker: Sendable {
    private let adapters: [any OfficialReleaseCheckingAdapter]
    private let hostValidator: AllowedHostValidator

    init(
        adapters: [any OfficialReleaseCheckingAdapter] = [OfficialGitHubReleaseAdapter()],
        hostValidator: AllowedHostValidator = AllowedHostValidator()
    ) {
        self.adapters = adapters
        self.hostValidator = hostValidator
    }

    func check(_ application: InstalledApplication) async throws -> OfficialReleaseCheckOutcome {
        guard let source = application.officialSource else {
            throw OfficialReleaseCheckerError.missingSource
        }
        return try await check(application, source: source)
    }

    func check(
        _ application: InstalledApplication,
        source: OfficialUpdateSource
    ) async throws -> OfficialReleaseCheckOutcome {
        guard source.trustLevel.permitsAutomaticDownload else {
            // User-confirmed and candidate sources may be opened, but their
            // reported versions are not promoted to trusted update metadata.
            throw OfficialReleaseCheckerError.sourceNotTrusted
        }
        guard source.applicationIdentity.bundleIdentifier == application.bundleIdentifier,
              source.expectedBundleIdentifier == application.bundleIdentifier else {
            throw OfficialReleaseCheckerError.sourceNotTrusted
        }
        guard let adapter = adapters.first(where: { $0.supports(source) }) else {
            return .latestVersionUnknown(OfficialReleaseCheckerError.noVerifiedAdapter.localizedDescription)
        }
        guard let release = try await adapter.latestRelease(for: source) else {
            return .latestVersionUnknown(nil)
        }
        try validate(release, source: source)
        guard application.installedVersion < release.version else {
            return .upToDate
        }
        return .updateAvailable(release)
    }

    private func validate(
        _ release: OfficialReleaseDescriptor,
        source: OfficialUpdateSource
    ) throws {
        guard !release.version.preferred.isEmpty else {
            throw OfficialReleaseCheckerError.invalidVersion
        }
        if let downloadSize = release.downloadSize, downloadSize <= 0 {
            throw OfficialReleaseCheckerError.invalidDownloadSize
        }
        if let downloadURL = release.downloadURL {
            do {
                try hostValidator.validate(downloadURL, allowedHosts: source.allowedHosts)
            } catch {
                throw OfficialReleaseCheckerError.invalidDownloadURL
            }
        }
    }
}
