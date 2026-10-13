import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class LightfieldEnergyProcessResolutionTests: XCTestCase {
    func testLargePIDPassLeavesMainActorResponsiveAndReusesOneBuffer() async throws {
        let pids = (100_000..<110_000).map(Int32.init)
        let app = energyNamingApp(processIDs: pids, bundlePath: "/Fixture/Browser.app")
        let probe = EnergyNamingReadProbe(blocksFirstRead: true) { _ in
            "/Fixture/Browser.app/Contents/MacOS/Browser Helper (Renderer)"
        }
        let work = Task { await probe.resolver.resolve(app) }
        defer { probe.release(); work.cancel() }
        try await probe.waitForBlockedRead()
        // This code executes on MainActor while the first kernel read is held.
        // A synchronous resolver fails both this check and the thread checks.
        var mainActorHeartbeat = 0
        mainActorHeartbeat += 1
        XCTAssertEqual(mainActorHeartbeat, 1)
        XCTAssertTrue(probe.snapshot.waiting)
        XCTAssertEqual(probe.snapshot.reads, 1)
        XCTAssertEqual(probe.snapshot.mainThreadOperations, 0)
        probe.release()
        let result = await work.value
        XCTAssertEqual(result.count, 10_000)
        XCTAssertEqual(result[pids.last!]?.name, L10n.text("Fixture Browser · 网页渲染", "Fixture Browser · Web Renderer"))
        let stats = probe.snapshot
        XCTAssertEqual(stats.factories, 1)
        XCTAssertEqual(stats.reads, 10_000)
        XCTAssertEqual(stats.namedPIDs.count, 10_000)
        XCTAssertEqual(stats.bufferAddresses.count, 1)
        XCTAssertEqual(stats.mainThreadOperations, 0)
        XCTAssertFalse(stats.gateExpired)
    }

    func testBundleIdentityRejectsReusedMissingAndLookalikePIDsBeforeNameLookup() async {
        let paths: [Int32: String] = [
            1: "/Fixture/Browser.app/Contents/MacOS/Browser",
            2: "/Fixture/Browser.app-evil/Contents/MacOS/Browser",
            3: "/Other/Browser.app/Contents/MacOS/Browser",
            4: "/Fixture/Browser.app",
            6: "relative/path"
        ]
        let probe = EnergyNamingReadProbe(paths: { paths[$0] }, names: { _ in "Verified Browser" })
        let result = await probe.resolver.resolve(energyNamingApp(processIDs: [1, 2, 3, 4, 5, 6], bundlePath: "/Fixture/Browser.app"))
        XCTAssertEqual(Set(result.keys), [1])
        XCTAssertEqual(result[1], .init(name: "Verified Browser", path: paths[1]!, bundlePath: "/Fixture/Browser.app"))
        XCTAssertEqual(probe.snapshot.namedPIDs, [1])
        XCTAssertEqual(probe.snapshot.reads, 6)
        XCTAssertEqual(probe.snapshot.mainThreadOperations, 0)
    }

    func testStandaloneIdentityRequiresTheCapturedExecutableAndHasNoAppIconPath() async {
        let probe = EnergyNamingReadProbe { pid in pid == 1 ? "/usr/libexec/worker" : "/usr/libexec/worker-reused" }
        let result = await probe.resolver.resolve(energyNamingApp(processIDs: [1, 2], bundlePath: nil, path: "/usr/libexec/worker"))
        XCTAssertEqual(Set(result.keys), [1])
        XCTAssertEqual(result[1]?.name, "worker")
        XCTAssertNil(result[1]?.bundlePath, "Verified daemons keep the B2 grey placeholder")
        XCTAssertEqual(probe.snapshot.namedPIDs, [1])
    }

    func testCancelledPassDiscardsItsResultAndStopsBeforeResolvingMorePIDs() async throws {
        let probe = EnergyNamingReadProbe(blocksFirstRead: true) { _ in "/Fixture/Browser.app/Contents/MacOS/Browser" }
        let work = Task { await probe.resolver.resolve(energyNamingApp(processIDs: [1, 2, 3], bundlePath: "/Fixture/Browser.app")) }
        defer { probe.release(); work.cancel() }
        try await probe.waitForBlockedRead()
        work.cancel()
        probe.release()
        let result = await work.value
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(probe.snapshot.reads, 1)
        XCTAssertTrue(probe.snapshot.namedPIDs.isEmpty)
        XCTAssertFalse(probe.snapshot.gateExpired)
    }

    func testReusedBufferDoesNotCarryThePreviousLongPathIntoAShorterRead() async {
        let short = "/Fixture/Browser.app/x"
        let long = "/Fixture/Browser.app/" + String(repeating: "a", count: 1_000)
        let probe = EnergyNamingReadProbe { $0 == 1 ? long : short }
        let result = await probe.resolver.resolve(energyNamingApp(processIDs: [1, 2], bundlePath: "/Fixture/Browser.app"))
        XCTAssertEqual(result[1]?.path, long)
        XCTAssertEqual(result[2]?.path, short)
        XCTAssertEqual(result[2]?.name, "x")
        XCTAssertEqual(probe.snapshot.bufferAddresses.count, 1)
    }
}

/// A bounded fake kernel read used by both the resolver tests and the real
/// 400-app page test. It preserves the production reader and identity checks.
final class EnergyNamingReadProbe: @unchecked Sendable {
    struct Snapshot: Sendable {
        var factories = 0
        var reads = 0
        var namedPIDs: Set<Int32> = []
        var bufferAddresses: Set<UInt> = []
        var buffersByReader: [Int: Set<UInt>] = [:]
        var readsByReader: [Int: Int] = [:]
        var waitingReaders: Set<Int> = []
        var released = false
        var mainThreadOperations = 0
        var waiting = false
        var gateExpired = false
    }
    private let lock = NSLock()
    private var state = Snapshot()
    private let gate = DispatchSemaphore(value: 0)
    private let blocksFirstRead: Bool
    private let paths: @Sendable (Int32) -> String?
    private let names: @Sendable (Int32) -> String?

    init(blocksFirstRead: Bool = false, paths: @escaping @Sendable (Int32) -> String?,
         names: @escaping @Sendable (Int32) -> String? = { _ in nil }) {
        self.blocksFirstRead = blocksFirstRead; self.paths = paths; self.names = names
    }
    var snapshot: Snapshot { lock.withLock { state } }
    func release() {
        let count = lock.withLock { state.released = true; return state.waitingReaders.count }
        for _ in 0..<count { gate.signal() }
    }
    var resolver: LightfieldEnergyProcessResolver {
        .init(makeReader: { [self] in makeReader() }, runningName: { [self] in runningName($0) })
    }
    private func makeReader() -> EnergyImpactService.ExecutablePathReader {
        let readerID = lock.withLock {
            state.factories += 1
            if Thread.isMainThread { state.mainThreadOperations += 1 }
            return state.factories
        }
        return .init(kernelRead: { [self] in read($0, into: $1, capacity: $2, readerID: readerID) })
    }
    private func runningName(_ pid: Int32) -> String? {
        lock.withLock {
            state.namedPIDs.insert(pid)
            if Thread.isMainThread { state.mainThreadOperations += 1 }
        }
        return names(pid)
    }
    private func read(_ pid: Int32, into buffer: UnsafeMutableRawPointer?, capacity: UInt32, readerID: Int) -> Int32 {
        let shouldBlock = lock.withLock {
            state.reads += 1
            if Thread.isMainThread { state.mainThreadOperations += 1 }
            if let buffer {
                let address = UInt(bitPattern: buffer)
                state.bufferAddresses.insert(address)
                state.buffersByReader[readerID, default: []].insert(address)
            }
            state.readsByReader[readerID, default: 0] += 1
            let first = blocksFirstRead && state.readsByReader[readerID] == 1 && !state.released
            if first { state.waitingReaders.insert(readerID) }
            state.waiting = !state.waitingReaders.isEmpty
            return first
        }
        if shouldBlock {
            let expired = gate.wait(timeout: .now() + 5) == .timedOut
            lock.withLock {
                state.waitingReaders.remove(readerID)
                state.waiting = !state.waitingReaders.isEmpty
                state.gateExpired = state.gateExpired || expired
            }
        }
        guard let path = paths(pid), let buffer else { return 0 }
        let bytes = Array(path.utf8)
        guard bytes.count < Int(capacity) else { return 0 }
        bytes.withUnsafeBytes { source in buffer.copyMemory(from: source.baseAddress!, byteCount: source.count) }
        buffer.storeBytes(of: UInt8(0), toByteOffset: bytes.count, as: UInt8.self)
        return Int32(bytes.count)
    }
    @MainActor func waitForBlockedRead() async throws {
        for _ in 0..<500 {
            if snapshot.waiting { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The production resolver never started the held background read")
    }
    @MainActor func waitForNamedPIDs(_ count: Int) async throws {
        for _ in 0..<500 {
            if snapshot.namedPIDs.count == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The production resolver did not finish naming the captured PID batch")
    }
}

func energyNamingApp(processIDs: [Int32], bundlePath: String?, path: String = "") -> EnergyImpactApp {
    EnergyImpactApp(id: "naming-app", name: "Fixture Browser", path: path, iconPath: bundlePath ?? "",
        bundlePath: bundlePath, bundleIdentifier: nil, measuredEnergyWh: 1, estimatedSupplementEnergyWh: 0,
        estimatedEnergyWh: 1, currentPowerWatts: 1, averagePowerWatts: 1, cpuPercent: 1,
        diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0, residentBytes: 1_024, cumulativeCPUSeconds: 1,
        longestRunningSeconds: 60, processCount: processIDs.count, measuredProcessCount: processIDs.count,
        processIDs: processIDs, isApplication: bundlePath != nil, currentMeasuredProcessCount: processIDs.count,
        sampledAt: Date(timeIntervalSince1970: 1_000), currentSampleSeconds: 1)
}
