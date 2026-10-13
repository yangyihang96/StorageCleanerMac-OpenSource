import Foundation
import XCTest
@testable import StorageCleanerMac

final class ProcessSamplingCacheTests: XCTestCase {
    func testProductionEntriesShareDiscoveryWhenMemoryArrivesDuringPS() async throws {
        let inspector = ProcessReadInspector(pids: [730, 731, 732])
        let gate = ProcessDiscoveryGate()
        let waiting = expectation(description: "memory awaits registered energy discovery")
        let cache = inspector.makeCache(onDiscoveryWait: { waiting.fulfill() })
        let energy = Task {
            await EnergyImpactService.menuBarCounterFrame(readProcessList: {
                await gate.read(inspector)
            }, readResourceUsage: { inspector.energyUsage($0) }, metadataCache: cache)
        }
        await gate.waitUntilStarted()
        let memory = Task { await inspector.memoryAwaiting(cache) }
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertEqual(inspector.state.discoveryReads, 0)
        await gate.open()
        let frame = await energy.value
        let sample = await memory.value
        XCTAssertNotNil(frame)
        XCTAssertEqual(Set(sample.processes.map(\.id)), [730, 731, 732])
        XCTAssertEqual(inspector.state.psReads, 1)
        XCTAssertEqual(inspector.state.discoveryReads, 0,
                       "actual frame + memory probe entries share one in-flight discovery")
        XCTAssertEqual(inspector.state.pathReads, [730: 1, 731: 1, 732: 1])
        XCTAssertEqual(inspector.state.nameReads, 3)
        XCTAssertEqual(inspector.state.energyReads[732], 1)
        XCTAssertEqual(inspector.state.memoryReads[732], 1)
    }

    func testInFlightDiscoveryTimeoutFallsBackToTheFullNativeList() async {
        let inspector = ProcessReadInspector(pids: [733, 734])
        let gate = ProcessDiscoveryGate()
        let cache = inspector.makeCache()
        let energy = Task {
            await EnergyImpactService.menuBarCounterFrame(readProcessList: {
                await gate.read(inspector)
            }, readResourceUsage: { inspector.energyUsage($0) }, metadataCache: cache)
        }
        await gate.waitUntilStarted()
        let memory = await inspector.memoryAwaiting(cache, timeout: .zero)
        XCTAssertEqual(Set(memory.processes.map(\.id)), [733, 734])
        XCTAssertEqual(inspector.state.discoveryReads, 1)
        await gate.open()
        _ = await energy.value
    }

    func testCancellingMemoryWaitDoesNotCancelPSOrConsumeItsInventory() async {
        let inspector = ProcessReadInspector(pids: [735])
        let gate = ProcessDiscoveryGate()
        let waiting = expectation(description: "memory registered")
        let cache = inspector.makeCache(onDiscoveryWait: { waiting.fulfill() })
        let energy = Task {
            await EnergyImpactService.menuBarCounterFrame(readProcessList: {
                await gate.read(inspector)
            }, readResourceUsage: { inspector.energyUsage($0) }, metadataCache: cache)
        }
        await gate.waitUntilStarted()
        let memory = Task { await inspector.memoryAwaiting(cache) }
        await fulfillment(of: [waiting], timeout: 2)
        memory.cancel()
        let cancelled = await memory.value
        XCTAssertTrue(cancelled.processes.isEmpty)
        XCTAssertEqual(inspector.state.discoveryReads, 0)
        await gate.open()
        let frame = await energy.value
        XCTAssertNotNil(frame)
        XCTAssertEqual(inspector.memory(cache).processes.map(\.id), [735])
        XCTAssertEqual(inspector.state.discoveryReads, 0)
    }

    func testCancelledEnergyDiscoveryReleasesMemoryToItsOwnFullDiscovery() async {
        let inspector = ProcessReadInspector(pids: [736, 737])
        let gate = ProcessDiscoveryGate()
        let waiting = expectation(description: "memory registered")
        let cache = inspector.makeCache(onDiscoveryWait: { waiting.fulfill() })
        let energy = Task {
            await EnergyImpactService.menuBarCounterFrame(readProcessList: {
                await gate.read(inspector)
            }, readResourceUsage: { inspector.energyUsage($0) }, metadataCache: cache)
        }
        await gate.waitUntilStarted()
        let memory = Task { await inspector.memoryAwaiting(cache) }
        await fulfillment(of: [waiting], timeout: 2)
        energy.cancel()
        await gate.open()
        let frame = await energy.value
        let sample = await memory.value
        XCTAssertNil(frame)
        XCTAssertEqual(Set(sample.processes.map(\.id)), [736, 737])
        XCTAssertEqual(inspector.state.discoveryReads, 1)
    }

    func testMemoryFirstWithoutARegisteredFlightDoesNotWaitForFuturePS() async {
        let inspector = ProcessReadInspector(pids: [738])
        let cache = inspector.makeCache()
        let memory = await inspector.memoryAwaiting(cache)
        XCTAssertEqual(memory.processes.map(\.id), [738])
        XCTAssertEqual(inspector.state.discoveryReads, 1)
    }

    func testFailedEnergyDiscoveryReleasesWaitingMemoryToFullNativeDiscovery() async {
        let inspector = ProcessReadInspector(pids: [739, 740])
        inspector.update { $0.failPS = true }
        let gate = ProcessDiscoveryGate()
        let waiting = expectation(description: "memory registered before failed ps completes")
        let cache = inspector.makeCache(onDiscoveryWait: { waiting.fulfill() })
        let energy = Task {
            await EnergyImpactService.menuBarCounterFrame(readProcessList: {
                await gate.read(inspector)
            }, readResourceUsage: { inspector.energyUsage($0) }, metadataCache: cache)
        }
        await gate.waitUntilStarted()
        let memory = Task { await inspector.memoryAwaiting(cache) }
        await fulfillment(of: [waiting], timeout: 2)
        await gate.open()
        let frame = await energy.value
        let sample = await memory.value
        XCTAssertNil(frame)
        XCTAssertEqual(Set(sample.processes.map(\.id)), [739, 740])
        XCTAssertEqual(inspector.state.discoveryReads, 1)
    }

    func testCPUFrameSharesCompleteDiscoveryWithMemoryAndReadsDynamicProvidersAgain() async throws {
        let inspector = ProcessReadInspector(pids: [701, 702, 703])
        inspector.update { $0.footprints[703] = 8_000 }
        let cache = inspector.makeCache()
        let frame = try await requireFrame(inspector, cache)
        XCTAssertEqual(frame.rows.map(\.pid), [701, 702, 703])
        let memory = inspector.memory(cache)
        XCTAssertEqual(Set(memory.processes.map(\.id)), [701, 702, 703],
                       "a low-CPU process absent from menu Top-K still belongs to the memory inventory")
        XCTAssertEqual(memory.processes.first?.id, 703)
        XCTAssertEqual(inspector.state.psReads, 1)
        XCTAssertEqual(inspector.state.discoveryReads, 0, "one ps discovery replaces ps + proc_listpids")
        XCTAssertEqual(inspector.state.pathReads, [701: 1, 702: 1, 703: 1])
        XCTAssertEqual(inspector.state.nameReads, 3, "CPU and memory share static path/name resolution")
        XCTAssertEqual(inspector.state.energyReads, [701: 1, 702: 1, 703: 1])
        XCTAssertEqual(inspector.state.memoryReads, [701: 1, 702: 1, 703: 1])
        XCTAssertEqual(inspector.state.identityReads, [701: 1, 702: 1, 703: 1])

        _ = inspector.memory(cache)
        XCTAssertEqual(inspector.state.discoveryReads, 1, "a second memory round cannot reuse the inventory")
        XCTAssertEqual(inspector.state.pathReads[703], 1)
        XCTAssertEqual(inspector.state.memoryReads[703], 2)
    }

    func testValidPIDWithMalformedMetricsRemainsInSharedMemoryInventory() async throws {
        let malformedRows = [
            "742 invalid-parent 2 00:10 1.0 0.1 /usr/bin/process742",
            "742 1 invalid-rss 00:10 1.0 0.1 /usr/bin/process742",
            "742 1 2 00:10 invalid-time 0.1 /usr/bin/process742",
            "742 1 2 00:10 1.0 invalid-percent /usr/bin/process742",
            "742",
        ]
        for malformedRow in malformedRows {
            let inspector = ProcessReadInspector(pids: [741, 742])
            let cache = inspector.makeCache()
            _ = try await requireFrame(inspector, cache)
            _ = inspector.memory(cache)
            let output = "741 1 2 00:10 1.0 0.1 /usr/bin/process741\n\(malformedRow)"
            inspector.update { $0.psOutputOverride = output }

            let discovery = EnergyImpactService.processPIDDiscovery(fromPSOutput: output)
            XCTAssertEqual(discovery.pids, [741, 742], malformedRow)
            XCTAssertTrue(discovery.isComplete, malformedRow)
            let frame = try await requireFrame(inspector, cache)
            XCTAssertEqual(frame.rows.map(\.pid), [741], "invalid metrics never become invented energy values")
            let memory = inspector.memory(cache)
            XCTAssertEqual(Set(memory.processes.map(\.id)), [741, 742], malformedRow)
            XCTAssertEqual(inspector.state.psReads, 2)
            XCTAssertEqual(inspector.state.discoveryReads, 0,
                           "PID-only discovery still saves the native list read when metrics fail")
            XCTAssertEqual(inspector.state.pathReads, [741: 1, 742: 1],
                           "metric failure must not evict a live PID's static metadata")
            XCTAssertEqual(inspector.state.energyReads[742], 1, "only the earlier valid energy row was sampled")
            XCTAssertEqual(inspector.state.memoryReads[742], 2, "memory keeps fresh native usage reads")
            XCTAssertEqual(inspector.state.identityReads[742], 2)
        }
    }

    func testAllMalformedMetricsStillPublishValidPIDsForMemory() async {
        let inspector = ProcessReadInspector(pids: [743, 744])
        inspector.update { $0.psOutputOverride = "743 malformed-metrics\n744" }
        let cache = inspector.makeCache()
        let frame = await readFrame(inspector, cache)
        XCTAssertNil(frame, "no valid energy metrics means no energy frame")
        let memory = inspector.memory(cache)
        XCTAssertEqual(Set(memory.processes.map(\.id)), [743, 744])
        XCTAssertEqual(inspector.state.psReads, 1)
        XCTAssertEqual(inspector.state.discoveryReads, 0,
                       "a complete PID list is useful even when no energy row is usable")
        XCTAssertTrue(inspector.state.energyReads.isEmpty)
        XCTAssertEqual(inspector.state.memoryReads, [743: 1, 744: 1])
        XCTAssertEqual(inspector.state.identityReads, [743: 1, 744: 1])
    }

    func testUnparseablePIDMakesEnergyHintIncompleteAndMemoryUsesFullNativeDiscovery() async throws {
        for invalidPID in ["invalid-pid", "0", "-1", "2147483648"] {
            let inspector = ProcessReadInspector(pids: [745, 746])
            let cache = inspector.makeCache()
            _ = cache.metadata(pid: 746, birth: 111)
            cache.publishEnergyDiscovery([745, 746])
            let output = "745 1 2 00:10 1.0 0.1 /usr/bin/process745\n\(invalidPID) malformed-metrics"
            inspector.update { $0.psOutputOverride = output }
            let discovery = EnergyImpactService.processPIDDiscovery(fromPSOutput: output)
            XCTAssertEqual(discovery.pids, [745])
            XCTAssertFalse(discovery.isComplete, invalidPID)

            _ = try await requireFrame(inspector, cache)
            let memory = inspector.memory(cache)
            XCTAssertEqual(Set(memory.processes.map(\.id)), [745, 746], invalidPID)
            XCTAssertEqual(inspector.state.discoveryReads, 1,
                           "an incomplete current hint must replace the earlier complete hint and read the native list")
            XCTAssertEqual(inspector.state.pathReads[746], 1,
                           "an incomplete hint cannot declare an unlisted PID exited")
            XCTAssertEqual(inspector.state.memoryReads[746], 1)
            XCTAssertEqual(inspector.state.identityReads[746], 1)
        }
    }

    func testMissingExpiredAndIncompleteHintsEachPerformOneFullNativeDiscovery() {
        for hint in ["missing", "expired", "incomplete"] {
            let inspector = ProcessReadInspector(pids: [747, 748])
            let cache = inspector.makeCache()
            _ = cache.metadata(pid: 748, birth: 111)
            switch hint {
            case "expired":
                cache.publishEnergyDiscovery([747])
                inspector.update { $0.now = 101.01 }
            case "incomplete":
                cache.publishEnergyDiscovery([747], isComplete: false)
            default:
                break
            }
            let memory = inspector.memory(cache)
            XCTAssertEqual(Set(memory.processes.map(\.id)), [747, 748], hint)
            XCTAssertEqual(inspector.state.discoveryReads, 1, hint)
            if hint == "incomplete" {
                XCTAssertEqual(inspector.state.pathReads[748], 1,
                               "explicitly incomplete hints cannot evict static metadata either")
            }
        }
    }

    func testWarmFramesReusePathAndNamesWhileKeepingFreshPSFieldsAndBirthReads() async throws {
        let inspector = ProcessReadInspector(pids: [704])
        let cache = inspector.makeCache()
        for round in 1...3 {
            inspector.update {
                $0.cpuPercent = Double(round)
                $0.cpuSeconds = Double(round)
            }
            let frame = try await requireFrame(inspector, cache)
            XCTAssertEqual(frame.rows.first?.cpuPercent, Double(round))
            XCTAssertEqual(frame.rows.first?.cpuTimeSeconds, Double(round))
            _ = inspector.memory(cache)
        }
        XCTAssertEqual(inspector.state.psReads, 3)
        XCTAssertEqual(inspector.state.discoveryReads, 0)
        XCTAssertEqual(inspector.state.energyReads[704], 3, "birth comes from a fresh rusage every frame")
        XCTAssertEqual(inspector.state.memoryReads[704], 3)
        XCTAssertEqual(inspector.state.identityReads[704], 3)
        XCTAssertEqual(inspector.state.pathReads[704], 1, "six consumer passes need one physical path read")
        XCTAssertEqual(inspector.state.nameReads, 1)
    }

    func testMemoryFirstKeepsNativeDiscoveryButSharesItsStaticMetadataWithNextFrame() async throws {
        let inspector = ProcessReadInspector(pids: [705])
        let cache = inspector.makeCache()
        _ = inspector.memory(cache)
        _ = try await requireFrame(inspector, cache)
        XCTAssertEqual(inspector.state.discoveryReads, 1,
                       "memory before ps still discovers all PIDs independently")
        XCTAssertEqual(inspector.state.psReads, 1)
        XCTAssertEqual(inspector.state.pathReads[705], 1)
        XCTAssertEqual(inspector.state.nameReads, 1)
    }

    func testExpiredOrBackwardClockDiscoveryFallsBackAndIncludesNewProcesses() {
        for time in [101.01, 99.0] {
            let inspector = ProcessReadInspector(pids: [706])
            let cache = inspector.makeCache()
            cache.publishEnergyDiscovery([706])
            inspector.update { $0.now = time; $0.pids = [706, 707] }
            let memory = inspector.memory(cache)
            XCTAssertEqual(Set(memory.processes.map(\.id)), [706, 707])
            XCTAssertEqual(inspector.state.discoveryReads, 1)
        }
    }

    func testFailedCPUDiscoveryCannotLeaveAnOldInventoryForMemory() async {
        let inspector = ProcessReadInspector(pids: [708])
        let cache = inspector.makeCache()
        cache.publishEnergyDiscovery([708])
        inspector.update { $0.failPS = true; $0.pids = [709] }
        let frame = await readFrame(inspector, cache)
        XCTAssertNil(frame)
        XCTAssertEqual(inspector.memory(cache).processes.map(\.id), [709])
        XCTAssertEqual(inspector.state.discoveryReads, 1)
    }

    func testCancelledCPUReadDoesNotInvalidateDiscoveryNeededByMemory() async {
        let inspector = ProcessReadInspector(pids: [722])
        let cache = inspector.makeCache()
        cache.publishEnergyDiscovery([722])
        let task = Task {
            await EnergyImpactService.menuBarCounterFrame(readProcessList: {
                withUnsafeCurrentTask { $0?.cancel() }
                return ""
            }, readResourceUsage: { inspector.energyUsage($0) }, metadataCache: cache)
        }
        let frame = await task.value
        XCTAssertNil(frame)
        XCTAssertEqual(inspector.memory(cache).processes.map(\.id), [722])
        XCTAssertEqual(inspector.state.discoveryReads, 0,
                       "cancelling one consumer does not cancel or poison the shared discovery")
    }

    func testCancelledMemoryReadDoesNotConsumeTheOtherConsumersDiscovery() async {
        let inspector = ProcessReadInspector(pids: [723])
        let cache = inspector.makeCache()
        cache.publishEnergyDiscovery([723])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return inspector.memory(cache)
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled.processes.isEmpty)
        XCTAssertEqual(inspector.memory(cache).processes.map(\.id), [723])
        XCTAssertEqual(inspector.state.discoveryReads, 0)
        XCTAssertEqual(inspector.state.memoryReads[723], 1)
    }

    func testStaleRunningAppIdentityCannotAttachToAReusedPIDOrAuthorizeQuit() {
        let inspector = ProcessReadInspector(pids: [724])
        let cache = inspector.makeCache()
        let stale = SystemMemoryProbe.RunningAppIdentity(
            name: "Old App", bundleIdentifier: "example.old", bundlePath: "/Applications/Old.app",
            executablePath: "/Applications/Old.app/Contents/MacOS/Old", launchDate: Date(timeIntervalSince1970: 5),
            activationPolicy: .regular, isActive: true, processStartTime: 5_000_000)
        let memory = SystemMemoryProbe.processes(
            physicalBytes: 10_000, capturedAt: Date(timeIntervalSince1970: 10), runningApps: [724: stale],
            processCache: cache, readUsage: { _ in .init(footprintBytes: 1_000, birth: 111) },
            readIdentity: { _ in .init(startTime: 6_000_000, userIdentifier: 123) },
            currentPID: 999, currentUser: 123)
        XCTAssertEqual(memory.processes.first?.path, "/usr/bin/process724")
        XCTAssertEqual(memory.processes.first?.launchDate, Date(timeIntervalSince1970: 6))
        XCTAssertNil(memory.processes.first?.bundleIdentifier)
        XCTAssertEqual(memory.processes.first?.canQuit, false)
        XCTAssertEqual(memory.processes.first?.isActive, false)
    }

    func testFailedNativeDiscoveryRetriesAndDoesNotClaimACompleteEmptyList() {
        let inspector = ProcessReadInspector(pids: [710])
        let cache = inspector.makeCache()
        _ = inspector.memory(cache)
        inspector.update { $0.pids = nil }
        let unavailable = inspector.memory(cache)
        XCTAssertTrue(unavailable.processes.isEmpty)
        XCTAssertEqual(unavailable.warnings.count, 1)
        inspector.update { $0.pids = [710] }
        XCTAssertEqual(inspector.memory(cache).processes.map(\.id), [710])
        XCTAssertEqual(inspector.state.discoveryReads, 3)
        XCTAssertEqual(inspector.state.pathReads[710], 1,
                       "an unsuccessful discovery does not assert that all known processes exited")
    }

    func testReusedPIDRevalidatesPathNameAndRejectsTheOldCounterBaseline() async throws {
        let inspector = ProcessReadInspector(pids: [711])
        let cache = inspector.makeCache()
        let first = try await requireFrame(inspector, cache)
        _ = inspector.memory(cache)
        inspector.update {
            $0.births[711] = 222
            $0.paths[711] = "/Applications/Replacement.app/Contents/MacOS/Replacement"
        }
        let second = try await requireFrame(inspector, cache)
        let memory = inspector.memory(cache)
        XCTAssertEqual(second.rows.first?.path, inspector.state.paths[711])
        XCTAssertEqual(memory.processes.first?.name, "Replacement")
        XCTAssertEqual(inspector.state.pathReads[711], 2)
        XCTAssertEqual(inspector.state.nameReads, 2)
        XCTAssertEqual(inspector.state.energyReads[711], 2)
        XCTAssertEqual(inspector.state.memoryReads[711], 2)
        let before = EnergyImpactService.MenuBarCounterFrame(sampledAt: first.sampledAt, uptime: 1,
                                                            rows: first.rows, counters: first.counters)
        let after = EnergyImpactService.MenuBarCounterFrame(sampledAt: second.sampledAt, uptime: 2,
                                                           rows: second.rows, counters: second.counters)
        XCTAssertNil(EnergyImpactService.menuBarSnapshot(previous: before, current: after, metadataCache: cache))
    }

    func testUsagePermissionDenialEvictsAndRecoversWithoutUsingOldMemory() {
        let inspector = ProcessReadInspector(pids: [712])
        let cache = inspector.makeCache()
        XCTAssertEqual(inspector.memory(cache).processes.count, 1)
        inspector.update { $0.denyUsage.insert(712) }
        XCTAssertTrue(inspector.memory(cache).processes.isEmpty)
        inspector.update { $0.denyUsage.remove(712); $0.footprints[712] = 9_000 }
        let recovered = inspector.memory(cache)
        XCTAssertEqual(recovered.processes.first?.residentBytes, 9_000)
        XCTAssertEqual(inspector.state.memoryReads[712], 3)
        XCTAssertEqual(inspector.state.pathReads[712], 2)
        XCTAssertEqual(inspector.state.nameReads, 2)
    }

    func testMemoryBirthChangeInvalidatesMetadataEvenWhenTheExecutablePathIsUnchanged() {
        let inspector = ProcessReadInspector(pids: [725])
        let cache = inspector.makeCache()
        _ = inspector.memory(cache)
        inspector.update { $0.births[725] = 222 }
        _ = inspector.memory(cache)
        XCTAssertEqual(inspector.state.pathReads[725], 2)
        XCTAssertEqual(inspector.state.nameReads, 2)
        XCTAssertEqual(inspector.state.memoryReads[725], 2)
    }

    func testBSDPermissionDenialEvictsAndRecovers() {
        let inspector = ProcessReadInspector(pids: [713])
        let cache = inspector.makeCache()
        _ = inspector.memory(cache)
        inspector.update { $0.denyIdentity.insert(713) }
        let denied = inspector.memory(cache)
        XCTAssertTrue(denied.processes.isEmpty)
        XCTAssertEqual(denied.warnings.count, 1)
        inspector.update { $0.denyIdentity.remove(713) }
        XCTAssertEqual(inspector.memory(cache).processes.count, 1)
        XCTAssertEqual(inspector.state.identityReads[713], 3)
        XCTAssertEqual(inspector.state.pathReads[713], 2)
    }

    func testFailedPathIsNeverNegativelyCachedAndUnknownBirthNeverReusesMetadata() {
        let inspector = ProcessReadInspector(pids: [714])
        let cache = inspector.makeCache()
        inspector.update { $0.denyPath.insert(714) }
        XCTAssertTrue(inspector.memory(cache).processes.isEmpty)
        inspector.update { $0.denyPath.remove(714) }
        XCTAssertEqual(inspector.memory(cache).processes.count, 1)
        XCTAssertEqual(inspector.state.pathReads[714], 2)
        XCTAssertEqual(inspector.state.nameReads, 1)
        inspector.update { $0.births[714] = 0 }
        _ = inspector.memory(cache)
        _ = inspector.memory(cache)
        XCTAssertEqual(inspector.state.pathReads[714], 4)
        XCTAssertEqual(inspector.state.nameReads, 3)
    }

    func testExitEvictsMetadataEvenIfTheSyntheticPIDReturnsWithTheSameBirth() {
        let inspector = ProcessReadInspector(pids: [715, 716])
        let cache = inspector.makeCache()
        _ = inspector.memory(cache)
        inspector.update { $0.pids = [715] }
        XCTAssertEqual(inspector.memory(cache).processes.map(\.id), [715])
        inspector.update { $0.pids = [715, 716] }
        _ = inspector.memory(cache)
        XCTAssertEqual(inspector.state.pathReads, [715: 1, 716: 2])
        cache.publishEnergyDiscovery([])
        cache.publishEnergyDiscovery([715])
        _ = inspector.memory(cache)
        XCTAssertEqual(inspector.state.pathReads[715], 2, "ps exits evict too")
    }

    func testChangedPSExecutableHintInvalidatesMetadataEvenWithTheSameBirth() async throws {
        let inspector = ProcessReadInspector(pids: [717])
        let cache = inspector.makeCache()
        _ = inspector.memory(cache) // entry starts without a ps path hint
        inspector.update { $0.paths[717] = "/Applications/NewImage.app/Contents/MacOS/NewImage" }
        let frame = try await requireFrame(inspector, cache)
        XCTAssertEqual(frame.rows.first?.path, inspector.state.paths[717])
        inspector.update { $0.paths[717] = "/Applications/ThirdImage.app/Contents/MacOS/ThirdImage" }
        let next = try await requireFrame(inspector, cache)
        XCTAssertEqual(next.rows.first?.path, inspector.state.paths[717])
        XCTAssertEqual(inspector.state.pathReads[717], 3)
    }

    func testStaticEntryLimitKeepsTheFullInventoryAndDoesNotCacheExcessRows() {
        let inspector = ProcessReadInspector(pids: [718, 719])
        let cache = inspector.makeCache(entryLimit: 1)
        XCTAssertEqual(inspector.memory(cache).processes.count, 2)
        XCTAssertEqual(inspector.memory(cache).processes.count, 2)
        XCTAssertEqual(inspector.state.pathReads, [718: 1, 719: 2])
    }

    func testOnlyDirectApplicationPresentationIsReusedAndBirthStillInvalidatesIt() {
        let inspector = ProcessReadInspector(pids: [720])
        inspector.update { $0.paths[720] = "/Applications/Display.app/Contents/MacOS/Display" }
        let cache = inspector.makeCache()
        _ = cache.metadata(pid: 720, birth: 111)
        let row = EnergyProcessRow(pid: 720, parentPID: 1, residentBytes: 1, elapsedSeconds: 1,
                                   cpuTimeSeconds: 1, cpuPercent: 1, path: inspector.state.paths[720]!)
        var nameReads = 0
        func resolve() -> EnergyImpactService.EnergyProcessPresentation {
            nameReads += 1
            return .init(name: "Display", groupKey: "bundle:display", groupPath: "/Applications/Display.app",
                         iconPath: "/Applications/Display.app", bundlePath: "/Applications/Display.app",
                         bundleIdentifier: "example.display", isApplication: true)
        }
        for _ in 0..<3 { _ = cache.energyPresentation(row: row, birth: 111, resolve: resolve) }
        XCTAssertEqual(nameReads, 1)
        _ = cache.metadata(pid: 720, birth: 222)
        _ = cache.energyPresentation(row: row, birth: 222, resolve: resolve)
        XCTAssertEqual(nameReads, 2)

        let standalone = EnergyProcessRow(pid: 721, parentPID: 720, residentBytes: 1, elapsedSeconds: 1,
                                          cpuTimeSeconds: 1, cpuPercent: 1, path: "/usr/libexec/helper")
        inspector.update { $0.paths[721] = standalone.path }
        _ = cache.metadata(pid: 721, birth: 111)
        for _ in 0..<2 { _ = cache.energyPresentation(row: standalone, birth: 111, resolve: resolve) }
        XCTAssertEqual(nameReads, 4, "parent attribution is resolved freshly rather than cached by child birth")
    }

    private func requireFrame(_ inspector: ProcessReadInspector, _ cache: ProcessSamplingCache) async throws
        -> EnergyImpactService.MenuBarCounterFrame {
        let frame = await readFrame(inspector, cache)
        return try XCTUnwrap(frame)
    }

    private func readFrame(_ inspector: ProcessReadInspector, _ cache: ProcessSamplingCache) async
        -> EnergyImpactService.MenuBarCounterFrame? {
        await EnergyImpactService.menuBarCounterFrame(
            readProcessList: { inspector.psOutput() }, readResourceUsage: { inspector.energyUsage($0) },
            metadataCache: cache)
    }
}

/// All shared helpers are available to Debug and Release tests. The lock is
/// the same synchronization boundary as the injected @Sendable providers.
private final class ProcessReadInspector: @unchecked Sendable {
    struct State {
        var pids: [Int32]?
        var paths: [Int32: String] = [:]
        var births: [Int32: UInt64] = [:]
        var footprints: [Int32: UInt64] = [:]
        var now: TimeInterval = 100
        var cpuPercent = 0.1
        var cpuSeconds = 1.0
        var failPS = false
        var psOutputOverride: String?
        var denyUsage: Set<Int32> = []
        var denyIdentity: Set<Int32> = []
        var denyPath: Set<Int32> = []
        var psReads = 0
        var discoveryReads = 0
        var pathReads: [Int32: Int] = [:]
        var nameReads = 0
        var energyReads: [Int32: Int] = [:]
        var memoryReads: [Int32: Int] = [:]
        var identityReads: [Int32: Int] = [:]
    }

    private let lock = NSLock()
    private var storage: State
    var state: State { lock.withLock { storage } }

    init(pids: [Int32]) {
        storage = State(pids: pids)
        for pid in pids { storage.paths[pid] = "/usr/bin/process\(pid)" }
    }

    func update(_ body: (inout State) -> Void) { lock.withLock { body(&storage) } }

    func makeCache(entryLimit: Int = 16_384, onDiscoveryWait: @escaping @Sendable () -> Void = {}) -> ProcessSamplingCache {
        ProcessSamplingCache(discover: { self.discover() }, readPath: { self.path($0) },
                             readName: { self.name($0) }, uptime: { self.state.now }, entryLimit: entryLimit,
                             onDiscoveryWait: onDiscoveryWait)
    }

    private func discover() -> [Int32]? {
        lock.withLock { storage.discoveryReads += 1; return storage.pids }
    }

    private func path(_ pid: Int32) -> String? {
        lock.withLock {
            storage.pathReads[pid, default: 0] += 1
            return storage.denyPath.contains(pid) ? nil : storage.paths[pid] ?? "/usr/bin/process\(pid)"
        }
    }

    private func name(_ path: String) -> String {
        lock.withLock { storage.nameReads += 1 }
        return URL(fileURLWithPath: EnergyImpactService.appBundlePath(in: path) ?? path)
            .deletingPathExtension().lastPathComponent
    }

    func psOutput() -> String {
        lock.withLock {
            storage.psReads += 1
            guard !storage.failPS else { return "" }
            if let output = storage.psOutputOverride { return output }
            return (storage.pids ?? []).map { pid in
                "\(pid) 1 2 00:10 \(storage.cpuSeconds) \(storage.cpuPercent) \(storage.paths[pid] ?? "/usr/bin/process\(pid)")"
            }.joined(separator: "\n")
        }
    }

    func energyUsage(_ pid: Int32) -> EnergyResourceUsage? {
        lock.withLock {
            storage.energyReads[pid, default: 0] += 1
            guard !storage.denyUsage.contains(pid) else { return nil }
            return .init(pid: pid, energyNanojoules: 1, cpuTimeMach: 1,
                         processStartMach: storage.births[pid] ?? 111, diskReadBytes: 1, diskWrittenBytes: 1)
        }
    }

    private func memoryUsage(_ pid: Int32) -> SystemMemoryProbe.ProcessUsage? {
        lock.withLock {
            storage.memoryReads[pid, default: 0] += 1
            guard !storage.denyUsage.contains(pid) else { return nil }
            return .init(footprintBytes: storage.footprints[pid] ?? 1_000, birth: storage.births[pid] ?? 111)
        }
    }

    private func identity(_ pid: Int32) -> SystemMemoryProbe.ProcessIdentity? {
        lock.withLock {
            storage.identityReads[pid, default: 0] += 1
            guard !storage.denyIdentity.contains(pid) else { return nil }
            return .init(startTime: 1_000_000, userIdentifier: 123)
        }
    }

    func memory(_ cache: ProcessSamplingCache) -> (processes: [MemoryProcess], warnings: [MeasurementWarning]) {
        SystemMemoryProbe.processes(physicalBytes: 10_000, capturedAt: Date(timeIntervalSince1970: 10),
                                    runningApps: [:], processCache: cache,
                                    readUsage: memoryUsage, readIdentity: identity, currentPID: 999, currentUser: 123)
    }

    func memoryAwaiting(_ cache: ProcessSamplingCache, timeout: Duration = .seconds(5)) async
        -> (processes: [MemoryProcess], warnings: [MeasurementWarning]) {
        await SystemMemoryProbe.processesAwaitingDiscovery(
            physicalBytes: 10_000, capturedAt: Date(timeIntervalSince1970: 10), runningApps: [:],
            processCache: cache, discoveryTimeout: timeout, readUsage: { self.memoryUsage($0) },
            readIdentity: { self.identity($0) }, currentPID: 999, currentUser: 123)
    }
}

private actor ProcessDiscoveryGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var readWaiter: CheckedContinuation<Void, Never>?

    func read(_ inspector: ProcessReadInspector) async -> String {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !released { await withCheckedContinuation { readWaiter = $0 } }
        return inspector.psOutput()
    }

    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiters.append($0) } }
    }

    func open() {
        released = true
        readWaiter?.resume()
        readWaiter = nil
    }
}
