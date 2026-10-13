import FanControlShared
import Foundation

/// An observer/consumer of the existing monitor, never a second sampler.
/// The caller supplies actual run-page visibility and explicitly ends its lease.
@MainActor
final class MSeriesV11TelemetryBridge {
    struct Reading: Equatable, Sendable {
        let telemetry: MSeriesV11Telemetry
        let clusters: [PowermetricsSample.ClusterFrequency]
        let gpuMegahertz: Double?
        let missingReasons: [String]
    }

    private let monitor: HelperPowerMetricsMonitor
    private let consumerID = UUID()
    private let now: @MainActor () -> UInt64
    private let maximumSamples: Int
    private var observerID: UUID?
    private var visibleSince: UInt64?
    private var firstAcceptedRequestSequence: UInt64 = 1
    private var seenSamples: Set<String> = []
    private(set) var isVisible = false
    private(set) var isCollecting = false
    private(set) var readings: [Reading] = []
    private(set) var overflowed = false
    private var activeSessionID: UUID?
    private(set) var liveObservation: MSeriesV11LiveObservation?
    func present(_ observation: MSeriesV11LiveObservation) {
        guard isCollecting, activeSessionID == observation.sessionID else { return }
        liveObservation = observation
    }

    init(monitor: HelperPowerMetricsMonitor, maximumSamples: Int = 1_024,
         now: @escaping @MainActor () -> UInt64 = { PowermetricsMonotonicClock.nanoseconds }) {
        self.monitor = monitor; self.maximumSamples = min(1_024, max(1, maximumSamples)); self.now = now
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        visibleSince = visible ? now() : nil
        firstAcceptedRequestSequence = monitor.requestSequence &+ 1
        updateDemand()
    }

    /// Starts a fresh run without replaying the monitor's latest cached reading.
    /// Surface visibility is retained across finish -> beginSession.
    func beginSession(sessionID: UUID? = nil) {
        reset()
        activeSessionID = sessionID
        isCollecting = true
        updateDemand()
    }

    /// Clears only this run's evidence. It neither clears the shared monitor nor
    /// bypasses its throttle, and excludes a prior run's in-flight request even
    /// when reset and request start happen on the same clock tick.
    func reset() {
        activeSessionID = nil
        liveObservation = nil
        readings.removeAll(keepingCapacity: true)
        seenSamples.removeAll(keepingCapacity: true)
        overflowed = false
        visibleSince = isVisible ? now() : nil
        firstAcceptedRequestSequence = monitor.requestSequence &+ 1
    }

    private func updateDemand() {
        if isVisible, isCollecting, observerID == nil {
            observerID = monitor.observeReadings(for: consumerID) { [weak self] in self?.receive($0) }
        }
        monitor.updateConsumer(consumerID, visible: isVisible && isCollecting)
    }

    /// Must be called by the owning run on cancel/completion, before releasing it.
    func finish() {
        activeSessionID = nil
        liveObservation = nil
        isCollecting = false
        monitor.updateConsumer(consumerID, visible: false)
        if let observerID { monitor.removeReadingObserver(observerID) }
        observerID = nil
    }

    var missingReasons: [String] {
        var reasons = Set(readings.flatMap(\.missingReasons))
        if !isVisible { reasons.insert("telemetryNotVisible") }
        if !isCollecting { reasons.insert("telemetrySessionInactive") }
        if overflowed { reasons.insert("telemetryLimitExceeded") }
        switch monitor.state {
        case .needsHelper: reasons.insert("helperUnavailable")
        case .needsUpdate: reasons.insert("helperNeedsUpdate")
        case .sampling: if readings.isEmpty { reasons.insert("telemetryPending") }
        case .failed(let failure): reasons.insert("helper-" + failure.rawValue)
        case .available: break
        }
        return reasons.sorted()
    }

    private func receive(_ reading: HelperPowerMetricsReading) {
        guard isVisible, isCollecting, let visibleSince, reading.requestStartMonotonicNs >= visibleSince,
              reading.requestSequence >= firstAcceptedRequestSequence, !overflowed else { return }
        let converted = Self.convert(reading)
        let identity = (converted.telemetry.helperBootID ?? "") + ":" + converted.telemetry.sampleID
        guard !seenSamples.contains(identity) else { return }
        guard readings.count < maximumSamples else {
            // Signal a failed evidence budget; never silently truncate history.
            overflowed = true
            return
        }
        seenSamples.insert(identity)
        readings.append(converted)
    }

    /// Pure conversion seam. A helper claim is accepted only with a coherent,
    /// same-domain interval inside this request; request duration is never used
    /// to infer the native measurement start/end.
    nonisolated static func convert(_ reading: HelperPowerMetricsReading) -> Reading {
        let sample = reading.sample
        let timing = sample.timing
        let bracketValid = reading.clockDomain == PowermetricsMonotonicClock.clockDomain
            && reading.responseReceivedMonotonicNs > reading.requestStartMonotonicNs
        var reasons: [String] = []
        var measurementStart: UInt64?
        var measurementEnd: UInt64?
        if let timing, timing.isWellFormed, timing.timestampQuality == .helperMeasured,
           timing.clockDomain == reading.clockDomain, bracketValid,
           let start = timing.measurementStartMonotonicNs, let end = timing.measurementEndMonotonicNs,
           end > start, start >= reading.requestStartMonotonicNs, end <= reading.responseReceivedMonotonicNs,
           sample.isValid, abs(Double(end - start) / 1e9 - sample.durationSeconds) <= 0.000001 {
            measurementStart = start; measurementEnd = end
        } else {
            reasons.append("helperMeasurementIntervalUnavailable")
            if timing?.timestampQuality == .helperMeasured { reasons.append("helperMeasurementIntervalInvalid") }
        }
        if timing == nil { reasons.append("legacyHelperTimingMissing") }
        if !bracketValid { reasons.append("requestClockInvalid") }
        let quality = measurementStart != nil ? "helperMeasured" : (bracketValid ? "requestBracketOnly" : "legacyUntimed")
        var telemetry = MSeriesV11Telemetry(
            // A local request ID is labelled explicitly; a legacy reply does
            // not acquire an invented helper boot identity.
            sampleID: timing?.sampleID ?? "request:" + UUID().uuidString,
            helperBootID: timing?.helperBootID ?? "", clockDomain: reading.clockDomain,
            measurementStartMonotonicNs: measurementStart, measurementEndMonotonicNs: measurementEnd,
            requestStartMonotonicNs: reading.requestStartMonotonicNs,
            responseReceivedMonotonicNs: reading.responseReceivedMonotonicNs,
            durationSeconds: sample.durationSeconds, cpuMilliwatts: sample.cpuMilliwatts,
            gpuMilliwatts: sample.gpuMilliwatts, aneMilliwatts: sample.aneMilliwatts, timestampQuality: quality)
        telemetry.clusters = sample.clusters
        telemetry.gpuMegahertz = sample.gpuMegahertz
        return Reading(telemetry: telemetry, clusters: sample.clusters, gpuMegahertz: sample.gpuMegahertz,
                       missingReasons: reasons.sorted())
    }
}
