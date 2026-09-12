import Foundation
import ServiceManagement

/// Service Management is intentionally scoped to this application's own
/// services. `SMAppService` is not a third-party enumeration/control API.
struct ServiceManagementScanner: StartupItemScanning {
    let source = StartupItemsDomain.ScanSource.serviceManagement
    let coverageIdentifier = "service-management.own-application"

    func scan(context: StartupScanContext) async throws -> [StartupItemsDomain.Candidate] {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let status = SMAppService.mainApp.status
        var candidates = [candidate(
            id: "service-management:main-app",
            name: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? L10n.text("存储清理助手", "Storage Cleaner"),
            label: bundleIdentifier,
            plistURL: nil,
            applicationURL: bundleURL,
            status: status,
            evidence: "SMAppService.mainApp.status"
        )]

        // Only query legacy plists already attributed to this app. This API is
        // not used to enumerate or control third-party services.
        for seed in context.seedCandidates {
            guard let plistURL = seed.plistURL,
                  seed.applicationURL?.standardizedFileURL == bundleURL else { continue }
            candidates.append(
                candidate(
                    id: "service-management:legacy:\(plistURL.path)",
                    name: seed.name,
                    label: seed.label,
                    plistURL: plistURL,
                    applicationURL: bundleURL,
                    status: SMAppService.statusForLegacyPlist(at: plistURL),
                    evidence: "SMAppService.statusForLegacyPlist"
                )
            )
        }
        return candidates
    }

    private func candidate(
        id: String,
        name: String,
        label: String?,
        plistURL: URL?,
        applicationURL: URL,
        status: SMAppService.Status,
        evidence: String
    ) -> StartupItemsDomain.Candidate {
        let state = Self.state(for: status)
        return StartupItemsDomain.Candidate(
            id: id,
            source: .serviceManagement,
            kind: .loginItem,
            scope: .applicationBundle,
            name: name,
            label: label,
            plistURL: plistURL,
            executableURL: Bundle(url: applicationURL)?.executableURL,
            applicationURL: applicationURL,
            configuration: nil,
            state: state,
            attribution: StartupItemsDomain.Attribution(
                applicationBundleIdentifier: Bundle.main.bundleIdentifier,
                applicationURL: applicationURL,
                applicationName: name,
                developerName: nil,
                teamIdentifier: nil,
                designatedRequirement: nil,
                evidence: [
                    StartupItemsDomain.AttributionEvidence(
                        kind: .embeddedInApplication,
                        value: applicationURL.path,
                        confidence: .verified
                    ),
                ]
            ),
            actionCapability: StartupItemsDomain.ActionCapability(
                canEnableDirectly: false,
                canDisableDirectly: false,
                canStopCurrentSession: false,
                canOpenSystemSettings: true,
                canRevealInFinder: true,
                canOpenParentApp: true,
                canRemoveOrphan: false,
                requiresAdministrator: false,
                isReadOnly: true,
                isManaged: false
            ),
            diagnosticEvidence: [evidence, "own-application-only"]
        )
    }

    private static func state(for status: SMAppService.Status) -> StartupItemsDomain.State {
        switch status {
        case .enabled:
            StartupItemsDomain.State(
                registration: .registered,
                authorization: .approved,
                enablement: .enabled,
                load: .unknown,
                process: .unknown,
                management: .directlyManageable
            )
        case .requiresApproval:
            StartupItemsDomain.State(
                registration: .registered,
                authorization: .requiresApproval,
                enablement: .disabled,
                load: .unknown,
                process: .unknown,
                management: .manageableInSystemSettings
            )
        case .notRegistered, .notFound:
            StartupItemsDomain.State(
                registration: .notRegistered,
                authorization: .notApplicable,
                enablement: .disabled,
                load: .notLoaded,
                process: .stopped,
                management: .directlyManageable
            )
        @unknown default:
            .unknown
        }
    }
}
