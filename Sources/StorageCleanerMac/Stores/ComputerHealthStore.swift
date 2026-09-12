import Combine
import Foundation

protocol ComputerHealthProbing: Sendable {
    func probe() async throws -> ComputerHealthSnapshot
}

enum BatterySettingsAdjustmentState: Equatable, Sendable {
    case idle
    case openingSettings
    case awaitingVerification
    case verifying
    case unchanged
    case expired
    case unverifiable
    case verified
    case failedToOpen
}

enum BatteryPowerModeAdjustmentState: Equatable, Sendable {
    case idle
    case changing(source: BatteryPowerSource, mode: BatteryPowerMode)
    case changed(source: BatteryPowerSource, mode: BatteryPowerMode)
    case unsupported(source: BatteryPowerSource, mode: BatteryPowerMode)
    case cancelled(source: BatteryPowerSource, mode: BatteryPowerMode)
    case permissionDenied(source: BatteryPowerSource, mode: BatteryPowerMode)
    case timedOut(source: BatteryPowerSource, mode: BatteryPowerMode)
    case failed(source: BatteryPowerSource, mode: BatteryPowerMode)
    case verificationFailed(source: BatteryPowerSource, mode: BatteryPowerMode)

    var isChanging: Bool {
        if case .changing = self { return true }
        return false
    }

    func isChanging(source: BatteryPowerSource, mode: BatteryPowerMode) -> Bool {
        self == .changing(source: source, mode: mode)
    }
}

struct DefaultComputerHealthProbe: ComputerHealthProbing {
    private enum Component: Sendable {
        case disk(DiskHealthSnapshot)
        case capacity(CapacityTrendSnapshot)
        case backup(TimeMachineSnapshot)
        case stability(StabilitySummary)
        case battery(BatteryHealthEvidence)
    }

    func probe() async throws -> ComputerHealthSnapshot {
        try Task.checkCancellation()

        var disk: DiskHealthSnapshot?
        var capacity: CapacityTrendSnapshot?
        var backup: TimeMachineSnapshot?
        var stability: StabilitySummary?
        var batteryEvidence: BatteryHealthEvidence?

        try await withThrowingTaskGroup(of: Component.self) { group in
            group.addTask(priority: .utility) {
                .disk(DiskHealthService().snapshot())
            }
            group.addTask(priority: .utility) {
                .capacity(Self.capacityTrendSnapshot())
            }
            group.addTask(priority: .utility) {
                .backup(TimeMachineStatusService().snapshot())
            }
            group.addTask(priority: .utility) {
                .stability(StabilityReportService().snapshot())
            }
            group.addTask(priority: .utility) {
                .battery(try await BatteryHealthRuntime.shared.evidence())
            }

            for try await component in group {
                if Task.isCancelled {
                    group.cancelAll()
                }
                switch component {
                case let .disk(value): disk = value
                case let .capacity(value): capacity = value
                case let .backup(value): backup = value
                case let .stability(value): stability = value
                case let .battery(value): batteryEvidence = value
                }
            }
        }

        try Task.checkCancellation()
        guard let disk, let capacity, let backup, let stability, let batteryEvidence else {
            throw ComputerHealthRefreshError.readFailed
        }
        return ComputerHealthSnapshot(
            generatedAt: Date(),
            disk: disk,
            capacity: capacity,
            backup: backup,
            stability: stability,
            batteryEvidence: batteryEvidence
        )
    }

    private static func capacityTrendSnapshot() -> CapacityTrendSnapshot {
        let history = CapacityHistoryService()
        let recordedAt = Date()
        if let capacity = StorageCapacityService.snapshot() {
            let currentPoint = CapacityHistoryPoint(
                recordedAt: recordedAt,
                totalBytes: capacity.totalBytes,
                availableBytes: capacity.availableBytes,
                availableForImportantUsageBytes: capacity.availableForImportantUsageBytes
            )
            if let trend = try? history.trendSnapshot(including: currentPoint) {
                return trend
            }
        }
        return CapacityTrendSnapshot(
            availability: .unavailable,
            status: .unavailable,
            totalBytes: nil,
            availableBytes: nil,
            availableForImportantUsageBytes: nil,
            sevenDayDeltaBytes: nil,
            thirtyDayDeltaBytes: nil,
            recordedAt: recordedAt
        )
    }
}

private actor TransientComputerHealthHistoryRepository: ComputerHealthHistoryPersisting {
    private var entries: [ComputerHealthHistoryEntry] = []

    func load() async -> [ComputerHealthHistoryEntry] { entries }

    func save(_ entry: ComputerHealthHistoryEntry) async throws {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let incomingDay = calendar.startOfDay(for: entry.recordedAt)
        entries.removeAll { calendar.startOfDay(for: $0.recordedAt) == incomingDay }
        entries.append(entry)
        entries.sort { $0.recordedAt > $1.recordedAt }
        entries = Array(entries.prefix(ComputerHealthHistoryRepository.maximumEntryCount))
    }
}

private actor DiscardingCapacityHistoryRepository: CapacityHistoryPersisting {
    func save(_ point: CapacityHistoryPoint) async throws {}
}

@MainActor
final class ComputerHealthStore: ObservableObject {
    @Published private(set) var snapshot: ComputerHealthSnapshot?
    @Published private(set) var evaluation: ComputerHealthEvaluation?
    @Published private(set) var history: [ComputerHealthHistoryEntry] = []
    @Published private(set) var storageForecast: StoragePressureForecast?
    @Published private(set) var batteryTrend: BatteryWearTrend?
    @Published private(set) var thermalReadiness: ThermalReadiness = .unknown
    @Published private(set) var menuBarSummary: MenuBarHealthSummary?
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: ComputerHealthRefreshError?
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var batterySettingsAdjustmentState: BatterySettingsAdjustmentState = .idle
    @Published private(set) var batteryPowerModes: BatteryPowerModes = .unavailable
    @Published private(set) var hasCompletedBatteryPowerModeRead = false
    @Published private(set) var batteryPowerModeAdjustmentState: BatteryPowerModeAdjustmentState = .idle

    private struct RefreshOperation {
        let generation: UUID
        let task: Task<Result<PreparedHealthRefresh, ComputerHealthRefreshError>, Never>
    }

    private struct PreparedHealthRefresh: Sendable {
        let snapshot: ComputerHealthSnapshot
        let evaluation: ComputerHealthEvaluation
        let history: [ComputerHealthHistoryEntry]
        let storageForecast: StoragePressureForecast?
        let batteryTrend: BatteryWearTrend?
        let thermalReadiness: ThermalReadiness
        let historyEntry: ComputerHealthHistoryEntry
        let capacityPoint: CapacityHistoryPoint?
    }

    private struct ValidatedCapacityEvidence: Sendable {
        let totalBytes: Int64
        let availableForImportantUsageBytes: Int64?
    }

    private let probe: any ComputerHealthProbing
    private let freshnessTTL: TimeInterval
    private let now: @MainActor () -> Date
    private let batterySettingsVerifier: any BatterySettingsVerifying
    private let batteryPowerModeController: any BatteryPowerModeControlling
    private let historyRepository: any ComputerHealthHistoryPersisting
    private let capacityHistoryRepository: any CapacityHistoryPersisting
    private let thermalReadinessProvider: @Sendable () -> ThermalReadiness
    private var refreshOperation: RefreshOperation?
    private var lastNetworkResult: NetworkSpeedTestResult?
    private var hasRestoredCachedDiskHealth = false
    private var batteryPowerModePublicationGeneration: UInt64 = 0
    private var pendingBatteryPowerModeIntent: BatteryPowerModeIntent?
    private var batteryPowerModeIntentTask: Task<Void, Never>?

    private struct BatteryPowerModeIntent {
        let generation: UInt64
        let source: BatteryPowerSource
        let mode: BatteryPowerMode
    }

    convenience init(
        freshnessTTL: TimeInterval = 600,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.init(
            probe: DefaultComputerHealthProbe(),
            freshnessTTL: freshnessTTL,
            now: now,
            historyRepository: ComputerHealthHistoryRepository(),
            capacityHistoryRepository: CapacityHistoryRepository(),
            thermalReadinessProvider: Self.liveThermalReadiness
        )
    }

    init(
        probe: any ComputerHealthProbing,
        freshnessTTL: TimeInterval = 600,
        now: @escaping @MainActor () -> Date = { Date() },
        batterySettingsVerifier: (any BatterySettingsVerifying)? = nil,
        batteryPowerModeController: (any BatteryPowerModeControlling)? = nil,
        historyRepository: (any ComputerHealthHistoryPersisting)? = nil,
        capacityHistoryRepository: (any CapacityHistoryPersisting)? = nil,
        thermalReadinessProvider: @escaping @Sendable () -> ThermalReadiness = { .unknown }
    ) {
        self.probe = probe
        self.freshnessTTL = max(0, freshnessTTL)
        self.now = now
        self.batterySettingsVerifier = batterySettingsVerifier
            ?? Self.makeDefaultBatterySettingsVerifier()
        self.batteryPowerModeController = batteryPowerModeController
            ?? BatteryHealthRuntime.shared
        self.historyRepository = historyRepository
            ?? TransientComputerHealthHistoryRepository()
        self.capacityHistoryRepository = capacityHistoryRepository
            ?? DiscardingCapacityHistoryRepository()
        self.thermalReadinessProvider = thermalReadinessProvider
    }

    func refresh(force: Bool = false) async {
        await verifyBatterySettingsAfterReturn()
        await restoreCachedDiskHealthIfNeeded()

        if !force, let refreshOperation {
            let result = await refreshOperation.task.value
            await finish(result, for: refreshOperation)
            return
        }

        if !force, hasFreshSnapshot {
            return
        }

        if force {
            refreshOperation?.task.cancel()
        }

        let generation = UUID()
        let probe = self.probe
        let historyRepository = self.historyRepository
        let thermalReadinessProvider = self.thermalReadinessProvider
        let task = Task.detached(
            priority: .utility
        ) { () -> Result<PreparedHealthRefresh, ComputerHealthRefreshError> in
            do {
                let snapshot = try await probe.probe()
                try Task.checkCancellation()
                let loadedHistory = await historyRepository.load()
                try Task.checkCancellation()
                let sameModelHistory = loadedHistory.filter {
                    $0.modelVersion == ComputerHealthHistoryEntry.currentModelVersion
                        && $0.evaluation.modelVersion == ComputerHealthEvaluation.currentModelVersion
                }
                let thermalReadiness = thermalReadinessProvider()
                try Task.checkCancellation()
                return .success(Self.prepare(
                    snapshot: snapshot,
                    priorHistory: sameModelHistory,
                    thermalReadiness: thermalReadiness
                ))
            } catch is CancellationError {
                return .failure(.cancelled)
            } catch let error as ComputerHealthRefreshError {
                return .failure(error)
            } catch {
                return .failure(.readFailed)
            }
        }
        refreshOperation = RefreshOperation(generation: generation, task: task)
        isRefreshing = true
        error = nil

        let result = await task.value
        await finish(result, for: RefreshOperation(generation: generation, task: task))
    }

    func prepareMenuBarHealthOnLaunch() async {
        await restoreCachedDiskHealthIfNeeded()
        await refresh()
    }

    func recordNetworkSpeedResult(_ result: NetworkSpeedTestResult) {
        guard result.downloadMbps.isFinite,
              result.downloadMbps >= 0,
              result.uploadMbps.isFinite,
              result.uploadMbps >= 0 else {
            return
        }
        lastNetworkResult = result
        rebuildMenuBarSummary()
    }

    func refreshBatteryPowerModes() async {
        guard !batteryPowerModeAdjustmentState.isChanging else { return }
        let generation = batteryPowerModePublicationGeneration
        guard let modes = await batteryPowerModeController.readPowerModes(),
              !Task.isCancelled,
              generation == batteryPowerModePublicationGeneration,
              !batteryPowerModeAdjustmentState.isChanging else { return }
        batteryPowerModes = modes
        hasCompletedBatteryPowerModeRead = true
    }

    func changeBatteryPowerMode(
        source: BatteryPowerSource,
        mode: BatteryPowerMode
    ) async {
        batteryPowerModePublicationGeneration &+= 1
        pendingBatteryPowerModeIntent = BatteryPowerModeIntent(
            generation: batteryPowerModePublicationGeneration,
            source: source,
            mode: mode
        )
        batteryPowerModeAdjustmentState = .changing(source: source, mode: mode)

        if let batteryPowerModeIntentTask {
            await batteryPowerModeIntentTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.driveBatteryPowerModeIntents()
        }
        batteryPowerModeIntentTask = task
        await task.value
    }

    private func driveBatteryPowerModeIntents() async {
        defer { batteryPowerModeIntentTask = nil }
        while let intent = pendingBatteryPowerModeIntent {
            pendingBatteryPowerModeIntent = nil
            await performBatteryPowerModeIntent(intent)
        }
    }

    private func performBatteryPowerModeIntent(
        _ intent: BatteryPowerModeIntent
    ) async {
        let result = await batteryPowerModeController.changePowerMode(
            source: intent.source,
            mode: intent.mode
        )
        guard intent.generation == batteryPowerModePublicationGeneration else {
            return
        }
        let source = intent.source
        let mode = intent.mode
        guard !Task.isCancelled else {
            batteryPowerModeAdjustmentState = .cancelled(source: source, mode: mode)
            return
        }

        switch result {
        case let .changed(modes):
            // Publish the checkmark only after the service has re-sampled and
            // verified the exact source and mode.
            batteryPowerModes = modes
            hasCompletedBatteryPowerModeRead = true
            batteryPowerModeAdjustmentState = .changed(source: source, mode: mode)
        case .busy:
            batteryPowerModeAdjustmentState = .failed(source: source, mode: mode)
        case .unsupported:
            batteryPowerModeAdjustmentState = .unsupported(source: source, mode: mode)
        case .cancelled:
            batteryPowerModeAdjustmentState = .cancelled(source: source, mode: mode)
        case .permissionDenied:
            batteryPowerModeAdjustmentState = .permissionDenied(source: source, mode: mode)
        case .timedOut:
            batteryPowerModeAdjustmentState = .timedOut(source: source, mode: mode)
        case .failed:
            batteryPowerModeAdjustmentState = .failed(source: source, mode: mode)
        case let .verificationFailed(observed):
            batteryPowerModes = observed
            hasCompletedBatteryPowerModeRead = true
            batteryPowerModeAdjustmentState = .verificationFailed(source: source, mode: mode)
        }
    }

    func beginBatterySettingsAdjustment() async {
        guard batterySettingsAdjustmentState != .openingSettings,
              batterySettingsAdjustmentState != .verifying else { return }
        batterySettingsAdjustmentState = .openingSettings
        let result = await batterySettingsVerifier.beginAdjustment()
        guard !Task.isCancelled else {
            batterySettingsAdjustmentState = .idle
            return
        }
        switch result {
        case .opened:
            batterySettingsAdjustmentState = .awaitingVerification
        case .baselineUnavailable:
            batterySettingsAdjustmentState = .unverifiable
        case .failedToOpen:
            batterySettingsAdjustmentState = .failedToOpen
        case .superseded:
            batterySettingsAdjustmentState = .idle
        }
    }

    func verifyBatterySettingsAfterReturn() async {
        guard batterySettingsAdjustmentState == .awaitingVerification
                || batterySettingsAdjustmentState == .unchanged else { return }
        batterySettingsAdjustmentState = .verifying
        let result = await batterySettingsVerifier.verifyAfterSettingsChange()
        guard !Task.isCancelled else {
            batterySettingsAdjustmentState = .awaitingVerification
            return
        }
        switch result {
        case .changed:
            batterySettingsAdjustmentState = .verified
        case .unchanged:
            batterySettingsAdjustmentState = .unchanged
        case .expired:
            batterySettingsAdjustmentState = .expired
        case .unverifiable:
            batterySettingsAdjustmentState = .unverifiable
        }
    }

    func openBatterySettingsWithoutVerification() {
        guard batterySettingsAdjustmentState == .unverifiable else { return }
        let didOpen = batterySettingsVerifier.openSettingsWithoutVerification()
        batterySettingsAdjustmentState = didOpen ? .unverifiable : .failedToOpen
    }

    private var hasFreshSnapshot: Bool {
        guard snapshot != nil, let lastRefreshAt, freshnessTTL > 0 else {
            return false
        }
        let age = now().timeIntervalSince(lastRefreshAt)
        return age >= 0 && age < freshnessTTL
    }

    private func restoreCachedDiskHealthIfNeeded() async {
        guard !hasRestoredCachedDiskHealth,
              menuBarSummary?.diskRemainingLifePercent == nil else { return }
        hasRestoredCachedDiskHealth = true
        let loadedHistory = await historyRepository.load()
        guard let percent = Self.latestDiskRemainingLifePercent(in: loadedHistory),
              let recordedAt = loadedHistory
                .filter({ $0.diskRemainingLifePercent == percent })
                .max(by: { $0.recordedAt < $1.recordedAt })?
                .recordedAt else { return }
        let fallback = MenuBarHealthSummary(
            generatedAt: recordedAt,
            diskRemainingLifePercent: percent
        )
        menuBarSummary = menuBarSummary?.retainingDiskHealth(from: fallback) ?? fallback
    }

    private func finish(
        _ result: Result<PreparedHealthRefresh, ComputerHealthRefreshError>,
        for operation: RefreshOperation
    ) async {
        guard refreshOperation?.generation == operation.generation else { return }

        refreshOperation = nil
        isRefreshing = false
        switch result {
        case let .success(prepared):
            snapshot = prepared.snapshot
            evaluation = prepared.evaluation
            history = prepared.history
            storageForecast = prepared.storageForecast
            batteryTrend = prepared.batteryTrend
            thermalReadiness = prepared.thermalReadiness
            rebuildMenuBarSummary()
            lastRefreshAt = now()
            try? await historyRepository.save(prepared.historyEntry)
            if let capacityPoint = prepared.capacityPoint {
                try? await capacityHistoryRepository.save(capacityPoint)
            }
        case let .failure(error):
            self.error = error
        }
    }

    private nonisolated static func prepare(
        snapshot: ComputerHealthSnapshot,
        priorHistory: [ComputerHealthHistoryEntry],
        thermalReadiness: ThermalReadiness
    ) -> PreparedHealthRefresh {
        let referenceDate = snapshot.generatedAt.timeIntervalSinceReferenceDate.isFinite
            ? snapshot.generatedAt
            : Date()
        let provisionalEvaluation = ComputerHealthScoring.evaluate(
            snapshot: snapshot,
            history: priorHistory,
            referenceDate: referenceDate
        )
        let confidence = HealthConfidenceScoring.evaluate(
            coverage: provisionalEvaluation.coverage,
            components: provisionalEvaluation.components,
            history: priorHistory,
            referenceDate: referenceDate
        )
        let evaluation = ComputerHealthScoring.evaluate(
            snapshot: snapshot,
            history: priorHistory,
            referenceDate: referenceDate,
            confidence: confidence
        )
        let capacityEvidence = validatedCapacityEvidence(from: snapshot.capacity)
        let currentDiskRemainingLifePercent = snapshot.disk.availability.hasUsableData
            && snapshot.disk.status != .unavailable
            ? validDiskRemainingLifePercent(snapshot.disk.remainingLifePercent)
            : nil
        let diskRemainingLifePercent = currentDiskRemainingLifePercent
            ?? latestDiskRemainingLifePercent(in: priorHistory)
        let historyEntry = ComputerHealthHistoryEntry(
            recordedAt: referenceDate,
            evaluation: evaluation,
            totalBytes: capacityEvidence?.totalBytes,
            availableForImportantUsageBytes: capacityEvidence?.availableForImportantUsageBytes,
            diskRemainingLifePercent: diskRemainingLifePercent,
            maximumCapacityPercent: snapshot.battery?.maximumCapacityPercent,
            batteryCycleCount: snapshot.battery?.cycleCount,
            latestVerifiedCompleteBackupAt: snapshot.backup.latestCompleteBackup
        )
        let mergedHistory = mergedHistory(
            priorHistory,
            replacingWith: historyEntry
        )
        return PreparedHealthRefresh(
            snapshot: snapshot,
            evaluation: evaluation,
            history: mergedHistory,
            storageForecast: SpacePressureForecasting.evaluate(
                history: mergedHistory,
                referenceDate: referenceDate
            ),
            batteryTrend: BatteryWearTrendAnalysis.evaluate(
                history: mergedHistory,
                referenceDate: referenceDate
            ),
            thermalReadiness: thermalReadiness,
            historyEntry: historyEntry,
            capacityPoint: capacityPoint(from: snapshot)
        )
    }

    private nonisolated static func mergedHistory(
        _ priorHistory: [ComputerHealthHistoryEntry],
        replacingWith current: ComputerHealthHistoryEntry
    ) -> [ComputerHealthHistoryEntry] {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        var latestByDay: [Date: ComputerHealthHistoryEntry] = [:]
        for entry in priorHistory + [current] {
            guard entry.recordedAt.timeIntervalSinceReferenceDate.isFinite else { continue }
            let day = calendar.startOfDay(for: entry.recordedAt)
            if let existing = latestByDay[day], existing.recordedAt > entry.recordedAt {
                continue
            }
            latestByDay[day] = entry
        }
        let newestFirst = latestByDay.values.sorted { $0.recordedAt > $1.recordedAt }
        guard let newest = newestFirst.first,
              let cutoff = calendar.date(
                byAdding: .day,
                value: -(ComputerHealthHistoryRepository.maximumEntryCount - 1),
                to: calendar.startOfDay(for: newest.recordedAt)
              ) else { return [] }
        return Array(newestFirst.filter {
            calendar.startOfDay(for: $0.recordedAt) >= cutoff
        }.prefix(ComputerHealthHistoryRepository.maximumEntryCount))
    }

    private nonisolated static func capacityPoint(
        from snapshot: ComputerHealthSnapshot
    ) -> CapacityHistoryPoint? {
        let capacity = snapshot.capacity
        guard capacity.availability.hasUsableData,
              let totalBytes = capacity.totalBytes,
              let availableBytes = capacity.availableBytes,
              totalBytes > 0,
              availableBytes >= 0,
              availableBytes <= totalBytes else { return nil }
        if let important = capacity.availableForImportantUsageBytes,
           important < 0 || important > totalBytes
        {
            return nil
        }
        return CapacityHistoryPoint(
            recordedAt: capacity.recordedAt,
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            availableForImportantUsageBytes: capacity.availableForImportantUsageBytes
        )
    }

    private nonisolated static func validatedCapacityEvidence(
        from capacity: CapacityTrendSnapshot
    ) -> ValidatedCapacityEvidence? {
        guard capacity.availability.hasUsableData,
              let totalBytes = capacity.totalBytes,
              totalBytes > 0 else { return nil }
        let importantBytes = capacity.availableForImportantUsageBytes.flatMap { value in
            value >= 0 && value <= totalBytes ? value : nil
        }
        return ValidatedCapacityEvidence(
            totalBytes: totalBytes,
            availableForImportantUsageBytes: importantBytes
        )
    }

    private nonisolated static func latestDiskRemainingLifePercent(
        in history: [ComputerHealthHistoryEntry]
    ) -> Int? {
        history
            .filter { validDiskRemainingLifePercent($0.diskRemainingLifePercent) != nil }
            .max { $0.recordedAt < $1.recordedAt }?
            .diskRemainingLifePercent
    }

    private nonisolated static func validDiskRemainingLifePercent(_ value: Int?) -> Int? {
        guard let value, (0...100).contains(value) else { return nil }
        return value
    }

    private nonisolated static func liveThermalReadiness() -> ThermalReadiness {
        switch SystemMonitorService.currentThermalState() {
        case .nominal:
            .ready
        case .fair:
            .elevated
        case .serious:
            .constrained
        case .critical:
            .critical
        case .unknown:
            .unknown
        }
    }

    deinit {
        refreshOperation?.task.cancel()
    }

    private func rebuildMenuBarSummary() {
        let previousSummary = menuBarSummary
        let historicalPercent = Self.latestDiskRemainingLifePercent(in: history)
        let base: MenuBarHealthSummary?
        if let snapshot {
            base = MenuBarHealthSummary(snapshot: snapshot)
                .retainingDiskHealth(
                    from: previousSummary,
                    fallbackRemainingLifePercent: historicalPercent
                )
        } else if let result = lastNetworkResult {
            base = MenuBarHealthSummary(generatedAt: result.testedAt)
        } else {
            base = nil
        }

        guard let base else {
            menuBarSummary = nil
            return
        }
        if let result = lastNetworkResult {
            menuBarSummary = base.includingNetworkResult(
                downloadMbps: result.downloadMbps,
                uploadMbps: result.uploadMbps,
                testedAt: result.testedAt
            )
        } else {
            menuBarSummary = base
        }
    }

    private static func makeDefaultBatterySettingsVerifier() -> any BatterySettingsVerifying {
        return BatterySettingsVerifier(reader: {
            try? await BatteryHealthRuntime.shared.snapshot()
        })
    }
}
