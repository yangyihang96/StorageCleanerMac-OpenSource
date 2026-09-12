import Foundation

struct StartupAttributionResolver: Sendable {
    func resolve(
        _ candidate: StartupItemsDomain.Candidate,
        using index: InstalledApplicationIndex
    ) -> StartupItemsDomain.Candidate {
        if let existing = candidate.attribution,
           existing.confidence >= .high {
            return enrich(candidate, existing: existing, using: index)
        }

        var resolved = candidate
        let associatedIdentifiers = candidate.configuration?.associatedBundleIdentifiers ?? []
        var unresolvedAssociationEvidence = candidate.attribution?.evidence ?? []
        for identifier in associatedIdentifiers {
            guard let applications = index.byBundleIdentifier[identifier],
                  !applications.isEmpty else {
                unresolvedAssociationEvidence.append(
                    associationEvidence(identifier: identifier, confidence: .medium)
                )
                continue
            }
            if let application = exactParentApplication(
                for: candidate,
                existing: candidate.attribution,
                among: applications
            ) {
                resolved.attribution = attribution(
                    application,
                    evidence: .associatedBundleIdentifier,
                    value: identifier,
                    confidence: .high
                )
                resolved.applicationURL = application.bundleURL
                return resolved
            }
            unresolvedAssociationEvidence.append(
                associationEvidence(identifier: identifier, confidence: .medium)
            )
        }
        if !unresolvedAssociationEvidence.isEmpty {
            // AssociatedBundleIdentifiers is supplied by the launchd plist.
            // When several installed copies share an identifier, it proves a
            // relationship hint but not which bundle owns the component.
            // Preserve that evidence for the Inspector without selecting an
            // arbitrary parent path, developer, icon or management action.
            resolved.applicationURL = nil
            resolved.attribution = StartupItemsDomain.Attribution(
                applicationBundleIdentifier: associatedIdentifiers.count == 1
                    ? associatedIdentifiers[0]
                    : nil,
                applicationURL: nil,
                applicationName: nil,
                developerName: nil,
                teamIdentifier: nil,
                designatedRequirement: nil,
                evidence: deduplicated(unresolvedAssociationEvidence)
            )
            return resolved
        }

        if let applicationURL = candidate.applicationURL?.standardizedFileURL,
           let application = index.application(at: applicationURL) {
            resolved.attribution = attribution(
                application,
                evidence: .applicationPath,
                value: applicationURL.path,
                confidence: .verified
            )
            return resolved
        }

        if let executableURL = candidate.executableURL?.standardizedFileURL,
           let application = index.application(containingExecutableAt: executableURL) {
            resolved.applicationURL = application.bundleURL
            resolved.attribution = attribution(
                application,
                evidence: .embeddedInApplication,
                value: executableURL.path,
                confidence: .verified
            )
            return resolved
        }

        if let label = candidate.label,
           let application = index.application(matchingBundleLabel: label) {
            resolved.applicationURL = application.bundleURL
            resolved.attribution = attribution(
                application,
                evidence: .labelHint,
                value: candidate.label ?? "",
                confidence: .low
            )
            return resolved
        }

        if let token = InstalledApplicationIndex.labelToken(candidate.label ?? candidate.name),
           let application = index.application(matchingLabelToken: token) {
            resolved.applicationURL = application.bundleURL
            resolved.attribution = attribution(
                application,
                evidence: .labelHint,
                value: token,
                confidence: .low
            )
        }
        return resolved
    }

    private func enrich(
        _ candidate: StartupItemsDomain.Candidate,
        existing: StartupItemsDomain.Attribution,
        using index: InstalledApplicationIndex
    ) -> StartupItemsDomain.Candidate {
        guard let parentIdentifier = existing.applicationBundleIdentifier?.trimmed.nonEmpty,
              let applications = index.byBundleIdentifier[parentIdentifier],
              let application = exactParentApplication(
                for: candidate,
                existing: existing,
                among: applications
              ) else {
            return candidate
        }

        var resolved = candidate
        var enriched = existing
        enriched.applicationURL = application.bundleURL
        enriched.applicationName = application.displayName
        enriched.developerName = application.developerName ?? existing.developerName
        enriched.teamIdentifier = application.teamIdentifier ?? existing.teamIdentifier
        enriched.designatedRequirement = application.designatedRequirement ?? existing.designatedRequirement
        if !enriched.evidence.contains(where: {
            $0.kind == .installedApplicationIndex && $0.value == parentIdentifier
        }) {
            enriched.evidence.append(
                StartupItemsDomain.AttributionEvidence(
                    kind: .installedApplicationIndex,
                    value: parentIdentifier,
                    confidence: .high
                )
            )
        }
        resolved.applicationURL = application.bundleURL
        resolved.attribution = enriched
        return resolved
    }

    private func exactParentApplication(
        for candidate: StartupItemsDomain.Candidate,
        existing: StartupItemsDomain.Attribution?,
        among applications: [StartupInstalledApplication]
    ) -> StartupInstalledApplication? {
        let knownPaths = Set([
            candidate.applicationURL?.standardizedFileURL.path,
            existing?.applicationURL?.standardizedFileURL.path,
        ].compactMap { $0 })
        if !knownPaths.isEmpty {
            let pathMatches = applications.filter { knownPaths.contains($0.bundleURL.standardizedFileURL.path) }
            if pathMatches.count == 1 { return pathMatches[0] }
        }

        if let teamIdentifier = existing?.teamIdentifier?.trimmed.nonEmpty,
           let signingIdentifier = existing?.applicationBundleIdentifier?.trimmed.nonEmpty {
            let identityMatches = applications.filter {
                $0.teamIdentifier == teamIdentifier
                    && $0.codeSigningIdentifier == signingIdentifier
            }
            if identityMatches.count == 1 { return identityMatches[0] }
        }
        return applications.count == 1 ? applications[0] : nil
    }

    private func associationEvidence(
        identifier: String,
        confidence: StartupItemsDomain.AttributionConfidence
    ) -> StartupItemsDomain.AttributionEvidence {
        StartupItemsDomain.AttributionEvidence(
            kind: .associatedBundleIdentifier,
            value: identifier,
            confidence: confidence
        )
    }

    private func deduplicated(
        _ evidence: [StartupItemsDomain.AttributionEvidence]
    ) -> [StartupItemsDomain.AttributionEvidence] {
        var seen = Set<String>()
        return evidence.filter {
            seen.insert("\($0.kind.rawValue):\($0.value):\($0.confidence.rawValue)").inserted
        }
    }

    private func attribution(
        _ application: StartupInstalledApplication,
        evidence: StartupItemsDomain.AttributionEvidenceKind,
        value: String,
        confidence: StartupItemsDomain.AttributionConfidence
    ) -> StartupItemsDomain.Attribution {
        StartupItemsDomain.Attribution(
            applicationBundleIdentifier: application.bundleIdentifier,
            applicationURL: application.bundleURL,
            applicationName: application.displayName,
            developerName: application.developerName,
            teamIdentifier: application.teamIdentifier,
            designatedRequirement: application.designatedRequirement,
            evidence: [
                StartupItemsDomain.AttributionEvidence(
                    kind: evidence,
                    value: value,
                    confidence: confidence
                ),
            ]
        )
    }

}
