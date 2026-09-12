import XCTest
@testable import StorageCleanerMac

final class ComputerHealthScoringTests: XCTestCase {
    func testEvaluationCanRepresentDataInsufficientWithoutFakeScore() {
        let value = ComputerHealthEvaluation.dataInsufficient(
            coverage: 0.5,
            confidence: .init(
                value: 35,
                level: .low,
                modelVersion: "health-confidence-v1"
            ),
            components: []
        )

        XCTAssertNil(value.score)
        XCTAssertEqual(value.status, .dataInsufficient)
        XCTAssertEqual(value.modelVersion, "computer-health-v2")
    }

    func testEvaluationAndHistoryRoundTripKeepVersionedOptionalScore() throws {
        let evaluatedAt = Date(timeIntervalSince1970: 1_752_624_000)
        let component = HealthComponentEvaluation(
            factor: .capacity,
            availability: .partial,
            score: 72.5,
            evidenceSummary: "important-usage capacity",
            evaluatedAt: evaluatedAt,
            modelVersion: "computer-health-v1"
        )
        let evaluation = ComputerHealthEvaluation(
            score: 72.5,
            status: .attention,
            coverage: 0.75,
            confidence: .init(
                value: 68,
                level: .medium,
                modelVersion: "health-confidence-v1"
            ),
            components: [component],
            evaluatedAt: evaluatedAt,
            modelVersion: "computer-health-v1"
        )
        let history = ComputerHealthHistoryEntry(
            recordedAt: evaluatedAt,
            evaluation: evaluation,
            totalBytes: 1_000,
            availableForImportantUsageBytes: 250,
            maximumCapacityPercent: 91,
            batteryCycleCount: 120,
            latestVerifiedCompleteBackupAt: evaluatedAt.addingTimeInterval(-3_600),
            modelVersion: "computer-health-history-v1"
        )

        let encoded = try JSONEncoder().encode(history)
        let decoded = try JSONDecoder().decode(ComputerHealthHistoryEntry.self, from: encoded)

        XCTAssertEqual(decoded, history)
        XCTAssertEqual(decoded.evaluation.score, 72.5)
        XCTAssertEqual(decoded.evaluation.modelVersion, "computer-health-v1")
        XCTAssertEqual(decoded.modelVersion, "computer-health-history-v1")
    }

    func testNotApplicableIsDistinctFromUnavailableAndContributesNoFakeScore() {
        let date = Date(timeIntervalSince1970: 1_752_624_000)
        let notApplicable = HealthComponentEvaluation(
            factor: .battery,
            availability: .notApplicable,
            score: nil,
            evidenceSummary: "No internal battery",
            evaluatedAt: date,
            modelVersion: "computer-health-v1"
        )
        let unavailable = HealthComponentEvaluation(
            factor: .battery,
            availability: .unavailable,
            score: nil,
            evidenceSummary: "Probe failed",
            evaluatedAt: date,
            modelVersion: "computer-health-v1"
        )

        XCTAssertNotEqual(notApplicable.availability, unavailable.availability)
        XCTAssertNil(notApplicable.score)
        XCTAssertNil(unavailable.score)
    }

    func testRawBatteryEvidenceDistinguishesAbsentBatteryFromProbeFailure() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_752_624_000)
        let absent = BatteryHealthEvidence.notPresent(checkedAt: checkedAt)
        let failed = BatteryHealthEvidence.failed(reason: .timedOut, checkedAt: checkedAt)

        XCTAssertNotEqual(absent, failed)

        for evidence in [absent, failed] {
            let data = try JSONEncoder().encode(evidence)
            XCTAssertEqual(
                try JSONDecoder().decode(BatteryHealthEvidence.self, from: data),
                evidence
            )
        }
    }

    func testTrendModelsRoundTripWithTheirAlgorithmVersions() throws {
        let evaluatedAt = Date(timeIntervalSince1970: 1_752_624_000)
        let storage = StoragePressureForecast(
            dailyAvailableByteSlope: -128 * 1_024 * 1_024,
            slopeMAD: 16 * 1_024 * 1_024,
            pressureLineBytes: 20 * 1_024 * 1_024 * 1_024,
            daysUntilPressure: 45,
            earliestDaysUntilPressure: 39,
            latestDaysUntilPressure: 54,
            sampleCount: 14,
            spanDays: 30,
            evaluatedAt: evaluatedAt,
            modelVersion: "storage-pressure-v1"
        )
        let battery = BatteryWearTrend(
            lossPer90Days: 1.2,
            lossPer100Cycles: 0.8,
            capacityMAD: 0.5,
            confidence: 76,
            classification: .observe,
            sampleCount: 12,
            spanDays: 70,
            evaluatedAt: evaluatedAt,
            modelVersion: "battery-wear-v1"
        )

        let storageData = try JSONEncoder().encode(storage)
        let batteryData = try JSONEncoder().encode(battery)

        XCTAssertEqual(
            try JSONDecoder().decode(StoragePressureForecast.self, from: storageData),
            storage
        )
        XCTAssertEqual(
            try JSONDecoder().decode(BatteryWearTrend.self, from: batteryData),
            battery
        )
        XCTAssertEqual(storage.modelVersion, "storage-pressure-v1")
        XCTAssertEqual(battery.modelVersion, "battery-wear-v1")
    }

    func testAllHealthyEvidenceProducesFullCoverageAndScore() {
        let result = ComputerHealthScoring.evaluate(
            snapshot: fixture(),
            referenceDate: referenceDate
        )

        XCTAssertEqual(result.coverage, 1, accuracy: 0.0001)
        XCTAssertEqual(result.score, 100)
        XCTAssertEqual(result.status, .healthy)
        XCTAssertEqual(result.components.count, HealthFactor.allCases.count)
    }

    func testDesktopReweightsNotApplicableBattery() {
        let result = ComputerHealthScoring.evaluate(
            snapshot: fixture(batteryEvidence: .notPresent(checkedAt: referenceDate)),
            referenceDate: referenceDate
        )

        XCTAssertEqual(result.coverage, 1, accuracy: 0.0001)
        XCTAssertEqual(result.score, 100)
        XCTAssertEqual(
            result.components.first(where: { $0.factor == .battery })?.availability,
            .notApplicable
        )
    }

    func testBatteryProbeFailureLowersCoverageWithoutPretendingDesktop() {
        let result = ComputerHealthScoring.evaluate(
            snapshot: fixture(
                batteryEvidence: .failed(reason: .timedOut, checkedAt: referenceDate)
            ),
            referenceDate: referenceDate
        )

        XCTAssertEqual(result.coverage, 0.7, accuracy: 0.0001)
        XCTAssertEqual(result.score, 100)
        XCTAssertEqual(
            result.components.first(where: { $0.factor == .battery })?.availability,
            .timedOut
        )
    }

    func testZeroAvailableDenominatorProducesDataInsufficient() {
        let unavailable = fixture(
            diskSMART: .unavailable,
            capacityAvailability: .unavailable,
            backupAvailability: .unavailable,
            latestBackupAgeHours: nil,
            stabilityAvailability: .unavailable,
            batteryEvidence: .failed(reason: .unavailable, checkedAt: referenceDate)
        )
        let result = ComputerHealthScoring.evaluate(
            snapshot: unavailable,
            referenceDate: referenceDate
        )

        XCTAssertNil(result.score)
        XCTAssertEqual(result.status, .dataInsufficient)
        XCTAssertEqual(result.coverage, 0)
    }

    func testCoverageBelowSeventyPercentWithholdsNumericScore() {
        let result = ComputerHealthScoring.evaluate(
            snapshot: fixture(
                capacityAvailability: .unavailable,
                backupAvailability: .unavailable,
                latestBackupAgeHours: nil,
                stabilityAvailability: .unavailable,
                batteryEvidence: .failed(reason: .unavailable, checkedAt: referenceDate)
            ),
            referenceDate: referenceDate
        )

        XCTAssertEqual(result.coverage, 0.35, accuracy: 0.0001)
        XCTAssertNil(result.score)
        XCTAssertEqual(result.status, .dataInsufficient)
    }

    func testPartialEvidenceReceivesHalfCoverageAndWeightedScore() {
        let result = ComputerHealthScoring.evaluate(
            snapshot: fixture(
                capacityAvailability: .partial,
                importantAvailableBytes: 100 * gib,
                totalBytes: 1_000 * gib,
                batteryEvidence: .notPresent(checkedAt: referenceDate)
            ),
            referenceDate: referenceDate
        )

        XCTAssertEqual(result.coverage, 62.5 / 70, accuracy: 0.0001)
        XCTAssertEqual(result.score ?? -1, 97.84, accuracy: 0.0001)
        XCTAssertEqual(result.status, .attention)
    }

    func testSmartFailingCapsOverallAtTwentyAndForcesActionRequired() {
        let result = ComputerHealthScoring.evaluate(
            snapshot: fixture(diskSMART: .failing),
            referenceDate: referenceDate
        )

        XCTAssertEqual(result.score, 20)
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(
            result.components.first(where: { $0.factor == .diskReliability })?.score,
            0
        )
    }

    func testUnavailableSMARTDoesNotReceivePartialCreditOrPenalty() {
        let result = ComputerHealthScoring.evaluate(
            snapshot: fixture(diskSMART: .unavailable, diskAvailability: .partial),
            referenceDate: referenceDate
        )

        XCTAssertEqual(result.coverage, 0.65, accuracy: 0.0001)
        XCTAssertNil(result.score)
        XCTAssertEqual(result.status, .dataInsufficient)
        XCTAssertEqual(
            result.components.first(where: { $0.factor == .diskReliability })?.availability,
            .unavailable
        )
    }

    func testCapacityPiecewiseBoundariesUseImportantUsageBytesOnly() {
        XCTAssertEqual(ComputerHealthScoring.capacityScore(availableBytes: 200 * gib, totalBytes: 1_000 * gib), 100)
        XCTAssertEqual(ComputerHealthScoring.capacityScore(availableBytes: 150 * gib, totalBytes: 1_000 * gib) ?? -1, 91, accuracy: 0.0001)
        XCTAssertEqual(ComputerHealthScoring.capacityScore(availableBytes: 100 * gib, totalBytes: 1_000 * gib) ?? -1, 82, accuracy: 0.0001)
        XCTAssertEqual(ComputerHealthScoring.capacityScore(availableBytes: 50 * gib, totalBytes: 1_000 * gib) ?? -1, 58, accuracy: 0.0001)
        XCTAssertEqual(ComputerHealthScoring.capacityScore(availableBytes: 20 * gib, totalBytes: 1_000 * gib) ?? -1, 33.6, accuracy: 0.0001)
        XCTAssertEqual(ComputerHealthScoring.capacityScore(availableBytes: 0, totalBytes: 1_000 * gib), 0)
        XCTAssertNil(ComputerHealthScoring.capacityScore(availableBytes: -1, totalBytes: 1_000 * gib))
        XCTAssertNil(ComputerHealthScoring.capacityScore(availableBytes: 500, totalBytes: 0))
    }

    func testStabilityUsesFourteenDayHalfLifeAndCapsPenalty() {
        let currentPanic = ComputerHealthScoring.stabilityScore(
            events: [.init(type: .panic, occurredAt: referenceDate)],
            referenceDate: referenceDate
        )
        let agedPanic = ComputerHealthScoring.stabilityScore(
            events: [
                .init(type: .panic, occurredAt: referenceDate.addingTimeInterval(-14 * 86_400))
            ],
            referenceDate: referenceDate
        )
        let futurePanic = ComputerHealthScoring.stabilityScore(
            events: [.init(type: .panic, occurredAt: referenceDate.addingTimeInterval(3_600))],
            referenceDate: referenceDate
        )
        let saturated = ComputerHealthScoring.stabilityScore(
            events: (0..<3).map { _ in .init(type: .panic, occurredAt: referenceDate) },
            referenceDate: referenceDate
        )

        XCTAssertEqual(currentPanic, 40, accuracy: 0.0001)
        XCTAssertEqual(agedPanic, 70, accuracy: 0.0001)
        XCTAssertEqual(futurePanic, 40, accuracy: 0.0001)
        XCTAssertEqual(saturated, 0, accuracy: 0.0001)
    }

    func testStabilityScoreExcludesApplicationDiagnostics() {
        let appEvents = ComputerHealthScoring.stabilityScore(
            events: [
                .init(type: .crash, occurredAt: referenceDate),
                .init(type: .spin, occurredAt: referenceDate)
            ],
            referenceDate: referenceDate
        )
        let systemHang = ComputerHealthScoring.stabilityScore(
            events: [.init(type: .hang, occurredAt: referenceDate)],
            referenceDate: referenceDate
        )

        XCTAssertEqual(appEvents, 100, accuracy: 0.0001)
        XCTAssertEqual(systemHang, 92, accuracy: 0.0001)
    }

    func testBackupAgeBandsAndUnreachableFallbackHistory() {
        let agesAndScores: [(Double, Double)] = [
            (12, 100), (48, 90), (5 * 24, 75), (10 * 24, 50), (20 * 24, 25)
        ]
        for (ageHours, expectedScore) in agesAndScores {
            let result = ComputerHealthScoring.evaluate(
                snapshot: fixture(latestBackupAgeHours: ageHours),
                referenceDate: referenceDate
            )
            XCTAssertEqual(
                result.components.first(where: { $0.factor == .backup })?.score,
                expectedScore
            )
        }

        let history = [
            ComputerHealthHistoryEntry(
                recordedAt: referenceDate.addingTimeInterval(-86_400),
                evaluation: .dataInsufficient(
                    coverage: 0,
                    confidence: .init(
                        value: 0,
                        level: .low,
                        modelVersion: "health-confidence-v1"
                    ),
                    components: [],
                    evaluatedAt: referenceDate.addingTimeInterval(-86_400)
                ),
                latestVerifiedCompleteBackupAt: referenceDate.addingTimeInterval(-2 * 86_400)
            )
        ]
        let unreachable = ComputerHealthScoring.evaluate(
            snapshot: fixture(
                backupDestination: .unreachable,
                backupAvailability: .partial,
                latestBackupAgeHours: nil
            ),
            history: history,
            referenceDate: referenceDate
        )
        XCTAssertEqual(
            unreachable.components.first(where: { $0.factor == .backup })?.score,
            40
        )
    }

    func testBatteryCapacityFormulaAndServiceCap() {
        let normal = ComputerHealthScoring.evaluate(
            snapshot: fixture(batteryCapacity: 80),
            referenceDate: referenceDate
        )
        let service = ComputerHealthScoring.evaluate(
            snapshot: fixture(batteryCapacity: 95, batteryCondition: .serviceRecommended),
            referenceDate: referenceDate
        )

        XCTAssertEqual(normal.components.first(where: { $0.factor == .battery })?.score, 80)
        XCTAssertEqual(
            service.components.first(where: { $0.factor == .battery })?.score,
            40
        )
        XCTAssertEqual(service.status, .actionRequired)
    }

    func testBackupReadinessRemainsVisibleWithoutChangingDeviceHealthScore() {
        let configured = ComputerHealthScoring.evaluate(
            snapshot: fixture(),
            referenceDate: referenceDate
        )
        let unconfigured = ComputerHealthScoring.evaluate(
            snapshot: fixture(
                backupDestination: .unconfigured,
                latestBackupAgeHours: nil
            ),
            referenceDate: referenceDate
        )

        XCTAssertEqual(unconfigured.score, configured.score)
        XCTAssertEqual(unconfigured.status, configured.status)
        XCTAssertEqual(
            unconfigured.components.first(where: { $0.factor == .backup })?.score,
            0
        )
        XCTAssertEqual(ComputerHealthScoring.weights[.backup], 0)
    }

    func testDiskLifeEstimateAndBatteryCapacityUseMeasuredNonlinearScores() {
        XCTAssertEqual(ComputerHealthScoring.batteryCapacityScore(100), 100)
        XCTAssertEqual(ComputerHealthScoring.batteryCapacityScore(90), 100)
        XCTAssertEqual(ComputerHealthScoring.batteryCapacityScore(80), 80)
        XCTAssertEqual(ComputerHealthScoring.batteryCapacityScore(70), 50)
        XCTAssertNil(ComputerHealthScoring.batteryCapacityScore(101))

        let result = ComputerHealthScoring.evaluate(
            snapshot: fixture(diskRemainingLifePercent: 68),
            referenceDate: referenceDate
        )
        XCTAssertEqual(
            result.components.first(where: { $0.factor == .diskReliability })?.score,
            68
        )
        XCTAssertEqual(result.status, .attention)
    }

    func testTrimAndFileVaultDoNotCreateDuplicatePenalty() {
        let baseline = ComputerHealthScoring.evaluate(
            snapshot: fixture(),
            referenceDate: referenceDate
        )
        let backgroundDetailsChanged = ComputerHealthScoring.evaluate(
            snapshot: fixture(trimEnabled: false, fileVaultEnabled: false),
            referenceDate: referenceDate
        )

        XCTAssertEqual(baseline.score, backgroundDetailsChanged.score)
    }

    private var referenceDate: Date {
        Date(timeIntervalSince1970: 1_790_000_000)
    }

    private var gib: Int64 { 1_024 * 1_024 * 1_024 }

    private func fixture(
        diskSMART: DiskSMARTStatus = .verified,
        diskRemainingLifePercent: Int? = nil,
        diskAvailability explicitDiskAvailability: HealthAvailability? = nil,
        trimEnabled: Bool? = true,
        fileVaultEnabled: Bool? = true,
        capacityAvailability: HealthAvailability = .available,
        importantAvailableBytes: Int64? = 250 * 1_024 * 1_024 * 1_024,
        totalBytes: Int64? = 1_000 * 1_024 * 1_024 * 1_024,
        backupDestination: TimeMachineDestinationState = .configured,
        backupAvailability: HealthAvailability = .available,
        latestBackupAgeHours: Double? = 12,
        stabilityAvailability: HealthAvailability = .available,
        stabilityEvents: [StabilityEvent] = [],
        batteryEvidence explicitBatteryEvidence: BatteryHealthEvidence? = nil,
        batteryCapacity: Int? = 100,
        batteryCondition: BatteryCondition = .normal
    ) -> ComputerHealthSnapshot {
        let batteryEvidence = explicitBatteryEvidence ?? .present(
            BatteryHealthSnapshot(
                availability: .available,
                status: batteryCondition == .serviceRecommended ? .actionRequired : .healthy,
                currentChargePercent: 80,
                isCharging: false,
                powerSource: .acPower,
                maximumCapacityPercent: batteryCapacity,
                cycleCount: 100,
                condition: batteryCondition,
                batteryPowerMode: .automatic,
                adapterPowerMode: .automatic,
                guidance: .init(kind: .none),
                sampledAt: referenceDate
            )
        )
        let latestBackup = latestBackupAgeHours.map {
            referenceDate.addingTimeInterval(-$0 * 3_600)
        }
        let diskAvailability = explicitDiskAvailability
            ?? (diskSMART == .unavailable ? .unavailable : .available)

        return ComputerHealthSnapshot(
            generatedAt: referenceDate,
            disk: DiskHealthSnapshot(
                availability: diskAvailability,
                status: diskSMART == .failing ? .actionRequired : .healthy,
                smartStatus: diskSMART,
                isTRIMEnabled: trimEnabled,
                fileSystem: "APFS",
                isSolidState: true,
                isInternal: true,
                isFileVaultEnabled: fileVaultEnabled,
                totalBytes: totalBytes,
                availableBytes: importantAvailableBytes,
                remainingLifePercent: diskRemainingLifePercent,
                summaryText: nil,
                checkedAt: referenceDate
            ),
            capacity: CapacityTrendSnapshot(
                availability: capacityAvailability,
                status: .healthy,
                totalBytes: totalBytes,
                availableBytes: 999,
                availableForImportantUsageBytes: importantAvailableBytes,
                sevenDayDeltaBytes: nil,
                recordedAt: referenceDate
            ),
            backup: TimeMachineSnapshot(
                availability: backupAvailability,
                status: backupDestination == .unconfigured ? .actionRequired : .healthy,
                destinationState: backupDestination,
                isRunning: false,
                latestLocalSnapshot: nil,
                latestCompleteBackup: latestBackup,
                completeBackupAvailability: backupAvailability,
                summaryText: nil,
                checkedAt: referenceDate
            ),
            stability: StabilitySummary(
                availability: stabilityAvailability,
                status: .healthy,
                crashCount: stabilityEvents.filter { $0.type == .crash }.count,
                hangCount: stabilityEvents.filter { $0.type == .hang }.count,
                spinCount: stabilityEvents.filter { $0.type == .spin }.count,
                panicCount: stabilityEvents.filter { $0.type == .panic }.count,
                unexpectedRestartCount: stabilityEvents.filter {
                    $0.type == .unexpectedRestart
                }.count,
                events: stabilityEvents,
                filesExamined: 10,
                windowStart: referenceDate.addingTimeInterval(-30 * 86_400),
                generatedAt: referenceDate
            ),
            batteryEvidence: batteryEvidence
        )
    }
}
