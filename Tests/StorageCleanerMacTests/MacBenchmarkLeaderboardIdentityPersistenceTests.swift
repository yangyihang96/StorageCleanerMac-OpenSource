import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacBenchmarkLeaderboardIdentityPersistenceTests: XCTestCase {
    private let legacyEntryIDKey = "benchmarkLeaderboard.lastEntryID.v1"
    private let submittedIdentityKey =
        "benchmarkLeaderboard.lastSubmittedIdentity.v2"

    @MainActor
    func testSubmittedIdentityRoundTripsAllRemovalContractFields() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = DefaultMacBenchmarkLeaderboardIdentityProvider(
            defaults: defaults
        )
        let identity = MacBenchmarkLeaderboardSubmittedIdentity(
            entryID: "11111111111111111111111111111111",
            profile: .full,
            workloadVersion: "mac-benchmark-full-v3"
        )

        provider.remember(
            displayName: "Removal Contract Mac",
            submittedIdentity: identity
        )

        let reloaded = DefaultMacBenchmarkLeaderboardIdentityProvider(
            defaults: defaults
        )
        XCTAssertEqual(reloaded.lastSubmittedIdentity(), identity)
        XCTAssertEqual(reloaded.lastSubmittedEntryID(), identity.entryID)
        XCTAssertEqual(
            defaults.string(forKey: legacyEntryIDKey),
            identity.entryID
        )
        XCTAssertNotNil(defaults.data(forKey: submittedIdentityKey))
    }

    @MainActor
    func testLegacyV1EntryMigratesToFrozenStandardV4Identity() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let entryID = "22222222222222222222222222222222"
        defaults.set(entryID, forKey: legacyEntryIDKey)
        let provider = DefaultMacBenchmarkLeaderboardIdentityProvider(
            defaults: defaults
        )

        XCTAssertEqual(
            provider.lastSubmittedIdentity(),
            MacBenchmarkLeaderboardSubmittedIdentity(
                entryID: entryID,
                profile: .standard,
                workloadVersion: "mac-benchmark-standard-v4"
            )
        )
        XCTAssertNotNil(defaults.data(forKey: submittedIdentityKey))
        XCTAssertEqual(provider.lastSubmittedEntryID(), entryID)
    }

    @MainActor
    func testRemovalUsesPersistedV4ContractAndClearsBothIdentityKeys() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = DefaultMacBenchmarkLeaderboardIdentityProvider(
            defaults: defaults
        )
        let identity = MacBenchmarkLeaderboardSubmittedIdentity(
            entryID: "33333333333333333333333333333333",
            profile: .standard,
            workloadVersion: "mac-benchmark-standard-v4"
        )
        provider.remember(displayName: "Public v4 Mac", submittedIdentity: identity)
        let service = RemovalRecordingLeaderboardService()
        let store = MacBenchmarkLeaderboardStore(
            service: service,
            identityProvider: provider
        )

        XCTAssertEqual(store.lastSubmittedEntryID, identity.entryID)
        // Simulate the UI being on another/current profile. Deletion must still
        // use the exact contract that created the persisted public entry.
        await store.removeMyEntry(profile: .quick)

        let capturedRemoval = await service.lastRemoval()
        let removal = try XCTUnwrap(capturedRemoval)
        XCTAssertEqual(removal.profile, .standard)
        XCTAssertEqual(removal.workloadVersion, "mac-benchmark-standard-v4")
        XCTAssertEqual(store.uploadState, .removed)
        XCTAssertEqual(store.loadedProfile, .standard)
        XCTAssertNil(store.lastSubmittedEntryID)
        XCTAssertNil(provider.lastSubmittedIdentity())
        XCTAssertNil(defaults.object(forKey: legacyEntryIDKey))
        XCTAssertNil(defaults.object(forKey: submittedIdentityKey))
    }

    @MainActor
    func testUnconfirmedRemovalKeepsExactIdentityForRetry() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = DefaultMacBenchmarkLeaderboardIdentityProvider(
            defaults: defaults
        )
        let identity = MacBenchmarkLeaderboardSubmittedIdentity(
            entryID: "44444444444444444444444444444444",
            profile: .standard,
            workloadVersion: "mac-benchmark-standard-v4"
        )
        provider.remember(displayName: "Retry v4 Mac", submittedIdentity: identity)
        let store = MacBenchmarkLeaderboardStore(
            service: RemovalRecordingLeaderboardService(deleted: false),
            identityProvider: provider
        )

        await store.removeMyEntry(profile: .standard)

        XCTAssertEqual(store.uploadState, .failed(.removalNotConfirmed))
        XCTAssertEqual(store.lastSubmittedEntryID, identity.entryID)
        XCTAssertEqual(provider.lastSubmittedIdentity(), identity)
        XCTAssertNotNil(defaults.object(forKey: legacyEntryIDKey))
        XCTAssertNotNil(defaults.object(forKey: submittedIdentityKey))
    }
}

private extension MacBenchmarkLeaderboardIdentityPersistenceTests {
    func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "MacBenchmarkLeaderboardIdentityPersistenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

private actor RemovalRecordingLeaderboardService:
    MacBenchmarkLeaderboardServicing
{
    nonisolated let isConfigured = true
    private var removal: MacBenchmarkLeaderboardRemoval?
    private let deleted: Bool

    init(deleted: Bool = true) {
        self.deleted = deleted
    }

    func leaderboard(profile: BenchmarkProfile) async throws
        -> MacBenchmarkLeaderboardPage
    {
        MacBenchmarkLeaderboardPage(
            data: [],
            pagination: MacBenchmarkLeaderboardPagination(
                page: 1,
                pageSize: MacBenchmarkLeaderboardConstants.pageSize,
                total: 0,
                totalPages: 0
            ),
            meta: MacBenchmarkLeaderboardMetadata(
                baselineVersion: MacBenchmarkLeaderboardConstants.baselineVersion(
                    for: profile
                ),
                profile: profile,
                workloadVersion: MacBenchmarkLeaderboardConstants.workloadVersion(
                    for: profile
                ),
                generatedAt: Date()
            )
        )
    }

    func submit(_: MacBenchmarkLeaderboardSubmission) async throws
        -> MacBenchmarkLeaderboardSubmissionReceipt
    {
        throw MacBenchmarkLeaderboardServiceError.unavailable
    }

    func remove(_ removal: MacBenchmarkLeaderboardRemoval) async throws
        -> MacBenchmarkLeaderboardRemovalReceipt
    {
        self.removal = removal
        return MacBenchmarkLeaderboardRemovalReceipt(
            data: .init(deleted: deleted)
        )
    }

    func lastRemoval() -> MacBenchmarkLeaderboardRemoval? { removal }
}
