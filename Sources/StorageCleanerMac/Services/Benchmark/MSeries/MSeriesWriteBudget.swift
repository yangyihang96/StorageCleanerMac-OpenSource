import Foundation

/// Session-owned, survives a storage worker's failed initialization/retry.
/// Reservations are conservative; actual successful write bytes are separate.
final class MSeriesWriteBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: UInt64
    private var reserved: UInt64 = 0
    private var actual: UInt64 = 0
    init(maximum: UInt64 = MSeriesProtocol.maximumWrittenBytes) { self.maximum = maximum }
    var writtenBytes: UInt64 { lock.withLock { actual } }
    func reserve(_ bytes: Int) throws {
        try lock.withLock {
            guard bytes >= 0 else { throw MSeriesKernelError.resourceBudget }
            let (next, overflow) = reserved.addingReportingOverflow(UInt64(bytes))
            guard !overflow, next <= maximum else { throw MSeriesKernelError.resourceBudget }
            reserved = next
        }
    }
    func recordWritten(_ bytes: Int) throws {
        try lock.withLock {
            guard bytes >= 0 else { throw MSeriesKernelError.resourceBudget }
            let (next, overflow) = actual.addingReportingOverflow(UInt64(bytes))
            guard !overflow, next <= reserved else { throw MSeriesKernelError.resourceBudget }
            actual = next
        }
    }
}
