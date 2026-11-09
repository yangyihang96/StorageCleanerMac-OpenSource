#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D231 and D238 (2.0.1 review, 2026-10-27), read from the live accessibility
/// tree of a hosting window (display-bound, `script/display-bound-tests.txt`):
/// every studio page's round button was two elements named “扫描” (a button
/// and an unknown-role container), and the clutter landing's subtitle read
/// out D228's word joiners (“整⁠理⁠重⁠复⁠…”).
@MainActor
final class CareStudioAccessibilityD231Tests: XCTestCase {
    /// Every node's role and readable strings (label, title and a string value).
    private func nodes(in root: NSObject) -> [(role: String?, texts: [String])] {
        var result: [(role: String?, texts: [String])] = []
        var visited = Set<ObjectIdentifier>()
        func read(_ object: NSObject, _ name: String) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        func text(_ value: AnyObject?) -> String? {
            switch value {
            case let string as String: string
            case let attributed as NSAttributedString: attributed.string
            default: nil
            }
        }
        func walk(_ object: NSObject) {
            guard result.count < 4_000, visited.insert(ObjectIdentifier(object)).inserted else { return }
            let texts = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { text(read(object, $0)) }
            result.append((text(read(object, "accessibilityRole")), texts))
            for name in ["accessibilityChildren", "accessibilityChildrenInNavigationOrder"] {
                for case let child as NSObject in (read(object, name) as? [Any]) ?? [] { walk(child) }
            }
            if let view = object as? NSView { for subview in view.subviews { walk(subview) } }
        }
        walk(root)
        return result
    }

    func testTheRoundButtonIsOneButtonElement() async throws {
        let language = MiniWindowLogicLanguageScope(.zhHans)
        defer { language.restore() }
        let host = V0LayoutHost(root: CareStudioActionButton(module: .smartScan, title: "扫描", action: {}),
                                size: CGSize(width: 240, height: 200), accessibility: true)
        defer { host.close() }
        _ = await AccessibilityTree.wait(in: host) { $0.contains { $0.isButton && $0.reads("扫描") } }
        let named = nodes(in: host.hostingView).filter { $0.texts.contains("扫描") }
        XCTAssertEqual(named.count, 1, "one element reads 扫描: \(named)")
        XCTAssertEqual(named.first?.role, NSAccessibility.Role.button.rawValue)
    }

    func testTheClutterSubtitleReadsWithoutWordJoiners() async throws {
        let language = MiniWindowLogicLanguageScope(.zhHans)
        defer { language.restore() }
        let plain = CareStudioLineBreaks.plain(CareStudioModule.clutter.subtitle)
        let host = V0LayoutHost(root: CareStudioHeadline(module: .clutter).frame(width: 460),
                                size: CGSize(width: 520, height: 320), accessibility: true)
        defer { host.close() }
        _ = await AccessibilityTree.wait(in: host) { elements in
            elements.contains { ($0.label ?? $0.title ?? "").contains("整理重复文件") }
        }
        let texts = nodes(in: host.hostingView).flatMap(\.texts)
        XCTAssertTrue(texts.contains(plain), "the subtitle is read as words: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains(CareStudioLineBreaks.wordJoiner) }, "no word joiner reaches VoiceOver")
    }
}
#endif
