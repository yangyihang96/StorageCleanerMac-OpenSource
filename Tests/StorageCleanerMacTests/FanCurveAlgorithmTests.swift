import XCTest
@testable import FanControlShared

final class FanCurveAlgorithmTests: XCTestCase {
    func testExactControlPointHit() throws {
        XCTAssertEqual(
            try FanCurveInterpolator.percentage(at: 65, profile: profile()),
            55,
            accuracy: 0.001
        )
    }

    func testLinearInterpolationBetweenPoints() throws {
        XCTAssertEqual(try FanCurveInterpolator.percentage(at: 60, profile: profile()), 45)
    }

    func testTemperatureBelowFirstPointUsesFirstPercentage() throws {
        XCTAssertEqual(try FanCurveInterpolator.percentage(at: 30, profile: profile()), 20)
    }

    func testTemperatureAboveLastPointUsesFullSpeed() throws {
        XCTAssertEqual(try FanCurveInterpolator.percentage(at: 100, profile: profile()), 100)
    }

    func testZeroPercentMapsToMinimumRPM() throws {
        XCTAssertEqual(try FanCurveRPMMapper.targetRPM(
            percentage: 0,
            range: range(minimum: 1_200, maximum: 6_400)
        ), 1_200)
    }

    func testFullSpeedMapsToMaximumRPM() throws {
        XCTAssertEqual(try FanCurveRPMMapper.targetRPM(
            percentage: 100,
            range: range(minimum: 1_200, maximum: 6_400)
        ), 6_400)
    }

    func testSingleFanMappingUsesItsHardwareRange() throws {
        XCTAssertEqual(try FanCurveRPMMapper.targets(
            percentage: 50,
            ranges: [range(minimum: 1_000, maximum: 5_000)]
        ), [0: 3_000])
    }

    func testMultipleFansMapTheSamePercentageToDifferentRanges() throws {
        XCTAssertEqual(try FanCurveRPMMapper.targets(
            percentage: 50,
            ranges: [
                range(id: 0, minimum: 1_000, maximum: 5_000),
                range(id: 1, minimum: 2_000, maximum: 6_000),
            ]
        ), [0: 3_000, 1: 4_000])
    }

    func testNonIncreasingTemperaturesAreRejected() {
        assertValidationError(.nonIncreasingTemperatures, points: [
            point(40, 20), point(55, 35), point(55, 100),
        ])
    }

    func testDecreasingFanPercentageIsRejected() {
        assertValidationError(.decreasingFanPercentage, points: [
            point(40, 40), point(55, 35), point(85, 100),
        ])
    }

    func testNaNTemperatureIsRejected() {
        assertValidationError(.invalidCurveTemperature, points: [
            point(.nan, 20), point(55, 35), point(85, 100),
        ])
    }

    func testInfiniteTemperatureIsRejected() {
        assertValidationError(.invalidCurveTemperature, points: [
            point(40, 20), point(.infinity, 35), point(85, 100),
        ])
    }

    func testNaNPercentageIsRejected() {
        assertValidationError(.invalidCurvePercentage, points: [
            point(40, 20), FanCurvePoint(temperatureCelsius: 55, speedFraction: .nan),
            point(85, 100),
        ])
    }

    func testInfinitePercentageIsRejected() {
        assertValidationError(.invalidCurvePercentage, points: [
            point(40, 20), FanCurvePoint(temperatureCelsius: 55, speedFraction: .infinity),
            point(85, 100),
        ])
    }

    func testFewerThanThreePointsAreRejected() {
        assertValidationError(.invalidCurvePointCount, points: [point(40, 20), point(85, 100)])
    }

    func testMoreThanEightPointsAreRejected() {
        assertValidationError(.invalidCurvePointCount, points: stride(from: 30, through: 46, by: 2)
            .map { point(Double($0), $0 == 46 ? 100 : Double($0 - 20)) })
    }

    func testMissingFullSpeedPointIsRejected() {
        assertValidationError(.missingFullSpeedPoint, points: [
            point(40, 20), point(55, 35), point(85, 95),
        ])
    }

    func testFullSpeedPointAboveNinetyDegreesIsRejected() {
        assertValidationError(.fullSpeedPointTooHot, points: [
            point(40, 20), point(55, 35), point(91, 100),
        ])
    }

    func testAdjacentTemperaturesLessThanTwoDegreesApartAreRejected() {
        assertValidationError(.nonIncreasingTemperatures, points: [
            point(40, 20), point(41, 35), point(85, 100),
        ])
    }

    func testRapidTemperatureIncreaseIsRateLimited() throws {
        var engine = FanCurveControlEngine(initialAppliedPercentage: 20)
        let decision = try engine.evaluate(
            rawTemperature: 75,
            profile: profile(),
            at: date(0)
        )
        XCTAssertEqual(decision.appliedPercentage, 30, accuracy: 0.001)
    }

    func testFullSpeedTemperatureBypassesRiseRateLimit() throws {
        var engine = FanCurveControlEngine(initialAppliedPercentage: 20)
        XCTAssertEqual(try engine.evaluate(
            rawTemperature: 90,
            profile: profile(),
            at: date(0)
        ).appliedPercentage, 100)
    }

    func testMedianFilterRejectsOneSampleSpike() throws {
        var policy = FanCurveControlPolicy.standard
        policy.risingFilterTimeConstant = 0.001
        policy.fallingFilterTimeConstant = 0.001
        var engine = FanCurveControlEngine(policy: policy, initialAppliedPercentage: 35)
        _ = try engine.evaluate(rawTemperature: 55, profile: profile(), at: date(0))
        _ = try engine.evaluate(rawTemperature: 90, profile: profile(), at: date(1))
        let decision = try engine.evaluate(rawTemperature: 55, profile: profile(), at: date(2))
        XCTAssertEqual(decision.filteredTemperature, 55, accuracy: 0.01)
    }

    func testDecreaseIsHeldForFiveSeconds() throws {
        var policy = FanCurveControlPolicy.standard
        policy.fallingFilterTimeConstant = 0.001
        var engine = FanCurveControlEngine(policy: policy, initialAppliedPercentage: 75)
        _ = try engine.evaluate(rawTemperature: 75, profile: profile(), at: date(0))
        let decision = try engine.evaluate(rawTemperature: 40, profile: profile(), at: date(4))
        XCTAssertEqual(decision.appliedPercentage, 75, accuracy: 0.001)
    }

    func testDecreaseBeginsAfterHoldAndHysteresis() throws {
        var policy = FanCurveControlPolicy.standard
        policy.fallingFilterTimeConstant = 0.001
        policy.medianSampleCount = 1
        var engine = FanCurveControlEngine(policy: policy, initialAppliedPercentage: 75)
        _ = try engine.evaluate(rawTemperature: 75, profile: profile(), at: date(0))
        let decision = try engine.evaluate(rawTemperature: 40, profile: profile(), at: date(6))
        XCTAssertEqual(decision.appliedPercentage, 57, accuracy: 0.01)
    }

    func testIncreaseRateIsTenPercentagePointsPerSecond() throws {
        var engine = FanCurveControlEngine(initialAppliedPercentage: 20)
        _ = try engine.evaluate(rawTemperature: 65, profile: profile(), at: date(0))
        let decision = try engine.evaluate(rawTemperature: 75, profile: profile(), at: date(2))
        XCTAssertLessThanOrEqual(decision.appliedPercentage, 50.001)
    }

    func testDecreaseRateIsThreePercentagePointsPerSecond() throws {
        var policy = FanCurveControlPolicy.standard
        policy.fallingFilterTimeConstant = 0.001
        policy.medianSampleCount = 1
        policy.decreaseHold = 0
        var engine = FanCurveControlEngine(policy: policy, initialAppliedPercentage: 75)
        _ = try engine.evaluate(rawTemperature: 75, profile: profile(), at: date(0))
        let decision = try engine.evaluate(rawTemperature: 40, profile: profile(), at: date(2))
        XCTAssertEqual(decision.appliedPercentage, 69, accuracy: 0.01)
    }

    func testPercentageWriteThresholdSuppressesSmallChanges() throws {
        var policy = FanCurveControlPolicy.standard
        policy.risingFilterTimeConstant = 0.001
        var engine = FanCurveControlEngine(policy: policy, initialAppliedPercentage: 35)
        let first = try engine.evaluate(rawTemperature: 55, profile: profile(), at: date(0))
        engine.markWritten(percentage: first.appliedPercentage)
        let second = try engine.evaluate(rawTemperature: 55.5, profile: profile(), at: date(1))
        XCTAssertFalse(second.shouldWrite)
    }

    func testRPMWriteThresholdIsCentralizedAtOneHundredRPM() {
        XCTAssertEqual(FanCurveControlPolicy.standard.rpmWriteThreshold, 100)
    }

    func testThreeConsecutiveSensorFailuresTriggerFallback() {
        var engine = FanCurveControlEngine()
        XCTAssertNil(engine.recordSensorFailure(at: date(0)))
        XCTAssertNil(engine.recordSensorFailure(at: date(1)))
        XCTAssertEqual(engine.recordSensorFailure(at: date(2)), .sensorUnavailable)
    }

    func testSensorDataOlderThanTenSecondsIsStale() throws {
        var engine = FanCurveControlEngine()
        _ = try engine.evaluate(rawTemperature: 55, profile: profile(), at: date(0))
        XCTAssertTrue(engine.sensorIsStale(at: date(11)))
        XCTAssertEqual(engine.recordSensorFailure(at: date(11)), .sensorStale)
    }

    func testHelperSensorWhitelistRejectsMissingGPU() {
        XCTAssertThrowsError(try FanCurveValidator.validate(
            profile(sensor: .gpu),
            allowedSensors: [.chipMaximum, .cpu]
        )) { XCTAssertEqual($0 as? FanCurveError, .unsupportedSensor) }
    }

    func testInvalidTargetFanIDIsRejected() {
        var candidate = profile()
        candidate.targetFanIDs = [16]
        XCTAssertThrowsError(try FanCurveValidator.validate(candidate, requiresTargetFans: true)) {
            XCTAssertEqual($0 as? FanCurveError, .invalidTargetFans)
        }
    }

    func testUnavailableTargetFanIsRejected() {
        var candidate = profile()
        candidate.targetFanIDs = [0, 1]
        XCTAssertThrowsError(try FanCurveValidator.validate(
            candidate,
            availableFanIDs: [0],
            requiresTargetFans: true
        )) { XCTAssertEqual($0 as? FanCurveError, .invalidTargetFans) }
    }

    func testMissingFanRangeRejectsCurveActivation() {
        XCTAssertThrowsError(try FanCurveRPMMapper.targets(percentage: 50, ranges: [])) {
            XCTAssertEqual($0 as? FanCurveError, .fanRangeUnavailable)
        }
    }

    func testInvalidRangeOnOneFanRejectsWholeMultiFanMapping() {
        XCTAssertThrowsError(try FanCurveRPMMapper.targets(percentage: 50, ranges: [
            range(id: 0, minimum: 1_000, maximum: 5_000),
            range(id: 1, minimum: 4_000, maximum: 4_000),
        ])) { XCTAssertEqual($0 as? FanCurveError, .fanRangeUnavailable) }
    }

    func testUnsupportedProfileVersionIsRejected() {
        var candidate = profile()
        candidate.version += 1
        XCTAssertThrowsError(try FanCurveValidator.validate(candidate)) {
            XCTAssertEqual($0 as? FanCurveError, .unsupportedProfileVersion)
        }
    }

    func testProfileAndRuntimeStateRoundTripThroughCodable() throws {
        let runtime = FanCurveRuntimeState(
            status: .active,
            rawTemperature: 53,
            filteredTemperature: 52.5,
            calculatedPercentage: 35,
            appliedPercentage: 34,
            targetRPMByFan: [0: 2_200],
            actualRPMByFan: [0: 2_160],
            activeProfileID: profile().id,
            lastSensorUpdate: date(1),
            lastFanWrite: date(1),
            lastVerification: date(1)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                FanCurveRuntimeState.self,
                from: JSONEncoder().encode(runtime)
            ),
            runtime
        )
    }

    private func profile(
        sensor: FanCurveSensor = .chipMaximum,
        points: [FanCurvePoint]? = nil
    ) -> FanCurveProfile {
        var profile = FanCurveProfile.balanced(now: date(0))
        profile.sensor = sensor
        if let points { profile.points = points }
        return profile
    }

    private func point(_ temperature: Double, _ percentage: Double) -> FanCurvePoint {
        FanCurvePoint(temperatureCelsius: temperature, speedFraction: percentage / 100)
    }

    private func range(
        id: Int = 0,
        minimum: Int,
        maximum: Int,
        actual: Int = 2_000
    ) -> FanCurveFanRange {
        FanCurveFanRange(
            fanID: id,
            minimumRPM: minimum,
            maximumRPM: maximum,
            actualRPM: actual
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func assertValidationError(
        _ expected: FanCurveError,
        points: [FanCurvePoint],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try FanCurveValidator.validate(profile(points: points)), file: file, line: line) {
            XCTAssertEqual($0 as? FanCurveError, expected, file: file, line: line)
        }
    }
}
