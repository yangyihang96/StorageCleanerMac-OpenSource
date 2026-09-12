import Foundation

protocol WebsiteUpdatePageOpening: Sendable {
    func open(_ url: URL) async -> Bool
}

struct ClosureWebsiteUpdatePageOpener: WebsiteUpdatePageOpening {
    private let operation: @Sendable (URL) async -> Bool

    init(operation: @escaping @Sendable (URL) async -> Bool) {
        self.operation = operation
    }

    func open(_ url: URL) async -> Bool {
        await operation(url)
    }
}

struct InstalledApplicationRecheckSnapshot: Sendable {
    let application: InstalledApplication
    let signature: CodeSignatureVerificationResult
}

protocol InstalledApplicationRechecking: Sendable {
    func snapshot(at applicationURL: URL) async throws -> InstalledApplicationRecheckSnapshot?
}

struct VerifiedInstalledApplicationRechecker: InstalledApplicationRechecking {
    private let metadataReader = ApplicationMetadataReader()
    private let signatureVerifier = CodeSignatureVerifier()

    func snapshot(at applicationURL: URL) async throws -> InstalledApplicationRecheckSnapshot? {
        let signature = try signatureVerifier.verifyCode(at: applicationURL)
        let runningState = await ApplicationRunningStateSnapshot.capture()
        guard let application = await metadataReader.read(
            applicationURL: applicationURL,
            runningState: runningState
        ), application.sourceEvidence.contains("valid-code-signature") else {
            return nil
        }
        return InstalledApplicationRecheckSnapshot(
            application: application,
            signature: signature
        )
    }
}

enum WebsiteUpdateRecheckResult: Hashable, Sendable {
    case updated(ApplicationVersion)
    case unchanged(ApplicationVersion?)
}

enum WebsiteUpdateWorkflowError: Error, Equatable, LocalizedError, Sendable {
    case noCurrentItem
    case sourceNotConfirmed
    case invalidActionURL
    case unableToOpenWebsite
    case unableToReadInstalledVersion
    case applicationIdentityChanged

    var errorDescription: String? {
        switch self {
        case .noCurrentItem:
            return L10n.text("没有待处理的官网更新。", "There is no website update to process.")
        case .sourceNotConfirmed:
            return L10n.text("该来源尚未确认，不能作为官网更新页打开。", "This source is not confirmed and cannot be opened as an official update page.")
        case .invalidActionURL:
            return L10n.text("官方更新页未通过域名校验。", "The official update page failed host validation.")
        case .unableToOpenWebsite:
            return L10n.text("无法打开官方更新页。", "The official update page could not be opened.")
        case .unableToReadInstalledVersion:
            return L10n.text("尚未检测到新版本。", "No new installed version was detected.")
        case .applicationIdentityChanged:
            return L10n.text(
                "检测到的应用身份或代码签名与原应用不一致。",
                "The detected application's identity or code signature does not match the original app."
            )
        }
    }
}

actor WebsiteUpdateWorkflow {
    private let queue: WebsiteUpdateQueue
    private let opener: any WebsiteUpdatePageOpening
    private let applicationRechecker: any InstalledApplicationRechecking
    private let hostValidator: AllowedHostValidator

    init(
        queue: WebsiteUpdateQueue,
        opener: any WebsiteUpdatePageOpening,
        applicationRechecker: any InstalledApplicationRechecking = VerifiedInstalledApplicationRechecker(),
        hostValidator: AllowedHostValidator = AllowedHostValidator()
    ) {
        self.queue = queue
        self.opener = opener
        self.applicationRechecker = applicationRechecker
        self.hostValidator = hostValidator
    }

    @discardableResult
    func start(applications: [InstalledApplication]) async throws -> WebsiteUpdateQueueSnapshot {
        try await queue.start(applications: applications)
    }

    @discardableResult
    func restore(applications: [InstalledApplication]) async throws -> WebsiteUpdateQueueSnapshot? {
        try await queue.restore(applications: applications)
    }

    func currentItem() async -> WebsiteUpdateQueueItem? {
        await queue.currentItem()
    }

    func currentSnapshot() async -> WebsiteUpdateQueueSnapshot? {
        await queue.currentSnapshot()
    }

    /// Opens exactly the current item. The queue cannot advance or open another
    /// URL until this item is explicitly rechecked, deferred, ignored, or failed.
    func openCurrentWebsite() async throws {
        guard let item = await queue.currentItem() else {
            throw WebsiteUpdateWorkflowError.noCurrentItem
        }
        guard item.source.trustLevel >= .userConfirmed else {
            throw WebsiteUpdateWorkflowError.sourceNotConfirmed
        }
        do {
            try hostValidator.validate(item.actionURL, allowedHosts: item.source.allowedHosts)
        } catch {
            throw WebsiteUpdateWorkflowError.invalidActionURL
        }

        try await queue.beginPresentation(itemID: item.id, sessionID: item.sessionID)
        guard await opener.open(item.actionURL) else {
            try await queue.failCurrent(
                itemID: item.id,
                sessionID: item.sessionID,
                detail: WebsiteUpdateWorkflowError.unableToOpenWebsite.localizedDescription
            )
            throw WebsiteUpdateWorkflowError.unableToOpenWebsite
        }
        try await queue.markWaitingForUser(
            itemID: item.id,
            sessionID: item.sessionID,
            detail: L10n.text("请在官网完成更新，返回后重新检查版本。", "Complete the update on the website, then return and recheck the installed version.")
        )
    }

    @discardableResult
    func recheckCurrentVersion() async throws -> WebsiteUpdateRecheckResult {
        guard let item = await queue.currentItem() else {
            throw WebsiteUpdateWorkflowError.noCurrentItem
        }
        try await queue.beginRecheck(itemID: item.id, sessionID: item.sessionID)

        let observedSnapshot: InstalledApplicationRecheckSnapshot?
        do {
            observedSnapshot = try await applicationRechecker.snapshot(at: item.bundleURL)
        } catch {
            try await queue.markWaitingForUser(
                itemID: item.id,
                sessionID: item.sessionID,
                detail: WebsiteUpdateWorkflowError.unableToReadInstalledVersion.localizedDescription
            )
            throw WebsiteUpdateWorkflowError.unableToReadInstalledVersion
        }

        guard let observedSnapshot else {
            try await queue.markWaitingForUser(
                itemID: item.id,
                sessionID: item.sessionID,
                detail: WebsiteUpdateWorkflowError.applicationIdentityChanged.localizedDescription
            )
            throw WebsiteUpdateWorkflowError.applicationIdentityChanged
        }
        let observedApplication = observedSnapshot.application
        let observedSignature = observedSnapshot.signature
        let expectedTeam = item.source.expectedTeamIdentifier
            ?? item.source.applicationIdentity.signingTeamIdentifier
        let expectedCodeIdentifier = item.source.applicationIdentity.codeSigningIdentifier
        guard observedApplication.bundleIdentifier == item.source.expectedBundleIdentifier,
              observedApplication.bundleIdentifier == item.source.applicationIdentity.bundleIdentifier,
              observedSignature.isValid,
              expectedTeam == nil || observedSignature.teamIdentifier == expectedTeam,
              expectedCodeIdentifier == nil || observedSignature.codeSigningIdentifier == expectedCodeIdentifier,
              item.source.expectedDesignatedRequirement == nil
                || observedSignature.designatedRequirement == item.source.expectedDesignatedRequirement else {
            try await queue.markWaitingForUser(
                itemID: item.id,
                sessionID: item.sessionID,
                detail: WebsiteUpdateWorkflowError.applicationIdentityChanged.localizedDescription
            )
            throw WebsiteUpdateWorkflowError.applicationIdentityChanged
        }
        let observed = observedApplication.installedVersion
        let reachedKnownTarget = item.targetVersion.map { observed >= $0 } ?? true
        guard item.originalVersion < observed, reachedKnownTarget else {
            try await queue.markWaitingForUser(
                itemID: item.id,
                sessionID: item.sessionID,
                detail: L10n.text("尚未检测到新版本。", "No new version has been detected yet.")
            )
            return .unchanged(observed)
        }

        try await queue.complete(
            itemID: item.id,
            sessionID: item.sessionID,
            observedVersion: observed
        )
        return .updated(observed)
    }

    func deferCurrent() async throws {
        guard let item = await queue.currentItem() else {
            throw WebsiteUpdateWorkflowError.noCurrentItem
        }
        try await queue.deferCurrent(itemID: item.id, sessionID: item.sessionID)
    }

    func ignoreCurrentVersion() async throws {
        guard let item = await queue.currentItem() else {
            throw WebsiteUpdateWorkflowError.noCurrentItem
        }
        try await queue.ignoreCurrent(itemID: item.id, sessionID: item.sessionID)
    }
}
