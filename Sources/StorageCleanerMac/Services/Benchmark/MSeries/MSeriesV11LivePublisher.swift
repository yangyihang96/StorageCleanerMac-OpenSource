import Foundation

/// One consumer, one in-flight callback and at most one waiting snapshot.
/// Display work never becomes a dependency of the measured batch loop.
final class MSeriesV11LivePublisher: Sendable {
    struct Snapshot: Sendable {
        let sessionID: UUID
        let stageID: String
        let batches: [MSeriesV11Batch]
        let end: UInt64
        let gpu: Bool
    }
    private let continuation: AsyncStream<Snapshot>.Continuation
    private let worker: Task<Void, Never>

    init(sessionID: UUID, telemetry: @escaping @Sendable () async -> [MSeriesV11Telemetry],
         publish: @escaping @Sendable (MSeriesV11LiveObservation) async -> Void) {
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        worker = Task.detached(priority: .utility) {
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                guard snapshot.sessionID == sessionID else { continue }
                let readings = await telemetry()
                guard !Task.isCancelled else { break }
                let live = MSeriesV11LiveObservation.make(sessionID: sessionID, stageID: snapshot.stageID,
                    batches: snapshot.batches, telemetry: readings, end: snapshot.end, gpu: snapshot.gpu)
                guard !Task.isCancelled else { break }
                await publish(live)
            }
        }
    }
    func submit(_ snapshot: Snapshot) { continuation.yield(snapshot) }
    /// A callback may suspend indefinitely. Cancellation and receiver session
    /// checks invalidate it; measured work never waits for its return.
    func finish() { continuation.finish(); worker.cancel() }
    func waitUntilFinished() async { await worker.value }
    deinit { continuation.finish(); worker.cancel() }
}
