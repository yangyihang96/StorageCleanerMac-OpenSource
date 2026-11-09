import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D275: every date shown to the user goes through one entry and follows the app's language.
/// This process's `Locale.current` is `en_US` whatever the app's language, while the packaged
/// app's is `zh-Hans_US` on the same Mac (it writes `AppleLanguages` into its own domain), so
/// the rule takes the current locale as a parameter. The expected text comes from a bundle
/// with the app's localization settings, run with each language and region.
@MainActor
final class AppDateTextTests: XCTestCase {
    private let date: Date = {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 11, 2, 15, 23, 45)
        return Calendar(identifier: .gregorian).date(from: parts)!
    }()

    /// ICU puts a narrow no-break space before AM and PM.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func testTheRuleForEachLanguageAndRegion() {
        let cases: [(usesChinese: Bool, current: String, wide: String, numeric: String)] = [
            (true, "zh-Hans_US", "2026年11月2日 15:23", "2026/11/2 15:23"),
            (true, "zh-Hans_AU", "2026年11月2日 15:23", "2026/11/2 15:23"),
            (true, "zh_CN", "2026年11月2日 15:23", "2026/11/2 15:23"),
            // Switched to Chinese while running: the process keeps its locale until a relaunch.
            (true, "en_US", "2026年11月2日 15:23", "2026/11/2 15:23"),
            (false, "en_US", "Nov 2, 2026 at 3:23 PM", "11/2/2026, 3:23 PM"),
            (false, "en_AU", "2 Nov 2026 at 3:23 pm", "2/11/2026, 3:23 pm"),
            (false, "en_GB", "2 Nov 2026 at 15:23", "02/11/2026, 15:23"),
            (false, "en_CN", "Nov 2, 2026 at 15:23", "2026/11/2, 15:23"),
            (false, "en_FR", "2 Nov 2026 at 15:23", "02/11/2026, 15:23"),
            // Switched to English while running.
            (false, "zh-Hans_US", "Nov 2, 2026 at 3:23 PM", "11/2/2026, 3:23 PM"),
        ]
        for item in cases {
            let locale = L10n.dateLocale(usesChinese: item.usesChinese, current: Locale(identifier: item.current))
            let label = "\(item.usesChinese ? "Chinese" : "English") on \(item.current)"
            XCTAssertEqual(
                plain(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))),
                item.wide, label)
            XCTAssertEqual(
                plain(date.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(locale))),
                item.numeric, label)
        }
    }

    func testEveryStyleInUseReadsAsOneChineseFormat() {
        let scope = CalibrationLanguageScope(.zhHans)
        defer { scope.restore() }
        let styles: [(Date.FormatStyle.DateStyle, Date.FormatStyle.TimeStyle, String)] = [
            (.abbreviated, .shortened, "2026年11月2日 15:23"),
            (.omitted, .standard, "15:23:45"),
            (.omitted, .shortened, "15:23"),
            (.abbreviated, .omitted, "2026年11月2日"),
            (.numeric, .omitted, "2026/11/2"),
            (.numeric, .shortened, "2026/11/2 15:23"),
            (.abbreviated, .standard, "2026年11月2日 15:23:45"),
            (.numeric, .standard, "2026/11/2 15:23:45"),
            (.long, .omitted, "2026年11月2日"),
        ]
        for (dateStyle, timeStyle, expected) in styles {
            XCTAssertEqual(date.appFormatted(date: dateStyle, time: timeStyle), expected)
        }
        let dateTimes: [(Date.FormatStyle, String)] = [
            (.dateTime.year().month().day().hour().minute(), "2026年11月2日 15:23"),
            (.dateTime.year().month().day().hour().minute().second(), "2026年11月2日 15:23:45"),
            (.dateTime.year().month(.abbreviated).day().hour().minute(), "2026年11月2日 15:23"),
            (.dateTime.year().month().day(), "2026年11月2日"),
        ]
        for (style, expected) in dateTimes {
            XCTAssertEqual(date.appFormatted(style), expected)
        }
    }

    func testEnglishNeverShowsChinese() {
        let scope = CalibrationLanguageScope(.english)
        defer { scope.restore() }
        for text in [
            date.appFormatted(date: .abbreviated, time: .shortened),
            date.appFormatted(.dateTime.year().month(.abbreviated).day().hour().minute()),
        ] {
            XCTAssertTrue(text.contains("Nov"), text)
            XCTAssertFalse(text.contains("年"), text)
        }
    }

    // MARK: - Real call sites, in the test process where they used to read in English

    func testTheChartReadoutFollowsTheAppLanguage() {
        let scope = CalibrationLanguageScope(.zhHans)
        defer { scope.restore() }
        XCTAssertEqual(LightfieldTrendChart.readoutLabel(time: date, xFraction: nil, xValueFormat: nil, precise: true), "15:23:45")
        XCTAssertEqual(LightfieldTrendChart.readoutLabel(time: date, xFraction: nil, xValueFormat: nil, precise: false), "15:23")
    }

    func testPanelChartsDefaultToTheAppLanguage() {
        let scope = CalibrationLanguageScope(.zhHans)
        defer { scope.restore() }
        XCTAssertEqual(PanelChartDateFormatting.string(for: date, visibleDuration: 3_600), "15:23:45")
        XCTAssertEqual(PanelChartDateFormatting.string(for: date, visibleDuration: 3 * PanelChartDateFormatting.oneDay), "11月2日 15:23")
        let lines = PanelChartDateFormatting.tooltipLines(for: date, visibleDuration: 3 * PanelChartDateFormatting.oneDay)
        XCTAssertEqual(lines.time, "15:23:45")
        XCTAssertEqual(lines.date, "11月2日")
    }

    func testTheBackupDetailFollowsTheAppLanguage() {
        let scope = CalibrationLanguageScope(.zhHans)
        defer { scope.restore() }
        let backup = MobileDeviceBackup(
            id: "fixture", location: "/Users/fixture/backup", deviceName: "Fixture", systemVersion: nil,
            backupDate: date, isEncrypted: nil, isUnfinished: false, bytes: 0, sharedBytes: 0, fileCount: 0,
            isIncomplete: false)
        let detail = MobileDeviceBackupPresentation.detail(backup)
        XCTAssertTrue(detail.contains("备份于 2026年11月2日 15:23"), detail)
    }

    // MARK: - For review

    /// `Text(_, format:)` and `Text(_, style:)` can only be read rendered. Writes the memory
    /// panel, which has the first, and the second as `ReversibleOperationsView` writes it, in each
    /// language, when `SCM_DATE_RENDER_DIR` names a directory.
    func testRendersTheDatesInTextForReview() throws {
        guard let path = ProcessInfo.processInfo.environment["SCM_DATE_RENDER_DIR"] else {
            throw XCTSkip("Set SCM_DATE_RENDER_DIR to write the review pictures.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = MemoryProcess(
            id: 7_101, name: "Fixture", path: "/Applications/Fixture.app/Contents/MacOS/Fixture",
            iconPath: "/Applications/Fixture.app", bundlePath: "/Applications/Fixture.app",
            residentBytes: 400 * 1024 * 1024, percent: 1, canQuit: false)
        let snapshot = MemorySnapshot(
            generatedAt: date, physicalBytes: 16 * 1024 * 1024 * 1024, freeBytes: 4 * 1024 * 1024 * 1024,
            inactiveBytes: 0, speculativeBytes: 0, fileBackedBytes: 0, purgeableBytes: 0, wiredBytes: 0,
            compressedBytes: 0, swapUsedBytes: 0, pressureFreePercentage: 80, pressureSummary: "fixture",
            topProcesses: [process])
        for (language, name) in [(AppLanguage.zhHans, "zh"), (.english, "en")] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            let store = try ScanStore.makeForTests(for: self)
            let page = VStack(alignment: .leading, spacing: 8) {
                MemoryProcessSelectionPanel(snapshot: snapshot, store: store)
                HStack(spacing: 4) {
                    Text(date, style: .date)
                        .environment(\.locale, L10n.dateLocale)
                    Text(date, style: .time)
                        .environment(\.locale, L10n.dateLocale)
                }
            }
            .padding(16)
            .frame(width: 900)
            .environment(\.colorScheme, .light)
            .background(Color.white)
            let renderer = ImageRenderer(content: page)
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("dates-in-text-\(name).png"))
        }
    }

    // MARK: - Source guard

    /// The patterns need no leading dot, so a call on `self` inside a `Date` extension counts.
    /// A bare `.formatted()` looks the same on a date as on a number, so this can't see one.
    func testNothingShownToTheUserBypassesTheEntry() throws {
        let entry = "Sources/StorageCleanerMac/Support/AppDateText.swift"
        var bypasses: [String] = []
        for (path, code) in try SwiftSourceScanning.compactSourceCode() where path != entry {
            for pattern in ["formatted(date:", "formatted(.dateTime", "Date.FormatStyle(", "formatter.locale=L10n.locale"]
            where code.contains(pattern) {
                bypasses.append("\(path): \(pattern)")
            }
        }
        XCTAssertEqual(bypasses.sorted(), [], "A date for the user goes through `Date.appFormatted` or `L10n.dateLocale`")
    }

    /// `Text(_, format:)` and `Text(_, style:)` format with the environment's locale, and the
    /// roots set `L10n.locale`, which isn't the entry's choice for English in other regions.
    func testDatesInTextSetTheEntryLocaleThemselves() throws {
        var missing: [String] = []
        for (path, code) in try SwiftSourceScanning.sourceCode() {
            let lines = code.components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.contains(#/\bText\([^"]*, (format: \.dateTime|style: \.)/#) {
                let next = lines[(index + 1)...].first { !$0.allSatisfy(\.isWhitespace) } ?? ""
                if !next.contains(".environment(\\.locale, L10n.dateLocale)") {
                    missing.append("\(path):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(missing.sorted(), [])
    }
}
