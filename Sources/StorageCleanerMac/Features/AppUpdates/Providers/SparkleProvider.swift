import Foundation
import Sparkle

enum SparkleReadOnlyProbeOutcome: Hashable, Sendable {
    case updateAvailable(version: ApplicationVersion, releaseDate: Date?)
    case noUpdate
}

enum SparkleReadOnlyProbeError: LocalizedError, Sendable {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout:
            L10n.text("Sparkle 检查超时。", "The Sparkle update check timed out.")
        }
    }
}

protocol SparkleReadOnlyProbing: Sendable {
    func probe(bundleURL: URL) async throws -> SparkleReadOnlyProbeOutcome
}

final class SparkleProvider: ApplicationUpdateProvider, @unchecked Sendable {
    let identifier = ApplicationUpdateProviderIdentifier.sparkle

    private let probe: any SparkleReadOnlyProbing
    private let signatureInspector: any ApplicationCodeSignatureInspecting
    private let probeTimeout: Duration
    private let automaticAdapter: (any SparkleAutomaticUpdating)?
    private let stateLock = NSLock()
    private var releases = [String: SparkleRelease]()
    private var preparedApplications = [String: InstalledApplication]()

    init(
        probe: any SparkleReadOnlyProbing = SystemSparkleReadOnlyProbe(),
        signatureInspector: any ApplicationCodeSignatureInspecting = SecurityFrameworkApplicationCodeSignatureInspector(),
        probeTimeout: Duration = .seconds(12),
        automaticAdapter: (any SparkleAutomaticUpdating)? = SparkleAutomaticUpdateAdapter()
    ) {
        self.probe = probe
        self.signatureInspector = signatureInspector
        self.probeTimeout = probeTimeout
        self.automaticAdapter = automaticAdapter
    }

    func canHandle(_ application: InstalledApplication) async -> Bool {
        application.sparkleConfiguration != nil
            || ApplicationMetadataReader.sparkleConfiguration(at: application.bundleURL) != nil
            || application.sourceEvidence.contains("sparkle-framework")
            || application.sourceEvidence.contains("sparkle-feed")
    }

    func inspect(_ application: InstalledApplication) async throws -> ApplicationUpdateSourceInfo {
        let configuration = ApplicationMetadataReader.sparkleConfiguration(at: application.bundleURL)
            ?? application.sparkleConfiguration
        var evidence = [String]()
        if configuration?.frameworkRelativePath != nil {
            evidence.append("sparkle-framework")
        }
        if configuration?.feedURL != nil {
            evidence.append("sparkle-feed")
        }
        if configuration?.publicEDKey != nil {
            evidence.append("sparkle-ed-key")
        }
        if configuration?.requiresSignedFeed == true {
            evidence.append("sparkle-signed-feed")
        }
        if configuration?.isEligibleForReadOnlyProbe == true {
            evidence.append("sparkle-readonly-probe")
        }
        return ApplicationUpdateSourceInfo(
            providerIdentifier: identifier,
            evidence: evidence,
            requiresUserInteraction: !canExecute(application, configuration: configuration),
            canAutomaticallyUpdate: canExecute(application, configuration: configuration)
        )
    }

    func checkForUpdate(_ application: InstalledApplication) async throws -> ApplicationUpdateCheckResult {
        try Task.checkCancellation()
        if let automaticAdapter, let configuration = ApplicationMetadataReader.sparkleConfiguration(at: application.bundleURL) ?? application.sparkleConfiguration,
           canExecute(application, configuration: configuration) {
            if let scanned = application.sparkleConfiguration, scanned != configuration { throw SparkleAutomaticUpdateError.configurationChanged }
            var current = application
            current.sparkleConfiguration = configuration
            guard let release = try await automaticAdapter.check(current) else {
                return .init(status: .upToDate, availableVersion: nil, releaseDate: nil, releaseNotes: nil, downloadSize: nil, warning: nil)
            }
            guard ["zip", "dmg"].contains(release.downloadURL.pathExtension.lowercased()) else {
                return .init(status: .applicationUpdateRequired, availableVersion: release.version, releaseDate: nil, releaseNotes: nil,
                    downloadSize: release.byteCount, warning: SparkleAutomaticUpdateError.unsupportedArchive.localizedDescription)
            }
            stateLock.withLock { releases[application.id] = release }
            return .init(status: .automaticallyUpdatable, availableVersion: release.version, releaseDate: nil, releaseNotes: nil,
                downloadSize: release.byteCount, warning: nil)
        }
        guard let configuration = ApplicationMetadataReader.sparkleConfiguration(at: application.bundleURL),
              configuration.isEligibleForReadOnlyProbe else {
            return unknownResult(
                L10n.text(
                    "Sparkle 配置未通过只读检查安全门，请在应用内检查更新。",
                    "The Sparkle configuration did not pass the read-only safety checks; check for updates in the app."
                )
            )
        }
        if let scannedConfiguration = application.sparkleConfiguration,
           scannedConfiguration != configuration {
            return unknownResult(
                L10n.text(
                    "Sparkle 配置在扫描后发生变化，请重新检查。",
                    "The Sparkle configuration changed after scanning; scan again."
                )
            )
        }
        guard let bundle = Bundle(url: application.bundleURL.standardizedFileURL),
              let bundleIdentifier = bundle.bundleIdentifier?.trimmed.nonEmpty,
              bundleIdentifier == application.bundleIdentifier,
              let expectedTeam = application.signingTeamIdentifier?.trimmed.nonEmpty,
              let expectedCodeIdentifier = application.codeSigningIdentifier?.trimmed.nonEmpty else {
            return unknownResult(
                L10n.text(
                    "应用签名身份不完整，未连接 Sparkle appcast。",
                    "The app signing identity is incomplete; its Sparkle appcast was not contacted."
                )
            )
        }
        let signature = await signatureInspector.inspectSignature(at: application.bundleURL)
        guard signature.isValid,
              signature.signingTeamIdentifier?.trimmed == expectedTeam,
              signature.codeSigningIdentifier?.trimmed == expectedCodeIdentifier else {
            return unknownResult(
                L10n.text(
                    "应用签名身份无法复核，未连接 Sparkle appcast。",
                    "The app signing identity could not be verified; its Sparkle appcast was not contacted."
                )
            )
        }

        do {
            switch try await probeWithTimeout(bundleURL: application.bundleURL) {
            case let .updateAvailable(version, releaseDate):
                return ApplicationUpdateCheckResult(
                    status: .updateAvailable,
                    availableVersion: version,
                    releaseDate: releaseDate,
                    releaseNotes: nil,
                    downloadSize: nil,
                    warning: L10n.text(
                        "已确认应用内更新可用；安装仍由目标应用完成。",
                        "An in-app update is available; installation remains with the target app."
                    )
                )
            case .noUpdate:
                return ApplicationUpdateCheckResult(
                    status: .upToDate,
                    availableVersion: nil,
                    releaseDate: nil,
                    releaseNotes: nil,
                    downloadSize: nil,
                    warning: nil
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return unknownResult(error.localizedDescription)
        }
    }

    private func canExecute(_ application: InstalledApplication, configuration: SparkleConfiguration?) -> Bool {
        guard automaticAdapter != nil, let configuration, let feed = configuration.feedURL,
              SparkleAutomaticUpdateAdapter.safeHTTPS(feed), application.identity.isCompleteForAutomaticUpdates,
              application.sourceEvidence.contains("valid-code-signature"), !application.isReadOnly,
              application.homebrewMetadata == nil else { return false }
        if let key = configuration.publicEDKey { return Data(base64Encoded: key.trimmed)?.count == 32 }
        return application.sourceEvidence.contains("signed-bundle-identity")
    }

    func prepareUpdate(_ application: InstalledApplication) async throws -> PreparedApplicationUpdate {
        guard canExecute(application, configuration: application.sparkleConfiguration), !application.isRunning else {
            throw ApplicationScanningError.providerUnsupported("sparkle-automatic-safety-check-unavailable")
        }
        guard let automaticAdapter, let release = try await automaticAdapter.check(application),
              release.version == application.availableVersion else { throw SparkleAutomaticUpdateError.configurationChanged }
        stateLock.withLock { releases[application.id] = release; preparedApplications[application.id] = application }
        return .init(applicationID: application.id, providerIdentifier: .sparkle, originalIdentity: application.identity,
            originalVersion: application.installedVersion, targetVersion: release.version, providerPayload: [:])
    }
    func install(_ preparedUpdate: PreparedApplicationUpdate, progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void) async throws -> ApplicationUpdateInstallResult {
        guard let automaticAdapter, let app = stateLock.withLock({ preparedApplications[preparedUpdate.applicationID] }),
              let release = stateLock.withLock({ releases[preparedUpdate.applicationID] }), app.identity == preparedUpdate.originalIdentity,
              app.installedVersion == preparedUpdate.originalVersion, release.version == preparedUpdate.targetVersion else { throw SparkleAutomaticUpdateError.configurationChanged }
        defer { _ = stateLock.withLock { preparedApplications.removeValue(forKey: app.id) } }
        return try await automaticAdapter.install(app, release: release, progress: progress)
    }

    private func probeWithTimeout(bundleURL: URL) async throws -> SparkleReadOnlyProbeOutcome {
        try await withThrowingTaskGroup(of: SparkleReadOnlyProbeOutcome.self) { group in
            group.addTask {
                try await self.probe.probe(bundleURL: bundleURL)
            }
            group.addTask {
                try await Task.sleep(for: self.probeTimeout)
                throw SparkleReadOnlyProbeError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }

    private func unknownResult(_ warning: String) -> ApplicationUpdateCheckResult {
        ApplicationUpdateCheckResult(
            status: .latestVersionUnknown,
            availableVersion: nil,
            releaseDate: nil,
            releaseNotes: nil,
            downloadSize: nil,
            warning: warning
        )
    }
}

struct SystemSparkleReadOnlyProbe: SparkleReadOnlyProbing {
    typealias SessionRunner = @Sendable (
        _ hostBundleURL: URL,
        _ applicationBundleURL: URL,
        _ expectedFeedURL: URL
    ) async throws -> SparkleReadOnlyProbeOutcome

    private let sessionRunner: SessionRunner

    init(sessionRunner: @escaping SessionRunner = SystemSparkleReadOnlyProbe.runSession) {
        self.sessionRunner = sessionRunner
    }

    func probe(bundleURL: URL) async throws -> SparkleReadOnlyProbeOutcome {
        try Task.checkCancellation()
        guard let targetBundle = Bundle(url: bundleURL.standardizedFileURL),
              let configuration = ApplicationMetadataReader.sparkleConfiguration(at: bundleURL),
              configuration.isEligibleForReadOnlyProbe,
              let expectedFeedURL = configuration.feedURL else {
            throw ApplicationScanningError.invalidApplicationBundle(bundleURL.path)
        }
        let shadowHost = try SparkleShadowHost.create(
            targetBundle: targetBundle,
            configuration: configuration
        )
        defer { shadowHost.remove() }
        return try await sessionRunner(
            shadowHost.bundleURL,
            targetBundle.bundleURL,
            expectedFeedURL
        )
    }

    private static func runSession(
        hostBundleURL: URL,
        applicationBundleURL: URL,
        expectedFeedURL: URL
    ) async throws -> SparkleReadOnlyProbeOutcome {
        guard let hostBundle = Bundle(url: hostBundleURL),
              let applicationBundle = Bundle(url: applicationBundleURL) else {
            throw ApplicationScanningError.invalidApplicationBundle(applicationBundleURL.path)
        }
        let session = await MainActor.run {
            SparkleTargetBoundProbeSession(
                hostBundle: hostBundle,
                applicationBundle: applicationBundle,
                expectedFeedURL: expectedFeedURL
            )
        }
        return try await withTaskCancellationHandler {
            try await session.run()
        } onCancel: {
            Task { @MainActor in
                session.cancel()
            }
        }
    }
}

private struct SparkleShadowHost: Sendable {
    let rootURL: URL
    let bundleURL: URL
    /// N23: an absolute path inside `rootURL`. Sparkle opens SUDefaultsDomain
    /// with NSUserDefaults(suiteName:), which then keeps "<path>.plist" in the
    /// probe's own folder. A plain domain named after the one-off host
    /// identifier left a new empty preferences file behind on every probe,
    /// since emptying a domain does not delete its file. Files earlier probes
    /// left are not touched by the app (D48: the main session moves them to
    /// the Trash).
    let defaultsDomain: String

    static func create(
        targetBundle: Bundle,
        configuration: SparkleConfiguration
    ) throws -> SparkleShadowHost {
        guard let feedURL = configuration.feedURL,
              let publicEDKey = configuration.publicEDKey,
              configuration.requiresSignedFeed else {
            throw ApplicationScanningError.invalidApplicationBundle(targetBundle.bundleURL.path)
        }
        let identifier = "com.storagecleanermac.sparkle-probe.\(UUID().uuidString.lowercased())"
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StorageCleanerMac-SparkleProbe-\(UUID().uuidString)",
            isDirectory: true
        )
        let bundleURL = rootURL.appendingPathComponent("SparkleProbe.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let defaultsDomain = rootURL.appendingPathComponent("SparkleDefaults", isDirectory: false).path
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createDirectory(
                at: contentsURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let sourceInfo = targetBundle.infoDictionary ?? [:]
            var info: [String: Any] = [
                "CFBundleIdentifier": identifier,
                "CFBundleName": sourceInfo["CFBundleName"] ?? "Sparkle Read-Only Probe",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": sourceInfo["CFBundleShortVersionString"] ?? "0",
                "CFBundleVersion": sourceInfo["CFBundleVersion"] ?? "0",
                "SUDefaultsDomain": defaultsDomain,
                "SUFeedURL": feedURL.absoluteString,
                "SUPublicEDKey": publicEDKey,
                "SURequireSignedFeed": true,
                // N23 review P2-3: with a grace period Sparkle records the first
                // failed feed-signature check in this app's standard defaults
                // under "SUInitialFailedFeedSigningValidationDate_<host id>",
                // and the host id is new on every probe. Each probe started a
                // new count anyway, so the grace period never applied; zero
                // turns it off and Sparkle writes no such key.
                "SUSignedFeedFailureExpirationInterval": 0,
            ]
            for key in [
                "SUVerifyUpdateBeforeExtraction",
                "NSUpdateSecurityPolicy",
            ] where sourceInfo[key] != nil {
                info[key] = sourceInfo[key]
            }
            let plist = try PropertyListSerialization.data(
                fromPropertyList: info,
                format: .xml,
                options: 0
            )
            try plist.write(
                to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false),
                options: .atomic
            )
            guard Bundle(url: bundleURL)?.bundleIdentifier == identifier else {
                throw ApplicationScanningError.invalidApplicationBundle(bundleURL.path)
            }
            return SparkleShadowHost(
                rootURL: rootURL,
                bundleURL: bundleURL,
                defaultsDomain: defaultsDomain
            )
        } catch {
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    func remove() {
        // Write out what Sparkle still holds before the folder goes.
        _ = CFPreferencesAppSynchronize(defaultsDomain as CFString)
        try? FileManager.default.removeItem(at: rootURL)
    }
}

@MainActor
private final class SparkleTargetBoundProbeSession: NSObject {
    private let hostBundle: Bundle
    private let applicationBundle: Bundle
    private let expectedFeedURL: URL
    private var updater: SPUUpdater?
    private var userDriver: SPUStandardUserDriver?
    private var continuation: CheckedContinuation<SparkleReadOnlyProbeOutcome, Error>?

    init(
        hostBundle: Bundle,
        applicationBundle: Bundle,
        expectedFeedURL: URL
    ) {
        self.hostBundle = hostBundle
        self.applicationBundle = applicationBundle
        self.expectedFeedURL = expectedFeedURL
        super.init()
    }

    func run() async throws -> SparkleReadOnlyProbeOutcome {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let userDriver = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
            let updater = SPUUpdater(
                hostBundle: hostBundle,
                applicationBundle: applicationBundle,
                userDriver: userDriver,
                delegate: nil
            )
            self.userDriver = userDriver
            self.updater = updater
            guard updater.feedURL?.absoluteString == expectedFeedURL.absoluteString else {
                finish(throwing: ApplicationScanningError.providerUnsupported("sparkle-feed-override"))
                return
            }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(didFindUpdate(_:)),
                name: .SUUpdaterDidFindValidUpdate,
                object: updater
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(didNotFindUpdate(_:)),
                name: .SUUpdaterDidNotFindUpdate,
                object: updater
            )
            do {
                try updater.start()
                updater.checkForUpdateInformation()
            } catch {
                finish(throwing: error)
            }
        }
    }

    func cancel() {
        finish(throwing: CancellationError())
    }

    @objc private func didFindUpdate(_ notification: Notification) {
        guard let item = notification.userInfo?[SUUpdaterAppcastItemNotificationKey] as? SUAppcastItem else {
            finish(throwing: ApplicationScanningError.providerUnsupported("sparkle-invalid-result"))
            return
        }
        finish(returning: .updateAvailable(
            version: ApplicationVersion(
                marketing: item.displayVersionString as String,
                build: item.versionString as String
            ),
            releaseDate: item.date as Date?
        ))
    }

    @objc private func didNotFindUpdate(_ notification: Notification) {
        finish(returning: .noUpdate)
    }

    private func finish(returning result: SparkleReadOnlyProbeOutcome) {
        guard let continuation else { return }
        tearDown()
        continuation.resume(returning: result)
    }

    private func finish(throwing error: Error) {
        guard let continuation else { return }
        tearDown()
        continuation.resume(throwing: error)
    }

    private func tearDown() {
        continuation = nil
        NotificationCenter.default.removeObserver(self)
        updater = nil
        userDriver = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
