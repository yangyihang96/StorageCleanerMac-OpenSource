import Foundation
import Security

struct SecurityFrameworkApplicationCodeSignatureInspector: ApplicationCodeSignatureInspecting {
    func inspectSignature(at applicationURL: URL) async -> ApplicationCodeSignatureMetadata {
        await Task.detached(priority: .utility) {
            var staticCode: SecStaticCode?
            let creationStatus = SecStaticCodeCreateWithPath(
                applicationURL as CFURL,
                SecCSFlags(rawValue: 0),
                &staticCode
            )
            guard creationStatus == errSecSuccess, let staticCode else {
                return ApplicationCodeSignatureMetadata(
                    signingTeamIdentifier: nil,
                    codeSigningIdentifier: nil,
                    isValid: false
                )
            }

            let validationFlags = SecCSFlags(
                rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate
            )
            let validationStatus = SecStaticCodeCheckValidity(staticCode, validationFlags, nil)
            var signingInformation: CFDictionary?
            let informationStatus = SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &signingInformation
            )
            let dictionary = signingInformation as? [String: Any]
            let teamIdentifier = dictionary?[kSecCodeInfoTeamIdentifier as String] as? String
            let codeIdentifier = dictionary?[kSecCodeInfoIdentifier as String] as? String
            let entitlements = dictionary?[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
            let hasAppSandboxEntitlement = (entitlements?["com.apple.security.app-sandbox"] as? Bool) == true
            return ApplicationCodeSignatureMetadata(
                signingTeamIdentifier: teamIdentifier?.trimmed.nonEmpty,
                codeSigningIdentifier: codeIdentifier?.trimmed.nonEmpty,
                isValid: validationStatus == errSecSuccess && informationStatus == errSecSuccess,
                hasAppSandboxEntitlement: hasAppSandboxEntitlement
            )
        }.value
    }
}

struct ApplicationMetadataReader: Sendable {
    private let signatureInspector: any ApplicationCodeSignatureInspecting

    init(
        signatureInspector: any ApplicationCodeSignatureInspecting = SecurityFrameworkApplicationCodeSignatureInspector()
    ) {
        self.signatureInspector = signatureInspector
    }

    func read(
        applicationURL: URL,
        runningState: ApplicationRunningStateSnapshot,
        scanDate: Date = Date()
    ) async -> InstalledApplication? {
        let url = applicationURL.standardizedFileURL
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let info = Self.infoDictionary(at: url) else {
            return nil
        }

        // Bundle caches metadata by URL. App updates replace a bundle at the
        // same path, so read Info.plist from disk to avoid reporting the old
        // version after a verified replacement.
        let displayName = Self.firstNonEmptyString(
            info["CFBundleDisplayName"],
            info[kCFBundleNameKey as String]
        ) ?? url.deletingPathExtension().lastPathComponent
        let bundleIdentifier = Self.string(info[kCFBundleIdentifierKey as String]) ?? ""
        let marketingVersion = Self.string(info["CFBundleShortVersionString"]) ?? ""
        let buildNumber = Self.string(info[kCFBundleVersionKey as String]) ?? ""
        let executableURL = Self.executableURL(info: info, bundleURL: url)
        let minimumSystemVersion = Self.minimumSystemVersion(info: info)
        let values = try? url.resourceValues(forKeys: [
            .volumeIsInternalKey,
            .volumeIsReadOnlyKey,
            .contentModificationDateKey,
        ])
        let isExternal = values?.volumeIsInternal == false
        let isReadOnly = values?.volumeIsReadOnly == true
        let isSystem = SystemApplicationPolicy.isSystemManaged(url: url)
        let installationSource = Self.installationSource(
            for: url,
            isSystem: isSystem,
            isExternal: isExternal
        )
        let signature = await signatureInspector.inspectSignature(at: url)
        let architectures = executableURL.map(MachOArchitectureReader.architectures(at:)) ?? []
        let feedURL = Self.string(info["SUFeedURL"])
        let sparkleConfiguration = Self.sparkleConfiguration(info: info, at: url)
        var evidence = [String]()
        if Self.hasAppStoreReceipt(at: url) {
            evidence.append("app-store-receipt")
            if await MacAppStoreReceiptVerifier().verifyReceipt(at: url) {
                evidence.append("verified-app-store-receipt")
            }
        }
        if sparkleConfiguration?.frameworkRelativePath != nil {
            evidence.append("sparkle-framework")
        }
        if feedURL?.trimmed.isEmpty == false {
            evidence.append("sparkle-feed")
        }
        if signature.isValid {
            evidence.append("valid-code-signature")
        }
        if signature.isValid,
           signature.signingTeamIdentifier?.trimmed.nonEmpty != nil,
           signature.codeSigningIdentifier?.trimmed.nonEmpty != nil,
           !bundleIdentifier.isEmpty {
            evidence.append("signed-bundle-identity")
        }
        if signature.hasAppSandboxEntitlement {
            evidence.append("app-sandbox-entitlement")
        }
        if sparkleConfiguration?.isEligibleForReadOnlyProbe == true {
            evidence.append("sparkle-readonly-probe")
        }

        let path = ApplicationPathNormalizer.normalizedPath(for: url)
        let applicationID = bundleIdentifier.isEmpty ? path : "\(bundleIdentifier)|\(path)"
        return InstalledApplication(
            id: applicationID,
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            bundleURL: url,
            executableURL: executableURL,
            installedVersion: ApplicationVersion(marketing: marketingVersion, build: buildNumber),
            buildNumber: buildNumber,
            signingTeamIdentifier: signature.signingTeamIdentifier,
            codeSigningIdentifier: signature.codeSigningIdentifier ?? bundleIdentifier.nonEmpty,
            installationSource: installationSource,
            updateProvider: isSystem ? .systemManaged : .manual,
            architectures: architectures,
            minimumSystemVersion: minimumSystemVersion,
            isSystemApplication: isSystem,
            isRunning: runningState.contains(bundleIdentifier: bundleIdentifier, bundleURL: url),
            isOnExternalVolume: isExternal,
            isReadOnly: isReadOnly,
            lastScanDate: scanDate,
            updateStatus: isSystem ? .systemManaged : .discovered,
            requiresUserInteraction: !isSystem,
            requiresApplicationQuit: false,
            requiresAdministratorAuthorization: false,
            canAutomaticallyUpdate: false,
            sourceDisplayName: Self.sourceDisplayName(for: installationSource),
            sourceEvidence: evidence,
            sparkleConfiguration: sparkleConfiguration,
            feedURL: feedURL,
            reportedCurrentVersion: marketingVersion.nonEmpty ?? buildNumber.nonEmpty,
            modifiedAt: values?.contentModificationDate
        )
    }

    private static func infoDictionary(at applicationURL: URL) -> [String: Any]? {
        let infoURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return value as? [String: Any]
    }

    static func hasAppStoreReceipt(at applicationURL: URL) -> Bool {
        let receiptURL = applicationURL
            .appendingPathComponent("Contents/_MASReceipt/receipt", isDirectory: false)
        guard let values = try? receiptURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let size = values.fileSize,
            (32...(16 * 1_024 * 1_024)).contains(size)
        else {
            return false
        }
        return true
    }

    static func hasSparkleFramework(at applicationURL: URL) -> Bool {
        safeSparkleFrameworkRelativePath(at: applicationURL) != nil
    }

    static func sparkleConfiguration(at applicationURL: URL) -> SparkleConfiguration? {
        guard let bundle = Bundle(url: applicationURL.standardizedFileURL) else { return nil }
        return sparkleConfiguration(info: bundle.infoDictionary ?? [:], at: applicationURL)
    }

    private static func sparkleConfiguration(
        info: [String: Any],
        at applicationURL: URL
    ) -> SparkleConfiguration? {
        let feedURL = string(info["SUFeedURL"]).flatMap(URL.init(string:))
        let publicEDKey = string(info["SUPublicEDKey"])
        let requiresSignedFeed = bool(info["SURequireSignedFeed"]) ?? false
        let frameworkRelativePath = safeSparkleFrameworkRelativePath(at: applicationURL)
        guard feedURL != nil
                || publicEDKey != nil
                || info["SURequireSignedFeed"] != nil
                || frameworkRelativePath != nil else {
            return nil
        }
        return SparkleConfiguration(
            feedURL: feedURL,
            publicEDKey: publicEDKey,
            requiresSignedFeed: requiresSignedFeed,
            frameworkRelativePath: frameworkRelativePath
        )
    }

    private static func safeSparkleFrameworkRelativePath(at applicationURL: URL) -> String? {
        let bundleRoot = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        let contents = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        let candidates = [
            ("Contents/Frameworks/Sparkle.framework", contents.appendingPathComponent("Frameworks/Sparkle.framework", isDirectory: true)),
            ("Contents/PrivateFrameworks/Sparkle.framework", contents.appendingPathComponent("PrivateFrameworks/Sparkle.framework", isDirectory: true)),
        ]
        for (relativePath, candidate) in candidates {
            guard let values = try? candidate.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]),
                values.isDirectory == true,
                values.isSymbolicLink != true else {
                continue
            }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(bundleRoot.path + "/") else { continue }
            return relativePath
        }
        return nil
    }

    private static func executableURL(info: [String: Any], bundleURL: URL) -> URL? {
        guard let executable = string(info[kCFBundleExecutableKey as String]) else { return nil }
        return bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executable, isDirectory: false)
    }

    private static func minimumSystemVersion(info: [String: Any]) -> String? {
        if let version = string(info["LSMinimumSystemVersion"]) {
            return version
        }
        guard let byArchitecture = info["LSMinimumSystemVersionByArchitecture"] as? [String: Any]
        else {
            return nil
        }
        return byArchitecture.values
            .compactMap(string)
            .max { ApplicationVersion.compare($0, $1) == .orderedAscending }
    }

    private static func installationSource(
        for url: URL,
        isSystem: Bool,
        isExternal: Bool
    ) -> ApplicationInstallationSource {
        if isSystem { return .system }
        if isExternal { return .externalVolume }
        let path = ApplicationPathNormalizer.normalizedPath(for: url)
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.path
        if path == userApplications || path.hasPrefix(userApplications + "/") {
            return .userDirectory
        }
        if path == "/Applications" || path.hasPrefix("/Applications/") {
            return .standardDirectory
        }
        return .unknown
    }

    private static func sourceDisplayName(
        for source: ApplicationInstallationSource
    ) -> String {
        switch source {
        case .system:
            L10n.text("macOS", "macOS")
        case .appStore:
            "App Store"
        case .homebrewCask, .homebrewFormula:
            "Homebrew"
        case .sparkle:
            "Sparkle"
        case .vendor:
            L10n.text("厂商更新器", "Vendor Updater")
        case .officialWebsite:
            L10n.text("官方网站", "Official Website")
        case .userDirectory:
            L10n.text("用户应用程序", "User Applications")
        case .standardDirectory:
            L10n.text("应用程序", "Applications")
        case .externalVolume:
            L10n.text("外置磁盘", "External Volume")
        case .unknown:
            L10n.text("来源待确认", "Source Unconfirmed")
        }
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            value.trimmed.nonEmpty
        case let value as NSNumber:
            value.stringValue.trimmed.nonEmpty
        default:
            nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            value
        case let value as NSNumber:
            value.boolValue
        default:
            nil
        }
    }

    private static func firstNonEmptyString(_ values: Any?...) -> String? {
        values.compactMap(string).first
    }
}

enum MachOArchitectureReader {
    static func architectures(at executableURL: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: executableURL) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), data.count >= 8 else { return [] }

        let magic = uint32(data, offset: 0, byteOrder: .big)
        switch magic {
        case 0xCAFE_BABE:
            return fatArchitectures(data, byteOrder: .big, is64Bit: false)
        case 0xBEBA_FECA:
            return fatArchitectures(data, byteOrder: .little, is64Bit: false)
        case 0xCAFE_BABF:
            return fatArchitectures(data, byteOrder: .big, is64Bit: true)
        case 0xBFBA_FECA:
            return fatArchitectures(data, byteOrder: .little, is64Bit: true)
        case 0xFEED_FACE, 0xFEED_FACF:
            return architectureName(for: uint32(data, offset: 4, byteOrder: .big)).map { [$0] } ?? []
        case 0xCEFA_EDFE, 0xCFFA_EDFE:
            return architectureName(for: uint32(data, offset: 4, byteOrder: .little)).map { [$0] } ?? []
        default:
            return []
        }
    }

    private enum ByteOrder {
        case big
        case little
    }

    private static func fatArchitectures(
        _ data: Data,
        byteOrder: ByteOrder,
        is64Bit: Bool
    ) -> [String] {
        let count = min(Int(uint32(data, offset: 4, byteOrder: byteOrder)), 64)
        let recordSize = is64Bit ? 32 : 20
        var names = Set<String>()
        for index in 0..<count {
            let offset = 8 + (index * recordSize)
            guard data.count >= offset + 4 else { break }
            if let name = architectureName(for: uint32(data, offset: offset, byteOrder: byteOrder)) {
                names.insert(name)
            }
        }
        return names.sorted()
    }

    private static func architectureName(for cpuType: UInt32) -> String? {
        switch cpuType {
        case 0x0100_000C:
            "arm64"
        case 0x0200_000C:
            "arm64_32"
        case 0x0000_000C:
            "arm"
        case 0x0100_0007:
            "x86_64"
        case 0x0000_0007:
            "i386"
        case 0x0100_0012:
            "ppc64"
        case 0x0000_0012:
            "ppc"
        default:
            nil
        }
    }

    private static func uint32(_ data: Data, offset: Int, byteOrder: ByteOrder) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        let bytes = [UInt8](data[offset..<(offset + 4)])
        switch byteOrder {
        case .big:
            return (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
        case .little:
            return (UInt32(bytes[3]) << 24)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[1]) << 8)
                | UInt32(bytes[0])
        }
    }
}
