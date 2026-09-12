import AppKit
import Foundation

struct ApplicationScanDirectory: Hashable, Sendable {
    let url: URL
    let requiresSecurityScopedAccess: Bool
    let maximumDepth: Int?

    init(
        url: URL,
        requiresSecurityScopedAccess: Bool = false,
        maximumDepth: Int? = nil
    ) {
        self.url = url
        self.requiresSecurityScopedAccess = requiresSecurityScopedAccess
        self.maximumDepth = maximumDepth
    }

    static func resolveSecurityScopedBookmark(
        _ bookmarkData: Data,
        maximumDepth: Int? = nil
    ) throws -> ApplicationScanDirectory {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else {
            throw ApplicationScanningError.staleSecurityScopedBookmark
        }
        return ApplicationScanDirectory(
            url: url,
            requiresSecurityScopedAccess: true,
            maximumDepth: maximumDepth
        )
    }
}

struct ApplicationScanConfiguration: Sendable {
    var includeSpotlightResults: Bool
    var spotlightTimeout: Duration
    var includeExternalVolumes: Bool
    var includeHomebrewFormulae: Bool
    var checkSelfUpdatingHomebrewCasks: Bool
    var additionalDirectories: [ApplicationScanDirectory]
    var additionalDirectoryBookmarks: [Data]
    var fallbackDirectories: [ApplicationScanDirectory]
    var externalVolumeMaximumDepth: Int

    init(
        includeSpotlightResults: Bool = true,
        spotlightTimeout: Duration = .seconds(12),
        includeExternalVolumes: Bool = false,
        includeHomebrewFormulae: Bool = true,
        checkSelfUpdatingHomebrewCasks: Bool = false,
        additionalDirectories: [ApplicationScanDirectory] = [],
        additionalDirectoryBookmarks: [Data] = [],
        fallbackDirectories: [ApplicationScanDirectory]? = nil,
        externalVolumeMaximumDepth: Int = 6
    ) {
        self.includeSpotlightResults = includeSpotlightResults
        self.spotlightTimeout = spotlightTimeout
        self.includeExternalVolumes = includeExternalVolumes
        self.includeHomebrewFormulae = includeHomebrewFormulae
        self.checkSelfUpdatingHomebrewCasks = checkSelfUpdatingHomebrewCasks
        self.additionalDirectories = additionalDirectories
        self.additionalDirectoryBookmarks = additionalDirectoryBookmarks
        self.fallbackDirectories = fallbackDirectories ?? Self.defaultFallbackDirectories()
        self.externalVolumeMaximumDepth = max(1, externalVolumeMaximumDepth)
    }

    static func standardDirectories(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ApplicationScanDirectory] {
        [
            ApplicationScanDirectory(url: URL(fileURLWithPath: "/Applications", isDirectory: true)),
            ApplicationScanDirectory(url: URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true)),
            ApplicationScanDirectory(url: homeDirectory.appendingPathComponent("Applications", isDirectory: true)),
            ApplicationScanDirectory(url: URL(fileURLWithPath: "/System/Applications", isDirectory: true)),
            ApplicationScanDirectory(url: URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true)),
        ]
    }

    private static func defaultFallbackDirectories(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ApplicationScanDirectory] {
        ["Desktop", "Documents", "Downloads"].map {
            ApplicationScanDirectory(
                url: homeDirectory.appendingPathComponent($0, isDirectory: true),
                maximumDepth: 4
            )
        }
    }
}

enum ApplicationScanStage: String, Sendable {
    case scanningStandardDirectories
    case readingMetadata
    case scanningSpotlight
    case scanningFallbackDirectories
    case scanningHomebrew
    case identifyingSources
    case completed
}

struct ApplicationScanProgress: Sendable {
    let stage: ApplicationScanStage
    let scannedCount: Int
    let discoveredCount: Int
    let detail: String?

    init(
        stage: ApplicationScanStage,
        scannedCount: Int = 0,
        discoveredCount: Int = 0,
        detail: String? = nil
    ) {
        self.stage = stage
        self.scannedCount = scannedCount
        self.discoveredCount = discoveredCount
        self.detail = detail
    }
}

enum SpotlightScanCompletion: Sendable {
    case completed
    case timedOut
    case unavailable
}

struct SpotlightApplicationScanResult: Sendable {
    let applicationURLs: [URL]
    let completion: SpotlightScanCompletion
}

enum ApplicationScanningError: LocalizedError, Sendable {
    case staleSecurityScopedBookmark
    case securityScopedAccessDenied(String)
    case spotlightUnavailable
    case invalidApplicationBundle(String)
    case invalidHomebrewOutput(String)
    case providerUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .staleSecurityScopedBookmark:
            L10n.text("已保存的扫描目录权限已过期。", "The saved scan-directory permission is stale.")
        case let .securityScopedAccessDenied(path):
            L10n.text("无法访问扫描目录：\(path)", "Cannot access scan directory: \(path)")
        case .spotlightUnavailable:
            L10n.text("Spotlight 暂时不可用。", "Spotlight is currently unavailable.")
        case let .invalidApplicationBundle(path):
            L10n.text("无法读取应用包：\(path)", "Cannot read application bundle: \(path)")
        case let .invalidHomebrewOutput(detail):
            L10n.text("Homebrew 输出无法解析：\(detail)", "Homebrew output could not be parsed: \(detail)")
        case let .providerUnsupported(provider):
            L10n.text("更新方式尚不支持自动安装：\(provider)", "Automatic installation is not supported by: \(provider)")
        }
    }
}

struct ApplicationCodeSignatureMetadata: Hashable, Sendable {
    let signingTeamIdentifier: String?
    let codeSigningIdentifier: String?
    let isValid: Bool
    let hasAppSandboxEntitlement: Bool

    init(
        signingTeamIdentifier: String?,
        codeSigningIdentifier: String?,
        isValid: Bool,
        hasAppSandboxEntitlement: Bool = false
    ) {
        self.signingTeamIdentifier = signingTeamIdentifier
        self.codeSigningIdentifier = codeSigningIdentifier
        self.isValid = isValid
        self.hasAppSandboxEntitlement = hasAppSandboxEntitlement
    }
}

protocol ApplicationCodeSignatureInspecting: Sendable {
    func inspectSignature(at applicationURL: URL) async -> ApplicationCodeSignatureMetadata
}

struct ApplicationRunningStateSnapshot: Sendable {
    let bundleIdentifiers: Set<String>
    let normalizedBundlePaths: Set<String>

    func contains(bundleIdentifier: String, bundleURL: URL) -> Bool {
        if !bundleIdentifier.isEmpty, bundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        return normalizedBundlePaths.contains(ApplicationPathNormalizer.normalizedPath(for: bundleURL))
    }

    @MainActor
    static func capture(workspace: NSWorkspace = .shared) -> ApplicationRunningStateSnapshot {
        var identifiers = Set<String>()
        var paths = Set<String>()
        for application in workspace.runningApplications {
            if let identifier = application.bundleIdentifier?.trimmed.nonEmpty {
                identifiers.insert(identifier)
            }
            if let bundleURL = application.bundleURL {
                paths.insert(ApplicationPathNormalizer.normalizedPath(for: bundleURL))
            }
        }
        return ApplicationRunningStateSnapshot(
            bundleIdentifiers: identifiers,
            normalizedBundlePaths: paths
        )
    }
}

enum ApplicationPathNormalizer {
    static func normalizedPath(for url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }

    static func comparisonKey(for url: URL) -> String {
        normalizedPath(for: url).lowercased()
    }
}
