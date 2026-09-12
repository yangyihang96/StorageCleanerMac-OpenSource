import XCTest
@testable import StorageCleanerMac

final class BrowserPrivacyDatePresetTests: XCTestCase {
    func testCalendarPresetsSpanLocalDaysAcrossDSTAndPreserveOtherFilters() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 14)))
        var filters = BrowserPrivacyFilters.empty
        filters.query = "example"
        filters.browserID = "chrome"
        BrowserPrivacyDatePreset.week.apply(to: &filters, now: now, calendar: calendar)
        let start = try XCTUnwrap(filters.startDate)
        let end = try XCTUnwrap(filters.endDate)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour], from: start),
                       DateComponents(year: 2026, month: 9, day: 29, hour: 0))
        XCTAssertEqual(calendar.dateComponents([.day], from: start, to: end).day, 6)
        XCTAssertNotEqual(end.timeIntervalSince(start), 6 * 86400, "Calendar days cross the spring DST change")
        XCTAssertEqual(filters.query, "example")
        XCTAssertEqual(filters.browserID, "chrome")
        XCTAssertEqual(BrowserPrivacyDatePreset.matching(filters, now: now, calendar: calendar), .week)
        BrowserPrivacyDatePreset.today.apply(to: &filters, now: now, calendar: calendar)
        XCTAssertEqual(filters.startDate, filters.endDate)
        BrowserPrivacyDatePreset.all.apply(to: &filters, now: now, calendar: calendar)
        XCTAssertNil(filters.startDate)
        XCTAssertNil(filters.endDate)
        XCTAssertEqual(filters.query, "example")
    }

    func testCustomAndPreviousDayRangesAreNotMarkedAsCurrentPreset() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var filters = BrowserPrivacyFilters.empty
        BrowserPrivacyDatePreset.month.apply(to: &filters, now: now, calendar: calendar)
        XCTAssertEqual(BrowserPrivacyDatePreset.matching(filters, now: now, calendar: calendar), .month)
        XCTAssertNil(BrowserPrivacyDatePreset.matching(filters, now: now.addingTimeInterval(86400), calendar: calendar))
        filters.endDate = nil
        XCTAssertNil(BrowserPrivacyDatePreset.matching(filters, now: now, calendar: calendar))
    }
}
