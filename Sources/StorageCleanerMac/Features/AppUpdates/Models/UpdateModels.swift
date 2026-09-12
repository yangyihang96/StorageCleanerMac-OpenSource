import Foundation

enum ApplicationUpdateTaskState: String, Codable, CaseIterable, Sendable {
    case queued
    case checking
    case downloading
    case waitingForQuit
    case waitingForAuthorization
    case installing
    case verifying
    case completed
    case skipped
    case cancelled
    case failed
    case needsReconciliation

    var isTerminal: Bool {
        switch self {
        case .completed, .skipped, .cancelled, .failed:
            true
        case .queued, .checking, .downloading, .waitingForQuit,
             .waitingForAuthorization, .installing, .verifying, .needsReconciliation:
            false
        }
    }
}

/// Stable, user-facing lifecycle for the one-click update coordinator.  The
/// coordinator still stores per-application task states; this projection keeps
/// the batch state machine explicit without introducing a second executor.
enum UpdateOrchestratorState: String, Codable, CaseIterable, Sendable {
    case idle
    case scanning
    case preparing
    case downloading
    case waitingForApplications
    case installing
    case verifying
    case completed
    case partialFailure
    case failed
    case cancelled
}

/// The inventory scanner owns this state.  It is deliberately separate from
/// the persisted update queue: an empty queue can mean either that scanning
/// has not started or that the scan is currently in progress, so the queue
/// must never be used to infer the scanner lifecycle.
enum ApplicationUpdateScanState: Equatable, Sendable {
    case idle
    case scanning(AppScanProgressSnapshot)
    case ready
    case cancelled
    case failed(String)

    var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }
}

struct ApplicationUpdateTask: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let sessionID: UUID
    let applicationID: String
    let providerIdentifier: ApplicationUpdateProviderIdentifier
    let originalIdentity: ApplicationIdentity
    let originalVersion: ApplicationVersion
    let targetVersion: ApplicationVersion?
    var state: ApplicationUpdateTaskState
    var progressFraction: Double?
    var detail: String?
    var errorDescription: String?
    var createdAt: Date
    var updatedAt: Date
    var attemptCount: Int

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        application: InstalledApplication,
        state: ApplicationUpdateTaskState = .queued,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        applicationID = application.id
        providerIdentifier = application.updateProvider
        originalIdentity = application.identity
        originalVersion = application.installedVersion
        targetVersion = application.availableVersion
        self.state = state
        progressFraction = nil
        detail = nil
        errorDescription = nil
        self.createdAt = createdAt
        updatedAt = createdAt
        attemptCount = 0
    }
}

struct ApplicationUpdatePlan: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let automaticApplicationIDs: [String]
    let requiresQuitApplicationIDs: [String]
    let requiresAuthorizationApplicationIDs: [String]
    let appStoreApplicationIDs: [String]
    let websiteApplicationIDs: [String]
    let manualApplicationIDs: [String]
    let skippedApplicationIDs: [String]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        automaticApplicationIDs: [String],
        requiresQuitApplicationIDs: [String],
        requiresAuthorizationApplicationIDs: [String],
        appStoreApplicationIDs: [String],
        websiteApplicationIDs: [String],
        manualApplicationIDs: [String],
        skippedApplicationIDs: [String]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.automaticApplicationIDs = automaticApplicationIDs
        self.requiresQuitApplicationIDs = requiresQuitApplicationIDs
        self.requiresAuthorizationApplicationIDs = requiresAuthorizationApplicationIDs
        self.appStoreApplicationIDs = appStoreApplicationIDs
        self.websiteApplicationIDs = websiteApplicationIDs
        self.manualApplicationIDs = manualApplicationIDs
        self.skippedApplicationIDs = skippedApplicationIDs
    }

    var automaticCount: Int { automaticApplicationIDs.count }
    var websiteCount: Int { websiteApplicationIDs.count }
}

struct ApplicationUpdateQueueSnapshot: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let plan: ApplicationUpdatePlan
    var tasks: [ApplicationUpdateTask]
    var isPaused: Bool
    var updatedAt: Date

    var orchestratorState: UpdateOrchestratorState {
        Self.projectTaskStates(tasks)
    }

    /// Projects only the persisted queue.  Inventory scanning is projected by
    /// `UpdateOrchestratorState.project(scanState:queue:)` below.
    static func projectTaskStates(
        _ tasks: [ApplicationUpdateTask]
    ) -> UpdateOrchestratorState {
        guard !tasks.isEmpty else { return .idle }

        // Active work always wins over terminal errors from other tasks.  A
        // failed task next to a downloading task is therefore still
        // downloading, never an early partial-failure terminal state.
        let activeTasks = tasks.filter { !$0.state.isTerminal }
        if !activeTasks.isEmpty {
            if activeTasks.contains(where: {
                $0.state == .waitingForQuit || $0.state == .waitingForAuthorization
            }) {
                return .waitingForApplications
            }
            if activeTasks.contains(where: { $0.state == .installing }) {
                return .installing
            }
            if activeTasks.contains(where: {
                $0.state == .verifying || $0.state == .needsReconciliation
            }) {
                return .verifying
            }
            if activeTasks.contains(where: { $0.state == .downloading }) {
                return .downloading
            }
            if activeTasks.contains(where: { $0.state == .checking }) {
                return .scanning
            }
            return .preparing
        }

        // Only an all-terminal queue can produce a terminal batch result.
        // Cancellation is intentionally dominant so a mixed completed /
        // cancelled queue truthfully remains cancelled rather than claiming
        // success.  Failed plus completed (or skipped) is partial failure;
        // an all-failed queue is failed.
        if tasks.contains(where: { $0.state == .cancelled }) {
            return .cancelled
        }
        if tasks.contains(where: { $0.state == .failed }) {
            return tasks.allSatisfy { $0.state == .failed || $0.state == .skipped }
                ? .failed
                : .partialFailure
        }
        if tasks.allSatisfy({ $0.state == .completed || $0.state == .skipped }) {
            return .completed
        }
        return .partialFailure
    }
}

extension UpdateOrchestratorState {
    /// Combines the real inventory scanner state with the single persisted
    /// coordinator queue.  An active queue wins over scan bookkeeping; when
    /// there is no active task, an actual scanner state (including scanning,
    /// cancellation, and failure) is used instead of guessing from an empty
    /// task list.
    static func project(
        scanState: ApplicationUpdateScanState,
        queue: ApplicationUpdateQueueSnapshot?,
        presentationSessionID: UUID?
    ) -> Self {
        let visibleQueue = queue.flatMap { snapshot -> ApplicationUpdateQueueSnapshot? in
            guard snapshot.tasks.allSatisfy(\.state.isTerminal),
                  presentationSessionID != Optional(snapshot.plan.id) else {
                return snapshot
            }
            return nil
        }

        if let queue = visibleQueue,
           queue.tasks.contains(where: { !$0.state.isTerminal }) {
            return queue.orchestratorState
        }

        if let queue = visibleQueue {
            // A post-update inventory refresh may run while the completed
            // queue is still being presented.  Expose its real scanning state,
            // but keep the terminal batch result authoritative once that scan
            // fails or is cancelled.
            if case .scanning = scanState {
                return .scanning
            }
            return queue.orchestratorState
        }

        switch scanState {
        case .scanning:
            return .scanning
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        case .idle, .ready:
            return .idle
        }
    }

    var title: String {
        switch self {
        case .idle: ""
        case .scanning: L10n.text("正在扫描应用", "Scanning Applications")
        case .preparing: L10n.text("正在准备更新", "Preparing Updates")
        case .downloading: L10n.text("正在下载更新", "Downloading Updates")
        case .waitingForApplications:
            L10n.text("等待应用退出或授权", "Waiting for Applications or Authorization")
        case .installing: L10n.text("正在安装更新", "Installing Updates")
        case .verifying: L10n.text("正在验证更新", "Verifying Updates")
        case .completed: L10n.text("更新已完成", "Updates Completed")
        case .partialFailure: L10n.text("更新部分完成", "Updates Partially Completed")
        case .failed: L10n.text("更新失败", "Updates Failed")
        case .cancelled: L10n.text("更新已取消", "Updates Cancelled")
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "arrow.down.circle"
        case .scanning: "magnifyingglass"
        case .preparing: "checkmark.shield"
        case .downloading: "arrow.down.circle"
        case .waitingForApplications: "pause.circle"
        case .installing: "shippingbox"
        case .verifying: "checkmark.shield"
        case .completed: "checkmark.circle"
        case .partialFailure: "exclamationmark.triangle"
        case .failed: "xmark.octagon"
        case .cancelled: "stop.circle"
        }
    }
}

/// The attachment calls the structured recipe an `UpdateRecipe`; keep the
/// existing, fully validated type as the single source of truth.
typealias UpdateRecipe = ApplicationUpdateExecutionRecipe

/// Compatibility name used by the 1.9.9 product contract.  The existing
/// actor remains the only coordinator implementation.
typealias UpdateOrchestrator = ApplicationUpdateCoordinator

struct ApplicationUpdateSourceInfo: Hashable, Sendable {
    let providerIdentifier: ApplicationUpdateProviderIdentifier
    let evidence: [String]
    let requiresUserInteraction: Bool
    let canAutomaticallyUpdate: Bool
}

struct ApplicationUpdateCheckResult: Hashable, Sendable {
    let status: ApplicationUpdateStatus
    let availableVersion: ApplicationVersion?
    let releaseDate: Date?
    let releaseNotes: String?
    let downloadSize: Int64?
    let warning: String?
    let appStoreProductURL: URL?

    init(
        status: ApplicationUpdateStatus,
        availableVersion: ApplicationVersion?,
        releaseDate: Date?,
        releaseNotes: String?,
        downloadSize: Int64?,
        warning: String?,
        appStoreProductURL: URL? = nil
    ) {
        self.status = status
        self.availableVersion = availableVersion
        self.releaseDate = releaseDate
        self.releaseNotes = releaseNotes
        self.downloadSize = downloadSize
        self.warning = warning
        self.appStoreProductURL = appStoreProductURL
    }
}

enum ApplicationUpdateVerificationStep: String, Hashable, Sendable {
    case trustedExecutable
    case downloadChecksum
    case packageIdentity
    case codeSignature
    case bundleIdentifier
    case teamIdentifier
    case installedVersion
}

enum ApplicationUpdateRollbackPlan: Hashable, Sendable {
    case verifiedBackup
    case providerManaged
    case unavailable(reason: String)
}

/// An immutable, provider-prepared process recipe. The executor passes these
/// fields directly to `Process`-backed infrastructure; no command string is
/// parsed or evaluated.
struct ApplicationUpdateExecutionRecipe: Hashable, Sendable {
    let applicationID: String
    let displayName: String
    let currentVersion: ApplicationVersion
    let targetVersion: ApplicationVersion?
    let sourceProvider: ApplicationUpdateProviderIdentifier
    let executableURL: URL
    let arguments: [String]
    let workingDirectory: URL?
    let environmentAllowlist: [String: String]
    let requiresAdministrator: Bool
    let applicationsToQuit: [String]
    let downloadURL: URL?
    let expectedBundleIdentifier: String
    let expectedTeamIdentifier: String?
    let expectedVersion: ApplicationVersion?
    let checksumSHA256: String?
    let verificationSteps: [ApplicationUpdateVerificationStep]
    let rollbackPlan: ApplicationUpdateRollbackPlan

    var commandPreview: String {
        ([executableURL.path] + arguments).map(Self.shellQuotedForDisplay).joined(separator: " ")
    }

    private static func shellQuotedForDisplay(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/@:+"))
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ safe.contains($0) }) else {
            return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        return value
    }
}

struct PreparedApplicationUpdate: Hashable, Sendable {
    let applicationID: String
    let providerIdentifier: ApplicationUpdateProviderIdentifier
    let originalIdentity: ApplicationIdentity
    let originalVersion: ApplicationVersion
    let targetVersion: ApplicationVersion?
    let providerPayload: [String: String]
    let executionRecipe: ApplicationUpdateExecutionRecipe?

    init(
        applicationID: String,
        providerIdentifier: ApplicationUpdateProviderIdentifier,
        originalIdentity: ApplicationIdentity,
        originalVersion: ApplicationVersion,
        targetVersion: ApplicationVersion?,
        providerPayload: [String: String],
        executionRecipe: ApplicationUpdateExecutionRecipe? = nil
    ) {
        self.applicationID = applicationID
        self.providerIdentifier = providerIdentifier
        self.originalIdentity = originalIdentity
        self.originalVersion = originalVersion
        self.targetVersion = targetVersion
        self.providerPayload = providerPayload
        self.executionRecipe = executionRecipe
    }
}

struct ApplicationUpdateStagingReport: Sendable, Equatable {
    let stagedApplicationIDs: Set<String>
    let failedApplicationDetails: [String: String]

    init(
        stagedApplicationIDs: Set<String> = [],
        failedApplicationDetails: [String: String] = [:]
    ) {
        self.stagedApplicationIDs = stagedApplicationIDs
        self.failedApplicationDetails = failedApplicationDetails
    }
}

struct ApplicationUpdateInstallResult: Hashable, Sendable {
    let applicationID: String
    let state: ApplicationUpdateTaskState
    let observedVersion: ApplicationVersion?
    let detail: String
}

struct ApplicationUpdateProgressEvent: Hashable, Sendable {
    let applicationID: String
    let state: ApplicationUpdateTaskState
    let fraction: Double?
    let detail: String
}
