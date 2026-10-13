import Combine
import Foundation

/// A bounded, read-only projection of the Store's session, never an execution
/// source. The risk summary uses the results page's totals; the rows use D47.
struct MiniWindowCleanupDetails: Sendable {
    static let rowLimit = 4
    let sessionID: ScanSessionID
    let completedAt: Date
    let outcome: ScanOutcome
    let safeBytes: Int64
    let safeCount: Int
    let defaultCount: Int
    let items: [ScanCandidate]

    init(session: ScanSession) {
        let totals = CleanupScanTierTotals(categories: session.categories)
        let defaults = session.outcome == .cancelled
            ? [] : totals.safe.filter(\.isPreselectedByDefault)
        sessionID = session.id
        completedAt = session.completedAt
        outcome = session.outcome
        safeBytes = totals.safeBytes
        safeCount = totals.safe.count
        defaultCount = defaults.count
        items = Array(defaults.sorted {
            if $0.estimatedSizeBytes == $1.estimatedSizeBytes {
                return $0.snapshot.standardizedPath.localizedStandardCompare(
                    $1.snapshot.standardizedPath
                ) == .orderedAscending
            }
            return $0.estimatedSizeBytes > $1.estimatedSizeBytes
        }.prefix(Self.rowLimit))
    }

    /// Called only on the worker. A session keeps its ID when running owners
    /// change or cleaned rows are removed, so ID/date alone is not a revision.
    static func cacheKey(for session: ScanSession) -> MenuBarDerivedKey {
        var hash = Hasher()
        hash.combine(session.id)
        hash.combine(session.completedAt)
        hash.combine(session.outcome.rawValue)
        for category in session.categories {
            for candidate in category.candidates {
                hash.combine(candidate.id)
                hash.combine(candidate.risk.rawValue)
                hash.combine(candidate.action.rawValue)
                hash.combine(candidate.isSelectable)
                hash.combine(candidate.isPreselectedByDefault)
                hash.combine(candidate.estimatedSizeBytes)
                hash.combine(candidate.measurementCompleteness)
                hash.combine(candidate.sourceURL)
                hash.combine(candidate.snapshot.standardizedPath)
                hash.combine(candidate.subcategoryTitle)
            }
        }
        return MenuBarDerivedKey(page: "cleanup", kind: "default-items",
                                 revision: String(hash.finalize()), configuration: "d47-largest-four-v2")
    }
}

/// Text and numbers are resolved at presentation time, so changing language
/// does not leave localized strings in the shared data cache.
struct MiniWindowCleanupPresentation {
    enum Source: Equatable { case session, preparing, history, empty }
    let source: Source
    let date: Date?
    let isCancelled: Bool
    let safeBytes: Int64?
    let safeCount: Int?
    let details: MiniWindowCleanupDetails?
    var isUpdating = false
    var isScanning = false

    static func resolve(session: ScanSession?, details: MiniWindowCleanupDetails?,
                        history: LastScanStatusSummary?, isUpdating: Bool = false,
                        isScanning: Bool = false) -> Self {
        if let session, session.coversCleanupCandidates {
            let current = details.flatMap {
                $0.sessionID == session.id && $0.completedAt == session.completedAt && $0.outcome == session.outcome ? $0 : nil
            }
            return Self(source: current == nil ? .preparing : .session,
                        date: session.completedAt, isCancelled: session.outcome == .cancelled,
                        safeBytes: current?.safeBytes, safeCount: current?.safeCount, details: current,
                        isUpdating: current != nil && isUpdating, isScanning: isScanning)
        }
        if let history, history.entry.coversCleanupCandidates {
            return Self(source: .history, date: history.entry.date, isCancelled: false,
                        safeBytes: history.entry.greenBytes, safeCount: history.entry.greenCount, details: nil,
                        isScanning: isScanning)
        }
        return Self(source: .empty, date: nil, isCancelled: false,
                    safeBytes: nil, safeCount: nil, details: nil, isScanning: isScanning)
    }

    var title: String {
        switch source {
        case .session, .preparing:
            return isCancelled ? L10n.text("扫描已取消", "Scan Cancelled")
                : L10n.text("可安全清理", "Safe Cleanup")
        case .history:
            let time = date?.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale)) ?? "--"
            return L10n.text("上次扫描 · \(time)", "Last Scan · \(time)")
        case .empty:
            return L10n.text("尚未扫描", "Not Scanned Yet")
        }
    }

    // These nonnumeric placeholders preserve the state's explanation in
    // GeekMetricCell. "--" would replace that explanation with "Unavailable".
    var bytesText: String { safeBytes.map(ByteFormat.string) ?? "…" }
    var countText: String {
        if isUpdating { return L10n.text("更新中…", "Updating…") }
        if source == .preparing { return L10n.text("正在整理", "Preparing Details") }
        if isScanning && source == .empty { return L10n.text("扫描中…", "Scanning…") }
        return safeCount.map(L10n.items)
            ?? L10n.text("等待扫描", "Waiting for Scan")
    }
    var actionableCountText: String { details.map { String($0.defaultCount) } ?? "…" }

    var actionableDetail: String {
        if isUpdating { return L10n.text("更新中…", "Updating…") }
        if isScanning { return L10n.text("扫描中…", "Scanning…") }
        switch source {
        case .session:
            if isCancelled { return L10n.text("扫描已取消", "Scan Cancelled") }
            return details?.defaultCount ?? 0 > 0
                ? L10n.text("默认可清理", "Default Cleanup Items")
                : L10n.text("无默认项目", "No Default Items")
        case .preparing:
            return L10n.text("正在整理明细", "Preparing Details")
        case .history:
            return safeCount ?? 0 > 0 ? L10n.text("需重新扫描", "Rescan Required")
                : L10n.text("历史摘要", "Scan Summary")
        case .empty:
            return L10n.text("等待首次扫描", "Waiting for First Scan")
        }
    }

    var notice: String {
        if isUpdating { return L10n.text("更新中…在主窗口确认。", "Updating… Confirm in the main window.") }
        if isScanning { return L10n.text("扫描中…等待本次结果。", "Scanning… Wait for the new results.") }
        switch source {
        case .session:
            if isCancelled {
                return L10n.text("扫描已取消。重新扫描后再确认清理。", "Scan cancelled. Rescan before confirming cleanup.")
            }
            if let count = details?.defaultCount, count > 0 {
                return L10n.text("默认可清理 \(count) 项。在主窗口确认。",
                                 count == 1 ? "1 default cleanup item. Confirm in the main window."
                                     : "\(count) default cleanup items. Confirm in the main window.")
            }
            return safeCount == 0
                ? L10n.text("本次扫描没有绿色清理项。", "This scan found no green cleanup items.")
                : L10n.text("本次扫描没有默认可清理项。在主窗口查看。", "No default cleanup items. Review in the main window.")
        case .preparing:
            return L10n.text("正在整理扫描明细…", "Preparing scan details…")
        case .history:
            return safeCount ?? 0 > 0
                ? L10n.text("仅保留扫描摘要。清理前请重新扫描。", "Only the scan summary is saved. Rescan before cleanup.")
                : L10n.text("仅保留扫描摘要。上次没有绿色清理项。", "Only the scan summary is saved. The last scan found no green items.")
        case .empty:
            return L10n.text("先在主窗口扫描，再查看清理项。", "Scan in the main window to see cleanup items.")
        }
    }
}

/// An O(1) current-value read, without subscribing or preparing a projection.
struct MiniWindowCleanupSnapshot: Sendable {
    let session: ScanSession?
    let isScanning: Bool
    let history: ScanHistorySummary
    static let empty = Self(session: nil, isScanning: false, history: .init(entries: []))
}

/// The adapter is cheap to create during root evaluation. Its three publishers
/// are subscribed only once per visible lifetime, never by SwiftUI onReceive.
/// Inputs are emitted on the main actor, like ScanStore's published properties.
@MainActor
struct MiniWindowCleanupSource {
    private let subscribe: @MainActor (MiniWindowCleanupDetailsModel) -> [AnyCancellable]
    private let readCurrent: @MainActor () -> MiniWindowCleanupSnapshot

    init(store: ScanStore) {
        self.init(session: store.$cleanupScanSession, scanning: store.$isScanning,
                  history: store.$scanHistorySummary, current: { [weak store] in
            guard let store else { return .empty }
            return MiniWindowCleanupSnapshot(session: store.cleanupScanSession,
                                             isScanning: store.isScanning, history: store.scanHistorySummary)
        })
    }

    init<Session: Publisher, Scanning: Publisher, History: Publisher>(
        session: Session, scanning: Scanning, history: History,
        current: @escaping @MainActor () -> MiniWindowCleanupSnapshot = { .empty }
    ) where Session.Output == ScanSession?, Scanning.Output == Bool,
            History.Output == ScanHistorySummary,
            Session.Failure == Never, Scanning.Failure == Never, History.Failure == Never {
        readCurrent = current
        subscribe = { model in
            // Subscribe to scalar status first; the initial session then starts
            // preparation with the latest scanning/history values already set.
            let scanningSubscription = scanning.sink { [weak model] in model?.receiveScanning($0) }
            let historySubscription = history.sink { [weak model] in model?.receiveHistory($0) }
            let sessionSubscription = session.sink { [weak model] in model?.request($0) }
            return [scanningSubscription, historySubscription, sessionSubscription]
        }
    }

    func current() -> MiniWindowCleanupSnapshot { readCurrent() }
    func connect(to model: MiniWindowCleanupDetailsModel) -> [AnyCancellable] { subscribe(model) }
}

@MainActor
final class MiniWindowCleanupDetailsModel: ObservableObject {
    @Published private(set) var details: MiniWindowCleanupDetails?
    @Published private(set) var isUpdating = false
    @Published private(set) var isVisible = false
    @Published private(set) var session: ScanSession?
    @Published private(set) var isScanning = false
    @Published private(set) var history: LastScanStatusSummary?
    @Published private(set) var visibilityID = UUID()
    // Advance only for a confirmed result change, not every request/opening.
    @Published private(set) var layoutRevision: UInt64 = 0
    private(set) var deliveredKey: MenuBarDerivedKey?
    private var hasReceivedSession = false
    var isPreparing: Bool { worker != nil }
    var presentation: MiniWindowCleanupPresentation {
        .resolve(session: session, details: details, history: history,
                 isUpdating: isUpdating, isScanning: isScanning)
    }
    func presentation(beforeStarting snapshot: MiniWindowCleanupSnapshot) -> MiniWindowCleanupPresentation {
        .resolve(session: snapshot.session, details: details, history: snapshot.history.latestCleanupStatus(),
                 isScanning: snapshot.isScanning)
    }
    var isInitialLayoutReady: Bool {
        isVisible && hasReceivedSession && (session == nil || presentation.source == .session)
    }
    private var subscriptions: [AnyCancellable] = []
    private var worker: Task<Void, Never>?
    private var updateNotice: Task<Void, Never>?
    private var generation = 0
    let cache: MenuBarDerivedCache
    private let fingerprint: @Sendable (ScanSession) async -> MenuBarDerivedKey
    private let waitForUpdateGrace: @Sendable () async throws -> Void

    init(cache: MenuBarDerivedCache = .shared,
         fingerprint: @escaping @Sendable (ScanSession) async -> MenuBarDerivedKey = { session in
             await Task.detached(priority: .userInitiated) { MiniWindowCleanupDetails.cacheKey(for: session) }.value
         },
         waitForUpdateGrace: @escaping @Sendable () async throws -> Void = {
             try await Task.sleep(for: .milliseconds(200))
         }) {
        self.cache = cache
        self.fingerprint = fingerprint
        self.waitForUpdateGrace = waitForUpdateGrace
    }

    func start(_ source: MiniWindowCleanupSource) {
        guard beginVisibility() else { return }
        subscriptions = source.connect(to: self)
    }

    /// Pure-model clients do not need a Store or publisher fixture.
    func start(_ session: ScanSession?) {
        guard beginVisibility() else { return }
        request(session)
    }

    private func beginVisibility() -> Bool {
        guard !isVisible else { return false }
        visibilityID = UUID()
        hasReceivedSession = false
        isVisible = true
        return true
    }

    fileprivate func receiveScanning(_ value: Bool) {
        guard isVisible, value != isScanning else { return }
        isScanning = value
    }

    fileprivate func receiveHistory(_ value: ScanHistorySummary) {
        guard isVisible else { return }
        history = value.latestCleanupStatus()
    }

    /// Identity checks are O(1). Candidate fingerprinting and projection stay
    /// off the opening path. Only session emissions request preparation;
    /// status/history changes and parent redraws do not restart the worker.
    func request(_ session: ScanSession?) {
        guard isVisible else { return }
        cancelPreparation()
        hasReceivedSession = true
        let hadResult = self.session != nil || deliveredKey != nil
        let cleanupSession = session.flatMap { $0.coversCleanupCandidates ? $0 : nil }
        self.session = cleanupSession
        guard let session = cleanupSession else {
            details = nil
            deliveredKey = nil
            if hadResult { layoutRevision &+= 1 }
            return
        }
        let hasRetainedRows = details.map {
            $0.sessionID == session.id && $0.completedAt == session.completedAt && $0.outcome == session.outcome
        } ?? false
        let requestGeneration = generation
        let requestCache = cache
        let fingerprint = fingerprint
        worker = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let key = await fingerprint(session)
            guard !Task.isCancelled, let self, self.generation == requestGeneration else { return }
            if self.deliveredKey == key, self.details != nil {
                self.finishPreparation()
                return
            }
            let prepared = await requestCache.value(for: key, cost: 64 * 1_024) {
                MiniWindowCleanupDetails(session: session)
            }
            guard !Task.isCancelled, self.generation == requestGeneration else { return }
            details = prepared
            deliveredKey = key
            layoutRevision &+= 1
            finishPreparation()
        }
        if hasRetainedRows {
            let grace = waitForUpdateGrace
            updateNotice = Task { @MainActor [weak self] in
                do { try await grace() } catch { return }
                guard !Task.isCancelled, let self, self.isVisible,
                      self.generation == requestGeneration, self.worker != nil else { return }
                self.isUpdating = true
            }
        }
    }

    /// Fixture owners can join cancelled tasks before releasing their host.
    @discardableResult
    func stop() -> [Task<Void, Never>] {
        let cancelledTasks = [worker, updateNotice].compactMap { $0 }
        isVisible = false
        subscriptions.forEach { $0.cancel() }
        subscriptions.removeAll()
        cancelPreparation()
        // Hidden pages retain only the bounded delivery, not an old full
        // session. Reopening receives current inputs before preparing.
        session = nil
        history = nil
        isScanning = false
        hasReceivedSession = false
        return cancelledTasks
    }

    private func finishPreparation() {
        worker = nil
        updateNotice?.cancel()
        updateNotice = nil
        if isUpdating { isUpdating = false }
    }

    private func cancelPreparation() {
        generation &+= 1
        worker?.cancel()
        finishPreparation()
    }
}
