import Foundation
import XCTest
@testable import StorageCleanerMac

/// D223: the clutter landing names its kinds, Large & Old Files included
/// (D226: and Downloads, in the sidebar's tooltip too), and keeps “one of
/// each stays” to the duplicates. D224 (D141): the
/// reminder card, its Ignore menu and the reminder settings say things in
/// this app's words; none of the sentences found in CleanMyMac's string
/// tables word for word is back.
@MainActor
final class WordingD223D224Tests: XCTestCase {
    private func code(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        // Comments may still name what CleanMyMac calls a thing.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testTheClutterLandingNamesItsKindsAndKeepsOneOfEachToTheDuplicates() {
        let language = CalibrationLanguageScope(.zhHans)
        defer { language.restore() }
        // D228＋旧值：the subtitle was the plain sentence; it now joins each phrase's characters with U+2060
        // so a line breaks only between phrases (`PreReleaseWordingD228Tests`). The words are compared without them.
        let subtitle = CareStudioModule.clutter.subtitle.replacingOccurrences(of: "\u{2060}", with: "")
        // D226＋旧值：was "整理重复文件、相似照片、大型和旧文件以及聊天文件；重复文件每组至少留一份。";
        // the Downloads folder joins the kinds in the results page's order.
        XCTAssertEqual(subtitle, "整理重复文件、相似照片、大型和旧文件、“下载”文件夹以及聊天文件；重复文件每组至少留一份。")
        for kind in ["重复文件", "相似照片", "大型和旧文件", "“下载”文件夹", "聊天文件"] { XCTAssertTrue(subtitle.contains(kind), kind) }
        XCTAssertTrue(subtitle.contains("重复文件每组至少留一份"), "Only duplicates keep one of each")
        // D226: the sidebar's tooltip lists the same kinds, shorter (it said only duplicates and similar photos).
        XCTAssertEqual(CareStudioFamily.clutter.summary, "重复文件、相似照片、大型和旧文件、下载和聊天文件")
    }

    func testCleanMyMacsSentencesAreNotUsedWordForWord() throws {
        let files = [
            "Sources/StorageCleanerMac/Features/AppLifecycle/Reminders/UI/AppLifecycleAlertCard.swift",
            "Sources/StorageCleanerMac/Features/AppLifecycle/Reminders/UI/AppLifecycleReminderSettingsSection.swift",
            "Sources/StorageCleanerMac/Features/AppLifecycle/Reminders/AppLifecycleIgnoreList.swift"
        ]
        // Found word for word in CleanMyMac's zh-Hans and en tables (2026-10-26).
        let copied = [
            "以正确的方式彻底卸载应用程序", "Uninstall applications correctly",
            "移除废纸篓中的应用程序以及所有相关残留项", "Remove trashed applications along with all related leftovers",
            "是时候清倒废纸篓了", "time to empty your Trash",
            "废纸篓中文件的大小已超过您设置的上限", "limit you have set",
            "正在释放…", "Freeing Up", "\"卸载...\"", "\"Uninstall...\"",
            "如果您将某款应用程序放入废纸篓中", "If you put an application into Trash",
            "废纸篓大小超过此值时发出通知", "Notify if Trash size exceeds", "Offer to uninstall applications correctly",
            "\"一天\"", "\"For a day\"", "\"3 天\"", "\"For 3 days\"", "\"一周\"", "\"For a week\"",
            "\"直到明天\"", "\"Until tomorrow\"", "\"永久\"", "\"Forever\""
        ]
        for file in files {
            let text = try code(file)
            for sentence in copied { XCTAssertFalse(text.contains(sentence), "\(file): \(sentence)") }
        }
    }

    func testTheIgnoreMenuSaysHowLongInItsOwnWords() {
        let language = CalibrationLanguageScope(.zhHans)
        defer { language.restore() }
        XCTAssertEqual(AppLifecycleIgnoreOption.menuOptions.map(\.title),
                       ["一天内不再提醒", "3 天内不再提醒", "一周内不再提醒", "今天不再提醒", "以后都不再提醒"])
        XCTAssertEqual(AppLifecycleIgnoreOption.ignore.title, "忽略", "The plain verb the app uses for every ignore")
    }
}
