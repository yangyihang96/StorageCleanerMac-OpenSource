import Combine
import XCTest
@testable import StorageCleanerMac

@MainActor
final class ScanStorePerformanceTests: XCTestCase {
    func testMenuRefreshCoordinatorPromotesSynchronouslyBeforeDriverStartsAndKeepsLoading() async {
        let probe = RecordingMenuSnapshotProbe()
        let coordinator = MenuBarRefreshCoordinator { request in
            await probe.sample(request)
        }

        coordinator.request(policy: .lightweight, showLoadingWhenEmpty: true)
        coordinator.request(policy: .fullMemory, showLoadingWhenEmpty: false)

        let becameIdle = await coordinator.waitUntilIdle(maximumYields: 10_000)
        let requests = await probe.requests()
        XCTAssertTrue(becameIdle)
        XCTAssertEqual(requests, [
            MenuBarRefreshRequest(policy: .fullMemory, showLoadingWhenEmpty: true)
        ])
    }

    func testMenuRefreshCoordinatorCurrentFullAbsorbsLowerPolicies() async {
        let probe = RecordingMenuSnapshotProbe(suspendFirstCall: true)
        let coordinator = MenuBarRefreshCoordinator { request in
            await probe.sample(request)
        }

        coordinator.request(policy: .fullMemory)
        let didStart = await probe.waitUntilCallCount(1, maximumYields: 10_000)
        XCTAssertTrue(didStart)
        coordinator.request(policy: .automatic)
        coordinator.request(policy: .lightweight)
        await probe.releaseFirstCall()

        let becameIdle = await coordinator.waitUntilIdle(maximumYields: 10_000)
        let requests = await probe.requests()
        let maximumConcurrentCalls = await probe.maximumConcurrentCalls()
        XCTAssertTrue(becameIdle)
        XCTAssertEqual(requests.map(\.policy), [.fullMemory])
        XCTAssertEqual(maximumConcurrentCalls, 1)
    }

    func testMenuRefreshCoordinatorQueuesOnlyHighestPolicyAboveCurrent() async {
        let probe = RecordingMenuSnapshotProbe(suspendFirstCall: true)
        let coordinator = MenuBarRefreshCoordinator { request in
            await probe.sample(request)
        }

        coordinator.request(policy: .lightweight)
        let didStart = await probe.waitUntilCallCount(1, maximumYields: 10_000)
        XCTAssertTrue(didStart)
        coordinator.request(policy: .automatic, showLoadingWhenEmpty: true)
        coordinator.request(policy: .fullMemory, showLoadingWhenEmpty: false)
        coordinator.request(policy: .lightweight)
        await probe.releaseFirstCall()

        let becameIdle = await coordinator.waitUntilIdle(maximumYields: 10_000)
        let requests = await probe.requests()
        let maximumConcurrentCalls = await probe.maximumConcurrentCalls()
        XCTAssertTrue(becameIdle)
        XCTAssertEqual(requests, [
            MenuBarRefreshRequest(policy: .lightweight, showLoadingWhenEmpty: false),
            MenuBarRefreshRequest(policy: .fullMemory, showLoadingWhenEmpty: true)
        ])
        XCTAssertEqual(maximumConcurrentCalls, 1)
    }

    func testMenuRefreshCoordinatorClearsInFlightAfterCancellationReturnsEarly() async {
        let probe = CancellationAwareMenuSnapshotProbe()
        let coordinator = MenuBarRefreshCoordinator { _ in
            await probe.waitForCancellation()
        }
        coordinator.request(policy: .automatic)
        let didStart = await probe.waitUntilStarted(maximumYields: 10_000)
        XCTAssertTrue(didStart)

        coordinator.cancelForTesting()
        let becameIdle = await coordinator.waitUntilIdle(maximumYields: 10_000)

        XCTAssertTrue(becameIdle)
        XCTAssertFalse(coordinator.isRefreshInFlight)
    }

    func testSlowMemoryReadDoesNotBlockLiveCPUAndNetworkAndRemainsSingleFlight() async {
        let snapshot = makeMemorySnapshot(generatedAt: Date(), topProcesses: [])
        let probe = SuspendedMenuMemoryProbe(snapshot: snapshot)
        let store = ScanStore(menuBarMemoryStatusProvider: { await probe.sample() })
        store.refreshMenuBarLiveStatus()
        await waitForLiveSnapshot(store)
        XCTAssertNotNil(store.menuBarMonitorState.snapshot)
        XCTAssertNil(store.menuBarDisplayMemorySnapshot)
        let firstDate = store.menuBarMonitorState.snapshot?.generatedAt
        store.refreshMenuBarLiveStatus()
        await waitForLiveSnapshot(store, newerThan: firstDate)
        XCTAssertNotEqual(store.menuBarMonitorState.snapshot?.generatedAt, firstDate)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 1, "A slow memory query must not accumulate more queries")
        await probe.release()
        for _ in 0..<200 where store.menuBarDisplayMemorySnapshot == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.menuBarDisplayMemorySnapshot?.generatedAt, snapshot.generatedAt)
        XCTAssertNil(store.memorySnapshot, "Status reads must preserve the separate process snapshot")
    }

    func testPauseDiscardsAnOutstandingMemoryStatusRead() async {
        let probe = SuspendedMenuMemoryProbe(snapshot: makeMemorySnapshot(generatedAt: Date(), topProcesses: []))
        let store = ScanStore(menuBarMemoryStatusProvider: { await probe.sample() })
        store.refreshMenuBarLiveStatus()
        await waitForLiveSnapshot(store)
        store.toggleMenuBarRefreshPaused()
        await probe.release()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.menuBarDisplayMemorySnapshot)
        store.toggleMenuBarRefreshPaused()
        for _ in 0..<200 where store.menuBarDisplayMemorySnapshot == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.menuBarDisplayMemorySnapshot)
    }

    func testLiveMemoryProcessesCoalesceRefreshAndPreserveASelectionMadeDuringRead() async {
        let snapshot = makeMemorySnapshot(generatedAt: Date(), topProcesses: [])
        let probe = SuspendedMenuMemoryProbe(snapshot: snapshot)
        let store = ScanStore(menuBarMemoryProcessProvider: { await probe.sample() })
        let consumer = attachProcessConsumer(to: store)
        defer { store.menuBarAuxiliaryMonitorState.unregisterConsumer(consumer) }
        store.refreshMenuBarMemoryProcesses()
        store.refreshMenuBarMemoryProcesses()
        for _ in 0..<200 {
            if await probe.callCount > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let calls = await probe.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(store.isLoadingMemory, "Background reads must not disable process actions")
        store.selectedMemoryProcessIDs = [987]
        await probe.release()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.selectedMemoryProcessIDs, [987])
        XCTAssertNil(store.memorySnapshot, "A late result must not replace the list the user is selecting")
        store.selectedMemoryProcessIDs = []
        store.refreshMenuBarMemoryProcesses()
        for _ in 0..<200 where store.memorySnapshot == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.memorySnapshot)
        store.refreshMenuBarMemoryProcesses(now: snapshot.generatedAt.addingTimeInterval(4.9))
        let finalCalls = await probe.callCount
        XCTAssertEqual(finalCalls, 2, "A current process reading must be reused for five seconds")
    }

    func testClosingMemoryPageDiscardsPendingProcessRead() async {
        let probe = SuspendedMenuMemoryProbe(snapshot: makeMemorySnapshot(generatedAt: Date(), topProcesses: []))
        let store = ScanStore(menuBarMemoryProcessProvider: { await probe.sample() })
        let consumer = attachProcessConsumer(to: store)
        defer { store.menuBarAuxiliaryMonitorState.unregisterConsumer(consumer) }
        store.refreshMenuBarMemoryProcesses()
        store.cancelMenuBarMemoryProcessRefresh()
        await probe.release()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.memorySnapshot)
    }

    private func attachProcessConsumer(to store: ScanStore) -> UUID {
        let consumer = UUID()
        store.menuBarAuxiliaryMonitorState.registerConsumer(consumer, demand: .init(
            needsProcessorTelemetry: false, needsDiskIOSampling: false,
            needsNetworkInterface: false, needsPublicNetworkAddress: false,
            needsNetworkProcesses: false
        ), paused: false)
        return consumer
    }

    private func waitForLiveSnapshot(_ store: ScanStore, newerThan previous: Date? = nil) async {
        for _ in 0..<200 {
            if let current = store.menuBarMonitorState.snapshot?.generatedAt, current != previous { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Live CPU/network readings waited for the blocked memory query")
    }

    func testMenuMemoryCadenceToleratesPublishJitterWithoutRepeatedEarlyReads() {
        let now = Date(timeIntervalSince1970: 1_000)
        for interval in [1.0, 2.0, 5.0] {
            for elapsed in [0.1, interval - 0.2, interval - 0.02, interval] {
                XCTAssertEqual(MenuBarMemoryRefreshThrottle.shouldRefresh(now: now, force: false,
                    primarySnapshotAvailable: false, menuStatusSnapshotAvailable: true,
                    refreshedAt: now.addingTimeInterval(-elapsed), interval: interval),
                    elapsed >= interval - 0.05)
            }
        }
    }

    func testMenuMemoryThrottleReusesFreshMenuStatusWhenPrimarySnapshotIsEmpty() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(MenuBarMemoryRefreshThrottle.shouldRefresh(
            now: now,
            force: false,
            primarySnapshotAvailable: false,
            menuStatusSnapshotAvailable: true,
            refreshedAt: now.addingTimeInterval(-1),
            interval: 10
        ))
        XCTAssertTrue(MenuBarMemoryRefreshThrottle.shouldRefresh(
            now: now,
            force: false,
            primarySnapshotAvailable: false,
            menuStatusSnapshotAvailable: false,
            refreshedAt: now,
            interval: 10
        ))
        XCTAssertTrue(MenuBarMemoryRefreshThrottle.shouldRefresh(
            now: now,
            force: true,
            primarySnapshotAvailable: true,
            menuStatusSnapshotAvailable: true,
            refreshedAt: now,
            interval: 10
        ))
    }

    func testMenuMemoryAdoptionKeepsAutomaticStatusSnapshotOutOfPrimaryMemory() {
        XCTAssertEqual(
            MenuBarMemorySnapshotAdoption.resolve(
                policy: .automatic,
                shouldRefreshMemorySnapshot: true,
                sampledSnapshotAvailable: true,
                primarySnapshotMissing: true,
                monitorCreatedSnapshot: false
            ),
            .menuStatusOnly
        )
        XCTAssertEqual(
            MenuBarMemorySnapshotAdoption.resolve(
                policy: .automatic,
                shouldRefreshMemorySnapshot: false,
                sampledSnapshotAvailable: true,
                primarySnapshotMissing: true,
                monitorCreatedSnapshot: false
            ),
            .none
        )
        XCTAssertEqual(
            MenuBarMemorySnapshotAdoption.resolve(
                policy: .lightweight,
                shouldRefreshMemorySnapshot: false,
                sampledSnapshotAvailable: false,
                primarySnapshotMissing: true,
                monitorCreatedSnapshot: true
            ),
            .primaryAndMenuFromMonitor
        )
        XCTAssertEqual(
            MenuBarMemorySnapshotAdoption.resolve(
                policy: .fullMemory,
                shouldRefreshMemorySnapshot: true,
                sampledSnapshotAvailable: true,
                primarySnapshotMissing: true,
                monitorCreatedSnapshot: false
            ),
            .primaryAndMenuFromRefresh
        )
        XCTAssertEqual(
            MenuBarMemorySnapshotAdoption.resolve(
                policy: .fullMemory,
                shouldRefreshMemorySnapshot: true,
                sampledSnapshotAvailable: false,
                primarySnapshotMissing: true,
                monitorCreatedSnapshot: true
            ),
            .primaryAndMenuFromMonitor
        )
    }

    func testMenuDisplayMemorySelectionPrefersStatusWithoutReplacingPrimaryProcesses() throws {
        let primaryProcess = MemoryProcess(
            id: 4_201,
            name: "Primary App",
            path: "/Applications/Primary.app/Contents/MacOS/Primary",
            iconPath: "/Applications/Primary.app",
            bundlePath: "/Applications/Primary.app",
            residentBytes: 512,
            percent: 6.4,
            canQuit: true
        )
        let primary = makeMemorySnapshot(
            generatedAt: Date(timeIntervalSince1970: 100),
            pressureFreePercentage: 45,
            topProcesses: [primaryProcess]
        )
        let menuStatus = makeMemorySnapshot(
            generatedAt: Date(timeIntervalSince1970: 200),
            pressureFreePercentage: 73,
            topProcesses: []
        )

        let display = try XCTUnwrap(MenuBarDisplayMemorySnapshotSelection.resolve(
            menuStatusSnapshot: menuStatus,
            primarySnapshot: primary
        ))

        XCTAssertEqual(display.generatedAt, menuStatus.generatedAt)
        XCTAssertEqual(display.pressureFreePercentage, 73)
        XCTAssertEqual(display.pressureFreePercentage.map { 100 - $0 }, 27)
        XCTAssertTrue(display.topProcesses.isEmpty)
        XCTAssertEqual(primary.pressureFreePercentage, 45)
        XCTAssertEqual(primary.topProcesses.map(\.id), [primaryProcess.id])
    }

    func testMenuDisplayMemorySnapshotFallsBackToPrimary() throws {
        let store = ScanStore()
        let primary = makeMemorySnapshot(
            generatedAt: Date(timeIntervalSince1970: 300),
            topProcesses: []
        )
        store.memorySnapshot = primary

        XCTAssertEqual(
            try XCTUnwrap(store.menuBarDisplayMemorySnapshot).generatedAt,
            primary.generatedAt
        )
    }

    func testMenuDisplayMemorySelectionUsesMonotonicCaptureOrder() throws {
        let olderInstant = ContinuousClock().now
        let newerInstant = olderInstant.advanced(by: .milliseconds(1))
        let olderMenuStatus = makeMemorySnapshot(
            generatedAt: Date(timeIntervalSince1970: 200),
            capturedInstant: olderInstant,
            pressureFreePercentage: 45,
            topProcesses: []
        )
        let newerPrimary = makeMemorySnapshot(
            generatedAt: Date(timeIntervalSince1970: 100),
            capturedInstant: newerInstant,
            pressureFreePercentage: 73,
            topProcesses: []
        )

        let display = try XCTUnwrap(MenuBarDisplayMemorySnapshotSelection.resolve(
            menuStatusSnapshot: olderMenuStatus,
            primarySnapshot: newerPrimary
        ))

        XCTAssertEqual(display.pressureFreePercentage, 73)
        XCTAssertFalse(MenuBarDisplayMemorySnapshotSelection.shouldReplace(
            current: newerPrimary,
            with: olderMenuStatus
        ))
        XCTAssertTrue(MenuBarDisplayMemorySnapshotSelection.shouldReplace(
            current: olderMenuStatus,
            with: newerPrimary
        ))
    }

    func testEveryFullMemoryResultUpdatesTheMenuDisplayThroughSharedAdoption() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Stores/ScanStore.swift")

        XCTAssertEqual(source.components(separatedBy: "memorySnapshot = snapshot").count - 1, 1)
        XCTAssertEqual(
            source.components(separatedBy: "as: .primaryAndMenuFromRefresh").count - 1,
            4
        )
        XCTAssertTrue(source.contains("let currentMemorySnapshot = menuBarDisplayMemorySnapshot"))
        XCTAssertTrue(source.contains("current: memorySnapshot"))
        XCTAssertTrue(source.contains("current: menuBarMemoryStatusSnapshot"))
    }

    func testManualMenuRefreshAlsoRefreshesExistingEnergyProcessCache() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Stores/ScanStore.swift")
        let refreshBody = try XCTUnwrap(
            source.components(separatedBy: "    func refreshMenuBarNow() {").dropFirst().first?
                .components(separatedBy: "    func refreshMenuBarMonitor()").first
        )

        XCTAssertTrue(refreshBody.contains("if energyImpactSnapshot != nil"))
        XCTAssertTrue(refreshBody.contains("refreshEnergyImpact()"))
    }

    func testAdvancedMenuDetailPageKeepsStableScrollIdentity() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")
        let componentsSource = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift"
        )
        let headerSource = try XCTUnwrap(
            componentsSource.components(separatedBy: "    var header: some View {").dropFirst().first?
                .components(separatedBy: "    var moduleRail: some View {").first
        )
        let moduleRailSource = try XCTUnwrap(
            componentsSource.components(separatedBy: "    var moduleRail: some View {").dropFirst().first?
                .components(separatedBy: "    func railSelectionDistance").first
        )
        let detailPageSource = try XCTUnwrap(
            source.components(separatedBy: "    var detailPage: some View {").dropFirst().first?
                .components(separatedBy: "    func refreshProcessorTelemetry").first
        )

        XCTAssertFalse(headerSource.contains(".contentTransition("))
        XCTAssertFalse(headerSource.contains(".animation("))
        XCTAssertEqual(moduleRailSource.components(separatedBy: "selectedSection = section").count - 1, 1)
        XCTAssertTrue(moduleRailSource.contains("withAnimation("))
        XCTAssertEqual(detailPageSource.components(separatedBy: "ScrollView(.vertical)").count - 1, 1)
        XCTAssertFalse(detailPageSource.contains(".id(selectedSection)"))
        XCTAssertFalse(detailPageSource.contains(".transition("))
        XCTAssertFalse(detailPageSource.contains(".animation("))
    }

    func testHistoryBootstrapDoesNotReadDuringStoreInitialization() async {
        let loader = RecordingHistoryLoader(result: makeHistorySnapshot())
        let store = ScanStore(historyLoader: loader)

        let initialLoadCount = await loader.loadCount()
        XCTAssertEqual(initialLoadCount, 0)
        XCTAssertTrue(store.scanHistorySummary.entries.isEmpty)
        XCTAssertTrue(store.cleanupHistorySummary.entries.isEmpty)

        await store.loadPersistedHistoryIfNeeded()

        let finalLoadCount = await loader.loadCount()
        XCTAssertEqual(finalLoadCount, 1)
        XCTAssertEqual(store.scanHistorySummary.entries.count, 1)
        XCTAssertEqual(store.cleanupHistorySummary.entries.count, 1)
    }

    func testHistoryBootstrapCoalescesConcurrentAndRepeatedCalls() async {
        let expected = makeHistorySnapshot()
        let loader = RecordingHistoryLoader(result: expected, startsSuspended: true)
        let store = ScanStore(historyLoader: loader)
        var scanPublications = 0
        var cleanupPublications = 0
        let scanSubscription = store.$scanHistorySummary
            .dropFirst()
            .sink { _ in scanPublications += 1 }
        let cleanupSubscription = store.$cleanupHistorySummary
            .dropFirst()
            .sink { _ in cleanupPublications += 1 }

        let first = Task { await store.loadPersistedHistoryIfNeeded() }
        await loader.waitUntilLoadStarts()
        let second = Task { await store.loadPersistedHistoryIfNeeded() }
        await Task.yield()
        await loader.resume()
        await first.value
        await second.value
        await store.loadPersistedHistoryIfNeeded()

        let loadCount = await loader.loadCount()
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(scanPublications, 1)
        XCTAssertEqual(cleanupPublications, 1)
        XCTAssertEqual(store.scanHistorySummary, expected.scanHistory)
        XCTAssertEqual(store.cleanupHistorySummary, expected.cleanupHistory)
        withExtendedLifetime((scanSubscription, cleanupSubscription)) {}
    }

    func testHistoryBootstrapRejectsStaleResultAfterScanHistoryMutation() async {
        let stale = makeHistorySnapshot(scanDate: 100, cleanupDate: 100)
        let current = makeHistorySnapshot(scanDate: 900, cleanupDate: 900)
        let loader = RecordingHistoryLoader(result: stale, startsSuspended: true)
        let store = ScanStore(historyLoader: loader)

        let bootstrap = Task { await store.loadPersistedHistoryIfNeeded() }
        await loader.waitUntilLoadStarts()
        store.scanHistorySummary = current.scanHistory
        await loader.resume()
        await bootstrap.value

        let loadCount = await loader.loadCount()
        XCTAssertEqual(store.scanHistorySummary, current.scanHistory)
        XCTAssertEqual(store.cleanupHistorySummary, stale.cleanupHistory)
        XCTAssertEqual(loadCount, 1)
    }

    func testHistoryBootstrapRejectsStaleResultAfterCleanupHistoryMutation() async {
        let stale = makeHistorySnapshot(scanDate: 100, cleanupDate: 100)
        let current = makeHistorySnapshot(scanDate: 900, cleanupDate: 900)
        let loader = RecordingHistoryLoader(result: stale, startsSuspended: true)
        let store = ScanStore(historyLoader: loader)

        let bootstrap = Task { await store.loadPersistedHistoryIfNeeded() }
        await loader.waitUntilLoadStarts()
        store.cleanupHistorySummary = current.cleanupHistory
        await loader.resume()
        await bootstrap.value

        let loadCount = await loader.loadCount()
        XCTAssertEqual(store.scanHistorySummary, stale.scanHistory)
        XCTAssertEqual(store.cleanupHistorySummary, current.cleanupHistory)
        XCTAssertEqual(loadCount, 1)
    }

    func testScanHistoryLoadReturnsNewestBoundedEntries() throws {
        let (defaults, suiteName) = makeTemporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let dates = (0..<65).map { ($0 * 17) % 65 }
        let entries = dates.map { makeScanEntry(date: TimeInterval($0)) }
        defaults.set(try JSONEncoder().encode(entries), forKey: ScanHistoryService.defaultsKey)

        let loaded = ScanHistoryService.load(defaults: defaults)

        XCTAssertEqual(loaded.count, 60)
        XCTAssertEqual(loaded.map(\.date), (5..<65).reversed().map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    func testCleanupHistoryLoadReturnsNewestBoundedEntries() throws {
        let (defaults, suiteName) = makeTemporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let dates = (0..<85).map { ($0 * 19) % 85 }
        let entries = dates.map { value in
            CleanupHistoryEntry(
                date: Date(timeIntervalSince1970: TimeInterval(value)),
                title: "Cleanup \(value)",
                itemCount: 1,
                totalBytes: Int64(value),
                paths: ["/tmp/\(value)"]
            )
        }
        defaults.set(try JSONEncoder().encode(entries), forKey: CleanupHistoryService.defaultsKey)

        let loaded = CleanupHistoryService.load(defaults: defaults)

        XCTAssertEqual(loaded.count, 80)
        XCTAssertEqual(loaded.map(\.date), (5..<85).reversed().map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    func testHistoryBootstrapRunsOnlyFromRootContentViewAfterYield() throws {
        let contentSource = try sourceText(at: "Sources/StorageCleanerMac/Views/ContentView.swift")
        let rootContentView = try XCTUnwrap(
            contentSource.components(separatedBy: "    private func selectFilter").first
        )
        XCTAssertTrue(rootContentView.contains(".task {"))
        XCTAssertTrue(rootContentView.contains("await Task.yield()"))
        XCTAssertTrue(rootContentView.contains("await store.loadPersistedHistoryIfNeeded()"))
        XCTAssertLessThan(
            try XCTUnwrap(rootContentView.range(of: "await Task.yield()")?.lowerBound),
            try XCTUnwrap(rootContentView.range(of: "await store.loadPersistedHistoryIfNeeded()")?.lowerBound)
        )

        for path in [
            "Sources/StorageCleanerMac/Views/MenuBarStatusView.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift",
            "Sources/StorageCleanerMac/Support/MenuBarStatusController.swift"
        ] {
            XCTAssertFalse(try sourceText(at: path).contains("loadPersistedHistoryIfNeeded"), path)
        }
    }

    func testDefaultHistoryLoaderUsesDetachedWorkWithoutUnsafeIsolation() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Stores/ScanStore.swift")
        let loaderSource = try XCTUnwrap(
            source.components(separatedBy: "struct UserDefaultsScanStoreHistoryLoader").dropFirst().first?
                .components(separatedBy: "@MainActor\nfinal class ScanStore").first
        )

        XCTAssertTrue(loaderSource.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(loaderSource.contains("ScanHistoryService.summary()"))
        XCTAssertTrue(loaderSource.contains("CleanupHistoryService.summary()"))
        XCTAssertFalse(loaderSource.contains("@unchecked"))
        XCTAssertFalse(loaderSource.contains("nonisolated(unsafe)"))
    }

    private func makeHistorySnapshot(
        scanDate: TimeInterval = 200,
        cleanupDate: TimeInterval = 100
    ) -> ScanStoreHistorySnapshot {
        ScanStoreHistorySnapshot(
            scanHistory: ScanHistorySummary(entries: [
                makeScanEntry(date: scanDate)
            ]),
            cleanupHistory: CleanupHistorySummary(entries: [
                CleanupHistoryEntry(
                    date: Date(timeIntervalSince1970: cleanupDate),
                    title: "Test cleanup",
                    itemCount: 1,
                    totalBytes: 10,
                    paths: ["/tmp/test"]
                )
            ])
        )
    }

    private func makeMemorySnapshot(
        generatedAt: Date,
        capturedInstant: ContinuousClock.Instant? = nil,
        pressureFreePercentage: Int = 80,
        topProcesses: [MemoryProcess]
    ) -> MemorySnapshot {
        MemorySnapshot(
            generatedAt: generatedAt,
            capturedInstant: capturedInstant,
            physicalBytes: 8_000,
            freeBytes: 1_000,
            inactiveBytes: 0,
            speculativeBytes: 0,
            fileBackedBytes: 1_000,
            purgeableBytes: 0,
            wiredBytes: 1_000,
            compressedBytes: 500,
            swapUsedBytes: 0,
            pressureFreePercentage: pressureFreePercentage,
            pressureSummary: "Pressure headroom \(pressureFreePercentage)%",
            topProcesses: topProcesses
        )
    }

    private func makeScanEntry(date: TimeInterval) -> ScanHistoryEntry {
        ScanHistoryEntry(
            date: Date(timeIntervalSince1970: date),
            scanSeconds: 1,
            score: 90,
            diskUsedBytes: 100,
            diskFreeBytes: 200,
            greenBytes: 10,
            yellowBytes: 20,
            redBytes: 30,
            itemCount: 3,
            greenCount: 1,
            yellowCount: 1,
            redCount: 1,
            deniedCount: 0
        )
    }

    private func makeTemporaryDefaults() -> (UserDefaults, String) {
        let suiteName = "ScanStorePerformanceTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func sourceText(at relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

private actor RecordingHistoryLoader: ScanStoreHistoryLoading {
    private let result: ScanStoreHistorySnapshot
    private let startsSuspended: Bool
    private var loads = 0
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(result: ScanStoreHistorySnapshot, startsSuspended: Bool = false) {
        self.result = result
        self.startsSuspended = startsSuspended
    }

    func load() async -> ScanStoreHistorySnapshot {
        loads += 1
        if startsSuspended, !isReleased {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        return result
    }

    func loadCount() -> Int {
        loads
    }

    func waitUntilLoadStarts() async {
        while loads == 0 {
            await Task.yield()
        }
    }

    func resume() {
        isReleased = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}

private actor RecordingMenuSnapshotProbe {
    private let suspendFirstCall: Bool
    private var recordedRequests: [MenuBarRefreshRequest] = []
    private var activeCalls = 0
    private var peakConcurrentCalls = 0
    private var firstCallContinuation: CheckedContinuation<Void, Never>?

    init(suspendFirstCall: Bool = false) {
        self.suspendFirstCall = suspendFirstCall
    }

    func sample(_ request: MenuBarRefreshRequest) async {
        activeCalls += 1
        peakConcurrentCalls = max(peakConcurrentCalls, activeCalls)
        recordedRequests.append(request)

        if suspendFirstCall, recordedRequests.count == 1 {
            await withCheckedContinuation { continuation in
                firstCallContinuation = continuation
            }
        }

        activeCalls -= 1
    }

    func waitUntilCallCount(_ count: Int, maximumYields: Int) async -> Bool {
        for _ in 0..<maximumYields {
            if recordedRequests.count >= count { return true }
            await Task.yield()
        }
        return recordedRequests.count >= count
    }

    func releaseFirstCall() {
        firstCallContinuation?.resume()
        firstCallContinuation = nil
    }

    func requests() -> [MenuBarRefreshRequest] {
        recordedRequests
    }

    func maximumConcurrentCalls() -> Int {
        peakConcurrentCalls
    }
}

private actor CancellationAwareMenuSnapshotProbe {
    private var started = false

    func waitForCancellation() async {
        started = true
        do {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        } catch {
            return
        }
    }

    func waitUntilStarted(maximumYields: Int) async -> Bool {
        for _ in 0..<maximumYields {
            if started { return true }
            await Task.yield()
        }
        return started
    }
}

private actor SuspendedMenuMemoryProbe {
    let snapshot: MemorySnapshot
    private(set) var callCount = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(snapshot: MemorySnapshot) { self.snapshot = snapshot }

    func sample() async -> MemorySnapshot {
        callCount += 1
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        return snapshot
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
