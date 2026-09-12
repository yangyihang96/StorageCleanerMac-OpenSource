import Foundation

enum OfficialUpdateLocalization {
    static func format(_ zh: String, _ en: String, _ arguments: CVarArg...) -> String {
        String(format: L10n.text(zh, en), locale: L10n.locale, arguments: arguments)
    }
}

enum OfficialURLValidationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedScheme
    case containsCredentials
    case missingHost
    case invalidHost
    case localOrIPAddressHost
    case unexpectedPort
    case hostNotAllowed(String)
    case redirectChainEmpty

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme:
            return L10n.text("官方更新地址必须使用 HTTPS。", "Official update URLs must use HTTPS.")
        case .containsCredentials:
            return L10n.text("官方更新地址不得包含用户名或密码。", "Official update URLs must not contain credentials.")
        case .missingHost:
            return L10n.text("官方更新地址缺少域名。", "The official update URL has no host.")
        case .invalidHost:
            return L10n.text("官方更新域名格式无效。", "The official update host is malformed.")
        case .localOrIPAddressHost:
            return L10n.text("不允许将本地地址或 IP 地址作为官方更新来源。", "Local and IP-address hosts are not accepted as official update sources.")
        case .unexpectedPort:
            return L10n.text("官方更新地址使用了未允许的端口。", "The official update URL uses an unexpected port.")
        case let .hostNotAllowed(host):
            return OfficialUpdateLocalization.format("域名 %@ 不在此应用的官方来源允许列表中。", "Host %@ is not in this application's official-source allowlist.", host)
        case .redirectChainEmpty:
            return L10n.text("下载重定向链为空。", "The download redirect chain is empty.")
        }
    }
}

struct AllowedHostValidator: Sendable {
    /// Official-source rules use exact hosts. A subdomain must be listed explicitly;
    /// accepting arbitrary suffixes would make a compromised sibling host trusted.
    func validate(_ url: URL, allowedHosts: Set<String>) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw OfficialURLValidationError.unsupportedScheme
        }
        guard url.user == nil, url.password == nil else {
            throw OfficialURLValidationError.containsCredentials
        }
        guard url.port == nil || url.port == 443 else {
            throw OfficialURLValidationError.unexpectedPort
        }
        guard let rawHost = url.host, !rawHost.isEmpty else {
            throw OfficialURLValidationError.missingHost
        }

        let host = try Self.normalizedHost(rawHost)
        let normalizedAllowedHosts = try Set(allowedHosts.map(Self.normalizedHost))
        guard normalizedAllowedHosts.contains(host) else {
            throw OfficialURLValidationError.hostNotAllowed(host)
        }
    }

    static func normalizedHost(_ rawHost: String) throws -> String {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }

        guard !host.isEmpty,
              host.count <= 253,
              host.contains("."),
              !host.contains(".."),
              !host.contains("%"),
              !host.contains(":"),
              !host.hasPrefix("."),
              !host.hasSuffix(".") else {
            throw OfficialURLValidationError.invalidHost
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ label in
                  guard !label.isEmpty, label.count <= 63,
                        label.first != "-", label.last != "-" else { return false }
                  return label.unicodeScalars.allSatisfy { scalar in
                      CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
                  }
              }) else {
            throw OfficialURLValidationError.invalidHost
        }

        let rejectedNames = ["localhost", "localhost.localdomain", "local"]
        guard !rejectedNames.contains(host),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".localhost"),
              !Self.looksLikeIPv4(host),
              !Self.looksLikeIPv6(rawHost) else {
            throw OfficialURLValidationError.localOrIPAddressHost
        }
        return host
    }

    private static func looksLikeIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }

    private static func looksLikeIPv6(_ host: String) -> Bool {
        host.contains(":") || (host.hasPrefix("[") && host.hasSuffix("]"))
    }
}

struct RedirectValidator: Sendable {
    private let hostValidator = AllowedHostValidator()

    /// Validates every hop, including the initial and final URL. An allowed
    /// first-party URL may not redirect through an unlisted tracking/CDN host.
    func validate(chain: [URL], allowedHosts: Set<String>) throws {
        guard !chain.isEmpty else { throw OfficialURLValidationError.redirectChainEmpty }
        for url in chain {
            try hostValidator.validate(url, allowedHosts: allowedHosts)
        }
    }

    func validateRedirect(from originalURL: URL, to proposedURL: URL, allowedHosts: Set<String>) throws {
        try validate(chain: [originalURL, proposedURL], allowedHosts: allowedHosts)
    }
}
