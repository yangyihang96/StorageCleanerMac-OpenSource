import CryptoKit
import Darwin
import Foundation
import FileOperationShared

enum OfficialApplicationUpdateInstallerError: LocalizedError, Sendable {
    case unsupportedPackage
    case invalidResponse
    case transientResponse(statusCode: Int)
    case invalidRedirect
    case sizeMismatch
    case checksumMismatch
    case invalidDiskImage
    case diskImageTooComplex
    case mountFailed
    case noVerifiedApplication
    case candidateBelowTarget(expected: String, observed: String)
    case ambiguousApplications
    case installedApplicationChanged
    case applicationBecameRunning
    case destinationNotWritable
    case stagedArtifactChanged
    case rollbackFailed(String)
    case replacementTransactionPending
    case targetVersionMissing

    var errorDescription: String? {
        switch self {
        case .unsupportedPackage:
            L10n.text(
                "当前只允许自动安装经过验证的 DMG，或只包含一个应用的安全 ZIP。",
                "Only verified DMGs or safe ZIP archives containing exactly one application can be installed automatically."
            )
        case .invalidResponse:
            L10n.text("官方下载服务器返回了无效响应。", "The official download server returned an invalid response.")
        case let .transientResponse(statusCode):
            L10n.text(
                "官方下载暂时不可用（HTTP \(statusCode)）。",
                "The official download is temporarily unavailable (HTTP \(statusCode))."
            )
        case .invalidRedirect:
            L10n.text("官方下载发生了未授权的重定向。", "The official download used an unauthorized redirect.")
        case .sizeMismatch:
            L10n.text("下载文件大小与官方发布信息不一致。", "The download size does not match the official release metadata.")
        case .checksumMismatch:
            L10n.text("下载文件的 SHA-256 校验失败。", "The downloaded file failed SHA-256 verification.")
        case .invalidDiskImage:
            L10n.text("下载内容不是有效的 DMG 磁盘映像。", "The download is not a valid DMG disk image.")
        case .diskImageTooComplex:
            L10n.text("更新包内容过多，已停止自动安装。", "The update package contains too many entries; automatic installation stopped.")
        case .mountFailed:
            L10n.text("无法以只读方式挂载更新磁盘映像。", "The update disk image could not be mounted read-only.")
        case .noVerifiedApplication:
            L10n.text("更新包中未找到 macOS 应用。", "No macOS application was found in the update package.")
        case let .candidateBelowTarget(expected, observed):
            L10n.text(
                "更新包版本为 \(observed)，低于目标版本 \(expected)。",
                "The package version \(observed) is below the target version \(expected)."
            )
        case .ambiguousApplications:
            L10n.text("更新包中存在多个应用，已停止自动安装。", "The update package contains multiple applications; automatic installation stopped.")
        case .installedApplicationChanged:
            L10n.text("下载期间已安装应用发生变化，请重新扫描。", "The installed app changed during download; rescan before updating.")
        case .applicationBecameRunning:
            L10n.text("应用已启动；退出后可继续更新。", "The app started; quit it before continuing the update.")
        case .destinationNotWritable:
            L10n.text("应用目录不可写，需要人工授权安装。", "The application directory is not writable and requires manual authorization.")
        case .stagedArtifactChanged:
            L10n.text("暂存的官方更新包已发生变化，已停止安装。", "The staged official update package changed; installation stopped.")
        case let .rollbackFailed(path):
            L10n.text("更新失败且无法自动回滚；原应用保留在：\(path)", "The update failed and rollback could not complete; the original app remains at: \(path)")
        case .replacementTransactionPending:
            L10n.text("上一次应用替换尚未完成核验。", "A previous application replacement is still awaiting reconciliation.")
        case .targetVersionMissing:
            L10n.text("无法确认冻结的目标版本，已停止替换。", "The frozen target version is unavailable; replacement stopped.")
        }
    }
}

struct OfficialApplicationUpdateContext: Sendable {
    let application: InstalledApplication
    let source: OfficialUpdateSource
    let download: ResolvedOfficialDownload
}

struct OfficialApplicationUpdateStage: Hashable, Sendable {
    let applicationID: String
    let workingDirectory: URL
    let packageURL: URL
    let packageType: OfficialPackageType
    let downloadURL: URL
    let byteCount: Int64
    let sha256: String
}

struct OfficialApplicationUpdateInstaller: Sendable {
    private let downloadResolver = OfficialDownloadResolver()
    private let packageValidator = PackageTypeValidator()
    private let bundleVerifier: BundleIdentityVerifier
    private let mountAuthenticated: (@Sendable (AuthenticatedUpdateArchive, URL) async throws -> [URL])?
    private let detachInjected: (@Sendable ([URL]) async -> Void)?
    private let protectedReplacement: @Sendable (URL, InstalledApplication, String) async throws -> Void
    private let writable: @Sendable (URL) -> Bool
    private let transactionURL: URL
    private let metadataReader: any ApplicationMetadataReading
    private let runningStateProvider: @Sendable () async -> ApplicationRunningStateSnapshot
    private let zipExtractor = SecureZipArchiveExtractor()
    private let afterExtraction: @Sendable (URL) async throws -> Void
    private let replacementEvent: @Sendable (OfficialApplicationReplacement.Event) throws -> Void

    init(
        metadataReader: any ApplicationMetadataReading = ApplicationMetadataReader(),
        bundleVerifier: BundleIdentityVerifier = BundleIdentityVerifier(),
        mountAuthenticated: (@Sendable (AuthenticatedUpdateArchive, URL) async throws -> [URL])? = nil,
        detachInjected: (@Sendable ([URL]) async -> Void)? = nil,
        protectedReplacement: @escaping @Sendable (URL, InstalledApplication, String) async throws -> Void = { candidate, app, digest in
            try await AppUpdateBatchAuthorization.shared.replace(candidate: candidate, application: app, authenticatedSHA256: digest)
        },
        writable: @escaping @Sendable (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) },
        transactionURL: URL = OfficialApplicationReplacementTransactionLocation.defaultURL,
        afterExtraction: @escaping @Sendable (URL) async throws -> Void = { _ in },
        replacementEvent: @escaping @Sendable (OfficialApplicationReplacement.Event) throws -> Void = { _ in },
        runningStateProvider: @escaping @Sendable () async -> ApplicationRunningStateSnapshot = {
            await MainActor.run { ApplicationRunningStateSnapshot.capture() }
        }
    ) {
        self.bundleVerifier = bundleVerifier; self.mountAuthenticated = mountAuthenticated; self.detachInjected = detachInjected
        self.protectedReplacement = protectedReplacement; self.writable = writable; self.transactionURL = transactionURL
        self.metadataReader = metadataReader
        self.afterExtraction = afterExtraction; self.replacementEvent = replacementEvent
        self.runningStateProvider = runningStateProvider
    }

    /// A retry starts a fresh, fully validated request; it never pretends to
    /// resume an untrusted partial archive.
    /// Called only after Sparkle archive authentication. Extraction, bundle
    /// validation, original readback and rollback use the same installer.
    func installVerifiedSparkleArchive(_ archive: AuthenticatedUpdateArchive, application: InstalledApplication, release: SparkleRelease,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void) async throws -> ApplicationUpdateInstallResult {
        let kind: OfficialPackageType = archive.fileExtension == "zip" ? .zipArchive : .diskImage
        let source = OfficialUpdateSource(applicationIdentity: application.identity, providerType: .sparkle,
            developerName: nil, homepageURL: nil, updatePageURL: nil, releaseFeedURL: application.sparkleConfiguration?.feedURL,
            directDownloadURL: release.downloadURL, allowedHosts: [release.downloadURL.host!],
            expectedBundleIdentifier: application.bundleIdentifier, expectedTeamIdentifier: application.signingTeamIdentifier,
            expectedDesignatedRequirement: nil, verificationMethod: .sparkleConfiguration, trustLevel: .providerVerified,
            lastVerifiedAt: Date(), capability: .automatic, expectedPackageExtensions: [kind.rawValue], officialGitHubRepository: nil)
        let download = ResolvedOfficialDownload(source: source, remoteURL: release.downloadURL, packageType: kind,
            expectedSize: release.byteCount, checksumSHA256: nil, permitsAutomaticInstallation: true)
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("StorageCleaner-Verified-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        return try await installPackage(packageURL: root.appendingPathComponent("Update." + archive.fileExtension), workingDirectory: root,
            context: .init(application: application, source: source, download: download), targetVersion: release.version, authenticated: archive, progress: progress)
    }

    private static let maximumDownloadAttempts = 2
    private static let downloadRetryDelayNanoseconds: UInt64 = 200_000_000

    static func shouldRetryDownload(error: Error, attempt: Int) -> Bool {
        guard attempt < maximumDownloadAttempts,
              !(error is CancellationError) else {
            return false
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .notConnectedToInternet,
                 .dnsLookupFailed, .secureConnectionFailed:
                return true
            case .cancelled:
                return false
            default:
                return false
            }
        }
        guard let installerError = error as? OfficialApplicationUpdateInstallerError else {
            return false
        }
        if case let .transientResponse(statusCode) = installerError {
            return isRetryableHTTPStatus(statusCode)
        }
        return false
    }

    static func retryingDownload<Value: Sendable>(
        operation: @escaping @Sendable (Int) async throws -> Value,
        sleep: @escaping @Sendable (UInt64) async throws -> Void
    ) async throws -> Value {
        var attempt = 1
        while true {
            do {
                return try await operation(attempt)
            } catch {
                guard shouldRetryDownload(error: error, attempt: attempt) else {
                    throw error
                }
                try await sleep(downloadRetryDelayNanoseconds)
                attempt += 1
            }
        }
    }

    static func supportsAutomaticPackageType(_ packageType: OfficialPackageType) -> Bool {
        packageType == .diskImage || packageType == .zipArchive
    }

    static func declaredAutomaticPackageType(
        for source: OfficialUpdateSource
    ) -> OfficialPackageType? {
        guard source.expectedPackageExtensions.count == 1,
              let rawExtension = source.expectedPackageExtensions.first else {
            return nil
        }
        let normalized = rawExtension
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let packageType = OfficialPackageType(rawValue: normalized),
              supportsAutomaticPackageType(packageType) else {
            return nil
        }
        return packageType
    }

    static func applicationBundleCandidates(in roots: [URL]) throws -> [URL] {
        var candidates = [URL]()
        var entryCount = 0
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                entryCount += 1
                guard entryCount <= 50_000 else {
                    throw OfficialApplicationUpdateInstallerError.diskImageTooComplex
                }
                guard url.pathExtension.lowercased() == "app" else { continue }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw OfficialApplicationUpdateInstallerError.noVerifiedApplication
                }
                candidates.append(url)
                guard candidates.count <= 256 else {
                    throw OfficialApplicationUpdateInstallerError.ambiguousApplications
                }
            }
        }
        return candidates
    }

    static func supportsAutomaticInstallation(
        application: InstalledApplication,
        source: OfficialUpdateSource
    ) -> Bool {
        guard let packageType = declaredAutomaticPackageType(for: source) else {
            return false
        }
        let hasMatchingStaticPackage = source.directDownloadURL?.pathExtension.lowercased()
            == packageType.rawValue
        let hasSupportedDynamicPackage = packageType == .diskImage
            && source.usesDynamicGitHubReleaseAsset
        guard source.canAutomaticallyInstall,
              source.capability == .automatic,
              (source.verificationMethod == .signedRegistry
                || source.verificationMethod == .vendorManifest),
              hasMatchingStaticPackage || hasSupportedDynamicPackage,
              source.expectedBundleIdentifier == application.bundleIdentifier,
              source.expectedTeamIdentifier?.trimmed.nonEmpty
                == application.signingTeamIdentifier?.trimmed.nonEmpty,
              application.identity.isCompleteForAutomaticUpdates,
              application.packageKind == .graphicalApplication,
              application.bundleURL.pathExtension.lowercased() == "app",
              !application.isSystemApplication,
              !application.isReadOnly
        else {
            return false
        }
        return FileManager.default.isWritableFile(atPath: application.bundleURL.deletingLastPathComponent().path)
            || application.bundleURL.deletingLastPathComponent().path == "/Applications"
    }

    func install(
        context: OfficialApplicationUpdateContext,
        targetVersion: ApplicationVersion?,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        guard Self.supportsAutomaticInstallation(
            application: context.application,
            source: context.source
        ), Self.supportsAutomaticPackageType(context.download.packageType),
           Self.declaredAutomaticPackageType(for: context.source)
            == context.download.packageType,
           context.download.permitsAutomaticInstallation else {
            throw OfficialApplicationUpdateInstallerError.unsupportedPackage
        }

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerMac-AppUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        progress(ApplicationUpdateProgressEvent(
            applicationID: context.application.id,
            state: .downloading,
            fraction: nil,
            detail: L10n.text("正在从已验证的官方来源下载", "Downloading from the verified official source")
        ))
        let packageURL = try await download(context.download, into: workingDirectory)
        try validateDownloadedPackage(packageURL, download: context.download)
        try await revalidateInstalledApplication(context.application)

        return try await installPackage(
            packageURL: packageURL,
            workingDirectory: workingDirectory,
            context: context,
            targetVersion: targetVersion,
            progress: progress
        )
    }

    func stage(
        context: OfficialApplicationUpdateContext,
        targetVersion: ApplicationVersion?,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void
    ) async throws -> OfficialApplicationUpdateStage {
        guard Self.supportsAutomaticInstallation(
            application: context.application,
            source: context.source
        ), Self.supportsAutomaticPackageType(context.download.packageType),
           Self.declaredAutomaticPackageType(for: context.source)
            == context.download.packageType,
           context.download.permitsAutomaticInstallation,
           let targetVersion,
           !targetVersion.preferred.isEmpty else {
            throw OfficialApplicationUpdateInstallerError.unsupportedPackage
        }

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerMac-AppUpdate-Stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        do {
            progress(ApplicationUpdateProgressEvent(
                applicationID: context.application.id,
                state: .downloading,
                fraction: nil,
                detail: L10n.text("正在暂存已验证的官方更新包", "Staging the verified official update package")
            ))
            let packageURL = try await download(context.download, into: workingDirectory)
            try validateDownloadedPackage(packageURL, download: context.download)
            try await revalidateInstalledApplication(context.application)
            let values = try packageURL.resourceValues(forKeys: [.fileSizeKey])
            let byteCount = Int64(values.fileSize ?? 0)
            let sha256 = try sha256(of: packageURL)
            return OfficialApplicationUpdateStage(
                applicationID: context.application.id,
                workingDirectory: workingDirectory,
                packageURL: packageURL,
                packageType: context.download.packageType,
                downloadURL: context.download.remoteURL,
                byteCount: byteCount,
                sha256: sha256
            )
        } catch {
            try? FileManager.default.removeItem(at: workingDirectory)
            throw error
        }
    }

    func install(
        staged: OfficialApplicationUpdateStage,
        context: OfficialApplicationUpdateContext,
        targetVersion: ApplicationVersion?,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        defer { cleanup(staged) }
        guard staged.applicationID == context.application.id,
              staged.packageType == context.download.packageType,
              staged.downloadURL == context.download.remoteURL else {
            throw OfficialApplicationUpdateInstallerError.stagedArtifactChanged
        }
        try verifyStagedPackage(staged, download: context.download)
        try await revalidateInstalledApplication(context.application)
        return try await installPackage(
            packageURL: staged.packageURL,
            workingDirectory: staged.workingDirectory,
            context: context,
            targetVersion: targetVersion,
            authenticated: try AuthenticatedUpdateArchive.snapshot(staged.packageURL, expectedSHA256: staged.sha256),
            progress: progress
        )
    }

    func cleanup(_ staged: OfficialApplicationUpdateStage) {
        try? FileManager.default.removeItem(at: staged.workingDirectory)
    }

    static func stagedArtifactMatches(_ staged: OfficialApplicationUpdateStage) throws -> Bool {
        let expectedDirectory = staged.workingDirectory.standardizedFileURL
        guard staged.packageURL.deletingLastPathComponent().standardizedFileURL == expectedDirectory,
              FileManager.default.fileExists(atPath: staged.packageURL.path) else {
            return false
        }
        let values = try staged.packageURL.resourceValues(forKeys: [.fileSizeKey])
        let byteCount = Int64(values.fileSize ?? 0)
        guard byteCount == staged.byteCount else { return false }
        let handle = try FileHandle(forReadingFrom: staged.packageURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == staged.sha256
    }

    private func installPackage(
        packageURL: URL,
        workingDirectory: URL,
        context: OfficialApplicationUpdateContext,
        targetVersion: ApplicationVersion?,
        authenticated: AuthenticatedUpdateArchive? = nil,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void
    ) async throws -> ApplicationUpdateInstallResult {

        let archive = try authenticated ?? AuthenticatedUpdateArchive.snapshot(packageURL, expectedSHA256: context.download.checksumSHA256)
        var mountPointsToDetach: [URL] = []
        do {
            let candidate: URL
            let authenticatedDigest: String
            switch context.download.packageType {
            case .diskImage:
                if let mountAuthenticated { mountPointsToDetach = try await mountAuthenticated(archive, workingDirectory) }
                else { mountPointsToDetach = try await mountReadOnly(archive, workingDirectory: workingDirectory) }
                candidate = try verifiedCandidate(
                    in: mountPointsToDetach,
                    application: context.application,
                    source: context.source,
                    targetVersion: targetVersion,
                    requiresSingleApplicationBundle: false
                )
                authenticatedDigest = try AuthenticatedApplicationDigest.compute(candidate)
                try await afterExtraction(candidate)
            case .zipArchive:
                let extractionRoot = workingDirectory.appendingPathComponent(
                    "Extracted",
                    isDirectory: true
                )
                let extracted = try await zipExtractor.extract(bytes: archive.bytes, to: extractionRoot)
                try await afterExtraction(extractionRoot)
                candidate = try verifiedCandidate(
                    in: [extractionRoot],
                    application: context.application,
                    source: context.source,
                    targetVersion: targetVersion,
                    requiresSingleApplicationBundle: true
                )
                authenticatedDigest = try extracted.digest(for: candidate)
            case .application, .installerPackage:
                throw OfficialApplicationUpdateInstallerError.unsupportedPackage
            }

            progress(ApplicationUpdateProgressEvent(
                applicationID: context.application.id,
                state: .installing,
                fraction: nil,
                detail: L10n.text("签名验证通过，正在替换应用", "Signature verified; replacing the application")
            ))
            let privateCandidate = try AuthenticatedApplicationCandidate.copy(from: candidate, into: workingDirectory, expectedSHA256: authenticatedDigest) { url in
                let verified = try bundleVerifier.verifyReplacement(at: url, for: context.application, source: context.source)
                guard targetVersion.map({ verified.candidateVersion.reaches($0) }) ?? false else { throw OfficialApplicationUpdateInstallerError.targetVersionMissing }
            }
            try await installCandidate(
                privateCandidate.url,
                application: context.application,
                source: context.source,
                targetVersion: targetVersion,
                authenticatedDigest: privateCandidate.sha256
            )
        } catch {
            await detach(mountPointsToDetach)
            throw error
        }
        await detach(mountPointsToDetach)

        progress(ApplicationUpdateProgressEvent(
            applicationID: context.application.id,
            state: .verifying,
            fraction: nil,
            detail: L10n.text("正在验证磁盘上的新应用", "Verifying the new on-disk application")
        ))
        return ApplicationUpdateInstallResult(
            applicationID: context.application.id,
            state: .needsReconciliation,
            observedVersion: nil,
            detail: L10n.text("应用已安全替换，等待最终版本核对。", "The app was safely replaced; final version reconciliation is pending.")
        )
    }

    private func verifyStagedPackage(
        _ staged: OfficialApplicationUpdateStage,
        download: ResolvedOfficialDownload
    ) throws {
        guard try Self.stagedArtifactMatches(staged) else {
            throw OfficialApplicationUpdateInstallerError.stagedArtifactChanged
        }
        do {
            try validateDownloadedPackage(staged.packageURL, download: download)
        } catch {
            throw OfficialApplicationUpdateInstallerError.stagedArtifactChanged
        }
    }

    private func download(
        _ download: ResolvedOfficialDownload,
        into directory: URL
    ) async throws -> URL {
        // ponytail: bounded fresh-request retry; byte-range resume is
        // intentionally omitted until the source proves a safe resume contract.
        return try await Self.retryingDownload(
            operation: { _ in
                try await self.downloadAttempt(download, into: directory)
            },
            sleep: { delay in
                try await Task.sleep(nanoseconds: delay)
            }
        )
    }

    private func downloadAttempt(
        _ download: ResolvedOfficialDownload,
        into directory: URL
    ) async throws -> URL {
        var request = URLRequest(url: download.remoteURL)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let downloaded = try await OfficialUpdateDownloader(
            maximumBytes: packageValidator.maximumDownloadBytes,
            allowedHosts: download.source.allowedHosts
        ).download(request, stagingURL: directory.appendingPathComponent("Update.partial", isDirectory: false))
        let temporaryURL = downloaded.fileURL
        let response = downloaded.response
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            if let http = response as? HTTPURLResponse,
               Self.isRetryableHTTPStatus(http.statusCode) {
                throw OfficialApplicationUpdateInstallerError.transientResponse(
                    statusCode: http.statusCode
                )
            }
            throw OfficialApplicationUpdateInstallerError.invalidResponse
        }
        var redirectChain = downloaded.redirectChain
        if let finalURL = http.url, redirectChain.last != finalURL {
            redirectChain.append(finalURL)
        }
        do {
            try downloadResolver.validateRedirectChain(redirectChain, for: download)
        } catch {
            throw OfficialApplicationUpdateInstallerError.invalidRedirect
        }

        let destination = directory.appendingPathComponent(
            "Update.\(download.packageType.rawValue)",
            isDirectory: false
        )
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        let observedType = try packageValidator.validateDownloadedFile(
            at: destination,
            expectedExtensions: [download.packageType.rawValue],
            reportedContentLength: http.expectedContentLength > 0
                ? http.expectedContentLength
                : nil
        )
        guard observedType == download.packageType else {
            throw OfficialApplicationUpdateInstallerError.unsupportedPackage
        }
        return destination
    }

    private static func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 425 || statusCode == 429
            || (500...599).contains(statusCode)
    }

    private func validateDownloadedPackage(
        _ packageURL: URL,
        download: ResolvedOfficialDownload
    ) throws {
        let values = try packageURL.resourceValues(forKeys: [.fileSizeKey])
        let actualSize = Int64(values.fileSize ?? 0)
        if let expectedSize = download.expectedSize, expectedSize > 0,
           abs(actualSize - expectedSize) > max(4_096, expectedSize / 100) {
            throw OfficialApplicationUpdateInstallerError.sizeMismatch
        }
        if let expectedChecksum = download.checksumSHA256?.trimmed.nonEmpty {
            let normalized = expectedChecksum
                .lowercased()
                .replacingOccurrences(of: "sha256:", with: "")
            guard try sha256(of: packageURL) == normalized else {
                throw OfficialApplicationUpdateInstallerError.checksumMismatch
            }
        }

        switch download.packageType {
        case .diskImage:
            let handle = try FileHandle(forReadingFrom: packageURL)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            guard end >= 512 else { throw OfficialApplicationUpdateInstallerError.invalidDiskImage }
            try handle.seek(toOffset: end - 512)
            guard try handle.read(upToCount: 4) == Data("koly".utf8) else {
                throw OfficialApplicationUpdateInstallerError.invalidDiskImage
            }
        case .zipArchive:
            try zipExtractor.validateArchive(at: packageURL)
        case .application, .installerPackage:
            throw OfficialApplicationUpdateInstallerError.unsupportedPackage
        }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func revalidateInstalledApplication(_ expected: InstalledApplication) async throws {
        let runningState = await runningStateProvider()
        guard let observed = await metadataReader.read(
            applicationURL: expected.bundleURL,
            runningState: runningState,
            scanDate: Date()
        ), observed.sourceEvidence.contains("valid-code-signature"),
           observed.bundleURL.standardizedFileURL == expected.bundleURL.standardizedFileURL,
           observed.identity == expected.identity,
           observed.installedVersion == expected.installedVersion else {
            throw OfficialApplicationUpdateInstallerError.installedApplicationChanged
        }
        guard !observed.isRunning else {
            throw OfficialApplicationUpdateInstallerError.applicationBecameRunning
        }
    }

    private func mountReadOnly(_ archive: AuthenticatedUpdateArchive, workingDirectory: URL) async throws -> [URL] {
        let descriptor = try archive.imageDescriptor(in: workingDirectory)
        defer { try? descriptor.close() }
        let cancellation = OfficialUpdateInstallerCancellation()
        let data = try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try AppUpdateCommandRunner(outputLimit: 1_048_576).runSync(executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                    arguments: ["attach", "/dev/fd/0", "-readonly", "-nobrowse", "-plist"],
                    environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: 120,
                    inputFD: descriptor.fileDescriptor, permitsPersistentSystemService: true, cancelled: { cancellation.isCancelled })
            }.value
        } onCancel: { cancellation.cancel() }
        return try Self.mountPoints(data)
    }
    private static func mountPoints(_ data: Data) throws -> [URL] {
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let entities = dictionary["system-entities"] as? [[String: Any]] else { throw OfficialApplicationUpdateInstallerError.mountFailed }
        let urls = entities.compactMap { ($0["mount-point"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() } }
            .filter { $0.path.hasPrefix("/Volumes/") }
        guard !urls.isEmpty else { throw OfficialApplicationUpdateInstallerError.mountFailed }
        return urls
    }

    func mountReadOnly(_ imageURL: URL) async throws -> [URL] {
        let cancellation = OfficialUpdateInstallerCancellation()
        let result = try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try Shell.run(
                    "/usr/bin/hdiutil",
                    ["attach", imageURL.path, "-readonly", "-nobrowse", "-plist"],
                    timeout: 120,
                    outputByteLimit: 1_048_576,
                    cancellationCheck: { cancellation.isCancelled },
                    // A successful attach deliberately leaves Apple's disk
                    // image helper alive until detach. The default shell
                    // cleanup would otherwise tear down the new mount.
                    permitsPersistentSystemService: true
                )
            }.value
        } onCancel: {
            cancellation.cancel()
        }
        guard result.terminationStatus == 0,
              let data = result.standardOutput.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let entities = dictionary["system-entities"] as? [[String: Any]] else {
            throw OfficialApplicationUpdateInstallerError.mountFailed
        }
        let mountPoints = entities.compactMap { entity -> URL? in
            guard let path = entity["mount-point"] as? String else { return nil }
            let resolved = URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard resolved.path.hasPrefix("/Volumes/") else { return nil }
            return resolved
        }
        guard !mountPoints.isEmpty else {
            throw OfficialApplicationUpdateInstallerError.mountFailed
        }
        return mountPoints
    }

    func detach(_ mountPoints: [URL]) async {
        if let detachInjected { await detachInjected(mountPoints); return }
        for mountPoint in mountPoints.reversed() {
            _ = try? await Task.detached(priority: .utility) {
                try Shell.run(
                    "/usr/bin/hdiutil",
                    ["detach", mountPoint.path],
                    timeout: 30,
                    outputByteLimit: 262_144
                )
            }.value
        }
    }

    func verifiedCandidate(
        in mountPoints: [URL],
        application: InstalledApplication,
        source: OfficialUpdateSource,
        targetVersion: ApplicationVersion?,
        requiresSingleApplicationBundle: Bool
    ) throws -> URL {
        let candidates = try Self.applicationBundleCandidates(in: mountPoints)

        if requiresSingleApplicationBundle, candidates.count != 1 {
            throw candidates.isEmpty
                ? OfficialApplicationUpdateInstallerError.noVerifiedApplication
                : OfficialApplicationUpdateInstallerError.ambiguousApplications
        }

        var verified = [URL]()
        var firstVerificationError: Error?
        for candidate in candidates {
            do {
                let result = try bundleVerifier.verifyReplacement(
                    at: candidate,
                    for: application,
                    source: source
                )
                if let targetVersion, !result.candidateVersion.reaches(targetVersion) {
                    firstVerificationError = OfficialApplicationUpdateInstallerError
                        .candidateBelowTarget(
                            expected: targetVersion.display,
                            observed: result.candidateVersion.display
                        )
                    continue
                }
                verified.append(candidate)
            } catch {
                if firstVerificationError == nil { firstVerificationError = error }
            }
        }
        guard !verified.isEmpty else {
            if let firstVerificationError { throw firstVerificationError }
            throw OfficialApplicationUpdateInstallerError.noVerifiedApplication
        }
        guard verified.count == 1 else {
            throw OfficialApplicationUpdateInstallerError.ambiguousApplications
        }
        return verified[0]
    }

    private func installCandidate(
        _ candidate: URL,
        application: InstalledApplication,
        source: OfficialUpdateSource,
        targetVersion: ApplicationVersion?,
        authenticatedDigest: String
    ) async throws {
        guard try AuthenticatedApplicationDigest.compute(candidate) == authenticatedDigest else { throw SparkleAutomaticUpdateError.invalidSignature }
        guard let targetVersion, !targetVersion.preferred.isEmpty else {
            throw OfficialApplicationUpdateInstallerError.targetVersionMissing
        }
        let parent = application.bundleURL.deletingLastPathComponent()
        guard writable(parent) else {
            try await revalidateInstalledApplication(application)
            guard AppUpdateProtectedReplacementPolicy.accepts(application) else { throw AuthorizedMoveError.unavailable }
            try await protectedReplacement(candidate, application, authenticatedDigest)
            return
        }
        let staged = parent.appendingPathComponent(
            ".StorageCleanerMac-Update-\(UUID().uuidString).app",
            isDirectory: true
        )
        // Once a transaction exists, it owns cleanup. A rollback failure must
        // retain staged (which may be the sole old bundle) and its journal.
        var handedToTransaction = false
        defer { if !handedToTransaction { try? FileManager.default.removeItem(at: staged) } }
        try FileManager.default.copyItem(at: candidate, to: staged)
        guard try AuthenticatedApplicationDigest.compute(staged) == authenticatedDigest else { throw SparkleAutomaticUpdateError.invalidSignature }
        _ = try bundleVerifier.verifyReplacement(
            at: staged,
            for: application,
            source: source
        )
        // Copying a large bundle can take long enough for the original app to
        // launch or change. Re-read its signature, version and running state at
        // the last safe point before the filesystem swap.
        try await revalidateInstalledApplication(application)
        handedToTransaction = true
        try OfficialApplicationReplacement.replace(
            destination: application.bundleURL,
            staged: staged,
            expectedIdentity: application.identity,
            originalVersion: application.installedVersion,
            targetVersion: targetVersion,
            transactionURL: transactionURL,
            authenticatedDigest: authenticatedDigest,
            event: replacementEvent
        ) { installedURL in
            _ = try bundleVerifier.verifyReplacement(
                at: installedURL,
                for: application,
                source: source
            )
        }
    }
}

enum OfficialApplicationReplacementPhase: String, Codable, Sendable {
    case rollbackFailed
    case bundlesExchanged
    /// The record is durable, but no filesystem move has been observed yet.
    case prepared
    /// The old application was moved to `backupURL`; the staged bundle is
    /// still expected to be moved into `destinationURL`.
    case destinationMovedToBackup
    /// The staged bundle is now at `destinationURL`; the backup can be removed
    /// after the new bundle has been verified.
    case stagedMovedToDestination
}

struct OfficialApplicationReplacementTransaction: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let rootURL: URL
    let destinationURL: URL
    let backupURL: URL
    let stagedURL: URL
    let expectedIdentity: ApplicationIdentity
    let originalVersion: ApplicationVersion
    let targetVersion: ApplicationVersion
    let authenticatedDigest: String?
    var retainedOldURL: URL?
    var phase: OfficialApplicationReplacementPhase

    init(
        id: UUID = UUID(),
        rootURL: URL,
        destinationURL: URL,
        backupURL: URL,
        stagedURL: URL,
        expectedIdentity: ApplicationIdentity,
        originalVersion: ApplicationVersion,
        targetVersion: ApplicationVersion,
        phase: OfficialApplicationReplacementPhase,
        authenticatedDigest: String? = nil,
        retainedOldURL: URL? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.rootURL = rootURL
        self.destinationURL = destinationURL
        self.backupURL = backupURL
        self.stagedURL = stagedURL
        self.expectedIdentity = expectedIdentity
        self.originalVersion = originalVersion
        self.targetVersion = targetVersion
        self.authenticatedDigest = authenticatedDigest; self.retainedOldURL = retainedOldURL
        self.phase = phase
    }
}

enum OfficialApplicationReplacementRecoveryResult: Equatable, Sendable {
    case none
    case restoredOriginal
    case cleanedCandidate
}

enum OfficialApplicationReplacementRecoveryError: LocalizedError, Sendable, Equatable {
    case invalidTransactionRecord
    case transactionNotOwned
    case filesystemStateMismatch
    case identityMismatch
    case recoveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidTransactionRecord:
            "The application replacement transaction record is invalid."
        case .transactionNotOwned:
            "The application replacement transaction record is not owner-only."
        case .filesystemStateMismatch:
            "The application replacement filesystem state does not match the durable transaction."
        case .identityMismatch:
            "The application replacement identity does not match the durable transaction."
        case let .recoveryFailed(detail):
            "The application replacement could not be reconciled: \(detail)"
        }
    }
}

struct OfficialApplicationReplacementTransactionStore: Sendable {
    let fileURL: URL

    init(fileURL: URL = OfficialApplicationReplacementTransactionLocation.defaultURL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    func load() throws -> OfficialApplicationReplacementTransaction? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        guard Self.isOwnerOnlyDirectory(fileURL.deletingLastPathComponent()),
              Self.isOwnerOnlyRegularFile(fileURL) else {
            throw OfficialApplicationReplacementRecoveryError.transactionNotOwned
        }
        guard let values = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              values.isSymbolicLink != true,
              values.isRegularFile == true else {
            throw OfficialApplicationReplacementRecoveryError.invalidTransactionRecord
        }
        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let decoder = JSONDecoder()
            let transaction = try decoder.decode(
                OfficialApplicationReplacementTransaction.self,
                from: data
            )
            guard transaction.schemaVersion == OfficialApplicationReplacementTransaction.currentSchemaVersion else {
                throw OfficialApplicationReplacementRecoveryError.invalidTransactionRecord
            }
            return transaction
        } catch let error as OfficialApplicationReplacementRecoveryError {
            throw error
        } catch {
            throw OfficialApplicationReplacementRecoveryError.invalidTransactionRecord
        }
    }

    func save(_ transaction: OfficialApplicationReplacementTransaction) throws {
        let fileManager = FileManager.default
        let parent = fileURL.deletingLastPathComponent()
        try Self.ensureOwnerOnlyDirectory(parent)
        if fileManager.fileExists(atPath: fileURL.path),
           !Self.isOwnerOnlyRegularFile(fileURL) {
            throw OfficialApplicationReplacementRecoveryError.transactionNotOwned
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(transaction)
        // `.atomic` writes a sibling temporary file and renames it into place;
        // the final mode is tightened before the next process can trust it.
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    func clear() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        guard Self.isOwnerOnlyDirectory(fileURL.deletingLastPathComponent()),
              Self.isOwnerOnlyRegularFile(fileURL) else {
            throw OfficialApplicationReplacementRecoveryError.transactionNotOwned
        }
        try fileManager.removeItem(at: fileURL)
    }

    private static func ensureOwnerOnlyDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let owner = attributes[.ownerAccountID] as? NSNumber,
                  owner.uint32Value == getuid() else {
                throw OfficialApplicationReplacementRecoveryError.transactionNotOwned
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
            guard isOwnerOnlyDirectory(url) else {
                throw OfficialApplicationReplacementRecoveryError.transactionNotOwned
            }
            return
        }
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard isOwnerOnlyDirectory(url) else {
            throw OfficialApplicationReplacementRecoveryError.transactionNotOwned
        }
    }

    private static func isOwnerOnlyDirectory(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return owner.uint32Value == getuid() && (permissions.uint16Value & 0o077) == 0
    }

    private static func isOwnerOnlyRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return owner.uint32Value == getuid() && (permissions.uint16Value & 0o077) == 0
    }
}

enum OfficialApplicationReplacementTransactionLocation {
    static var defaultURL: URL {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("AppUpdates", isDirectory: true)
            .appendingPathComponent("official-replacement-v1.json", isDirectory: false)
    }
}

enum OfficialApplicationReplacement {
    enum Event: Sendable, Equatable { case beforeSwap, afterSwap, beforeCleanup, afterCleanup, beforeRollback }
    typealias IdentityVerifier = @Sendable (URL, ApplicationIdentity) throws -> Bool

    static func replace(
        destination: URL,
        staged: URL,
        expectedIdentity: ApplicationIdentity,
        originalVersion: ApplicationVersion,
        targetVersion: ApplicationVersion,
        transactionURL: URL = OfficialApplicationReplacementTransactionLocation.defaultURL,
        authenticatedDigest: String,
        event: (Event) throws -> Void = { _ in },
        verify: (URL) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let destination = destination.standardizedFileURL
        let staged = staged.standardizedFileURL
        let root = destination.deletingLastPathComponent().standardizedFileURL
        guard fileManager.fileExists(atPath: destination.path),
              fileManager.fileExists(atPath: staged.path),
              Self.isSafeBundlePath(destination, root: root),
              Self.isSafeBundlePath(staged, root: root) else {
            throw OfficialApplicationReplacementRecoveryError.filesystemStateMismatch
        }

        let store = OfficialApplicationReplacementTransactionStore(fileURL: transactionURL)
        if try store.load() != nil {
            throw OfficialApplicationUpdateInstallerError.replacementTransactionPending
        }

        let backup = root.appendingPathComponent(
            ".StorageCleanerMac-Backup-\(UUID().uuidString).app",
            isDirectory: true
        )
        let transaction = OfficialApplicationReplacementTransaction(
            rootURL: root,
            destinationURL: destination,
            backupURL: backup,
            stagedURL: staged,
            expectedIdentity: expectedIdentity,
            originalVersion: originalVersion,
            targetVersion: targetVersion,
            phase: .prepared,
            authenticatedDigest: authenticatedDigest
        )
        try Self.validate(transaction)
        try store.save(transaction)

        var exchanged = false
        var oldURL = staged
        var backupRemoved = false
        var restored = false
        do {
            try event(.beforeSwap)
            try AuthenticatedApplicationDigest.authenticateCopy(staged, expectedSHA256: authenticatedDigest)
            try swap(staged, destination)
            exchanged = true
            try event(.afterSwap)
            try AuthenticatedApplicationDigest.authenticateCopy(destination, expectedSHA256: authenticatedDigest)
            try store.save(Self.withPhase(transaction, .bundlesExchanged))
            try fileManager.moveItem(at: staged, to: backup)
            oldURL = backup
            try store.save(Self.withPhase(transaction, .stagedMovedToDestination))
            try verify(destination)
            try event(.beforeCleanup)
            try AuthenticatedApplicationDigest.authenticateCopy(destination, expectedSHA256: authenticatedDigest)
            try fileManager.removeItem(at: backup)
            backupRemoved = true
            try event(.afterCleanup)
            try store.clear()
        } catch {
            if exchanged && !backupRemoved {
                do {
                    try event(.beforeRollback)
                    try swap(oldURL, destination)
                    restored = true
                    try fileManager.removeItem(at: oldURL)
                    try store.clear()
                } catch {
                    var retained = Self.withPhase(transaction, .rollbackFailed)
                    retained.retainedOldURL = restored ? destination : oldURL
                    try? store.save(retained)
                    throw OfficialApplicationUpdateInstallerError.rollbackFailed((restored ? destination : oldURL).path + "；staging: " + staged.path + "；journal: " + transactionURL.path)
                }
            } else if !exchanged { try? store.clear() }
            throw error
        }
    }

    private static func swap(_ from: URL, _ to: URL) throws {
        let result = from.path.withCString { from in to.path.withCString { to in renamex_np(from, to, UInt32(RENAME_SWAP)) } }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func reconcilePending(
        transactionURL: URL = OfficialApplicationReplacementTransactionLocation.defaultURL,
        expectedDestinationURL: URL? = nil,
        expectedIdentity: ApplicationIdentity? = nil,
        expectedOriginalVersion: ApplicationVersion? = nil,
        expectedTargetVersion: ApplicationVersion? = nil,
        identityVerifier: @escaping IdentityVerifier = defaultIdentityVerifier
    ) throws -> OfficialApplicationReplacementRecoveryResult {
        let store = OfficialApplicationReplacementTransactionStore(fileURL: transactionURL)
        guard let transaction = try store.load() else { return .none }
        try validate(transaction)
        if transaction.phase == .rollbackFailed {
            throw OfficialApplicationUpdateInstallerError.rollbackFailed((transaction.retainedOldURL ?? transaction.stagedURL).path + "；journal: " + transactionURL.path)
        }
        if let expectedDestinationURL,
           transaction.destinationURL.standardizedFileURL.path
                != expectedDestinationURL.standardizedFileURL.path {
            throw OfficialApplicationReplacementRecoveryError.filesystemStateMismatch
        }
        if let expectedIdentity,
           transaction.expectedIdentity != expectedIdentity {
            throw OfficialApplicationReplacementRecoveryError.identityMismatch
        }
        if let expectedOriginalVersion,
           transaction.originalVersion != expectedOriginalVersion {
            throw OfficialApplicationReplacementRecoveryError.identityMismatch
        }
        if let expectedTargetVersion,
           transaction.targetVersion != expectedTargetVersion {
            throw OfficialApplicationReplacementRecoveryError.identityMismatch
        }

        let fileManager = FileManager.default
        let destinationExists = fileManager.fileExists(atPath: transaction.destinationURL.path)
        let backupExists = fileManager.fileExists(atPath: transaction.backupURL.path)
        let stagedExists = fileManager.fileExists(atPath: transaction.stagedURL.path)

        let expectedIdentity = transaction.expectedIdentity

        func verifyOriginal(_ url: URL) throws {
            guard try identityVerifier(url, expectedIdentity),
                  Self.matchesOriginalVersion(
                      at: url,
                      expected: transaction.originalVersion
                  ) else {
                throw OfficialApplicationReplacementRecoveryError.identityMismatch
            }
        }

        func verifyCandidate(_ url: URL) throws {
            guard let digest = transaction.authenticatedDigest else { throw OfficialApplicationUpdateInstallerError.stagedArtifactChanged }
            try AuthenticatedApplicationDigest.authenticateCopy(url, expectedSHA256: digest)
            guard try identityVerifier(url, expectedIdentity),
                  Self.matchesCandidateVersion(
                      at: url,
                      original: transaction.originalVersion,
                      target: transaction.targetVersion
                  ) else {
                throw OfficialApplicationReplacementRecoveryError.identityMismatch
            }
        }

        // A move can complete immediately before the process dies, before its
        // next phase record is flushed. Infer only states that are uniquely
        // identified by the expected old version and the generated paths.
        if !destinationExists, backupExists, stagedExists {
            try verifyOriginal(transaction.backupURL)
            try verifyCandidate(transaction.stagedURL)
            try store.save(Self.withPhase(transaction, .prepared))
            try fileManager.moveItem(at: transaction.backupURL, to: transaction.destinationURL)
            try verifyOriginal(transaction.destinationURL)
            try fileManager.removeItem(at: transaction.stagedURL)
            try store.clear()
            return .restoredOriginal
        }

        if destinationExists, backupExists, !stagedExists {
            guard transaction.phase == .destinationMovedToBackup
                    || transaction.phase == .stagedMovedToDestination else {
                throw OfficialApplicationReplacementRecoveryError.filesystemStateMismatch
            }
            try verifyOriginal(transaction.backupURL)
            try verifyCandidate(transaction.destinationURL)
            try fileManager.removeItem(at: transaction.backupURL)
            try store.clear()
            return .cleanedCandidate
        }

        if destinationExists, !backupExists, stagedExists,
           Self.matchesCandidateVersion(at: transaction.destinationURL, original: transaction.originalVersion, target: transaction.targetVersion),
           Self.matchesOriginalVersion(at: transaction.stagedURL, expected: transaction.originalVersion) {
            try verifyCandidate(transaction.destinationURL)
            try verifyOriginal(transaction.stagedURL)
            try fileManager.removeItem(at: transaction.stagedURL)
            try store.clear()
            return .cleanedCandidate
        }

        if destinationExists, !backupExists, stagedExists {
            guard transaction.phase == .prepared
                    || transaction.phase == .destinationMovedToBackup else {
                throw OfficialApplicationReplacementRecoveryError.filesystemStateMismatch
            }
            try verifyOriginal(transaction.destinationURL)
            try verifyCandidate(transaction.stagedURL)
            try fileManager.removeItem(at: transaction.stagedURL)
            try store.clear()
            return transaction.phase == .prepared ? .none : .restoredOriginal
        }

        if destinationExists, !backupExists, !stagedExists {
            switch transaction.phase {
            case .prepared:
                try verifyOriginal(transaction.destinationURL)
                try store.clear()
                return .restoredOriginal
            case .destinationMovedToBackup, .rollbackFailed:
                throw OfficialApplicationReplacementRecoveryError.filesystemStateMismatch
            case .bundlesExchanged, .stagedMovedToDestination:
                try verifyCandidate(transaction.destinationURL)
                try store.clear()
                return .cleanedCandidate
            }
        }

        if !destinationExists, backupExists, !stagedExists {
            try verifyOriginal(transaction.backupURL)
            try store.save(Self.withPhase(transaction, .prepared))
            try fileManager.moveItem(at: transaction.backupURL, to: transaction.destinationURL)
            try verifyOriginal(transaction.destinationURL)
            try store.clear()
            return .restoredOriginal
        }

        throw OfficialApplicationReplacementRecoveryError.filesystemStateMismatch
    }

    private static func withPhase(
        _ transaction: OfficialApplicationReplacementTransaction,
        _ phase: OfficialApplicationReplacementPhase
    ) -> OfficialApplicationReplacementTransaction {
        OfficialApplicationReplacementTransaction(
            id: transaction.id,
            rootURL: transaction.rootURL,
            destinationURL: transaction.destinationURL,
            backupURL: transaction.backupURL,
            stagedURL: transaction.stagedURL,
            expectedIdentity: transaction.expectedIdentity,
            originalVersion: transaction.originalVersion,
            targetVersion: transaction.targetVersion,
            phase: phase,
            authenticatedDigest: transaction.authenticatedDigest,
            retainedOldURL: transaction.retainedOldURL
        )
    }

    private static func validate(
        _ transaction: OfficialApplicationReplacementTransaction
    ) throws {
        guard transaction.schemaVersion == OfficialApplicationReplacementTransaction.currentSchemaVersion,
              transaction.id.uuidString != "00000000-0000-0000-0000-000000000000",
              transaction.expectedIdentity.isCompleteForAutomaticUpdates,
              !transaction.expectedIdentity.bundleIdentifier.contains("/"),
              transaction.originalVersion < transaction.targetVersion else {
            throw OfficialApplicationReplacementRecoveryError.invalidTransactionRecord
        }

        let root = transaction.rootURL.standardizedFileURL
        let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL
        guard root.isFileURL,
              root.path.hasPrefix("/"),
              root.path == rootResolved.path,
              Self.isDirectory(root),
              Self.isSafeBundlePath(transaction.destinationURL, root: root),
              Self.isSafeGeneratedPath(transaction.backupURL, root: root, prefix: ".StorageCleanerMac-Backup-"),
              Self.isSafeGeneratedPath(transaction.stagedURL, root: root, prefix: ".StorageCleanerMac-Update-") else {
            throw OfficialApplicationReplacementRecoveryError.invalidTransactionRecord
        }
        guard transaction.destinationURL.standardizedFileURL.path != transaction.backupURL.standardizedFileURL.path,
              transaction.destinationURL.standardizedFileURL.path != transaction.stagedURL.standardizedFileURL.path,
              transaction.backupURL.standardizedFileURL.path != transaction.stagedURL.standardizedFileURL.path else {
            throw OfficialApplicationReplacementRecoveryError.invalidTransactionRecord
        }
    }

    private static func isSafeBundlePath(_ url: URL, root: URL) -> Bool {
        let candidate = url.standardizedFileURL
        guard candidate.isFileURL,
              candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              candidate.deletingLastPathComponent().path == root.path else {
            return false
        }
        if let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            return false
        }
        return true
    }

    private static func isSafeGeneratedPath(_ url: URL, root: URL, prefix: String) -> Bool {
        guard isSafeBundlePath(url, root: root) else {
            return false
        }
        let name = url.standardizedFileURL.lastPathComponent
        guard name.hasPrefix(prefix) else { return false }
        let uuidPart = String(name.dropFirst(prefix.count).dropLast(4))
        return UUID(uuidString: uuidPart) != nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func matchesOriginalVersion(
        at url: URL,
        expected: ApplicationVersion?
    ) -> Bool {
        guard let expected else { return true }
        return observedVersion(at: url) == expected
    }

    private static func matchesCandidateVersion(
        at url: URL,
        original: ApplicationVersion?,
        target: ApplicationVersion?
    ) -> Bool {
        guard let original,
              let target,
              let observed = observedVersion(at: url) else {
            return false
        }
        return observed != original && observed.reaches(target)
    }

    private static func observedVersion(at url: URL) -> ApplicationVersion? {
        let infoURL = url.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = value as? [String: Any] else { return nil }
        let observed = ApplicationVersion(
            marketing: (info["CFBundleShortVersionString"] as? String) ?? "",
            build: (info["CFBundleVersion"] as? String) ?? ""
        )
        return observed.preferred.isEmpty ? nil : observed
    }

    static let defaultIdentityVerifier: IdentityVerifier = { url, expected in
        let infoURL = url.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = value as? [String: Any],
              info["CFBundleIdentifier"] as? String == expected.bundleIdentifier else {
            return false
        }
        do {
            let signature = try CodeSignatureVerifier().verifyCode(at: url)
            // Two missing Team IDs are not a match: without an expected,
            // Apple-anchored Team ID the replacement cannot be tied to the
            // same developer.
            guard let expectedTeam = expected.signingTeamIdentifier?.trimmed.nonEmpty,
                  signature.teamIdentifier == expectedTeam else {
                return false
            }
            if let expectedCodeIdentifier = expected.codeSigningIdentifier,
               signature.codeSigningIdentifier != expectedCodeIdentifier {
                return false
            }
            return signature.isValid
        } catch {
            return false
        }
    }
}

/// Downloads through a plain delegate-driven task: unlike the async
/// convenience API, it is guaranteed to report every write, so the size
/// limit stops an oversized or unbounded (chunked) response while it streams
/// instead of after the whole file reached the disk.
struct OfficialUpdateDownloader: Sendable {
    struct Result: Sendable {
        let fileURL: URL
        let response: URLResponse
        let redirectChain: [URL]
    }

    /// Test seams; production leaves both empty.
    struct TestHooks: Sendable {
        /// Runs after the transfer task exists and before the download
        /// registers for its completion, which may arrive first.
        var beforeStart: (@Sendable () -> Void)?
        /// Sees the running total of every write the size limit checks.
        var didWrite: (@Sendable (_ totalBytesWritten: Int64) -> Void)?
    }

    let maximumBytes: Int64
    let allowedHosts: Set<String>
    var makeConfiguration: @Sendable () -> URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30 * 60
        return configuration
    }
    var testHooks = TestHooks()

    func download(_ request: URLRequest, stagingURL: URL) async throws -> Result {
        guard let initialURL = request.url else { throw OfficialApplicationUpdateInstallerError.invalidResponse }
        let delegate = OfficialUpdateDownloadDelegate(
            initialURL: initialURL,
            allowedHosts: allowedHosts,
            maximumDownloadBytes: maximumBytes,
            stagingURL: stagingURL,
            testHooks: testHooks
        )
        let session = URLSession(configuration: makeConfiguration(), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (fileURL, response) = try await delegate.run(session.downloadTask(with: request))
            // A refused redirect or a crossed limit fails the download even
            // if the transfer still managed to complete.
            guard !delegate.rejectedRedirect, !delegate.exceededSize else { throw URLError(.cancelled) }
            return Result(fileURL: fileURL, response: response, redirectChain: delegate.redirectChain)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            if delegate.rejectedRedirect { throw OfficialApplicationUpdateInstallerError.invalidRedirect }
            if delegate.exceededSize { throw PackageValidationError.fileTooLarge }
            throw error
        }
    }
}

private final class OfficialUpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private typealias Outcome = Swift.Result<(URL, URLResponse), Error>

    private let allowedHosts: Set<String>
    private let maximumDownloadBytes: Int64
    private let stagingURL: URL
    private let testHooks: OfficialUpdateDownloader.TestHooks
    private let validator = AllowedHostValidator()
    private let lock = NSLock()
    private var chain: [URL]
    private var didReject = false
    private var didExceedSize = false
    private var finishedURL: URL?
    private var finishError: Error?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    /// A completion that arrived before `run` registered its continuation,
    /// for example for a task cancelled before it started.
    private var earlyOutcome: Outcome?

    init(
        initialURL: URL,
        allowedHosts: Set<String>,
        maximumDownloadBytes: Int64,
        stagingURL: URL,
        testHooks: OfficialUpdateDownloader.TestHooks
    ) {
        self.allowedHosts = allowedHosts
        self.maximumDownloadBytes = maximumDownloadBytes
        self.stagingURL = stagingURL
        self.testHooks = testHooks
        chain = [initialURL]
    }

    var redirectChain: [URL] { lock.withLock { chain } }
    var rejectedRedirect: Bool { lock.withLock { didReject } }
    var exceededSize: Bool { lock.withLock { didExceedSize } }

    func run(_ task: URLSessionDownloadTask) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                testHooks.beforeStart?()
                // Registration and completion meet under one lock, so the
                // download resumes whichever of the two comes first.
                let early = lock.withLock { () -> Outcome? in
                    if let earlyOutcome { return earlyOutcome }
                    self.continuation = continuation
                    return nil
                }
                if let early {
                    continuation.resume(with: early)
                } else if Task.isCancelled {
                    // Never start a transfer for a cancelled caller; the
                    // cancellation still completes the task and resumes here.
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // A declared length over the limit stops at the first write; an
        // undeclared (chunked) one stops as soon as it crosses the limit.
        if totalBytesWritten > maximumDownloadBytes || totalBytesExpectedToWrite > maximumDownloadBytes {
            lock.withLock { didExceedSize = true }
            downloadTask.cancel()
        }
        testHooks.didWrite?(totalBytesWritten)
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The system deletes `location` when this returns; keep the bytes.
        do {
            try? FileManager.default.removeItem(at: stagingURL)
            try FileManager.default.moveItem(at: location, to: stagingURL)
            lock.withLock { finishedURL = stagingURL }
        } catch {
            lock.withLock { finishError = error }
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let response = task.response
        let (continuation, outcome) = lock.withLock {
            () -> (CheckedContinuation<(URL, URLResponse), Error>?, Outcome) in
            let outcome: Outcome
            if let error {
                outcome = .failure(error)
            } else if let finishError {
                outcome = .failure(finishError)
            } else if let finishedURL, let response {
                outcome = .success((finishedURL, response))
            } else {
                outcome = .failure(OfficialApplicationUpdateInstallerError.invalidResponse)
            }
            // `run` may not have registered yet: keep the outcome for it.
            guard let continuation = self.continuation else {
                earlyOutcome = outcome
                return (nil, outcome)
            }
            self.continuation = nil
            return (continuation, outcome)
        }
        continuation?.resume(with: outcome)
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              (try? validator.validate(url, allowedHosts: allowedHosts)) != nil else {
            lock.withLock { didReject = true }
            // Refusing only stops following: the task would still complete
            // with the redirect's own body. Cancel it so the download fails as
            // an invalid redirect.
            task.cancel()
            completionHandler(nil)
            return
        }
        lock.withLock { chain.append(url) }

        completionHandler(request)
    }
}

private final class OfficialUpdateInstallerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
