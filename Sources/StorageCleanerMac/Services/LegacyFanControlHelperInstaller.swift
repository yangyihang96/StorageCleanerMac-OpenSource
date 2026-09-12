import Darwin
import FanControlShared
import Foundation

struct LegacyFanControlArtifactMetadata: Equatable, Sendable {
    let isRegularFile: Bool
    let isSymbolicLink: Bool
    let ownerUserID: uid_t
    let posixPermissions: UInt16

    var isTrusted: Bool {
        isRegularFile
            && !isSymbolicLink
            && ownerUserID == 0
            && posixPermissions & 0o022 == 0
            && posixPermissions & 0o7000 == 0
    }
}

struct LegacyFanControlSigningIdentity: Equatable, Sendable {
    let identifier: String?
    let teamIdentifier: String?
    let certificateCommonNames: [String]
}

enum LegacyFanControlHelperInstallerError: LocalizedError {
    case installedArtifactsMismatch

    var errorDescription: String? {
        switch self {
        case .installedArtifactsMismatch:
            L10n.text(
                "检测到旧版系统控制辅助程序。为避免再次弹出管理员密码或执行旧式安装脚本，高级硬件控制保持关闭；请先手动移除旧版辅助程序。",
                "A legacy system-control helper was detected. Advanced hardware control remains disabled to avoid another administrator-password prompt or legacy install script; remove the legacy helper manually first."
            )
        }
    }
}

enum LegacyFanControlHelperInstaller {
    static let helperLabel = StorageCleanerBuildIdentity.helperLabel
    static let bundledHelperName = "StorageCleanerFanControlHelper"
    static let installedHelperPath =
        "/Library/PrivilegedHelperTools/\(helperLabel)"
    static let installedPlistPath =
        "/Library/LaunchDaemons/\(helperLabel).plist"

    static func installedArtifactsPresent(
        fileManager: FileManager = .default
    ) -> Bool {
        // Treat a partial legacy installation as present too. Registering the
        // new daemon over a stale fixed-path plist would not be fail-closed.
        _ = fileManager
        return artifactMetadata(at: installedHelperPath) != nil
            || artifactMetadata(at: installedPlistPath) != nil
    }

    static func installedArtifactsCurrent(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        metadataProvider: (String) -> LegacyFanControlArtifactMetadata? = artifactMetadata,
        signingIdentityProvider: (URL) -> LegacyFanControlSigningIdentity? = signingIdentity
    ) -> Bool {
        guard installedArtifactsPresent(fileManager: fileManager),
              let helperURL = bundle.url(
                forResource: bundledHelperName,
                withExtension: nil
              ),
              metadataProvider(installedHelperPath)?.isTrusted == true,
              metadataProvider(installedPlistPath)?.isTrusted == true else {
            return false
        }
        guard fileManager.contentsEqual(
            atPath: helperURL.path,
            andPath: installedHelperPath
        ) else {
            return false
        }

        guard let appIdentity = signingIdentityProvider(bundle.bundleURL),
              let bundledIdentity = signingIdentityProvider(helperURL),
              let installedIdentity = signingIdentityProvider(
                URL(fileURLWithPath: installedHelperPath)
              ),
              signingContractIsTrusted(
                app: appIdentity,
                bundledHelper: bundledIdentity,
                installedHelper: installedIdentity
              ) else {
            return false
        }

        // The legacy plist is deliberately not part of new app bundles. Keep
        // its fixed root-owned contract here so an old installation can still
        // be trusted without making the legacy path the normal registration
        // route.
        guard let data = fileManager.contents(atPath: installedPlistPath),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let plist = propertyList as? [String: Any],
              plist.count == 3,
              plist["Label"] as? String == helperLabel,
              plist["ProgramArguments"] as? [String] == [installedHelperPath],
              let services = plist["MachServices"] as? [String: Bool],
              services.count == 1,
              services[helperLabel] == true else {
            return false
        }

        return true
    }

    static func installedArtifactsSafeForRemoval(
        metadataProvider: (String) -> LegacyFanControlArtifactMetadata? = artifactMetadata
    ) -> Bool {
        let existing = [installedHelperPath, installedPlistPath]
            .compactMap(metadataProvider)
        return !existing.isEmpty && existing.allSatisfy(\.isTrusted)
    }

    static func artifactMetadata(
        at path: String
    ) -> LegacyFanControlArtifactMetadata? {
        var value = stat()
        guard path.withCString({ Darwin.lstat($0, &value) }) == 0 else {
            return nil
        }
        let fileType = value.st_mode & S_IFMT
        return LegacyFanControlArtifactMetadata(
            isRegularFile: fileType == S_IFREG,
            isSymbolicLink: fileType == S_IFLNK,
            ownerUserID: value.st_uid,
            posixPermissions: UInt16(value.st_mode & 0o7777)
        )
    }

    static func signingContractIsTrusted(
        app: LegacyFanControlSigningIdentity,
        bundledHelper: LegacyFanControlSigningIdentity,
        installedHelper: LegacyFanControlSigningIdentity
    ) -> Bool {
        guard bundledSigningContractIsTrusted(
            app: app,
            bundledHelper: bundledHelper
        ),
              installedHelper.identifier == helperLabel,
              let teamIdentifier = app.teamIdentifier,
              installedHelper.teamIdentifier == teamIdentifier,
              bundledHelper.certificateCommonNames
                == installedHelper.certificateCommonNames else {
            return false
        }
        return app.certificateCommonNames.contains {
            $0.hasPrefix("Developer ID Application:")
        }
    }

    static func bundledSigningContractIsTrusted(
        app: LegacyFanControlSigningIdentity,
        bundledHelper: LegacyFanControlSigningIdentity
    ) -> Bool {
        app.identifier == StorageCleanerBuildIdentity.appBundleIdentifier
            && bundledHelper.identifier == helperLabel
            && app.teamIdentifier?.isEmpty == false
            && bundledHelper.teamIdentifier == app.teamIdentifier
            && !app.certificateCommonNames.isEmpty
            && app.certificateCommonNames == bundledHelper.certificateCommonNames
    }

    static func signingIdentity(
        at url: URL
    ) -> LegacyFanControlSigningIdentity? {
        guard let result = try? CodeSignatureVerifier().verifyCode(at: url),
              result.isValid else {
            return nil
        }
        return LegacyFanControlSigningIdentity(
            identifier: result.codeSigningIdentifier,
            teamIdentifier: result.teamIdentifier,
            certificateCommonNames: result.certificateCommonNames
        )
    }

}
