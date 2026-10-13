import XCTest
@testable import StorageCleanerMac

/// Layout and refusal tests have no health readings. Explicitly report a failed
/// read instead of attaching the live probe or synthesizing a healthy snapshot.
struct TestUnavailableComputerHealthProbe: ComputerHealthProbing {
    func probe() async throws -> ComputerHealthSnapshot {
        throw ComputerHealthRefreshError.readFailed
    }
}
