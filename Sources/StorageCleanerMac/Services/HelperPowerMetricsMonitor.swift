import Combine
import FanControlShared
import Foundation

enum HelperPowerMetricsAvailability: Equatable { case ready, needsHelper, needsUpdate }

enum HelperPowerMetricsState: Equatable {
    case needsHelper, needsUpdate, sampling
    case available(PowermetricsSample, sampledAt: Date)
    case failed(PowermetricsFailure)
}

/// The app's request bracket, deliberately separate from the helper's optional
/// measurement interval. sampledAt remains a presentation/audit wall clock.
struct HelperPowerMetricsReading: Equatable, Sendable {
    let sample: PowermetricsSample
    let requestStartMonotonicNs: UInt64
    let responseReceivedMonotonicNs: UInt64
    let clockDomain: String
    let requestSequence: UInt64

    init(sample: PowermetricsSample, requestStartMonotonicNs: UInt64, responseReceivedMonotonicNs: UInt64,
         clockDomain: String, requestSequence: UInt64 = 0) {
        self.sample = sample; self.requestStartMonotonicNs = requestStartMonotonicNs
        self.responseReceivedMonotonicNs = responseReceivedMonotonicNs; self.clockDomain = clockDomain
        self.requestSequence = requestSequence
    }
}

/// A single app-side demand stream shared by the energy page and mini modules.
/// The SMC whole-computer reading and the existing energy accumulator are separate.
@MainActor
final class HelperPowerMetricsMonitor: ObservableObject {
    nonisolated static let minimumInterval: TimeInterval = 2
    nonisolated static let maximumReadingAge: TimeInterval = 6
    @Published private(set) var state: HelperPowerMetricsState = .needsHelper
    @Published private(set) var latestReading: HelperPowerMetricsReading?
    /// Session observers exclude a request already dispatched before reset.
    private(set) var requestSequence: UInt64 = 0
    private var consumers: Set<UUID> = []
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var lastRequestStart: TimeInterval?
    private var requestInFlight = false
    private var residentCadence: MenuBarSamplingCadence?
    private var usesResidentScheduler = false
    private var residentSuspended = false
    @Published private(set) var lastFailure: PowermetricsFailure?
    struct StoredReading: Sendable {
        let date: Date
        let sample: PowermetricsSample
        var byteCost: Int { 512 + sample.clusters.reduce(0) { $0 + 128 + 2 * $1.name.utf8.count } }
    }
    private(set) var history: [StoredReading] = []
    private(set) var historyBytes = 0
    private let availability: @MainActor () -> HelperPowerMetricsAvailability
    private let request: @MainActor () async -> PowermetricsResult
    private let now: @MainActor () -> TimeInterval
    private let wallClock: @MainActor () -> Date
    private let automaticSampling: Bool
    private let monotonicNanoseconds: @MainActor () -> UInt64
    private let clockDomain: String
    private let sleep: @MainActor (TimeInterval) async throws -> Void
    private var observers: [UUID: @MainActor (HelperPowerMetricsReading) -> Void] = [:]
    private var measurementConsumers: [UUID: UUID] = [:]

    init(availability: @escaping @MainActor () -> HelperPowerMetricsAvailability,
         request: @escaping @MainActor () async -> PowermetricsResult,
         now: @escaping @MainActor () -> TimeInterval = { PowermetricsMonotonicClock.seconds },
         wallClock: @escaping @MainActor () -> Date = { Date() }, automaticSampling: Bool = true,
         monotonicNanoseconds: @escaping @MainActor () -> UInt64 = { PowermetricsMonotonicClock.nanoseconds },
         clockDomain: String = PowermetricsMonotonicClock.clockDomain,
         sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.availability = availability; self.request = request
        self.now = now; self.wallClock = wallClock; self.automaticSampling = automaticSampling
        self.monotonicNanoseconds = monotonicNanoseconds; self.clockDomain = clockDomain; self.sleep = sleep
    }

    var hasDemand: Bool { !consumers.isEmpty }
    /// Capability readback does not register demand or launch a sample.
    var capabilityAvailability: HelperPowerMetricsAvailability { availability() }

    func useResidentScheduler() {
        usesResidentScheduler = true
        worker?.cancel()
        generation &+= 1
        // Keep the old worker until its physical request drains.
    }

    func setResidentCadence(_ cadence: MenuBarSamplingCadence) {
        residentCadence = cadence
        setResidentSuspended(cadence.suspended)
        reconcileDemandWorker()
    }

    func setResidentSuspended(_ suspended: Bool) {
        guard residentSuspended != suspended else { return }
        residentSuspended = suspended
        if suspended { generation &+= 1; worker?.cancel() }
        else { reconcileDemandWorker() }
    }

    func updateConsumer(_ id: UUID, visible: Bool) {
        if visible { consumers.insert(id) } else { consumers.remove(id) }
        if usesResidentScheduler { reconcileDemandWorker(); return }
        guard hasDemand else {
            generation &+= 1
            worker?.cancel()
            // Keep the cancelled worker until its XPC await drains. Reopening
            // restarts at the next due time after drain, with no second worker.
            // No previous reading is presented as live on reopening.
            state = .sampling
            latestReading = nil
            return
        }
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard shouldRunDemandWorker, automaticSampling, worker == nil else { return }
        let expectedGeneration = generation
        worker = Task { [weak self] in
            defer {
                self?.worker = nil
                if let self, self.shouldRunDemandWorker, self.generation != expectedGeneration || Task.isCancelled {
                    self.startWorkerIfNeeded()
                }
            }
            while !Task.isCancelled {
                guard let self, self.shouldRunDemandWorker, self.generation == expectedGeneration else { return }
                await self.sampleIfDue()
                guard self.shouldRunDemandWorker, self.generation == expectedGeneration, !Task.isCancelled else { return }
                // Due is aligned to the previous request START. A one-second
                // request therefore leaves one second, not two, to sleep.
                let remaining = self.delayUntilNextRequest
                do {
                    if remaining > 0 { try await self.sleep(remaining) }
                    else { await Task.yield() }
                } catch { return }
            }
        }
    }

    /// Observing never creates demand or another sampling task.
    @discardableResult
    func observeReadings(_ observer: @escaping @MainActor (HelperPowerMetricsReading) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        reconcileDemandWorker()
        return id
    }

    /// Fast measurement cadence belongs to this consumer's visible lease.
    /// A passive observer or another visible page cannot keep it alive.
    @discardableResult
    func observeReadings(for consumerID: UUID,
                         _ observer: @escaping @MainActor (HelperPowerMetricsReading) -> Void) -> UUID {
        let id = observeReadings(observer)
        measurementConsumers[id] = consumerID
        reconcileDemandWorker()
        return id
    }

    func removeReadingObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
        measurementConsumers.removeValue(forKey: id)
        reconcileDemandWorker()
    }

    // Observers alone never request. Only a collecting visible v11 session's
    // own consumer can request the existing stream at its 2 s rate.
    // Resident UI demand keeps D74's 5/60/180 s policy, including Low Power Mode.
    private var hasMeasurementDemand: Bool { measurementConsumers.values.contains { consumers.contains($0) } }
    private var samplingInterval: TimeInterval {
        guard usesResidentScheduler, let cadence = residentCadence else { return Self.minimumInterval }
        if cadence.helperPower == MenuBarPerformancePolicy.lowPowerHelperPowerInterval { return cadence.helperPower }
        if hasMeasurementDemand { return Self.minimumInterval }
        return hasDemand ? MenuBarPerformancePolicy.visibleHelperPowerInterval : cadence.helperPower
    }
    private var shouldRunDemandWorker: Bool {
        hasDemand && !residentSuspended && (!usesResidentScheduler ||
            (hasMeasurementDemand && samplingInterval == Self.minimumInterval))
    }
    private func reconcileDemandWorker() {
        if shouldRunDemandWorker { startWorkerIfNeeded() }
        else { worker?.cancel() } // its defer owns clearing the slot after drain
    }

    private var delayUntilNextRequest: TimeInterval {
        // A helper that became unavailable after a successful request must not
        // turn an overdue deadline into a yield-only busy loop.
        switch state {
        case .needsHelper, .needsUpdate: return samplingInterval
        default: break
        }
        guard !requestInFlight, let lastRequestStart else { return samplingInterval }
        let time = now()
        guard time.isFinite, time >= lastRequestStart else { return samplingInterval }
        return max(0, samplingInterval - (time - lastRequestStart))
    }

    /// Internal seam for deterministic tests; eligibility is enforced here too.
    func sampleIfDue() async {
        guard (usesResidentScheduler || hasDemand), !residentSuspended,
              !requestInFlight, !Task.isCancelled else { return }
        let interval = samplingInterval
        switch availability() {
        case .needsHelper: state = .needsHelper; latestReading = nil; return
        case .needsUpdate: state = .needsUpdate; latestReading = nil; return
        case .ready: break
        }
        let time = now()
        guard time.isFinite,
              lastRequestStart.map({ time - $0 >= interval }) ?? true else { return }
        requestSequence &+= 1
        let dispatchedSequence = requestSequence
        requestInFlight = true
        let expectedGeneration = generation
        defer { requestInFlight = false }
        if case .available = state {} else { state = .sampling }
        let requestStart = monotonicNanoseconds()
        // Set the throttle origin after the envelope's start capture, so work
        // before dispatch cannot shave time off the next >=2 s request bracket.
        lastRequestStart = now()
        let result = await request()
        let responseReceived = monotonicNanoseconds()
        guard (usesResidentScheduler || hasDemand), !residentSuspended,
              generation == expectedGeneration, !Task.isCancelled else { return }
        // Approval/version may have changed while the XPC call was in flight.
        switch availability() {
        case .needsHelper: state = .needsHelper; latestReading = nil; return
        case .needsUpdate: state = .needsUpdate; latestReading = nil; return
        case .ready: break
        }
        switch result {
        case .sample(let sample):
            if sample.isValid {
                lastFailure = nil
                let at = wallClock()
                state = .available(sample, sampledAt: at)
                let stored = StoredReading(date: at, sample: sample)
                history.append(stored)
                historyBytes += stored.byteCost
                while historyBytes > MenuBarPerformancePolicy.processCacheByteLimit
                    || history.count > MenuBarHistoryRetention.maximumPointCount
                    || history.first.map({ at.timeIntervalSince($0.date) > MenuBarHistoryRetention.duration }) == true {
                    historyBytes -= history.removeFirst().byteCost
                }
                let reading = HelperPowerMetricsReading(sample: sample, requestStartMonotonicNs: requestStart,
                    responseReceivedMonotonicNs: responseReceived, clockDomain: clockDomain,
                    requestSequence: dispatchedSequence)
                latestReading = reading
                for observer in Array(observers.values) { observer(reading) }
            } else { publishFailure(.invalidOutput) }
        case .failure(let failure):
            publishFailure(failure)
        }
    }

    private func publishFailure(_ failure: PowermetricsFailure) {
        latestReading = nil // failed requests never become fresh v11 telemetry
        lastFailure = failure
        if failure == .unavailable || failure == .unauthorized { state = .needsHelper }
        else if usesResidentScheduler, case .available = state { /* retain original date */ }
        else { state = .failed(failure) }
    }

    deinit { worker?.cancel() }
}
