import Foundation
import MSeriesKernels

/// Workspaces are prepared before timing. Each concurrent worker owns one
/// distinct C workspace; the result collector is accessed only after its clock stops.
final class MSeriesCPUMemoryKernel: @unchecked Sendable {
    private let workspaces: [OpaquePointer]
    private let kind: Int32
    init(kind: Int32, workers: Int, budgetBytes: UInt64) throws {
        let (required, overflow) = msc_resident_bytes(kind).multipliedReportingOverflow(by: UInt64(max(0, workers)))
        guard workers > 0, !overflow, required > 0, required <= budgetBytes else { throw MSeriesKernelError.resourceBudget }
        var created: [OpaquePointer] = []
        for _ in 0..<workers {
            guard let pointer = msc_create(kind) else {
                created.forEach { msc_destroy($0) }; throw MSeriesKernelError.allocation
            }
            created.append(pointer)
        }
        self.kind = kind; self.workspaces = created
    }
    deinit { workspaces.forEach { msc_destroy($0) } }

    func measure(id: String, cancellation: MSeriesCancellation) throws -> MSeriesMeasurement {
        try cancellation.check()
        // The first fixed unit is warmup and a pilot; never part of samples.
        let pilot = try run(repetitions: 1, cancellation: cancellation)
        let repetitions = max(1, min(4096, Int(ceil(0.15 / pilot.elapsedSeconds))))
        var samples: [BenchmarkV7RawSample] = []
        for _ in 0..<MSeriesProtocol.samples {
            try cancellation.check()
            samples.append(try run(repetitions: repetitions, cancellation: cancellation))
        }
        let unit = kind == 6 ? "ns/access" : (kind >= 4 ? "GB/s" : "fixed-fixtures/s")
        return MSeriesMeasurement(id: id, unit: unit, availability: .available, reason: nil,
            samples: samples, statistics: try BenchmarkStatistics.summarize(samples.map(\.value)),
            repetitions: repetitions, workers: workspaces.count)
    }

    private func run(repetitions: Int, cancellation: MSeriesCancellation) throws -> BenchmarkV7RawSample {
        let collector = WorkerResults()
        DispatchQueue.concurrentPerform(iterations: workspaces.count) { worker in
            let pointer = self.workspaces[worker]
            var succeeded = true
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<repetitions {
                if cancellation.isCancelled { succeeded = false; break }
                if msc_run_unit(pointer) == 0 { succeeded = false; break }
            }
            let end = DispatchTime.now().uptimeNanoseconds
            collector.append(start: start, end: end, valid: succeeded, checksum: 0)
        }
        if cancellation.isCancelled { throw CancellationError() }
        let records = collector.records
        guard records.allSatisfy(\.valid), let first = records.map(\.start).min(),
              let last = records.map(\.end).max(), last > first else { throw MSeriesKernelError.invalidOutput }
        // Wait for every worker's timed section before validating any worker,
        // otherwise early validation steals CPU from the last timed worker.
        var checksum: UInt64 = 0
        for pointer in workspaces {
            guard msc_validate(pointer) != 0 else { throw MSeriesKernelError.invalidOutput }
            checksum &+= msc_checksum(pointer)
        }
        let elapsed = Double(last - first) / 1e9
        let work = Double(repetitions * workspaces.count)
        let value: Double
        if kind == 6 { value = elapsed * 1e9 / (work * Double(msc_accesses(kind))) }
        else if kind >= 4 { value = work * Double(msc_unit_bytes(kind)) / elapsed / 1e9 }
        else { value = work / elapsed }
        guard value.isFinite, value > 0 else { throw MSeriesKernelError.invalidTiming }
        return BenchmarkV7RawSample(value: value, elapsedSeconds: elapsed, wallElapsedSeconds: nil,
            checksum: checksum)
    }

    private final class WorkerResults: @unchecked Sendable {
        struct Record { let start: UInt64; let end: UInt64; let valid: Bool; let checksum: UInt64 }
        private let lock = NSLock()
        private var values: [Record] = []
        var records: [Record] { lock.withLock { values } }
        func append(start: UInt64, end: UInt64, valid: Bool, checksum: UInt64) {
            lock.withLock { values.append(Record(start: start, end: end, valid: valid, checksum: checksum)) }
        }
    }
}
