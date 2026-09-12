import Foundation

enum WebsiteUpdateQueueItemState: String, Codable, CaseIterable, Sendable {
    case queued
    case presenting
    case waitingForUser
    case rechecking
    case completed
    case deferred
    case ignored
    case failed

    var isTerminal: Bool {
        switch self {
        case .completed, .deferred, .ignored, .failed:
            true
        case .queued, .presenting, .waitingForUser, .rechecking:
            false
        }
    }
}

struct WebsiteUpdateQueueItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let sessionID: UUID
    let applicationID: String
    let displayName: String
    let bundleURL: URL
    let originalVersion: ApplicationVersion
    let targetVersion: ApplicationVersion?
    var source: OfficialUpdateSource
    var actionURL: URL
    var state: WebsiteUpdateQueueItemState
    /// Optional for backwards-compatible decoding of schema-v1 queue files.
    /// Newly created and restored items always normalize these three fields.
    var sourceResolutionState: SourceResolutionState?
    var versionCheckState: VersionCheckState?
    var updateCapability: UpdateCapability?
    var observedVersion: ApplicationVersion?
    var detail: String?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        application: InstalledApplication,
        source: OfficialUpdateSource,
        actionURL: URL,
        now: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        applicationID = application.id
        displayName = application.displayName
        bundleURL = application.bundleURL
        originalVersion = application.installedVersion
        targetVersion = application.availableVersion
        self.source = source
        self.actionURL = actionURL
        state = .queued
        sourceResolutionState = source.trustLevel >= .userConfirmed ? .resolved : .unresolved
        versionCheckState = application.versionCheckState
        updateCapability = .websiteGuided
        observedVersion = nil
        detail = nil
        updatedAt = now
    }
}

struct WebsiteUpdateQueueSnapshot: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let sessionID: UUID
    var items: [WebsiteUpdateQueueItem]
    var updatedAt: Date

    init(sessionID: UUID, items: [WebsiteUpdateQueueItem], updatedAt: Date = Date()) {
        schemaVersion = 1
        self.sessionID = sessionID
        self.items = items
        self.updatedAt = updatedAt
    }
}

protocol WebsiteUpdateQueuePersisting: Sendable {
    func load() async throws -> WebsiteUpdateQueueSnapshot?
    func save(_ snapshot: WebsiteUpdateQueueSnapshot) async throws
    func remove() async throws
}

actor FileWebsiteUpdateQueueStore: WebsiteUpdateQueuePersisting {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> WebsiteUpdateQueueSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WebsiteUpdateQueueSnapshot.self, from: data)
    }

    func save(_ snapshot: WebsiteUpdateQueueSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

actor InMemoryWebsiteUpdateQueueStore: WebsiteUpdateQueuePersisting {
    private var snapshot: WebsiteUpdateQueueSnapshot?

    init(snapshot: WebsiteUpdateQueueSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load() -> WebsiteUpdateQueueSnapshot? { snapshot }
    func save(_ snapshot: WebsiteUpdateQueueSnapshot) { self.snapshot = snapshot }
    func remove() { snapshot = nil }
}

enum WebsiteUpdateQueueError: Error, Equatable, LocalizedError, Sendable {
    case queueEmpty
    case noOfficialSource(String)
    case sourceNotConfirmed(String)
    case missingWebsite(String)
    case invalidWebsite(String)
    case staleSession
    case itemNotCurrent
    case invalidTransition(from: WebsiteUpdateQueueItemState, to: WebsiteUpdateQueueItemState)

    var errorDescription: String? {
        switch self {
        case .queueEmpty:
            return L10n.text("官网更新队列为空。", "The website update queue is empty.")
        case let .noOfficialSource(name):
            return OfficialUpdateLocalization.format("%@ 没有官方更新来源。", "%@ has no official update source.", name)
        case let .sourceNotConfirmed(name):
            return OfficialUpdateLocalization.format("%@ 的更新来源待确认。", "%@ has an unconfirmed update source.", name)
        case let .missingWebsite(name):
            return OfficialUpdateLocalization.format("%@ 没有可打开的官方网页。", "%@ has no official page that can be opened.", name)
        case let .invalidWebsite(name):
            return OfficialUpdateLocalization.format("%@ 的官方网页未通过 HTTPS 和域名校验。", "%@'s official page failed HTTPS and host validation.", name)
        case .staleSession:
            return L10n.text("忽略了旧官网更新队列的回调。", "A callback from an old website update queue was ignored.")
        case .itemNotCurrent:
            return L10n.text("只能处理当前官网更新项。", "Only the current website update item can be handled.")
        case let .invalidTransition(from, to):
            return OfficialUpdateLocalization.format("无效的官网更新状态转换：%@ → %@。", "Invalid website update transition: %@ → %@.", from.rawValue, to.rawValue)
        }
    }
}

actor WebsiteUpdateQueue {
    private var snapshot: WebsiteUpdateQueueSnapshot?
    private let store: (any WebsiteUpdateQueuePersisting)?
    private let hostValidator: AllowedHostValidator

    init(
        store: (any WebsiteUpdateQueuePersisting)? = nil,
        hostValidator: AllowedHostValidator = AllowedHostValidator()
    ) {
        self.store = store
        self.hostValidator = hostValidator
    }

    @discardableResult
    func start(applications: [InstalledApplication], now: Date = Date()) async throws -> WebsiteUpdateQueueSnapshot {
        let sessionID = UUID()
        var seenApplicationIDs: Set<String> = []
        var items: [WebsiteUpdateQueueItem] = []

        for application in applications where seenApplicationIDs.insert(application.id).inserted {
            guard let source = application.officialSource else {
                throw WebsiteUpdateQueueError.noOfficialSource(application.displayName)
            }
            guard source.trustLevel >= .userConfirmed else {
                throw WebsiteUpdateQueueError.sourceNotConfirmed(application.displayName)
            }
            guard let actionURL = source.updatePageURL ?? source.homepageURL else {
                throw WebsiteUpdateQueueError.missingWebsite(application.displayName)
            }
            do {
                try hostValidator.validate(actionURL, allowedHosts: source.allowedHosts)
            } catch {
                throw WebsiteUpdateQueueError.invalidWebsite(application.displayName)
            }
            items.append(
                WebsiteUpdateQueueItem(
                    sessionID: sessionID,
                    application: application,
                    source: source,
                    actionURL: actionURL,
                    now: now
                )
            )
        }

        guard !items.isEmpty else { throw WebsiteUpdateQueueError.queueEmpty }
        let created = WebsiteUpdateQueueSnapshot(sessionID: sessionID, items: items, updatedAt: now)
        snapshot = created
        try await persist()
        return created
    }

    func restore(applications: [InstalledApplication]) async throws -> WebsiteUpdateQueueSnapshot? {
        guard let store, let restored = try await store.load() else { return snapshot }
        guard restored.schemaVersion == 1 else { return nil }
        var normalized = restored
        let applicationsByID = Dictionary(uniqueKeysWithValues: applications.map { ($0.id, $0) })
        for index in normalized.items.indices {
            guard let application = applicationsByID[normalized.items[index].applicationID],
                  application.bundleURL.standardizedFileURL == normalized.items[index].bundleURL.standardizedFileURL,
                  let currentSource = application.officialSource,
                  currentSource.trustLevel >= .userConfirmed,
                  currentSource.applicationIdentity.bundleIdentifier == application.bundleIdentifier,
                  let currentActionURL = currentSource.updatePageURL ?? currentSource.homepageURL,
                  (try? hostValidator.validate(
                    currentActionURL,
                    allowedHosts: currentSource.allowedHosts
                  )) != nil else {
                normalized.items[index].state = .failed
                normalized.items[index].sourceResolutionState = .failed
                normalized.items[index].versionCheckState = .notChecked
                normalized.items[index].updateCapability = .unavailable
                normalized.items[index].detail = L10n.text(
                    "官方来源已失效，请重新扫描并创建更新队列。",
                    "The official source is no longer valid; rescan and create a new update queue."
                )
                continue
            }
            normalized.items[index].source = currentSource
            normalized.items[index].actionURL = currentActionURL
            normalized.items[index].sourceResolutionState = .resolved
            normalized.items[index].versionCheckState = normalized.items[index].versionCheckState
                ?? application.versionCheckState
            normalized.items[index].updateCapability = .websiteGuided
            if normalized.items[index].state == .presenting || normalized.items[index].state == .rechecking {
                normalized.items[index].state = .waitingForUser
                normalized.items[index].detail = L10n.text("已恢复，请重新检查版本。", "Restored; recheck the installed version.")
            }
        }
        snapshot = normalized
        try await persist()
        return normalized
    }

    func currentSnapshot() -> WebsiteUpdateQueueSnapshot? { snapshot }

    func currentItem() -> WebsiteUpdateQueueItem? {
        snapshot?.items.first(where: { !$0.state.isTerminal })
    }

    func beginPresentation(itemID: UUID, sessionID: UUID, now: Date = Date()) async throws {
        try await transition(
            itemID: itemID,
            sessionID: sessionID,
            allowedFrom: [.queued, .waitingForUser],
            to: .presenting,
            detail: L10n.text("正在打开官方更新页。", "Opening the official update page."),
            now: now
        )
    }

    func markWaitingForUser(
        itemID: UUID,
        sessionID: UUID,
        detail: String,
        now: Date = Date()
    ) async throws {
        try await transition(
            itemID: itemID,
            sessionID: sessionID,
            allowedFrom: [.presenting, .rechecking, .waitingForUser],
            to: .waitingForUser,
            detail: detail,
            now: now
        )
        try await mutateCurrent(itemID: itemID, sessionID: sessionID) { item in
            if item.versionCheckState == .checking {
                item.versionCheckState = item.targetVersion == nil
                    ? .unavailable
                    : .updateAvailable
            }
        }
    }

    func beginRecheck(itemID: UUID, sessionID: UUID, now: Date = Date()) async throws {
        try await transition(
            itemID: itemID,
            sessionID: sessionID,
            allowedFrom: [.waitingForUser],
            to: .rechecking,
            detail: L10n.text("正在重新读取本地版本。", "Re-reading the installed version."),
            now: now
        )
        try await mutateCurrent(itemID: itemID, sessionID: sessionID) { item in
            item.versionCheckState = .checking
        }
    }

    func complete(
        itemID: UUID,
        sessionID: UUID,
        observedVersion: ApplicationVersion,
        now: Date = Date()
    ) async throws {
        try await mutateCurrent(itemID: itemID, sessionID: sessionID) { item in
            guard item.state == .rechecking else {
                throw WebsiteUpdateQueueError.invalidTransition(from: item.state, to: .completed)
            }
            item.state = .completed
            item.versionCheckState = .upToDate
            item.observedVersion = observedVersion
            item.detail = OfficialUpdateLocalization.format("已更新至 %@", "Updated to %@", observedVersion.display)
            item.updatedAt = now
        }
    }

    func deferCurrent(itemID: UUID, sessionID: UUID, now: Date = Date()) async throws {
        try await transition(
            itemID: itemID,
            sessionID: sessionID,
            allowedFrom: [.queued, .waitingForUser],
            to: .deferred,
            detail: L10n.text("已稍后处理。", "Deferred."),
            now: now
        )
    }

    func ignoreCurrent(itemID: UUID, sessionID: UUID, now: Date = Date()) async throws {
        try await transition(
            itemID: itemID,
            sessionID: sessionID,
            allowedFrom: [.queued, .waitingForUser],
            to: .ignored,
            detail: L10n.text("已忽略此版本。", "This version was ignored."),
            now: now
        )
    }

    func failCurrent(
        itemID: UUID,
        sessionID: UUID,
        detail: String,
        now: Date = Date()
    ) async throws {
        try await transition(
            itemID: itemID,
            sessionID: sessionID,
            allowedFrom: [.queued, .presenting, .waitingForUser, .rechecking],
            to: .failed,
            detail: detail,
            now: now
        )
    }

    func clearCompletedQueue() async throws {
        guard snapshot?.items.allSatisfy(\.state.isTerminal) == true else { return }
        snapshot = nil
        try await store?.remove()
    }

    private func transition(
        itemID: UUID,
        sessionID: UUID,
        allowedFrom: Set<WebsiteUpdateQueueItemState>,
        to state: WebsiteUpdateQueueItemState,
        detail: String,
        now: Date
    ) async throws {
        try await mutateCurrent(itemID: itemID, sessionID: sessionID) { item in
            guard allowedFrom.contains(item.state) else {
                throw WebsiteUpdateQueueError.invalidTransition(from: item.state, to: state)
            }
            item.state = state
            item.detail = detail
            item.updatedAt = now
        }
    }

    private func mutateCurrent(
        itemID: UUID,
        sessionID: UUID,
        mutation: (inout WebsiteUpdateQueueItem) throws -> Void
    ) async throws {
        guard var snapshot else { throw WebsiteUpdateQueueError.queueEmpty }
        guard snapshot.sessionID == sessionID else { throw WebsiteUpdateQueueError.staleSession }
        guard let currentIndex = snapshot.items.firstIndex(where: { !$0.state.isTerminal }),
              snapshot.items[currentIndex].id == itemID else {
            throw WebsiteUpdateQueueError.itemNotCurrent
        }
        try mutation(&snapshot.items[currentIndex])
        snapshot.updatedAt = Date()
        self.snapshot = snapshot
        try await persist()
    }

    private func persist() async throws {
        guard let snapshot else {
            try await store?.remove()
            return
        }
        try await store?.save(snapshot)
    }
}

enum WebsiteUpdateQueueLocation {
    static var defaultURL: URL {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("AppUpdates", isDirectory: true)
            .appendingPathComponent("website-queue-v1.json", isDirectory: false)
    }
}
