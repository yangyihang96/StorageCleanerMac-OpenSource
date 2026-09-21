import Foundation

enum MacBenchmarkLeaderboardServiceError: Error, Equatable, Sendable {
    case notConfigured
    case invalidEndpoint
    case invalidResponse
    case responseTooLarge
    case transport
    case rateLimited
    case incompatibleSourceVersion
    case removalNotConfirmed
    case rejected
    case unavailable
}

protocol MacBenchmarkLeaderboardServicing: Sendable {
    var isConfigured: Bool { get }
    func leaderboard(profile: BenchmarkProfile) async throws -> MacBenchmarkLeaderboardPage
    func submit(
        _ submission: MacBenchmarkLeaderboardSubmission
    ) async throws -> MacBenchmarkLeaderboardSubmissionReceipt
    func remove(_ removal: MacBenchmarkLeaderboardRemoval) async throws
        -> MacBenchmarkLeaderboardRemovalReceipt
}

protocol MacBenchmarkLeaderboardTransporting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionMacBenchmarkLeaderboardTransport: MacBenchmarkLeaderboardTransporting,
    @unchecked Sendable
{
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await BoundedHTTPSReader.data(for: request, session: session, maximumBytes: 512 * 1024)
    }
}

struct MacBenchmarkLeaderboardService: MacBenchmarkLeaderboardServicing, Sendable {
    static let maximumResponseBytes = 512 * 1_024

    let endpoint: URL
    private let transport: any MacBenchmarkLeaderboardTransporting

    init(
        endpoint: URL,
        transport: any MacBenchmarkLeaderboardTransporting =
            URLSessionMacBenchmarkLeaderboardTransport()
    ) throws {
        guard Self.isAllowedEndpoint(endpoint) else {
            throw MacBenchmarkLeaderboardServiceError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.transport = transport
    }

    var isConfigured: Bool { true }

    func leaderboard(profile: BenchmarkProfile) async throws -> MacBenchmarkLeaderboardPage {
        guard profile == .standard else {
            throw MacBenchmarkLeaderboardServiceError.rejected
        }
        let workloadVersion = MacBenchmarkLeaderboardConstants.workloadVersion(for: profile)
        guard var components = URLComponents(
            url: endpoint.appendingPathComponent("v1/leaderboard"),
            resolvingAgainstBaseURL: false
        ) else {
            throw MacBenchmarkLeaderboardServiceError.invalidEndpoint
        }
        components.queryItems = [
            URLQueryItem(name: "profile", value: profile.rawValue),
            URLQueryItem(name: "workloadVersion", value: workloadVersion),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(
                name: "pageSize",
                value: String(MacBenchmarkLeaderboardConstants.pageSize)
            ),
        ]
        guard let url = components.url else {
            throw MacBenchmarkLeaderboardServiceError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request)
        try validateSuccessResponse(response, data: data, acceptedStatuses: 200...200)
        let page: MacBenchmarkLeaderboardPage
        do {
            page = try JSONDecoder().decode(MacBenchmarkLeaderboardPage.self, from: data)
        } catch {
            throw MacBenchmarkLeaderboardServiceError.invalidResponse
        }
        guard page.meta.baselineVersion
                == MacBenchmarkLeaderboardConstants.baselineVersion(for: profile),
              page.meta.profile == profile,
              page.meta.workloadVersion == workloadVersion,
              page.pagination.page == 1,
              page.pagination.pageSize == MacBenchmarkLeaderboardConstants.pageSize,
              page.pagination.total >= page.data.count,
              page.data.count <= MacBenchmarkLeaderboardConstants.pageSize,
              page.data.allSatisfy({ entry in
                  Self.isValid(entry, profile: profile, workloadVersion: workloadVersion)
              }) else {
            throw MacBenchmarkLeaderboardServiceError.invalidResponse
        }
        return page
    }

    func submit(
        _ submission: MacBenchmarkLeaderboardSubmission
    ) async throws -> MacBenchmarkLeaderboardSubmissionReceipt {
        guard submission.profile == .standard,
              submission.workloadVersion
                == MacBenchmarkLeaderboardConstants.standardWorkloadVersion,
              submission.baselineVersion
                == MacBenchmarkLeaderboardConstants.activeBaselineVersion,
              submission.metrics.physicalMemoryBytes.map({ $0 > 0 }) == true,
              submission.metrics.systemDiskCapacityBytes.map({ $0 > 0 }) == true
        else {
            throw MacBenchmarkLeaderboardServiceError.rejected
        }
        let url = endpoint.appendingPathComponent("v1/submissions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(submission)
        } catch {
            throw MacBenchmarkLeaderboardServiceError.rejected
        }

        let (data, response) = try await send(request)
        try validateSuccessResponse(response, data: data, acceptedStatuses: 200...201)
        let receipt: MacBenchmarkLeaderboardSubmissionReceipt
        do {
            receipt = try JSONDecoder().decode(
                MacBenchmarkLeaderboardSubmissionReceipt.self,
                from: data
            )
        } catch {
            throw MacBenchmarkLeaderboardServiceError.invalidResponse
        }
        let expectedWorkload = MacBenchmarkLeaderboardConstants.workloadVersion(
            for: submission.profile
        )
        guard Self.isValid(
            receipt.data,
            profile: submission.profile,
            workloadVersion: expectedWorkload
        ), receipt.data.displayName == submission.displayName,
           receipt.data.processorModel == submission.processorModel,
           receipt.data.physicalMemoryBytes
            == submission.metrics.physicalMemoryBytes,
           receipt.data.systemDiskCapacityBytes
            == submission.metrics.systemDiskCapacityBytes,
           abs(receipt.data.score - submission.proposedScore) <= 1,
           receipt.disposition == "created" || receipt.disposition == "updated" else {
            throw MacBenchmarkLeaderboardServiceError.invalidResponse
        }
        return receipt
    }

    func remove(_ removal: MacBenchmarkLeaderboardRemoval) async throws
        -> MacBenchmarkLeaderboardRemovalReceipt
    {
        let url = endpoint.appendingPathComponent("v1/submissions")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(removal)
        } catch {
            throw MacBenchmarkLeaderboardServiceError.rejected
        }

        let (data, response) = try await send(request)
        try validateSuccessResponse(response, data: data, acceptedStatuses: 200...200)
        do {
            let receipt = try JSONDecoder().decode(
                MacBenchmarkLeaderboardRemovalReceipt.self,
                from: data
            )
            guard receipt.data.deleted else {
                throw MacBenchmarkLeaderboardServiceError.removalNotConfirmed
            }
            return receipt
        } catch let error as MacBenchmarkLeaderboardServiceError {
            throw error
        } catch {
            throw MacBenchmarkLeaderboardServiceError.invalidResponse
        }
    }

    static func production(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any MacBenchmarkLeaderboardServicing {
        guard let endpoint = MacBenchmarkLeaderboardEndpointConfiguration.endpointURL(
            bundle: bundle,
            environment: environment
        ), let service = try? Self(endpoint: endpoint) else {
            return UnavailableMacBenchmarkLeaderboardService()
        }
        return service
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport.data(for: request)
            try Task.checkCancellation()
            guard data.count <= Self.maximumResponseBytes else {
                throw MacBenchmarkLeaderboardServiceError.responseTooLarge
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  let responseURL = httpResponse.url,
                  Self.sameOrigin(endpoint, responseURL) else {
                throw MacBenchmarkLeaderboardServiceError.invalidResponse
            }
            return (data, httpResponse)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MacBenchmarkLeaderboardServiceError {
            throw error
        } catch {
            throw MacBenchmarkLeaderboardServiceError.transport
        }
    }

    private func validateSuccessResponse(
        _ response: HTTPURLResponse,
        data: Data,
        acceptedStatuses: ClosedRange<Int>
    ) throws {
        guard response.value(forHTTPHeaderField: "X-Leaderboard-Schema")
                == String(MacBenchmarkLeaderboardConstants.schemaVersion) else {
            throw MacBenchmarkLeaderboardServiceError.invalidResponse
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""
        guard contentType.hasPrefix("application/json") else {
            throw MacBenchmarkLeaderboardServiceError.invalidResponse
        }
        guard acceptedStatuses.contains(response.statusCode) else {
            throw Self.serviceError(status: response.statusCode, data: data)
        }
    }

    private static func isValid(
        _ entry: MacBenchmarkLeaderboardEntry,
        profile: BenchmarkProfile,
        workloadVersion: String
    ) -> Bool {
        entry.id.utf8.count == 32
            && entry.id.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
            && entry.rank > 0
            && MacBenchmarkLeaderboardText.isValid(entry.displayName)
            && !entry.processorModel.isEmpty
            && entry.processorModel.count
                <= MacBenchmarkLeaderboardText.maximumProcessorCharacters
            && entry.processorModel.utf8.count
                <= MacBenchmarkLeaderboardText.maximumProcessorBytes
            && entry.score.isFinite
            && entry.score > 0
            && entry.score <= 30_000
            && entry.profile == profile
            && entry.workloadVersion == workloadVersion
            && entry.physicalMemoryBytes.map({ $0 > 0 }) == true
            && entry.systemDiskCapacityBytes.map({ $0 > 0 }) == true
            && entry.completedAt.timeIntervalSinceReferenceDate.isFinite
    }

    private static func serviceError(status: Int, data: Data) -> Error {
        let code = (try? JSONDecoder().decode(
            MacBenchmarkLeaderboardErrorEnvelope.self,
            from: data
        ))?.error.code
        return switch (status, code) {
        case (429, _), (_, "rate_limited"):
            MacBenchmarkLeaderboardServiceError.rateLimited
        case (_, "incompatible_source_version"):
            MacBenchmarkLeaderboardServiceError.incompatibleSourceVersion
        case (400..<500, _):
            MacBenchmarkLeaderboardServiceError.rejected
        default:
            MacBenchmarkLeaderboardServiceError.unavailable
        }
    }

    private static func isAllowedEndpoint(_ url: URL) -> Bool {
        guard url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else { return false }
        if url.scheme?.lowercased() == "https" { return true }
#if DEBUG
        if url.scheme?.lowercased() == "http",
           url.host == "127.0.0.1" || url.host == "localhost" {
            return true
        }
#endif
        return false
    }

    private static func sameOrigin(_ endpoint: URL, _ responseURL: URL) -> Bool {
        endpoint.scheme?.lowercased() == responseURL.scheme?.lowercased()
            && endpoint.host?.lowercased() == responseURL.host?.lowercased()
            && effectivePort(endpoint) == effectivePort(responseURL)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

struct UnavailableMacBenchmarkLeaderboardService: MacBenchmarkLeaderboardServicing {
    var isConfigured: Bool { false }

    func leaderboard(profile _: BenchmarkProfile) async throws -> MacBenchmarkLeaderboardPage {
        throw MacBenchmarkLeaderboardServiceError.notConfigured
    }

    func submit(
        _: MacBenchmarkLeaderboardSubmission
    ) async throws -> MacBenchmarkLeaderboardSubmissionReceipt {
        throw MacBenchmarkLeaderboardServiceError.notConfigured
    }

    func remove(_: MacBenchmarkLeaderboardRemoval) async throws
        -> MacBenchmarkLeaderboardRemovalReceipt
    {
        throw MacBenchmarkLeaderboardServiceError.notConfigured
    }
}

enum MacBenchmarkLeaderboardEndpointConfiguration {
    static let environmentKey = "STORAGE_CLEANER_LEADERBOARD_URL"
    static let infoDictionaryKey = "LeaderboardAPIURL"

    static func endpointURL(
        bundle: Bundle,
        environment: [String: String]
    ) -> URL? {
        let raw = environment[environmentKey]
            ?? bundle.object(forInfoDictionaryKey: infoDictionaryKey) as? String
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(string: trimmed)
    }
}

private struct MacBenchmarkLeaderboardErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let code: String
    }

    let error: APIError
}
