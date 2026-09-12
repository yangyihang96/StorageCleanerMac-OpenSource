import Foundation

extension StartupItemsDomain {
    enum PurposeSource: String, Codable, Hashable, Sendable {
        case officialDescription
        case verifiedRegistry
        case launchConfigurationInference
        case unknown
    }

    enum PurposeConfidence: Int, Codable, Comparable, Hashable, Sendable {
        case unknown = 0
        case low = 1
        case medium = 2
        case high = 3
        case verified = 4

        static func < (lhs: PurposeConfidence, rhs: PurposeConfidence) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct Purpose: Codable, Hashable, Sendable {
        let value: String
        let source: PurposeSource
        let confidence: PurposeConfidence
    }
}

struct StartupPurposeResolver: Sendable {
    func resolve(_ candidate: StartupItemsDomain.Candidate) -> StartupItemsDomain.Purpose {
        if candidate.isVerifiedAppleSystem {
            return StartupItemsDomain.Purpose(
                value: L10n.text("macOS 系统后台服务", "macOS system background service"),
                source: .officialDescription,
                confidence: .verified
            )
        }

        if hasVerifiedIdentity(candidate),
           let attribution = candidate.attribution,
           let teamIdentifier = attribution.teamIdentifier?.uppercased(),
           let bundleIdentifier = attribution.applicationBundleIdentifier?.lowercased(),
           let label = candidate.label?.lowercased() {
            if teamIdentifier == "EQHXZ8M8AV",
               bundleIdentifier.hasPrefix("com.google."),
               Self.matchesGoogleUpdater(label) {
                return StartupItemsDomain.Purpose(
                    value: L10n.text("检查并安装 Google 应用更新", "Checks and installs Google application updates"),
                    source: .verifiedRegistry,
                    confidence: .verified
                )
            }

            if teamIdentifier == "UBF8T346G9",
               bundleIdentifier.hasPrefix("com.microsoft."),
               Self.matchesMicrosoftAutoUpdate(label) {
                return StartupItemsDomain.Purpose(
                    value: L10n.text("检查并安装 Microsoft 应用更新", "Checks and installs Microsoft application updates"),
                    source: .verifiedRegistry,
                    confidence: .verified
                )
            }
        }

        return inferredPurpose(for: candidate)
    }

    private func hasVerifiedIdentity(_ candidate: StartupItemsDomain.Candidate) -> Bool {
        guard candidate.attribution?.confidence ?? .unknown >= .high else { return false }
        let evidence = Set(candidate.diagnosticEvidence)
        return evidence.contains("valid-code-signature")
            && !evidence.contains("signature-invalid")
            && !evidence.contains("team-identifier-mismatch")
            && !evidence.contains("helper-team-identifier-missing")
    }

    private func inferredPurpose(
        for candidate: StartupItemsDomain.Candidate
    ) -> StartupItemsDomain.Purpose {
        let trigger = candidate.configuration?.triggers.first
        let value: String
        if let trigger {
            value = L10n.text(
                "\(trigger.userFacingDescription)；具体用途尚未确认",
                "\(trigger.userFacingDescription); specific purpose is not yet confirmed"
            )
        } else if candidate.kind == .openAtLogin || candidate.kind == .loginItem {
            value = L10n.text("登录时运行；具体用途尚未确认", "Runs at login; specific purpose is not yet confirmed")
        } else if Self.isBackgroundKind(candidate.kind) {
            value = L10n.text("登录后按需运行；具体用途尚未确认", "Runs on demand after login; specific purpose is not yet confirmed")
        } else {
            return StartupItemsDomain.Purpose(
                value: L10n.text("具体用途尚未确认", "Specific purpose is not yet confirmed"),
                source: .unknown,
                confidence: .unknown
            )
        }
        return StartupItemsDomain.Purpose(
            value: value,
            source: .launchConfigurationInference,
            confidence: .low
        )
    }

    private static func matchesGoogleUpdater(_ label: String) -> Bool {
        label == "com.google.keystone.agent"
            || label.hasPrefix("com.google.keystone.")
            || label == "com.google.googleupdater"
            || label.hasPrefix("com.google.googleupdater.")
    }

    private static func isBackgroundKind(_ kind: StartupItemsDomain.ItemKind) -> Bool {
        switch kind {
        case .userLaunchAgent, .globalLaunchAgent, .systemLaunchAgent,
             .launchDaemon, .systemLaunchDaemon, .appBackgroundTask,
             .embeddedHelper, .privilegedHelper:
            return true
        case .openAtLogin, .loginItem, .managedItem, .orphanedItem, .unknown:
            return false
        }
    }

    private static func matchesMicrosoftAutoUpdate(_ label: String) -> Bool {
        label == "com.microsoft.update.agent"
            || label.hasPrefix("com.microsoft.update.")
            || label == "com.microsoft.autoupdate"
            || label.hasPrefix("com.microsoft.autoupdate.")
    }
}

extension StartupItemsDomain.Candidate {
    var resolvedPurpose: StartupItemsDomain.Purpose {
        StartupPurposeResolver().resolve(self)
    }
}

extension StartupItemsDomain.Item {
    var resolvedPurpose: StartupItemsDomain.Purpose {
        components.map(\.resolvedPurpose).max { lhs, rhs in
            lhs.confidence < rhs.confidence
        } ?? StartupItemsDomain.Purpose(
            value: L10n.text("具体用途尚未确认", "Specific purpose is not yet confirmed"),
            source: .unknown,
            confidence: .unknown
        )
    }
}
