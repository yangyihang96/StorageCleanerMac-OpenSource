import Foundation

/// A browser search is discovery evidence only. It never creates an
/// `OfficialUpdateSource`, upgrades trust, resolves a download, or starts an
/// installation. The user must inspect and explicitly confirm a website.
struct OfficialWebsiteCandidateSearch: Hashable, Sendable {
    let searchURL: URL
    let query: String
    let evidenceTerms: [String]
    let trustLevel: SourceTrustLevel
}

enum OfficialWebsiteSearchError: LocalizedError, Equatable, Sendable {
    case missingApplicationIdentity
    case invalidSearchURL

    var errorDescription: String? {
        switch self {
        case .missingApplicationIdentity:
            L10n.text("缺少可用于查找候选官网的应用身份。", "No application identity is available for candidate website discovery.")
        case .invalidSearchURL:
            L10n.text("无法创建候选官网搜索。", "Could not create the candidate website search.")
        }
    }
}

struct OfficialWebsiteSearchService: Sendable {
    func candidateSearch(
        for application: InstalledApplication
    ) throws -> OfficialWebsiteCandidateSearch {
        let identityTerms = Self.uniqueTerms([
            application.displayName,
            application.bundleIdentifier,
            application.signingTeamIdentifier,
            application.codeSigningIdentifier,
        ])
        guard !identityTerms.isEmpty else {
            throw OfficialWebsiteSearchError.missingApplicationIdentity
        }

        let evidenceTerms = identityTerms + ["official", "download", "update", "macOS"]
        let query = evidenceTerms.joined(separator: " ").prefix(512)
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: String(query))]
        guard let searchURL = components?.url,
              searchURL.scheme == "https",
              searchURL.host == "www.google.com",
              searchURL.path == "/search" else {
            throw OfficialWebsiteSearchError.invalidSearchURL
        }

        return OfficialWebsiteCandidateSearch(
            searchURL: searchURL,
            query: String(query),
            evidenceTerms: evidenceTerms,
            trustLevel: .candidate
        )
    }

    private static func uniqueTerms(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { rawValue in
            guard let value = rawValue?.trimmed.nonEmpty else { return nil }
            let bounded = String(value.prefix(120))
            let key = bounded.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(key).inserted else { return nil }
            return bounded
        }
    }
}
