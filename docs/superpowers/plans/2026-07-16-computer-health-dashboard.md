# Computer Health Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the existing health cards into a unified, explainable health dashboard with a coverage-gated score, evidence confidence, 90-day history, robust storage/battery trends, and at most three safe actions.

**Architecture:** Existing probes remain the source of raw snapshots. New pure evaluators transform snapshots and history into versioned score/trend models; a small atomic repository persists one daily aggregate. `ComputerHealthStore` orchestrates probes and generation checks, while focused SwiftUI components render the approved dashboard without putting network or thermal readiness into the core score.

**Tech Stack:** Swift 6, SwiftUI, Foundation, existing health probes, XCTest, Application Support JSON.

---

### Task 1: Define versioned evaluation models

**Files:**
- Modify: `Sources/StorageCleanerMac/Models/ComputerHealthModels.swift`
- Create: `Sources/StorageCleanerMac/Models/ComputerHealthAssessmentModels.swift`
- Create: `Sources/StorageCleanerMac/Models/ComputerHealthTrendModels.swift`
- Create: `Tests/StorageCleanerMacTests/ComputerHealthScoringTests.swift`

- [ ] **Step 1: Add failing model construction tests**

```swift
func testEvaluationCanRepresentDataInsufficientWithoutFakeScore() {
    let value = ComputerHealthEvaluation.dataInsufficient(
        coverage: 0.5,
        confidence: .init(value: 35, level: .low, modelVersion: "health-confidence-v1"),
        components: []
    )
    XCTAssertNil(value.score)
    XCTAssertEqual(value.modelVersion, "computer-health-v1")
}
```

- [ ] **Step 2: Run and verify missing model failure**

Run: `./script/test.sh --filter ComputerHealthScoringTests`

Expected: compilation fails because `ComputerHealthEvaluation` is absent.

- [ ] **Step 3: Add explicit score/evidence types**

Keep raw probe snapshots in `ComputerHealthModels.swift` and add explicit battery present/notPresent/failed evidence plus dated stability events. Define `HealthFactor` (`diskReliability`, `capacity`, `stability`, `backup`, `battery`), `HealthEvidenceAvailability` (`available`, `partial`, `permissionDenied`, `timedOut`, `unavailable`, `notApplicable`), `HealthComponentEvaluation`, `HealthConfidence`, `ComputerHealthEvaluation`, and `ComputerHealthHistoryEntry` in `ComputerHealthAssessmentModels.swift`. Define `StoragePressureForecast` and `BatteryWearTrend` in `ComputerHealthTrendModels.swift`. Every persisted/evaluated result must carry model versions; `score` must be optional rather than encoded as zero when evidence is insufficient.

- [ ] **Step 4: Run the model tests**

Run: `./script/test.sh --filter ComputerHealthScoringTests`

Expected: construction, Codable round trip, and `notApplicable` distinctions pass.

- [ ] **Step 5: Commit the model boundary**

```bash
git add Sources/StorageCleanerMac/Models/ComputerHealthModels.swift Sources/StorageCleanerMac/Models/ComputerHealthAssessmentModels.swift Sources/StorageCleanerMac/Models/ComputerHealthTrendModels.swift Tests/StorageCleanerMacTests/ComputerHealthScoringTests.swift
git commit -m "feat(health): define explainable evaluation models"
```

### Task 2: Implement `computer-health-v1`

**Files:**
- Create: `Sources/StorageCleanerMac/Services/ComputerHealthScoring.swift`
- Modify: `Tests/StorageCleanerMacTests/ComputerHealthScoringTests.swift`

- [ ] **Step 1: Add failing weighting and guard tests**

```swift
func testDesktopReweightsNotApplicableBattery() {
    let result = ComputerHealthScoring.evaluate(fixture(battery: .notApplicable))
    XCTAssertEqual(result.coverage, 1, accuracy: 0.0001)
    XCTAssertEqual(result.score, 100)
}

func testZeroAvailableDenominatorProducesDataInsufficient() {
    let result = ComputerHealthScoring.evaluate(allUnknownFixture())
    XCTAssertNil(result.score)
    XCTAssertEqual(result.status, .dataInsufficient)
}

func testSmartFailingCapsOverallAtTwenty() {
    let result = ComputerHealthScoring.evaluate(fixture(smart: .failing))
    XCTAssertLessThanOrEqual(result.score!, 20)
}
```

- [ ] **Step 2: Run and verify evaluator absence**

Run: `./script/test.sh --filter ComputerHealthScoringTests`

Expected: compilation fails on `ComputerHealthScoring`.

- [ ] **Step 3: Implement factor weights and piecewise rules**

```swift
enum ComputerHealthScoring {
    static let modelVersion = "computer-health-v1"
    static let weights: [HealthFactor: Double] = [
        .diskReliability: 30, .capacity: 25, .stability: 20,
        .backup: 15, .battery: 10
    ]
    static func availabilityCredit(_ value: HealthEvidenceAvailability) -> Double {
        switch value {
        case .available: 1
        case .partial: 0.5
        case .permissionDenied, .timedOut, .unavailable, .notApplicable: 0
        }
    }
}
```

Implement the design's capacity breakpoints, SMART rules/cap, Time Machine age bands, battery capacity formula/service cap, and 14-day half-life stability event weights. Exclude `notApplicable` from applicable weight. If either denominator is zero or coverage is below 0.70, return no numeric score. Preserve the clamped Double internally, display its nearest integer, and map `>=85` healthy, `60–84` attention, `<60` actionRequired; SMART failing always actionRequired with the 20 cap. TRIM/FileVault are evidence details only and cannot create duplicate penalties.

- [ ] **Step 4: Run complete scoring tests**

Run: `./script/test.sh --filter ComputerHealthScoringTests`

Expected: full score, partial credit, unknown, desktop, SMART cap, capacity segments, stability decay, backup bands, battery cap, and zero denominators pass.

- [ ] **Step 5: Commit the score engine**

```bash
git add Sources/StorageCleanerMac/Services/ComputerHealthScoring.swift Tests/StorageCleanerMacTests/ComputerHealthScoringTests.swift
git commit -m "feat(health): add coverage-gated health score"
```

### Task 3: Implement evidence confidence

**Files:**
- Create: `Sources/StorageCleanerMac/Services/HealthConfidenceScoring.swift`
- Create: `Tests/StorageCleanerMacTests/HealthConfidenceScoringTests.swift`

- [ ] **Step 1: Write formula boundary tests**

```swift
func testFreshnessUsesSeventyTwoHourHalfLife() {
    XCTAssertEqual(HealthConfidenceScoring.freshness(ageHours: 72), 0.5, accuracy: 0.0001)
    XCTAssertEqual(HealthConfidenceScoring.freshness(ageHours: -2), 1, accuracy: 0.0001)
    XCTAssertEqual(HealthConfidenceScoring.freshness(ageHours: 721), 0, accuracy: 0.0001)
}

func testConsistencyRequiresFiveSameModelScores() {
    XCTAssertEqual(HealthConfidenceScoring.consistency(scores: [80, 81, 82, 83]), 0)
}
```

- [ ] **Step 2: Run and verify missing scorer failure**

Run: `./script/test.sh --filter HealthConfidenceScoringTests`

Expected: compilation fails.

- [ ] **Step 3: Implement `health-confidence-v1`**

Use `exp(-log(2) * ageHours / 72)`, force samples older than 30 days to zero, weight factor freshness by applicable factor weight, clamp history span to distinct days divided by 30, and set consistency to `1 - clamp(scoreMAD / 15)` only with at least five same-model numeric scores. Return rounded `100 * (0.50 coverage + 0.25 freshness + 0.15 historySpan + 0.10 consistency)`, with high `>=80`, medium `60–79`, low below 60.

- [ ] **Step 4: Run confidence tests**

Run: `./script/test.sh --filter HealthConfidenceScoringTests`

Expected: freshness, history, MAD, missing-history, level, finite-value, and zero-denominator tests pass.

- [ ] **Step 5: Commit confidence scoring**

```bash
git add Sources/StorageCleanerMac/Services/HealthConfidenceScoring.swift Tests/StorageCleanerMacTests/HealthConfidenceScoringTests.swift
git commit -m "feat(health): score evidence confidence"
```

### Task 4: Add robust statistics, storage forecast, and battery trend

**Files:**
- Create: `Sources/StorageCleanerMac/Services/RobustTrendStatistics.swift`
- Create: `Sources/StorageCleanerMac/Services/SpacePressureForecasting.swift`
- Create: `Sources/StorageCleanerMac/Services/BatteryWearTrendAnalysis.swift`
- Create: `Tests/StorageCleanerMacTests/RobustTrendStatisticsTests.swift`
- Create: `Tests/StorageCleanerMacTests/SpacePressureForecastingTests.swift`
- Create: `Tests/StorageCleanerMacTests/BatteryWearTrendAnalysisTests.swift`

- [ ] **Step 1: Write Theil-Sen/MAD rejection tests**

```swift
func testStorageForecastResistsOneDayCleanupOutlier() {
    let forecast = SpacePressureForecasting.evaluate(samples: storageSamplesWithOutlier())
    XCTAssertNotNil(forecast)
    XCTAssertLessThan(forecast!.dailyAvailableByteSlope, 0)
}

func testBatteryTrendRequiresEightPointsAcrossFortyFiveDays() {
    XCTAssertNil(BatteryWearTrendAnalysis.evaluate(samples: sevenBatterySamples()))
    XCTAssertNil(BatteryWearTrendAnalysis.evaluate(samples: eightSamplesAcrossFortyDays()))
}
```

- [ ] **Step 2: Run and observe missing analysis type**

Run: `./script/test.sh --filter 'RobustTrendStatisticsTests|SpacePressureForecastingTests|BatteryWearTrendAnalysisTests'`

Expected: compilation fails.

- [ ] **Step 3: Implement reusable robust statistics**

`RobustTrendStatistics` implements pairwise Theil-Sen median slope, median absolute deviation, distinct-calendar-day filtering, and finite-value guards. `SpacePressureForecasting` requires at least seven dates over 14 days, important-usage capacity, whole-window total-capacity drift at most 5%, at least 70% negative pair slopes, `r = 1.4826 × slopeMAD`, `-s > max(64 MiB/day, r)`, `s + r < -64 MiB/day`, and pressure line `max(total * 0.15, 20 GiB)`; it returns 0 days when already under pressure and calculates the outward-rounded range from `s-r`/`s+r`. `BatteryWearTrendAnalysis` requires at least eight points over 45 days and capacity MAD at most 1.5 points; compute loss per 90 days and per 100 cycles plus confidence `100 × (0.40 × min(count/16,1) + 0.30 × min(span/90,1) + 0.30 × (1-min(MAD/1.5,1)))`, then classify with 1/3-point and 70-confidence thresholds.

- [ ] **Step 4: Run trend tests**

Run: `./script/test.sh --filter 'RobustTrendStatisticsTests|SpacePressureForecastingTests|BatteryWearTrendAnalysisTests'`

Expected: outliers, noise, insufficient span, capacity change, cycle stagnation, confidence gate, and no-death-prediction tests pass.

- [ ] **Step 5: Commit unique algorithms**

```bash
git add Sources/StorageCleanerMac/Services/RobustTrendStatistics.swift Sources/StorageCleanerMac/Services/SpacePressureForecasting.swift Sources/StorageCleanerMac/Services/BatteryWearTrendAnalysis.swift Tests/StorageCleanerMacTests/RobustTrendStatisticsTests.swift Tests/StorageCleanerMacTests/SpacePressureForecastingTests.swift Tests/StorageCleanerMacTests/BatteryWearTrendAnalysisTests.swift
git commit -m "feat(health): add robust storage and battery trends"
```

### Task 5: Persist one daily 90-day aggregate

**Files:**
- Create: `Sources/StorageCleanerMac/Services/ComputerHealthHistoryRepository.swift`
- Create: `Tests/StorageCleanerMacTests/ComputerHealthHistoryRepositoryTests.swift`

- [ ] **Step 1: Write atomic persistence tests**

Test same-day replacement, newest-first ordering, 90-day trimming, corrupt JSON fallback, model-version preservation, and encoded-data privacy. The encoded bytes must not contain process names, file paths, browser domains, IP addresses, disk serials, or diagnostic report contents.

- [ ] **Step 2: Run and verify missing repository failure**

Run: `./script/test.sh --filter ComputerHealthHistoryRepositoryTests`

Expected: compilation fails.

- [ ] **Step 3: Implement repository protocol and atomic file store**

```swift
protocol ComputerHealthHistoryPersisting: Sendable {
    func load() async -> [ComputerHealthHistoryEntry]
    func save(_ entry: ComputerHealthHistoryEntry) async throws
}
```

The live actor writes in Application Support using a same-directory temporary file and atomic replacement. It stores at most one entry per local calendar day and retains 90 days. A successfully gathered but data-insufficient snapshot saves components/coverage with a nil total; failed, cancelled, and stale-generation refreshes do not save.

- [ ] **Step 4: Run repository tests**

Run: `./script/test.sh --filter ComputerHealthHistoryRepositoryTests`

Expected: persistence and privacy tests pass.

- [ ] **Step 5: Commit history repository**

```bash
git add Sources/StorageCleanerMac/Services/ComputerHealthHistoryRepository.swift Tests/StorageCleanerMacTests/ComputerHealthHistoryRepositoryTests.swift
git commit -m "feat(health): persist bounded daily history"
```

### Task 6: Integrate evaluation into `ComputerHealthStore`

**Files:**
- Modify: `Sources/StorageCleanerMac/Stores/ComputerHealthStore.swift:113-316`
- Modify: `Sources/StorageCleanerMac/Services/StorageCapacityService.swift`
- Modify: `Sources/StorageCleanerMac/Services/CapacityHistoryService.swift`
- Modify: `Sources/StorageCleanerMac/Services/StabilityReportService.swift`
- Modify: `Sources/StorageCleanerMac/Services/BatteryHealthService.swift`
- Modify: `Tests/StorageCleanerMacTests/ComputerHealthIntegrationTests.swift`
- Modify: `Tests/StorageCleanerMacTests/MenuBarCachedHealthTests.swift`
- Modify: `Tests/StorageCleanerMacTests/SystemUtilitySafetyTests.swift`

- [ ] **Step 1: Add failing refresh/publication tests**

Test that refresh publishes raw snapshot, evaluation, confidence, storage forecast, battery trend, and history as one generation; a late cancelled generation cannot overwrite or persist; capacity history writes only after generation acceptance; explicit no-battery differs from probe failure; stability event dates survive without paths; network and thermal readiness stay separate from the core evaluation; menu bar reads a cached summary only. Replace the brittle source assertion that bans every `.task`/`.onAppear` with semantic assertions that page entry never calls `refresh`, a probe, or network start; lightweight local-history loading remains allowed.

- [ ] **Step 2: Run integration tests and verify missing evaluation state**

Run: `./script/test.sh --filter ComputerHealthIntegrationTests`

Expected: assertions fail because the Store publishes only `snapshot`.

- [ ] **Step 3: Add explicit Store outputs and orchestration**

```swift
@Published private(set) var evaluation: ComputerHealthEvaluation?
@Published private(set) var history: [ComputerHealthHistoryEntry] = []
@Published private(set) var storageForecast: StoragePressureForecast?
@Published private(set) var batteryTrend: BatteryWearTrend?
@Published private(set) var thermalReadiness: ThermalReadiness = .unknown
```

Make capacity probing side-effect free and preserve `availableForImportantUsageBytes`; move daily capacity/history commits out of `DefaultComputerHealthProbe`. Preserve stability `event(type, occurredAt)` values while discarding report paths. Make battery probing return explicit present/notPresent/failed evidence. After all raw probes finish, load same-model history, evaluate score/confidence/trends off the MainActor, check cancellation and generation, then publish once on the MainActor and atomically commit capacity plus health history. Save data-insufficient component evidence with nil total, but never save failed/cancelled/stale work. Keep `recordNetworkSpeedResult` as a separate cached environment result and do not change health score when it changes.

- [ ] **Step 4: Run health integration and cached-menu tests**

Run: `./script/test.sh --filter ComputerHealth`

Expected: generation, cancellation, history, cache-only menu, and explicit-action safety tests pass.

- [ ] **Step 5: Commit Store integration**

```bash
git add Sources/StorageCleanerMac/Stores/ComputerHealthStore.swift Sources/StorageCleanerMac/Services/StorageCapacityService.swift Sources/StorageCleanerMac/Services/CapacityHistoryService.swift Sources/StorageCleanerMac/Services/StabilityReportService.swift Sources/StorageCleanerMac/Services/BatteryHealthService.swift Tests/StorageCleanerMacTests/ComputerHealthIntegrationTests.swift Tests/StorageCleanerMacTests/MenuBarCachedHealthTests.swift Tests/StorageCleanerMacTests/SystemUtilitySafetyTests.swift
git commit -m "feat(health): publish versioned dashboard evaluation"
```

### Task 7: Build the unified health dashboard

**Files:**
- Modify: `Sources/StorageCleanerMac/Views/ComputerHealthView.swift`
- Create: `Sources/StorageCleanerMac/Views/ComputerHealth/HealthScoreHero.swift`
- Create: `Sources/StorageCleanerMac/Views/ComputerHealth/HealthTrendChart.swift`
- Create: `Sources/StorageCleanerMac/Views/ComputerHealth/HealthActionList.swift`
- Create: `Sources/StorageCleanerMac/Views/ComputerHealth/HealthFactorGrid.swift`
- Create: `Tests/StorageCleanerMacTests/ComputerHealthDashboardTests.swift`
- Modify: `Tests/StorageCleanerMacTests/L10nTests.swift`

- [ ] **Step 1: Add source-policy and action-limit tests**

Require the hero, trend chart, action list, factor grid, score-breakdown disclosure, network environment card, and thermal readiness card. Assert action selection returns at most three items, each with one safe action, and network/thermal identifiers never occur in core score factors.

- [ ] **Step 2: Run dashboard tests and verify failure**

Run: `./script/test.sh --filter ComputerHealthDashboardTests`

Expected: new components do not exist.

- [ ] **Step 3: Compose the approved dashboard**

Use `AppDesignTokens`, `glassPanel`, semantic colors, monospaced digits, and the existing blue download/pink upload colors. Top order: score/data-insufficient ring, confidence and checked time, 7/30-day change, refresh; maximum three prioritized actions; trend chart; factor grid; separate environment section; expandable score evidence. For 7/30-day deltas, select the closest same-model local-day sample within ±2/±5 days and prefer the newer tie; consistency uses only history preceding the candidate. Prioritize/dedupe actions exactly as the design spec: SMART, current pressure, battery service, stale/unconfigured backup, recent panic/restart, 30-day forecast, remaining score bands; break ties by weighted deduction then stable factor order. Unknown/unavailable evidence must say so and never show green. Preserve battery settings safe guidance; do not directly modify charging limits.

- [ ] **Step 4: Add deterministic debug fixtures for visual checks**

Add Debug-only view initializers accepting fixed evaluation/history values for full score, insufficient data, SMART failing, no battery, and long localized text. They must not trigger probes or persist history.

- [ ] **Step 5: Run dashboard, localization, and full health tests**

Run: `./script/test.sh --filter ComputerHealth`

Expected: layout/source-policy, action priority, localization, scoring, Store, and integration tests pass.

- [ ] **Step 6: Commit the dashboard**

```bash
git add Sources/StorageCleanerMac/Views/ComputerHealthView.swift Sources/StorageCleanerMac/Views/ComputerHealth Tests/StorageCleanerMacTests/ComputerHealthDashboardTests.swift Tests/StorageCleanerMacTests/L10nTests.swift
git commit -m "feat(health): build unified health dashboard"
```

### Task 8: Real-data and performance validation

**Files:**
- Create: `release/validation/computer-health-v1.5.0.md`

- [ ] **Step 1: Verify every raw value against its system source**

Cross-check SMART/status, capacity, Time Machine, recent stability events, battery capacity/cycles/condition, and thermal state. Record unavailable and permission-limited cases separately; do not coerce them to healthy.

- [ ] **Step 2: Verify evaluation consistency**

Recalculate factor deductions, applicable weights, coverage, confidence, top-three actions, and score cap from the captured aggregate. Confirm network score and thermal readiness do not change the core total.

- [ ] **Step 3: Verify UI and refresh performance**

Check system/light/dark appearance, Chinese and English, reduced motion, minimum 980×680 window, no battery fixture, long values, manual refresh, page switching, and 60-second idle. No probe may run solely because the page appeared; CPU/memory/threads must return to the v1.4.0 idle band after refresh.

- [ ] **Step 4: Commit the validation record**

```bash
git add release/validation/computer-health-v1.5.0.md
git commit -m "test(health): record dashboard data validation"
```
