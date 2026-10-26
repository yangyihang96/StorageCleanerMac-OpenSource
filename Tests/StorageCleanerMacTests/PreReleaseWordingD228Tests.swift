import AppKit
import Foundation
import XCTest
@testable import StorageCleanerMac

/// D228 (before 2.0.1): the clutter landing's sentence breaks only between
/// phrases (a 1280-point window split “聊天文件”); a Downloads group's name has
/// no space before a Chinese app name; a size of 0 bytes stands a space from
/// its unit, as every other size does, wherever the app shows one.
@MainActor
final class PreReleaseWordingD228Tests: XCTestCase {
    /// The lines TextKit lays `text` out in at `width`, in the system font
    /// the landing uses, without the word joiners.
    private func lines(_ text: String, width: CGFloat, size: CGFloat) -> [String] {
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)])
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        var result: [String] = []
        var glyph = 0
        while glyph < layout.numberOfGlyphs {
            var range = NSRange()
            layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            let characters = layout.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            result.append((text as NSString).substring(with: characters)
                .replacingOccurrences(of: String(CareStudioLineBreaks.wordJoiner), with: ""))
            glyph = NSMaxRange(range)
        }
        return result
    }

    /// The landing caps its text column at 460 points (`CareStudioTemplateLanding`):
    /// about 451, 460 and 460 in the 1024-, 1280- and 1500-point windows the
    /// window tests use, over 420 in the smallest window. Every width from
    /// 240 points up is checked, in the regular and the compact size.
    func testTheClutterSentenceBreaksOnlyBetweenPhrasesAtEveryWidth() {
        let widths = stride(from: CGFloat(240), through: 460, by: 2)
        let sizes = [CGFloat(14), CareStudioMetrics.subtitleSize]
        do {
            let language = CalibrationLanguageScope(.zhHans)
            defer { language.restore() }
            let subtitle = CareStudioModule.clutter.subtitle
            let plain = "整理重复文件、相似照片、大型和旧文件、“下载”文件夹以及聊天文件；重复文件每组至少留一份。"
            XCTAssertEqual(subtitle.replacingOccurrences(of: String(CareStudioLineBreaks.wordJoiner), with: ""), plain,
                           "The words are the same; only joiners were added")
            XCTAssertTrue(subtitle.contains("聊\u{2060}天\u{2060}文\u{2060}件"))
            let words = ["整理重复文件", "相似照片", "大型和旧文件", "“下载”文件夹", "聊天文件", "重复文件", "每组至少留一份"]
            for size in sizes {
                for width in widths {
                    let laid = lines(subtitle, width: width, size: size)
                    XCTAssertEqual(laid.joined(), plain)
                    for (line, next) in zip(laid, laid.dropFirst()) {
                        XCTAssertTrue(line.last.map { "、；。".contains($0) } == true || next.hasPrefix("以及"),
                                      "\(size) pt, \(width) pt: “\(line)｜\(next)” breaks inside a phrase")
                    }
                    for word in words {
                        XCTAssertEqual(laid.reduce(0) { $0 + SwiftSourceScanning.occurrences(of: word, in: $1) },
                                       SwiftSourceScanning.occurrences(of: word, in: plain),
                                       "\(size) pt, \(width) pt: “\(word)” is split: \(laid)")
                    }
                }
            }
            // The 1280-point window's column, where the report saw “聊｜天文件”.
            XCTAssertEqual(lines(subtitle, width: 460, size: CareStudioMetrics.subtitleSize),
                           ["整理重复文件、相似照片、大型和旧文件、“下载”文件夹", "以及聊天文件；重复文件每组至少留一份。"])
        }
        do {
            let language = CalibrationLanguageScope(.english)
            defer { language.restore() }
            let subtitle = CareStudioModule.clutter.subtitle
            XCTAssertFalse(subtitle.contains(CareStudioLineBreaks.wordJoiner), "English breaks at spaces as it is")
            for size in sizes {
                for width in widths {
                    let laid = lines(subtitle, width: width, size: size)
                    XCTAssertEqual(laid.joined(), subtitle)
                    for (line, next) in zip(laid, laid.dropFirst()) {
                        XCTAssertEqual(line.last, " ", "\(size) pt, \(width) pt: “\(line)｜\(next)” breaks inside a word")
                    }
                }
            }
        }
    }

    func testBetweenPhrasesJoinsOnlyInsideChinesePhrases() {
        XCTAssertEqual(CareStudioLineBreaks.betweenPhrases("聊天文件、相似照片；以及"),
                       "聊\u{2060}天\u{2060}文\u{2060}件\u{2060}、相\u{2060}似\u{2060}照\u{2060}片\u{2060}；以\u{2060}及",
                       "A line may break after a pause mark, never inside a phrase")
        XCTAssertEqual(CareStudioLineBreaks.betweenPhrases("Copy Path"), "Copy Path")
        XCTAssertEqual(CareStudioLineBreaks.betweenPhrases("iCloud 云盘"), "iCloud 云\u{2060}盘",
                       "Latin letters and spaces are left as they are")
        XCTAssertEqual(CareStudioLineBreaks.betweenPhrases("文件夹以及聊天"), "文\u{2060}件\u{2060}夹以\u{2060}及\u{2060}聊\u{2060}天",
                       "A line may break before 以及")
    }

    func testDownloadGroupNamesSpaceOnlyBeforeLatinNames() {
        do {
            let language = CalibrationLanguageScope(.zhHans)
            defer { language.restore() }
            XCTAssertEqual(DownloadSource.application(DownloadSource.applicationName(forAgent: "sharingd")).title, "来自隔空投送")
            XCTAssertEqual(DownloadSource.application(DownloadSource.applicationName(forAgent: "Mail")).title, "来自邮件")
            XCTAssertEqual(DownloadSource.application("微信 WeChat").title, "来自微信 WeChat", "A Chinese start: no space")
            XCTAssertEqual(DownloadSource.application("Chrome").title, "来自 Chrome")
            XCTAssertEqual(DownloadSource.application("WPS Office").title, "来自 WPS Office", "A Latin start: a space")
            XCTAssertEqual(DownloadSource.site("github.com").title, "来自 github.com")
            XCTAssertEqual(DownloadSource.site("163.com").title, "来自 163.com", "A number stands apart too")
            XCTAssertEqual(DownloadSource.other.title, "其他来源")
        }
        do {
            let language = CalibrationLanguageScope(.english)
            defer { language.restore() }
            XCTAssertEqual(DownloadSource.application("Chrome").title, "From Chrome")
            XCTAssertEqual(DownloadSource.application("微信").title, "From 微信")
            XCTAssertEqual(DownloadSource.application(DownloadSource.applicationName(forAgent: "sharingd")).title, "From AirDrop")
        }
    }

    func testZeroAndOtherByteCountsStandASpaceFromTheirUnit() {
        let chinese = Locale(identifier: "zh_Hans"), english = Locale(identifier: "en_US")
        XCTAssertEqual(ByteFormat.storageString(0, locale: chinese), "0 字节")
        XCTAssertEqual(ByteFormat.storageString(512, locale: chinese), "512 字节")
        XCTAssertEqual(ByteFormat.memoryString(0, locale: chinese), "0 字节")
        XCTAssertEqual(ByteFormat.memoryString(1_000, locale: chinese), "1,000 字节")
        XCTAssertEqual(ByteFormat.storageString(17_800_000, locale: chinese), "17.8 MB", "Other units keep their space")
        XCTAssertEqual(ByteFormat.storageString(2_000, locale: chinese), "2 KB")
        XCTAssertEqual(ByteFormat.storageString(0, locale: english), "0 bytes")
        XCTAssertEqual(ByteFormat.storageString(1, locale: english), "1 byte")
        XCTAssertEqual(ByteFormat.memoryString(512, locale: english), "512 bytes")
        let language = CalibrationLanguageScope(.zhHans)
        defer { language.restore() }
        XCTAssertEqual(FileAnalysisTrashPresentation.selectionSummary(count: 0, bytes: 0), "已选 0 项 · 0 字节",
                       "The managers' footer (it said 0字节)")
    }

    /// The sizes that can be 0 and were written by the system's formatter
    /// (in the system's language, "Zero KB") go through ByteFormat.
    func testSizesThatCanBeZeroGoThroughByteFormat() throws {
        let sources = try SwiftSourceScanning.sources()
        for path in ["Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift",
                     "Sources/StorageCleanerMac/Features/AppUpdates/Coordination/ProviderBackedApplicationUpdateExecutor.swift",
                     "Sources/StorageCleanerMac/Views/ComputerHealthView.swift"] {
            let code = SwiftSourceScanning.code(try XCTUnwrap(sources[path], path))
            XCTAssertFalse(code.contains("ByteCountFormatter"), path)
            XCTAssertFalse(code.contains(".byteCount("), path)
            XCTAssertTrue(code.contains("ByteFormat.storageString("), path)
        }
    }
}
