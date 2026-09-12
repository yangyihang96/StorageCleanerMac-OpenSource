import Foundation
import Security

protocol MacAppStoreReceiptVerifying: Sendable {
    func verifyReceipt(at applicationURL: URL) async -> Bool
}

struct MacAppStoreReceiptVerifier: MacAppStoreReceiptVerifying {
    func verifyReceipt(at applicationURL: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            let receiptURL = applicationURL
                .appendingPathComponent("Contents/_MASReceipt/receipt", isDirectory: false)
            guard ApplicationMetadataReader.hasAppStoreReceipt(at: applicationURL),
                  let data = try? Data(contentsOf: receiptURL, options: [.mappedIfSafe])
            else {
                return false
            }

            var decoder: CMSDecoder?
            guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return false }
            let updateStatus = data.withUnsafeBytes { buffer -> OSStatus in
                guard let baseAddress = buffer.baseAddress else { return errSecDecode }
                return CMSDecoderUpdateMessage(decoder, baseAddress, data.count)
            }
            guard updateStatus == errSecSuccess,
                  CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
                  let policy = SecPolicyCreateWithProperties(kSecPolicyMacAppStoreReceipt, nil)
            else {
                return false
            }

            var signerStatus = CMSSignerStatus(rawValue: 0)!
            var trust: SecTrust?
            var certificateStatus: OSStatus = errSecDecode
            let status = CMSDecoderCopySignerStatus(
                decoder,
                0,
                policy,
                true,
                &signerStatus,
                &trust,
                &certificateStatus
            )
            guard status == errSecSuccess
                && signerStatus == .valid
                && certificateStatus == errSecSuccess,
                  let applicationBundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier,
                  Self.receipt(in: decoder, matchesBundleIdentifier: applicationBundleIdentifier) else {
                return false
            }
            return true
        }.value
    }

    private static func receipt(
        in decoder: CMSDecoder,
        matchesBundleIdentifier applicationBundleIdentifier: String
    ) -> Bool {
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess,
              let content else { return false }
        return MacAppStoreReceiptPayloadParser.receipt(
            payload: content as Data,
            matchesBundleIdentifier: applicationBundleIdentifier
        )
    }
}

final class MacAppStoreCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

enum MacAppStoreExecutableLocator {
    private static let standardPaths = [
        "/opt/homebrew/bin/mas",
        "/usr/local/bin/mas",
    ]

    static func locate(fileManager: FileManager = .default) -> URL? {
        standardPaths
            .map { URL(fileURLWithPath: $0, isDirectory: false) }
            .first { isTrusted($0, fileManager: fileManager) }
    }

    static func isTrusted(_ executableURL: URL, fileManager: FileManager = .default) -> Bool {
        let executable = executableURL.standardizedFileURL
        guard standardPaths.contains(executable.path),
              executable.lastPathComponent == "mas",
              fileManager.isExecutableFile(atPath: executable.path) else {
            return false
        }
        let resolved = executable.resolvingSymlinksInPath().standardizedFileURL
        let expectedCellarPrefix = executable.path.hasPrefix("/opt/homebrew/")
            ? "/opt/homebrew/Cellar/mas/"
            : "/usr/local/Cellar/mas/"
        guard resolved == executable || resolved.path.hasPrefix(expectedCellarPrefix) else {
            return false
        }
        return [
            executable,
            executable.deletingLastPathComponent(),
            resolved,
            resolved.deletingLastPathComponent(),
        ].allSatisfy { url in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let owner = attributes[.ownerAccountID] as? NSNumber,
                  let permissions = attributes[.posixPermissions] as? NSNumber else {
                return false
            }
            let ownerID = owner.uint32Value
            return (ownerID == 0 || ownerID == getuid())
                && (permissions.uint16Value & 0o002) == 0
        }
    }
}

enum MacAppStoreAutomaticUpdateSupport {
    static let evidencePrefix = "mas-product-id:"

    static func productIdentifier(from productURL: URL?) -> UInt64? {
        guard let productURL else { return nil }
        for component in productURL.pathComponents.reversed() {
            guard component.hasPrefix("id"),
                  let identifier = UInt64(component.dropFirst(2)),
                  identifier > 0 else { continue }
            return identifier
        }
        return nil
    }

    static func productURL(for identifier: UInt64) -> URL? {
        guard identifier > 0 else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(identifier)")
    }

    static func recordedProductIdentifier(in evidence: [String]) -> UInt64? {
        evidence.lazy.compactMap { value -> UInt64? in
            guard value.hasPrefix(evidencePrefix) else { return nil }
            return UInt64(value.dropFirst(evidencePrefix.count))
        }.first
    }

    static func matchingRecord(
        for application: InstalledApplication,
        in records: [String: AppStoreOutdatedInfo]
    ) -> AppStoreOutdatedInfo? {
        guard let record = records[application.bundleIdentifier],
              record.productID != nil,
              ApplicationVersion.compare(
                record.currentVersion,
                application.installedVersion.marketing
              ) == .orderedSame else {
            return nil
        }
        let target = ApplicationVersion(marketing: record.latestVersion)
        guard application.installedVersion < target else { return nil }
        if let bundleURL = record.bundleURL,
           !sameApplication(bundleURL, application.bundleURL) {
            return nil
        }
        return record
    }

    static func isEligible(_ application: InstalledApplication) -> Bool {
        guard application.updateProvider == .macAppStore,
              application.updateCapability == .automatic,
              application.canAutomaticallyUpdate,
              !application.isReadOnly,
              application.identity.isCompleteForAutomaticUpdates,
              application.sourceEvidence.contains("verified-app-store-receipt"),
              application.sourceEvidence.contains("valid-code-signature"),
              application.sourceEvidence.contains("signed-bundle-identity"),
              application.sourceEvidence.contains("mas-executable-trusted"),
              let recordedID = recordedProductIdentifier(in: application.sourceEvidence),
              recordedID == productIdentifier(from: application.appStoreProductURL),
              let target = application.availableVersion,
              application.installedVersion < target else {
            return false
        }
        switch application.updateStatus {
        case .updateAvailable, .automaticallyUpdatable, .queued, .failed:
            return true
        default:
            return false
        }
    }

    static func makeRecipe(
        application: InstalledApplication,
        executableURL: URL,
        environment: [String: String]
    ) -> ApplicationUpdateExecutionRecipe? {
        guard isEligible(application),
              let productID = productIdentifier(from: application.appStoreProductURL),
              productID == recordedProductIdentifier(in: application.sourceEvidence) else {
            return nil
        }
        return ApplicationUpdateExecutionRecipe(
            applicationID: application.id,
            displayName: application.displayName,
            currentVersion: application.installedVersion,
            targetVersion: application.availableVersion,
            sourceProvider: .macAppStore,
            executableURL: executableURL,
            arguments: ["upgrade", String(productID)],
            workingDirectory: nil,
            environmentAllowlist: environmentAllowlist(
                executableURL: executableURL,
                environment: environment
            ),
            requiresAdministrator: false,
            applicationsToQuit: application.isRunning ? [application.bundleIdentifier] : [],
            downloadURL: nil,
            expectedBundleIdentifier: application.bundleIdentifier,
            expectedTeamIdentifier: application.signingTeamIdentifier,
            expectedVersion: application.availableVersion,
            checksumSHA256: nil,
            verificationSteps: [
                .trustedExecutable,
                .codeSignature,
                .bundleIdentifier,
                .teamIdentifier,
                .installedVersion,
            ],
            rollbackPlan: .unavailable(
                reason: L10n.text(
                    "App Store 不提供可验证的自动回滚；失败会保留真实错误并继续其他项目。",
                    "The App Store does not expose a verifiable automatic rollback; failures are reported and remaining items continue."
                )
            )
        )
    }

    static func isValid(
        _ recipe: ApplicationUpdateExecutionRecipe,
        for preparedUpdate: PreparedApplicationUpdate
    ) -> Bool {
        guard recipe.applicationID == preparedUpdate.applicationID,
              recipe.sourceProvider == .macAppStore,
              recipe.currentVersion == preparedUpdate.originalVersion,
              recipe.targetVersion == preparedUpdate.targetVersion,
              recipe.expectedBundleIdentifier == preparedUpdate.originalIdentity.bundleIdentifier,
              recipe.expectedTeamIdentifier == preparedUpdate.originalIdentity.signingTeamIdentifier,
              recipe.arguments.count == 2,
              recipe.arguments[0] == "upgrade",
              let productID = preparedUpdate.providerPayload["product-id"],
              recipe.arguments[1] == productID,
              let numericProductID = UInt64(productID),
              numericProductID > 0,
              recipe.verificationSteps.contains(.trustedExecutable),
              recipe.verificationSteps.contains(.installedVersion),
              recipe.environmentAllowlist == environmentAllowlist(
                executableURL: recipe.executableURL,
                environment: recipe.environmentAllowlist
              ) else {
            return false
        }
        return true
    }

    private static func environmentAllowlist(
        executableURL: URL,
        environment: [String: String]
    ) -> [String: String] {
        var result: [String: String] = [
            "HOME": environment["HOME"]?.trimmed.nonEmpty
                ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": environment["TMPDIR"]?.trimmed.nonEmpty
                ?? FileManager.default.temporaryDirectory.path,
            "PATH": [
                executableURL.deletingLastPathComponent().path,
                "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            ].joined(separator: ":"),
        ]
        for key in ["USER", "LOGNAME", "LANG", "LC_ALL"] {
            if let value = environment[key]?.trimmed.nonEmpty { result[key] = value }
        }
        return result
    }

    private static func sameApplication(_ lhs: URL, _ rhs: URL) -> Bool {
        if ApplicationPathNormalizer.comparisonKey(for: lhs)
            == ApplicationPathNormalizer.comparisonKey(for: rhs) {
            return true
        }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
        guard let left = try? lhs.resourceValues(forKeys: keys),
              let right = try? rhs.resourceValues(forKeys: keys),
              let leftFile = left.fileResourceIdentifier,
              let rightFile = right.fileResourceIdentifier,
              let leftVolume = left.volumeIdentifier,
              let rightVolume = right.volumeIdentifier else {
            return false
        }
        return String(describing: leftFile) == String(describing: rightFile)
            && String(describing: leftVolume) == String(describing: rightVolume)
    }
}

final class MacAppStoreProvider: ApplicationUpdateProvider, @unchecked Sendable {
    let identifier = ApplicationUpdateProviderIdentifier.macAppStore
    private let receiptVerifier: any MacAppStoreReceiptVerifying
    private let catalogResolver: any AppStoreCatalogResolving
    private let storefront: String
    private let masExecutableProvider: @Sendable () -> URL?
    private let outdatedProvider: @Sendable () -> [String: AppStoreOutdatedInfo]
    private let environmentProvider: @Sendable () -> [String: String]
    private let commandCapture: @Sendable (
        URL,
        [String],
        [String: String],
        MacAppStoreCommandCancellation
    ) throws -> String
    private let stateLock = NSLock()
    private var activeUpdates = [String: MacAppStoreCommandCancellation]()
    private var cachedOutdated: (date: Date, records: [String: AppStoreOutdatedInfo])?

    init(
        receiptVerifier: any MacAppStoreReceiptVerifying = MacAppStoreReceiptVerifier(),
        catalogResolver: any AppStoreCatalogResolving = AppStoreCatalogResolver(),
        storefront: String = AppStoreCatalogResolver.currentStorefront,
        masExecutableProvider: @escaping @Sendable () -> URL? = {
            MacAppStoreExecutableLocator.locate()
        },
        outdatedProvider: @escaping @Sendable () -> [String: AppStoreOutdatedInfo] = {
            AppUpdateService.appStoreOutdatedByBundleIdentifier()
        },
        environmentProvider: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        },
        commandCapture: @escaping @Sendable (
            URL,
            [String],
            [String: String],
            MacAppStoreCommandCancellation
        ) throws -> String = { executableURL, arguments, environment, cancellation in
            try Shell.captureCancellable(
                executableURL.path,
                arguments,
                environment: environment,
                timeout: 30 * 60,
                outputByteLimit: 2 * 1_024 * 1_024,
                cancellationCheck: { cancellation.isCancelled }
            )
        }
    ) {
        self.receiptVerifier = receiptVerifier
        self.catalogResolver = catalogResolver
        self.storefront = AppStoreCatalogResolver.normalizedStorefront(storefront)
        self.masExecutableProvider = masExecutableProvider
        self.outdatedProvider = outdatedProvider
        self.environmentProvider = environmentProvider
        self.commandCapture = commandCapture
    }

    func canHandle(_ application: InstalledApplication) async -> Bool {
        await hasVerifiedAppStoreEvidence(application)
    }

    func inspect(_ application: InstalledApplication) async throws -> ApplicationUpdateSourceInfo {
        guard await hasVerifiedAppStoreEvidence(application) else {
            throw ApplicationScanningError.providerUnsupported(identifier.rawValue)
        }
        let record = await matchingOutdatedRecord(for: application)
        var evidence = [
            "app-store-receipt",
            "verified-app-store-receipt",
            "valid-code-signature",
            "signed-bundle-identity",
        ]
        if let productID = record?.productID {
            evidence.append("mas-outdated")
            evidence.append("\(MacAppStoreAutomaticUpdateSupport.evidencePrefix)\(productID)")
        }
        return ApplicationUpdateSourceInfo(
            providerIdentifier: identifier,
            evidence: evidence,
            requiresUserInteraction: true,
            canAutomaticallyUpdate: false
        )
    }

    func checkForUpdate(_ application: InstalledApplication) async throws -> ApplicationUpdateCheckResult {
        switch try await catalogResolver.resolve(
            bundleIdentifier: application.bundleIdentifier,
            storefront: storefront
        ) {
        case let .matched(entry):
            let updateAvailable = application.installedVersion < entry.version
            return ApplicationUpdateCheckResult(
                status: updateAvailable ? .updateAvailable : .upToDate,
                availableVersion: entry.version,
                releaseDate: entry.releaseDate,
                releaseNotes: entry.releaseNotes,
                downloadSize: entry.downloadSize,
                warning: updateAvailable
                    ? L10n.text("请在 App Store 中确认更新。", "Confirm the update in the App Store.")
                    : nil,
                appStoreProductURL: entry.productURL
            )
        case .notFound:
            return ApplicationUpdateCheckResult(
                status: .appStoreManaged,
                availableVersion: nil,
                releaseDate: nil,
                releaseNotes: nil,
                downloadSize: nil,
                warning: L10n.text(
                    "Apple 目录中未找到完全匹配的 Bundle Identifier；请在 App Store 中检查。",
                    "No exact bundle identifier match was found in Apple's catalog; check in the App Store."
                )
            )
        case .ambiguous:
            return ApplicationUpdateCheckResult(
                status: .appStoreManaged,
                availableVersion: nil,
                releaseDate: nil,
                releaseNotes: nil,
                downloadSize: nil,
                warning: L10n.text(
                    "Apple 目录返回多个同 Bundle Identifier 结果；未自动选择。",
                    "Apple's catalog returned multiple results for the same bundle identifier; none was selected automatically."
                )
            )
        }
    }

    func prepareUpdate(_ application: InstalledApplication) async throws -> PreparedApplicationUpdate {
        throw ApplicationScanningError.providerUnsupported("mac-app-store-system-confirmation-required")
    }

    func install(
        _ preparedUpdate: PreparedApplicationUpdate,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        throw ApplicationScanningError.providerUnsupported("mac-app-store-system-confirmation-required")
    }

    func cancelUpdate(for application: InstalledApplication) async {
        stateLock.withLock { activeUpdates[application.id] }?.cancel()
    }

    private func hasVerifiedAppStoreEvidence(_ application: InstalledApplication) async -> Bool {
        guard !SystemApplicationPolicy.isSystemManaged(application),
              application.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              application.bundleIdentifier.trimmed.nonEmpty != nil,
              application.codeSigningIdentifier == application.bundleIdentifier
        else {
            return false
        }
        let hasVerifiedReceipt = await receiptVerifier.verifyReceipt(at: application.bundleURL)
        return hasVerifiedReceipt
            && application.sourceEvidence.contains("valid-code-signature")
            && application.sourceEvidence.contains("signed-bundle-identity")
            && application.identity.isCompleteForAutomaticUpdates
            && application.codeSigningIdentifier?.trimmed.nonEmpty != nil
    }

    private func matchingOutdatedRecord(
        for application: InstalledApplication,
        forceRefresh: Bool = false
    ) async -> AppStoreOutdatedInfo? {
        let records: [String: AppStoreOutdatedInfo]
        if !forceRefresh,
           let cached = stateLock.withLock({ cachedOutdated }),
           Date().timeIntervalSince(cached.date) < 15 {
            records = cached.records
        } else {
            let provider = outdatedProvider
            records = await Task.detached(priority: .utility) { provider() }.value
            stateLock.withLock { cachedOutdated = (Date(), records) }
        }
        return MacAppStoreAutomaticUpdateSupport.matchingRecord(
            for: application,
            in: records
        )
    }
}

enum MacAppStoreReceiptPayloadParser {
    static func receipt(payload: Data, matchesBundleIdentifier bundleIdentifier: String) -> Bool {
        guard let receiptBundleIdentifier = self.bundleIdentifier(from: payload) else {
            return false
        }
        return receiptBundleIdentifier == bundleIdentifier
    }

    static func bundleIdentifier(from payload: Data) -> String? {
        var rootReader = DERReader(data: payload)
        guard let root = rootReader.readElement(), root.tag == 0x31, rootReader.isAtEnd else {
            return nil
        }
        var attributes = DERReader(data: root.content)
        while let attribute = attributes.readElement() {
            guard attribute.tag == 0x30 else { continue }
            var fields = DERReader(data: attribute.content)
            guard let typeElement = fields.readElement(), typeElement.tag == 0x02,
                  DERReader.integer(from: typeElement.content) == 2,
                  let versionElement = fields.readElement(), versionElement.tag == 0x02,
                  DERReader.integer(from: versionElement.content) != nil,
                  let valueElement = fields.readElement(), valueElement.tag == 0x04,
                  fields.isAtEnd else {
                continue
            }
            var valueReader = DERReader(data: valueElement.content)
            guard let value = valueReader.readElement(),
                  valueReader.isAtEnd,
                  value.tag == 0x0C || value.tag == 0x16 else { continue }
            return String(data: value.content, encoding: .utf8)?.trimmed.nonEmpty
        }
        return nil
    }

    private struct DERReader {
        let data: Data
        var offset = 0

        var isAtEnd: Bool {
            offset == data.count
        }

        mutating func readElement() -> (tag: UInt8, content: Data)? {
            guard offset < data.count else { return nil }
            let tag = data[offset]
            offset += 1
            guard offset < data.count else { return nil }
            let firstLength = data[offset]
            offset += 1
            let length: Int
            if firstLength & 0x80 == 0 {
                length = Int(firstLength)
            } else {
                let lengthByteCount = Int(firstLength & 0x7F)
                guard lengthByteCount > 0, lengthByteCount <= 4,
                      offset + lengthByteCount <= data.count else { return nil }
                var resolvedLength = 0
                for _ in 0..<lengthByteCount {
                    guard resolvedLength <= (Int.max >> 8) else { return nil }
                    resolvedLength = (resolvedLength << 8) | Int(data[offset])
                    offset += 1
                }
                length = resolvedLength
            }
            guard length >= 0, offset <= data.count, length <= data.count - offset else {
                return nil
            }
            let content = data.subdata(in: offset..<(offset + length))
            offset += length
            return (tag, content)
        }

        static func integer(from data: Data) -> Int? {
            guard !data.isEmpty, data.count <= MemoryLayout<Int>.size,
                  data.first.map({ $0 & 0x80 == 0 }) == true else { return nil }
            return data.reduce(0) { partial, byte in
                (partial << 8) | Int(byte)
            }
        }
    }
}
