import Foundation

enum BenchmarkV7LeaderboardServiceError: Error, Equatable, Sendable {
    case notConfigured
    case invalidEndpoint
    case invalidResponse
    case responseTooLarge
    case transport
    case rateLimited
    case incompatibleSourceVersion
    case removalNotConfirmed
    case conflict
    case rejected
    case unavailable
}

protocol BenchmarkV7LeaderboardServicing: Sendable {
    var isConfigured: Bool { get }
    func leaderboard(page: Int, pageSize: Int) async throws -> BenchmarkV7LeaderboardPage
    func submit(
        _ submission: BenchmarkV7LeaderboardSubmission,
        expectedEntryID: String?
    ) async throws -> BenchmarkV7LeaderboardReceipt
    func remove(
        _ removal: BenchmarkV7LeaderboardRemoval
    ) async throws -> BenchmarkV7LeaderboardRemovalReceipt
}

extension BenchmarkV7LeaderboardServicing {
    func submit(
        _ submission: BenchmarkV7LeaderboardSubmission
    ) async throws -> BenchmarkV7LeaderboardReceipt {
        try await submit(submission, expectedEntryID: nil)
    }
}

struct BenchmarkV7LeaderboardService: BenchmarkV7LeaderboardServicing, Sendable {
    let endpoint: URL
    private let transport: any MacBenchmarkLeaderboardTransporting

    init(
        endpoint: URL,
        transport: any MacBenchmarkLeaderboardTransporting =
            URLSessionMacBenchmarkLeaderboardTransport()
    ) throws {
        guard Self.isAllowedEndpoint(endpoint) else {
            throw BenchmarkV7LeaderboardServiceError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.transport = transport
    }

    var isConfigured: Bool { true }

    func leaderboard(
        page: Int,
        pageSize: Int = BenchmarkV7LeaderboardConstants.pageSize
    ) async throws -> BenchmarkV7LeaderboardPage {
        guard (1...10_000).contains(page),
              pageSize == BenchmarkV7LeaderboardConstants.pageSize,
              var components = URLComponents(
                  url: endpoint.appendingPathComponent("v2/leaderboard"),
                  resolvingAgainstBaseURL: false
              ) else {
            throw BenchmarkV7LeaderboardServiceError.rejected
        }
        let versions = BenchmarkV7LeaderboardConstants.currentVersions
        components.queryItems = [
            URLQueryItem(name: "workloadVersion", value: versions.workloadVersion),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ]
        guard let url = components.url else {
            throw BenchmarkV7LeaderboardServiceError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request)
        try validateResponse(response, data: data, acceptedStatuses: 200...200)
        guard Self.hasExactPageShape(data) else {
            throw BenchmarkV7LeaderboardServiceError.invalidResponse
        }
        let result: BenchmarkV7LeaderboardPage
        do {
            result = try JSONDecoder().decode(BenchmarkV7LeaderboardPage.self, from: data)
        } catch {
            throw BenchmarkV7LeaderboardServiceError.invalidResponse
        }
        guard Self.isValid(result, requestedPage: page, pageSize: pageSize) else {
            throw BenchmarkV7LeaderboardServiceError.invalidResponse
        }
        return result
    }

    func submit(
        _ submission: BenchmarkV7LeaderboardSubmission,
        expectedEntryID: String? = nil
    ) async throws -> BenchmarkV7LeaderboardReceipt {
        guard Self.isValid(submission),
              expectedEntryID.map(Self.isValidEntryID) ?? true else {
            throw BenchmarkV7LeaderboardServiceError.rejected
        }
        var request = URLRequest(
            url: endpoint.appendingPathComponent("v2/submissions")
        )
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(submission)
        } catch {
            throw BenchmarkV7LeaderboardServiceError.rejected
        }

        let (data, response) = try await send(request)
        try validateResponse(response, data: data, acceptedStatuses: 200...201)
        guard Self.hasExactReceiptShape(data) else {
            throw BenchmarkV7LeaderboardServiceError.invalidResponse
        }
        let receipt: BenchmarkV7LeaderboardReceipt
        do {
            receipt = try JSONDecoder().decode(BenchmarkV7LeaderboardReceipt.self, from: data)
        } catch {
            throw BenchmarkV7LeaderboardServiceError.invalidResponse
        }
        guard Self.hasCurrentContract(
            planVersion: receipt.meta.planVersion,
            workloadVersion: receipt.meta.workloadVersion,
            scoringVersion: receipt.meta.scoringVersion,
            referenceSetVersion: receipt.meta.referenceSetVersion
        ), Self.isValid(receipt.data),
           Self.isValid(
               receipt,
               for: submission,
               expectedEntryID: expectedEntryID
           ) else {
            throw BenchmarkV7LeaderboardServiceError.invalidResponse
        }
        return receipt
    }

    func remove(
        _ removal: BenchmarkV7LeaderboardRemoval
    ) async throws -> BenchmarkV7LeaderboardRemovalReceipt {
        guard UUID(uuidString: removal.installationId) != nil,
              removal.workloadVersion
                == BenchmarkV7LeaderboardConstants.currentVersions.workloadVersion else {
            throw BenchmarkV7LeaderboardServiceError.rejected
        }
        var request = URLRequest(
            url: endpoint.appendingPathComponent("v2/submissions")
        )
        request.httpMethod = "DELETE"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(removal)
        } catch {
            throw BenchmarkV7LeaderboardServiceError.rejected
        }

        let (data, response) = try await send(request)
        try validateResponse(response, data: data, acceptedStatuses: 200...200)
        guard Self.hasExactRemovalReceiptShape(data) else {
            throw BenchmarkV7LeaderboardServiceError.invalidResponse
        }
        let receipt: BenchmarkV7LeaderboardRemovalReceipt
        do {
            receipt = try JSONDecoder().decode(
                BenchmarkV7LeaderboardRemovalReceipt.self,
                from: data
            )
        } catch {
            throw BenchmarkV7LeaderboardServiceError.invalidResponse
        }
        guard receipt.data.deleted,
              Self.hasCurrentContract(
                  planVersion: receipt.meta.planVersion,
                  workloadVersion: receipt.meta.workloadVersion,
                  scoringVersion: receipt.meta.scoringVersion,
                  referenceSetVersion: receipt.meta.referenceSetVersion
              ) else {
            throw BenchmarkV7LeaderboardServiceError.removalNotConfirmed
        }
        return receipt
    }

    static func production(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any BenchmarkV7LeaderboardServicing {
        guard let endpoint = MacBenchmarkLeaderboardEndpointConfiguration.endpointURL(
            bundle: bundle,
            environment: environment
        ), let service = try? Self(endpoint: endpoint) else {
            return UnavailableBenchmarkV7LeaderboardService()
        }
        return service
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport.data(for: request)
            try Task.checkCancellation()
            guard data.count <= BenchmarkV7LeaderboardConstants.maximumResponseBytes else {
                throw BenchmarkV7LeaderboardServiceError.responseTooLarge
            }
            guard let response = response as? HTTPURLResponse,
                  let responseURL = response.url,
                  Self.sameOrigin(endpoint, responseURL) else {
                throw BenchmarkV7LeaderboardServiceError.invalidResponse
            }
            return (data, response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BenchmarkV7LeaderboardServiceError {
            throw error
        } catch {
            throw BenchmarkV7LeaderboardServiceError.transport
        }
    }

    private func validateResponse(
        _ response: HTTPURLResponse,
        data: Data,
        acceptedStatuses: ClosedRange<Int>
    ) throws {
        let mediaType = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard response.value(forHTTPHeaderField: "X-Leaderboard-Schema")
                == String(BenchmarkV7LeaderboardConstants.schemaVersion),
              mediaType == "application/json" else {
            throw BenchmarkV7LeaderboardServiceError.invalidResponse
        }
        guard acceptedStatuses.contains(response.statusCode) else {
            throw Self.serviceError(status: response.statusCode, data: data)
        }
    }

    private static func isValid(
        _ page: BenchmarkV7LeaderboardPage,
        requestedPage: Int,
        pageSize: Int
    ) -> Bool {
        guard hasCurrentContract(page.meta),
              page.pagination.page == requestedPage,
              page.pagination.pageSize == pageSize,
              page.pagination.total >= 0,
              page.pagination.totalPages
                == (page.pagination.total == 0
                    ? 0
                    : (page.pagination.total + pageSize - 1) / pageSize),
              page.data.count <= pageSize,
              page.pagination.total >= page.data.count else {
            return false
        }
        let firstRank = (requestedPage - 1) * pageSize + 1
        var ids = Set<String>()
        for (offset, entry) in page.data.enumerated() {
            guard isValid(entry),
                  entry.rank == firstRank + offset,
                  ids.insert(entry.id).inserted else {
                return false
            }
        }
        return true
    }

    private static func isValid(_ entry: BenchmarkV7LeaderboardEntry) -> Bool {
        isValidEntryID(entry.id)
            && entry.rank > 0
            && BenchmarkV7LeaderboardText.isValid(
                entry.displayName,
                maximumCharacters: 40,
                maximumBytes: 120
            )
            && BenchmarkV7LeaderboardText.isValid(
                entry.computerModel,
                maximumCharacters: 80,
                maximumBytes: 240
            )
            && BenchmarkV7LeaderboardText.isValid(
                entry.processorModel,
                maximumCharacters: 80,
                maximumBytes: 240
            )
            && (1...2_048).contains(entry.memoryGB)
            && entry.score.isFinite
            && entry.score > 0
            && entry.score <= 1_000_000
            && entry.workloadVersion
                == BenchmarkV7LeaderboardConstants.currentVersions.workloadVersion
            && BenchmarkV7LeaderboardDateCodec.isValidCompletedOn(entry.completedOn)
    }

    private static func isValid(
        _ receipt: BenchmarkV7LeaderboardReceipt,
        for submission: BenchmarkV7LeaderboardSubmission,
        expectedEntryID: String?
    ) -> Bool {
        guard receipt.data.workloadVersion == submission.workloadVersion else {
            return false
        }
        switch receipt.disposition {
        case .unchanged:
            return expectedEntryID.map { receipt.data.id == $0 } ?? true
        case .created, .updated:
            return receipt.data.displayName == submission.displayName
                && receipt.data.computerModel == submission.computerModel
                && receipt.data.processorModel == submission.processorModel
                && receipt.data.memoryGB == submission.memoryGB
                && receipt.data.completedOn == completedOn(from: submission.completedAt)
                && abs(receipt.data.score - submission.proposedScore) <= 1
        }
    }

    private static func isValidEntryID(_ entryID: String) -> Bool {
        entryID.utf8.count == 32
            && entryID.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }

    private static func isValid(_ submission: BenchmarkV7LeaderboardSubmission) -> Bool {
        let versions = BenchmarkV7LeaderboardConstants.currentVersions
        return UUID(uuidString: submission.submissionId) != nil
            && UUID(uuidString: submission.installationId) != nil
            && BenchmarkV7LeaderboardText.isValid(
                submission.displayName,
                maximumCharacters: 40,
                maximumBytes: 120
            )
            && BenchmarkV7LeaderboardText.isValid(
                submission.computerModel,
                maximumCharacters: 80,
                maximumBytes: 240
            )
            && BenchmarkV7LeaderboardText.isValid(
                submission.processorModel,
                maximumCharacters: 80,
                maximumBytes: 240
            )
            && (1...2_048).contains(submission.memoryGB)
            && submission.architecture == BenchmarkArchitecture.arm64.rawValue
            && submission.planVersion == versions.planVersion
            && submission.workloadVersion == versions.workloadVersion
            && submission.scoringVersion == versions.scoringVersion
            && submission.referenceSetVersion == versions.referenceSetVersion
            && MacBenchmarkLeaderboardDateCodec.date(from: submission.completedAt) != nil
            && !submission.appVersion.isEmpty
            && (8...20).contains(submission.appBuild.count)
            && submission.appBuild.allSatisfy(\.isNumber)
            && submission.conditions.powerSource == BenchmarkPowerSource.acPower.rawValue
            && !submission.conditions.lowPowerModeEnabled
            && submission.conditions.thermalState == BenchmarkThermalState.nominal.rawValue
            && (submission.conditions.confidence
                == BenchmarkV7ConfidenceRating.high.rawValue
                || submission.conditions.confidence
                    == BenchmarkV7ConfidenceRating.medium.rawValue
                || submission.conditions.confidence
                    == BenchmarkV7ConfidenceRating.low.rawValue)
            && submission.conditions.sustainedReachedTargetDuration
            && Set(submission.metrics.keys)
                == Set(BenchmarkV7LeaderboardConstants.requiredCoreMetricIDs)
            && submission.metrics.values.allSatisfy { $0.isFinite && $0 > 0 }
            && submission.proposedScore.isFinite
            && submission.proposedScore > 0
    }

    private static func hasCurrentContract(_ metadata: BenchmarkV7LeaderboardMetadata) -> Bool {
        metadata.generatedAt.timeIntervalSinceReferenceDate.isFinite
            && hasCurrentContract(
                planVersion: metadata.planVersion,
                workloadVersion: metadata.workloadVersion,
                scoringVersion: metadata.scoringVersion,
                referenceSetVersion: metadata.referenceSetVersion
            )
    }

    private static func hasCurrentContract(
        planVersion: String,
        workloadVersion: String,
        scoringVersion: String,
        referenceSetVersion: String
    ) -> Bool {
        let versions = BenchmarkV7LeaderboardConstants.currentVersions
        return planVersion == versions.planVersion
            && workloadVersion == versions.workloadVersion
            && scoringVersion == versions.scoringVersion
            && referenceSetVersion == versions.referenceSetVersion
    }

    private static func completedOn(from completedAt: String) -> String? {
        MacBenchmarkLeaderboardDateCodec.date(from: completedAt)
            .map(BenchmarkV7LeaderboardDateCodec.completedOn)
    }

    private static func hasExactPageShape(_ data: Data) -> Bool {
        guard let root = jsonObject(data),
              hasExactKeys(root, ["data", "pagination", "meta"]),
              let entries = root["data"] as? [[String: Any]],
              entries.allSatisfy({ hasExactKeys($0, entryFields) }),
              let pagination = root["pagination"] as? [String: Any],
              hasExactKeys(pagination, ["page", "pageSize", "total", "totalPages"]),
              let metadata = root["meta"] as? [String: Any],
              hasExactKeys(metadata, [
                  "generatedAt", "planVersion", "workloadVersion",
                  "scoringVersion", "referenceSetVersion",
              ]) else {
            return false
        }
        return true
    }

    private static func hasExactReceiptShape(_ data: Data) -> Bool {
        guard let root = jsonObject(data),
              hasExactKeys(root, ["data", "disposition", "meta"]),
              let entry = root["data"] as? [String: Any],
              hasExactKeys(entry, entryFields),
              let metadata = root["meta"] as? [String: Any],
              hasExactKeys(metadata, [
                  "submittedAt", "planVersion", "workloadVersion",
                  "scoringVersion", "referenceSetVersion",
              ]) else {
            return false
        }
        return true
    }

    private static func hasExactRemovalReceiptShape(_ data: Data) -> Bool {
        guard let root = jsonObject(data),
              hasExactKeys(root, ["data", "meta"]),
              let payload = root["data"] as? [String: Any],
              hasExactKeys(payload, ["deleted"]),
              let metadata = root["meta"] as? [String: Any],
              hasExactKeys(metadata, [
                  "deletedAt", "planVersion", "workloadVersion",
                  "scoringVersion", "referenceSetVersion",
              ]) else {
            return false
        }
        return true
    }

    private static let entryFields = [
        "id", "rank", "displayName", "computerModel", "processorModel",
        "memoryGB", "score", "workloadVersion", "completedOn", "confidence",
    ]

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func hasExactKeys(
        _ object: [String: Any],
        _ expected: [String]
    ) -> Bool {
        Set(object.keys) == Set(expected)
    }

    private static func serviceError(status: Int, data: Data) -> Error {
        let code = (try? JSONDecoder().decode(
            BenchmarkV7LeaderboardErrorEnvelope.self,
            from: data
        ))?.error.code
        return switch (status, code) {
        case (429, _), (_, "rate_limited"):
            BenchmarkV7LeaderboardServiceError.rateLimited
        case (_, "incompatible_source_version"):
            BenchmarkV7LeaderboardServiceError.incompatibleSourceVersion
        case (409, _), (_, "submission_id_conflict"), (_, "submission_in_progress"):
            BenchmarkV7LeaderboardServiceError.conflict
        case (404, _), (_, "submission_not_found"):
            BenchmarkV7LeaderboardServiceError.removalNotConfirmed
        case (400..<500, _):
            BenchmarkV7LeaderboardServiceError.rejected
        default:
            BenchmarkV7LeaderboardServiceError.unavailable
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
        return switch url.scheme?.lowercased() {
        case "https": 443
        case "http": 80
        default: nil
        }
    }
}

struct UnavailableBenchmarkV7LeaderboardService: BenchmarkV7LeaderboardServicing {
    var isConfigured: Bool { false }

    func leaderboard(page _: Int, pageSize _: Int) async throws
        -> BenchmarkV7LeaderboardPage
    {
        throw BenchmarkV7LeaderboardServiceError.notConfigured
    }

    func submit(
        _: BenchmarkV7LeaderboardSubmission,
        expectedEntryID _: String?
    ) async throws
        -> BenchmarkV7LeaderboardReceipt
    {
        throw BenchmarkV7LeaderboardServiceError.notConfigured
    }

    func remove(_: BenchmarkV7LeaderboardRemoval) async throws
        -> BenchmarkV7LeaderboardRemovalReceipt
    {
        throw BenchmarkV7LeaderboardServiceError.notConfigured
    }
}

private struct BenchmarkV7LeaderboardErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let code: String
    }

    let error: APIError
}
