import Foundation

struct LastAppScanSummary: Hashable, Sendable {
    let completedAt: Date
    let scannedCount: Int
    let automaticCount: Int
    let requiresQuitCount: Int
    let requiresAuthorizationCount: Int
    let manualCount: Int
    let currentCount: Int
    let unknownCount: Int

    init(summary: AppScanSummary) {
        completedAt = summary.generatedAt
        scannedCount = summary.scannedCount
        automaticCount = summary.automaticCount
        requiresQuitCount = summary.requiresQuitCount
        requiresAuthorizationCount = summary.requiresAuthorizationCount
        manualCount = summary.manualCount
        currentCount = summary.currentCount
        unknownCount = summary.unknownCount
    }
}

enum AppScanStage: String, Hashable, Sendable {
    case discoveringApplications
    case readingMetadata
    case resolvingSources
    case checkingVersions
    case finishing
}

struct AppScanProgressSnapshot: Hashable, Sendable {
    let sessionID: UUID
    let generatedAt: Date
    let stage: AppScanStage
    let completedUnitCount: Int
    let totalUnitCount: Int?
    let currentApplicationID: String?
    let currentApplicationName: String?

    var progressFraction: Double? {
        guard let totalUnitCount, totalUnitCount > 0 else { return nil }
        return min(max(Double(completedUnitCount) / Double(totalUnitCount), 0), 1)
    }
}

enum AppScanCompletionState: Hashable, Sendable {
    case updatesAvailable
    case allCurrent
    case noConfirmedUpdates
}

struct AppScanSummary: Hashable, Sendable {
    let sessionID: UUID
    let generatedAt: Date
    let applications: [InstalledApplication]

    var scannedCount: Int { applications.count }
    var eligibleAutomaticApps: [InstalledApplication] {
        applications.filter { $0.appUpdatePresentationCategory == .automatic }
    }
    var requiresQuitApps: [InstalledApplication] {
        applications.filter { $0.appUpdatePresentationCategory == .requiresQuit }
    }
    var requiresAuthorizationApps: [InstalledApplication] {
        applications.filter { $0.appUpdatePresentationCategory == .requiresAuthorization }
    }
    var batchEligibleApps: [InstalledApplication] {
        eligibleAutomaticApps + requiresQuitApps
    }
    var automaticCount: Int { eligibleAutomaticApps.count }
    var requiresQuitCount: Int { requiresQuitApps.count }
    var requiresAuthorizationCount: Int { requiresAuthorizationApps.count }
    var manualCount: Int {
        applications.count { $0.appUpdateSummaryCategory == .manual }
    }
    var currentCount: Int {
        applications.count { $0.appUpdateSummaryCategory == .current }
    }
    var unknownCount: Int {
        applications.count { $0.appUpdateSummaryCategory == .unknown }
    }
    var systemManagedCount: Int {
        applications.count { $0.appUpdatePresentationCategory == .systemManaged }
    }
    var completionState: AppScanCompletionState {
        if applications.contains(where: \.hasConfirmedPresentableUpdate) {
            return .updatesAvailable
        }
        if currentCount > 0, manualCount == 0, unknownCount == 0 {
            return .allCurrent
        }
        return .noConfirmedUpdates
    }

    init(
        sessionID: UUID,
        generatedAt: Date = Date(),
        applications: [InstalledApplication]
    ) {
        self.sessionID = sessionID
        self.generatedAt = generatedAt
        self.applications = applications
    }
}

enum AppUpdateCatalogFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case automatic
    case requiresQuit
    case requiresAuthorization
    case manual
    case appStore
    case inApplication
    case website
    case unknown
}

enum AppUpdateCatalogCategory: String, Hashable, Sendable {
    case automatic
    case requiresQuit
    case requiresAuthorization
    case manual
    case appStore
    case inApplication
    case website
    case unknown
    case systemManaged
}

struct AppUpdateCatalogEntry: Identifiable, Hashable, Sendable {
    let application: InstalledApplication
    let category: AppUpdateCatalogCategory

    var id: String { application.id }
    var isUpdateAvailable: Bool { application.hasPresentableUpdate }
    var canJoinAutomaticUpdatePlan: Bool { application.canJoinAutomaticUpdatePlan }
    var canJoinAutomaticUpdateBatch: Bool { application.canJoinAutomaticUpdateBatch }
}

struct AppUpdateCatalogSnapshot: Hashable, Sendable {
    let sessionID: UUID
    let generatedAt: Date
    let entries: [AppUpdateCatalogEntry]

    init(
        sessionID: UUID,
        generatedAt: Date = Date(),
        applications: [InstalledApplication]
    ) {
        self.sessionID = sessionID
        self.generatedAt = generatedAt
        entries = applications.compactMap {
            guard $0.hasConfirmedPresentableUpdate
                || $0.hasActionableInApplicationPath else { return nil }
            return AppUpdateCatalogEntry(
                application: $0,
                category: $0.appUpdatePresentationCategory
            )
        }
    }

    init(summary: AppScanSummary) {
        self.init(
            sessionID: summary.sessionID,
            generatedAt: summary.generatedAt,
            applications: summary.applications
        )
    }

    func entries(matching filter: AppUpdateCatalogFilter) -> [AppUpdateCatalogEntry] {
        guard filter != .all else { return entries }
        return entries.filter { entry in
            switch filter {
            case .all: true
            case .automatic: entry.category == .automatic
            case .requiresQuit: entry.category == .requiresQuit
            case .requiresAuthorization: entry.category == .requiresAuthorization
            case .manual: entry.category == .manual
            case .appStore: entry.category == .appStore
            case .inApplication: entry.category == .inApplication
            case .website: entry.category == .website
            case .unknown: entry.category == .unknown
            }
        }
    }
}

struct FrozenUpdatePlan: Hashable, Sendable {
    let sessionID: UUID
    let createdAt: Date
    let plan: ApplicationUpdatePlan
    let executionPlan: ApplicationUpdatePlan
    let applications: [InstalledApplication]
    let automaticApplications: [InstalledApplication]

    init(
        applications: [InstalledApplication],
        sessionID: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        let built = ApplicationUpdatePlanBuilder().build(
            applications: applications,
            id: sessionID,
            createdAt: createdAt
        )
        let applicationsByID = Dictionary(
            applications.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        self.sessionID = sessionID
        self.createdAt = createdAt
        let executableApplicationIDs = built.automaticApplicationIDs
            + built.requiresQuitApplicationIDs
        automaticApplications = executableApplicationIDs.compactMap {
            applicationsByID[$0]
        }
        let allApplicationIDs = executableApplicationIDs
            + built.requiresAuthorizationApplicationIDs
            + built.appStoreApplicationIDs
            + built.websiteApplicationIDs
            + built.manualApplicationIDs
            + built.skippedApplicationIDs
        self.applications = allApplicationIDs.compactMap { applicationsByID[$0] }
        plan = built

        // There is no safe continuation for authorization, App Store, in-app,
        // or manual work in this queue. Keep those items visible as skipped
        // instead of dropping them or leaving an authorization task hanging.
        executionPlan = ApplicationUpdatePlan(
            id: sessionID,
            createdAt: createdAt,
            automaticApplicationIDs: built.automaticApplicationIDs,
            requiresQuitApplicationIDs: built.requiresQuitApplicationIDs,
            requiresAuthorizationApplicationIDs: [],
            appStoreApplicationIDs: [],
            websiteApplicationIDs: [],
            manualApplicationIDs: [],
            skippedApplicationIDs: built.requiresAuthorizationApplicationIDs
                + built.appStoreApplicationIDs
                + built.websiteApplicationIDs
                + built.manualApplicationIDs
                + built.skippedApplicationIDs
        )
    }
}

struct AppUpdateSessionItem: Identifiable, Hashable, Sendable {
    let task: ApplicationUpdateTask
    let application: InstalledApplication?

    var id: UUID { task.id }
    var applicationID: String { task.applicationID }
    var displayName: String { application?.displayName ?? task.applicationID }
}

struct AppUpdateSessionSnapshot: Hashable, Sendable {
    let queue: ApplicationUpdateQueueSnapshot
    let items: [AppUpdateSessionItem]
    let isCancellationRequested: Bool

    var sessionID: UUID { queue.plan.id }
    var generatedAt: Date { queue.updatedAt }
    var completedCount: Int { items.count { $0.task.state == .completed } }
    var failedCount: Int { items.count { $0.task.state == .failed } }
    var cancelledCount: Int { items.count { $0.task.state == .cancelled } }

    /// Measures processed work only. A provider's fractional contribution is
    /// included only when that provider emitted a real fraction.
    var processedFraction: Double? {
        guard !items.isEmpty else { return nil }
        let processed = items.reduce(0.0) { result, item in
            if item.task.state.isTerminal { return result + 1 }
            guard let fraction = item.task.progressFraction, fraction.isFinite else {
                return result
            }
            return result + min(max(fraction, 0), 1)
        }
        return processed / Double(items.count)
    }

    init(
        queue: ApplicationUpdateQueueSnapshot,
        applications: [InstalledApplication],
        isCancellationRequested: Bool = false
    ) {
        self.queue = queue
        self.isCancellationRequested = isCancellationRequested
        let applicationsByID = Dictionary(
            applications.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        items = queue.tasks.map {
            AppUpdateSessionItem(task: $0, application: applicationsByID[$0.applicationID])
        }
    }
}

enum AppUpdateReportOutcome: String, Hashable, Sendable {
    case allSucceeded
    case partialSuccess
    case allFailed
    case cancelled
    case noEligibleUpdates
    case requiresAction
}

struct AppUpdateReportItem: Identifiable, Hashable, Sendable {
    let taskID: UUID
    let applicationID: String
    let displayName: String
    let providerIdentifier: ApplicationUpdateProviderIdentifier
    let sourceDisplayName: String
    let applicationPath: String?
    let originalVersion: ApplicationVersion
    let targetVersion: ApplicationVersion?
    let downloadSize: Int64?
    let state: ApplicationUpdateTaskState
    let detail: String?
    let errorDescription: String?
    let createdAt: Date
    let updatedAt: Date
    let attemptCount: Int

    var id: UUID { taskID }
    var canRetry: Bool { state == .failed }
}

struct AppUpdateReport: Hashable, Sendable {
    let sessionID: UUID
    let completedAt: Date
    let outcome: AppUpdateReportOutcome
    let items: [AppUpdateReportItem]
    let sessionError: String?

    var succeededCount: Int { items.count { $0.state == .completed } }
    var failedCount: Int { items.count { $0.state == .failed } }
    var cancelledCount: Int { items.count { $0.state == .cancelled } }
    var retryableApplicationIDs: [String] {
        items.filter(\.canRetry).map(\.applicationID)
    }

    init(snapshot: AppUpdateSessionSnapshot, sessionError: String? = nil) {
        sessionID = snapshot.sessionID
        completedAt = snapshot.generatedAt
        items = snapshot.items.map { item in
            AppUpdateReportItem(
                taskID: item.task.id,
                applicationID: item.task.applicationID,
                displayName: item.displayName,
                providerIdentifier: item.task.providerIdentifier,
                sourceDisplayName: item.application?.source.trimmed.nonEmpty
                    ?? item.task.providerIdentifier.rawValue,
                applicationPath: item.application?.path,
                originalVersion: item.task.originalVersion,
                targetVersion: item.task.targetVersion,
                downloadSize: item.application?.downloadSize,
                state: item.task.state,
                detail: item.task.detail,
                errorDescription: item.task.errorDescription,
                createdAt: item.task.createdAt,
                updatedAt: item.task.updatedAt,
                attemptCount: item.task.attemptCount
            )
        }
        self.sessionError = sessionError
        outcome = Self.outcome(for: items)
    }

    init(
        sessionID: UUID,
        completedAt: Date = Date(),
        sessionError: String
    ) {
        self.sessionID = sessionID
        self.completedAt = completedAt
        outcome = .allFailed
        items = []
        self.sessionError = sessionError
    }

    private static func outcome(for items: [AppUpdateReportItem]) -> AppUpdateReportOutcome {
        guard !items.isEmpty else { return .noEligibleUpdates }
        if items.contains(where: { $0.state == .cancelled }) { return .cancelled }
        if items.allSatisfy({ $0.state == .completed }) { return .allSucceeded }
        if items.contains(where: { $0.state == .completed }) { return .partialSuccess }
        if items.allSatisfy({ $0.state == .failed }) { return .allFailed }
        return .requiresAction
    }
}

enum AppUpdatePresentationState: Hashable, Sendable {
    case idle(LastAppScanSummary?)
    case scanning(AppScanProgressSnapshot)
    case scanSummary(AppScanSummary)
    case managing(AppUpdateCatalogSnapshot)
    case preparingUpdate(FrozenUpdatePlan)
    case updating(AppUpdateSessionSnapshot)
    case finalizing(AppUpdateSessionSnapshot)
    case completed(AppUpdateReport)
    case cancelled(AppUpdateReport?)
    case failed(AppUpdateReport)

    var phase: AppUpdatePresentationPhase {
        switch self {
        case .idle: .idle
        case .scanning: .scanning
        case .scanSummary: .scanSummary
        case .managing: .managing
        case .preparingUpdate: .preparingUpdate
        case .updating: .updating
        case .finalizing: .finalizing
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }

    var sessionID: UUID? {
        switch self {
        case .idle:
            nil
        case let .scanning(snapshot):
            snapshot.sessionID
        case let .scanSummary(summary):
            summary.sessionID
        case let .managing(snapshot):
            snapshot.sessionID
        case let .preparingUpdate(plan):
            plan.sessionID
        case let .updating(snapshot), let .finalizing(snapshot):
            snapshot.sessionID
        case let .completed(report), let .failed(report):
            report.sessionID
        case let .cancelled(report):
            report?.sessionID
        }
    }
}

enum AppUpdatePresentationPhase: String, Hashable, Sendable {
    case idle
    case scanning
    case scanSummary
    case managing
    case preparingUpdate
    case updating
    case finalizing
    case completed
    case cancelled
    case failed
}

struct AppUpdatePresentationToken: Hashable, Sendable {
    let sessionID: UUID
    let generation: UInt64
}

enum AppUpdateTransitionRejection: Hashable, Sendable {
    case staleToken(expected: AppUpdatePresentationToken, received: AppUpdatePresentationToken)
    case payloadSessionMismatch(expected: UUID, received: UUID?)
    case invalidTransition(from: AppUpdatePresentationPhase, to: AppUpdatePresentationPhase)
}

enum AppUpdateTransitionResult: Hashable, Sendable {
    case applied
    case rejected(AppUpdateTransitionRejection)
}

struct AppUpdatePresentationMachine: Sendable {
    private(set) var state: AppUpdatePresentationState
    private(set) var activeToken: AppUpdatePresentationToken

    init(
        state: AppUpdatePresentationState = .idle(nil),
        sessionID: UUID = UUID(),
        generation: UInt64 = 0
    ) {
        self.state = state
        activeToken = AppUpdatePresentationToken(
            sessionID: sessionID,
            generation: generation
        )
    }

    @discardableResult
    mutating func beginSession(sessionID: UUID = UUID()) -> AppUpdatePresentationToken {
        activeToken = AppUpdatePresentationToken(
            sessionID: sessionID,
            generation: activeToken.generation + 1
        )
        return activeToken
    }

    @discardableResult
    mutating func transition(
        to nextState: AppUpdatePresentationState,
        token: AppUpdatePresentationToken
    ) -> AppUpdateTransitionResult {
        guard token == activeToken else {
            return .rejected(.staleToken(expected: activeToken, received: token))
        }
        if let payloadSessionID = nextState.sessionID,
           payloadSessionID != activeToken.sessionID {
            return .rejected(
                .payloadSessionMismatch(
                    expected: activeToken.sessionID,
                    received: payloadSessionID
                )
            )
        }
        guard Self.canTransition(from: state.phase, to: nextState.phase) else {
            return .rejected(.invalidTransition(from: state.phase, to: nextState.phase))
        }
        state = nextState
        return .applied
    }

    static func canTransition(
        from: AppUpdatePresentationPhase,
        to: AppUpdatePresentationPhase
    ) -> Bool {
        switch from {
        case .idle:
            return [.idle, .scanning, .managing, .preparingUpdate].contains(to)
        case .scanning:
            return [.scanning, .scanSummary, .cancelled, .failed].contains(to)
        case .scanSummary:
            return [
                .scanSummary, .managing, .preparingUpdate, .updating, .scanning, .idle,
            ].contains(to)
        case .managing:
            return [
                .managing, .scanSummary, .preparingUpdate, .updating, .scanning, .idle,
            ].contains(to)
        case .preparingUpdate:
            return [.preparingUpdate, .updating, .cancelled, .failed, .managing].contains(to)
        case .updating:
            return [.updating, .finalizing, .cancelled, .failed].contains(to)
        case .finalizing:
            return [.finalizing, .completed, .cancelled, .failed].contains(to)
        case .completed:
            return [
                .completed, .scanSummary, .managing, .preparingUpdate, .updating, .scanning, .idle,
            ].contains(to)
        case .cancelled:
            return [
                .cancelled, .scanSummary, .managing, .preparingUpdate, .updating, .scanning, .idle,
            ].contains(to)
        case .failed:
            return [
                .failed, .scanSummary, .managing, .preparingUpdate, .updating, .scanning, .idle,
            ].contains(to)
        }
    }
}

private enum AppUpdateSummaryCategory {
    case automatic
    case requiresQuit
    case requiresAuthorization
    case manual
    case current
    case unknown
    case systemManaged
}

private extension InstalledApplication {
    var isPresentationSystemManaged: Bool {
        isSystemApplication
            || effectiveUpdateCapability == .systemManaged
            || primaryUpdateProvider == .systemManaged
            || SystemApplicationPolicy.isSystemManaged(self)
    }

    var hasPresentableUpdate: Bool {
        if effectiveVersionCheckState == .updateAvailable { return true }
        switch updateStatus {
        case .updateAvailable, .automaticallyUpdatable, .officialInstallerAvailable,
             .websiteUpdateRequired, .applicationUpdateRequired, .queued,
             .downloading, .waitingForQuit, .waitingForAuthorization,
             .installing, .verifying, .failed:
            return true
        case .discovered, .identifyingSource, .checking, .upToDate,
             .appStoreManaged, .systemManaged, .sourceUnconfirmed,
             .latestVersionUnknown, .completed, .skipped, .cancelled, .ignored:
            return false
        }
    }

    var hasConfirmedPresentableUpdate: Bool {
        guard !isPresentationSystemManaged,
              !isDuplicate,
              hasPresentableUpdate,
              effectiveSourceResolutionState == .resolved,
              effectiveVersionCheckState == .updateAvailable,
              let availableVersion,
              installedVersion < availableVersion else {
            return false
        }

        switch primaryUpdateProvider {
        case .macAppStore:
            return sourceEvidence.contains("verified-app-store-receipt")
        case .homebrew:
            return homebrewMetadata?.isOutdated == true
                && sourceEvidence.contains("homebrew-cli-json-v2")
        case .sparkle:
            return sourceEvidence.contains("sparkle-framework")
                && sourceEvidence.contains("sparkle-feed")
        case .officialWebsite:
            return hasConfirmedOfficialWebsiteSource
        case .systemManaged, .vendorUpdater, .manual:
            return false
        }
    }

    /// Apps whose updates are delivered by their own trusted updater —
    /// Sparkle in-app updaters and vendor updaters such as Keystone or
    /// Squirrel. The remote version is often unknowable read-only, but the
    /// update path itself is real and actionable, so the catalog must not
    /// hide these behind a bare summary count. The row states the version is
    /// unknown; it never claims an update exists.
    var hasActionableInApplicationPath: Bool {
        guard !isPresentationSystemManaged, !isDuplicate else { return false }
        switch updateStatus {
        case .latestVersionUnknown, .failed:
            break
        default:
            return false
        }
        switch primaryUpdateProvider {
        case .sparkle:
            return sourceEvidence.contains("sparkle-framework")
                || sourceEvidence.contains("sparkle-feed")
        case .vendorUpdater:
            return effectiveUpdateCapability == .inApplication
        case .systemManaged, .macAppStore, .homebrew, .officialWebsite, .manual:
            return false
        }
    }

    var appUpdateSummaryCategory: AppUpdateSummaryCategory {
        if isPresentationSystemManaged { return .systemManaged }
        if effectiveVersionCheckState == .upToDate
            || updateStatus == .upToDate
            || updateStatus == .completed {
            return .current
        }
        if hasPresentableUpdate {
            switch ApplicationUpdatePlanBuilder.destination(for: self) {
            case .automatic:
                return .automatic
            case .requiresQuit:
                return .requiresQuit
            case .requiresAuthorization:
                return .requiresAuthorization
            case .appStore, .website, .manual:
                return .manual
            case .skipped:
                break
            }
        }
        switch effectiveUpdateCapability {
        case .appStoreManaged, .inApplication, .websiteGuided, .manual:
            return .manual
        case .automatic:
            return hasPresentableUpdate ? .manual : .unknown
        case .unavailable, .systemManaged:
            return .unknown
        }
    }

    var appUpdatePresentationCategory: AppUpdateCatalogCategory {
        if isPresentationSystemManaged { return .systemManaged }
        switch ApplicationUpdatePlanBuilder.destination(for: self) {
        case .automatic:
            return .automatic
        case .requiresQuit:
            return .requiresQuit
        case .requiresAuthorization:
            return .requiresAuthorization
        case .appStore:
            return .appStore
        case .website:
            return .website
        case .manual, .skipped:
            break
        }
        switch effectiveUpdateCapability {
        case .appStoreManaged: return .appStore
        case .inApplication: return .inApplication
        case .websiteGuided: return .website
        case .manual: return .manual
        case .automatic: return hasPresentableUpdate ? .manual : .unknown
        case .unavailable, .systemManaged: return .unknown
        }
    }
}
