import Foundation

/// Draft math only. There is deliberately no bundled/active reference and no
/// production call to this evaluator before controlled Release calibration.
enum MSeriesScoring {
    struct ControlledReference: Codable, Equatable, Sendable {
        let protocolHash: String
        let independentSessionIDs: [UUID]
        let medians: [String: Double]
        let createdAt: Date
    }
    enum Failure: Error { case incompleteCore, invalidReference, insufficientEvidence }

    static func calibrate(_ sessions: [BenchmarkV7Result]) throws -> ControlledReference {
        let raw = sessions.compactMap(\.mSeries)
        guard raw.count == sessions.count, raw.count >= 3,
              Set(raw.map(\.sessionID)).count == raw.count,
              sessions.allSatisfy({ $0.isComplete && $0.preflight.powerSource == .acPower }),
              raw.allSatisfy({ $0.hardware.releaseBuild && $0.isCompleteCore && $0.isValid
                  && !$0.coreEnvironment.isEmpty && $0.coreEnvironment.allSatisfy {
                      $0.thermalState == ProcessInfo.ThermalState.nominal.rawValue
                          && !$0.lowPower && $0.powerSource == "AC Power"
                  }
              }) else { throw Failure.insufficientEvidence }
        // Sessions must be independent serial runs, not overlapping captures.
        let ordered = raw.sorted { $0.startedAt < $1.startedAt }
        for index in 1..<ordered.count {
            guard ordered[index].startedAt >= ordered[index - 1].completedAt else { throw Failure.insufficientEvidence }
        }
        var medians: [String: Double] = [:]
        for id in MSeriesProtocol.coreIDs {
            let values = raw.compactMap { $0.metrics.first { $0.id == id }?.statistics?.median }
            guard values.count == raw.count else { throw Failure.incompleteCore }
            medians[id] = try BenchmarkStatistics.summarize(values).median
        }
        return ControlledReference(protocolHash: MSeriesProtocol.contractHash,
            independentSessionIDs: ordered.map(\.sessionID), medians: medians, createdAt: Date())
    }

    /// Within each group all tasks have equal weight. Group weights are
    /// single .20, multi .20, GPU .25, memory .20, storage .15. No ratio clamp.
    static func index(for result: MSeriesResult, reference: ControlledReference) throws -> Double {
        guard result.isCompleteCore, result.isValid else { throw Failure.incompleteCore }
        guard reference.protocolHash == result.contractHash,
              reference.independentSessionIDs.count >= 3,
              Set(reference.independentSessionIDs).count == reference.independentSessionIDs.count,
              Set(reference.medians.keys) == Set(MSeriesProtocol.coreIDs),
              reference.medians.values.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw Failure.invalidReference }
        var logIndex = 0.0
        for (prefix, weight, count) in [("cpu.single.", 0.20, 4), ("cpu.multi.", 0.20, 4),
                                       ("gpu.", 0.25, 3), ("memory.", 0.20, 3), ("storage.", 0.15, 4)] {
            let metrics = result.metrics.filter { $0.id.hasPrefix(prefix) }
            guard metrics.count == count else { throw Failure.incompleteCore }
            for metric in metrics {
                guard let value = metric.statistics?.median, let base = reference.medians[metric.id] else {
                    throw Failure.incompleteCore
                }
                let logRatio = metric.id == "memory.pointerChase" ? log(base) - log(value) : log(value) - log(base)
                logIndex += logRatio * weight / Double(count)
            }
        }
        let index = 1000 * exp(logIndex)
        guard index.isFinite, index > 0 else { throw Failure.invalidReference }
        return index
    }
}
