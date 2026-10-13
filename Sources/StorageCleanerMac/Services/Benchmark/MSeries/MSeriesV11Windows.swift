import Foundation

/// All intervals use the system continuous monotonic clock, in nanoseconds.
struct MSeriesV11Batch: Codable, Equatable, Sendable {
    let stageID: String
    let startMonotonicNs: UInt64
    let endMonotonicNs: UInt64
    let workUnits: Double
    let gpuElapsedSeconds: Double?
    let checksum: UInt64
    let clockDomain: String
    var isValid: Bool {
        endMonotonicNs > startMonotonicNs && workUnits.isFinite && workUnits > 0 && checksum != 0
            && clockDomain == MSeriesV11Windows.clockDomain
            && (gpuElapsedSeconds.map { $0.isFinite && $0 > 0 && $0 <= Double(endMonotonicNs - startMonotonicNs) / 1e9 + 0.001 } ?? true)
    }
}

struct MSeriesV11Observation: Sendable {
    let atMonotonicNs: UInt64
    let cpuTemperatureC: Double?
    let gpuTemperatureC: Double?
    let environment: MSeriesV11Environment
}

enum MSeriesV11Windows {
    static let clockDomain = "mach-continuous-v1"
    struct Power: Equatable, Sendable {
        let joules: Double
        let matchedWork: Double
        let observedSeconds: Double
        let sampleIDs: [String]
        var watts: Double? { observedSeconds > 0 ? joules / observedSeconds : nil }
        var efficiency: Double? { joules > 0 && matchedWork > 0 ? matchedWork / joules : nil }
    }

    static func seconds(_ start: UInt64, _ end: UInt64) -> Double {
        end > start ? Double(end - start) / 1e9 : 0
    }
    static func overlap(_ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64) -> Double {
        seconds(max(a, c), min(b, d))
    }
    static func validBatches(_ batches: [MSeriesV11Batch], id: String) -> Bool {
        guard !batches.isEmpty else { return false }
        var last: UInt64 = 0
        for batch in batches {
            guard batch.stageID == id, batch.isValid, batch.startMonotonicNs >= last else { return false }
            last = batch.endMonotonicNs
        }
        return true
    }

    /// Request brackets and completion wall-clock dates cannot prove a power interval.
    static func measuredTelemetry(_ telemetry: [MSeriesV11Telemetry], gpu: Bool) -> [MSeriesV11Telemetry] {
        let groups = Dictionary(grouping: telemetry, by: \.sampleID)
        var accepted: [MSeriesV11Telemetry] = []
        for sample in telemetry.sorted(by: { ($0.measurementStartMonotonicNs ?? 0) < ($1.measurementStartMonotonicNs ?? 0) }) {
            let hasHelperIdentity = !(sample.helperBootID ?? "").isEmpty
                || sample.helperProcessOrdinal.map { (1...1_024).contains($0) } == true
            guard groups[sample.sampleID]?.count == 1, !sample.sampleID.isEmpty, hasHelperIdentity,
                  sample.timestampQuality == "helperMeasured", sample.clockDomain == clockDomain,
                  let start = sample.measurementStartMonotonicNs, let end = sample.measurementEndMonotonicNs,
                  let request = sample.requestStartMonotonicNs, let response = sample.responseReceivedMonotonicNs,
                  end > start, request <= start, end <= response,
                  let duration = sample.durationSeconds, duration.isFinite, duration > 0,
                  abs(duration - seconds(start, end)) <= 0.001,
                  let mw = gpu ? sample.gpuMilliwatts : sample.cpuMilliwatts, mw.isFinite, mw > 0 else { continue }
            // One shared stream: overlap or a restarted helper's colliding interval is never double-counted.
            if accepted.contains(where: { overlap(start, end, $0.measurementStartMonotonicNs!, $0.measurementEndMonotonicNs!) > 0 }) { continue }
            accepted.append(sample)
        }
        return accepted
    }

    static func power(start: UInt64, end: UInt64, batches: [MSeriesV11Batch],
                      telemetry: [MSeriesV11Telemetry], gpu: Bool) -> Power {
        var energy = 0.0, matched = 0.0, observed = 0.0
        var ids: [String] = []
        for sample in measuredTelemetry(telemetry, gpu: gpu) {
            let a = max(start, sample.measurementStartMonotonicNs!)
            let b = min(end, sample.measurementEndMonotonicNs!)
            let duration = seconds(a, b)
            guard duration > 0 else { continue }
            let watts = (gpu ? sample.gpuMilliwatts! : sample.cpuMilliwatts!) / 1000
            energy += watts * duration
            observed += duration
            ids.append(sample.sampleID)
            for batch in batches where batch.isValid {
                matched += batch.workUnits * overlap(a, b, batch.startMonotonicNs, batch.endMonotonicNs)
                    / seconds(batch.startMonotonicNs, batch.endMonotonicNs)
            }
        }
        return Power(joules: energy, matchedWork: matched, observedSeconds: observed, sampleIDs: ids)
    }

    static func windows(id: String, start: UInt64, durationSeconds: Int, count: Int,
                        finishedAt: UInt64, batches: [MSeriesV11Batch], telemetry: [MSeriesV11Telemetry],
                        observations: [MSeriesV11Observation] = [], gpu: Bool) -> [MSeriesV11Window] {
        guard durationSeconds > 0, count > 0, start <= UInt64.max - UInt64(durationSeconds) * 1_000_000_000 else { return [] }
        let durationNs = UInt64(durationSeconds) * 1_000_000_000
        let valid = validBatches(batches, id: id)
        return (0..<count).map { index in
            let a = start + durationNs * UInt64(index) / UInt64(count)
            let b = start + durationNs * UInt64(index + 1) / UInt64(count)
            let elapsed = seconds(a, b)
            let intersecting = batches.filter { $0.isValid && overlap(a, b, $0.startMonotonicNs, $0.endMonotonicNs) > 0 }
            var work = 0.0, gpuSeconds = 0.0
            for batch in intersecting {
                let fraction = overlap(a, b, batch.startMonotonicNs, batch.endMonotonicNs) / seconds(batch.startMonotonicNs, batch.endMonotonicNs)
                work += batch.workUnits * fraction
                gpuSeconds += (batch.gpuElapsedSeconds ?? 0) * fraction
            }
            var reasons: [String] = []
            if !valid { reasons.append("invalidBatchTimeline") }
            if finishedAt < b { reasons.append("incompleteWindow") }
            if work <= 0 { reasons.append("missingWork") }
            let orderedObservations = observations.sorted { $0.atMonotonicNs < $1.atMonotonicNs }
            if zip(orderedObservations, orderedObservations.dropFirst()).contains(where: { previous, next in
                seconds(previous.atMonotonicNs, next.atMonotonicNs) > 1.5
                    && previous.atMonotonicNs < b && next.atMonotonicNs > a
            }) { reasons.append("environmentObservationLate") }
            // No dispatch or sleep gaps are removed from the wall denominator.
            if gpu && intersecting.contains(where: { $0.gpuElapsedSeconds == nil }) { reasons.append("gpuTimingUnverified") }
            let power = power(start: a, end: b, batches: batches, telemetry: telemetry, gpu: gpu)
            let frequencies = measuredTelemetry(telemetry, gpu: gpu).filter {
                overlap(a, b, $0.measurementStartMonotonicNs!, $0.measurementEndMonotonicNs!) > 0
            }.flatMap { sample -> [MSeriesV11Frequency] in
                if gpu {
                    return sample.gpuMegahertz.map { [.init(cluster: "GPU", gigahertz: $0 / 1000,
                        source: "helper-powermetrics", startMonotonicNs: sample.measurementStartMonotonicNs,
                        endMonotonicNs: sample.measurementEndMonotonicNs)] } ?? []
                }
                return (sample.clusters ?? []).map { .init(cluster: $0.name, gigahertz: $0.megahertz / 1000,
                    source: "helper-powermetrics", startMonotonicNs: sample.measurementStartMonotonicNs,
                    endMonotonicNs: sample.measurementEndMonotonicNs) }
            }
            let points = observations.filter { $0.atMonotonicNs >= a && $0.atMonotonicNs < b }
            let temperatures = points.compactMap { gpu ? $0.gpuTemperatureC : $0.cpuTemperatureC }.filter(\.isFinite)
            let temperature = temperatures.isEmpty ? nil : temperatures.reduce(0, +) / Double(temperatures.count)
            return .init(id: "\(id).window.\(index)", startMonotonicNs: a, endMonotonicNs: b,
                elapsedSeconds: seconds(start, b), workUnits: work,
                wallThroughput: work > 0 && valid && finishedAt >= b ? work / elapsed : nil,
                gpuTimedThroughput: gpu && gpuSeconds > 0 && reasons.isEmpty ? work / gpuSeconds : nil,
                temperatureC: temperature, powerW: power.watts, frequencies: frequencies, validityReasons: reasons,
                environment: points.map(\.environment))
        }
    }

    static func metric(id: String, values: [Double], elapsed: [Double], windows: [MSeriesV11Window],
                       batches: [MSeriesV11Batch], extensionHash: String, gpu: Bool) -> MSeriesV11Metric? {
        guard values.count == windows.count, values.allSatisfy({ $0.isFinite && $0 > 0 }),
              windows.allSatisfy({ $0.validityReasons.isEmpty }), let checksum = batches.first?.checksum else { return nil }
        return .init(id: id, contract: MSeriesScoringV11.metricContract(id, extensionHash: extensionHash),
            availability: "available", reasonCode: nil,
            samples: zip(values, elapsed).map { .init(value: $0.0, elapsedSeconds: $0.1, wallElapsedSeconds: $0.1, checksum: checksum) },
            environment: windows.flatMap(\.environment), usedWallClockFallback: gpu ? false : nil)
    }

    static func efficiencyPoint(id: String, workers: Int, coreType: String, windows: [MSeriesV11Window],
                                batches: [MSeriesV11Batch], telemetry: [MSeriesV11Telemetry], extensionHash: String,
                                extraReasons: [String] = []) -> MSeriesV11EfficiencyPoint {
        let gpu = id == MSeriesScoringV11.peakID
        let expected = gpu ? 15 : 5
        let eligible = telemetry.filter { sample in
            guard let request = sample.requestStartMonotonicNs, let first = windows.first, let last = windows.last else { return false }
            return request >= first.startMonotonicNs && request < last.endMonotonicNs
        }
        let powers = windows.map { power(start: $0.startMonotonicNs, end: $0.endMonotonicNs, batches: batches, telemetry: eligible, gpu: gpu) }
        let ids = Set(powers.flatMap(\.sampleIDs))
        let observed = powers.reduce(0) { $0 + $1.observedSeconds }
        let energy = powers.reduce(0) { $0 + $1.joules }
        let work = powers.reduce(0) { $0 + $1.matchedWork }
        var missing = extraReasons
        if ids.count < (gpu ? 12 : 4) || ids.count > expected { missing.append("insufficientPowerSampleCoverage") }
        if powers.contains(where: { $0.sampleIDs.isEmpty }) { missing.append("missingPowerWindow") }
        if telemetry.isEmpty { missing.append("powerTelemetryUnavailable") }
        if ids.isEmpty && eligible.contains(where: { $0.timestampQuality != "helperMeasured" }) { missing.append("timestampMissing") }
        let durations = windows.map { seconds($0.startMonotonicNs, $0.endMonotonicNs) }
        let throughput = metric(id: id, values: windows.compactMap { gpu ? $0.gpuTimedThroughput : $0.wallThroughput },
            elapsed: durations, windows: windows, batches: batches, extensionHash: extensionHash, gpu: gpu)
        let efficiencyID = gpu ? "power.gpu.peak.matchedTrianglesPerJoule" : id == "power.cpu.allCores" ? MSeriesScoringV11.efficiencyID : id + ".matchedFixturesPerJoule"
        var efficiency: MSeriesV11Metric?
        if missing.isEmpty, let raw = metric(id: efficiencyID, values: powers.compactMap(\.efficiency), elapsed: powers.map(\.observedSeconds),
            windows: windows, batches: batches, extensionHash: extensionHash, gpu: false) {
            efficiency = raw
            efficiency?.powerAlignment = .init(timestampQuality: "helperMeasured", expectedSampleCount: expected, validSampleCount: ids.count,
                windows: powers.map { .init(matchedWorkUnits: $0.matchedWork, joules: $0.joules, observedSeconds: $0.observedSeconds, validSampleCount: $0.sampleIDs.count) })
        }
        var point = MSeriesV11EfficiencyPoint(id: id, throughput: throughput, efficiency: efficiency, resolvedWorkers: workers, coreType: coreType,
            meanPowerW: observed > 0 ? energy / observed : nil, matchedWorkUnits: observed > 0 ? work : nil,
            joules: observed > 0 ? energy : nil, expectedSampleCount: expected, validSampleCount: ids.count,
            observedSeconds: observed > 0 ? observed : nil,
            timestampQuality: ids.isEmpty ? (eligible.contains { $0.timestampQuality == "requestBracketOnly" } ? "requestBracketOnly" : "legacyUntimed") : "helperMeasured",
            alignmentQuality: efficiency == nil ? "unavailable" : "measuredIntersections", missingReasons: Array(Set(missing)).sorted(),
            frequencies: windows.flatMap(\.frequencies), windows: windows)
        point.sampleCoverageFraction = Double(ids.count) / Double(expected)
        let windowSeconds = durations.reduce(0, +)
        point.timeCoverageFraction = windowSeconds > 0 ? observed / windowSeconds : nil
        return point
    }

    static func sustained(id: String, duration: Int, windows: [MSeriesV11Window], batches: [MSeriesV11Batch],
                          extensionHash: String, gpu: Bool) -> MSeriesV11Sustained {
        let values = windows.compactMap { gpu ? $0.gpuTimedThroughput : $0.wallThroughput }
        let complete = windows.count == duration / 5 && values.count == windows.count && windows.allSatisfy { $0.validityReasons.isEmpty }
        let head = complete ? try? BenchmarkStatistics.summarize(Array(values.prefix(2))).median : nil
        let tailID = gpu ? MSeriesScoringV11.sustainedID : "sustained.cpu.tail30.wallThroughput"
        let tail = complete ? metric(id: tailID, values: Array(values.suffix(6)), elapsed: Array(repeating: 5, count: 6),
            windows: Array(windows.suffix(6)), batches: batches, extensionHash: extensionHash, gpu: gpu) : nil
        let median = tail?.statistics?.median
        return .init(id: id, durationSeconds: Double(duration), windows: windows, first10Median: head,
            tail30Metric: tail, retention: head.flatMap { initial in median.map { $0 / initial } },
            missingReasons: complete ? [] : ["incompleteSustainedWindows"])
    }

    static func contiguous(_ windows: [MSeriesV11Window], count: Int, duration: Int, gpu: Bool) -> Bool {
        guard windows.count == count, let first = windows.first,
              first.startMonotonicNs <= UInt64.max - UInt64(duration) * 1_000_000_000,
              Set(windows.map(\.id)).count == count else { return false }
        let ns = UInt64(duration) * 1_000_000_000
        for (index, window) in windows.enumerated() {
            guard window.startMonotonicNs == first.startMonotonicNs + ns * UInt64(index) / UInt64(count),
                  window.endMonotonicNs == first.startMonotonicNs + ns * UInt64(index + 1) / UInt64(count),
                  window.validityReasons.isEmpty, (gpu ? window.gpuTimedThroughput : window.wallThroughput).map({ $0.isFinite && $0 > 0 }) == true else { return false }
        }
        return true
    }

    /// Rebuild evidence from sample IDs, independent intervals and validated work batches.
    static func validatesEfficiency(_ point: MSeriesV11EfficiencyPoint, envelope: MSeriesV11Result) -> Bool {
        guard contiguous(point.windows, count: 3, duration: 10, gpu: false), point.id == "power.cpu.allCores",
              let start = point.windows.first?.startMonotonicNs, let end = point.windows.last?.endMonotonicNs else { return false }
        let batches = envelope.workloadBatches.filter { $0.stageID == point.id }
        guard validBatches(batches, id: point.id), batches.first!.startMonotonicNs >= start,
              batches.last!.endMonotonicNs >= end else { return false }
        let rebuilt = efficiencyPoint(id: point.id, workers: point.resolvedWorkers ?? 0, coreType: point.coreType ?? "unknown",
            windows: point.windows, batches: batches, telemetry: envelope.telemetry, extensionHash: envelope.extensionContractHash)
        guard let expected = rebuilt.efficiency, let actual = point.efficiency else { return false }
        return actual.samples.map(\.value) == expected.samples.map(\.value)
            && actual.powerAlignment == expected.powerAlignment && point.validSampleCount == rebuilt.validSampleCount
            && point.expectedSampleCount == rebuilt.expectedSampleCount && point.observedSeconds == rebuilt.observedSeconds
            && point.joules == rebuilt.joules && point.matchedWorkUnits == rebuilt.matchedWorkUnits && point.meanPowerW == rebuilt.meanPowerW
    }
}

extension MSeriesV11Result {
    var hasCompletedRequiredMeasurements: Bool {
        let duration = mode == "pressure10m" ? 300 : 90
        guard let cpu = sustainedCPU, let gpu = sustainedGPU, cpu.durationSeconds == Double(duration), gpu.durationSeconds == Double(duration),
              MSeriesV11Windows.contiguous(cpu.windows, count: duration / 5, duration: duration, gpu: false),
              MSeriesV11Windows.contiguous(gpu.windows, count: duration / 5, duration: duration, gpu: true) else { return false }
        if mode == "pressure10m" { return true }
        let required = ["power.cpu.single", "power.cpu.performanceCores", "power.cpu.allCores", "power.gpu.peak"]
        guard efficiencyPoints.count == required.count, Set(efficiencyPoints.map(\.id)) == Set(required) else { return false }
        return efficiencyPoints.allSatisfy { point in
            let gpu = point.id == "power.gpu.peak"
            return (point.resolvedWorkers ?? 0) > 0 && point.throughput?.availability == "available"
                && point.throughput?.samples.count == 3 && point.throughput?.samples.allSatisfy(\.isValid) == true
                && MSeriesV11Windows.contiguous(point.windows, count: 3, duration: gpu ? 30 : 10, gpu: gpu)
        }
    }
}
