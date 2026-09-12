import Foundation

extension StartupItemsDomain {
    enum TrustAssessment: String, Codable, Hashable, Sendable {
        case appleSystem
        case verifiedDeveloper
        case unsigned
        case invalidSignature
        case missingExecutable
        case unknown
    }
}

extension StartupItemsDomain.Candidate {
    /// A system-looking label is not proof that an item belongs to Apple.
    var isVerifiedAppleSystem: Bool {
        if let plistURL,
           Self.mayResolveIntoSystemLocation(plistURL.path) {
            let parent = plistURL.standardizedFileURL.deletingLastPathComponent().path
            let isProtectedLaunchdLocation = parent == "/System/Library/LaunchAgents"
                || parent == "/System/Library/LaunchDaemons"
            if isProtectedLaunchdLocation {
                if scope == .system,
                   (kind == .systemLaunchAgent || kind == .systemLaunchDaemon),
                   diagnosticEvidence.contains("apple-system-location") {
                    return true
                }
                if source == .orphanDetection,
                   kind == .orphanedItem,
                   diagnosticEvidence.contains(where: { $0.hasPrefix("source-candidate:") }) {
                    return true
                }
            }
        }

        // A real bundle or executable below Apple's sealed system locations is
        // authoritative regardless of which public scanner discovered it.
        // This covers, for example, an Open at Login entry for Maps.app.
        if Self.isProtectedAppleApplicationURL(executableURL)
            || Self.isProtectedAppleApplicationURL(applicationURL)
            || Self.isProtectedAppleApplicationURL(attribution?.applicationURL) {
            return true
        }

        guard source == .backgroundTaskDiagnostic else { return false }
        return diagnosticEvidence.contains("apple-system-signature")
    }

    private static func isProtectedAppleApplicationPath(_ path: String) -> Bool {
        path == "/System/Library"
            || path.hasPrefix("/System/Library/")
            || path == "/System/Applications"
            || path.hasPrefix("/System/Applications/")
            || path == "/System/iOSSupport"
            || path.hasPrefix("/System/iOSSupport/")
    }

    private static func isProtectedAppleApplicationURL(_ URL: URL?) -> Bool {
        guard let URL,
              mayResolveIntoSystemLocation(URL.path) else { return false }
        return isProtectedAppleApplicationPath(URL.standardizedFileURL.path)
    }

    private static func mayResolveIntoSystemLocation(_ path: String) -> Bool {
        path == "/System"
            || path.hasPrefix("/System/")
            || path.hasPrefix("//")
            || path.contains("/./")
            || path.contains("/../")
    }

    static func isAppleSystemDesignatedRequirement(_ requirement: String?) -> Bool {
        guard let normalized = requirement?.lowercased() else { return false }
        return normalized.contains("anchor apple")
            && !normalized.contains("anchor apple generic")
    }

    /// Low-confidence label guesses may be displayed as a hint, but they must
    /// not merge otherwise independent launchd components.
    var reliableApplicationIdentity: String? {
        if let attribution, attribution.confidence >= .high {
            if let identifier = attribution.applicationBundleIdentifier?.trimmed.nonEmpty {
                let bundleIdentifier = identifier.lowercased()
                if let teamIdentifier = attribution.teamIdentifier?.trimmed.nonEmpty {
                    return "bundle:\(bundleIdentifier)|team:\(teamIdentifier.uppercased())"
                }
                if let requirement = attribution.designatedRequirement?.trimmed.nonEmpty {
                    return "bundle:\(bundleIdentifier)|requirement:\(requirement)"
                }
                if let URL = attribution.applicationURL {
                    return "bundle:\(bundleIdentifier)|path:\(URL.standardizedFileURL.path)"
                }
                return nil
            }
            if let URL = attribution.applicationURL {
                return "path:\(URL.standardizedFileURL.path)"
            }
        }

        if attribution == nil,
           let URL = applicationURL?.standardizedFileURL,
           URL.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            return "path:\(URL.path)"
        }
        return nil
    }

    var reliableApplicationIconPath: String? {
        if let attribution,
           attribution.confidence >= .high,
           let URL = attribution.applicationURL,
           URL.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            return URL.standardizedFileURL.path
        }
        if attribution == nil,
           let URL = applicationURL,
           URL.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            return URL.standardizedFileURL.path
        }
        return nil
    }

    var hasAuthoritativeParentApplication: Bool {
        reliableApplicationIconPath != nil
    }

    var trustAssessment: StartupItemsDomain.TrustAssessment {
        if isVerifiedAppleSystem { return .appleSystem }
        if diagnosticEvidence.contains("signature-invalid")
            || diagnosticEvidence.contains("team-identifier-mismatch") {
            return .invalidSignature
        }
        if diagnosticEvidence.contains("target-missing") { return .missingExecutable }
        if diagnosticEvidence.contains("unsigned-executable") { return .unsigned }
        if diagnosticEvidence.contains("valid-code-signature")
            && !diagnosticEvidence.contains("helper-team-identifier-missing") {
            return .verifiedDeveloper
        }
        return .unknown
    }
}

struct StartupInspectorIdentityPresentation: Equatable, Sendable {
    let applicationLabel: String
    let applicationName: String
    let applicationURL: URL?
    let bundleIdentifier: String?
    let teamIdentifier: String?

    static func make(
        candidate: StartupItemsDomain.Candidate
    ) -> StartupInspectorIdentityPresentation {
        let attribution = candidate.attribution
        let confidence = attribution?.confidence ?? .unknown
        if attribution != nil, confidence < .high {
            return StartupInspectorIdentityPresentation(
                applicationLabel: L10n.text("可能所属（低可信）", "Possible Application (Low Confidence)"),
                applicationName: attribution?.applicationName?.trimmed.nonEmpty
                    ?? L10n.text("未知后台项目", "Unknown Background Item"),
                applicationURL: nil,
                bundleIdentifier: nil,
                teamIdentifier: nil
            )
        }

        return StartupInspectorIdentityPresentation(
            applicationLabel: L10n.text("所属应用", "Application"),
            applicationName: attribution?.applicationName?.trimmed.nonEmpty
                ?? L10n.text("未知后台项目", "Unknown Background Item"),
            applicationURL: attribution?.applicationURL ?? candidate.applicationURL,
            bundleIdentifier: attribution?.applicationBundleIdentifier,
            teamIdentifier: attribution?.teamIdentifier
        )
    }
}
