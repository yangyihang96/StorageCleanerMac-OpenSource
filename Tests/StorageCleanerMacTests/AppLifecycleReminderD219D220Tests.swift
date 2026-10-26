import Foundation
import XCTest
@testable import StorageCleanerMac

/// D219 (a scan is due) and D220 (little free space) on the reminder panel:
/// when each card comes, what its button leads to, and how the Ignore menu
/// and the once-per-drop rule keep it from coming back. The center runs
/// without its panel here (`presentsPanel: false`); no window opens.
@MainActor
final class AppLifecycleReminderD219D220Tests: XCTestCase {
    /// A clock moved by hand, shared by the center and its ignore list.
    private final class ReminderClock: @unchecked Sendable {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func makeCenter(defaults: UserDefaults, clock: ReminderClock, lastScanAt: Date?) -> AppLifecycleReminderCenter {
        AppLifecycleReminderCenter(
            ignoreList: AppLifecycleIgnoreList(directory: nil, now: { clock.date }),
            defaults: defaults,
            now: { clock.date },
            lastScanDate: { lastScanAt },
            readStartupDiskSpace: { _ in nil },
            presentsPanel: false)
    }

    /// Pins the free-space settings, so the default taken from this Mac's
    /// disk size does not enter the test.
    private func pinDiskSpacePreferences(_ defaults: UserDefaults, notifies: Bool = true,
                                         threshold: Int64 = 10_000_000_000) {
        var snapshot = AppLifecycleReminderPreferences.snapshot(defaults: defaults, startupDiskCapacity: { 1_000_000_000_000 })
        snapshot.notifiesLowDiskSpace = notifies
        snapshot.lowDiskSpaceThresholdBytes = threshold
        AppLifecycleReminderPreferences.set(snapshot, defaults: defaults)
    }

    private func space(gigabytes: Int64) -> AppLifecycleReminderCenter.StartupDiskSpace {
        AppLifecycleReminderCenter.StartupDiskSpace(availableBytes: gigabytes * 1_000_000_000,
                                                    totalBytes: 1_000_000_000_000,
                                                    volumeName: "Macintosh HD")
    }

    // MARK: D219 choices

    func testScanIntervalsAreCleanMyMacsAndDailyBecomesEveryThreeDays() {
        XCTAssertEqual(MaintenanceReminderCadence.allCases, [.off, .every3Days, .weekly, .biweekly, .monthly])
        XCTAssertEqual(MaintenanceReminderCadence.allCases.map(\.interval),
                       [nil, 3 * day, 7 * day, 14 * day, 30 * day])
        XCTAssertEqual(MaintenanceReminderService.defaultCadence, .weekly)
        XCTAssertEqual(MaintenanceReminderService.cadence(from: "daily"), .every3Days)
        XCTAssertEqual(MaintenanceReminderService.cadence(from: "weekly"), .weekly)
        XCTAssertEqual(MaintenanceReminderService.cadence(from: "monthly"), .monthly)
        XCTAssertEqual(MaintenanceReminderService.cadence(from: "off"), .off)

        let defaults = TestPreferenceDomain.make(for: self)
        XCTAssertEqual(MaintenanceReminderService.cadence(defaults: defaults), .weekly)
        defaults.set("daily", forKey: MaintenanceReminderService.defaultsKey)
        XCTAssertEqual(MaintenanceReminderService.cadence(defaults: defaults), .every3Days)
    }

    func testScanDueTitleNamesTheTimeInTheLargestWholeUnit() {
        let language = CalibrationLanguageScope(.zhHans)
        defer { language.restore() }
        let expected: [(days: Double, title: String)] = [
            (3, "已经 3 天没有扫描了"), (6.9, "已经 6 天没有扫描了"), (7, "已经一周没有扫描了"),
            (14, "已经 2 周没有扫描了"), (29, "已经 4 周没有扫描了"), (30, "已经一个月没有扫描了"),
            (61, "已经 2 个月没有扫描了")
        ]
        for item in expected {
            XCTAssertEqual(AppLifecycleAlertCard.scanDueTitle(since: start, now: start.addingTimeInterval(item.days * day)),
                           item.title, "\(item.days) days")
        }
    }

    // MARK: D219 card

    func testScanCardComesOnlyWhenTheChosenIntervalHasPassed() {
        let defaults = TestPreferenceDomain.make(for: self)
        pinDiskSpacePreferences(defaults)
        let clock = ReminderClock(start)
        let lastScan = start.addingTimeInterval(-6 * day)
        let center = makeCenter(defaults: defaults, clock: clock, lastScanAt: lastScan)
        XCTAssertNil(center.currentAlert(), "Weekly: six days is not yet due")

        clock.date = lastScan.addingTimeInterval(7 * day)
        XCTAssertEqual(center.currentAlert(), .scanDue(lastScanAt: lastScan, cadence: .weekly))

        defaults.set(MaintenanceReminderCadence.off.rawValue, forKey: MaintenanceReminderService.defaultsKey)
        XCTAssertNil(center.currentAlert(), "Off: no card")
        defaults.set("daily", forKey: MaintenanceReminderService.defaultsKey)
        clock.date = lastScan.addingTimeInterval(3 * day)
        XCTAssertEqual(center.currentAlert(), .scanDue(lastScanAt: lastScan, cadence: .every3Days),
                       "A stored daily choice reminds every 3 days")

        let neverScanned = makeCenter(defaults: defaults, clock: clock, lastScanAt: nil)
        XCTAssertNil(neverScanned.currentAlert(), "A Mac never scanned is left to the first-launch guide")
    }

    func testScanNowLeadsToSmartScansReadOnlyScanAndRestsForADay() {
        let defaults = TestPreferenceDomain.make(for: self)
        pinDiskSpacePreferences(defaults)
        let clock = ReminderClock(start)
        let lastScan = start.addingTimeInterval(-10 * day)
        let center = makeCenter(defaults: defaults, clock: clock, lastScanAt: lastScan)
        var destinations: [AppLifecycleReminderCenter.Destination] = []
        center.destinationOverride = { destinations.append($0) }

        center.refreshAlert()
        XCTAssertEqual(center.presentedAlert, .scanDue(lastScanAt: lastScan, cadence: .weekly))
        center.openJunkCleanup()
        center.uninstallTrashedApplications()
        XCTAssertEqual(destinations, [], "Only the scan card's own button acts on it")

        center.scanNow()
        XCTAssertEqual(destinations, [.smartScan])
        XCTAssertNil(center.presentedAlert)
        center.refreshAlert()
        XCTAssertNil(center.presentedAlert, "A stopped scan does not bring the card straight back")

        clock.date = start.addingTimeInterval(day + 1)
        center.refreshAlert()
        XCTAssertEqual(center.presentedAlert, .scanDue(lastScanAt: lastScan, cadence: .weekly),
                       "Still not scanned a day later: the card returns")
    }

    func testIgnoringTheScanCardFollowsTheIgnoreMenu() {
        let defaults = TestPreferenceDomain.make(for: self)
        pinDiskSpacePreferences(defaults)
        let clock = ReminderClock(start)
        let center = makeCenter(defaults: defaults, clock: clock, lastScanAt: start.addingTimeInterval(-8 * day))
        center.refreshAlert()
        XCTAssertEqual(center.presentedAlert?.kind, .scanDue)

        center.ignore(.oneDay)
        XCTAssertNil(center.presentedAlert)
        XCTAssertTrue(center.ignoreList.isIgnored(.scanDue, discriminator: ""))
        clock.date = start.addingTimeInterval(day - 60)
        center.refreshAlert()
        XCTAssertNil(center.presentedAlert)
        clock.date = start.addingTimeInterval(day + 1)
        center.refreshAlert()
        XCTAssertEqual(center.presentedAlert?.kind, .scanDue)
    }

    // MARK: D220 defaults

    func testFreeSpaceDefaultIsTheChoiceNearestATenthOfTheDisk() {
        let choices = AppLifecycleReminderPreferences.lowDiskSpaceThresholdChoices
        XCTAssertEqual(choices, [2, 5, 10, 20, 30, 50, 100].map { Int64($0) * 1_000_000_000 })
        let gigabyte: Int64 = 1_000_000_000
        let cases: [(capacity: Int64?, threshold: Int64)] = [
            (nil, 100 * gigabyte),                // unreadable: CleanMyMac assumes 1 TB
            (1_000_000_000_000, 100 * gigabyte),
            (2_000_000_000_000, 100 * gigabyte),
            (494_384_795_648, 50 * gigabyte),     // a “512 GB” Mac
            (245_107_195_904, 20 * gigabyte),     // a “256 GB” Mac: 24.5 GB is nearer 20
            (256_000_000_000, 30 * gigabyte),
            (250_000_000_000, 20 * gigabyte),     // a tie keeps the earlier choice
            (0, 2 * gigabyte)
        ]
        for item in cases {
            XCTAssertEqual(AppLifecycleReminderPreferences.defaultLowDiskSpaceThresholdBytes(startupDiskCapacity: item.capacity),
                           item.threshold, "\(String(describing: item.capacity))")
        }

        let defaults = TestPreferenceDomain.make(for: self)
        let fresh = AppLifecycleReminderPreferences.snapshot(defaults: defaults, startupDiskCapacity: { 494_384_795_648 })
        XCTAssertTrue(fresh.notifiesLowDiskSpace)
        XCTAssertEqual(fresh.lowDiskSpaceThresholdBytes, 50 * gigabyte)
        var changed = fresh
        changed.notifiesLowDiskSpace = false
        changed.lowDiskSpaceThresholdBytes = 5 * gigabyte
        AppLifecycleReminderPreferences.set(changed, defaults: defaults)
        XCTAssertEqual(AppLifecycleReminderPreferences.snapshot(defaults: defaults, startupDiskCapacity: { 2_000_000_000_000 }),
                       changed, "A chosen threshold is kept whatever the disk size")
    }

    // MARK: D220 card

    func testFreeSpaceCardComesOncePerDrop() {
        let defaults = TestPreferenceDomain.make(for: self)
        pinDiskSpacePreferences(defaults)
        let center = makeCenter(defaults: defaults, clock: ReminderClock(start), lastScanAt: start)
        var destinations: [AppLifecycleReminderCenter.Destination] = []
        center.destinationOverride = { destinations.append($0) }

        center.applyStartupDiskSpace(space(gigabytes: 11))
        XCTAssertNil(center.presentedAlert)
        center.applyStartupDiskSpace(space(gigabytes: 9))
        XCTAssertEqual(center.presentedAlert, .lowDiskSpace(space(gigabytes: 9), threshold: 10_000_000_000))
        center.scanNow()
        XCTAssertEqual(destinations, [], "Only the free-space card's own button acts on it")

        center.openJunkCleanup()
        XCTAssertEqual(destinations, [.junkCleanup], "Only the module page opens; nothing is scanned or cleaned")
        XCTAssertNil(center.presentedAlert)
        center.applyStartupDiskSpace(space(gigabytes: 8))
        XCTAssertNil(center.presentedAlert, "Still the same drop: the card does not come back")

        center.applyStartupDiskSpace(space(gigabytes: 10))
        XCTAssertNil(center.presentedAlert, "Back at the threshold")
        center.applyStartupDiskSpace(space(gigabytes: 9))
        XCTAssertEqual(center.presentedAlert?.kind, .lowDiskSpace, "A new drop shows the card again")
    }

    func testFreeSpaceCardLeavesWhenSpaceRecoversBeforeAnyClick() {
        let defaults = TestPreferenceDomain.make(for: self)
        pinDiskSpacePreferences(defaults)
        let center = makeCenter(defaults: defaults, clock: ReminderClock(start), lastScanAt: start)
        center.applyStartupDiskSpace(space(gigabytes: 9))
        XCTAssertEqual(center.presentedAlert?.kind, .lowDiskSpace)
        center.applyStartupDiskSpace(space(gigabytes: 12))
        XCTAssertNil(center.presentedAlert)
        center.applyStartupDiskSpace(space(gigabytes: 9))
        XCTAssertEqual(center.presentedAlert?.kind, .lowDiskSpace)
    }

    func testIgnoringTheFreeSpaceCardAppliesOnTopOfTheDropRule() {
        let defaults = TestPreferenceDomain.make(for: self)
        pinDiskSpacePreferences(defaults)
        let clock = ReminderClock(start)
        let center = makeCenter(defaults: defaults, clock: clock, lastScanAt: start)
        center.applyStartupDiskSpace(space(gigabytes: 9))
        center.ignore(.oneWeek)
        XCTAssertNil(center.presentedAlert)
        XCTAssertTrue(center.ignoreList.isIgnored(.lowDiskSpace, discriminator: ""))

        center.applyStartupDiskSpace(space(gigabytes: 15))
        center.applyStartupDiskSpace(space(gigabytes: 9))
        XCTAssertNil(center.presentedAlert, "A new drop within the ignored week stays quiet")
        clock.date = start.addingTimeInterval(8 * day)
        center.applyStartupDiskSpace(space(gigabytes: 9))
        XCTAssertEqual(center.presentedAlert?.kind, .lowDiskSpace)
    }

    func testFreeSpaceComesBeforeTheScanCardAndTurningItOffClearsIt() {
        let defaults = TestPreferenceDomain.make(for: self)
        pinDiskSpacePreferences(defaults)
        let center = makeCenter(defaults: defaults, clock: ReminderClock(start), lastScanAt: start.addingTimeInterval(-9 * day))
        center.destinationOverride = { _ in }
        center.applyStartupDiskSpace(space(gigabytes: 9))
        XCTAssertEqual(center.presentedAlert?.kind, .lowDiskSpace)
        center.openJunkCleanup()
        center.refreshAlert()
        XCTAssertEqual(center.presentedAlert?.kind, .scanDue, "The scan card waits its turn")

        center.ignore(.ignore)
        pinDiskSpacePreferences(defaults, notifies: false)
        center.reloadPreferences()
        XCTAssertNil(center.startupDiskSpace)
        center.applyStartupDiskSpace(space(gigabytes: 1))
        XCTAssertNil(center.startupDiskSpace, "The warning is off: no reading is kept")
        XCTAssertNil(center.currentAlert())
    }

    func testResetIgnoredRemindersBringsBackHandledCards() {
        let defaults = TestPreferenceDomain.make(for: self)
        pinDiskSpacePreferences(defaults)
        let center = makeCenter(defaults: defaults, clock: ReminderClock(start), lastScanAt: start.addingTimeInterval(-9 * day))
        center.destinationOverride = { _ in }
        center.applyStartupDiskSpace(space(gigabytes: 9))
        center.openJunkCleanup()
        center.refreshAlert()
        center.ignore(.forever)
        XCTAssertNil(center.currentAlert())

        center.ignoreList.reset()
        center.releaseHandledReminders()
        XCTAssertEqual(center.presentedAlert?.kind, .lowDiskSpace)
        center.ignore(.ignore)
        center.ignoreList.reset(.lowDiskSpace)
        center.refreshAlert()
        XCTAssertEqual(center.presentedAlert?.kind, .scanDue,
                       "Ignored again, the free-space card waits for the space to recover even with its record gone")
    }

    // MARK: Reading the disk and the stored list

    func testStartupDiskReadingUsesTheAppsFreeSpaceFigure() throws {
        let plain = try XCTUnwrap(StorageCapacityService.snapshot(path: "/", includeImportantUsage: false))
        let reading = try XCTUnwrap(AppLifecycleReminderCenter.measureStartupDiskSpace(thresholdBytes: 0))
        XCTAssertEqual(reading.totalBytes, plain.totalBytes)
        XCTAssertGreaterThan(reading.availableBytes, 0)
        XCTAssertLessThanOrEqual(reading.availableBytes, reading.totalBytes)
        let short = try XCTUnwrap(AppLifecycleReminderCenter.measureStartupDiskSpace(thresholdBytes: .max))
        XCTAssertEqual(short.totalBytes, plain.totalBytes)
        XCTAssertGreaterThanOrEqual(short.availableBytes + 1_000_000_000, plain.availableBytes,
                                    "Below the threshold the purgeable space is added, as on other pages")
    }

    func testIgnoreListKeepsKnownRecordsBesideAnUnknownKind() throws {
        let directory = try TestFileSystem.makeHome(for: self).appendingPathComponent("AppLifecycle", isDirectory: true)
        try TestFileSystem.createDirectory(at: directory)
        let json = """
        [{"discriminator":"","ignoredAt":"2026-10-25T00:00:00Z","kind":999},
         {"discriminator":"","ignoredAt":"2026-10-25T00:00:00Z","kind":100},
         {"discriminator":"","ignoredAt":"2026-10-25T00:00:00Z","kind":101}]
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent(AppLifecycleIgnoreList.fileName))
        let list = AppLifecycleIgnoreList(directory: directory)
        XCTAssertTrue(list.isIgnored(.scanDue, discriminator: ""))
        XCTAssertTrue(list.isIgnored(.lowDiskSpace, discriminator: ""))
        XCTAssertEqual(list.activeRecords().count, 2)
    }
}
