# Mac Benchmark and Heavy-Work Coordination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safe, cancellable CPU/GPU/memory/disk benchmark with real raw metrics and calibrated scores while preventing scans, cleanup, network tests, memory optimization, updates, and benchmark work from overlapping or freezing the app.

**Architecture:** A fail-fast actor issues non-reentrant tokens to one heavy operation at a time. Benchmark kernels are isolated behind protocols and coordinated by an off-MainActor service; the MainActor Store only publishes throttled state. Baselines are generated from validated reference sessions, frozen with a report hash, and keyed by workload/profile/architecture/capability set.

**Tech Stack:** Swift 6 concurrency, Foundation/Darwin, Metal compute, AppKit power/thermal APIs, SwiftUI, XCTest, SwiftPM release builds.

---

### Task 1: Implement the fail-fast heavy-work lease

**Files:**
- Create: `Sources/StorageCleanerMac/Services/HeavyWorkCoordinator.swift`
- Create: `Tests/StorageCleanerMacTests/HeavyWorkCoordinatorTests.swift`

- [ ] **Step 1: Write actor semantics tests**

```swift
func testLeaseIsFailFastNonReentrantAndTokenChecked() async throws {
    let coordinator = HeavyWorkCoordinator()
    let first = try await coordinator.acquire(owner: .benchmark)
    await XCTAssertThrowsErrorAsync(try await coordinator.acquire(owner: .benchmark))
    await coordinator.release(.init(id: UUID(), owner: .benchmark))
    XCTAssertEqual(await coordinator.activeOwner, .benchmark)
    await coordinator.release(first)
    await coordinator.release(first)
    XCTAssertNil(await coordinator.activeOwner)
}

func testWithLeaseReleasesAfterCancellation() async {
    let coordinator = HeavyWorkCoordinator()
    let task = Task {
        try await coordinator.withLease(owner: .networkTest) {
            try await Task.sleep(for: .seconds(20))
        }
    }
    task.cancel()
    _ = await task.result
    XCTAssertNil(await coordinator.activeOwner)
}
```

- [ ] **Step 2: Run and verify compilation failure**

Run: `./script/test.sh --filter HeavyWorkCoordinatorTests`

Expected: `HeavyWorkCoordinator` is missing.

- [ ] **Step 3: Implement exact token ownership**

```swift
actor HeavyWorkCoordinator {
    enum Owner: String, Codable, Sendable {
        case mainScan, duplicateScan, cleanup, restore, emptyTrash
        case memoryOptimization, appUpdates, networkTest, benchmark
    }
    struct Lease: Hashable, Sendable { let id: UUID; let owner: Owner }
    enum LeaseError: Error, Equatable {
        case busy(activeOwner: Owner)
        case invalidLease(expectedOwner: Owner)
    }

    private var active: Lease?
    var activeOwner: Owner? { active?.owner }

    func acquire(owner: Owner) throws -> Lease {
        guard active == nil else { throw LeaseError.busy(activeOwner: active!.owner) }
        let lease = Lease(id: UUID(), owner: owner)
        active = lease
        return lease
    }

    func release(_ lease: Lease) {
        guard active == lease else { return }
        active = nil
    }

    func requireValid(_ lease: Lease, owner: Owner) throws {
        guard active == lease, lease.owner == owner else {
            throw LeaseError.invalidLease(expectedOwner: owner)
        }
    }

    func withLease<T: Sendable>(
        owner: Owner,
        operation: @Sendable (Lease) async throws -> T
    ) async throws -> T {
        let lease = try acquire(owner: owner)
        defer { release(lease) }
        return try await operation(lease)
    }
}
```

- [ ] **Step 4: Run coordinator tests**

Run: `./script/test.sh --filter HeavyWorkCoordinatorTests`

Expected: fail-fast, non-reentrant, correct/wrong/repeated release, error, timeout, and cancellation paths pass.

- [ ] **Step 5: Commit coordinator**

```bash
git add Sources/StorageCleanerMac/Services/HeavyWorkCoordinator.swift Tests/StorageCleanerMacTests/HeavyWorkCoordinatorTests.swift
git commit -m "feat(core): coordinate heavy operations"
```

### Task 2: Integrate existing ScanStore heavy operations

**Files:**
- Modify: `Sources/StorageCleanerMac/Stores/ScanStore.swift`
- Modify: `Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift:78-130`
- Create: `Sources/StorageCleanerMac/Services/ScanHeavyWorkService.swift`
- Create: `Sources/StorageCleanerMac/Stores/HeavyWorkActivityStore.swift`
- Modify: `Tests/StorageCleanerMacTests/SystemUtilitySafetyTests.swift`
- Create: `Tests/StorageCleanerMacTests/HeavyWorkIntegrationTests.swift`

- [ ] **Step 1: Add failing mutual-exclusion tests**

Inject one coordinator into the root Store and test these independent lease ranges: `startScan`, `scanDuplicateFiles`, `confirmTrash`, `confirmTrashAllGreen`, `confirmEmptyTrash`, `confirmRestoreLatestCleanup`, `optimizeMemory`, and `confirmOneClickAppUpdates`. Assert scanning releases before the user browses results; confirmation-only waiting holds no lease; cleanup reacquires a new `.cleanup` lease.

- [ ] **Step 2: Run the focused safety tests**

Run: `./script/test.sh --filter SystemUtilitySafetyTests/testHeavyWork`

Expected: tests fail because existing Store booleans do not coordinate with network/benchmark owners.

- [ ] **Step 3: Inject the shared actor and wrap operations**

Add `let heavyWorkCoordinator: HeavyWorkCoordinator` to the root app, pass it to `ScanStore`, `NetworkSpeedTestStore`, and later `MacBenchmarkStore`. A `HeavyWorkActivityStore` consumes coordinator snapshots and exposes the current owner, one localized conflict message, and navigation destination without owning or releasing leases. Each listed asynchronous operation calls `withLease` around only its real work and resource cleanup. Main scan obtains its lease after permission/readiness preflight and before `DiskScanner.scan`; requests, result browsing, selection editing, alerts, and confirmation sheets do not hold a lease. Map `LeaseError.busy(activeOwner:)` to one localized action message; do not queue or retry automatically.

- [ ] **Step 4: Require service-level tokens for destructive work**

Add `ScanHeavyWorkService` and a `lease: HeavyWorkCoordinator.Lease` parameter at destructive service entry boundaries used by cleanup/restore/trash/update operations; call `requireValid` before file or process mutation. Move `CleanupService.moveToTrash`, batch trash, empty-trash and restore loops out of the MainActor into this cancellable service and publish results back only after generation checks. Keep UI disabled state as secondary feedback rather than the safety boundary.

- [ ] **Step 5: Make app-update ownership truthful**

Run Homebrew updates through the app's bounded cancellable process runner and await verified process-tree exit before releasing `.appUpdates`; do not launch an unobservable Terminal script and immediately report completion. App Store/System Settings handoff is not an in-app update: release after the open request succeeds and report “已打开系统更新，等待用户操作”, never “更新完成”.

- [ ] **Step 6: Run system utility and ScanStore tests**

Run: `./script/test.sh --filter 'HeavyWorkIntegrationTests|SystemUtilitySafetyTests'`

Expected: existing per-feature safety tests plus cross-owner conflict/release tests pass.

- [ ] **Step 7: Commit existing-operation integration**

```bash
git add Sources/StorageCleanerMac/Stores/ScanStore.swift Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift Sources/StorageCleanerMac/Services/ScanHeavyWorkService.swift Sources/StorageCleanerMac/Stores/HeavyWorkActivityStore.swift Tests/StorageCleanerMacTests/HeavyWorkIntegrationTests.swift Tests/StorageCleanerMacTests/SystemUtilitySafetyTests.swift
git commit -m "fix(core): prevent overlapping heavy operations"
```

### Task 3: Define benchmark models and comparison keys

**Files:**
- Create: `Sources/StorageCleanerMac/Models/MacBenchmarkModels.swift`
- Create: `Tests/StorageCleanerMacTests/MacBenchmarkModelsTests.swift`

- [ ] **Step 1: Write comparability and incomplete-score tests**

```swift
func testComparisonKeySeparatesProfileArchitectureAndCapabilities() {
    let arm = BenchmarkComparisonKey(workloadVersion: "1", baselineVersion: "1", profile: .quick, architecture: .arm64, capabilitySet: .all)
    let intel = BenchmarkComparisonKey(workloadVersion: "1", baselineVersion: "1", profile: .quick, architecture: .x86_64, capabilitySet: .all)
    XCTAssertNotEqual(arm, intel)
}

func testIncompleteResultCannotExposeOverallScore() {
    XCTAssertNil(MacBenchmarkResult.incomplete(completed: [.cpuSingle: 100]).overallScore)
}
```

- [ ] **Step 2: Run and verify model absence**

Run: `./script/test.sh --filter MacBenchmarkModelsTests`

Expected: compilation fails.

- [ ] **Step 3: Define Codable/Sendable models**

Add profile (`quick`, `full`), stage, component, architecture, capability set, power/thermal preflight, environment metadata, component sample/CV, raw result, comparison key, baseline, scored result, state, and failure types. Do not include username, serial number, hardware UUID, UDID, path, or IP fields. `overallScore` is optional and cannot be initialized unless all key capabilities and a matching frozen baseline are present.

- [ ] **Step 4: Run model tests**

Run: `./script/test.sh --filter MacBenchmarkModelsTests`

Expected: Codable, equality, privacy field policy, architecture, capability and incomplete-result tests pass.

- [ ] **Step 5: Commit models**

```bash
git add Sources/StorageCleanerMac/Models/MacBenchmarkModels.swift Tests/StorageCleanerMacTests/MacBenchmarkModelsTests.swift
git commit -m "feat(benchmark): define safe result models"
```

### Task 4: Build deterministic CPU and memory kernels

**Files:**
- Create: `Sources/StorageCleanerMac/Services/Benchmark/CPUBenchmarkKernel.swift`
- Create: `Sources/StorageCleanerMac/Services/Benchmark/MemoryBenchmarkKernel.swift`
- Create: `Tests/StorageCleanerMacTests/MacBenchmarkKernelTests.swift`

- [ ] **Step 1: Write checksum, cancellation, and work-limit tests**

Test fixed-seed checksum repeatability, single-core execution width one, multi-core width `max(1, activeProcessorCount - 1)`, cancellation at chunk boundaries, quick memory set at most 64 MiB, full at most 128 MiB, finite positive throughput, and every timed kernel records `Thread.isMainThread == false`.

- [ ] **Step 2: Run and verify missing kernels**

Run: `./script/test.sh --filter MacBenchmarkKernelTests`

Expected: compilation fails.

- [ ] **Step 3: Implement CPU kernels**

Use a deterministic xorshift seed and fixed integer/floating mix. Generate input before timing, retain a checksum after timing, report operations divided by monotonic elapsed seconds, and check cancellation between bounded chunks. Multi-core uses a task group with one partition per allowed worker and combines checksums in stable partition order.

- [ ] **Step 4: Implement memory kernels**

Allocate fixed `UnsafeMutableRawBufferPointer` buffers off the MainActor, run warm-up, then timed copy and scan/checksum passes. Release buffers with `defer`; report effective decimal GB/s and reject zero/non-finite duration or checksum mismatch.

- [ ] **Step 5: Run kernel tests**

Run: `./script/test.sh --filter MacBenchmarkKernelTests`

Expected: deterministic results, size limits, cancellation, worker reservation, finite metrics, and release counters pass.

- [ ] **Step 6: Commit CPU/memory kernels**

```bash
git add Sources/StorageCleanerMac/Services/Benchmark/CPUBenchmarkKernel.swift Sources/StorageCleanerMac/Services/Benchmark/MemoryBenchmarkKernel.swift Tests/StorageCleanerMacTests/MacBenchmarkKernelTests.swift
git commit -m "feat(benchmark): add CPU and memory workloads"
```

### Task 5: Build Metal and private temporary-file kernels

**Files:**
- Create: `Sources/StorageCleanerMac/Services/Benchmark/MetalBenchmarkKernel.swift`
- Create: `Sources/StorageCleanerMac/Services/Benchmark/DiskBenchmarkKernel.swift`
- Create: `Tests/StorageCleanerMacTests/MacBenchmarkIOTests.swift`

- [ ] **Step 1: Write fake Metal and disk cleanup tests**

Test that compilation/warm-up are outside the timer, command-buffer failure produces no GPU metric, checksum mismatch fails, quick disk file is 128 MiB, full is 256 MiB, space requires file size ×2 plus 2 GiB, `fsync` occurs before read, every success/failure/timeout/cancel removes the private file, and startup orphan cleanup only touches the app's benchmark directory.

- [ ] **Step 2: Run and verify missing I/O kernels**

Run: `./script/test.sh --filter MacBenchmarkIOTests`

Expected: compilation fails.

- [ ] **Step 3: Implement Metal compute**

Create a public Metal compute pipeline from a fixed source string, allocate bounded buffers, warm up once, time only command encoding through completion, validate status and checksum, and release buffers/pipeline at operation end. Report a documented operation throughput, not FPS or current utilization.

- [ ] **Step 4: Implement disk sequencing and cleanup**

Use only `Application Support/BenchmarkTemporary`, create with exclusive access, write deterministic blocks sequentially, call `fsync`, read sequentially, verify SHA-256/checksum, and delete with `defer`. Never access a raw device or issue random writes. Provide `cleanupOrphans(olderThan:)` scoped to the fixed directory for app startup.

- [ ] **Step 5: Run I/O tests**

Run: `./script/test.sh --filter MacBenchmarkIOTests`

Expected: Metal failure/cancellation and every disk cleanup/size/space/order test pass.

- [ ] **Step 6: Commit GPU/disk kernels**

```bash
git add Sources/StorageCleanerMac/Services/Benchmark/MetalBenchmarkKernel.swift Sources/StorageCleanerMac/Services/Benchmark/DiskBenchmarkKernel.swift Tests/StorageCleanerMacTests/MacBenchmarkIOTests.swift
git commit -m "feat(benchmark): add Metal and disk workloads"
```

### Task 6: Orchestrate profiles, preflight, timeouts, and cancellation

**Files:**
- Create: `Sources/StorageCleanerMac/Services/MacBenchmarkService.swift`
- Create: `Tests/StorageCleanerMacTests/MacBenchmarkServiceTests.swift`

- [ ] **Step 1: Write injected-runner sequence tests**

Test quick stage order and one sample, full stage order and three samples/median/CV, per-stage timeout, progress capped at 5 Hz, nominal/fair/serious thermal handling, power requirements, low-power warnings, SMART failure disk gate, space gate, cancellation, and release of large resources and lease.

- [ ] **Step 2: Run and verify missing orchestrator**

Run: `./script/test.sh --filter MacBenchmarkServiceTests`

Expected: compilation fails.

- [ ] **Step 3: Implement service protocols and sequence**

Inject clock, CPU, Metal, memory, disk, thermal, power, SMART, capacity, sensor-refresh suspension, EnergyImpact suspension, and progress sink protocols. `run(profile:lease:)` validates the `.benchmark` token, performs safety preflight, pauses only GPU/temperature/fan/IOReport deep refresh plus `EnergyImpactService` resampling, keeps lightweight CPU/memory/network menu status interactive, runs stages off MainActor, applies stage timeouts, checks cancellation before/after every stage, takes medians and CV, and restores every suspension with `defer`. Return an incomplete raw result when a capability is unavailable and never synthesize a missing metric.

- [ ] **Step 4: Run service tests and heartbeat test**

Run: `./script/test.sh --filter MacBenchmarkServiceTests`

Expected: all sequences, gates, timeouts, cleanup and a MainActor heartbeat during fake heavy work pass.

- [ ] **Step 5: Commit service orchestration**

```bash
git add Sources/StorageCleanerMac/Services/MacBenchmarkService.swift Tests/StorageCleanerMacTests/MacBenchmarkServiceTests.swift
git commit -m "feat(benchmark): orchestrate safe benchmark profiles"
```

### Task 7: Implement versioned scoring and frozen baseline validation

**Files:**
- Create: `Sources/StorageCleanerMac/Services/MacBenchmarkScoring.swift`
- Create: `Sources/StorageCleanerMac/Services/MacBenchmarkBaseline.swift`
- Create: `Tests/StorageCleanerMacTests/MacBenchmarkScoringTests.swift`
- Create: `script/calibrate_benchmark.sh`

- [ ] **Step 1: Write geometric score and baseline gate tests**

Test exact reference equals 1000, each ratio clamps to 0.2–5.0, weights sum to one, any missing/zero/non-finite reference rejects scoring, report hash mismatch rejects scoring, x86_64 without a frozen baseline yields raw metrics only, and app/build metadata does not alter comparison-key equality.

- [ ] **Step 2: Run and verify missing scorer**

Run: `./script/test.sh --filter MacBenchmarkScoringTests`

Expected: compilation fails.

- [ ] **Step 3: Implement the score equation**

```swift
let weightedLog =
    0.20 * log(clamp(cpu1 / ref.cpu1)) +
    0.25 * log(clamp(cpuN / ref.cpuN)) +
    0.20 * log(clamp(gpu / ref.gpu)) +
    0.15 * log(clamp(memory / ref.memory)) +
    0.10 * log(clamp(read / ref.read)) +
    0.10 * log(clamp(write / ref.write))
let score = 1000 * exp(weightedLog)
```

Validate the complete comparison key and frozen report SHA-256 before computing. Only arm64 has a v1.5.0 baseline; x86_64 remains raw-only until separately calibrated.

- [ ] **Step 4: Add calibration export/validation tooling**

`script/calibrate_benchmark.sh` must build release mode, request quick/full runs from the app's benchmark calibration launch argument, reject samples when thermal changes, another lease is active, or component CV exceeds 5%, aggregate medians, write `docs/benchmarks/mac17-9-m5-pro-v1.json`, calculate SHA-256, and generate `MacBenchmarkBaseline.swift`. It must require two session identifiers and at least eight valid runs per profile, and it must never export serial/UUID/UDID.

- [ ] **Step 5: Run scoring tests with a synthetic signed fixture**

Run: `./script/test.sh --filter MacBenchmarkScoringTests`

Expected: formula and every baseline rejection path pass before real calibration.

- [ ] **Step 6: Commit scorer and calibration tool**

```bash
git add Sources/StorageCleanerMac/Services/MacBenchmarkScoring.swift Sources/StorageCleanerMac/Services/MacBenchmarkBaseline.swift Tests/StorageCleanerMacTests/MacBenchmarkScoringTests.swift script/calibrate_benchmark.sh
git commit -m "feat(benchmark): add versioned scoring and calibration gates"
```

### Task 8: Add Store, history, navigation, and UI

**Files:**
- Create: `Sources/StorageCleanerMac/Stores/MacBenchmarkStore.swift`
- Create: `Sources/StorageCleanerMac/Services/MacBenchmarkHistoryRepository.swift`
- Create: `Sources/StorageCleanerMac/Views/MacBenchmarkView.swift`
- Modify: `Sources/StorageCleanerMac/Models/StorageModels.swift:53-198`
- Modify: `Sources/StorageCleanerMac/Support/AppArtwork.swift`
- Modify: `Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift:1-100`
- Modify: `Sources/StorageCleanerMac/Views/ContentView.swift`
- Modify: `Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift:78-130`
- Create: `Tests/StorageCleanerMacTests/MacBenchmarkStoreTests.swift`
- Modify: `Tests/StorageCleanerMacTests/L10nTests.swift`

- [ ] **Step 1: Write Store/navigation/history tests**

Test no automatic run on init/page entry, explicit start/cancel, single flight, busy-owner UI, generation protection, page-leave cancels only its own task, 30-entry atomic history, complete-key grouping, no cross-baseline line, privacy-safe copied report, `ReviewFilter.benchmark` under system tools, and route restoration.

- [ ] **Step 2: Run and verify missing route/Store failure**

Run: `./script/test.sh --filter MacBenchmark`

Expected: compilation fails.

- [ ] **Step 3: Implement MainActor Store and bounded repository**

The Store obtains a `.benchmark` lease only after explicit confirmation, publishes preflight/stage/progress no faster than 5 Hz, owns and cancels only its task, waits for service cleanup before `.cancelled`, scores only matching complete results, and atomically saves the newest 30 aggregates. App termination cancels the Store; app launch invokes orphan cleanup.

- [ ] **Step 4: Add exact navigation case**

Add `.benchmark` to `ReviewFilter`, titles/icons/accent color, `utilityToolCases` between energy and uninstall, sidebar destination/group switches, `SystemUtilitiesView` tab title, `ContentView` destination rendering, root Store injection, and navigation localization tests. It must appear once under “系统工具” and not create another sidebar.

- [ ] **Step 5: Build the benchmark page**

Top: score or raw-only state, profile, confidence/environment, start/cancel. Then current stage/progress, component bars with raw units, safety state, environment metadata, and history grouped by comparison key. Explain that it is the app's benchmark, affected by power/temperature/load, not an Apple/Geekbench/Cinebench score, and never uploaded. Copy report contains aggregate metrics and versions only.

- [ ] **Step 6: Run Store, route, history and localization tests**

Run: `./script/test.sh --filter MacBenchmark`

Expected: all tests pass and app initialization remains lightweight.

- [ ] **Step 7: Commit feature integration**

```bash
git add Sources/StorageCleanerMac/Stores/MacBenchmarkStore.swift Sources/StorageCleanerMac/Services/MacBenchmarkHistoryRepository.swift Sources/StorageCleanerMac/Views/MacBenchmarkView.swift Sources/StorageCleanerMac/Models/StorageModels.swift Sources/StorageCleanerMac/Support/AppArtwork.swift Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift Sources/StorageCleanerMac/Views/ContentView.swift Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift Tests/StorageCleanerMacTests/MacBenchmarkStoreTests.swift Tests/StorageCleanerMacTests/L10nTests.swift
git commit -m "feat(benchmark): add Mac benchmark experience"
```

### Task 9: Calibrate the M5 Pro reference and validate real performance

**Files:**
- Create: `docs/benchmarks/mac17-9-m5-pro-v1.json`
- Modify: `Sources/StorageCleanerMac/Services/MacBenchmarkBaseline.swift`
- Create: `release/validation/mac-benchmark-v1.5.0.md`

- [ ] **Step 1: Prepare the reference environment**

Use the current MacBook Pro `Mac17,9`, Apple M5 Pro, 18 cores and 48 GB RAM on AC power, automatic power mode, battery at least 50%, thermal nominal, with no heavy lease or other benchmark/load running. Record only non-unique hardware metadata.

- [ ] **Step 2: Run two cooled calibration sessions**

Run: `./script/calibrate_benchmark.sh session-a`, cool to thermal nominal, then run `./script/calibrate_benchmark.sh session-b`.

Expected: each profile has at least eight total valid samples across the sessions, no component CV exceeds 5%, and invalid thermal/conflict samples are excluded with reasons.

- [ ] **Step 3: Verify frozen values and hash**

Run: `./script/test.sh --filter MacBenchmarkScoringTests`

Expected: generated values are finite/positive, report SHA-256 matches source, quick/full baselines exist for arm64, and release gating passes.

- [ ] **Step 4: Run one real quick and one full benchmark**

Verify UI remains responsive during window movement, page switching and status-panel use; cancel once in CPU and once in disk; confirm no temp file, Metal buffer, task, or lease remains; CPU drops within two seconds and memory/threads return toward idle.

- [ ] **Step 5: Commit baseline and validation**

```bash
git add docs/benchmarks/mac17-9-m5-pro-v1.json Sources/StorageCleanerMac/Services/MacBenchmarkBaseline.swift release/validation/mac-benchmark-v1.5.0.md
git commit -m "test(benchmark): calibrate M5 Pro baseline"
```
