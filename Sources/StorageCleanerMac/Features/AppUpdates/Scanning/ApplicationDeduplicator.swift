import Foundation

struct ApplicationDeduplicator: Sendable {
    func deduplicatePaths(_ applications: [InstalledApplication]) -> [InstalledApplication] {
        var byPath = [String: InstalledApplication]()
        for application in applications {
            let key = ApplicationPathNormalizer.comparisonKey(for: application.bundleURL)
            if let existing = byPath[key] {
                byPath[key] = preferred(existing, application)
            } else {
                byPath[key] = application
            }
        }
        return Array(byPath.values)
    }

    func annotateDuplicateBundles(_ applications: [InstalledApplication]) -> [InstalledApplication] {
        let groups = Dictionary(grouping: applications.indices) { index -> String in
            duplicateIdentityKey(for: applications[index])
        }
        var result = applications

        for indices in groups.values where indices.count > 1 {
            let locations = indices
                .map { applications[$0].bundleURL.standardizedFileURL }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            for index in indices {
                result[index].isDuplicate = true
                result[index].duplicateLocations = locations
                if hasConflictingSigningIdentities(indices, in: applications) {
                    result[index].sourceEvidence = Array(Set(
                        result[index].sourceEvidence + ["duplicate-signing-identity-conflict"]
                    )).sorted()
                    result[index].canAutomaticallyUpdate = false
                    result[index].updateCapability = .manual
                }
            }
        }
        return result
    }

    private func duplicateIdentityKey(for application: InstalledApplication) -> String {
        let identifier = application.bundleIdentifier.trimmed.lowercased()
        guard !identifier.isEmpty else {
            return "path:\(ApplicationPathNormalizer.comparisonKey(for: application.bundleURL))"
        }
        return "bundle:\(identifier)"
    }

    private func hasConflictingSigningIdentities(
        _ indices: [Int],
        in applications: [InstalledApplication]
    ) -> Bool {
        let identities = Set(indices.map { index in
            let application = applications[index]
            return [
                application.signingTeamIdentifier?.trimmed.lowercased() ?? "unsigned",
                application.codeSigningIdentifier?.trimmed.lowercased() ?? "unknown",
            ].joined(separator: "|")
        })
        return identities.count > 1
    }

    func process(_ applications: [InstalledApplication]) -> [InstalledApplication] {
        annotateDuplicateBundles(deduplicatePaths(applications))
    }

    private func preferred(
        _ left: InstalledApplication,
        _ right: InstalledApplication
    ) -> InstalledApplication {
        let leftScore = metadataScore(left)
        let rightScore = metadataScore(right)
        if leftScore == rightScore {
            return left.lastScanDate >= right.lastScanDate ? left : right
        }
        return leftScore > rightScore ? left : right
    }

    private func metadataScore(_ application: InstalledApplication) -> Int {
        var score = 0
        if !application.bundleIdentifier.isEmpty { score += 2 }
        if !application.installedVersion.preferred.isEmpty { score += 2 }
        if application.signingTeamIdentifier != nil { score += 2 }
        if application.codeSigningIdentifier != nil { score += 1 }
        if application.executableURL != nil { score += 1 }
        if !application.architectures.isEmpty { score += 1 }
        return score
    }
}
