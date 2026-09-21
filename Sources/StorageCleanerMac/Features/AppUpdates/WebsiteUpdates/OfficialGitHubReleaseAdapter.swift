import Foundation

protocol OfficialReleaseDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

enum OfficialGitHubReleaseArchitecture: String, Sendable {
    case arm64
    case x64

    static var current: Self {
        #if arch(arm64)
        .arm64
        #else
        .x64
        #endif
    }
}

enum OfficialGitHubReleaseAdapterError: Error, Equatable, LocalizedError, Sendable {
    case ambiguousMacDiskImages
    case invalidAssetMetadata
    case assetRepositoryMismatch

    var errorDescription: String? {
        switch self {
        case .ambiguousMacDiskImages:
            L10n.text(
                "GitHub 发布中有多个同等匹配的 macOS 磁盘映像。",
                "The GitHub release contains multiple equally matching macOS disk images."
            )
        case .invalidAssetMetadata:
            L10n.text(
                "GitHub 发布资产缺少有效的大小或 SHA-256 摘要。",
                "The GitHub release asset has no valid size or SHA-256 digest."
            )
        case .assetRepositoryMismatch:
            L10n.text(
                "GitHub 发布资产不属于已验证的官方仓库。",
                "The GitHub release asset does not belong to the verified official repository."
            )
        }
    }
}

final class GitHubAPIURLSessionRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let allowedHosts: Set<String> = ["api.github.com"]
    private let validator = AllowedHostValidator()

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let previousURL = response.url,
              let proposedURL = request.url,
              (try? validator.validate(previousURL, allowedHosts: Self.allowedHosts)) != nil,
              (try? validator.validate(proposedURL, allowedHosts: Self.allowedHosts)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct URLSessionOfficialReleaseDataLoader: OfficialReleaseDataLoading {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(
            configuration: configuration,
            delegate: GitHubAPIURLSessionRedirectDelegate(),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        return try await BoundedHTTPSReader.data(for: request, session: session, maximumBytes: 2 * 1024 * 1024)
    }
}

/// Uses GitHub's documented Releases API only when a trusted registry entry
/// explicitly identifies the developer-owned repository.
struct OfficialGitHubReleaseAdapter: OfficialReleaseCheckingAdapter {
    let identifier = "official-github-releases-v2"
    private let loader: any OfficialReleaseDataLoading
    private let architecture: OfficialGitHubReleaseArchitecture

    init(
        loader: any OfficialReleaseDataLoading = URLSessionOfficialReleaseDataLoader(),
        architecture: OfficialGitHubReleaseArchitecture = .current
    ) {
        self.loader = loader
        self.architecture = architecture
    }

    func supports(_ source: OfficialUpdateSource) -> Bool {
        source.providerType == .officialGitHubRelease
            && source.trustLevel.permitsAutomaticDownload
            && source.officialGitHubRepository?.trimmed.nonEmpty != nil
    }

    func latestRelease(for source: OfficialUpdateSource) async throws -> OfficialReleaseDescriptor? {
        guard let repository = source.officialGitHubRepository?.trimmed.nonEmpty,
              OfficialGitHubRepositoryPolicy.isValid(repository),
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
        else {
            return nil
        }
        let allowedHosts: Set<String> = ["api.github.com"]
        try AllowedHostValidator().validate(url, allowedHosts: allowedHosts)

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        request.setValue("StorageCleanerMac/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await loader.data(for: request)
        guard let finalURL = response.url else {
            throw URLError(.badServerResponse)
        }
        try AllowedHostValidator().validate(finalURL, allowedHosts: allowedHosts)
        if response.statusCode == 404 { return nil }
        guard (200..<300).contains(response.statusCode), data.count <= 2 * 1_024 * 1_024 else {
            throw URLError(.badServerResponse)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTag = (root["tag_name"] as? String)?.trimmed.nonEmpty else {
            return nil
        }
        let versionString = rawTag.hasPrefix("v") || rawTag.hasPrefix("V")
            ? String(rawTag.dropFirst())
            : rawTag
        guard !versionString.trimmed.isEmpty else { return nil }
        let selectedAsset = try Self.selectMacDiskImage(
            from: root["assets"] as? [[String: Any]] ?? [],
            architecture: architecture,
            repository: repository,
            source: source
        )
        let releaseDate = (root["published_at"] as? String).flatMap(Self.iso8601Date)
        let notes = (root["body"] as? String).map { String($0.prefix(32_000)) }
        return OfficialReleaseDescriptor(
            version: ApplicationVersion(marketing: versionString),
            releaseDate: releaseDate,
            releaseNotes: notes,
            downloadURL: selectedAsset?.url,
            downloadSize: selectedAsset?.size,
            checksumSHA256: selectedAsset?.digest
        )
    }

    private struct SelectedAsset {
        let url: URL
        let size: Int64
        let digest: String
    }

    private enum AssetArchitecture {
        case arm64
        case x64
        case universal
        case unsupported
    }

    private static func selectMacDiskImage(
        from assets: [[String: Any]],
        architecture: OfficialGitHubReleaseArchitecture,
        repository: String,
        source: OfficialUpdateSource
    ) throws -> SelectedAsset? {
        guard source.expectedPackageExtensions == [OfficialPackageType.diskImage.rawValue] else {
            return nil
        }
        let diskImages = assets.compactMap { asset -> (payload: [String: Any], architecture: AssetArchitecture)? in
            guard let name = (asset["name"] as? String)?.trimmed.nonEmpty,
                  name.count <= 1_024,
                  (name as NSString).pathExtension.lowercased()
                    == OfficialPackageType.diskImage.rawValue else {
                return nil
            }
            return (asset, assetArchitecture(for: name))
        }
        let exactArchitecture: AssetArchitecture = architecture == .arm64 ? .arm64 : .x64
        let exact = diskImages.filter { $0.architecture == exactArchitecture }
        let universal = diskImages.filter { $0.architecture == .universal }
        let candidates = exact.isEmpty ? universal : exact
        guard candidates.count <= 1 else {
            throw OfficialGitHubReleaseAdapterError.ambiguousMacDiskImages
        }
        guard let selected = candidates.first,
              let rawURL = (selected.payload["browser_download_url"] as? String)?.trimmed.nonEmpty,
              rawURL.count <= 8_192,
              let assetURL = URL(string: rawURL),
              let sizeNumber = selected.payload["size"] as? NSNumber,
              String(cString: sizeNumber.objCType) != "c",
              sizeNumber.int64Value > 0,
              sizeNumber.doubleValue == Double(sizeNumber.int64Value),
              sizeNumber.int64Value <= PackageTypeValidator().maximumDownloadBytes,
              let rawDigest = (selected.payload["digest"] as? String)?.trimmed.nonEmpty,
              let digest = normalizedSHA256Digest(rawDigest) else {
            if candidates.isEmpty { return nil }
            throw OfficialGitHubReleaseAdapterError.invalidAssetMetadata
        }

        try AllowedHostValidator().validate(assetURL, allowedHosts: source.allowedHosts)
        let expectedPathPrefix = "/\(repository.lowercased())/releases/download/"
        guard assetURL.host?.lowercased() == "github.com",
              assetURL.path.lowercased().hasPrefix(expectedPathPrefix) else {
            throw OfficialGitHubReleaseAdapterError.assetRepositoryMismatch
        }
        return SelectedAsset(
            url: assetURL,
            size: sizeNumber.int64Value,
            digest: digest
        )
    }

    private static func assetArchitecture(for name: String) -> AssetArchitecture {
        let tokens = Set(
            name.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        if tokens.contains("universal") || tokens.contains("universal2") {
            return .universal
        }
        let isARM = tokens.contains("arm64")
            || tokens.contains("aarch64")
            || (tokens.contains("apple") && tokens.contains("silicon"))
        let isX64 = tokens.contains("x64")
            || tokens.contains("amd64")
            || tokens.contains("intel")
            || (tokens.contains("x86") && tokens.contains("64"))
        if isARM != isX64 {
            return isARM ? .arm64 : .x64
        }
        if isARM && isX64
            || tokens.contains("ia32")
            || tokens.contains("i386")
            || tokens.contains("i586")
            || tokens.contains("i686")
            || tokens.contains("x86")
            || tokens.contains("arm")
            || tokens.contains("arm32")
            || tokens.contains("armv7") {
            return .unsupported
        }
        // A lone macOS DMG such as CC-Switch-v3.19.1-macOS.dmg is the
        // repository's architecture-neutral fallback.
        return .universal
    }

    private static func normalizedSHA256Digest(_ value: String) -> String? {
        let normalized = value.lowercased()
        guard normalized.hasPrefix("sha256:") else { return nil }
        let digest = normalized.dropFirst("sha256:".count)
        guard digest.count == 64,
              digest.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet(charactersIn: "0123456789abcdef").contains(scalar)
              }) else {
            return nil
        }
        return normalized
    }

    private static func iso8601Date(_ value: String) -> Date? {
        AppISO8601DateCodec.date(from: value)
    }
}
