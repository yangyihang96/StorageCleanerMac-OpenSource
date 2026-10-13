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

    init(result: BenchmarkV7Result, state: State) {
        recordID = result.recordID
        sessionID = result.session.id
        rawPayloadSHA256 = result.mSeriesV11?.rawPayloadSHA256
        self.state = state
    }
    func matches(_ result: BenchmarkV7Result) -> Bool {
        recordID == result.recordID && sessionID == result.session.id
            && rawPayloadSHA256 == result.mSeriesV11?.rawPayloadSHA256
    }
}
