import Foundation

struct ResolvedOfficialDownload: Codable, Hashable, Sendable {
    let source: OfficialUpdateSource
    let remoteURL: URL
    let packageType: OfficialPackageType
    let expectedSize: Int64?
    let checksumSHA256: String?
    let permitsAutomaticInstallation: Bool
}

enum OfficialDownloadResolverError: Error, Equatable, LocalizedError, Sendable {
    case sourceNotTrusted
    case capabilityDoesNotPermitDownload
    case missingDownloadURL
    case identityMismatch
    case invalidRedirectChain

    var errorDescription: String? {
        switch self {
        case .sourceNotTrusted:
            return L10n.text("只有经注册表或 Provider 验证的来源才能自动下载。", "Only registry- or provider-verified sources may be downloaded automatically.")
        case .capabilityDoesNotPermitDownload:
            return L10n.text("该更新来源只允许打开官网。", "This update source only permits opening the official website.")
        case .missingDownloadURL:
            return L10n.text("官方更新来源没有提供可验证的直接下载地址。", "The official source has no verifiable direct download URL.")
        case .identityMismatch:
            return L10n.text("官方来源与当前应用身份不匹配。", "The official source does not match the current application identity.")
        case .invalidRedirectChain:
            return L10n.text("下载重定向链离开了允许的官方域名。", "The download redirect chain left the allowed official hosts.")
        }
    }
}

struct OfficialDownloadResolver: Sendable {
    private let hostValidator: AllowedHostValidator
    private let redirectValidator: RedirectValidator
    private let packageValidator: PackageTypeValidator

    init(
        hostValidator: AllowedHostValidator = AllowedHostValidator(),
        redirectValidator: RedirectValidator = RedirectValidator(),
        packageValidator: PackageTypeValidator = PackageTypeValidator()
    ) {
        self.hostValidator = hostValidator
        self.redirectValidator = redirectValidator
        self.packageValidator = packageValidator
    }

    func resolve(
        for application: InstalledApplication,
        release: OfficialReleaseDescriptor? = nil
    ) throws -> ResolvedOfficialDownload {
        guard let source = application.officialSource else {
            throw OfficialDownloadResolverError.missingDownloadURL
        }
        guard source.applicationIdentity.bundleIdentifier == application.bundleIdentifier,
              source.expectedBundleIdentifier == application.bundleIdentifier else {
            throw OfficialDownloadResolverError.identityMismatch
        }
        guard source.trustLevel.permitsAutomaticDownload else {
            throw OfficialDownloadResolverError.sourceNotTrusted
        }
        guard source.capability == .automatic || source.capability == .assistedInstaller else {
            throw OfficialDownloadResolverError.capabilityDoesNotPermitDownload
        }
        guard let remoteURL = release?.downloadURL ?? source.directDownloadURL else {
            throw OfficialDownloadResolverError.missingDownloadURL
        }

        try hostValidator.validate(remoteURL, allowedHosts: source.allowedHosts)
        let packageType = try packageValidator.validateRemoteURL(
            remoteURL,
            expectedExtensions: source.expectedPackageExtensions
        )
        return ResolvedOfficialDownload(
            source: source,
            remoteURL: remoteURL,
            packageType: packageType,
            expectedSize: release?.downloadSize,
            checksumSHA256: release?.checksumSHA256,
            permitsAutomaticInstallation: source.canAutomaticallyInstall
        )
    }

    /// Call this with the complete URLSession redirect history before accepting
    /// a downloaded file. Every hop is checked, not only the final URL.
    func validateRedirectChain(
        _ chain: [URL],
        for download: ResolvedOfficialDownload
    ) throws {
        do {
            try redirectValidator.validate(chain: chain, allowedHosts: download.source.allowedHosts)
        } catch {
            throw OfficialDownloadResolverError.invalidRedirectChain
        }
        guard chain.first == download.remoteURL else {
            throw OfficialDownloadResolverError.invalidRedirectChain
        }
    }
}
