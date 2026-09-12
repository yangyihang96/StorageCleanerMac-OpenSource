# Network Speed Test 2.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the system network-quality test parse real macOS output correctly, expose truthful state and scoring, warn about high traffic, and offer a separately consented 128 MB HTTPS compatibility estimate only when the native service is unavailable.

**Architecture:** Preserve the hardened `networkQuality` process runner and split parsing, error-envelope classification, path preflight, scoring, compatibility transfer, history, and UI state into focused files. `NetworkSpeedTestStore` owns one generation-protected state machine; the native attempt and any later explicitly confirmed compatibility attempt use separate heavy-work leases, with no lease held while awaiting the second consent.

**Tech Stack:** Swift 6, Foundation, Network `NWPathMonitor`, `URLSession`, AppKit/SwiftUI, XCTest/URLProtocol, `/usr/bin/networkQuality`.

---

### Task 1: Correct fractional RPM and classify native error envelopes

**Files:**
- Modify: `Sources/StorageCleanerMac/Services/NetworkSpeedTestService.swift:6-400`
- Modify: `Tests/StorageCleanerMacTests/NetworkSpeedTestServiceTests.swift`
- Create: `Tests/StorageCleanerMacTests/Fixtures/NetworkQuality/macos26-fractional-rpm.json`
- Create: `Tests/StorageCleanerMacTests/Fixtures/NetworkQuality/service-unavailable.json`

- [ ] **Step 1: Add failing fixture tests**

```swift
func testParsesFractionalResponsivenessFromMacOS26() throws {
    let data = try fixture("macos26-fractional-rpm.json")
    let result = try NetworkSpeedTestService.parse(data, testedAt: Date(timeIntervalSince1970: 10))
    XCTAssertEqual(result.responsivenessRPM, 749.993347, accuracy: 0.000001)
}

func testServiceUnavailableEnvelopeIsNotGenericFailure() async {
    let runner = StubNetworkQualityRunner(output: .init(
        standardOutput: try! fixture("service-unavailable.json"),
        standardError: Data(),
        terminationStatus: 1
    ))
    do {
        _ = try await NetworkSpeedTestService(runner: runner).test()
        XCTFail("Expected serviceUnavailable")
    } catch {
        XCTAssertEqual(error as? NetworkSpeedTestError, .serviceUnavailable)
    }
}
```

The fractional fixture must include numeric `responsiveness: 749.993347`; the unavailable fixture must include `domain: "NetworkQualityErrorDomain"` and `code: 1003` without real IP addresses or server URLs.

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `./script/test.sh --filter NetworkSpeedTestServiceTests/testParsesFractionalResponsivenessFromMacOS26`

Expected: the old integer conversion throws `invalidOutput`.

- [ ] **Step 3: Expand result and error types**

```swift
enum NetworkTestSource: String, Codable, Sendable { case nativeSystem, compatibilityEstimate }

struct NetworkSpeedTestResult: Equatable, Codable, Sendable {
    let downloadMbps: Double
    let uploadMbps: Double
    let responsivenessRPM: Double?
    let idleLatencyMilliseconds: Double
    let loadedLatencyP50Milliseconds: Double?
    let loadedLatencyP95Milliseconds: Double?
    let jitterMilliseconds: Double?
    let interfaceName: String
    let source: NetworkTestSource
    let methodVersion: String
    let durationSeconds: Double
    let transferredBytes: UInt64?
    let completeness: Double
    let testedAt: Date
}

enum NetworkSpeedTestError: Error, Equatable, Sendable {
    case invalidOutput, outputTooLarge, offline, timedOut, cancelled
    case serviceUnavailable, failed, terminationFailed
}
```

Remove the integer guard. Parse stdout and stderr dictionaries for a structured error envelope before checking `terminationStatus`; classify domain/code 1003 as `.serviceUnavailable`. Keep public IP, endpoint, server URL, and OS-version fields out of `NetworkSpeedTestResult` and all log strings.

- [ ] **Step 4: Run the complete service test class**

Run: `./script/test.sh --filter NetworkSpeedTestServiceTests`

Expected: existing process-runner cancellation/output-limit tests and new parsing tests pass.

- [ ] **Step 5: Commit parser repair**

```bash
git add Sources/StorageCleanerMac/Services/NetworkSpeedTestService.swift Tests/StorageCleanerMacTests/NetworkSpeedTestServiceTests.swift Tests/StorageCleanerMacTests/Fixtures/NetworkQuality
git commit -m "fix(network): parse fractional system quality results"
```

### Task 2: Add deterministic network-experience scoring

**Files:**
- Create: `Sources/StorageCleanerMac/Services/NetworkExperienceScoring.swift`
- Create: `Tests/StorageCleanerMacTests/NetworkExperienceScoringTests.swift`

- [ ] **Step 1: Write failing score and missing-data tests**

```swift
func testStableConnectionScoresAtLeastEighty() {
    let score = NetworkExperienceScoring.evaluate(.init(
        downloadMbps: 250, uploadMbps: 50, idleLatencyMS: 20,
        loadedLatencyP95MS: 50, jitterMS: 5, responsivenessRPM: 1000
    ))
    XCTAssertGreaterThanOrEqual(score.value!, 80)
    XCTAssertEqual(score.grade, .stable)
}

func testMissingCoreMetricSuppressesTotal() {
    let score = NetworkExperienceScoring.evaluate(.init(
        downloadMbps: 50, uploadMbps: nil, idleLatencyMS: 30,
        loadedLatencyP95MS: nil, jitterMS: nil, responsivenessRPM: nil
    ))
    XCTAssertNil(score.value)
    XCTAssertEqual(score.grade, .dataInsufficient)
}
```

- [ ] **Step 2: Verify the tests fail because the scorer is absent**

Run: `./script/test.sh --filter NetworkExperienceScoringTests`

Expected: compilation fails on `NetworkExperienceScoring`.

- [ ] **Step 3: Implement `network-experience-v1` exactly**

```swift
enum NetworkExperienceGrade: String, Codable, Sendable {
    case stable, average, congested, dataInsufficient
}

struct NetworkExperienceInput: Equatable, Sendable {
    let downloadMbps: Double?
    let uploadMbps: Double?
    let idleLatencyMS: Double?
    let loadedLatencyP95MS: Double?
    let jitterMS: Double?
    let responsivenessRPM: Double?
}

struct NetworkExperienceScore: Equatable, Codable, Sendable {
    let value: Int?
    let grade: NetworkExperienceGrade
    let completeness: Double
    let missingMetrics: Set<String>
    let modelVersion: String
}

enum NetworkExperienceScoring {
    static let modelVersion = "network-experience-v1"
    static func higherLog(_ x: Double, bad: Double, good: Double) -> Double {
        min(100, max(0, log(max(x, bad) / bad) / log(good / bad) * 100))
    }
    static func lowerLinear(_ x: Double, good: Double, bad: Double) -> Double {
        min(100, max(0, (bad - x) / (bad - good) * 100))
    }
}
```

Use weights download 25, upload 15, idle latency 20, loaded P95 20, jitter 10, RPM 10 with anchors from the design spec. Reject non-finite or negative values. Reweight only optional missing fields, require download/upload/idle latency, and return completeness plus the exact missing-field set. Grade `>=80` stable, `55..<80` average, and `<55` congested.

- [ ] **Step 4: Run scorer tests**

Run: `./script/test.sh --filter NetworkExperienceScoringTests`

Expected: normalization, boundaries, optional reweighting, invalid values, and core-field suppression pass.

- [ ] **Step 5: Commit scoring**

```bash
git add Sources/StorageCleanerMac/Services/NetworkExperienceScoring.swift Tests/StorageCleanerMacTests/NetworkExperienceScoringTests.swift
git commit -m "feat(network): add explainable experience score"
```

### Task 3: Add Network path preflight

**Files:**
- Create: `Sources/StorageCleanerMac/Services/NetworkPathPreflight.swift`
- Create: `Tests/StorageCleanerMacTests/NetworkPathPreflightTests.swift`

- [ ] **Step 1: Write state-mapping tests with a fake path source**

```swift
func testPreflightDistinguishesOfflineExpensiveAndConstrained() async {
    XCTAssertEqual(await probe(status: .unsatisfied), .offline)
    XCTAssertEqual(await probe(status: .satisfied, expensive: true), .warning(.expensive))
    XCTAssertEqual(await probe(status: .satisfied, constrained: true), .warning(.constrained))
    XCTAssertEqual(await probe(status: .satisfied), .ready(interface: .wifi))
}
```

- [ ] **Step 2: Run and observe missing preflight symbols**

Run: `./script/test.sh --filter NetworkPathPreflightTests`

Expected: compilation fails.

- [ ] **Step 3: Implement one-shot `NWPathMonitor` probing**

Define `NetworkPathPreflightResult` with `.offline`, `.warning(Reason)`, and `.ready(interface:)`. The live implementation starts a dedicated `NWPathMonitor`, resumes exactly one continuation on its serial queue, cancels the monitor after the first path, and maps Wi-Fi/wired/cellular/other without storing interface addresses.

- [ ] **Step 4: Run preflight tests**

Run: `./script/test.sh --filter NetworkPathPreflightTests`

Expected: all one-shot and cancellation tests pass.

- [ ] **Step 5: Commit preflight**

```bash
git add Sources/StorageCleanerMac/Services/NetworkPathPreflight.swift Tests/StorageCleanerMacTests/NetworkPathPreflightTests.swift
git commit -m "feat(network): preflight metered and constrained paths"
```

### Task 4: Implement the bounded compatibility estimate

**Files:**
- Create: `Sources/StorageCleanerMac/Services/NetworkCompatibilitySpeedTestService.swift`
- Create: `Tests/StorageCleanerMacTests/NetworkCompatibilitySpeedTestServiceTests.swift`

- [ ] **Step 1: Write URLProtocol security and byte-budget tests**

```swift
func testRejectsCrossHostRedirect() async {
    let service = makeService(response: .redirect(URL(string: "https://example.com/file")!))
    await XCTAssertThrowsErrorAsync(try await service.test()) { error in
        XCTAssertEqual(error as? CompatibilitySpeedTestError, .disallowedRedirect)
    }
}

func testTotalTransferNeverExceeds128MiB() async throws {
    let meter = TransferMeter()
    let service = makeService(meter: meter)
    _ = try await service.test()
    XCTAssertLessThanOrEqual(await meter.totalBytes, 128 * 1_024 * 1_024)
}
```

- [ ] **Step 2: Run and verify missing service failure**

Run: `./script/test.sh --filter NetworkCompatibilitySpeedTestServiceTests`

Expected: compilation fails.

- [ ] **Step 3: Implement the HTTPS-only service**

Use an ephemeral `URLSessionConfiguration` with cookies disabled, cache policy `.reloadIgnoringLocalCacheData`, no URL cache, connectivity waits disabled, and a delegate that permits only `https://speed.cloudflare.com/__down` and `https://speed.cloudflare.com/__up`. Reject a redirect when scheme, host, or the allowed path changes. Share an actor-backed `TransferMeter` between download and upload stages; stop both tasks before the total reaches `134_217_728` bytes. Return measured duration, exact bytes, throughput estimates, idle/loaded latency samples, P50/P95/MAD, source `.compatibilityEstimate`, and method version `compatibility-cloudflare-v1`. Do not claim packet loss or RPM.

- [ ] **Step 4: Run security and cancellation tests**

Run: `./script/test.sh --filter NetworkCompatibilitySpeedTestServiceTests`

Expected: HTTPS allowlist, redirect rejection, early EOF, HTTP failure, cookie/cache disablement, cancellation, and byte cap pass.

- [ ] **Step 5: Commit compatibility testing**

```bash
git add Sources/StorageCleanerMac/Services/NetworkCompatibilitySpeedTestService.swift Tests/StorageCleanerMacTests/NetworkCompatibilitySpeedTestServiceTests.swift
git commit -m "feat(network): add bounded compatibility estimate"
```

### Task 5: Expand the store state machine and consent flow

**Files:**
- Modify: `Sources/StorageCleanerMac/Stores/NetworkSpeedTestStore.swift:1-115`
- Modify: `Sources/StorageCleanerMac/Views/ComputerHealthView.swift`
- Modify: `Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift:78-130`
- Modify: `Tests/StorageCleanerMacTests/NetworkSpeedTestServiceTests.swift`

- [ ] **Step 1: Add failing transition tests**

Test native consent, path preflight, expensive/constrained second confirmation, native service unavailable, compatibility second consent, cancellation without fallback, and preservation of `lastSuccessfulResult` when a later attempt fails. Assert that the native HeavyWork lease is released only after child-process cleanup and before `compatibilityConsentRequired`; after compatibility confirmation, a new lease remains until URLSession cleanup.

- [ ] **Step 2: Run store tests and verify old eight-state model fails**

Run: `./script/test.sh --filter NetworkSpeedTestStore`

Expected: compilation or state assertions fail.

- [ ] **Step 3: Replace the state enum and actions**

```swift
enum NetworkSpeedTestState: Equatable, Sendable {
    case idle(lastResult: NetworkSpeedTestResult?)
    case consentRequired
    case preflighting
    case constrainedWarning(NetworkPathWarning)
    case nativeRunning(elapsed: Duration, limit: Duration)
    case nativeParsing
    case nativeServiceUnavailable
    case compatibilityConsentRequired
    case compatibilityRunning(stage: CompatibilityStage, progress: Double)
    case cancelling(stage: NetworkTestStage)
    case succeeded(NetworkSpeedTestResult)
    case offline, timedOut, cancelled
    case failed(NetworkSpeedTestFailure)
}
```

Expose explicit actions `requestNativeTest()`, `confirmNativeTraffic()`, `confirmConstrainedPath()`, `requestCompatibilityEstimate()`, `confirmCompatibilityProvider()`, and `cancel()`. Do not automatically transition from native failure/cancel to compatibility. Use generation checks at every awaited boundary and publish progress no faster than 5 Hz.

- [ ] **Step 4: Update the health-page network card**

The consent copy must state that native traffic can be hundreds of MB to several GB. The compatibility sheet must name Cloudflare, explain that the public IP is visible to the service, state the 128 MB maximum, and label results `兼容估算`. Display raw values first, then score/grade/completeness, source, duration, bytes, timestamp, and missing metrics. Keep the existing blue download and pink upload colors.

- [ ] **Step 5: Run store, health integration, and localization tests**

Run: `./script/test.sh --filter NetworkSpeedTest`

Expected: all service/store/UI source-policy tests pass with no raw endpoint or IP persistence.

- [ ] **Step 6: Commit state and UI integration**

```bash
git add Sources/StorageCleanerMac/Stores/NetworkSpeedTestStore.swift Sources/StorageCleanerMac/Views/ComputerHealthView.swift Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift Tests/StorageCleanerMacTests/NetworkSpeedTestServiceTests.swift
git commit -m "feat(network): add truthful test states and consent"
```

### Task 6: Add bounded history and real native verification

**Files:**
- Create: `Sources/StorageCleanerMac/Services/NetworkSpeedTestHistory.swift`
- Create: `Tests/StorageCleanerMacTests/NetworkSpeedTestHistoryTests.swift`
- Create: `release/validation/network-speed-v1.5.0.md`

- [ ] **Step 1: Test atomic 20-entry history without sensitive fields**

Run: `./script/test.sh --filter NetworkSpeedTestHistoryTests`

Expected before implementation: compilation fails; after implementation: newest 20 aggregate records survive reload, corrupt JSON falls back to empty, and encoded JSON contains no IP, URL, endpoint, cookie, username, or raw process output.

- [ ] **Step 2: Implement atomic Application Support persistence**

Persist only `NetworkSpeedTestResult`, `NetworkExperienceScore`, method version, and timestamp. Write a temporary file in the same directory, `fsync`, then replace the destination. Failed, cancelled, incomplete, or stale-generation attempts must not write.

- [ ] **Step 3: Run the real system test after explicit local confirmation**

Verify the app accepts fractional RPM, displays the real download/upload/latency/RPM/interface, reports actual duration and traffic, and leaves no `networkQuality` process after early or late cancellation. Trigger the compatibility path with a stubbed native service-unavailable result before any real provider transfer; the real compatibility run must stay at or under 128 MB.

- [ ] **Step 4: Record and commit validation**

```bash
git add Sources/StorageCleanerMac/Services/NetworkSpeedTestHistory.swift Tests/StorageCleanerMacTests/NetworkSpeedTestHistoryTests.swift release/validation/network-speed-v1.5.0.md
git commit -m "test(network): validate native and bounded speed tests"
```
