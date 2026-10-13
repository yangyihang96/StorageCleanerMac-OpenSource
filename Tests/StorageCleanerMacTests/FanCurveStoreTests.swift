import FanControlShared
import XCTest
@testable import StorageCleanerMac

@MainActor
final class FanCurveStoreTests: XCTestCase {
    func testDraftChangesNeverMutateAppliedProfile() throws {
        let (store, _, suite) = makeStore()
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        let applied = try store.preparedProfile(targetFanIDs: [0])
        store.markApplied(applied)
        let point = try XCTUnwrap(store.draftProfile.points.first)

        store.updatePoint(
            id: point.id,
            temperatureCelsius: point.temperatureCelsius + 2,
            speedFraction: point.speedFraction
        )

        XCTAssertEqual(store.appliedProfile, applied)
        XCTAssertNotEqual(store.draftProfile.points, applied.points)
        XCTAssertTrue(store.hasUnappliedChanges)
    }

    func testCorruptPersistenceFallsBackWithoutStartingControl() {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = TestPreferenceDomain.open(suiteName: suite)!
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        defaults.set(Data("not-json".utf8), forKey: "fanCurve.savedProfile.v1")
        defaults.set(Data("not-json".utf8), forKey: "fanCurve.draftProfile.v1")

        let store = FanCurveStore(defaults: defaults)
        let expected = FanCurveProfile.balanced().points

        XCTAssertEqual(store.savedProfile.points.map(\.temperatureCelsius), expected.map(\.temperatureCelsius))
        XCTAssertEqual(store.savedProfile.points.map(\.fanPercentage), expected.map(\.fanPercentage))
        XCTAssertEqual(store.draftProfile.points.map(\.temperatureCelsius), expected.map(\.temperatureCelsius))
        XCTAssertEqual(store.draftProfile.points.map(\.fanPercentage), expected.map(\.fanPercentage))
        XCTAssertNil(store.appliedProfile)
    }

    func testPointCountAndFullSpeedPointStayConstrained() throws {
        let (store, _, suite) = makeStore()
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }

        for _ in 0..<12 { store.addPoint() }
        XCTAssertLessThanOrEqual(store.draftProfile.points.count, 8)

        let finalID = try XCTUnwrap(store.draftProfile.points.last?.id)
        store.removePoint(id: finalID)
        XCTAssertEqual(store.draftProfile.points.last?.id, finalID)
        XCTAssertEqual(store.draftProfile.points.last?.fanPercentage, 100)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(store.draftProfile.points.last?.temperatureCelsius),
            90
        )

        while store.draftProfile.points.count > 3 {
            store.removePoint(id: store.draftProfile.points[0].id)
        }
        store.removePoint(id: store.draftProfile.points[0].id)
        XCTAssertEqual(store.draftProfile.points.count, 3)
    }

    func testOnlyProfilesPersistNotRuntimeOrLeaseState() throws {
        let (store, defaults, suite) = makeStore()
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        store.markApplied(try store.preparedProfile(targetFanIDs: [0, 1]))

        let keys = Set(defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("fanCurve.")
        })
        XCTAssertEqual(keys, ["fanCurve.savedProfile.v1", "fanCurve.draftProfile.v1"])
        XCTAssertFalse(keys.contains { $0.localizedCaseInsensitiveContains("lease") })
        XCTAssertFalse(keys.contains { $0.localizedCaseInsensitiveContains("runtime") })
    }

    private func makeStore() -> (FanCurveStore, UserDefaults, String) {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = TestPreferenceDomain.open(suiteName: suite)!
        return (FanCurveStore(defaults: defaults), defaults, suite)
    }
}
