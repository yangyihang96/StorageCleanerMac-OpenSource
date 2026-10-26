import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D154 batch 3P: big numbers count up from 0 written as their result, and
/// the round button answers the pointer the same way on every page.
@MainActor
final class CareStudioCountingTests: XCTestCase {
    func testANumberCountsUpWrittenAsItsResult() {
        XCTAssertEqual(CareStudioCount.text("2.3 GiB", progress: 0), "0.0 GiB")
        XCTAssertEqual(CareStudioCount.text("2.3 GiB", progress: 0.5), "1.1 GiB")
        XCTAssertEqual(CareStudioCount.text("512 KiB", progress: 0.5), "256 KiB")
        XCTAssertEqual(CareStudioCount.text("+12.0 GiB", progress: 0.25), "+3.0 GiB")
        XCTAssertEqual(CareStudioCount.text("12 个", progress: 0.4), "4 个")
        // Grouping and decimal marks as the locale writes them.
        XCTAssertEqual(CareStudioCount.text("1,234", progress: 0.9), "1,110")
        XCTAssertEqual(CareStudioCount.text("1,234", progress: 0.5), "617")
        XCTAssertEqual(CareStudioCount.text("1.234,5 MB", progress: 0.5), "617,2 MB")
        XCTAssertEqual(CareStudioCount.text("0.125 GB", progress: 0.5), "0.062 GB")
        XCTAssertEqual(CareStudioCount.text("3 / 12", progress: 0.5), "1 / 6")
    }

    func testTheCountEndsOnTheResultAndNeverPassesIt() {
        func digits(_ text: String) -> Int { Int(text.filter(\.isNumber)) ?? -1 }
        for text in ["2.3 GiB", "1,234", "+12.0 GiB", "999", "1.234,5 MB", "512 KiB"] {
            XCTAssertEqual(CareStudioCount.text(text, progress: 1), text)
            XCTAssertEqual(CareStudioCount.text(text, progress: 1.4), text)
            var previous = -1
            for step in 0...20 {
                let shown = CareStudioCount.text(text, progress: Double(step) / 20)
                XCTAssertLessThanOrEqual(digits(shown), digits(text), "\(text) at \(step): \(shown)")
                XCTAssertGreaterThanOrEqual(digits(shown), previous, "\(text) at \(step): \(shown) went back")
                XCTAssertLessThanOrEqual(shown.count, text.count, "\(text) at \(step): \(shown) is longer")
                previous = digits(shown)
            }
        }
        XCTAssertEqual(CareStudioCount.text("2.3 GiB", progress: -1), "0.0 GiB")
    }

    func testATextWithoutANumberStaysAsItIs() {
        for text in ["—", "未读取", "Up to date", ""] {
            XCTAssertFalse(CareStudioCount.hasNumber(text), text)
            XCTAssertEqual(CareStudioCount.text(text, progress: 0), text)
        }
        XCTAssertTrue(CareStudioCount.hasNumber("0 KiB"))
    }

    /// The counting text has the result's exact size from its first frame and
    /// draws the count over it; a still render (captures, Reduce Motion)
    /// draws the result.
    func testTheCountKeepsTheResultsSizeAndAStillRenderShowsTheResult() throws {
        func image(_ view: some View) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: view
                .font(.system(size: 34, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.black)
                .padding(1)
                .background(Color.white))
            renderer.scale = 2
            return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        }
        let plain = try image(Text("12.3 GiB"))
        let start = try image(CareStudioCountingText("12.3 GiB", counted: false))
        let end = try image(CareStudioCountingText("12.3 GiB", counted: true))
        let still = try image(CareStudioCountingText("12.3 GiB", counted: false)
            .environment(\.featureDisablesLayoutAnimations, true))
        for bitmap in [start, end, still] {
            XCTAssertEqual(bitmap.pixelsWide, plain.pixelsWide)
            XCTAssertEqual(bitmap.pixelsHigh, plain.pixelsHigh)
        }
        XCTAssertNotEqual(start.tiffRepresentation, end.tiffRepresentation, "the count starts at 0.0 GiB")
        XCTAssertEqual(still.tiffRepresentation, end.tiffRepresentation, "a still render shows the result")
    }

    /// CleanMyMac's main button: the glow brightens on hover (the button no
    /// longer grows), a press sinks it; Reduce Motion keeps only the
    /// darkening, and a disabled button does neither.
    func testTheRoundButtonBrightensOnHoverAndSinksWhenPressed() {
        typealias Look = CareStudioActionButtonLook
        XCTAssertGreaterThan(Look.glowOpacity(isHovered: true, isEnabled: true),
                             Look.glowOpacity(isHovered: false, isEnabled: true))
        XCTAssertGreaterThan(Look.brightness(isHovered: true, isPressed: false, isEnabled: true), 0)
        XCTAssertEqual(Look.scale(isPressed: false, isEnabled: true, reduceMotion: false), 1, "a hover does not grow it")
        XCTAssertLessThan(Look.scale(isPressed: true, isEnabled: true, reduceMotion: false), 1)
        XCTAssertLessThan(Look.brightness(isHovered: true, isPressed: true, isEnabled: true), 0)
        XCTAssertEqual(Look.scale(isPressed: true, isEnabled: true, reduceMotion: true), 1, "Reduce Motion: no movement")
        XCTAssertLessThan(Look.brightness(isHovered: false, isPressed: true, isEnabled: true), 0)
        XCTAssertEqual(Look.glowOpacity(isHovered: true, isEnabled: false), Look.glowOpacity(isHovered: false, isEnabled: true))
        XCTAssertEqual(Look.brightness(isHovered: true, isPressed: true, isEnabled: false), 0)
        XCTAssertEqual(Look.scale(isPressed: true, isEnabled: false, reduceMotion: false), 1)
    }
}
