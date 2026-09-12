import Combine
import Foundation

enum BenchmarkV7LeaderboardLoadState: Equatable, Sendable {
    case idle
    case loading
    case loadingMore
    case loaded(Date)
    case failed(BenchmarkV7LeaderboardFailure)
}

enum BenchmarkV7LeaderboardMutationState: Equatable, Sendable {
    case idle
    case submitting
    case submitted(entryID: String, disposition: BenchmarkV7LeaderboardDisposition)
    case removing
    case removed
    case failed(BenchmarkV7LeaderboardFailure)
}

enum BenchmarkV7LeaderboardFailure: Equatable, Sendable {
    case notConfigured
    case offline
    case rateLimited
    case incompatibleResult
    case removalNotConfirmed
    case conflict
    case rejected
    case unavailable

    var message: String {
        switch self {
        case .notConfigured:
            L10n.text(
                "全球排行榜服务尚未配置，本机性能测试不受影响。",
                "The global leaderboard is not configured. Local benchmarks remain available."
            )
        case .offline:
            L10n.text(
                "当前无法连接排行榜，请检查网络后重试。",
                "The leaderboard could not be reached. Check the network and try again."
            )
        case .rateLimited:
            L10n.text("操作过于频繁，请稍后再试。", "Too many requests. Please try again shortly.")
        case .incompatibleResult:
            L10n.text(
                "没有符合当前 V7 正式协议的可上传成绩。",
                "No result is eligible for the current official V7 leaderboard."
            )
        case .removalNotConfirmed:
            L10n.text(
                "服务器未确认公开成绩已移除，本地删除凭据已保留。",
                "The server did not confirm removal. The local removal credential was kept."
            )
        case .conflict:
            L10n.text(
                "这条提交记录与服务器已有记录冲突，请重新运行测试。",
                "This submission conflicts with an existing server record. Run the benchmark again."
            )
        case .rejected:
            L10n.text(
                "服务器未接受这项操作，请检查成绩后重试。",
                "The server rejected this operation. Check the result and try again."
            )
        case .unavailable:
            L10n.text(
                "排行榜暂时不可用，本机性能测试和历史记录不受影响。",
                "The leaderboard is temporarily unavailable. Local results are unaffected."
            )
        }
    }
}

struct BenchmarkV7LeaderboardSubmittedIdentity: Codable, Equatable, Sendable {
    let entryID: String
    let workloadVersion: String

    var isValid: Bool {
        entryID.utf8.count == 32
            && entryID.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
            && !workloadVersion.isEmpty
    }
}

@MainActor
protocol BenchmarkV7LeaderboardIdentityProviding: AnyObject {
    func installationID() -> UUID
    func anonymousDisplayName() -> String
    func remember(_ identity: BenchmarkV7LeaderboardSubmittedIdentity)
    func forgetSubmittedEntry()
    func lastSubmittedIdentity() -> BenchmarkV7LeaderboardSubmittedIdentity?
}

@MainActor
final class DefaultBenchmarkV7LeaderboardIdentityProvider:
    BenchmarkV7LeaderboardIdentityProviding
{
    private enum Key {
        static let installationID = "benchmarkV7Leaderboard.installationID.v1"
        static let displayName = "benchmarkV7Leaderboard.displayName.v1"
        static let submittedIdentity = "benchmarkV7Leaderboard.submittedIdentity.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func installationID() -> UUID {
        if let value = defaults.string(forKey: Key.installationID),
           let id = UUID(uuidString: value) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString.lowercased(), forKey: Key.installationID)
        return id
    }

    func anonymousDisplayName() -> String {
        if let saved = defaults.string(forKey: Key.displayName),
           BenchmarkV7LeaderboardText.isValid(
               saved,
               maximumCharacters: 40,
               maximumBytes: 120
           ) {
            return saved
        }
        let suffix = installationID().uuidString.prefix(4).uppercased()
        let name = L10n.text("匿名 Mac \(suffix)", "Anonymous Mac \(suffix)")
        defaults.set(name, forKey: Key.displayName)
        return name
    }

    func remember(_ identity: BenchmarkV7LeaderboardSubmittedIdentity) {
        guard identity.isValid,
              let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: Key.submittedIdentity)
    }

    func forgetSubmittedEntry() {
        defaults.removeObject(forKey: Key.submittedIdentity)
    }

    func lastSubmittedIdentity() -> BenchmarkV7LeaderboardSubmittedIdentity? {
        guard let data = defaults.data(forKey: Key.submittedIdentity),
              let identity = try? JSONDecoder().decode(
                  BenchmarkV7LeaderboardSubmittedIdentity.self,
                  from: data
              ), identity.isValid else {
            return nil
        }
        return identity
    }
}

@MainActor
final class BenchmarkV7LeaderboardStore: ObservableObject {
    @Published private(set) var entries: [BenchmarkV7LeaderboardEntry] = []
    @Published private(set) var total = 0
    @Published private(set) var generatedAt: Date?
    @Published private(set) var hasMore = false
    @Published private(set) var loadState: BenchmarkV7LeaderboardLoadState = .idle
    @Published private(set) var mutationState: BenchmarkV7LeaderboardMutationState = .idle
    @Published private(set) var lastSubmittedEntryID: String?

    private let service: any BenchmarkV7LeaderboardServicing
    private let identityProvider: any BenchmarkV7LeaderboardIdentityProviding
    private let now: () -> Date
    private var submittedIdentity: BenchmarkV7LeaderboardSubmittedIdentity?
    private var nextPage = 1
    private var lastSuccessfulFirstPageLoad: Date?
    private var loadGeneration: UUID?
    private var mutationGeneration: UUID?

    init(
        service: any BenchmarkV7LeaderboardServicing =
            BenchmarkV7LeaderboardService.production(),
        identityProvider: any BenchmarkV7LeaderboardIdentityProviding =
            DefaultBenchmarkV7LeaderboardIdentityProvider(),
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.identityProvider = identityProvider
        self.now = now
        let identity = identityProvider.lastSubmittedIdentity()
        submittedIdentity = identity
        lastSubmittedEntryID = identity?.entryID
    }

    var isConfigured: Bool { service.isConfigured }
    var anonymousDisplayName: String { identityProvider.anonymousDisplayName() }
    var hasSubmittedEntry: Bool { submittedIdentity != nil }

    func loadFirst(force: Bool = false) async {
        if !force,
           let loadedAt = lastSuccessfulFirstPageLoad,
           now().timeIntervalSince(loadedAt) < 60 {
            return
        }
        let generation = UUID()
        loadGeneration = generation
        loadState = .loading
        do {
            let page = try await service.leaderboard(
                page: 1,
                pageSize: BenchmarkV7LeaderboardConstants.pageSize
            )
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            entries = page.data
            total = page.pagination.total
            generatedAt = page.meta.generatedAt
            nextPage = 2
            hasMore = page.pagination.page < page.pagination.totalPages
            let loadedAt = now()
            lastSuccessfulFirstPageLoad = loadedAt
            loadState = .loaded(loadedAt)
            loadGeneration = nil
        } catch is CancellationError {
            guard loadGeneration == generation else { return }
            loadGeneration = nil
            loadState = lastSuccessfulFirstPageLoad.map(BenchmarkV7LeaderboardLoadState.loaded)
                ?? .idle
        } catch {
            guard loadGeneration == generation else { return }
            loadGeneration = nil
            loadState = .failed(Self.failure(from: error, whileLoading: true))
        }
    }

    func loadMore() async {
        guard hasMore else { return }
        switch loadState {
        case .loading, .loadingMore:
            return
        case .idle, .loaded, .failed:
            break
        }
        let requestedPage = nextPage
        let generation = UUID()
        loadGeneration = generation
        loadState = .loadingMore
        do {
            let page = try await service.leaderboard(
                page: requestedPage,
                pageSize: BenchmarkV7LeaderboardConstants.pageSize
            )
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            var knownIDs = Set(entries.map(\.id))
            entries.append(contentsOf: page.data.filter { knownIDs.insert($0.id).inserted })
            total = page.pagination.total
            generatedAt = page.meta.generatedAt
            nextPage = requestedPage + 1
            hasMore = page.pagination.page < page.pagination.totalPages
            loadState = .loaded(now())
            loadGeneration = nil
        } catch is CancellationError {
            guard loadGeneration == generation else { return }
            loadGeneration = nil
            loadState = lastSuccessfulFirstPageLoad.map(BenchmarkV7LeaderboardLoadState.loaded)
                ?? .idle
        } catch {
            guard loadGeneration == generation else { return }
            loadGeneration = nil
            loadState = .failed(Self.failure(from: error, whileLoading: true))
        }
    }

    func draft(for result: BenchmarkV7Result) throws -> BenchmarkV7LeaderboardDraft {
        try BenchmarkV7LeaderboardDraft.make(
            result: result,
            installationID: identityProvider.installationID(),
            displayName: identityProvider.anonymousDisplayName()
        )
    }

    func bestDraft(in results: [BenchmarkV7Result]) -> BenchmarkV7LeaderboardDraft? {
        results.compactMap { try? draft(for: $0) }
            .max { $0.score < $1.score }
    }

    func canSubmit(_ results: [BenchmarkV7Result]) -> Bool {
        service.isConfigured && bestDraft(in: results) != nil
    }

    /// Deliberately manual. UI must obtain explicit user consent before calling.
    func submitBest(_ results: [BenchmarkV7Result]) async {
        guard service.isConfigured,
              mutationState != .submitting,
              mutationState != .removing,
              let draft = bestDraft(in: results) else {
            if service.isConfigured {
                mutationState = .failed(.incompatibleResult)
            }
            return
        }

        let generation = UUID()
        mutationGeneration = generation
        mutationState = .submitting
        do {
            let expectedEntryID = submittedIdentity.flatMap { identity in
                identity.workloadVersion == draft.versions.workloadVersion
                    ? identity.entryID
                    : nil
            }
            let receipt = try await service.submit(
                draft.submission(),
                expectedEntryID: expectedEntryID
            )
            try Task.checkCancellation()
            guard mutationGeneration == generation else { return }
            let identity = BenchmarkV7LeaderboardSubmittedIdentity(
                entryID: receipt.data.id,
                workloadVersion: draft.versions.workloadVersion
            )
            identityProvider.remember(identity)
            submittedIdentity = identity
            lastSubmittedEntryID = identity.entryID
            mutationState = .submitted(
                entryID: identity.entryID,
                disposition: receipt.disposition
            )
            mutationGeneration = nil
            await loadFirst(force: true)
        } catch is CancellationError {
            guard mutationGeneration == generation else { return }
            mutationGeneration = nil
            mutationState = .idle
        } catch {
            guard mutationGeneration == generation else { return }
            mutationGeneration = nil
            mutationState = .failed(Self.failure(from: error))
        }
    }

    func removeMyEntry() async {
        guard let identity = submittedIdentity else {
            mutationState = .failed(.rejected)
            return
        }
        let generation = UUID()
        mutationGeneration = generation
        mutationState = .removing
        let removal = BenchmarkV7LeaderboardRemoval(
            installationId: identityProvider.installationID().uuidString.lowercased(),
            workloadVersion: identity.workloadVersion
        )
        do {
            _ = try await service.remove(removal)
            try Task.checkCancellation()
            guard mutationGeneration == generation else { return }
            identityProvider.forgetSubmittedEntry()
            submittedIdentity = nil
            lastSubmittedEntryID = nil
            entries.removeAll { $0.id == identity.entryID }
            total = max(0, total - 1)
            mutationState = .removed
            mutationGeneration = nil
            await loadFirst(force: true)
        } catch is CancellationError {
            guard mutationGeneration == generation else { return }
            mutationGeneration = nil
            mutationState = .idle
        } catch {
            guard mutationGeneration == generation else { return }
            mutationGeneration = nil
            mutationState = .failed(Self.failure(from: error))
        }
    }

    func resetMutationState() {
        guard mutationState != .submitting, mutationState != .removing else { return }
        mutationState = .idle
    }

    private static func failure(
        from error: Error,
        whileLoading: Bool = false
    ) -> BenchmarkV7LeaderboardFailure {
        guard let error = error as? BenchmarkV7LeaderboardServiceError else {
            return .offline
        }
        return switch error {
        case .notConfigured:
            .notConfigured
        case .transport:
            .offline
        case .rateLimited:
            .rateLimited
        case .incompatibleSourceVersion:
            whileLoading ? .unavailable : .incompatibleResult
        case .removalNotConfirmed:
            .removalNotConfirmed
        case .conflict:
            .conflict
        case .rejected:
            whileLoading ? .unavailable : .rejected
        case .invalidEndpoint, .invalidResponse, .responseTooLarge, .unavailable:
            .unavailable
        }
    }
}
