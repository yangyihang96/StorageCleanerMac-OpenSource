import XCTest
@testable import StorageCleanerMac

final class MaintenanceReminderServiceTests: XCTestCase {
    func testOffCadenceDisablesReminder() {
        let referenceDate = Date(timeIntervalSince1970: 20_000)
        let lastScanAt = referenceDate.addingTimeInterval(-60 * 24 * 60 * 60)

        let summary = MaintenanceReminderService.summary(
            cadence: .off,
            lastScanAt: lastScanAt,
            referenceDate: referenceDate
        )

        XCTAssertEqual(summary.status, .disabled)
        XCTAssertFalse(summary.isDue)
        XCTAssertNil(summary.nextDueAt)
    }

    func testCadenceWithoutScanRequestsFirstScan() {
        let summary = MaintenanceReminderService.summary(
            cadence: .weekly,
            lastScanAt: nil,
            referenceDate: Date(timeIntervalSince1970: 20_000)
        )

        XCTAssertEqual(summary.status, .waitingForFirstScan)
        XCTAssertTrue(summary.isDue)
        XCTAssertNil(summary.nextDueAt)
    }

    func testWeeklyCadenceIsScheduledBeforeDueDate() {
        let referenceDate = Date(timeIntervalSince1970: 1_000_000)
        let lastScanAt = referenceDate.addingTimeInterval(-3 * 24 * 60 * 60)

        let summary = MaintenanceReminderService.summary(
            cadence: .weekly,
            lastScanAt: lastScanAt,
            referenceDate: referenceDate
        )

        XCTAssertEqual(summary.status, .scheduled)
        XCTAssertFalse(summary.isDue)
        XCTAssertEqual(summary.nextDueAt, lastScanAt.addingTimeInterval(7 * 24 * 60 * 60))
    }

    func testWeeklyCadenceIsDueAfterInterval() {
        let referenceDate = Date(timeIntervalSince1970: 1_000_000)
        let lastScanAt = referenceDate.addingTimeInterval(-8 * 24 * 60 * 60)

        let summary = MaintenanceReminderService.summary(
            cadence: .weekly,
            lastScanAt: lastScanAt,
            referenceDate: referenceDate
        )

        XCTAssertEqual(summary.status, .due)
        XCTAssertTrue(summary.isDue)
        XCTAssertEqual(summary.nextDueAt, lastScanAt.addingTimeInterval(7 * 24 * 60 * 60))
    }

    func testUnknownRawValueFallsBackToDefaultCadence() {
        XCTAssertEqual(
            MaintenanceReminderService.cadence(from: "unknown"),
            MaintenanceReminderService.defaultCadence
        )
    }
}
