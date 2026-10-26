import Foundation
import XCTest
@testable import StorageCleanerMac

/// D100 G8: the SMART counters read from the dictionary diskutil already
/// returns; no new command. Fixture values were read on a Mac (2026-10-15).
final class DiskSMARTDetailsTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let measured: [String: Any] = [
        "DATA_UNITS_WRITTEN_0": 277_223_714, "DATA_UNITS_WRITTEN_1": 0,
        "DATA_UNITS_READ_0": 305_576_964, "DATA_UNITS_READ_1": 0,
        "POWER_ON_HOURS_0": 1_469, "POWER_ON_HOURS_1": 0,
        "POWER_CYCLES_0": 207, "POWER_CYCLES_1": 0,
        "UNSAFE_SHUTDOWNS_0": 9, "UNSAFE_SHUTDOWNS_1": 0,
        "MEDIA_ERRORS_0": 0, "MEDIA_ERRORS_1": 0,
        "AVAILABLE_SPARE": 100, "AVAILABLE_SPARE_THRESHOLD": 99,
        "TEMPERATURE": 329, "PERCENTAGE_USED": 7,
    ]

    func testMeasuredCountersAreReadAndConverted() throws {
        let snapshot = try parse(smart: measured)
        let details = try XCTUnwrap(snapshot.smartDetails)
        XCTAssertEqual(details.dataUnitsWritten, 277_223_714)
        XCTAssertEqual(try XCTUnwrap(details.bytesWritten), 141_938_541_568_000)  // about 141.9 TB
        XCTAssertEqual(try XCTUnwrap(details.bytesRead), 305_576_964 * 512_000)
        XCTAssertEqual(details.powerOnHours, 1_469)
        XCTAssertEqual(details.powerCycles, 207)
        XCTAssertEqual(details.unsafeShutdowns, 9)
        XCTAssertEqual(details.mediaErrors, 0)
        XCTAssertEqual(details.availableSparePercent, 100)
        XCTAssertEqual(details.availableSpareThresholdPercent, 99)
        XCTAssertNil(details.criticalWarning)
        XCTAssertEqual(snapshot.remainingLifePercent, 93)
        XCTAssertEqual(try XCTUnwrap(snapshot.temperatureCelsius), 55.85, accuracy: 0.01)
        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.status, .healthy)
    }

    func testMissingKeysLeaveTheirFieldsUnknown() throws {
        XCTAssertNil(try parse(smart: nil).smartDetails)
        XCTAssertNil(try parse(smart: ["PERCENTAGE_USED": 7, "TEMPERATURE": 329]).smartDetails)
        let partial = try XCTUnwrap(try parse(smart: ["POWER_CYCLES_0": 12, "AVAILABLE_SPARE": 100]).smartDetails)
        XCTAssertEqual(partial, DiskSMARTDetails(powerCycles: 12, availableSparePercent: 100))
        XCTAssertNil(partial.bytesWritten)
        XCTAssertNil(partial.availableSpareThresholdPercent)
    }

    func testValuesThatAreNotNonnegativeIntegersAreUnknown() throws {
        let details = try XCTUnwrap(try parse(smart: [
            "DATA_UNITS_WRITTEN_0": "many", "DATA_UNITS_READ_0": true, "POWER_ON_HOURS_0": 1.5,
            "POWER_CYCLES_0": -3, "UNSAFE_SHUTDOWNS_0": 4, "UNSAFE_SHUTDOWNS_1": "x",
            "MEDIA_ERRORS_0": " 2 ", "AVAILABLE_SPARE": 150, "AVAILABLE_SPARE_THRESHOLD": 10,
            "CRITICAL_WARNING": "none",
        ]).smartDetails)
        XCTAssertEqual(details, DiskSMARTDetails(mediaErrors: 2, availableSpareThresholdPercent: 10))
    }

    func testTheHighHalfOfACounterIsAdded() throws {
        let details = try XCTUnwrap(try parse(smart: [
            "DATA_UNITS_WRITTEN_0": 5, "DATA_UNITS_WRITTEN_1": 1, "POWER_ON_HOURS_0": 10, "POWER_ON_HOURS_1": 2,
        ]).smartDetails)
        XCTAssertEqual(details.dataUnitsWritten, 18_446_744_073_709_551_616 + 5)
        XCTAssertEqual(details.powerOnHours, 2 * 18_446_744_073_709_551_616 + 10)
    }

    func testOnlyTheDrivesOwnWarningAndUsedUpLifeChangeTheResult() throws {
        var warned = measured
        warned["CRITICAL_WARNING"] = 4
        let warning = try parse(smart: warned)
        XCTAssertEqual(warning.smartDetails?.criticalWarning, 4)
        XCTAssertEqual(warning.status, .actionRequired)
        XCTAssertEqual(warning.summaryText, L10n.text("硬盘报告了严重警告", "The drive reports a critical warning"))

        var cleared = measured
        cleared["CRITICAL_WARNING"] = 0
        XCTAssertEqual(try parse(smart: cleared).status, .healthy)

        var wornOut = measured
        wornOut["PERCENTAGE_USED"] = 104
        let worn = try parse(smart: wornOut)
        XCTAssertEqual(worn.remainingLifePercent, 0)
        XCTAssertEqual(worn.status, .attention)
        XCTAssertEqual(worn.summaryText, L10n.text("硬盘已达到额定写入寿命", "The drive has reached its rated endurance"))

        // Spare below its threshold is shown, never judged here (the drive's
        // own critical warning carries that conclusion).
        var lowSpare = measured
        lowSpare["AVAILABLE_SPARE"] = 5
        lowSpare["AVAILABLE_SPARE_THRESHOLD"] = 10
        let spare = try parse(smart: lowSpare)
        XCTAssertEqual(spare.smartDetails?.availableSparePercent, 5)
        XCTAssertEqual(spare.status, .healthy)
    }

    func testDetailsSurviveEncodingAndOlderSnapshotsDecodeWithout() throws {
        let snapshot = try parse(smart: measured)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(DiskHealthSnapshot.self, from: data), snapshot)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "smartDetails")
        let older = try JSONDecoder().decode(DiskHealthSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(older.smartDetails)
        XCTAssertEqual(older.remainingLifePercent, snapshot.remainingLifePercent)
    }

    private func parse(smart: [String: Any]?) throws -> DiskHealthSnapshot {
        var root: [String: Any] = [
            "FilesystemType": "apfs", "TotalSize": 1_000_000, "FreeSpace": 400_000, "Internal": true,
            "SolidState": true, "FileVault": true, "SMARTStatus": "Verified", "TRIM": true,
        ]
        root["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] = smart
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        return DiskHealthService.parseDiskInfo(data, checkedAt: checkedAt)
    }
}
