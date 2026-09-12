import Darwin
import Foundation

struct StartupScanContext: Sendable {
    var homeDirectory: URL
    var applicationDirectories: [URL]
    var seedCandidates: [StartupItemsDomain.Candidate]
    var currentUserID: uid_t
    var includeAppleSystemItems: Bool
    var includeBackgroundTaskDiagnostic: Bool
    var commandTimeout: TimeInterval

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil,
        seedCandidates: [StartupItemsDomain.Candidate] = [],
        currentUserID: uid_t = getuid(),
        includeAppleSystemItems: Bool = true,
        // `sfltool dumpbtm` can present an administrator authorization dialog on
        // current macOS releases. Keep it opt-in so simply opening the page is
        // always a silent, read-only scan.
        includeBackgroundTaskDiagnostic: Bool = false,
        commandTimeout: TimeInterval = 4
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        ]
        self.seedCandidates = seedCandidates
        self.currentUserID = currentUserID
        self.includeAppleSystemItems = includeAppleSystemItems
        self.includeBackgroundTaskDiagnostic = includeBackgroundTaskDiagnostic
        self.commandTimeout = max(0.1, commandTimeout)
    }
}

protocol StartupItemScanning: Sendable {
    var source: StartupItemsDomain.ScanSource { get }
    var coverageIdentifier: String { get }

    func scan(context: StartupScanContext) async throws -> [StartupItemsDomain.Candidate]
}

extension StartupItemScanning {
    var coverageIdentifier: String { source.rawValue }
}

struct StartupCommandResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
}

protocol StartupCommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> StartupCommandResult
}

private final class StartupCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

struct StructuredStartupCommandRunner: StartupCommandRunning {
    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> StartupCommandResult {
        let cancellation = StartupCommandCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let result = try Shell.run(
                    executable,
                    arguments,
                    timeout: timeout,
                    outputByteLimit: 16 * 1_024 * 1_024,
                    cancellationCheck: cancellation.isCancelled,
                    cleanupReaper: .shared,
                    cleanupWaitTimeout: 1
                )
                return StartupCommandResult(
                    terminationStatus: result.terminationStatus,
                    standardOutput: result.standardOutput,
                    standardError: result.standardError
                )
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }
}

struct StartupSourceCoverage: Hashable, Sendable {
    let source: StartupItemsDomain.ScanSource
    let identifier: String
    var discoveredCount: Int
    var errorDescription: String?
}

struct StartupCoverageReport: Hashable, Sendable {
    var sources: [StartupSourceCoverage]
    var countsBySource: [StartupItemsDomain.ScanSource: Int]
    var countsByKind: [StartupItemsDomain.ItemKind: Int]
    /// All raw scanner evidence, including embedded components that are not registered.
    var rawEvidenceCount: Int
    /// Raw evidence intentionally excluded from the visible startup-item set.
    var filteredEvidenceCount: Int
    /// Visible candidates before deduplication. This is the same population
    /// used to produce `candidatesAfterDeduplication`.
    var discoveredBeforeDeduplication: Int
    var candidatesAfterDeduplication: Int
    var groupedItemCount: Int
    /// Grouped, non-system items with at least medium-confidence application
    /// attribution. This intentionally excludes confirmed Apple/system items so
    /// the three grouped counters below form one explainable partition.
    var attributedItemCount: Int
    /// Grouped items confirmed as Apple or system protected by scan evidence.
    /// This is an item count; `appleSystemCount` below remains the legacy
    /// candidate/component count.
    var systemProtectedItemCount: Int
    /// Grouped items not confirmed as system protected whose owning application
    /// remains below medium confidence. These are the real third-party review
    /// population, rather than hundreds of known macOS launchd services.
    var unattributedThirdPartyCount: Int
    var openAtLoginCount: Int
    var runningCount: Int
    var appleSystemCount: Int
    /// `nil` means the modern Background Task Management diagnostic source
    /// was unavailable, restricted or disabled; zero is a real observed zero.
    var managedItemCount: Int?
    var managedItemCoverageAvailable: Bool
    var directlyManageableCount: Int
    var systemSettingsOnlyCount: Int
    var administratorRequiredCount: Int
    var orphanedCount: Int

    static let empty = StartupCoverageReport(
        sources: [],
        countsBySource: [:],
        countsByKind: [:],
        rawEvidenceCount: 0,
        filteredEvidenceCount: 0,
        discoveredBeforeDeduplication: 0,
        candidatesAfterDeduplication: 0,
        groupedItemCount: 0,
        attributedItemCount: 0,
        systemProtectedItemCount: 0,
        unattributedThirdPartyCount: 0,
        openAtLoginCount: 0,
        runningCount: 0,
        appleSystemCount: 0,
        managedItemCount: nil,
        managedItemCoverageAvailable: false,
        directlyManageableCount: 0,
        systemSettingsOnlyCount: 0,
        administratorRequiredCount: 0,
        orphanedCount: 0
    )
}

struct StartupScanResult: Sendable {
    let candidates: [StartupItemsDomain.Candidate]
    let items: [StartupItemsDomain.Item]
    let coverage: StartupCoverageReport
}

enum StartupScanPhase: String, Sendable {
    case loginItems
    case backgroundTasks
    case launchd
    case attribution
    case runtime
    case signatures
    case orphanDetection
    case completed
}

struct StartupScanProgress: Sendable {
    let phase: StartupScanPhase
    let discoveredCount: Int
    let message: String
}

typealias StartupScanProgressHandler = @Sendable (StartupScanProgress) async -> Void
