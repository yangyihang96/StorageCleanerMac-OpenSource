import Foundation

protocol AppStoreCatalogHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionAppStoreCatalogHTTPClient: AppStoreCatalogHTTPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AppStoreCatalogError.invalidResponse
        }
        return (data, response)
    }
}

protocol AppStoreCatalogResolving: Sendable {
    func resolve(
        bundleIdentifier: String,
        storefront: String
    ) async throws -> AppStoreCatalogResolution
}

enum AppStoreCatalogResolution: Hashable, Sendable {
    case matched(AppStoreCatalogEntry)
    case notFound
    case ambiguous
}

struct AppStoreCatalogEntry: Hashable, Sendable {
    let bundleIdentifier: String
    let version: ApplicationVersion
    let productURL: URL
    let sellerName: String?
    let releaseDate: Date?
    let releaseNotes: String?
    let downloadSize: Int64?
    let averageUserRating: Double?
    let userRatingCount: Int?

    init(
        bundleIdentifier: String,
        version: ApplicationVersion,
        productURL: URL,
        sellerName: String?,
        releaseDate: Date?,
        releaseNotes: String?,
        downloadSize: Int64?,
        averageUserRating: Double? = nil,
        userRatingCount: Int? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.productURL = productURL
        self.sellerName = sellerName
        self.releaseDate = releaseDate
        self.releaseNotes = releaseNotes
        self.downloadSize = downloadSize
        self.averageUserRating = averageUserRating
        self.userRatingCount = userRatingCount
    }
}

enum AppStoreCatalogError: Error, LocalizedError, Equatable {
    case invalidBundleIdentifier
    case invalidResponse
    case unexpectedStatus(Int)
    case temporarilyUnavailable
    case malformedResponse
    case invalidProductURL

    var errorDescription: String? {
        switch self {
        case .invalidBundleIdentifier:
            L10n.text("App Store 查询缺少 Bundle Identifier。", "The App Store lookup is missing a bundle identifier.")
        case .invalidResponse:
            L10n.text("App Store 返回了无效响应。", "The App Store returned an invalid response.")
        case let .unexpectedStatus(status):
            L10n.text("App Store 查询失败（HTTP \(status)）。", "The App Store lookup failed (HTTP \(status)).")
        case .temporarilyUnavailable:
            L10n.text(
                "App Store 目录暂时不可用；稍后重试时会恢复检查。",
                "The App Store catalog is temporarily unavailable; checks will resume after a short cooldown."
            )
        case .malformedResponse:
            L10n.text("App Store 返回了无法解析的目录数据。", "The App Store returned malformed catalog data.")
        case .invalidProductURL:
            L10n.text("App Store 产品链接未通过 Apple 域名校验。", "The App Store product link failed Apple host validation.")
        }
    }
}

struct AppStoreCatalogResolver: AppStoreCatalogResolving {
    private static let allowedProductHosts: Set<String> = [
        "apps.apple.com",
        "itunes.apple.com",
    ]

    private let client: any AppStoreCatalogHTTPClient
    private let timeout: TimeInterval
    private let cooldown: TimeInterval
    private let availability: AppStoreCatalogAvailabilityState

    init(
        client: any AppStoreCatalogHTTPClient = URLSessionAppStoreCatalogHTTPClient(),
        timeout: TimeInterval = 8,
        cooldown: TimeInterval = 30,
        availability: AppStoreCatalogAvailabilityState = AppStoreCatalogAvailabilityState()
    ) {
        self.client = client
        self.timeout = timeout
        self.cooldown = cooldown
        self.availability = availability
    }

    static var currentStorefront: String {
        normalizedStorefront(Locale.current.region?.identifier)
    }

    func resolve(
        bundleIdentifier: String,
        storefront: String
    ) async throws -> AppStoreCatalogResolution {
        let bundleIdentifier = bundleIdentifier.trimmed
        guard !bundleIdentifier.isEmpty else {
            throw AppStoreCatalogError.invalidBundleIdentifier
        }
        try await availability.ensureAvailable()

        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleIdentifier),
            URLQueryItem(name: "entity", value: "macSoftware"),
            URLQueryItem(name: "country", value: Self.normalizedStorefront(storefront)),
        ]
        guard let url = components?.url else {
            throw AppStoreCatalogError.invalidBundleIdentifier
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
            throw CancellationError()
        } catch {
            await availability.recordFailure(cooldown: cooldown)
            throw error
        }
        guard (200..<300).contains(response.statusCode) else {
            await availability.recordFailure(cooldown: cooldown)
            throw AppStoreCatalogError.unexpectedStatus(response.statusCode)
        }
        return try Self.parse(data, expectedBundleIdentifier: bundleIdentifier)
    }

    static func normalizedStorefront(_ value: String?) -> String {
        let candidate = value?.trimmed.lowercased() ?? ""
        guard candidate.count == 2,
              candidate.unicodeScalars.allSatisfy(CharacterSet.letters.contains) else {
            return "us"
        }
        return candidate
    }

    static func parse(
        _ data: Data,
        expectedBundleIdentifier: String
    ) throws -> AppStoreCatalogResolution {
        let response: CatalogResponse
        do {
            response = try JSONDecoder().decode(CatalogResponse.self, from: data)
        } catch {
            throw AppStoreCatalogError.malformedResponse
        }

        let matches = response.results.filter {
            $0.bundleIdentifier == expectedBundleIdentifier
                && $0.wrapperType.caseInsensitiveCompare("software") == .orderedSame
                && $0.kind.caseInsensitiveCompare("mac-software") == .orderedSame
        }
        guard !matches.isEmpty else { return .notFound }
        guard matches.count == 1, let match = matches.first else { return .ambiguous }
        guard let version = match.version.trimmed.nonEmpty else {
            throw AppStoreCatalogError.malformedResponse
        }
        guard let productURL = URL(string: match.productURL),
              productURL.scheme?.lowercased() == "https",
              productURL.user == nil,
              productURL.password == nil,
              productURL.port == nil,
              let host = productURL.host?.lowercased(),
              allowedProductHosts.contains(host) else {
            throw AppStoreCatalogError.invalidProductURL
        }

        return .matched(AppStoreCatalogEntry(
            bundleIdentifier: match.bundleIdentifier,
            version: ApplicationVersion(marketing: version),
            productURL: productURL,
            sellerName: match.sellerName?.trimmed.nonEmpty,
            releaseDate: parseDate(match.releaseDate),
            releaseNotes: match.releaseNotes?.trimmed.nonEmpty,
            downloadSize: match.fileSizeBytes?.value,
            averageUserRating: match.averageUserRating.flatMap { (0...5).contains($0) ? $0 : nil },
            userRatingCount: match.userRatingCount.flatMap { $0 >= 0 ? $0 : nil }
        ))
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value = value?.trimmed.nonEmpty else { return nil }
        return AppISO8601DateCodec.date(from: value)
    }

    private struct CatalogResponse: Decodable {
        let results: [CatalogResult]
    }

    private struct CatalogResult: Decodable {
        let bundleIdentifier: String
        let version: String
        let productURL: String
        let wrapperType: String
        let kind: String
        let sellerName: String?
        let releaseDate: String?
        let releaseNotes: String?
        let fileSizeBytes: LosslessInt64?
        let averageUserRating: Double?
        let userRatingCount: Int?

        private enum CodingKeys: String, CodingKey {
            case bundleIdentifier = "bundleId"
            case version
            case productURL = "trackViewUrl"
            case wrapperType
            case kind
            case sellerName
            case releaseDate = "currentVersionReleaseDate"
            case releaseNotes
            case fileSizeBytes
            case averageUserRating
            case userRatingCount
        }
    }

    private struct LosslessInt64: Decodable {
        let value: Int64

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int64.self) {
                self.value = value
                return
            }
            let string = try container.decode(String.self)
            guard let value = Int64(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an Int64 or its decimal string representation."
                )
            }
            self.value = value
        }
    }
}

actor AppStoreCatalogAvailabilityState {
    private var unavailableUntil: Date?

    func ensureAvailable(now: Date = Date()) throws {
        guard let unavailableUntil else { return }
        guard now >= unavailableUntil else {
            throw AppStoreCatalogError.temporarilyUnavailable
        }
        self.unavailableUntil = nil
    }

    func recordFailure(cooldown: TimeInterval, now: Date = Date()) {
        unavailableUntil = now.addingTimeInterval(max(0, cooldown))
    }
}
