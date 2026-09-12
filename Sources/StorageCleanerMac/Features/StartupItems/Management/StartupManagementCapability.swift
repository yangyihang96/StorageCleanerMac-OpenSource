import Foundation
import Security

extension StartupItemsDomain {
    struct StartupManagementCapability: Hashable, Sendable {
        enum DistributionProfile: String, Codable, Hashable, Sendable {
            case nonSandboxDirect
            case sandboxRestricted
        }

        let distributionProfile: DistributionProfile
        let canManageCurrentUserLaunchAgents: Bool
        let canInspectStandardLaunchdDirectories: Bool
        let hasPrivilegedHelper: Bool

        static let nonSandboxDirect = StartupManagementCapability(
            distributionProfile: .nonSandboxDirect,
            canManageCurrentUserLaunchAgents: true,
            canInspectStandardLaunchdDirectories: true,
            hasPrivilegedHelper: false
        )

        static let sandboxRestricted = StartupManagementCapability(
            distributionProfile: .sandboxRestricted,
            canManageCurrentUserLaunchAgents: false,
            canInspectStandardLaunchdDirectories: false,
            hasPrivilegedHelper: false
        )

        /// Resolves the capability from the running executable's signed
        /// entitlements. Failure to read signing information is treated as a
        /// restricted environment rather than optimistically enabling system
        /// inspection or mutation.
        static func currentApplication() -> StartupManagementCapability {
            guard let executableURL = Bundle.main.executableURL else {
                return resolving(appSandboxEntitlement: nil)
            }
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(
                executableURL as CFURL,
                SecCSFlags(rawValue: 0),
                &code
            ) == errSecSuccess,
                  let code else {
                return resolving(appSandboxEntitlement: nil)
            }
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(
                code,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &information
            ) == errSecSuccess,
                  let dictionary = information as? [String: Any] else {
                return resolving(appSandboxEntitlement: nil)
            }
            let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
            let isSandboxed = (entitlements?["com.apple.security.app-sandbox"] as? Bool) == true
            return resolving(appSandboxEntitlement: isSandboxed)
        }

        static func resolving(appSandboxEntitlement: Bool?) -> StartupManagementCapability {
            guard let appSandboxEntitlement else { return .sandboxRestricted }
            return appSandboxEntitlement ? .sandboxRestricted : .nonSandboxDirect
        }

        var canManageSystemLaunchItems: Bool {
            distributionProfile == .nonSandboxDirect && hasPrivilegedHelper
        }
    }

    enum ManagementDestination: Equatable, Sendable {
        case directlyManageable
        case systemSettingsLoginItems
        case administratorHelperUnavailable
        case managedByOrganization
        case systemProtected
        case readOnly(reason: String)
    }

    struct StartupCapabilityResolver: Sendable {
        let platform: StartupManagementCapability
        let currentUserID: uid_t
        let userLaunchAgentsDirectory: URL

        init(
            platform: StartupManagementCapability,
            currentUserID: uid_t = getuid(),
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        ) {
            self.platform = platform
            self.currentUserID = currentUserID
            userLaunchAgentsDirectory = homeDirectory
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .standardizedFileURL
        }

        func capability(for candidate: Candidate) -> ActionCapability {
            switch destination(for: candidate) {
            case .directlyManageable:
                return ActionCapability(
                    // The exact plist and the executable's fresh signing
                    // identity are bound again at confirmation and execution.
                    // Parent-app attribution is useful display metadata, but
                    // is not required to manage an otherwise verified job.
                    canEnableDirectly: hasVerifiedExecutableIdentity(candidate),
                    canDisableDirectly: true,
                    canStopCurrentSession: true,
                    canOpenSystemSettings: true,
                    canRevealInFinder: true,
                    canOpenParentApp: candidate.hasAuthoritativeParentApplication,
                    canRemoveOrphan: false,
                    requiresAdministrator: false,
                    isReadOnly: false,
                    isManaged: false
                )
            case .systemSettingsLoginItems:
                return ActionCapability(
                    canEnableDirectly: false,
                    canDisableDirectly: false,
                    canStopCurrentSession: false,
                    canOpenSystemSettings: true,
                    canRevealInFinder: candidate.plistURL != nil || candidate.executableURL != nil,
                    canOpenParentApp: candidate.hasAuthoritativeParentApplication,
                    canRemoveOrphan: false,
                    requiresAdministrator: false,
                    isReadOnly: true,
                    isManaged: false
                )
            case .administratorHelperUnavailable:
                let canManage = platform.canManageSystemLaunchItems
                    && isVerifiedAdministrativeLaunchItem(candidate)
                return ActionCapability(
                    canEnableDirectly: canManage
                        && candidate.hasAuthoritativeParentApplication
                        && hasVerifiedExecutableIdentity(candidate),
                    canDisableDirectly: canManage,
                    canStopCurrentSession: false,
                    canOpenSystemSettings: true,
                    canRevealInFinder: true,
                    canOpenParentApp: candidate.hasAuthoritativeParentApplication,
                    canRemoveOrphan: false,
                    requiresAdministrator: true,
                    isReadOnly: !canManage,
                    isManaged: false
                )
            case .managedByOrganization:
                return ActionCapability(
                    canEnableDirectly: false,
                    canDisableDirectly: false,
                    canStopCurrentSession: false,
                    canOpenSystemSettings: true,
                    canRevealInFinder: candidate.plistURL != nil || candidate.executableURL != nil,
                    canOpenParentApp: candidate.hasAuthoritativeParentApplication,
                    canRemoveOrphan: false,
                    requiresAdministrator: false,
                    isReadOnly: true,
                    isManaged: true
                )
            case .systemProtected, .readOnly:
                return ActionCapability(
                    canEnableDirectly: false,
                    canDisableDirectly: false,
                    canStopCurrentSession: false,
                    canOpenSystemSettings: false,
                    canRevealInFinder: candidate.plistURL != nil || candidate.executableURL != nil,
                    canOpenParentApp: candidate.hasAuthoritativeParentApplication,
                    canRemoveOrphan: false,
                    requiresAdministrator: false,
                    isReadOnly: true,
                    isManaged: false
                )
            }
        }

        func destination(for candidate: Candidate) -> ManagementDestination {
            if candidate.kind == .managedItem
                || candidate.scope == .managed
                || candidate.state.authorization == .managed
                || candidate.state.management == .managedByOrganization {
                return .managedByOrganization
            }

            if candidate.kind == .systemLaunchAgent
                || candidate.kind == .systemLaunchDaemon
                || candidate.isVerifiedAppleSystem
                || candidate.state.management == .systemProtected {
                return .systemProtected
            }

            if candidate.kind == .globalLaunchAgent
                || candidate.kind == .launchDaemon
                || candidate.kind == .privilegedHelper
                || candidate.state.management == .requiresAdministrator {
                return .administratorHelperUnavailable
            }

            if candidate.kind == .openAtLogin
                || candidate.kind == .appBackgroundTask
                || candidate.kind == .loginItem {
                return .systemSettingsLoginItems
            }

            guard candidate.kind == .userLaunchAgent,
                  candidate.scope == .currentUser else {
                return .readOnly(reason: "unsupported-startup-item-kind")
            }
            guard platform.canManageCurrentUserLaunchAgents else {
                return .systemSettingsLoginItems
            }
            guard isDirectUserLaunchAgentPath(candidate.plistURL) else {
                return .readOnly(reason: "launch-agent-outside-current-user-domain")
            }
            guard hasVerifiedExecutableIdentity(candidate) else {
                return .readOnly(reason: "startup-item-identity-not-verified")
            }
            return .directlyManageable
        }

        private func hasVerifiedExecutableIdentity(_ candidate: Candidate) -> Bool {
            let evidence = Set(candidate.diagnosticEvidence)
            guard evidence.contains("valid-code-signature"),
                  !evidence.contains("signature-invalid"),
                  !evidence.contains("group-writable"),
                  !evidence.contains("world-writable"),
                  !evidence.contains("target-missing"),
                  !evidence.contains("target-not-executable"),
                  !evidence.contains("unresolved-symbolic-link"),
                  !evidence.contains("temporary-directory-target"),
                  !evidence.contains("trash-target") else {
                return false
            }
            guard candidate.hasAuthoritativeParentApplication else { return true }
            return !evidence.contains("team-identifier-mismatch")
                && !evidence.contains("helper-team-identifier-missing")
                && !evidence.contains("parent-application-signature-unverified")
        }

        func isDirectUserLaunchAgentPath(_ url: URL?) -> Bool {
            guard let url else { return false }
            let normalized = url.standardizedFileURL
            return normalized.pathExtension.lowercased() == "plist"
                && normalized.deletingLastPathComponent() == userLaunchAgentsDirectory
        }

        func administrativeDomain(for url: URL?) -> String? {
            guard let url else { return nil }
            let normalized = url.standardizedFileURL
            guard normalized.pathExtension.lowercased() == "plist" else { return nil }
            switch normalized.deletingLastPathComponent().path {
            case "/Library/LaunchAgents":
                return "gui/\(currentUserID)"
            case "/Library/LaunchDaemons":
                return "system"
            default:
                return nil
            }
        }

        private func isVerifiedAdministrativeLaunchItem(_ candidate: Candidate) -> Bool {
            guard candidate.kind == .globalLaunchAgent || candidate.kind == .launchDaemon,
                  candidate.attribution?.confidence ?? .unknown >= .high,
                  candidate.executableURL != nil,
                  administrativeDomain(for: candidate.plistURL) != nil else {
                return false
            }
            let evidence = Set(candidate.diagnosticEvidence)
            return evidence.contains("valid-code-signature")
                && !evidence.contains("signature-invalid")
                && !evidence.contains("team-identifier-mismatch")
                && !evidence.contains("helper-team-identifier-missing")
                && !evidence.contains("parent-application-signature-unverified")
                && !evidence.contains("group-writable")
                && !evidence.contains("world-writable")
                && !evidence.contains("target-missing")
                && !evidence.contains("unresolved-symbolic-link")
        }
    }
}
