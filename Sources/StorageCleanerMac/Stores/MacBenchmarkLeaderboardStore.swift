import Combine
import Foundation
import SystemConfiguration

enum MacBenchmarkLeaderboardLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded(Date)
    case failed(MacBenchmarkLeaderboardFailure)
}

enum MacBenchmarkLeaderboardUploadState: Equatable, Sendable {
    case idle
    case submitting
    case succeeded(entryID: String)
    case removing
    case removed
    case failed(MacBenchmarkLeaderboardFailure)
}

enum MacBenchmarkLeaderboardFailure: Equatable, Sendable {
    case notConfigured
    case offline
    case rateLimited
    case incompatibleResult
    case removalNotConfirmed
    case rejected
    case unavailable

    var message: String {
        switch self {
        case .notConfigured:
            L10n.text(
                "社区排行榜服务尚未配置，当前只显示本机性能测试。",
                "The community leaderboard service is not configured; local benchmarks remain available."
            )
        case .offline:
            L10n.text(
                "当前无法连接排行榜，请检查网络后重试。",
                "The leaderboard could not be reached. Check the network and try again."
            )
        case .rateLimited:
            L10n.text(
                "上传过于频繁，请稍后再试。",
                "Uploads are too frequent. Please try again shortly."
            )
        case .incompatibleResult:
            L10n.text(
                "这条结果与当前冻结的 Standard v6 榜单版本不一致，无法上传；本机历史仍会保留。",
                "This result does not match the frozen Standard v6 leaderboard contract and cannot be uploaded; local history is still retained."
            )
        case .removalNotConfirmed:
            L10n.text(
                "服务器未确认公开成绩已移除；本地关联已保留，请刷新后重试。",
                "The server did not confirm removal. The local link was kept; refresh and try again."
            )
        case .rejected:
            L10n.text(
                "服务器未接受这条成绩，请重新运行性能测试后再试。",
                "The server did not accept this result. Run the benchmark again and retry."
            )
        case .unavailable:
            L10n.text(
                "排行榜暂时不可用，本机性能测试和历史记录不受影响。",
                "The leaderboard is temporarily unavailable. Local benchmarks and history are unaffected."
            )
        }
    }
}

@MainActor
protocol MacBenchmarkLeaderboardIdentityProviding: AnyObject {
    func installationID() -> UUID
    func suggestedDisplayName() -> String
    func remember(displayName: String, entryID: String)
    func remember(
        displayName: String,
        submittedIdentity: MacBenchmarkLeaderboardSubmittedIdentity
    )
    func forgetSubmittedEntry()
    func lastSubmittedEntryID() -> String?
    func lastSubmittedIdentity() -> MacBenchmarkLeaderboardSubmittedIdentity?
}

struct MacBenchmarkLeaderboardSubmittedIdentity: Codable, Equatable, Sendable {
    let entryID: String
    let profile: BenchmarkProfile
    let workloadVersion: String

    /// v1 persisted only an entry ID. At that time the last genuinely public
    /// contract was Standard v4, so migration must not infer a future active
    /// workload from mutable constants.
    static func legacyV1(entryID: String) -> Self {
        Self(
            entryID: entryID,
            profile: .standard,
            workloadVersion: "mac-benchmark-standard-v4"
        )
    }

    var isValid: Bool {
        !entryID.isEmpty && !workloadVersion.isEmpty
    }
}

extension MacBenchmarkLeaderboardIdentityProviding {
    func remember(
        displayName: String,
        submittedIdentity: MacBenchmarkLeaderboardSubmittedIdentity
    ) {
        remember(displayName: displayName, entryID: submittedIdentity.entryID)
    }

    func lastSubmittedIdentity() -> MacBenchmarkLeaderboardSubmittedIdentity? {
        guard let entryID = lastSubmittedEntryID(), !entryID.isEmpty else {
            return nil
        }
        return .legacyV1(entryID: entryID)
    }
}

@MainActor
final class DefaultMacBenchmarkLeaderboardIdentityProvider:
    MacBenchmarkLeaderboardIdentityProviding
{
    private enum Key {
        static let installationID = "benchmarkLeaderboard.installationID.v1"
        static let displayName = "benchmarkLeaderboard.displayName.v1"
        static let entryID = "benchmarkLeaderboard.lastEntryID.v1"
        static let submittedIdentity =
            "benchmarkLeaderboard.lastSubmittedIdentity.v2"
    }

    private let defaults: UserDefaults
    private let computerNameProvider: () -> String?
    private let hostNameProvider: () -> String?

    init(
        defaults: UserDefaults = .standard,
        computerNameProvider: @escaping () -> String? = {
            SCDynamicStoreCopyComputerName(nil, nil) as String?
        },
        hostNameProvider: @escaping () -> String? = {
            Host.current().localizedName
        }
    ) {
        self.defaults = defaults
        self.computerNameProvider = computerNameProvider
        self.hostNameProvider = hostNameProvider
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

    func suggestedDisplayName() -> String {
        if let computerName = computerNameProvider() {
            let normalized = MacBenchmarkLeaderboardText.normalized(computerName)
            if MacBenchmarkLeaderboardText.isValid(normalized) { return normalized }
        }
        if let hostName = hostNameProvider() {
            let normalized = MacBenchmarkLeaderboardText.normalized(hostName)
            if MacBenchmarkLeaderboardText.isValid(normalized) { return normalized }
        }
        if let saved = defaults.string(forKey: Key.displayName) {
            let normalized = MacBenchmarkLeaderboardText.normalized(saved)
            if MacBenchmarkLeaderboardText.isValid(normalized) { return normalized }
        }
        return L10n.text("我的 Mac", "My Mac")
    }

    func remember(displayName: String, entryID: String) {
        remember(
            displayName: displayName,
            submittedIdentity: .legacyV1(entryID: entryID)
        )
    }

    func remember(
        displayName: String,
        submittedIdentity: MacBenchmarkLeaderboardSubmittedIdentity
    ) {
        defaults.set(displayName, forKey: Key.displayName)
        defaults.set(submittedIdentity.entryID, forKey: Key.entryID)
        if let data = try? JSONEncoder().encode(submittedIdentity) {
            defaults.set(data, forKey: Key.submittedIdentity)
        }
    }

    func forgetSubmittedEntry() {
        defaults.removeObject(forKey: Key.entryID)
        defaults.removeObject(forKey: Key.submittedIdentity)
    }

    func lastSubmittedEntryID() -> String? {
        lastSubmittedIdentity()?.entryID
    }

    func lastSubmittedIdentity() -> MacBenchmarkLeaderboardSubmittedIdentity? {
        if let data = defaults.data(forKey: Key.submittedIdentity),
           let identity = try? JSONDecoder().decode(
               MacBenchmarkLeaderboardSubmittedIdentity.self,
               from: data
           ),
           identity.isValid {
            return identity
        }
        guard let entryID = defaults.string(forKey: Key.entryID),
              !entryID.isEmpty else {
            return nil
        }
        let migrated = MacBenchmarkLeaderboardSubmittedIdentity.legacyV1(
            entryID: entryID
        )
        if let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: Key.submittedIdentity)
        }
        return migrated
    }
}

@MainActor
final class MacBenchmarkLeaderboardStore: ObservableObject {
    @Published private(set) var entries: [MacBenchmarkLeaderboardEntry] = []
    @Published private(set) var loadState: MacBenchmarkLeaderboardLoadState = .idle
    @Published private(set) var uploadState: MacBenchmarkLeaderboardUploadState = .idle
    @Published private(set) var loadedProfile: BenchmarkProfile?
    @Published private(set) var totalEntryCount = 0
    @Published private(set) var lastSubmittedEntryID: String?

    private let service: any MacBenchmarkLeaderboardServicing
    private let identityProvider: any MacBenchmarkLeaderboardIdentityProviding
    private var submittedIdentity: MacBenchmarkLeaderboardSubmittedIdentity?
    private var loadGeneration: UUID?
    private var uploadGeneration: UUID?

    init(
        service: any MacBenchmarkLeaderboardServicing =
            MacBenchmarkLeaderboardService.production(),
        identityProvider: any MacBenchmarkLeaderboardIdentityProviding =
            DefaultMacBenchmarkLeaderboardIdentityProvider()
    ) {
        self.service = service
        self.identityProvider = identityProvider
        let submittedIdentity = identityProvider.lastSubmittedIdentity()
        self.submittedIdentity = submittedIdentity
        lastSubmittedEntryID = submittedIdentity?.entryID
    }

    var isConfigured: Bool { service.isConfigured }

    var automaticDisplayName: String {
        identityProvider.suggestedDisplayName()
    }

    func load(profile: BenchmarkProfile, force: Bool = false) async {
        if !force,
           loadedProfile == profile,
           case let .loaded(date) = loadState,
           Date().timeIntervalSince(date) < 60 {
            return
        }

        let generation = UUID()
        loadGeneration = generation
        if loadedProfile != profile {
            entries = []
            totalEntryCount = 0
        }
        loadedProfile = profile
        loadState = .loading

        do {
            let page = try await service.leaderboard(profile: profile)
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            let uniqueEntries = Self.deduplicated(page.data)
            entries = uniqueEntries
            totalEntryCount = max(
                uniqueEntries.count,
                page.pagination.total - (page.data.count - uniqueEntries.count)
            )
            loadState = .loaded(Date())
            loadGeneration = nil
        } catch is CancellationError {
            guard loadGeneration == generation else { return }
            loadGeneration = nil
            loadState = entries.isEmpty ? .idle : .loaded(Date())
        } catch {
            guard loadGeneration == generation else { return }
            loadGeneration = nil
            loadState = .failed(Self.failure(from: error, whileLoading: true))
        }
    }

    func uploadDraft(for result: MacBenchmarkResult) throws
        -> MacBenchmarkLeaderboardUploadDraft
    {
        try MacBenchmarkLeaderboardUploadDraft.make(
            result: result,
            installationID: identityProvider.installationID(),
            defaultDisplayName: identityProvider.suggestedDisplayName()
        )
    }

    func bestUploadDraft(
        in results: [MacBenchmarkResult]
    ) -> MacBenchmarkLeaderboardUploadDraft? {
        results.compactMap { try? uploadDraft(for: $0) }
            .max { $0.score < $1.score }
    }

    func canUpload(_ results: [MacBenchmarkResult]) -> Bool {
        service.isConfigured && bestUploadDraft(in: results) != nil
    }

    func submitBestAutomatically(_ results: [MacBenchmarkResult]) async {
        guard service.isConfigured,
              uploadState != .submitting,
              uploadState != .removing,
              let draft = bestUploadDraft(in: results)
        else { return }

        await submit(
            draft: draft,
            displayName: draft.defaultDisplayName
        )
    }

    func submit(
        draft: MacBenchmarkLeaderboardUploadDraft,
        displayName: String
    ) async {
        let submission: MacBenchmarkLeaderboardSubmission
        do {
            submission = try draft.submission(displayName: displayName)
        } catch {
            uploadState = .failed(.incompatibleResult)
            return
        }

        let generation = UUID()
        uploadGeneration = generation
        uploadState = .submitting
        do {
            let receipt = try await service.submit(submission)
            try Task.checkCancellation()
            guard uploadGeneration == generation else { return }
            let submittedIdentity = MacBenchmarkLeaderboardSubmittedIdentity(
                entryID: receipt.data.id,
                profile: draft.profile,
                workloadVersion: draft.workloadVersion
            )
            identityProvider.remember(
                displayName: receipt.data.displayName,
                submittedIdentity: submittedIdentity
            )
            self.submittedIdentity = submittedIdentity
            lastSubmittedEntryID = receipt.data.id
            uploadState = .succeeded(entryID: receipt.data.id)
            uploadGeneration = nil
            await load(profile: draft.profile, force: true)
        } catch is CancellationError {
            guard uploadGeneration == generation else { return }
            uploadGeneration = nil
            uploadState = .idle
        } catch {
            guard uploadGeneration == generation else { return }
            uploadGeneration = nil
            uploadState = .failed(Self.failure(from: error))
        }
    }

    func resetUploadState() {
        guard uploadState != .submitting, uploadState != .removing else { return }
        uploadState = .idle
    }

    func removeMyEntry(profile _: BenchmarkProfile) async {
        guard let submittedIdentity else {
            uploadState = .failed(.rejected)
            return
        }
        let generation = UUID()
        uploadGeneration = generation
        uploadState = .removing
        let removal = MacBenchmarkLeaderboardRemoval(
            installationId: identityProvider.installationID().uuidString.lowercased(),
            profile: submittedIdentity.profile,
            workloadVersion: submittedIdentity.workloadVersion
        )
        do {
            let receipt = try await service.remove(removal)
            guard receipt.data.deleted else {
                throw MacBenchmarkLeaderboardServiceError.removalNotConfirmed
            }
            try Task.checkCancellation()
            guard uploadGeneration == generation else { return }
            let removedEntryID = submittedIdentity.entryID
            identityProvider.forgetSubmittedEntry()
            self.submittedIdentity = nil
            lastSubmittedEntryID = nil
            entries.removeAll { $0.id == removedEntryID }
            totalEntryCount = max(0, totalEntryCount - 1)
            uploadState = .removed
            uploadGeneration = nil
            await load(profile: submittedIdentity.profile, force: true)
        } catch is CancellationError {
            guard uploadGeneration == generation else { return }
            uploadGeneration = nil
            uploadState = .idle
        } catch {
            guard uploadGeneration == generation else { return }
            uploadGeneration = nil
            uploadState = .failed(Self.failure(from: error))
        }
    }

    private static func failure(
        from error: Error,
        whileLoading: Bool = false
    ) -> MacBenchmarkLeaderboardFailure {
        guard let serviceError = error as? MacBenchmarkLeaderboardServiceError else {
            return .offline
        }
        return switch serviceError {
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
        case .rejected:
            whileLoading ? .unavailable : .rejected
        case .invalidEndpoint, .invalidResponse, .responseTooLarge, .unavailable:
            .unavailable
        }
    }

    /// The service is expected to upsert by its anonymous installation and
    /// protocol key. Keep the client defensive against a page containing the
    /// exact same visible submission more than once.
    private static func deduplicated(
        _ entries: [MacBenchmarkLeaderboardEntry]
    ) -> [MacBenchmarkLeaderboardEntry] {
        var seen = Set<String>()
        return entries.filter { entry in
            let key = [
                entry.id,
                entry.profile.rawValue,
                entry.workloadVersion,
                entry.displayName,
                entry.processorModel,
                String(entry.physicalMemoryBytes ?? 0),
                String(entry.systemDiskCapacityBytes ?? 0),
                String(entry.score),
                entry.completedAt.timeIntervalSinceReferenceDate.description,
            ].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }
}
