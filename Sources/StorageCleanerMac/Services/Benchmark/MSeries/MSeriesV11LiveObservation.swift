import Foundation

/// Display evidence from an already completed interval; it never drives the
/// kernel, score, sampling cadence or persisted payload.
struct MSeriesV11LiveObservation: Equatable, Sendable {
    let sessionID: UUID
    let stageID: String
    let endedAtNanoseconds: UInt64
    let efficiency: Double?
    let unit: String
    let observedSeconds: Double

    static func make(sessionID: UUID, stageID: String, batches: [MSeriesV11Batch],
                     telemetry: [MSeriesV11Telemetry], end: UInt64, gpu: Bool) -> Self {
        let start = end > 10_000_000_000 ? end - 10_000_000_000 : 0
        let evidence = MSeriesV11Windows.power(start: start, end: end,
            batches: batches.filter { $0.stageID == stageID }, telemetry: telemetry, gpu: gpu)
        return .init(sessionID: sessionID, stageID: stageID, endedAtNanoseconds: end,
            efficiency: evidence.efficiency, unit: gpu ? "Mtri/J" : "fixed-fixtures/J", observedSeconds: evidence.observedSeconds)
    }
}
