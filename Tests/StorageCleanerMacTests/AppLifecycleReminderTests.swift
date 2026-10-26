import Foundation
import XCTest
@testable import StorageCleanerMac

/// CleanMyMac's trashed-app and Trash-size reminders as rebuilt here
/// (`CleanMyMac卸载更新逆向-2026-10-19/逆向规格与差距清单.md` §5).
final class AppLifecycleReminderTests: XCTestCase {
    private func makeApp(at url: URL, identifier: String, createMacOS: Bool = true) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try TestFileSystem.createDirectory(at: contents)
        if createMacOS { try TestFileSystem.createDirectory(at: contents.appendingPathComponent("MacOS")) }
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": url.deletingPathExtension().lastPathComponent,
                                   "CFBundleShortVersionString": "1.0", "CFBundleExecutable": "Fixture"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    // MARK: Detection (`applicationsToUninstallFromTrashURL:`)

    func testDetectorFindsNestedAppsAndSkipsOpaquePackagesAndBundleInternals() throws {
        let home = try TestFileSystem.makeHome(for: self)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        try makeApp(at: trash.appendingPathComponent("Alpha.app"), identifier: "com.example.alpha")
        try makeApp(at: trash.appendingPathComponent("Alpha.app/Contents/Helpers/Inner.app"), identifier: "com.example.inner")
        try makeApp(at: trash.appendingPathComponent("folder/sub/Beta.app"), identifier: "com.example.beta")
        try makeApp(at: trash.appendingPathComponent("Broken.app"), identifier: "com.example.broken", createMacOS: false)
        try makeApp(at: trash.appendingPathComponent("Library.photolibrary/Hidden.app"), identifier: "com.example.hidden")
        try makeApp(at: trash.appendingPathComponent("Machine.vmwarevm/Guest.app"), identifier: "com.example.guest")
        // CleanMyMac matches the extension with rangeOfString("app"): an
        // .appex with MacOS and Info.plist counts as an application.
        try makeApp(at: trash.appendingPathComponent("Widget.appex"), identifier: "com.example.widget")

        let scan = TrashedApplicationsDetector.applicationURLs(inTrash: trash)
        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(Set(scan.applicationURLs.map(\.lastPathComponent)), ["Alpha.app", "Beta.app", "Widget.appex"])
    }

    func testValidApplicationNeedsMacOSFolderAndInfoPlist() throws {
        let home = try TestFileSystem.makeHome(for: self)
        let valid = home.appendingPathComponent("Valid.APP")
        try makeApp(at: valid, identifier: "com.example.valid")
        XCTAssertTrue(TrashedApplicationsDetector.isValidApplication(at: valid))
        let noMacOS = home.appendingPathComponent("NoMacOS.app")
        try makeApp(at: noMacOS, identifier: "com.example.nomacos", createMacOS: false)
        XCTAssertFalse(TrashedApplicationsDetector.isValidApplication(at: noMacOS))
        let plainFolder = home.appendingPathComponent("Folder")
        try TestFileSystem.createDirectory(at: plainFolder.appendingPathComponent("Contents/MacOS"))
        XCTAssertFalse(TrashedApplicationsDetector.isValidApplication(at: plainFolder))
    }

    // MARK: Filter (`appExistsOutsideTrashWithURL:`)

    func testCopyOutsideTheTrashCountsOnlyWhenWritable() throws {
        let home = try TestFileSystem.makeHome(for: self)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        let trashed = trash.appendingPathComponent("Gamma.app")
        try makeApp(at: trashed, identifier: "com.example.gamma")
        let applications = home.appendingPathComponent("Applications", isDirectory: true)
        let outside = applications.appendingPathComponent("Gamma.app")
        try makeApp(at: outside, identifier: "com.example.gamma")

        // LaunchServices knows a writable copy outside the Trash.
        XCTAssertTrue(TrashedApplicationsDetector.applicationExistsOutsideTrash(
            trashed, trashURL: trash, launchServicesPath: { _ in outside.path },
            applicationsDirectory: applications.path))
        // LaunchServices only knows the copy in the Trash, and the
        // Applications folder has none of that name.
        XCTAssertFalse(TrashedApplicationsDetector.applicationExistsOutsideTrash(
            trashed, trashURL: trash, launchServicesPath: { _ in trashed.path },
            applicationsDirectory: home.appendingPathComponent("Empty").path))
        // LaunchServices knows nothing; the same bundle name in Applications counts.
        XCTAssertTrue(TrashedApplicationsDetector.applicationExistsOutsideTrash(
            trashed, trashURL: trash, launchServicesPath: { _ in nil },
            applicationsDirectory: applications.path))
    }

    func testDetectedAppsCarryCleanMyMacStyleDiscriminator() throws {
        let home = try TestFileSystem.makeHome(for: self)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        try makeApp(at: trash.appendingPathComponent("My App.app"), identifier: "com.example.myapp")
        let result = TrashedApplicationsDetector.trashedApplications(inTrash: trash, existsOutsideTrash: { _ in false })
        let app = try XCTUnwrap(result.applications.first)
        XCTAssertEqual(app.bundleIdentifier, "com.example.myapp")
        XCTAssertTrue(app.discriminator.hasPrefix("file://"))
        XCTAssertTrue(app.discriminator.hasSuffix("/.Trash/My%20App.app/"))
    }

    // MARK: Ignore list

    func testIgnoreOptionIntervalsMatchTheObservedRecords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        // 803772210.36 + 57389.64 = 803829600, Sydney midnight (observed).
        let ignoredAt = Date(timeIntervalSinceReferenceDate: 803_772_210.36188102)
        let untilTomorrow = AppLifecycleIgnoreOption.untilTomorrow.interval(from: ignoredAt, calendar: calendar)
        XCTAssertEqual(untilTomorrow ?? 0, 57_389.64, accuracy: 0.01)
        XCTAssertEqual(AppLifecycleIgnoreOption.ignore.interval(from: ignoredAt), 604_800)
        XCTAssertEqual(AppLifecycleIgnoreOption.oneDay.interval(from: ignoredAt), 86_400)
        XCTAssertEqual(AppLifecycleIgnoreOption.threeDays.interval(from: ignoredAt), 259_200)
        XCTAssertNil(AppLifecycleIgnoreOption.forever.interval(from: ignoredAt))
        XCTAssertEqual(AppLifecycleIgnoreOption.menuOptions, [.oneDay, .threeDays, .oneWeek, .untilTomorrow, .forever])
    }

    func testIgnoreListIsPerDiscriminatorPersistsAndExpires() throws {
        let directory = try TestFileSystem.makeHome(for: self).appendingPathComponent("AppLifecycle")
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let list = AppLifecycleIgnoreList(directory: directory, now: { clock.now })
        list.ignore(.trashedApplication, discriminators: ["file:///a.app/"], option: .oneDay)
        list.ignore(.trashSize, discriminators: [""], option: .forever)
        XCTAssertTrue(list.isIgnored(.trashedApplication, discriminator: "file:///a.app/"))
        XCTAssertFalse(list.isIgnored(.trashedApplication, discriminator: "file:///b.app/"))
        XCTAssertFalse(list.isIgnored(.trashSize, discriminator: "file:///a.app/"))

        clock.now = clock.now.addingTimeInterval(2 * 24 * 60 * 60)
        let reloaded = AppLifecycleIgnoreList(directory: directory, now: { clock.now })
        XCTAssertFalse(reloaded.isIgnored(.trashedApplication, discriminator: "file:///a.app/"))
        XCTAssertTrue(reloaded.isIgnored(.trashSize, discriminator: ""))
        reloaded.reset(.trashSize)
        XCTAssertFalse(reloaded.isIgnored(.trashSize, discriminator: ""))
    }

    func testPreferencesDefaultToCleanMyMacValues() {
        let defaults = TestPreferenceDomain.make(for: self)
        let snapshot = AppLifecycleReminderPreferences.snapshot(defaults: defaults)
        XCTAssertTrue(snapshot.offersCorrectUninstall)
        XCTAssertTrue(snapshot.notifiesTrashSize)
        XCTAssertEqual(snapshot.trashSizeThresholdBytes, 2_000_000_000)
        var changed = snapshot
        changed.notifiesTrashSize = false
        changed.trashSizeThresholdBytes = 5_000_000_000
        AppLifecycleReminderPreferences.set(changed, defaults: defaults)
        XCTAssertEqual(AppLifecycleReminderPreferences.snapshot(defaults: defaults), changed)
    }

    // MARK: Trash size

    func testTrashSizeCountsTopLevelEntriesAndFlagsUnreadableTrash() throws {
        let home = try TestFileSystem.makeHome(for: self)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        try Data(count: 64 * 1024).write(to: trash.appendingPathComponent("one.bin"))
        try TestFileSystem.createDirectory(at: trash.appendingPathComponent("folder"))
        try Data(count: 32 * 1024).write(to: trash.appendingPathComponent("folder/two.bin"))
        let measurer = TrashSizeMeasurer()
        let measurement = measurer.measure(locations: [trash])
        XCTAssertTrue(measurement.isReadable)
        XCTAssertEqual(measurement.itemCount, 2)
        XCTAssertGreaterThanOrEqual(measurement.totalBytes, 96 * 1024)
        let missing = measurer.measure(locations: [home.appendingPathComponent("NoTrash")])
        XCTAssertFalse(missing.isReadable)
    }
}

/// A clock tests can move.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
