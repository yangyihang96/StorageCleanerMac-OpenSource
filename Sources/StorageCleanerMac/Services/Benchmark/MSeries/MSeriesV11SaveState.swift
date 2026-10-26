import Foundation

/// Local commit outcome is independent of the sealed measurement and its stop
/// reason. Scoped identity prevents a later run or an opened history record
/// from inheriting another result's failed save.
struct MSeriesV11SaveState: Equatable, Sendable {
    enum State: Equatable, Sendable { case saved, failed }
    let recordID: UUID?
    let sessionID: UUID
    let rawPayloadSHA256: String?
    let state: State
    /// The save was refused because the local history is at its explicit
    /// record capacity (D95), not because the commit failed.
    let historyFull: Bool

    init(result: BenchmarkV7Result, state: State, historyFull: Bool = false) {
        recordID = result.recordID
        sessionID = result.session.id
        rawPayloadSHA256 = result.mSeriesV11?.rawPayloadSHA256
        self.state = state
        self.historyFull = state == .failed && historyFull
    }
    func matches(_ result: BenchmarkV7Result) -> Bool {
        recordID == result.recordID && sessionID == result.session.id
            && rawPayloadSHA256 == result.mSeriesV11?.rawPayloadSHA256
    }
}
