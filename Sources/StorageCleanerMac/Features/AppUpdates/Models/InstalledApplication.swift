import AppKit
import Foundation

struct ApplicationIdentity: Codable, Hashable, Sendable {
    let bundleIdentifier: String
    let signingTeamIdentifier: String?
    let codeSigningIdentifier: String?

    var isCompleteForAutomaticUpdates: Bool {
        !bundleIdentifier.trimmed.isEmpty
            && signingTeamIdentifier?.trimmed.isEmpty == false
    }
}

struct ApplicationVersion: Codable, Hashable, Sendable, Comparable {
    let marketing: String
    let build: String

    init(marketing: String, build: String = "") {
        self.marketing = marketing.trimmed
        self.build = build.trimmed
    }

    var preferred: String {
        marketing.isEmpty ? build : marketing
    }

    var display: String {
        if marketing.isEmpty, build.isEmpty {
            return L10n.text("版本未知", "Unknown Version")
        }
        if marketing.isEmpty { return build }
        if build.isEmpty || build == marketing { return marketing }
        return "\(marketing) (\(build))"
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        compare(lhs.preferred, rhs.preferred) == .orderedAscending
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = tokenize(lhs)
        let right = tokenize(rhs)
        let count = max(left.count, right.count)

        for index in 0..<count {
            let leftPart = index < left.count ? left[index] : .number(0)
            let rightPart = index < right.count ? right[index] : .number(0)
            if leftPart == rightPart { continue }
            return leftPart < rightPart ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private enum Part: Equatable, Comparable {
        case number(Int)
        case text(String)

        static func < (lhs: Part, rhs: Part) -> Bool {
            switch (lhs, rhs) {
            case let (.number(left), .number(right)):
                return left < right
            case let (.text(left), .text(right)):
                return left.localizedStandardCompare(right) == .orderedAscending
            case (.number, .text):
                return false
            case (.text, .number):
                return true
            }
        }
    }

    private static func tokenize(_ value: String) -> [Part] {
        let normalized = value.trimmed.lowercased()
        guard !normalized.isEmpty else { return [] }
        let pattern = #"([0-9]+|[a-z]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return [.text(normalized)]
        }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        return expression.matches(in: normalized, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: normalized) else { return nil }
            let token = String(normalized[swiftRange])
            if let number = Int(token) { return .number(number) }
            return .text(token)
        }
    }
}

enum ApplicationInstallationSource: String, Codable, CaseIterable, Sendable {
    case system
    case appStore
    case homebrewCask
    case homebrewFormula
    case sparkle
    case vendor
    case officialWebsite
    case userDirectory
    case standardDirectory
    case externalVolume
    case unknown
}

enum ApplicationUpdateProviderIdentifier: String, Codable, CaseIterable, Sendable {
    case systemManaged
    case macAppStore
    case homebrew
    case sparkle
    case vendorUpdater
    case officialWebsite
    case manual
}

enum ApplicationUpdateStatus: String, Codable, CaseIterable, Sendable {
    case discovered
    case identifyingSource
    case checking
    case upToDate
    case updateAvailable
    case automaticallyUpdatable
    case officialInstallerAvailable
    case websiteUpdateRequired
    case applicationUpdateRequired
    case appStoreManaged
    case systemManaged
    case sourceUnconfirmed
    case latestVersionUnknown
    case queued
    case downloading
    case waitingForQuit
    case waitingForAuthorization
    case installing
    case verifying
    case completed
    case skipped
    case cancelled
    case failed
    case ignored
}

/// Source discovery, remote version inspection and execution support are
/// deliberately independent. A website can be verified even when its latest
/// version is temporarily unavailable, and that must not be presented as an
/// untrusted source.
enum SourceResolutionState: String, Codable, CaseIterable, Sendable {
    case unresolved
    case resolving
    case resolved
    case needsConfirmation
    case failed
}

enum VersionCheckState: String, Codable, CaseIterable, Sendable {
    case notChecked
    case checking
    case upToDate
    case updateAvailable
    case unavailable
    case failed
}

enum UpdateCapability: String, Codable, CaseIterable, Sendable {
    case unavailable
    case systemManaged
    case appStoreManaged
    case automatic
    case inApplication
    case websiteGuided
    case manual
}

enum ApplicationPackageKind: String, Codable, Sendable {
    case graphicalApplication
    case commandLineTool
}

enum HomebrewPackageKind: String, Codable, Sendable {
    case cask
    case formula
}

enum HomebrewOutdatedProvenance: String, Codable, Sendable {
    case plain
    case greedy
    case unknown
}

struct HomebrewPackageMetadata: Codable, Hashable, Sendable {
    let token: String
    let kind: HomebrewPackageKind
    let homepageURL: URL?
    let installedVersions: [String]
    let currentVersion: String?
    let isOutdated: Bool
    /// Optional storage keeps inventories written before provenance tracking
    /// decodable. Missing values are interpreted as `.unknown` and therefore
    /// can never authorize an automatic update.
    let outdatedProvenance: HomebrewOutdatedProvenance?
    let isPinned: Bool
    let isDisabled: Bool
    let isDeprecated: Bool
    let autoUpdates: Bool
    let requiresManualInstaller: Bool
    let appBundlePaths: [String]

    var effectiveOutdatedProvenance: HomebrewOutdatedProvenance {
        outdatedProvenance ?? .unknown
    }

    var hasPlainOutdatedEvidence: Bool {
        isOutdated && effectiveOutdatedProvenance == .plain
    }

    init(
        token: String,
        kind: HomebrewPackageKind,
        homepageURL: URL?,
        installedVersions: [String],
        currentVersion: String?,
        isOutdated: Bool,
        outdatedProvenance: HomebrewOutdatedProvenance = .unknown,
        isPinned: Bool,
        isDisabled: Bool,
        isDeprecated: Bool,
        autoUpdates: Bool,
        requiresManualInstaller: Bool,
        appBundlePaths: [String]
    ) {
        self.token = token
        self.kind = kind
        self.homepageURL = homepageURL
        self.installedVersions = installedVersions
        self.currentVersion = currentVersion
        self.isOutdated = isOutdated
        self.outdatedProvenance = outdatedProvenance
        self.isPinned = isPinned
        self.isDisabled = isDisabled
        self.isDeprecated = isDeprecated
        self.autoUpdates = autoUpdates
        self.requiresManualInstaller = requiresManualInstaller
        self.appBundlePaths = appBundlePaths
    }
}

struct SparkleConfiguration: Codable, Hashable, Sendable {
    let feedURL: URL?
    let publicEDKey: String?
    let requiresSignedFeed: Bool
    let frameworkRelativePath: String?

    var isEligibleForReadOnlyProbe: Bool {
        guard let feedURL,
              feedURL.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              feedURL.host?.trimmed.nonEmpty != nil,
              feedURL.user == nil,
              feedURL.password == nil,
              frameworkRelativePath?.trimmed.nonEmpty != nil,
              requiresSignedFeed,
              let publicEDKey,
              let keyData = Data(base64Encoded: publicEDKey.trimmed),
              keyData.count == 32 else {
            return false
        }
        return true
    }
}

struct InstalledApplication: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var displayName: String
    var bundleIdentifier: String
    var bundleURL: URL
    var executableURL: URL?
    var installedVersion: ApplicationVersion
    var buildNumber: String
    var signingTeamIdentifier: String?
    var codeSigningIdentifier: String?
    var installationSource: ApplicationInstallationSource
    /// Keep the historical JSON key for backward compatibility. This is the
    /// only stored provider value; `primaryUpdateProvider` is its semantic API.
    var updateProvider: ApplicationUpdateProviderIdentifier
    var architectures: [String]
    var minimumSystemVersion: String?
    var isSystemApplication: Bool
    var isRunning: Bool
    var isOnExternalVolume: Bool
    var isReadOnly: Bool
    var isDuplicate: Bool
    var duplicateLocations: [URL]
    var lastScanDate: Date
    var availableVersion: ApplicationVersion?
    var releaseDate: Date?
    var releaseNotes: String?
    var downloadSize: Int64?
    var appStoreProductURL: URL?
    var updateStatus: ApplicationUpdateStatus
    /// Optional storage keeps decoding compatible with inventories written
    /// before these orthogonal states were introduced. Freshly scanned items
    /// always populate all three values.
    var sourceResolutionState: SourceResolutionState?
    var versionCheckState: VersionCheckState?
    var updateCapability: UpdateCapability?
    var updateError: String?
    var requiresUserInteraction: Bool
    var requiresApplicationQuit: Bool
    var requiresAdministratorAuthorization: Bool
    var canAutomaticallyUpdate: Bool
    var packageKind: ApplicationPackageKind
    var sourceDisplayName: String
    var sourceEvidence: [String]
    var officialSource: OfficialUpdateSource?
    var homebrewMetadata: HomebrewPackageMetadata?
    var sparkleConfiguration: SparkleConfiguration?
    var feedURL: String?
    var caskToken: String?
    var reportedCurrentVersion: String?
    var modifiedAt: Date?

    var primaryUpdateProvider: ApplicationUpdateProviderIdentifier {
        get { updateProvider }
        set { updateProvider = newValue }
    }

    /// Decoded inventories from before 1.8.12 do not contain the orthogonal
    /// state fields. Keep their meaning available without rewriting them on
    /// read.
    var effectiveSourceResolutionState: SourceResolutionState {
        sourceResolutionState ?? Self.inferredSourceResolutionState(for: updateStatus)
    }

    var effectiveVersionCheckState: VersionCheckState {
        versionCheckState ?? Self.inferredVersionCheckState(
            for: updateStatus,
            availableVersion: availableVersion
        )
    }

    var effectiveUpdateCapability: UpdateCapability {
        updateCapability ?? Self.inferredUpdateCapability(
            provider: updateProvider,
            canAutomaticallyUpdate: canAutomaticallyUpdate
        )
    }

    var identity: ApplicationIdentity {
        ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            signingTeamIdentifier: signingTeamIdentifier,
            codeSigningIdentifier: codeSigningIdentifier
        )
    }

    var name: String { displayName }
    var path: String { bundleURL.path }
    var version: String { installedVersion.marketing }
    var build: String { buildNumber }
    var source: String { sourceDisplayName }
    var currentVersion: String? { reportedCurrentVersion }
    var latestVersion: String? { availableVersion?.preferred.nonEmpty }

    var method: AppUpdateMethod {
        switch updateProvider {
        case .macAppStore:
            .appStore
        case .homebrew:
            .homebrew
        case .sparkle:
            .sparkle
        case .systemManaged, .vendorUpdater, .officialWebsite, .manual:
            .manual
        }
    }

    var versionDisplay: String { installedVersion.display }

    var currentVersionDisplay: String {
        reportedCurrentVersion?.trimmed.nonEmpty ?? versionDisplay
    }

    var latestVersionDisplay: String {
        availableVersion?.display ?? L10n.text("未知", "Unknown")
    }

    var homebrewCommand: String? {
        HomebrewUpdateRecipeBuilder.copyCommand(for: self)
    }

    var canRunInOneClickUpdate: Bool { canAutomaticallyUpdate }

    var updateHandlingTitle: String {
        switch ApplicationUpdatePlanBuilder.destination(for: self) {
        case .automatic:
            return L10n.text("可直接自动更新", "Automatic Update")
        case .requiresQuit:
            return L10n.text("退出后自动更新", "Automatic After Quit")
        case .requiresAuthorization:
            return L10n.text("需要管理员授权", "Administrator Authorization Required")
        case .appStore, .website, .manual, .skipped:
            break
        }
        switch updateProvider {
        case .systemManaged:
            return L10n.text("由 macOS 管理", "Managed by macOS")
        case .macAppStore:
            return L10n.text("由 App Store 管理", "Managed by App Store")
        case .sparkle, .vendorUpdater:
            return L10n.text("请在应用内检查", "Check in the App")
        case .officialWebsite:
            return L10n.text("需在官网完成", "Complete on Website")
        case .homebrew, .manual:
            return requiresUserInteraction
                ? L10n.text("需要确认", "Confirmation Required")
                : L10n.text("无法确认最新版本", "Latest Version Unknown")
        }
    }

    var updateHandlingDetail: String {
        if let updateError, !updateError.trimmed.isEmpty { return updateError }
        switch ApplicationUpdatePlanBuilder.destination(for: self) {
        case .automatic:
            return L10n.text(
                "可立即加入受控更新队列；完成后会重新读取磁盘版本。",
                "Can join the controlled update queue now; the on-disk version is checked afterwards."
            )
        case .requiresQuit:
            return L10n.text(
                "将先正常退出此应用，再使用已验证来源更新；不会强制终止进程。",
                "The app will be asked to quit normally before updating from the verified source; it will not be force-terminated."
            )
        case .requiresAuthorization:
            return L10n.text(
                "目标目录不可直接写入；当前自动队列不会请求或绕过管理员授权。",
                "The destination is not directly writable; the automatic queue does not request or bypass administrator authorization."
            )
        case .appStore, .website, .manual, .skipped:
            break
        }
        switch updateProvider {
        case .systemManaged:
            return L10n.text("此应用随 macOS 更新，不会单独替换。", "This app is updated with macOS and is not replaced separately.")
        case .macAppStore:
            return L10n.text("请在 App Store 中检查并确认更新。", "Check and confirm the update in the App Store.")
        case .sparkle:
            return L10n.text("打开应用，使用其经过签名的内置更新器。", "Open the app and use its signed built-in updater.")
        case .officialWebsite:
            return L10n.text("按官网更新向导逐项处理，版本变化后才算完成。", "Use the website assistant; completion requires an on-disk version change.")
        case .homebrew:
            return L10n.text("此 Homebrew 项目需要退出、授权或人工安装。", "This Homebrew item needs quitting, authorization, or manual installation.")
        case .vendorUpdater:
            return L10n.text(
                "此应用由自带的更新器维护（如 Google 更新器或内置自动更新），打开应用即可检查并安装更新。",
                "This app is maintained by its own updater (such as Google Updater or a built-in auto updater); open the app to check and install updates."
            )
        case .manual:
            return L10n.text("尚无经过验证的自动更新接口。", "No verified automatic update interface is available.")
        }
    }

    var officialDomain: String? {
        officialSource?.displayHost
    }

    /// A website source belongs in the trusted website category only after a
    /// user or provider has confirmed it and it exposes a concrete page or
    /// release endpoint. Candidate search results remain source-unconfirmed.
    var hasConfirmedOfficialWebsiteSource: Bool {
        guard primaryUpdateProvider == .officialWebsite,
              let source = officialSource,
              source.trustLevel >= .userConfirmed,
              source.capability != .sourceConfirmation else {
            return false
        }
        return source.homepageURL != nil
            || source.updatePageURL != nil
            || source.releaseFeedURL != nil
            || source.directDownloadURL != nil
    }

    /// Uses the same eligibility gate as the plan builder, including duplicate
    /// copies and version direction, so detail views cannot promise an action
    /// that the coordinator will reject.
    var canJoinAutomaticUpdatePlan: Bool {
        ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(self)
    }

    var canJoinAutomaticUpdateBatch: Bool {
        switch ApplicationUpdatePlanBuilder.destination(for: self) {
        case .automatic, .requiresQuit:
            true
        case .requiresAuthorization, .appStore, .website, .manual, .skipped:
            false
        }
    }

    @MainActor
    var applicationIcon: NSImage {
        NSWorkspace.shared.icon(forFile: ApplicationIconSourceResolver.sourceURL(for: self).path)
    }

    init(
        id: String,
        displayName: String,
        bundleIdentifier: String,
        bundleURL: URL,
        executableURL: URL?,
        installedVersion: ApplicationVersion,
        buildNumber: String,
        signingTeamIdentifier: String?,
        codeSigningIdentifier: String?,
        installationSource: ApplicationInstallationSource,
        updateProvider: ApplicationUpdateProviderIdentifier,
        architectures: [String],
        minimumSystemVersion: String?,
        isSystemApplication: Bool,
        isRunning: Bool,
        isOnExternalVolume: Bool,
        isReadOnly: Bool,
        isDuplicate: Bool = false,
        duplicateLocations: [URL] = [],
        lastScanDate: Date,
        availableVersion: ApplicationVersion? = nil,
        releaseDate: Date? = nil,
        releaseNotes: String? = nil,
        downloadSize: Int64? = nil,
        appStoreProductURL: URL? = nil,
        updateStatus: ApplicationUpdateStatus,
        sourceResolutionState: SourceResolutionState? = nil,
        versionCheckState: VersionCheckState? = nil,
        updateCapability: UpdateCapability? = nil,
        updateError: String? = nil,
        requiresUserInteraction: Bool,
        requiresApplicationQuit: Bool,
        requiresAdministratorAuthorization: Bool,
        canAutomaticallyUpdate: Bool,
        packageKind: ApplicationPackageKind = .graphicalApplication,
        sourceDisplayName: String,
        sourceEvidence: [String] = [],
        officialSource: OfficialUpdateSource? = nil,
        homebrewMetadata: HomebrewPackageMetadata? = nil,
        sparkleConfiguration: SparkleConfiguration? = nil,
        feedURL: String? = nil,
        caskToken: String? = nil,
        reportedCurrentVersion: String? = nil,
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.executableURL = executableURL
        self.installedVersion = installedVersion
        self.buildNumber = buildNumber
        self.signingTeamIdentifier = signingTeamIdentifier
        self.codeSigningIdentifier = codeSigningIdentifier
        self.installationSource = installationSource
        self.updateProvider = updateProvider
        self.architectures = architectures
        self.minimumSystemVersion = minimumSystemVersion
        self.isSystemApplication = isSystemApplication
        self.isRunning = isRunning
        self.isOnExternalVolume = isOnExternalVolume
        self.isReadOnly = isReadOnly
        self.isDuplicate = isDuplicate
        self.duplicateLocations = duplicateLocations
        self.lastScanDate = lastScanDate
        self.availableVersion = availableVersion
        self.releaseDate = releaseDate
        self.releaseNotes = releaseNotes
        self.downloadSize = downloadSize
        self.appStoreProductURL = appStoreProductURL
        self.updateStatus = updateStatus
        self.sourceResolutionState = sourceResolutionState
            ?? Self.inferredSourceResolutionState(for: updateStatus)
        self.versionCheckState = versionCheckState
            ?? Self.inferredVersionCheckState(
                for: updateStatus,
                availableVersion: availableVersion
            )
        self.updateCapability = updateCapability
            ?? Self.inferredUpdateCapability(
                provider: updateProvider,
                canAutomaticallyUpdate: canAutomaticallyUpdate
            )
        self.updateError = updateError
        self.requiresUserInteraction = requiresUserInteraction
        self.requiresApplicationQuit = requiresApplicationQuit
        self.requiresAdministratorAuthorization = requiresAdministratorAuthorization
        self.canAutomaticallyUpdate = canAutomaticallyUpdate
        self.packageKind = packageKind
        self.sourceDisplayName = sourceDisplayName
        self.sourceEvidence = sourceEvidence
        self.officialSource = officialSource
        self.homebrewMetadata = homebrewMetadata
        self.sparkleConfiguration = sparkleConfiguration
        self.feedURL = feedURL
        self.caskToken = caskToken
        self.reportedCurrentVersion = reportedCurrentVersion
        self.modifiedAt = modifiedAt
    }

    private static func inferredSourceResolutionState(
        for status: ApplicationUpdateStatus
    ) -> SourceResolutionState {
        switch status {
        case .discovered:
            .unresolved
        case .identifyingSource:
            .resolving
        case .sourceUnconfirmed:
            .needsConfirmation
        case .failed:
            .failed
        default:
            .resolved
        }
    }

    private static func inferredVersionCheckState(
        for status: ApplicationUpdateStatus,
        availableVersion: ApplicationVersion?
    ) -> VersionCheckState {
        switch status {
        case .checking:
            .checking
        case .upToDate, .completed:
            .upToDate
        case .updateAvailable, .automaticallyUpdatable, .officialInstallerAvailable,
             .websiteUpdateRequired, .applicationUpdateRequired, .queued,
             .downloading, .waitingForQuit, .waitingForAuthorization, .installing,
             .verifying:
            availableVersion == nil ? .unavailable : .updateAvailable
        case .failed:
            .failed
        case .latestVersionUnknown, .sourceUnconfirmed, .appStoreManaged, .systemManaged:
            .unavailable
        case .discovered, .identifyingSource, .skipped, .cancelled, .ignored:
            .notChecked
        }
    }

    private static func inferredUpdateCapability(
        provider: ApplicationUpdateProviderIdentifier,
        canAutomaticallyUpdate: Bool
    ) -> UpdateCapability {
        if canAutomaticallyUpdate { return .automatic }
        switch provider {
        case .systemManaged: return .systemManaged
        case .macAppStore: return .appStoreManaged
        case .sparkle, .vendorUpdater: return .inApplication
        case .officialWebsite: return .websiteGuided
        case .homebrew, .manual: return .manual
        }
    }

    init(
        id: String,
        name: String,
        bundleIdentifier: String,
        path: String,
        version: String,
        build: String,
        source: String,
        method: AppUpdateMethod,
        feedURL: String?,
        caskToken: String?,
        currentVersion: String?,
        latestVersion: String?,
        modifiedAt: Date?
    ) {
        let provider: ApplicationUpdateProviderIdentifier
        let installationSource: ApplicationInstallationSource
        switch method {
        case .appStore:
            provider = .macAppStore
            installationSource = .appStore
        case .homebrew:
            provider = .homebrew
            installationSource = .homebrewCask
        case .sparkle:
            provider = .sparkle
            installationSource = .sparkle
        case .manual:
            provider = .manual
            installationSource = .unknown
        }
        let latest = latestVersion?.trimmed.nonEmpty.map { ApplicationVersion(marketing: $0) }
        let canAutomaticallyUpdate = provider == .homebrew && caskToken?.trimmed.isEmpty == false
        self.init(
            id: id,
            displayName: name,
            bundleIdentifier: bundleIdentifier,
            bundleURL: URL(fileURLWithPath: path),
            executableURL: nil,
            installedVersion: ApplicationVersion(marketing: version, build: build),
            buildNumber: build,
            signingTeamIdentifier: nil,
            codeSigningIdentifier: bundleIdentifier.nonEmpty,
            installationSource: installationSource,
            updateProvider: provider,
            architectures: [],
            minimumSystemVersion: nil,
            isSystemApplication: false,
            isRunning: false,
            isOnExternalVolume: false,
            isReadOnly: false,
            lastScanDate: Date(),
            availableVersion: latest,
            updateStatus: latest == nil ? .latestVersionUnknown : .updateAvailable,
            requiresUserInteraction: provider != .homebrew,
            requiresApplicationQuit: false,
            requiresAdministratorAuthorization: false,
            canAutomaticallyUpdate: canAutomaticallyUpdate,
            sourceDisplayName: source,
            feedURL: feedURL,
            caskToken: caskToken,
            reportedCurrentVersion: currentVersion,
            modifiedAt: modifiedAt
        )
    }
}

typealias AppUpdateItem = InstalledApplication
