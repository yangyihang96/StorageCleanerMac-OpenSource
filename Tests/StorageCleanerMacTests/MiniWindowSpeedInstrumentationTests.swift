#if DEBUG
import Foundation
import XCTest
@testable import StorageCleanerMac

/// Batch r2-mini-speed, phase 2: the audit's stall sampler reads the main
/// thread's stack while a long run-loop iteration is still running.
@MainActor
final class MiniWindowSpeedInstrumentationTests: XCTestCase {
    func testTheStallSamplerReadsTheMainThreadDuringALongIteration() {
        let sampler = MenuBarStallSampler.shared
        sampler.start()
        _ = sampler.iterationEnded()
        sampler.iterationBegan(at: ProcessInfo.processInfo.systemUptime)
        busyMainThread(for: 0.2)
        let samples = sampler.iterationEnded()
        XCTAssertGreaterThanOrEqual(samples.count, 5, "sampled about every 10 ms after the first 50 ms")
        XCTAssertTrue(samples.allSatisfy { $0.offsetMs >= MenuBarStallSampler.samplingStartsAfter * 1000 - 1 })
        let frames = MenuBarStallSampler.describe(samples, stacks: 8, frames: 48)
            .flatMap { ($0["frames"] as? [String]) ?? [] }
        XCTAssertTrue(frames.contains { $0.contains("busyMainThread") },
                      "the walk reaches the function that kept the main thread busy")
        XCTAssertFalse(frames.contains { $0.contains("/") }, "image names only, never paths")

        // A short iteration is not sampled.
        sampler.iterationBegan(at: ProcessInfo.processInfo.systemUptime)
        busyMainThread(for: 0.02)
        XCTAssertTrue(sampler.iterationEnded().isEmpty)
    }

    @inline(never)
    private func busyMainThread(for seconds: Double) {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        var counter = 0
        while ProcessInfo.processInfo.systemUptime < end { counter &+= 1 }
        XCTAssertGreaterThan(counter, 0)
    }
}
#endif
