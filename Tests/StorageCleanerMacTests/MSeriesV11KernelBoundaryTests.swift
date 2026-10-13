import Foundation
import XCTest
@testable import StorageCleanerMac

final class MSeriesV11KernelBoundaryTests: XCTestCase {
    func testProductionTimingFactoryAndExecutionContractArePresent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Services/Benchmark/MSeries/MSeriesV11Metal3DDriver.swift"), encoding: .utf8)
        let actorStart = try XCTUnwrap(source.range(of: "private actor SystemMSeriesV11Metal3DDriver:"))
        XCTAssertEqual(MSeriesV11Digest.sha256(Data(source[..<actorStart.lowerBound].utf8)),
            "a4d274d03ab8ce346f666cb64bad50203280807cdba74557f243f562f55825b1",
            "Execution structure, protocol and production factory must remain locked")
        let timing = ["let continuousStartedAt = MSeriesV11Clock.nanoseconds",
            "let continuousFinishedAt = MSeriesV11Clock.nanoseconds",
            "execution.startMonotonicNs = continuousStartedAt", "execution.endMonotonicNs = continuousFinishedAt"]
        for line in timing { XCTAssertEqual(source.components(separatedBy: line).count - 1, 1, line) }
        let order = [timing[0], "commandBuffer.commit()", "commandBuffer.waitUntilCompleted()", timing[1], timing[2], timing[3], "return execution"]
        var previous = source.startIndex
        for token in order {
            let range = try XCTUnwrap(source.range(of: token, range: previous..<source.endIndex), token)
            previous = range.upperBound
        }
        // Constructing the actor allocates no Metal device or workload.
        XCTAssertEqual(String(describing: type(of: Metal3DBenchmarkKernel.makeV11Driver())), "SystemMSeriesV11Metal3DDriver")
        var execution = MSeriesV11Metal3DExecution(gpuElapsedSeconds: 0.025, wallElapsedSeconds: 0.05,
            usedWallClockFallback: true, ranOnMainThread: false)
        XCTAssertNil(execution.startMonotonicNs); XCTAssertNil(execution.endMonotonicNs)
        execution.startMonotonicNs = UInt64.max - 50_000_000; execution.endMonotonicNs = UInt64.max
        XCTAssertEqual(execution.gpuElapsedSeconds, 0.025); XCTAssertEqual(execution.wallElapsedSeconds, 0.05)
        XCTAssertTrue(execution.usedWallClockFallback); XCTAssertFalse(execution.ranOnMainThread)
        XCTAssertEqual(execution.endMonotonicNs! - execution.startMonotonicNs!, 50_000_000)
    }
    func testV11RendererPreservesFrozenSceneValidationAndDrainCode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = root.appendingPathComponent("Sources/StorageCleanerMac/Services/Benchmark")
        let frozen = try String(contentsOf: base.appendingPathComponent("Metal3DBenchmarkKernel.swift"), encoding: .utf8)
        let v11 = try String(contentsOf: base.appendingPathComponent("MSeries/MSeriesV11Metal3DDriver.swift"), encoding: .utf8)
        let frozenStart = try XCTUnwrap(frozen.range(of: "private actor SystemMetal3DBenchmarkDriver:"))
        let v11Start = try XCTUnwrap(v11.range(of: "private actor SystemMSeriesV11Metal3DDriver:"))
        var migrated = String(v11[v11Start.lowerBound...])
        migrated = migrated.replacingOccurrences(of: "SystemMSeriesV11Metal3DDriver", with: "SystemMetal3DBenchmarkDriver")
            .replacingOccurrences(of: "MSeriesV11Metal3DDriving", with: "Metal3DBenchmarkDriving")
            .replacingOccurrences(of: "MSeriesV11Metal3DExecution", with: "Metal3DBenchmarkExecution")
            .replacingOccurrences(of: "        let continuousStartedAt = MSeriesV11Clock.nanoseconds\n", with: "")
            .replacingOccurrences(of: "        let continuousFinishedAt = MSeriesV11Clock.nanoseconds\n", with: "")
            .replacingOccurrences(of: "        var execution = Metal3DBenchmarkExecution(", with: "        return Metal3DBenchmarkExecution(")
            .replacingOccurrences(of: "        execution.startMonotonicNs = continuousStartedAt\n        execution.endMonotonicNs = continuousFinishedAt\n        return execution\n", with: "")
        XCTAssertEqual(migrated, String(frozen[frozenStart.lowerBound...]),
            "Only v11 type names and continuous timing may differ; shader, scene, GPU timing, checksum and draining stay frozen")
    }

    func testGPUAdapterKeepsValidationOutsideBatchTimingAndDrainsSubstitute() async throws {
        let clock = V11MetalBoundaryClock()
        let substitute = V11MetalBoundaryDriver(clock: clock)
        let adapter = SystemMSeriesV11BatchDriver(gpuDriverFactory: { substitute }, now: { clock.now })
        let cancellation = MSeriesCancellation()
        try await adapter.prepare(id: "power.gpu.peak", workers: 1, cancellation: cancellation)
        let batch = try await adapter.next(id: "power.gpu.peak", cancellation: cancellation)
        XCTAssertEqual(batch.startMonotonicNs, 1_000_000_000)
        XCTAssertEqual(batch.endMonotonicNs, 3_000_000_000)
        XCTAssertEqual(batch.gpuElapsedSeconds, 1)
        XCTAssertEqual(batch.workUnits, Double(262144 * 12) / 1e6)
        XCTAssertEqual(batch.checksum, 7)
        XCTAssertEqual(clock.now, 10_000_000_000, "slow validation cannot extend the recorded workload interval")
        XCTAssertTrue(batch.isValid)
        await adapter.finish()
        let events = await substitute.events
        XCTAssertEqual(events, ["prepare1920x1080:262144:1:12", "warmup", "execute", "validate", "drain"])
    }
}

private final class V11MetalBoundaryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ns: UInt64 = 0
    var now: UInt64 { lock.withLock { ns } }
    func advance(_ seconds: UInt64) { lock.withLock { ns += seconds * 1_000_000_000 } }
}

private actor V11MetalBoundaryDriver: MSeriesV11Metal3DDriving {
    let clock: V11MetalBoundaryClock
    private(set) var events: [String] = []
    init(clock: V11MetalBoundaryClock) { self.clock = clock }
    func prepare(workload: Metal3DBenchmarkWorkload) {
        events.append("prepare\(workload.width)x\(workload.height):\(workload.instanceCount):\(workload.frameCount):\(workload.trianglesPerInstance)")
    }
    func warmUp() { events.append("warmup"); clock.advance(1) }
    func execute() -> MSeriesV11Metal3DExecution {
        events.append("execute")
        var value = MSeriesV11Metal3DExecution(gpuElapsedSeconds: 1, wallElapsedSeconds: 2, ranOnMainThread: false)
        value.startMonotonicNs = clock.now
        clock.advance(2)
        value.endMonotonicNs = clock.now
        return value
    }
    func validate() -> UInt64 { events.append("validate"); clock.advance(7); return 7 }
    func tearDown() { events.append("drain") }
}
