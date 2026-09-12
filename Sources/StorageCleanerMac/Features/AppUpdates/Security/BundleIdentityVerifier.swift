import Foundation

enum BundleIdentityValidationIssue: Error, Equatable, LocalizedError, Sendable {
    case sourceNotTrustedForAutomaticInstall
    case notAnApplicationBundle
    case missingInfoPlist
    case missingBundleIdentifier
    case bundleIdentifierChanged(expected: String, actual: String)
    case invalidCodeSignature
    case missingTeamIdentifier
    case teamIdentifierChanged(expected: String, actual: String?)
    case codeSigningIdentifierChanged(expected: String, actual: String?)
    case designatedRequirementChanged
    case versionMissing
    case versionNotNewer(installed: String, candidate: String)
    case minimumSystemVersionNotMet(String)
    case executableMissing
    case incompatibleArchitecture([String])
    case escapingSymbolicLink(String)

    var errorDescription: String? {
        switch self {
        case .sourceNotTrustedForAutomaticInstall:
            return L10n.text("更新来源未达到自动安装信任级别。", "The update source is not trusted for automatic installation.")
        case .notAnApplicationBundle:
            return L10n.text("下载内容不是 macOS 应用包。", "The downloaded item is not a macOS application bundle.")
        case .missingInfoPlist:
            return L10n.text("应用包缺少可读的 Info.plist。", "The application bundle has no readable Info.plist.")
        case .missingBundleIdentifier:
            return L10n.text("应用包缺少 Bundle Identifier。", "The application bundle has no bundle identifier.")
        case let .bundleIdentifierChanged(expected, actual):
            return OfficialUpdateLocalization.format("Bundle Identifier 不一致：预期 %@，实际 %@。", "Bundle identifier mismatch: expected %@, got %@.", expected, actual)
        case .invalidCodeSignature:
            return L10n.text("新应用的代码签名无效。", "The new application's code signature is invalid.")
        case .missingTeamIdentifier:
            return L10n.text("无法确认原应用的签名开发者。", "The installed application's signing developer cannot be established.")
        case let .teamIdentifierChanged(expected, actual):
            return OfficialUpdateLocalization.format("签名开发者已改变：预期 %@，实际 %@。", "Signing team changed: expected %@, got %@.", expected, actual ?? "-")
        case let .codeSigningIdentifierChanged(expected, actual):
            return OfficialUpdateLocalization.format("代码签名标识不一致：预期 %@，实际 %@。", "Code-signing identifier mismatch: expected %@, got %@.", expected, actual ?? "-")
        case .designatedRequirementChanged:
            return L10n.text("应用的 designated requirement 已改变。", "The application's designated requirement changed.")
        case .versionMissing:
            return L10n.text("新应用未声明版本。", "The new application does not declare a version.")
        case let .versionNotNewer(installed, candidate):
            return OfficialUpdateLocalization.format("候选版本 %@ 不高于已安装版本 %@。", "Candidate version %@ is not newer than installed version %@.", candidate, installed)
        case let .minimumSystemVersionNotMet(version):
            return OfficialUpdateLocalization.format("新版本需要 macOS %@ 或更高版本。", "The new version requires macOS %@ or later.", version)
        case .executableMissing:
            return L10n.text("应用包的主可执行文件缺失。", "The application's main executable is missing.")
        case let .incompatibleArchitecture(architectures):
            return OfficialUpdateLocalization.format("新应用不包含当前 CPU 所需架构（%@）。", "The new app does not include a compatible CPU architecture (%@).", architectures.joined(separator: ", "))
        case let .escapingSymbolicLink(path):
            return OfficialUpdateLocalization.format("应用包包含指向包外的符号链接：%@", "The app bundle contains a symlink outside the bundle: %@", path)
        }
    }
}

struct BundleIdentityValidationResult: Sendable {
    let candidateIdentity: ApplicationIdentity
    let candidateVersion: ApplicationVersion
    let architectures: [String]
    let minimumSystemVersion: String?
    let signature: CodeSignatureVerificationResult
}

struct BundleIdentityVerifier: Sendable {
    private let signatureVerification: @Sendable (URL) throws -> CodeSignatureVerificationResult

    init(signatureVerifier: CodeSignatureVerifier = CodeSignatureVerifier()) {
        signatureVerification = { try signatureVerifier.verifyCode(at: $0) }
    }

    init(
        signatureVerification: @escaping @Sendable (URL) throws -> CodeSignatureVerificationResult
    ) {
        self.signatureVerification = signatureVerification
    }

    func verifyReplacement(
        at candidateURL: URL,
        for installedApplication: InstalledApplication,
        source: OfficialUpdateSource
    ) throws -> BundleIdentityValidationResult {
        guard source.trustLevel.permitsAutomaticDownload,
              source.capability.permitsAutomaticInstallation else {
            throw BundleIdentityValidationIssue.sourceNotTrustedForAutomaticInstall
        }
        guard candidateURL.pathExtension.lowercased() == "app",
              (try? candidateURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw BundleIdentityValidationIssue.notAnApplicationBundle
        }

        let root = candidateURL.standardizedFileURL.resolvingSymlinksInPath()
        try validateContainedSymbolicLinks(in: root)
        let info = try readInfoPlist(from: root)
        guard let bundleIdentifier = (info["CFBundleIdentifier"] as? String)?.trimmed.nonEmpty else {
            throw BundleIdentityValidationIssue.missingBundleIdentifier
        }
        let expectedBundleIdentifier = source.expectedBundleIdentifier
        guard bundleIdentifier == expectedBundleIdentifier,
              bundleIdentifier == installedApplication.bundleIdentifier else {
            throw BundleIdentityValidationIssue.bundleIdentifierChanged(
                expected: expectedBundleIdentifier,
                actual: bundleIdentifier
            )
        }

        let signature: CodeSignatureVerificationResult
        do {
            signature = try signatureVerification(root)
        } catch {
            throw BundleIdentityValidationIssue.invalidCodeSignature
        }

        guard let expectedTeam = source.expectedTeamIdentifier?.trimmed.nonEmpty
                ?? installedApplication.signingTeamIdentifier?.trimmed.nonEmpty else {
            throw BundleIdentityValidationIssue.missingTeamIdentifier
        }
        guard signature.teamIdentifier == expectedTeam else {
            throw BundleIdentityValidationIssue.teamIdentifierChanged(
                expected: expectedTeam,
                actual: signature.teamIdentifier
            )
        }

        if let expectedCodeIdentifier = installedApplication.codeSigningIdentifier?.trimmed.nonEmpty,
           signature.codeSigningIdentifier != expectedCodeIdentifier {
            throw BundleIdentityValidationIssue.codeSigningIdentifierChanged(
                expected: expectedCodeIdentifier,
                actual: signature.codeSigningIdentifier
            )
        }
        if let expectedRequirement = source.expectedDesignatedRequirement?.trimmed.nonEmpty,
           signature.designatedRequirement != expectedRequirement {
            throw BundleIdentityValidationIssue.designatedRequirementChanged
        }

        let marketingVersion = (info["CFBundleShortVersionString"] as? String)?.trimmed ?? ""
        let buildVersion = (info["CFBundleVersion"] as? String)?.trimmed ?? ""
        let candidateVersion = ApplicationVersion(marketing: marketingVersion, build: buildVersion)
        guard !candidateVersion.preferred.isEmpty else { throw BundleIdentityValidationIssue.versionMissing }
        guard installedApplication.installedVersion < candidateVersion else {
            throw BundleIdentityValidationIssue.versionNotNewer(
                installed: installedApplication.installedVersion.display,
                candidate: candidateVersion.display
            )
        }

        let minimumSystemVersion = (info["LSMinimumSystemVersion"] as? String)?.trimmed.nonEmpty
        if let minimumSystemVersion,
           ApplicationVersion.compare(Self.currentSystemVersion, minimumSystemVersion) == .orderedAscending {
            throw BundleIdentityValidationIssue.minimumSystemVersionNotMet(minimumSystemVersion)
        }

        guard let executableName = (info["CFBundleExecutable"] as? String)?.trimmed.nonEmpty else {
            throw BundleIdentityValidationIssue.executableMissing
        }
        let executableURL = root.appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw BundleIdentityValidationIssue.executableMissing
        }
        let architectures = try UpdateSecurityMachOArchitectureReader.architectures(at: executableURL)
        guard architectures.contains(Self.currentArchitecture) else {
            throw BundleIdentityValidationIssue.incompatibleArchitecture(architectures)
        }

        return BundleIdentityValidationResult(
            candidateIdentity: ApplicationIdentity(
                bundleIdentifier: bundleIdentifier,
                signingTeamIdentifier: signature.teamIdentifier,
                codeSigningIdentifier: signature.codeSigningIdentifier
            ),
            candidateVersion: candidateVersion,
            architectures: architectures,
            minimumSystemVersion: minimumSystemVersion,
            signature: signature
        )
    }

    private func readInfoPlist(from applicationURL: URL) throws -> [String: Any] {
        let infoURL = applicationURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = value as? [String: Any] else {
            throw BundleIdentityValidationIssue.missingInfoPlist
        }
        return dictionary
    }

    private func validateContainedSymbolicLinks(in root: URL) throws {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return }

        for case let itemURL as URL in enumerator {
            let values = try itemURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true else { continue }
            let destination = itemURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard destination == root.path || destination.hasPrefix(rootPath) else {
                throw BundleIdentityValidationIssue.escapingSymbolicLink(itemURL.path)
            }
        }
    }

    private static var currentSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

enum UpdateSecurityMachOArchitectureReader {
    static func architectures(at url: URL) throws -> [String] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= 8 else { return [] }
        let magic = readUInt32(data, offset: 0, endian: .big)
        switch magic {
        case 0xFEED_FACE, 0xFEED_FACF:
            return [architectureName(readUInt32(data, offset: 4, endian: .big))]
        case 0xCEFA_EDFE, 0xCFFA_EDFE:
            return [architectureName(readUInt32(data, offset: 4, endian: .little))]
        case 0xCAFE_BABE, 0xCAFE_BABF:
            return fatArchitectures(data, endian: .big, is64Bit: magic == 0xCAFE_BABF)
        case 0xBEBA_FECA, 0xBFBA_FECA:
            return fatArchitectures(data, endian: .little, is64Bit: magic == 0xBFBA_FECA)
        default:
            return []
        }
    }

    private enum Endian { case big, little }

    private static func fatArchitectures(_ data: Data, endian: Endian, is64Bit: Bool) -> [String] {
        let count = Int(readUInt32(data, offset: 4, endian: endian))
        guard count > 0, count <= 64 else { return [] }
        let stride = is64Bit ? 32 : 20
        return (0..<count).compactMap { index in
            let offset = 8 + index * stride
            guard data.count >= offset + 4 else { return nil }
            return architectureName(readUInt32(data, offset: offset, endian: endian))
        }
    }

    private static func readUInt32(_ data: Data, offset: Int, endian: Endian) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        let bytes = data[offset..<(offset + 4)]
        switch endian {
        case .big:
            return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        case .little:
            return bytes.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
    }

    private static func architectureName(_ rawCPUType: UInt32) -> String {
        switch rawCPUType {
        case 0x0100_000C: "arm64"
        case 0x0100_0007: "x86_64"
        case 0x0000_000C: "arm"
        case 0x0000_0007: "i386"
        default: "cpu-0x" + String(rawCPUType, radix: 16)
        }
    }
}
