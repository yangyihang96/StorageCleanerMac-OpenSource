import Foundation

/// A deliberately small, local-only classifier for the browser-privacy view.
/// It never resolves a host, opens a URL, uploads history, or relies on a
/// remote reputation service.  The result is an aid for review, not a claim
/// that a site belongs to a sensitive category.
struct BrowserPrivacyLocalClassifier: Sendable {
    private let ruleSet = BrowserPrivacyLocalRuleSet.bundled

    func classify(
        url: String?,
        title: String?,
        domain: String?
    ) -> BrowserPrivacyClassification {
        guard let normalizedDomain = domain.flatMap(BrowserPrivacyHostname.normalized) else {
            return .init(category: .unknown, confidence: .unavailable)
        }
        let text = [url, title, normalizedDomain]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if isHighConfidenceAdultDomain(normalizedDomain) {
            return .init(category: .adult, confidence: .high)
        }

        // Words such as "sex" or "reproduction" occur routinely in medical,
        // educational, research, and news pages.  They must not result in a
        // high-confidence adult label or an automatic selection.
        if containsAny(text, terms: Self.contextExclusions) {
            return classifyNonAdult(text: text)
        }

        let adultTermMatches = Self.adultTerms.reduce(into: 0) { count, term in
            if text.contains(term) { count += 1 }
        }
        if adultTermMatches > 0 {
            // A single broad local token remains low confidence. Multiple
            // independent signals may reach medium confidence, but never the
            // default-selected high tier; only a verified domain rule can do
            // that. Context exclusions above still win first.
            return .init(
                category: .adult,
                confidence: adultTermMatches >= 2 ? .medium : .low
            )
        }

        return classifyNonAdult(text: text)
    }

    private func classifyNonAdult(text: String) -> BrowserPrivacyClassification {
        for rule in Self.categoryRules {
            if containsAny(text, terms: rule.terms) {
                return .init(category: rule.category, confidence: .medium)
            }
        }
        return .init(category: .other, confidence: .low)
    }

    private func isHighConfidenceAdultDomain(_ domain: String) -> Bool {
        let labels = domain.split(separator: ".").map(String.init)
        guard labels.count >= 2,
              let terminalLabel = labels.last else { return false }

        // A terminal label is an exact DNS-label comparison. Values such as
        // `example.xxx.evil.test`, `example.notxxx`, or a Unicode lookalike do
        // not match. The bundled set contains only adult-specific delegated
        // top-level domains; brand names and fuzzy hostname tokens are not
        // high-confidence rules.
        return ruleSet.highConfidenceAdultTerminalLabels.contains(terminalLabel)
    }

    private func containsAny(_ text: String, terms: Set<String>) -> Bool {
        terms.contains { text.contains($0) }
    }

    private static let adultTerms: Set<String> = [
        "adult content",
        "porn",
        "explicit video",
        "nsfw",
    ]

    private static let contextExclusions: Set<String> = [
        "medical", "health", "clinic", "hospital", "therapy", "research",
        "journal", "study", "education", "reproductive", "fertility",
        "pregnan", "sexual health", "sex education", "news",
    ]

    private static let categoryRules: [(category: BrowserPrivacyCategory, terms: Set<String>)] = [
        (.finance, [
            "bank", "banking", "payment", "wallet", "broker", "invest",
            "finance", "insurance", "tax", "invoice",
        ]),
        (.social, [
            "social", "facebook", "instagram", "linkedin", "reddit",
            "discord", "mastodon", "threads",
        ]),
        (.shopping, [
            "shopping", "shop", "store", "cart", "checkout", "marketplace",
        ]),
        (.entertainment, [
            "video", "music", "stream", "movie", "gaming", "podcast",
        ]),
        (.search, [
            "search", "google", "bing", "duckduckgo", "query",
        ]),
        (.productivity, [
            "document", "calendar", "project", "workspace", "notion",
            "spreadsheet", "mail", "drive",
        ]),
        (.news, [
            "news", "newspaper", "press", "article", "journalism",
        ]),
    ]
}

/// Auditable rules compiled into the application. Updating this set requires
/// a version bump and test changes; it is never downloaded or supplemented by
/// browsing data at runtime.
struct BrowserPrivacyLocalRuleSet: Equatable, Sendable {
    let version: Int
    let highConfidenceAdultTerminalLabels: Set<String>

    static let bundled = Self(
        version: 1,
        highConfidenceAdultTerminalLabels: [
            "adult",
            "porn",
            "sex",
            "xxx",
        ]
    )
}

private enum BrowserPrivacyHostname {
    private static let forbiddenCharacters = CharacterSet(charactersIn: "/?#@:%\\")

    static func normalized(_ rawHost: String) -> String? {
        var candidate = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate.rangeOfCharacter(from: forbiddenCharacters) == nil else {
            return nil
        }
        if candidate.hasSuffix(".") {
            candidate.removeLast()
        }
        guard !candidate.isEmpty,
              !candidate.hasPrefix("."),
              candidate.utf8.count <= 253,
              let components = URLComponents(string: "https://\(candidate)"),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let parsedHost = components.host else {
            return nil
        }

        let host = parsedHost
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        let labels = host
            .split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        guard labels.count >= 2,
              host.utf8.count <= 253,
              labels.allSatisfy(isValidLabel) else {
            return nil
        }
        return labels.joined(separator: ".")
    }

    private static func isValidLabel(_ label: String) -> Bool {
        guard !label.isEmpty,
              label.utf8.count <= 63,
              label.first != "-",
              label.last != "-" else {
            return false
        }
        return label.allSatisfy { character in
            character == "-" || character.isLetter || character.isNumber
        }
    }
}

struct BrowserPrivacyClassification: Equatable, Sendable {
    let category: BrowserPrivacyCategory
    let confidence: BrowserPrivacySelectionConfidence
}
