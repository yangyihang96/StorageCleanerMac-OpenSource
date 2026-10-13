import Foundation

enum ExternalUpdateVersionResult: Equatable, Sendable {
    case updated(ApplicationVersion)
    case unchanged(ApplicationVersion?)
    case targetNotReached(ApplicationVersion)
    case identityUnverifiable
    case identityChanged
}

/// External updaters and the App Store own the installation. This verifier
/// observes the installed bundle after the user returns; opening an entry is
/// never treated as evidence of completion.
struct ExternalUpdateVersionVerifier: Sendable {
    let rechecker: any InstalledApplicationRechecking

    init(rechecker: any InstalledApplicationRechecking = VerifiedInstalledApplicationRechecker()) {
        self.rechecker = rechecker
    }

    func verify(_ original: InstalledApplication) async throws -> ExternalUpdateVersionResult {
        let expectedTeam = original.officialSource?.expectedTeamIdentifier
            ?? original.signingTeamIdentifier
        guard !original.bundleIdentifier.trimmed.isEmpty,
              let expectedTeam, !expectedTeam.trimmed.isEmpty else {
            return .identityUnverifiable
        }
        guard let snapshot = try await rechecker.snapshot(at: original.bundleURL) else {
            return .identityChanged
        }
        let observed = snapshot.application
        let signature = snapshot.signature
        guard signature.isValid,
              observed.bundleURL.standardizedFileURL == original.bundleURL.standardizedFileURL,
              observed.bundleIdentifier == original.bundleIdentifier,
              signature.teamIdentifier == expectedTeam,
              original.codeSigningIdentifier == nil
                || signature.codeSigningIdentifier == original.codeSigningIdentifier,
              original.officialSource?.expectedDesignatedRequirement == nil
                || signature.designatedRequirement
                    == original.officialSource?.expectedDesignatedRequirement else {
            return .identityChanged
        }
        let version = observed.installedVersion
        guard original.installedVersion < version else {
            return .unchanged(version)
        }
        if let target = original.availableVersion, version < target {
            return .targetNotReached(version)
        }
        return .updated(version)
    }
}
