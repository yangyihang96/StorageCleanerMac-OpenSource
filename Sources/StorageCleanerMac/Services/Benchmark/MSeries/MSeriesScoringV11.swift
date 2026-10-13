import Foundation

enum MSeriesScoringV11 {
    static let version = "mseries-d72-geomean-v11.2"
    static let scoringContractHash = "fc154594b7f4f2877b6ace113b544f05db7bfbbe8176966c0fb2bf0a96d1f16e"
    // The exact ASCII contract from SPEC §6.2 is inserted below, without a newline.
    static let contract = #"{"acceleratorContribution":0,"aggregation":"weighted-geometric-mean-of-ratios","capacityContribution":0,"comparability":{"batteryFairLowPowerHighBackgroundOrUnknown":"restricted","debugRosettaInvalidOrUnstable":"incomparable","precedence":["incomparable","restricted","comparable"]},"coreCompatibility":"unchanged-v10-fixtures-and-algorithms","cv":{"definition":"sample-standard-deviation-divided-by-mean","endpointsInclusive":true,"minimumSamples":3,"relaxed":0.1,"relaxedDomains":["gpu-core","gpu-peak","gpu-sustained-tail","storage-write","ray-tracing","media-encode"],"strict":0.05,"strictDomains":["cpu","memory","storage-read","cpu-efficiency","cpu-sustained-tail","tensor","ai","media-decode"]},"groups":{"chip":{"cpu":0.7,"gpu":0.3},"cpu":{"cpuMulti":0.7,"cpuSingle":0.3},"cpuMulti":{"cpu.multi.compression":0.25,"cpu.multi.floating":0.25,"cpu.multi.image":0.25,"cpu.multi.integer":0.25},"cpuSingle":{"cpu.single.compression":0.25,"cpu.single.floating":0.25,"cpu.single.image":0.25,"cpu.single.integer":0.25},"efficiency":{"power.cpu.allCores.matchedFixturesPerJoule":1.0},"gpu":{"gpuPeak":0.5,"gpuSustained":0.5},"gpuPeak":{"gpu.compute.fp16":0.25,"gpu.compute.fp32":0.25,"gpu.graphics.offscreen":0.25,"power.gpu.peak":0.25},"gpuSustained":{"sustained.gpu.tail30.gpuTimedThroughput":1.0},"memory":{"memory.copy":0.3333333333333333,"memory.pointerChase":0.3333333333333333,"memory.triad":0.3333333333333333},"storage":{"storage.randomReadQD1":0.25,"storage.randomWriteQD1":0.25,"storage.seqRead":0.25,"storage.seqWrite":0.25},"system":{"chip":0.55,"memory":0.2,"storage":0.25}},"missingInput":"dependent-parent-null-no-reweight","provisionalReference":"local-M5-Pro-controlled-v11-only-no-estimated-medians","ratios":{"acceptedMaximum":5,"acceptedMinimum":0.02,"endpointsInclusive":true,"higherIsBetter":"measuredMedian/referenceMedian","inverseCoreIDs":["memory.pointerChase"],"lowerIsBetter":"referenceMedian/measuredMedian","outOfRange":"reject-no-clamp"},"referenceScore":1000,"timing":{"efficiency":"work-and-joules-in-matching-measured-wall-intervals","gpuScores":"reliable-gpu-timeline-only","pressure10m":"raw-only","retention":"median-last30/median-first10","sustainedScoreWindow":"last-30-of-90-seconds"},"version":"mseries-d72-geomean-v11.2"}"#
    static let peakID = "power.gpu.peak"
    static let sustainedID = "sustained.gpu.tail30.gpuTimedThroughput"
    static let efficiencyID = "power.cpu.allCores.matchedFixturesPerJoule"
    static let inputIDs = MSeriesProtocol.coreIDs + [peakID, sustainedID, efficiencyID]
    static let groups: [(String, [(String, Double)])] = [
        ("cpuSingle", MSeriesProtocol.coreIDs.filter { $0.hasPrefix("cpu.single.") }.map { ($0, 0.25) }),
        ("cpuMulti", MSeriesProtocol.coreIDs.filter { $0.hasPrefix("cpu.multi.") }.map { ($0, 0.25) }),
        ("cpu", [("cpuSingle", 0.30), ("cpuMulti", 0.70)]),
        ("gpuPeak", (MSeriesProtocol.coreIDs.filter { $0.hasPrefix("gpu.") } + [peakID]).map { ($0, 0.25) }),
        ("gpuSustained", [(sustainedID, 1)]),
        ("gpu", [("gpuPeak", 0.50), ("gpuSustained", 0.50)]),
        ("chip", [("cpu", 0.70), ("gpu", 0.30)]),
        ("memory", MSeriesProtocol.coreIDs.filter { $0.hasPrefix("memory.") }.map { ($0, 1.0 / 3) }),
        ("storage", MSeriesProtocol.coreIDs.filter { $0.hasPrefix("storage.") }.map { ($0, 0.25) }),
        ("system", [("chip", 0.55), ("memory", 0.20), ("storage", 0.25)]),
        ("efficiency", [(efficiencyID, 1)])
    ]

    static func metricContract(_ id: String, extensionHash: String) -> MSeriesV11MetricContract {
        let core = MSeriesProtocol.coreIDs.contains(id)
        let unit = id == "memory.pointerChase" ? "ns/access" :
            id.hasPrefix("memory.") || id.hasPrefix("storage.seq") ? "GB/s" :
            id.hasPrefix("storage.random") ? "IOPS" :
            id == peakID || id == sustainedID ? "Mtri/s" :
            id.hasSuffix(".matchedTrianglesPerJoule") ? "Mtri/J" :
            id.hasSuffix(".matchedFixturesPerJoule") ? "fixed-fixtures/J" : "fixed-fixtures/s"
        let timing = id.hasSuffix("PerJoule") ? "aligned-measured-wall" :
            id.hasPrefix("gpu.") || id == peakID || id == sustainedID ? "gpu-timeline" : "wall-monotonic"
        return .init(unit: unit, timing: timing,
            statisticsVersion: core ? MSeriesProtocol.statistics : "mseries-window-cv-v11.1",
            workloadHash: core ? MSeriesProtocol.contractHash : extensionHash)
    }

    static func maximumCV(_ id: String) -> Double {
        id.hasPrefix("gpu.") || id == peakID || id == sustainedID
            || (id.hasPrefix("storage.") && id.contains("Write")) ? 0.10 : 0.05
    }

    /// Same sample-standard-deviation definition as v6; n >= 3 is a v11 gate.
    static func coefficientOfVariation(_ values: [Double]) -> Double? {
        guard values.count >= 3, values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean.isFinite, mean > 0 else { return nil }
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)
        let cv = sqrt(variance) / mean
        return cv.isFinite ? cv : nil
    }

    static func environmentLabel(_ points: [MSeriesV11Environment]) -> MSeriesComparabilityLabel {
        var bad: [String] = []
        var limited: [String] = []
        if points.isEmpty { limited.append("environmentUnknown") }
        for point in points {
            if point.releaseBuild == false { bad.append("debugBuild") }
            if point.nativeARM64 == false { bad.append("intel") }
            if point.translated == true { bad.append("rosetta") }
            if point.thermalState == 2 || point.thermalState == 3 { bad.append("thermalProtection") }
            if point.thermalState == 1 { limited.append("thermalFair") }
            if let thermal = point.thermalState, !(0...3).contains(thermal) { limited.append("thermalUnknown") }
            if point.powerSource == "Battery Power" { limited.append("batteryPower") }
            if let power = point.powerSource, !["AC Power", "Battery Power"].contains(power) { limited.append("powerUnknown") }
            if point.powerChanged == true { limited.append("powerChanged") }
            if point.lowPower == true { limited.append("lowPower") }
            if point.automaticPowerMode == false { limited.append("powerModeRestricted") }
            if point.backgroundLoadHigh == true { limited.append("backgroundLoadHigh") }
            if point.releaseBuild == nil || point.nativeARM64 == nil || point.translated == nil
                || point.powerSource == nil || point.powerChanged == nil || point.lowPower == nil
                || point.automaticPowerMode == nil || point.thermalState == nil || point.backgroundLoadHigh == nil {
                limited.append("environmentUnknown")
            }
        }
        return label(bad: bad, limited: limited)
    }

    static func label(bad: [String], limited: [String] = []) -> MSeriesComparabilityLabel {
        .init(status: bad.isEmpty ? (limited.isEmpty ? .comparable : .restricted) : .incomparable,
              reasonCodes: Array(Set(bad + limited)).sorted())
    }

    static func merge(_ values: [MSeriesComparabilityLabel]) -> MSeriesComparabilityLabel {
        let status: MSeriesComparability = values.contains { $0.status == .incomparable } ? .incomparable :
            values.contains { $0.status == .restricted } ? .restricted : .comparable
        return .init(status: status, reasonCodes: Array(Set(values.flatMap(\.reasonCodes))).sorted())
    }

    /// Eligibility of measured evidence, independent of a reference score.
    static func evidenceLabel(_ metric: MSeriesV11Metric, extensionHash: String,
                              mode: String = "standard") -> MSeriesComparabilityLabel {
        let id = metric.id
        let env = environmentLabel(metric.environment)
        var bad: [String] = []
        if mode != "standard" { bad.append("pressureRawOnly") }
        if metric.availability != "available" { bad.append(metric.reasonCode ?? "inputUnavailable") }
        if metric.contract != metricContract(id, extensionHash: extensionHash) { bad.append("metricContractMismatch") }
        let expectedCount = id == sustainedID ? 6 : 3
        if metric.samples.count != expectedCount || !metric.samples.allSatisfy({ $0.isValid && ($0.checksum ?? 0) != 0 }) {
            bad.append("invalidSamples")
        }
        if let cv = metric.sampleCV, cv.isFinite, cv <= maximumCV(id) {} else { bad.append("unstableSamples") }
        if metric.contract.timing == "gpu-timeline", metric.usedWallClockFallback != false { bad.append("gpuTimingUnverified") }
        if id == efficiencyID, metric.powerAlignment?.validates(metric.samples) != true { bad.append("powerAlignmentUnavailable") }
        return merge([env, label(bad: bad)])
    }

    static func evaluate(metrics: [MSeriesV11Metric], reference: MSeriesReferenceV11.Loaded,
                         extensionHash: String, mode: String = "standard") -> MSeriesV11Scores {
        var ratios: [String: Double] = [:]
        var labels: [String: MSeriesComparabilityLabel] = [:]
        let byID = Dictionary(grouping: metrics, by: \.id)
        for id in inputIDs {
            guard let matches = byID[id], matches.count == 1, let metric = matches.first else {
                labels[id] = label(bad: [byID[id] == nil ? "missingV11Inputs" : "duplicateInput"])
                continue
            }
            let evidence = evidenceLabel(metric, extensionHash: extensionHash, mode: mode)
            var bad: [String] = []
            if let frozen = reference.reference {
                if !MSeriesProtocol.coreIDs.contains(id), frozen.extensionContractHash != extensionHash { bad.append("extensionContractMismatch") }
                if let base = frozen.medians[id], base.contract == metric.contract,
                   let measured = metric.statistics?.median {
                    let ratio = id == "memory.pointerChase" ? base.median / measured : measured / base.median
                    if ratio.isFinite, ratio >= 0.02, ratio <= 5 {
                        if bad.isEmpty && evidence.status != .incomparable { ratios[id] = ratio }
                    } else { bad.append("ratioOutOfRange") }
                } else { bad.append("referenceContractMismatch") }
            }
            labels[id] = merge([evidence, label(bad: bad)])
            if labels[id]?.status == .incomparable { ratios[id] = nil }
        }
        for (group, dependencies) in groups {
            labels[group] = merge(dependencies.map { labels[$0.0] ?? label(bad: ["missingV11Inputs"]) })
            // Never reweight a surviving subset.
            if dependencies.allSatisfy({ ratios[$0.0] != nil }), labels[group]?.status != .incomparable {
                let ratio = exp(dependencies.reduce(0) { $0 + $1.1 * log(ratios[$1.0]!) })
                if ratio.isFinite && ratio > 0 { ratios[group] = ratio }
            }
        }
        return .init(componentScores: ratios.mapValues { 1000 * $0 }, labels: labels,
            referenceIdentity: reference.identity, scoreStatus: reference.reference == nil ? "unavailable" :
                (ratios["system"] == nil ? "partial" : "available"))
    }

    /// No guessing extensions for old records. New measurements carry their own scoped environment.
    static func inputs(core: MSeriesResult, envelope: MSeriesV11Result?) -> [MSeriesV11Metric] {
        let coreEnvironment = core.coreEnvironment.map { point in
            MSeriesV11Environment(releaseBuild: core.hardware.releaseBuild, nativeARM64: core.hardware.nativeARM64,
                translated: core.hardware.translated, powerSource: point.powerSource, lowPower: point.lowPower,
                thermalState: point.thermalState)
        }
        var metrics = core.metrics.map { metric in
            let expected = metricContract(metric.id, extensionHash: "")
            var scopedEnvironment = envelope?.perStageEnvironment["core"] ?? coreEnvironment
            for index in scopedEnvironment.indices {
                scopedEnvironment[index].releaseBuild = core.hardware.releaseBuild
                scopedEnvironment[index].nativeARM64 = core.hardware.nativeARM64
                scopedEnvironment[index].translated = core.hardware.translated
            }
            return MSeriesV11Metric(id: metric.id,
                contract: .init(unit: metric.unit, timing: expected.timing,
                    statisticsVersion: core.statisticsVersion, workloadHash: core.contractHash),
                availability: core.isValid ? metric.availability.rawValue : "failed",
                reasonCode: core.isValid ? metric.reason : "coreContractMismatch", samples: metric.samples,
                environment: scopedEnvironment,
                usedWallClockFallback: metric.id.hasPrefix("gpu.") ? false : nil)
        }
        guard let envelope else { return metrics }
        if let peak = envelope.efficiencyPoints.first(where: { $0.id == peakID })?.throughput { metrics.append(peak) }
        if let sustained = envelope.sustainedGPU, sustained.durationSeconds == 90,
           validSustainedWindows(sustained.windows), let tail = sustained.tail30Metric {
            // Tail samples must represent the actual last six GPU windows, not an unrelated metric.
            let expected = Array(sustained.windows.suffix(6)).compactMap(\.gpuTimedThroughput)
            if tail.id == sustainedID && tail.samples.map(\.value) == expected {
                metrics.append(.init(id: tail.id, contract: tail.contract, availability: tail.availability,
                    reasonCode: tail.reasonCode, samples: tail.samples,
                    environment: sustained.windows.suffix(6).flatMap(\.environment), usedWallClockFallback: tail.usedWallClockFallback))
            }
        }
        if let point = envelope.efficiencyPoints.first(where: { $0.id == "power.cpu.allCores" }),
           point.timestampQuality == "helperMeasured", point.expectedSampleCount == 5,
           point.validSampleCount >= 4 && point.validSampleCount <= 5,
           let energy = point.joules, energy.isFinite, energy > 0,
           let work = point.matchedWorkUnits, work.isFinite, work > 0,
           let power = point.meanPowerW, power.isFinite, power > 0,
           let observed = point.observedSeconds, observed.isFinite, observed > 0, observed <= 10,
           point.windows.count == 3, point.windows.allSatisfy({ ($0.powerW ?? 0) > 0 && $0.validityReasons.isEmpty }),
           let metric = point.efficiency, metric.id == efficiencyID,
           MSeriesV11Windows.validatesEfficiency(point, envelope: envelope) { metrics.append(metric) }
        return metrics
    }

    private static func validSustainedWindows(_ windows: [MSeriesV11Window]) -> Bool {
        guard windows.count == 18, Set(windows.map(\.id)).count == 18, let first = windows.first,
              first.startMonotonicNs <= UInt64.max - 90_000_000_000 else { return false }
        for (index, window) in windows.enumerated() {
            guard window.endMonotonicNs > window.startMonotonicNs,
                  window.startMonotonicNs == first.startMonotonicNs + UInt64(index) * 5_000_000_000,
                  window.endMonotonicNs - window.startMonotonicNs == 5_000_000_000,
                  window.validityReasons.isEmpty, (window.gpuTimedThroughput ?? 0) > 0 else { return false }
        }
        return true
    }
}
